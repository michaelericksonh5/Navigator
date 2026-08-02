import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ImageIO
import Security
import Quartz
import QuickLookThumbnailing
import CoreServices
import NetFS
import FinderSync   // detect / offer to enable the Finder menu extension
import Carbon.HIToolbox   // RegisterEventHotKey — the ONLY permission-free global hotkey
import SQLite3   // read-only peek at Google Drive's own index — see googleDriveLocalPath
import os

// Perf logging — view in Console.app (or `log stream`) filtered by
// subsystem "com.merickson.navigator". Records how long SMB enumeration and
// metadata enrichment actually take, so slow folders are diagnosable.
let navLog = Logger(subsystem: "com.merickson.navigator", category: "perf")

extension Notification.Name {
    static let navigatorDidNavigate = Notification.Name("navigatorDidNavigate")
    static let navigatorFocusSearch = Notification.Name("navigatorFocusSearch")
    static let navigatorResignFields = Notification.Name("navigatorResignFields")   // drop address/search focus so typing → type-to-select
}

enum ViewMode: String { case list, icon, gallery }
enum ConflictPolicy { case keepBoth, replace, skip }

final class TransferProgress: ObservableObject {
    @Published var fraction: Double = 0
    @Published var current: String = ""
    @Published var cancelled = false
    @Published var done = 0            // items finished
    @Published var total = 0           // items in this transfer (0 = unknown)
    // "1,234 of 30,000 items" — a percentage alone doesn't tell you how much is left.
    var countText: String {
        guard total > 1 else { return "" }
        let f = NumberFormatter(); f.numberStyle = .decimal
        let d = f.string(from: NSNumber(value: done)) ?? "\(done)"
        let t = f.string(from: NSNumber(value: total)) ?? "\(total)"
        return "\(d) of \(t) items"
    }
}

// App-wide, non-blocking progress for background-removal jobs (Photoshop /
// After Effects). Shown in the status bar of every window; the user keeps
// using Navigator while it runs. All mutations on the main thread.
final class BGJobProgress: ObservableObject {
    static let shared = BGJobProgress()
    @Published var active = false
    @Published var label = ""       // "Removing backgrounds" / "Chroma keying"
    @Published var done = 0
    @Published var total = 0        // 0 → indeterminate (folder batch)
    @Published var finished = false // showing the final summary line
    private var gen = 0

    func start(_ label: String, total: Int) {
        gen += 1; self.label = label; self.total = total; done = 0
        finished = false; active = true
    }
    func advance() { done = min(done + 1, max(total, done + 1)) }
    // Show a final one-line summary, then auto-dismiss after a few seconds
    // (unless a new job started in the meantime).
    func finish(_ summary: String) {
        gen += 1; let g = gen
        label = summary; finished = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.gen == g else { return }
            self.active = false; self.finished = false
        }
    }
    var text: String {
        if finished { return label }
        return total > 0 ? "\(label)… \(done) of \(total)" : "\(label)…"
    }
    var fraction: Double? { total > 0 && !finished ? Double(done) / Double(total) : nil }
}

// Result of driving an Adobe app: ok + a status/error message (script stdout on
// success, or the failure reason).
struct ScriptResult { let ok: Bool; let message: String }

enum SortField: String, CaseIterable { case name, modified, size, kind }
enum GroupBy: String, CaseIterable { case none, kind, date, size }

enum SearchKind: String, CaseIterable {
    case any = "Any", images = "Images", documents = "Documents", pdf = "PDFs"
    case movies = "Movies", audio = "Audio", folders = "Folders"
    var typeTree: String? {
        switch self {
        case .any: return nil
        case .images: return "public.image"
        case .documents: return "public.content"
        case .pdf: return "com.adobe.pdf"
        case .movies: return "public.movie"
        case .audio: return "public.audio"
        case .folders: return "public.folder"
        }
    }
}

// Rich per-file metadata read lazily from Spotlight (the same index Finder uses):
// media duration, pixel dimensions, and Finder comment. Loaded off the main
// thread and cached, so scrolling a folder of media never blocks.
struct FileMeta {
    var duration: Double?          // seconds (audio/video)
    var width: Int?
    var height: Int?
    var comment: String?
    var loaded = false
}

final class MetadataCache {
    static let shared = MetadataCache()
    private var store: [String: FileMeta] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "navigator.metadata", qos: .utility, attributes: .concurrent)

    func meta(for url: URL, completion: @escaping (FileMeta) -> Void) {
        let key = url.path
        lock.lock(); let cached = store[key]; lock.unlock()
        if let cached { completion(cached); return }
        queue.async {
            var m = FileMeta(loaded: true)
            if let md = MDItemCreate(nil, url.path as CFString) {
                if let d = MDItemCopyAttribute(md, kMDItemDurationSeconds) as? Double { m.duration = d }
                if let w = MDItemCopyAttribute(md, kMDItemPixelWidth) as? Int { m.width = w }
                if let h = MDItemCopyAttribute(md, kMDItemPixelHeight) as? Int { m.height = h }
                if let c = MDItemCopyAttribute(md, kMDItemFinderComment) as? String, !c.isEmpty { m.comment = c }
            }
            self.lock.lock(); self.store[key] = m; self.lock.unlock()
            DispatchQueue.main.async { completion(m) }
        }
    }

    /// What's already known about a file, without starting a lookup. Sorting by Time or
    /// Dimensions runs over every item on every re-sort, so it must never block and must
    /// never kick off work — `prefetch` below does the loading, once.
    func cached(for url: URL) -> FileMeta? {
        lock.lock(); defer { lock.unlock() }
        return store[url.path]
    }

    /// Load metadata for a whole listing and call back ONCE, when the last one lands.
    ///
    /// Sorting by Time or Dimensions is the reason this exists. Those values arrive
    /// per-cell, asynchronously, and only for cells that have actually been drawn — so a
    /// header click that sorted on whatever happened to be loaded produced a visibly
    /// wrong order (everything below the fold counted as unknown) that then never
    /// corrected itself, because nothing re-sorted when the values arrived. Filling the
    /// cache first and re-sorting after is what makes those two columns honest.
    func prefetch(_ urls: [URL], completion: @escaping () -> Void) {
        let missing = urls.filter { cached(for: $0) == nil }
        guard !missing.isEmpty else { completion(); return }
        let group = DispatchGroup()
        for u in missing {
            group.enter()
            meta(for: u) { _ in group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }
}

// MARK: - File owner (POSIX)

/// The POSIX owner name for a path, for the Owner column.
///
/// Deliberately NOT added to the listing's URLResourceKeys. Those are fetched for every
/// entry the moment a folder is enumerated, and on a DFS-heavy SMB share each extra
/// attribute is a round trip per file — the exact cost `namesOnlyItems` exists to dodge.
/// This is asked for only when the Owner column is on screen or being sorted by.
///
/// Only the uid→name mapping is cached, because that is the expensive half (getpwuid can
/// hit a directory service) and it does not change under us. The stat itself is repeated
/// every time, so a chown shows up on the next redraw instead of being remembered wrong
/// forever.
/// ponytail: stat-per-render is fine locally (~µs) and rides the SMB attribute cache
/// remotely; if the Owner column ever feels slow on a big network folder, cache
/// path→name per directory load and clear it in Browser.load().
enum FileOwner {
    private static var names: [uid_t: String] = [:]
    private static let lock = NSLock()

    static func name(for url: URL) -> String {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return "—" }
        let uid = st.st_uid
        lock.lock()
        if let cached = names[uid] { lock.unlock(); return cached }
        lock.unlock()
        let resolved = getpwuid(uid).flatMap { String(validatingUTF8: $0.pointee.pw_name) } ?? String(uid)
        lock.lock(); names[uid] = resolved; lock.unlock()
        return resolved
    }
}

// On-demand recursive folder sizing (opt-in, like Finder's "Calculate all sizes").
// ObservableObject so Size cells refresh once a computed total lands.
final class FolderSizeCache: ObservableObject {
    static let shared = FolderSizeCache()
    @Published private var version = 0
    private var store: [String: Int64] = [:]
    private var inFlight: Set<String> = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "navigator.foldersize", qos: .utility, attributes: .concurrent)

    func cached(_ url: URL) -> Int64? { lock.lock(); defer { lock.unlock() }; return store[url.path] }

    func compute(_ url: URL) {
        let key = url.path
        lock.lock()
        if store[key] != nil || inFlight.contains(key) { lock.unlock(); return }
        inFlight.insert(key); lock.unlock()
        queue.async {
            let total = FolderSizeCache.size(of: url)
            self.lock.lock(); self.store[key] = total; self.inFlight.remove(key); self.lock.unlock()
            DispatchQueue.main.async { self.version &+= 1 }
        }
    }

    static func size(of url: URL) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                   options: [], errorHandler: { _, _ in true }) {
            for case let f as URL in en {
                let v = try? f.resourceValues(forKeys: Set(keys))
                if v?.isRegularFile == true {
                    total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
                }
            }
        }
        return total
    }
}

// Compact size string for the narrowest reasonable Size column: no space
// before the unit, "b" not "bytes", "0KB" not "Zero KB". KB is always a whole
// number (matches how ByteCountFormatter itself never showed KB with a
// decimal); MB/GB/TB get one decimal only below 10 of that unit.
func compactByteCount(_ bytes: Int64) -> String {
    if bytes == 0 { return "0KB" }
    if bytes < 1000 { return "\(bytes)b" }
    if bytes < 1_000_000 { return "\(Int((Double(bytes) / 1000).rounded()))KB" }
    for (threshold, suffix) in [(1e12, "TB"), (1e9, "GB"), (1e6, "MB")] where Double(bytes) >= threshold {
        let value = Double(bytes) / threshold
        return (value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)) + suffix
    }
    return "\(bytes)b"
}

struct SizeCell: View {
    let item: FileItem
    @ObservedObject private var cache = FolderSizeCache.shared
    var body: some View {
        if item.isDirectory {
            if let s = cache.cached(item.url) {
                Text(compactByteCount(s)).foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        } else if item.modified == .distantPast {
            // Network item whose size hasn't been fetched yet (see Browser.lightItem).
            Text("—").foregroundStyle(.tertiary)
        } else {
            Text(compactByteCount(item.size)).foregroundStyle(.secondary)
        }
    }
}

// Renders a date column, showing a placeholder while a network item's metadata
// is still being fetched in the background (sentinel = .distantPast).
// Explorer-style format: "07/16/2026 8:03AM" — no leading zero on the hour, no
// space before AM/PM. SwiftUI's .dateTime FormatStyle has no option for that
// exact spacing, hence the plain DateFormatter.
struct DateCell: View {
    let date: Date
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yyyy h:mma"
        return f
    }()
    var body: some View {
        if date == .distantPast { Text("—").foregroundStyle(.tertiary) }
        else { Text(Self.formatter.string(from: date)).foregroundStyle(.secondary) }
    }
}

func formatDuration(_ seconds: Double) -> String {
    guard seconds >= 1 else { return "" }
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

// Maps Finder's standard tag names to their dot colors; unknown tags show gray.
func tagColor(_ name: String) -> Color {
    switch name.lowercased() {
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "blue": return .blue
    case "purple": return .purple
    case "gray", "grey": return .gray
    default: return .secondary
    }
}

// A table cell that lazily loads Spotlight metadata for one file (like the
// thumbnail cells): shows "—" until the value arrives, then updates in place.
struct MetadataCell: View {
    enum Field { case duration, dimensions }
    let url: URL
    let field: Field
    @State private var text = "—"
    var body: some View {
        Text(text).foregroundStyle(.secondary).lineLimit(1)
            .onAppear { load() }
            .onChange(of: url) { text = "—"; load() }
    }
    private func load() {
        MetadataCache.shared.meta(for: url) { m in
            switch field {
            case .duration:
                let d = m.duration.map(formatDuration) ?? ""
                text = d.isEmpty ? "—" : d
            case .dimensions:
                if let w = m.width, let h = m.height, w > 0, h > 0 { text = "\(w) × \(h)" } else { text = "—" }
            }
        }
    }
}

struct TagsCell: View {
    let tags: [String]
    var body: some View {
        if tags.isEmpty {
            Text("—").foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                ForEach(tags.prefix(5), id: \.self) { tag in
                    Circle().fill(tagColor(tag)).frame(width: 8, height: 8)
                }
                Text(tags.joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: - API keys (macOS Keychain — never plaintext)

enum APIKeys {
    private static let service = "com.merickson.navigator.apikeys"
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data, let s = String(data: d, encoding: .utf8) else { return nil }
        return s.isEmpty ? nil : s
    }
    static func set(_ value: String, _ account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = base; add[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
    // The fal.ai API key (used for AI upscaling).
    static var fal: String? { get { get("fal.ai") } set { set(newValue ?? "", "fal.ai") } }
}

// MARK: - Persistence (UserDefaults-backed view settings)

enum Prefs {
    static let d = UserDefaults.standard
    static var showHidden: Bool { get { d.bool(forKey: "showHidden") } set { d.set(newValue, forKey: "showHidden") } }
    static var viewMode: String { get { d.string(forKey: "viewMode") ?? "list" } set { d.set(newValue, forKey: "viewMode") } }
    static var iconSize: CGFloat {
        get { let v = d.double(forKey: "iconSize"); return v < 32 ? 76 : CGFloat(v) }
        set { d.set(Double(newValue), forKey: "iconSize") }
    }
    static var sortKey: String { get { d.string(forKey: "sortKey") ?? "name" } set { d.set(newValue, forKey: "sortKey") } }
    static var sortAscending: Bool {
        get { d.object(forKey: "sortAscending") == nil ? true : d.bool(forKey: "sortAscending") }
        set { d.set(newValue, forKey: "sortAscending") }
    }
    static var groupBy: String { get { d.string(forKey: "groupBy") ?? "none" } set { d.set(newValue, forKey: "groupBy") } }
    static var showPreview: Bool { get { d.bool(forKey: "showPreview") } set { d.set(newValue, forKey: "showPreview") } }
    static var showSidebar: Bool {
        get { d.object(forKey: "showSidebar") == nil ? true : d.bool(forKey: "showSidebar") }
        set { d.set(newValue, forKey: "showSidebar") }
    }
    static var dualPane: Bool { get { d.bool(forKey: "dualPane") } set { d.set(newValue, forKey: "dualPane") } }
    static var sidebarWidth: CGFloat {
        get { let v = d.double(forKey: "sidebarWidth"); return v < 120 ? 210 : CGFloat(v) }
        set { d.set(Double(newValue), forKey: "sidebarWidth") }
    }
    static var previewWidth: CGFloat {
        get { let v = d.double(forKey: "previewWidth"); return v < 120 ? 280 : CGFloat(v) }
        set { d.set(Double(newValue), forKey: "previewWidth") }
    }
    static var recentFolders: [String] { get { d.stringArray(forKey: "recentFolders") ?? [] } set { d.set(newValue, forKey: "recentFolders") } }
    static var confirmTrash: Bool {
        get { d.object(forKey: "confirmTrash") == nil ? true : d.bool(forKey: "confirmTrash") }
        set { d.set(newValue, forKey: "confirmTrash") }
    }
    static var thumbnailMode: String { get { d.string(forKey: "thumbnailMode") ?? "all" } set { d.set(newValue, forKey: "thumbnailMode") } }  // all | images | off
    static var didOfferDefaults: Bool { get { d.bool(forKey: "didOfferDefaults") } set { d.set(newValue, forKey: "didOfferDefaults") } }
    /// The Open/Save dialog bridge (PickerBridge). On by default: its chord is ⌃⌥⌘-based
    /// so it shadows nothing, and a global hotkey nobody knows about is a feature nobody
    /// finds. The teleport variant is off by default — it needs Accessibility, and asking
    /// for that unprompted is not something an app should do on its own.
    static var pickerHotkeyEnabled: Bool {
        get { d.object(forKey: "pickerHotkeyEnabled") == nil ? true : d.bool(forKey: "pickerHotkeyEnabled") }
        set { d.set(newValue, forKey: "pickerHotkeyEnabled") }
    }
    static var pickerHotkeyChord: String {
        get { d.string(forKey: "pickerHotkeyChord") ?? PickerBridgeRules.chords[0].id }
        set { d.set(newValue, forKey: "pickerHotkeyChord") }
    }
    static var pickerTeleportEnabled: Bool {
        get { d.bool(forKey: "pickerTeleportEnabled") }
        set { d.set(newValue, forKey: "pickerTeleportEnabled") }
    }
    static var warnImageDelete: Bool { get { d.object(forKey: "warnImageDelete") == nil ? true : d.bool(forKey: "warnImageDelete") } set { d.set(newValue, forKey: "warnImageDelete") } }
    static var warnExtensionChange: Bool { get { d.object(forKey: "warnExtensionChange") == nil ? true : d.bool(forKey: "warnExtensionChange") } set { d.set(newValue, forKey: "warnExtensionChange") } }
    static var lastUpdateCheck: Double { get { d.double(forKey: "lastUpdateCheck") } set { d.set(newValue, forKey: "lastUpdateCheck") } }
    static var skipUpdateVersion: String { get { d.string(forKey: "skipUpdateVersion") ?? "" } set { d.set(newValue, forKey: "skipUpdateVersion") } }
    /// Globally visible Details columns. `nil` (the key absent) deliberately means "use
    /// each column's own defaultVisible", so an install that predates this key — and a
    /// fresh install — shows exactly the four columns it always did.
    static var columns: [String]? {
        get { d.stringArray(forKey: "detailColumns") }
        set { newValue == nil ? d.removeObject(forKey: "detailColumns") : d.set(newValue, forKey: "detailColumns") }
    }
    /// The per-folder view options blob (a JSON-encoded ViewOptionsLRU). Stored as Data
    /// rather than a plist dictionary for the same reason favoritesV2 is: one Codable
    /// type on both sides means the shape can't drift.
    static var folderViewOptions: Data? {
        get { d.data(forKey: "folderViewOptionsV1") }
        set { d.set(newValue, forKey: "folderViewOptionsV1") }
    }
    /// Pick the view from what's IN a folder (FolderKind) when the folder has nothing
    /// remembered of its own. Default on, like Explorer — and off in one checkbox,
    /// because a guess about your folders is precisely the kind of help some people
    /// want nothing to do with.
    static var inferFolderView: Bool {
        get { d.object(forKey: "inferFolderView") == nil ? true : d.bool(forKey: "inferFolderView") }
        set { d.set(newValue, forKey: "inferFolderView") }
    }
    /// Has the Setup Assistant opened itself once on this install?
    ///
    /// Set the moment it is SHOWN, not when it is completed: someone who closes it
    /// straight away has answered the question, and a setup screen that reappears until
    /// you satisfy it is the exact behaviour that trains people to dismiss things
    /// unread — which is how this install ended up with Desktop denied in the first
    /// place. Help ▸ Setup Assistant… is always there when they want it back.
    static var didRunSetup: Bool { get { d.bool(forKey: "didRunSetup") } set { d.set(newValue, forKey: "didRunSetup") } }
}

// MARK: - Per-folder view options (⌘J)

/// The store behind "this folder should always open in Details sorted by date".
///
/// Same shape as FavoritesStore: an ObservableObject singleton holding a Codable value
/// and writing it straight back to UserDefaults on every change. The interesting half
/// (recency, the cap, and "what applies to a folder with nothing saved") is pure logic
/// in NavigatorCore's ViewOptionsLRU, where it is unit-tested.
///
/// A folder gets a record the moment its view is CHANGED while you're in it — no opt-in,
/// the way Explorer works. Merely visiting a folder writes nothing, so browsing a tree
/// costs no records and a user who never changes a view setting still has an empty store
/// and the behaviour they always had.
final class FolderViewOptionsStore: ObservableObject {
    static let shared = FolderViewOptionsStore()
    @Published private var lru: ViewOptionsLRU

    private init() {
        if let data = Prefs.folderViewOptions,
           let decoded = try? JSONDecoder().decode(ViewOptionsLRU.self, from: data) {
            // Records written before folderKey existed are keyed on the raw path. Re-file
            // them once and write the result straight back, so the migration is paid on
            // one launch instead of being redone on every launch for a store nobody edits.
            lru = decoded.migratedToNormalizedKeys()
            if lru != decoded { persist() }
        } else {
            lru = ViewOptionsLRU()
        }
    }

    func contains(_ path: String) -> Bool { lru.contains(path) }
    func options(for path: String) -> ViewOptions? { lru.value(for: path) }
    var rememberedCount: Int { lru.count }

    func save(_ options: ViewOptions, for path: String) {
        guard lru.value(for: path) != options else { return }   // no churn on a re-save of the same thing
        lru.set(options, for: path)
        persist()
    }
    func forget(_ path: String) {
        guard lru.contains(path) else { return }
        lru.remove(path)
        persist()
    }
    /// Called when a folder with saved options is opened, so the folders you actually
    /// keep visiting are the ones that survive the cap. Writes only when the order
    /// genuinely moved — otherwise every refresh of the current folder would hit disk.
    func markUsed(_ path: String) {
        if lru.touch(path) { persist() }
    }
    private func persist() { Prefs.folderViewOptions = try? JSONEncoder().encode(lru) }
}

// MARK: - Recent folders (Windows Quick Access-style MRU list)

final class RecentFolders: ObservableObject {
    static let shared = RecentFolders()
    @Published var urls: [URL]
    private let cap = 30
    private let fm = FileManager.default
    init() { urls = Prefs.recentFolders.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) } }
    func record(_ url: URL) {
        let std = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: std.path, isDirectory: &isDir), isDir.boolValue else { return }
        if std.path == "/" { return }
        urls.removeAll { $0.path == std.path }
        urls.insert(std, at: 0)
        if urls.count > cap { urls = Array(urls.prefix(cap)) }
        Prefs.recentFolders = urls.map { $0.path }
    }
    // Drop one entry (sidebar context menu) — a folder you visited once by mistake
    // shouldn't cost you the whole list to get rid of.
    func remove(_ url: URL) {
        let p = url.standardizedFileURL.path
        urls.removeAll { $0.path == p }
        Prefs.recentFolders = urls.map { $0.path }
    }
    func clear() { urls = []; Prefs.recentFolders = [] }
}

// Watches the current directory and fires onChange when its contents change —
// so a file appearing, disappearing, or being renamed refreshes the view
// automatically. Uses FSEvents (what Finder uses) rather than a raw kqueue fd,
// because FSEvents also catches File Provider / cloud-storage changes (e.g.
// Google Drive syncing a file down) that a kqueue on the directory misses.
// Local volumes only; SMB doesn't emit these, so network folders use ⌘R.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private var watchedPath: String?
    private var pending = false
    private let onChange: () -> Void
    init(onChange: @escaping () -> Void) { self.onChange = onChange }
    func watch(_ url: URL) {
        if watchedPath == url.path, stream != nil { return }   // already watching this folder
        stop()
        let path = url.path
        watchedPath = path
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().fire()
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
    }
    // Coalesce bursts of events (a copy/sync fires many) into one refresh.
    private func fire() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pending = false; self?.onChange()
        }
    }
    func stop() {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
        watchedPath = nil
    }
    deinit { if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) } }
}

// Live refresh for NETWORK folders, which FSEvents cannot do: SMB emits no
// filesystem events, so DirectoryWatcher above is deliberately skipped on network
// volumes and every window showing a share used to go stale until ⌘R.
//
// One shared timer for the whole app, not a timer per Browser. That is the entire
// reason this is a coordinator: a per-tab repeating timer is how you end up with a
// dozen of them hammering a dead SMB mount long after the user navigated away, and
// the failure mode (the app wedging on a share nobody is looking at) is far worse
// than the staleness it fixes. Here there is exactly one timer, it only exists while
// the app is active, and it re-derives its targets from the live window list on every
// tick — so navigating away, switching tabs, minimising, or closing a window stops
// the polling for free, with nothing to remember to cancel.
//
// What it polls: the ACTIVE tab of each visible, non-miniaturised window. A
// background tab on a slow share is never touched.
//
// How it detects change: one stat of the folder's own mtime — a single round-trip,
// off the main thread. A full reload only happens when that mtime actually moved,
// because reloading on a timer would fight the user's scroll position and selection
// for no reason. (An in-place edit of a file doesn't bump the parent's mtime, so that
// case still needs ⌘R; catching it would mean enumerating the whole folder every few
// seconds over SMB, which is exactly the cost this design exists to avoid.)
final class NetworkPollCoordinator {
    static let shared = NetworkPollCoordinator()

    /// Base interval. Long enough that an unattended window costs one stat every few
    /// seconds, short enough that a file someone else drops in a shared folder shows
    /// up while you're still looking at the folder.
    private let interval: TimeInterval = 4
    /// A stat slower than this means the share is struggling — back off rather than
    /// queue up more work on a connection that can't keep up.
    private let slowStatBudget: TimeInterval = 2

    private struct State {
        var path: String = ""
        var signature: Date?
        var strikes = 0
        var quietUntil: Date?
        var statInFlight = false
    }
    private var state: [ObjectIdentifier: State] = [:]
    private var timer: Timer?

    func start() {
        let nc = NotificationCenter.default
        // Polling exists to keep the window you are LOOKING at fresh. When the app
        // isn't active nobody is looking, so the timer shouldn't exist at all —
        // this is what guarantees a backgrounded Navigator never touches a share.
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.schedule() }
        nc.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.suspend() }
        if NSApp.isActive { schedule() }
    }

    private func schedule() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = 1   // let the OS coalesce this with other timers; 4s ± 1s is fine
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private func suspend() { timer?.invalidate(); timer = nil }

    @objc private func tick() {
        for w in NSApp.windows.compactMap({ $0 as? NavWindow }) where w.isVisible && !w.isMiniaturized {
            poll(w.model.active)
        }
        // Bound the bookkeeping. Entries belong to Browsers that may be long gone
        // (closed tabs); keeping the map small is cheaper than tracking their deaths.
        if state.count > 64 { state.removeAll() }
    }

    private func poll(_ browser: Browser) {
        guard browser.currentIsNetwork, !browser.isSearching, !browser.isRecents else { return }
        // busy / stalled / slow are the app's own "this share is not answering right
        // now" signals. Adding poll traffic on top of a load that is already crawling
        // makes both slower.
        guard !browser.busy, !browser.slowNetwork, !browser.networkStalled else { return }
        let key = ObjectIdentifier(browser)
        var s = state[key] ?? State()
        let path = browser.currentURL.path
        // Navigated to a different folder: adopt the new folder without treating the
        // change of signature as "the folder changed", which would fire a pointless
        // reload of a listing that was just loaded.
        if s.path != path { s = State(path: path); state[key] = s }
        if s.statInFlight { return }                                  // previous stat still outstanding
        if let q = s.quietUntil, q > Date() { return }                // backing off

        s.statInFlight = true
        state[key] = s
        let dir = browser.currentURL
        let t0 = Date()
        DispatchQueue.global(qos: .utility).async { [weak self, weak browser] in
            // POSIX stat, NOT URL.resourceValues: a URL CACHES its resource values, and
            // every copy of `currentURL` shares that cache — so the second poll onwards
            // kept handing back the mtime from the first one and the folder never
            // appeared to change. (Measured: files added on an SMB share, the shell saw
            // the new mtime immediately, the poll saw the original value forever.)
            var st = stat()
            let mtime: Date? = stat(dir.path, &st) == 0
                ? Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
                : nil
            let elapsed = Date().timeIntervalSince(t0)
            DispatchQueue.main.async {
                guard let self, let browser else { return }
                var s = self.state[key] ?? State(path: dir.path)
                s.statInFlight = false
                // The folder moved out from under us while the stat was in flight —
                // whatever came back describes a folder nobody is looking at.
                guard s.path == dir.path, browser.currentURL.path == dir.path else {
                    self.state[key] = s; return
                }
                if mtime == nil || elapsed > self.slowStatBudget {
                    s.strikes += 1
                    // 15s, 30s, 45s, 60s… capped. An unreachable mount gets a stat a
                    // minute instead of one every four seconds.
                    s.quietUntil = Date().addingTimeInterval(min(60, 15 * Double(s.strikes)))
                    self.state[key] = s
                    return
                }
                s.strikes = 0; s.quietUntil = nil
                let previous = s.signature
                s.signature = mtime
                self.state[key] = s
                // First successful stat only establishes the baseline — there is
                // nothing to compare against yet, and reloading here would mean every
                // arrival at a network folder immediately re-enumerated it.
                guard let previous, previous != mtime else { return }
                browser.silentRefresh()
            }
        }
    }
}

// The undo/redo stack itself lives in NavigatorCore.swift — it is pure ordering
// logic (what invalidates a redo, what a failed half does to the entry) and that is
// exactly the part worth pinning down with tests.

// Keeps pinned network drives mounted, so a share that dropped (sleep, VPN
// reconnect, reboot) is simply there when you go to use it — no Finder trip, no
// "Reconnect" click.
//
// Deliberately cheap and quiet for people who have NO network drives: if no
// sidebar favorite carries a mount URL, start() returns immediately and nothing is
// scheduled or observed at all. It also only mounts shares that are genuinely
// ABSENT from the mount table — a mounted-but-wedged share is left alone, because
// fixing that needs a force-unmount, which can destroy unsaved work in other apps.
// That case gets the explicit Reconnect button instead.
final class NetworkReconnector {
    static let shared = NetworkReconnector()
    private var lastTry: [String: Date] = [:]     // per share, for backoff
    private var sweeping = false
    private let retryInterval: TimeInterval = 90  // don't hammer an unreachable server
    private var timer: Timer?

    // Shares the user disconnected deliberately. Without this, Disconnect is a button
    // that does nothing: the next sweep sees a missing share, can't tell "the VPN
    // dropped it" from "the user just let it go", and mounts it straight back —
    // measured at under 10 seconds. Deliberately NOT persisted: reconnecting
    // everything at launch is the promised behaviour, so a restart is a clean slate.
    private var manual = Set<String>()

    private func shareKey(_ u: URL) -> String { (u.host ?? "") + u.path }

    /// Keys of the pinned shares currently mounted at `volume`. Call BEFORE
    /// unmounting — afterwards there's nothing left to match on.
    func shareKeys(mountedAt volume: String) -> [String] {
        pinnedShares.filter { Browser.mountedPath(forShare: $0) == volume }.map(shareKey)
    }
    /// Stop auto-mounting these until the user asks for them again.
    func suppress(_ keys: [String]) { manual.formUnion(keys) }
    /// The user asked for this location again (clicked the drive, or reconnected a
    /// stalled one), so resume looking after it.
    func allowReconnect(mountURL: String?) {
        guard let m = mountURL, let u = URL(string: m) else { return }
        manual.remove(shareKey(u))
    }

    private var pinnedShares: [URL] {
        // Unique share URLs from favorites that were saved as network drives.
        var seen = Set<String>(); var out: [URL] = []
        for f in FavoritesStore.shared.items {
            guard let m = f.mountURL, let u = URL(string: m), u.host != nil else { continue }
            let key = (u.host ?? "") + u.path
            if seen.insert(key).inserted { out.append(u) }
        }
        return out
    }

    func start() {
        guard !pinnedShares.isEmpty else { return }   // no network drives → do nothing, ever
        // Waking from sleep and coming back on VPN are the two moments shares drop.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.sweep(reason: "wake")
        }
        // A light periodic check covers VPN reconnects, which post no notification
        // we can rely on. 60s is far cheaper than one directory listing.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.sweep(reason: "timer")
        }
        sweep(reason: "launch")
    }

    func sweep(reason: String) {
        let shares = pinnedShares
        // Snapshot on the caller's thread (sweep is always called from main) so the
        // background pass never reads `manual` while the UI is mutating it.
        let skip = manual
        guard !shares.isEmpty, !sweeping else { return }
        sweeping = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { self?.sweeping = false }
            guard let self else { return }
            for share in shares {
                // Already mounted (even if unhappy)? Leave it completely alone.
                if Browser.mountedPath(forShare: share) != nil { continue }
                let key = (share.host ?? "") + share.path
                if skip.contains(key) { continue }   // user disconnected this on purpose
                if let last = self.lastTry[key], Date().timeIntervalSince(last) < self.retryInterval { continue }
                self.lastTry[key] = Date()
                if let mp = Browser.mountShareSilently(share) {
                    navLog("auto-reconnect (\(reason)): mounted \(share.absoluteString) at \(mp)")
                }
            }
            // Always finish by pointing favorites at where their shares really are —
            // a share can be perfectly mounted yet under a different name ("Games-1"),
            // which makes the sidebar entry look dead. Runs even when nothing needed
            // mounting, so a stale path is corrected on the very next sweep.
            DispatchQueue.main.async {
                let moved = FavoritesStore.shared.reanchorNetworkPaths()
                if moved || reason == "launch" {
                    NotificationCenter.default.post(name: .navigatorShareReconnected, object: nil)
                }
            }
        }
    }
}
extension Notification.Name {
    static let navigatorShareReconnected = Notification.Name("navigatorShareReconnected")
    /// Undo/redo of the image viewer's own Delete telling that viewer to take the picture
    /// back into (or out of) its list. See ImageViewerView.deleteCurrent for why this is
    /// a notification and not a direct write.
    static let navigatorImageViewerUndo = Notification.Name("navigatorImageViewerUndo")
}

// MARK: - Bonjour network discovery (nearby SMB file servers)

final class NetworkBrowser: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = NetworkBrowser()
    @Published var servers: [SidebarLocation] = []
    private let browser = NetServiceBrowser()
    private var resolving: Set<NetService> = []
    private var found: [String: URL] = [:]
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        browser.delegate = self
        browser.searchForServices(ofType: "_smb._tcp.", inDomain: "local.")
    }

    func netServiceBrowser(_ b: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.insert(service)
        service.resolve(withTimeout: 5)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        let host = sender.hostName ?? "\(sender.name).local."
        let clean = host.hasSuffix(".") ? String(host.dropLast()) : host
        if let url = URL(string: "smb://\(clean)") {
            found[sender.name] = url
            rebuild()
        }
        resolving.remove(sender)
    }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) { resolving.remove(sender) }
    func netServiceBrowser(_ b: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        found[service.name] = nil; rebuild()
    }
    private func rebuild() {
        servers = found.map { SidebarLocation(name: $0.key, url: $0.value, symbol: "network") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// Async thumbnail cache backed by QuickLook. Unlike loading the full NSImage,
/// True for a file whose bytes are NOT on disk — an online-only item from a File
/// Provider (Google Drive, iCloud). APFS marks these with SF_DATALESS; reading one
/// forces the provider to download it. Checked before any local-decode fallback so a
/// thumbnail pass over a big cloud folder never turns into a mass download.
func isDatalessFile(_ url: URL) -> Bool {
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return false }
    return (st.st_flags & 0x4000_0000) != 0   // SF_DATALESS (sys/stat.h)
}

// QLThumbnailGenerator produces a right-sized preview cheaply and supports many
// formats beyond plain images — PSD, PDF, AI, RAW — via the system's thumbnail
// generators (and its own on-disk cache). Non-thumbnailable files return nil so
// callers fall back to the file-type icon. Cache is keyed by path+size so the
// small list-view thumbnail and the large preview don't clobber each other.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    // Generation runs on a bounded queue. Measured: for ordinary PNG/JPG the bound
    // makes no difference (40 cold Drive images filled in ~1.2s either way), so this
    // is a safety valve, not a speed-up — it stops a 300-image folder from queueing
    // 300 concurrent generations. The real wins here are the failure cache and the
    // timeout below: a big cloud-hosted PSD can take many seconds (one test never
    // returned inside two minutes), and without a failure cache an unthumbnailable
    // file was re-requested on every single scroll.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 6
        q.qualityOfService = .userInitiated
        return q
    }()
    private let lock = NSLock()
    private var ops: [String: Operation] = [:]
    // Failures are throttled, NOT permanent. The old Set<String> version cached a
    // failure for the whole session, which turned any transient miss into a file that
    // never shows a thumbnail again: a freshly-generated file still syncing to Drive, a
    // slow-VPN day tripping the 15s timeout once — from then on, generic icon forever,
    // even after the file was fully materialised. The TTL keeps the original win (no
    // re-request on every scroll tick) while letting transients heal on the next pass.
    private var failed: [String: Date] = [:]
    private let failureRetryAfter: TimeInterval = 20
    func thumbnail(for url: URL, size: CGFloat = 256, completion: @escaping (NSImage?) -> Void) {
        let key = "\(url.path)@\(Int(size))" as NSString
        if let c = cache.object(forKey: key) { completion(c); return }
        // Settings → Thumbnails: off = type icons only (fastest on slow shares);
        // images = skip the pricey PSD/PDF/RAW/video generators. The image viewer
        // loads full images directly, so it's unaffected either way.
        switch Prefs.thumbnailMode {
        case "off": completion(nil); return
        case "images" where !isImageFile(url): completion(nil); return
        default: break
        }
        guard isThumbnailable(url) else { completion(nil); return }
        // NOTE: do NOT skip online-only cloud files here. Measured on Google Drive:
        // QuickLook returns a thumbnail for a dataless file WITHOUT materialising it
        // (the File Provider supplies it), so skipping would lose thumbnails for no
        // bandwidth saving.
        lock.lock()
        if let failedAt = failed[key as String] {
            if Date().timeIntervalSince(failedAt) < failureRetryAfter {
                lock.unlock(); completion(nil); return
            }
            failed[key as String] = nil   // TTL elapsed — try again
        }
        if ops[key as String] != nil { lock.unlock(); return }   // already being generated
        lock.unlock()

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            guard let self, op?.isCancelled != true else { return }
            // lowQualityThumbnail INCLUDED, not just .thumbnail: for online-only cloud
            // files the File Provider supplies a ready-made low-quality thumb, and
            // requesting only the full-quality kind rejected it — those files showed
            // generic icons while Finder, asking for any representation, showed art.
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: scale,
                                                   representationTypes: [.lowQualityThumbnail, .thumbnail])
            var img: NSImage?
            let sem = DispatchSemaphore(value: 0)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                img = rep?.nsImage; sem.signal()
            }
            // Give up on a pathological file rather than holding a slot forever —
            // some large cloud-hosted PSDs never come back in reasonable time.
            if sem.wait(timeout: .now() + 15) == .timedOut { QLThumbnailGenerator.shared.cancel(req) }
            // QuickLook failed on a plain image that is actually present on disk —
            // decode it ourselves. This covers a file QL is being weird about (fresh
            // sync, odd encoder) with zero QuickLook dependence. Never for dataless
            // (online-only) files: reading one forces the provider to download it,
            // and a folder of 300 would become 300 downloads.
            if img == nil, op?.isCancelled != true, isImageFile(url), !isDatalessFile(url) {
                img = ThumbnailCache.decodeDownscaled(url, maxPixel: size * scale)
            }
            self.lock.lock()
            self.ops[key as String] = nil
            if let img { self.cache.setObject(img, forKey: key) }
            else { self.failed[key as String] = Date() }   // throttled, retried after TTL
            self.lock.unlock()
            if op?.isCancelled == true { return }
            DispatchQueue.main.async { completion(img) }
        }
        lock.lock(); ops[key as String] = op; lock.unlock()
        queue.addOperation(op)
    }

    /// Straight CGImageSource downscale — the no-QuickLook fallback for plain images.
    static func decodeDownscaled(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Everything queued as failed is forgotten — wired to ⌘R, because "refresh" is
    /// exactly the gesture someone makes at a folder whose thumbnails look wrong.
    func forgetFailures() {
        lock.lock(); failed.removeAll(); lock.unlock()
    }

    // Row scrolled out of view — drop its pending request so the queue stays
    // focused on what's actually on screen.
    func cancel(for url: URL, size: CGFloat = 256) {
        let key = "\(url.path)@\(Int(size))"
        lock.lock(); let op = ops.removeValue(forKey: key); lock.unlock()
        op?.cancel()
    }
}

// Quick Look preview panel controller.
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var urls: [URL] = []
    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { NSSound.beep(); return }
        self.urls = urls
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}

// MARK: - Model

struct FileItem: Identifiable, Hashable, Codable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    let created: Date
    let accessed: Date
    let dateAdded: Date
    let kind: String
    let tags: [String]

    var ext: String { isDirectory ? "" : url.pathExtension.lowercased() }
    var baseName: String { (name as NSString).deletingPathExtension }

    /// POSIX owner name, for the Owner column. See FileOwner for why it isn't fetched
    /// with the rest of the listing's metadata.
    var owner: String { FileOwner.name(for: url) }

    /// Sort keys for the two columns whose values arrive from Spotlight. Read from
    /// MetadataCache WITHOUT triggering a lookup — a comparator runs O(n log n) times per
    /// sort and must not start n² pieces of background work. Browser.sortOrder's setter
    /// fills the cache first (MetadataCache.prefetch) and re-sorts once it's full, which
    /// is what makes an unloaded value a transient 0 rather than a permanently wrong one.
    var durationSortKey: MediaSortKey {
        MediaSortKey.duration(isDirectory ? nil : MetadataCache.shared.cached(for: url)?.duration, name: name)
    }
    var dimensionsSortKey: MediaSortKey {
        let m = isDirectory ? nil : MetadataCache.shared.cached(for: url)
        return MediaSortKey.pixelArea(width: m?.width, height: m?.height, name: name)
    }

    static func == (l: FileItem, r: FileItem) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// Persists network directory listings across launches so the FIRST open of a
// network folder in a new session paints instantly (then refreshes in the
// background). Local folders enumerate fast enough to skip. Capped, evicts
// oldest. Main-thread access only; disk writes are async-snapshotted.
enum DiskCache {
    // dirModified = the folder's own mtime when we cached it. On revisit we stat
    // just the folder (one round-trip) and compare: if it matches, no files were
    // added or removed, so the cached listing is still valid and we skip the full
    // re-enumeration. (Optional so old cache files decode as nil.)
    private struct Entry: Codable { let items: [FileItem]; let savedAt: Date; let dirModified: Date? }
    private static let maxFolders = 60
    private static let maxItemsPerFolder = 5000
    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Navigator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dircache.json")
    }()
    private static var store: [String: Entry] = {
        guard let d = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode([String: Entry].self, from: d) else { return [:] }
        return s
    }()
    static func get(_ key: String) -> [FileItem]? { store[key]?.items }
    static func age(_ key: String) -> TimeInterval? { store[key].map { Date().timeIntervalSince($0.savedAt) } }
    static func dirModified(_ key: String) -> Date? { store[key]?.dirModified }
    static func put(_ key: String, _ items: [FileItem], dirModified: Date? = nil) {
        guard items.count <= maxItemsPerFolder else { return }
        store[key] = Entry(items: items, savedAt: Date(), dirModified: dirModified)
        if store.count > maxFolders {
            for v in store.sorted(by: { $0.value.savedAt < $1.value.savedAt }).prefix(store.count - maxFolders) {
                store[v.key] = nil
            }
        }
        persist()
    }
    static func remove(_ key: String) { if store.removeValue(forKey: key) != nil { persist() } }
    private static func persist() {
        let snap = store
        DispatchQueue.global(qos: .utility).async {
            if let d = try? JSONEncoder().encode(snap) { try? d.write(to: fileURL) }
        }
    }
}

struct SidebarLocation: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
    let symbol: String
    var ejectable: Bool = false
    var isNetwork: Bool = false   // "Disconnect" rather than "Eject", and picks the error wording
}

// The one alert for "macOS said no", with the fix one click away. Must be called on
// the main thread.
//
// Everything that can fail on a permission routes here rather than each growing its
// own wording, so the user always gets the same sentence and the same button no matter
// which feature they were using when they hit it.
func reportPermissionDenied(_ summary: String, _ detail: String) {
    let a = NSAlert(); a.alertStyle = .warning
    a.messageText = summary
    a.informativeText = detail
    a.addButton(withTitle: "Open Setup Assistant…")
    a.addButton(withTitle: "OK")
    if a.runModal() == .alertFirstButtonReturn { SetupAssistantController.shared.show() }
}

// Surfaces a file-operation failure instead of failing silently. Must be called
// on the main thread.
// `permissionHint` appends the Full Disk Access note. Pass false when the failure
// clearly isn't about permissions (e.g. "a folder can't be copied into itself") —
// tacking an unrelated FDA paragraph onto a logic error just confuses people.
// `at` is the destination the operation was aiming at, when there is one: it lets a
// denial name the folder ("your Desktop") instead of talking about permissions in the
// abstract. Optional so the forty existing call sites need no change.
func reportFileError(_ summary: String, _ detail: String = "", permissionHint: Bool = true, at destination: URL? = nil) {
    // A failure macOS caused is a different problem with a different fix, so it gets
    // its own alert rather than the generic one with a paragraph bolted on. This is
    // where Send To ▸ Desktop used to die quietly on an install whose Desktop
    // permission had been dismissed: "couldn't be copied" plus an FDA note that
    // wasn't the actual missing switch.
    if permissionHint, PermissionDiagnosis.looksLikeDenial(detail) {
        let folder = destination.flatMap { PermissionDiagnosis.protectedFolder(for: $0.path, home: NSHomeDirectory()) }
        reportPermissionDenied(summary, folder.map {
            "macOS is blocking Navigator from your \($0) folder — the files themselves are fine.\n\nThe Setup Assistant shows which permissions are missing and takes you straight to the switch."
        } ?? "macOS blocked this: \(detail)\n\nThe Setup Assistant shows which of Navigator's permissions are missing and takes you straight to the switch.")
        return
    }
    let a = NSAlert(); a.alertStyle = .warning
    a.messageText = summary
    var msg = detail
    // Cap the detail so a long message can't make the alert taller than the
    // screen — that pushes the OK button off-screen and it can't be dismissed.
    if msg.count > 1200 { msg = String(msg.prefix(1200)) + "\n… (truncated)" }
    if permissionHint {
        if !msg.isEmpty { msg += "\n\n" }
        msg += "Items in protected folders (Desktop, Documents, Pictures, Downloads) or on read-only volumes can need Navigator to have Full Disk Access — see Help → “Setup Assistant…”."
    }
    a.informativeText = msg
    a.addButton(withTitle: "OK"); a.runModal()
}

// The "an item with that name already exists" prompt, shared by copy/move/paste and by
// rename so both speak the same language. Must be called on the main thread; returns
// nil when the user cancels.
//
// `options` is the button set, in order, with Cancel always appended. It varies because
// not every choice makes sense everywhere: a single-item rename has nothing to Skip
// past, so it offers Keep Both and Replace only. Rename used to have no prompt at all —
// it let moveItem fail and reported the raw Cocoa error plus an unrelated Full Disk
// Access paragraph, which is actively misleading for a plain name clash.
func askConflictPolicy(_ message: String, informative: String,
                       options: [ConflictPolicy]) -> ConflictPolicy? {
    let a = NSAlert()
    a.messageText = message
    a.informativeText = informative
    for o in options {
        switch o {
        case .keepBoth: a.addButton(withTitle: "Keep Both")
        case .replace:  a.addButton(withTitle: "Replace")
        case .skip:     a.addButton(withTitle: "Skip")
        }
    }
    a.addButton(withTitle: "Cancel")
    let i = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    return options.indices.contains(i) ? options[i] : nil
}

// Shared dialogs / actions usable from menus and context menus.
// Inline rename (Explorer/Finder-style), not a modal dialog: select the row,
// scroll it into view, and let the Table/Icon/Gallery cell itself swap in
// RenameField in response to `renamingID`.
func promptRename(_ browser: Browser, _ id: String) {
    guard browser.items.contains(where: { $0.id == id }) else { return }
    browser.selection = [id]
    browser.keyboardScrollID = id
    browser.renamingID = id
}
func promptComment(_ browser: Browser, _ id: String) {
    guard let item = browser.items.first(where: { $0.id == id }) else { return }
    var existing = ""
    if let md = MDItemCreate(nil, item.url.path as CFString),
       let c = MDItemCopyAttribute(md, kMDItemFinderComment) as? String { existing = c }
    let a = NSAlert(); a.messageText = "Comment"; a.informativeText = "Finder comment for “\(item.name)”:"
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); f.stringValue = existing
    a.accessoryView = f; a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
    if a.runModal() == .alertFirstButtonReturn { browser.setComment(id: id, f.stringValue) }
}
func showInfo(_ browser: Browser, _ ids: Set<String>) {
    // A multi-selection gets the SAME window, in summary mode (combined size, file and
    // folder counts) — it used to get a three-line NSAlert with no permissions, no
    // tags and no way to act on anything.
    let sel = browser.items.filter { ids.contains($0.id) }
    guard !sel.isEmpty else { return }
    GetInfoController.shared.show(browser, sel)
}
// Google Drive for desktop stamps every synced item with its Drive item ID in
// this extended attribute. That ID maps to a universal drive.google.com link
// that resolves for anyone with access — regardless of OS, username, or mount
// path — which is the correct way to share a Drive location across users.
func googleDriveItemID(_ url: URL) -> String? {
    let name = "com.google.drivefs.item-id#S"
    let n = getxattr(url.path, name, nil, 0, 0, 0)
    guard n > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: n)
    guard getxattr(url.path, name, &buf, n, 0, 0) == n else { return nil }
    return String(decoding: buf, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
func googleDriveURL(for url: URL, isDirectory: Bool) -> URL? {
    guard let id = googleDriveItemID(url), !id.isEmpty else { return nil }
    return URL(string: isDirectory
        ? "https://drive.google.com/drive/folders/\(id)"
        : "https://drive.google.com/file/d/\(id)/view")
}
// A portable, username-free path for a Drive item, matching the breadcrumb:
// /Users/x/Library/CloudStorage/GoogleDrive-x@…/Shared drives/A/B
//   → "Google Drive/Shared drives/A/B"
func googleDrivePortablePath(_ url: URL) -> String? {
    let p = url.path
    guard let r = p.range(of: "/CloudStorage/GoogleDrive-") else { return nil }
    let after = p[r.upperBound...]
    guard let slash = after.firstIndex(of: "/") else { return nil }
    let rel = after[after.index(after: slash)...]
    return rel.isEmpty ? "Google Drive" : "Google Drive/\(rel)"
}
// Where Drive for desktop mounts THIS Mac's account. The one thing about a Drive
// path that no pure rule can work out, and the anchor every resolved form lands on.
func googleDriveAccountRoot() -> String? {
    let cs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
    guard let accounts = try? FileManager.default.contentsOfDirectory(atPath: cs.path),
          let local = accounts.first(where: { $0.hasPrefix("GoogleDrive-") }) else { return nil }
    return cs.appendingPathComponent(local).path
}

/// The reverse of `googleDriveURL`: a drive.google.com link → where that item actually
/// lives on this Mac, so a link someone pasted into Slack can be handed to an Open/Save
/// dialog, which understands POSIX paths and nothing else.
///
/// Reads Drive for desktop's own metadata index. The obvious alternative — walk the
/// mount reading the item-id xattr off every file — is one stat per file across a
/// network-backed filesystem holding hundreds of thousands of them, which is not
/// something a keystroke is allowed to do; this is a single indexed lookup plus a
/// parent walk, measured at 15 ms against the 1 GB index on this machine. Opened
/// read-only with `immutable=1` because Drive keeps the database open: that skips
/// locking and the write-ahead log, so the worst case is a slightly stale row — and a
/// stale row names a path that either still exists or fails the existence check below.
///
/// ponytail: the schema is Google's, private and undocumented. Every failure path
/// returns nil, and the one caller falls back to Navigator's own folder — so a schema
/// change quietly retires the feature instead of misaiming someone's dialog. If that
/// day comes there is nothing to maintain but this one query.
func googleDriveLocalPath(webURL: String) -> String? {
    guard let id = PathRules.googleDriveItemID(webURL: webURL) else { return nil }
    let fs = NSHomeDirectory() + "/Library/Application Support/Google/DriveFS"
    // The account folder is Drive's numeric obfuscated account id; with one signed-in
    // account there is exactly one, and with several we have no way to tell which owns
    // the link, so trying each in turn and letting the existence check decide is both
    // the simplest and the only correct thing available.
    let accounts = (try? FileManager.default.contentsOfDirectory(atPath: fs))?
        .filter { $0.allSatisfy(\.isNumber) } ?? []
    for account in accounts {
        if let p = driveIndexLookup(id: id, db: "\(fs)/\(account)/metadata_sqlite_db") { return p }
    }
    return nil
}

private func driveIndexLookup(id: String, db path: String) -> String? {
    guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
    var db: OpaquePointer?
    guard sqlite3_open_v2("file:" + encoded + "?immutable=1", &db,
                          SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
        sqlite3_close(db); return nil
    }
    defer { sqlite3_close(db) }
    // Walk from the item to its root collecting titles. The depth cap is a cycle guard:
    // this is somebody else's database and a parent loop in it would hang the walk, not
    // just return a wrong answer. `stable_parents` is many-to-many for items that were
    // in two folders at once (Drive stopped allowing that in 2020) — such a walk fans
    // out and we take whichever branch the rows arrive in, backstopped by the existence
    // check in the caller.
    let sql = """
        WITH RECURSIVE up(sid, depth) AS (
          SELECT stable_id, 0 FROM items WHERE id = ?1 AND trashed = 0 AND is_tombstone = 0
          UNION ALL
          SELECT p.parent_stable_id, up.depth + 1 FROM stable_parents p, up
           WHERE p.item_stable_id = up.sid AND up.depth < 32)
        SELECT i.local_title, i.stable_id = i.team_drive_stable_id
          FROM up JOIN items i ON i.stable_id = up.sid ORDER BY up.depth LIMIT 64
        """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    // SQLITE_TRANSIENT: `id` is a Swift String whose C buffer dies with this call, so
    // SQLite has to take its own copy.
    sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    var titles: [String] = []
    var isSharedDrive = false
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let t = sqlite3_column_text(stmt, 0) else { return nil }
        titles.append(String(cString: t))
        // The last row is the root; a shared drive's root is the drive itself, which
        // Drive marks by pointing team_drive_stable_id at its own row.
        isSharedDrive = sqlite3_column_int(stmt, 1) != 0
    }
    guard let rel = PathRules.driveRelativePath(leafFirst: titles, isSharedDrive: isSharedDrive),
          let local = Browser.resolveGoogleDrivePath(rel),
          FileManager.default.fileExists(atPath: local) else { return nil }
    return local
}

// The installed Google Drive app's own icon, for the Drive context-menu items
// (mirrors how Finder badges its Quick Actions). Loaded once.
/// An app icon shrunk to menu-row height.
///
/// NSWorkspace hands back a 32pt-plus icon, and a context menu lays icons out at
/// the NSImage's OWN size — SwiftUI's `.frame()` is ignored once a Label is
/// rendered into an NSMenu, so the full-size icon stretched every row it appeared
/// on and left the menu unevenly spaced. Setting the size on a copy is what
/// actually constrains it (the same thing FinderExt does for its menu items);
/// copying keeps us from resizing an image other call sites share.
func menuIcon(_ img: NSImage, _ pt: CGFloat = 14) -> NSImage {
    guard let c = img.copy() as? NSImage else { return img }
    c.size = NSSize(width: pt, height: pt)
    return c
}

enum GoogleDriveIcon {
    static let image: NSImage = menuIcon(NSWorkspace.shared.icon(forFile: "/Applications/Google Drive.app"))
}
// A context-menu label badged with the Google Drive app icon.
@ViewBuilder func gdLabel(_ title: String) -> some View {
    Label {
        Text(title)
    } icon: {
        Image(nsImage: GoogleDriveIcon.image)
    }.labelStyle(.titleAndIcon)
}

// Photoshop's own icon + location, for the Remove-BG menu items. Resolved once;
// `image` is nil (and the menu items are hidden) when Photoshop isn't installed.
enum PhotoshopIcon {
    static let url: URL? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.adobe.Photoshop")
    static let image: NSImage? = url.map { menuIcon(NSWorkspace.shared.icon(forFile: $0.path)) }
}
@ViewBuilder func psLabel(_ title: String) -> some View {
    Label {
        Text(title)
    } icon: {
        if let img = PhotoshopIcon.image { Image(nsImage: img) }
    }.labelStyle(.titleAndIcon)
}

// After Effects' own icon + location, for the Chroma Key menu items. Resolved
// once; menu items are hidden when After Effects isn't installed.
enum AfterEffectsIcon {
    static let url: URL? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.adobe.AfterEffects")
    static let image: NSImage? = url.map { menuIcon(NSWorkspace.shared.icon(forFile: $0.path)) }
}
@ViewBuilder func aeLabel(_ title: String) -> some View {
    Label {
        Text(title)
    } icon: {
        if let img = AfterEffectsIcon.image { Image(nsImage: img) }
    }.labelStyle(.titleAndIcon)
}

// "Prep for AI" → pick an aspect ratio (Auto = nearest, the default; or a
// specific NB2 ratio with a shape icon), then a fill color. `action` receives
// the color and the chosen ratio (nil = Auto). Selecting a ratio just opens its
// color submenu — the menu stays open until you pick a color.
@ViewBuilder func prepForAIMenu(_ action: @escaping (AIPrepColor, Double?) -> Void) -> some View {
    Menu {
        Menu {
            fillColorButtons(ratio: nil, action)
        } label: { Label("Auto (nearest ratio)", systemImage: "wand.and.stars") }
        Divider()
        ForEach(nb2Ratios, id: \.name) { r in
            Menu {
                fillColorButtons(ratio: r.ratio, action)
            } label: { Label { Text(r.name) } icon: { Image(nsImage: aspectSwatch(r.ratio)) } }
        }
    } label: {
        Label("Prep for AI", systemImage: "wand.and.stars")
    }
}
/// Icons for the AI services behind menu items. Photoshop and After Effects lend
/// their own icons because they're installed apps; Vertex and fal are web services
/// with nothing to borrow from, so their marks ship in Assets/ and are loaded here.
/// A missing file falls back to an SF Symbol rather than leaving a blank.
enum ServiceIcon {
    static let vertex: NSImage? = load("vertex", fallback: "sparkles")
    static let fal: NSImage? = load("fal", fallback: "bolt.fill")

    private static func load(_ name: String, fallback symbol: String) -> NSImage? {
        let img = Bundle.main.url(forResource: name, withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        img?.size = NSSize(width: 14, height: 14)   // menus size icons from the image
        return img
    }
}
@ViewBuilder func serviceLabel(_ title: String, _ icon: NSImage?) -> some View {
    Label {
        Text(title)
    } icon: {
        if let icon { Image(nsImage: icon) }
    }.labelStyle(.titleAndIcon)
}

// "Upscale (AI)" submenu — the low-quality fal preset plus Vertex/Imagen 4 ×2/×4.
@ViewBuilder func upscaleMenu(label: String = "Upscale (AI)",
                              fal: @escaping (UpscaleOption) -> Void,
                              imagen: @escaping (Int) -> Void) -> some View {
    Menu {
        ForEach(upscaleOptions) { o in
            Button { fal(o) } label: { serviceLabel(o.label, ServiceIcon.fal) }
        }
        Divider()
        Button { imagen(2) } label: { serviceLabel("Upscale (Imagen 4) ×2", ServiceIcon.vertex) }
        Button { imagen(4) } label: { serviceLabel("Upscale (Imagen 4) ×4", ServiceIcon.vertex) }
    } label: { Label(label, systemImage: "arrow.up.backward.and.arrow.down.forward") }
}
/// "Restyle (AI)…" — one image or a whole selection.
///
/// A multi-selection opens the same window with the images queued: one shared style
/// reference, but each image keeps its own auto-detected identity, since a batch is
/// usually different subjects heading for one look. Lives here beside upscaleMenu
/// because all three context menus (list, icons, viewer) need it and none of them
/// should own a second copy. Skips this feature's own outputs so re-running a
/// folder doesn't restyle the restyles.
@ViewBuilder func restyleMenuItem(_ urls: [URL], onDone: @escaping (URL) -> Void) -> some View {
    let imgs = urls.filter { isImageFile($0) && !PathRules.isOwnOutput($0, suffix: "_restyled") }
    if !imgs.isEmpty {
        Button { RestyleController.show(sources: imgs, onFinished: onDone) } label: {
            serviceLabel(imgs.count == 1 ? "Restyle (AI)…" : "Restyle (AI)… (\(imgs.count) images)",
                         ServiceIcon.vertex)
        }
    }
}

@ViewBuilder func fillColorButtons(ratio: Double?, _ action: @escaping (AIPrepColor, Double?) -> Void) -> some View {
    ForEach(aiPrepColors) { c in
        Button { action(c, ratio) } label: {
            Label { Text(c.name) } icon: { Image(nsImage: circleSwatch(c.color)) }
        }
    }
}

// "foo.png" → "foo_rmbg.png" in the same folder (background removal needs PNG).
func rmbgOutputURL(_ src: URL) -> URL {
    let base = src.deletingPathExtension().lastPathComponent
    return src.deletingLastPathComponent().appendingPathComponent("\(base)_rmbg.png")
}

// ===== Prep for AI: background fill =====

// The background-fill colors offered in the "Prep for AI" menu. The screen
// colors match the chroma keyer's expected values for later Chroma Key use.
// `suffix` becomes the filename tag: "<base>_BG<suffix>.png" (e.g. _BGgreen).
struct AIPrepColor: Identifiable { let name: String; let suffix: String; let color: NSColor; var id: String { name } }
let aiPrepColors: [AIPrepColor] = [
    .init(name: "White",         suffix: "white",   color: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
    .init(name: "Black",         suffix: "black",   color: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)),
    .init(name: "Greenscreen",   suffix: "green",   color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
    .init(name: "MagentaScreen", suffix: "magenta", color: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)),
    .init(name: "Bluescreen",    suffix: "blue",    color: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
    .init(name: "Yellow",        suffix: "yellow",  color: NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)),
    .init(name: "Orange",        suffix: "orange",  color: NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)),
]

// A small filled-circle swatch for the menu (kept in color — not a template
// image — with a hairline border so white/black read against the menu).
func circleSwatch(_ color: NSColor, size: CGFloat = 12) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let path = NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: size - 1, height: size - 1))
    color.setFill(); path.fill()
    NSColor.separatorColor.setStroke(); path.lineWidth = 0.5; path.stroke()
    img.unlockFocus()
    img.isTemplate = false
    return img
}

// NB2's supported aspect ratios (width/height).
let nb2Ratios: [(name: String, ratio: Double)] = [
    ("16:9", 16.0/9), ("9:16", 9.0/16), ("4:3", 4.0/3), ("3:4", 3.0/4), ("1:1", 1),
    ("3:2", 3.0/2), ("2:3", 2.0/3), ("21:9", 21.0/9), ("9:21", 9.0/21), ("5:4", 5.0/4), ("4:5", 4.0/5),
]
// Nearest supported ratio by log-distance (symmetric for ratios).
func nearestNB2Ratio(w: Double, h: Double) -> Double {
    let r = w / max(h, 1)
    return nb2Ratios.min { abs(log($0.ratio) - log(r)) < abs(log($1.ratio) - log(r)) }!.ratio
}

// A small proportional-rectangle icon showing an aspect ratio's shape (wide /
// tall / square) for the menu.
func aspectSwatch(_ ratio: Double, box: CGFloat = 15) -> NSImage {
    let img = NSImage(size: NSSize(width: box, height: box))
    img.lockFocus()
    let avail = box - 3
    var w = avail, h = avail
    if ratio >= 1 { h = avail / CGFloat(ratio) } else { w = avail * CGFloat(ratio) }
    let r = NSRect(x: (box - w) / 2, y: (box - h) / 2, width: w, height: h)
    let path = NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5)
    NSColor.secondaryLabelColor.withAlphaComponent(0.25).setFill(); path.fill()
    NSColor.secondaryLabelColor.setStroke(); path.lineWidth = 1; path.stroke()
    img.unlockFocus(); img.isTemplate = false
    return img
}

func bgfillOutputURL(_ src: URL, suffix: String) -> URL {
    let base = src.deletingPathExtension().lastPathComponent
    return src.deletingLastPathComponent().appendingPathComponent("\(base)_BG\(suffix).png")
}

// Fit the image into an NB2 aspect ratio (a specific one, or nearest when
// `ratio` is nil), pad by 20% (space on all sides), fill the background with
// `color`, and write "<base>_BG<suffix>.png". The image is centered at its
// native size — never scaled or cropped, never overwrites the original.
func fillBackgroundForImage(_ src: URL, color: NSColor, suffix: String, ratio: Double?,
                            dest explicitDest: URL? = nil) -> URL? {
    guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let w = CGFloat(cg.width), h = CGFloat(cg.height)
    guard w > 0, h > 0 else { return nil }
    let rt = CGFloat(ratio ?? nearestNB2Ratio(w: Double(w), h: Double(h)))
    // Smallest target-ratio box that contains the image, then +20% padding.
    var tightW = w, tightH = h
    if w / h > rt { tightW = w; tightH = w / rt } else { tightH = h; tightW = h * rt }
    let canvasW = Int((tightW * 1.2).rounded())
    let canvasH = Int((tightH * 1.2).rounded())
    guard canvasW > 0, canvasH > 0,
          let ctx = CGContext(data: nil, width: canvasW, height: canvasH, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor((color.usingColorSpace(.deviceRGB) ?? color).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
    let x = (CGFloat(canvasW) - w) / 2, y = (CGFloat(canvasH) - h) / 2
    ctx.draw(cg, in: CGRect(x: x, y: y, width: w, height: h))   // native size, centered
    guard let outImg = ctx.makeImage() else { return nil }
    let dst = explicitDest ?? bgfillOutputURL(src, suffix: suffix)
    guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, outImg, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return dst
}

// Fill backgrounds for one or many images (native — no Adobe app). Shows the
// non-blocking progress bar + end-of-run summary for multi-image runs.
func fillBackgroundForImages(_ srcs: [URL], color: NSColor, suffix: String, ratio: Double?, onDone: (([URL]) -> Void)? = nil) {
    let imgs = srcs.filter { isImageFile($0) }
    guard !imgs.isEmpty else { NSSound.beep(); return }
    let showProgress = imgs.count > 1
    if showProgress { DispatchQueue.main.async { BGJobProgress.shared.start("Filling backgrounds", total: imgs.count) } }
    DispatchQueue.global(qos: .userInitiated).async {
        var outs: [URL] = []; var errors: [String] = []
        for src in imgs {
            if let out = fillBackgroundForImage(src, color: color, suffix: suffix, ratio: ratio) { outs.append(out) }
            else { errors.append("\(src.lastPathComponent): couldn’t create fill") }
            if showProgress { DispatchQueue.main.async { BGJobProgress.shared.advance() } }
        }
        DispatchQueue.main.async {
            if showProgress { BGJobProgress.shared.finish("Filled \(outs.count) of \(imgs.count) background\(imgs.count == 1 ? "" : "s")") }
            if !errors.isEmpty { showBGSummary(app: "Prep for AI", done: outs.count, total: imgs.count, errors: errors) }
            if !outs.isEmpty { onDone?(outs) }
        }
    }
}

// ===== AI Upscale (fal.ai / Topaz Gigapixel) =====

struct UpscaleOption: Identifiable { let label: String; let model: String; let factor: Int; var id: String { label } }
// Only the low-quality fal/Topaz preset remains — the Art/Photoreal presets were
// replaced by Imagen 4 (better results). Imagen options live in upscaleMenu.
let upscaleOptions: [UpscaleOption] = [
    .init(label: "Upscale Low Quality ×4", model: "Wonder 3", factor: 4),
]

func upscaleOutputURL(_ src: URL) -> URL {
    let base = src.deletingPathExtension().lastPathComponent
    return src.deletingLastPathComponent().appendingPathComponent("\(base)_upscaled.png")
}

private func loadCGImage(_ url: URL) -> CGImage? {
    guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(s, 0, nil)
}
// Pixel dimensions from the header — no full decode.
func imagePixelSize(_ url: URL) -> (w: Int, h: Int)? {
    guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
          let w = p[kCGImagePropertyPixelWidth] as? Int,
          let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}
private func loadCGImage(data: Data) -> CGImage? {
    guard let s = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(s, 0, nil)
}
private func encodePNG(_ cg: CGImage) -> Data? {
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

// True if the image has an alpha channel AND any actually-transparent pixel
// (downsampled scan so it's cheap).
func imageHasTransparency(_ url: URL) -> Bool {
    guard let cg = loadCGImage(url) else { return false }
    switch cg.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: return false
    default: break
    }
    let w = min(cg.width, 128), h = min(cg.height, 128)
    guard w > 0, h > 0, let ptr = calloc(w * h * 4, 1) else { return false }
    defer { free(ptr) }
    guard let ctx = CGContext(data: ptr, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    let px = ptr.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var i = 3
    while i < w * h * 4 { if px[i] < 250 { return true }; i += 4 }
    return false
}

// Composite the image over an opaque solid color (a full backing layer) at
// native size — gives the upscaler clean context and gradual edges.
private func compositeOnColor(_ cg: CGImage, _ color: CGColor) -> CGImage? {
    let w = cg.width, h = cg.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}
private func compositeOnGreen(_ cg: CGImage) -> CGImage? { compositeOnColor(cg, CGColor(red: 0, green: 1, blue: 0, alpha: 1)) }

// After upscaling a green-backed image, key the green (#00FF00) back to
// transparent. ponytail: threshold chroma key, no edge despill — fine for clean
// flat art; a fal matting model would give crisper edges if needed.
private func stripGreen(_ data: Data) -> Data? {
    guard let cg = loadCGImage(data: data) else { return nil }
    let w = cg.width, h = cg.height
    guard w > 0, h > 0, let ptr = calloc(w * h * 4, 1) else { return nil }
    defer { free(ptr) }
    guard let ctx = CGContext(data: ptr, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    let px = ptr.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var i = 0
    while i < w * h * 4 {
        if px[i + 1] > 150, px[i] < 120, px[i + 2] < 120 { px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0 }
        i += 4
    }
    guard let outCG = ctx.makeImage() else { return nil }
    return encodePNG(outCG)
}

// Imagen flattens alpha (returns opaque RGB), so for a transparent source we
// upscale it on a green backing, then rebuild transparency from the ORIGINAL
// matte — the alpha the background-removal already computed — instead of
// chroma-keying green back out (which leaves a fringe on soft edges). The
// original alpha is bilinearly upscaled to the output size for smooth edges;
// green spill is despilled ONLY on partial-alpha edge pixels so subject colors
// are untouched. Returns a transparent PNG, or nil to fall back to stripGreen.
private func recombineUpscaledAlpha(source: URL, upscaledOpaque: Data) -> Data? {
    guard let srcCG = loadCGImage(source), let upCG = loadCGImage(data: upscaledOpaque) else { return nil }
    let W = upCG.width, H = upCG.height
    guard W > 0, H > 0 else { return nil }
    let cs = CGColorSpaceCreateDeviceRGB()
    let bmp = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let aPtr = calloc(W * H * 4, 1), let uPtr = calloc(W * H * 4, 1) else { return nil }
    defer { free(aPtr); free(uPtr) }
    guard let aCtx = CGContext(data: aPtr, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs, bitmapInfo: bmp),
          let uCtx = CGContext(data: uPtr, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs, bitmapInfo: bmp) else { return nil }
    aCtx.interpolationQuality = .high
    aCtx.draw(srcCG, in: CGRect(x: 0, y: 0, width: W, height: H))   // upscaled source → its alpha is our matte
    uCtx.draw(upCG, in: CGRect(x: 0, y: 0, width: W, height: H))    // Imagen's opaque RGB (alpha 255)
    let a = aPtr.bindMemory(to: UInt8.self, capacity: W * H * 4)
    let u = uPtr.bindMemory(to: UInt8.self, capacity: W * H * 4)
    var i = 0
    while i < W * H * 4 {
        let alpha = a[i + 3]
        if alpha == 0 {
            u[i] = 0; u[i + 1] = 0; u[i + 2] = 0; u[i + 3] = 0
        } else {
            let r = u[i], b = u[i + 2]
            // Standard green-screen despill: clamp green to the larger of the other
            // two channels. Only removes green that EXCEEDS both (i.e. spill); a
            // balanced subject color (gold/teal/skin) is left essentially untouched.
            let g = min(u[i + 1], max(r, b))
            let af = Double(alpha) / 255.0         // straight → premultiplied for this context
            u[i] = UInt8(Double(r) * af); u[i + 1] = UInt8(Double(g) * af); u[i + 2] = UInt8(Double(b) * af); u[i + 3] = alpha
        }
        i += 4
    }
    guard let outCG = uCtx.makeImage() else { return nil }
    return encodePNG(outCG)
}

// One synchronous fal Topaz upscale call → (result PNG bytes, error message).
private func falUpscale(pngData input: Data, model: String, factor: Int, key: String) -> (data: Data?, error: String?) {
    let dataURI = "data:image/png;base64," + input.base64EncodedString()
    guard let url = URL(string: "https://fal.run/fal-ai/topaz/upscale/image") else { return (nil, "bad URL") }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 600
    req.httpBody = try? JSONSerialization.data(withJSONObject: ["image_url": dataURI, "model": model, "upscale_factor": factor, "output_format": "png"])
    var out: (Data?, String?) = (nil, "no response")
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, err in
        defer { sem.signal() }
        if let err { out = (nil, err.localizedDescription); return }
        guard let data, let http = resp as? HTTPURLResponse else { out = (nil, "no data"); return }
        guard http.statusCode == 200 else {
            out = (nil, "fal HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")"); return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let img = json["image"] as? [String: Any], let outStr = img["url"] as? String,
              let outURL = URL(string: outStr) else { out = (nil, "unexpected fal response"); return }
        if let outData = try? Data(contentsOf: outURL) { out = (outData, nil) }
        else { out = (nil, "couldn’t download the upscaled result") }
    }.resume()
    sem.wait()
    return out
}

func promptAddFalKey() {
    let a = NSAlert(); a.alertStyle = .warning
    a.messageText = "Add your fal.ai API key first"
    a.informativeText = "AI upscaling runs through fal.ai. Add your key from the menu bar: AI → API Keys…"
    a.addButton(withTitle: "OK"); a.runModal()
}

// Upscale one or many images via fal. Transparent images get a green backing,
// are upscaled, then keyed back to transparent. Non-blocking progress + summary.
func upscaleImagesViaFal(_ srcs: [URL], option: UpscaleOption, onDone: (([URL]) -> Void)? = nil) {
    let imgs = srcs.filter { isImageFile($0) }
    guard !imgs.isEmpty else { NSSound.beep(); return }
    guard let key = APIKeys.fal else { DispatchQueue.main.async { promptAddFalKey() }; return }
    guard confirmUpscale(count: imgs.count, label: option.label, perImage: nil) else { return }
    // total:0 → an animated INDETERMINATE bar (an upscale is one long opaque
    // network call with no sub-progress, so a static "0 of 1" looked frozen).
    // The label names the current file/model; the whole thing is off the main
    // thread so Navigator stays fully usable.
    DispatchQueue.main.async { BGJobProgress.shared.start("Upscaling", total: 0) }
    DispatchQueue.global(qos: .userInitiated).async {
        var outs: [URL] = []; var errors: [String] = []
        for (idx, src) in imgs.enumerated() {
            DispatchQueue.main.async {
                BGJobProgress.shared.label = imgs.count == 1
                    ? "Upscaling \(src.lastPathComponent) — \(option.model)"
                    : "Upscaling \(idx + 1) of \(imgs.count) — \(option.model)"
            }
            guard let cg = loadCGImage(src) else { errors.append("\(src.lastPathComponent): can’t read"); continue }
            let transparent = imageHasTransparency(src)
            let inputCG = transparent ? (compositeOnGreen(cg) ?? cg) : cg
            guard let inputPNG = encodePNG(inputCG) else { errors.append("\(src.lastPathComponent): encode failed"); continue }
            let (outData, err) = falUpscale(pngData: inputPNG, model: option.model, factor: option.factor, key: key)
            if let outData {
                let finalData = transparent ? (stripGreen(outData) ?? outData) : outData
                let dst = upscaleOutputURL(src)
                do { try finalData.write(to: dst); outs.append(dst) }
                catch { errors.append("\(src.lastPathComponent): save failed — \(error.localizedDescription)") }
            } else {
                errors.append("\(src.lastPathComponent): \(err ?? "upscale failed")")
            }
        }
        DispatchQueue.main.async {
            BGJobProgress.shared.finish("Upscaled \(outs.count) of \(imgs.count)")
            if !errors.isEmpty { showBGSummary(app: "Upscale", done: outs.count, total: imgs.count, errors: errors, verb: "upscaled") }
            if !outs.isEmpty { onDone?(outs) }
        }
    }
}

// ===== AI Upscale (Vertex / Imagen 4) via the H5G ai-connect client =====
// We don't re-implement Vertex OAuth in Swift — we drive the existing,
// cost-tracked `client.mjs` (browser Google sign-in, company-metered). Navigator
// just locates node + the client, then shells `imagen-upscale`.

struct H5GResult { let out: String; let err: String; let code: Int32 }

/// True when the window's first responder is editing text, so app-wide shortcuts must
/// keep their hands off.
///
/// `NSTextInputClient` is the load-bearing part. The old check was
/// `r is NSText || r is NSTextView`, which is what an AppKit NSTextField's field editor
/// looks like — but SwiftUI's TextField does NOT reliably make an NSText/NSTextView the
/// first responder, so that check reported "not editing" while someone was typing in
/// the address bar. Two things went wrong as a result: every printable keystroke was
/// swallowed by type-to-select (so the address bar simply would not accept typing), and
/// ⌘V reached AppDelegate's file-paste fallback, pasting FILES into the current folder
/// instead of text into the field. Every text-input responder conforms to
/// NSTextInputClient, SwiftUI's included, so this catches all of them.
func isEditingText(in win: NSWindow?) -> Bool {
    guard let r = win?.firstResponder else { return false }
    return r is NSTextInputClient || r is NSText || r is NSTextView || r is NSTextField
}

/// Runs a standard editing action against the focused text responder. Returns true when
/// the event belongs to text editing and must NOT fall through to a file operation.
///
/// Implemented with tryToPerform — dispatch the STANDARD selector up the responder
/// chain from the focused view — rather than by manipulating NSTextInputClient by hand.
/// The field's own copy:/cut:/paste:/selectAll: implementations then run, with their
/// undo support and selection behaviour intact. An earlier hand-rolled version got
/// Select All wrong in the worst way: it recognised "text is focused", couldn't find a
/// portable way to select all, and swallowed the event having done NOTHING — ⌘A in the
/// address bar was a no-op by construction.
///
/// Still returns true even if nothing responded to the selector: when text is focused,
/// falling through to the FILE operation (paste files into the folder because the
/// caret was in a text field) is strictly worse than doing nothing.
@discardableResult
func performTextEditingAction(_ kind: TextEditAction) -> Bool {
    guard let win = NSApp.keyWindow, isEditingText(in: win) else { return false }
    let sel: Selector
    switch kind {
    case .copy:      sel = #selector(NSText.copy(_:))
    case .cut:       sel = #selector(NSText.cut(_:))
    case .paste:     sel = #selector(NSText.paste(_:))
    case .selectAll: sel = #selector(NSText.selectAll(_:))
    }
    _ = win.firstResponder?.tryToPerform(sel, with: nil)
    return true
}

enum TextEditAction { case copy, cut, paste, selectAll }

// Append-only dev log at ~/Library/Logs/Navigator.log — while we bring the
// Vertex/Imagen path up, so failures are diagnosable instead of guesswork.
let navLogURL = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Navigator.log"))
/// Roll over at 4 MB, keeping one previous file, so the pair is bounded at 8 MB. Big
/// enough that the whole of a long Imagen batch or a day of drags is still in the live
/// file when someone comes to read it, which is the only reason this log exists.
private let navLogMaxBytes: UInt64 = 4 << 20
func navLog(_ msg: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    guard let data = "[\(stamp)] \(msg)\n".data(using: .utf8) else { return }
    guard let fh = try? FileHandle(forWritingTo: navLogURL) else {
        try? FileManager.default.createDirectory(at: navLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: navLogURL)
        return
    }
    // seekToEnd already hands back the size, so rotation costs no stat at all — which
    // matters because this runs on drag and spring-load paths, per event.
    let size = ((try? fh.seekToEnd()) ?? 0) + UInt64(data.count)
    try? fh.write(contentsOf: data)
    try? fh.close()
    guard size > navLogMaxBytes else { return }
    // Rotate AFTER the write and with the handle closed: the line that tripped the
    // threshold belongs in the file it was written to, not in a gap between the two.
    let fm = FileManager.default
    let previous = navLogURL.appendingPathExtension("1")
    try? fm.removeItem(at: previous)
    try? fm.moveItem(at: navLogURL, to: previous)
}

// GUI apps launched from Finder/Dock have a minimal PATH (no nvm/homebrew), so
// resolve node by absolute path: nvm versions, then homebrew, then system.
func resolveNode() -> String? {
    let fm = FileManager.default
    var candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
    let nvm = (NSHomeDirectory() as NSString).appendingPathComponent(".nvm/versions/node")
    if let vers = try? fm.contentsOfDirectory(atPath: nvm).sorted(by: >) {
        candidates.insert(contentsOf: vers.map { "\(nvm)/\($0)/bin/node" }, at: 0)
    }
    return candidates.first { fm.isExecutableFile(atPath: $0) }
}

// The h5g-ai-connect client, wherever the plugin/skill is installed.
func resolveH5GClient() -> String? {
    let home = NSHomeDirectory()
    let fixed = [
        "\(home)/.claude/skills/h5g-ai-connect/client.mjs",
        "\(home)/Documents/h5g-ai-connect/skills/h5g-ai-connect/client.mjs",
        "\(home)/Downloads/claude-plugins-main/plugins/h5g-ai-connect/skills/h5g-ai-connect/client.mjs",
    ]
    if let f = fixed.first(where: { FileManager.default.fileExists(atPath: $0) }) { return f }
    let cache = "\(home)/.claude/plugins/cache"
    if let e = FileManager.default.enumerator(atPath: cache) {
        for case let p as String in e where p.hasSuffix("skills/h5g-ai-connect/client.mjs") { return "\(cache)/\(p)" }
    }
    return nil
}

func vertexSignedIn() -> Bool {
    FileManager.default.fileExists(atPath: (NSHomeDirectory() as NSString).appendingPathComponent(".h5g-ai-gen/token.json"))
}

// Synchronous run of `node client.mjs <args>`. Reads pipes fully before waiting
// (avoids a full-buffer deadlock). Node's own dir is put on PATH so the client's
// child `open`/etc. resolve.
func runH5GClient(_ args: [String]) -> H5GResult {
    guard let node = resolveNode() else { return H5GResult(out: "", err: "Node.js not found", code: 127) }
    guard let client = resolveH5GClient() else { return H5GResult(out: "", err: "h5g-ai-connect client not found", code: 127) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: node)
    p.arguments = [client] + args
    var env = ProcessInfo.processInfo.environment
    let nodeDir = (node as NSString).deletingLastPathComponent
    env["PATH"] = "\(nodeDir):/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
    p.environment = env
    let o = Pipe(); let e = Pipe()
    p.standardOutput = o; p.standardError = e
    navLog("run: node \(client) \(args.joined(separator: " "))")
    do { try p.run() } catch {
        navLog("run FAILED to launch: \(error.localizedDescription)")
        return H5GResult(out: "", err: error.localizedDescription, code: 127)
    }
    let od = o.fileHandleForReading.readDataToEndOfFile()
    let ed = e.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: od, encoding: .utf8) ?? "", err = String(data: ed, encoding: .utf8) ?? ""
    navLog("exit \(p.terminationStatus)\n  out: \(out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500))\n  err: \(err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500))")
    return H5GResult(out: out, err: err, code: p.terminationStatus)
}

// client.mjs prints "✅ Saved <path>" on success.
private func parseSavedPath(_ out: String) -> String? {
    for line in out.split(separator: "\n") {
        if let r = line.range(of: "Saved ") { return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
    }
    return nil
}
// Surface the whole "❌ …" block (the client prints the real reason there, often
// multi-line JSON), not just the last line — that was only the request_id.
private func cleanH5GError(_ r: H5GResult) -> String {
    let combined = (r.out + "\n" + r.err)
    let lines = combined.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    if let start = lines.firstIndex(where: { $0.contains("❌") }) {
        let block = lines[start...].joined(separator: " ")
            .replacingOccurrences(of: "❌", with: "").trimmingCharacters(in: .whitespaces)
        if !block.isEmpty { return String(block.prefix(300)) }
    }
    return lines.last { !$0.isEmpty } ?? "upscale failed"
}

func promptVertexSetup() {
    let a = NSAlert(); a.alertStyle = .warning
    a.messageText = "Vertex (Imagen) isn’t set up on this Mac"
    a.informativeText = "Imagen upscaling needs Node.js and the H5G ai-connect plugin installed. Ask Michael for the h5g-ai-connect setup, then try again."
    a.addButton(withTitle: "OK"); a.runModal()
}
func promptVertexSignin() {
    let a = NSAlert(); a.alertStyle = .warning
    a.messageText = "Sign in to Vertex first"
    a.informativeText = "Imagen upscaling runs through your High 5 Games Vertex account. Sign in from the menu bar: AI → Sign in to Vertex (Imagen)…"
    a.addButton(withTitle: "OK"); a.runModal()
}

// Upscale one or many images via Vertex/Imagen 4. Imagen flattens alpha, so a
// transparent cutout is composited onto a full solid backing layer first. With
// Photoshop present we back it on WHITE, upscale, then re-cut with Photoshop's
// Remove BG (best edges). Without Photoshop we back on GREEN and rebuild the
// cutout from the original matte. Non-blocking progress + summary.
func upscaleImagesViaImagen(_ srcs: [URL], factor: Int, onDone: (([URL]) -> Void)? = nil) {
    let imgs = srcs.filter { isImageFile($0) }
    guard !imgs.isEmpty else { NSSound.beep(); return }
    guard resolveNode() != nil, resolveH5GClient() != nil else { DispatchQueue.main.async { promptVertexSetup() }; return }
    guard vertexSignedIn() else { DispatchQueue.main.async { promptVertexSignin() }; return }
    guard confirmUpscale(count: imgs.count, label: "Imagen 4 ×\(factor)", perImage: 0.06) else { return }
    let psAvail = PhotoshopIcon.url != nil
    navLog("Imagen upscale ×\(factor): \(imgs.count) image(s)  photoshop=\(psAvail)  node=\(resolveNode() ?? "?")  client=\(resolveH5GClient() ?? "?")")
    DispatchQueue.main.async { BGJobProgress.shared.start("Upscaling", total: 0) }
    DispatchQueue.global(qos: .userInitiated).async {
        var outs: [URL] = []; var errors: [String] = []; var usedPS = false
        for (idx, src) in imgs.enumerated() {
            DispatchQueue.main.async {
                BGJobProgress.shared.label = imgs.count == 1
                    ? "Upscaling \(src.lastPathComponent) — Imagen ×\(factor)"
                    : "Upscaling \(idx + 1) of \(imgs.count) — Imagen ×\(factor)"
            }
            // Preflight against Imagen's documented limits (17 MP output, 10 MB
            // input) so we fail clearly and cancel instead of spending a call.
            guard let (w, h) = imagePixelSize(src) else {
                navLog("  SKIP: can’t read dimensions"); errors.append("\(src.lastPathComponent): can’t read the image"); continue
            }
            let outMP = Double(w * factor) * Double(h * factor) / 1_000_000
            if outMP > 17 {
                let x2fits = Double(w * 2) * Double(h * 2) / 1_000_000 <= 17
                let hint = (factor == 4 && x2fits) ? " ×2 (\(String(format: "%.1f", outMP / 4)) MP) would fit." : " Use a smaller source or a lower factor."
                let m = "can’t upscale \(w)×\(h) at ×\(factor) — that’s \(String(format: "%.1f", outMP)) MP, over Imagen’s 17 MP limit.\(hint)"
                navLog("  SKIP: \(m)"); errors.append("\(src.lastPathComponent): \(m)"); continue
            }
            let transparent = imageHasTransparency(src)
            navLog("[\(idx + 1)/\(imgs.count)] \(src.lastPathComponent) \(w)×\(h) transparent=\(transparent) → \(String(format: "%.1f", outMP)) MP")
            var inputPath = src.path
            var tmpInput: URL? = nil
            // Transparent → composite on a full solid backing (white if we'll re-cut
            // with Photoshop, green if we'll rebuild from the matte).
            if transparent, let cg = loadCGImage(src) {
                let backing: CGColor = psAvail ? CGColor(red: 1, green: 1, blue: 1, alpha: 1) : CGColor(red: 0, green: 1, blue: 0, alpha: 1)
                if let g = compositeOnColor(cg, backing), let png = encodePNG(g) {
                    let t = FileManager.default.temporaryDirectory.appendingPathComponent("nav_imagen_in_\(idx).png")
                    if (try? png.write(to: t)) != nil { inputPath = t.path; tmpInput = t }
                    else { navLog("  backing composite temp write FAILED — sending original transparent PNG") }
                }
            }
            let inBytes = ((try? FileManager.default.attributesOfItem(atPath: inputPath))?[.size] as? Int) ?? 0
            if inBytes > 10 * 1024 * 1024 {
                if let t = tmpInput { try? FileManager.default.removeItem(at: t) }
                let m = "can’t upscale — the input is \(String(format: "%.1f", Double(inBytes) / 1_048_576)) MB, over Imagen’s 10 MB limit. Flatten or downsize the source first."
                navLog("  SKIP: \(m)"); errors.append("\(src.lastPathComponent): \(m)"); continue
            }
            let args = ["imagen-upscale", inputPath, "--factor", "x\(factor)", "--out", FileManager.default.temporaryDirectory.path]
            var r = runH5GClient(args)
            // Imagen's diffusion upscaler blips transiently ("no image returned"),
            // which doesn't bill — one retry kills most spurious failures.
            if r.code != 0 || parseSavedPath(r.out) == nil { navLog("  attempt 1 failed — retrying once"); r = runH5GClient(args) }
            if let t = tmpInput { try? FileManager.default.removeItem(at: t) }
            guard r.code == 0, let saved = parseSavedPath(r.out) else {
                let msg = cleanH5GError(r)
                navLog("  RESULT: error — \(msg)")
                errors.append("\(src.lastPathComponent): \(msg)"); continue
            }
            let savedURL = URL(fileURLWithPath: saved)   // opaque upscaled result
            let dst = upscaleOutputURL(src)
            if transparent && psAvail {
                // Re-cut the white-backed upscale with Photoshop's Remove BG → clean
                // high-res transparent PNG (the tool that's best at it).
                usedPS = true
                let r2 = removeBackgroundOnce(src: savedURL, out: dst, reportFinalError: false)
                try? FileManager.default.removeItem(at: savedURL)
                if r2.ok {
                    outs.append(dst); navLog("  RESULT: ok (Photoshop re-cut) → \(dst.lastPathComponent)")
                } else {
                    navLog("  RESULT: Photoshop re-cut failed — \(r2.message)")
                    errors.append("\(src.lastPathComponent): upscaled, but Photoshop Remove BG failed — \(r2.message)")
                }
            } else {
                do {
                    let data = try Data(contentsOf: savedURL)
                    // No Photoshop: rebuild transparency from the original matte
                    // (green backing); direct copy for opaque sources.
                    let finalData = transparent ? (recombineUpscaledAlpha(source: src, upscaledOpaque: data) ?? stripGreen(data) ?? data) : data
                    try finalData.write(to: dst)
                    try? FileManager.default.removeItem(at: savedURL)
                    outs.append(dst)
                    navLog("  RESULT: ok\(transparent ? " (matte re-cut)" : "") → \(dst.lastPathComponent)")
                } catch {
                    navLog("  RESULT: save failed — \(error.localizedDescription)")
                    errors.append("\(src.lastPathComponent): save failed — \(error.localizedDescription)")
                }
            }
        }
        navLog("Imagen upscale done: \(outs.count) ok, \(errors.count) error(s)")
        DispatchQueue.main.async {
            if usedPS { hideApp(bundleID: "com.adobe.Photoshop") }
            BGJobProgress.shared.finish("Upscaled \(outs.count) of \(imgs.count)")
            if !errors.isEmpty { showBGSummary(app: "Upscale (Imagen 4)", done: outs.count, total: imgs.count, errors: errors, verb: "upscaled") }
            if !outs.isEmpty { onDone?(outs) }
        }
    }
}

// Batch Remove BG on a FOLDER (Photoshop) — shared by Navigator's menu and Finder.
// Images under a folder for a batch AI op: recurse, skip "EN"/"en" subfolders
// and our own outputs so re-runs are safe. `skipSuffix` is the output marker to
// exclude ("_rmbg" for background removal, "_upscaled" for upscaling). Sorted.
func batchImageURLs(in folder: URL, skipSuffix: String = "_rmbg") -> [URL] {
    let fm = FileManager.default
    guard let en = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
    var out: [URL] = []
    for case let url as URL in en {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if url.lastPathComponent.lowercased() == "en" { en.skipDescendants() }
            continue
        }
        guard isImageFile(url) else { continue }
        if url.deletingPathExtension().lastPathComponent.lowercased().hasSuffix(skipSuffix) { continue }
        out.append(url)
    }
    return out.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
}

// Batch Remove BG on a FOLDER (Photoshop). Routes through the proven per-file
// path (same one multi-select uses) — the old in-Photoshop batch loop failed
// with "command Get is not available" on every image. Non-blocking progress +
// a capped end-of-run summary.
func batchRemoveBackgroundFolder(_ folder: URL, onDone: (() -> Void)? = nil) {
    let imgs = batchImageURLs(in: folder)
    guard !imgs.isEmpty else {
        DispatchQueue.main.async { reportFileError("No images to process", "No images found in “\(folder.lastPathComponent)” (skipping “EN” folders and existing “_rmbg” files).") }
        onDone?(); return
    }
    removeBackgroundForImages(imgs) { _ in onDone?() }
}

// Batch Chroma Key on a FOLDER (After Effects) — same per-file routing.
func batchChromaKeyFolder(_ folder: URL, onDone: (() -> Void)? = nil) {
    let pngs = batchImageURLs(in: folder).filter { $0.pathExtension.lowercased() == "png" }
    guard !pngs.isEmpty else {
        DispatchQueue.main.async { reportFileError("No PNGs to process", "Chroma Key processes PNG images; none found in “\(folder.lastPathComponent)” (skipping “EN” folders and existing “_rmbg” files).") }
        onDone?(); return
    }
    chromaKeyForImages(pngs) { _ in onDone?() }
}

// Price warning shown before ANY upscale — it's one PAID AI call per image.
// Returns true to proceed. `perImage` is a known $/image (Imagen) or nil (fal —
// cost varies by image size). Runs modally; callers invoke on the main thread.
func confirmUpscale(count: Int, label: String, perImage: Double?) -> Bool {
    let a = NSAlert()
    a.messageText = "Upscale \(count) image\(count == 1 ? "" : "s") with \(label)?"
    var info = "Each image is one paid AI upscale."
    if let p = perImage {
        info += count == 1
            ? String(format: "\n\nEstimated cost: ~$%.2f.", p)
            : String(format: "\n\nEstimated cost: ~$%.2f (about $%.2f each).", Double(count) * p, p)
    } else {
        info += " Cost depends on image size."
    }
    a.informativeText = info
    a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
    return a.runModal() == .alertFirstButtonReturn
}

// Batch upscale a FOLDER — recurse (skip "EN" folders and existing "_upscaled"
// outputs) and route through the per-image upscalers (which show the price
// warning), same as multi-select.
func batchUpscaleFolderViaFal(_ folder: URL, option: UpscaleOption, onDone: (() -> Void)? = nil) {
    let imgs = batchImageURLs(in: folder, skipSuffix: "_upscaled")
    guard !imgs.isEmpty else {
        DispatchQueue.main.async { reportFileError("No images to upscale", "No images found in “\(folder.lastPathComponent)” (skipping “EN” folders and existing “_upscaled” files).") }
        onDone?(); return
    }
    upscaleImagesViaFal(imgs, option: option) { _ in onDone?() }
}
func batchUpscaleFolderViaImagen(_ folder: URL, factor: Int, onDone: (() -> Void)? = nil) {
    let imgs = batchImageURLs(in: folder, skipSuffix: "_upscaled")
    guard !imgs.isEmpty else {
        DispatchQueue.main.async { reportFileError("No images to upscale", "No images found in “\(folder.lastPathComponent)” (skipping “EN” folders and existing “_upscaled” files).") }
        onDone?(); return
    }
    upscaleImagesViaImagen(imgs, factor: factor) { _ in onDone?() }
}

// Remove BG for ONE file, retrying a failure before giving up.
//
// Photoshop intermittently refuses a single file in a long run with a transient
// scripting error — "General Photoshop error occurred… The command 'Get' is not
// currently available" — and then processes the very next file fine. It is a
// Photoshop state problem, not a file problem: in a real 39-image run the one file
// that failed (HP4_Frame.png) was IDENTICAL to the 38 that succeeded in every
// property that could matter — 3584x4800, 8-bit, RGB, no alpha, no colour profile,
// same PNG encoder, comparable byte size. Nothing about it was special.
//
// This same error is already recorded in this file's history: the ORIGINAL design ran
// the batch loop inside one Photoshop script and hit "command Get is not available"
// on EVERY image, which is why the code moved to one script per file. That change
// took it from always to rare — it didn't eliminate it. Since the input is provably
// fine, simply asking again is the correct remedy, and it's the same approach the
// Restyle path already uses for Vertex's transient 503s.
//
// Idempotent by construction: the script re-opens the source read-only and saveAs
// overwrites the output, so a retry can't corrupt or double-write anything.
//
// `reportFinalError` keeps the single-image path's dialog behaviour exactly as it was
// — only the LAST attempt is allowed to surface an error, so retries stay silent and a
// genuine failure still reports through the same routing (automation-permission vs
// script error) it always did.
func removeBackgroundOnce(src: URL, out: URL, attempts: Int = 3,
                          reportFinalError: Bool, recovery: AdobeRecovery? = nil) -> ScriptResult {
    let recovery = recovery ?? AdobeRecovery()
    var last = ScriptResult(ok: false, message: "not attempted")
    for i in 0..<attempts {
        let isLast = (i == attempts - 1)
        last = runPhotoshopScript(resource: "NavigatorRemoveBG", arguments: [src.path, out.path],
                                 reportError: reportFinalError && isLast)
        if last.ok {
            if i > 0 { navLog("remove bg: \(src.lastPathComponent) succeeded on attempt \(i + 1)") }
            return last
        }
        guard !isLast else { break }
        navLog("remove bg: \(src.lastPathComponent) attempt \(i + 1) failed — \(last.message); retrying")
        if i == attempts - 2, !recovery.used, let psURL = PhotoshopIcon.url {
            // Every plain retry failed too, so this is no longer "Photoshop was busy
            // for a moment" — a long-running hidden Photoshop can wedge into a state
            // where one call (app.open, live-confirmed) fails PERMANENTLY while the
            // rest of scripting still answers. Retrying into that process loses every
            // remaining file in the run; restarting the app is the only cure. Once per
            // run: if a fresh Photoshop still fails, the problem is the file, and the
            // remaining files shouldn't each pay the restart again.
            recovery.markUsed()
            restartAdobeApp(bundleID: "com.adobe.Photoshop", appURL: psURL)
        } else {
            // Let Photoshop settle. The failure is it being briefly unable to service
            // a scripting request, so a short pause is the whole point of the retry.
            Thread.sleep(forTimeInterval: 1.0 + Double(i))
        }
    }
    return last
}

// Single-image Remove BG usable from anywhere (browser or image viewer): Photoshop
// opens the ORIGINAL and saves the keyed result as "<name>_rmbg.png" — no redundant
// pre-copy (faster, especially on network/Drive), and the original is never
// written. `onProgress` (main thread) fires after Photoshop finishes so callers
// can refresh.
func removeBackgroundForImage(_ src: URL, onDone: ((URL) -> Void)? = nil) {
    guard isImageFile(src) else { NSSound.beep(); return }
    let out = rmbgOutputURL(src)
    DispatchQueue.global(qos: .userInitiated).async {
        let r = removeBackgroundOnce(src: src, out: out, reportFinalError: true)
        DispatchQueue.main.async {
            guard r.ok else { return }       // failure already surfaced; leave PS visible
            hideApp(bundleID: "com.adobe.Photoshop")
            onDone?(out)
        }
    }
}

// Remove BG for several images in one hidden Photoshop session (reuses the
// proven single script per file). Shows non-blocking "N of M" progress and an
// end-of-run summary (per-file errors collapsed into one dialog).
func removeBackgroundForImages(_ srcs: [URL], onDone: (([URL]) -> Void)? = nil) {
    let imgs = srcs.filter { isImageFile($0) }
    guard !imgs.isEmpty else { NSSound.beep(); return }
    DispatchQueue.main.async { BGJobProgress.shared.start("Removing backgrounds", total: imgs.count) }
    DispatchQueue.global(qos: .userInitiated).async {
        var outs: [URL] = []
        var errors: [String] = []
        let recovery = AdobeRecovery()   // at most one Photoshop restart for the whole batch
        for src in imgs {
            let out = rmbgOutputURL(src)
            let r = removeBackgroundOnce(src: src, out: out, reportFinalError: false, recovery: recovery)
            if r.ok { outs.append(out) } else { errors.append("\(src.lastPathComponent): \(r.message)") }
            DispatchQueue.main.async { BGJobProgress.shared.advance() }
        }
        DispatchQueue.main.async {
            hideApp(bundleID: "com.adobe.Photoshop")
            BGJobProgress.shared.finish("Removed \(outs.count) of \(imgs.count) background\(imgs.count == 1 ? "" : "s")")
            if !errors.isEmpty { showBGSummary(app: "Photoshop", done: outs.count, total: imgs.count, errors: errors) }
            if !outs.isEmpty { onDone?(outs) }
        }
    }
}

// One chroma-key script run with bounded retries — the After Effects twin of
// removeBackgroundOnce, for the same two failure modes: a transient refusal (plain
// retry fixes it) and a wedged host app (only a restart fixes it, once per run).
// The render overwrites its own output, so retrying is idempotent; the config file
// is reused across attempts and deleted by the caller after the last one.
func chromaKeyOnce(cfgPath: String, src: URL, attempts: Int = 3,
                   reportFinalError: Bool, recovery: AdobeRecovery? = nil) -> ScriptResult {
    let recovery = recovery ?? AdobeRecovery()
    var last = ScriptResult(ok: false, message: "not attempted")
    for i in 0..<attempts {
        let isLast = (i == attempts - 1)
        last = runAfterEffectsScript(resource: "NavigatorChromaKeyStill",
                                     globals: ["H5G_CHROMA_KEY_CONFIG": cfgPath],
                                     reportError: reportFinalError && isLast)
        if last.ok {
            if i > 0 { navLog("chroma key: \(src.lastPathComponent) succeeded on attempt \(i + 1)") }
            return last
        }
        guard !isLast else { break }
        navLog("chroma key: \(src.lastPathComponent) attempt \(i + 1) failed — \(last.message); retrying")
        if i == attempts - 2, !recovery.used, let aeURL = AfterEffectsIcon.url {
            // Same reasoning as removeBackgroundOnce: plain retries exhausted means the
            // host app itself is likely wedged, and restarting it once per run is the
            // only recovery that can save the remaining files.
            recovery.markUsed()
            restartAdobeApp(bundleID: "com.adobe.AfterEffects", appURL: aeURL)
        } else {
            Thread.sleep(forTimeInterval: 1.0 + Double(i))
        }
    }
    return last
}

// True when Photoshop's Quick Export as PNG applies to this file — the layered
// Photoshop formats. Plain images don't need Photoshop to become a PNG.
func isPhotoshopDocument(_ url: URL) -> Bool {
    ["psd", "psb"].contains(url.pathExtension.lowercased())
}

// Quick Export as PNG for one or more PSDs, in one hidden Photoshop session (one
// script run per file — the Remove BG model exactly: bounded retries per file, at
// most one wedged-app restart per run, progress + end-of-run summary, PSD opened
// read-only and never written). Output is "<name>.png" next to the PSD, uniqued so
// an existing "<name>.png" the user already has is never overwritten.
func exportPSDsToPNG(_ srcs: [URL], onDone: (([URL]) -> Void)? = nil) {
    let psds = srcs.filter { isPhotoshopDocument($0) }
    guard !psds.isEmpty else { NSSound.beep(); return }
    DispatchQueue.main.async { BGJobProgress.shared.start("Exporting PNGs", total: psds.count) }
    DispatchQueue.global(qos: .userInitiated).async {
        var outs: [URL] = []
        var errors: [String] = []
        let recovery = AdobeRecovery()   // at most one Photoshop restart for the whole run
        for src in psds {
            let dir = src.deletingLastPathComponent()
            let out = PathRules.uniqueDest(dir, src.deletingPathExtension().lastPathComponent + ".png") {
                FileManager.default.fileExists(atPath: $0)
            }
            var r = ScriptResult(ok: false, message: "not attempted")
            for i in 0..<3 {
                let isLast = (i == 2)
                r = runPhotoshopScript(resource: "NavigatorExportPNG", arguments: [src.path, out.path],
                                       reportError: false)
                if r.ok {
                    if i > 0 { navLog("export png: \(src.lastPathComponent) succeeded on attempt \(i + 1)") }
                    break
                }
                guard !isLast else { break }
                navLog("export png: \(src.lastPathComponent) attempt \(i + 1) failed — \(r.message); retrying")
                if i == 1, !recovery.used, let psURL = PhotoshopIcon.url {
                    // Same reasoning as removeBackgroundOnce: plain retries exhausted
                    // means Photoshop itself is likely wedged; restarting it once per
                    // run is the only recovery that can save the remaining files.
                    recovery.markUsed()
                    restartAdobeApp(bundleID: "com.adobe.Photoshop", appURL: psURL)
                } else {
                    Thread.sleep(forTimeInterval: 1.0 + Double(i))
                }
            }
            if r.ok { outs.append(out) } else { errors.append("\(src.lastPathComponent): \(r.message)") }
            DispatchQueue.main.async { BGJobProgress.shared.advance() }
        }
        DispatchQueue.main.async {
            hideApp(bundleID: "com.adobe.Photoshop")
            BGJobProgress.shared.finish("Exported \(outs.count) of \(psds.count) PNG\(psds.count == 1 ? "" : "s")")
            if !errors.isEmpty { showBGSummary(app: "Photoshop", done: outs.count, total: psds.count, errors: errors, verb: "exported") }
            if !outs.isEmpty { onDone?(outs) }
        }
    }
}

// Chroma Key for several PNGs in one hidden After Effects session (single still
// script per file). Non-blocking "N of M" progress + end-of-run summary.
func chromaKeyForImages(_ srcs: [URL], onDone: (([URL]) -> Void)? = nil) {
    let pngs = srcs.filter { $0.pathExtension.lowercased() == "png" }
    guard !pngs.isEmpty else { NSSound.beep(); return }
    DispatchQueue.main.async { BGJobProgress.shared.start("Chroma keying", total: pngs.count) }
    DispatchQueue.global(qos: .userInitiated).async {
        var outs: [URL] = []
        var errors: [String] = []
        let recovery = AdobeRecovery()   // at most one After Effects restart for the whole batch
        for src in pngs {
            let folder = src.deletingLastPathComponent()
            let base = src.deletingPathExtension().lastPathComponent
            let out = folder.appendingPathComponent("\(base)_rmbg.png")
            let cfg: [String: Any] = [
                "sourceFile": src.path, "outputFolder": folder.path, "outputName": "\(base)_rmbg",
                "automationMode": true, "showUi": false, "appendFrameToken": false,
                "renderImmediately": true, "finalOutputFormat": "png",
                "deleteIntermediateRender": true, "keyMode": "auto"
            ]
            guard let cfgPath = writeChromaConfig(cfg) else { errors.append("\(src.lastPathComponent): couldn’t write config"); continue }
            let r = chromaKeyOnce(cfgPath: cfgPath, src: src, reportFinalError: false, recovery: recovery)
            try? FileManager.default.removeItem(atPath: cfgPath)
            if r.ok { outs.append(out) } else { errors.append("\(src.lastPathComponent): \(r.message)") }
            DispatchQueue.main.async { BGJobProgress.shared.advance() }
        }
        DispatchQueue.main.async {
            hideApp(bundleID: "com.adobe.AfterEffects")
            BGJobProgress.shared.finish("Keyed \(outs.count) of \(pngs.count) image\(pngs.count == 1 ? "" : "s")")
            if !errors.isEmpty { showBGSummary(app: "After Effects", done: outs.count, total: pngs.count, errors: errors) }
            if !outs.isEmpty { onDone?(outs) }
        }
    }
}

// One end-of-run dialog for a multi-image job with failures (collapses the
// per-file errors). Success-only runs get no dialog — the progress bar's final
// line + the highlighted results are the confirmation.
func showBGSummary(app: String, done: Int, total: Int, errors: [String], verb: String = "removed") {
    let a = NSAlert()
    a.alertStyle = .warning
    a.messageText = "\(app): \(verb) \(done) of \(total)"
    var msg = "\(errors.count) image\(errors.count == 1 ? "" : "s") could not be processed:\n\n"
    msg += errors.prefix(15).joined(separator: "\n")
    if errors.count > 15 { msg += "\n… and \(errors.count - 15) more." }
    a.informativeText = msg
    a.addButton(withTitle: "OK")
    a.runModal()
}

// Short status-bar line from a folder-batch script's "OK: processed X of N" /
// "ERROR: …" status.
func batchSummaryLine(_ prefix: String, _ r: ScriptResult) -> String {
    guard r.ok else { return "\(prefix): failed" }
    let m = r.message.replacingOccurrences(of: "OK: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    return m.isEmpty ? "\(prefix): done" : "\(prefix): \(m)"
}

// Hide a finished helper app (Photoshop / After Effects) and bring Navigator
// back to the front, so it isn't left sitting in front of the user.
func hideApp(bundleID: String) {
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.hide() }
    NSApp.activate(ignoringOtherApps: true)
}

// Make sure `bundleID` is running and HIDDEN before we drive it — launching it
// hidden (never activated) if it isn't running — so the whole Remove BG /
// Chroma Key run happens in the background without stealing focus. Blocks
// briefly; call off the main thread.
func launchHidden(bundleID: String, appURL: URL) {
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
        if !app.isHidden { app.hide() }
        return
    }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = false
    cfg.hides = true
    cfg.addsToRecentItems = false
    let sem = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { _, _ in sem.signal() }
    _ = sem.wait(timeout: .now() + 90)
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) where !app.isHidden { app.hide() }
}

// One "quit and relaunch the wedged host app" allowed per user-visible operation
// (a batch shares one; a single-file job gets its own). Restarting is the ONLY cure
// for the failure this exists for, but it's heavy (~20-60s), so it must never loop.
final class AdobeRecovery {
    private(set) var used = false
    func markUsed() { used = true }
}

// Quit and relaunch an Adobe host app hidden, because its scripting has wedged.
//
// Seen live (Jul 2026): a Photoshop that had been running hidden for ~4.5 hours
// permanently refused every `app.open` with 'The command "Get" is not currently
// available' while the rest of scripting still answered fine. No amount of retrying
// into that process can ever succeed — reproduced with a bare one-line script outside
// Navigator entirely, and only an app restart cleared it. Blocks; call off main.
//
// Quit is polite first (regular Apple-event quit); force-terminate is the logged
// last resort, for when a hidden "save changes?" prompt (usually from documents our
// own failed scripts leaked open) blocks the polite quit. In this workflow the host
// app is a hidden automation appliance Navigator itself launched, so losing user work
// to the force-kill requires the user to have been editing in an app Navigator keeps
// hidden — accepted trade against a tool that otherwise stays broken until they
// notice and restart Photoshop by hand.
func restartAdobeApp(bundleID: String, appURL: URL) {
    navLog("\(bundleID): scripting wedged — restarting the app")
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.terminate() }
    var deadline = Date().addingTimeInterval(20)
    while Date() < deadline, !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
        Thread.sleep(forTimeInterval: 0.5)
    }
    let leftovers = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    if !leftovers.isEmpty {
        navLog("\(bundleID): didn't quit politely (likely a hidden modal) — force-terminating")
        for app in leftovers { app.forceTerminate() }
        deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
    launchHidden(bundleID: bundleID, appURL: appURL)
    // The next `do javascript` blocks until the app can service it, so no readiness
    // poll is needed — this pause just spares the relaunch the very first spike.
    Thread.sleep(forTimeInterval: 3.0)
    navLog("\(bundleID): restarted")
}

// While `p` is running, keep `bundleID` hidden — opening a document can un-hide
// an app, so we re-hide it (only if it actually became visible, so no flicker
// when it's already hidden). Runs on a background queue; returns immediately.
func keepHidden(while p: Process, bundleID: String) {
    DispatchQueue.global(qos: .utility).async {
        while p.isRunning {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) where !app.isHidden { app.hide() }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}

// Runs a bundled Photoshop .jsx (by resource name, no extension) against one
// path argument, launching Photoshop if needed. `do javascript` blocks until the
// script finishes, so callers run this off the main thread and refresh after.
// Never fails silently: a permission denial (Automation not allowed) or any
// other error is surfaced with a clear next step.
@discardableResult
func runPhotoshopScript(resource: String, arguments: [String], reportError: Bool = true) -> ScriptResult {
    guard PhotoshopIcon.url != nil else {
        if reportError { DispatchQueue.main.async { reportFileError("Photoshop isn’t installed", "Install Adobe Photoshop to use Remove BG.") } }
        return ScriptResult(ok: false, message: "Photoshop isn’t installed")
    }
    guard let scriptURL = Bundle.main.url(forResource: resource, withExtension: "jsx"),
          let fileSource = try? String(contentsOf: scriptURL, encoding: .utf8) else {
        if reportError { DispatchQueue.main.async { reportFileError("Photoshop script missing", "\(resource).jsx isn’t bundled in Navigator.app.") } }
        return ScriptResult(ok: false, message: "\(resource).jsx isn’t bundled")
    }
    // Pass the ExtendScript SOURCE and the args via osascript argv. This avoids
    // AppleScript file coercion (a `POSIX file … as alias` reference fails with
    // -1728 and the script never runs), and avoids escaping the multi-line source
    // into a string literal. `with timeout` lets long AI cutouts / big batches run
    // past osascript's default 2-minute AppleEvent limit (which shows as -1712).
    // Also prepend the args as $.global.NAV_ARG/NAV_ARG2 so the script gets them
    // even if `with arguments` doesn't populate arguments[] for a string source.
    func jsEsc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    var source = ""
    for (i, a) in arguments.enumerated() { source += "$.global.NAV_ARG\(i == 0 ? "" : String(i + 1)) = \"\(jsEsc(a))\";\n" }
    source += fileSource
    // Build the AppleScript `with arguments {…}` list from argv items 2…n.
    let argRefs = (0..<arguments.count).map { "item \($0 + 2) of argv" }.joined(separator: ", ")
    // No `activate` — we launch Photoshop hidden and keep it hidden, so the whole
    // run stays in the background (do javascript works whether or not it's front).
    if let psURL = PhotoshopIcon.url { launchHidden(bundleID: "com.adobe.Photoshop", appURL: psURL) }
    let appleScript = """
    on run argv
        set jsxSource to item 1 of argv
        with timeout of 3600 seconds
            tell application id "com.adobe.Photoshop"
                do javascript jsxSource with arguments {\(argRefs)}
            end tell
        end timeout
    end run
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", appleScript, source] + arguments
    let err = Pipe(); p.standardError = err
    let out = Pipe(); p.standardOutput = out
    do {
        try p.run()
        keepHidden(while: p, bundleID: "com.adobe.Photoshop")
        // Read pipes before waiting so a chatty script can't deadlock on a full pipe.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let stdout = (String(data: outData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            if reportError { DispatchQueue.main.async { reportAdobeAutomationFailure("Photoshop", stderr) } }
            return ScriptResult(ok: false, message: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if stdout.hasPrefix("ERROR") {
            // The script ran but reported a failure (e.g. save/removeBackground).
            if reportError { DispatchQueue.main.async { reportFileError("Photoshop couldn’t finish Remove BG", stdout) } }
            return ScriptResult(ok: false, message: stdout)
        }
        return ScriptResult(ok: true, message: stdout)
    } catch {
        if reportError { DispatchQueue.main.async { reportFileError("Couldn’t launch Photoshop", error.localizedDescription) } }
        return ScriptResult(ok: false, message: error.localizedDescription)
    }
}

// Turn osascript's raw error into a clear message. The one users hit is the
// Automation (Apple-events) permission being off — offer to open the right pane.
func reportAdobeAutomationFailure(_ appName: String, _ raw: String) {
    let lower = raw.lowercased()
    let isPermission = lower.contains("not authorized") || lower.contains("not allowed")
        || lower.contains("-1743") || lower.contains("1743")
    let a = NSAlert(); a.alertStyle = .warning
    if isPermission {
        a.messageText = "Navigator needs permission to control \(appName)"
        a.informativeText = "macOS blocks apps from automating other apps until you allow it. Open Privacy & Security → Automation, turn on Adobe \(appName) under Navigator, then try again."
        a.addButton(withTitle: "Open Automation Settings")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        }
    } else {
        a.messageText = "\(appName) couldn’t run the script"
        a.informativeText = raw.isEmpty ? "\(appName) reported an error." : raw
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

// Runs a bundled After Effects .jsx via AppleScript DoScript, after setting the
// given ExtendScript string globals (e.g. a config-file path the script reads).
// DoScript blocks until AE finishes (render included), so callers run this off
// the main thread. Never fails silently.
@discardableResult
func runAfterEffectsScript(resource: String, globals: [String: String], reportError: Bool = true) -> ScriptResult {
    guard AfterEffectsIcon.url != nil else {
        if reportError { DispatchQueue.main.async { reportFileError("After Effects isn’t installed", "Install Adobe After Effects to use Chroma Key BG.") } }
        return ScriptResult(ok: false, message: "After Effects isn’t installed")
    }
    guard let scriptURL = Bundle.main.url(forResource: resource, withExtension: "jsx"),
          let fileSource = try? String(contentsOf: scriptURL, encoding: .utf8) else {
        if reportError { DispatchQueue.main.async { reportFileError("After Effects script missing", "\(resource).jsx isn’t bundled in Navigator.app.") } }
        return ScriptResult(ok: false, message: "\(resource).jsx isn’t bundled")
    }
    func jsEsc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    // Prepend the string globals (e.g. the config-file path), then the script's
    // own source. The whole thing is passed to DoScript as an osascript argv item,
    // so there's no AppleScript file coercion (-1728) and no literal escaping.
    var source = ""
    for (k, v) in globals { source += "$.global.\(k) = \"\(jsEsc(v))\";\n" }
    source += fileSource
    // No `activate` — launch After Effects hidden and keep it hidden.
    if let aeURL = AfterEffectsIcon.url { launchHidden(bundleID: "com.adobe.AfterEffects", appURL: aeURL) }
    let appleScript = """
    on run argv
        set jsxSource to item 1 of argv
        with timeout of 3600 seconds
            tell application id "com.adobe.AfterEffects"
                DoScript jsxSource
            end tell
        end timeout
    end run
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", appleScript, source]
    let err = Pipe(); p.standardError = err
    let out = Pipe(); p.standardOutput = out
    do {
        try p.run()
        keepHidden(while: p, bundleID: "com.adobe.AfterEffects")
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let stdout = (String(data: outData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            if reportError { DispatchQueue.main.async { reportAdobeAutomationFailure("After Effects", stderr) } }
            return ScriptResult(ok: false, message: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if stdout.contains("ERROR") {
            if reportError { DispatchQueue.main.async { reportFileError("After Effects couldn’t finish Chroma Key", stdout) } }
            return ScriptResult(ok: false, message: stdout)
        }
        return ScriptResult(ok: true, message: stdout)
    } catch {
        if reportError { DispatchQueue.main.async { reportFileError("Couldn’t launch After Effects", error.localizedDescription) } }
        return ScriptResult(ok: false, message: error.localizedDescription)
    }
}

// Write a chroma-key config dict to a temp JSON file the AE scripts read. Path returned.
func writeChromaConfig(_ dict: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nav_chroma_\(UUID().uuidString).json")
    do { try data.write(to: url); return url.path } catch { return nil }
}

// Single-image chroma key (green/cyan/magenta screen → transparent PNG via AE
// Keylight). Writes "<base>_rmbg.png" next to the source. Original is untouched.
func chromaKeyForImage(_ src: URL, onDone: ((URL) -> Void)? = nil) {
    guard src.pathExtension.lowercased() == "png" else {
        DispatchQueue.main.async { reportFileError("Chroma Key needs a PNG", "The After Effects chroma-key workflow processes green/cyan/magenta-screen PNG images.") }
        return
    }
    let folder = src.deletingLastPathComponent()
    let base = src.deletingPathExtension().lastPathComponent
    let out = folder.appendingPathComponent("\(base)_rmbg.png")
    DispatchQueue.global(qos: .userInitiated).async {
        let cfg: [String: Any] = [
            "sourceFile": src.path, "outputFolder": folder.path, "outputName": "\(base)_rmbg",
            "automationMode": true, "showUi": false, "appendFrameToken": false,
            "renderImmediately": true, "finalOutputFormat": "png",
            "deleteIntermediateRender": true, "keyMode": "auto"
        ]
        guard let cfgPath = writeChromaConfig(cfg) else {
            DispatchQueue.main.async { reportFileError("Couldn’t start Chroma Key", "Failed to write the temporary config.") }; return
        }
        // Same bounded retry + wedged-app restart as the batch path — previously the
        // single-image path had no retry at all, so one transient AE refusal failed it.
        let r = chromaKeyOnce(cfgPath: cfgPath, src: src, reportFinalError: true)
        try? FileManager.default.removeItem(atPath: cfgPath)
        DispatchQueue.main.async {
            guard r.ok else { return }       // failure already surfaced; leave AE visible
            hideApp(bundleID: "com.adobe.AfterEffects")
            onDone?(out)
        }
    }
}

func confirmEmptyTrash(_ browser: Browser) {
    let a = NSAlert(); a.alertStyle = .warning
    a.messageText = "Empty the Trash?"
    a.informativeText = "Items in the Trash will be permanently deleted. This can't be undone."
    a.addButton(withTitle: "Empty Trash"); a.addButton(withTitle: "Cancel")
    if a.runModal() == .alertFirstButtonReturn { browser.emptyTrash() }
}
// All visible images in on-screen order + the index of `item` — so the viewer
// browses in the order the user sees. nil if the item isn't an image.
func imageContext(_ item: FileItem, _ browser: Browser) -> ([URL], Int)? {
    guard isImageFile(item.url) else { return nil }
    let imgs = browser.orderedVisibleItems().filter { !$0.isDirectory && isImageFile($0.url) }.map { $0.url }
    return (imgs, imgs.firstIndex(of: item.url) ?? 0)
}
func openItem(_ item: FileItem, _ browser: Browser) {
    if item.isDirectory { browser.navigate(to: item.url); return }
    if let (imgs, idx) = imageContext(item, browser) {
        ImageViewerController.shared.show(urls: imgs, index: idx); return
    }
    NSWorkspace.shared.open(item.url)
}
func shareItems(_ urls: [URL]) {
    guard !urls.isEmpty, let cv = NSApp.keyWindow?.contentView else { return }
    let picker = NSSharingServicePicker(items: urls)
    picker.show(relativeTo: .zero, of: cv, preferredEdge: .minY)
}

// Open With / default-app helpers.
func applicationsToOpen(_ url: URL) -> [URL] {
    NSWorkspace.shared.urlsForApplications(toOpen: url)
}
func openWith(_ urls: [URL], app: URL) {
    NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
}
// MARK: - Custom search range prompts

/// The two custom-range prompts live in an NSAlert accessory view rather than in the
/// filter Menu itself: a DatePicker (or a text field) inside a SwiftUI Menu on macOS
/// renders as a menu item you cannot actually type into or open a calendar from.
private final class RangeBox: ObservableObject {
    @Published var from: Date
    @Published var to: Date
    @Published var fromText: String
    @Published var toText: String
    init(from: Date, to: Date, fromText: String = "", toText: String = "") {
        self.from = from; self.to = to; self.fromText = fromText; self.toText = toText
    }
}

/// Whole-day range, inclusive of both ends (SearchDateFilter.custom does the
/// end-of-day arithmetic). Returns nil if cancelled.
func promptCustomDateRange(from: Date?, to: Date?) -> (from: Date, to: Date)? {
    let cal = Calendar.current
    let box = RangeBox(from: from ?? cal.date(byAdding: .day, value: -7, to: Date()) ?? Date(),
                       to: to ?? Date())
    let a = NSAlert()
    a.messageText = "Custom Date Range"
    a.informativeText = "Show items modified between these dates, including both days."
    let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 8) {
        DatePicker("From", selection: Binding(get: { box.from }, set: { box.from = $0 }), displayedComponents: .date)
        DatePicker("To", selection: Binding(get: { box.to }, set: { box.to = $0 }), displayedComponents: .date)
    }.frame(width: 260))
    host.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
    a.accessoryView = host
    a.addButton(withTitle: "Apply"); a.addButton(withTitle: "Cancel")
    guard a.runModal() == .alertFirstButtonReturn else { return nil }
    // Accept the two dates in either order rather than returning an empty range for
    // what is obviously "between these two days".
    return box.from <= box.to ? (box.from, box.to) : (box.to, box.from)
}

/// Custom size bounds in MB, either side may be left blank for "no limit".
/// Returns nil if cancelled; a bound of nil means unbounded on that side.
func promptCustomSizeRange(from: Int64?, to: Int64?) -> (from: Int64?, to: Int64?)? {
    func mbText(_ v: Int64?) -> String {
        guard let v else { return "" }
        let mb = Double(v) / Double(SearchSizeFilter.mb)
        return mb == mb.rounded() ? String(Int(mb)) : String(format: "%.3f", mb)
    }
    let box = RangeBox(from: Date(), to: Date(), fromText: mbText(from), toText: mbText(to))
    let a = NSAlert()
    a.messageText = "Custom Size Range"
    a.informativeText = "In megabytes. Leave either box empty for no limit."
    let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 8) {
        HStack {
            Text("At least").frame(width: 60, alignment: .trailing)
            TextField("any", text: Binding(get: { box.fromText }, set: { box.fromText = $0 })).frame(width: 90)
            Text("MB")
        }
        HStack {
            Text("Less than").frame(width: 60, alignment: .trailing)
            TextField("any", text: Binding(get: { box.toText }, set: { box.toText = $0 })).frame(width: 90)
            Text("MB")
        }
    }.frame(width: 240))
    host.frame = NSRect(x: 0, y: 0, width: 240, height: 56)
    a.accessoryView = host
    a.addButton(withTitle: "Apply"); a.addButton(withTitle: "Cancel")
    guard a.runModal() == .alertFirstButtonReturn else { return nil }
    func bytes(_ s: String) -> Int64? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let mb = Double(t), mb >= 0 else { return nil }
        return Int64(mb * Double(SearchSizeFilter.mb))
    }
    let lo = bytes(box.fromText), hi = bytes(box.toText)
    // Both blank is not a filter — refuse rather than arm a "custom" that matches
    // everything and looks broken.
    guard lo != nil || hi != nil else { return nil }
    if let lo, let hi, lo > hi { return (hi, lo) }
    return (lo, hi)
}

func chooseApplication() -> URL? {
    let panel = NSOpenPanel()
    panel.message = "Choose an application"
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    return panel.runModal() == .OK ? panel.url : nil
}
func setDefaultApp(_ appURL: URL, for fileURL: URL) {
    guard let type = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType else { NSSound.beep(); return }
    Task { try? await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) }
}
func openInTerminal(_ url: URL) {
    let dir = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", "Terminal", dir.path]
    try? p.run()
}

func defaultLocations() -> [SidebarLocation] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    func sub(_ c: String) -> URL { home.appendingPathComponent(c) }
    return [
        .init(name: "Home", url: home, symbol: "house"),
        .init(name: "Desktop", url: sub("Desktop"), symbol: "menubar.dock.rectangle"),
        .init(name: "Documents", url: sub("Documents"), symbol: "doc"),
        .init(name: "Downloads", url: sub("Downloads"), symbol: "arrow.down.circle"),
        .init(name: "Pictures", url: sub("Pictures"), symbol: "photo"),
        .init(name: "Music", url: sub("Music"), symbol: "music.note"),
        .init(name: "Movies", url: sub("Movies"), symbol: "film"),
        .init(name: "Applications", url: URL(fileURLWithPath: "/Applications"), symbol: "square.grid.2x2"),
    ]
}

// SF Symbol / display name for a favorite path (well-known folders get their icon).
func favoriteSymbol(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    switch url.path {
    case home: return "house"
    case "\(home)/Desktop": return "menubar.dock.rectangle"
    case "\(home)/Documents": return "doc"
    case "\(home)/Downloads": return "arrow.down.circle"
    case "\(home)/Pictures": return "photo"
    case "\(home)/Music": return "music.note"
    case "\(home)/Movies": return "film"
    case "/Applications": return "square.grid.2x2"
    default: return url.path.hasPrefix("/Volumes/") ? "externaldrive.connected.to.line.below" : "folder"
    }
}
func favoriteName(_ url: URL) -> String {
    if url.path == FileManager.default.homeDirectoryForCurrentUser.path { return "Home" }
    let n = url.lastPathComponent
    return n.isEmpty ? url.path : n
}

// A sidebar favorite: a labeled shortcut to a path, optionally backed by a
// network URL to (re)mount when the path isn't currently available.
struct Favorite: Codable, Identifiable, Hashable {
    var label: String
    var path: String
    var mountURL: String?
    var id: String { "\(label)\u{1}\(path)" }
    var url: URL { URL(fileURLWithPath: path) }
}

// User-customizable sidebar favorites (add / remove / reorder), persisted.
// Supports custom labels + optional network mount URLs (mapped-drive style).
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()
    @Published var items: [Favorite]
    init() {
        if let data = UserDefaults.standard.data(forKey: "favoritesV2"),
           let decoded = try? JSONDecoder().decode([Favorite].self, from: data), !decoded.isEmpty {
            items = decoded
        } else if let saved = UserDefaults.standard.stringArray(forKey: "favorites"), !saved.isEmpty {
            items = saved.map { Favorite(label: favoriteName(URL(fileURLWithPath: $0)), path: $0, mountURL: nil) }
            persist()
        } else {
            items = defaultLocations().map { Favorite(label: $0.name, path: $0.url.path, mountURL: nil) }
            persist()
        }
    }
    func contains(_ url: URL) -> Bool { items.contains { $0.path == url.standardizedFileURL.path } }

    // Point network favorites at where their share ACTUALLY is right now.
    //
    // A share doesn't always come back on the same mountpoint: if anything is
    // holding the old name, macOS mounts it as "Games-1" instead of "Games". A
    // favorite storing the literal old path then points at nothing, and the drive
    // looks broken even though it's mounted and healthy — which is exactly what
    // happened to G Drive / ArtSource / T Drive while X Drive kept working.
    //
    // So: whenever a favorite's stored path is missing but its share is mounted,
    // rewrite the path onto the real mountpoint, keeping the same sub-folder. This
    // is self-healing in both directions — when the share later returns on its
    // proper name, the paths follow it back. Returns true if anything changed.
    @discardableResult
    func reanchorNetworkPaths() -> Bool {
        let fm = FileManager.default
        var updated = items
        var changed = false
        for i in updated.indices {
            guard let m = updated[i].mountURL, let share = URL(string: m) else { continue }
            let stored = updated[i].path
            if fm.fileExists(atPath: stored) { continue }              // already correct
            guard let mp = Browser.mountedPath(forShare: share) else { continue }   // share not mounted
            let rel = Browser.shareRelativePath(stored)                // "artSource", "Tools", or ""
            let target = rel.isEmpty ? mp : (mp as NSString).appendingPathComponent(rel)
            guard target != stored, fm.fileExists(atPath: target) else { continue }
            navLog("favorite “\(updated[i].label)” re-anchored: \(stored) → \(target)")
            updated[i].path = target
            changed = true
        }
        if changed { items = updated; persist() }
        return changed
    }
    func add(_ url: URL, label: String? = nil, mountURL: String? = nil) {
        let s = url.standardizedFileURL
        if label == nil, contains(s) { return }   // dedupe plain drag-adds; named drives may share a path
        items.append(Favorite(label: label ?? favoriteName(s), path: s.path, mountURL: mountURL)); persist()
    }
    // Drag-to-reorder from the sidebar. Home always snaps back to the top so it
    // stays the fixed anchor, regardless of where it's dropped.
    func move(fromOffsets: IndexSet, toOffset: Int) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let order = PathRules.reorder(count: items.count, from: fromOffsets, to: toOffset,
                                      pinnedToFront: items.firstIndex { $0.path == home })
        items = order.map { items[$0] }
        persist()
    }
    /// Index of a favorite by path, for the nudge helpers below.
    private func index(of path: String) -> Int? { items.firstIndex { $0.path == path } }

    // Keyboard-free, aim-free reordering from the context menu. Dragging is fine when
    // you hit a row, but "just below Home" is a small target and a miss looks like the
    // feature is broken — these always land.
    func moveToTop(path: String) {
        guard let i = index(of: path) else { return }
        move(fromOffsets: IndexSet(integer: i), toOffset: 0)
    }
    func moveUp(path: String) {
        guard let i = index(of: path), i > 0 else { return }
        move(fromOffsets: IndexSet(integer: i), toOffset: i - 1)
    }
    func moveDown(path: String) {
        guard let i = index(of: path), i < items.count - 1 else { return }
        // toOffset is "before the item originally at this index", so moving down one
        // place means inserting before i+2, not i+1.
        move(fromOffsets: IndexSet(integer: i), toOffset: i + 2)
    }
    /// Reorder driven by a drop: `src` takes `dest`'s place.
    func reorder(from src: String, onto dest: String) {
        guard let from = index(of: src), let target = index(of: dest), from != target else { return }
        move(fromOffsets: IndexSet(integer: from), toOffset: from < target ? target + 1 : target)
    }

    func remove(label: String, path: String) { items.removeAll { $0.label == label && $0.path == path }; persist() }
    func remove(url: URL) { let p = url.standardizedFileURL.path; items.removeAll { $0.path == p }; persist() }
    private func persist() { if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: "favoritesV2") } }

    // Export/import favorites as JSON — so a shared set (e.g. team network
    // drives) can be handed to a coworker who imports it. Each person still
    // connects through their own VPN/credentials; only the shortcuts are shared.
    func exportData() -> Data? {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(items)
    }
    @discardableResult
    func importData(_ data: Data) -> Int {
        guard let incoming = try? JSONDecoder().decode([Favorite].self, from: data) else { return -1 }
        let existing = Set(items.map { $0.id })
        let homeName = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent
        // A favorite is portable if it's a network drive (mountURL) or not under
        // some OTHER user's home. This skips a sharer's personal ~/Desktop etc.,
        // which would be a broken path for the importer, while keeping shared
        // network drives, /Applications, /Volumes, etc.
        func portable(_ f: Favorite) -> Bool {
            if f.mountURL != nil { return true }
            let parts = f.path.split(separator: "/")
            if parts.count >= 2, parts[0] == "Users", parts[1] != Substring(homeName) { return false }
            return true
        }
        // Upsert by label: a re-imported team file with corrected paths updates the
        // existing drive in place instead of adding a duplicate. New labels append.
        var changed = 0
        for f in incoming where portable(f) {
            if let idx = items.firstIndex(where: { $0.label == f.label }) {
                if items[idx].path != f.path || items[idx].mountURL != f.mountURL { items[idx] = f; changed += 1 }
            } else if !existing.contains(f.id) {
                items.append(f); changed += 1
            }
        }
        guard changed > 0 else { return 0 }
        persist()
        return changed
    }
}

// imageExtensions/videoExtensions themselves live in NavigatorCore, next to the folder
// classifier that has to agree with them (FolderKind).
func isImageFile(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }

// Cloud (File Provider) download state for a Google Drive / iCloud item, read
// from standard URL resource keys (local, no network). Matches Finder: a badge
// only for online-only or actively-downloading items; downloaded items show none.
enum CloudBadge {
    case onlineOnly, downloading, offlineAvailable
    var symbol: String {
        switch self {
        case .downloading: return "arrow.clockwise"
        case .onlineOnly: return "icloud.and.arrow.down"
        case .offlineAvailable: return "internaldrive.fill"   // saved locally
        }
    }
    var helpText: String {
        switch self {
        case .downloading: return "Downloading from the cloud…"
        case .onlineOnly: return "Online only — will download when opened"
        case .offlineAvailable: return "Available offline — saved on this Mac"
        }
    }
}
// Only File Provider locations (Google Drive & other CloudStorage providers,
// iCloud Drive) can be online-only. Gate on the PATH first — a cheap string
// check — so we never stat SMB / local files per cell. Reading the ubiquitous
// keys on an SMB file is a NETWORK round-trip; doing it per visible row made
// scrolling network folders (e.g. artSource) lag. This restores that speed.
func isCloudProviderPath(_ url: URL) -> Bool {
    let p = url.path
    return p.contains("/Library/CloudStorage/") || p.contains("/Library/Mobile Documents/")
}
func cloudBadge(for url: URL) -> CloudBadge? {
    guard isCloudProviderPath(url),
          let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                                    .ubiquitousItemIsDownloadingKey, .isDirectoryKey]),
          v.isUbiquitousItem == true else { return nil }
    if v.ubiquitousItemIsDownloading == true { return .downloading }
    if v.ubiquitousItemDownloadingStatus == .notDownloaded { return .onlineOnly }
    // Present locally = available offline. Files only: a FOLDER always reports
    // "current" regardless of what's inside it, so badging folders would mark
    // every folder as offline-ready, which isn't true.
    if v.isDirectory == true { return nil }
    return .offlineAvailable
}
@ViewBuilder func cloudBadgeView(_ badge: CloudBadge?) -> some View {
    if let badge {
        Image(systemName: badge.symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(3)
            .background(Circle().fill(Color.black.opacity(0.55)))
            .help(badge.helpText)
    }
}

func isVideoFile(_ url: URL) -> Bool { videoExtensions.contains(url.pathExtension.lowercased()) }
// Formats that should play (not just show a frame) in the viewer/preview.
func isAnimatedImage(_ url: URL) -> Bool { url.pathExtension.lowercased() == "gif" }

// Types worth asking QuickLook for a thumbnail of: images, video (poster frame),
// plus design/raw formats it can render — notably PSD. Everything else shows its
// file-type icon.
let thumbnailExtensions: Set<String> = imageExtensions.union(videoExtensions).union(
    ["psd","psb","pdf","ai","eps","svg","tga","exr","dds","cr2","nef","arw","dng","raw","orf","rw2","raf"])
func isThumbnailable(_ url: URL) -> Bool { thumbnailExtensions.contains(url.pathExtension.lowercased()) }

let archiveExtensions: Set<String> = ["zip","tar","tgz","gz","bz2","xz","tbz","txz"]
func isArchive(_ url: URL) -> Bool { archiveExtensions.contains(url.pathExtension.lowercased()) }

// Cloud providers mounted as folders under ~/Library/CloudStorage, plus iCloud Drive.
func cloudLocations() -> [SidebarLocation] {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    var out: [SidebarLocation] = []
    let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    if fm.fileExists(atPath: icloud.path) { out.append(.init(name: "iCloud Drive", url: icloud, symbol: "icloud")) }
    let cs = home.appendingPathComponent("Library/CloudStorage")
    if let entries = try? fm.contentsOfDirectory(atPath: cs.path) {
        for e in entries.sorted() where !e.hasPrefix(".") {
            let url = cs.appendingPathComponent(e)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name: String
            if e.hasPrefix("GoogleDrive") { name = "Google Drive" }
            else if e.hasPrefix("OneDrive") { name = "OneDrive" }
            else if e.hasPrefix("Dropbox") { name = "Dropbox" }
            else if e.hasPrefix("Box") { name = "Box" }
            else { name = String(e.split(separator: "-").first ?? Substring(e)) }
            out.append(.init(name: name, url: url, symbol: "cloud"))
        }
    }
    return out
}

/// Unmount a volume — a USB disk, or a network share (NSWorkspace handles both;
/// verified against a live SMB mount).
///
/// Both callers used to do this with `try?`, so the overwhelmingly common failure
/// — something still has a file open on the share — looked exactly like nothing
/// happening at all. A volume in use is normal and worth saying out loud, so the
/// error is reported instead of dropped. `isNetwork` only picks the wording.
func disconnectVolume(_ url: URL, isNetwork: Bool) {
    // Callers may hand us a path INSIDE the volume (a favorite pointing at
    // /Volumes/Games/artSource); unmounting needs the volume root.
    let c = url.pathComponents
    let vol = (c.count >= 3 && c[1] == "Volumes") ? URL(fileURLWithPath: "/Volumes/\(c[2])") : url
    // Work out which pinned shares live here while the volume still exists; only
    // hold auto-reconnect off if the unmount actually succeeds, so a failed
    // disconnect leaves the safety net intact. (getmntinfo, so no network I/O.)
    let keys = isNetwork ? NetworkReconnector.shared.shareKeys(mountedAt: vol.path) : []
    do {
        try NSWorkspace.shared.unmountAndEjectDevice(at: vol)
        NetworkReconnector.shared.suppress(keys)
    }
    catch {
        reportFileError(isNetwork ? "Couldn’t disconnect “\(vol.lastPathComponent)”"
                                  : "Couldn’t eject “\(vol.lastPathComponent)”",
                        (error as NSError).localizedDescription
                        + "\n\nA file on it is probably still open in another app.",
                        permissionHint: false)
    }
}

// Real mounted volumes via the system API (no /Volumes symlink duplicates).
func volumeLocations() -> [SidebarLocation] {
    let fm = FileManager.default
    let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeIsEjectableKey,
                                     .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey]
    guard let vols = fm.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) else {
        return [.init(name: "Macintosh HD", url: URL(fileURLWithPath: "/"), symbol: "internaldrive")]
    }
    var out: [SidebarLocation] = []
    for url in vols {
        let rv = try? url.resourceValues(forKeys: keys)
        let name = rv?.volumeLocalizedName ?? url.lastPathComponent
        let isRoot = rv?.volumeIsRootFileSystem ?? (url.path == "/")
        let isLocal = rv?.volumeIsLocal ?? true
        // A network share reports ejectable=false AND removable=false (checked: every
        // SMB mount on this Mac does), so keying the button on those flags alone meant
        // mounted shares could never be disconnected from Navigator at all — Finder
        // offers it. Any non-root volume that isn't the local disk can be let go of.
        let ejectable = ((rv?.volumeIsEjectable ?? false) || (rv?.volumeIsRemovable ?? false) || !isLocal) && !isRoot
        let sym = isRoot ? "internaldrive" : (isLocal ? "externaldrive" : "network")
        out.append(.init(name: name, url: url, symbol: sym, ejectable: ejectable, isNetwork: !isLocal))
    }
    return out
}

// MARK: - Browser state (one per tab)

/// "Scroll this item back to the top of the view." The sequence number is what makes a
/// repeat of the same anchor a new instruction — see Browser.restoreScroll.
struct ScrollRestore: Equatable {
    let id: String
    let seq: Int
}

final class Browser: ObservableObject, Identifiable {
    let id = UUID()
    // The one place a folder change is noticed, which is why per-folder view options are
    // applied here rather than in load(): load() also runs for ⌘R, a Show-Hidden toggle
    // and an FSEvents refresh, and re-applying settings on those would undo a view change
    // the user just made in a folder that has nothing saved.
    @Published var currentURL: URL {
        didSet {
            guard oldValue.path != currentURL.path else { return }
            // Record where we were BEFORE anything reloads: `items`, `selection` and the
            // view's scroll are all still the folder we are leaving at this point, and
            // load() (which runs right after every assignment to currentURL) clears them.
            rememberPlace(leaving: oldValue)
            // Deliberately staged here and not in load(): load() also runs for ⌘R, a
            // Show-Hidden toggle and an FSEvents refresh, and replaying a stored
            // selection on those would resurrect whatever was selected when you last LEFT
            // the folder over what you have selected right now.
            pendingPlace = places.value(for: currentURL.path)
            topVisibleID = nil          // the arriving view owns this; the old one's value is not ours
            applyFolderViewOptions()
            collapsedGroups = collapsedByFolder[folderKey(currentURL.path)] ?? []
            // The app-wide "a tab moved" signal, posted from the ONE place every route
            // goes through. It used to be posted by navigate(to:) alone, so goBack() and
            // goForward() — which assign currentURL directly — left the window title (and
            // the saved session) describing the folder you had just left.
            NotificationCenter.default.post(name: .navigatorDidNavigate, object: nil)
        }
    }
    // Bumped when cloud availability changes so rows re-read their badge — a
    // refresh alone doesn't do it, since the row's identity (its path) is unchanged.
    @Published var badgeGeneration = 0
    @Published var items: [FileItem] = [] {
        didSet {
            visibleCache = nil
            prefetchMetadataIfSortingOnIt()
            // A background op (e.g. Remove BG) asked to reveal file(s) once the
            // listing reloads and contains them — select + scroll to them now.
            if !pendingRevealPaths.isEmpty {
                let present = pendingRevealPaths.filter { p in items.contains { $0.id == p } }
                if !present.isEmpty {
                    pendingRevealPaths = []
                    selection = Set(present); keyboardScrollID = present.first; updateStatus()
                    // A just-created item (New Folder/New Text File) asked to start in
                    // rename mode the moment it actually shows up in the listing.
                    if let p = pendingRenamePath, present.contains(p) { renamingID = p }
                    pendingRenamePath = nil
                }
            }
            restorePendingPlace()
            // Content-based view inference. Hooked to `items` rather than to load()'s
            // completion because every backend (local, network phase 1 and 2, cache seed,
            // FSEvents refresh) ends up here — one hook covers all of them.
            //
            // Deferred by one runloop turn on purpose: all of those assign `items` and
            // only THEN clear `busy`, so asking right here always sees a listing that
            // claims to still be arriving, and the classification never runs at all.
            // (Measured: without the hop, a folder of 30 images opened in Details.)
            DispatchQueue.main.async { [weak self] in self?.applyInferredView() }
        }
    }
    @Published var selection: Set<String> = []
    // Drives the inline rename field (Table/Icon/Gallery all read this) — set
    // directly for the New Folder/keyboard-shortcut path, or via handleNameTap
    // below for the Explorer-style "click an already-selected name again" path.
    @Published var renamingID: String?
    private var pendingRenamePath: String?
    private var lastNameClick: (id: String, at: Date)?
    // Paths to select + scroll to as soon as the next listing load includes them.
    var pendingRevealPaths: [String] = []
    @Published var pathText: String = ""
    @Published var filterText: String = "" { didSet { visibleCache = nil } }
    @Published var searchText: String = ""
    @Published var isSearching = false
    @Published var searchThisMac = false
    @Published var searchKind: SearchKind = .any
    /// Date Modified + Size narrowing, applied identically by both search backends —
    /// see SearchFilters in NavigatorCore.
    @Published var searchFilters = SearchFilters()
    @Published var showHidden = false { didSet { Prefs.showHidden = showHidden; load() } }
    @Published var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\FileItem.name, order: .forward)] {
        didSet {
            visibleCache = nil
            prefetchMetadataIfSortingOnIt()
            // Every sort lands in the folder's own record, including one on a column
            // SortField cannot name (Ext, the extra dates, Time, Dimensions, Owner) —
            // which is the only way "always sort this folder by Dimensions" survives
            // navigating away. The global sort default has no such gap to fill: it is set
            // from Settings and from ⌘J's Use as Defaults, both of which offer only
            // columns it can express.
            persistViewSetting()
        }
    }
    @Published var groupBy: GroupBy = .none {
        didSet {
            // Titles from the OLD grouping must not survive into the new one. "Folders" is
            // a group title under both Kind and Size, so collapsing it under one and
            // switching to the other would arrive already collapsed for no visible reason.
            //
            // NOT while applyFolderViewOptions is assigning. On a folder CHANGE that runs
            // before load(), so groups() still describes the folder we just left: the
            // prune measured the new folder's remembered titles against the old folder's
            // items, and collapsedGroups.didSet then wrote that wrong answer into
            // collapsedByFolder[the new path] — destroying the destination's own state
            // and carrying the old folder's collapse across. The folder-change hook on
            // currentURL restores the right set itself, immediately after this.
            guard !applyingViewOptions else { return }   // persistViewSetting is a no-op then too
            collapsedGroups = GroupCollapse.pruned(collapsedGroups, toTitles: groups().map(\.title))
            persistViewSetting()
        }
    }
    @Published var status: String = ""
    @Published var freeSpace: String = ""
    @Published var isRecents = false
    @Published var viewMode: ViewMode = .list { didSet { persistViewSetting() } }
    @Published var iconSize: CGFloat = 76 { didSet { persistViewSetting() } }
    /// Which Details columns are shown. This is the SINGLE source both the View ▸ Columns
    /// menu and the header right-click menu read and write; the NSTableColumn `isHidden`
    /// flags are pushed from here on every reload and never treated as the truth. Two
    /// menus each holding their own idea of what's visible is precisely the drift that has
    /// already caused real bugs in this app's menus.
    @Published var visibleColumns: Set<String> = Set(defaultVisibleColumnIDs) {
        didSet { persistViewSetting() }
    }
    /// Group titles collapsed in the CURRENT folder. Group headers are always rendered;
    /// only their contents hide, so there is always something left to click.
    @Published var collapsedGroups: Set<String> = [] {
        didSet { collapsedByFolder[folderKey(currentURL.path)] = collapsedGroups.isEmpty ? nil : collapsedGroups }
    }
    /// Collapsed groups per folder, so navigating away and back doesn't silently
    /// re-expand everything. Deliberately in memory and per tab, NOT persisted: a
    /// collapsed group is a temporary "get this out of my way while I look at the rest",
    /// not a preference worth surviving a relaunch — and persisting it would need its own
    /// eviction policy for a value nobody would miss.
    private var collapsedByFolder: [String: Set<String>] = [:]
    @Published var gridColumns = 1
    @Published var keyboardScrollID: String?
    @Published var busy = false
    @Published var busyText = ""
    @Published var slowNetwork = false   // a network op is taking a while — shown quietly in the breadcrumb bar
    // A network listing that has produced NOTHING for a long time. The share is
    // wedged or the server won't answer, and "Loading…" forever with no way out is
    // what sends people to Finder to reconnect. Drives the recovery panel.
    @Published var networkStalled = false

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    // MARK: Coming back to where you were
    //
    // Back that lands you at the top of the folder with nothing selected is Back that
    // makes you find your place again. These three fields are the whole feature: the
    // views report what is at the top of the viewport, leaving a folder files that away,
    // and arriving at one replays it.

    /// The item currently at the top of the viewport, pushed by whichever view is on
    /// screen (list, icon; the gallery filmstrip has no meaningful "top" and leaves it
    /// nil, where the selection is a better anchor anyway).
    ///
    /// Deliberately NOT @Published: it changes on every scroll tick, and publishing it
    /// would re-render the entire file view continuously while you drag the scrollbar.
    var topVisibleID: String?
    private var places = FolderPlaceLRU()
    private var pendingPlace: FolderPlace?
    /// Set once when a stored place is replayed. Carries a sequence number because the
    /// same anchor is the right answer twice in a row — dive into a subfolder and come
    /// back a second time and the id is unchanged, so a bare String would compare equal
    /// and the views would never fire.
    @Published var restoreScroll: ScrollRestore?

    private func rememberPlace(leaving old: URL) {
        let ids = orderedVisibleItems().map(\.id)
        guard !ids.isEmpty else { return }
        // The gallery reports no top item, so fall back to the selection — which is
        // exactly what its filmstrip and big preview are showing you.
        let anchor = topVisibleID ?? ids.first { selection.contains($0) }
        let place = FolderPlace(anchorID: anchor,
                                anchorIndex: anchor.flatMap { ids.firstIndex(of: $0) } ?? 0,
                                selection: selection)
        places.set(place, for: old.path)
    }

    /// Replay a stored place once the listing that can satisfy it has arrived.
    private func restorePendingPlace() {
        guard let place = pendingPlace, !items.isEmpty else { return }
        // A background op asking to reveal specific files (Remove BG, New Folder) is a
        // deliberate, more recent instruction than "put me back where I was" — let it win
        // rather than have the two fight over the selection.
        guard pendingRevealPaths.isEmpty else { pendingPlace = nil; return }
        let ids = orderedVisibleItems().map(\.id)
        // `busy` still set means more of this folder is on its way; restoreAnchor uses it
        // to tell "gone" from "not here yet". Nil means it wants to wait, so keep the
        // record and try again on the next batch.
        guard let anchor = place.restoreAnchor(among: ids, settled: !busy) else { return }
        pendingPlace = nil
        // Only ids that still exist — a selection naming deleted files would show a
        // status line counting items that aren't there.
        let survivors = place.selection.intersection(ids)
        if !survivors.isEmpty { selection = survivors; updateStatus() }
        // Deliberately NOT keyboardScrollID: that one scrolls its target to the CENTRE
        // (right for arrow keys, wrong here) and would fight the anchor by aiming at the
        // first selected item instead of the item that was at the top. Also deliberately
        // not touching renamingID or lastNameClick — restoring a selection must never
        // arm the click-pause-click rename.
        restoreScroll = ScrollRestore(id: anchor, seq: (restoreScroll?.seq ?? 0) + 1)
    }
    private var recentsQuery: NSMetadataQuery?
    private var searchQuery: NSMetadataQuery?
    private var searchGen = 0   // cancels an in-flight recursive walk when a new search / clear starts
    private var typeBuffer = ""
    private var lastTypeAt = Date.distantPast
    private let fm = FileManager.default

    init(start: URL) {
        currentURL = start
        pathText = googleDrivePortablePath(start) ?? start.path
        showHidden = Prefs.showHidden
        // Swift doesn't run a property's didSet for an assignment made in init, so the
        // folder-options hook on currentURL above never fires for the very first folder —
        // this call is that hook, not a duplicate of it.
        applyFolderViewOptions()
        load()
        // A pinned drive came back on its own: if this window was sitting on a folder
        // that's now reachable again, just load it — the user shouldn't have to retry.
        NotificationCenter.default.addObserver(forName: .navigatorShareReconnected, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.items.isEmpty || self.networkStalled else { return }
            guard self.fm.fileExists(atPath: self.currentURL.path) else { return }
            self.networkStalled = false
            Browser.invalidateCache(self.currentURL.path)
            self.load()
        }
    }

    static func comparator(for f: SortField, ascending: Bool) -> KeyPathComparator<FileItem> {
        let o: SortOrder = ascending ? .forward : .reverse
        switch f {
        case .name: return KeyPathComparator(\FileItem.name, order: o)
        case .modified: return KeyPathComparator(\FileItem.modified, order: o)
        case .size: return KeyPathComparator(\FileItem.size, order: o)
        case .kind: return KeyPathComparator(\FileItem.kind, order: o)
        }
    }
    var currentSortField: SortField {
        for f in SortField.allCases where sortOrder.first == Browser.comparator(for: f, ascending: true)
            || sortOrder.first == Browser.comparator(for: f, ascending: false) { return f }
        return .name
    }
    var currentAscending: Bool { sortOrder.first?.order == .forward }
    func setSort(_ f: SortField, ascending: Bool) { sortOrder = [Browser.comparator(for: f, ascending: ascending)] }

    // MARK: Per-folder view options (⌘J)

    /// Comparator for a Details COLUMN id ("name", "dimensions", "owner", …).
    ///
    /// Per-folder options store the column id rather than a SortField, because a folder
    /// sorted by Dimensions or Owner has to come back sorted that way and SortField only
    /// names the four the toolbar Sort menu offers. Falls back to Name so a saved id whose
    /// column no longer exists can't leave a folder unsorted.
    static func comparator(forColumn id: String, ascending: Bool) -> KeyPathComparator<FileItem> {
        fileColumnDefs.first { $0.id == id }?.comparator?(ascending)
            ?? comparator(for: .name, ascending: ascending)
    }
    /// The column id the current sort corresponds to — the inverse of the above, and what
    /// gets written into a folder's record.
    var currentSortColumn: String {
        guard let cur = sortOrder.first else { return "name" }
        for def in fileColumnDefs {
            guard let make = def.comparator else { continue }
            if cur == make(true) || cur == make(false) { return def.id }
        }
        return "name"
    }

    /// The global defaults: what a folder with nothing saved looks like. Every value comes
    /// from the same Prefs keys the app has always read, so this is today's behaviour
    /// expressed as a record — which is what makes an untouched folder identical.
    static var defaultViewOptions: ViewOptions {
        ViewOptions(viewMode: Prefs.viewMode, iconSize: Double(Prefs.iconSize),
                    sortKey: Prefs.sortKey, sortAscending: Prefs.sortAscending,
                    groupBy: Prefs.groupBy,
                    columns: Prefs.columns ?? defaultVisibleColumnIDs)
    }
    /// This browser's current arrangement, in the form the ⌘J panel shows and a folder
    /// record stores.
    var currentViewOptions: ViewOptions {
        ViewOptions(viewMode: viewMode.rawValue, iconSize: Double(iconSize),
                    sortKey: currentSortColumn, sortAscending: currentAscending,
                    groupBy: groupBy.rawValue,
                    columns: fileColumnIDs.filter { visibleColumns.contains($0) })
    }

    /// True while applyFolderViewOptions is assigning, so the didSet on each property
    /// doesn't echo what we just applied straight back into storage. Without this, opening
    /// a folder that remembers "Icons" would immediately rewrite the GLOBAL default to
    /// Icons — one visit to one customized folder would silently change every other
    /// folder in the app.
    private var applyingViewOptions = false

    /// Where a view change lands: ALWAYS in this folder's own record, never in the global
    /// default. Changing the view is how a folder starts remembering — there is nothing
    /// to opt into, which is the whole of Item 1.
    ///
    /// It used to fall through to the global default for any folder without a record, and
    /// that is precisely what can't survive automatic remembering: switching one folder to
    /// Gallery would both remember it here AND redefine what every folder nobody has ever
    /// opened looks like. The global default now moves only when the user says so —
    /// "Use as Defaults" in ⌘J, or the Settings pickers.
    ///
    /// Recents is not a folder. It force-sorts by date on entry (loadRecents) without
    /// changing currentURL, so persisting from there would stamp that sort onto whichever
    /// real folder the tab happens to be sitting on.
    private func persistViewSetting() {
        guard !applyingViewOptions, !isRecents else { return }
        FolderViewOptionsStore.shared.save(currentViewOptions, for: currentURL.path)
    }

    /// Apply whatever governs the folder we're now in: its own options if it has any,
    /// otherwise the global defaults. Content inference is the third source and can't
    /// happen here — see applyInferredView, which needs a listing this runs before.
    func applyFolderViewOptions() {
        let path = currentURL.path
        let store = FolderViewOptionsStore.shared
        let o = store.options(for: path) ?? Browser.defaultViewOptions
        store.markUsed(path)              // recency by use, so the cap evicts the right folder
        viewWasInferred = false           // whatever we're about to apply, it isn't a guess
        applyingViewOptions = true
        // A saved "column" from the removed Columns view no longer parses, so it falls
        // back to Details here for free — no coercion step needed.
        viewMode = ViewMode(rawValue: o.viewMode) ?? .list
        iconSize = max(Browser.minIconSize, min(Browser.maxIconSize, CGFloat(o.iconSize)))
        groupBy = GroupBy(rawValue: o.groupBy) ?? .none
        sortOrder = [Browser.comparator(forColumn: o.sortKey, ascending: o.sortAscending)]
        visibleColumns = Set(o.columns.isEmpty ? defaultVisibleColumnIDs : o.columns)
        applyingViewOptions = false
    }

    /// Windows-style folder-type detection: a folder nobody has arranged by hand, whose
    /// contents are mostly pictures or video, opens in big thumbnails instead of a list of
    /// names. Third in the resolution order, behind this folder's own record and ahead of
    /// nothing — a folder it declines to classify simply keeps the global default.
    ///
    /// Driven by the LISTING, not by the folder change: classification needs names, and
    /// applyFolderViewOptions runs before load() has any. Re-running it on every settled
    /// reload is deliberate and costs nothing — the first time the user changes anything
    /// here the folder gets a record of its own, and the `options(for:)` guard below then
    /// makes this a permanent no-op for that folder.
    ///
    /// Applied behind `applyingViewOptions`, so the guess is NOT written down as the
    /// user's own choice. An inference that persisted itself would outlive turning the
    /// preference off, which is not what turning it off means.
    private func applyInferredView() {
        // `busy` is the same "the listing has settled" signal restorePendingPlace uses.
        // Classifying a 24-file first batch of a big folder would flip the view mode and
        // then flip it back when the rest arrives.
        guard Prefs.inferFolderView, !busy, !isRecents, !isSearching,
              FolderViewOptionsStore.shared.options(for: currentURL.path) == nil,
              // Already a thumbnail view — the user's default is Icons or Gallery, and
              // there is nothing here worth overriding it with.
              viewMode == .list,
              FolderKind.infer(items.map { ($0.name, $0.isDirectory) }) == .media else { return }
        applyingViewOptions = true
        viewMode = .icon
        iconSize = max(iconSize, 128)     // Explorer's "Large Icons"; never SHRINK the user's icons
        applyingViewOptions = false
        viewWasInferred = true
        // Coming BACK into this folder, restorePendingPlace has already asked the Details
        // list to scroll to where you were — and we have just replaced that list with a
        // grid. Both grid renderers consume restoreScroll through .onChange alone, so a
        // view mounted after the value was set never sees it and you land at the top.
        // Re-issue on the next turn, once the grid exists to observe the change.
        if let r = restoreScroll {
            DispatchQueue.main.async { [weak self] in
                self?.restoreScroll = ScrollRestore(id: r.id, seq: r.seq + 1)
            }
        }
    }

    /// True when what's on screen came from applyInferredView rather than from a saved
    /// record or the global default. Read by the ⌘J panel, which must not describe a guess
    /// as a setting — cached rather than recomputed, because the panel re-renders on every
    /// selection change and the classifier walks the whole listing.
    @Published private(set) var viewWasInferred = false

    /// ⌘J → "Restore Defaults": forget this folder's own options so it falls back to
    /// inference, then the global defaults. Finder's revert-to-defaults.
    func forgetFolderViewOptions() {
        FolderViewOptionsStore.shared.forget(currentURL.path)
        applyFolderViewOptions()
        // groupBy's own prune is suppressed while applyFolderViewOptions assigns (see
        // there). We're still in the SAME folder, so groups() describes what's on
        // screen and the prune is both safe and needed — otherwise reverting to a
        // different Group By leaves titles collapsed that the new grouping never had.
        collapsedGroups = GroupCollapse.pruned(collapsedGroups, toTitles: groups().map(\.title))
        // The listing is already loaded, so inference can take over immediately instead of
        // waiting for a refresh — otherwise "Restore Defaults" in a photo folder lands on
        // Details and only becomes the inferred view the next time you walk back into it.
        applyInferredView()
    }
    /// "Use as Defaults": what's on screen becomes the global default, i.e. what every
    /// folder with no saved options of its own will show from now on.
    func useCurrentViewOptionsAsDefaults() {
        let o = currentViewOptions
        Prefs.viewMode = o.viewMode
        Prefs.iconSize = CGFloat(o.iconSize)
        Prefs.groupBy = o.groupBy
        Prefs.columns = o.columns
        // Prefs.sortKey only understands the four SortField columns. Sorting by Ext,
        // Dimensions or Owner is per-folder-only, so a global default is simply left
        // alone rather than written as something SettingsView's picker can't display.
        if let f = SortField(rawValue: o.sortKey) {
            Prefs.sortKey = f.rawValue
            Prefs.sortAscending = o.sortAscending
        }
        objectWillChange.send()
    }

    // MARK: Collapsible group headers

    func toggleGroupCollapsed(_ title: String) {
        collapsedGroups = GroupCollapse.toggled(collapsedGroups, title: title)
        // A collapsed group can swallow the selection. Dropping anything now hidden is
        // what stops Return/Delete from acting on a file the user can't see.
        let visible = Set(orderedVisibleItems().map(\.id))
        let survivors = selection.intersection(visible)
        if survivors != selection { selection = survivors; updateStatus() }
    }
    func isGroupCollapsed(_ title: String) -> Bool {
        GroupCollapse.canCollapse(title: title) && collapsedGroups.contains(title)
    }

    /// Fill the metadata cache and re-sort, when (and only when) the sort is on a column
    /// whose values come from Spotlight. Without this, sorting by Time or Dimensions ranks
    /// every not-yet-drawn row as unknown and then never corrects itself.
    private func prefetchMetadataIfSortingOnIt() {
        // Called both when the sort changes AND when a listing arrives. The listing hook is
        // the one that matters for a folder that REMEMBERS a Time/Dimensions sort: the sort
        // is applied while `items` is still empty, so without it that folder would come
        // back in name order and never correct itself.
        guard fileColumnNeedsMetadata(currentSortColumn) else { return }
        let urls = items.filter { !$0.isDirectory }.map(\.url)
        guard !urls.isEmpty else { return }
        let gen = loadGeneration
        MetadataCache.shared.prefetch(urls) { [weak self] in
            // A different folder loaded while Spotlight was answering — re-sorting now
            // would sort the new folder against the old folder's reason for sorting.
            guard let self, gen == self.loadGeneration else { return }
            self.visibleCache = nil
            self.objectWillChange.send()
        }
    }

    // ⌘ + scroll wheel changes the view size, Windows 11-style: a continuum from
    // Details → Icons → Gallery, and within Icons a smooth resize (small → extra
    // large). Icon sizing is continuous (real-time micro-adjustments); crossing a
    // view boundary needs a bit of accumulated scroll so one flick doesn't skip
    // through everything. dy > 0 = larger. minIcon 44 ≈ "small", 256 ≈ "extra large".
    static let minIconSize: CGFloat = 44
    static let maxIconSize: CGFloat = 256
    private var scrollAccum: CGFloat = 0
    func adjustViewScale(_ dy: CGFloat) {
        // The cycle is Details ↔ Icons (small→large) ↔ Gallery.
        if viewMode == .icon {
            let proposed = iconSize + dy * 1.4
            if proposed < Browser.minIconSize {          // shrinking past the smallest icons → Details
                scrollAccum += dy
                if scrollAccum <= -6 { viewMode = .list; scrollAccum = 0 }
            } else {
                iconSize = min(Browser.maxIconSize, proposed); scrollAccum = 0
            }
        } else {
            scrollAccum += dy
            if scrollAccum >= 6 {                          // grow
                scrollAccum = 0
                switch viewMode {
                case .list: viewMode = .icon; iconSize = Browser.minIconSize
                default: break
                }
            } else if scrollAccum <= -6 {                  // shrink
                scrollAccum = 0
                switch viewMode {
                case .gallery: viewMode = .icon; iconSize = Browser.maxIconSize
                default: break
                }
            }
        }
    }

    var currentIsNetwork = false
    private static var typeIconCache: [String: NSImage] = [:]
    func icon(for item: FileItem) -> NSImage {
        // The Trash gets its proper can icon (icon(forFile:) returns a blank
        // document for ~/.Trash, and it's often unreadable without Full Disk Access).
        if item.url.lastPathComponent == ".Trash" {
            return NSImage(named: NSImage.trashEmptyName) ?? NSWorkspace.shared.icon(for: .folder)
        }
        // On network volumes, use cached icons keyed by type (no per-file I/O over
        // SMB). Locally, use the real per-file icon (custom folder/app icons).
        guard currentIsNetwork else { return NSWorkspace.shared.icon(forFile: item.url.path) }
        let key = item.isDirectory ? "/dir" : (item.ext.isEmpty ? "/file" : item.ext)
        if let c = Browser.typeIconCache[key] { return c }
        let type: UTType = item.isDirectory ? .folder : (UTType(filenameExtension: item.ext) ?? .data)
        let img = NSWorkspace.shared.icon(for: type)
        Browser.typeIconCache[key] = img
        return img
    }

    // Full metadata (used on fast/local volumes and for single-item detail views).
    static let itemKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                                             .creationDateKey, .contentAccessDateKey, .addedToDirectoryDateKey,
                                             .localizedTypeDescriptionKey, .tagNamesKey,
                                             .isSymbolicLinkKey, .isAliasFileKey]
    // Minimal metadata for slow (network/SMB) volumes — just what the default
    // columns need. Everything else is derived locally or falls back, so a
    // 600-item network folder loads in a couple of round-trips, not hundreds.
    static let fastItemKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

    // Localized "Kind" derived from the extension with no disk/network I/O.
    private static var kindCache: [String: String] = [:]
    private static let kindLock = NSLock()
    static func localKind(_ url: URL, isDir: Bool) -> String {
        if isDir { return "Folder" }
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return "Document" }
        kindLock.lock(); defer { kindLock.unlock() }
        if let c = kindCache[ext] { return c }
        let kind = UTType(filenameExtension: ext)?.localizedDescription ?? "\(ext.uppercased()) file"
        kindCache[ext] = kind
        return kind
    }

    static func item(from u: URL, _ rv: URLResourceValues?) -> FileItem {
        var isDir = rv?.isDirectory ?? false
        // A symlink/alias to a folder (e.g. the "Google Drive" cloud link) should
        // behave and sort like a folder — open into it, keep it up top with folders.
        if !isDir, rv?.isSymbolicLink == true || rv?.isAliasFile == true {
            var d: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &d), d.boolValue { isDir = true }
        }
        let modified = rv?.contentModificationDate ?? Date.distantPast
        let kind = (rv?.allValues[.localizedTypeDescriptionKey] as? String) ?? localKind(u, isDir: isDir)
        return FileItem(id: u.path, url: u, name: u.lastPathComponent,
                        isDirectory: isDir, size: Int64(rv?.fileSize ?? 0),
                        modified: modified,
                        created: rv?.creationDate ?? modified,
                        accessed: (rv?.allValues[.contentAccessDateKey] as? Date) ?? modified,
                        dateAdded: (rv?.allValues[.addedToDirectoryDateKey] as? Date) ?? modified,
                        kind: kind,
                        tags: (rv?.allValues[.tagNamesKey] as? [String]) ?? [])
    }

    private func makeItem(_ u: URL) -> FileItem {
        Browser.item(from: u, try? u.resourceValues(forKeys: Set(Browser.itemKeys)))
    }

    // Names ONLY, straight from POSIX readdir — no attribute fetch of any kind.
    //
    // This exists because asking for attributes is catastrophically expensive on
    // some SMB shares. Measured on a DFS-heavy share: readdir returned 669 entries
    // in 429 ms, while the same folder enumerated WITH attributes managed 41
    // entries in 38 seconds (~925 ms each) — every entry that is a DFS referral
    // costs a round trip. readdir's d_type already tells us file vs folder, which
    // is all the list needs to paint; sizes and dates arrive in phase 2.
    static func namesOnlyItems(_ dir: URL, showHidden: Bool) -> [FileItem] {
        guard let d = opendir(dir.path) else { return [] }
        defer { closedir(d) }
        var out: [FileItem] = []
        while let ent = readdir(d) {
            var raw = ent.pointee.d_name
            let name = withUnsafeBytes(of: &raw) { buf in
                String(cString: buf.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            if !showHidden && name.hasPrefix(".") { continue }
            let isDir = ent.pointee.d_type == DT_DIR
            let u = dir.appendingPathComponent(name, isDirectory: isDir)
            out.append(FileItem(id: u.path, url: u, name: name, isDirectory: isDir,
                                size: 0, modified: .distantPast, created: .distantPast,
                                accessed: .distantPast, dateAdded: .distantPast,
                                kind: localKind(u, isDir: isDir), tags: []))
        }
        return out
    }

    // The view order: sort, folders-first, then name filter.
    // Memoized: sorting + filtering 669 items is O(n log n), and this is called
    // from `body`, which SwiftUI re-evaluates on every scroll tick — so without a
    // cache a large network folder re-sorts every frame and scrolling stutters.
    // Invalidated (visibleCache = nil) whenever items / sortOrder / filterText change.
    private var visibleCache: [FileItem]?
    func visibleItems() -> [FileItem] {
        if let c = visibleCache { return c }
        let sorted = items.sorted(using: sortOrder)
        let combined = sorted.filter { $0.isDirectory } + sorted.filter { !$0.isDirectory }
        let result = filterText.isEmpty ? combined : combined.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
        visibleCache = result
        return result
    }

    // Grouped sections for the current groupBy setting.
    func groups() -> [(title: String, items: [FileItem])] {
        let vis = visibleItems()
        switch groupBy {
        case .none:
            return [("", vis)]
        case .kind:
            let grouped = Dictionary(grouping: vis) { $0.isDirectory ? "Folders" : ($0.kind.isEmpty ? "Files" : $0.kind) }
            return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
        case .date:
            let cal = Calendar.current
            let now = Date()
            func bucket(_ d: Date) -> String {
                if cal.isDateInToday(d) { return "Today" }
                if cal.isDateInYesterday(d) { return "Yesterday" }
                let days = cal.dateComponents([.day], from: d, to: now).day ?? 9999
                if days < 7 { return "Earlier this week" }
                if days < 30 { return "Earlier this month" }
                if days < 365 { return "Earlier this year" }
                return "Older"
            }
            let grouped = Dictionary(grouping: vis) { bucket($0.modified) }
            let order = ["Today", "Yesterday", "Earlier this week", "Earlier this month", "Earlier this year", "Older"]
            return order.compactMap { t in grouped[t].map { (t, $0) } }
        case .size:
            func bucket(_ it: FileItem) -> String {
                if it.isDirectory { return "Folders" }
                let mb = Double(it.size) / 1_000_000
                if mb < 1 { return "Small (< 1 MB)" }
                if mb < 100 { return "Medium (1–100 MB)" }
                return "Large (> 100 MB)"
            }
            let grouped = Dictionary(grouping: vis) { bucket($0) }
            let order = ["Folders", "Small (< 1 MB)", "Medium (1–100 MB)", "Large (> 100 MB)"]
            return order.compactMap { t in grouped[t].map { (t, $0) } }
        }
    }
    // Flat order matching what the user sees (used for keyboard navigation).
    //
    // "What the user sees" now excludes the contents of a collapsed group, and that is
    // load-bearing rather than cosmetic: arrow keys, Tab/⇧Tab, type-to-select, ⇧-click
    // ranges and Select All all walk this list, so leaving hidden items in it means Tab
    // selects a file that isn't on screen — the status bar updates and Return opens
    // something invisible, with nothing to explain it.
    func orderedVisibleItems() -> [FileItem] {
        guard groupBy != .none else { return visibleItems() }
        return GroupCollapse.visibleOrder(groups: groups(), collapsed: collapsedGroups)
    }

    // Spotlight-backed Recents (recently used/modified files), like Finder's Recents.
    // Recents = the folders you've actually worked in: every folder you've
    // navigated to, plus every folder you've created/saved/pasted/renamed a file
    // in (see RecentFolders.shared.record calls in the file operations). Shown
    // most-recent first — no Spotlight flood of every touched file.
    // "Recents" in Favorites works like Finder's: recently used / changed FILES
    // across your home folder, newest first. (The separate "Recent Folders" list
    // is the folders you've worked in — see RecentFolders.)
    func loadRecents() {
        isRecents = true
        isSearching = false
        dirWatcher.stop()
        selection = []
        pathText = "Recents"
        items = []
        status = "Finding recent files…"
        sortOrder = [KeyPathComparator(\FileItem.modified, order: .reverse)]
        recentsQuery?.stop()
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        let since = Date().addingTimeInterval(-60 * 60 * 24 * 45) as NSDate
        q.predicate = NSPredicate(format: "kMDItemLastUsedDate >= %@ OR kMDItemFSContentChangeDate >= %@", since, since)
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemFSContentChangeDate", ascending: false)]
        NotificationCenter.default.addObserver(self, selector: #selector(recentsGathered(_:)),
                                               name: .NSMetadataQueryDidFinishGathering, object: q)
        recentsQuery = q
        q.start()
    }

    @objc private func recentsGathered(_ note: Notification) {
        guard let q = recentsQuery else { return }
        q.disableUpdates()
        var result: [FileItem] = []
        let n = min(q.resultCount, 200)
        for i in 0..<n {
            guard let mi = q.result(at: i) as? NSMetadataItem,
                  let path = mi.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            result.append(makeItem(URL(fileURLWithPath: path)))
        }
        items = result
        updateStatus()
        q.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: q)
        recentsQuery = nil
    }

    // Spotlight search within the current folder subtree (name + content).
    func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        // A Date/Size filter on its own IS a search ("everything modified today"), which
        // is how Explorer and Finder both behave. Only a search with no text AND no
        // filter is nothing at all.
        guard !query.isEmpty || searchFilters.isActive else { clearSearch(); return }
        isSearching = true
        dirWatcher.stop()
        selection = []
        items = []
        status = "Searching…"
        searchQuery?.stop(); searchQuery = nil
        searchGen += 1
        // Spotlight only for a true-local "This Mac" search — it doesn't index SMB
        // shares or Google Drive (File Provider), so those need a real recursive
        // walk. "This Folder" always walks (works everywhere, incl. cloud/SMB).
        if searchThisMac && !currentIsNetwork && !isCloudProviderPath(currentURL) {
            runSpotlight(query)
        } else {
            walkSearch(query, root: currentURL, gen: searchGen)
        }
    }
    /// Combines metadata subpredicates, unwrapping the single-element case.
    ///
    /// This is not tidiness — it is the fix for a search that did not work at all.
    /// NSMetadataQuery RAISES on a compound predicate holding only one subpredicate
    /// ("NSAndPredicateType NSCompoundPredicate with wrong number (1) of subpredicates
    /// given to NSMetadataQuery", caught in the log). "This Mac" with Kind = Any and no
    /// Date/Size filter builds exactly one subpredicate — the name match — so the
    /// commonest possible Spotlight search threw inside menu tracking and silently
    /// returned nothing. It only ever appeared to work when a second filter happened to
    /// be set.
    static func metadataCompound(_ subs: [NSPredicate], and: Bool) -> NSPredicate? {
        switch subs.count {
        case 0: return nil
        case 1: return subs[0]
        default: return and ? NSCompoundPredicate(andPredicateWithSubpredicates: subs)
                            : NSCompoundPredicate(orPredicateWithSubpredicates: subs)
        }
    }
    private func runSpotlight(_ query: String) {
        let q = NSMetadataQuery()
        q.searchScopes = searchThisMac ? [NSMetadataQueryLocalComputerScope] : [currentURL]
        var subs: [NSPredicate] = []
        if !query.isEmpty {
            subs.append(NSPredicate(format: "kMDItemDisplayName LIKE[cd] %@ OR kMDItemTextContent CONTAINS[cd] %@", "*\(query)*", query))
        }
        if let tree = searchKind.typeTree { subs.append(NSPredicate(format: "kMDItemContentTypeTree == %@", tree)) }
        // Date/Size go into the PREDICATE as well as the post-hoc check in
        // searchGathered, purely so the 500-result cap is spent on rows that can
        // actually match — filtering after the cap would drop real hits. The post-hoc
        // check is still the authority (a stale Spotlight index can disagree with disk).
        let dates = searchFilters.dateRange()
        if let f = dates.from { subs.append(NSPredicate(format: "kMDItemFSContentChangeDate >= %@", f as NSDate)) }
        if let t = dates.to { subs.append(NSPredicate(format: "kMDItemFSContentChangeDate < %@", t as NSDate)) }
        let sizes = searchFilters.sizeRange()
        if sizes.from != nil || sizes.to != nil {
            var sizeSubs: [NSPredicate] = []
            if let f = sizes.from { sizeSubs.append(NSPredicate(format: "kMDItemFSSize >= %lld", f)) }
            if let t = sizes.to { sizeSubs.append(NSPredicate(format: "kMDItemFSSize < %lld", t)) }
            // OR'd with "is a folder", because kMDItemFSSize on a directory is its
            // directory entry, not its contents. Without this the two backends would
            // disagree: SearchFilters exempts folders from the size test, so a folder
            // Spotlight had already thrown away would still show up in walkSearch.
            if let sizeClause = Browser.metadataCompound(sizeSubs, and: true) {
                subs.append(NSCompoundPredicate(orPredicateWithSubpredicates: [
                    sizeClause,
                    NSPredicate(format: "kMDItemContentTypeTree == %@", "public.folder"),
                ]))
            }
        }
        // runSearch has already guaranteed there is at least text or a filter, so subs
        // is never empty and this is never nil.
        guard let predicate = Browser.metadataCompound(subs, and: true) else { return }
        q.predicate = predicate
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemFSName", ascending: true)]
        NotificationCenter.default.addObserver(self, selector: #selector(searchGathered(_:)),
                                               name: .NSMetadataQueryDidFinishGathering, object: q)
        searchQuery = q
        q.start()
    }
    // Recursive filesystem search — the only reliable way on SMB / Google Drive
    // (Spotlight can't index them). Matches a name substring OR a file extension
    // (so "png", ".png", or "logo" all work). Streams matches in as they're found,
    // on a background thread, cancellable via searchGen.
    private func walkSearch(_ raw: String, root: URL, gen: Int) {
        let q = raw.lowercased()
        let extQ = q.trimmingCharacters(in: CharacterSet(charactersIn: "*."))
        let kindTree = searchKind.typeTree   // optional kind constraint (Images, etc.)
        let showHidden = self.showHidden
        // Snapshot the filters (and "now") once, off the main thread's back: a walk of a
        // big tree can straddle midnight, and re-deriving "Today" per file would then
        // change the answer halfway through the results.
        let filters = self.searchFilters
        let now = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let keys = Browser.itemKeys
            var opts: FileManager.DirectoryEnumerationOptions = []
            if !showHidden { opts.insert(.skipsHiddenFiles) }
            let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: opts)
            var batch: [FileItem] = []
            var total = 0
            func flush(final: Bool) {
                let snap = batch; batch.removeAll()
                DispatchQueue.main.async { [weak self] in
                    guard let self, gen == self.searchGen else { return }
                    if !snap.isEmpty { self.items.append(contentsOf: snap) }
                    self.status = final ? "\(self.items.count) found" : "Searching… \(self.items.count) found"
                }
            }
            while let u = en?.nextObject() as? URL {
                guard let self, gen == self.searchGen else { return }   // cancelled
                let name = u.lastPathComponent.lowercased()
                let ext = u.pathExtension.lowercased()
                if kindTree != nil {   // kind filter set → require a matching content type
                    if !(UTType(filenameExtension: ext)?.conforms(to: UTType(kindTree!) ?? .data) ?? false) { continue }
                }
                // Empty query = filter-only search, so every name qualifies.
                if !q.isEmpty {
                    guard name.contains(q) || (!extQ.isEmpty && ext == extQ) else { continue }
                }
                let item = Browser.item(from: u, try? u.resourceValues(forKeys: Set(keys)))
                guard filters.matches(modified: item.modified, size: item.size,
                                      isDirectory: item.isDirectory, now: now) else { continue }
                batch.append(item)
                total += 1
                if batch.count >= 40 { flush(final: false) }
                if total >= 10_000 { break }   // sanity cap on huge trees
            }
            flush(final: true)
        }
    }
    @objc private func searchGathered(_ note: Notification) {
        // Take the query from the NOTIFICATION, and ignore it unless it is still the
        // current one. Reading `searchQuery` instead was a live bug: changing two
        // filters at once starts two queries in the same frame, and when the FIRST
        // one finished gathering this handler read results from the SECOND (which had
        // gathered nothing yet), published an empty list, and then stopped it — so the
        // real results never arrived and the search looked like it found nothing.
        guard let q = note.object as? NSMetadataQuery, q === searchQuery else { return }
        q.disableUpdates()
        var result: [FileItem] = []
        let n = min(q.resultCount, 500)
        let now = Date()
        for i in 0..<n {
            guard let mi = q.result(at: i) as? NSMetadataItem,
                  let path = mi.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let item = makeItem(URL(fileURLWithPath: path))
            // Re-check against the SAME predicate walkSearch uses. Spotlight's index can
            // lag the disk (a file saved seconds ago still carries its old size there),
            // and a filter that means one thing on the Spotlight path and another on the
            // recursive path is worse than no filter at all.
            guard searchFilters.matches(modified: item.modified, size: item.size,
                                        isDirectory: item.isDirectory, now: now) else { continue }
            result.append(item)
        }
        items = result
        updateStatus()
        q.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: q)
        searchQuery = nil
    }
    /// This tab's window is gone — stop everything that would otherwise keep running.
    ///
    /// A closed NavWindow does NOT deallocate: it is `isReleasedWhenClosed = false` (and
    /// must stay that way — flipping it crashes in _NSWindowTransformAnimation dealloc,
    /// measured), and AppKit still holds it after the app drops its own reference. So
    /// without this, every window you closed left an FSEvents stream watching a folder
    /// and a live Spotlight query answering notifications for the rest of the session.
    /// Called from AppModel.forgetSession, which is the one "this window is finished"
    /// signal — deliberately NOT on quit, where the process is going away anyway.
    func stopWatching() {
        dirWatcher.stop()
        recentsQuery?.stop(); recentsQuery = nil
        searchQuery?.stop(); searchQuery = nil
        searchGen += 1   // cancel any in-flight recursive walk
        loadGeneration += 1   // and any in-flight listing, so it can't restart the watcher
    }

    func clearSearch() {
        searchQuery?.stop(); searchQuery = nil
        searchGen += 1   // cancel any in-flight recursive walk
        searchText = ""; isSearching = false
        // Filters go too. A filter left armed after the search is closed is invisible
        // state that silently narrows the NEXT search for no reason the user can see.
        searchFilters = SearchFilters()
        load()
    }

    private var loadGeneration = 0
    // Client-side directory cache (Windows-style): last-known listing per folder,
    // so revisits / back-forward are instant while a fresh copy loads in the
    // background. Main-thread only.
    private static var dirCache: [String: [FileItem]] = [:]
    static func invalidateCache(_ path: String) {
        for k in [path, path + "\u{1}h"] { dirCache[k] = nil; DiskCache.remove(k) }
    }

    // Auto-refresh: watches the current (local) folder and silently re-reads it
    // when its contents change on disk (e.g. a download finishes, another app
    // adds a file). Preserves selection; no "Loading…" flash.
    private lazy var dirWatcher = DirectoryWatcher { [weak self] in self?.silentRefresh() }
    /// Re-reads the current folder in place: same items array, so selection survives
    /// (filtered to what still exists) and the table/grid keeps its scroll offset,
    /// because every row's identity is its path and only the changed rows differ.
    ///
    /// Network folders reach this from NetworkPollCoordinator rather than FSEvents —
    /// SMB emits no FSEvents at all. They also refresh the PERSISTED cache, or the
    /// next visit's mtime revalidation would compare against a stale stored mtime and
    /// throw away the listing we just paid for.
    func silentRefresh() {
        guard !isSearching, !isRecents else { return }
        let dir = currentURL, sh = showHidden
        let isNet = currentIsNetwork
        let cacheKey = dir.path + (sh ? "\u{1}h" : "")
        loadGeneration += 1
        let gen = loadGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let keys = Browser.itemKeys
            var opts: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
            if !sh { opts.insert(.skipsHiddenFiles) }
            let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: opts)
            var result: [FileItem] = []
            while let u = en?.nextObject() as? URL {
                guard let self, gen == self.loadGeneration else { return }
                result.append(Browser.item(from: u, try? u.resourceValues(forKeys: Set(keys))))
            }
            let final = result
            // stat(), not resourceValues — a URL caches those, so the value stored
            // alongside the cached listing would be the mtime from an earlier read.
            var dst = stat()
            let mtime: Date? = (isNet && stat(dir.path, &dst) == 0)
                ? Date(timeIntervalSince1970: Double(dst.st_mtimespec.tv_sec) + Double(dst.st_mtimespec.tv_nsec) / 1e9)
                : nil
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.loadGeneration else { return }
                // A share that went away mid-read enumerates as empty. Replacing a good
                // listing with nothing looks exactly like "someone deleted everything".
                if final.isEmpty, isNet, !self.items.isEmpty { return }
                Browser.dirCache[cacheKey] = final
                if isNet, !final.isEmpty { DiskCache.put(cacheKey, final, dirModified: mtime) }
                self.items = final
                self.selection = self.selection.filter { sel in final.contains { $0.id == sel } }
                self.updateStatus()
            }
        }
    }

    // Explicit user Refresh (⌘R): drop the cached listing for this folder so we
    // re-read from disk/network and show a clean "Loading…" instead of stale cache.
    func refresh() {
        Browser.invalidateCache(currentURL.path)
        // ⌘R is the natural "these thumbnails look wrong" gesture — forget throttled
        // thumbnail failures so the reload really does try again immediately.
        ThumbnailCache.shared.forgetFailures()
        if isSearching { runSearch() } else { load() }
    }

    // Directory enumeration (and its per-file attribute fetches) runs on a
    // background queue — over SMB/VPN it can take a while, and doing it on the
    // main thread would freeze the UI. Results are applied on the main thread,
    // and stale loads (superseded by a newer navigation) are discarded.
    func load() {
        isRecents = false
        isSearching = false
        slowNetwork = false
        networkStalled = false
        pathText = addressString(for: currentURL)
        selection = []
        // Arriving in the Trash: read Finder's put-back records so Put Back knows
        // where items trashed by other apps came from.
        if isTrash { loadTrashPutBack() }
        let dir = currentURL
        loadGeneration += 1
        let gen = loadGeneration
        let cacheKey = dir.path + (showHidden ? "\u{1}h" : "")
        // Seed instantly from cache — no stat needed (DiskCache only ever holds
        // network folders, so a local path's key simply isn't present).
        let seed = Browser.dirCache[cacheKey] ?? DiskCache.get(cacheKey)
        let hadSeed = seed != nil
        let cachedDirMtime = DiskCache.dirModified(cacheKey)
        let withinBackstop = (DiskCache.age(cacheKey) ?? .infinity) < Browser.networkCacheTTL
        if let seed {
            items = seed
            busy = false; busyText = ""
            updateStatus()
        } else {
            items = []            // clear stale previous-folder contents; the load fills it in
            busy = true; busyText = "Loading…"
            updateStatus()
        }
        // OFF the main thread, stat just the folder: its mtime (one round-trip) and
        // whether it's a network volume. Both are stats that can block on a slow SMB
        // mount, so never on the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, gen == self.loadGeneration else { return }
            let rv = try? dir.resourceValues(forKeys: [.volumeIsLocalKey])
            let isNetwork = rv?.volumeIsLocal == false
            // The folder's mtime comes from POSIX stat, NOT from resourceValues.
            // resourceValues is cached — measured on an SMB share: 46 files were added
            // and `stat` in a shell saw the new folder mtime immediately, while
            // .contentModificationDateKey kept returning the mtime from before they
            // existed. Feeding that into the revalidation below said "nothing changed"
            // and served the stale cached listing until the 15-minute TTL expired.
            var dst = stat()
            let dirMtime: Date? = stat(dir.path, &dst) == 0
                ? Date(timeIntervalSince1970: Double(dst.st_mtimespec.tv_sec) + Double(dst.st_mtimespec.tv_nsec) / 1e9)
                : nil
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.loadGeneration else { return }
                self.currentIsNetwork = isNetwork
                if isNetwork { self.dirWatcher.stop() } else { self.dirWatcher.watch(dir) }
                self.updateFreeSpace()
                if isNetwork {
                    // Conditional revalidation: if the folder's mtime is unchanged, no
                    // files were added or removed since we cached it — serve the cache
                    // and skip the slow re-enumeration. A changed mtime → refresh now
                    // (new files show immediately). The TTL backstop catches the cases
                    // dir-mtime misses (in-place edits / some servers' renames). ⌘R
                    // always forces a refresh.
                    let unchanged = hadSeed && dirMtime != nil && dirMtime == cachedDirMtime && withinBackstop
                    if unchanged { self.slowNetwork = false; return }
                    self.loadNetwork(dir, gen: gen, cacheKey: cacheKey, hadSeed: hadSeed, dirMtime: dirMtime)
                } else {
                    self.loadLocal(dir, gen: gen, cacheKey: cacheKey, hadCache: Browser.dirCache[cacheKey] != nil)
                }
            }
        }
    }
    // Backstop for the conditional-revalidation cache: even if the folder's mtime
    // looks unchanged, re-scan after this long to catch in-place edits/renames that
    // don't bump the directory mtime. Generous because the mtime check is accurate
    // for the common case (files added/removed).
    static let networkCacheTTL: TimeInterval = 900

    // Local volumes: stat is cheap, so read everything (incl. tags/kind) up front
    // via Foundation's enumerator, streaming in batches for very large folders.
    private func loadLocal(_ dir: URL, gen: Int, cacheKey: String, hadCache: Bool) {
        let keys = Browser.itemKeys
        var opts: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !showHidden { opts.insert(.skipsHiddenFiles) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: opts)
            var result: [FileItem] = []
            var sinceFlush = 0
            var lastFlush = ProcessInfo.processInfo.systemUptime
            while let u = en?.nextObject() as? URL {
                guard let self, gen == self.loadGeneration else { return }
                result.append(Browser.item(from: u, try? u.resourceValues(forKeys: Set(keys))))
                sinceFlush += 1
                // Show what we have as it arrives. The old rule only flushed every
                // 200 entries, so a folder with fewer than that (most folders) stayed
                // completely EMPTY behind "Loading…" until the whole enumeration
                // finished — the worst case being a cloud folder where each entry
                // costs a provider round-trip. Now: first rows land quickly, then a
                // flush at least every 100ms.
                let now = ProcessInfo.processInfo.systemUptime
                if !hadCache, sinceFlush >= 24 || (sinceFlush > 0 && now - lastFlush >= 0.1) {
                    sinceFlush = 0; lastFlush = now
                    let snapshot = result
                    DispatchQueue.main.async { [weak self] in
                        guard let self, gen == self.loadGeneration else { return }
                        self.items = snapshot; self.updateStatus()
                    }
                }
            }
            let committed = result
            DispatchQueue.main.async {
                guard let self, gen == self.loadGeneration else { return }
                Browser.dirCache[cacheKey] = committed
                self.items = committed
                self.busy = false; self.busyText = ""
                self.updateFreeSpace(); self.updateStatus()
            }
        }
    }

    // Network volumes: two-phase load that beats Finder. Phase 1 shows names +
    // folder icons instantly (POSIX readdir, ~0.7s for hundreds of entries).
    // Phase 2 fills in size/date in the background (one stat each, ~86ms over
    // VPN), updating the UI in chunks. Both phases honor the generation token so
    // navigating away cancels them, and the final result is cached for instant
    // revisits. Finder blocks on phase 2 for the whole folder — hence the hang.
    private func loadNetwork(_ dir: URL, gen: Int, cacheKey: String, hadSeed: Bool = false, dirMtime: Date? = nil) {
        let showHidden = self.showHidden
        // Non-blocking hint if the enumeration stalls (slow/hiccuping SMB mount):
        // a quiet note in the breadcrumb bar, not a popup. Fires only if we're
        // still on this same load after a few seconds.
        if !hadSeed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, gen == self.loadGeneration, self.busy else { return }
                self.slowNetwork = true
            }
            // Nothing at all after this long → treat the share as not responding and
            // offer a way out, instead of spinning indefinitely.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, gen == self.loadGeneration, self.busy, self.items.isEmpty else { return }
                self.networkStalled = true
            }
        }
        let keys = Browser.itemKeys
        var opts: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !showHidden { opts.insert(.skipsHiddenFiles) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // PHASE 1 — names only, via readdir. Paints the folder essentially
            // immediately even on shares where attribute reads crawl (a DFS-heavy
            // share measured 429 ms for 669 names vs 38 s for 41 entries WITH
            // attributes). Skipped when a detailed seed is already on screen, so we
            // never replace real sizes/dates with blanks.
            if !hadSeed {
                let quick = Browser.namesOnlyItems(dir, showHidden: showHidden)
                if !quick.isEmpty {
                    guard let self, gen == self.loadGeneration else { return }
                    let sorted = quick
                    DispatchQueue.main.async { [weak self] in
                        guard let self, gen == self.loadGeneration else { return }
                        self.items = sorted
                        self.busy = true; self.busyText = "Loading details…"
                        self.slowNetwork = false; self.networkStalled = false
                        self.updateStatus()
                    }
                }
            }
            // PHASE 2 — the full metadata pass. Slow on some shares, but the list is
            // already usable while it runs, and it replaces phase 1 when it lands.
            func enumerate() -> [FileItem] {
                guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: opts) else { return [] }
                var out: [FileItem] = []
                var sinceFlush = 0
                while let u = en.nextObject() as? URL {
                    guard let self, gen == self.loadGeneration else { return out }
                    out.append(Browser.item(from: u, try? u.resourceValues(forKeys: Set(keys))))
                    sinceFlush += 1
                    if !hadSeed, sinceFlush >= 100 {
                        sinceFlush = 0
                        let snap = out
                        DispatchQueue.main.async { [weak self] in
                            guard let self, gen == self.loadGeneration else { return }
                            // Never let a partial detail pass SHRINK what's on screen:
                            // phase 1 already listed the whole folder, so a 100-item
                            // snapshot of a 669-item folder must not replace it.
                            guard snap.count >= self.items.count else { return }
                            self.items = snap; self.busy = false; self.busyText = ""; self.slowNetwork = false; self.networkStalled = false; self.updateStatus()
                        }
                    }
                }
                return out
            }
            let t0 = DispatchTime.now()
            var result = enumerate()
            // DFS junctions auto-mount on first access and can read empty; retry once.
            if result.isEmpty {
                Thread.sleep(forTimeInterval: 1.5)
                guard let self, gen == self.loadGeneration else { return }
                result = enumerate()
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            navLog.log("network bulk enumerate \(result.count, privacy: .public) items in \(Int(ms), privacy: .public) ms — \(dir.lastPathComponent, privacy: .public)")
            guard let self, gen == self.loadGeneration else { return }
            let committed = result
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.loadGeneration else { return }
                // A transient empty read (folder briefly unreachable) must not wipe a
                // seed we're already showing, nor overwrite the persisted cache.
                if committed.isEmpty && hadSeed { return }
                // Same protection for the final result: if the detail pass came back
                // with fewer entries than phase 1 already showed (aborted, or a share
                // that stopped answering mid-way), keep the fuller list.
                if committed.count < self.items.count, !self.items.isEmpty {
                    self.busy = false; self.busyText = ""; self.slowNetwork = false
                    self.updateFreeSpace(); self.updateStatus(); return
                }
                Browser.dirCache[cacheKey] = committed
                if !committed.isEmpty { DiskCache.put(cacheKey, committed, dirModified: dirMtime) }   // store folder mtime for conditional revalidation
                self.items = committed
                self.busy = false; self.busyText = ""; self.slowNetwork = false
                self.updateFreeSpace(); self.updateStatus()
            }
        }
    }

    func updateFreeSpace() {
        // Volume-capacity read is a stat that can block over SMB — do it off-main.
        let url = currentURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            let text: String
            if let avail = vals?.volumeAvailableCapacityForImportantUsage, avail > 0 {
                text = "\(ByteCountFormatter.string(fromByteCount: avail, countStyle: .file)) available"
            } else if let avail = vals?.volumeAvailableCapacity, let total = vals?.volumeTotalCapacity, total > 0 {
                text = "\(ByteCountFormatter.string(fromByteCount: Int64(avail), countStyle: .file)) available"
            } else { text = "" }
            DispatchQueue.main.async { guard let self, self.currentURL == url else { return }; self.freeSpace = text }
        }
    }

    // Click selection with modifiers, like Finder/Explorer:
    //  • plain click → select just this item (and set the range anchor)
    //  • ⌘-click → toggle this item in/out of the selection
    //  • ⇧-click → select the range from the anchor to this item
    var selectionAnchor: String?
    func click(_ id: String, modifiers: NSEvent.ModifierFlags) {
        // Clicking in the file view drops keyboard focus from the address/search
        // fields, so typing next goes to type-to-select instead of the address bar.
        NotificationCenter.default.post(name: .navigatorResignFields, object: nil)
        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            selectionAnchor = id
        } else if modifiers.contains(.shift), let anchor = selectionAnchor {
            let vis = orderedVisibleItems()
            if let a = vis.firstIndex(where: { $0.id == anchor }),
               let b = vis.firstIndex(where: { $0.id == id }) {
                selection = Set(vis[min(a, b)...max(a, b)].map { $0.id })
            } else { selection = [id]; selectionAnchor = id }
        } else {
            selection = [id]; selectionAnchor = id
        }
        updateStatus()
    }

    // Windows Explorer / Finder-style rename: click a name, then click it again
    // (not a double-click, which opens it) to edit in place. Callers pass every
    // single (clickCount == 1) tap on a name label here — a double-click's second
    // press reports clickCount == 2 and is filtered out by the caller before this
    // is ever reached, so it's never mistaken for a slow second click. Tracked by
    // "last tap was on this exact id, a deliberate pause ago" rather than by
    // selection state, since Table/Icon/Gallery all update `selection` at slightly
    // different points relative to the tap and comparing against selection would
    // make the very click that first selects an item indistinguishable from a
    // genuine second click on an already-selected one.
    func handleNameTap(_ id: String) {
        let now = Date()
        defer { lastNameClick = (id, now) }
        guard let last = lastNameClick, last.id == id else { return }
        let gap = now.timeIntervalSince(last.at)
        guard gap > 0.35, gap < 1.4 else { return }
        renamingID = id
    }

    func updateStatus() {
        let count = items.count
        if selection.isEmpty {
            status = "\(count) item\(count == 1 ? "" : "s")"
        } else {
            let sel = items.filter { selection.contains($0.id) }
            let bytes = sel.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
            status = "\(sel.count) of \(count) selected  —  \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        }
    }

    // MARK: Keyboard navigation

    func openSelection() {
        let chosen = items.filter { selection.contains($0.id) }
        if chosen.count == 1, let only = chosen.first { openItem(only, self); return }
        for it in chosen { NSWorkspace.shared.open(it.url) }
    }
    func moveSelection(dx: Int = 0, dy: Int = 0) {
        let list = orderedVisibleItems()
        guard !list.isEmpty else { return }
        let cols = max(1, gridColumns)
        let cur = selection.first.flatMap { id in list.firstIndex { $0.id == id } }
        var idx: Int
        if let c = cur { idx = c + dx + dy * cols } else { idx = 0 }
        idx = max(0, min(list.count - 1, idx))
        let item = list[idx]
        selection = [item.id]; keyboardScrollID = item.id; updateStatus()
    }
    /// Tab / ⇧Tab move the selection one item along the CURRENT visible order.
    ///
    /// Deliberately not routed through moveSelection: that one is grid geometry
    /// (it multiplies dy by gridColumns and CLAMPS at both ends), which is right
    /// for arrow keys in icon view and wrong here — Tab is a flat walk of the
    /// sorted/grouped list that has to wrap, and it has to behave identically in
    /// list and gallery view where there is no meaningful column count.
    func cycleSelection(_ delta: Int) {
        let list = orderedVisibleItems()
        let cur = selection.first.flatMap { id in list.firstIndex { $0.id == id } }
        guard let idx = cycledSelectionIndex(from: cur, delta: delta, count: list.count) else { return }
        let item = list[idx]
        selection = [item.id]; keyboardScrollID = item.id; updateStatus()
    }
    func typeSelect(_ s: String) {
        let now = Date()
        if now.timeIntervalSince(lastTypeAt) > 0.8 { typeBuffer = "" }
        lastTypeAt = now
        typeBuffer += s.lowercased()
        let list = orderedVisibleItems()
        let match = list.first { $0.name.lowercased().hasPrefix(typeBuffer) }
            ?? list.first { $0.name.lowercased().contains(typeBuffer) }
        if let m = match { selection = [m.id]; keyboardScrollID = m.id; updateStatus() }
    }

    func navigate(to url: URL, recordHistory: Bool = true) {
        // No main-thread fileExists here: callers pass validated directories
        // (sidebar/breadcrumb/openItem all check), and submitPath validates its
        // own input off-main. load() enumerates on a background thread and simply
        // shows an empty folder if the path is gone — so navigation never blocks
        // on a stat over a slow SMB mount.
        if recordHistory { backStack.append(currentURL); forwardStack.removeAll() }
        searchText = ""; isSearching = false; searchQuery?.stop(); searchQuery = nil
        // NOTE: navigating does NOT record a recent folder — "Recent Folders" is
        // only folders you've worked in (created/saved/moved/renamed files).
        // .navigatorDidNavigate is posted by currentURL's own didSet, so Back/Forward
        // and any future direct assignment get it too.
        currentURL = url
        load()
    }

    // Navigate to a sidebar favorite. For a network drive whose volume isn't
    // mounted (e.g. after a reboot or VPN reconnect), mount it directly via
    // NetFS — NOT NSWorkspace.open(smb://…), which hands the mount to Finder and
    // pops Finder's "Connecting to…" window. NetFSMountURLSync mounts silently to
    // /Volumes using keychain creds (its own auth sheet only if none are stored)
    // and returns the real mountpoint, so no polling/guessing is needed.
    func openFavorite(_ path: String, mountURL: String?) {
        // Clicking a drive is asking for it back, which cancels an earlier Disconnect.
        NetworkReconnector.shared.allowReconnect(mountURL: mountURL)
        if fm.fileExists(atPath: path) { navigate(to: URL(fileURLWithPath: path)); return }
        guard let m = mountURL, let smb = URL(string: m) else { NSSound.beep(); return }
        busy = true; busyText = "Connecting to \(smb.host ?? "server")…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let mounted = Browser.mountShare(smb)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false; self.busyText = ""
                // 1) Stored path present (share mounted where we expected)? Go there.
                if self.fm.fileExists(atPath: path) {
                    self.navigate(to: URL(fileURLWithPath: path))
                } else if let mp = mounted {
                    // 2) The share mounted somewhere else than the stored path — a
                    // clash (…-1), or the coworker had it mounted under a different
                    // name. Re-anchor the favorite's sub-path onto the ACTUAL
                    // mountpoint so we still land inside the target folder.
                    let rel = Browser.shareRelativePath(path)
                    let target = rel.isEmpty ? mp : (mp as NSString).appendingPathComponent(rel)
                    if self.fm.fileExists(atPath: target) {
                        self.navigate(to: URL(fileURLWithPath: target))
                    } else {
                        self.navigate(to: URL(fileURLWithPath: mp))   // last resort: share root
                    }
                } else { NSSound.beep() }
            }
        }
    }
    // The favorite path's location beneath its volume root:
    // "/Volumes/cifs-games/Games/ArtSource" -> "Games/ArtSource". Used to
    // re-anchor onto the actual mountpoint when a share mounts somewhere
    // unexpected. Empty if the favorite IS the volume root.
    static func shareRelativePath(_ path: String) -> String {
        PathRules.shareRelativePath(path)                   // tested in NavigatorCoreTests
    }
    // Mount an SMB/AFP URL directly, without Finder. Blocking — call off the main
    // thread. Returns the real mountpoint path (nil on failure). NetFS uses stored
    // keychain creds and shows its own auth sheet only when none exist.
    // The network share backing whatever volume `url` sits on, read from the mount
    // table: f_mntfromname "//user@host/share" → smb://user@host/share, plus the
    // volume's mountpoint. nil for local disks.
    static func shareMountInfo(for url: URL) -> (volume: String, share: URL)? {
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return nil }
        let from = withUnsafeBytes(of: &s.f_mntfromname) { raw -> String in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let on = withUnsafeBytes(of: &s.f_mntonname) { raw -> String in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        guard from.hasPrefix("//"), let u = URL(string: "smb:" + from) else { return nil }
        return (on, u)
    }

    // Force-unmount a wedged share and mount it again, then return to the same
    // folder. This is the "Reconnect" button: a dead SMB session can't be recovered
    // any other way, and doing it here means no trip to Finder.
    func reconnectShare() {
        guard let info = Browser.shareMountInfo(for: currentURL) else { NSSound.beep(); return }
        // An explicit repair also means "I want this share", clearing any Disconnect.
        NetworkReconnector.shared.allowReconnect(mountURL: info.share.absoluteString)
        // Remember where we were, relative to the volume, so we can come back.
        let rel = currentURL.path.hasPrefix(info.volume)
            ? String(currentURL.path.dropFirst(info.volume.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : ""
        networkStalled = false
        busy = true; busyText = "Reconnecting to \(info.share.host ?? "server")…"
        loadGeneration += 1                     // abandon the stalled enumeration
        items = []
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let du = Process()
            du.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            du.arguments = ["unmount", "force", info.volume]
            try? du.run(); du.waitUntilExit()
            let mp = Browser.mountShare(info.share)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false; self.busyText = ""; self.slowNetwork = false
                guard let mp else {
                    reportFileError("Couldn’t reconnect to “\(info.share.host ?? "the server")”",
                                    "The share didn’t mount. Check your VPN connection and try again.",
                                    permissionHint: false)
                    return
                }
                // The share can come back under a different mountpoint (…-1) if a
                // stale folder is holding the old name — re-anchor onto the new one.
                let target = rel.isEmpty ? mp : (mp as NSString).appendingPathComponent(rel)
                Browser.invalidateCache(target)
                self.navigate(to: URL(fileURLWithPath: self.fm.fileExists(atPath: target) ? target : mp))
            }
        }
    }

    // Is this share already in the mount table? MNT_NOWAIT is essential: a wedged
    // SMB mount would otherwise block us here. Compares the share path so
    // "smb://host/Games" matches "//user@host/Games" regardless of the user part or
    // which /Volumes name it landed on.
    static func mountedPath(forShare url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let share = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard !share.isEmpty else { return nil }
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let buf else { return nil }
        for i in 0..<Int(n) {
            var fs = buf[i]
            let from = withUnsafeBytes(of: &fs.f_mntfromname) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }.lowercased()
            guard from.hasPrefix("//") else { continue }
            // "//user@host/share" → host + share
            let body = String(from.dropFirst(2))
            let hostPart = body.split(separator: "/").first.map(String.init) ?? ""
            let sharePart = body.split(separator: "/").dropFirst().joined(separator: "/")
            let bareHost = hostPart.contains("@") ? String(hostPart.split(separator: "@").last!) : hostPart
            if sharePart == share, bareHost == host || bareHost.hasPrefix(host + ".") || host.hasPrefix(bareHost + ".") {
                let on = withUnsafeBytes(of: &fs.f_mntonname) { raw in
                    String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                return on
            }
        }
        return nil
    }

    // Mount WITHOUT any UI. Used by the background auto-reconnect: it must never
    // pop an authentication sheet out of nowhere, so it only succeeds when the
    // credentials are already in the keychain. Clicking a favorite still uses the
    // interactive mountShare below.
    static func mountShareSilently(_ url: URL) -> String? {
        let opts = NSMutableDictionary()
        opts[kNAUIOptionKey] = kNAUIOptionNoUI
        var pts: Unmanaged<CFArray>?
        guard NetFSMountURLSync(url as CFURL, nil, nil, nil, opts as CFMutableDictionary, nil, &pts) == 0 else { return nil }
        return (pts?.takeRetainedValue() as? [String])?.first
    }

    static func mountShare(_ url: URL) -> String? {
        let openOpts = NSMutableDictionary()
        openOpts[kNAUIOptionKey] = kNAUIOptionAllowUI
        var pts: Unmanaged<CFArray>?
        let rc = NetFSMountURLSync(url as CFURL, nil, nil, nil,
                                   openOpts as CFMutableDictionary, nil, &pts)
        guard rc == 0 else { return nil }
        return (pts?.takeRetainedValue() as? [String])?.first
    }

    func goUp() {
        let parent = currentURL.deletingLastPathComponent()
        if parent.path != currentURL.path { navigate(to: parent) }
    }
    func goBack() {
        guard let prev = backStack.popLast() else { NSSound.beep(); return }
        forwardStack.append(currentURL); currentURL = prev; load()
    }
    func goForward() {
        guard let next = forwardStack.popLast() else { NSSound.beep(); return }
        backStack.append(currentURL); currentURL = next; load()
    }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func submitPath() {
        var p = pathText.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("~") { p = (p as NSString).expandingTildeInPath }
        guard !p.isEmpty else { pathText = addressString(for: currentURL); return }
        // Validate the typed path off the main thread — a fileExists over SMB can
        // block. Resolve Google Drive path forms, then act on the result on main.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var path = p
            if !FileManager.default.fileExists(atPath: path), let resolved = Browser.resolveGoogleDrivePath(path) { path = resolved }
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            DispatchQueue.main.async {
                guard let self else { return }
                if exists, isDir.boolValue { self.navigate(to: URL(fileURLWithPath: path)) }
                else if exists { NSWorkspace.shared.open(URL(fileURLWithPath: path)); self.pathText = self.addressString(for: self.currentURL) }
                else { NSSound.beep(); self.pathText = self.addressString(for: self.currentURL) }
            }
        }
    }

    func breadcrumbs() -> [(name: String, url: URL)] {
        if isRecents { return [("Recents", currentURL)] }
        var crumbs: [(String, URL)] = []
        var u = currentURL.standardizedFileURL
        var guardCount = 0
        while guardCount < 256 {
            guardCount += 1
            let name = u.path == "/" ? "Macintosh HD" : u.lastPathComponent
            crumbs.append((name, u))
            if u.path == "/" || u.path.isEmpty { break }
            let parent = u.deletingLastPathComponent().standardizedFileURL
            if parent.path == u.path { break }
            u = parent
        }
        return crumbs.reversed()
    }

    func revealInFinder(_ ids: Set<String>) {
        let urls = items.filter { ids.contains($0.id) }.map { $0.url }
        if urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting([currentURL]) }
        else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    func copyPath(_ ids: Set<String>) {
        copyToClipboard(pathStrings(ids).joined(separator: "\n"))
    }

    /// The URLs behind an id set, in listing order.
    func urls(_ ids: Set<String>) -> [URL] { items.filter { ids.contains($0.id) }.map { $0.url } }

    /// Paths for a "Copy …" item, falling back to the CURRENT FOLDER when nothing is
    /// selected — that's what the blank-area menu means by "copy the path", and every
    /// copy variant has to agree on it or they contradict each other on an empty click.
    private func pathStrings(_ ids: Set<String>) -> [String] {
        let paths = urls(ids).map { $0.path }
        return paths.isEmpty ? [currentURL.path] : paths
    }

    /// One place that touches the pasteboard for text, so the half-dozen "Copy …"
    /// items can't drift into forgetting clearContents() (which silently appends to
    /// whatever was there instead of replacing it).
    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // The quoting/escaping rules themselves live in NavigatorCore's PathText (tested
    // there); these just decide WHAT to hand them.
    func copyQuotedPath(_ ids: Set<String>) { copyToClipboard(PathText.quoted(pathStrings(ids))) }
    func copyFileURL(_ ids: Set<String>) { copyToClipboard(PathText.fileURLs(pathStrings(ids))) }
    func copyParentPath(_ ids: Set<String>) {
        let parents = urls(ids).map { $0.deletingLastPathComponent().path }
        copyToClipboard((parents.isEmpty ? [currentURL.deletingLastPathComponent().path] : parents)
                            .joined(separator: "\n"))
    }
    func copyNameWithoutExtension(_ ids: Set<String>) {
        let names = items.filter { ids.contains($0.id) }.map { $0.name }
        copyToClipboard(PathText.namesWithoutExtension(names.isEmpty ? [currentURL.lastPathComponent] : names))
    }
    func copyMarkdownLink(_ ids: Set<String>) {
        let sel = items.filter { ids.contains($0.id) }.map { (name: $0.name, path: $0.url.path) }
        copyToClipboard(PathText.markdownLinks(sel.isEmpty
            ? [(name: currentURL.lastPathComponent, path: currentURL.path)] : sel))
    }

    // Refresh the listing and, once it reloads with the file(s) present, select +
    // scroll to them (used to highlight just-produced "_rmbg" results).
    /// Show `url` selected IN Navigator, navigating to its folder first if we aren't
    /// already there. Finder's "Reveal Original" hands you off to Finder; doing that
    /// from a file manager is an odd thing to do, so this stays in the app.
    func revealInApp(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        pendingRevealPaths = [url.path]
        if currentURL.standardizedFileURL.path == dir.standardizedFileURL.path { refresh() }
        else { navigate(to: dir) }
    }
    func refreshAndReveal(_ url: URL) { refreshAndReveal([url]) }
    func refreshAndReveal(_ urls: [URL]) {
        pendingRevealPaths = urls.map { $0.path }
        refresh()
    }

    // Remove BG: Photoshop keys the selected image(s) and writes "<name>_rmbg.png"
    // alongside each; then we refresh and highlight the new file(s). Works for one
    // selected image or many (e.g. 20 of 300).
    func removeBackground(_ ids: Set<String>) {
        let urls = items.filter { ids.contains($0.id) && !$0.isDirectory && isImageFile($0.url) }.map { $0.url }
        guard !urls.isEmpty else { NSSound.beep(); return }
        if urls.count == 1 {
            removeBackgroundForImage(urls[0]) { [weak self] out in self?.refreshAndReveal(out) }
        } else {
            removeBackgroundForImages(urls) { [weak self] outs in self?.refreshAndReveal(outs) }
        }
    }

    // Quick Export as PNG: Photoshop flattens each selected PSD/PSB into
    // "<name>.png" alongside it (uniqued, never overwriting an existing PNG);
    // then we refresh and highlight the new file(s). One or many.
    func exportPNG(_ ids: Set<String>) {
        let urls = items.filter { ids.contains($0.id) && !$0.isDirectory && isPhotoshopDocument($0.url) }.map { $0.url }
        guard !urls.isEmpty else { NSSound.beep(); return }
        exportPSDsToPNG(urls) { [weak self] outs in self?.refreshAndReveal(outs) }
    }

    // Prep for AI — Fill Background: fit each selected image to the nearest NB2
    // aspect ratio, pad 20%, fill with `color`, write "<name>_bgfill.png". Native
    // (no Adobe app); originals untouched.
    func fillBackground(_ ids: Set<String>, _ c: AIPrepColor, ratio: Double?) {
        let urls = items.filter { ids.contains($0.id) && !$0.isDirectory && isImageFile($0.url) }.map { $0.url }
        guard !urls.isEmpty else { NSSound.beep(); return }
        fillBackgroundForImages(urls, color: c.color, suffix: c.suffix, ratio: ratio) { [weak self] outs in self?.refreshAndReveal(outs) }
    }

    // Upscale the selected image(s) via fal.ai (Topaz) → "<name>_upscaled.png".
    func upscale(_ ids: Set<String>, _ option: UpscaleOption) {
        let urls = items.filter { ids.contains($0.id) && !$0.isDirectory && isImageFile($0.url) }.map { $0.url }
        guard !urls.isEmpty else { NSSound.beep(); return }
        upscaleImagesViaFal(urls, option: option) { [weak self] outs in self?.refreshAndReveal(outs) }
    }

    // Upscale the selected image(s) via Vertex/Imagen 4 → "<name>_upscaled.png".
    func upscaleImagen(_ ids: Set<String>, factor: Int) {
        let urls = items.filter { ids.contains($0.id) && !$0.isDirectory && isImageFile($0.url) }.map { $0.url }
        guard !urls.isEmpty else { NSSound.beep(); return }
        upscaleImagesViaImagen(urls, factor: factor) { [weak self] outs in self?.refreshAndReveal(outs) }
    }

    // Chroma Key BG (After Effects) on the selected PNG(s) — one or many.
    func chromaKeyBackground(_ ids: Set<String>) {
        let urls = items.filter { ids.contains($0.id) && !$0.isDirectory && $0.url.pathExtension.lowercased() == "png" }.map { $0.url }
        guard !urls.isEmpty else { NSSound.beep(); return }
        if urls.count == 1 {
            chromaKeyForImage(urls[0]) { [weak self] out in self?.refreshAndReveal(out) }
        } else {
            chromaKeyForImages(urls) { [weak self] outs in self?.refreshAndReveal(outs) }
        }
    }

    // Batch Chroma Key BG (folder): AE keys every PNG in the folder, writing
    // transparent "<name>_rmbg" PNGs into a "_rmbg" subfolder. Originals untouched.
    func batchChromaKeyBackground(_ ids: Set<String>) {
        guard let id = ids.first, let it = items.first(where: { $0.id == id }), it.isDirectory else { NSSound.beep(); return }
        batchChromaKeyFolder(it.url) { [weak self] in self?.refresh() }
    }

    // Batch Remove BG (folder): Photoshop opens each ORIGINAL image (recursively,
    // skipping EN folders and existing "_rmbg" outputs) and writes a keyed
    // "<name>_rmbg.png" next to it. No pre-duplication — originals are never
    // written.
    func batchRemoveBackground(_ ids: Set<String>) {
        guard let id = ids.first, let it = items.first(where: { $0.id == id }), it.isDirectory else { NSSound.beep(); return }
        batchRemoveBackgroundFolder(it.url) { [weak self] in self?.refresh() }
    }

    // Batch upscale every image in the selected folder → "<name>_upscaled.png".
    func batchUpscale(_ ids: Set<String>, _ option: UpscaleOption) {
        guard let id = ids.first, let it = items.first(where: { $0.id == id }), it.isDirectory else { NSSound.beep(); return }
        batchUpscaleFolderViaFal(it.url, option: option) { [weak self] in self?.refresh() }
    }
    func batchUpscaleImagen(_ ids: Set<String>, factor: Int) {
        guard let id = ids.first, let it = items.first(where: { $0.id == id }), it.isDirectory else { NSSound.beep(); return }
        batchUpscaleFolderViaImagen(it.url, factor: factor) { [weak self] in self?.refresh() }
    }
    // What the address bar shows: inside Google Drive, the clean username-free
    // "Google Drive/Shared drives/…" form (directly shareable — a coworker pastes
    // it into their address bar and it resolves to their own account). Elsewhere,
    // the real local path.
    func addressString(for url: URL) -> String { googleDrivePortablePath(url) ?? url.path }
    func copyDisplayedPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(addressString(for: currentURL), forType: .string)
    }
    // The two selected images (in on-screen order) for Swipe Compare, else nil.
    func imagePair(_ ids: Set<String>) -> (URL, URL)? {
        let imgs = orderedVisibleItems().filter { ids.contains($0.id) && !$0.isDirectory && isImageFile($0.url) }.map { $0.url }
        return imgs.count == 2 ? (imgs[0], imgs[1]) : nil
    }
    // True when the selection lives inside Google Drive (has a Drive item ID).
    func isGoogleDriveSelection(_ ids: Set<String>) -> Bool {
        guard let id = ids.first, let it = items.first(where: { $0.id == id }) else { return false }
        // Must actually LIVE in Google Drive — not merely carry the drivefs xattr,
        // which files copied OUT of Drive keep (that made the Drive menu appear on
        // local copies). Path check first, then the item-id.
        return it.url.path.contains("/Library/CloudStorage/GoogleDrive-") && googleDriveItemID(it.url) != nil
    }
    // Copy a shareable drive.google.com link (resolves for anyone with access,
    // no username/mount in it) instead of a machine-specific local path.
    func copyGoogleDriveLink(_ ids: Set<String>) {
        let links = items.filter { ids.contains($0.id) }
            .compactMap { googleDriveURL(for: $0.url, isDirectory: $0.isDirectory)?.absoluteString }
        guard !links.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }
    func openGoogleDriveLink(_ ids: Set<String>) {
        let urls = items.filter { ids.contains($0.id) }
            .compactMap { googleDriveURL(for: $0.url, isDirectory: $0.isDirectory) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        for u in urls { NSWorkspace.shared.open(u) }
    }

    // Right-clicking a row acts on the whole selection when that row is part of a
    // multi-selection, otherwise just that row (what the BG-removal menus do).
    func rowSelection(_ id: String) -> Set<String> {
        (selection.contains(id) && selection.count > 1) ? selection : [id]
    }

    // Is everything in this selection already stored locally (available offline)?
    // Drives which ONE of the two Drive availability items is offered, so they're
    // never both shown. A file answers for itself; a FOLDER's own status always
    // reads "current" no matter what's inside, so we judge it by a small sample of
    // its direct children. Results are cached briefly because this is evaluated
    // while a context menu is being built.
    private static var offlineStateCache: [String: (value: Bool, at: Date)] = [:]
    func driveSelectionIsOffline(_ ids: Set<String>) -> Bool {
        let urls = items.filter { ids.contains($0.id) }.map { $0.url }
        guard !urls.isEmpty else { return false }
        func isLocal(_ u: URL) -> Bool {
            guard let r = try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]) else { return true }
            return r.ubiquitousItemDownloadingStatus != .notDownloaded
        }
        for u in urls {
            let key = u.path
            if let c = Browser.offlineStateCache[key], Date().timeIntervalSince(c.at) < 5 {
                if !c.value { return false }
                continue
            }
            var local: Bool
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                // Sample a handful of direct files: any online-only child means the
                // folder isn't fully offline, so "Make available offline" is the
                // useful action. ponytail: bounded sample, not a recursive walk —
                // a full walk would stall the menu on big Drive folders.
                let kids = (try? FileManager.default.contentsOfDirectory(
                    at: u, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                let files = kids.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true }
                local = files.isEmpty ? true : files.prefix(12).allSatisfy(isLocal)
            } else {
                local = isLocal(u)
            }
            Browser.offlineStateCache[key] = (local, Date())
            if !local { return false }
        }
        return true
    }

    // "Make available offline" / "Make available online only" for Drive items,
    // via the standard File Provider APIs (verified against Google Drive):
    // startDownloadingUbiquitousItem materialises a file, evictUbiquitousItem
    // drops the local copy (content stays in Drive — reversible either way).
    // Folders are walked recursively since the APIs act per file. Runs off the
    // main thread with the shared non-blocking progress line.
    func setDriveAvailability(_ ids: Set<String>, offline: Bool) {
        let roots = items.filter { ids.contains($0.id) }.map { $0.url }
        guard !roots.isEmpty else { NSSound.beep(); return }
        let label = offline ? "Making available offline" : "Making online only"
        DispatchQueue.main.async { BGJobProgress.shared.start(label, total: 0) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            // Expand folders to their files (skipping hidden housekeeping entries).
            var files: [URL] = []
            for r in roots {
                if (try? r.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    if let en = fm.enumerator(at: r, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                        for case let u as URL in en
                        where (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true { files.append(u) }
                    }
                } else {
                    files.append(r)
                }
            }
            guard !files.isEmpty else {
                DispatchQueue.main.async { BGJobProgress.shared.finish("Nothing to change") }; return
            }
            var done = 0; var errors: [String] = []
            for (i, u) in files.enumerated() {
                if i % 10 == 0 {
                    let n = i + 1, total = files.count
                    DispatchQueue.main.async { BGJobProgress.shared.label = "\(label) — \(n) of \(total)" }
                }
                do {
                    if offline { try fm.startDownloadingUbiquitousItem(at: u) }
                    else { try fm.evictUbiquitousItem(at: u) }
                    done += 1
                } catch {
                    // Google Drive refuses eviction (File Provider error -2008) for
                    // items it insists on keeping local — e.g. pinned for offline use
                    // or a mirrored folder. Say so instead of showing "couldn't be saved".
                    let ns = error as NSError
                    let inner = (ns.userInfo["NSUnderlyingError"] as? NSError)?.code ?? ns.code
                    let msg = inner == -2008
                        ? "Google Drive is keeping this file on this Mac (pinned for offline use, or the folder is mirrored). Turn it off in Google Drive to free the space."
                        : error.localizedDescription
                    errors.append("\(u.lastPathComponent): \(msg)")
                }
            }
            DispatchQueue.main.async {
                let verb = offline ? "Downloading" : "Made online only:"
                BGJobProgress.shared.finish(offline ? "\(verb) \(done) file\(done == 1 ? "" : "s")…"
                                                    : "\(verb) \(done) file\(done == 1 ? "" : "s")")
                if !errors.isEmpty {
                    showBGSummary(app: offline ? "Make available offline" : "Make online only",
                                  done: done, total: files.count, errors: errors,
                                  verb: offline ? "downloaded" : "evicted")
                }
                // Drop the cached offline-state decisions and re-read the badges, so
                // the menu offers the other action and the icons update right away.
                Browser.offlineStateCache.removeAll()
                self?.badgeGeneration += 1
                self?.silentRefresh()
            }
        }
    }
    // Copy a clean, username-free path like "Google Drive/Shared drives/…/NB2 pass"
    // (matches the breadcrumb). It carries no home folder or account email, and
    // Navigator's address bar resolves it against the local Drive account — so a
    // coworker can paste it and land in the same shared-drive location.
    func copyGoogleDrivePath(_ ids: Set<String>) {
        let paths = items.filter { ids.contains($0.id) }.compactMap { googleDrivePortablePath($0.url) }
        let text = paths.isEmpty ? (googleDrivePortablePath(currentURL) ?? "") : paths.joined(separator: "\n")
        guard !text.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    // Resolve any Google Drive path form typed/pasted into the address bar — or found
    // on the clipboard by the Open/Save dialog bridge — onto THIS Mac's Drive account.
    // The forms and the reasoning are in PathRules.googleDrivePath; the only thing this
    // adds is finding the local account folder, which no pure rule can know.
    // Returns nil if it isn't a Drive path.
    static func resolveGoogleDrivePath(_ input: String) -> String? {
        guard let root = googleDriveAccountRoot() else { return nil }
        return PathRules.googleDrivePath(input, accountRoot: root)
    }
    func copyName(_ ids: Set<String>) {
        let names = items.filter { ids.contains($0.id) }.map { $0.name }
        guard !names.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
    }
    // Undo/redo for any operation whose result is a set of NEW items — New Folder,
    // New Text File, Duplicate, drag-Copy, Compress, Extract, aliases, symlinks.
    // Undo bins them and redo restores those exact items from the Trash, so anything
    // the user put inside a new folder before pressing ⌘Z survives the round trip.
    func pushCreation(_ desc: String, _ created: [URL]) {
        var restores: [(from: URL, to: URL)] = []
        UndoStack.shared.push(desc, undo: { [weak self] in
            let r = trashItems(created)
            restores = r.restores
            self?.load()
            return r.problem
        }, redo: { [weak self] in
            let problem = restoreItems(restores)
            self?.load()
            return problem
        })
    }

    // Tags are an xattr, not a file, so writing a snapshot back IS the whole undo and
    // the whole redo — the two halves are the same call with a different snapshot.
    private func pushTags(_ before: [(URL, [String])], _ after: [(URL, [String])]) {
        let apply: ([(URL, [String])]) -> UndoAction = { snapshot in
            { [weak self] in
                // setxattr on a vanished file fails mutely, so check first: otherwise
                // undoing a tag on a file that Finder deleted looks like it worked.
                var missing: [String] = []
                for (u, tags) in snapshot {
                    guard FileManager.default.fileExists(atPath: u.path) else {
                        missing.append("• \(u.lastPathComponent)"); continue
                    }
                    Browser.writeTags(u, tags)
                }
                self?.load()
                return missing.isEmpty ? nil
                     : "These items are no longer where they were:\n" + missing.prefix(5).joined(separator: "\n")
            }
        }
        UndoStack.shared.push("Tag", undo: apply(before), redo: apply(after))
    }

    func moveToTrash(_ ids: Set<String>) {
        // Already in the Trash — trashItem would either fail or shuffle the item
        // around inside the Trash. The Trash view offers Delete Immediately instead,
        // which is destructive and must be an explicit choice, never what ⌘⌫ does.
        guard !isTrash else { NSSound.beep(); return }
        let urls = items.filter { ids.contains($0.id) }.map { $0.url }
        guard !urls.isEmpty else { NSSound.beep(); return }
        if Prefs.confirmTrash {
            let a = NSAlert(); a.alertStyle = .warning
            a.messageText = urls.count == 1
                ? "Move “\(urls[0].lastPathComponent)” to the Trash?"
                : "Move \(urls.count) items to the Trash?"
            a.addButton(withTitle: "Move to Trash"); a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        var restores: [(from: URL, to: URL)] = []   // where it landed in the Trash → where it came from
        var failures: [(url: URL, reason: String)] = []
        for u in urls {
            var out: NSURL?
            do { try fm.trashItem(at: u, resultingItemURL: &out); if let t = out as URL? { restores.append((from: t, to: u)) } }
            catch { failures.append((u, error.localizedDescription)) }
        }
        if !restores.isEmpty {
            TrashOrigins.record(restores)   // powers Put Back in the Trash view; see trashItems()
            RecentFolders.shared.record(currentURL)
            UndoStack.shared.push("Move to Trash", undo: { [weak self] in
                let problem = restoreItems(restores)
                // The items are out of the Trash again, so their origin records name
                // paths that no longer exist. Left behind they would be handed to the
                // next thing that lands on the same Trash path (same name, same
                // collision suffix) as ITS origin — a Put Back to the wrong folder.
                TrashOrigins.forget(restores.map { $0.from.path })
                self?.load()
                return problem
            }, redo: { [weak self] in
                // Re-trashing lands at a DIFFERENT path each round (the Trash renames
                // collisions), so the undo half has to be re-pointed at where the items
                // actually went this time.
                let r = trashItems(restores.map { $0.to })
                restores = r.restores
                self?.load()
                return r.problem
            })
        }
        // Surface failures instead of silently doing nothing (e.g. protected
        // folders like ~/Pictures need Full Disk Access to trash).
        if !failures.isEmpty {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = failures.count == 1
                ? "“\(failures[0].url.lastPathComponent)” couldn't be moved to the Trash"
                : "\(failures.count) items couldn't be moved to the Trash"
            a.informativeText = (failures.first?.reason ?? "")
                + "\n\nItems in protected folders (like Pictures, Documents, or Desktop) may need Navigator to have Full Disk Access — see the Navigator menu → “Grant Full Disk Access…”."
            a.addButton(withTitle: "OK")
            a.runModal()
        }
        Browser.invalidateCache(currentURL.path)
        load()
    }
    func newFolder() {
        let target = uniqueDest(currentURL, "New Folder")
        do { try fm.createDirectory(at: target, withIntermediateDirectories: false) }
        catch { reportFileError("Couldn't create the folder", error.localizedDescription); return }
        RecentFolders.shared.record(currentURL)
        pushCreation("New Folder", [target])
        // Reveal it selected and immediately ready to type a name, like Explorer/Finder.
        pendingRevealPaths = [target.path]
        pendingRenamePath = target.path
        load()
    }
    func newTextFile() { newEmptyFile("New Text File.txt", Data(), desc: "New Text File") }

    // .rtf rather than a Word format: an RTF document opens in TextEdit on a stock
    // Mac, so this can never produce a file the machine has nothing to open it with.
    // The header is the minimum RTF a reader will accept — a zero-byte .rtf makes
    // TextEdit report a corrupt file.
    func newRichTextFile() {
        let rtf = Data("{\\rtf1\\ansi\\ansicpg1252\\cocoartf2818\n{\\fonttbl}\n}\n".utf8)
        newEmptyFile("New Rich Text.rtf", rtf, desc: "New Rich Text Document")
    }

    private func newEmptyFile(_ name: String, _ contents: Data, desc: String) {
        let target = uniqueDest(currentURL, name)
        guard fm.createFile(atPath: target.path, contents: contents) else {
            reportFileError("Couldn't create “\(name)”",
                            "Navigator couldn't write to “\(currentURL.lastPathComponent)”."); return
        }
        RecentFolders.shared.record(currentURL)
        pushCreation(desc, [target])
        load()
    }

    // Finder's "New Folder with Selection": make a folder here and move the selected
    // items into it.
    //
    // The moves are done inline rather than through performTransfer, and that's the
    // point: every source is already IN this folder, so each move is a same-directory
    // rename — instant, and impossible to collide inside a folder created empty a line
    // earlier. That also lets undo be ONE step (put the items back AND remove the
    // folder we made); handing the moves to performTransfer would push its own "Move"
    // entry and leave an orphaned empty folder behind after a single ⌘Z.
    func newFolderWithSelection(_ ids: Set<String>) {
        let sources = urls(ids)
        guard !sources.isEmpty else { NSSound.beep(); return }
        let dir = currentURL
        let target = uniqueDest(dir, sources.count == 1 ? "New Folder With Item" : "New Folder With Items")
        do { try fm.createDirectory(at: target, withIntermediateDirectories: false) }
        catch { reportFileError("Couldn't create the folder", error.localizedDescription); return }
        var moved: [(from: URL, to: URL)] = []
        var failures: [String] = []
        for src in sources {
            let dest = target.appendingPathComponent(src.lastPathComponent)
            do { try fm.moveItem(at: src, to: dest); moved.append((from: src, to: dest)) }
            catch { failures.append("• \(src.lastPathComponent): \(error.localizedDescription)") }
        }
        // Nothing made it in — bin the folder rather than leaving an empty stray behind.
        if moved.isEmpty {
            try? fm.removeItem(at: target)
            reportFileError("Couldn't move the items into a new folder", failures.joined(separator: "\n"))
            return
        }
        if !failures.isEmpty {
            reportFileError(failures.count == 1 ? "1 item couldn't be moved into the new folder"
                                                : "\(failures.count) items couldn't be moved into the new folder",
                            failures.prefix(5).joined(separator: "\n"))
        }
        RecentFolders.shared.record(dir)
        UndoStack.shared.push("New Folder with Selection", undo: { [weak self] in
            let problem = restoreItems(moved.map { (from: $0.to, to: $0.from) })
            // Only remove it if it's genuinely empty: the user may have dropped
            // something else in since, and deleting that would be data loss.
            if (try? FileManager.default.contentsOfDirectory(atPath: target.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: target)
            }
            self?.load()
            return problem
        }, redo: { [weak self] in
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let problem = restoreItems(moved)
            self?.load()
            return problem
        })
        Browser.invalidateCache(dir.path)
        pendingRevealPaths = [target.path]
        pendingRenamePath = target.path
        load()
    }

    // File clipboard. STATIC, not per-Browser: the pasteboard is system-wide, and
    // every tab/window owns its own Browser. When these were instance properties,
    // cutting in one tab and pasting in another silently became a COPY — the files
    // were duplicated and the originals left behind, with no hint anything differed.
    static var cutMode = false
    // The pasteboard changeCount captured when we cut. A paste is a MOVE only if
    // the pasteboard hasn't changed since — otherwise another app (or a later
    // copy) replaced the contents and we must not move files we didn't cut.
    static var cutChangeCount = -1
    private func selectedURLs() -> [URL] { items.filter { selection.contains($0.id) }.map { $0.url } }
    // Copy/Cut act on an explicit id set when given (the right-clicked row from a
    // context menu, which may not be in `selection`), else the current selection.
    func copyFiles(_ ids: Set<String>? = nil) {
        let urls = items.filter { (ids ?? selection).contains($0.id) }.map { $0.url }
        guard !urls.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(urls as [NSURL]); Browser.cutMode = false
    }
    func cutFiles(_ ids: Set<String>? = nil) {
        let urls = items.filter { (ids ?? selection).contains($0.id) }.map { $0.url }
        guard !urls.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(urls as [NSURL])
        Browser.cutMode = true; Browser.cutChangeCount = NSPasteboard.general.changeCount
    }
    private func uniqueDest(_ dir: URL, _ name: String) -> URL {
        PathRules.uniqueDest(dir, name) { FileManager.default.fileExists(atPath: $0) }
    }

    // Name for pasting a file into its own folder: "photo.jpg" -> "photo (1).jpg",
    // then "(2)", "(3)"… (Windows/Explorer-style in-place copy).
    private func numberedCopyDest(_ dir: URL, _ name: String) -> URL {
        PathRules.numberedCopyDest(dir, name) { FileManager.default.fileExists(atPath: $0) }
    }

    // Explicit paste (⌘V / context menu). Pasting a copied item into its own
    // folder makes a numbered duplicate ("photo.jpg" -> "photo (1).jpg"); a cut
    // item pasted into its own folder is a no-op.
    func pasteFiles() {
        let urls = pasteboardURLs()
        guard !urls.isEmpty else { return }
        let isMove = Browser.cutMode && NSPasteboard.general.changeCount == Browser.cutChangeCount
        if isMove {
            let sources = urls.filter { $0.path != currentURL.path && $0.deletingLastPathComponent().path != currentURL.path }
            guard !sources.isEmpty else { return }
            performTransfer(sources, into: currentURL, move: true, resetCut: true)
        } else {
            let sources = urls.filter { $0.path != currentURL.path }   // keep same-folder → duplicated by isSelfDup
            guard !sources.isEmpty else { return }
            performTransfer(sources, into: currentURL, move: false, resetCut: true)
        }
    }

    private func pasteboardURLs() -> [URL] {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
    }

    // Background copy/move with a busy indicator (keeps the UI responsive on big
    // transfers). Used by drag-and-drop: dropping items into the folder they
    // already live in is a no-op (cancel), NOT a self-copy.
    func copyURLs(_ urls: [URL], move: Bool) {
        let sources = urls.filter { $0.path != currentURL.path && $0.deletingLastPathComponent().path != currentURL.path }
        guard !sources.isEmpty else { return }
        performTransfer(sources, into: currentURL, move: move, resetCut: true)
    }

    // A drag-drop of external files onto the current folder. Finder-style: move
    // when the sources are on the same volume as this folder, copy across
    // volumes. (This is what a plain drag into a window does.)
    // Are all of `urls` on the same volume as `dest`? Decides move-vs-copy for a
    // drop, Finder-style. Reads a volume identifier per item, which is a stat each
    // (a round trip over SMB), so callers MUST run this off the main thread — a drop
    // handler runs on main, and stalling there freezes the UI mid-interaction.
    static func sameVolume(_ urls: [URL], as dest: URL) -> Bool {
        func volID(_ u: URL) -> NSObject? {
            (try? u.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let destVol = volID(dest) else { return false }
        return urls.allSatisfy { volID($0)?.isEqual(destVol) == true }
    }

    // Should a drop MOVE, or copy? Same rule as Finder — move within a volume, copy
    // across — with one deliberate exception:
    //
    // Dragging OUT of a cloud provider is always a COPY. Google Drive and iCloud are
    // File Providers living on the local volume, so a plain volume comparison calls
    // them "same volume" and would move, deleting the original. On a shared team
    // drive that deletes it for everyone, from a drag that looks like "give me a
    // local copy". Rearranging WITHIN the provider is still a move.
    // Runs the volume stats, so call this off the main thread.
    static func shouldMove(_ urls: [URL], into dest: URL) -> Bool {
        if PathRules.leavesCloudProvider(urls, into: dest) { return false }   // tested in NavigatorCoreTests
        return sameVolume(urls, as: dest)
    }

    /// Every drop surface in the app funnels through here or `dropInto`, which is why the
    /// non-file filter lives at these two doors rather than at each of the eight callers.
    ///
    /// The app's private drag tokens are URLs that are deliberately NOT files
    /// (`navreorder:` for a sidebar reorder, `navtab:` for a tab drag), and any
    /// `.dropDestination(for: URL.self)` in the app will happily hand one over if the user
    /// releases it in the wrong place. Passed on, it reached performTransfer and raised a
    /// copy error about a file that never existed. Dropped here, a stray token does
    /// nothing at all — which is what a missed aim should do.
    func dropIntoCurrentFolder(_ incoming: [URL]) {
        let urls = incoming.filter { $0.isFileURL }
        guard !urls.isEmpty else { return }
        SpringLoader.shared.noteDrop()
        let dest = currentURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let same = Browser.shouldMove(urls, into: dest)
            DispatchQueue.main.async {
                guard let self, self.currentURL == dest else { return }   // navigated away
                self.copyURLs(urls, move: same)
            }
        }
    }

    // Drop onto a specific folder (a folder row, or another tab). Same rule as a
    // drop into the current folder: move within a volume, COPY across volumes.
    // These sites used to force move:true, so dragging a file off a network share or
    // Google Drive onto a local folder deleted the original — Finder copies.
    func dropInto(_ incoming: [URL], folder: URL) {
        let urls = incoming.filter { $0.isFileURL }   // see dropIntoCurrentFolder
        guard !urls.isEmpty else { return }
        SpringLoader.shared.noteDrop()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let same = Browser.shouldMove(urls, into: folder)
            DispatchQueue.main.async { self?.importURLs(urls, into: folder, move: same) }
        }
    }

    // "Send To" (Windows Explorer parity): COPY the selection into a well-known folder
    // or a mounted removable drive. Deliberately routed through the same transfer path
    // as paste and drag-drop, so name conflicts prompt the same way and ⌘Z undoes it
    // identically — a private copy loop here would have neither.
    func sendTo(_ ids: Set<String>, folder: URL) {
        let sources = urls(ids)
        guard !sources.isEmpty else { NSSound.beep(); return }
        importURLs(sources, into: folder, move: false)
    }

    // Import (move or copy) dropped items into a target directory (a folder row or another tab).
    func importURLs(_ urls: [URL], into dir: URL, move: Bool) {
        let sources = urls.filter { $0.deletingLastPathComponent().path != dir.path && $0.path != dir.path }
        guard !sources.isEmpty else { return }
        performTransfer(sources, into: dir, move: move, resetCut: false)
    }

    // The platform copy engine (copyfile) with byte-level progress: clones on
    // APFS (instant), byte-copies across volumes / SMB / File Provider while
    // reporting bytes, and preserves metadata — the same engine FileManager uses.
    // Used for regular files so a large copy shows a real, moving bar.
    static func copyWithProgress(_ src: URL, _ dst: URL,
                                 isCancelled: @escaping () -> Bool = { false },
                                 onBytes: @escaping (Int64) -> Void) throws {
        final class Box {
            let cb: (Int64) -> Void; let cancelled: () -> Bool
            init(_ c: @escaping (Int64) -> Void, _ x: @escaping () -> Bool) { cb = c; cancelled = x }
        }
        let boxPtr = Unmanaged.passRetained(Box(onBytes, isCancelled)).toOpaque()
        defer { Unmanaged<Box>.fromOpaque(boxPtr).release() }
        let state = copyfile_state_alloc(); defer { copyfile_state_free(state) }
        let cb: copyfile_callback_t = { what, stage, st, _, _, ctx in
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let ctx {
                let box = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue()
                var copied: off_t = 0
                _ = copyfile_state_get(st, UInt32(COPYFILE_STATE_COPIED), &copied)
                box.cb(Int64(copied))
                // Honour Cancel *during* a single large file. Without this, hitting
                // Cancel closed the window while the copy ran on to completion.
                if box.cancelled() { return COPYFILE_QUIT }
            }
            return COPYFILE_CONTINUE
        }
        _ = copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), boxPtr)
        _ = copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(cb, to: UnsafeMutableRawPointer.self))
        if copyfile(src.path, dst.path, state, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE)) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
    }

    // True when `dir` is `src` itself or lives inside it. Copying/moving a folder
    // into its own subtree must be refused: FileManager happily recurses into the
    // copy it is creating, and only stops when the path gets too long — a real test
    // produced 231 junk directories nested 1000+ characters deep before failing.
    private static func isSelfOrDescendant(_ dir: URL, of src: URL) -> Bool {
        PathRules.isSelfOrDescendant(dir, of: src)          // tested in NavigatorCoreTests
    }

    private func performTransfer(_ sources: [URL], into dir: URL, move: Bool, resetCut: Bool) {
        let fm = FileManager.default
        // Refuse folder-into-itself before touching the disk (Finder does the same).
        //
        // Note there is deliberately NO isDirectory check here. It would be a stat
        // per source on the MAIN thread — a round trip each over SMB, which is
        // exactly what the comment below says never to do, and a drop of a hundred
        // files from a slow share would freeze the UI. It's also unnecessary: a
        // destination directory can never equal, nor live inside, a FILE's path, so
        // path comparison alone can only ever flag a real folder.
        let recursive = sources.filter { Browser.isSelfOrDescendant(dir, of: $0) }
        if !recursive.isEmpty {
            let names = recursive.map { "“\($0.lastPathComponent)”" }.joined(separator: ", ")
            reportFileError(recursive.count == 1 ? "\(names) can’t be \(move ? "moved" : "copied") into itself"
                                                : "\(recursive.count) folders can’t be \(move ? "moved" : "copied") into themselves",
                            "A folder can’t be \(move ? "moved" : "copied") into itself or into one of its own subfolders. Pick a destination outside \(names).",
                            permissionHint: false)
            if resetCut { Browser.cutMode = false }
            return
        }
        // A copy whose source already lives in the destination is an in-place
        // duplicate ("paste into same folder") — it gets a numbered name silently,
        // so it's never treated as a conflict.
        func isSelfDup(_ src: URL) -> Bool { !move && src.deletingLastPathComponent().path == dir.path }
        let progress = TransferProgress()
        TransferProgressController.shared.show(progress, title: move ? "Moving…" : "Copying…")
        busy = true; busyText = move ? "Moving…" : "Copying…"
        slowNetwork = false
        // Non-blocking "responding slowly" hint if a network op stalls (e.g. a
        // hiccuping SMB mount) — shown quietly in the breadcrumb bar, not a popup.
        // Cancelled the moment the transfer finishes.
        let slowHint = DispatchWorkItem { [weak self] in self?.slowNetwork = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: slowHint)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // Conflict scan runs HERE, on the background thread — fileExists over
            // SMB is a round-trip and must never block the main thread. The prompt
            // (which must be on the main thread) hops over and back via a semaphore.
            let conflicts = sources.filter { !isSelfDup($0) && fm.fileExists(atPath: dir.appendingPathComponent($0.lastPathComponent).path) }
            let conflictNames = Set(conflicts.map { $0.lastPathComponent })
            var policy: ConflictPolicy = .keepBoth
            if !conflicts.isEmpty {
                var cancel = false
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    if let p = askConflictPolicy(
                        conflicts.count == 1
                            ? "“\(conflicts[0].lastPathComponent)” already exists in “\(dir.lastPathComponent)”"
                            : "\(conflicts.count) items already exist in “\(dir.lastPathComponent)”",
                        informative: "Choose how to handle items with the same name.",
                        options: [.keepBoth, .replace, .skip]) {
                        policy = p
                    } else {
                        cancel = true
                    }
                    sem.signal()
                }
                sem.wait()
                if cancel {
                    DispatchQueue.main.async {
                        slowHint.cancel(); TransferProgressController.shared.hide()
                        self.busy = false; self.busyText = ""; self.slowNetwork = false
                    }
                    return
                }
            }
            var moved: [(from: URL, to: URL)] = []
            var copied: [URL] = []
            var failures: [(name: String, reason: String)] = []
            let total = sources.count
            DispatchQueue.main.async { progress.total = total }
            let step = max(1, total / 50)
            // Byte-level progress so a single large file shows a real, moving bar
            // (not a stuck 0%). Used only for plain file copies; folders and moves
            // fall back to per-file (count) progress.
            let sizes: [Int64] = sources.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            let anyDir = sources.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            let totalBytes = sizes.reduce(0, +)
            let useBytes = !move && !anyDir && totalBytes > 0
            var base: Int64 = 0
            var lastFrac = -1.0
            for (i, src) in sources.enumerated() {
                if progress.cancelled { break }
                if useBytes { let n = src.lastPathComponent; DispatchQueue.main.async { progress.current = n } }
                let target = dir.appendingPathComponent(src.lastPathComponent)
                var dest = target
                if isSelfDup(src) {
                    dest = self.numberedCopyDest(dir, src.lastPathComponent)
                } else if conflictNames.contains(src.lastPathComponent) {
                    switch policy {
                    case .skip: base += sizes[i]; continue
                    case .replace: try? fm.removeItem(at: target)
                    case .keepBoth: dest = self.uniqueDest(dir, src.lastPathComponent)
                    }
                }
                let fileBase = base
                let onBytes: (Int64) -> Void = { copiedBytes in
                    let frac = Double(fileBase + copiedBytes) / Double(totalBytes)
                    if frac - lastFrac >= 0.004 {            // ~250 UI updates max, even for a 2 GB file
                        lastFrac = frac
                        DispatchQueue.main.async { progress.fraction = min(1, frac) }
                    }
                }
                do {
                    if move { try fm.moveItem(at: src, to: dest); moved.append((src, dest)) }
                    else if useBytes {
                        try Browser.copyWithProgress(src, dest, isCancelled: { progress.cancelled }, onBytes: onBytes)
                        // A cancelled copyfile leaves a truncated file behind — bin it
                        // rather than leaving a corrupt partial copy in the folder.
                        if progress.cancelled { try? fm.removeItem(at: dest); break }
                        copied.append(dest)
                    }
                    else { try fm.copyItem(at: src, to: dest); copied.append(dest) }   // APFS clones this too
                } catch {
                    if progress.cancelled { try? fm.removeItem(at: dest); break }
                    // Cross-volume move (rename fails) or a copyfile hiccup → plain copy.
                    do {
                        try fm.copyItem(at: src, to: dest)
                        if move { try? fm.removeItem(at: src); moved.append((src, dest)) }
                        else { copied.append(dest) }
                    } catch let e {
                        failures.append((src.lastPathComponent, e.localizedDescription))
                    }
                }
                base += sizes[i]
                if !useBytes, i % step == 0 || i == total - 1 {
                    let n = src.lastPathComponent, frac = total > 0 ? Double(i + 1) / Double(total) : 0
                    let d = i + 1
                    DispatchQueue.main.async { progress.current = n; progress.fraction = frac; progress.done = d }
                } else if useBytes {
                    let d = i + 1
                    DispatchQueue.main.async { progress.done = d }
                }
            }
            DispatchQueue.main.async {
                slowHint.cancel()
                TransferProgressController.shared.hide()
                if resetCut { Browser.cutMode = false }
                self.busy = false; self.busyText = ""; self.slowNetwork = false
                RecentFolders.shared.record(dir)   // you worked in the destination folder
                if move, !moved.isEmpty {
                    UndoStack.shared.push("Move", undo: { [weak self] in
                        let problem = restoreItems(moved.map { (from: $0.to, to: $0.from) })
                        self?.load()
                        return problem
                    }, redo: { [weak self] in
                        let problem = restoreItems(moved)
                        self?.load()
                        return problem
                    })
                } else if !copied.isEmpty {
                    self.pushCreation("Copy", copied)
                }
                Browser.invalidateCache(dir.path)
                // Only re-read the current folder if it actually changed: files
                // landed here, or a move may have removed them from here. A copy
                // into a DIFFERENT folder leaves the current listing untouched —
                // skip the reload, which over SMB re-stats the whole folder and
                // reads like a hang after copying just a few files.
                if move || dir.path == self.currentURL.path {
                    if self.currentIsNetwork { self.load() } else { self.silentRefresh() }
                }
                if !failures.isEmpty {
                    let verb = move ? "moved" : "copied"
                    let detail = failures.prefix(5).map { "• \($0.name): \($0.reason)" }.joined(separator: "\n")
                    // `at: dir` is what lets a denial say "your Desktop" — this is the
                    // path Send To ▸ Desktop takes.
                    reportFileError(failures.count == 1 ? "“\(failures[0].name)” couldn't be \(verb)"
                                                        : "\(failures.count) items couldn't be \(verb)", detail, at: dir)
                }
                // Cancel STOPS the transfer; whatever already finished stays put. Say
                // so plainly — otherwise a cancelled MOVE looks like files vanished
                // from the source folder for no reason. Undo puts them back.
                let settled = move ? moved.count : copied.count
                if progress.cancelled, settled > 0 {
                    let f = NumberFormatter(); f.numberStyle = .decimal
                    let n = f.string(from: NSNumber(value: settled)) ?? "\(settled)"
                    let t = f.string(from: NSNumber(value: total)) ?? "\(total)"
                    let a = NSAlert()
                    a.alertStyle = .informational
                    a.messageText = move ? "Move cancelled" : "Copy cancelled"
                    a.informativeText = move
                        ? "\(n) of \(t) items had already been moved into “\(dir.lastPathComponent)”. They were not moved back — press ⌘Z to undo the move."
                        : "\(n) of \(t) items had already been copied into “\(dir.lastPathComponent)”. They were kept — press ⌘Z to remove them."
                    a.addButton(withTitle: "OK")
                    a.runModal()
                }
            }
        }
    }

    func makeAlias(_ ids: Set<String>) {
        var created: [URL] = []
        var failure: String?
        for it in items.filter({ ids.contains($0.id) }) {
            let aliasURL = uniqueDest(currentURL, it.url.deletingPathExtension().lastPathComponent + " alias")
            do {
                let data = try it.url.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                try URL.writeBookmarkData(data, to: aliasURL)
                created.append(aliasURL)
            } catch { failure = failure ?? error.localizedDescription }
        }
        if let failure { reportFileError("Couldn't make an alias", failure) }
        if !created.isEmpty {
            RecentFolders.shared.record(currentURL)
            pushCreation("Make Alias", created)
        }
        load()
    }

    // Writes Finder tags via the com.apple.metadata:_kMDItemUserTags xattr (the
    // URLResourceValues.tagNames setter is macOS 26+, so we set the store directly).
    // Standard color names get their color index ("Red\n6"); custom tags stay plain.
    static func writeTags(_ url: URL, _ names: [String]) {
        let colorIndex: [String: Int] = ["gray": 1, "grey": 1, "green": 2, "purple": 3,
                                         "blue": 4, "yellow": 5, "red": 6, "orange": 7]
        let attr = "com.apple.metadata:_kMDItemUserTags"
        if names.isEmpty {
            _ = url.withUnsafeFileSystemRepresentation { removexattr($0, attr, 0) }
            return
        }
        let entries = names.map { n -> String in colorIndex[n.lowercased()].map { "\(n)\n\($0)" } ?? n }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0) else { return }
        _ = data.withUnsafeBytes { raw in
            url.withUnsafeFileSystemRepresentation { path in
                setxattr(path, attr, raw.baseAddress, data.count, 0, 0)
            }
        }
    }
    func toggleTag(_ ids: Set<String>, _ tag: String) {
        let affected = items.filter { ids.contains($0.id) }
        guard !affected.isEmpty else { return }
        let undoData: [(URL, [String])] = affected.map { ($0.url, $0.tags) }
        var redoData: [(URL, [String])] = []
        for it in affected {
            var t = it.tags
            if let idx = t.firstIndex(of: tag) { t.remove(at: idx) } else { t.append(tag) }
            Browser.writeTags(it.url, t)
            redoData.append((it.url, t))
        }
        pushTags(undoData, redoData)
        load()
    }
    func setTags(_ ids: Set<String>, tags: [String]) {
        let affected = items.filter { ids.contains($0.id) }
        guard !affected.isEmpty else { return }
        let undoData: [(URL, [String])] = affected.map { ($0.url, $0.tags) }
        for it in affected { Browser.writeTags(it.url, tags) }
        pushTags(undoData, affected.map { ($0.url, tags) })
        load()
    }
    func setComment(id: String, _ comment: String) {
        guard let it = items.first(where: { $0.id == id }) else { return }
        let path = it.url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let c = comment.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let src = "tell application \"Finder\" to set comment of (POSIX file \"\(path)\" as alias) to \"\(c)\""
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            if let err {
                NSLog("setComment error: \(err)")
                // -1743 is macOS refusing Automation ▸ Finder. A Finder comment is
                // WRITTEN BY FINDER (there is no supported API to set one directly), so
                // a denied Automation grant made Get Info's Save Comment do precisely
                // nothing, with no error anywhere the user could see it.
                if (err[NSAppleScript.errorNumber] as? Int) == -1743 {
                    DispatchQueue.main.async {
                        reportPermissionDenied("Navigator isn’t allowed to control Finder",
                            "Finder comments are stored by Finder itself, so macOS needs Navigator to have permission to control it. Your comment wasn’t saved.")
                    }
                }
            }
        }
    }

    func applyRenames(_ pairs: [(url: URL, newName: String)]) {
        var undo: [(from: URL, to: URL)] = []   // renamed → original
        var failure: String?
        for (url, newName) in pairs {
            let n = newName.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty, n != url.lastPathComponent else { continue }
            let dest = url.deletingLastPathComponent().appendingPathComponent(n)
            guard !fm.fileExists(atPath: dest.path) else { continue }
            do { try fm.moveItem(at: url, to: dest); undo.append((from: dest, to: url)) }
            catch { failure = failure ?? error.localizedDescription }
        }
        if let failure { reportFileError("Some items couldn't be renamed", failure) }
        if !undo.isEmpty { RecentFolders.shared.record(currentURL) }
        if !undo.isEmpty {
            UndoStack.shared.push("Batch Rename", undo: { [weak self] in
                let problem = restoreItems(undo)
                self?.load()
                return problem
            }, redo: { [weak self] in
                let problem = restoreItems(undo.map { (from: $0.to, to: $0.from) })
                self?.load()
                return problem
            })
        }
        load()
    }

    func makeSymlink(_ ids: Set<String>) {
        var created: [URL] = []
        for it in items.filter({ ids.contains($0.id) }) {
            let base = it.url.deletingPathExtension().lastPathComponent
            let ext = it.url.pathExtension
            let linkName = ext.isEmpty ? "\(base) symlink" : "\(base) symlink.\(ext)"
            let linkURL = uniqueDest(currentURL, linkName)
            do { try fm.createSymbolicLink(at: linkURL, withDestinationURL: it.url); created.append(linkURL) }
            catch { reportFileError("Couldn't create the symbolic link", error.localizedDescription) }
        }
        if !created.isEmpty {
            RecentFolders.shared.record(currentURL)
            pushCreation("Make Symbolic Link", created)
        }
        load()
    }

    /// Do these two paths name the SAME item on disk? File identity, not a string
    /// compare: macOS volumes are case-insensitive by default, so "photo.png" and
    /// "Photo.png" are one file and a case-only rename must not be mistaken for a
    /// collision with itself. Also gets hardlinks and "/tmp" vs "/private/tmp" right,
    /// which path normalisation alone would not.
    static func isSameItem(_ path: String, as url: URL) -> Bool {
        let k: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let a = (try? URL(fileURLWithPath: path).resourceValues(forKeys: k))?
                .fileResourceIdentifier as? NSObject,
              let b = (try? url.resourceValues(forKeys: k))?
                .fileResourceIdentifier as? NSObject else { return false }
        return a.isEqual(b)
    }

    // Rename is the one file operation whose destination name is typed by hand, so it's
    // the one that collides most — and every check below deliberately runs BEFORE
    // moveItem. Letting moveItem fail produced "couldn't be moved because an item with
    // the same name already exists" wrapped in reportFileError's Full Disk Access
    // paragraph: a permissions lecture for what is really just a name clash.
    func rename(id: String, to newName: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        var n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != item.name else { return }
        if let why = PathRules.invalidNameReason(n) {
            reportFileError("The name “\(n)” can’t be used.", why, permissionHint: false)
            return
        }
        // Finder's extension warning. The rename field pre-selects the base name only,
        // so the extension survives an ordinary rename untouched — which means a change
        // to it is either deliberate or a select-all-and-paste accident, and the accident
        // silently changes which app opens the file. Suppressible (Settings → Behavior).
        if Prefs.warnExtensionChange,
           let ch = PathRules.extensionChange(from: item.name, to: n, isDirectory: item.isDirectory) {
            let a = NSAlert()
            a.alertStyle = .warning
            let fromLabel = ch.from.isEmpty ? "no extension" : "“.\(ch.from)”"
            let toLabel = ch.to.isEmpty ? "no extension" : "“.\(ch.to)”"
            a.messageText = "Are you sure you want to change the extension from \(fromLabel) to \(toLabel)?"
            a.informativeText = "If you make this change, your document may open in a different application."
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Don't ask again"
            a.addButton(withTitle: ch.to.isEmpty ? "Remove Extension" : "Use “.\(ch.to)”")
            a.addButton(withTitle: ch.from.isEmpty ? "Keep No Extension" : "Keep “.\(ch.from)”")
            let resp = a.runModal()
            if a.suppressionButton?.state == .on { Prefs.warnExtensionChange = false }
            if resp != .alertFirstButtonReturn {
                // "Keep" re-applies the ORIGINAL extension on top of whatever was typed,
                // exactly as Finder does — "a.jpg" renamed to "b.png" becomes "b.png.jpg".
                n = ch.from.isEmpty ? (n as NSString).deletingPathExtension : n + "." + ch.from
            }
            // Keeping the extension can land back on the name we started from
            // ("a.jpg" -> "a" -> keep -> "a.jpg"); moveItem onto itself would throw.
            guard !n.isEmpty, n != item.name else { return }
        }
        let oldURL = item.url
        let dir = oldURL.deletingLastPathComponent()
        var dest = dir.appendingPathComponent(n)
        // The item displaced by Replace, so Undo can put it back.
        var replaced: URL?
        if PathRules.renameCollides(dest: dest.path,
                                    exists: { self.fm.fileExists(atPath: $0) },
                                    isSameItem: { Browser.isSameItem($0, as: oldURL) }) {
            switch askConflictPolicy("“\(n)” already exists in “\(dir.lastPathComponent)”",
                                     informative: "Choose how to handle items with the same name.",
                                     options: [.keepBoth, .replace]) {
            case .keepBoth:
                dest = uniqueDest(dir, n)
            case .replace:
                // Trash rather than delete: Undo has to be able to restore the item that
                // was clobbered, and the Trash is the only place it can be restored from.
                //
                // Through trashItems, not fm.trashItem directly: that helper is also what
                // records the TrashOrigins entry. Binning the displaced item by hand left
                // it in the Trash with no origin, so Put Back on it fell through to
                // Finder's lazily-written .DS_Store and usually offered nothing at all.
                let r = trashItems([dest])
                guard let t = r.restores.first?.from else {
                    reportFileError("Couldn't replace “\(n)”", r.problem ?? "")
                    return
                }
                replaced = t
            default:
                return   // Cancel — the original name stands
            }
        }
        let finalDest = dest
        do {
            try fm.moveItem(at: oldURL, to: finalDest)
            RecentFolders.shared.record(currentURL)
            UndoStack.shared.push("Rename", undo: { [weak self] in
                var problem = restoreItems([(from: finalDest, to: oldURL)])
                if let r = replaced { problem = problem ?? restoreItems([(from: r, to: finalDest)]) }
                self?.load()
                return problem
            }, redo: { [weak self] in
                // The undo put any displaced item back at the destination name, so it
                // has to be binned again before the rename can re-take that name —
                // moveItem onto an occupied path just fails. Re-binning yields a fresh
                // Trash path, which the undo half above then needs.
                var problem: String?
                if replaced != nil {
                    let r = trashItems([finalDest])
                    replaced = r.restores.first?.from
                    problem = r.problem
                }
                problem = problem ?? restoreItems([(from: oldURL, to: finalDest)])
                self?.load()
                return problem
            })
            load()
        } catch { reportFileError("Couldn't rename “\(item.name)”", error.localizedDescription) }
    }

    func duplicate(_ ids: Set<String>) {
        var created: [URL] = []
        var failure: String?
        for it in items.filter({ ids.contains($0.id) }) {
            let ext = it.url.pathExtension
            let base = it.url.deletingPathExtension().lastPathComponent
            let name = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
            let dest = uniqueDest(currentURL, name)
            do { try fm.copyItem(at: it.url, to: dest); created.append(dest) }
            catch { failure = failure ?? error.localizedDescription }
        }
        if let failure { reportFileError("Couldn't duplicate", failure) }
        if !created.isEmpty {
            RecentFolders.shared.record(currentURL)
            pushCreation("Duplicate", created)
        }
        load()
    }

    func infoText(_ ids: Set<String>) -> String {
        let sel = items.filter { ids.contains($0.id) }
        guard let it = sel.first else { return "" }
        if sel.count > 1 {
            let total = sel.reduce(Int64(0)) { $0 + $1.size }
            return "\(sel.count) items selected\nTotal size: \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
        }
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        let sizeStr = it.isDirectory ? "Folder" : ByteCountFormatter.string(fromByteCount: it.size, countStyle: .file)
        let created = (try? it.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        return """
        Name:      \(it.name)
        Kind:      \(it.kind)
        Size:      \(sizeStr)
        Created:   \(created.map { df.string(from: $0) } ?? "—")
        Modified:  \(df.string(from: it.modified))
        Where:     \(it.url.deletingLastPathComponent().path)
        """
    }

    func compress(_ ids: Set<String>) {
        let sel = items.filter { ids.contains($0.id) }
        guard !sel.isEmpty else { return }
        let names = sel.map { $0.url.lastPathComponent }
        let zipName = sel.count == 1 ? (sel[0].url.deletingPathExtension().lastPathComponent + ".zip") : "Archive.zip"
        let dest = uniqueDest(currentURL, zipName)
        let dir = currentURL
        busy = true; busyText = "Compressing…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.arguments = ["-r", "-q", dest.lastPathComponent] + names
            p.currentDirectoryURL = dir
            var runError: String?
            do { try p.run(); p.waitUntilExit() } catch { runError = error.localizedDescription }
            let ok = runError == nil && p.terminationStatus == 0
            DispatchQueue.main.async {
                self?.busy = false; self?.busyText = ""
                if ok {
                    RecentFolders.shared.record(dir)
                    self?.pushCreation("Compress", [dest])
                } else {
                    try? FileManager.default.removeItem(at: dest)   // clean up partial archive
                    reportFileError("Couldn't create the archive",
                                    runError ?? "zip exited with code \(p.terminationStatus).")
                }
                self?.load()
            }
        }
    }

    func extract(_ ids: Set<String>) {
        let sel = items.filter { ids.contains($0.id) && !$0.isDirectory && isArchive($0.url) }
        guard !sel.isEmpty else { return }
        let dir = currentURL
        busy = true; busyText = "Extracting…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var created: [URL] = []
            var failures: [(name: String, reason: String)] = []
            for it in sel {
                var base = it.url.deletingPathExtension().lastPathComponent
                if (base as NSString).pathExtension.lowercased() == "tar" { base = (base as NSString).deletingPathExtension }
                let dest = self.uniqueDest(dir, base)
                try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                let p = Process()
                if it.url.pathExtension.lowercased() == "zip" {
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    p.arguments = ["-x", "-k", it.url.path, dest.path]
                } else {
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                    p.arguments = ["-xf", it.url.path, "-C", dest.path]
                }
                do {
                    try p.run(); p.waitUntilExit()
                    if p.terminationStatus == 0 { created.append(dest) }
                    else { try? FileManager.default.removeItem(at: dest); failures.append((it.url.lastPathComponent, "The archive couldn't be expanded (code \(p.terminationStatus)).")) }
                } catch { try? FileManager.default.removeItem(at: dest); failures.append((it.url.lastPathComponent, error.localizedDescription)) }
            }
            DispatchQueue.main.async {
                self.busy = false; self.busyText = ""
                if !created.isEmpty {
                    RecentFolders.shared.record(dir)
                    self.pushCreation("Extract", created)
                }
                self.load()
                if !failures.isEmpty {
                    let detail = failures.prefix(5).map { "• \($0.name): \($0.reason)" }.joined(separator: "\n")
                    reportFileError(failures.count == 1 ? "Couldn't extract “\(failures[0].name)”" : "\(failures.count) archives couldn't be extracted", detail)
                }
            }
        }
    }

    func emptyTrash() {
        let trash = Browser.trashURL
        guard let entries = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else { return }
        var failure: String?
        var gone: [String] = []
        for e in entries {
            do { try fm.removeItem(at: e); gone.append(e.path) } catch { failure = failure ?? error.localizedDescription }
        }
        TrashOrigins.forget(gone)
        if let failure { reportFileError("Some items couldn't be removed from the Trash", failure) }
        if isTrash { load() }
    }

    // MARK: Trash browsing & Put Back

    static let trashURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")

    /// True only for the Trash ITSELF, not folders inside it: put-back is recorded for
    /// the top-level item that was trashed, so a file three levels down inside a
    /// trashed folder has no origin of its own and must not be offered one.
    var isTrash: Bool { currentURL.standardizedFileURL.path == Browser.trashURL.standardizedFileURL.path }

    /// Finder's put-back records for the Trash, read once per visit. Keyed by the
    /// item's name inside the Trash.
    private var trashPutBack: [String: TrashOrigin] = [:]

    /// Where a trashed item came from, or nil if nothing knows.
    ///
    /// Navigator's own record wins: it is written the instant we trash something,
    /// whereas Finder's `.DS_Store` is written lazily and typically has no entry yet
    /// for a file trashed seconds ago — which is exactly when Put Back gets used.
    func trashOrigin(of item: FileItem) -> TrashOrigin? {
        TrashOrigins.origin(of: item.url.path) ?? trashPutBack[item.name]
    }

    /// Reads the Trash's put-back records off the main thread and republishes, so the
    /// context menu can enable/disable Put Back per item. Called on arrival in the
    /// Trash; `.DS_Store` there can be several KB and is on disk, so never on-main.
    func loadTrashPutBack() {
        let url = Browser.trashURL.appendingPathComponent(".DS_Store")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let recs = (try? Data(contentsOf: url)).map { DSStore.putBackRecords($0) } ?? [:]
            DispatchQueue.main.async {
                guard let self else { return }
                self.trashPutBack = recs
                self.objectWillChange.send()   // menus read trashOrigin(of:) — let them re-evaluate
            }
        }
    }

    /// Finder's "Put Back": each selected item returns to the folder it was trashed
    /// from, under the name it had BEFORE the Trash renamed it for a collision.
    ///
    /// Items whose origin can't be resolved are skipped, not guessed at — dropping a
    /// file into some plausible-looking folder is worse than not restoring it, because
    /// the user has no way to know it happened.
    func putBack(_ ids: Set<String>) {
        let sel = items.filter { ids.contains($0.id) }
        var moves: [(from: URL, to: URL)] = []
        var unresolved: [String] = []
        var missingFolders: [String] = []
        for it in sel {
            guard let origin = trashOrigin(of: it) else { unresolved.append(it.name); continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: origin.directory, isDirectory: &isDir), isDir.boolValue else {
                missingFolders.append("• \(it.name) → \(origin.directory)")
                continue
            }
            // Something already lives at the original path. Keep Both rather than
            // clobber: the file at the destination is one the user still has, and
            // silently replacing it with a deleted version is unrecoverable.
            let dest = fm.fileExists(atPath: origin.url.path)
                ? uniqueDest(URL(fileURLWithPath: origin.directory), origin.name)
                : origin.url
            moves.append((from: it.url, to: dest))
        }
        if !moves.isEmpty {
            let problem = restoreItems(moves)
            TrashOrigins.forget(moves.map { $0.from.path })
            let undoPairs = moves.map { (from: $0.to, to: $0.from) }
            UndoStack.shared.push("Put Back", undo: { [weak self] in
                let p = restoreItems(undoPairs)
                TrashOrigins.record(undoPairs.map { (from: $0.to, to: $0.from) })
                self?.load(); return p
            }, redo: { [weak self] in
                let p = restoreItems(moves)
                TrashOrigins.forget(moves.map { $0.from.path })
                self?.load(); return p
            })
            load()
            if let problem { reportFileError("Some items couldn't be put back", problem) }
        }
        if !missingFolders.isEmpty {
            reportFileError("The original folder no longer exists",
                            missingFolders.prefix(5).joined(separator: "\n")
                            + "\n\nUse “Move to…” to choose somewhere else.", permissionHint: false)
        }
        if !unresolved.isEmpty {
            reportFileError(unresolved.count == 1
                            ? "Navigator doesn't know where “\(unresolved[0])” came from"
                            : "\(unresolved.count) items have no recorded original location",
                            "macOS only records an item's original location when it's moved to the Trash, and that record can be missing for items trashed by other apps or on an earlier system.\n\nUse “Move to…” to put them somewhere you choose.",
                            permissionHint: false)
        }
    }

    /// The fallback for items with no recorded origin: the user picks the folder.
    func moveOutOfTrash(_ ids: Set<String>) {
        let sel = items.filter { ids.contains($0.id) }
        guard !sel.isEmpty else { NSSound.beep(); return }
        let p = NSOpenPanel()
        p.message = sel.count == 1 ? "Move “\(sel[0].name)” out of the Trash to…" : "Move \(sel.count) items out of the Trash to…"
        p.prompt = "Move"
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        guard p.runModal() == .OK, let dir = p.url else { return }
        let moves = sel.map { (from: $0.url, to: uniqueDest(dir, $0.name)) }
        let problem = restoreItems(moves)
        TrashOrigins.forget(moves.map { $0.from.path })
        let undoPairs = moves.map { (from: $0.to, to: $0.from) }
        UndoStack.shared.push("Move Out of Trash", undo: { [weak self] in
            let p = restoreItems(undoPairs); self?.load(); return p
        }, redo: { [weak self] in
            let p = restoreItems(moves); self?.load(); return p
        })
        load()
        if let problem { reportFileError("Some items couldn't be moved", problem) }
    }

    /// Permanent delete of selected Trash items. Not undoable, hence the confirmation
    /// — and it exists because the alternative in a Trash view is "Move to Trash",
    /// which is nonsense for something already there.
    func deleteFromTrash(_ ids: Set<String>) {
        let sel = items.filter { ids.contains($0.id) }
        guard !sel.isEmpty else { NSSound.beep(); return }
        let a = NSAlert(); a.alertStyle = .warning
        a.messageText = sel.count == 1
            ? "Delete “\(sel[0].name)” permanently?"
            : "Delete \(sel.count) items permanently?"
        a.informativeText = "This can't be undone."
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var failure: String?
        var gone: [String] = []
        for it in sel {
            do { try fm.removeItem(at: it.url); gone.append(it.url.path) }
            catch { failure = failure ?? "• \(it.name): \(error.localizedDescription)" }
        }
        TrashOrigins.forget(gone)
        load()
        if let failure { reportFileError("Some items couldn't be deleted", failure) }
    }
}

// MARK: - App model (tabs)

/// One window's worth of restorable state.
struct WindowSession: Codable {
    var tabs: [String]
    var selected: Int
}

/// Per-WINDOW tab persistence.
///
/// The bug this replaces: every window's AppModel wrote its tab list to the same
/// single "openTabs" array, so the last window to navigate overwrote every other
/// window's tabs and a relaunch restored exactly one window's worth — whichever
/// happened to save last. Worse, `openWindow(showing:)` assigns a brand-new
/// single-tab list, so merely tearing a tab off into its own window destroyed the
/// original window's persisted tabs.
///
/// Windows register here in creation order and each one only ever rewrites its OWN
/// slot, identified by a UUID that has nothing to do with its index — a window
/// closing must not silently reassign another window's saved tabs to it.
/// Registration order is the restore order, so windows come back in the order they
/// were opened.
enum WindowSessions {
    private static let key = "windowSessionsV1"
    private static var live: [(id: UUID, session: WindowSession)] = []
    /// Sessions read at launch for windows that have not been created yet.
    ///
    /// DATA LOSS this prevents: an image-only launch (double-clicking a PNG) never
    /// shows the browser, so the extra windows are never restored — but the main
    /// window's AppModel still registered itself, and `persist()` writes the WHOLE
    /// list. That rewrote the file with ONE session, and every other window's tabs
    /// were gone from disk the moment you quit. Held here they are still persisted,
    /// so a launch that restores nothing destroys nothing either.
    private static var held: [WindowSession] = []

    /// What to restore, oldest window first. Falls back to the pre-multi-window
    /// single "openTabs" list so an upgrade doesn't lose the tabs you had open.
    static func saved() -> [WindowSession] {
        if let d = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode([WindowSession].self, from: d), !s.isEmpty {
            return s
        }
        let legacy = UserDefaults.standard.stringArray(forKey: "openTabs") ?? []
        guard !legacy.isEmpty else { return [] }
        return [WindowSession(tabs: legacy, selected: UserDefaults.standard.integer(forKey: "selectedTab"))]
    }

    static func register(_ id: UUID, _ session: WindowSession) {
        if let i = live.firstIndex(where: { $0.id == id }) { live[i].session = session }
        else { live.append((id, session)) }
        persist()
    }

    /// Park the sessions whose windows haven't been opened yet (see `held`).
    static func hold(_ sessions: [WindowSession]) { held = sessions; persist() }
    /// Claimed by whoever is about to turn them into real windows — those windows
    /// register themselves, so holding them any longer would double them up.
    static func takeHeld() -> [WindowSession] {
        let s = held
        held = []
        return s
    }
    /// Called when a window closes. Without this, a window you closed comes back on
    /// the next launch — its slot is still in the list.
    static func unregister(_ id: UUID) {
        live.removeAll { $0.id == id }
        // Never persist an EMPTY list: the last window closing is how the app quits,
        // and blanking the file there would mean every quit wipes the session.
        if !live.isEmpty || !held.isEmpty { persist() }
    }
    private static func persist() {
        let all = live.map { $0.session } + held
        if let d = try? JSONEncoder().encode(all) { UserDefaults.standard.set(d, forKey: key) }
    }
}

final class AppModel: ObservableObject {
    @Published var tabs: [Browser]
    /// This window's identity in the persisted session list — see WindowSessions.
    let sessionID = UUID()
    @Published var selected: Int = 0 { didSet { saveState() } }
    @Published var showPreview: Bool = Prefs.showPreview { didSet { Prefs.showPreview = showPreview } }
    @Published var showSidebar: Bool = Prefs.showSidebar { didSet { Prefs.showSidebar = showSidebar } }
    @Published var dualPane: Bool = Prefs.dualPane { didSet { Prefs.dualPane = dualPane } }
    /// The dual-pane right-hand browser, created on first use. Spelled out rather than
    /// `lazy var`, because forgetSession has to be able to ask whether it exists — and
    /// merely READING a lazy var creates it, which would spin up a Browser (and its
    /// folder watcher) for a window that is closing.
    private var secondaryIfLoaded: Browser?
    var secondary: Browser {
        if let s = secondaryIfLoaded { return s }
        let s = Browser(start: FileManager.default.homeDirectoryForCurrentUser)
        secondaryIfLoaded = s
        return s
    }
    /// `session` is this window's saved tabs, or nil for a window that starts fresh
    /// (New Window, or a torn-off tab). Passed in rather than read from UserDefaults
    /// here, because a second window must NOT restore the first window's tab list —
    /// that is what made "Move Tab to New Window" arrive alongside a copy of every
    /// other tab.
    init(session: WindowSession? = nil) {
        let fm = FileManager.default
        let saved = (session?.tabs ?? []).filter { fm.fileExists(atPath: $0) }
        if saved.isEmpty {
            tabs = [Browser(start: fm.homeDirectoryForCurrentUser)]
        } else {
            tabs = saved.map { Browser(start: URL(fileURLWithPath: $0)) }
            selected = max(0, min(session?.selected ?? 0, tabs.count - 1))
        }
        // Claim a persistence slot immediately, so a window whose tabs are never
        // touched still comes back next launch.
        WindowSessions.register(sessionID, WindowSession(tabs: tabs.map { $0.currentURL.path }, selected: selected))
        // Refresh the sidebar the instant a disk/USB/network share mounts or ejects,
        // so new volumes appear (and stale ones disappear) automatically.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
        // Persist open tabs whenever any tab navigates.
        NotificationCenter.default.addObserver(forName: .navigatorDidNavigate, object: nil, queue: .main) { [weak self] _ in
            self?.saveState()
        }
    }
    func saveState() {
        // A forgotten window must never claim a slot again. It could: a closed
        // NavWindow stays in NSApp.windows (isReleasedWhenClosed = false), so quitting
        // re-saved it and it came back next launch — and the .navigatorDidNavigate
        // observer below is app-wide, so ANY navigation in ANY window re-registered it
        // too. Both defeat the one thing forgetSession() exists to do.
        guard !forgotten else { return }
        WindowSessions.register(sessionID, WindowSession(tabs: tabs.map { $0.currentURL.path }, selected: selected))
    }
    private var forgotten = false
    /// This window is going away for good — drop its slot so it doesn't reopen next
    /// launch. NOT called on quit: quitting closes every window, and forgetting them
    /// all is precisely what session restore exists to avoid.
    func forgetSession() {
        forgotten = true
        WindowSessions.unregister(sessionID)
        // AppKit keeps a closed window alive (see Browser.stopWatching), so the work has
        // to be stopped by hand or every closed window keeps watching folders forever.
        tabs.forEach { $0.stopWatching() }
        secondaryIfLoaded?.stopWatching()
    }
    var active: Browser { tabs[max(0, min(selected, tabs.count - 1))] }
    func newTab(at url: URL? = nil) {
        tabs.append(Browser(start: url ?? FileManager.default.homeDirectoryForCurrentUser))
        selected = tabs.count - 1
        saveState()
    }
    func closeTab(_ index: Int) {
        guard tabs.indices.contains(index), tabs.count > 1 else { return }
        tabs.remove(at: index)
        if selected >= tabs.count { selected = tabs.count - 1 }
        saveState()
    }
    // Tab-strip right-click commands. Each one checks TabMenuRules (tested) so the
    // menu's disabled state and the action's own guard can never disagree — a menu
    // item that looks live and then does nothing reads as a broken app.
    func closeOtherTabs(_ index: Int) {
        guard TabMenuRules.canCloseOthers(index: index, count: tabs.count) else { return }
        tabs = [tabs[index]]
        selected = 0
        saveState()
    }
    func closeTabsToRight(_ index: Int) {
        guard TabMenuRules.canCloseToRight(index: index, count: tabs.count) else { return }
        tabs.removeSubrange((index + 1)...)
        if selected > index { selected = index }
        saveState()
    }
    // Moves the tab OUT: it leaves this window's strip and the folder opens in a fresh
    // window. Window creation lives on the AppDelegate (it owns the retain of extra
    // windows), so this goes through the one existing path rather than a second copy.
    /// `at` is where a tear-off drag was released, so the new window appears under the
    /// cursor instead of at the stock cascade offset. nil from the context menu, which has
    /// no meaningful position to offer.
    func moveTabToNewWindow(_ index: Int, at screenPoint: CGPoint? = nil) {
        guard TabMenuRules.canMoveToNewWindow(index: index, count: tabs.count) else { return }
        let url = tabs[index].currentURL
        closeTab(index)
        (NSApp.delegate as? AppDelegate)?.openWindow(showing: url, at: screenPoint)
    }
    // Open a folder in the right-hand pane, turning on dual-pane view if needed.
    func openInSecondPane(_ url: URL) {
        dualPane = true
        secondary.navigate(to: url)
    }

    /// Reorder the strip by dragging one tab onto another. The selected tab is carried by
    /// IDENTITY, not by index: keeping `selected` on the same slot would silently switch
    /// which folder the window is showing every time you rearranged tabs.
    func moveTab(from: Int, to: Int) {
        guard let order = TabMoveRules.reordered(count: tabs.count, from: from, to: to) else { return }
        let current = tabs[max(0, min(selected, tabs.count - 1))]
        tabs = order.map { tabs[$0] }
        selected = tabs.firstIndex { $0 === current } ?? selected
        saveState()
    }
}

// MARK: - Drag lifetime

/// Runs `body` once the left mouse button comes back up — the only signal available for
/// "the drag is over, whoever started it and however it ended".
///
/// Polling `NSEvent.pressedMouseButtons` rather than watching for a mouse-up event: a
/// drag session consumes its own mouse-up, so no local monitor ever sees it, and a
/// GLOBAL monitor needs the accessibility trust this app deliberately never asks for.
/// AppKit's own drag-ended callbacks are no use either — they only fire on the surface
/// that owns the session, and a drag can start in Finder and end over the sidebar.
///
/// `grace` exists because the drop handler fires on that same mouse-up: without a delay,
/// spring-back raced the drop and could navigate away from the folder just dropped into.
final class MouseUpWatch {
    private var timer: Timer?
    /// True across the post-mouse-up grace delay, when `timer` is already nil but this
    /// watch has not run its body yet.
    private var settling = false
    var isRunning: Bool { timer != nil || settling }

    func start(grace: TimeInterval = 0.25, _ body: @escaping () -> Void) {
        guard !isRunning else { return }   // already watching this same drag
        // Gating on `timer == nil` alone left the door open for the whole grace window,
        // so a second drag begun within 0.25s armed a SECOND watch on top of the first.
        // `settling` closes it — see isRunning.
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] t in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            t.invalidate()
            self?.timer = nil
            self?.settling = true
            DispatchQueue.main.asyncAfter(deadline: .now() + grace) { self?.settling = false; body() }
        }
        // .common, NOT Timer.scheduledTimer: a drag that STARTED in this app runs the
        // main run loop in NSEventTrackingRunLoopMode, and a .default-mode timer does
        // not tick at all until the drag is over. See SpringLoader.hover for the
        // user-visible half of this bug.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

// MARK: - Spring-loaded folders

/// Hover a folder mid-drag and it opens, so you can keep going and drop deeper — the
/// Finder/Explorer behaviour. One shared instance drives every drop surface (list rows,
/// icon cells, gallery cells, sidebar rows) because only one drag can be in flight at a
/// time, and because a per-surface timer could not do the one thing that makes this
/// usable: reset when the pointer crosses from one folder to a different one.
///
/// The dangerous failure mode is a timer that fires AFTER the drag is over — navigating
/// the window out from under someone who already let go. Three things prevent it: the
/// dwell timer is cancelled on every drag exit, `noteDrop` records that a drop landed,
/// and `finish` (driven by MouseUpWatch, which sees the end of any drag from anywhere)
/// tears the whole thing down.
final class SpringLoader {
    static let shared = SpringLoader()

    /// The folder the dwell timer is counting down on, if any.
    private var armed: URL?
    private var dwell: Timer?
    /// The folder the window was showing before the FIRST spring of this drag — where
    /// spring-back returns to. nil means nothing has sprung, so there is nothing to undo.
    private var origin: URL?
    private weak var sprung: Browser?
    private var didDrop = false
    private let watch = MouseUpWatch()

    /// The pointer is over `folder` with a drag in flight. Called repeatedly (AppKit's
    /// validateDrop fires on every mouse move) — repeats on the SAME folder deliberately
    /// leave the countdown running, or it would restart forever and never fire.
    func hover(folder: URL, browser: Browser) {
        guard SpringRules.canSpring(into: folder, from: browser.currentURL,
                                    dragging: Self.draggedFiles()) else { cancel(); return }
        watch.start { [weak self] in self?.finish() }
        let path = folder.standardizedFileURL.path
        if armed?.standardizedFileURL.path == path { return }
        // A different folder: restart the countdown from zero. THIS is what stops a drag
        // that merely sweeps across a folder on the way somewhere else from opening it.
        cancel()
        armed = folder
        let t = Timer(timeInterval: SpringRules.dwell, repeats: false) { [weak self, weak browser] _ in
            guard let self, let browser else { return }
            self.dwell = nil
            self.armed = nil
            if self.origin == nil { self.origin = browser.currentURL; self.sprung = browser }
            navLog("spring: opening \(folder.lastPathComponent) mid-drag")
            browser.navigate(to: folder)
        }
        // .common mode is LOAD-BEARING. Timer.scheduledTimer schedules in .default only,
        // and a drag that BEGAN inside Navigator puts the main run loop in
        // NSEventTrackingRunLoopMode for its whole duration — so the dwell timer never
        // ticked until the drag was already over and spring-loading simply did not
        // happen for the drags that matter most. Drags from OTHER apps kept working,
        // which is exactly why this survived testing. Same pattern as
        // NetworkPollCoordinator. Do not go back to scheduledTimer.
        RunLoop.main.add(t, forMode: .common)
        dwell = t
    }

    /// The pointer left `folder`. Ignored unless that folder is the one counting down:
    /// SwiftUI reports the NEW cell as targeted BEFORE the old one un-targets, so an
    /// unconditional cancel here would kill the countdown the next cell just armed.
    func leave(_ folder: URL) {
        if armed?.standardizedFileURL.path == folder.standardizedFileURL.path { cancel() }
    }

    /// Unconditional — for surfaces that report "the drag left me entirely" (the table's
    /// draggingExited/draggingEnded), where there is no ambiguity to protect against.
    func cancel() {
        dwell?.invalidate()
        dwell = nil
        armed = nil
    }

    /// A drop landed somewhere. Suppresses spring-back: the user finished their drag, and
    /// yanking the view back to where they started would hide the file they just moved.
    func noteDrop() {
        didDrop = true
        // Cancels the countdown too. A drop can land while the dwell is still running —
        // measured: drop a file onto a folder row and the spring fired 0.3s LATER, moving
        // the window into that folder after the user had already let go. That is the
        // fire-after-the-drag-is-over failure this class exists to prevent; it only became
        // reachable once the dwell timer started ticking during in-app drags (see hover).
        cancel()
    }

    /// Finder's spring-back. A drag abandoned without dropping leaves you where you
    /// started rather than parked several folders deep in something you only passed
    /// through. Either way the spring navigations went through `navigate(to:)`, so every
    /// hop is on the back stack and ⌘← walks out by hand — that is the real guarantee
    /// against being stranded, and it holds even if this never runs.
    private func finish() {
        cancel()
        if let o = origin, let b = sprung, !didDrop {
            navLog("spring: drag ended with no drop, springing back to \(o.lastPathComponent)")
            b.navigate(to: o)
        }
        origin = nil
        sprung = nil
        didDrop = false
    }

    /// What the in-flight drag is actually carrying, read from the drag pasteboard.
    ///
    /// Read from the pasteboard rather than tracked from our own drag sources, because
    /// SwiftUI's `isTargeted:` callback hands over a Bool and nothing else — there is no
    /// payload to inspect at hover time. This also covers drags that started in another
    /// app. Non-file URLs are dropped, which is what makes the sidebar's `navreorder:`
    /// token and the tab strip's `navtab:` token spring nothing.
    private static func draggedFiles() -> [URL] {
        let objs = NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self], options: nil)
        return (objs as? [URL] ?? []).filter { $0.isFileURL }
    }
}

// MARK: - Tab tear-off

/// What a tab drag puts on the pasteboard: the tab's index, plus which window's strip it
/// came from.
///
/// A private URL scheme, exactly like the sidebar's ReorderToken and for the same reason
/// — a tab needs to receive BOTH file drops and tab drops, and one row can only have one
/// drop handler, so one handler means one payload type. The window key is what stops a
/// tab dragged out of window A from reordering window B's strip at the same index.
enum TabDragToken {
    static let scheme = "navtab"

    static func key(_ model: AppModel) -> String {
        String(UInt(bitPattern: ObjectIdentifier(model).hashValue), radix: 16)
    }
    static func provider(model: AppModel, index: Int) -> NSItemProvider {
        var c = URLComponents()
        c.scheme = scheme
        c.host = key(model)
        c.path = "/\(index)"
        return NSItemProvider(object: (c.url ?? URL(fileURLWithPath: "/")) as NSURL)
    }
    /// The dragged tab's index, or nil if this drop isn't a tab from `model`'s own strip.
    static func index(of url: URL, model: AppModel) -> Int? {
        guard url.scheme == scheme, url.host == key(model) else { return nil }
        return Int(url.lastPathComponent)
    }
}

/// Drag a tab out of the strip and let go: it becomes its own window (Safari/Chrome).
///
/// There is no "my drag was refused" callback in SwiftUI, so tear-off can't be driven by
/// the absence of a drop. Instead the gesture itself decides: a release more than
/// `pullOut` points above or below where the drag started means the tab was pulled OUT of
/// the strip, which is the same vertical-detach rule Chrome uses. Sideways travel, however
/// far, is a reorder — so releasing in the 6pt gap between two tabs leaves the strip alone
/// instead of surprising the user with a new window.
final class TabDrag {
    static let shared = TabDrag()
    /// ~1.5 tab heights. Big enough that no reorder along the strip trips it.
    private static let pullOut: CGFloat = 40

    private weak var model: AppModel?
    private var index = 0
    private var startPoint = CGPoint.zero
    private var handled = false
    private let watch = MouseUpWatch()

    func begin(model: AppModel, index: Int) {
        self.model = model
        self.index = index
        startPoint = NSEvent.mouseLocation
        handled = false
        watch.start { [weak self] in self?.end() }
    }

    /// A tab in the strip took this drop (a reorder, or a release back on the tab itself),
    /// so it was never a tear-off however far the pointer wandered on the way.
    func noteHandled() { handled = true }

    private func end() {
        let m = model
        model = nil
        guard !handled, let m else { return }
        // The SAME rule the context-menu item is enabled by, checked here too so the log
        // below never claims a tear-off that moveTabToNewWindow is about to refuse. Its
        // refusal to move the ONLY tab out is what keeps this from leaving an empty ghost
        // window behind — dragging a lone tab anywhere simply does nothing.
        guard TabMenuRules.canMoveToNewWindow(index: index, count: m.tabs.count) else { return }
        let p = NSEvent.mouseLocation
        guard abs(p.y - startPoint.y) > Self.pullOut else { return }
        navLog("tab tear-off: index \(index) at \(Int(p.x)),\(Int(p.y))")
        m.moveTabToNewWindow(index, at: p)
    }
}

// MARK: - Components

/// The commands every folder-backed row shares, in the order and wording the sidebar
/// already uses — a right-click has to mean the same thing on a sidebar row, a
/// breadcrumb segment and a Favorites entry, or they stop reading as one app.
///
/// A free function rather than a method so the breadcrumb bar can use the SAME list
/// the sidebar does; it was private to SidebarView before there was a second caller.
@ViewBuilder func folderLocationMenu(_ url: URL, browser: Browser, model: AppModel) -> some View {
    Button("Open") { browser.navigate(to: url) }
    Button("Open in New Tab") { model.newTab(at: url) }
    Button("Open in Second Pane") { model.openInSecondPane(url) }
    Divider()
    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    Button("Copy Path") { browser.copyToClipboard(url.path) }
}

/// Get Info for something that isn't in any listing (a volume row, a breadcrumb
/// segment): builds the FileItem from the URL itself, since showInfo() can only look
/// ids up in browser.items, which only ever holds the CURRENT folder's contents.
func showFolderInfo(_ url: URL, browser: Browser) {
    GetInfoController.shared.show(browser, Browser.item(from: url, try? url.resourceValues(forKeys: Set(Browser.itemKeys))))
}

struct SidebarView: View {
    @ObservedObject var browser: Browser
    @ObservedObject var model: AppModel
    @ObservedObject var recents = RecentFolders.shared
    @ObservedObject var network = NetworkBrowser.shared
    @ObservedObject var favStore = FavoritesStore.shared
    @State private var favNodes: [SidebarNode] = []
    @State private var recentsTargeted = false
    @State private var cloudNodes: [SidebarNode] = []

    @ViewBuilder private func row(_ loc: SidebarLocation) -> some View {
        HStack(spacing: 2) {
            Button { browser.navigate(to: loc.url) } label: {
                Label(loc.name, systemImage: loc.symbol).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            if loc.ejectable {
                Button { disconnectVolume(loc.url, isNetwork: loc.isNetwork) } label: {
                    Image(systemName: "eject.fill").font(.caption2)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(loc.isNetwork ? "Disconnect" : "Eject")
            }
        }
        .modifier(FolderDropRow(folder: loc.url, browser: browser))
        .contextMenu {
            locationMenu(loc.url)
            Button("Get Info") { showRowInfo(loc.url) }
            // Same condition as the eject button above, so the two can never
            // disagree about whether a volume can be let go of (the startup disk
            // reports ejectable=false and must never be offered).
            if loc.ejectable {
                Divider()
                Button(loc.isNetwork ? "Disconnect" : "Eject") { disconnectVolume(loc.url, isNetwork: loc.isNetwork) }
            }
        }
    }

    // The shared list and the URL-only Get Info both live at file scope now
    // (folderLocationMenu / showFolderInfo) so the breadcrumb bar offers the same
    // commands from the same source.
    @ViewBuilder private func locationMenu(_ url: URL) -> some View {
        folderLocationMenu(url, browser: browser, model: model)
    }
    private func showRowInfo(_ url: URL) { showFolderInfo(url, browser: browser) }

    /// What a favorite-reorder drag puts on the pasteboard: the row's path wrapped in
    /// a private URL scheme.
    ///
    /// It used to be the bare path as plain text, which cannot survive next to file
    /// drops — `.dropDestination(for: URL.self)` shadows a sibling `.onDrop(of: [.text])`
    /// on the same row and then declines the text itself (verified with synthesized
    /// drags: the reorder never reached either handler). One drop handler per row is
    /// the fix, and one handler means one payload type, so the token became a URL that
    /// is unmistakably not a file: `navreorder:` says "this is a row, not a document"
    /// no matter which sidebar section it lands on.
    private enum ReorderToken {
        static let scheme = "navreorder"
        static func provider(_ path: String) -> NSItemProvider {
            var c = URLComponents()
            c.scheme = scheme
            c.path = path   // percent-encodes for us, so spaces in a path survive
            return NSItemProvider(object: (c.url ?? URL(fileURLWithPath: path)) as NSURL)
        }
        /// The favorite path this drop carries, or nil if it isn't a reorder at all.
        static func path(of url: URL) -> String? { url.scheme == scheme ? url.path : nil }
    }

    /// THE drop handler for a sidebar row — both kinds of drop, one modifier.
    ///
    /// Files dropped ON a row go INTO that folder — the same move-or-copy the file
    /// list does for a folder row, through the same Browser call, so conflict
    /// prompts, undo and error reporting are identical. Before this, a file dropped
    /// on a favorite vanished into the section-level "pin this folder" handler,
    /// which only accepted directories and so silently did nothing.
    ///
    /// A favorite row ALSO receives the reorder drag, and it must be handled here,
    /// in the same closure. Two drop modifiers on one row is a trap, not a layering:
    /// an earlier version put this URL destination inside a separate
    /// `.onDrop(of: [.text])` that did the reordering, expecting the text drag to
    /// fall through to the outer one. It never does — the URL destination wins the
    /// hit test and then refuses the text itself, so reordering died silently while
    /// file drops kept working. Both payloads arrive here, and are told apart by
    /// what they are (see ReorderToken). Do NOT add a second drop modifier here.
    ///
    /// The highlight matters as much as the drop: with no feedback there was no way
    /// to tell a row apart from the gap above it, the section header, or Recents —
    /// so a near miss looked exactly like a broken feature. Now the row you're about
    /// to displace (or drop into) lights up, and nothing lighting up means "don't
    /// let go here".
    private struct FolderDropRow: ViewModifier {
        let folder: URL
        @ObservedObject var browser: Browser
        /// The favorite this row IS, or nil on rows that can't be a reorder target
        /// (Locations, Recents, Cloud, expanded subfolders) — none of those are
        /// entries in favStore, so reorder() could never find them.
        var reorderOnto: String?
        @State private var targeted = false

        func body(content: Content) -> some View {
            content
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(targeted ? 0.35 : 0))
                )
                .dropDestination(for: URL.self) { urls, _ in
                    guard let first = urls.first else { return false }
                    if let src = ReorderToken.path(of: first) {
                        guard let onto = reorderOnto else { return false }
                        FavoritesStore.shared.reorder(from: src, onto: onto)
                        return true
                    }
                    // Drop a folder on its own row (or on a row inside it) and there
                    // is nothing sane to do — dropInto would alert about copying a
                    // folder into itself for what was obviously just a missed aim.
                    let safe = urls.filter { !PathRules.isSelfOrDescendant(folder, of: $0) }
                    guard !safe.isEmpty else { return false }
                    browser.dropInto(safe, folder: folder)
                    return true
                } isTargeted: { t in
                    targeted = t
                    // Spring-loading: hovering a pinned folder mid-drag navigates the main
                    // view there, so a favorite works as a shortcut INTO a hierarchy and
                    // not only as a place to let go. A reorder drag springs nothing — its
                    // pasteboard holds no file (see SpringLoader.draggedFiles).
                    if t { SpringLoader.shared.hover(folder: folder, browser: browser) }
                    else { SpringLoader.shared.leave(folder) }
                }
        }
    }

    /// The drag SOURCE half of favorite reordering; the drop half lives in
    /// FolderDropRow, which is the row's one and only drop handler (read the trap
    /// documented there before touching either).
    ///
    /// onDrag rather than draggable: the row's content is a full-width Button, and
    /// the newer API loses the mouse-down to it, so the drag never starts. List's
    /// .onMove isn't available either — these rows are OutlineGroups and a List only
    /// reorders plain ForEach rows (tested).
    private struct ReorderDrag: ViewModifier {
        let path: String
        let enabled: Bool
        @ViewBuilder func body(content: Content) -> some View {
            if enabled { content.onDrag { ReorderToken.provider(path) } } else { content }
        }
    }

    // An expandable folder entry (Windows-11-style): disclosure triangle drills
    // into subfolders inline; clicking any node navigates the main view there.
    @ViewBuilder private func tree(_ node: SidebarNode, removable: Bool) -> some View {
        OutlineGroup(node, children: \.children) { n in
            // Show a pushpin on top-level pinned favorites (Windows 11 Quick Access
            // style). Home stays a fixed anchor with no pin. Click the pin to unpin.
            let isTop = n.id == node.id
            let isHome = n.url.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser.path
            let pinned = removable && isTop && !isHome
            HStack(spacing: 4) {
                Button { browser.openFavorite(n.url.path, mountURL: n.mountURL) } label: {
                    Label(n.name, systemImage: n.symbol).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                }.buttonStyle(.plain).help(n.mountURL ?? n.url.path)
                if pinned {
                    Button { favStore.remove(label: n.name, path: n.url.path) } label: {
                        Image(systemName: "pin.fill").font(.caption2).rotationEffect(.degrees(45))
                    }.buttonStyle(.plain).foregroundStyle(.tertiary).help("Unpin from Sidebar")
                }
            }
            .contextMenu {
                Button("Open") { browser.openFavorite(n.url.path, mountURL: n.mountURL) }
                Button("Open in New Tab") { model.newTab(at: n.url) }
                Button("Open in Second Pane") { model.openInSecondPane(n.url) }
                Divider()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([n.url]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(n.url.path, forType: .string)
                }
                if n.mountURL != nil {   // network drive favorite → offer to disconnect
                    Button("Disconnect") { disconnectVolume(n.url, isNetwork: true) }
                }
                if pinned {
                    Divider()
                    // Always-works alternative to aiming a drag.
                    Button("Move to Top") { favStore.moveToTop(path: n.url.path) }
                    Button("Move Up") { favStore.moveUp(path: n.url.path) }
                    Button("Move Down") { favStore.moveDown(path: n.url.path) }
                    Divider()
                    Button("Unpin from Sidebar") { favStore.remove(label: n.name, path: n.url.path) }
                }
            }
            // Offer the reorder drag ONLY where reordering is real: a row that is
            // itself an entry in favStore.items, i.e. a top-level Favorites row.
            // Cloud rows (removable: false) and expanded subfolders aren't in the
            // store, so reorder() could never find them — the drag they advertised
            // always ended in nothing happening.
            .modifier(FolderDropRow(folder: n.url, browser: browser,
                                    reorderOnto: removable && isTop ? n.url.path : nil))
            .modifier(ReorderDrag(path: n.url.path, enabled: removable && isTop))
        }
    }

    var body: some View {
        let volumes = volumeLocations()
        List {
            Section("Favorites") {
                // Recents sits above the first favorite, so it's exactly where you let
                // go when you mean "put it at the very top" — it used to swallow that
                // drop silently. Accepting it as "move to the top" removes the trap.
                Button { browser.loadRecents() } label: {
                    Label("Recents", systemImage: "clock").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                .dropDestination(for: URL.self) { urls, _ in
                    // The drag ENDED here, so there must be no spring-back: a drag that
                    // sprung into a folder on its way to this row used to yank the window
                    // back to where it started 0.25s after the drop landed. Every drop
                    // path has to say so — dropInto/dropIntoCurrentFolder do it for the
                    // file surfaces, these two sidebar handlers call neither.
                    SpringLoader.shared.noteDrop()
                    if let src = urls.first.flatMap(ReorderToken.path(of:)) {
                        favStore.moveToTop(path: src)
                        return true
                    }
                    // Not a reorder, so it's a folder someone means to pin — and this
                    // row shadows the section's own pin drop (a row's drop destination
                    // always beats its section's), so it has to do that job itself
                    // rather than swallow the drop.
                    let dirs = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                    dirs.forEach { favStore.add($0) }
                    return !dirs.isEmpty
                } isTargeted: { recentsTargeted = $0 }
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(recentsTargeted ? 0.35 : 0)))
                // Reorder by dragging one favorite onto another — see `tree`. List's
                // .onMove is NOT usable here: these rows are OutlineGroups (they
                // expand into subfolders), and a List only offers its own reorder
                // drag for plain ForEach rows. Tested with a synthetic drag — .onMove
                // silently does nothing on these rows.
                ForEach(favNodes) { tree($0, removable: true) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                SpringLoader.shared.noteDrop()   // see the Recents row above
                for u in urls where (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { favStore.add(u) }
                return true
            }
            if !recents.urls.isEmpty {
                Section {
                    ForEach(recents.urls, id: \.self) { u in
                        Button { browser.navigate(to: u) } label: {
                            Label(u.lastPathComponent.isEmpty ? u.path : u.lastPathComponent, systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        }.buttonStyle(.plain).help(u.path)
                        .modifier(FolderDropRow(folder: u, browser: browser))
                        .contextMenu {
                            locationMenu(u)
                            Divider()
                            Button("Remove from Recents") { recents.remove(u) }
                            Button("Clear Recents") { recents.clear() }
                        }
                    }
                } header: {
                    HStack {
                        Text("Recent Folders")
                        Spacer()
                        Button("Clear") { recents.clear() }.buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if !cloudNodes.isEmpty {
                Section("Cloud") { ForEach(cloudNodes) { tree($0, removable: false) } }
            }
            Section("Locations") {
                ForEach(volumes) { row($0) }
                // The Trash is a location like any other — browsing it is the only way
                // to get at Put Back, and before this the Trash was reachable from
                // Navigator only by typing its path. Deliberately NOT a drop target:
                // dropping files on it would be a delete disguised as a move, and
                // ⌘⌫ / the toolbar trash button are the explicit ways to do that.
                Button { browser.navigate(to: Browser.trashURL) } label: {
                    Label("Trash", systemImage: "trash").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                .contextMenu {
                    Button("Open") { browser.navigate(to: Browser.trashURL) }
                    Button("Open in New Tab") { model.newTab(at: Browser.trashURL) }
                    Divider()
                    Button("Empty Trash…") { confirmEmptyTrash(browser) }
                }
            }
            if !network.servers.isEmpty {
                Section("Network") {
                    ForEach(network.servers) { s in
                        Button { NSWorkspace.shared.open(s.url) } label: {
                            Label(s.name, systemImage: "network").frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).help("Connect to \(s.url.absoluteString)")
                        // Deliberately NOT the shared locationMenu: a discovered
                        // server is an smb:// address, not a mounted folder, so
                        // "New Tab"/"Second Pane"/"Reveal in Finder" would all be
                        // handed a URL no file API can open. Once it IS mounted it
                        // appears under Locations, which has the full menu.
                        .contextMenu {
                            Button("Open") { NSWorkspace.shared.open(s.url) }
                            Button("Copy Address") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(s.url.absoluteString, forType: .string)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear { rebuildNodes() }
        .onChange(of: favStore.items) { rebuildFav() }
    }

    private func rebuildFav() {
        favNodes = favStore.items.map { SidebarNode(url: $0.url, name: $0.label, symbol: favoriteSymbol($0.url), mountURL: $0.mountURL) }
    }
    private func rebuildNodes() {
        rebuildFav()
        cloudNodes = cloudLocations().map { SidebarNode(url: $0.url, name: $0.name, symbol: $0.symbol) }
    }
}

struct ControlBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var browser: Browser
    // Only the search field uses SwiftUI focus. It is never removed from the
    // hierarchy, so its focus value cannot go stale the way the address bar's did —
    // that field is an AppKit bridge for exactly that reason (see AddressField).
    @FocusState private var searchFocused: Bool
    // Drives which address-bar state is showing (read-only path vs live field). A plain
    // @State separate from the FocusState on purpose: the field must EXIST before it can
    // be focused, so "start editing" inserts it (this flag) and the field then takes
    // focus in its own onAppear — the order the old single-flag design got wrong.
    @State private var editingPath = false
    private var folderName: String {
        let n = browser.currentURL.lastPathComponent
        return n.isEmpty ? "Macintosh HD" : n
    }
    var body: some View {
        VStack(spacing: 7) {
            // Row 1: navigation + address bar + search (Windows 11 layout)
            HStack(spacing: 8) {
                Button { model.showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help("Navigation Pane (⌥⌘S)").foregroundStyle(model.showSidebar ? Color.accentColor : .secondary)
                // ⌘[ / ⌘] / ⌘↑ live in the Go menu, NOT here. A SwiftUI
                // .keyboardShortcut and an NSMenuItem key equivalent for the same
                // chord are two independent handlers, and both fire — ⌘[ went back
                // TWO steps. The menu owns the chords (it's the discoverable place
                // and it can grey out at the ends of the history); these buttons are
                // click-only.
                Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack).help("Back (⌘[)")
                Button { browser.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!browser.canGoForward).help("Forward (⌘])")
                Button { browser.goUp() } label: { Image(systemName: "chevron.up") }
                    .help("Up (⌘↑)")
                Button { browser.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command).help("Refresh")

                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(.secondary).font(.caption)
                    // Two explicit states, swapped like Windows Explorer's address bar:
                    // a head-truncated read-only path (the long path's useful end is the
                    // deep folder you're in), and a real TextField while editing.
                    //
                    // Swapped with if/else, NOT the old opacity trick. The previous
                    // design kept the field at .opacity(0) under a non-hit-testing Text
                    // and asked FocusState to focus it — but an opacity-0 view isn't
                    // hit-testable, and AppKit refuses first-responder for it, so the
                    // focus request usually just failed. That's why the bar took "a few
                    // double-clicks" to catch: it only worked when a click happened to
                    // land during a re-render race. Here the field is INSERTED first and
                    // takes first responder itself (see AddressField) — no race to win.
                    if editingPath {
                        // Return navigates; Escape restores the real path. Both also put
                        // the bar back to its read-only display.
                        AddressField(text: $browser.pathText,
                                     onCommit: { browser.submitPath(); editingPath = false },
                                     onCancel: {
                                         browser.pathText = browser.addressString(for: browser.currentURL)
                                         editingPath = false
                                     })
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(browser.pathText.isEmpty ? "Type a path and press Return" : browser.pathText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(browser.pathText.isEmpty ? Color.secondary : Color.primary)
                            .lineLimit(1).truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .frame(maxWidth: .infinity)
                // The whole capsule begins editing — one click, anywhere in the bar.
                .contentShape(Rectangle())
                .onTapGesture { if !editingPath { editingPath = true } }

                Button { browser.copyDisplayedPath() } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy Path Shown in Address Bar")

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("Search “\(folderName)”", text: $browser.searchText)
                        .textFieldStyle(.plain).focused($searchFocused)
                        .onSubmit { browser.runSearch() }
                        .onChange(of: browser.searchText) {
                            // Emptying the text ends the search ONLY if no filter is
                            // armed — "everything modified today" is still a search
                            // with no text in the box.
                            if browser.searchText.isEmpty && browser.isSearching {
                                if browser.searchFilters.isActive { browser.runSearch() } else { browser.clearSearch() }
                            }
                        }
                    if !browser.searchText.isEmpty {
                        Button { browser.clearSearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Clear Search")
                    }
                    Menu {
                        Picker("Scope", selection: $browser.searchThisMac) {
                            Text("This Folder").tag(false); Text("This Mac").tag(true)
                        }
                        Picker("Kind", selection: $browser.searchKind) {
                            ForEach(SearchKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Date Modified", selection: $browser.searchFilters.date) {
                            ForEach(SearchDateFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Size", selection: $browser.searchFilters.size) {
                            ForEach(SearchSizeFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        if browser.searchFilters.isActive {
                            Divider()
                            // Resetting the struct is enough: the two .onChange handlers
                            // below see date and size go back to .any and re-run the
                            // search themselves. Calling runSearch() here as well only
                            // started a third query for the same keystroke.
                            Button("Clear Date & Size Filters") { browser.searchFilters = SearchFilters() }
                        }
                    } label: {
                        // The icon fills in when a filter is armed. Without it a
                        // filter-narrowed result list is indistinguishable from a folder
                        // that simply doesn't contain what you're looking for.
                        Image(systemName: browser.searchFilters.isActive || browser.searchKind != .any
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                            .foregroundStyle(browser.searchFilters.isActive || browser.searchKind != .any ? Color.accentColor : Color.secondary)
                    }
                        .menuStyle(.borderlessButton).frame(width: 20).help("Search Scope, Kind, Date & Size")
                        .onChange(of: browser.searchThisMac) { if browser.isSearching { browser.runSearch() } }
                        .onChange(of: browser.searchKind) { if browser.isSearching { browser.runSearch() } }
                        // Picking "Custom Range…" has to collect the range BEFORE the
                        // search runs, and a cancelled prompt must not leave the picker
                        // reading "Custom Range…" while matching everything.
                        .onChange(of: browser.searchFilters.date) {
                            if browser.searchFilters.date == .custom {
                                guard let r = promptCustomDateRange(from: browser.searchFilters.customDateFrom,
                                                                    to: browser.searchFilters.customDateTo) else {
                                    browser.searchFilters.date = .any; return
                                }
                                browser.searchFilters.customDateFrom = r.from
                                browser.searchFilters.customDateTo = r.to
                            }
                            browser.runSearch()
                        }
                        .onChange(of: browser.searchFilters.size) {
                            if browser.searchFilters.size == .custom {
                                guard let r = promptCustomSizeRange(from: browser.searchFilters.customSizeFrom,
                                                                    to: browser.searchFilters.customSizeTo) else {
                                    browser.searchFilters.size = .any; return
                                }
                                browser.searchFilters.customSizeFrom = r.from
                                browser.searchFilters.customSizeTo = r.to
                            }
                            browser.runSearch()
                        }
                }
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .frame(width: 200)

                // ⌘L has to INSERT the field, not just ask for focus. The address bar
                // only exists as an editable field while editingPath is true, so the
                // old focus-only version aimed a focus request at a view that wasn't in
                // the hierarchy and did nothing whatsoever — ⌘L was dead. Focus, and the
                // whole path arriving selected so you can type a replacement, come from
                // AddressField itself.
                Button("") { editingPath = true }.keyboardShortcut("l", modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }

            // Row 2: Windows 11-style command bar
            HStack(spacing: 6) {
                Menu {
                    newItemsMenu(browser, ids: browser.selection)
                } label: { Label("New", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize().help("New")

                sep()
                Button { browser.cutFiles() } label: { Image(systemName: "scissors") }.help("Cut").disabled(!hasSel)
                Button { browser.copyFiles() } label: { Image(systemName: "doc.on.doc") }.help("Copy").disabled(!hasSel)
                Button { browser.pasteFiles() } label: { Image(systemName: "doc.on.clipboard") }.help("Paste")
                Button { if let id = browser.selection.first { promptRename(browser, id) } } label: { Image(systemName: "pencil") }.help("Rename").disabled(!oneSel)
                Button { shareItems(selURLs) } label: { Image(systemName: "square.and.arrow.up") }.help("Share").disabled(!hasSel)
                // In the Trash, "move to trash" is meaningless — the two things you
                // actually want there are Put Back and Empty, so the button becomes
                // the one that can't be reached any other way from the toolbar.
                if browser.isTrash {
                    Button { browser.putBack(browser.selection) } label: { Image(systemName: "arrow.uturn.backward") }
                        .help("Put Back").disabled(!hasSel)
                    Button { confirmEmptyTrash(browser) } label: { Image(systemName: "trash.slash") }
                        .help("Empty Trash")
                } else {
                    Button { browser.moveToTrash(browser.selection) } label: { Image(systemName: "trash") }.help("Delete (⌘⌫)").disabled(!hasSel)
                }

                sep()
                Menu {
                    Picker("Sort by", selection: sortFieldBinding) {
                        Text("Name").tag(SortField.name)
                        Text("Date Modified").tag(SortField.modified)
                        Text("Type").tag(SortField.kind)
                        Text("Size").tag(SortField.size)
                    }
                    Divider()
                    Picker("Order", selection: ascendingBinding) {
                        Text("Ascending").tag(true); Text("Descending").tag(false)
                    }
                    Divider()
                    Picker("Group by", selection: $browser.groupBy) {
                        Text("(None)").tag(GroupBy.none)
                        Text("Kind").tag(GroupBy.kind)
                        Text("Date Modified").tag(GroupBy.date)
                        Text("Size").tag(GroupBy.size)
                    }
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }.menuStyle(.borderlessButton).fixedSize().help("Sort")

                Menu {
                    Button { browser.viewMode = .icon; browser.iconSize = 128 } label: { Label("Large icons", systemImage: "square.grid.2x2") }
                    Button { browser.viewMode = .icon; browser.iconSize = 90 } label: { Label("Medium icons", systemImage: "square.grid.3x3") }
                    Button { browser.viewMode = .icon; browser.iconSize = 56 } label: { Label("Small icons", systemImage: "square.grid.4x3.fill") }
                    Divider()
                    Button { browser.viewMode = .list } label: { Label("Details", systemImage: "list.bullet") }
                    Button { browser.viewMode = .gallery } label: { Label("Gallery", systemImage: "photo.on.rectangle") }
                    Divider()
                    // Same ColumnMenu source as the menu-bar submenu and the header
                    // right-click menu, so all three always agree.
                    Menu("Columns") {
                        ForEach(ColumnMenu.togglableIDs, id: \.self) { id in
                            Toggle(fileColumnTitle(id), isOn: Binding(
                                get: { browser.visibleColumns.contains(id) },
                                set: { _ in
                                    browser.visibleColumns = ColumnMenu.toggled(browser.visibleColumns, id: id)
                                    if browser.viewMode != .list { browser.viewMode = .list }
                                }))
                        }
                    }
                    Toggle("Preview pane", isOn: $model.showPreview)
                    Menu("Show") {
                        Toggle("Navigation pane", isOn: $model.showSidebar)
                        Toggle("Hidden items", isOn: $browser.showHidden)
                    }
                    Divider()
                    Button { ViewOptionsController.shared.toggle(model) } label: {
                        Label("Show View Options (⌘J)", systemImage: "slider.horizontal.3")
                    }
                } label: { Label("View", systemImage: "square.grid.2x2") }.menuStyle(.borderlessButton).fixedSize().help("View")

                Menu {
                    Toggle("Dual Pane (⌥⌘2)", isOn: $model.dualPane)
                    Button { openInTerminal(browser.currentURL) } label: { Label("Open in Terminal", systemImage: "terminal") }
                    Divider()
                    Button { showInfo(browser, browser.selection) } label: { Label("Get Info", systemImage: "info.circle") }.disabled(!hasSel)
                    Button { browser.compress(browser.selection) } label: { Label("Compress", systemImage: "archivebox") }.disabled(!hasSel)
                    Button { browser.makeAlias(browser.selection) } label: { Label("Make Alias", systemImage: "arrow.up.right") }.disabled(!hasSel)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().frame(width: 34).help("More")

                Spacer()
                Button { model.showPreview.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                    .foregroundStyle(model.showPreview ? Color.accentColor : .secondary).help("Details / Preview Pane (⇧⌘P)")
            }
        }.padding(.horizontal, 10).padding(.vertical, 8)
        .onReceive(NotificationCenter.default.publisher(for: .navigatorFocusSearch)) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .navigatorResignFields)) { _ in
            searchFocused = false; editingPath = false
        }
    }

    @ViewBuilder private func sep() -> some View { Divider().frame(height: 16).padding(.horizontal, 3) }
    private var hasSel: Bool { !browser.selection.isEmpty }
    private var oneSel: Bool { browser.selection.count == 1 }
    private var selURLs: [URL] { browser.items.filter { browser.selection.contains($0.id) }.map(\.url) }

    private var sortFieldBinding: Binding<SortField> {
        Binding(get: { browser.currentSortField },
                set: { browser.setSort($0, ascending: browser.currentAscending) })
    }
    private var ascendingBinding: Binding<Bool> {
        Binding(get: { browser.currentAscending },
                set: { browser.setSort(browser.currentSortField, ascending: $0) })
    }
}

struct SearchBanner: View {
    @ObservedObject var browser: Browser
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            Text("Search results in “\(browser.currentURL.lastPathComponent)”").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Clear") { browser.clearSearch() }.font(.caption)
        }.padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.10))
    }
}

struct BreadcrumbBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var model: AppModel
    @ObservedObject private var favStore = FavoritesStore.shared
    var body: some View {
        let crumbs = browser.breadcrumbs()
        // Too deep to fit? Drop crumbs from the FRONT, not the back — the folder
        // you're in is the part worth reading, and clipping the right edge used to
        // cut it off mid-name. ViewThatFits takes the first candidate that fits, so
        // these run shallowest-drop first and give up as little of the path as
        // possible. The extra final candidate lets the last crumb itself shrink,
        // for a very long folder name in a narrow window.
        ViewThatFits(in: .horizontal) {
            ForEach(0..<max(crumbs.count, 1), id: \.self) { drop in
                trail(crumbs, dropping: drop)
            }
            trail(crumbs, dropping: max(crumbs.count - 1, 0), flexibleTail: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading).clipped()
    }

    private func trail(_ crumbs: [(name: String, url: URL)], dropping drop: Int,
                       flexibleTail: Bool = false) -> some View {
        let shown = Array(crumbs.dropFirst(drop).enumerated())
        return HStack(spacing: 2) {
            if drop > 0 { Text("…").font(.callout).foregroundStyle(.tertiary) }
            ForEach(shown, id: \.offset) { idx, crumb in
                if idx > 0 || drop > 0 {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                Button { browser.navigate(to: crumb.url) } label: {
                    // fixedSize is what makes this work: it holds every candidate at
                    // its natural width so a too-wide one is genuinely rejected. Let
                    // a crumb compress and every candidate would "fit" by squeezing,
                    // and the first (full) one would always win.
                    Text(crumb.name).font(.callout).lineLimit(1).truncationMode(.head)
                        .fixedSize(horizontal: !(flexibleTail && idx == shown.count - 1),
                                   vertical: false)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                // Every item acts on THIS crumb's folder, not browser.currentURL —
                // `crumb.url` is captured per iteration, which is the whole reason a
                // per-segment menu is worth having (right-clicking "Users" and getting
                // the deepest folder's menu would be worse than no menu).
                .contextMenu { crumbMenu(crumb.url) }
            }
        }
    }

    // Reuses the sidebar's shared folder commands verbatim, plus the two that only
    // make sense for a real directory on disk.
    @ViewBuilder private func crumbMenu(_ url: URL) -> some View {
        folderLocationMenu(url, browser: browser, model: model)
        Divider()
        Button("Get Info") { showFolderInfo(url, browser: browser) }
        if favStore.contains(url) {
            Button("Unpin from Sidebar") { FavoritesStore.shared.remove(url: url) }
        } else {
            Button("Pin to Sidebar") { FavoritesStore.shared.add(url) }
        }
    }
}

// Small leading icon for list/column rows that upgrades to a real thumbnail
// (images, video poster frames, PSD, PDF…) once QuickLook produces one. Lazy
// per row via .onAppear, so only rows scrolled into view do any work; folders
// and non-visual files just keep their type icon.
struct ThumbIcon: View {
    let item: FileItem
    @ObservedObject var browser: Browser
    var size: CGFloat = 16
    @State private var thumb: NSImage?
    var body: some View {
        Group {
            if let thumb { Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit) }
            else { Image(nsImage: browser.icon(for: item)).resizable() }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard thumb == nil, !item.isDirectory, isThumbnailable(item.url) else { return }
            ThumbnailCache.shared.thumbnail(for: item.url, size: max(40, size * 2)) { if let t = $0 { thumb = t } }
        }
        .onDisappear {
            if thumb == nil { ThumbnailCache.shared.cancel(for: item.url, size: max(40, size * 2)) }
        }
    }
}

// Inline rename field: an NSTextField bridge, not a plain SwiftUI TextField,
// because only AppKit gives control over the INITIAL selection range — needed to
// select just the base name and exclude the extension (Explorer/Finder's rename
// behavior), which a fresh TextField would otherwise select-all or select-none.
// The address bar's editor: an NSTextField bridge for the same reason RenameField is
// one — SwiftUI's @FocusState could not be made to focus this field reliably. Because
// the field is INSERTED and REMOVED (the bar is a truncated Text the rest of the time),
// SwiftUI keeps the focus value pointing at it after removal and re-syncs that value
// back from the platform responder, so the "focus me" assignment on the next open was
// a same-value write that moved nothing. Measured on every variation tried (two Bools,
// one enum, clearing on submit/disappear): ⌘L focused the bar once per launch, and
// after that the caret went to the SEARCH box instead. Taking first responder here has
// no SwiftUI state that can go stale, and it selects the whole path for free.
struct AddressField: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: text)
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        f.placeholderString = "Type a path and press Return"
        f.delegate = context.coordinator
        f.lineBreakMode = .byTruncatingHead
        DispatchQueue.main.async {
            guard let window = f.window else { return }
            window.makeFirstResponder(f)
            f.currentEditor()?.selectAll(nil)   // whole path selected: type to replace it
        }
        return f
    }
    // Only push text IN when the field isn't being typed in, so navigation that
    // rewrites pathText while the bar is open can't fight the caret.
    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.currentEditor() == nil, nsView.stringValue != text { nsView.stringValue = text }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: AddressField
        private var finished = false
        init(_ parent: AddressField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.text = f.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finished = true; parent.text = control.stringValue; parent.onCommit(); return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finished = true; parent.onCancel(); return true
            }
            return false
        }
        // Unlike RenameField, ending the edit any other way (clicking a file, tabbing
        // away) must NOT commit: navigating somewhere because the caret happened to
        // leave a half-typed path is the opposite of what the user asked for. Only
        // Return navigates — which is also how the bar behaved before it could be
        // opened with ⌘L at all.
        func controlTextDidEndEditing(_ obj: Notification) {
            guard !finished else { return }
            finished = true
            parent.onCancel()
        }
    }
}

struct RenameField: NSViewRepresentable {
    let initialText: String
    let excludeExtension: Bool
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: initialText)
        f.isBordered = false
        f.drawsBackground = true
        f.focusRingType = .default
        f.font = .systemFont(ofSize: NSFont.systemFontSize)
        f.delegate = context.coordinator
        f.lineBreakMode = .byTruncatingTail
        DispatchQueue.main.async {
            guard let window = f.window else { return }
            window.makeFirstResponder(f)
            let base = (initialText as NSString).deletingPathExtension
            if excludeExtension, !base.isEmpty, base.count < initialText.count {
                f.currentEditor()?.selectedRange = NSRange(location: 0, length: base.utf16.count)
            } else {
                f.currentEditor()?.selectAll(nil)
            }
        }
        return f
    }
    func updateNSView(_ nsView: NSTextField, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCommit: onCommit, onCancel: onCancel) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let onCommit: (String) -> Void
        let onCancel: () -> Void
        private var finished = false
        init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCommit = onCommit; self.onCancel = onCancel
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finished = true; onCommit(control.stringValue); return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finished = true; onCancel(); return true
            }
            return false
        }
        // Clicking away or Tab-ing out ends editing without going through
        // doCommandBy above — Finder treats that as a commit, not a cancel, so
        // this mirrors that rather than silently discarding the typed name.
        func controlTextDidEndEditing(_ obj: Notification) {
            guard !finished, let field = obj.object as? NSTextField else { return }
            finished = true
            onCommit(field.stringValue)
        }
    }
}

struct NameCell: View {
    let item: FileItem
    @ObservedObject var browser: Browser
    @State private var cloud: CloudBadge?
    var body: some View {
        HStack(spacing: 6) {
            ThumbIcon(item: item, browser: browser)
            if browser.renamingID == item.id {
                RenameField(initialText: item.name, excludeExtension: !item.isDirectory,
                           onCommit: { browser.rename(id: item.id, to: $0); browser.renamingID = nil },
                           onCancel: { browser.renamingID = nil })
                    .frame(maxWidth: 260)
            } else {
                Text(item.name).lineLimit(1)
            }
            cloudBadgeView(cloud)
        }
        .onAppear { cloud = cloudBadge(for: item.url) }
        .onChange(of: browser.badgeGeneration) { cloud = cloudBadge(for: item.url) }
    }
}

let standardTags = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]

struct TagsMenu: View {
    @ObservedObject var browser: Browser
    let ids: Set<String>
    var body: some View {
        Menu("Tags") {
            ForEach(standardTags, id: \.self) { t in
                Button { browser.toggleTag(ids, t) } label: {
                    Label(t, systemImage: appliedToAll(t) ? "checkmark.circle.fill" : "circle")
                }
            }
            Divider()
            Button("Clear Tags") { browser.setTags(ids, tags: []) }
        }
    }
    private func appliedToAll(_ t: String) -> Bool {
        let sel = browser.items.filter { ids.contains($0.id) }
        return !sel.isEmpty && sel.allSatisfy { $0.tags.contains(t) }
    }
}

struct OpenWithMenu: View {
    let urls: [URL]
    var body: some View {
        Menu("Open With") {
            if let first = urls.first {
                ForEach(applicationsToOpen(first), id: \.self) { app in
                    Button(app.deletingPathExtension().lastPathComponent) { openWith(urls, app: app) }
                }
                Divider()
            }
            Button("Other Application…") { if let app = chooseApplication() { openWith(urls, app: app) } }
            if urls.count == 1, let f = urls.first {
                Button("Always Open With…") {
                    if let app = chooseApplication() { setDefaultApp(app, for: f); openWith([f], app: app) }
                }
            }
        }
    }
}

// The list/detail view, hand-built on NSTableView (via NSViewRepresentable)
// instead of SwiftUI's Table. Table repeatedly broke plain click-to-select and
// double-click-to-open the moment anything (a nested gesture, a nested drop
// destination) was attached inside a row or cell — confirmed live, twice, as two
// separate regressions. NSTableView gives direct control over exactly when a
// click starts a drag vs. a selection vs. a rename, with zero risk of two
// recognizers fighting over the same event. Column CONTENT is still ordinary
// SwiftUI (NameCell, DateCell, SizeCell, MetadataCell, TagsCell) hosted per cell
// via NSHostingView — only the outer shell (rows, selection, sorting, drag-and-
// drop, the context menu) is native.
struct FileTableView: View {
    let model: AppModel
    @ObservedObject var browser: Browser
    @State private var dropTargeted = false

    var body: some View {
        NativeFileTable(model: model, browser: browser, open: { openFileItems($0, browser: browser) },
                        contextMenu: { AnyView(fileContextMenu(model: model, browser: browser, ids: $0)) },
                        isTargeted: $dropTargeted)
            .overlay {
                if browser.visibleItems().isEmpty {
                    emptyFolderPlaceholder
                } else if dropTargeted {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2).padding(2).allowsHitTesting(false)
                }
            }
    }

    // Purely visual now — the native table underneath already accepts a drop
    // anywhere in its bounds (including when it has zero rows), so this doesn't
    // need its own drop target, just the empty-state message.
    private var emptyFolderPlaceholder: some View {
        ZStack {
            (dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 34)).foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.6))
                Text("This folder is empty").font(.title3).foregroundStyle(.secondary)
                Text("Drag files here to add them").font(.callout).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

func openFileItems(_ ids: Set<String>, browser: Browser) {
    let chosen = browser.items.filter { ids.contains($0.id) }
    if chosen.count == 1, let only = chosen.first { openItem(only, browser); return }
    for it in chosen { NSWorkspace.shared.open(it.url) }
}

// THE list of "New …" items, in one place.
//
// Four surfaces offer it — the toolbar's New button, List view's blank-area menu,
// Icon view's blank-area menu and the file context menu — and they were previously
// four hand-written copies that had already drifted apart once. Anything added here
// appears in all of them at once. (The menu-bar File menu is an AppKit NSMenu and
// can't share a ViewBuilder; it calls the same Browser methods, which is where the
// behaviour actually lives.)
//
// `ids` is what the selection-dependent entries act on: the right-clicked items for a
// context menu, `browser.selection` for the toolbar and the blank-area menus.
@ViewBuilder
func newItemsMenu(_ browser: Browser, ids: Set<FileItem.ID>) -> some View {
    Button { browser.newFolder() } label: { Label("Folder", systemImage: "folder.badge.plus") }
    if !ids.isEmpty {
        Button { browser.newFolderWithSelection(ids) } label: {
            Label(ids.count == 1 ? "Folder with Selection" : "Folder with Selection (\(ids.count) items)",
                  systemImage: "folder.badge.gearshape")
        }
    }
    Divider()
    Button { browser.newTextFile() } label: { Label("Text File", systemImage: "doc.badge.plus") }
    Button { browser.newRichTextFile() } label: { Label("Rich Text Document", systemImage: "doc.richtext") }
    // Zip and Alias need something to act ON, so they're absent rather than disabled
    // when nothing is selected — an "empty archive" is not a thing anyone wants, and
    // zip refuses to create one anyway.
    if !ids.isEmpty {
        Divider()
        Button { browser.compress(ids) } label: { Label("Zip Archive from Selection", systemImage: "doc.zipper") }
        Button { browser.makeAlias(ids) } label: { Label("Alias of Selection", systemImage: "arrow.uturn.forward") }
    }
}

// "Send To" (Windows Explorer parity), mapped onto macOS. Everything here COPIES —
// never moves — because that's what Explorer's Send To does, and because a move to a
// removable drive that turns out to be full or read-only would take the original with it.
@ViewBuilder
func sendToMenu(_ browser: Browser, ids: Set<FileItem.ID>) -> some View {
    Menu {
        let home = FileManager.default.homeDirectoryForCurrentUser
        Button("Desktop") { browser.sendTo(ids, folder: home.appendingPathComponent("Desktop")) }
        Button("Documents") { browser.sendTo(ids, folder: home.appendingPathComponent("Documents")) }
        Button("Downloads") { browser.sendTo(ids, folder: home.appendingPathComponent("Downloads")) }
        Button("Home Folder") { browser.sendTo(ids, folder: home) }
        Divider()
        Button("Compressed (zipped) Folder") { browser.compress(ids) }
        // Mail only if the system can actually do it. canPerform() is the whole point:
        // with no mail account configured, perform() silently does nothing, and a menu
        // item that quietly fails is worse than one that isn't there.
        let selURLs = browser.urls(ids)
        if let mail = NSSharingService(named: .composeEmail), mail.canPerform(withItems: selURLs) {
            Button("Mail Recipient") { mail.perform(withItems: selURLs) }
        }
        // Removable drives, enumerated live. Network shares are excluded even though
        // volumeLocations() marks them ejectable too — Explorer's Send To means "a stick
        // you're about to walk away with", and a slow SMB copy started from a submenu
        // with no obvious destination is a nasty surprise.
        let drives = volumeLocations().filter { $0.ejectable && !$0.isNetwork }
        if !drives.isEmpty {
            Divider()
            ForEach(drives, id: \.url) { d in
                Button { browser.sendTo(ids, folder: d.url) } label: { Label(d.name, systemImage: d.symbol) }
            }
        }
    } label: {
        Label("Send To", systemImage: "paperplane")
    }
}

// Shift+right-click = Windows 11's "Show more options". True only when Shift was held
// for the click that ASKED for this menu.
//
// Two sources, and both are needed. The click event's OWN flags come first: that is the
// only reading tied to the gesture that opened this menu, and it is what a right-click
// carries no matter which of the three surfaces built the menu (NSTableView's
// menu(for:), MarqueeCatcher's NSHostingMenu, or SwiftUI's .contextMenu — all three are
// constructed while the right-mouse-down is NSApp.currentEvent). The live keyboard state
// is the fallback for the case where the current event is something else entirely (a
// menu-tracking or periodic event), where "is Shift down right now" is the best answer
// available. Reading ONLY the live state was measured NOT to work with synthesized
// input, so the event flags are not a redundant belt.
func contextMenuIsExtended() -> Bool {
    if let e = NSApp.currentEvent {
        switch e.type {
        case .rightMouseDown, .rightMouseUp, .leftMouseDown, .leftMouseUp:
            return e.modifierFlags.contains(.shift)
        default: break
        }
    }
    return NSEvent.modifierFlags.contains(.shift)
}

// The extra developer/power items Shift+right-click reveals.
//
// Deliberately NOT including a "Copy POSIX Path": that is byte-for-byte what the plain
// "Copy Path" above already does, and two items with identical behaviour is how a menu
// starts lying about itself.
@ViewBuilder
func extendedCopyItems(_ browser: Browser, ids: Set<FileItem.ID>) -> some View {
    // A Section, not a Divider + Text: a bare Text inside a menu ViewBuilder was
    // measured to silently drop ITSELF AND EVERY BUTTON AFTER IT from the rendered
    // NSMenu — the flag was read correctly and the extra items simply never appeared.
    // Only real menu content (Button/Divider/Menu/Section) survives the conversion.
    Section("More Options") {
        Button("Copy file:// URL") { browser.copyFileURL(ids) }
        Button("Copy Name Without Extension") { browser.copyNameWithoutExtension(ids) }
        Button("Copy as Markdown Link") { browser.copyMarkdownLink(ids) }
        Button("Copy Enclosing Folder Path") { browser.copyParentPath(ids) }
    }
}

/// What replaces "Move to Trash" when you're already looking AT the Trash.
///
/// Put Back is offered only for items whose original location is actually known, and
/// the disabled item says so rather than looking live and doing nothing. For the rest
/// there is "Move to…", which asks where — because the one thing a Restore must never
/// do is guess and drop a file somewhere the user won't think to look.
@ViewBuilder
func trashItemMenu(_ browser: Browser, ids: Set<FileItem.ID>) -> some View {
    let sel = browser.items.filter { ids.contains($0.id) }
    let known = sel.filter { browser.trashOrigin(of: $0) != nil }
    if known.count == sel.count, let first = known.first {
        // No force-unwrap on the second lookup. It was only safe because the filter and
        // the unwrap happened in one synchronous pass — and loadTrashPutBack republishes
        // trashPutBack from a background read, so an origin that existed a moment ago can
        // be gone by the next evaluation. A crash in a menu builder is not worth the
        // shorter line; a plain "Put Back" reads fine.
        let title = (sel.count == 1 ? browser.trashOrigin(of: first)?.directory : nil)
            .map { "Put Back to “\($0)”" } ?? "Put Back"
        Button(title) { browser.putBack(ids) }
    } else if known.isEmpty {
        Button("Put Back") {}
            .disabled(true)
            .help("macOS didn't record where \(sel.count == 1 ? "this item came" : "these items came") from — use “Move to…” instead.")
    } else {
        Button("Put Back (\(known.count) of \(sel.count))") { browser.putBack(ids) }
            .help("\(sel.count - known.count) of these have no recorded original location.")
    }
    Button("Move to…") { browser.moveOutOfTrash(ids) }
    Divider()
    Button("Delete Immediately…") { browser.deleteFromTrash(ids) }
    Button("Empty Trash…") { confirmEmptyTrash(browser) }
}

// Shared right-click menu for a file/folder selection — used by both List view
// (NativeFileTable) and Icon view, so a fix or an added action lands in every
// view mode at once instead of drifting between hand-duplicated copies.
@ViewBuilder
func fileContextMenu(model: AppModel, browser: Browser, ids: Set<FileItem.ID>) -> some View {
        if !ids.isEmpty {
            Button("Open") { openFileItems(ids, browser: browser) }
            if ids.count == 1, let it = browser.items.first(where: { $0.id == ids.first }), it.isDirectory {
                Button("Open in New Tab") { model.newTab(at: it.url) }
                Button("Open in Second Pane") { model.openInSecondPane(it.url) }
            }
            if let pair = browser.imagePair(ids) {
                Button("Swipe Compare") { CompareController.show(left: pair.0, right: pair.1) }
            }
            let selURLs = browser.items.filter { ids.contains($0.id) }.map { $0.url }
            if selURLs.contains(where: { !$0.hasDirectoryPath }) { OpenWithMenu(urls: selURLs.filter { !$0.hasDirectoryPath }) }
            Button("Quick Look") { QuickLook.shared.show(browser.items.filter { ids.contains($0.id) }.map { $0.url }) }
            Button("Reveal in Finder") { browser.revealInFinder(ids) }
            Divider()
            if ids.count == 1 { Button("Rename…") { promptRename(browser, ids.first!) } }
            else { Button("Batch Rename…") { BatchRenameController.shared.show(browser, browser.items.filter { ids.contains($0.id) }) } }
            TagsMenu(browser: browser, ids: ids)
            if ids.count == 1 { Button("Edit Comment…") { promptComment(browser, ids.first!) } }
            Button("Duplicate") { browser.duplicate(ids) }
            Button("Make Alias") { browser.makeAlias(ids) }
            Button("Make Symbolic Link") { browser.makeSymlink(ids) }
            if PhotoshopIcon.image != nil {
                let sel = browser.items.filter { ids.contains($0.id) }
                let imgCount = sel.filter { !$0.isDirectory && isImageFile($0.url) }.count
                let dirs = sel.filter { $0.isDirectory }
                if imgCount >= 1 {
                    Button { browser.removeBackground(ids) } label: { psLabel(imgCount == 1 ? "Remove BG" : "Remove BG (\(imgCount) images)") }
                } else if dirs.count == 1, sel.count == 1 {
                    Button { browser.batchRemoveBackground(ids) } label: { psLabel("Batch Remove BG") }
                }
                let psdCount = sel.filter { !$0.isDirectory && isPhotoshopDocument($0.url) }.count
                if psdCount >= 1 {
                    Button { browser.exportPNG(ids) } label: { psLabel(psdCount == 1 ? "Quick Export as PNG" : "Quick Export as PNG (\(psdCount) PSDs)") }
                }
            }
            if AfterEffectsIcon.image != nil {
                let sel = browser.items.filter { ids.contains($0.id) }
                let pngCount = sel.filter { !$0.isDirectory && $0.url.pathExtension.lowercased() == "png" }.count
                let dirs = sel.filter { $0.isDirectory }
                if pngCount >= 1 {
                    Button { browser.chromaKeyBackground(ids) } label: { aeLabel(pngCount == 1 ? "Chroma Key BG" : "Chroma Key BG (\(pngCount) images)") }
                } else if dirs.count == 1, sel.count == 1 {
                    Button { browser.batchChromaKeyBackground(ids) } label: { aeLabel("Batch Chroma Key BG") }
                }
            }
            if browser.items.contains(where: { ids.contains($0.id) && !$0.isDirectory && isImageFile($0.url) }) {
                prepForAIMenu { c, ratio in browser.fillBackground(ids, c, ratio: ratio) }
                upscaleMenu(fal: { opt in browser.upscale(ids, opt) },
                            imagen: { f in browser.upscaleImagen(ids, factor: f) })
                restyleMenuItem(browser.items.filter { ids.contains($0.id) && !$0.isDirectory }.map(\.url)) { out in
                    browser.refreshAndReveal([out])
                }
            } else if browser.items.filter({ ids.contains($0.id) }).count == 1,
                      browser.items.first(where: { ids.contains($0.id) })?.isDirectory == true {
                upscaleMenu(label: "Batch Upscale (AI)",
                            fal: { opt in browser.batchUpscale(ids, opt) },
                            imagen: { f in browser.batchUpscaleImagen(ids, factor: f) })
            }
            if browser.items.contains(where: { ids.contains($0.id) && $0.isDirectory }) {
                Button("Calculate Size") {
                    for it in browser.items where ids.contains(it.id) && it.isDirectory { FolderSizeCache.shared.compute(it.url) }
                }
                let dirs = browser.items.filter { ids.contains($0.id) && $0.isDirectory }
                if dirs.count == 1, FavoritesStore.shared.contains(dirs[0].url) {
                    Button("Unpin from Sidebar") { FavoritesStore.shared.remove(url: dirs[0].url) }
                } else {
                    Button("Pin to Sidebar") { for it in dirs { FavoritesStore.shared.add(it.url) } }
                }
            }
            Button("Get Info") { showInfo(browser, ids) }
            Button("Compress") { browser.compress(ids) }
            if browser.items.contains(where: { ids.contains($0.id) && isArchive($0.url) }) {
                Button("Extract") { browser.extract(ids) }
            }
            Divider()
            sendToMenu(browser, ids: ids)
            // Same "New" list as the blank-area menu and the toolbar, driven by the
            // right-clicked items — that's what makes "Folder with Selection" reachable
            // from a right-click on the files it should wrap up.
            Menu { newItemsMenu(browser, ids: ids) } label: { Label("New", systemImage: "plus") }
            Divider()
            Button("Share…") { shareItems(browser.items.filter { ids.contains($0.id) }.map { $0.url }) }
            if let it = browser.items.first(where: { $0.id == ids.first }) {
                Button("Open in Terminal") { openInTerminal(it.isDirectory ? it.url : browser.currentURL) }
            }
            Divider()
            Button("Copy") { browser.copyFiles(ids) }
            Button("Cut") { browser.cutFiles(ids) }
            Button("Paste") { browser.pasteFiles() }
            if !browser.isGoogleDriveSelection(ids) {
                Button("Copy Path") { browser.copyPath(ids) }
                // Windows' "Copy as path" — the same path in QUOTED form, so it can be
                // pasted straight into a shell. The suffix is in the title because
                // "Copy Path" and "Copy as Path" are otherwise indistinguishable.
                Button("Copy as Path (Quoted)") { browser.copyQuotedPath(ids) }
            }
            Button("Copy Name") { browser.copyName(ids) }
            if browser.isGoogleDriveSelection(ids) {
                Button { browser.copyGoogleDriveLink(ids) } label: { gdLabel("Copy Web Link") }
                Button { browser.copyGoogleDrivePath(ids) } label: { gdLabel("Copy Local Path") }
                Button { browser.copyPath(ids) } label: { gdLabel("Copy Path for Claude") }
                Button { browser.openGoogleDriveLink(ids) } label: { gdLabel("Open in Web") }
                // Only the applicable one — never both.
                if browser.driveSelectionIsOffline(ids) {
                    Button { browser.setDriveAvailability(ids, offline: false) } label: { gdLabel("Make available online only") }
                } else {
                    Button { browser.setDriveAvailability(ids, offline: true) } label: { gdLabel("Make available offline") }
                }
            }
            if contextMenuIsExtended() { extendedCopyItems(browser, ids: ids) }
            Divider()
            if browser.isTrash {
                trashItemMenu(browser, ids: ids)
            } else {
                Button("Move to Trash") { browser.moveToTrash(ids) }
            }
        } else if browser.isTrash {
            Button("Empty Trash…") { confirmEmptyTrash(browser) }
            Button("Refresh") { browser.refresh() }
        } else {
            Button("Paste") { browser.pasteFiles() }
            Menu { newItemsMenu(browser, ids: browser.selection) } label: { Label("New", systemImage: "plus") }
            Button("Calculate All Sizes") {
                for it in browser.items where it.isDirectory { FolderSizeCache.shared.compute(it.url) }
            }
            Button("Reveal in Finder") { browser.revealInFinder([]) }
            Button("Copy Path") { browser.copyPath([]) }
            Button("Copy as Path (Quoted)") { browser.copyQuotedPath([]) }
            if contextMenuIsExtended() { extendedCopyItems(browser, ids: []) }
        }
}

// One row is either a group-section header or a real file/folder.
private enum FileRow {
    case header(String)
    case item(FileItem)
}

// A column: identifier, header title, widths, default visibility, and (if
// sortable) how to build the KeyPathComparator for a given direction. Ext and
// the three extra date columns ARE sortable here (matching the original Table's
// per-column `value:` bindings) even though Browser's own SortField/setSort only
// names the four primary ones the toolbar Sort menu exposes — clicking one of
// these headers sets browser.sortOrder directly.
private struct FileColumnDef {
    let id: String
    let title: String
    let minWidth: CGFloat
    let idealWidth: CGFloat
    let defaultVisible: Bool
    let comparator: ((Bool) -> KeyPathComparator<FileItem>)?
}

private let fileColumnDefs: [FileColumnDef] = [
    FileColumnDef(id: "name", title: "Name", minWidth: 160, idealWidth: 260, defaultVisible: true,
                 comparator: { KeyPathComparator(\FileItem.name, order: $0 ? .forward : .reverse) }),
    FileColumnDef(id: "modified", title: "Date Modified", minWidth: 150, idealWidth: 185, defaultVisible: true,
                 comparator: { KeyPathComparator(\FileItem.modified, order: $0 ? .forward : .reverse) }),
    FileColumnDef(id: "size", title: "Size", minWidth: 44, idealWidth: 58, defaultVisible: true,
                 comparator: { KeyPathComparator(\FileItem.size, order: $0 ? .forward : .reverse) }),
    FileColumnDef(id: "kind", title: "Kind", minWidth: 90, idealWidth: 130, defaultVisible: true,
                 comparator: { KeyPathComparator(\FileItem.kind, order: $0 ? .forward : .reverse) }),
    FileColumnDef(id: "created", title: "Date Created", minWidth: 150, idealWidth: 185, defaultVisible: false,
                 comparator: { KeyPathComparator(\FileItem.created, order: $0 ? .forward : .reverse) }),
    FileColumnDef(id: "accessed", title: "Date Last Opened", minWidth: 150, idealWidth: 185, defaultVisible: false,
                 comparator: { KeyPathComparator(\FileItem.accessed, order: $0 ? .forward : .reverse) }),
    FileColumnDef(id: "dateAdded", title: "Date Added", minWidth: 150, idealWidth: 185, defaultVisible: false,
                 comparator: { KeyPathComparator(\FileItem.dateAdded, order: $0 ? .forward : .reverse) }),
    FileColumnDef(id: "extension", title: "Ext", minWidth: 44, idealWidth: 56, defaultVisible: false,
                 comparator: { KeyPathComparator(\FileItem.ext, order: $0 ? .forward : .reverse) }),
    // Time and Dimensions sort through MediaSortKey rather than a bare Double, because
    // their values arrive from Spotlight asynchronously: see MediaSortKey for why absent
    // and not-yet-loaded both have to collapse to one end, and why the file name is
    // folded into the key. The cache is filled before the sort lands — see
    // Browser.sortOrder / prefetchMetadataIfSortingOnIt.
    FileColumnDef(id: "duration", title: "Time", minWidth: 50, idealWidth: 64, defaultVisible: false,
                 comparator: { KeyPathComparator(\FileItem.durationSortKey, order: $0 ? .forward : .reverse) }),
    FileColumnDef(id: "dimensions", title: "Dimensions", minWidth: 90, idealWidth: 110, defaultVisible: false,
                 comparator: { KeyPathComparator(\FileItem.dimensionsSortKey, order: $0 ? .forward : .reverse) }),
    FileColumnDef(id: "owner", title: "Owner", minWidth: 70, idealWidth: 100, defaultVisible: false,
                 comparator: { KeyPathComparator(\FileItem.owner, order: $0 ? .forward : .reverse) }),
    // Tags stays unsortable on purpose: an item can carry SEVERAL tags, so there is no
    // single value to order by, and sorting on the joined string would rank "Blue, Red"
    // above "Red" for reasons no one could predict from looking at the column.
    FileColumnDef(id: "tags", title: "Tags", minWidth: 90, idealWidth: 140, defaultVisible: false, comparator: nil),
]

/// Every column id, in header order — the ONE list both column menus are built from.
let fileColumnIDs: [String] = fileColumnDefs.map(\.id)
/// The columns shown when nothing has been customized. Also what "Restore Defaults"
/// falls back to.
let defaultVisibleColumnIDs: [String] = fileColumnDefs.filter(\.defaultVisible).map(\.id)
func fileColumnTitle(_ id: String) -> String { fileColumnDefs.first { $0.id == id }?.title ?? id }
/// True when this column's values come from Spotlight and therefore have to be
/// prefetched before a sort on them means anything.
func fileColumnNeedsMetadata(_ id: String) -> Bool { id == "duration" || id == "dimensions" }

/// The rules BOTH column pickers obey — the header right-click menu and View ▸ Columns.
///
/// One source deliberately, because the header menu was for a long time the only way to
/// reach column visibility at all (undiscoverable), and adding a second entry point is
/// precisely how two menus start listing different columns. Neither menu decides anything
/// for itself: both enumerate `togglableIDs` and both call `toggled`.
enum ColumnMenu {
    /// Name is excluded: hiding it would leave rows with no filename and no way to click
    /// one, and the rename field lives in that column.
    static let togglableIDs: [String] = fileColumnIDs.filter { $0 != "name" }

    static func toggled(_ visible: Set<String>, id: String) -> Set<String> {
        guard id != "name" else { return visible }
        var out = visible
        if out.contains(id) { out.remove(id) } else { out.insert(id) }
        out.insert("name")            // never reachable as a toggle, but never lost either
        return out
    }
}

// NSTableView subclass that lets a click reach Table's OWN normal handling
// (selection, drag-start) FIRST via super.mouseDown, and only afterward —
// never instead of, never racing it — reports "this looked like a rename
// candidate" so Browser.handleNameTap can apply its own click-pause-click
// timing check. This is the whole reason for this rewrite: a nested SwiftUI
// gesture recognizer or drop destination competes with Table's native click
// handling for the same event; sequencing after super.mouseDown cannot.
private final class ClickTimingTableView: NSTableView {
    var onNameClickCandidate: ((Int) -> Void)?
    var onContextMenuRequest: ((Int) -> NSMenu?)?
    var onDragTargeted: ((Bool) -> Void)?
    /// Clicking a group header collapses/expands it. Reported from here rather than from a
    /// button or a SwiftUI gesture inside the header cell so there is exactly ONE handler
    /// for the click — the failure mode when two exist is a toggle that fires twice and
    /// looks like nothing happened.
    var onGroupRowClick: ((Int) -> Void)?
    var isGroupRowAt: ((Int) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        // Parity with icon view (whose clicks route through Browser.click): clicking
        // the file list takes keyboard focus away from the address/search fields, so
        // typing afterwards is type-to-select — not characters silently appended to a
        // still-focused address bar. Windows Explorer behaves the same way.
        NotificationCenter.default.post(name: .navigatorResignFields, object: nil)
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        // Group headers are handled entirely here and super is deliberately NOT called:
        // the row is unselectable, so super would only start a drag-select from it, and a
        // double-click on a header would otherwise reach doubleAction and try to open a
        // selection the click never made.
        if clickedRow >= 0, isGroupRowAt?(clickedRow) == true {
            if event.clickCount == 1 { onGroupRowClick?(clickedRow) }
            return
        }
        let clickedColumn = column(at: point)
        let wasSoleSelected = clickedRow >= 0 && selectedRowIndexes.count == 1 && selectedRowIndexes.contains(clickedRow)
        let isNameColumn = clickedColumn >= 0 && tableColumns.indices.contains(clickedColumn)
            && tableColumns[clickedColumn].identifier.rawValue == "name"
        super.mouseDown(with: event)
        if event.clickCount == 1, wasSoleSelected, isNameColumn, clickedRow >= 0 {
            onNameClickCandidate?(clickedRow)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenuRequest?(row(at: convert(event.locationInWindow, from: nil)))
    }
    // The highlight flag is published ASYNCHRONOUSLY, never synchronously inside these
    // callbacks. Writing SwiftUI @State from here re-enters the view update on the spot,
    // and that update path can call reloadData()/selectRowIndexes() on this very table
    // WHILE a drag is in flight — which throws away the drag's drop targeting and makes
    // every drop silently do nothing. (That's what broke dragging files onto a folder
    // row after this view was rewritten on NSTableView.) The coordinator also refuses to
    // touch the table at all while `isDragActive`; both halves are needed, because a
    // deferred update can still land mid-drag.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = super.draggingEntered(sender)
        DispatchQueue.main.async { [weak self] in self?.onDragTargeted?(true) }
        return op
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        DispatchQueue.main.async { [weak self] in self?.onDragTargeted?(false) }
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        DispatchQueue.main.async { [weak self] in self?.onDragTargeted?(false) }
    }

    // SOURCE side of the drag (the two above are the destination side).
    //
    // These are `override`s of NSDraggingSource methods NSTableView already implements,
    // not optional delegate callbacks — so the compiler guarantees they're wired up. A
    // mistyped optional delegate method would just silently never fire, which is not a
    // risk worth taking while chasing this.
    //
    // Reports how many rows AppKit actually decided to drag versus how many are
    // selected: that single comparison distinguishes "the table only put one row in the
    // drag" from "all rows were dragged but the drop only took one".
    var onDragSessionBegin: ((_ selectedRows: Int, _ pasteboardItems: Int) -> Void)?
    var onDragSessionEnd: (() -> Void)?

    override func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        super.draggingSession(session, willBeginAt: screenPoint)
        onDragSessionBegin?(selectedRowIndexes.count,
                            session.draggingPasteboard.pasteboardItems?.count ?? -1)
    }
    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                                 operation: NSDragOperation) {
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
        onDragSessionEnd?()
    }
}

// A reusable NSTableCellView holding one NSHostingView, whose rootView is
// swapped in place on reuse instead of tearing the hosting view down — the key
// to letting each cell's SwiftUI content (NameCell etc.) stay a live, reactive
// view across ordinary redraws instead of restarting every scroll/update.
// The SwiftUI host for a cell's content, made TRANSPARENT to the mouse.
//
// This is what makes dragging work. NSHostingView hit-tests like any other view, so
// with plain SwiftUI content it claims the mouse wherever a Text sits — verified by
// hit-testing this exact cell layout: a press on the filename returned
// NSHostingView<AnyView>, while the icon and the row's edges returned NSTableRowView.
// NSTableView therefore never saw the mouseDown over a filename and never started its
// drag tracking; the event fell through the responder chain and merely selected the
// row. The symptom was "it just selects instead of dragging", and it was worst exactly
// where people grab a file — on its name.
//
// Returning nil from hitTest hands every click, drag and double-click straight to the
// table, which is what owns selection, dragging and opening.
//
// The exception is real editable content: the inline rename field is an NSTextField
// living inside this host, and it has to receive clicks so the caret can be placed.
// `acceptsEvents` is set explicitly by the cell rather than sniffed from the view
// tree — an earlier version scanned the subtree for an NSTextField and got it wrong,
// because SwiftUI materialises an NSViewRepresentable's view on its own schedule, so
// the field often doesn't exist yet at hit-test time. The coordinator already knows
// exactly which row is renaming; that is the reliable signal.
//
// Known trade-off: SwiftUI .help() tooltips inside cells no longer appear, since a
// tooltip needs the hit-test. Working drag-and-drop is worth more than a tooltip.
private final class PassthroughHostingView: NSHostingView<AnyView> {
    var acceptsEvents = false
    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsEvents ? super.hitTest(point) : nil
    }
}

// The cell view is transparent to the mouse for the same reason its hosting view is —
// and this half matters specifically for MULTI-row drag.
//
// With only the hosting view transparent, a press still landed on this cell view, so
// NSTableView saw it only second-hand via the responder chain. AppKit's "a press inside
// an existing selection drags the WHOLE selection" logic runs in NSTableView's own mouse
// tracking, and it wants the press to arrive at the table/row view the way it does in a
// stock text-based table (where a non-editable NSTextField declines the hit for exactly
// this reason). Declining here restores that arrangement: the press reaches
// NSTableRowView → NSTableView, and a drag from within a selection carries every
// selected row instead of just the one grabbed.
private final class HostingTableCellView: NSTableCellView {
    var acceptsEvents = false
    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsEvents ? super.hitTest(point) : nil
    }
    private let hosting = PassthroughHostingView(rootView: AnyView(EmptyView()))
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        addSubview(hosting)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            hosting.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    // NSHostingView centers its rootView within its own frame by default when
    // given more space than the content's ideal size — which is exactly what
    // happens here, since the hosting view is pinned to the cell's full width.
    // The explicit leading-aligned frame is what makes cell content actually
    // left-align like every other column in a normal table.
    /// `interactive` = this cell currently holds an editable control (the rename field),
    /// so it must receive mouse events. Everything else stays transparent so the table
    /// owns selection, dragging and double-click.
    func update(_ content: AnyView, interactive: Bool = false) {
        acceptsEvents = interactive          // the cell itself, so the press can reach the table
        hosting.acceptsEvents = interactive  // and the SwiftUI host inside it
        hosting.rootView = AnyView(content.frame(maxWidth: .infinity, alignment: .leading))
    }
}

// A group header row: disclosure triangle + title, both drawn by AppKit.
//
// Not a HostingTableCellView like the data cells, on purpose. This row's only job is to
// be clicked, and the whole row is the target — wrapping a SwiftUI view in an
// NSHostingView here would put a second mouse handler in the path for one gesture, which
// is the shape of bug this file has been bitten by repeatedly. Plain NSViews decline the
// hit and the click reaches the table.
private final class GroupHeaderCellView: NSTableCellView {
    private let chevron = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = .boldSystemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        chevron.contentTintColor = .secondaryLabelColor
        chevron.imageScaling = .scaleProportionallyDown
        textField = label
        for v in [chevron, label] as [NSView] {
            addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 11),
            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(title: String, collapsed: Bool) {
        label.stringValue = title
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
                                accessibilityDescription: collapsed ? "Expand group" : "Collapse group")
    }
    /// Declines the mouse for the same reason the data cells do — the click has to reach
    /// NSTableView, which is where the collapse toggle is wired up.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct NativeFileTable: NSViewRepresentable {
    let model: AppModel
    @ObservedObject var browser: Browser
    let open: (Set<String>) -> Void
    let contextMenu: (Set<FileItem.ID>) -> AnyView
    @Binding var isTargeted: Bool

    func makeCoordinator() -> FileTableCoordinator {
        FileTableCoordinator(model: model, browser: browser, open: open, contextMenu: contextMenu)
    }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeScrollView() }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.browser = browser
        context.coordinator.open = open
        context.coordinator.contextMenu = contextMenu
        context.coordinator.isTargetedBinding = $isTargeted
        context.coordinator.reload()
    }
}

/// A column header that sorts on the FIRST click, even when the window isn't key.
///
/// THIS IS THE FIX FOR A CONFIRMED REGRESSION — do not delete it as a no-op subclass.
///
/// AppKit's default is `acceptsFirstMouse == false`, which means the click that brings a
/// window forward is consumed by the activation and never reaches the view. Once the app
/// grew a floating ⌘J View Options panel, any use of that panel handed key away from the
/// browser window, and the next click on a column header did nothing whatsoever: no
/// re-sort, no indicator move. A RIGHT-click at the same point still opened the column
/// picker (context menus don't need a key window), which made it look like left-click
/// sorting specifically had broken, when the sorting code was never involved.
///
/// Returning true here makes a header click always mean "sort", the way it did before any
/// panel existed, and it does so for EVERY window that could steal key — not just ⌘J.
private final class FirstMouseTableHeaderView: NSTableHeaderView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class FileTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let model: AppModel
    var browser: Browser
    var open: (Set<String>) -> Void
    var contextMenu: (Set<FileItem.ID>) -> AnyView
    var isTargetedBinding: Binding<Bool>?

    weak var tableView: ClickTimingTableView?
    private var rows: [FileRow] = []
    private var lastRowSignature: [String] = []
    private var lastKeyboardScrollID: String?
    private var lastRestoreScroll: ScrollRestore?
    private var isPushingSelectionFromModel = false
    /// True from the moment a drag enters this table until it leaves or drops. While set,
    /// `reload()` refuses to touch the table: reloadData() or selectRowIndexes() during a
    /// live drag discards the drag's drop targeting, and the visible symptom is a drop
    /// that "does nothing" — no error, no move, no feedback.
    fileprivate var isDragActive = false
    /// The folder the last reload was built from — the one thing `isDragActive` lets
    /// through, so a spring-loaded folder actually appears while the drag continues.
    private var lastReloadPath: String?

    init(model: AppModel, browser: Browser, open: @escaping (Set<String>) -> Void, contextMenu: @escaping (Set<FileItem.ID>) -> AnyView) {
        self.model = model; self.browser = browser; self.open = open; self.contextMenu = contextMenu
    }

    func makeScrollView() -> NSScrollView {
        let table = ClickTimingTableView()
        table.style = .automatic
        table.rowHeight = 22
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = true
        table.allowsColumnResizing = true
        table.allowsColumnReordering = true
        table.autosaveName = "NavigatorFileTableColumnsV1"
        table.autosaveTableColumns = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.onNameClickCandidate = { [weak self] row in self?.handleNameClickCandidate(row: row) }
        table.onContextMenuRequest = { [weak self] row in self?.buildContextMenu(row: row) }
        table.isGroupRowAt = { [weak self] row in
            guard let self, self.rows.indices.contains(row) else { return false }
            if case .header = self.rows[row] { return true }
            return false
        }
        table.onGroupRowClick = { [weak self] row in
            guard let self, self.rows.indices.contains(row), case .header(let title) = self.rows[row] else { return }
            self.browser.toggleGroupCollapsed(title)
        }
        // Clearing isDragActive here (not only in acceptDrop) matters: a drag that leaves
        // the table or is cancelled never reaches acceptDrop, and a stuck isDragActive
        // would freeze the table's updates for the rest of the session.
        table.onDragTargeted = { [weak self] t in
            guard let self else { return }
            // The drag left this table (or ended): a dwell timer that outlived it would
            // navigate the window after the user had already let go.
            if !t { SpringLoader.shared.cancel() }
            if !t { self.isDragActive = false }
            self.isTargetedBinding?.wrappedValue = t
            if !t { self.reload() }   // catch up on anything skipped during the drag
        }
        // Source side. Previously only the DESTINATION side set isDragActive, which left
        // a real gap: dragging OUT of Navigator (to Slack, to Finder) never enters this
        // table as a destination, so nothing stopped a SwiftUI re-render from calling
        // selectRowIndexes()/reloadData() on the table while its own drag was in flight.
        table.onDragSessionBegin = { [weak self] selectedRows, pbItems in
            guard let self else { return }
            self.isDragActive = true
            navLog("drag start: \(selectedRows) row(s) selected, \(pbItems) pasteboard item(s), model selection \(self.browser.selection.count)")
        }
        table.onDragSessionEnd = { [weak self] in
            guard let self else { return }
            self.isDragActive = false
            self.reload()
        }
        table.registerForDraggedTypes([.fileURL])
        // REQUIRED for dragging files OUT to other apps (Slack, Mail, Photoshop, Finder).
        // NSTableView's documented default is NSDragOperationAll for local drags but
        // NSDragOperationNone for non-local ones, so without this AppKit refuses to let
        // the drag leave the app at all — the pasteboard content is irrelevant because no
        // external drop is ever offered. (Apple's QA1220 is literally "Re-enabling
        // dragging from NSTableView to other applications".) Dropping onto a folder row
        // inside Navigator kept working, which is what made this look like a Slack
        // problem rather than a missing one-liner here.
        //
        // .copy only, deliberately not .move: the destination can't move what we don't
        // offer, and an accidental drag-out that RELOCATES a file off a shared team drive
        // removes it for everyone. That's the same hazard PathRules.leavesCloudProvider
        // already forces to copy for in-app drops; this extends the rule to every app.
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        for def in fileColumnDefs {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(def.id))
            col.title = def.title
            col.minWidth = def.minWidth
            col.width = def.idealWidth
            if def.comparator != nil { col.sortDescriptorPrototype = NSSortDescriptor(key: def.id, ascending: true) }
            // Visibility is pushed from browser.visibleColumns in reload(), never seeded
            // from def.defaultVisible here — one source, so the View menu and the header
            // menu cannot disagree. (autosaveTableColumns still owns width and order,
            // which is why column resize and drag-reorder keep working.)
            table.addTableColumn(col)
        }
        // Replaces AppKit's header purely to get acceptsFirstMouse — see
        // FirstMouseTableHeaderView for the regression this prevents.
        let header = FirstMouseTableHeaderView()
        header.frame = table.headerView?.frame ?? .zero
        table.headerView = header
        let headerMenu = NSMenu(); headerMenu.delegate = self
        table.headerView?.menu = headerMenu
        self.tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // Report the row at the top of the viewport as it changes, so leaving the folder
        // can record it (see Browser.topVisibleID). Bounds-change is the cheap way to
        // learn about EVERY scroll — wheel, scrollbar, keyboard and programmatic alike.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        reload()
        return scroll
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func didScroll(_ n: Notification) { browser.topVisibleID = topVisibleItemID() }

    /// The first FILE row fully or partly at the top of the viewport — group headers are
    /// skipped, because a header is not something you can navigate back to.
    private func topVisibleItemID() -> String? {
        guard let table = tableView else { return nil }
        let range = table.rows(in: table.visibleRect)
        guard range.length > 0 else { return nil }
        for idx in range.location..<(range.location + range.length) where rows.indices.contains(idx) {
            if case .item(let it) = rows[idx] { return it.id }
        }
        return nil
    }

    /// Put the remembered item back at the TOP of the viewport.
    ///
    /// Deliberately not scrollRowToVisible: that scrolls the minimum distance needed, so
    /// coming from the top of a fresh listing it parks the target at the BOTTOM of the
    /// window — every row you were looking at replaced by the rows above it. scroll(_:)
    /// to the row's own origin puts the folder back exactly as you left it, and NSClipView
    /// clamps the point for us when the folder has since got shorter.
    private func syncRestoreScroll() {
        guard let table = tableView, let r = browser.restoreScroll, r != lastRestoreScroll else { return }
        lastRestoreScroll = r
        guard let idx = rows.firstIndex(where: { if case .item(let it) = $0, it.id == r.id { return true }; return false })
        else { return }
        table.scroll(NSPoint(x: 0, y: table.rect(ofRow: idx).minY))
    }

    // Recomputes the row list. Only actually reloads the table (tearing down and
    // rebuilding every cell) when the row SET changed — a plain selection or
    // rename-mode change does NOT reload, because each cell's own SwiftUI content
    // (NameCell etc.) already observes `browser` directly and re-renders itself;
    // reloading unconditionally would tear down an in-progress RenameField mid-edit
    // on every unrelated Browser change (selection, badgeGeneration, ...).
    func reload() {
        guard let table = tableView else { return }
        // Hands off while a drag is over this table — see isDragActive. The pending state
        // is not lost: the drop itself triggers a reload once it lands, and
        // draggingExited/Ended schedule one on the way out.
        //
        // The one exception is a FOLDER CHANGE, which mid-drag means a spring-loaded
        // folder just opened and showing it is the entire point. Keeping the old rows
        // would be worse than the reload this lock guards against: the drop would target
        // rows that no longer exist. Drop targeting survives because validateDrop
        // re-hit-tests and re-setDropRow on every mouse move afterwards.
        if isDragActive, browser.currentURL.path == lastReloadPath { return }
        lastReloadPath = browser.currentURL.path
        let newRows: [FileRow] = browser.groupBy == .none
            ? browser.visibleItems().map { .item($0) }
            : browser.groups().flatMap { g -> [FileRow] in
                guard !g.title.isEmpty else { return g.items.map { .item($0) } }
                // The header always stays — it's what you click to get the group back.
                return [.header(g.title)] + (browser.isGroupCollapsed(g.title) ? [] : g.items.map { .item($0) })
              }
        // The renaming row is part of the signature so that STARTING or ENDING a rename
        // rebuilds the cells — which is what refreshes each cell's `interactive` flag
        // (see PassthroughHostingView). Deliberately keyed on renamingID and nothing
        // else about the edit: typing doesn't change it, so the field is never torn down
        // mid-edit, which is the failure the row-set check was written to avoid.
        var newSignature = newRows.map { row -> String in
            switch row { case .header(let t): return "H:" + t; case .item(let it): return "I:" + it.id }
        }
        newSignature.append("R:" + (browser.renamingID ?? ""))
        if newSignature != lastRowSignature {
            rows = newRows
            lastRowSignature = newSignature
            table.reloadData()
        }
        syncColumnVisibility()
        syncSortDescriptors()
        syncSelection()
        syncScrollTarget()
        syncRestoreScroll()
    }

    /// Push browser.visibleColumns onto the table. Assigning isHidden unconditionally
    /// would post a column-visibility change (and an autosave write) on every reload, so
    /// only genuine differences are written.
    private func syncColumnVisibility() {
        guard let table = tableView else { return }
        for col in table.tableColumns {
            let shouldHide = !browser.visibleColumns.contains(col.identifier.rawValue)
            if col.isHidden != shouldHide { col.isHidden = shouldHide }
        }
        // NOTE: deliberately does NOT reflow column widths to pull a newly revealed column
        // into view when the columns already overflow the window.
        //
        // Turning on a column whose slot is past the right edge does look like nothing
        // happened (seen live with Owner, behind a column that had been dragged — and
        // autosaved — to 1174pt). A table.sizeToFit() here fixes that, but it also
        // rewrites every column's width, throwing away widths the user set by hand, and
        // it fires from inside the SwiftUI update that reload() runs in. Not worth that
        // trade for a cosmetic gain: widening the window, or dragging the greedy column
        // narrower, brings the new column into view, and both are one gesture.
    }

    private func syncSortDescriptors() {
        guard let table = tableView, let cur = browser.sortOrder.first else { return }
        for def in fileColumnDefs {
            guard let make = def.comparator else { continue }
            let ascVal = make(true), descVal = make(false)
            guard cur == ascVal || cur == descVal else { continue }
            let asc = cur == ascVal
            for col in table.tableColumns {
                table.setIndicatorImage(col.identifier.rawValue == def.id
                    ? NSImage(named: asc ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") : nil, in: col)
            }
            // Rewrites the WHOLE stack, not just a differing first entry — see
            // TableSortRules for why a stale tail matters even though only the first
            // descriptor is ever read.
            if TableSortRules.needsRewrite(current: table.sortDescriptors.map { ($0.key ?? "", $0.ascending) },
                                           desiredKey: def.id, desiredAscending: asc) {
                table.sortDescriptors = [NSSortDescriptor(key: def.id, ascending: asc)]
            }
            return
        }
    }

    private func syncSelection() {
        guard let table = tableView else { return }
        let indexSet = IndexSet(rows.indices.filter {
            if case .item(let it) = rows[$0] { return browser.selection.contains(it.id) }
            return false
        })
        guard table.selectedRowIndexes != indexSet else { return }
        isPushingSelectionFromModel = true
        table.selectRowIndexes(indexSet, byExtendingSelection: false)
        isPushingSelectionFromModel = false
    }

    private func syncScrollTarget() {
        guard let table = tableView, let id = browser.keyboardScrollID, id != lastKeyboardScrollID else { return }
        lastKeyboardScrollID = id
        if let idx = rows.firstIndex(where: { if case .item(let it) = $0, it.id == id { return true }; return false }) {
            table.scrollRowToVisible(idx)
        }
    }

    private func selectedItemIDs() -> Set<String> {
        Set((tableView?.selectedRowIndexes ?? []).compactMap { idx -> String? in
            guard rows.indices.contains(idx), case .item(let it) = rows[idx] else { return nil }
            return it.id
        })
    }

    private func handleNameClickCandidate(row: Int) {
        guard rows.indices.contains(row), case .item(let item) = rows[row] else { return }
        browser.handleNameTap(item.id)
    }

    private func buildContextMenu(row: Int) -> NSMenu? {
        guard let table = tableView else { return nil }
        var ids: Set<FileItem.ID> = []
        if row >= 0, rows.indices.contains(row), case .item(let clicked) = rows[row] {
            if table.selectedRowIndexes.contains(row) { ids = selectedItemIDs() }
            else { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); ids = [clicked.id] }
        }
        return NSHostingMenu(rootView: contextMenu(ids))
    }

    @objc private func doubleClicked(_ sender: NSTableView) {
        let ids = selectedItemIDs()
        guard !ids.isEmpty else { return }
        open(ids)
    }

    // Toggles the MODEL, not the NSTableColumn. Flipping col.isHidden directly (what this
    // used to do) made the table its own source of truth, which the View ▸ Columns menu
    // could not see — and two menus each holding their own idea of what's visible is
    // exactly the drift that has already produced real bugs here. reload() pushes the
    // model back onto the columns.
    @objc private func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        browser.visibleColumns = ColumnMenu.toggled(browser.visibleColumns, id: id)
    }

    // MARK: NSMenuDelegate (right-click on the column header — show/hide optional columns)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === tableView?.headerView?.menu else { return }
        menu.removeAllItems()
        // Built from fileColumnIDs — the same list the View ▸ Columns menu uses — rather
        // than from the table's own columns, so the two menus cannot list different things.
        for id in ColumnMenu.togglableIDs {
            let item = NSMenuItem(title: fileColumnTitle(id), action: #selector(toggleColumnVisibility(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = browser.visibleColumns.contains(id) ? .on : .off
            menu.addItem(item)
        }
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .header = rows[row] { return true }
        return false
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .header = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        if case .header(let title) = rows[row] {
            // A disclosure triangle plus the title. The triangle is a plain image, not a
            // button: the whole row is already the click target (see
            // ClickTimingTableView.onGroupRowClick), and a real NSButton on top of it would
            // give the row two competing mouse handlers for one gesture.
            let collapsed = browser.isGroupCollapsed(title)
            let id = NSUserInterfaceItemIdentifier("groupRow")
            if let cell = tableView.makeView(withIdentifier: id, owner: self) as? GroupHeaderCellView {
                cell.update(title: title, collapsed: collapsed); return cell
            }
            let cell = GroupHeaderCellView(identifier: id)
            cell.update(title: title, collapsed: collapsed)
            return cell
        }
        guard case .item(let item) = rows[row], let colID = tableColumn?.identifier.rawValue else { return nil }
        let reuseID = NSUserInterfaceItemIdentifier(colID)
        // Only the Name column ever holds the rename field, so only it can need events.
        let interactive = (colID == "name" && browser.renamingID == item.id)
        if let cell = tableView.makeView(withIdentifier: reuseID, owner: self) as? HostingTableCellView {
            cell.update(cellContent(for: colID, item: item), interactive: interactive); return cell
        }
        let cell = HostingTableCellView(identifier: reuseID)
        cell.update(cellContent(for: colID, item: item), interactive: interactive)
        return cell
    }

    private func cellContent(for colID: String, item: FileItem) -> AnyView {
        switch colID {
        case "name": return AnyView(NameCell(item: item, browser: browser))
        case "modified": return AnyView(DateCell(date: item.modified))
        case "size": return AnyView(SizeCell(item: item))
        case "kind": return AnyView(Text(item.kind).foregroundStyle(.secondary).lineLimit(1))
        case "created": return AnyView(DateCell(date: item.created))
        case "accessed": return AnyView(DateCell(date: item.accessed))
        case "dateAdded": return AnyView(DateCell(date: item.dateAdded))
        case "extension": return AnyView(Text(item.ext.isEmpty ? "—" : item.ext.uppercased()).foregroundStyle(.secondary))
        case "duration":
            return item.isDirectory ? AnyView(Text("—").foregroundStyle(.secondary)) : AnyView(MetadataCell(url: item.url, field: .duration))
        case "dimensions":
            return item.isDirectory ? AnyView(Text("—").foregroundStyle(.secondary)) : AnyView(MetadataCell(url: item.url, field: .dimensions))
        case "owner": return AnyView(Text(item.owner).foregroundStyle(.secondary).lineLimit(1))
        case "tags": return AnyView(TagsCell(tags: item.tags))
        default: return AnyView(EmptyView())
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isPushingSelectionFromModel else { return }
        let ids = selectedItemIDs()
        guard browser.selection != ids else { return }
        browser.selection = ids
        browser.updateStatus()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let desc = tableView.sortDescriptors.first, let key = desc.key,
              let def = fileColumnDefs.first(where: { $0.id == key }), let make = def.comparator else { return }
        let new = make(desc.ascending)
        // AppKit calls this for a PROGRAMMATIC assignment to tableView.sortDescriptors as
        // well as for a header click, and updateNSView pushes the browser's sort into the
        // table on every refresh — so this fires with the sort we just gave it, on every
        // folder we open. Harmless while a view change only rewrote the global default to
        // the value it already had; not harmless now that a change is what makes a folder
        // remember itself, where it wrote a record for every folder merely VISITED.
        guard browser.sortOrder.first != new else { return }
        browser.sortOrder = [new]
    }

    // MARK: Drag out / drag in

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard rows.indices.contains(row), case .item(let item) = rows[row] else { return nil }
        return item.url as NSURL
    }

    /// The folder row under the cursor, hit-tested from the drag's own location.
    ///
    /// Deliberately does NOT trust the `proposedRow`/`proposedDropOperation` AppKit hands
    /// in. Whether a table proposes `.on` (over a row) versus `.above` (between rows)
    /// depends on where in the row height the cursor sits, so relying on it made "drop
    /// onto this folder" work only in part of each row — and every miss fell through to
    /// "drop into the current folder", which for files already in that folder is a no-op
    /// that looks exactly like drag-and-drop being broken. Hit-testing directly makes the
    /// whole row height a valid target.
    private func folderRow(under info: NSDraggingInfo, in tableView: NSTableView) -> (row: Int, url: URL)? {
        let point = tableView.convert(info.draggingLocation, from: nil)
        let hovered = tableView.row(at: point)
        guard rows.indices.contains(hovered), case .item(let item) = rows[hovered], item.isDirectory else { return nil }
        return (hovered, item.url)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) else { return [] }
        isDragActive = true
        if let hit = folderRow(under: info, in: tableView) {
            // Spring-loading hangs off validateDrop because it is already the one place
            // that knows which folder row the pointer is over, and AppKit calls it on
            // every mouse move — exactly the signal a dwell timer needs.
            SpringLoader.shared.hover(folder: hit.url, browser: browser)
            // Retarget explicitly so acceptDrop is guaranteed to see this exact row with
            // .on, no matter what was proposed.
            tableView.setDropRow(hit.row, dropOperation: .on)
            return .copy
        }
        SpringLoader.shared.cancel()   // over empty space or a file: nothing to spring into
        // Empty space, a file row, or between rows → the current folder, which is what
        // Finder does for a drop that isn't aimed at a specific folder.
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        isDragActive = false
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else { return false }
        // Re-hit-test rather than trusting `row`: validateDrop already retargeted, but
        // this keeps the two paths deciding the same way from the same input.
        if let hit = folderRow(under: info, in: tableView) {
            // Never drop a folder into itself or its own subtree — FileManager will
            // happily recurse into the copy it's creating. PathRules has the rule.
            let safe = urls.filter { !PathRules.isSelfOrDescendant(hit.url, of: $0) }
            guard !safe.isEmpty else { NSSound.beep(); return false }
            navLog("drop: \(safe.count) item(s) onto folder \(hit.url.lastPathComponent)")
            browser.dropInto(safe, folder: hit.url)
        } else {
            navLog("drop: \(urls.count) item(s) into current folder")
            browser.dropIntoCurrentFolder(urls)
        }
        return true
    }
}

struct IconCell: View {
    let item: FileItem
    @ObservedObject var browser: Browser
    let selected: Bool
    @State private var thumb: NSImage?
    @State private var cloud: CloudBadge?
    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let t = thumb { Image(nsImage: t).resizable().scaledToFit() }
                else { Image(nsImage: browser.icon(for: item)).resizable().scaledToFit() }
            }
            .frame(width: browser.iconSize, height: browser.iconSize)
            .overlay(alignment: .bottomTrailing) { cloudBadgeView(cloud) }
            if browser.renamingID == item.id {
                RenameField(initialText: item.name, excludeExtension: !item.isDirectory,
                           onCommit: { browser.rename(id: item.id, to: $0); browser.renamingID = nil },
                           onCancel: { browser.renamingID = nil })
                    .multilineTextAlignment(.center)
            } else {
                Text(item.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .frame(width: browser.iconSize + 40, height: browser.iconSize + 46)
        .padding(4)
        .background(selected ? Color.accentColor.opacity(0.25) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        // Replaces .draggable(item.url) AND the name's .onTapGesture. .draggable could
        // only ever carry ONE file, so dragging a multi-selection dropped just the one
        // grabbed; this hands the cell's mouse handling to AppKit, which can put every
        // selected file on the drag. Skipped while renaming so the field keeps its clicks.
        .overlay {
            if browser.renamingID != item.id {
                IconCellMouseHandler(
                    select: { e in browser.click(item.id, modifiers: e.modifierFlags) },
                    isSelected: { browser.selection.contains(item.id) },
                    open: { openItem(item, browser) },
                    plainClickCompleted: { browser.handleNameTap(item.id) },
                    urlsForDrag: {
                        // Selection landed on mouse-down, so by drag time this item is
                        // in the selection — the drag simply carries whatever is selected.
                        if browser.selection.contains(item.id), browser.selection.count > 1 {
                            return browser.orderedVisibleItems()
                                .filter { browser.selection.contains($0.id) }.map { $0.url }
                        }
                        return [item.url]
                    },
                    dragIcon: { browser.icon(for: item) }
                )
            }
        }
        .onAppear {
            // Only fetch a thumbnail for files that can have one — folders keep
            // their type icon (matches the list view; avoids per-cell churn).
            if !item.isDirectory, isThumbnailable(item.url) {
                ThumbnailCache.shared.thumbnail(for: item.url) { thumb = $0 }
            }
            cloud = cloudBadge(for: item.url)
        }
        .onDisappear { if thumb == nil { ThumbnailCache.shared.cancel(for: item.url) } }
        .onChange(of: browser.badgeGeneration) {
            cloud = cloudBadge(for: item.url)
            // Cloud state changed (a download finished, a sync completed) — the exact
            // moment a previously-failed thumbnail is worth another try.
            if thumb == nil, !item.isDirectory, isThumbnailable(item.url) {
                ThumbnailCache.shared.thumbnail(for: item.url) { if let t = $0 { thumb = t } }
            }
        }
    }
}

// Owns one icon cell's mouse handling in AppKit, so a drag can carry the WHOLE
// selection.
//
// SwiftUI's `.draggable` carries exactly one item — it has no concept of the current
// selection — so selecting eight files and dragging them dragged only the one grabbed.
// There is no SwiftUI API for multi-item drag; putting one NSDraggingItem per file on
// the pasteboard requires AppKit. Since this view has to receive the mouse-down to
// start that drag, it also takes over click/double-click for the cell (which means
// clicking anywhere on a cell now selects it, not just its filename).
//
// Selection follows the Finder/NSTableView model — applied on mouse DOWN, not up:
//   • down on an UNSELECTED item → selection changes immediately (with ⌘/⇧ honoured),
//     so a drag that follows carries what you see selected;
//   • down on an ALREADY-SELECTED item → deferred to mouse-up, so grabbing one item of
//     a multi-selection and dragging doesn't collapse the selection first;
//   • up without a drag resolves the deferred case (plain → collapse to this item,
//     ⌘ → toggle it off) and arms click-pause-click rename for plain clicks only.
// An earlier version did ALL selection on mouse-up, which both deviated from every
// native file browser and broke ⌘-click multi-select in practice.
//
// Not installed while a cell is being renamed — the rename field needs its own clicks.
struct IconCellMouseHandler: NSViewRepresentable {
    /// Apply a selection click (modifiers included) to this cell's item.
    let select: (NSEvent) -> Void
    /// Is this cell's item currently in the selection?
    let isSelected: () -> Bool
    /// Open the item (double-click).
    let open: () -> Void
    /// Plain single click fully resolved (no drag, no modifiers) — rename arming.
    let plainClickCompleted: () -> Void
    /// Resolved at drag time, not view-build time, so it reflects the selection as it is
    /// when the drag actually starts.
    let urlsForDrag: () -> [URL]
    let dragIcon: () -> NSImage?

    func makeNSView(context: Context) -> Handler {
        let v = Handler(); apply(to: v); return v
    }
    func updateNSView(_ v: Handler, context: Context) { apply(to: v) }
    private func apply(to v: Handler) {
        v.select = select; v.isSelected = isSelected; v.open = open
        v.plainClickCompleted = plainClickCompleted
        v.urlsForDrag = urlsForDrag; v.dragIcon = dragIcon
    }

    final class Handler: NSView, NSDraggingSource {
        var select: ((NSEvent) -> Void)?
        var isSelected: (() -> Bool)?
        var open: (() -> Void)?
        var plainClickCompleted: (() -> Void)?
        var urlsForDrag: (() -> [URL])?
        var dragIcon: (() -> NSImage?)?
        private var downPoint: NSPoint?
        private var didDrag = false
        // Selection change postponed to mouse-up (the down landed on an already-
        // selected item, which may be the start of a whole-selection drag).
        private var deferredSelection = false

        override func mouseDown(with event: NSEvent) {
            // A rename in progress on ANOTHER cell must end when the user clicks here
            // (commit-on-focus-loss, like every native file browser). The rename field
            // only commits when it loses first responder, and nothing else would take
            // it — this handler deliberately never becomes first responder itself.
            if let w = window, isEditingText(in: w) { w.makeFirstResponder(nil) }
            downPoint = convert(event.locationInWindow, from: nil)
            didDrag = false
            deferredSelection = (isSelected?() == true)
            if !deferredSelection { select?(event) }   // Finder: selection lands on DOWN
            // Deliberately no super: this view owns the cell's mouse handling.
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start = downPoint, !didDrag else { return }
            let p = convert(event.locationInWindow, from: nil)
            // Threshold so a slightly shaky click still counts as a click, not a drag.
            guard hypot(p.x - start.x, p.y - start.y) >= 6 else { return }
            didDrag = true
            beginFileDrag(with: event)
        }
        override func mouseUp(with event: NSEvent) {
            defer { downPoint = nil; deferredSelection = false }
            guard !didDrag else { return }   // a completed drag is not a click
            if event.clickCount >= 2 { open?(); return }
            let mods = event.modifierFlags.intersection([.command, .shift])
            if deferredSelection {
                // The down didn't act; resolve now — plain collapses to this item,
                // ⌘ toggles it out of the selection, ⇧ extends the range.
                select?(event)
            }
            if mods.isEmpty { plainClickCompleted?() }   // arm click-pause-click rename
        }

        private func beginFileDrag(with event: NSEvent) {
            let urls = urlsForDrag?() ?? []
            guard !urls.isEmpty else { return }
            let fallbackIcon = dragIcon?()
            let items: [NSDraggingItem] = urls.enumerated().map { i, url in
                let di = NSDraggingItem(pasteboardWriter: url as NSURL)
                // One NSDraggingItem per file — this is the part SwiftUI can't express,
                // and it's what makes the receiving app see eight files instead of one.
                // Offset each image slightly so a multi-file drag reads as a stack.
                let side: CGFloat = 48
                let step = CGFloat(min(i, 4)) * 6
                di.setDraggingFrame(NSRect(x: step, y: step, width: side, height: side),
                                    contents: fallbackIcon ?? NSWorkspace.shared.icon(forFile: url.path))
                return di
            }
            navLog("icon drag start: \(items.count) file(s)")
            beginDraggingSession(with: items, event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // Other apps (Slack, Finder) get copy; inside Navigator the destination
            // decides move-vs-copy itself, so offer both.
            context == .outsideApplication ? .copy : [.copy, .move]
        }
    }
}

// Collects each icon cell's frame (in the grid's coordinate space) so a
// rubber-band drag can hit-test which items it covers.
// Holds each visible cell's frame for rubber-band hit-testing. A plain reference
// (not @Published / not a PreferenceKey) on purpose: cells write their frame into
// it WITHOUT feeding layout-derived values back into the view graph. The old
// PreferenceKey approach reduced 600+ frames during layout and, with a large
// cached folder present at launch, spun in a layout loop that hung the window.
final class FrameStore { var frames: [String: CGRect] = [:] }

// AppKit-level drag catcher for rubber-band selection. A SwiftUI DragGesture
// inside a ScrollView is unreliable (the scroll view eats the drag), so we use a
// real NSView that receives mouseDragged directly. It sits behind the cells, so
// only drags/clicks on empty space reach it. Coordinates are top-left (flipped)
// to match SwiftUI's grid space.
/// A right-click-ONLY overlay whose NSMenu is built at click time.
///
/// Why this has to exist at all: SwiftUI's `.contextMenu` content is a View, and SwiftUI
/// evaluates it during ordinary body updates — measured here, an icon cell's menu was
/// built while the pointer was merely MOVING over the grid, long before any right-click
/// (`NSApp.currentEvent` was a `mouseMoved`). So a menu that has to branch on the click's
/// modifier keys (Shift+right-click → the extended menu) cannot be a `.contextMenu`: by
/// the time it is shown, the flags it would have read are long gone. AppKit's
/// `menu(for:)` is handed the actual right-mouse-down, which is the only moment those
/// flags are still true.
///
/// The overlay is invisible to every event EXCEPT a right-click, because `hitTest` is
/// consulted per event and declines unless the event being dispatched IS the
/// right-mouse-down. That is what makes it safe to lay over cells that already own their
/// mouse handling (IconCellMouseHandler) or carry SwiftUI tap gestures: neither sees any
/// change at all, so the "SwiftUI gesture and AppKit mouseDown both fire on one click"
/// trap that has caused five regressions in this file cannot apply here.
struct RightClickMenu: NSViewRepresentable {
    let build: () -> NSMenu?
    func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.build = build; return v }
    func updateNSView(_ v: CatcherView, context: Context) { v.build = build }
    final class CatcherView: NSView {
        var build: (() -> NSMenu?)?
        /// macOS has TWO context-click gestures and this used to answer only one.
        /// Control + left click arrives as a `.leftMouseDown` with `.control` set, so
        /// the right-click-only guard declined it and it fell through as a plain
        /// selection — Details/List view kept working (AppKit's `menu(for:)` covers
        /// both gestures for a real NSTableView), so Icon, Gallery and the filmstrip
        /// were the only surfaces where Ctrl-click silently did nothing.
        private static func isContextClick(_ e: NSEvent?) -> Bool {
            guard let e else { return false }
            return e.type == .rightMouseDown
                || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Still invisible to an ORDINARY left click, which is what keeps
            // IconCellMouseHandler owning selection and drag — one click must never be
            // processed by both this and the handler underneath.
            guard Self.isContextClick(NSApp.currentEvent) else { return nil }
            return super.hitTest(point)
        }
        /// Reached for BOTH gestures: AppKit asks the hit view for its menu on a
        /// right-mouse-down and on a control-left-click alike (verified live), so
        /// letting the click through hitTest above is the whole fix.
        override func menu(for event: NSEvent) -> NSMenu? { build?() }
    }
}

extension View {
    /// Drop-in replacement for `.contextMenu` wherever the menu must react to the
    /// modifier keys held during the right-click. See RightClickMenu for why
    /// `.contextMenu` cannot.
    func appKitContextMenu<M: View>(@ViewBuilder _ content: @escaping () -> M) -> some View {
        overlay { RightClickMenu { NSHostingMenu(rootView: content()) } }
    }
}

struct MarqueeCatcher: NSViewRepresentable {
    var onRect: (CGRect?) -> Void      // drag rect in grid space; nil when the drag ends
    var onEmptyClick: () -> Void        // a click on empty space (no drag) → deselect
    // Right-click on empty space → this menu (Paste / New Folder / …). The catcher is
    // the AppKit view that owns the grid's empty area, so it's the only place a
    // blank-space right-click ever arrives — without this, icon view simply had no
    // empty-area menu at all (the table view has one via its row==-1 path).
    var emptyAreaMenu: (() -> NSMenu?)? = nil
    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView(); v.onRect = onRect; v.onEmptyClick = onEmptyClick; v.emptyAreaMenu = emptyAreaMenu; return v
    }
    func updateNSView(_ v: CatcherView, context: Context) {
        v.onRect = onRect; v.onEmptyClick = onEmptyClick; v.emptyAreaMenu = emptyAreaMenu
    }
    final class CatcherView: NSView {
        var onRect: ((CGRect?) -> Void)?
        var onEmptyClick: (() -> Void)?
        var emptyAreaMenu: (() -> NSMenu?)?
        private var start: NSPoint?
        private var dragged = false
        override var isFlipped: Bool { true }
        override func mouseDown(with e: NSEvent) {
            // Same commit-on-focus-loss as IconCellMouseHandler.Handler: a rename in
            // progress must end when the user clicks blank space too, not just when
            // they click another cell. This view only ever received the marquee
            // drag/deselect click — nothing here canceled the rename field's edit
            // session, so it stayed open no matter where else you clicked.
            if let w = window, isEditingText(in: w) { w.makeFirstResponder(nil) }
            start = convert(e.locationInWindow, from: nil); dragged = false
        }
        override func mouseDragged(with e: NSEvent) {
            guard let s = start else { return }
            dragged = true
            let p = convert(e.locationInWindow, from: nil)
            onRect?(CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y)))
        }
        override func mouseUp(with e: NSEvent) {
            if !dragged { onEmptyClick?() }
            start = nil; onRect?(nil)
        }
        override func menu(for event: NSEvent) -> NSMenu? { emptyAreaMenu?() }
    }
}

// The rubber-band selection rectangle: a translucent fill with an animated
// dashed "marching ants" outline (TimelineView drives the dash phase each frame).
struct MarqueeRect: View {
    let rect: CGRect
    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = -timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 8
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .overlay(Rectangle().stroke(Color.accentColor,
                                            style: StrokeStyle(lineWidth: 1.2, dash: [5, 3], dashPhase: phase)))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }
}

struct IconGridView: View {
    let model: AppModel
    @ObservedObject var browser: Browser
    @State private var frameStore = FrameStore()
    @State private var marquee: CGRect?
    /// The item at the top-leading corner of the viewport, maintained by SwiftUI.
    @State private var topID: String?
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: browser.iconSize + 44), spacing: 12)] }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        // Rubber-band catcher (behind the cells): an AppKit NSView that
                        // receives the drag directly, so ScrollView doesn't eat it.
                        MarqueeCatcher(
                            onRect: { r in
                                marquee = r
                                if let r {
                                    browser.selection = Set(frameStore.frames.filter { $0.value.intersects(r) }.map { $0.key })
                                    browser.updateStatus()
                                }
                            },
                            onEmptyClick: { browser.selection = []; browser.updateStatus() },
                            // Literally the list view's blank-space menu: the ids.isEmpty
                            // branch of the shared builder, not a hand-written twin. The
                            // twin it replaced had already drifted (no Copy Path, no
                            // extended items) — and it drifts again the moment anything
                            // is added on only one side.
                            emptyAreaMenu: {
                                NSHostingMenu(rootView: AnyView(
                                    fileContextMenu(model: model, browser: browser, ids: [])))
                            }
                        )
                        .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                        LazyVGrid(columns: columns, spacing: 12) {
                            if browser.groupBy == .none {
                                ForEach(browser.visibleItems()) { item in cell(item) }
                            } else {
                                ForEach(browser.groups(), id: \.title) { group in
                                    let collapsed = browser.isGroupCollapsed(group.title)
                                    Section {
                                        // The header stays either way — it's the only thing
                                        // left to click to bring the group back.
                                        if !collapsed { ForEach(group.items) { item in cell(item) } }
                                    } header: {
                                        HStack(spacing: 5) {
                                            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                            Text(group.title).font(.headline).foregroundStyle(.secondary)
                                            Spacer()
                                        }.padding(.top, 8).padding(.horizontal, 4)
                                        .contentShape(Rectangle())
                                        // Safe to use a plain tap gesture here, unlike on a
                                        // file cell: a group header carries no
                                        // IconCellMouseHandler, so nothing else is competing
                                        // for this click and it cannot fire twice. (The
                                        // MarqueeCatcher sitting behind the grid may also see
                                        // the press and clear the selection — which is what
                                        // clicking a header should do anyway.)
                                        .onTapGesture { browser.toggleGroupCollapsed(group.title) }
                                    }
                                }
                            }
                        }
                        // Marks the grid as the thing .scrollPosition(id:) reads its
                        // answer from. Harmless on its own — it only becomes a snapping
                        // behaviour when paired with .scrollTargetBehavior, which we
                        // deliberately do not use.
                        .scrollTargetLayout()
                        .padding(14)
                    }
                    .coordinateSpace(name: "iconGrid")
                    .overlay(alignment: .topLeading) {
                        if let m = marquee { MarqueeRect(rect: m) }
                    }
                }
                // AppKit hands us the top row for free in list view; here SwiftUI's own
                // scrollPosition is the equivalent, and it costs nothing per scroll tick —
                // unlike reading a named-coordinate-space frame, which is exactly the
                // measured expense the cell frames below are written to avoid.
                .scrollPosition(id: $topID)
                .onChange(of: topID) { browser.topVisibleID = topID }
                .onChange(of: browser.keyboardScrollID) {
                    if let id = browser.keyboardScrollID { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
                // No animation: this is restoring a view you already had, not moving you
                // somewhere. Animating it makes returning to a folder look like a scroll
                // you didn't ask for.
                .onChange(of: browser.restoreScroll) {
                    if let r = browser.restoreScroll { proxy.scrollTo(r.id, anchor: .top) }
                }
            }
            .onAppear { updateColumns(geo.size.width) }
            .onChange(of: geo.size.width) { updateColumns(geo.size.width) }
            .onChange(of: browser.iconSize) { updateColumns(geo.size.width) }
        }
    }

    private func updateColumns(_ width: CGFloat) {
        let content = width - 28
        let minItem = browser.iconSize + 44
        let n = max(1, Int((content + 12) / (minItem + 12)))
        if browser.gridColumns != n { DispatchQueue.main.async { browser.gridColumns = n } }
    }

    @ViewBuilder private func cell(_ item: FileItem) -> some View {
        IconCell(item: item, browser: browser, selected: browser.selection.contains(item.id))
            .id(item.id)
            .background(GeometryReader { g in
                // Record this cell's frame for marquee hit-testing — writing to a
                // plain store (not a PreferenceKey), so it never feeds back into
                // layout. Updated as cells appear/scroll into view.
                // Capture the frame once when the cell appears (for marquee
                // hit-testing). No .onChange — evaluating a named-coordinate-space
                // frame per cell on every layout pass janks LazyVGrid scrolling.
                Color.clear.onAppear { frameStore.frames[item.id] = g.frame(in: .named("iconGrid")) }
            })
            // NO tap gesture here — and that absence is load-bearing. SwiftUI gesture
            // recognizers attach at the hosting-view level and fire INDEPENDENTLY of
            // the AppKit mouse handler inside IconCell consuming the click, so a tap
            // gesture here ran every click a SECOND time. Plain clicks double-selected
            // harmlessly (idempotent), but ⌘-click toggled twice: the handler added
            // the item on mouse-down, this gesture immediately toggled it back off —
            // "it selects it and deselects it". Confirmed live. Selection, open, and
            // rename arming all live in IconCellMouseHandler alone.
            .dropDestination(for: URL.self) { urls, _ in
                if item.isDirectory { browser.dropInto(urls, folder: item.url) }
                else { browser.dropIntoCurrentFolder(urls) }
                return true
            } isTargeted: { t in
                // Spring-loading. `leave` rather than an unconditional cancel: SwiftUI
                // reports the next cell as targeted BEFORE this one un-targets, so
                // cancelling blindly here would kill the countdown that cell just armed.
                guard item.isDirectory else { return }
                if t { SpringLoader.shared.hover(folder: item.url, browser: browser) }
                else { SpringLoader.shared.leave(item.url) }
            }
            // Same shared menu as List view: if the right-clicked cell is part of
            // a multi-selection, act on the whole selection (Copy/Cut/Batch
            // Rename/etc.); otherwise just this item. Was previously a hand-
            // duplicated copy of List view's menu that had drifted — missing
            // Copy/Cut/Paste and the multi-select Batch Rename branch entirely.
            //
            // appKitContextMenu, not .contextMenu: the menu has to be built by the
            // right-click itself for Shift+right-click to be visible to it.
            .appKitContextMenu {
                let ids: Set<String> = (browser.selection.contains(item.id) && browser.selection.count > 1) ? browser.selection : [item.id]
                fileContextMenu(model: model, browser: browser, ids: ids)
            }
    }
}

struct PreviewPane: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var sizeCache = FolderSizeCache.shared
    @State private var thumb: NSImage?
    @State private var meta = FileMeta()
    private static let df: DateFormatter = { let d = DateFormatter(); d.dateStyle = .medium; d.timeStyle = .short; return d }()
    private var item: FileItem? {
        let sel = browser.items.filter { browser.selection.contains($0.id) }
        return sel.count == 1 ? sel.first : nil
    }
    var body: some View {
        VStack(spacing: 12) {
            if let it = item {
                Group {
                    if isAnimatedImage(it.url) { AnimatedImage(url: it.url).id(it.url) }
                    else if let t = thumb { Image(nsImage: t).resizable().scaledToFit() }
                    else { Image(nsImage: browser.icon(for: it)).resizable().scaledToFit() }
                }.frame(maxWidth: 200, maxHeight: 200)
                Text(it.name).font(.headline).multilineTextAlignment(.center).lineLimit(3)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    infoRow("Kind", it.kind)
                    infoRow("Size", sizeText(it))
                    if let d = meta.duration, d >= 1 { infoRow("Duration", formatDuration(d)) }
                    if let w = meta.width, let h = meta.height, w > 0, h > 0 { infoRow("Dimensions", "\(w) × \(h)") }
                    infoRow("Created", Self.df.string(from: it.created))
                    infoRow("Modified", Self.df.string(from: it.modified))
                    infoRow("Added", Self.df.string(from: it.dateAdded))
                    if !it.tags.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Text("Tags").foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                            TagsCell(tags: it.tags)
                        }
                    }
                    if let c = meta.comment { infoRow("Comment", c) }
                    infoRow("Where", it.url.deletingLastPathComponent().path)
                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                Button { QuickLook.shared.show([it.url]) } label: {
                    Label("Quick Look", systemImage: "eye").frame(maxWidth: .infinity)
                }
            } else {
                Spacer()
                Image(systemName: "sidebar.right").font(.largeTitle).foregroundStyle(.tertiary)
                Text(browser.selection.count > 1 ? "\(browser.selection.count) items selected" : "No selection")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        .onChange(of: browser.selection) { loadDetails() }
        .onAppear { loadDetails() }
    }
    @ViewBuilder private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(k).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Text(v).textSelection(.enabled).lineLimit(3)
        }
    }
    private func sizeText(_ it: FileItem) -> String {
        if it.isDirectory {
            if let s = sizeCache.cached(it.url) { return ByteCountFormatter.string(fromByteCount: s, countStyle: .file) }
            return "Calculating…"
        }
        return ByteCountFormatter.string(fromByteCount: it.size, countStyle: .file)
    }
    private func loadDetails() {
        guard let it = item else { thumb = nil; meta = FileMeta(); return }
        thumb = nil; meta = FileMeta()
        if it.isDirectory { FolderSizeCache.shared.compute(it.url) }
        ThumbnailCache.shared.thumbnail(for: it.url, size: 512) { img in
            if self.item?.url == it.url { self.thumb = img }
        }
        MetadataCache.shared.meta(for: it.url) { m in
            if self.item?.url == it.url { self.meta = m }
        }
    }
}

// Miller-column (Finder column) view: a horizontal chain of folder listings.
// A lazily-loaded folder node for the sidebar's expandable tree (Windows-11-style
// navigation pane). Shows sub-FOLDERS only; `children` loads one level on first
// access (nil when a folder has no subfolders, so no disclosure triangle shows).
final class SidebarNode: Identifiable {
    let url: URL
    let name: String
    let symbol: String
    let mountURL: String?    // for a network-drive favorite: (re)mount when the path is gone
    var id: String { "\(name)\u{1}\(url.path)" }   // name-scoped so two labels can share a path
    private var loaded = false
    private var cache: [SidebarNode] = []
    init(url: URL, name: String, symbol: String, mountURL: String? = nil) {
        self.url = url; self.name = name; self.symbol = symbol; self.mountURL = mountURL
    }

    var children: [SidebarNode]? {
        // Network-drive favorites: never enumerate synchronously — SMB/VPN listing
        // on the main thread freezes the UI. They open in the main pane on click.
        if mountURL != nil { return nil }
        if !loaded { loaded = true; cache = SidebarNode.subfolders(url) }
        return cache.isEmpty ? nil : cache
    }
    static func subfolders(_ dir: URL) -> [SidebarNode] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { SidebarNode(url: $0, name: $0.lastPathComponent, symbol: "folder") }
    }
}

// Shared image/thumbnail view with icon fallback, used by Gallery view.
struct ThumbImage: View {
    let item: FileItem
    @ObservedObject var browser: Browser
    @State private var thumb: NSImage?
    @State private var cloud: CloudBadge?
    var body: some View {
        Group {
            if let t = thumb { Image(nsImage: t).resizable().scaledToFit() }
            else { Image(nsImage: browser.icon(for: item)).resizable().scaledToFit() }
        }
        .overlay(alignment: .bottomTrailing) { cloudBadgeView(cloud).padding(4) }
        .onAppear { ThumbnailCache.shared.thumbnail(for: item.url) { thumb = $0 }; cloud = cloudBadge(for: item.url) }
        .onChange(of: item.url) { thumb = nil; ThumbnailCache.shared.thumbnail(for: item.url) { thumb = $0 }; cloud = cloudBadge(for: item.url) }
        .onChange(of: browser.badgeGeneration) {
            cloud = cloudBadge(for: item.url)
            // Same retry-on-cloud-change as the icon grid: a finished download is the
            // moment a failed thumbnail becomes generatable.
            if thumb == nil {
                ThumbnailCache.shared.thumbnail(for: item.url) { if let t = $0 { thumb = t } }
            }
        }
    }
}

struct GalleryView: View {
    let model: AppModel
    @ObservedObject var browser: Browser
    private var items: [FileItem] { browser.orderedVisibleItems() }
    private var selected: FileItem? { items.first { browser.selection.contains($0.id) } ?? items.first }
    private func contextIDs(for id: String) -> Set<String> {
        (browser.selection.contains(id) && browser.selection.count > 1) ? browser.selection : [id]
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Same commit-on-focus-loss as the icon grid's blank-space catcher:
                // clicking the empty area around the preview must end an in-progress
                // rename too, not just clicking another filmstrip thumbnail.
                Color(nsColor: .textBackgroundColor).opacity(0.25)
                    .onTapGesture {
                        if let w = NSApp.keyWindow, isEditingText(in: w) { w.makeFirstResponder(nil) }
                    }
                if let it = selected {
                    VStack(spacing: 8) {
                        // The big preview was the last gallery surface with no click
                        // handler of its own: a click here reaches neither the background
                        // Color (it's underneath), nor the name label, nor a filmstrip
                        // cell — so nothing took first responder away and an in-progress
                        // rename stayed stuck open. A plain SwiftUI gesture is safe HERE
                        // and only here: unlike the filmstrip thumbnails, this instance of
                        // ThumbImage carries no IconCellMouseHandler overlay, so there's
                        // no AppKit mouseDown to fire a second time on the same click.
                        ThumbImage(item: it, browser: browser).padding(24)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let w = NSApp.keyWindow, isEditingText(in: w) { w.makeFirstResponder(nil) }
                            }
                        if browser.renamingID == it.id {
                            RenameField(initialText: it.name, excludeExtension: !it.isDirectory,
                                       onCommit: { browser.rename(id: it.id, to: $0); browser.renamingID = nil },
                                       onCancel: { browser.renamingID = nil })
                                .frame(maxWidth: 260).padding(.bottom, 6)
                        } else {
                            Text(it.name).font(.callout).lineLimit(1).padding(.bottom, 6)
                                .onTapGesture {
                                    // Same gate as IconCellMouseHandler.mouseUp: a click
                                    // carrying ⌘ or ⇧ is a selection gesture, never the
                                    // second half of click-pause-click rename. Without the
                                    // modifier test, ⌘-clicking the name armed a rename.
                                    let e = NSApp.currentEvent
                                    guard (e?.clickCount ?? 1) == 1,
                                          e?.modifierFlags.intersection([.command, .shift]).isEmpty ?? true
                                    else { return }
                                    browser.handleNameTap(it.id)
                                }
                        }
                    }
                    // Built by the right-click (see RightClickMenu) so Shift+right-click
                    // reaches the extended menu here too.
                    .appKitContextMenu { fileContextMenu(model: model, browser: browser, ids: contextIDs(for: it.id)) }
                } else {
                    Text("No items").foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(items) { it in
                            ThumbImage(item: it, browser: browser)
                                .frame(width: 66, height: 66)
                                .padding(3)
                                .background(browser.selection.contains(it.id) ? Color.accentColor.opacity(0.3) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .id(it.id)
                                .dropDestination(for: URL.self) { urls, _ in
                                    if it.isDirectory { browser.dropInto(urls, folder: it.url) }
                                    else { browser.dropIntoCurrentFolder(urls) }
                                    return true
                                } isTargeted: { t in
                                    guard it.isDirectory else { return }   // see IconCell
                                    if t { SpringLoader.shared.hover(folder: it.url, browser: browser) }
                                    else { SpringLoader.shared.leave(it.url) }
                                }
                                // Same reason as the icon grid: .draggable can only carry
                                // one file, so a multi-selection dragged just the one
                                // grabbed. AppKit handles the mouse so every selected file
                                // travels. (No rename arming in the filmstrip — the big
                                // preview's title handles that.)
                                .overlay {
                                    IconCellMouseHandler(
                                        select: { e in browser.click(it.id, modifiers: e.modifierFlags) },
                                        isSelected: { browser.selection.contains(it.id) },
                                        open: { openItem(it, browser) },
                                        plainClickCompleted: {},
                                        urlsForDrag: {
                                            if browser.selection.contains(it.id), browser.selection.count > 1 {
                                                return browser.orderedVisibleItems()
                                                    .filter { browser.selection.contains($0.id) }.map { $0.url }
                                            }
                                            return [it.url]
                                        },
                                        dragIcon: { browser.icon(for: it) }
                                    )
                                }
                                .appKitContextMenu { fileContextMenu(model: model, browser: browser, ids: contextIDs(for: it.id)) }
                        }
                    }.padding(8)
                }
                .frame(height: 92)
                .onChange(of: browser.keyboardScrollID) {
                    if let id = browser.keyboardScrollID { withAnimation { proxy.scrollTo(id) } }
                }
                // Coming back to a folder in gallery view: the restored selection is
                // already driving the big preview, this brings its thumbnail back into
                // the filmstrip so the strip agrees with what's on show.
                .onChange(of: browser.restoreScroll) {
                    if let r = browser.restoreScroll { proxy.scrollTo(r.id) }
                }
            }
        }
    }
}

struct StatusBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var bgJob = BGJobProgress.shared
    var body: some View {
        HStack {
            if bgJob.active {
                // App-wide background-removal progress — non-blocking; the user
                // keeps using Navigator while Photoshop / After Effects work.
                if let f = bgJob.fraction {
                    ProgressView(value: f).frame(width: 90).controlSize(.small)
                } else {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                Text(bgJob.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("·").font(.caption).foregroundStyle(.tertiary)
            }
            if browser.busy {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(browser.busyText).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(browser.status).font(.caption).foregroundStyle(.secondary)
                if !browser.freeSpace.isEmpty {
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                    Text(browser.freeSpace).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if browser.slowNetwork {
                Label("Network drive responding slowly…", systemImage: "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                    .padding(.trailing, 8).transition(.opacity)
            }
            if browser.viewMode == .icon {
                Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $browser.iconSize, in: 48...192).frame(width: 110).controlSize(.mini)
            }
            Toggle("Show hidden files", isOn: $browser.showHidden).toggleStyle(.checkbox).font(.caption)
        }.padding(.horizontal, 10).padding(.vertical, 4)
    }
}

struct TabItemView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var browser: Browser
    let index: Int
    let isSelected: Bool
    let showClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var dropTargeted = false
    private var title: String {
        if browser.isRecents { return "Recents" }
        let n = browser.currentURL.lastPathComponent
        return n.isEmpty ? "Macintosh HD" : n
    }
    var body: some View {
        HStack(spacing: 6) {
            if browser.busy {
                ProgressView().controlSize(.mini).scaleEffect(0.55).frame(width: 12, height: 12)
            } else {
                Image(systemName: browser.slowNetwork ? "wifi.exclamationmark" : "folder")
                    .font(.caption2).foregroundStyle(browser.slowNetwork ? .orange : .secondary)
            }
            Text(title).font(.callout).lineLimit(1)
            if showClose {
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.30) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: dropTargeted ? 2 : 0))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        // THE tab's one and only drop handler, for BOTH payloads. A second destination for
        // the reorder token would win the hit test over this one and then decline the file
        // URLs it doesn't recognise, silently killing drop-a-file-onto-a-tab — the exact
        // bug that broke sidebar favorite reordering. Told apart by what they are, like the
        // sidebar does (TabDragToken / ReorderToken). Do NOT add a second drop modifier.
        .dropDestination(for: URL.self) { urls, _ in
            if let src = urls.first.flatMap({ TabDragToken.index(of: $0, model: model) }) {
                // Released ON a tab, so this was a reorder however far the pointer roamed —
                // including a release back on the source tab, which does nothing. Either
                // way it must not also tear the tab off into a new window.
                TabDrag.shared.noteHandled()
                model.moveTab(from: src, to: index)
                return true
            }
            browser.dropInto(urls, folder: browser.currentURL)
            onSelect(); return true
        } isTargeted: { dropTargeted = $0 }
        // Drag a tab: sideways onto another tab reorders, pulled out of the strip it
        // becomes its own window (see TabDrag). onDrag rather than draggable for the same
        // reason the sidebar uses it — draggable loses the mouse-down to the content.
        //
        // The .onTapGesture above still fires (verified live): onDrag only claims the
        // gesture once the press has travelled past the drag threshold, and a press that
        // moves ~12pt before releasing IS a drag, in this strip exactly as in Chrome's.
        .onDrag {
            TabDrag.shared.begin(model: model, index: index)
            return TabDragToken.provider(model: model, index: index)
        }
        // Safe to attach here, unlike on a file cell: a tab carries no
        // NSViewRepresentable mouse handler, so nothing else is competing for the
        // click and the existing .onTapGesture / .dropDestination keep working.
        .contextMenu {
            Button("New Tab") { model.newTab() }
            Button("Duplicate Tab") { model.newTab(at: browser.currentURL) }
            Divider()
            Button("Close Tab") { onClose() }
                .disabled(model.tabs.count < 2)
            // Disabled, not silently inert, when there is nothing to close — the same
            // TabMenuRules checks the actions themselves guard on.
            Button("Close Other Tabs") { model.closeOtherTabs(index) }
                .disabled(!TabMenuRules.canCloseOthers(index: index, count: model.tabs.count))
            Button("Close Tabs to the Right") { model.closeTabsToRight(index) }
                .disabled(!TabMenuRules.canCloseToRight(index: index, count: model.tabs.count))
            Divider()
            Button("Move Tab to New Window") { model.moveTabToNewWindow(index) }
                .disabled(!TabMenuRules.canMoveToNewWindow(index: index, count: model.tabs.count))
            Divider()
            // This tab's folder, never the active one — that distinction is the whole
            // point of a per-tab menu.
            Button("Copy Path") { browser.copyToClipboard(browser.currentURL.path) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([browser.currentURL]) }
        }
    }
}

struct TabStrip: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.tabs.enumerated()), id: \.element.id) { idx, browser in
                TabItemView(model: model, browser: browser, index: idx,
                            isSelected: idx == model.selected,
                            showClose: model.tabs.count > 1,
                            onSelect: { model.selected = idx },
                            onClose: { model.closeTab(idx) })
            }
            Button { model.newTab() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).help("New Tab (⌘T)")
            Spacer()
        }.padding(.horizontal, 8).padding(.vertical, 5)
    }
}

// The middle pane: toolbar, breadcrumb/search banner, file view, status bar.
struct BrowserContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var browser: Browser
    var body: some View {
        VStack(spacing: 0) {
            if browser.isSearching {
                SearchBanner(browser: browser)
                Divider()
            } else {
                BreadcrumbBar(browser: browser, model: model)
                Divider()
            }
            Group {
                if browser.networkStalled && browser.items.isEmpty {
                    StalledShareView(browser: browser)
                } else {
                    switch browser.viewMode {
                    case .icon: IconGridView(model: model, browser: browser)
                    case .gallery: GalleryView(model: model, browser: browser)
                    default: FileTableView(model: model, browser: browser)
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                browser.dropIntoCurrentFolder(urls); return true
            }
            Divider()
            StatusBar(browser: browser)
        }
    }
}

// Frame-based NSSplitView with an explicit delegate. Divider positions are
// changed ONLY by a user drag or a collapse toggle — never by a relayout — so
// SwiftUI re-renders (which happen constantly) can't make a divider snap back.
// This is the classic, predictable model:
//   • drag a divider  → its two neighbours trade width (min/max enforced)
//   • resize the window → only the middle (content) pane flexes
//   • side panes keep their width and are remembered across launches
final class PaneController: NSViewController, NSSplitViewDelegate {
    let sidebarHC = NSHostingController(rootView: AnyView(EmptyView()))
    let contentHC = NSHostingController(rootView: AnyView(EmptyView()))
    let previewHC = NSHostingController(rootView: AnyView(EmptyView()))

    private let splitView = NSSplitView()
    private let sidebarPane = NSView()
    private let contentPane = NSView()
    private let previewPane = NSView()

    private let sidebarMin: CGFloat = 180, sidebarMax: CGFloat = 380
    private let contentMin: CGFloat = 400
    private let previewMin: CGFloat = 200, previewMax: CGFloat = 620

    private var sidebarWidth = Prefs.sidebarWidth
    private var previewWidth = Prefs.previewWidth
    private var sidebarCollapsed: Bool
    private var previewCollapsed: Bool
    private var didInitialLayout = false
    private var applyingLayout = false
    private var bypassConstraints = false

    init(sidebarCollapsed: Bool, previewCollapsed: Bool) {
        self.sidebarCollapsed = sidebarCollapsed
        self.previewCollapsed = previewCollapsed
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        for (pane, hc) in [(sidebarPane, sidebarHC), (contentPane, contentHC), (previewPane, previewHC)] {
            hc.sizingOptions = []                       // never push SwiftUI's size back into AppKit
            addChild(hc)
            hc.view.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(hc.view)
            NSLayoutConstraint.activate([
                hc.view.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
                hc.view.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
                hc.view.topAnchor.constraint(equalTo: pane.topAnchor),
                hc.view.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            ])
            splitView.addSubview(pane)
        }
        view = splitView
        NotificationCenter.default.addObserver(self, selector: #selector(didResize(_:)),
                                               name: NSSplitView.didResizeSubviewsNotification, object: splitView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didInitialLayout, splitView.bounds.width > 0 {
            didInitialLayout = true
            applyLayout()
        }
    }

    private var total: CGFloat { splitView.bounds.width }
    private var thickness: CGFloat { splitView.dividerThickness }

    // Set divider positions from the stored widths. Called only initially and on
    // an explicit collapse/expand — NOT on every relayout.
    private func applyLayout() {
        guard total > 0 else { return }
        applyingLayout = true
        bypassConstraints = true      // let setPosition reach 0 / full width to truly collapse
        let sw = sidebarCollapsed ? 0 : sidebarWidth
        let pw = previewCollapsed ? 0 : previewWidth
        splitView.setPosition(sw, ofDividerAt: 0)
        splitView.setPosition(total - pw, ofDividerAt: 1)
        bypassConstraints = false
        applyingLayout = false
    }

    // Window resize: hold the side panes, let only the content pane flex.
    func splitView(_ sv: NSSplitView, shouldAdjustSizeOfSubview subview: NSView) -> Bool {
        subview === contentPane
    }
    func splitView(_ sv: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === sidebarPane || subview === previewPane
    }
    // Drag limits. Bypassed during programmatic collapse/expand so panes can hit 0.
    //
    // THE COLLAPSED CASES ARE NOT OPTIONAL — they are the fix for "when I drag to resize
    // the window, the Details pane appears".
    //
    // A collapsed pane is a divider parked at an extreme: preview collapsed → divider 1
    // sits at `total`, sidebar collapsed → divider 0 sits at 0. Those are exactly the two
    // x positions where the window's own left/right resize border is, and the divider's
    // grab zone wins the hit test over it. So aiming at the window edge to resize grabs
    // the divider instead — and because these methods described the OPEN pane's drag
    // limits regardless of the collapsed state, that divider was free to travel to
    // `total - previewMin`, yanking a 200pt preview pane out of nothing. Confirmed by
    // measurement: one press-drag 1pt inside the right border moved no window at all and
    // took the preview pane from 0pt to 199pt.
    //
    // Pinning min == max at the extreme while collapsed makes that divider immovable, so
    // a mis-aimed window resize can no longer open the pane; the toggles stay the only
    // way in or out. (A live window resize was NOT the mechanism — verified separately
    // that AppKit leaves a collapsed subview collapsed across a resize, so re-asserting
    // the layout afterwards would have fixed nothing.)
    func splitView(_ sv: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        if bypassConstraints { return 0 }
        if i == 0 { return sidebarCollapsed ? 0 : sidebarMin }
        if previewCollapsed { return total }
        // divider 1: keep content ≥ contentMin and preview ≤ previewMax
        return max(sidebarPane.frame.maxX + thickness + contentMin, total - previewMax)
    }
    func splitView(_ sv: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        if bypassConstraints { return total }
        if i == 0 { return sidebarCollapsed ? 0 : min(sidebarMax, previewPane.frame.minX - thickness - contentMin) }
        if previewCollapsed { return total }
        // divider 1: keep preview ≥ previewMin
        return total - previewMin
    }

    // Remember the side-pane widths while they're open (ignore transient 0-widths).
    // Open/closed state is owned solely by the toggle buttons (setSidebar/setPreview),
    // so we never infer it from layout here — that used to spuriously flip the
    // persisted showPreview/showSidebar during initial layout.
    @objc private func didResize(_ n: Notification) {
        guard !applyingLayout else { return }
        if !sidebarCollapsed, sidebarPane.frame.width > 1 {
            sidebarWidth = sidebarPane.frame.width; Prefs.sidebarWidth = sidebarWidth
        }
        if !previewCollapsed, previewPane.frame.width > 1 {
            previewWidth = previewPane.frame.width; Prefs.previewWidth = previewWidth
        }
    }

    func setSidebar(collapsed: Bool) {
        guard collapsed != sidebarCollapsed else { return }
        sidebarCollapsed = collapsed
        applyLayout()
    }
    func setPreview(collapsed: Bool) {
        guard collapsed != previewCollapsed else { return }
        previewCollapsed = collapsed
        applyLayout()
    }
    func apply(sidebar: AnyView, content: AnyView, preview: AnyView) {
        sidebarHC.rootView = sidebar
        contentHC.rootView = content
        previewHC.rootView = preview
    }
}

struct BrowserPane: NSViewControllerRepresentable {
    @ObservedObject var model: AppModel
    var browser: Browser

    func makeNSViewController(context: Context) -> PaneController {
        let vc = PaneController(sidebarCollapsed: !model.showSidebar, previewCollapsed: !model.showPreview)
        _ = vc.view
        apply(vc)
        return vc
    }
    func updateNSViewController(_ vc: PaneController, context: Context) {
        apply(vc)
        vc.setSidebar(collapsed: !model.showSidebar)
        vc.setPreview(collapsed: !model.showPreview)
    }
    private func apply(_ vc: PaneController) {
        let content: AnyView
        if model.dualPane {
            content = AnyView(HSplitView {
                BrowserContent(model: model, browser: browser).id(browser.id).frame(minWidth: 260)
                BrowserContent(model: model, browser: model.secondary).id(model.secondary.id).frame(minWidth: 260)
            })
        } else {
            content = AnyView(BrowserContent(model: model, browser: browser).id(browser.id))
        }
        vc.apply(sidebar: AnyView(SidebarView(browser: browser, model: model)),
                 content: content,
                 preview: AnyView(PreviewPane(browser: browser)))
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: model)
            Divider()
            // Windows 11-style command bar spanning the full width, above the
            // navigation / content / details panes.
            ControlBar(model: model, browser: model.active)
            Divider()
            BrowserPane(model: model, browser: model.active)
        }.frame(minWidth: 880, minHeight: 560)
    }
}

// MARK: - Image viewer (left/right scroll through folder images)

// NSImageView plays animated GIFs natively; SwiftUI's Image renders only a
// single frame. Used by the image viewer and preview pane for GIFs.
struct AnimatedImage: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.animates = true
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        loadAsync(into: v)
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) { loadAsync(into: v) }
    private func loadAsync(into v: NSImageView) {
        let target = url
        DispatchQueue.global(qos: .userInitiated).async {
            let img = NSImage(contentsOf: target)
            DispatchQueue.main.async { v.image = img; v.animates = true }
        }
    }
}

// Pannable, zoomable image view. zoom is the display scale relative to the
// image's actual pixels (1.0 = 100%). Scroll wheel zooms toward the cursor,
// drag pans when zoomed in; the SwiftUI bar drives it via ZoomController.
final class ZoomView: NSView {
    var onZoomChange: ((Double, Double) -> Void)?     // (current, fit)
    private var _image: NSImage?
    private var _cgImage: CGImage?
    private var _zoom: Double = 1
    private var offset = CGPoint.zero
    private var didFit = false
    private var rotation = 0     // degrees, multiples of 90
    private var flipH = false
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func setImage(_ img: NSImage?) {
        _image = img
        _cgImage = img?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        offset = .zero; didFit = false; rotation = 0; flipH = false
        if bounds.width > 0, bounds.height > 0 { fit() } else { needsDisplay = true }
    }
    private var pixelSize: CGSize {
        guard let rep = _image?.representations.first else { return _image?.size ?? .zero }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
    var fitZoom: Double {
        let s = pixelSize
        let swap = (rotation % 180) != 0                 // 90°/270° swaps the fit box
        let iw = swap ? s.height : s.width, ih = swap ? s.width : s.height
        guard iw > 0, ih > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return Double(min(bounds.width / iw, bounds.height / ih))
    }
    var zoom: Double { _zoom }
    func rotate() { rotation = (rotation + 90) % 360; fit() }
    func flipHorizontal() { flipH.toggle(); needsDisplay = true }
    func actualSize() { setZoom(1) }
    func fit() {
        offset = .zero; _zoom = fitZoom; didFit = true
        needsDisplay = true; report()
    }
    func setZoom(_ z: Double) { zoomAt(CGPoint(x: bounds.midX, y: bounds.midY), factor: z / max(_zoom, 0.0001)) }
    func zoomBy(_ factor: Double) { zoomAt(CGPoint(x: bounds.midX, y: bounds.midY), factor: factor) }
    func zoomAt(_ p: CGPoint, factor: Double) {
        let old = _zoom
        let newZoom = max(0.05, min(old * factor, 16))
        guard abs(newZoom - old) > 0.0001 else { return }
        let cx = bounds.midX + offset.x, cy = bounds.midY + offset.y
        let rel = CGPoint(x: p.x - cx, y: p.y - cy)
        let ratio = CGFloat(newZoom / old)
        offset.x -= rel.x * (ratio - 1); offset.y -= rel.y * (ratio - 1)
        _zoom = newZoom; clampOffset(); needsDisplay = true; report()
    }
    private func report() { onZoomChange?(_zoom, fitZoom) }
    private func clampOffset() {
        let s = pixelSize
        let w = CGFloat(s.width) * CGFloat(_zoom), h = CGFloat(s.height) * CGFloat(_zoom)
        let maxX = max(0, (w - bounds.width) / 2), maxY = max(0, (h - bounds.height) / 2)
        offset.x = min(maxX, max(-maxX, offset.x)); offset.y = min(maxY, max(-maxY, offset.y))
    }
    override func layout() {
        super.layout()
        if !didFit, _image != nil, bounds.width > 0, bounds.height > 0 { fit() } else { clampOffset() }
    }
    override func draw(_ dirtyRect: NSRect) {
        // Clear to transparent (not black) so the viewer's checkerboard shows
        // through an image's alpha — makes transparency visible at a glance.
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        guard let img = _image else { return }
        let s = pixelSize
        let w = CGFloat(s.width) * CGFloat(_zoom), h = CGFloat(s.height) * CGFloat(_zoom)
        let cx = bounds.midX + offset.x, cy = bounds.midY + offset.y
        guard let cg = _cgImage, let ctx = NSGraphicsContext.current?.cgContext else {
            // Fallback: no CGImage (rare) — draw upright without transform.
            img.draw(in: NSRect(x: cx - w/2, y: cy - h/2, width: w, height: h))
            return
        }
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        ctx.rotate(by: CGFloat(Double(rotation) * .pi / 180))
        if flipH { ctx.scaleBy(x: -1, y: 1) }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: -w/2, y: -h/2, width: w, height: h))
        ctx.restoreGState()
    }
    override func scrollWheel(with event: NSEvent) {
        let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        guard d != 0 else { return }
        zoomAt(convert(event.locationInWindow, from: nil), factor: 1 + Double(d) * 0.012)
    }
    private var lastDrag: CGPoint?
    override func mouseDown(with event: NSEvent) { lastDrag = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let l = lastDrag else { return }
        let p = convert(event.locationInWindow, from: nil)
        offset.x += p.x - l.x; offset.y += p.y - l.y
        lastDrag = p; clampOffset(); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { lastDrag = nil }
}

final class ZoomController: ObservableObject {
    @Published var zoom: Double = 1
    @Published var fitZoom: Double = 1
    weak var view: ZoomView?
    var percent: Int { Int((zoom * 100).rounded()) }
    func setZoom(_ z: Double) { view?.setZoom(z) }
    func zoomBy(_ f: Double) { view?.zoomBy(f) }
    func fit() { view?.fit() }
    func rotate() { view?.rotate() }
    func flipHorizontal() { view?.flipHorizontal() }
    func actualSize() { view?.actualSize() }
}

struct ZoomableImageView: NSViewRepresentable {
    let url: URL
    let controller: ZoomController
    func makeNSView(context: Context) -> ZoomView {
        let v = ZoomView()
        v.onZoomChange = { z, fit in DispatchQueue.main.async { controller.zoom = z; controller.fitZoom = fit } }
        controller.view = v
        context.coordinator.url = url
        loadAsync(into: v, coord: context.coordinator)
        return v
    }
    func updateNSView(_ v: ZoomView, context: Context) {
        controller.view = v
        if context.coordinator.url != url {
            context.coordinator.url = url
            loadAsync(into: v, coord: context.coordinator)
        }
    }
    // Decode off the main thread — a large PSD / online-only file would freeze
    // the UI if read on the main thread. Ignore a stale load if the view moved on.
    private func loadAsync(into v: ZoomView, coord: Coord) {
        let target = url
        DispatchQueue.global(qos: .userInitiated).async {
            let img = NSImage(contentsOf: target)
            DispatchQueue.main.async { if coord.url == target { v.setImage(img) } }
        }
    }
    func makeCoordinator() -> Coord { Coord() }
    final class Coord { var url: URL? }
}

// Transparency checkerboard — the standard way to show that an image is
// transparent rather than black-backed. Mid grays so it reads clearly as a
// checker while staying dark enough that the white nav/zoom controls stay legible.
struct CheckerboardBackground: View {
    var square: CGFloat = 14
    var body: some View {
        Canvas { ctx, size in
            let light = Color(white: 0.42), dark = Color(white: 0.30)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(dark))
            let cols = Int(ceil(size.width / square)), rows = Int(ceil(size.height / square))
            for r in 0..<rows {
                for c in 0..<cols where (r + c) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(c) * square, y: CGFloat(r) * square, width: square, height: square)), with: .color(light))
                }
            }
        }
        .drawingGroup()
        .ignoresSafeArea()
    }
}

// Frosted-glass backdrop (default) — an image's transparent areas reveal the
// blurred content behind the window, so it reads as transparent, not black.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// Shared picker for the viewer/compare background (Frosted Glass vs Checkerboard),
// persisted in one place so both windows stay in sync.
struct BackdropPicker: View {
    @AppStorage("viewerBackdrop") private var backdrop = "glass"
    var body: some View {
        Menu {
            Picker("Viewer Background", selection: $backdrop) {
                Text("Frosted Glass").tag("glass")
                Text("Checkerboard").tag("checker")
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            Image(systemName: backdrop == "checker" ? "square.grid.3x3" : "sparkles")
        }
        .menuIndicator(.hidden).fixedSize().help("Viewer background: Frosted Glass or Checkerboard")
    }
}

// Chosen background as a view — used by both the viewer and swipe-compare.
struct BackdropView: View {
    @AppStorage("viewerBackdrop") private var backdrop = "glass"
    var body: some View {
        if backdrop == "checker" { CheckerboardBackground() } else { VisualEffectBackground().ignoresSafeArea() }
    }
}

/// Reads back what writePNGWithRestyleMetadata wrote, if this file was ever
/// restyled by Navigator. nil for anything else — including a PNG with unrelated
/// Title/Description metadata from some other app, so this can never show the
/// wrong tool's notes as if they were a restyle prompt.
struct RestyleInfo { let prompt: String, contents: String, software: String }
func readRestyleInfo(_ url: URL) -> RestyleInfo? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any],
          let software = png[kCGImagePropertyPNGSoftware] as? String,
          software.hasPrefix("Navigator Restyle") else { return nil }
    let prompt = png[kCGImagePropertyPNGDescription] as? String ?? ""
    let contents = png[kCGImagePropertyPNGTitle] as? String ?? ""
    guard !prompt.isEmpty || !contents.isEmpty else { return nil }
    return RestyleInfo(prompt: prompt, contents: contents, software: software)
}

struct ImageViewerView: View {
    @State private var urls: [URL]
    var onTitle: (String) -> Void = { _ in }
    @State private var index: Int
    @State private var dims: String = ""
    @State private var sizeStr: String = ""
    @State private var kindStr: String = ""
    @State private var showRestyleInfo = false
    /// Identifies THIS viewer to its own undo notifications. @State, not a plain `let`:
    /// SwiftUI re-creates the struct on every update, so a `let` would hand out a fresh
    /// id each time and the undo posted by one instance would match none of them.
    @State private var viewerID = UUID()
    @StateObject private var zoomCtl = ZoomController()
    // Read fresh per access rather than cached in @State — cheap (one CGImageSource
    // properties read) and guarantees the (i) button never shows stale info if the
    // file on disk changed under the same viewer session.
    private var restyleInfo: RestyleInfo? { urls.indices.contains(index) ? readRestyleInfo(urls[index]) : nil }
    init(urls: [URL], index: Int, onTitle: @escaping (String) -> Void = { _ in }) {
        _urls = State(initialValue: urls); self.onTitle = onTitle; _index = State(initialValue: index)
    }
    // Move the current image to the Trash (with an optional, suppressible warning),
    // then advance to the next. Undo (⌘Z) restores it from the Trash.
    private func deleteCurrent() {
        guard urls.indices.contains(index) else { return }
        let target = urls[index]
        let perform = {
            // trashItems, not fm.trashItem: the helper records where this came from, so
            // Put Back works on an image deleted here. A bare trashItem left it in the
            // Trash with no origin at all.
            let r = trashItems([target])
            guard let landed = r.restores.first?.from else {
                reportFileError("Couldn't move “\(target.lastPathComponent)” to the Trash.", r.problem ?? "")
                return
            }
            var trashed: URL? = landed   // re-pointed by redo; the Trash path changes each round
            // Where it was in THIS viewer's list, captured now: the closures below run
            // long after `index` has moved on to the next picture.
            let wasAt = index
            let vid = viewerID
            // Undoing the delete used to put the file back on disk and nothing else, so
            // the picture stayed missing from the viewer you deleted it in until you
            // closed and reopened the folder — the one place the user is looking.
            //
            // Posted rather than written straight into `urls`: this closure outlives the
            // window (the undo stack is app-wide, and the viewer closes itself when the
            // last image goes), and writing into a torn-down @State is a SwiftUI warning
            // and a silently dropped update. A notification nobody is listening for is
            // simply nothing.
            let tell = { (insert: Bool) in
                NotificationCenter.default.post(name: .navigatorImageViewerUndo, object: nil,
                                                userInfo: ["viewer": vid, "url": target,
                                                           "index": wasAt, "insert": insert])
            }
            UndoStack.shared.push("Delete “\(target.lastPathComponent)”", undo: {
                guard let t = trashed else { return nil }
                if let problem = restoreItems([(from: t, to: target)]) { return problem }
                tell(true)
                return nil
            }, redo: {
                // Fresh Trash path on every re-bin, so point the undo half at it.
                let r = trashItems([target])
                trashed = r.restores.first?.from
                if r.problem == nil { tell(false) }
                return r.problem
            })
            urls.remove(at: index)
            if urls.isEmpty { NSApp.keyWindow?.close(); return }
            if index >= urls.count { index = urls.count - 1 }
            loadInfo()
        }
        guard Prefs.warnImageDelete else { perform(); return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Move “\(target.lastPathComponent)” to the Trash?"
        a.informativeText = "You can bring it back with Undo (⌘Z)."
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "Don't ask again"
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        let resp = a.runModal()
        if a.suppressionButton?.state == .on { Prefs.warnImageDelete = false }
        if resp == .alertFirstButtonReturn { perform() }
    }
    private func step(_ d: Int) {
        guard !urls.isEmpty else { return }
        index = (index + d + urls.count) % urls.count
    }
    private var currentURL: URL? { urls.indices.contains(index) ? urls[index] : nil }
    // Put the decoded picture on the clipboard (paste into Photoshop, Slack, docs…).
    private func copyImageToClipboard() {
        guard let u = currentURL, let img = NSImage(contentsOf: u) else { NSSound.beep(); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([img])
    }
    // Put the file itself on the clipboard as a file reference, so ⌘V pastes the
    // actual file into any Navigator (or Finder) folder. Matches copyFiles().
    private func copyFileToClipboard() {
        guard let u = currentURL else { NSSound.beep(); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([u as NSURL])
    }
    private func copyLocation() {
        guard let u = currentURL else { NSSound.beep(); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.path, forType: .string)
    }
    private func copyFileName() {
        guard let u = currentURL else { NSSound.beep(); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.lastPathComponent, forType: .string)
    }
    // After a background-removal finishes, move the viewer to the new "_rmbg"
    // image: jump to it if already in the list, otherwise insert it after the
    // current image and show it.
    private func revealNewImage(_ out: URL) {
        if let existing = urls.firstIndex(of: out) {
            index = existing
        } else {
            let insertAt = min(index + 1, urls.count)
            urls.insert(out, at: insertAt)
            index = insertAt
        }
        loadInfo()
    }
    private var zoomBinding: Binding<Double> {
        Binding(get: { zoomCtl.zoom }, set: { zoomCtl.setZoom($0) })
    }
    // Read dimensions / size / kind for the bottom detail bar (Windows Photos-style).
    private func loadInfo() {
        guard urls.indices.contains(index) else { dims = ""; sizeStr = ""; kindStr = ""; return }
        let u = urls[index]
        onTitle(u.lastPathComponent)   // keep the window title in sync with ←/→ navigation
        let vals = try? u.resourceValues(forKeys: [.fileSizeKey, .localizedTypeDescriptionKey])
        sizeStr = (vals?.fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        kindStr = vals?.allValues[.localizedTypeDescriptionKey] as? String ?? u.pathExtension.uppercased()
        dims = ""
        // Read pixel dimensions straight from the image header (instant, works for
        // just-created files that Spotlight hasn't indexed — unlike MetadataCache).
        DispatchQueue.global(qos: .userInitiated).async {
            var wh: (Int, Int)?
            if let src = CGImageSourceCreateWithURL(u as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 {
                wh = (w, h)
            }
            DispatchQueue.main.async {
                guard urls.indices.contains(index), urls[index] == u, let wh else { return }
                dims = "\(wh.0) × \(wh.1)"
            }
        }
    }
    private var isAnimated: Bool { urls.indices.contains(index) && isAnimatedImage(urls[index]) }
    var body: some View {
        ZStack {
            BackdropView()
            // Image lives in the area ABOVE the bottom bar so nothing is hidden
            // behind it; the bar is a sibling below, not an overlay.
            VStack(spacing: 0) {
                ZStack {
                    if urls.indices.contains(index), isAnimated {
                        AnimatedImage(url: urls[index]).padding(44).id(urls[index])
                    } else if urls.indices.contains(index) {
                        ZoomableImageView(url: urls[index], controller: zoomCtl).id(urls[index])
                    } else {
                        Text("Can't load image").foregroundStyle(.white)
                    }
                    HStack {
                        Button { step(-1) } label: { Image(systemName: "chevron.left.circle.fill").font(.system(size: 36)) }
                            .buttonStyle(.plain).keyboardShortcut(.leftArrow, modifiers: [])
                        Spacer()
                        Button { step(1) } label: { Image(systemName: "chevron.right.circle.fill").font(.system(size: 36)) }
                            .buttonStyle(.plain).keyboardShortcut(.rightArrow, modifiers: [])
                    }.foregroundStyle(.white.opacity(0.8)).padding(.horizontal, 14)
                }
                bottomBar
            }
            // ⌘+ / ⌘= zoom in, ⌘- zoom out, ⌘0 fit (hidden shortcut buttons)
            Group {
                Button("") { zoomCtl.zoomBy(1.25) }.keyboardShortcut("+", modifiers: .command)
                Button("") { zoomCtl.zoomBy(1.25) }.keyboardShortcut("=", modifiers: .command)
                Button("") { zoomCtl.zoomBy(0.8) }.keyboardShortcut("-", modifiers: .command)
                Button("") { zoomCtl.fit() }.keyboardShortcut("0", modifiers: .command)
                Button("") { deleteCurrent() }.keyboardShortcut(.delete, modifiers: [])
                Button("") { UndoStack.shared.undo() }.keyboardShortcut("z", modifiers: .command)
                Button("") { UndoStack.shared.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
                Button("") { NSApp.keyWindow?.close() }.keyboardShortcut(.escape, modifiers: [])
            }.frame(width: 0, height: 0).opacity(0)
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear { loadInfo() }
        .onChange(of: index) { loadInfo() }
        // ⌘Z / ⇧⌘Z on an image deleted from this viewer. Only this viewer's own id is
        // honoured, so a second open viewer doesn't grow a picture it never deleted.
        .onReceive(NotificationCenter.default.publisher(for: .navigatorImageViewerUndo)) { note in
            guard let info = note.userInfo, info["viewer"] as? UUID == viewerID,
                  let u = info["url"] as? URL else { return }
            if info["insert"] as? Bool == true {
                guard !urls.contains(u) else { index = urls.firstIndex(of: u) ?? index; return }
                // Clamped: the viewer may have been reordered or shortened by a later
                // delete, so the recorded index is a hint, not a promise.
                let at = min(info["index"] as? Int ?? urls.count, urls.count)
                urls.insert(u, at: at)
                index = at
            } else if let at = urls.firstIndex(of: u) {
                urls.remove(at: at)
                if urls.isEmpty { NSApp.keyWindow?.close(); return }
                index = min(index, urls.count - 1)
            }
            loadInfo()
        }
        .contextMenu {
            Button("Copy to Clipboard") { copyImageToClipboard() }
            Button("Copy File") { copyFileToClipboard() }
            Button("Copy Location") { copyLocation() }
            Button("Copy File Name") { copyFileName() }
            if let u = currentURL {
                Divider()
                OpenWithMenu(urls: [u])
                prepForAIMenu { c, ratio in
                    fillBackgroundForImages([u], color: c.color, suffix: c.suffix, ratio: ratio) { outs in if let o = outs.first { revealNewImage(o) } }
                }
                upscaleMenu(fal: { opt in
                    upscaleImagesViaFal([u], option: opt) { outs in if let o = outs.first { revealNewImage(o) } }
                }, imagen: { f in
                    upscaleImagesViaImagen([u], factor: f) { outs in if let o = outs.first { revealNewImage(o) } }
                })
                restyleMenuItem([u]) { out in revealNewImage(out) }
            }
            if (PhotoshopIcon.image != nil || AfterEffectsIcon.image != nil), let u = currentURL {
                Divider()
                if PhotoshopIcon.image != nil {
                    Button { removeBackgroundForImage(u) { out in revealNewImage(out) } } label: { psLabel("Remove BG") }
                }
                if AfterEffectsIcon.image != nil, u.pathExtension.lowercased() == "png" {
                    Button { chromaKeyForImage(u) { out in revealNewImage(out) } } label: { aeLabel("Chroma Key BG") }
                }
            }
        }
    }
    // Windows Photos-style bottom bar: details on the left, zoom controls on the right.
    private var bottomBar: some View {
        HStack(spacing: 12) {
            if urls.indices.contains(index) {
                // Filename is shown in the title bar, so keep the bottom bar to
                // dimensions · size · position.
                detail("photo", dims)
                detail("internaldrive", sizeStr)
                Text("·").foregroundStyle(.white.opacity(0.4))
                Text("\(index + 1) of \(urls.count)").foregroundStyle(.white.opacity(0.85))
                if restyleInfo != nil {
                    Button { showRestyleInfo = true } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.plain).help("Restyle info — the prompt Navigator used on this image")
                        .popover(isPresented: $showRestyleInfo, arrowEdge: .top) { RestyleInfoPopover(info: restyleInfo!) }
                }
            }
            Spacer(minLength: 12)
            BackdropPicker()
            if !isAnimated {
                Button { zoomCtl.rotate() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Rotate 90°")
                Button { zoomCtl.flipHorizontal() } label: { Image(systemName: "arrow.left.and.right") }
                    .buttonStyle(.plain).help("Flip Horizontal")
                Button { zoomCtl.actualSize() } label: { Text("1:1").font(.callout.monospacedDigit()) }
                    .buttonStyle(.plain).help("Actual Size (100%)")
                Button { zoomCtl.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.plain).help("Fit to Window (⌘0)")
                Button { zoomCtl.zoomBy(0.8) } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.plain).help("Zoom Out (⌘−)")
                Slider(value: zoomBinding, in: 0.05...8).frame(width: 130)
                Button { zoomCtl.zoomBy(1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.plain).help("Zoom In (⌘+)")
                Button { zoomCtl.actualSize() } label: {
                    Text("\(zoomCtl.percent)%").monospacedDigit().frame(width: 46, alignment: .trailing)
                }.buttonStyle(.plain).help("Reset to 100%")
            }
        }
        .font(.callout).foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(.black.opacity(0.6))
    }
    @ViewBuilder private func detail(_ symbol: String, _ text: String) -> some View {
        if !text.isEmpty {
            Label { Text(text) } icon: { Image(systemName: symbol).font(.caption) }
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// Popover content for the viewer's (i) button — read-only, text-selectable, with a
/// one-click copy since the prompt is often long enough that selecting it by hand is
/// annoying.
struct RestyleInfoPopover: View {
    let info: RestyleInfo
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Restyle Info").font(.headline)
                    Spacer()
                    Button { copyAll() } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).help("Copy prompt")
                }
                if !info.contents.isEmpty {
                    Text("Contents preserved").font(.caption).foregroundStyle(.secondary)
                    Text(info.contents).font(.system(size: 11)).textSelection(.enabled)
                }
                if !info.prompt.isEmpty {
                    Text("Prompt sent").font(.caption).foregroundStyle(.secondary)
                    Text(info.prompt).font(.system(size: 11)).textSelection(.enabled)
                }
                Text(info.software).font(.caption2).foregroundStyle(.tertiary)
            }.padding(14)
        }
        .frame(width: 340, height: 320)
    }
    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info.prompt.isEmpty ? info.contents : info.prompt, forType: .string)
    }
}

final class ImageViewerController {
    static let shared = ImageViewerController()
    private static var windows: [NSWindow] = []   // every open viewer (retained)

    // Every image open gets its OWN window, so images stack side by side —
    // including when earlier ones are minimized (a minimized window reports
    // isVisible == false, so reuse-based logic wrongly replaced it). ←/→ browses
    // within each window.
    func show(urls: [URL], index: Int) { ImageViewerController.open(urls: urls, index: index) }
    static func open(urls: [URL], index: Int) {
        guard !urls.isEmpty else { NSSound.beep(); return }
        let w = makeWindow()
        install(urls: urls, index: index, in: w)
        // Cascade off the most recent viewer so stacked windows don't perfectly overlap.
        if let last = windows.last { w.setFrameOrigin(NSPoint(x: last.frame.minX + 32, y: max(40, last.frame.minY - 32))) }
        windows.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            windows.removeAll { $0 === w }
        }
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private static func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.center(); return w
    }
    private static func install(urls: [URL], index: Int, in w: NSWindow) {
        w.title = urls.indices.contains(index) ? urls[index].lastPathComponent : "Image"
        w.contentView = NSHostingView(rootView: ImageViewerView(urls: urls, index: index) { [weak w] name in w?.title = name })
    }
}

// MARK: - Swipe compare (two images, aspect-aligned)

// Draws two images into the SAME box (each aspect-fit, so different resolutions
// line up aspect-to-aspect), with a draggable divider revealing the right image
// over the left. Shared zoom (scroll) + pan (drag); double-click resets.
final class CompareView: NSView {
    var leftImage: NSImage?
    var rightImage: NSImage?
    private var _zoom: Double = 1
    private var offset = CGPoint.zero
    private var dividerFrac: CGFloat = 0.5
    private var didFit = false
    private var draggingDivider = false
    private var lastDrag: CGPoint?
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    private func pixels(_ img: NSImage?) -> CGSize {
        guard let rep = img?.representations.first else { return img?.size ?? .zero }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
    // Aspect-fit EACH image into the window box, centered — never stretched to
    // the other's shape (that squashed mismatched-aspect images). Because both
    // fit the same box, a base and its 2× upscale (same aspect) land on the exact
    // same on-screen rect and overlay perfectly; different-aspect images each keep
    // their own shape at a comparable scale. Shared zoom/pan applied on top.
    private func destRect(for img: NSImage?) -> NSRect {
        let s = pixels(img)
        guard s.width > 0, s.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / s.width, bounds.height / s.height)
        let w = s.width * scale * CGFloat(_zoom), h = s.height * scale * CGFloat(_zoom)
        return NSRect(x: (bounds.width - w)/2 + offset.x, y: (bounds.height - h)/2 + offset.y, width: w, height: h)
    }
    func fit() { _zoom = 1; offset = .zero; didFit = true; needsDisplay = true }
    override func layout() {
        super.layout()
        if !didFit, bounds.width > 0 { fit(); return }
        if abs(_zoom - 1) < 0.001 { offset = .zero }   // at fit: stay centered when the window resizes
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        // Clear to transparent so the window's checkerboard/frosted-glass backdrop
        // shows through each image's alpha (and the letterbox areas).
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        let hints: [NSImageRep.HintKey: Any] = [.interpolation: NSImageInterpolation.high.rawValue]
        let dx = bounds.minX + dividerFrac * bounds.width
        // Clip EACH image to its own side of the divider, so neither shows through
        // the other's transparent areas (no v1 head bleeding behind v2). Each draws
        // into its OWN aspect-fit rect so mismatched aspects aren't squashed.
        if let left = leftImage {
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: bounds.minX, y: 0, width: dx - bounds.minX, height: bounds.height)).addClip()
            left.draw(in: destRect(for: left), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: hints)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        if let right = rightImage {
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: dx, y: 0, width: bounds.maxX - dx, height: bounds.height)).addClip()
            right.draw(in: destRect(for: right), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: hints)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let line = NSBezierPath(); line.lineWidth = 2
        line.move(to: CGPoint(x: dx, y: 0)); line.line(to: CGPoint(x: dx, y: bounds.height)); line.stroke()
        let handle = NSBezierPath(ovalIn: NSRect(x: dx-11, y: bounds.midY-11, width: 22, height: 22))
        NSColor.white.setFill(); handle.fill()
        NSColor.black.withAlphaComponent(0.55).setStroke(); handle.stroke()
    }
    override func scrollWheel(with event: NSEvent) {
        let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        guard d != 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let old = _zoom, nz = max(0.1, min(old * (1 + Double(d) * 0.012), 16))
        guard abs(nz - old) > 0.0001 else { return }
        let cx = bounds.midX + offset.x, cy = bounds.midY + offset.y
        let rel = CGPoint(x: p.x - cx, y: p.y - cy), ratio = CGFloat(nz/old)
        offset.x -= rel.x * (ratio - 1); offset.y -= rel.y * (ratio - 1)
        _zoom = nz; needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { fit(); return }
        let p = convert(event.locationInWindow, from: nil)
        draggingDivider = abs(p.x - (bounds.minX + dividerFrac * bounds.width)) < 16
        lastDrag = p
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if draggingDivider {
            dividerFrac = max(0, min(1, (p.x - bounds.minX) / max(1, bounds.width)))
        } else if let l = lastDrag {
            offset.x += p.x - l.x; offset.y += p.y - l.y
        }
        lastDrag = p; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { lastDrag = nil; draggingDivider = false }
}

struct SwipeCompare: NSViewRepresentable {
    let left: NSImage?
    let right: NSImage?
    func makeNSView(context: Context) -> CompareView { let v = CompareView(); v.leftImage = left; v.rightImage = right; return v }
    func updateNSView(_ v: CompareView, context: Context) { v.leftImage = left; v.rightImage = right; v.needsDisplay = true }
}

struct SwipeCompareView: View {
    let leftURL: URL, rightURL: URL
    @State private var leftImg: NSImage?
    @State private var rightImg: NSImage?
    var body: some View {
        ZStack {
            BackdropView()
            SwipeCompare(left: leftImg, right: rightImg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    // Decode off the main thread so opening compare on large
                    // images doesn't freeze the UI.
                    DispatchQueue.global(qos: .userInitiated).async {
                        let l = NSImage(contentsOf: leftURL), r = NSImage(contentsOf: rightURL)
                        DispatchQueue.main.async { leftImg = l; rightImg = r }
                    }
                }
            VStack {
                HStack { tag(leftURL.lastPathComponent); Spacer(); tag(rightURL.lastPathComponent) }.padding(12)
                Spacer()
                HStack(spacing: 10) {
                    BackdropPicker().foregroundStyle(.white)
                    Text("Drag the divider to swipe  ·  scroll to zoom  ·  drag to pan  ·  double-click to reset")
                        .font(.caption).foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.5)).clipShape(Capsule()).padding(.bottom, 12)
            }
        }.frame(minWidth: 560, minHeight: 440)
    }
    private func tag(_ t: String) -> some View {
        Text(t).font(.callout).foregroundStyle(.white).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.55)).clipShape(Capsule())
    }
}

final class CompareController {
    private static var windows: [NSWindow] = []
    static func show(left: URL, right: URL) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 740),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = "Compare — \(left.lastPathComponent)  ↔  \(right.lastPathComponent)"
        w.contentView = NSHostingView(rootView: SwipeCompareView(leftURL: left, rightURL: right))
        w.center(); windows.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            windows.removeAll { $0 === w }
        }
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Rich Get Info window

/// Everything Get Info's Sharing & Permissions section needs, read in ONE pass —
/// stat + two directory-service lookups + one resource read. Off the main thread,
/// because on a network file each of those is a round-trip.
struct FileAccess {
    var mode: UInt16 = 0
    var owner = "—"
    var group = "—"
    var locked = false
    var isDirectory = false
    /// Only the owner (or root) can chmod, so the pickers are read-only for anyone
    /// else — offering an editable control that always fails is worse than showing
    /// the truth.
    var canChangeMode = false
}

func readFileAccess(_ url: URL) -> FileAccess? {
    var st = stat()
    // stat, not lstat: chmod() FOLLOWS a symlink, so reading the link's own mode here
    // would show one thing and change another — the picker would say "Read only" for
    // the link while the change landed on the file it points at. lstat is only the
    // fallback for a BROKEN link, where there is nothing else to describe.
    guard stat(url.path, &st) == 0 || lstat(url.path, &st) == 0 else { return nil }
    var a = FileAccess()
    a.mode = UInt16(st.st_mode) & 0o7777
    a.isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
    a.owner = getpwuid(st.st_uid).flatMap { String(validatingUTF8: $0.pointee.pw_name) } ?? String(st.st_uid)
    a.group = getgrgid(st.st_gid).flatMap { String(validatingUTF8: $0.pointee.gr_name) } ?? String(st.st_gid)
    a.locked = (st.st_flags & UInt32(UF_IMMUTABLE)) != 0
    a.canChangeMode = st.st_uid == geteuid() || geteuid() == 0
    return a
}

/// chmod, returning nil on success or a message to show. Deliberately NOT
/// `try? FileManager.setAttributes`: that swallows the reason, and "you are not the
/// owner" is the entire useful content of the failure.
func setPosixMode(_ url: URL, _ mode: UInt16) -> String? {
    guard chmod(url.path, mode_t(mode)) != 0 else { return nil }
    return String(cString: strerror(errno))
}

/// Finder's "Locked" checkbox — the UF_IMMUTABLE (uchg) flag, which stops the file
/// being renamed, moved, edited or deleted until it's cleared.
func setLocked(_ url: URL, _ locked: Bool) -> String? {
    var u = url
    var v = URLResourceValues()
    v.isUserImmutable = locked
    do { try u.setResourceValues(v); return nil }
    catch { return error.localizedDescription }
}

/// What an alias or symlink points at, or nil if this isn't one.
///
/// Symlinks are checked FIRST: `.isAliasFileKey` is true for symbolic links as well
/// as for Finder aliases, so testing it first would send every symlink through the
/// bookmark resolver, which can't read one.
func aliasTarget(_ url: URL) -> URL? {
    let rv = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
    if rv?.isSymbolicLink == true {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        return dest.hasPrefix("/")
            ? URL(fileURLWithPath: dest)
            : url.deletingLastPathComponent().appendingPathComponent(dest).standardizedFileURL
    }
    if rv?.isAliasFile == true, let t = try? URL(resolvingAliasFileAt: url, options: []),
       t.standardizedFileURL != url.standardizedFileURL {
        return t
    }
    return nil
}

struct GetInfoView: View {
    @ObservedObject var browser: Browser
    /// One item, or a whole selection. A multi-item window shows the combined
    /// summary instead of per-item fields — the old behaviour for >1 item was a bare
    /// NSAlert with three lines of text.
    let items: [FileItem]
    private var item: FileItem { items[0] }
    private var isMulti: Bool { items.count > 1 }
    @ObservedObject private var sizeCache = FolderSizeCache.shared
    @State private var name: String
    @State private var comment: String = ""
    @State private var tags: [String]
    @State private var thumb: NSImage?
    @State private var meta = FileMeta()
    @State private var access: FileAccess?
    @State private var target: URL?
    private static let df: DateFormatter = { let d = DateFormatter(); d.dateStyle = .long; d.timeStyle = .short; return d }()

    init(browser: Browser, items: [FileItem]) {
        self.browser = browser; self.items = items
        _name = State(initialValue: items[0].name)
        _tags = State(initialValue: items[0].tags)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    Group {
                        if isMulti {
                            Image(systemName: "square.stack.3d.up").resizable().scaledToFit().foregroundStyle(.secondary)
                        } else if let t = thumb {
                            Image(nsImage: t).resizable().scaledToFit()
                        } else {
                            Image(nsImage: browser.icon(for: item)).resizable().scaledToFit()
                        }
                    }.frame(width: 120, height: 120)
                    Spacer()
                }
                if isMulti {
                    Text("\(items.count) items selected").font(.headline)
                    Divider()
                    Group {
                        row("Total Size", multiSizeText())
                        row("Files", "\(items.filter { !$0.isDirectory }.count)")
                        row("Folders", "\(items.filter { $0.isDirectory }.count)")
                        row("Where", item.url.deletingLastPathComponent().path)
                    }.font(.callout)
                    if items.contains(where: { $0.isDirectory }) {
                        Button("Calculate Folder Sizes") {
                            for it in items where it.isDirectory { FolderSizeCache.shared.compute(it.url) }
                        }
                    }
                } else {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder).font(.headline)
                        .onSubmit { if name != item.name { browser.rename(id: item.id, to: name) } }
                }
                Divider()
                if !isMulti {
                    Group {
                        row("Kind", item.kind)
                        row("Size", sizeText())
                        if let d = meta.duration, d >= 1 { row("Duration", formatDuration(d)) }
                        if let w = meta.width, let h = meta.height, w > 0, h > 0 { row("Dimensions", "\(w) × \(h)") }
                        row("Created", Self.df.string(from: item.created))
                        row("Modified", Self.df.string(from: item.modified))
                        row("Added", Self.df.string(from: item.dateAdded))
                        row("Where", item.url.deletingLastPathComponent().path)
                    }.font(.callout)
                    // An alias/symlink whose target is shown and reachable — the whole
                    // point of Get Info on one is finding out what it actually points at.
                    if let target {
                        Divider()
                        Text("Original").font(.subheadline).bold()
                        row("Points to", target.path)
                        let exists = FileManager.default.fileExists(atPath: target.path)
                        HStack {
                            Button("Reveal Original") { browser.revealInApp(target) }.disabled(!exists)
                            if !exists {
                                Label("The original is missing.", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    Divider()
                    Toggle("Locked", isOn: Binding(
                        get: { access?.locked ?? false },
                        set: { changeLocked($0) }
                    )).disabled(access == nil)
                        .help("A locked item can't be renamed, moved, edited or deleted until it's unlocked.")
                }
                Divider()
                sharingSection()
                Divider()
                Text("Tags").font(.subheadline).bold()
                HStack(spacing: 8) {
                    ForEach(standardTags, id: \.self) { t in
                        Button { toggle(t) } label: {
                            Circle().fill(tagColor(t)).frame(width: 20, height: 20)
                                .overlay(Circle().stroke(Color.primary, lineWidth: tags.contains(t) ? 2.5 : 0))
                        }.buttonStyle(.plain).help(t)
                    }
                }
                if !isMulti {
                    Divider()
                    Text("Comment").font(.subheadline).bold()
                    TextEditor(text: $comment).frame(height: 56)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    Button("Save Comment") { browser.setComment(id: item.id, comment) }
                    if !item.isDirectory {
                        Divider()
                        HStack {
                            Text("Opens with").foregroundStyle(.secondary)
                            Spacer()
                            Button("Change…") { if let app = chooseApplication() { setDefaultApp(app, for: item.url) } }
                        }.font(.callout)
                    }
                    if let ri = readRestyleInfo(item.url) {
                        Divider()
                        Text("Restyle Info").font(.subheadline).bold()
                        if !ri.contents.isEmpty { row("Contents", ri.contents) }
                        if !ri.prompt.isEmpty { row("Prompt", ri.prompt) }
                    }
                }
            }.padding(16)
        }
        .frame(minWidth: 340, minHeight: 480)
        .onAppear { load() }
    }

    /// Finder's Sharing & Permissions, including the part Finder gets right and a
    /// raw "rwxr-xr-x" string does not: the levels are editable, and a change that
    /// the filesystem refuses says so instead of appearing to work.
    @ViewBuilder private func sharingSection() -> some View {
        Text("Sharing & Permissions").font(.subheadline).bold()
        if let a = access {
            let levels = PosixMode.levels(a.mode)
            Group {
                accessRow(a.owner, levels.owner, .owner, editable: a.canChangeMode)
                accessRow(a.group, levels.group, .group, editable: a.canChangeMode)
                accessRow("everyone", levels.other, .other, editable: a.canChangeMode)
                row("POSIX", PosixMode.string(a.mode) + "  (\(String(a.mode, radix: 8)))")
            }.font(.callout)
            if !a.canChangeMode {
                Label("You can only change these if you own the item.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if isMulti {
                Label("Showing “\(item.name)”. Changes apply to all \(items.count) selected items.",
                      systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Reading…").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func accessRow(_ who: String, _ level: PosixAccess, _ cls: PosixClass, editable: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(who).foregroundStyle(.secondary).frame(width: 92, alignment: .trailing).lineLimit(1)
            if editable {
                Picker("", selection: Binding(get: { level }, set: { changeAccess(cls, $0) })) {
                    ForEach(PosixAccess.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(maxWidth: 200, alignment: .leading)
            } else {
                Text(level.rawValue).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k).foregroundStyle(.secondary).frame(width: 92, alignment: .trailing)
            Text(v).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sizeText() -> String {
        if item.isDirectory {
            if let s = sizeCache.cached(item.url) { return ByteCountFormatter.string(fromByteCount: s, countStyle: .file) }
            return "Calculating…"
        }
        return ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
    }
    /// Combined size of a selection. Folders only count once their recursive size has
    /// been computed, and the total says so rather than quietly under-reporting.
    private func multiSizeText() -> String {
        var total: Int64 = 0
        var pendingFolders = 0
        for it in items {
            if it.isDirectory {
                if let s = sizeCache.cached(it.url) { total += s } else { pendingFolders += 1 }
            } else {
                total += it.size
            }
        }
        let s = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return pendingFolders == 0 ? s : "\(s) + \(pendingFolders) folder\(pendingFolders == 1 ? "" : "s") not yet calculated"
    }

    // Kept for the Owner column, which wants the string form.
    static func permString(_ url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let perm = attrs[.posixPermissions] as? NSNumber else { return "—" }
        return PosixMode.string(perm.uint16Value)
    }

    private func toggle(_ t: String) {
        if let i = tags.firstIndex(of: t) { tags.remove(at: i) } else { tags.append(t) }
        browser.setTags(Set(items.map { $0.id }), tags: tags)
    }

    /// chmod every selected item, then RE-READ from disk. Re-reading is the point:
    /// the picker must show what the filesystem actually says, not what we asked for,
    /// or a refused change leaves the UI claiming a permission the file doesn't have.
    private func changeAccess(_ cls: PosixClass, _ level: PosixAccess) {
        guard let a = access else { return }
        // OFF-MAIN. A stat and a chmod are one network round-trip each, so this loop was
        // 2N round-trips run on the main thread from a Picker's setter — pick a
        // permission for twenty files on a VPN'd share and the whole window froze,
        // beachball and all, until every one of them answered. Same shape as load().
        let targets = items
        let probe = item.url
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [String] = []
            for it in targets {
                guard let cur = readFileAccess(it.url) else { failures.append("• \(it.name): can't be read"); continue }
                let next = PosixMode.setting(cur.mode, cls, to: level, isDirectory: cur.isDirectory)
                if next == cur.mode { continue }
                if let err = setPosixMode(it.url, next) { failures.append("• \(it.name): \(err)") }
            }
            let fresh = readFileAccess(probe)
            DispatchQueue.main.async {
                access = fresh ?? a
                if !failures.isEmpty {
                    reportFileError(failures.count == 1 ? "The permission couldn't be changed" : "\(failures.count) items couldn't be changed",
                                    failures.prefix(5).joined(separator: "\n"))
                }
            }
        }
    }

    private func changeLocked(_ locked: Bool) {
        guard let a = access else { return }
        let targets = items
        let probe = item.url
        DispatchQueue.global(qos: .userInitiated).async {   // one round-trip per item — see changeAccess
            var failures: [String] = []
            for it in targets {
                if let err = setLocked(it.url, locked) { failures.append("• \(it.name): \(err)") }
            }
            let fresh = readFileAccess(probe)
            DispatchQueue.main.async {
                access = fresh ?? a
                if !failures.isEmpty {
                    reportFileError(locked ? "The item couldn't be locked" : "The item couldn't be unlocked",
                                    failures.prefix(5).joined(separator: "\n"))
                }
            }
        }
    }

    private func load() {
        if !isMulti {
            ThumbnailCache.shared.thumbnail(for: item.url, size: 512) { thumb = $0 }
            MetadataCache.shared.meta(for: item.url) { m in meta = m; if let c = m.comment, comment.isEmpty { comment = c } }
        }
        for it in items where it.isDirectory { FolderSizeCache.shared.compute(it.url) }
        // stat + directory-service lookups + the alias resolve are all round-trips on a
        // network file, so opening Get Info there doesn't hitch the window.
        let url = item.url
        let multi = isMulti
        DispatchQueue.global(qos: .utility).async {
            let a = readFileAccess(url)
            let t = multi ? nil : aliasTarget(url)
            DispatchQueue.main.async { access = a; target = t }
        }
    }
}

final class GetInfoController {
    static let shared = GetInfoController()
    private var windows: [String: NSWindow] = [:]
    func show(_ browser: Browser, _ item: FileItem) { show(browser, [item]) }
    func show(_ browser: Browser, _ items: [FileItem]) {
        guard !items.isEmpty else { return }
        // Keyed by the whole selection, so re-asking for the same multi-selection
        // reuses its window instead of stacking a new one every time.
        let key = items.map { $0.id }.sorted().joined(separator: "\u{1}")
        if let w = windows[key] { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = items.count == 1 ? "\(items[0].name) Info" : "\(items.count) Items Info"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: GetInfoView(browser: browser, items: items))
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows[key] = w
        // Without this the map grows for the life of the process and a reopened Get
        // Info hands back a window that has already been closed.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.windows[key] = nil
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Transfer progress window

// Shown instead of an endless "Loading…" when a network folder returns nothing for
// 15s. A wedged SMB session can't recover on its own, so give the two things that
// actually help: reconnect the share, or stop waiting and go somewhere useful.
struct StalledShareView: View {
    @ObservedObject var browser: Browser
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 38)).foregroundStyle(.orange)
            Text("“\(browser.currentURL.lastPathComponent)” isn’t responding").font(.headline)
            Text("The network drive stopped answering. Reconnecting drops the stuck connection and mounts the share again.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button("Reconnect") { browser.reconnectShare() }.keyboardShortcut(.defaultAction)
                Button("Stop Waiting") { browser.networkStalled = false; browser.busy = false; browser.busyText = "" }
                Button("Go Up") { browser.networkStalled = false; browser.goUp() }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TransferProgressView: View {
    @ObservedObject var progress: TransferProgress
    let title: String
    let onCancel: () -> Void
    var body: some View {
        // No repeated title here — it's already the window's title, and showing
        // "Copying…" twice in one small panel just looked unfinished. The useful
        // line is what's being copied and how far along it is.
        VStack(alignment: .leading, spacing: 12) {
            if !progress.countText.isEmpty {
                Text(progress.countText).font(.headline).monospacedDigit()
            }
            ProgressView(value: progress.fraction)
            HStack {
                Text(progress.current).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(Int((progress.fraction * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Cancel") { progress.cancelled = true; onCancel() } }
        }.padding(18).frame(width: 380)
    }
}

final class TransferProgressController {
    static let shared = TransferProgressController()
    private var window: NSWindow?
    private var pendingShow: DispatchWorkItem?
    // Delay before the progress window appears. Most copy/pastes (a few small
    // files) finish well inside this, so no window is ever built or flashed —
    // that flash, plus the focus theft below, is what made small pastes feel
    // laggy and weird. Only a genuinely slow transfer gets a window.
    private static let showDelay: TimeInterval = 0.7
    func show(_ progress: TransferProgress, title: String) {
        pendingShow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window == nil else { return }
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
                             styleMask: [.titled], backing: .buffered, defer: false)
            w.title = title
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: TransferProgressView(progress: progress, title: title) { [weak w] in w?.close() })
            w.center()
            // orderFront, NOT makeKeyAndOrderFront: never steal keyboard focus from
            // the file list mid-copy (that left later keystrokes going nowhere).
            w.orderFront(nil)
            self.window = w
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: work)
    }
    func hide() {
        pendingShow?.cancel(); pendingShow = nil
        window?.close(); window = nil
    }
}

// MARK: - Batch rename

struct BatchRenameView: View {
    @ObservedObject var browser: Browser
    let items: [FileItem]
    let onClose: () -> Void
    @State private var find = ""
    @State private var replace = ""
    @State private var prefix = ""
    @State private var suffix = ""
    @State private var numbered = false
    @State private var startAt = 1

    private func newName(_ item: FileItem, _ index: Int) -> String {
        let ext = item.url.pathExtension
        var base = item.url.deletingPathExtension().lastPathComponent
        if !find.isEmpty { base = base.replacingOccurrences(of: find, with: replace) }
        base = prefix + base + suffix
        if numbered { base += " \(startAt + index)" }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename \(items.count) Items").font(.headline)
            HStack { Text("Find").frame(width: 70, alignment: .trailing); TextField("text to find", text: $find).textFieldStyle(.roundedBorder) }
            HStack { Text("Replace").frame(width: 70, alignment: .trailing); TextField("replacement", text: $replace).textFieldStyle(.roundedBorder) }
            HStack { Text("Prefix").frame(width: 70, alignment: .trailing); TextField("prepend", text: $prefix).textFieldStyle(.roundedBorder) }
            HStack { Text("Suffix").frame(width: 70, alignment: .trailing); TextField("append (before extension)", text: $suffix).textFieldStyle(.roundedBorder) }
            HStack {
                Toggle("Append number, starting at", isOn: $numbered)
                TextField("", value: $startAt, format: .number).frame(width: 50).textFieldStyle(.roundedBorder).disabled(!numbered)
            }
            Divider()
            Text("Preview").font(.subheadline).bold()
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(items.prefix(200).enumerated()), id: \.element.id) { i, it in
                        HStack(spacing: 6) {
                            Text(it.name).foregroundStyle(.secondary).lineLimit(1)
                            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                            Text(newName(it, i)).lineLimit(1)
                        }.font(.callout)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 170)
            HStack {
                Spacer()
                Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
                Button("Rename All") {
                    browser.applyRenames(items.enumerated().map { (i, it) in (it.url, newName(it, i)) })
                    onClose()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 480)
    }
}

final class BatchRenameController {
    static let shared = BatchRenameController()
    private var window: NSWindow?
    func show(_ browser: Browser, _ items: [FileItem]) {
        guard !items.isEmpty else { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 480),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Batch Rename"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: BatchRenameView(browser: browser, items: items) { [weak w] in w?.close() })
        w.center(); w.makeKeyAndOrderFront(nil)
        window = w
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - AppKit entry point

// Self-update from GitHub Releases. Checks the latest release, and (if newer)
// downloads Navigator.zip and swaps the app bundle in place, then relaunches.
// Your settings live in UserDefaults / ~/Library — replacing the .app bundle
// doesn't touch them, and the stable signing identity keeps macOS permission
// grants intact — so updating never wipes your personalization.
enum Updater {
    static let repo = "michaelericksonh5/Navigator"
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 } }
        let r = parts(remote), l = parts(local)
        for i in 0..<max(r.count, l.count) where (i < r.count ? r[i] : 0) != (i < l.count ? l[i] : 0) {
            return (i < r.count ? r[i] : 0) > (i < l.count ? l[i] : 0)
        }
        return false
    }

    // userInitiated: show "you're up to date" / errors. Automatic launch checks
    // are silent unless there's an update, and throttled to once/day.
    static func check(userInitiated: Bool) {
        if !userInitiated {
            let dayAgo = Date().timeIntervalSince1970 - 86_400
            if Prefs.lastUpdateCheck > dayAgo { return }
        }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Navigator", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                Prefs.lastUpdateCheck = Date().timeIntervalSince1970
                guard let json, let tag = json["tag_name"] as? String else {
                    if userInitiated { alert("Couldn't check for updates", "Please try again later, or visit the Releases page.", link: releasesPage) }
                    return
                }
                let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let notes = (json["body"] as? String) ?? ""
                let page = (json["html_url"] as? String).flatMap(URL.init) ?? releasesPage
                var zip: URL?
                if let assets = json["assets"] as? [[String: Any]] {
                    zip = assets.first { ($0["name"] as? String) == "Navigator.zip" }
                        .flatMap { ($0["browser_download_url"] as? String) }.flatMap(URL.init)
                }
                if isNewer(remote, than: currentVersion) {
                    if !userInitiated, Prefs.skipUpdateVersion == remote { return }
                    presentUpdate(version: remote, notes: notes, page: page, zip: zip, userInitiated: userInitiated)
                } else if userInitiated {
                    alert("You're up to date", "Navigator \(currentVersion) is the latest version.")
                }
            }
        }.resume()
    }

    private static func presentUpdate(version: String, notes: String, page: URL, zip: URL?, userInitiated: Bool) {
        let a = NSAlert()
        a.messageText = "Navigator \(version) is available"
        var info = "You have \(currentVersion). Updating keeps all your settings and permissions."
        if !notes.isEmpty { info += "\n\n" + String(notes.prefix(600)) }
        a.informativeText = info
        a.addButton(withTitle: "Update Now")
        a.addButton(withTitle: "Release Notes")
        a.addButton(withTitle: userInitiated ? "Later" : "Skip This Version")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            if let zip { download(zip) } else { NSWorkspace.shared.open(page) }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(page)
        default:
            if !userInitiated { Prefs.skipUpdateVersion = version }
        }
    }

    private static func download(_ zip: URL) {
        guard access("/Applications", W_OK) == 0 else {
            alert("Can't update automatically", "Navigator can't write to /Applications. Download the update manually from the Releases page.", link: releasesPage)
            return
        }
        NSApp.dockTile.badgeLabel = "↓"   // brief hint while the (small) zip downloads
        URLSession.shared.downloadTask(with: zip) { tmp, _, err in
            DispatchQueue.main.async {
                NSApp.dockTile.badgeLabel = nil
                guard let tmp, err == nil else { alert("Download failed", err?.localizedDescription ?? "Please try again."); return }
                install(zipAt: tmp)
            }
        }.resume()
    }

    private static func install(zipAt zip: URL) {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("NavigatorUpdate-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let expand = Process(); expand.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        expand.arguments = ["-x", "-k", zip.path, work.path]
        do { try expand.run(); expand.waitUntilExit() } catch { alert("Update failed", error.localizedDescription); return }
        guard expand.terminationStatus == 0,
              let newApp = (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))?
                  .first(where: { $0.pathExtension == "app" }) else {
            alert("Update failed", "The downloaded update couldn't be expanded."); return
        }
        let dest = "/Applications/Navigator.app"
        // A helper that waits for us to quit, swaps the bundle, and relaunches —
        // you can't overwrite a running app bundle from within itself.
        let script = """
        #!/bin/bash
        for i in $(seq 1 60); do /usr/bin/pgrep -x Navigator >/dev/null || break; sleep 0.25; done
        /bin/rm -rf "\(dest)"
        /usr/bin/ditto "\(newApp.path)" "\(dest)"
        /usr/bin/xattr -dr com.apple.quarantine "\(dest)" 2>/dev/null
        /usr/bin/open "\(dest)"
        /bin/rm -rf "\(work.path)"
        """
        let scriptURL = work.appendingPathComponent("update.sh")
        do { try script.write(to: scriptURL, atomically: true, encoding: .utf8) } catch { alert("Update failed", error.localizedDescription); return }
        let runner = Process(); runner.executableURL = URL(fileURLWithPath: "/bin/bash"); runner.arguments = [scriptURL.path]
        do { try runner.run() } catch { alert("Update failed", error.localizedDescription); return }
        NSApp.terminate(nil)   // quit so the helper can replace the bundle
    }

    private static func alert(_ title: String, _ msg: String, link: URL? = nil) {
        let a = NSAlert(); a.messageText = title; a.informativeText = msg
        if link != nil { a.addButton(withTitle: "Open Releases Page") }
        a.addButton(withTitle: "OK")
        if a.runModal() == .alertFirstButtonReturn, let link { NSWorkspace.shared.open(link) }
    }
}

// A view with one job: hold the keyboard focus that would otherwise land in the
// search box. AppKit gives first responder to the first view in the key-view loop
// that will take it whenever a window has no initial first responder, and in this
// window the empty search field is the only taker — so the app opened with the caret
// in Search and the first thing typed went there instead of doing type-to-select.
// Handles no keys itself: events fall straight through to the window (Tab) and the
// app's key monitor (type-to-select, arrows, Space, …), which is the point.
final class FocusParkView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

final class NavWindow: NSWindow {
    let model: AppModel

    /// `session` is the saved tab list this window is restoring, or nil for a fresh
    /// one. It has to arrive through the initialiser: the model reads it once, and a
    /// window created without one must not go looking for somebody else's tabs.
    init(session: WindowSession?) {
        model = AppModel(session: session)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
    }
    // Retained by the view hierarchy; kept here so it can be re-parked if needed.
    let focusPark = FocusParkView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private var titleObservers: [AnyCancellable] = []

    // Keeps the title (and so the Dock menu's window list) showing the folder the
    // active tab is open to, instead of a generic "Navigator" for every window —
    // watches both tab SWITCHES (model.objectWillChange, since `selected` and `tabs`
    // are @Published on AppModel itself) and navigation WITHIN a tab (Browser is its
    // own ObservableObject, so its currentURL change doesn't bubble into AppModel's
    // own objectWillChange — .navigatorDidNavigate is the existing cross-cutting
    // signal the rest of the app already posts on every navigation).
    func startObservingFolderTitle() {
        updateTitleFromFolder()
        titleObservers = [
            model.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateTitleFromFolder() }
            },
            NotificationCenter.default.publisher(for: .navigatorDidNavigate).sink { [weak self] _ in
                self?.updateTitleFromFolder()
            },
        ]
    }

    private func updateTitleFromFolder() {
        let name = model.active.currentURL.lastPathComponent
        title = name.isEmpty ? "Navigator" : name
    }

    // Never leave the WINDOW ITSELF holding first responder — park it on focusPark.
    // Two separate breakages, both measured, come from letting focus sit on the window:
    // AppKit reads that state as "no view has focus" and its pick-the-first-key-view
    // fallback can hand focus to the empty search box, and SwiftUI's .keyboardShortcut
    // buttons (⌘L, ⌘F, ⌘R) stop firing because there is no focused view inside the
    // hosting view to dispatch through — after committing a path with Return, the very
    // next ⌘L did nothing at all until focus was parked here.
    //
    // nil and self are the two ways callers land on the window: makeFirstResponder(nil)
    // is how the app force-ends an edit (rename commit, .navigatorResignFields, a click
    // in the file list), and AppKit's own endEditingFor: passes the window.
    //
    // The `parking` flag is load-bearing: making focusPark first responder resigns the
    // old responder, and AppKit's resign path calls straight back in here with the
    // window again — without the flag that recurses until the stack runs out.
    private var parking = false
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        guard !parking, responder == nil || responder === self, focusPark.window === self else {
            return super.makeFirstResponder(responder)
        }
        parking = true
        defer { parking = false }
        return super.makeFirstResponder(focusPark)
    }

    // ⌘ + scroll wheel resizes/cycles the view (Windows 11 Ctrl+scroll). Handled
    // here in sendEvent so the event is fully consumed — a local event monitor
    // isn't reliable because AppKit's responsive scrolling can still deliver the
    // wheel event to the list, making it scroll while zooming.
    override func sendEvent(_ event: NSEvent) {
        // Tab / ⇧Tab cycles the file selection, Finder-style — handled HERE rather
        // than in AppDelegate's key monitor for the same reason ⌘-scroll is: the
        // monitor cannot make the keystroke go away. Measured live: with the monitor
        // returning nil, AppKit still ran the key event through the key-view loop a
        // few tens of milliseconds later, which parked first responder in the search
        // field — so every OTHER Tab then looked like "text is being edited, keep
        // out" and did nothing. Consuming it in sendEvent means the key-view loop
        // never sees it, and Tab cycles on every press.
        //
        // While a field IS being edited (rename editor, address bar, search) the
        // event falls through untouched, so Tab still does normal field-to-field
        // navigation there.
        if event.type == .keyDown, event.keyCode == 48, !isEditingText(in: self),
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            model.active.cycleSelection(event.modifierFlags.contains(.shift) ? -1 : 1)
            return   // consume — do not forward to AppKit's key-view loop
        }
        if event.type == .scrollWheel,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
            if dy != 0 { model.active.adjustViewScale(dy) }
            return   // consume — do not forward to the content/scroll view
        }
        super.sendEvent(event)
    }
}

// MARK: - View Options panel (⌘J)

/// Finder's ⌘J, for the folder the front window is showing.
///
/// Every control writes straight through to the live Browser, so the folder rearranges as
/// you change things rather than on an OK button — which is also what makes "Always open
/// this folder with these options" honest: it snapshots what you are already looking at.
///
/// The panel binds to `model.active`, not to a Browser captured when it opened, so
/// switching tabs or navigating retargets it instead of quietly editing a folder that is
/// no longer on screen.
struct ViewOptionsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store = FolderViewOptionsStore.shared

    var body: some View {
        // Observing the active Browser is what refreshes this panel when the folder or its
        // arrangement changes underneath it.
        ViewOptionsBody(browser: model.active, store: store)
            .frame(width: 300)
    }
}

private struct ViewOptionsBody: View {
    @ObservedObject var browser: Browser
    @ObservedObject var store: FolderViewOptionsStore

    private var remembers: Bool { store.contains(browser.currentURL.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(browser.currentURL.lastPathComponent.isEmpty ? "/" : browser.currentURL.lastPathComponent)
                .font(.headline).lineLimit(1).truncationMode(.middle)

            // Replaces the old "Always open this folder with these options" toggle. That
            // switch is a lie now: every folder keeps its own options the moment you change
            // one, so there is nothing left to turn on — only a fact to state, and a way
            // (Restore Defaults, below) to take it back.
            Text(stateLine)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Picker("View", selection: Binding(get: { browser.viewMode }, set: { browser.viewMode = $0 })) {
                Text("Details").tag(ViewMode.list)
                Text("Icons").tag(ViewMode.icon)
                Text("Gallery").tag(ViewMode.gallery)
            }
            Picker("Sort by", selection: Binding(
                get: { browser.currentSortColumn },
                set: { browser.sortOrder = [Browser.comparator(forColumn: $0, ascending: browser.currentAscending)] })) {
                // Only the sortable columns — an unsortable one (Tags) in this picker would
                // silently do nothing when chosen.
                ForEach(sortableColumnIDs, id: \.self) { Text(fileColumnTitle($0)).tag($0) }
            }
            Picker("Order", selection: Binding(
                get: { browser.currentAscending },
                set: { browser.sortOrder = [Browser.comparator(forColumn: browser.currentSortColumn, ascending: $0)] })) {
                Text("Ascending").tag(true); Text("Descending").tag(false)
            }
            Picker("Group by", selection: Binding(get: { browser.groupBy }, set: { browser.groupBy = $0 })) {
                Text("(None)").tag(GroupBy.none)
                Text("Kind").tag(GroupBy.kind)
                Text("Date Modified").tag(GroupBy.date)
                Text("Size").tag(GroupBy.size)
            }

            // Icon size only means something in the two grid modes; shown disabled rather
            // than hidden so the panel doesn't change height as you switch views.
            HStack {
                Text("Icon size")
                Slider(value: Binding(get: { browser.iconSize }, set: { browser.iconSize = $0 }),
                       in: Browser.minIconSize...Browser.maxIconSize)
                Text("\(Int(browser.iconSize))").monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
            .disabled(browser.viewMode == .list)

            Divider()
            Text("Columns").font(.subheadline).foregroundStyle(.secondary)
            // Same source as the View ▸ Columns menu and the header right-click menu.
            ForEach(ColumnMenu.togglableIDs, id: \.self) { id in
                Toggle(fileColumnTitle(id), isOn: columnBinding(id))
            }
            .disabled(browser.viewMode != .list)

            Divider()
            HStack {
                // Explorer calls this "Apply to Folders"; the app has always called it Use
                // as Defaults and renaming it would only orphan the muscle memory. It is
                // now the ONLY way a view change reaches the global default, so it gets
                // the leading, prominent slot rather than sitting beside its opposite.
                Button("Use as Defaults") { browser.useCurrentViewOptionsAsDefaults() }
                    .help("Apply to folders: make these the options every folder without its own uses.")
                Spacer()
                Button("Restore Defaults") { browser.forgetFolderViewOptions() }
                    .disabled(!remembers)
                    .help("Forget this folder's own options and go back to the default view.")
            }
        }
        .padding(14)
    }

    /// What is actually governing this folder right now, in the same order the code
    /// resolves it: the folder's own record, then content inference, then the defaults.
    private var stateLine: String {
        if remembers { return "Remembering this folder's own view options." }
        if browser.viewWasInferred { return "Large icons, chosen because this folder is mostly images or video." }
        return "Using the default view options."
    }

    private var sortableColumnIDs: [String] { fileColumnDefs.filter { $0.comparator != nil }.map(\.id) }

    private func columnBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { browser.visibleColumns.contains(id) },
                set: { _ in browser.visibleColumns = ColumnMenu.toggled(browser.visibleColumns, id: id) })
    }
}

/// One floating panel for the whole app, retargeted at whichever window is key — the same
/// arrangement Finder's ⌘J has. A utility panel (not a window) so it stays above the
/// browser and doesn't take over the menu bar while you keep working in the folder.
final class ViewOptionsController {
    static let shared = ViewOptionsController()
    private var panel: NSPanel?
    /// Whose options the panel is currently editing.
    private weak var target: AppModel?

    private init() {
        // Follow the frontmost browser window. Without this the panel stayed bound to
        // whichever window opened it, so clicking into window B left a panel that read
        // and WROTE window A's folder options — silent, and invisible unless you knew.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                               object: nil, queue: .main) { [weak self] n in
            guard let self, self.panel?.isVisible == true,
                  let w = n.object as? NavWindow, w.model !== self.target else { return }
            self.show(w.model)
        }
    }

    func toggle(_ model: AppModel) {
        // RETARGET, don't close. ⌘J in a second window used to order the panel out
        // because it was visible — so there was no way at all to open View Options for
        // any window but the one that already had it. Only ⌘J on the window the panel
        // is ALREADY editing means "close it".
        if let p = panel, p.isVisible, target === model { p.orderOut(nil); return }
        show(model)
    }
    private func show(_ model: AppModel) {
        target = model
        let p = panel ?? {
            // .nonactivatingPanel + becomesKeyOnlyIfNeeded, and orderFront rather than
            // makeKeyAndOrderFront, are LOAD-BEARING — this is the fix for a confirmed
            // regression, do not "simplify" them away.
            //
            // A plain utility panel that takes key steals it from the browser window, and
            // the next left-click anywhere in that window is then eaten by AppKit as the
            // window-activation click (NSTableHeaderView, like most AppKit views, returns
            // false from acceptsFirstMouse). The visible symptom was that clicking a
            // Details column header did nothing at all — no re-sort, no indicator move —
            // while a RIGHT-click at the identical point still opened the column menu,
            // because context menus don't need a key window. It looked exactly like
            // "header sorting is broken" and had nothing to do with the sorting code.
            //
            // Nothing in this panel edits text, so it never needs key: with these flags it
            // floats above the browser, its controls still work on a single click, and the
            // browser window keeps key the whole time.
            let new = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 560),
                              styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                              backing: .buffered, defer: false)
            new.title = "View Options"
            new.isFloatingPanel = true
            new.becomesKeyOnlyIfNeeded = true
            new.hidesOnDeactivate = false
            new.isReleasedWhenClosed = false
            panel = new
            return new
        }()
        // Rebuilt on each show so it binds to the CURRENT window's AppModel — ⌘J in a
        // second window must configure that window's folder, not the first one's.
        let host = NSHostingView(rootView: ViewOptionsView(model: model))
        p.contentView = host
        // A fixed height rather than fittingSize: an NSHostingView reports a zero-ish
        // fitting size before its first layout pass, which produced a panel a few pixels
        // tall with the content clipped away.
        p.setContentSize(NSSize(width: 300, height: 620))
        // Placed beside the browser window rather than centred on top of it: centring put
        // the panel straight over the column headers of the window it configures.
        p.setFrameTopLeftPoint(panelOrigin(besides: NSApp.keyWindow ?? NSApp.mainWindow, size: p.frame.size))
        p.orderFront(nil)
    }

    /// Top-left corner just outside the browser window's right edge, pulled back onto the
    /// screen if it won't fit there.
    private func panelOrigin(besides w: NSWindow?, size: NSSize) -> NSPoint {
        guard let w, let vis = (w.screen ?? NSScreen.main)?.visibleFrame else { return NSPoint(x: 80, y: 700) }
        let x = min(w.frame.maxX + 12, vis.maxX - size.width)
        return NSPoint(x: max(vis.minX, x), y: min(w.frame.maxY, vis.maxY))
    }
}

// MARK: - Open/Save dialog bridge

/// A brief label near the pointer, shown when a global hotkey did something while
/// Navigator was in the BACKGROUND — where its own window is nowhere the user is looking
/// and there is otherwise no sign at all that the key press landed.
///
/// Non-activating, never key, mouse-transparent. That isn't politeness: the whole point
/// of the feature is to serve an Open/Save panel in ANOTHER app, and a panel of ours that
/// took key would deactivate that app and pull focus off the dialog the user is standing
/// in. (ViewOptionsController documents what a key-taking panel costs even inside our own
/// window.)
final class PathHUD {
    static let shared = PathHUD()
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideTimer: Timer?
    private init() {}

    static func show(_ text: String) { shared.present(text) }

    private func present(_ text: String) {
        let p = panel ?? make()
        guard let label else { return }
        label.stringValue = text
        label.sizeToFit()
        let size = NSSize(width: min(max(label.frame.width + 28, 180), 640), height: 40)
        p.setContentSize(size)
        label.frame = NSRect(x: 14, y: (size.height - label.frame.height) / 2,
                             width: size.width - 28, height: label.frame.height)
        p.setFrameOrigin(origin(for: size))
        p.orderFront(nil)     // NOT makeKeyAndOrderFront — see the class comment
        hideTimer?.invalidate()
        // Timer(…) + RunLoop.main.add(forMode: .common), never Timer.scheduledTimer: a
        // default-mode timer doesn't fire while a drag or menu-tracking loop is running,
        // and a HUD that can get stuck on screen over someone else's dialog is worse than
        // no HUD at all.
        let t = Timer(timeInterval: 1.8, repeats: false) { [weak p] _ in p?.orderOut(nil) }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    /// Just below-right of the pointer — where the user is already looking — pulled back
    /// onto whichever screen that is. NSEvent.mouseLocation needs no permission: it's the
    /// cursor's position, not another app's input.
    private func origin(for size: NSSize) -> NSPoint {
        let m = NSEvent.mouseLocation
        let vis = (NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: min(max(m.x + 16, vis.minX + 8), vis.maxX - size.width - 8),
                       y: min(max(m.y - size.height - 16, vis.minY + 8), vis.maxY - size.height - 8))
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false        // it exists PRECISELY while we are deactivated
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true        // never between the user and the dialog beneath
        p.isOpaque = false
        p.backgroundColor = .clear
        // .statusBar to sit above the frontmost app's windows and its Open/Save sheet;
        // .canJoinAllSpaces so it appears on whichever Space that app is on.
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.autoresizingMask = [.width, .height]
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 11
        bg.layer?.masksToBounds = true
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.lineBreakMode = .byTruncatingMiddle
        bg.addSubview(l)
        p.contentView = bg
        label = l
        panel = p
        return p
    }
}

/// Puts Navigator's location on the clipboard for ANOTHER app's Open/Save panel, from a
/// system-wide hotkey that works while Navigator is in the background — the only state
/// that matters, since the user is standing in Photoshop's or Chrome's dialog when they
/// press it. PickerBridgeRules explains why the clipboard is the bridge and which path
/// gets copied.
///
/// Carbon's RegisterEventHotKey, deliberately NOT NSEvent.addGlobalMonitorForEvents: the
/// monitor needs Accessibility trust. Navigator is signed with a local identity and no
/// Team ID, so TCC grants for it are fragile — an ad-hoc build is identified by code hash
/// alone and loses every grant on each rebuild — and a feature whose entire job is "it's
/// always there" must not be built on one. A Carbon hot key needs no permission at all.
final class PickerBridge {
    static let shared = PickerBridge()
    /// 'NAVP', so our hot keys can't be confused with any other client's.
    private static let signature = OSType(0x4E415650)
    private static let copyID: UInt32 = 1
    private static let teleportID: UInt32 = 2

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var lastFired = Date.distantPast
    /// Set when the one-key variant was pressed without Accessibility, so the
    /// explanation can wait for a moment where an alert isn't stealing a dialog's focus.
    private var owesAccessibilityExplanation = false

    private init() {
        // The alert below is deferred to the next time Navigator is frontmost on purpose:
        // the hotkey fires while another app owns the screen, and an alert thrown up then
        // would take focus off the very dialog the user is trying to fill in.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.explainAccessibilityIfOwed()
        }
    }

    /// (Re)register from prefs — called at launch and after every change in Settings.
    func reload() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        guard Prefs.pickerHotkeyEnabled else { return }
        installHandler()
        let copy = PickerBridgeRules.chord(id: Prefs.pickerHotkeyChord)
        var failed: [String] = []
        if !register(copy, id: Self.copyID) { failed.append(copy.display) }
        if Prefs.pickerTeleportEnabled {
            let go = PickerBridgeRules.teleportChord(for: copy)
            if !register(go, id: Self.teleportID) { failed.append(go.display) }
        }
        guard !failed.isEmpty else { return }
        // A global hotkey that silently failed to register is the worst outcome this
        // feature has available: the user presses it in Photoshop forever, nothing
        // happens, and there is nothing anywhere to look at. Another app already holding
        // the chord is the usual cause. Deferred one turn so it never runs modal inside
        // applicationDidFinishLaunching.
        DispatchQueue.main.async {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Navigator couldn’t register \(failed.joined(separator: " and "))"
            a.informativeText = "Another app already owns that shortcut system-wide, so it will never reach Navigator. Pick a different one in Settings ▸ Open/Save Dialogs.\n\nGo ▸ “Copy Path for Open/Save Dialog” still works while Navigator is frontmost."
            a.addButton(withTitle: "OK")
            a.runModal()
        }
    }

    private func register(_ c: PickerBridgeRules.Chord, id: UInt32) -> Bool {
        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(c.keyCode, c.carbonModifiers,
                                      EventHotKeyID(signature: Self.signature, id: id),
                                      GetApplicationEventTarget(), 0, &ref)
        guard err == noErr, let ref else { return false }
        refs.append(ref)
        return true
    }

    /// Installed once and left in place: the handler is keyed by hot-key id, so
    /// re-registering chords never needs a second one.
    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            // Everything downstream is AppKit and pasteboard work; hop to main rather
            // than trusting a Carbon callback's thread.
            DispatchQueue.main.async { PickerBridge.shared.fire(hk.id) }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Go ▸ Copy Path for Open/Save Dialog — the same action, so the menu can never
    /// disagree with the hotkey about which folder is "current".
    func copyNow() { fire(Self.copyID) }

    private func fire(_ id: UInt32) {
        // The menu item carries the same chord (that's how anyone discovers the feature),
        // so one press while Navigator IS frontmost can arrive twice: once as the Carbon
        // hot key, once as the menu key equivalent. Copying twice is harmless — two HUDs
        // stacked on each other, and two bursts of synthesized keystrokes, are not.
        guard Date().timeIntervalSince(lastFired) > 0.35 else { return }
        lastFired = Date()
        // Read BEFORE we overwrite it: only the teleport path can put it back (it pastes
        // for the user), and only if it's plain text — see Settings for that admission.
        let previousText = NSPasteboard.general.string(forType: .string)
        let rescued = Self.rescuedFromClipboard(previousText)
        let path = rescued ?? currentPath()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        if id == Self.teleportID {
            teleport(to: path, restoring: previousText, rescued: rescued != nil)
        } else {
            PathHUD.show((rescued != nil ? "Resolved " : "Copied ") + PickerBridgeRules.hudLabel(path)
                         + "   ·   ⌘⇧G then ⌘V in the dialog")
        }
    }

    /// A Drive location already sitting on the clipboard that NO dialog could open, turned
    /// into this Mac's real path for it. nil — the normal case — means "use Navigator's
    /// folder", which stays this feature's primary job.
    ///
    /// The rule, deliberately narrow, is: the clipboard wins only over a string that is
    /// unmistakably a Google Drive location, is useless to a dialog exactly as it stands,
    /// and names something that really exists here once resolved. That is the trap this
    /// closes — a coworker's Slack link or portable "Google Drive/…" path, or Navigator's
    /// own username-free Copy Local Path, none of which ⌘⇧G can open. A clipboard already
    /// holding a working path is left alone and Navigator's folder wins, because a working
    /// path needs no bridge and the user pressed Navigator's shortcut rather than ⌘V.
    ///
    /// Not gated on "Navigator has no selection": a background window virtually always has
    /// a leftover highlighted row, so that gate would mean this never fires — and "it
    /// depends on what is selected in a window you can't see" is the more surprising rule,
    /// not the safer one. What keeps it honest is that the HUD names which source it used
    /// every single time.
    private static func rescuedFromClipboard(_ clipboard: String?) -> String? {
        guard let s = clipboard?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        // Parse first, stat second: the cheap string test bounds the two filesystem hits
        // below to strings already shaped like a Drive path, so an SMB path on the
        // clipboard can't block this keystroke handler on a network stat.
        let resolved = Browser.resolveGoogleDrivePath(s) ?? googleDriveLocalPath(webURL: s)
        guard let resolved, !FileManager.default.fileExists(atPath: s),
              FileManager.default.fileExists(atPath: resolved) else { return nil }
        return resolved
    }

    /// Resolved through `appModel`, the same window every menu command acts on, so the
    /// hotkey can't copy a different folder than the menu item beside it.
    private func currentPath() -> String {
        guard let d = NSApp.delegate as? AppDelegate else { return NSHomeDirectory() }
        let b = d.appModel.active
        return PickerBridgeRules.pathToCopy(folder: b.currentURL.path,
                                            selection: b.urls(b.selection).map { $0.path })
    }

    private func teleport(to path: String, restoring previousText: String?, rescued: Bool) {
        let label = PickerBridgeRules.hudLabel(path)
        // Posting keystrokes into another process IS input control, and macOS gates it
        // behind Accessibility. Degrade to exactly what the other hotkey does rather than
        // failing: the path is already on the clipboard, so the manual three keys work.
        guard AXIsProcessTrusted() else {
            PathHUD.show("Copied \(label)   ·   one-key needs Accessibility — use ⌘⇧G then ⌘V")
            owesAccessibilityExplanation = true
            explainAccessibilityIfOwed()   // fires now only if we happen to be frontmost
            return
        }
        // Never at ourselves: with Navigator frontmost there is no foreign dialog to
        // teleport, and ⌘⇧G would open Navigator's OWN Go to Folder sheet and paste into
        // it — which reads as the feature misfiring.
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.processIdentifier != getpid() else {
            PathHUD.show("Copied \(label)   ·   no other app’s dialog is in front")
            return
        }
        let appName = front?.localizedName ?? "the frontmost app"
        // Off the main thread: this waits on another process's Accessibility tree between
        // keystrokes, and blocking main would freeze our UI (and the HUD) mid-send. The
        // HUD is deliberately shown at the END now — the three outcomes below differ, and
        // an up-front "Sending…" would have to lie about two of them.
        DispatchQueue.global(qos: .userInitiated).async {
            // Read BEFORE ⌘⇧G, while the panel itself still owns focus: once the
            // Go-to-Folder sheet is up, the save/open panel is no longer on the focused
            // element's ancestor path and this answer is unrecoverable.
            let kind = Self.focusedPanelKind()
            Self.post(key: 5, flags: [.maskCommand, .maskShift])   // ⌘⇧G  (kVK_ANSI_G)
            // See PickerBridgeRules "the Save-panel escape": the fixed 250 ms sleep this
            // replaces was a guess, and when the guess was wrong the ⌘V landed in a Save
            // panel's FILENAME field, where an absolute path is a destination and one
            // Return writes the file. Nothing is pasted until the field is really there.
            let ready = Self.waitForGoToFolderFocus()
            let sendReturn = ready && PickerBridgeRules.mayPostReturn(kind)
            if ready {
                Self.post(key: 9, flags: .maskCommand)             // ⌘V   (kVK_ANSI_V)
                usleep(150_000)
                // NEVER unconditionally: in a Save panel — or in anything we could not
                // positively identify as an Open panel — this Return is what created
                // `Untitled copy.rtf` in someone's Google Drive. The user presses it.
                if sendReturn { Self.post(key: 36, flags: []) }    // ⏎    (kVK_Return)
            }
            let outcome: PickerBridgeRules.TeleportOutcome =
                !ready ? .noGoToFolder : (sendReturn ? .jumped : .pastedAwaitingReturn)
            DispatchQueue.main.async {
                PathHUD.show(PickerBridgeRules.teleportHUD(label: label, app: appName,
                                                           rescued: rescued, outcome: outcome))
            }
            // Only plain text is ever restored. A pasteboard can promise its data lazily
            // (Photoshop does exactly that for images), and there is no way to snapshot
            // such a promise without forcing the producer to render it — so anything that
            // isn't text is left alone and Settings says so outright.
            //
            // `ready` gates it too: with nothing pasted, the path on the clipboard is the
            // only way left for the user to finish by hand, and taking it back would
            // leave them with neither.
            guard ready, let previousText else { return }
            usleep(400_000)
            DispatchQueue.main.async {
                // Only while OUR path is still what's on the clipboard: if anything else
                // copied in the meantime, putting the old text back would make US the
                // thing that destroyed the user's clipboard.
                guard NSPasteboard.general.string(forType: .string) == path else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(previousText, forType: .string)
            }
        }
    }

    // MARK: Reading the dialog before we type at it
    //
    // All of this exists for one reason: PickerBridgeRules' "Save-panel escape" note.
    // Navigator has to know what it is about to press Return in, and has to know the
    // Go-to-Folder field is really there before it pastes a path at it.

    /// Every AX read goes through the SYSTEM-WIDE element, never the frontmost
    /// application's: a sandboxed app's Open/Save panel is drawn by a separate Powerbox
    /// process — Chrome's upload picker is exactly that — so Chrome's own AX tree
    /// contains no panel at all and we would answer "unknown" for the commonest Open
    /// panel there is. The system-wide focused element crosses that boundary.
    private static func systemWideFocus() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        // Bounded on purpose: this runs between two synthesized keystrokes, and a wedged
        // app must not be able to stall the sequence with the ⌘⇧G already delivered.
        AXUIElementSetMessagingTimeout(system, 0.5)
        return axElement(system, kAXFocusedUIElementAttribute)
    }

    private static func axElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func axIdentifier(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXIdentifierAttribute as CFString, &v) == .success
        else { return nil }
        return v as? String
    }

    private static func axChildren(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success
        else { return [] }
        return v as? [AXUIElement] ?? []
    }

    /// Walks OUT from the focused element to the panel that contains it. Outward rather
    /// than down from the window, because in a Save panel the focused element is the
    /// filename field and the panel is two hops up — a couple of AX round trips instead
    /// of a whole tree.
    private static func focusedPanelKind() -> PickerBridgeRules.PanelKind {
        guard var node = systemWideFocus() else { return .unknown }
        for _ in 0..<12 {
            if let id = axIdentifier(node), id == "save-panel" || id == "open-panel" {
                return PickerBridgeRules.panelKind(identifier: id,
                                                   hasFilenameField: hasFilenameField(node, depth: 4))
            }
            guard let up = axElement(node, kAXParentAttribute) else { break }
            node = up
        }
        return .unknown
    }

    /// Depth-bounded: `saveAsNameTextField` sits two levels inside the panel, while an
    /// Open panel's column view below this is thousands of rows we must not walk.
    private static func hasFilenameField(_ el: AXUIElement, depth: Int) -> Bool {
        if axIdentifier(el) == "saveAsNameTextField" { return true }
        guard depth > 0 else { return false }
        return axChildren(el).contains { hasFilenameField($0, depth: depth - 1) }
    }

    /// Polls instead of sleeping a fixed guess, and reports honestly when the field never
    /// arrives — an app that doesn't honour ⌘⇧G must end with nothing pasted, not with a
    /// path in its filename field.
    private static func waitForGoToFolderFocus(timeout: TimeInterval = 1.5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            var chain: [String] = []
            var node = systemWideFocus()
            for _ in 0..<6 {
                guard let n = node else { break }
                if let id = axIdentifier(n) { chain.append(id) }
                node = axElement(n, kAXParentAttribute)
            }
            if PickerBridgeRules.isGoToFolderFocused(chain) { return true }
            usleep(50_000)
        } while Date() < deadline
        return false
    }

    /// Carbon mask → Cocoa mask, so the menu item can advertise the very chord that was
    /// registered instead of a hand-kept copy of it.
    static func cocoaModifiers(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        if carbon & PickerBridgeRules.controlKeyMask != 0 { m.insert(.control) }
        if carbon & PickerBridgeRules.optionKeyMask  != 0 { m.insert(.option) }
        if carbon & PickerBridgeRules.shiftKeyMask   != 0 { m.insert(.shift) }
        if carbon & PickerBridgeRules.commandKeyMask != 0 { m.insert(.command) }
        return m
    }

    private static func post(key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    /// Said once, ever, and only while we're frontmost — a HUD line is too small to carry
    /// "here is the switch to flip", and an alert raised mid-dialog would break the thing
    /// the user was doing.
    private func explainAccessibilityIfOwed() {
        guard owesAccessibilityExplanation, NSApp.isActive, !AXIsProcessTrusted(),
              !Prefs.d.bool(forKey: "pickerAXExplained") else { return }
        owesAccessibilityExplanation = false
        Prefs.d.set(true, forKey: "pickerAXExplained")
        let a = NSAlert()
        a.messageText = "The one-key version needs Accessibility"
        a.informativeText = "Sending ⌘⇧G, ⌘V and Return to another app is input control, which macOS only allows with Accessibility permission.\n\nUntil it's granted the shortcut still copies the path — press ⌘⇧G then ⌘V in the dialog yourself.\n\nNavigator is signed locally, so macOS drops this grant every time the app is rebuilt or updated and you'll have to tick it again."
        a.addButton(withTitle: "Open Accessibility Settings…")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn {
            PermissionProbe.openPane(PermissionProbe.accessibilityPane)
        }
    }
}

// Settings window (⌘,). Bound directly to the same UserDefaults keys the app
// reads via Prefs, so changes take effect with no plumbing: the behavioral ones
// (Trash confirm, thumbnails) are read live at point-of-use; view/sort/hidden
// apply to newly opened windows and tabs.
struct SettingsView: View {
    @AppStorage("viewMode") private var viewMode = "list"
    @AppStorage("sortKey") private var sortKey = "name"
    @AppStorage("sortAscending") private var sortAscending = true
    @AppStorage("showHidden") private var showHidden = false
    @AppStorage("confirmTrash") private var confirmTrash = true
    @AppStorage("thumbnailMode") private var thumbnailMode = "all"
    @AppStorage("warnExtensionChange") private var warnExtensionChange = true
    @AppStorage("inferFolderView") private var inferFolderView = true
    @AppStorage("pickerHotkeyEnabled") private var pickerHotkeyEnabled = true
    @AppStorage("pickerHotkeyChord") private var pickerHotkeyChord = PickerBridgeRules.chords[0].id
    @AppStorage("pickerTeleportEnabled") private var pickerTeleportEnabled = false
    var body: some View {
        Form {
            Section("Defaults for new windows & tabs") {
                Picker("View", selection: $viewMode) {
                    Text("Details").tag("list"); Text("Icons").tag("icon")
                    Text("Gallery").tag("gallery")
                }
                Picker("Sort by", selection: $sortKey) {
                    Text("Name").tag("name"); Text("Date Modified").tag("modified")
                    Text("Size").tag("size"); Text("Kind").tag("kind")
                }
                Toggle("Ascending order", isOn: $sortAscending)
                Toggle("Show hidden files", isOn: $showHidden)
            }
            Section("Behavior") {
                Toggle("Open image folders in large icons", isOn: $inferFolderView)
                    .help("Folders you haven't arranged yourself open in large icons when they're mostly images or video. Off: every such folder uses the default view above.")
                Toggle("Confirm before moving to Trash", isOn: $confirmTrash)
                Toggle("Warn before changing a file extension", isOn: $warnExtensionChange)
                Picker("Thumbnails", selection: $thumbnailMode) {
                    Text("All files").tag("all")
                    Text("Images only").tag("images")
                    Text("Off (fastest on slow drives)").tag("off")
                }
            }
            // Wordier than the rest of this window on purpose: this section reaches into
            // another app's dialog, replaces the clipboard, and optionally leans on a
            // permission macOS revokes behind the user's back. None of that should be
            // discovered by surprise.
            Section("Open/Save dialogs in other apps") {
                Toggle("Global shortcut to copy this folder’s path", isOn: $pickerHotkeyEnabled)
                Picker("Shortcut", selection: $pickerHotkeyChord) {
                    ForEach(PickerBridgeRules.chords, id: \.id) { Text($0.display).tag($0.id) }
                }
                .disabled(!pickerHotkeyEnabled)
                Text("Press it in any app — Navigator needn’t be in front — then ⌘⇧G, ⌘V, Return in the Open or Save dialog. One selected item copies that item; several copy their folder; none copies the folder you’re browsing.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("A Google Drive path or link already on the clipboard — a coworker’s “Google Drive/Shared drives/…”, a path from their Mac, or a drive.google.com link — is converted to this Mac’s Drive folder and used instead, since a dialog can’t open any of those as they stand.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("One keystroke: also send ⌘⇧G, paste and Return to the frontmost app",
                       isOn: $pickerTeleportEnabled)
                    .disabled(!pickerHotkeyEnabled)
                // The note and its remedy live in ONE row, and the link shows whenever the
                // permission is missing rather than only while the toggle is on: as a
                // separate Form row it was the first thing to fall off the bottom of the
                // window — the button that fixes the problem, invisible.
                VStack(alignment: .leading, spacing: 4) {
                    Text(teleportNote)
                    if !AXIsProcessTrusted() {
                        Button("Open Accessibility Settings…") {
                            PermissionProbe.openPane(PermissionProbe.accessibilityPane)
                        }
                        .buttonStyle(.link)
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Width fixed, height derived from the content. NOT a hard height: a grouped Form
        // pinned to one CLIPS instead of scrolling (a ScrollView doesn't help — the Form
        // still takes the whole height offered), and what fell off the bottom was the
        // dialog-bridge section's Accessibility warning and the button that resolves it.
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        // Every one of these three changes the registered hot keys, so they all go
        // through the one re-registration path rather than each doing its own thing.
        .onChange(of: pickerHotkeyEnabled) { _, _ in PickerBridge.shared.reload() }
        .onChange(of: pickerHotkeyChord) { _, _ in PickerBridge.shared.reload() }
        .onChange(of: pickerTeleportEnabled) { _, _ in PickerBridge.shared.reload() }
    }

    /// Stated plainly rather than reassuringly: the Accessibility grant really does vanish
    /// on every rebuild, and the clipboard really is only put back when it held text.
    private var teleportNote: String {
        let chord = PickerBridgeRules.teleportChord(for: PickerBridgeRules.chord(id: pickerHotkeyChord)).display
        let ax = AXIsProcessTrusted() ? "Needs Accessibility — granted."
                                      : "Needs Accessibility — not granted, so it only copies."
        // This used to warn that a Save dialog's Return also saved the file. It did, and
        // it wrote one into a real shared drive — so the behaviour was fixed rather than
        // documented, and the note now describes the split it was replaced with.
        return "\(chord) does it in one press. \(ax) macOS drops that grant whenever Navigator is rebuilt or updated (signed locally, no Team ID). Only a plain-text clipboard is put back; anything else keeps the path. In an Open dialog it goes all the way. In a Save dialog — or any dialog Navigator can’t identify — it stops after pasting and you press Return yourself, so this shortcut can never save a file."
    }
}

// MARK: - Setup Assistant (first launch, and Help ▸ Setup Assistant…)

/// Live answers to "can Navigator actually do this right now?".
///
/// Every answer here comes from ATTEMPTING the thing, never from reading TCC's
/// database: that file is private, needs Full Disk Access to read at all, and its
/// schema is Apple's to change. A capability probe cannot be wrong about the only
/// question the user has — whether the feature works — and it keeps working when
/// Apple next moves the furniture.
enum PermissionProbe {
    // Where System Settings keeps each switch. The com.apple.preference.security
    // anchors still resolve on macOS 14/15 (the app already ships the AllFiles and
    // Automation ones); each was opened and screenshotted before being trusted here.
    static let filesAndFoldersPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
    static let fullDiskPane        = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    static let automationPane      = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    /// The single most important string in this file. System Settings has TWO panes called
    /// "Accessibility": the one in the sidebar (VoiceOver, Zoom, Hover Text, Captions) and
    /// this one, the permission list under Privacy & Security. The app's owner clicked the
    /// sidebar one, found no app list, and concluded the permission didn't exist — which is
    /// why every place that mentions Accessibility now offers this button instead of prose.
    /// Opened and screenshotted on macOS 26.6: lands on "Allow the applications below to
    /// control your computer", the list with Navigator's switch in it.
    static let accessibilityPane   = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    static func openPane(_ url: String) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }

    /// Rows whose probe IS the request — reading a protected folder is what makes macOS
    /// put its dialog up. Until an id is in here the row honestly reads "Not yet asked",
    /// so merely opening this window can't spawn a stack of system dialogs at someone.
    /// Once macOS has a decision on file the same probe is silent, which is what makes
    /// the refresh-on-focus below possible at all.
    static var asked: Set<String> {
        get { Set(Prefs.d.stringArray(forKey: "setupAsked") ?? []) }
        set { Prefs.d.set(newValue.sorted(), forKey: "setupAsked") }
    }

    /// Can we list this folder right now? Success is the only proof of access that counts.
    /// A folder that isn't there is `.unknown`, not `.denied` — nothing is wrong with the
    /// permission, and saying "Denied" would send the user after a switch that is fine.
    static func folder(_ url: URL) -> PermissionState {
        do { _ = try FileManager.default.contentsOfDirectory(atPath: url.path); return .granted }
        catch let e as NSError {
            return PermissionDiagnosis.isDenial(domain: e.domain, code: e.code) ? .denied : .unknown
        }
    }

    /// Network / removable volumes can only be tested against a volume of that kind that
    /// is actually mounted — with none mounted there is literally nothing to read, and
    /// the honest answer is `.unknown` (macOS asks the first time one is opened). This
    /// costs nothing in that case: no volume of the class means no filesystem call.
    static func volumes(network: Bool) -> PermissionState {
        let match = volumeLocations().first { network ? $0.isNetwork : (!$0.isNetwork && $0.ejectable) }
        guard let v = match else { return .unknown }
        return folder(v.url)
    }

    /// Full Disk Access has no API and macOS never prompts for it, so the only thing an
    /// ordinary app can observe is whether it can OPEN a file that nothing but FDA opens.
    /// We ask for a handle to TCC's own database and drop it immediately — nothing is
    /// read from it and nothing here parses it, which is the line this must not cross.
    static func fullDisk() -> PermissionState {
        let p = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        do { try FileHandle(forReadingFrom: URL(fileURLWithPath: p)).close(); return .granted }
        catch let e as NSError {
            return PermissionDiagnosis.isDenial(domain: e.domain, code: e.code) ? .denied : .unknown
        }
    }

    /// Automation ▸ Finder, probed by sending Finder a harmless event — the SAME call
    /// setComment makes, so this answer is literally the feature's answer.
    ///
    /// Deliberately NOT AEDeterminePermissionToAutomateTarget, the API that appears to
    /// exist for exactly this: measured live, it blocks forever inside TCC when a consent
    /// dialog can't be put up (screen locked), and because the probes share a queue that
    /// left EVERY row stuck on "Unknown". A status that can hang is worse than no API.
    /// -1743 is macOS refusing; anything else (Finder not running, a script error) is
    /// not evidence of a denial and must not be reported as one.
    static func finderAutomation() -> PermissionState {
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to return version")?.executeAndReturnError(&err)
        guard let err else { return .granted }
        return (err[NSAppleScript.errorNumber] as? Int) == -1743 ? .denied : .unknown
    }
}

/// Where, in words, `FIFinderSyncController.showExtensionManagementInterface()` actually
/// lands — checked on this machine, not assumed from Apple's docs.
///
/// The name matters because guessing it wasted the app's owner's evening: the copy used to
/// say "Finder Extensions", and there is no such section. On macOS 26.6 the API opens
/// System Settings ▸ Login Items & Extensions and pops the sheet headed "File Providers",
/// and THAT is where a Finder Sync extension's tick lives — Navigator sits in it alongside
/// Core Sync and Google Drive's FinderHelper, which `pluginkit -p com.apple.FinderSync`
/// confirms are Finder Sync plug-ins too. The category actually named "Finder" in that
/// pane is Quick Actions (Convert Image, Create PDF, Markup) and never lists us.
///
/// Named once and shared by all three places that say it — the assistant row, the AI ▸
/// Finder Menu… alert and the once-per-version nudge — so they cannot drift apart again.
let finderExtensionSectionName = "Login Items & Extensions ▸ File Providers"

/// One row of the assistant: what the permission is FOR in the user's words, how to find
/// out whether we have it, and where they go to change it.
struct SetupItem: Identifiable {
    let id: String
    let title: String
    let why: String
    /// `prompt` is true only from the row's own "Ask macOS" button.
    let probe: (_ prompt: Bool) -> PermissionState
    /// True when merely RUNNING the probe is what makes macOS ask. Those rows stay at
    /// "Not yet asked" until the user presses the button — see PermissionProbe.asked.
    let probeMayPrompt: Bool
    /// True when macOS can be made to ask. False means the switch is the user's to flip
    /// in System Settings and no app is allowed to raise a dialog for it — the row says so.
    let canAsk: Bool
    /// True when System Settings lists this permission only AFTER the app has asked for it
    /// once. Sending someone to the pane before that is the dead end the app's owner hit:
    /// they went to Files & Folders looking for a Removable Volumes switch that macOS had
    /// never had reason to create. SetupAudit.buttons drops "Open Settings" for those rows.
    var listedOnlyAfterRequest = false
    /// Never counted in the footer — see SetupAudit.attentionCount.
    var optional = false
    var settingsLabel = "Open Settings"
    /// The half of the job the button can't do. macOS opens these panes scrolled to the
    /// top with nothing highlighted, so "we opened it" leaves the user hunting an app
    /// name in a list of forty. Shown only alongside the button it describes.
    var afterOpening: String?
    let openSettings: () -> Void

    static func all() -> [SetupItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func files() { PermissionProbe.openPane(PermissionProbe.filesAndFoldersPane) }
        // Every Files & Folders row lands on the same pane and needs the same last step,
        // so the sentence is written once — five copies would drift.
        let inFilesPane = "Then: find Navigator in that list, expand it, and switch this on. The pane opens at the top and doesn’t highlight us."
        func homeFolder(_ name: String, _ why: String) -> SetupItem {
            SetupItem(id: name, title: name, why: why,
                      probe: { _ in PermissionProbe.folder(home.appendingPathComponent(name)) },
                      probeMayPrompt: true, canAsk: true, listedOnlyAfterRequest: true,
                      afterOpening: inFilesPane,
                      openSettings: files)
        }
        return [
            // Listed FIRST, and in this section rather than under Extras, because it is the
            // row that explains the five below it: when it reads Granted they all read
            // "Covered by Full Disk Access", and a user who scrolled past a green tick at
            // the bottom would have no idea why.
            SetupItem(id: "fda", title: "Full Disk Access",
                      why: "Optional, and it changes what the rows below mean: with it on, macOS grants Navigator every file permission listed here and REPLACES their individual switches in Files & Folders with a single greyed “Full Disk Access” line — so there is nothing left to turn on there. It reaches what those switches don’t, too: other apps’ Library folders, another user’s home, some system folders. It does NOT override a file’s own owner or read-only flag, everyday browsing works without it, and macOS never asks — you turn it on yourself.",
                      probe: { _ in PermissionProbe.fullDisk() },
                      probeMayPrompt: false, canAsk: false, optional: true,
                      afterOpening: "Then: find Navigator in that list and switch it on. If it isn’t listed, click +, press ⇧⌘G, type /Applications/Navigator.app. Quit and reopen Navigator afterwards.",
                      openSettings: { PermissionProbe.openPane(PermissionProbe.fullDiskPane) }),
            homeFolder("Desktop", "Browse your Desktop, and drop files onto it with Send To."),
            homeFolder("Documents", "Browse, rename and organise everything in Documents."),
            homeFolder("Downloads", "Browse Downloads and move things out of it."),
            // Volumes are probed live rather than gated behind a button: with none of the
            // kind mounted the probe is free and answers "Unknown", and with one mounted
            // reading it is both the honest test and the prompt you'd want anyway.
            //
            // canAsk stays false for both, and that is not an oversight: with no volume of
            // the kind mounted there is nothing to attempt, so an "Ask macOS…" button would
            // be a button that provably does nothing. The wording carries that instead.
            SetupItem(id: "network", title: "Network volumes",
                      why: "Open shared drives you connect to (⌘K), and copy files to and from them. With none mounted there is nothing to test — macOS settles this the first time Navigator opens one, and does not list it in System Settings before then.",
                      probe: { _ in PermissionProbe.volumes(network: true) },
                      probeMayPrompt: false, canAsk: false, listedOnlyAfterRequest: true,
                      afterOpening: inFilesPane,
                      openSettings: files),
            SetupItem(id: "removable", title: "USB & external drives",
                      why: "Browse sticks and external disks, and use them as a Send To target. With none plugged in there is nothing to test — macOS settles this the first time Navigator opens one, and does not list it in System Settings before then.",
                      probe: { _ in PermissionProbe.volumes(network: false) },
                      probeMayPrompt: false, canAsk: false, listedOnlyAfterRequest: true,
                      afterOpening: inFilesPane,
                      openSettings: files),
            SetupItem(id: "automation", title: "Control Finder",
                      why: "Used for one thing: saving the Comment field in Get Info. Finder owns Finder comments, so Finder has to be the one to write them. Automation only lists Navigator once it has asked, so use the button — the pane is empty of us until then.",
                      probe: { _ in PermissionProbe.finderAutomation() },
                      probeMayPrompt: true, canAsk: true, listedOnlyAfterRequest: true,
                      afterOpening: "Then: find Navigator in that list and switch Finder on underneath it.",
                      openSettings: { PermissionProbe.openPane(PermissionProbe.automationPane) }),
            SetupItem(id: "finderext", title: "Navigator’s Finder menu",
                      why: "Adds Navigator’s submenu — Remove BG, Chroma Key, the AI upscalers — to Finder’s own right-click menu. macOS makes you tick this one yourself, in \(finderExtensionSectionName).",
                      probe: { _ in FIFinderSyncController.isExtensionEnabled ? .granted : .off },
                      probeMayPrompt: false, canAsk: false,
                      settingsLabel: "Open Extensions",
                      afterOpening: "Then: tick Navigator in the “File Providers” sheet that opens on top, and click Done.",
                      // The SAME call the AI ▸ Finder Menu… item and the once-per-version
                      // nudge already use — one path to that pane, not two.
                      openSettings: { FIFinderSyncController.showExtensionManagementInterface() }),
            // The row this whole window was missing. It is LAST and optional because it
            // buys exactly one keystroke, but its `why` is the longest here on purpose:
            // the owner of this app went looking for this switch, clicked the pane named
            // "Accessibility" in the sidebar, found VoiceOver and Zoom, and concluded the
            // permission wasn't there. Naming the trap is the row's main job; the button
            // is what makes the naming unnecessary.
            SetupItem(id: "accessibility", title: "Accessibility (one-key dialog jump)",
                      why: "Needed for one thing only: ⌃⌥⇧⌘G, which types ⇧⌘G, pastes and presses Return in another app’s Open or Save dialog. Driving another app’s keyboard is what macOS gates here. Without it ⌃⌥⌘G still copies the path and you paste it yourself, so nothing is broken — that is why this row never counts as needing attention.\n\nThe button goes to Privacy & Security ▸ Accessibility. That is NOT the Accessibility item in the System Settings sidebar, which is VoiceOver, Zoom and Hover Text and has no list of apps in it at all — two different panes, same name.\n\nExpect to redo this: macOS keys the grant to Navigator’s code signature, and Navigator is signed locally, so rebuilding or updating the app drops it.",
                      probe: { _ in AXIsProcessTrusted() ? .granted : .off },
                      probeMayPrompt: false, canAsk: false, optional: true,
                      afterOpening: "Then: find Navigator in that list and switch it on. If it isn’t listed, click +, press ⇧⌘G, type /Applications/Navigator.app.",
                      openSettings: { PermissionProbe.openPane(PermissionProbe.accessibilityPane) })
        ]
    }
}

// Laid out like SettingsView — grouped Form, one Section per topic — because it IS the
// same kind of window and should not read as a bolted-on wizard.
struct SetupAssistantView: View {
    @State private var states: [String: PermissionState] = [:]
    @State private var checking = false
    @State private var checkedAt: Date?
    @AppStorage("viewMode") private var viewMode = "list"
    @AppStorage("iconSize") private var iconSize = 76.0
    @AppStorage("inferFolderView") private var inferFolderView = true

    private let items = SetupItem.all()
    /// Rows that aren't about reading files. Full Disk Access can't cover any of them.
    private static let extras: Set<String> = ["automation", "finderext", "accessibility"]

    var body: some View {
        Form {
            Section {
                Text("macOS keeps Navigator out of your files until you say otherwise. This checks what it can actually reach right now.\n\n“Ask macOS” makes macOS put up its own permission dialog. A row with no button needs nothing from you — either it is already covered, or macOS has nowhere for you to change it yet and will decide the first time Navigator tries.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Split by id rather than by count: the sections used to be prefix(5)/dropFirst(5)
            // and reordering the list silently moved a row into the wrong one. One membership
            // set, negated for the other section, so no row can land in both or in neither.
            Section("Files & folders") { ForEach(items.filter { !Self.extras.contains($0.id) }) { row($0) } }
            Section("Extras") { ForEach(items.filter { Self.extras.contains($0.id) }) { row($0) } }
            Section("How folders open") {
                Picker("New windows and tabs", selection: $viewMode) {
                    Text("Details").tag("list"); Text("Icons").tag("icon"); Text("Gallery").tag("gallery")
                }
                // A slider over the same range as View Options (⌘J), not a Small/Medium/Large
                // picker: icon size is continuous here — the pinch gesture and ⌘J both write
                // arbitrary values — so a picker showed an EMPTY selection for anyone whose
                // size didn't land exactly on one of three magic numbers.
                HStack {
                    Text("Icon size")
                    Slider(value: $iconSize, in: Double(Browser.minIconSize)...Double(Browser.maxIconSize))
                    Text("\(Int(iconSize))").monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
                Toggle("Open image folders in large icons", isOn: $inferFolderView)
                    .help("Folders you haven’t arranged yourself open in large icons when they’re mostly images or video.")
            }
            Section {
                HStack(spacing: 8) {
                    if checking { ProgressView().controlSize(.small) }
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Again") { refresh() }
                    Button("Done") { SetupAssistantController.shared.close() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 660)
        .onAppear { refresh() }
        // Returning from System Settings re-activates Navigator, which is the only
        // signal we get that a switch may have moved. Re-probing here is what stops
        // this window from showing yesterday's answer until the app is restarted.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard SetupAssistantController.shared.isVisible else { return }
            refresh()
        }
    }

    /// Every row's status is read through here, and so is the footer count — the two can
    /// only ever be the same answer because they are literally the same function.
    private var fullDisk: PermissionState { states["fda"] ?? .unknown }
    private func state(of item: SetupItem) -> PermissionState {
        SetupAudit.effectiveState(id: item.id, probed: states[item.id] ?? .unknown, fullDisk: fullDisk)
    }

    private var summary: String {
        let stamp = checkedAt.map { " · checked " + $0.formatted(date: .omitted, time: .standard) } ?? ""
        if checking { return "Checking…" }
        let bad = SetupAudit.attentionCount(items.map { ($0.id, states[$0.id] ?? .unknown, $0.optional) },
                                            fullDisk: fullDisk)
        if bad == 0 { return "Nothing needs your attention" + stamp }
        return "\(bad) item\(bad == 1 ? "" : "s") still need\(bad == 1 ? "s" : "") attention" + stamp
    }

    private func tint(_ s: PermissionState) -> Color {
        switch s {
        case .granted, .covered: return .green
        case .denied:  return .red
        case .off, .notAsked: return .orange
        case .unknown: return .secondary
        }
    }

    @ViewBuilder private func row(_ item: SetupItem) -> some View {
        let state = state(of: item)
        let buttons = SetupAudit.buttons(state: state, canAsk: item.canAsk,
                                         listedOnlyAfterRequest: item.listedOnlyAfterRequest)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.symbol)
                .foregroundStyle(tint(state)).frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).fontWeight(.medium)
                    Text(state.label).font(.caption).foregroundStyle(tint(state))
                }
                Text(item.why).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Only next to the button it is about: with no button there is no "then",
                // and a "find Navigator in the list" on a row we just told the user needs
                // nothing would send them to a pane for no reason.
                if buttons.settings, let next = item.afterOpening {
                    Text(next).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if buttons.ask {
                    Button("Ask macOS…") { ask(item) }.buttonStyle(.borderedProminent)
                }
                if buttons.settings { Button(item.settingsLabel) { item.openSettings() } }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    /// The row's own button: run the probe in its PROMPTING form. For a folder that
    /// simply means reading it — attempting the access is the only way to get the real
    /// system dialog, and no API exists to raise one on demand.
    private func ask(_ item: SetupItem) {
        checking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let s = item.probe(true)
            PermissionProbe.asked.insert(item.id)
            DispatchQueue.main.async { states[item.id] = s; checking = false; checkedAt = Date() }
        }
    }

    /// Off the main thread: a network-volume probe is a directory listing over SMB, and
    /// a TCC dialog blocks whichever thread triggered it until the user answers.
    ///
    /// Each row is published as its own probe finishes rather than all at the end, so one
    /// slow or wedged probe can no longer hold every other row hostage — the panel showed
    /// nothing but "Unknown" for as long as a single hung TCC call kept the loop from
    /// completing, which is precisely the "confident wrong status" this is meant to avoid.
    private func refresh() {
        checking = true
        let items = self.items
        DispatchQueue.global(qos: .userInitiated).async {
            let asked = PermissionProbe.asked
            // Full Disk Access is first in the list on purpose: every row below it reads its
            // answer, so probing it first means no row ever paints "Not yet asked" for a
            // second before flipping to "Covered".
            for item in items {
                let s = (item.probeMayPrompt && !asked.contains(item.id)) ? .notAsked : item.probe(false)
                DispatchQueue.main.async { states[item.id] = s }
            }
            DispatchQueue.main.async { checking = false; checkedAt = Date() }
        }
    }
}

final class SetupAssistantController {
    static let shared = SetupAssistantController()
    private var window: NSWindow?
    /// Read by the view before it re-probes on app activation, so a window that has been
    /// closed stops costing directory reads on every switch back to Navigator.
    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 660),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Navigator Setup"
            w.contentView = NSHostingView(rootView: SetupAssistantView())
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func close() { window?.orderOut(nil) }
}

// NSMenuItemValidation conformance is load-bearing, not decoration: validateMenuItem
// below is a plain Swift method, so without an @objc protocol requiring it AppKit
// never finds it and never calls it. Verified live — File → Eject stayed enabled on
// a disk that can't be ejected, and Edit → Undo never greyed out or renamed itself.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    var window: NavWindow!
    /// View ▸ Columns. Rebuilt on open (menuNeedsUpdate) rather than filled once at
    /// startup, because its tick marks belong to whichever folder is showing right now —
    /// and because the header right-click menu can change them behind its back.
    fileprivate var columnsMenu: NSMenu?
    private var extraWindows: [NavWindow] = []
    private var keyMonitor: Any?
    private var mainWindowShown = false
    // Set when we're launched purely to view an image (open handler runs before
    // didFinishLaunching) — then we DON'T pop the browser window behind the viewer.
    private var suppressMainWindow = false

    // Menu commands and keyboard nav target whichever Navigator window is key.
    //
    // The fallback is the LAST browser window that was key, not the main window: while
    // a panel holds key (View Options, Get Info), `NSApp.keyWindow as? NavWindow` is
    // nil and this resolved to the main window — so a menu command issued while
    // working in window B silently acted on window A's folder.
    var appModel: AppModel { ((NSApp.keyWindow as? NavWindow) ?? lastKeyNavWindow ?? window).model }
    private weak var lastKeyNavWindow: NavWindow?

    private var pendingFolders: [URL] = []

    /// Read (and immediately consumed) at the top of launch, because two later
    /// deferred blocks both need to know it and the flag is set the moment it's read.
    private var isFirstRun = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        isFirstRun = !Prefs.didRunSetup
        Prefs.didRunSetup = true
        // The undo stack is pure logic in NavigatorCore (so it can be unit-tested and
        // never reaches for AppKit); these hook its two user-visible outcomes back up.
        UndoStack.shared.onEmpty = { NSSound.beep() }
        UndoStack.shared.onFailure = { reportFileError($0, $1, permissionHint: false) }
        // Remembered so menu commands still find the right window when a panel takes
        // key away from it — see `appModel`.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                               object: nil, queue: .main) { [weak self] n in
            if let w = n.object as? NavWindow { self?.lastKeyNavWindow = w }
        }
        setupMenu()
        // Every window the last session had open comes back, each with its OWN tabs.
        // The first saved session belongs to the main window (it registered first, so
        // it is first in the list); the rest get real extra windows behind it.
        let sessions = WindowSessions.saved()
        window = makeWindow(session: sessions.first)   // created, but not shown yet
        window.setFrameAutosaveName("NavigatorMainWindow")
        // Deferred to showMainWindow: an image-only launch (double-clicking a PNG)
        // suppresses the browser entirely, and popping five restored browser windows
        // over the image viewer would be worse than the single-window bug this fixes.
        // Parked in WindowSessions rather than in a field of our own, because a launch
        // that never restores them must still PERSIST them — see WindowSessions.held.
        WindowSessions.hold(Array(sessions.dropFirst()))
        installKeyMonitor()
        // The system-wide chord for "copy my location for another app's Open/Save panel".
        // Registered at launch, not on first use: its whole value is being available while
        // Navigator sits in the background.
        PickerBridge.shared.reload()
        ensureSMBTuning()
        Updater.check(userInitiated: false)   // silent, throttled to once/day; prompts only if an update exists
        NetworkBrowser.shared.start()
        // Quietly put pinned network drives back if they dropped. No-op for anyone
        // whose sidebar has no network drives.
        NetworkReconnector.shared.start()
        // Live refresh for network folders (FSEvents doesn't fire for SMB).
        NetworkPollCoordinator.shared.start()
        NSApp.servicesProvider = self   // powers the "Open in Navigator" Finder Services entry
        NSUpdateDynamicServices()
        // Install the Finder Quick Actions once per version (cheap; skips the pbs
        // flush on subsequent launches). Bump the marker when the workflows change.
        if Prefs.d.integer(forKey: "finderQuickActionsVersion") < 4 {
            installFinderQuickActions(nil)
            Prefs.d.set(4, forKey: "finderQuickActionsVersion")
        }
        // The Finder menu ships inside the app but macOS won't switch a Finder
        // extension on by itself — the user has to tick it once. Offer to take them
        // straight there rather than leaving the feature silently absent. Asked at
        // most once per version, and always reachable from AI → Finder Menu….
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.offerFinderExtensionIfDisabled()
        }
        // Show the browser shortly — unless we were launched only to view an image
        // (the open handler sets suppressMainWindow first). The tiny delay also lets
        // a folder-open event arrive so it opens as a tab in the same window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.suppressMainWindow else { return }
            self.showMainWindow()
            self.offerDefaultsIfNeeded()   // one-time; only on a normal (visible) launch
            // First launch of this install: open the Setup Assistant so a new user sees
            // what macOS is still blocking, instead of discovering it months later as a
            // Send To that silently does nothing. Marked shown, not completed — it never
            // reappears on its own, and Help ▸ Setup Assistant… brings it back.
            if self.isFirstRun { SetupAssistantController.shared.show() }
        }
        // (Background pre-indexing was removed: on a degraded VPN it competed with
        // the user's own navigation for the choked connection and made browsing
        // hang. The persistent cache + mtime revalidation already make revisits
        // instant without any background traffic.)
    }

    @objc private func bringDockWindowToFront(_ sender: NSMenuItem) {
        guard let w = sender.representedObject as? NSWindow else { return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Bring up the browser window (idempotent) and flush any queued folder opens.
    func showMainWindow() {
        if !mainWindowShown {
            mainWindowShown = true
            // Extras first, then the main window on top of them.
            let extras = WindowSessions.takeHeld()
            if !extras.isEmpty { restoreExtraWindows(extras) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        if !pendingFolders.isEmpty { pendingFolders.forEach { window.model.newTab(at: $0) }; pendingFolders = [] }
        // Clear any initial keyboard focus off the address bar so typing goes to
        // type-to-select, not the address field.
        DispatchQueue.main.async { NotificationCenter.default.post(name: .navigatorResignFields, object: nil) }
    }

    // Make network-drive browsing steadier out of the box by disabling SMB
    // change-notifications (needless chatter over the VPN). macOS reads a
    // per-user config at ~/Library/Preferences/nsmb.conf — no sudo, no /etc.
    // We only ADD our setting; we never remove or overwrite existing config,
    // and skip if the user/IT already tuned it. Takes effect on the next mount.
    func ensureSMBTuning() {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Preferences/nsmb.conf")
        // Research-backed client tuning for high-latency SMB over VPN. Per-user,
        // no sudo; takes effect on the NEXT mount. Values target the two things
        // we CAN influence against a slow/non-batching server:
        //   dir_cache_async_cnt  10→100 : many parallel directory queries in flight
        //                                 to hide per-round-trip VPN latency while
        //                                 the listing is fetched.
        //   dir_cache_max/min           : keep a fetched directory cached longer so
        //                                 repeat browsing isn't re-listed (default
        //                                 60s is shorter than a big folder takes).
        //   max_cached_per_dir  =10000  : cache even large (600+ item) folders fully.
        //   notify_off                  : skip change-notify chatter over the VPN.
        let ours = """
        # Written by Navigator — faster, steadier SMB browsing over VPN (per-user, no sudo).
        # Takes effect on the next mount. See `man nsmb.conf`.
        [default]
        notify_off=yes
        dir_cache_async_cnt=100
        dir_cache_max=180s
        dir_cache_min=60s
        max_cached_per_dir=10000
        """
        let existing = try? String(contentsOfFile: path, encoding: .utf8)
        // Our file (or none) → safe to (re)write with the full tuned block.
        if existing == nil || existing!.contains("Written by Navigator") {
            if existing != ours { try? ours.write(toFile: path, atomically: true, encoding: .utf8) }
            return
        }
        // A file we didn't create → be conservative: only add notify_off if there's
        // no [default] section yet, never disturbing existing user/IT config.
        if !existing!.contains("notify_off"),
           existing!.range(of: #"(?m)^\s*\[default\]"#, options: .regularExpression) == nil {
            try? (existing! + "\n[default]\nnotify_off=yes\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // Finder Services entry: right-click a folder/file in Finder → Services →
    // "Open in Navigator". Folders open as tabs; a file opens its enclosing folder.
    @objc func openInNavigator(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        let folders = urls.map { u -> URL in
            ((try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true) ? u : u.deletingLastPathComponent()
        }
        guard !folders.isEmpty else { return }
        if let win = (NSApp.keyWindow as? NavWindow) ?? window {
            folders.forEach { win.model.newTab(at: $0) }
            win.makeKeyAndOrderFront(nil)
        } else {
            pendingFolders += folders
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func upscalePreset(_ model: String) -> UpscaleOption {
        upscaleOptions.first { $0.model == model } ?? upscaleOptions[0]
    }

    // A Finder Quick Action fired: navigatoraction://<action>?hex=<hex of newline-
    // joined file paths>. Decode and run the matching action on the images.
    private func handleActionURL(_ url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let hex = comps.queryItems?.first(where: { $0.name == "hex" })?.value else { return }
        var bytes = [UInt8](); var idx = hex.startIndex
        while let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex), next <= hex.endIndex {
            if let b = UInt8(hex[idx..<next], radix: 16) { bytes.append(b) } else { break }
            idx = next
            if idx == hex.endIndex { break }
        }
        let paths = (String(bytes: bytes, encoding: .utf8) ?? "")
            .split(separator: "\n").map(String.init)
        // Same routing as Navigator's own menu: folders → batch; image(s) → single/multi.
        let all = paths.map { URL(fileURLWithPath: $0) }
        let folders = all.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        let images = all.filter { !folders.contains($0) && isImageFile($0) }
        guard !folders.isEmpty || !images.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        switch url.host {
        case "removebg":
            folders.forEach { batchRemoveBackgroundFolder($0) }
            if !images.isEmpty { removeBackgroundForImages(images) }
        case "chromakey":
            folders.forEach { batchChromaKeyFolder($0) }
            if !images.isEmpty { chromaKeyForImages(images) }
        case "upscale-lowq":
            folders.forEach { batchUpscaleFolderViaFal($0, option: upscalePreset("Wonder 3")) }
            if !images.isEmpty { upscaleImagesViaFal(images, option: upscalePreset("Wonder 3")) }
        case "upscale-imagen2":
            folders.forEach { batchUpscaleFolderViaImagen($0, factor: 2) }
            if !images.isEmpty { upscaleImagesViaImagen(images, factor: 2) }
        case "upscale-imagen4":
            folders.forEach { batchUpscaleFolderViaImagen($0, factor: 4) }
            if !images.isEmpty { upscaleImagesViaImagen(images, factor: 4) }
        default: break
        }
    }

    // Finder Quick Actions. Names + logic MATCH Navigator's own menu. `requires`
    // = only installed when that app is present (PS/AE). `acceptsFolders` = also
    // offered on folders (batch), like Navigator's Batch Remove BG / Chroma Key.
    private struct FinderQA { let title: String; let action: String; let requires: String?; let acceptsFolders: Bool }
    private static let finderQuickActions: [FinderQA] = [
        .init(title: "Remove BG",              action: "removebg",     requires: "com.adobe.Photoshop",    acceptsFolders: true),
        .init(title: "Chroma Key BG",          action: "chromakey",    requires: "com.adobe.AfterEffects", acceptsFolders: true),
        .init(title: "Upscale Low Quality ×4", action: "upscale-lowq",    requires: nil,                   acceptsFolders: true),
        .init(title: "Upscale (Imagen 4) ×2",  action: "upscale-imagen2", requires: nil,                   acceptsFolders: true),
        .init(title: "Upscale (Imagen 4) ×4",  action: "upscale-imagen4", requires: nil,                   acceptsFolders: true),
    ]
    // Older names to clean up so we don't leave stale duplicates behind (includes
    // the retired Art/Photoreal upscalers now replaced by Imagen).
    private static let legacyQuickActionNames = [
        "Navigator — Remove Background", "Navigator — Chroma Key (Green Screen)",
        "Navigator — Upscale (Art)", "Navigator — Upscale (Photoreal)", "Navigator — Upscale (Low Quality ×4)",
        "Upscale Art", "Upscale Photoreal",
    ]

    // Install/refresh the Quick Actions in ~/Library/Services. Photoshop/After
    // Effects actions install only when that app is present; upscales always.
    @objc func installFinderQuickActions(_ sender: Any? = nil) {
        let fm = FileManager.default
        let svc = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services")
        for name in Self.legacyQuickActionNames {
            try? fm.removeItem(at: svc.appendingPathComponent("\(name).workflow"))
        }
        for qa in Self.finderQuickActions {
            let bundle = svc.appendingPathComponent("\(qa.title).workflow")
            if let req = qa.requires, NSWorkspace.shared.urlForApplication(withBundleIdentifier: req) == nil {
                try? fm.removeItem(at: bundle)   // app not installed → don't offer it
                continue
            }
            let contents = bundle.appendingPathComponent("Contents")
            try? fm.createDirectory(at: contents, withIntermediateDirectories: true)
            let cmd = "h=$(printf '%s\\n' \"$@\" | xxd -p | tr -d '\\n'); open \"navigatoraction://\(qa.action)?hex=$h\""
            try? Self.quickActionInfoPlist(title: qa.title, acceptsFolders: qa.acceptsFolders).write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
            try? Self.quickActionWorkflow(command: cmd, acceptsFolders: qa.acceptsFolders).write(to: contents.appendingPathComponent("document.wflow"), atomically: true, encoding: .utf8)
        }
        let flush = Process(); flush.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs"); flush.arguments = ["-flush"]
        try? flush.run()
        if sender != nil {
            let a = NSAlert(); a.messageText = "Finder Quick Actions installed"
            a.informativeText = "Right-click an image (or a folder) in Finder to find Navigator’s Remove BG, Chroma Key BG, and Upscale actions — the same as Navigator’s own menu. If they don’t show right away, enable them in System Settings → Keyboard → Keyboard Shortcuts → Services (or log out and back in)."
            a.addButton(withTitle: "OK"); a.runModal()
        }
    }
    private static func quickActionInfoPlist(title: String, acceptsFolders: Bool) -> String {
        let types = acceptsFolders ? "<string>public.image</string><string>public.folder</string>" : "<string>public.image</string>"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>NSServices</key>
          <array><dict>
            <key>NSMenuItem</key><dict><key>default</key><string>\(title)</string></dict>
            <key>NSMessage</key><string>runWorkflowAsService</string>
            <key>NSRequiredContext</key><dict><key>NSApplicationIdentifier</key><string>com.apple.finder</string></dict>
            <key>NSSendFileTypes</key><array>\(types)</array>
          </dict></array>
        </dict></plist>
        """
    }
    private static func quickActionWorkflow(command: String, acceptsFolders: Bool) -> String {
        let inputType = acceptsFolders ? "com.apple.Automator.fileSystemObject" : "com.apple.Automator.fileSystemObject.image"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>AMApplicationBuild</key><string>528</string>
          <key>AMApplicationVersion</key><string>2.10</string>
          <key>AMDocumentVersion</key><string>2</string>
          <key>actions</key>
          <array>
            <dict>
              <key>action</key>
              <dict>
                <key>AMAccepts</key><dict>
                  <key>Container</key><string>List</string>
                  <key>Optional</key><true/>
                  <key>Types</key><array><string>com.apple.cocoa.string</string></array>
                </dict>
                <key>AMActionVersion</key><string>2.0.3</string>
                <key>AMApplication</key><array><string>Automator</string></array>
                <key>AMParameterProperties</key><dict>
                  <key>COMMAND_STRING</key><dict/>
                  <key>CheckedForUserDefaultShell</key><dict/>
                  <key>inputMethod</key><dict/>
                  <key>shell</key><dict/>
                  <key>source</key><dict/>
                </dict>
                <key>AMProvides</key><dict>
                  <key>Container</key><string>List</string>
                  <key>Types</key><array><string>com.apple.cocoa.string</string></array>
                </dict>
                <key>ActionBundlePath</key><string>/System/Library/Automator/Run Shell Script.action</string>
                <key>ActionName</key><string>Run Shell Script</string>
                <key>ActionParameters</key><dict>
                  <key>COMMAND_STRING</key><string>\(command)</string>
                  <key>CheckedForUserDefaultShell</key><true/>
                  <key>inputMethod</key><integer>1</integer>
                  <key>shell</key><string>/bin/zsh</string>
                  <key>source</key><string></string>
                </dict>
                <key>BundleIdentifier</key><string>com.apple.RunShellScript</string>
                <key>CFBundleVersion</key><string>2.0.3</string>
                <key>CanShowSelectedItemsWhenRun</key><false/>
                <key>CanShowWhenRun</key><true/>
                <key>Category</key><array><string>AMCategoryUtilities</string></array>
                <key>Class Name</key><string>RunShellScriptAction</string>
                <key>InputUUID</key><string>A1111111-1111-1111-1111-111111111111</string>
                <key>Keywords</key><array><string>Shell</string><string>Script</string></array>
                <key>OutputUUID</key><string>B2222222-2222-2222-2222-222222222222</string>
                <key>UUID</key><string>C3333333-3333-3333-3333-333333333333</string>
                <key>UnlocalizedApplications</key><array><string>Automator</string></array>
                <key>arguments</key><dict>
                  <key>0</key><dict><key>default value</key><integer>0</integer><key>name</key><string>inputMethod</string><key>required</key><string>0</string><key>type</key><string>0</string><key>uuid</key><string>0</string></dict>
                  <key>1</key><dict><key>default value</key><false/><key>name</key><string>CheckedForUserDefaultShell</string><key>required</key><string>0</string><key>type</key><string>0</string><key>uuid</key><string>1</string></dict>
                  <key>2</key><dict><key>default value</key><string></string><key>name</key><string>source</string><key>required</key><string>0</string><key>type</key><string>0</string><key>uuid</key><string>2</string></dict>
                  <key>3</key><dict><key>default value</key><string>/bin/sh</string><key>name</key><string>shell</string><key>required</key><string>0</string><key>type</key><string>0</string><key>uuid</key><string>3</string></dict>
                  <key>4</key><dict><key>default value</key><string></string><key>name</key><string>COMMAND_STRING</string><key>required</key><string>0</string><key>type</key><string>0</string><key>uuid</key><string>4</string></dict>
                </dict>
                <key>isViewVisible</key><integer>1</integer>
                <key>location</key><string>309.000000:253.000000</string>
                <key>nibPath</key><string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib</string>
              </dict>
              <key>isViewVisible</key><integer>1</integer>
            </dict>
          </array>
          <key>connectors</key><dict/>
          <key>workflowMetaData</key><dict>
            <key>applicationBundleIDsByPath</key><dict/>
            <key>applicationPaths</key><array/>
            <key>inputTypeIdentifier</key><string>\(inputType)</string>
            <key>outputTypeIdentifier</key><string>com.apple.Automator.nothing</string>
            <key>presentationMode</key><integer>11</integer>
            <key>processesInput</key><integer>0</integer>
            <key>serviceApplicationBundleID</key><string>com.apple.finder</string>
            <key>serviceApplicationPath</key><string>/System/Library/CoreServices/Finder.app</string>
            <key>serviceInputTypeIdentifier</key><string>\(inputType)</string>
            <key>serviceOutputTypeIdentifier</key><string>com.apple.Automator.nothing</string>
            <key>serviceProcessesInput</key><integer>0</integer>
            <key>systemImageName</key><string>NSActionTemplate</string>
            <key>useAutomaticInputType</key><integer>0</integer>
            <key>workflowTypeIdentifier</key><string>com.apple.Automator.servicesMenu</string>
          </dict>
        </dict></plist>
        """
    }

    // Receives folders/files the system routes to us (e.g. when Navigator is the
    // default folder handler). Folders open as new tabs; other files open normally.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Finder Quick Actions call back via our navigatoraction:// scheme.
        let actionURLs = urls.filter { $0.scheme == "navigatoraction" }
        if !actionURLs.isEmpty { actionURLs.forEach { handleActionURL($0) }; return }
        let urls = urls.filter { $0.isFileURL }
        guard !urls.isEmpty else { return }
        // Images → our built-in viewer (when Navigator is the default image app,
        // opening one from Finder lands here). Do NOT NSWorkspace.open them, or it
        // would bounce right back to us. Arrow through the folder like Preview.
        let images = urls.filter { isImageFile($0) }
        let rest = urls.filter { !isImageFile($0) }
        let folders = rest.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        let others = rest.filter { !folders.contains($0) }

        if let first = images.first {
            // If we're only being asked to view image(s) and the browser hasn't
            // shown yet (launched to view), keep the browser hidden — just the viewer.
            if folders.isEmpty && others.isEmpty && !mainWindowShown { suppressMainWindow = true }
            let folder = first.deletingLastPathComponent()
            // Enumerate the sibling images off the main thread — over a network /
            // Drive folder this scan can block. Open the viewer once the list is
            // ready (near-instant for local folders); no main-thread stall.
            DispatchQueue.global(qos: .userInitiated).async {
                let siblings = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                    .filter { isImageFile($0) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                let list = siblings.isEmpty ? images : siblings
                DispatchQueue.main.async {
                    ImageViewerController.shared.show(urls: list, index: list.firstIndex(of: first) ?? 0)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        for u in others { NSWorkspace.shared.open(u) }   // non-images → their own default app
        guard !folders.isEmpty else { return }
        // Folders always need the browser window.
        if window == nil { pendingFolders += folders; return }   // opened before launch finished
        showMainWindow()
        folders.forEach { window.model.newTab(at: $0) }
    }

    /// True from applicationWillTerminate onward, so the windowWillClose hook can tell
    /// "the user closed this window" (forget its tabs) from "the app is quitting"
    /// (keep every window's tabs for next launch).
    private var terminating = false

    @discardableResult
    private func makeWindow(session: WindowSession?) -> NavWindow {
        let w = NavWindow(session: session)
        w.isReleasedWhenClosed = false
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self, weak w] _ in
            guard let self, let w else { return }
            if !self.terminating { w.model.forgetSession() }
            if let token { NotificationCenter.default.removeObserver(token) }
            // Drop our strong reference or the window NEVER deallocates — with
            // isReleasedWhenClosed = false, `extraWindows` was the last owner and had
            // no matching removal, so every window you closed leaked its AppModel, its
            // Browsers and their DirectoryWatchers for the life of the process (each
            // one still watching a folder and still answering notifications).
            // Deferred: releasing a window from inside its own willClose is a
            // use-after-free waiting to happen.
            DispatchQueue.main.async { self.extraWindows.removeAll { $0 === w } }
        }
        w.startObservingFolderTitle()
        w.contentView = NSHostingView(rootView: ContentView(model: w.model))
        // Park the window's initial keyboard focus somewhere harmless. Leaving this
        // nil is what put the caret in the SEARCH BOX on launch: AppKit's
        // -[NSWindow _setUpFirstResponder] falls back to _selectFirstKeyView, which
        // hands first responder to the first view in the key-view loop that will take
        // it — and the empty search field is the only one in this window that will.
        // The window then opened with Search focused (measured: on most launches), so
        // the first thing typed went silently into the search box instead of doing
        // type-to-select on the files. The hosting view itself is NOT a usable stand-in
        // here: it refuses first responder often enough that AppKit fell back to the
        // search field on some launches anyway (measured), hence the dedicated view.
        w.contentView?.addSubview(w.focusPark)
        w.initialFirstResponder = w.focusPark
        w.center()
        return w
    }

    @objc func newWindowAction(_ sender: Any?) { openWindow() }

    /// Opens an extra browser window, optionally showing exactly one folder.
    ///
    /// `showing` is what makes "Move Tab to New Window" land on the right folder: a
    /// fresh NavWindow's AppModel restores the SAVED tab list in its initialiser, so
    /// without replacing that list the moved tab would arrive alongside a copy of every
    /// other tab. Assigned directly and NOT via newTab(), because newTab() calls
    /// saveState() — which would immediately overwrite the persisted tab list of the
    /// window the tab just left.
    /// `at` places the window's top-left corner at a screen point — where a torn-off tab
    /// was dropped. Constrained to the screen afterwards, or a drop near the bottom-right
    /// corner would put most of the new window off-display.
    @discardableResult
    func openWindow(showing url: URL? = nil, at topLeft: CGPoint? = nil,
                    session: WindowSession? = nil, activate: Bool = true) -> NavWindow {
        let w = makeWindow(session: session)
        if let topLeft {
            w.setFrameTopLeftPoint(topLeft)
            w.setFrame(w.constrainFrameRect(w.frame, to: w.screen), display: false)
        } else {
            var f = w.frame; f.origin.x += 28; f.origin.y -= 28; w.setFrame(f, display: false)
        }
        extraWindows.append(w)
        if let url {
            w.model.tabs = [Browser(start: url)]
            w.model.selected = 0
            w.model.saveState()   // assigning `tabs` directly doesn't fire saveState
        }
        w.makeKeyAndOrderFront(nil)
        if activate { NSApp.activate(ignoringOtherApps: true) }
        return w
    }

    /// Puts back the extra windows a previous session had open, behind the main
    /// window. Ordered oldest-first and NOT activated, so restoring five windows
    /// doesn't leave a random one in front of the one the user was last using.
    private func restoreExtraWindows(_ sessions: [WindowSession]) {
        for (i, s) in sessions.enumerated() {
            let w = openWindow(session: s, activate: false)
            var f = w.frame
            f.origin.x += CGFloat(28 * (i + 1)); f.origin.y -= CGFloat(28 * (i + 1))
            w.setFrame(w.constrainFrameRect(f, to: w.screen), display: false)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Clicking the Dock icon (or reopening) with no window visible brings the
    // browser up — important since an image-only launch keeps it hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        // Set BEFORE the save: quitting closes every window, and the willClose hook
        // must not read those closes as "the user doesn't want these tabs back".
        terminating = true
        for w in NSApp.windows.compactMap({ $0 as? NavWindow }) { w.model.saveState() }
    }

    // Keyboard navigation for the file list/grid. Runs only when our window is key
    // and a text field isn't being edited, so typing in the address/search/filter
    // fields (and modal dialogs) is never disturbed.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
        // ⌘ + scroll wheel view resizing is handled in NavWindow.sendEvent.
    }
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let keyWin = NSApp.keyWindow as? NavWindow else { return event }
        if isEditingText(in: keyWin) { return event }
        let b = keyWin.model.active
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 36, 76: // Return / Enter → open
            if !b.selection.isEmpty { b.openSelection(); return nil }
            return event
        case 51: // Delete/Backspace (no modifier) → Move to Trash
            // Bare Delete trashes the selection (what people expect); ⌘⌫ does too
            // via the File menu. "Enclosing folder" is ⌘↑ (toolbar Up button's
            // shortcut), so no navigation is lost. Text fields are handled above,
            // and moveToTrash still honours the "Confirm before Trash" setting.
            if flags.isEmpty {
                if b.selection.isEmpty { return event }
                b.moveToTrash(b.selection); return nil
            }
            return event
        // NOTE: Tab / ⇧Tab is NOT handled here — see NavWindow.sendEvent. Returning
        // nil from this monitor does not stop AppKit's key-view loop from also seeing
        // the keystroke, and that second look moved first responder into the search
        // field, which made the NEXT Tab look like "a text field is focused, keep
        // out". Only sendEvent consumes it early enough.
        case 120: // F2 → rename selected (Windows parity)
            if !b.selection.isEmpty { renameAction(nil); return nil }
            return event
        case 49: // Space → Quick Look
            if !b.selection.isEmpty {
                QuickLook.shared.show(b.items.filter { b.selection.contains($0.id) }.map { $0.url }); return nil
            }
            return event
        // NOTE: ⌘C / ⌘X / ⌘V are deliberately NOT handled here. The Edit menu's
        // Cut/Copy/Paste items dispatch through the responder chain to the
        // AppDelegate's cut/copy/paste fallbacks (which already do files when no
        // text field is focused). Handling them here as well made every ⌘V run
        // TWICE — pasting two copies of everything and doing double the work,
        // which is what made copy/paste feel weird and laggy.
        case 125: // Down
            if b.viewMode == .icon, flags.isEmpty { b.moveSelection(dy: 1); return nil }
            return event
        case 126: // Up
            if b.viewMode == .icon, flags.isEmpty { b.moveSelection(dy: -1); return nil }
            return event
        case 123: // Left
            if b.viewMode == .icon || b.viewMode == .gallery, flags.isEmpty { b.moveSelection(dx: -1); return nil }
            return event
        case 124: // Right
            if b.viewMode == .icon || b.viewMode == .gallery, flags.isEmpty { b.moveSelection(dx: 1); return nil }
            return event
        default:
            // Type-to-select (printable key, no command/control/option)
            if flags.isEmpty || flags == .shift,
               let chars = event.charactersIgnoringModifiers, chars.count == 1,
               let scalar = chars.unicodeScalars.first, scalar.value >= 32, scalar.value != 127 {
                b.typeSelect(chars); return nil
            }
            return event
        }
    }

    private func setupMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Navigator", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let cfu = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdatesAction(_:)), keyEquivalent: ""); cfu.target = self
        appMenu.addItem(.separator())
        let set = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettingsAction(_:)), keyEquivalent: ","); set.target = self
        appMenu.addItem(.separator())
        let dfb = appMenu.addItem(withTitle: "Set as Default File Browser…", action: #selector(setDefaultBrowserAction(_:)), keyEquivalent: "")
        dfb.target = self
        let div = appMenu.addItem(withTitle: "Set as Default Image Viewer…", action: #selector(setDefaultImageViewerAction(_:)), keyEquivalent: "")
        div.target = self
        // The app menu is where the owner went looking, so this is where the checklist
        // lives — Help ▸ Setup Assistant… stays too, and both open the SAME window.
        //
        // "Grant Full Disk Access…" survives underneath it, and the labels say why: one
        // audits every permission, the other walks one switch a user is usually sent to
        // by name (the denial alerts and PERMISSIONS.md both cite it) and adds the two
        // things the checklist row can't — the +/⇧⌘G recipe and Reveal in Finder.
        let checklist = appMenu.addItem(withTitle: "Permissions Checklist…", action: #selector(showSetupAssistantAction(_:)), keyEquivalent: "")
        checklist.target = self
        let fda = appMenu.addItem(withTitle: "Grant Full Disk Access…", action: #selector(openFullDiskAccessAction(_:)), keyEquivalent: "")
        fda.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Navigator", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Navigator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File"); fileItem.submenu = fileMenu
        let nw = fileMenu.addItem(withTitle: "New Window", action: #selector(newWindowAction(_:)), keyEquivalent: "n"); nw.target = self
        let nt = fileMenu.addItem(withTitle: "New Tab", action: #selector(newTabAction(_:)), keyEquivalent: "t"); nt.target = self
        let ct = fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTabAction(_:)), keyEquivalent: "w"); ct.target = self
        // ⌘W closes the TAB (falling back to the window on the last one), so a window
        // full of tabs took one ⌘W per tab to get rid of. ⌘⇧W closes the lot at once,
        // matching Finder and Safari.
        let cw = fileMenu.addItem(withTitle: "Close Window", action: #selector(closeWindowAction(_:)), keyEquivalent: "w")
        cw.keyEquivalentModifierMask = [.command, .shift]; cw.target = self
        fileMenu.addItem(.separator())
        let nf = fileMenu.addItem(withTitle: "New Folder", action: #selector(newFolderAction(_:)), keyEquivalent: "n")
        nf.keyEquivalentModifierMask = [.command, .shift]; nf.target = self
        let ntf = fileMenu.addItem(withTitle: "New Text File", action: #selector(newTextFileAction(_:)), keyEquivalent: "n")
        ntf.keyEquivalentModifierMask = [.command, .option]; ntf.target = self
        // The rest of the "New" family. No key equivalents: the three chords above are
        // the ones worth spending, and these all reach the same Browser methods the
        // toolbar/context "New" submenu uses (newItemsMenu) — that's where the list of
        // items is defined; an NSMenu can't share a SwiftUI ViewBuilder.
        let nrt = fileMenu.addItem(withTitle: "New Rich Text Document", action: #selector(newRichTextFileAction(_:)), keyEquivalent: "")
        nrt.target = self
        let nfs = fileMenu.addItem(withTitle: "New Folder with Selection", action: #selector(newFolderWithSelectionAction(_:)), keyEquivalent: "")
        nfs.target = self
        fileMenu.addItem(.separator())
        let gi = fileMenu.addItem(withTitle: "Get Info", action: #selector(getInfoAction(_:)), keyEquivalent: "i"); gi.target = self
        let dup = fileMenu.addItem(withTitle: "Duplicate", action: #selector(duplicateAction(_:)), keyEquivalent: "d"); dup.target = self
        // ⌃⌘A, the modern Finder chord — NOT Finder's historical ⌘L, which this app
        // spends on "focus the address bar" (used far more often than aliasing).
        let mka = fileMenu.addItem(withTitle: "Make Alias", action: #selector(makeAliasAction(_:)), keyEquivalent: "a")
        mka.keyEquivalentModifierMask = [.command, .control]; mka.target = self
        let rn = fileMenu.addItem(withTitle: "Rename…", action: #selector(renameAction(_:)), keyEquivalent: ""); rn.target = self
        let ql = fileMenu.addItem(withTitle: "Quick Look", action: #selector(quickLookAction(_:)), keyEquivalent: "y"); ql.target = self
        let zip = fileMenu.addItem(withTitle: "Compress", action: #selector(compressAction(_:)), keyEquivalent: ""); zip.target = self
        fileMenu.addItem(.separator())
        let del = fileMenu.addItem(withTitle: "Move to Trash", action: #selector(moveToTrashAction(_:)), keyEquivalent: "\u{8}")
        del.keyEquivalentModifierMask = [.command]; del.target = self
        let et = fileMenu.addItem(withTitle: "Empty Trash", action: #selector(emptyTrashAction(_:)), keyEquivalent: "\u{8}")
        et.keyEquivalentModifierMask = [.command, .shift]; et.target = self
        fileMenu.addItem(.separator())
        // Connect to Server (⌘K) now lives in the Go menu, where Finder keeps it — one
        // menu item per chord, so nothing has to arbitrate between two copies of ⌘K.
        let and = fileMenu.addItem(withTitle: "Add Network Drive…", action: #selector(addNetworkDriveAction(_:)), keyEquivalent: "")
        and.target = self
        let ej = fileMenu.addItem(withTitle: "Eject", action: #selector(ejectAction(_:)), keyEquivalent: "e"); ej.target = self
        fileMenu.addItem(.separator())
        let expF = fileMenu.addItem(withTitle: "Export Favorites…", action: #selector(exportFavoritesAction(_:)), keyEquivalent: ""); expF.target = self
        let impF = fileMenu.addItem(withTitle: "Import Favorites…", action: #selector(importFavoritesAction(_:)), keyEquivalent: ""); impF.target = self

        // Edit menu uses the STANDARD selectors + titles, so the user's System Settings
        // keyboard-shortcut overrides for Copy/Cut/Paste are applied automatically.
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
        let undo = editMenu.addItem(withTitle: "Undo", action: #selector(undoAction(_:)), keyEquivalent: "z"); undo.target = self
        let redo = editMenu.addItem(withTitle: "Redo", action: #selector(redoAction(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]; redo.target = self
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        // Targeted at self rather than sent down the responder chain: nil-targeted
        // NSText.selectAll reached neither the SwiftUI text field nor the file list, so
        // ⌘A did nothing at all. selectAllAction routes it — text field if one has the
        // caret, otherwise select every file in view.
        let sa = editMenu.addItem(withTitle: "Select All", action: #selector(selectAllAction(_:)), keyEquivalent: "a")
        sa.target = self

        let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View"); viewItem.submenu = viewMenu
        let sb = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebarAction(_:)), keyEquivalent: "s")
        sb.keyEquivalentModifierMask = [.command, .option]; sb.target = self
        let pv = viewMenu.addItem(withTitle: "Toggle Preview Pane", action: #selector(togglePreviewAction(_:)), keyEquivalent: "p")
        pv.keyEquivalentModifierMask = [.command, .shift]; pv.target = self
        let dp = viewMenu.addItem(withTitle: "Toggle Dual Pane", action: #selector(toggleDualPaneAction(_:)), keyEquivalent: "2")
        dp.keyEquivalentModifierMask = [.command, .option]; dp.target = self
        let sh = viewMenu.addItem(withTitle: "Toggle Hidden Files", action: #selector(toggleHiddenAction(_:)), keyEquivalent: ".")
        sh.keyEquivalentModifierMask = [.command, .shift]; sh.target = self
        viewMenu.addItem(.separator())
        // Finder's ⌘J, in Finder's place in the View menu.
        let vo = viewMenu.addItem(withTitle: "Show View Options", action: #selector(showViewOptionsAction(_:)), keyEquivalent: "j")
        vo.keyEquivalentModifierMask = [.command]; vo.target = self
        // The column picker used to exist ONLY as a right-click on a column header, which
        // nobody finds. This submenu is built from the same ColumnMenu source as that menu,
        // and menuNeedsUpdate below re-ticks it every time it opens, so the two can't drift.
        let colsItem = viewMenu.addItem(withTitle: "Columns", action: nil, keyEquivalent: "")
        let colsMenu = NSMenu(title: "Columns")
        colsMenu.delegate = self
        colsItem.submenu = colsMenu
        columnsMenu = colsMenu

        // Go menu, in Finder's position (after View). Before this, the only way to
        // reach Applications / Volumes / Home / Go to Folder was the Dock icon's
        // right-click menu — undiscoverable, and unusable while the app is frontmost.
        //
        // This menu OWNS ⌘[ / ⌘] / ⌘↑; the toolbar buttons deliberately carry no
        // .keyboardShortcut, because both would fire (see ControlBar).
        let goItem = NSMenuItem(); mainMenu.addItem(goItem)
        let goMenu = NSMenu(title: "Go"); goItem.submenu = goMenu
        let back = goMenu.addItem(withTitle: "Back", action: #selector(goBackAction(_:)), keyEquivalent: "[")
        back.target = self
        let fwd = goMenu.addItem(withTitle: "Forward", action: #selector(goForwardAction(_:)), keyEquivalent: "]")
        fwd.target = self
        let up = goMenu.addItem(withTitle: "Enclosing Folder", action: #selector(goUpAction(_:)), keyEquivalent: "\u{F700}")
        up.keyEquivalentModifierMask = [.command]; up.target = self
        goMenu.addItem(.separator())
        let rec = goMenu.addItem(withTitle: "Recents", action: #selector(goRecentsAction(_:)), keyEquivalent: "")
        rec.target = self
        // One selector for every fixed destination, with the URL on the item itself:
        // validateMenuItem reads the same representedObject to grey out anything this
        // Mac doesn't have (/Network on most of them), so a chord for a missing folder
        // is dead rather than navigating somewhere broken.
        func dest(_ title: String, _ path: String, _ key: String, _ mods: NSEvent.ModifierFlags) {
            let it = goMenu.addItem(withTitle: title, action: #selector(goToLocationAction(_:)), keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.representedObject = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            it.target = self
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        dest("Home", home, "h", [.command, .shift])
        dest("Desktop", home + "/Desktop", "d", [.command, .shift])
        dest("Documents", home + "/Documents", "o", [.command, .shift])
        dest("Downloads", home + "/Downloads", "l", [.command, .option])
        goMenu.addItem(.separator())
        dest("Applications", "/Applications", "a", [.command, .shift])
        dest("Utilities", "/Applications/Utilities", "u", [.command, .shift])
        // Finder's ⌘⇧C is "Computer"; /Volumes is this app's equivalent (it's what the
        // Dock menu's "Volumes" already opens) and it always exists.
        dest("Computer", "/Volumes", "c", [.command, .shift])
        dest("Network", "/Network", "k", [.command, .shift])
        goMenu.addItem(.separator())
        // No AirDrop item: macOS exposes no public API to open an AirDrop browsing
        // view, in-app or otherwise, and a fake one that opens something else is worse
        // than its absence.
        let gtf = goMenu.addItem(withTitle: "Go to Folder…", action: #selector(goToFolderAction(_:)), keyEquivalent: "g")
        gtf.keyEquivalentModifierMask = [.command, .shift]; gtf.target = self
        let cs = goMenu.addItem(withTitle: "Connect to Server…", action: #selector(connectServerAction(_:)), keyEquivalent: "k")
        cs.target = self
        goMenu.addItem(.separator())
        // The discoverable face of the global hotkey — nobody finds a system-wide chord
        // that exists only in Settings. Its key equivalent is refreshed from the pref in
        // validateMenuItem, since the chord is configurable and this is built once.
        let cpd = goMenu.addItem(withTitle: "Copy Path for Open/Save Dialog",
                                 action: #selector(copyPathForDialogAction(_:)), keyEquivalent: "")
        cpd.target = self
        cpd.toolTip = "Copies this folder (or the selected item) so any app's Open/Save dialog can jump to it with ⌘⇧G, ⌘V. Works while Navigator is in the background. A Google Drive path or drive.google.com link already on the clipboard is converted to this Mac's Drive folder and used instead."

        // Window menu: standard Minimize/Zoom/Bring All to Front. Deliberately NOT set
        // as NSApp.windowsMenu — confirmed live that doing so makes the Dock's
        // right-click menu ALSO merge in its own auto-tracked window list on top of the
        // one applicationDockMenu() already builds below, duplicating every window
        // entry. The Dock menu is the one place this app needs a live window list
        // (matching Chrome), so it owns that job alone.
        let windowItem = NSMenuItem(); mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window"); windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        let aiItem = NSMenuItem(); mainMenu.addItem(aiItem)
        let aiMenu = NSMenu(title: "AI"); aiItem.submenu = aiMenu
        let keysItem = aiMenu.addItem(withTitle: "API Keys…", action: #selector(apiKeysAction(_:)), keyEquivalent: "")
        keysItem.target = self
        let fxItem = aiMenu.addItem(withTitle: "Finder Menu…", action: #selector(finderExtensionAction(_:)), keyEquivalent: "")
        fxItem.target = self
        let qaItem = aiMenu.addItem(withTitle: "Install Finder Quick Actions", action: #selector(installFinderQuickActions(_:)), keyEquivalent: "")
        qaItem.target = self
        aiMenu.addItem(NSMenuItem.separator())
        let vSignIn = aiMenu.addItem(withTitle: "Sign in to Vertex (Imagen)…", action: #selector(vertexSignInAction(_:)), keyEquivalent: "")
        vSignIn.target = self
        let vStatus = aiMenu.addItem(withTitle: "Vertex Status…", action: #selector(vertexStatusAction(_:)), keyEquivalent: "")
        vStatus.target = self
        let vLog = aiMenu.addItem(withTitle: "Open AI Log…", action: #selector(openAILogAction(_:)), keyEquivalent: "")
        vLog.target = self

        // Help, in its conventional last position — where someone who half-set-up their
        // permissions months ago will actually go looking for a way back.
        let helpItem = NSMenuItem(); mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help"); helpItem.submenu = helpMenu
        let setupItem = helpMenu.addItem(withTitle: "Setup Assistant…", action: #selector(showSetupAssistantAction(_:)), keyEquivalent: "")
        setupItem.target = self

        NSApp.mainMenu = mainMenu
    }

    // AI → API Keys… — paste/store the fal.ai key (Keychain-backed).
    @objc func apiKeysAction(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "AI API Keys"
        a.informativeText = "Paste your fal.ai API key (used for AI upscaling). It’s stored securely in your macOS Keychain, not in a file."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "fal.ai key (e.g. 1234abcd-…:…)"
        field.stringValue = APIKeys.fal ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        if a.runModal() == .alertFirstButtonReturn {
            APIKeys.fal = field.stringValue
        }
    }

    // AI → Sign in to Vertex — runs the H5G client's browser Google sign-in in a
    // visible Terminal window so the user sees the flow and the result. No key is
    // typed; the token is stored by the client at ~/.h5g-ai-gen/token.json.
    @objc func vertexSignInAction(_ sender: Any?) {
        guard let node = resolveNode(), let client = resolveH5GClient() else { promptVertexSetup(); return }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let shell = "clear; \(q(node)) \(q(client)) login; echo; echo 'You can close this window.'"
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"\nend tell"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    // Nudge, once per version, if Navigator's Finder menu is switched off.
    private func offerFinderExtensionIfDisabled() {
        guard !FIFinderSyncController.isExtensionEnabled else { return }
        // The Setup Assistant has a row for this and opened moments ago — two prompts
        // about the same switch on someone's very first launch is one too many.
        guard !isFirstRun else { return }
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        guard Prefs.d.string(forKey: "finderExtPrompt") != ver else { return }
        Prefs.d.set(ver, forKey: "finderExtPrompt")
        let a = NSAlert()
        a.messageText = "Turn on Navigator’s Finder menu?"
        a.informativeText = """
        Navigator can add its own menu to Finder’s right-click menu — Remove BG, \
        Chroma Key BG and the AI upscalers — so you don’t have to switch apps.

        macOS needs you to switch it on once: tick Navigator in \(finderExtensionSectionName).
        """
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Not Now")
        if a.runModal() == .alertFirstButtonReturn {
            FIFinderSyncController.showExtensionManagementInterface()
        }
    }

    // AI → Finder Menu… — say whether it's on, and offer the switch either way.
    @objc func finderExtensionAction(_ sender: Any?) {
        let on = FIFinderSyncController.isExtensionEnabled
        let a = NSAlert()
        a.messageText = on ? "Navigator’s Finder menu is on" : "Navigator’s Finder menu is off"
        a.informativeText = on
            ? "Right-click any file or folder in Finder and look for the Navigator submenu."
            : "Tick Navigator in \(finderExtensionSectionName) to add its menu to Finder’s right-click menu."
        a.addButton(withTitle: on ? "Open Settings" : "Open Settings")
        a.addButton(withTitle: "Done")
        if a.runModal() == .alertFirstButtonReturn {
            FIFinderSyncController.showExtensionManagementInterface()
        }
    }

    // AI → Open AI Log — reveal the dev log so failures are easy to inspect.
    @objc func openAILogAction(_ sender: Any?) {
        if !FileManager.default.fileExists(atPath: navLogURL.path) { navLog("(log opened — no activity yet)") }
        NSWorkspace.shared.open(navLogURL)
    }

    // AI → Vertex Status — `whoami` against the metered service.
    @objc func vertexStatusAction(_ sender: Any?) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = runH5GClient(["whoami"])
            let email = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                let a = NSAlert()
                if r.code == 0, !email.isEmpty, !email.lowercased().contains("not signed in") {
                    a.messageText = "Signed in to Vertex"
                    a.informativeText = "Account: \(email)\nImagen upscaling is ready."
                } else {
                    a.alertStyle = .warning
                    a.messageText = "Not signed in to Vertex"
                    a.informativeText = "Use AI → Sign in to Vertex (Imagen)… to sign in with your High 5 Games Google account."
                }
                a.addButton(withTitle: "OK"); a.runModal()
            }
        }
    }

    // Fallback handlers for the Edit menu, reached when the responder chain declined the
    // action. "Declined" does NOT reliably mean "no text field is focused" — SwiftUI's
    // TextField often lets these fall through while it genuinely has the caret, and the
    // result was ⌘V in the address bar pasting FILES into the current folder. So each of
    // these asks first, and only touches files when text editing isn't in play.
    @objc func copy(_ sender: Any?) {
        if performTextEditingAction(.copy) { return }
        appModel.active.copyFiles()
    }
    @objc func cut(_ sender: Any?) {
        if performTextEditingAction(.cut) { return }
        appModel.active.cutFiles()
    }
    @objc func paste(_ sender: Any?) {
        if performTextEditingAction(.paste) { return }
        appModel.active.pasteFiles()
    }
    @objc func selectAllAction(_ sender: Any?) {
        if performTextEditingAction(.selectAll) { return }
        let b = appModel.active
        b.selection = Set(b.orderedVisibleItems().map { $0.id })
        b.updateStatus()
    }
    @objc func newTabAction(_ sender: Any?) { appModel.newTab() }
    @objc func closeTabAction(_ sender: Any?) {
        // ⌘W has to mean "close what I'm looking at". This is a single app-wide menu
        // item, so without the NavWindow check it reached past a focused Settings /
        // Get Info / Setup Assistant / viewer window and closed a browser TAB behind
        // it — the user loses a tab they could still see while the window they aimed
        // at stays open. `appModel` deliberately falls back to the last key browser
        // window, which is what let it find a tab to close from any window at all.
        guard NSApp.keyWindow is NavWindow else { NSApp.keyWindow?.performClose(nil); return }
        if appModel.tabs.count > 1 { appModel.closeTab(appModel.selected) } else { NSApp.keyWindow?.performClose(nil) }
    }
    @objc func closeWindowAction(_ sender: Any?) { (NSApp.keyWindow ?? window)?.performClose(nil) }
    @objc func makeAliasAction(_ sender: Any?) { appModel.active.makeAlias(appModel.active.selection) }

    // MARK: Go menu
    @objc func goBackAction(_ sender: Any?) { appModel.active.goBack() }
    @objc func goForwardAction(_ sender: Any?) { appModel.active.goForward() }
    @objc func goUpAction(_ sender: Any?) { appModel.active.goUp() }
    @objc func goRecentsAction(_ sender: Any?) { appModel.active.loadRecents() }
    // Navigates the CURRENT tab, like the sidebar and unlike the Dock menu's
    // openFolderTab — a Go menu that spawned a tab per destination would pile them up.
    @objc func goToLocationAction(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let win = (NSApp.keyWindow as? NavWindow) ?? window!
        win.makeKeyAndOrderFront(nil)
        win.model.active.navigate(to: url)
    }
    @objc func newFolderAction(_ sender: Any?) { appModel.active.newFolder() }
    @objc func newTextFileAction(_ sender: Any?) { appModel.active.newTextFile() }
    @objc func newRichTextFileAction(_ sender: Any?) { appModel.active.newRichTextFile() }
    @objc func newFolderWithSelectionAction(_ sender: Any?) {
        appModel.active.newFolderWithSelection(appModel.active.selection)
    }
    @objc func moveToTrashAction(_ sender: Any?) { appModel.active.moveToTrash(appModel.active.selection) }
    @objc func getInfoAction(_ sender: Any?) { showInfo(appModel.active, appModel.active.selection) }
    @objc func duplicateAction(_ sender: Any?) { appModel.active.duplicate(appModel.active.selection) }
    @objc func renameAction(_ sender: Any?) {
        let b = appModel.active
        let sel = b.items.filter { b.selection.contains($0.id) }
        if sel.count > 1 { BatchRenameController.shared.show(b, sel) }
        else if let id = b.selection.first { promptRename(b, id) }
    }
    @objc func quickLookAction(_ sender: Any?) {
        let b = appModel.active
        QuickLook.shared.show(b.items.filter { b.selection.contains($0.id) }.map { $0.url })
    }
    @objc func compressAction(_ sender: Any?) { appModel.active.compress(appModel.active.selection) }
    @objc func emptyTrashAction(_ sender: Any?) { confirmEmptyTrash(appModel.active) }

    // File → Eject (⌘E). Finder ejects the SELECTED disk; the sidebar here has no
    // selection to read (its rows are buttons), so the unambiguous equivalent is the
    // volume the folder you're looking at lives on. validateMenuItem below greys the
    // item out when that volume can't be let go of, so ⌘E never quietly does nothing.
    @objc func ejectAction(_ sender: Any?) {
        guard let v = ejectableVolume() else { return }
        disconnectVolume(v.url, isNetwork: v.isNetwork)
    }
    private func ejectableVolume() -> SidebarLocation? {
        let vols = volumeLocations().filter { $0.ejectable }
        guard let root = PathRules.deepestRoot(containing: appModel.active.currentURL,
                                               among: vols.map { $0.url }) else { return nil }
        return vols.first { $0.url == root }
    }
    @objc func togglePreviewAction(_ sender: Any?) { appModel.showPreview.toggle() }
    @objc func toggleSidebarAction(_ sender: Any?) { appModel.showSidebar.toggle() }
    @objc func toggleDualPaneAction(_ sender: Any?) { appModel.dualPane.toggle() }
    @objc func toggleHiddenAction(_ sender: Any?) { appModel.active.showHidden.toggle() }
    @objc func undoAction(_ sender: Any?) {
        // When editing text, let the field's own undo run; otherwise undo file
        // operations. Uses the KEY window (not the first window) so ⌘Z works in
        // whichever Navigator window you're actually in.
        let win = NSApp.keyWindow ?? window
        if let r = win?.firstResponder, r is NSText || r is NSTextView,
           let um = win?.undoManager, um.canUndo { um.undo(); return }
        UndoStack.shared.undo()
    }
    @objc func redoAction(_ sender: Any?) {
        let win = NSApp.keyWindow ?? window
        if let r = win?.firstResponder, r is NSText || r is NSTextView,
           let um = win?.undoManager, um.canRedo { um.redo(); return }
        UndoStack.shared.redo()
    }

    // Keep Edit → Undo/Redo honest: each names the operation it will act on and greys
    // out when its stack is empty (text fields keep their own undo). Eject is the
    // same deal — it names the disk it will eject, and is disabled (so ⌘E is dead
    // too, not silently ignored) when the current folder isn't on an ejectable one.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // Go menu. A destination this Mac doesn't have (/Network is absent unless
        // something mounts it, and ~/Documents can be missing too) is greyed out, so
        // its chord is dead rather than navigating into a folder that isn't there.
        if item.action == #selector(goToLocationAction(_:)) {
            guard let url = item.representedObject as? URL else { return false }
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        if item.action == #selector(goBackAction(_:)) { return appModel.active.canGoBack }
        if item.action == #selector(goForwardAction(_:)) { return appModel.active.canGoForward }
        if item.action == #selector(goUpAction(_:)) {
            let u = appModel.active.currentURL
            return u.deletingLastPathComponent().path != u.path
        }
        // The chord is a user pref and this item is built once at launch, so it re-reads
        // it as the menu opens — an item advertising a shortcut the user has since changed
        // would be a lie the user can see.
        if item.action == #selector(copyPathForDialogAction(_:)) {
            let c = PickerBridgeRules.chord(id: Prefs.pickerHotkeyChord)
            item.keyEquivalent = c.key.lowercased()
            item.keyEquivalentModifierMask = PickerBridge.cocoaModifiers(c.carbonModifiers)
            return true
        }
        if item.action == #selector(makeAliasAction(_:)) { return !appModel.active.selection.isEmpty }
        // Grey out rather than beep: with nothing selected there is nothing to wrap up.
        if item.action == #selector(newFolderWithSelectionAction(_:)) { return !appModel.active.selection.isEmpty }
        if item.action == #selector(ejectAction(_:)) {
            guard let v = ejectableVolume() else { item.title = "Eject"; return false }
            item.title = v.isNetwork ? "Disconnect “\(v.name)”" : "Eject “\(v.name)”"
            return true
        }
        if item.action == #selector(redoAction(_:)) {
            let r = (NSApp.keyWindow ?? window)?.firstResponder
            if r is NSText || r is NSTextView { item.title = "Redo"; return true }
            if let desc = UndoStack.shared.topRedoDescription {
                item.title = "Redo \(desc)"; return true
            }
            item.title = "Redo"; return false
        }
        guard item.action == #selector(undoAction(_:)) else { return true }
        let r = (NSApp.keyWindow ?? window)?.firstResponder
        if r is NSText || r is NSTextView { item.title = "Undo"; return true }
        if let desc = UndoStack.shared.topDescription {
            item.title = "Undo \(desc)"; return true
        }
        item.title = "Undo"; return false
    }
    @objc func setDefaultImageViewerAction(_ sender: Any?) { applyImageDefaults(announce: true) }

    // Set Navigator as the default app for the image types its viewer handles.
    // (We register for public.image, but Launch Services defaults are set per
    // concrete type.) `announce` shows a result alert; the first-launch prompt
    // passes false since it already asked.
    private func applyImageDefaults(announce: Bool) {
        let types = ["public.png", "public.jpeg", "com.compuserve.gif", "public.tiff",
                     "public.heic", "public.heif", "org.webmproject.webp",
                     "com.microsoft.bmp", "com.microsoft.ico", "public.jpeg-2000"]
        let appURL = Bundle.main.bundleURL
        let group = DispatchGroup()
        var failures = 0
        for t in types {
            guard let ut = UTType(t) else { continue }
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: ut) { err in
                if err != nil { failures += 1 }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard announce else { return }
            let a = NSAlert()
            if failures == 0 {
                a.messageText = "Navigator is now your default image viewer"
                a.informativeText = "Opening an image anywhere — Finder, Mail, Messages — now opens it in Navigator's viewer.\n\nTo undo later: in Finder select an image → Get Info → “Open with” → choose another app → “Change All…”."
            } else {
                a.alertStyle = .warning
                a.messageText = "Set as default image viewer (mostly)"
                a.informativeText = "\(failures) image type(s) couldn't be set automatically. You can finish manually: Finder → select an image → Get Info → “Open with” → Navigator → “Change All…”."
            }
            a.addButton(withTitle: "OK"); a.runModal()
        }
    }

    // One-time, on first normal launch: offer to become the default for the only
    // type Navigator genuinely owns — images. Folders are deliberately excluded
    // (macOS reserves them for Finder), and other types would just bounce back
    // out to their own apps, so we don't pretend to own them.
    private func offerDefaultsIfNeeded() {
        guard !Prefs.didOfferDefaults else { return }
        Prefs.didOfferDefaults = true
        let appURL = Bundle.main.bundleURL
        // Skip if already the default (e.g. set earlier via the menu).
        if NSWorkspace.shared.urlForApplication(toOpen: UTType.png)?.standardizedFileURL == appURL.standardizedFileURL { return }
        let a = NSAlert()
        a.messageText = "Make Navigator your default image viewer?"
        a.informativeText = "Images opened anywhere — Finder, Mail, Messages — would open in Navigator's fast built-in viewer instead of Preview.\n\nFinder stays your file manager; macOS reserves folders for it. You can change this anytime in the Navigator menu."
        a.addButton(withTitle: "Use Navigator")
        a.addButton(withTitle: "Not Now")
        if a.runModal() == .alertFirstButtonReturn { applyImageDefaults(announce: false) }
    }

    @objc func setDefaultBrowserAction(_ sender: Any?) {
        let appURL = Bundle.main.bundleURL
        Task { @MainActor in
            // Attempt the real takeover (works only if the OS permits it for folders).
            try? await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: .folder)
            let def = NSWorkspace.shared.urlForApplication(toOpen: UTType.folder)
            let isDefault = def?.standardizedFileURL.path == appURL.standardizedFileURL.path
            let a = NSAlert()
            if isDefault {
                a.messageText = "Navigator is now your default folder handler"
                a.informativeText = "Folders opened through the system will now open in Navigator."
                a.addButton(withTitle: "OK")
                a.runModal()
            } else {
                a.messageText = "macOS reserves folders for Finder"
                a.informativeText = """
                macOS doesn't let any third-party app fully replace Finder as the system-wide handler for folders — Apple locks that to Finder.

                What does work — Navigator is registered as a folder app, so you can:
                •  Right-click a folder in Finder → Open With → Navigator
                •  Open With → Other…, pick Navigator, and tick “Always Open With” to make that folder always open in Navigator
                •  From Terminal:  open -b com.merickson.navigator <folder>
                •  Keep Navigator in your Dock as your everyday browser

                Folders opened this way open as tabs in Navigator.
                """
                a.addButton(withTitle: "Reveal Navigator in Finder")
                a.addButton(withTitle: "OK")
                if a.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([appURL])
                }
            }
        }
    }
    @objc func openFullDiskAccessAction(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "Grant Navigator Full Disk Access"
        a.informativeText = """
        This lets Navigator see protected folders (Desktop, Documents, Downloads) and all your files.

        1. Click “Open Settings” — the Full Disk Access list opens.
        2. If Navigator isn't listed, click the + button, press ⌘⇧G, type /Applications/Navigator.app, and add it.
        3. Turn the switch ON next to Navigator.
        4. Quit and reopen Navigator.

        macOS requires you to flip this switch yourself — no app is allowed to grant it automatically.
        """
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Reveal Navigator in Finder")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: "/Applications/Navigator.app")])
        default:
            break
        }
    }

    @objc func showViewOptionsAction(_ sender: Any?) { ViewOptionsController.shared.toggle(appModel) }

    /// View ▸ Columns, ticked from the live folder's visible set — the SAME set the header
    /// right-click menu reads and writes (see ColumnMenu). Neither menu keeps its own copy,
    /// so toggling Owner in one shows it ticked in the other.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === columnsMenu else { return }
        menu.removeAllItems()
        let visible = appModel.active.visibleColumns
        for id in ColumnMenu.togglableIDs {
            let item = menu.addItem(withTitle: fileColumnTitle(id), action: #selector(toggleColumnAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = visible.contains(id) ? .on : .off
        }
    }
    @objc func toggleColumnAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let b = appModel.active
        b.visibleColumns = ColumnMenu.toggled(b.visibleColumns, id: id)
        // Columns only exist in Details view, so a column turned on from the menu while in
        // Icons/Gallery would appear to do nothing at all. Switching there is what the user
        // asked for by asking for a column.
        if b.viewMode != .list { b.viewMode = .list }
    }

    @objc func showSetupAssistantAction(_ sender: Any?) { SetupAssistantController.shared.show() }

    @objc func checkForUpdatesAction(_ sender: Any?) { Updater.check(userInitiated: true) }
    private var settingsWindow: NSWindow?
    @objc func showSettingsAction(_ sender: Any?) {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Settings"
            w.contentView = NSHostingView(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // center() above ran against the 440x360 placeholder; the hosting view then resizes
        // the window to whatever its content needs, growing DOWNWARD from that origin. With
        // the taller pane that put the last rows below the screen edge and behind the Dock —
        // including the Accessibility warning and its button. Re-centre once the real height
        // is known, and only when the window doesn't fit where it is.
        DispatchQueue.main.async { [weak self] in
            guard let w = self?.settingsWindow,
                  let vis = (w.screen ?? NSScreen.main)?.visibleFrame,
                  !vis.contains(w.frame) else { return }
            w.center()
        }
    }

    @objc func exportFavoritesAction(_ sender: Any?) {
        guard let data = FavoritesStore.shared.exportData() else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Navigator Favorites.json"
        panel.allowedContentTypes = [.json]
        panel.message = "Share this file with a coworker; they can import it to get the same sidebar shortcuts (they still connect through their own VPN/login)."
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }
    @objc func importFavoritesAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Navigator favorites (.json) file to add its shortcuts to your sidebar."
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let n = FavoritesStore.shared.importData(data)
        let a = NSAlert()
        if n > 0 {
            a.messageText = "Imported \(n) favorite\(n == 1 ? "" : "s")"
            a.informativeText = "They've been added to your sidebar. Network drives connect through your own VPN and login when you first click them."
        } else if n == 0 {
            a.alertStyle = .informational
            a.messageText = "Nothing new to import"
            a.informativeText = "Those favorites are already in your sidebar."
        } else {
            a.alertStyle = .warning
            a.messageText = "Couldn't read that file"
            a.informativeText = "It doesn't look like a Navigator favorites export."
        }
        a.addButton(withTitle: "OK"); a.runModal()
    }

    @objc func connectServerAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Connect to Server"
        alert.informativeText = "Enter a server address, e.g. smb://server/share or afp://server. It will mount and appear under Locations."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = "smb://"
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let s = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty, let url = URL(string: s) {
                DispatchQueue.global(qos: .userInitiated).async {
                    let mp = Browser.mountShare(url)   // direct mount, no Finder
                    DispatchQueue.main.async {
                        if let mp { self.openFolderTab(URL(fileURLWithPath: mp)) } else { NSSound.beep() }
                    }
                }
            }
        }
    }

    // Add a network drive as a pinned favorite: prompt for a name + address,
    // mount it, and add it to the sidebar with its mount URL so a click re-mounts
    // it later (VPN reconnect, reboot). This is how a coworker sets up a new share
    // without editing JSON.
    @objc func addNetworkDriveAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Add Network Drive"
        alert.informativeText = "Give it a name and the server address (e.g. smb://server/share). It mounts now and stays pinned in the sidebar — one click reconnects it later."
        let name = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        name.placeholderString = "Name (e.g. G Drive)"
        let addr = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        addr.stringValue = "smb://"
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 320, height: 58))
        stack.orientation = .vertical; stack.spacing = 8
        stack.addArrangedSubview(name); stack.addArrangedSubview(addr)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let label = name.stringValue.trimmingCharacters(in: .whitespaces)
        let s = addr.stringValue.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, let url = URL(string: s) else { NSSound.beep(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let mp = Browser.mountShare(url) else {
                DispatchQueue.main.async {
                    let a = NSAlert(); a.messageText = "Couldn't connect to \(url.host ?? "the server")"
                    a.informativeText = "Check the address and that you're on the VPN, then try again."
                    a.runModal()
                }
                return
            }
            DispatchQueue.main.async {
                FavoritesStore.shared.add(URL(fileURLWithPath: mp), label: label.isEmpty ? nil : label, mountURL: s)
                self.openFolderTab(URL(fileURLWithPath: mp))
            }
        }
    }

    // Right-click (or Control-click) the Dock icon → Finder-style shortcuts.
    // macOS appends its own "Options / Show All Windows / Quit" below these.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            m.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self
        }
        // Every open Navigator window (browser, image viewer, Compare, Restyle…) listed
        // by title, so one is always reachable after minimizing — like Chrome's Dock
        // icon. Needed regardless of the system's "Minimize windows into application
        // icon" preference: verified live that with that preference off, even Chrome's
        // own Dock menu shows no window list, so Chrome must build this itself too.
        // isVisible goes false the instant a window is miniaturized (confirmed live) —
        // isMiniaturized is what keeps it listed here after that.
        let openWindows = NSApp.windows.filter {
            ($0.isVisible || $0.isMiniaturized) && !$0.title.isEmpty && !$0.isExcludedFromWindowsMenu
        }
        if !openWindows.isEmpty {
            for w in openWindows {
                let item = m.addItem(withTitle: w.title, action: #selector(bringDockWindowToFront(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = w
                item.state = w.isKeyWindow ? .on : .off
            }
            m.addItem(.separator())
        }
        add("New Window", #selector(newWindowAction(_:)))
        add("New Tab", #selector(dockNewTabAction(_:)))
        add("Find…", #selector(dockFindAction(_:)))
        m.addItem(.separator())
        add("Go to Folder…", #selector(goToFolderAction(_:)))
        add("Connect to Server…", #selector(connectServerAction(_:)))
        m.addItem(.separator())
        add("Applications", #selector(dockApplicationsAction(_:)))
        add("Volumes", #selector(dockVolumesAction(_:)))
        add("Home", #selector(dockHomeAction(_:)))
        return m
    }

    private func openFolderTab(_ url: URL) {
        let win = (NSApp.keyWindow as? NavWindow) ?? window!
        win.model.newTab(at: url)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func dockNewTabAction(_ sender: Any?) {
        let win = (NSApp.keyWindow as? NavWindow) ?? window!
        win.model.newTab()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func dockApplicationsAction(_ sender: Any?) { openFolderTab(URL(fileURLWithPath: "/Applications")) }
    @objc func dockVolumesAction(_ sender: Any?) { openFolderTab(URL(fileURLWithPath: "/Volumes")) }
    @objc func dockHomeAction(_ sender: Any?) { openFolderTab(FileManager.default.homeDirectoryForCurrentUser) }
    @objc func dockFindAction(_ sender: Any?) {
        let win = (NSApp.keyWindow as? NavWindow) ?? window!
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .navigatorFocusSearch, object: nil)
    }
    /// The mirror image of Go to Folder: instead of taking a path from the clipboard, it
    /// puts one there for somebody else's Open/Save panel to receive.
    @objc func copyPathForDialogAction(_ sender: Any?) { PickerBridge.shared.copyNow() }

    @objc func goToFolderAction(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Go to Folder"
        alert.informativeText = "Enter a path, e.g. /Users/you/Documents or ~/Desktop"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Go"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            var p = field.stringValue.trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("~") { p = (p as NSString).expandingTildeInPath }
            guard !p.isEmpty else { return }
            let url = URL(fileURLWithPath: p)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                openFolderTab(url)
            } else { NSSound.beep() }
        }
    }
}

// ===== Restyle (AI) — Gemini style analysis + Nano Banana edit ===============
//
// Two calls, and the split is the whole trick. Handing the style reference to the
// image model as a second input does NOT transfer style — tested against the live
// model, the reference's SUBJECT replaced the output (a tiki "SUPER WIN" frame came
// back as a lion in Jedi robes, the lion being the reference). Nano Banana treats
// the LAST input image as the thing it is editing.
//
// So: a vision model reads the reference and reduces it to subject-free TEXT, and
// only the image being restyled is ever sent as pixels. See RestyleRules.

/// The metered AI service, called directly.
///
/// Navigator shells out to client.mjs elsewhere, but not for this: that client's alias
/// map knows only nb1/nb2/nb-pro and silently substitutes NB2's ID for anything else,
/// so a model chosen in the UI could quietly run a different one. The service accepts a
/// full Vertex model ID (verified by posting raw IDs to /v1/images), so Navigator sends
/// the ID and what you pick is what runs.
enum H5GService {
    static var token: String? {
        let f = (NSHomeDirectory() as NSString).appendingPathComponent(".h5g-ai-gen/token.json")
        guard let d = FileManager.default.contents(atPath: f),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j["token"] as? String
    }

    /// The hub's URL. Baked into client.mjs, overridable by the same env var the client
    /// honours, so a redeploy that moves the service needs no change here.
    static var baseURL: String? {
        if let e = ProcessInfo.processInfo.environment["H5G_AIGEN_URL"], !e.isEmpty {
            return e.hasSuffix("/") ? String(e.dropLast()) : e
        }
        guard let client = resolveH5GClient(),
              let src = try? String(contentsOfFile: client, encoding: .utf8) else { return nil }
        // SERVICE_URL = "https://…"  — first quoted https URL after the name.
        guard let r = src.range(of: "SERVICE_URL"),
              let q = src.range(of: "https://[^\"']+", options: .regularExpression,
                                range: r.upperBound..<src.endIndex) else { return nil }
        var u = String(src[q])
        if u.hasSuffix("/") { u = String(u.dropLast()) }
        return u
    }

    /// POST /v1/images. Returns the PNG, what it cost, or an error to show.
    ///
    /// `inputPNGs` order matters: on a live run, the LAST image is the one the model
    /// treats as the edit target — an earlier image is a reference. Confirmed by
    /// swapping the order of the same two images and observing which one the output
    /// kept as its subject.
    static func image(prompt: String, modelID: String, inputPNGs: [Data],
                      aspect: String?, size: String?) -> (png: Data?, cost: Double?, error: String?) {
        guard let base = baseURL else { return (nil, nil, "Couldn’t find the AI service URL.") }
        guard let token else {
            return (nil, nil, "Not signed in to Vertex. Use AI → Sign in to Vertex first.")
        }
        guard let url = URL(string: base + "/v1/images") else { return (nil, nil, "bad service URL") }
        var body: [String: Any] = ["prompt": prompt, "model": modelID]
        if !inputPNGs.isEmpty {
            // "base64", not "data" — the service checks im?.base64 (matches client.mjs's
            // own { base64, mime } shape). Sending "data" silently drops every input
            // image: no error, no 400, just zero images reaching the model. Confirmed
            // directly — a request naming a completely wrong subject, sent with a real
            // photo attached under the wrong key, generated the WRONG subject with no
            // trace of the real photo at all. Every restyle before this fix was pure
            // text-to-image generation from the prompt, not actually editing the source.
            body["input_images"] = inputPNGs.map { ["mime": "image/png", "base64": $0.base64EncodedString()] }
        }
        if let aspect, !aspect.isEmpty { body["aspect_ratio"] = aspect }
        if let size, !size.isEmpty { body["image_size"] = size }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        var out: (Data?, Double?, String?) = (nil, nil, "no response")
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { out = (nil, nil, err.localizedDescription); return }
            guard let data, let http = resp as? HTTPURLResponse else { out = (nil, nil, "no data"); return }
            let text = String(data: data, encoding: .utf8) ?? ""
            guard http.statusCode == 200 else {
                out = (nil, nil, "AI service HTTP \(http.statusCode): " + String(text.prefix(400))); return
            }
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let b64 = j["image_base64"] as? String,
                  let png = Data(base64Encoded: b64) else {
                out = (nil, nil, "unexpected response: " + String(text.prefix(300))); return
            }
            out = (png, j["cost_usd"] as? Double, nil)
        }.resume()
        sem.wait()
        return out
    }

    /// POST /v1/vision — plain Gemini text describing an image, never generating
    /// one. Distinct from `image` above, which requires an image in the response;
    /// this requires TEXT and fails if it gets an image back. Model is pinned
    /// server-side (gemini-3.5-flash-lite) — not client-selectable, so there's no
    /// modelID parameter here.
    static func describe(prompt: String, systemPrompt: String?, imagePNG: Data)
        -> (text: String?, cost: Double?, error: String?) {
        guard let base = baseURL else { return (nil, nil, "Couldn’t find the AI service URL.") }
        guard let token else {
            return (nil, nil, "Not signed in to Vertex. Use AI → Sign in to Vertex first.")
        }
        guard let url = URL(string: base + "/v1/vision") else { return (nil, nil, "bad service URL") }
        var body: [String: Any] = [
            "prompt": prompt,
            "input_images": [["mime": "image/png", "base64": imagePNG.base64EncodedString()]],
        ]
        if let systemPrompt, !systemPrompt.isEmpty { body["system_prompt"] = systemPrompt }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        var out: (String?, Double?, String?) = (nil, nil, "no response")
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { out = (nil, nil, err.localizedDescription); return }
            guard let data, let http = resp as? HTTPURLResponse else { out = (nil, nil, "no data"); return }
            let text = String(data: data, encoding: .utf8) ?? ""
            guard http.statusCode == 200 else {
                out = (nil, nil, "AI service HTTP \(http.statusCode): " + String(text.prefix(400))); return
            }
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = j["text"] as? String else {
                out = (nil, nil, "unexpected response: " + String(text.prefix(300))); return
            }
            out = (t, j["cost_usd"] as? Double, nil)
        }.resume()
        sem.wait()
        return out
    }
}

/// PNG of `url` with its long edge capped at `maxDim`. A vision read only needs
/// enough resolution to make out the subject, and a 2500px reference would make
/// the request needlessly heavy for no benefit.
func downscaledPNG(_ url: URL, maxDim: CGFloat = 768) -> Data? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceThumbnailMaxPixelSize: maxDim,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return encodePNG(cg)
}

/// Ask Gemini (via /v1/vision) to name the SOURCE image's persistent identity —
/// species/type, face, markings, worn items — as an anchor for the restyle prompt.
func analyzeIdentity(sourcePNG png: Data) -> (text: String?, error: String?) {
    let r = H5GService.describe(prompt: "Describe the identity to preserve.",
                                systemPrompt: RestyleRules.identitySystemPrompt, imagePNG: png)
    return (r.text, r.error)
}

/// Ask Gemini (via /v1/vision) to extract the REFERENCE image's art style as
/// subject-free text, for the single-image restyle path.
func analyzeStyle(referencePNG png: Data) -> (text: String?, error: String?) {
    let r = H5GService.describe(prompt: "Extract the transferable art style.",
                                systemPrompt: RestyleRules.styleSystemPrompt, imagePNG: png)
    return (r.text, r.error)
}

/// True when the image actually has see-through pixels.
///
/// An alpha channel alone isn't enough — plenty of exported PNGs carry one that is
/// fully opaque. Nano Banana flattens alpha to black, so a cutout sent unpadded comes
/// back on black; this decides whether a backing colour is needed. Sampled from a
/// small thumbnail, so it costs nothing on a 4K asset.
func hasTransparency(_ url: URL) -> Bool {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
              kCGImageSourceThumbnailMaxPixelSize: 128,
              kCGImageSourceCreateThumbnailFromImageAlways: true,
          ] as CFDictionary) else { return false }
    switch cg.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: return false
    default: break
    }
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    for i in stride(from: 3, to: buf.count, by: 4) where buf[i] < 250 { return true }
    return false
}

/// A Gemini image model, addressed by its real Vertex model ID.
///
/// These deliberately do NOT match the aliases in the AI hub's client.mjs, which
/// point at "-preview" spellings (gemini-3.1-flash-image-preview,
/// gemini-3-pro-image-preview). The service used to substitute its own stale
/// default for any model it didn't recognise -- verified by posting nonsense model
/// names and seeing Vertex asked for that same "-preview" ID every time -- which
/// made every model but the original fail regardless of what was requested. Fixed
/// service-side; re-verified against the live endpoint that all four now generate
/// under the exact ID sent (the response echoes the model back).
struct NanoBananaModel: Identifiable, Hashable {
    let flag: String, id: String, name: String, note: String
    static let all = [
        NanoBananaModel(flag: "nb2", id: "gemini-3.1-flash-image", name: "Nano Banana 2",
                        note: "Default."),
        NanoBananaModel(flag: "nb-lite", id: "gemini-3.1-flash-lite-image", name: "Nano Banana 2 Lite",
                        note: "Faster and cheaper than NB2."),
        NanoBananaModel(flag: "nb-pro", id: "gemini-3-pro-image", name: "Nano Banana Pro",
                        note: "Highest quality."),
        NanoBananaModel(flag: "nb1", id: "gemini-2.5-flash-image", name: "Nano Banana 1",
                        note: "The original, tuned for editing."),
    ]
    static func byFlag(_ f: String) -> NanoBananaModel { all.first { $0.flag == f } ?? all[0] }
}

/// Run the restyle. `styleReferencePNG`, when present, is sent as a real second
/// input image alongside the source — both through H5GService.image, Vertex only.
///
/// The input images were silently never reaching the model at all until a real
/// bug got fixed here: this function built `input_images` under the JSON key
/// "data", but the service reads `im.base64` — wrong key, no error, image just
/// never attached. Confirmed directly: a request naming the wrong subject, with a
/// real photo attached under the wrong key, generated the wrong subject with zero
/// trace of the real photo. So every restyle before that fix was pure
/// text-to-image generation, not an edit — it only looked like editing when the
/// prompt's identity anchors were specific enough to regenerate something
/// recognizable from scratch. Fixed; the source and any reference are now genuine
/// inputs to the edit.
/// Write a PNG to disk with the restyle recipe embedded in its own metadata.
///
/// Re-encodes from the decoded image rather than copying the source through with
/// AddImageFromSource. That looked wasteful at first, but AddImageFromSource carries
/// the ORIGINAL file's metadata along and will not reliably overwrite a key it
/// already has — tested against a Photoshop-saved PNG, the output kept claiming
/// "Adobe Photoshop 27.8" as its Software no matter what was passed in, which would
/// have every restyled file lying about how it was made. PNG is lossless, so
/// re-encoding costs pixels nothing; it just guarantees the metadata is ours alone.
///
/// Lands in the PNG's standard text chunks so anything can read it back (Preview's
/// inspector, exiftool, `sips -g`, Navigator's own Get Info):
///   Description — the full prompt actually sent
///   Title       — the identity anchors that were preserved
///   Software    — model, resolution, and which images were sent
/// Returns false on any failure so the caller can fall back to a plain write rather
/// than losing the image entirely.
///
/// `mode` is appended to Software rather than given a field of its own so the existing
/// reader (readRestyleInfo, which gates on the "Navigator Restyle" prefix) and the
/// (i) popover pick it up with no extra plumbing. It matters because "text only" and
/// "source + style image" produce very different results from the same settings, and
/// six months later the prompt alone is a subtle way to tell them apart.
@discardableResult
func writePNGWithRestyleMetadata(_ png: Data, to dest: URL, identity: String, prompt: String,
                                 model: String, size: String, mode: String = "") -> Bool {
    guard let src = CGImageSourceCreateWithData(png as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let out = CGImageDestinationCreateWithURL(dest as CFURL, "public.png" as CFString, 1, nil)
    else { return false }
    var pngMeta: [CFString: Any] = [
        kCGImagePropertyPNGSoftware: "Navigator Restyle — \(model), \(size)"
            + (mode.isEmpty ? "" : ", \(mode)"),
        kCGImagePropertyPNGCreationTime: ISO8601DateFormatter().string(from: Date()),
    ]
    let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if !p.isEmpty { pngMeta[kCGImagePropertyPNGDescription] = p }
    let id = identity.trimmingCharacters(in: .whitespacesAndNewlines)
    if !id.isEmpty { pngMeta[kCGImagePropertyPNGTitle] = id }
    CGImageDestinationAddImage(out, img, [kCGImagePropertyPNGDictionary: pngMeta] as CFDictionary)
    return CGImageDestinationFinalize(out)
}

/// `sendSourceImage: false` withholds the source's pixels and generates from the
/// prompt's content description instead — the caller must pair that with a `create`
/// prompt shape (see RestyleRules.prompt), because a "preserve this image exactly"
/// prompt with no image attached asks the model to be faithful to something it can't
/// see. The output is still NAMED after `source`/`nameAfter` either way, which is the
/// point: it's still that file's restyle, just generated from its description.
func runRestyle(source: URL, prompt: String, modelFlag: String, aspect: String, size: String,
                styleReferencePNG: Data? = nil, nameAfter: URL? = nil, identity: String = "",
                sendSourceImage: Bool = true, modeLabel: String = "")
    -> (saved: URL?, cost: Double?, error: String?) {
    let named = nameAfter ?? source
    let model = NanoBananaModel.byFlag(modelFlag)
    // Raw position alone is NOT the deciding factor — explicit role labels in the
    // prompt override it. The one combination proven to preserve identity twice in a
    // row (source FIRST, reference SECOND, both under explicit "IMAGE 1 is..." /
    // "IMAGE 2 is..." labels) is reproduced exactly here; this is not the position
    // that a naive "last image wins" rule would predict, and that's the point —
    // don't reorder this without re-testing.
    //
    // With the source withheld the reference becomes the ONLY image, which is exactly
    // what generatePromptStyleImage labels it as ("the attached image is a STYLE
    // reference ONLY") — so the label still matches the payload.
    var inputs: [Data] = []
    if sendSourceImage {
        guard let sourcePNG = try? Data(contentsOf: source) else {
            return (nil, nil, "Couldn’t read \(source.lastPathComponent).")
        }
        inputs.append(sourcePNG)
    }
    if let styleReferencePNG { inputs.append(styleReferencePNG) }
    let r = H5GService.image(prompt: prompt, modelID: model.id, inputPNGs: inputs,
                            aspect: aspect, size: size)
    guard let out = r.png else { return (nil, nil, r.error ?? "Restyle failed.") }
    let dest = PathRules.uniqueDest(named.deletingLastPathComponent(),
                                    named.deletingPathExtension().lastPathComponent + "_restyled.png",
                                    exists: { FileManager.default.fileExists(atPath: $0) })
    // Embed the recipe, falling back to a plain write so a metadata problem can never
    // cost someone the generated image.
    if !writePNGWithRestyleMetadata(out, to: dest, identity: identity, prompt: prompt,
                                    model: model.name, size: size, mode: modeLabel) {
        do { try out.write(to: dest) }
        catch { return (nil, r.cost, "Couldn’t save the result: \(error.localizedDescription)") }
    }
    return (dest, r.cost, nil)
}

/// One image in the restyle queue. Each carries its OWN identity anchors, because
/// a batch is usually a set of different characters/objects sharing one target
/// style — a single shared description would drag every output toward whatever the
/// first image happened to be.
struct RestyleItem: Identifiable {
    enum State: Equatable {
        case pending, detecting, running, done(URL), failed(String)
        var isTerminal: Bool { if case .done = self { return true }; if case .failed = self { return true }; return false }
    }
    let id = UUID()
    let url: URL
    var identity: String = ""
    var state: State = .pending
    /// Send this file's actual pixels, or generate from `identity` alone. Per-item
    /// rather than one shared switch because a batch is a mix: some files worth
    /// editing directly, others better rebuilt from a description that's been
    /// cleaned up by hand.
    var sendImage: Bool = true
    /// How many times this item has been run. Regenerating never overwrites — each
    /// run writes a new "_restyled N.png" — so the count is the only way to tell a
    /// second attempt's result from the first at a glance.
    var attempts: Int = 0
}

/// The Restyle window: a queue of images on the left, shared style settings on the
/// right. Restyle just the selected one, or run the whole list.
struct RestyleSheet: View {
    var onFinished: (URL) -> Void
    // Hosted in a plain NSWindow (matching the viewer and compare windows), where the
    // SwiftUI dismiss environment has nothing to act on — so closing is a callback.
    var onClose: () -> Void

    @State private var items: [RestyleItem]
    @State private var selected: UUID?
    @State private var listTargeted = false

    @State private var reference: URL?
    @State private var refTargeted = false
    /// Send the reference's pixels, or let `styleText` carry the style alone. Untick
    /// after Analyze and the workflow becomes: read the look out of a reference into
    /// words, edit those words, then generate from the words — which is the whole
    /// reason a style can be "pure text" while a reference is still on screen.
    @State private var sendReference = true
    @State private var styleText = ""
    @State private var styleBusy = false
    @State private var extra = ""
    @State private var modelFlag = "nb2"
    @State private var size = RestyleRules.defaultSize
    @State private var aspect = "auto"
    @State private var padOn = true
    @State private var padColor = RestyleRules.defaultPadColorName
    @State private var identityBusy = false

    @State private var busy = false          // a single restyle is running
    @State private var batchRunning = false
    @State private var cancelRequested = false
    @State private var progress = ""
    @State private var status = ""
    @State private var failure = ""
    // How many restyles run at once during "Restyle All". Kept adjustable rather than
    // hardcoded: the AI hub's Cloud Run concurrency ceiling wasn't something this could
    // confirm directly (gcloud auth had expired when this was written), so 4 is a
    // conservative starting default, not a measured safe maximum. Per-item transient
    // retry (503/429) already absorbs occasional contention either way.
    @State private var parallelism = 4

    init(sources: [URL], onFinished: @escaping (URL) -> Void, onClose: @escaping () -> Void) {
        let list = sources.map { RestyleItem(url: $0) }
        _items = State(initialValue: list)
        _selected = State(initialValue: list.first?.id)
        self.onFinished = onFinished
        self.onClose = onClose
    }

    // MARK: - Derived

    private var current: RestyleItem? { items.first { $0.id == selected } }
    private var currentIndex: Int? { items.firstIndex { $0.id == selected } }
    private var models: [NanoBananaModel] { NanoBananaModel.all }
    private var sizes: [String] { RestyleRules.sizes(forModelFlag: modelFlag) }
    private var leaks: [String] { RestyleRules.styleLeaks(in: styleText) }
    private var contentStyleLeaks: [String] {
        RestyleRules.styleLeaksInContents(current?.identity ?? "")
    }
    private var anyRunning: Bool { busy || batchRunning }

    // MARK: Input mode

    /// True only when a reference image is both present AND ticked to be sent.
    private var referenceInPlay: Bool { sendReference && reference != nil }
    /// The mode for one specific item (each carries its own sendImage).
    private func mode(for item: RestyleItem) -> RestyleInputMode {
        RestyleInputMode(sendSource: item.sendImage, sendReference: referenceInPlay)
    }
    private var currentMode: RestyleInputMode? { current.map(mode(for:)) }

    /// A style has to come from SOMEWHERE: either a reference image that's actually
    /// being sent, or style text. A reference sitting there with its box unticked is not
    /// a style — that case is exactly why this can't just check `reference != nil`.
    private var hasStyleSource: Bool {
        referenceInPlay || !styleText.trimmingCharacters(in: .whitespaces).isEmpty
    }
    /// Content has to come from somewhere too. With the source image sent, the image
    /// itself is the content and an empty description is merely weaker. With it
    /// withheld, an empty description means there is nothing to draw at all.
    private func hasContentSource(_ item: RestyleItem) -> Bool {
        item.sendImage || !item.identity.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Run / regenerate counts

    /// Items a plain "Restyle All" would pick up: everything not already finished.
    private var pendingCount: Int { items.filter { !$0.state.isTerminal }.count }
    /// Once every item is finished, "Restyle All" would be a no-op — so the batch
    /// button turns into "Regenerate All" and resets them instead. That's what makes
    /// the window re-runnable rather than one-and-done, without a second button that
    /// does almost the same thing.
    private var batchIsRegenerate: Bool { !items.isEmpty && pendingCount == 0 }
    private var batchCount: Int { batchIsRegenerate ? items.count : pendingCount }
    private var batchLabel: String {
        batchIsRegenerate ? "Regenerate All (\(batchCount))" : "Restyle All (\(batchCount))"
    }
    private var runLabel: String {
        (current?.state.isTerminal ?? false) ? "Regenerate" : "Restyle This"
    }
    private var anyFinished: Bool { items.contains { $0.state.isTerminal } }

    private var canRun: Bool {
        guard !anyRunning, let cur = current else { return false }
        return hasStyleSource && hasContentSource(cur)
    }
    /// A batch only needs a style up front. Per-item content is deliberately NOT checked
    /// here: an item with no description still gets one auto-detected as the batch
    /// reaches it, so demanding one now would disable the button for the normal case.
    /// The one genuinely unrunnable case — text-only, no description, and detection
    /// fails too — is caught per item in the worker, which fails just that item with the
    /// fix in the message.
    ///
    /// This is intentionally free of filesystem checks. It runs on every re-render, and
    /// a stat-per-item here would hit the disk (or a slow SMB share) continuously while
    /// someone types in the style field.
    private var canRunBatch: Bool { !anyRunning && hasStyleSource && batchCount > 0 }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            queue
            Divider()
            controls
        }
        .padding(16)
        // minWidth/minHeight rather than a fixed frame, paired with a resizable window:
        // the panel grows a few conditional warning lines (missing description, "auto"
        // aspect with no source image) and a fixed 640pt window would clip the buttons
        // off the bottom with no way to reach them — this window has no scroll view and
        // used to have no resize control either.
        .frame(minWidth: 900, minHeight: 720)
        .onAppear {
            if !sizes.contains(size) { size = sizes.first ?? RestyleRules.defaultSize }
            detectIdentity()   // for whatever opened selected
        }
        .onChange(of: selected) { detectIdentity() }
    }

    // MARK: - Left: the queue

    private var queue: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Images (\(items.count))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Send All Images") { setAllSendImage(true) }
                    Button("All Text-Only (don’t send images)") { setAllSendImage(false) }
                    Divider()
                    Button("Reset Finished to Pending") { resetFinished() }
                        .disabled(!anyFinished)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().frame(width: 28)
                    .disabled(items.isEmpty || anyRunning)
                    .help("Bulk image/text mode, and reset finished items so they can run again")
                Button { addImages() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("Add images")
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .buttonStyle(.plain).disabled(current == nil || anyRunning).help("Remove selected")
            }

            List(selection: $selected) {
                ForEach(items) { item in
                    let live = item.state == .running || item.state == .detecting
                    HStack(spacing: 6) {
                        stateIcon(item.state)
                        Text(item.url.lastPathComponent)
                            .font(.caption2).lineLimit(1).truncationMode(.middle)
                            .fontWeight(live ? .bold : .regular)
                        Spacer(minLength: 2)
                        // Mode shown as a plain glyph, NOT a checkbox: an interactive
                        // control inside a selectable row competes with the row's own
                        // click handling, which is exactly what broke selection in the
                        // file list twice. The real toggle lives under the thumbnail
                        // below, where nothing contests the click; bulk changes go
                        // through the menu above.
                        if !item.sendImage {
                            Image(systemName: "textformat")
                                .font(.caption2).foregroundStyle(.orange)
                                .help("Text-only — this file's pixels aren't sent")
                        }
                        if item.attempts > 1 {
                            Text("×\(item.attempts)").font(.caption2).foregroundStyle(.tertiary)
                                .help("Run \(item.attempts) times")
                        }
                    }
                    // The row being worked on is called out in the accent colour. Without
                    // this, a batch looked like it might be reusing one prompt for
                    // everything, because the only moving part was a small spinner while
                    // the description field kept showing whatever was SELECTED.
                    .listRowBackground(live ? Color.accentColor.opacity(0.22) : Color.clear)
                    .tag(item.id)
                }
            }
            .frame(height: 190)
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(listTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: listTargeted ? 2 : 1))

            if let item = current {
                thumb(item.url)
                Text(item.url.lastPathComponent).font(.caption2).lineLimit(2)
                    .frame(width: 250, alignment: .leading)
                if let s = imagePixelSize(item.url) {
                    Text("\(s.w) × \(s.h)").font(.caption2).foregroundStyle(.tertiary)
                }
                Toggle(isOn: sendImageBinding) {
                    Text("Send this image").font(.caption)
                }
                .disabled(anyRunning)
                .help("Off: generate from the content description below instead of this file's pixels")
                if !item.sendImage {
                    Text("Text-only — the description below is the whole subject. The result is still saved next to this file.")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .failed(let e) = item.state {
                    Text(e).font(.caption2).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(3)
                }
                if case .done(let out) = item.state {
                    Text("Saved \(out.lastPathComponent)"
                         + (item.attempts > 1 ? " · attempt \(item.attempts)" : ""))
                        .font(.caption2).foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(2)
                }
            } else {
                Text("Drop images above to build a batch.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(width: 250)
        // Files can come from anywhere — different folders, different volumes — so the
        // queue takes drops directly, not just whatever was selected when it opened.
        // The target is this whole column, NOT the List: a List intercepts the drop and
        // silently accepts nothing (verified — dropping onto the list itself did
        // nothing at all), the same trap the sidebar reorder hit.
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            SpringLoader.shared.noteDrop()   // a completed drag must not spring back — see the sidebar
            addURLs(urls)
            return true
        } isTargeted: { listTargeted = $0 }
    }

    @ViewBuilder private func stateIcon(_ s: RestyleItem.State) -> some View {
        switch s {
        case .pending:   Image(systemName: "circle").font(.caption2).foregroundStyle(.tertiary)
        case .detecting: ProgressView().controlSize(.mini)
        case .running:   ProgressView().controlSize(.mini)
        case .done:      Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
        case .failed:    Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
        }
    }

    private func thumb(_ url: URL) -> some View {
        Group {
            if let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .frame(width: 250, height: 150)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.15)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Right: shared settings

    private var controls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Restyle with AI").font(.headline)
                Spacer()
                if anyRunning { ProgressView().controlSize(.small) }
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Style reference").font(.caption).foregroundStyle(.secondary)
                    referenceWell
                    HStack(spacing: 8) {
                        Button("Choose…") { pickReference() }
                        if reference != nil {
                            Button("Clear") { reference = nil; styleText = "" }.foregroundStyle(.secondary)
                        }
                    }.font(.caption)
                    if reference != nil {
                        Toggle(isOn: $sendReference) { Text("Send reference image").font(.caption) }
                            .disabled(anyRunning)
                            .help("Off: use the style text below instead of the reference's pixels")
                        if !sendReference {
                            Text("Style text only — the reference is just a source for Analyze now.")
                                .font(.caption2).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true).frame(width: 210, alignment: .leading)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Model", selection: $modelFlag) {
                        ForEach(models) { m in Text(m.name).tag(m.flag) }
                    }
                    .onChange(of: modelFlag) { if !sizes.contains(size) { size = sizes.first ?? "1K" } }
                    Picker("Resolution", selection: $size) {
                        ForEach(sizes, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Aspect", selection: $aspect) {
                        ForEach(RestyleRules.aspects, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle(isOn: $padOn) { Text("Pad transparent art").font(.callout) }
                    if padOn {
                        Picker("Background", selection: $padColor) {
                            ForEach(aiPrepColors) { c in
                                Label { Text(c.name) } icon: { Image(nsImage: circleSwatch(c.color)) }.tag(c.name)
                            }
                        }
                    }
                }
            }
            if padOn {
                Text("Only images that are actually transparent (or an odd aspect) get padded — the rest are sent untouched, and no original is modified either way."
                     + (items.contains { !$0.sendImage } ? " Text-only items skip padding entirely." : ""))
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            modeNotes

            Divider().padding(.vertical, 2)

            HStack {
                // The field's job changes with the mode: anchors protecting a real
                // image, versus the only description of a subject that doesn't exist yet.
                Text(currentMode?.needsContentText == true ? "Content to create" : "Content to preserve")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                // Detect still reads the file even in text-only mode — that's the
                // intended way to get a starting description you can then edit.
                Button(identityBusy ? "Detecting…" : "Detect") { detectIdentity(force: true) }
                    .font(.caption).disabled(identityBusy || current == nil)
            }
            // TextEditor, not TextField: a vertical TextField clips at its line limit with
            // no way to reach the rest — the only way to read a long description was to
            // select the text and drag. A TextEditor scrolls.
            TextEditor(text: identityBinding)
                .font(.system(size: 11))
                .frame(height: 52)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                .disabled(current == nil)
            Text("Per image — auto-detected when you select it, and again for each image as a batch runs. Covers backgrounds, UI and multi-symbol art boards, not just characters. Edit freely, then Regenerate.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            if currentMode?.needsContentText == true,
               (current?.identity ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                Label("Nothing to generate from — this image isn't being sent, so this description is the only subject. Press Detect, or type one.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if !contentStyleLeaks.isEmpty {
                Label("Describes style (\(contentStyleLeaks.joined(separator: ", "))) — this field is for WHAT is in the image; style words here fight the new look.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                // "Notes (optional)" only holds while a reference image is actually
                // being sent — untick that box and this field IS the style, so calling
                // it optional would be a lie the run then fails on.
                Text(referenceInPlay ? "Style notes (optional)" : "Style / desired change")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                // Analyze stays available with the box unticked on purpose: reading a
                // reference INTO this field is how you get editable style text to
                // generate from without sending the image.
                if reference != nil {
                    Button(styleBusy ? "Analyzing…" : "Analyze") { analyzeReferenceStyle() }
                        .font(.caption).disabled(styleBusy)
                        .help("Read this reference's style into the text below — editable, and usable with the image itself switched off")
                }
            }
            TextEditor(text: $styleText)
                .font(.system(size: 11))
                .frame(height: 76)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            if styleText.isEmpty {
                Text(referenceInPlay ? "Optional — the reference image drives the look."
                                     : "e.g. warm illustrated colors, thick outlines")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if !leaks.isEmpty {
                Label("Mentions \(leaks.joined(separator: ", ")) — make sure that's about the STYLE, not the character.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            TextField("Extra direction (optional)", text: $extra)

            if !failure.isEmpty {
                Text(failure).font(.caption2).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).lineLimit(3)
            }
            if !progress.isEmpty {
                Text(progress).font(.caption2).foregroundStyle(.secondary)
            } else if !status.isEmpty {
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }

            Spacer()
            HStack {
                Text(costHint).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if batchRunning {
                    Button("Stop") { cancelRequested = true }.keyboardShortcut(.cancelAction)
                } else {
                    if batchCount > 1 {
                        Picker("Parallel", selection: $parallelism) {
                            ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)×").tag($0) }
                        }.frame(width: 130).help("How many images restyle at once during Restyle All")
                    }
                    Button("Close") { onClose() }.keyboardShortcut(.cancelAction).disabled(anyRunning)
                    Button(runLabel) { runOne() }.disabled(!canRun)
                        .help(runLabel == "Regenerate"
                              ? "Run this image again with the current settings — writes a new file, keeps the previous one"
                              : "Restyle just the selected image")
                    Button(batchLabel) { runBatch() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canRunBatch)
                }
            }
        }
    }

    /// The one caveat worth its own line: "auto" aspect means "match the source image's
    /// shape", which has no meaning for an item whose source image isn't being sent. Left
    /// as a warning rather than silently overriding the picker — quietly changing a
    /// setting someone chose is worse than telling them it won't do what they expect.
    /// (The padding caveat is folded into the padding line above instead of adding a
    /// second line here.)
    @ViewBuilder private var modeNotes: some View {
        if aspect == "auto", items.contains(where: { !$0.sendImage }) {
            Label("Aspect “auto” matches the source image's shape — with a source image withheld there's nothing to match, so pick an explicit aspect.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Per-item image toggle, written straight back into the queue item like the
    /// description field, so it survives switching away and back.
    private var sendImageBinding: Binding<Bool> {
        Binding(
            get: { current?.sendImage ?? true },
            set: { v in if let i = currentIndex { items[i].sendImage = v } }
        )
    }

    private func setAllSendImage(_ on: Bool) {
        for i in items.indices { items[i].sendImage = on }
    }

    /// Clears finished states so those items are runnable again. Deliberately does NOT
    /// touch `identity`, `sendImage` or `attempts` — the whole point of resetting is to
    /// re-run with the edits you just made, and attempts is the record of how many runs
    /// this file has had, which a reset doesn't undo.
    private func resetFinished() {
        for i in items.indices where items[i].state.isTerminal { items[i].state = .pending }
        failure = ""; status = ""
    }

    /// Editing the text field writes straight back into the selected queue item, so a
    /// hand-tuned description survives switching away and back.
    private var identityBinding: Binding<String> {
        Binding(
            get: { current?.identity ?? "" },
            set: { v in if let i = currentIndex { items[i].identity = v } }
        )
    }

    private var costHint: String {
        let per = size == "4K" ? 0.15 : (size == "2K" ? 0.10 : 0.067)
        let n = max(batchCount, 1)
        return String(format: "≈ $%.2f each · $%.2f for %d", per, per * Double(n), n)
    }

    /// Drop target for the shared style reference.
    private var referenceWell: some View {
        Group {
            if let reference { thumb2(reference) }
            else {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                    .foregroundStyle(refTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(width: 210, height: 118)
                    .overlay(
                        VStack(spacing: 3) {
                            Image(systemName: "square.and.arrow.down")
                            Text("Drag a style reference").font(.caption2)
                        }.foregroundStyle(.secondary)
                    )
            }
        }
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(refTargeted ? 0.15 : 0)))
        // dropDestination, not onDrop: the file rows publish their URL with
        // .draggable (Transferable), and pairing that with the older NSItemProvider
        // onDrop API silently accepts nothing.
        .dropDestination(for: URL.self) { urls, _ in
            SpringLoader.shared.noteDrop()   // a completed drag must not spring back — see the sidebar
            guard let url = urls.first(where: { isImageFile($0) }) else { return false }
            reference = url
            analyzeReferenceStyle()
            return true
        } isTargeted: { refTargeted = $0 }
    }

    private func thumb2(_ url: URL) -> some View {
        Group {
            if let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
            }
        }
        .frame(width: 210, height: 118)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.15)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Queue editing

    private func addImages() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = true
        p.prompt = "Add to Batch"
        if p.runModal() == .OK { addURLs(p.urls) }
    }

    private func addURLs(_ urls: [URL]) {
        let existing = Set(items.map { $0.url.standardizedFileURL.path })
        // Skip this feature's own outputs, so re-running a folder doesn't restyle the
        // restyles — same rule the other batch actions use.
        let fresh = urls.filter {
            isImageFile($0)
            && !existing.contains($0.standardizedFileURL.path)
            && !PathRules.isOwnOutput($0, suffix: "_restyled")
        }
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh.map { RestyleItem(url: $0) })
        if selected == nil { selected = items.first?.id }
    }

    private func removeSelected() {
        guard let i = currentIndex else { return }
        items.remove(at: i)
        selected = items.indices.contains(i) ? items[i].id : items.last?.id
    }

    // MARK: - Vision reads

    /// Auto-detect the selected image's identity. Skips when it already has text so
    /// switching between images doesn't wipe hand-edits; `force` is the Detect button.
    private func detectIdentity(force: Bool = false) {
        guard let idx = currentIndex, !batchRunning else { return }
        if !force, !items[idx].identity.isEmpty { return }
        let url = items[idx].url
        identityBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let text = downscaledPNG(url).flatMap { analyzeIdentity(sourcePNG: $0).text }
            DispatchQueue.main.async {
                identityBusy = false
                // The selection may have moved while the call was in flight — write
                // back by URL, not by the index captured earlier.
                guard let i = items.firstIndex(where: { $0.url == url }), let text else { return }
                if force || items[i].identity.isEmpty { items[i].identity = text }
            }
        }
    }

    private func analyzeReferenceStyle() {
        guard let reference, let png = downscaledPNG(reference) else { return }
        styleBusy = true; failure = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let r = analyzeStyle(referencePNG: png)
            DispatchQueue.main.async {
                styleBusy = false
                if let t = r.text { styleText = t } else { failure = r.error ?? "Style analysis failed." }
            }
        }
    }

    private func pickReference() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = false
        p.prompt = "Use as Style Reference"
        if p.runModal() == .OK, let u = p.url { reference = u; analyzeReferenceStyle() }
    }

    // MARK: - Running

    /// Everything one restyle needs, captured on the main thread so the worker never
    /// touches @State.
    private struct Job {
        let url: URL
        let identity: String
        let prompt: String
        let mode: RestyleInputMode
        let refPNG: Data?
        let flag: String, aspect: String, size: String
        let padColor: NSColor?, padSuffix: String
    }

    private func makeJob(for item: RestyleItem, identity: String) -> Job {
        let m = mode(for: item)
        let prompt = RestyleRules.prompt(mode: m, contents: identity, styleText: styleText, extra: extra)
        // Padding is resolved to nil here rather than checked again in perform(): with no
        // source image being sent there is nothing to pad, and a nil padColor is already
        // how perform() spells "don't pad". One decision, one place.
        let c = (padOn && m.padApplies) ? aiPrepColors.first(where: { $0.name == padColor }) : nil
        return Job(url: item.url, identity: identity, prompt: prompt, mode: m,
                   refPNG: m.sendsReference ? reference.flatMap { try? Data(contentsOf: $0) } : nil,
                   flag: modelFlag, aspect: aspect, size: size,
                   padColor: c?.color, padSuffix: c?.suffix ?? "")
    }

    /// One item, start to finish, on a background queue. Pads only when the image
    /// actually needs it, retries transient Vertex failures, and never writes the
    /// padded temp file anywhere near the user's folder.
    private func perform(_ job: Job) -> (saved: URL?, cost: Double?, error: String?) {
        var send = job.url
        let needsPad = job.padColor != nil
            && (hasTransparency(job.url)
                || (imagePixelSize(job.url).map { RestyleRules.needsPadding(width: $0.w, height: $0.h) } ?? false))
        if needsPad, let c = job.padColor {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("navigator-restyle-pad-\(UUID().uuidString).png")
            if let padded = fillBackgroundForImage(job.url, color: c, suffix: job.padSuffix,
                                                   ratio: job.aspect == "auto" ? nil : RestyleRules.ratio(job.aspect),
                                                   dest: tmp) {
                send = padded
            }
        }
        defer { if send != job.url { try? FileManager.default.removeItem(at: send) } }

        // Vertex 503s under load are common enough that a batch would otherwise
        // abandon its queue over a condition that clears in seconds.
        var last: (URL?, Double?, String?) = (nil, nil, "not attempted")
        for attempt in 0..<3 {
            if cancelRequested { return (nil, nil, "Cancelled") }
            let r = runRestyle(source: send, prompt: job.prompt, modelFlag: job.flag,
                               aspect: job.aspect, size: job.size,
                               styleReferencePNG: job.refPNG, nameAfter: job.url,
                               identity: job.identity,
                               sendSourceImage: job.mode.sendsSource, modeLabel: job.mode.label)
            if r.saved != nil { return r }
            last = (r.saved, r.cost, r.error)
            guard let e = r.error, RestyleRules.isTransient(e), attempt < 2 else { break }
            Thread.sleep(forTimeInterval: Double(attempt + 1) * 4)
        }
        return last
    }

    /// Restyle — or, if this item already finished, re-run it. A re-run is the same code
    /// path deliberately: the only difference is that the previous result's file is left
    /// alone (uniqueDest gives the new one "_restyled 2.png"), so nothing you already
    /// generated is ever overwritten by trying again.
    private func runOne() {
        guard let idx = currentIndex else { return }
        let item = items[idx]
        let job = makeJob(for: item, identity: item.identity)
        let again = item.state.isTerminal
        busy = true; failure = ""
        status = (again ? "Regenerating " : "Restyling ") + "\(item.url.lastPathComponent)…"
        items[idx].attempts += 1
        items[idx].state = .running
        DispatchQueue.global(qos: .userInitiated).async {
            let r = perform(job)
            DispatchQueue.main.async {
                busy = false; status = ""
                guard let i = items.firstIndex(where: { $0.url == job.url }) else { return }
                if let saved = r.saved {
                    if let c = r.cost { navLog("restyle cost $\(String(format: "%.4f", c)) [\(job.mode.label)] -> \(saved.lastPathComponent)") }
                    items[i].state = .done(saved)
                    onFinished(saved)
                } else {
                    items[i].state = .failed(r.error ?? "Restyle failed.")
                    failure = r.error ?? "Restyle failed."
                }
            }
        }
    }

    /// Runs the whole queue with up to `parallelism` restyles in flight at once. Each
    /// image gets its own identity read first (unless it already has one), then its
    /// own restyle. One failure marks that item and moves on rather than stopping the
    /// run — a 20-image batch shouldn't die on image 3.
    ///
    /// Every `items[...]`, `completed`, `failed` and `totalCost` touch happens inside a
    /// `DispatchQueue.main.async` block, even though several workers are running at
    /// once — main is a single serial queue, so these can never actually collide with
    /// each other no matter how many workers schedule them concurrently. A worker's
    /// OWN copy of the item it was handed (captured once, before any of this starts)
    /// is what it reads for the source URL and starting identity, so it never reads
    /// the live @State array off-main while another worker might be writing it.
    ///
    /// With several running at once there's no single "the current image" to follow,
    /// so — unlike the one-at-a-time version this replaced — nothing forces the
    /// selection to chase a particular row. Every active row is already called out by
    /// its own highlighted, bold state in the list; that's the "what's happening now"
    /// signal now, not the preview pane.
    /// When every item has already finished, this is a regenerate-all: the finished
    /// states are cleared first so the same machinery picks them all up again. Reading
    /// `items` right after mutating it is safe — a @State write is visible to later reads
    /// in the same call; it's only the re-render that's deferred.
    private func runBatch() {
        if batchIsRegenerate { resetFinished() }
        let queued = items.filter { !$0.state.isTerminal }
        guard !queued.isEmpty else { return }
        batchRunning = true; cancelRequested = false; failure = ""
        let total = queued.count
        var completed = 0, failed = 0
        var totalCost = 0.0
        let group = DispatchGroup()
        // Bounds actual concurrent restyles; queued-but-not-yet-started workers just
        // block here rather than doing any work, so nothing beyond `parallelism` items
        // is ever really in flight even though all of them are dispatched up front.
        let gate = DispatchSemaphore(value: parallelism)

        for item in queued {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                gate.wait()
                defer { gate.signal(); group.leave() }
                if cancelRequested {
                    DispatchQueue.main.async {
                        if let i = items.firstIndex(where: { $0.url == item.url }) { items[i].state = .pending }
                    }
                    return
                }

                let hadIdentity = !item.identity.isEmpty
                DispatchQueue.main.async {
                    if let i = items.firstIndex(where: { $0.url == item.url }) {
                        items[i].attempts += 1
                        items[i].state = hadIdentity ? .running : .detecting
                    }
                }

                var identity = item.identity
                if identity.isEmpty, let png = downscaledPNG(item.url) {
                    identity = analyzeIdentity(sourcePNG: png).text ?? ""
                    let captured = identity
                    DispatchQueue.main.async {
                        if let i = items.firstIndex(where: { $0.url == item.url }) {
                            items[i].identity = captured
                            items[i].state = .running
                        }
                    }
                }

                // A text-only item with no description has nothing to draw — the vision
                // read above is its only chance, and if that failed too, generating
                // anyway would return an unrelated image and bill for it. Fail loudly
                // instead, with the fix in the message. (canRunBatch can't catch this:
                // the description may legitimately arrive between the click and here.)
                if !item.sendImage, identity.trimmingCharacters(in: .whitespaces).isEmpty {
                    DispatchQueue.main.async {
                        failed += 1
                        if let i = items.firstIndex(where: { $0.url == item.url }) {
                            items[i].state = .failed("No content description, and this image isn't being sent — nothing to generate from. Select it, press Detect or type a description, then Regenerate.")
                        }
                        let running = min(parallelism, total - completed - failed)
                        progress = "\(completed + failed) of \(total) done · \(running) running"
                    }
                    return
                }

                // makeJob reads shared @State (style text, reference, model…), none of
                // which changes mid-batch, so it's read once on main and handed to this
                // worker as a plain value from here on.
                var job: Job!
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { job = makeJob(for: item, identity: identity); sem.signal() }
                sem.wait()

                let r = perform(job)

                DispatchQueue.main.async {
                    if r.saved != nil { completed += 1 } else { failed += 1 }
                    if let c = r.cost { totalCost += c }
                    guard let i = items.firstIndex(where: { $0.url == item.url }) else { return }
                    if let saved = r.saved {
                        items[i].state = .done(saved)
                        onFinished(saved)
                    } else {
                        items[i].state = .failed(r.error ?? "Restyle failed.")
                    }
                    let running = min(parallelism, total - completed - failed)
                    progress = "\(completed + failed) of \(total) done · \(running) running"
                }
            }
        }

        group.notify(queue: .main) {
            batchRunning = false
            progress = ""
            var parts = ["Restyled \(completed)"]
            if failed > 0 { parts.append("\(failed) failed") }
            if cancelRequested { parts.append("stopped early") }
            status = parts.joined(separator: " · ") + String(format: " · $%.2f", totalCost)
            navLog("restyle batch: \(completed) ok, \(failed) failed, $\(String(format: "%.4f", totalCost))")
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

final class RestyleController {
    private static var windows: [NSWindow] = []
    static func show(sources: [URL], onFinished: @escaping (URL) -> Void) {
        guard !sources.isEmpty else { return }
        // .resizable so the panel is never a trap: it grows conditional warning lines,
        // and long descriptions/style text make the ideal height genuinely variable.
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        // Matches the sheet's own minWidth/minHeight. Without this, "resizable" would let
        // someone shrink the window past what the content can compress to and clip the
        // buttons — resizable has to mean bigger-only here, since there's no scroll view.
        w.minSize = NSSize(width: 900, height: 720)
        w.title = sources.count == 1
            ? "Restyle — \(sources[0].lastPathComponent)"
            : "Restyle — \(sources.count) images"
        w.contentView = NSHostingView(rootView: RestyleSheet(sources: sources, onFinished: onFinished,
                                                            onClose: { [weak w] in w?.close() }))
        w.center(); windows.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            windows.removeAll { $0 === w }
        }
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
