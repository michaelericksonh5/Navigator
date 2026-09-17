// Accessibility-driven UI smoke tests for Navigator.
//
// Why this exists, and why it is not XCUITest: Navigator is built by raw swiftc from two
// source files, not from an Xcode project, and XCUITest needs an Xcode test target - SwiftPM
// cannot host UI tests on macOS. This drives the SAME accessibility API that XCUITest drives,
// from a plain executable, so it runs under the build system the app already has.
//
// It covers exactly the class of defect the unit tests CANNOT see: a command that is presented
// as available but cannot act, and a window that opens in the wrong state. Both shipped at
// least once. Every assertion here corresponds to a bug that was real.
//
// Keep it thin. Logic belongs in NavigatorCore where it is cheap and fast to test; this only
// asks "is the app in the state the user would see".

import AppKit
import ApplicationServices

// MARK: - tiny AX wrapper

struct AX {
    let el: AXUIElement

    static func app(pid: pid_t) -> AX { AX(el: AXUIElementCreateApplication(pid)) }

    func attr(_ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }
    func children() -> [AX] {
        guard let raw = attr(kAXChildrenAttribute as String) as? [AXUIElement] else { return [] }
        return raw.map { AX(el: $0) }
    }
    var title: String { attr(kAXTitleAttribute as String) as? String ?? "" }
    var role: String  { attr(kAXRoleAttribute as String) as? String ?? "" }
    var value: String { attr(kAXValueAttribute as String) as? String ?? "" }
    var enabled: Bool { attr(kAXEnabledAttribute as String) as? Bool ?? false }
    /// Controls expose their label as a DESCRIPTION, not a value - the zoom readout is a button.
    var describedAs: String { attr(kAXDescriptionAttribute as String) as? String ?? "" }

    /// Every descendant, breadth-first, bounded so a runaway tree cannot hang the run.
    func descendants(limit: Int = 8000) -> [AX] {
        var out: [AX] = [], queue = children()
        while !queue.isEmpty, out.count < limit {
            let n = queue.removeFirst()
            out.append(n)
            queue.append(contentsOf: n.children())
        }
        return out
    }

    /// A menu bar item's submenu item, by exact title. Returns nil when either is missing,
    /// which the caller must treat as a failure rather than as "disabled".
    func menuItem(menu: String, item: String) -> AX? {
        guard let bar = attr(kAXMenuBarAttribute as String) else { return nil }
        let barEl = AX(el: bar as! AXUIElement)
        guard let top = barEl.children().first(where: { $0.title == menu }),
              let sub = top.children().first else { return nil }
        return sub.children().first { $0.title == item }
    }

    /// Menu titles change with state ("Undo Move to Trash"), so prefix matching is needed.
    func menuItem(menu: String, startingWith prefix: String) -> AX? {
        guard let bar = attr(kAXMenuBarAttribute as String) else { return nil }
        let barEl = AX(el: bar as! AXUIElement)
        guard let top = barEl.children().first(where: { $0.title == menu }),
              let sub = top.children().first else { return nil }
        return sub.children().first { $0.title.hasPrefix(prefix) }
    }

    @discardableResult func press() -> Bool {
        AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }
    func setSelected(_ on: Bool) {
        AXUIElementSetAttributeValue(el, kAXSelectedAttribute as CFString, on as CFTypeRef)
    }
}

// MARK: - harness

var failures: [String] = []
var checks = 0

func check(_ what: String, _ condition: Bool) {
    checks += 1
    if condition { print("  ok    \(what)") }
    else { print("  FAIL  \(what)"); failures.append(what) }
}

/// Wait until a condition HOLDS, not for a fixed number of seconds.
///
/// Fixed sleeps are why this suite was flaky: run straight after a rebuild, with the previous
/// instance still terminating, 5 seconds was not enough and three unrelated checks failed. A
/// flaky UI test is worse than no UI test - it teaches you to ignore red.
@discardableResult
func waitUntil(_ what: String, timeout: Double = 25, _ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        settle(0.25)
    }
    print("  (timed out waiting for \(what))")
    return false
}

func settle(_ seconds: Double = 1.2) {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until { RunLoop.current.run(mode: .default, before: until) }
}

func navigatorPID() -> pid_t? {
    NSWorkspace.shared.runningApplications
        .first { $0.bundleIdentifier == "com.merickson.navigator" }?.processIdentifier
}

/// Point Navigator at a folder through the address bar, which is the only entry point that
/// does not depend on the current selection or view mode.
/// Point Navigator at a folder through the address bar, retrying until the tab actually
/// changes.
///
/// One attempt is not enough. The address bar needs time to open, and how much time depends on
/// what the app is busy with - a tab left pointing at a share that has since been unmounted
/// makes everything slower, and a fixed 0.6s delay silently dropped the typed path. The suite
/// then failed for a reason that had nothing to do with the build under test.
func goTo(_ path: String, _ app: AX) {
    let leaf = (path as NSString).lastPathComponent
    let want = leaf.isEmpty ? "Macintosh HD" : leaf
    func arrived() -> Bool {
        app.children().contains { $0.role == kAXWindowRole as String && $0.title == want }
    }
    for attempt in 1...4 {
        if arrived() { settle(0.5); return }
        let src = """
        tell application "Navigator" to activate
        delay 0.8
        tell application "System Events" to tell process "Navigator"
          keystroke "l" using {command down}
          delay \(0.8 * Double(attempt))
          keystroke "\(path)"
          delay 0.5
          key code 36
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if waitUntil("navigation to \(want) (attempt \(attempt))", timeout: 12, arrived) {
            settle(0.6); return
        }
    }
    print("  (never reached \(want) after 4 attempts)")
}

/// The file list, wherever it is.
///
/// Depth-first, stopping at the FIRST table rather than materialising every descendant: a flat
/// breadth-first cap silently truncated once the window had several tabs and a populated
/// sidebar, so the table existed but was never reached.
func fileTable(_ app: AX) -> AX? {
    func find(_ node: AX, depth: Int) -> AX? {
        if depth > 24 { return nil }
        for c in node.children() {
            if c.role == kAXTableRole as String { return c }
            if let hit = find(c, depth: depth + 1) { return hit }
        }
        return nil
    }
    for win in app.children() where win.role == kAXWindowRole as String {
        if let t = find(win, depth: 0) { return t }
    }
    return nil
}

func rows(_ app: AX) -> [AX] {
    guard let t = fileTable(app) else { return [] }
    return t.children().filter { $0.role == kAXRowRole as String }
}

/// Select a row through the table's own selection attribute.
///
/// NOT by synthesising a click at the row's screen position: that moves the real cursor, lands
/// on whatever happens to be under it, and one stray click cascaded into every later check
/// failing. This asks the table to select, which is what the table is for.
@discardableResult
func selectRow(_ table: AX, _ r: AX) -> Bool {
    AXUIElementSetAttributeValue(table.el, kAXSelectedRowsAttribute as CFString,
                                 [r.el] as CFArray) == .success
}

func rowName(_ r: AX) -> String {
    r.descendants().first { $0.role == kAXStaticTextRole as String }?.value ?? ""
}

// MARK: - the tests

let fixture = NSTemporaryDirectory() + "navigator-uismoke-\(UUID().uuidString)"
let fm = FileManager.default
try? fm.createDirectory(atPath: fixture, withIntermediateDirectories: true)
for n in ["alpha.txt", "beta.txt"] {
    fm.createFile(atPath: fixture + "/" + n, contents: Data(n.utf8))
}
try? fm.createDirectory(atPath: fixture + "/nested", withIntermediateDirectories: true)
fm.createFile(atPath: fixture + "/nested/deep.txt", contents: Data("deep".utf8))
// a SMALL image: fit would scale it UP, so it proves the viewer opens at 100% rather than
// merely failing to shrink something oversized.
if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 240,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 320, height: 240).fill()
    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: fixture + "/small_320x240.png"))
    }
}

guard AXIsProcessTrusted() else {
    print("REFUSING TO RUN: this process is not trusted for Accessibility.")
    print("Grant it in System Settings > Privacy & Security > Accessibility, then re-run.")
    exit(2)
}

// A stale instance would answer with the previous build's behaviour.
for a in NSWorkspace.shared.runningApplications where a.bundleIdentifier == "com.merickson.navigator" {
    a.terminate()
}
settle(2.0)
let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
let sem = DispatchSemaphore(value: 0)
NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Navigator.app"),
                                   configuration: cfg) { _, _ in sem.signal() }
_ = sem.wait(timeout: .now() + 20)

guard waitUntil("Navigator to start", { navigatorPID() != nil }),
      let pid = navigatorPID() else { print("Navigator did not start"); exit(1) }
let app = AX.app(pid: pid)
// Do NOT require a table before navigating. Navigator restores TABS, and the active tab at
// launch may be one that legitimately has no table - a folder on a share that has since been
// unmounted shows an empty pane. Waiting for a table first made the whole suite fail for a
// reason that had nothing to do with the build under test. Wait for a window, navigate to our
// own fixture, and require the table THERE.
guard waitUntil("a Navigator window", timeout: 40, { !AX.app(pid: pid).children().isEmpty }) else {
    print("Navigator started but never presented a window"); exit(1)
}
print("Navigator pid \(pid)\nfixture \(fixture)\n")

goTo(fixture, app)
guard waitUntil("the fixture folder's file table", timeout: 40, { fileTable(app) != nil }) else {
    print("navigated to the fixture but no file table appeared"); exit(1)
}

// ---- 1. commands must not offer themselves when they cannot act ----
// Every one of these shipped ENABLED with an empty selection and silently did nothing.
print("commands with an EMPTY selection:")
let needsSelection = ["Duplicate", "Compress", "Get Info", "Rename…", "Quick Look", "Move to Trash", "Make Alias"]
for name in needsSelection {
    guard let m = app.menuItem(menu: "File", item: name) else {
        check("File > \(name) exists", false); continue
    }
    check("File > \(name) disabled with no selection", !m.enabled)
}

// ---- 2. ... and must offer themselves when they can ----
print("\ncommands with a REAL selection:")
if let table = fileTable(app), let first = rows(app).first(where: { rowName($0).hasSuffix(".txt") }) {
    selectRow(table, first)
    settle(1.5)
    for name in needsSelection {
        guard let m = app.menuItem(menu: "File", item: name) else {
            check("File > \(name) exists", false); continue
        }
        check("File > \(name) enabled with a selection", m.enabled)
    }
} else {
    check("a .txt row was selectable", false)
}

// ---- 3. Up at the filesystem root ----
print("\nnavigation bounds:")
goTo("/", app)
if let up = app.menuItem(menu: "Go", item: "Enclosing Folder") {
    check("Go > Enclosing Folder disabled at /", !up.enabled)
} else { check("Go > Enclosing Folder exists", false) }
goTo(fixture, app)
if let up = app.menuItem(menu: "Go", item: "Enclosing Folder") {
    check("Go > Enclosing Folder enabled in a subfolder", up.enabled)
} else { check("Go > Enclosing Folder exists", false) }

// ---- 4. search runs WITHOUT pressing Return ----
// It used to run only on Return, which is the single biggest reason search felt broken.
print("\nsearch:")
let typeSearch = """
tell application "System Events" to tell process "Navigator"
  keystroke "f" using {command down}
  delay 0.6
  keystroke "deep"
end tell
"""
var e1: NSDictionary?
NSAppleScript(source: typeSearch)?.executeAndReturnError(&e1)
let banner = waitUntil("the search banner (typing alone must start a search)") {
    app.descendants().contains { $0.value.hasPrefix("Search results in") }
}
check("typing alone starts a search (no Return pressed)", banner)

// ---- 5. image viewer opens at 100%, not scaled to the window ----
print("\nimage viewer:")
let imgCfg = NSWorkspace.OpenConfiguration(); imgCfg.activates = true
let imgSem = DispatchSemaphore(value: 0)
NSWorkspace.shared.open([URL(fileURLWithPath: fixture + "/small_320x240.png")],
                        withApplicationAt: URL(fileURLWithPath: "/Applications/Navigator.app"),
                        configuration: imgCfg) { _, _ in imgSem.signal() }
_ = imgSem.wait(timeout: .now() + 20)
waitUntil("the image viewer window") { app.children().contains { $0.title.hasPrefix("small_320x240") } }
settle(1.0)
let viewer = app.children().first { $0.title.hasPrefix("small_320x240") }
if let v = viewer {
    let texts = v.descendants().flatMap { [$0.value, $0.describedAs] }
    let dims = texts.first { $0.contains("\u{00D7}") } ?? ""   // the "640 × 480" readout
    check("viewer reports the image's real size (got \"\(dims)\")",
          dims.replacingOccurrences(of: " ", with: "") == "320\u{00D7}240")
    let zoomTexts = texts.filter { $0.contains("%") }
    check("viewer opens at 100%, not fitted", zoomTexts.contains { $0.replacingOccurrences(of: " ", with: "").contains("100%") })
    if !zoomTexts.contains(where: { $0.replacingOccurrences(of: " ", with: "").contains("100%") }) {
        print("        (zoom readouts seen: \(zoomTexts))")
    }
} else {
    check("image viewer window opened", false)
}

// ---- report ----
try? fm.removeItem(atPath: fixture)
print("\n\(checks - failures.count)/\(checks) checks passed")
if failures.isEmpty { print("UI SMOKE: PASS"); exit(0) }
print("UI SMOKE: FAIL")
for f in failures { print("  - \(f)") }
exit(1)
