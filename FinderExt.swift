// Navigator's Finder Sync extension.
//
// Gives Navigator its own submenu in Finder's MAIN right-click menu — not buried
// under Services, and not mixed in with "Set Desktop Picture". This is the only
// supported way for an app to do that (it's the same mechanism cloud clients use).
//
// It deliberately contains NO image logic. Every item just hands the selected
// paths to the running Navigator through the navigatoraction:// URL scheme, and
// Navigator's existing handler does the work — including deciding folder→batch vs
// image→single/multi. One implementation, one place to fix things.
//
// Built by rebuild.sh into Navigator.app/Contents/PlugIns/NavigatorFinder.appex.

import Cocoa
import FinderSync
import os

// @objc(...) pins the Objective-C runtime name. Without it Swift exposes the class
// as "<module>.NavigatorFinderSync", the NSExtensionPrincipalClass lookup fails, and
// FinderSync aborts in -[FIFinderSyncExtension begin] the moment Finder loads us.
@objc(NavigatorFinderSync)
final class NavigatorFinderSync: FIFinderSync {

    override init() {
        super.init()
        // Observe the whole filesystem root. Finder only offers an extension's menu
        // for items inside an observed directory, and Navigator's actions make sense
        // anywhere — home, network volumes, cloud folders. Narrower roots (home,
        // /Volumes) are not honoured for this purpose.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/", isDirectory: true)]
    }

    // MARK: - Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // Right-click on empty space in a Finder window: offer to open THAT folder.
        // Finder decides where an extension's items go (down by Quick Actions) — an
        // extension can't place them next to Open, so keep them few and obvious.
        if menuKind == .contextualMenuForContainer {
            guard let here = FIFinderSyncController.default().targetedURL() else { return nil }
            let m = NSMenu()
            let item = NSMenuItem(title: "Open “\(here.lastPathComponent)” in Navigator",
                                  action: #selector(openContainer(_:)), keyEquivalent: "")
            item.target = self
            item.image = Self.appIcon
            m.addItem(item)
            let gdd = NSMenuItem(title: "GDD to Assets…", action: #selector(openGDDTool(_:)), keyEquivalent: "")
            gdd.target = self
            gdd.image = Self.vertexIcon
            m.addItem(gdd)
            return m
        }
        guard menuKind == .contextualMenuForItems else { return nil }
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !urls.isEmpty else { return nil }

        let imageCount = urls.filter { Self.isImage($0) }.count
        let hasImage = imageCount > 0
        let hasPNG = urls.contains { $0.pathExtension.lowercased() == "png" }
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        let hasFolder = !folders.isEmpty
        let hasPSD = urls.contains { ["psd", "psb"].contains($0.pathExtension.lowercased()) }
        // Detected by the manifest Layerize writes, as Navigator does, not by the name.
        let hasLayerFolder = folders.contains {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("_layers.json").path)
        }
        let isGDD = urls.count == 1 && Self.gddExts.contains(urls[0].pathExtension.lowercased())
        let hasPS = Self.installed("com.adobe.Photoshop")
        let hasAE = Self.aeBundleID != nil

        let root = NSMenu()

        // Everything lives under the one "Navigator" item. "Open Location" used to also
        // sit at the top level for one-click reach, but next to the submenu's "Open in
        // Navigator" it just read as the same command listed twice.
        let parent = NSMenuItem(title: "Navigator", action: nil, keyEquivalent: "")
        parent.image = Self.appIcon
        let sub = NSMenu()

        add(sub, "Open in Navigator", "open", Self.appIcon)
        let loc = NSMenuItem(title: "Open Location in Navigator",
                             action: #selector(openLocation(_:)), keyEquivalent: "")
        loc.target = self
        loc.image = Self.appIcon
        sub.addItem(loc)

        // The same image tools as Navigator's own right-click menu, gated the same way:
        // Photoshop / After Effects rows only when that app is present, image-only rows
        // only when the selection has an image. Each carries the icon of the app or
        // service that does the work. One separator divides "open" from "do something";
        // Finder draws separators as a full blank row, so more than one looks broken.
        if hasImage || hasFolder || hasPSD || isGDD {
            sub.addItem(.separator())
        }
        if hasImage || hasFolder {
            if hasPS {
                add(sub, "Remove BG", "removebg", Self.psIcon)
            }
            if hasAE, hasPNG || hasFolder {
                // The same two jobs Navigator's own menu offers; one item that silently
                // picked soft FX left every symbol keyed from Finder see-through.
                sub.addItem(submenu("Chroma Key BG", Self.aeIcon) { m in
                    add(m, "Soft FX — keep transparency", "chromakey", Self.icon(systemSymbol: "sparkles"))
                    add(m, "Solid subject — opaque interior", "chromakey-solid", Self.icon(systemSymbol: "square.fill"))
                })
            }
            if hasAE, hasImage {
                // Paid per image; Navigator shows the price and asks before spending.
                sub.addItem(submenu("FX Alpha Upscale", Self.aeIcon) { m in
                    add(m, "2K", "fxalpha-2k")
                    add(m, "4K", "fxalpha-4k")
                })
            }
            if hasImage {
                // Ratio × colour, exactly as Navigator's menu. Addressed by INDEX into
                // Navigator's `aiPrepColors` and `nb2Ratios`, like the upscalers below.
                sub.addItem(submenu("Prep for AI", Self.icon(systemSymbol: "wand.and.stars")) { m in
                    m.addItem(submenu("Auto (nearest ratio)", Self.icon(systemSymbol: "wand.and.stars")) {
                        colourItems($0, ratio: "auto")
                    })
                    m.addItem(.separator())
                    for (i, r) in Self.prepRatios.enumerated() {
                        m.addItem(submenu(r, nil) { colourItems($0, ratio: String(i)) })
                    }
                })
            }

            sub.addItem(submenu(hasImage ? "Upscale (AI)" : "Batch Upscale (AI)",
                                Self.icon(systemSymbol: "arrow.up.left.and.arrow.down.right")) { m in
                // Addressed by INDEX into Navigator's own `upscaleOptions`, so the two menus
                // cannot drift: reorder that list and Finder follows. Titles are duplicated
                // here because the extension is a separate target and can't import them.
                add(m, "Crystal (best fidelity) ×4", "upscale-0", Self.falIcon)
                add(m, "AuraSR (non-generative) ×4", "upscale-1", Self.falIcon)
                add(m, "Topaz ×4", "upscale-2", Self.falIcon)
                add(m, "Local resample ×4 (free)", "upscale-3", Self.icon(systemSymbol: "desktopcomputer"))
                // Firefly runs inside Photoshop and takes images only, as in Navigator.
                if hasPS, hasImage {
                    m.addItem(.separator())
                    add(m, "Firefly ×2", "firefly-2", Self.psIcon)
                    add(m, "Firefly ×4", "firefly-4", Self.psIcon)
                }
            })

            // These open a Navigator window rather than running silently, so they read
            // as "…" commands exactly as they do in Navigator's own menu.
            if hasImage {
                add(sub, "Restyle (AI)…", "restyle", Self.icon(systemSymbol: "paintbrush.pointed"))
                add(sub, "Layerize (AI)…", "layerize", Self.falIcon)
            }
            if imageCount >= 2 {
                add(sub, "Swipe Compare", "compare", Self.icon(systemSymbol: "rectangle.split.2x1"))
            }
            if hasLayerFolder, hasPS {
                add(sub, "Assemble Layers into PSD", "assemblelayers", Self.psIcon)
            }
        }

        // Photoshop documents are not "images" by extension, so this sits outside the
        // block above — a PSD-only selection reaches nothing else here.
        if hasPSD, hasPS {
            add(sub, "Quick Export as PNG", "exportpng", Self.psIcon)
        }
        // Always offered: on a GDD it opens with that document picked and read; on
        // anything else it just opens the tool.
        if !(hasImage || hasFolder || hasPSD || isGDD) { sub.addItem(.separator()) }
        add(sub, "GDD to Assets…", "gddtoassets", Self.vertexIcon)

        parent.submenu = sub
        root.addItem(parent)
        return root
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: String, _ image: NSImage? = nil) {
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        item.target = self
        item.tag = Self.tag(for: action)
        item.image = image
        menu.addItem(item)
    }

    // Finder hands the action a COPY of the clicked item, and the copy has no
    // representedObject — it arrived as nil, so every tool here silently did nothing.
    // The tag survives the copy, so the action rides in it as an index into this list.
    // Tags start at 1 so an unset tag (0) can't be mistaken for the first action.
    private static var actions: [String] = []
    private static func tag(for action: String) -> Int {
        if let i = actions.firstIndex(of: action) { return i + 1 }
        actions.append(action)
        return actions.count
    }

    private func submenu(_ title: String, _ image: NSImage?, _ fill: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = image
        let m = NSMenu()
        fill(m)
        item.submenu = m
        return item
    }

    private func colourItems(_ menu: NSMenu, ratio: String) {
        for (i, c) in Self.prepColours.enumerated() {
            let img = c.rgb.map { rgb -> NSImage? in
                let cfg = NSImage.SymbolConfiguration(paletteColors: [NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)])
                return Self.sized(NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(cfg))
            } ?? Self.icon(systemSymbol: "eyedropper.halffull")
            add(menu, c.name, "prep-\(i)-\(ratio)", img)
        }
    }

    // MARK: - Dispatch to Navigator

    /// Right-click empty space → open the folder being viewed.
    @objc private func openContainer(_ sender: NSMenuItem) {
        guard let here = FIFinderSyncController.default().targetedURL() else { return }
        openInNavigator([here])
    }

    /// Right-click empty space → GDD to Assets. The folder rides along only because the
    /// action URL always carries paths; Navigator pre-picks nothing for a folder.
    @objc private func openGDDTool(_ sender: NSMenuItem) {
        guard let here = FIFinderSyncController.default().targetedURL() else { return }
        send("gddtoassets", [here])
    }

    /// Open the folder the selection lives in. For a selected FOLDER that's the
    /// folder itself; for files it's their enclosing directory. Passing the file
    /// would open it (an image would land in the viewer) — the point here is the
    /// location, so resolve to a directory first.
    @objc private func openLocation(_ sender: NSMenuItem) {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        var dirs: [URL] = []
        var seen = Set<String>()
        for u in urls {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let target = isDir ? u : u.deletingLastPathComponent()
            if seen.insert(target.path).inserted { dirs.append(target) }
        }
        if dirs.isEmpty, let here = FIFinderSyncController.default().targetedURL() { dirs = [here] }
        openInNavigator(dirs)
    }

    private func openInNavigator(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: Self.appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard Self.actions.indices.contains(sender.tag - 1) else {
            Self.log.error("no action for tag \(sender.tag) (\(sender.title, privacy: .public))")
            return
        }
        let action = Self.actions[sender.tag - 1]
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        Self.log.notice("clicked \(action, privacy: .public), \(urls.count) selected")
        guard !urls.isEmpty else { return }

        if action == "open" { openInNavigator(urls); return }
        // navigatoraction://<action>?hex=<hex of the newline-joined paths>. Hex keeps
        // spaces, quotes and non-ASCII names intact with no escaping questions.
        send(action, urls)
    }

    private static let log = Logger(subsystem: "com.merickson.navigator.findersync", category: "menu")

    private func send(_ action: String, _ urls: [URL]) {
        Self.log.notice("send \(action, privacy: .public) with \(urls.count) path(s)")
        let joined = urls.map { $0.path }.joined(separator: "\n")
        let hex = Data(joined.utf8).map { String(format: "%02x", $0) }.joined()
        guard let u = URL(string: "navigatoraction://\(action)?hex=\(hex)") else { return }
        NSWorkspace.shared.open(u)
    }

    // MARK: - Helpers

    private static let imageExts: Set<String> = [
        "png","jpg","jpeg","gif","bmp","tif","tiff","webp","heic","psd","avif","jp2"
    ]
    private static func isImage(_ u: URL) -> Bool { imageExts.contains(u.pathExtension.lowercased()) }
    // Copies of Navigator's `aiPrepColors` (name, sRGB; nil = adaptive) and `nb2Ratios`,
    // in the same order — the menu sends indices, so only the titles can go stale.
    private static let prepColours: [(name: String, rgb: (CGFloat, CGFloat, CGFloat)?)] = [
        ("Adaptive (from image)", nil), ("White", (1, 1, 1)), ("Black", (0, 0, 0)),
        ("Greenscreen", (0, 1, 0)), ("MagentaScreen", (1, 0, 1)), ("Bluescreen", (0, 0, 1)),
        ("Yellow", (1, 1, 0)), ("Orange", (1, 0.5, 0)),
    ]
    private static let prepRatios = ["16:9", "9:16", "4:3", "3:4", "1:1", "3:2", "2:3",
                                     "21:9", "9:21", "5:4", "4:5"]
    // What GDD to Assets can read (GDDLibrary.entries): Google Docs/Sheets/Slides
    // pointers and Word files.
    private static let gddExts: Set<String> = ["gdoc", "gsheet", "gslides", "docx"]
    // After Effects 2026 is "com.adobe.AfterEffects.application"; older builds dropped the
    // suffix. Checking only the old one hid every After Effects row on a Mac that has it.
    private static let aeBundleID: String? = ["com.adobe.AfterEffects.application", "com.adobe.AfterEffects"]
        .first { installed($0) }
    private static func installed(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
    // The extension lives at Navigator.app/Contents/PlugIns/X.appex, so the host app
    // is three directories up.
    private static let appURL: URL = Bundle.main.bundleURL
        .deletingLastPathComponent()   // PlugIns
        .deletingLastPathComponent()   // Contents
        .deletingLastPathComponent()   // Navigator.app
    // MARK: - Menu icons
    //
    // A menu lays icons out at the NSImage's own size, so everything here is stamped
    // to 16pt. Miss that and a 32pt app icon stretches its row and throws the whole
    // menu's spacing out.
    private static let iconSize = NSSize(width: 16, height: 16)

    private static func sized(_ img: NSImage?) -> NSImage? {
        img?.size = iconSize
        return img
    }
    /// The installed app's own icon, or nil when it isn't there.
    private static func appIcon(_ bundleID: String) -> NSImage? {
        guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return sized(NSWorkspace.shared.icon(forFile: u.path))
    }
    private static func icon(systemSymbol: String) -> NSImage? {
        sized(NSImage(systemSymbolName: systemSymbol, accessibilityDescription: nil))
    }
    /// A PNG bundled in Assets/, falling back to an SF Symbol so a missing file
    /// degrades to a sensible glyph instead of a blank gap. Vertex has no installed
    /// app to borrow an icon from, and fal is a web service — hence bundling.
    private static func bundled(_ name: String, fallback symbol: String) -> NSImage? {
        if let u = Bundle.main.url(forResource: name, withExtension: "png"),
           let img = NSImage(contentsOf: u) { return sized(img) }
        return icon(systemSymbol: symbol)
    }

    private static let appIcon: NSImage? = sized(NSWorkspace.shared.icon(forFile: appURL.path))
    private static let psIcon: NSImage? = appIcon("com.adobe.Photoshop")
    private static let aeIcon: NSImage? = aeBundleID.flatMap { appIcon($0) }
    private static let vertexIcon: NSImage? = bundled("vertex", fallback: "sparkles")
    private static let falIcon: NSImage? = bundled("fal", fallback: "bolt.fill")
}
