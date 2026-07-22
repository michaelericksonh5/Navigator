import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Quartz
import QuickLookThumbnailing
import CoreServices
import NetFS

extension Notification.Name {
    static let navigatorDidNavigate = Notification.Name("navigatorDidNavigate")
    static let navigatorFocusSearch = Notification.Name("navigatorFocusSearch")
}

enum ViewMode: String { case list, icon, gallery, column }
enum ConflictPolicy { case keepBoth, replace, skip }

final class TransferProgress: ObservableObject {
    @Published var fraction: Double = 0
    @Published var current: String = ""
    @Published var cancelled = false
}

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

struct SizeCell: View {
    let item: FileItem
    @ObservedObject private var cache = FolderSizeCache.shared
    var body: some View {
        if item.isDirectory {
            if let s = cache.cached(item.url) {
                Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)).foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        } else if item.modified == .distantPast {
            // Network item whose size hasn't been fetched yet (see Browser.lightItem).
            Text("—").foregroundStyle(.tertiary)
        } else {
            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).foregroundStyle(.secondary)
        }
    }
}

// Renders a date column, showing a placeholder while a network item's metadata
// is still being fetched in the background (sentinel = .distantPast).
struct DateCell: View {
    let date: Date
    var body: some View {
        if date == .distantPast { Text("—").foregroundStyle(.tertiary) }
        else { Text(date, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary) }
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
    static var columnData: Data? { get { d.data(forKey: "columnCustomization") } set { d.set(newValue, forKey: "columnCustomization") } }
    static var recentFolders: [String] { get { d.stringArray(forKey: "recentFolders") ?? [] } set { d.set(newValue, forKey: "recentFolders") } }
    static var confirmTrash: Bool {
        get { d.object(forKey: "confirmTrash") == nil ? true : d.bool(forKey: "confirmTrash") }
        set { d.set(newValue, forKey: "confirmTrash") }
    }
    static var thumbnailMode: String { get { d.string(forKey: "thumbnailMode") ?? "all" } set { d.set(newValue, forKey: "thumbnailMode") } }  // all | images | off
    static var didOfferDefaults: Bool { get { d.bool(forKey: "didOfferDefaults") } set { d.set(newValue, forKey: "didOfferDefaults") } }
    static var lastUpdateCheck: Double { get { d.double(forKey: "lastUpdateCheck") } set { d.set(newValue, forKey: "lastUpdateCheck") } }
    static var skipUpdateVersion: String { get { d.string(forKey: "skipUpdateVersion") ?? "" } set { d.set(newValue, forKey: "skipUpdateVersion") } }
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

// MARK: - Undo stack (file operations)

final class UndoStack {
    static let shared = UndoStack()
    private var stack: [(desc: String, action: () -> Void)] = []
    var canUndo: Bool { !stack.isEmpty }
    var topDescription: String? { stack.last?.desc }
    func push(_ desc: String, _ action: @escaping () -> Void) {
        stack.append((desc, action))
        if stack.count > 50 { stack.removeFirst() }
    }
    func undo() {
        guard let entry = stack.popLast() else { NSSound.beep(); return }
        entry.action()
    }
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
// QLThumbnailGenerator produces a right-sized preview cheaply and supports many
// formats beyond plain images — PSD, PDF, AI, RAW — via the system's thumbnail
// generators (and its own on-disk cache). Non-thumbnailable files return nil so
// callers fall back to the file-type icon. Cache is keyed by path+size so the
// small list-view thumbnail and the large preview don't clobber each other.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
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
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                               scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            let img = rep?.nsImage
            if let img { self?.cache.setObject(img, forKey: key) }
            DispatchQueue.main.async { completion(img) }
        }
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

    static func == (l: FileItem, r: FileItem) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// Persists network directory listings across launches so the FIRST open of a
// network folder in a new session paints instantly (then refreshes in the
// background). Local folders enumerate fast enough to skip. Capped, evicts
// oldest. Main-thread access only; disk writes are async-snapshotted.
enum DiskCache {
    private struct Entry: Codable { let items: [FileItem]; let savedAt: Date }
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
    static func put(_ key: String, _ items: [FileItem]) {
        guard items.count <= maxItemsPerFolder else { return }
        store[key] = Entry(items: items, savedAt: Date())
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
}

// Surfaces a file-operation failure instead of failing silently. Must be called
// on the main thread.
func reportFileError(_ summary: String, _ detail: String = "") {
    let a = NSAlert(); a.alertStyle = .warning
    a.messageText = summary
    var msg = detail
    if !msg.isEmpty { msg += "\n\n" }
    msg += "Items in protected folders (Desktop, Documents, Pictures, Downloads) or on read-only volumes can need Navigator to have Full Disk Access — see the Navigator menu → “Grant Full Disk Access…”."
    a.informativeText = msg
    a.addButton(withTitle: "OK"); a.runModal()
}

// Shared dialogs / actions usable from menus and context menus.
func promptRename(_ browser: Browser, _ id: String) {
    guard let item = browser.items.first(where: { $0.id == id }) else { return }
    let a = NSAlert(); a.messageText = "Rename"; a.informativeText = "Enter a new name:"
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); f.stringValue = item.name
    a.accessoryView = f; a.addButton(withTitle: "Rename"); a.addButton(withTitle: "Cancel")
    if a.runModal() == .alertFirstButtonReturn { browser.rename(id: id, to: f.stringValue) }
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
    guard !ids.isEmpty else { return }
    if ids.count == 1, let it = browser.items.first(where: { $0.id == ids.first }) {
        GetInfoController.shared.show(browser, it)
    } else {
        let a = NSAlert(); a.messageText = "Get Info"; a.informativeText = browser.infoText(ids)
        a.addButton(withTitle: "OK"); a.runModal()
    }
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
// The installed Google Drive app's own icon, for the Drive context-menu items
// (mirrors how Finder badges its Quick Actions). Loaded once.
enum GoogleDriveIcon {
    static let image: NSImage = NSWorkspace.shared.icon(forFile: "/Applications/Google Drive.app")
}
// A context-menu label badged with the Google Drive app icon.
@ViewBuilder func gdLabel(_ title: String) -> some View {
    Label {
        Text(title)
    } icon: {
        Image(nsImage: GoogleDriveIcon.image).resizable().frame(width: 13, height: 13)
    }.labelStyle(.titleAndIcon)
}

func confirmEmptyTrash(_ browser: Browser) {
    let a = NSAlert(); a.alertStyle = .warning
    a.messageText = "Empty the Trash?"
    a.informativeText = "Items in the Trash will be permanently deleted. This can't be undone."
    a.addButton(withTitle: "Empty Trash"); a.addButton(withTitle: "Cancel")
    if a.runModal() == .alertFirstButtonReturn { browser.emptyTrash() }
}
func openItem(_ item: FileItem, _ browser: Browser) {
    if item.isDirectory { browser.navigate(to: item.url); return }
    if isImageFile(item.url) {
        // Use the on-screen order (current sort/filter), so ←/→ in the viewer
        // matches what the user sees in the folder — not the raw load order.
        let imgs = browser.orderedVisibleItems().filter { !$0.isDirectory && isImageFile($0.url) }.map { $0.url }
        ImageViewerController.shared.show(urls: imgs, index: imgs.firstIndex(of: item.url) ?? 0)
        return
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
    func add(_ url: URL, label: String? = nil, mountURL: String? = nil) {
        let s = url.standardizedFileURL
        if label == nil, contains(s) { return }   // dedupe plain drag-adds; named drives may share a path
        items.append(Favorite(label: label ?? favoriteName(s), path: s.path, mountURL: mountURL)); persist()
    }
    // Drag-to-reorder from the sidebar. Home always snaps back to the top so it
    // stays the fixed anchor, regardless of where it's dropped.
    func move(fromOffsets: IndexSet, toOffset: Int) {
        items.move(fromOffsets: fromOffsets, toOffset: toOffset)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let hi = items.firstIndex(where: { $0.path == home }), hi != 0 {
            items.insert(items.remove(at: hi), at: 0)
        }
        persist()
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

let imageExtensions: Set<String> = ["jpg","jpeg","png","gif","bmp","tiff","tif","heic","heif","webp","ico"]
func isImageFile(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }

let videoExtensions: Set<String> = ["mp4","mov","m4v","avi","mkv","webm","wmv","flv","mpg","mpeg","3gp","m2ts","mts","m2v","ts"]
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
        let ejectable = ((rv?.volumeIsEjectable ?? false) || (rv?.volumeIsRemovable ?? false)) && !isRoot
        let sym = isRoot ? "internaldrive" : (isLocal ? "externaldrive" : "network")
        out.append(.init(name: name, url: url, symbol: sym, ejectable: ejectable))
    }
    return out
}

// MARK: - Browser state (one per tab)

final class Browser: ObservableObject, Identifiable {
    let id = UUID()
    @Published var currentURL: URL
    @Published var items: [FileItem] = []
    @Published var selection: Set<String> = []
    @Published var pathText: String = ""
    @Published var filterText: String = ""
    @Published var searchText: String = ""
    @Published var isSearching = false
    @Published var searchThisMac = false
    @Published var searchKind: SearchKind = .any
    @Published var showHidden = false { didSet { Prefs.showHidden = showHidden; load() } }
    @Published var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\FileItem.name, order: .forward)] {
        didSet {
            for f in SortField.allCases {
                for asc in [true, false] where sortOrder.first == Browser.comparator(for: f, ascending: asc) {
                    Prefs.sortKey = f.rawValue; Prefs.sortAscending = asc; return
                }
            }
        }
    }
    @Published var groupBy: GroupBy = .none { didSet { Prefs.groupBy = groupBy.rawValue } }
    @Published var status: String = ""
    @Published var freeSpace: String = ""
    @Published var isRecents = false
    @Published var viewMode: ViewMode = .list { didSet { Prefs.viewMode = viewMode.rawValue } }
    @Published var iconSize: CGFloat = 76 { didSet { Prefs.iconSize = iconSize } }
    @Published var gridColumns = 1
    @Published var keyboardScrollID: String?
    @Published var busy = false
    @Published var busyText = ""

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var recentsQuery: NSMetadataQuery?
    private var searchQuery: NSMetadataQuery?
    private var typeBuffer = ""
    private var lastTypeAt = Date.distantPast
    private let fm = FileManager.default

    init(start: URL) {
        currentURL = start
        pathText = googleDrivePortablePath(start) ?? start.path
        showHidden = Prefs.showHidden
        viewMode = ViewMode(rawValue: Prefs.viewMode) ?? .list
        iconSize = Prefs.iconSize
        groupBy = GroupBy(rawValue: Prefs.groupBy) ?? .none
        sortOrder = [Browser.comparator(for: SortField(rawValue: Prefs.sortKey) ?? .name, ascending: Prefs.sortAscending)]
        load()
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

    // ⌘ + scroll wheel changes the view size, Windows 11-style: a continuum from
    // Details → Columns → Icons, and within Icons a smooth resize (small → extra
    // large). Icon sizing is continuous (real-time micro-adjustments); crossing a
    // view boundary needs a bit of accumulated scroll so one flick doesn't skip
    // through everything. dy > 0 = larger. minIcon 44 ≈ "small", 256 ≈ "extra large".
    static let minIconSize: CGFloat = 44
    static let maxIconSize: CGFloat = 256
    private var scrollAccum: CGFloat = 0
    func adjustViewScale(_ dy: CGFloat) {
        if viewMode == .icon {
            let proposed = iconSize + dy * 1.4
            if proposed < Browser.minIconSize {          // shrinking past the smallest icons
                scrollAccum += dy
                if scrollAccum <= -6 { viewMode = .column; scrollAccum = 0 }
            } else {
                iconSize = min(Browser.maxIconSize, proposed); scrollAccum = 0
            }
        } else {
            scrollAccum += dy
            if scrollAccum >= 6 {                          // grow
                scrollAccum = 0
                switch viewMode {
                case .list: viewMode = .column
                case .column: viewMode = .icon; iconSize = Browser.minIconSize
                default: break
                }
            } else if scrollAccum <= -6 {                  // shrink
                scrollAccum = 0
                switch viewMode {
                case .gallery: viewMode = .icon; iconSize = Browser.maxIconSize
                case .column: viewMode = .list
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

    // Fast directory read for slow (network/SMB) volumes. POSIX readdir returns
    // names AND the directory bit (d_type) from a single batched server response
    // — ~0.7s for hundreds of entries. Foundation's enumerator, by contrast,
    // stats every entry up front (~1 round-trip/file ≈ 86ms each over VPN),
    // which is why a 600-item network folder "hangs" for a minute in Finder.
    // Size/dates are filled in lazily afterward (see loadNetwork).
    static func fastNames(_ dir: URL, showHidden: Bool) -> [(url: URL, isDir: Bool)] {
        guard let dp = opendir(dir.path) else { return [] }
        defer { closedir(dp) }
        var out: [(URL, Bool)] = []
        while let ep = readdir(dp) {
            var e = ep.pointee
            let name = withUnsafeBytes(of: &e.d_name) { raw -> String in
                raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? ""
            }
            if name.isEmpty || name == "." || name == ".." { continue }
            if !showHidden && name.hasPrefix(".") { continue }
            var isDir = Int32(e.d_type) == Int32(DT_DIR)
            if Int32(e.d_type) == Int32(DT_UNKNOWN) {   // rare: server didn't return a type → one stat
                var st = stat()
                if lstat(dir.path + "/" + name, &st) == 0 { isDir = (st.st_mode & S_IFMT) == S_IFDIR }
            }
            out.append((dir.appendingPathComponent(name, isDirectory: isDir), isDir))
        }
        return out
    }

    // A FileItem with just name + directory bit (no size/date I/O). The
    // .distantPast dates are a sentinel meaning "not fetched yet"; the Size/Date
    // cells render a placeholder for it until loadNetwork's enrich pass fills in.
    static func lightItem(url u: URL, isDir: Bool) -> FileItem {
        FileItem(id: u.path, url: u, name: u.lastPathComponent,
                 isDirectory: isDir, size: 0,
                 modified: .distantPast, created: .distantPast,
                 accessed: .distantPast, dateAdded: .distantPast,
                 kind: localKind(u, isDir: isDir), tags: [])
    }

    // The view order: sort, folders-first, then name filter.
    func visibleItems() -> [FileItem] {
        let sorted = items.sorted(using: sortOrder)
        let combined = sorted.filter { $0.isDirectory } + sorted.filter { !$0.isDirectory }
        if filterText.isEmpty { return combined }
        return combined.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
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
    func orderedVisibleItems() -> [FileItem] { groupBy == .none ? visibleItems() : groups().flatMap { $0.items } }

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
        guard !query.isEmpty else { clearSearch(); return }
        isSearching = true
        dirWatcher.stop()
        selection = []
        items = []
        status = "Searching…"
        searchQuery?.stop()
        let q = NSMetadataQuery()
        q.searchScopes = searchThisMac ? [NSMetadataQueryLocalComputerScope] : [currentURL]
        var subs = [NSPredicate(format: "kMDItemDisplayName LIKE[cd] %@ OR kMDItemTextContent CONTAINS[cd] %@", "*\(query)*", query)]
        if let tree = searchKind.typeTree { subs.append(NSPredicate(format: "kMDItemContentTypeTree == %@", tree)) }
        q.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: subs)
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemFSName", ascending: true)]
        NotificationCenter.default.addObserver(self, selector: #selector(searchGathered(_:)),
                                               name: .NSMetadataQueryDidFinishGathering, object: q)
        searchQuery = q
        q.start()
    }
    @objc private func searchGathered(_ note: Notification) {
        guard let q = searchQuery else { return }
        q.disableUpdates()
        var result: [FileItem] = []
        let n = min(q.resultCount, 500)
        for i in 0..<n {
            guard let mi = q.result(at: i) as? NSMetadataItem,
                  let path = mi.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            result.append(makeItem(URL(fileURLWithPath: path)))
        }
        items = result
        updateStatus()
        q.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: q)
        searchQuery = nil
    }
    func clearSearch() {
        searchQuery?.stop(); searchQuery = nil
        searchText = ""; isSearching = false
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
    func silentRefresh() {
        guard !isSearching, !isRecents, !currentIsNetwork else { return }
        let dir = currentURL, sh = showHidden
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
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.loadGeneration else { return }
                Browser.dirCache[cacheKey] = final
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
        if isSearching { runSearch() } else { load() }
    }

    // Directory enumeration (and its per-file attribute fetches) runs on a
    // background queue — over SMB/VPN it can take a while, and doing it on the
    // main thread would freeze the UI. Results are applied on the main thread,
    // and stale loads (superseded by a newer navigation) are discarded.
    func load() {
        isRecents = false
        isSearching = false
        pathText = addressString(for: currentURL)
        selection = []
        let dir = currentURL
        let isNetwork = ((try? dir.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false)
        currentIsNetwork = isNetwork
        if isNetwork { dirWatcher.stop() } else { dirWatcher.watch(dir) }   // auto-refresh local folders
        loadGeneration += 1
        let gen = loadGeneration
        let cacheKey = dir.path + (showHidden ? "\u{1}h" : "")
        // Show cached contents instantly on revisit; still refresh in the background.
        let cached = Browser.dirCache[cacheKey]
        // Disk cache seeds only network folders (local is already instant).
        let seed = cached ?? (isNetwork ? DiskCache.get(cacheKey) : nil)
        if let seed {
            items = seed
            busy = false; busyText = ""
            updateFreeSpace(); updateStatus()
        } else {
            items = []            // clear stale previous-folder contents; the load fills it in
            busy = true; busyText = "Loading…"
            updateStatus()
        }
        let hadSeed = seed != nil
        if isNetwork { loadNetwork(dir, gen: gen, cacheKey: cacheKey, hadSeed: hadSeed) }
        else { loadLocal(dir, gen: gen, cacheKey: cacheKey, hadCache: cached != nil) }
    }

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
            while let u = en?.nextObject() as? URL {
                guard let self, gen == self.loadGeneration else { return }
                result.append(Browser.item(from: u, try? u.resourceValues(forKeys: Set(keys))))
                sinceFlush += 1
                if !hadCache, sinceFlush >= 200 {
                    sinceFlush = 0
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
    private func loadNetwork(_ dir: URL, gen: Int, cacheKey: String, hadSeed: Bool = false) {
        let showHidden = self.showHidden
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var names = Browser.fastNames(dir, showHidden: showHidden)
            // DFS junctions auto-mount on first access and can read empty; retry once.
            if names.isEmpty {
                Thread.sleep(forTimeInterval: 1.5)
                guard let self, gen == self.loadGeneration else { return }
                names = Browser.fastNames(dir, showHidden: showHidden)
            }
            // Folders first, then by name, so the top of the list — what the user
            // sees and what we enrich first — is stable and Finder-like.
            names.sort { a, b in
                if a.isDir != b.isDir { return a.isDir }
                return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            }
            var enriched = names.map { Browser.lightItem(url: $0.url, isDir: $0.isDir) }
            guard let self, gen == self.loadGeneration else { return }
            let light = enriched
            // Skip the names-only repaint if a full-detail seed is already on screen
            // — it would blank out sizes/dates until Phase 2 refills them.
            if !hadSeed {
                DispatchQueue.main.async { [weak self] in
                    guard let self, gen == self.loadGeneration else { return }
                    self.items = light                   // instant: names + folder icons
                    self.busy = false; self.busyText = ""
                    self.updateFreeSpace(); self.updateStatus()
                }
            }
            // Phase 2 — fetch size + dates. Each is a separate SMB round-trip
            // (~90ms over VPN); done serially a 600-item folder stalls ~a minute.
            // Run them IN PARALLEL — they're I/O-bound, so GCD keeps many in flight
            // and the wall-clock drops ~10x. Each iteration writes only its own
            // index, so no locking. (ponytail: GCD pool ~= cores+blocked; widen with
            // an explicit semaphore pool only if this still isn't fast enough.)
            let enrichKeys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .creationDateKey]
            enriched.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: buf.count) { i in
                    guard gen == self.loadGeneration,
                          let rv = try? buf[i].url.resourceValues(forKeys: enrichKeys) else { return }
                    let u = buf[i].url, m = rv.contentModificationDate ?? Date()
                    buf[i] = FileItem(id: u.path, url: u, name: u.lastPathComponent,
                                      isDirectory: buf[i].isDirectory, size: Int64(rv.fileSize ?? 0),
                                      modified: m, created: rv.creationDate ?? m,
                                      accessed: m, dateAdded: m, kind: buf[i].kind, tags: [])
                }
            }
            guard gen == self.loadGeneration else { return }
            let committed = enriched
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.loadGeneration else { return }
                // A transient empty read (folder briefly unreachable) must not wipe a
                // seed we're already showing, nor overwrite the persisted cache.
                if committed.isEmpty && hadSeed { return }
                Browser.dirCache[cacheKey] = committed
                if !committed.isEmpty { DiskCache.put(cacheKey, committed) }   // persist for instant first-open next session
                self.items = committed; self.updateStatus()
            }
        }
    }

    func updateFreeSpace() {
        let vals = try? currentURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        if let avail = vals?.volumeAvailableCapacityForImportantUsage, avail > 0 {
            freeSpace = "\(ByteCountFormatter.string(fromByteCount: avail, countStyle: .file)) available"
        } else if let avail = vals?.volumeAvailableCapacity, let total = vals?.volumeTotalCapacity, total > 0 {
            freeSpace = "\(ByteCountFormatter.string(fromByteCount: Int64(avail), countStyle: .file)) available"
        } else {
            freeSpace = ""
        }
    }

    // Click selection with modifiers, like Finder/Explorer:
    //  • plain click → select just this item (and set the range anchor)
    //  • ⌘-click → toggle this item in/out of the selection
    //  • ⇧-click → select the range from the anchor to this item
    var selectionAnchor: String?
    func click(_ id: String, modifiers: NSEvent.ModifierFlags) {
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
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { NSSound.beep(); return }
        if recordHistory { backStack.append(currentURL); forwardStack.removeAll() }
        searchText = ""; isSearching = false; searchQuery?.stop(); searchQuery = nil
        currentURL = url
        load()
        // NOTE: navigating does NOT record a recent folder — "Recent Folders" is
        // only folders you've worked in (created/saved/moved/renamed files).
        NotificationCenter.default.post(name: .navigatorDidNavigate, object: nil)
    }

    // Navigate to a sidebar favorite. For a network drive whose volume isn't
    // mounted (e.g. after a reboot or VPN reconnect), mount it directly via
    // NetFS — NOT NSWorkspace.open(smb://…), which hands the mount to Finder and
    // pops Finder's "Connecting to…" window. NetFSMountURLSync mounts silently to
    // /Volumes using keychain creds (its own auth sheet only if none are stored)
    // and returns the real mountpoint, so no polling/guessing is needed.
    func openFavorite(_ path: String, mountURL: String?) {
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
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 2, parts[0] == "Volumes" else { return "" }
        return parts.dropFirst(2).joined(separator: "/")
    }
    // Mount an SMB/AFP URL directly, without Finder. Blocking — call off the main
    // thread. Returns the real mountpoint path (nil on failure). NetFS uses stored
    // keychain creds and shows its own auth sheet only when none exist.
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
        // Resolve any Google Drive path form (a coworker's full path, the portable
        // "Google Drive/…", or a bare "Shared drives/…") onto this Mac's account.
        if !fm.fileExists(atPath: p), let resolved = Browser.resolveGoogleDrivePath(p) { p = resolved }
        let url = URL(fileURLWithPath: p)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue { navigate(to: url) } else { NSWorkspace.shared.open(url); pathText = addressString(for: currentURL) }
        } else { NSSound.beep(); pathText = addressString(for: currentURL) }
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
        let paths = items.filter { ids.contains($0.id) }.map { $0.url.path }
        let text = paths.isEmpty ? currentURL.path : paths.joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
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
    // True when the selection lives inside Google Drive (has a Drive item ID).
    func isGoogleDriveSelection(_ ids: Set<String>) -> Bool {
        guard let id = ids.first, let it = items.first(where: { $0.id == id }) else { return false }
        return googleDriveItemID(it.url) != nil
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
    // Resolve any Google Drive path form typed/pasted into the address bar onto
    // THIS Mac's Drive account: a full cross-user path from another Mac
    // (/Users/them/…/GoogleDrive-them@…/Shared drives/…), the portable
    // "Google Drive/…" form, or a bare "Shared drives/…" / "My Drive/…".
    // Returns nil if it isn't a Drive path.
    static func resolveGoogleDrivePath(_ input: String) -> String? {
        let cs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        guard let accounts = try? FileManager.default.contentsOfDirectory(atPath: cs.path),
              let local = accounts.first(where: { $0.hasPrefix("GoogleDrive-") }) else { return nil }
        var rel: String?
        if let r = input.range(of: "/CloudStorage/GoogleDrive-") {          // full path from another Mac
            let after = input[r.upperBound...]
            if let slash = after.firstIndex(of: "/") { rel = String(after[after.index(after: slash)...]) }
        } else if input.hasPrefix("Google Drive/") {                        // portable form
            rel = String(input.dropFirst("Google Drive/".count))
        } else if input.hasPrefix("Shared drives") || input.hasPrefix("My Drive") {   // drive-relative
            rel = input
        }
        guard let rel, !rel.isEmpty else { return nil }
        return cs.appendingPathComponent(local).appendingPathComponent(rel).path
    }
    func copyName(_ ids: Set<String>) {
        let names = items.filter { ids.contains($0.id) }.map { $0.name }
        guard !names.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
    }
    func moveToTrash(_ ids: Set<String>) {
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
        var restores: [(trash: URL, original: URL)] = []
        var failures: [(url: URL, reason: String)] = []
        for u in urls {
            var out: NSURL?
            do { try fm.trashItem(at: u, resultingItemURL: &out); if let t = out as URL? { restores.append((t, u)) } }
            catch { failures.append((u, error.localizedDescription)) }
        }
        if !restores.isEmpty {
            RecentFolders.shared.record(currentURL)
            UndoStack.shared.push("Move to Trash") { [weak self] in
                for r in restores { try? FileManager.default.moveItem(at: r.trash, to: r.original) }
                self?.load()
            }
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
        UndoStack.shared.push("New Folder") { [weak self] in
            try? FileManager.default.trashItem(at: target, resultingItemURL: nil); self?.load()
        }
        load()
    }
    func newTextFile() {
        let target = uniqueDest(currentURL, "New Text File.txt")
        guard fm.createFile(atPath: target.path, contents: Data()) else {
            reportFileError("Couldn't create the text file",
                            "Navigator couldn't write to “\(currentURL.lastPathComponent)”."); return
        }
        RecentFolders.shared.record(currentURL)
        UndoStack.shared.push("New Text File") { [weak self] in
            try? FileManager.default.trashItem(at: target, resultingItemURL: nil); self?.load()
        }
        load()
    }

    // File clipboard
    var cutMode = false
    // The pasteboard changeCount captured when we cut. A paste is a MOVE only if
    // the pasteboard hasn't changed since — otherwise another app (or a later
    // copy) replaced the contents and we must not move files we didn't cut.
    var cutChangeCount = -1
    private func selectedURLs() -> [URL] { items.filter { selection.contains($0.id) }.map { $0.url } }
    func copyFiles() {
        let urls = selectedURLs(); guard !urls.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(urls as [NSURL]); cutMode = false
    }
    func cutFiles() {
        let urls = selectedURLs(); guard !urls.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(urls as [NSURL])
        cutMode = true; cutChangeCount = NSPasteboard.general.changeCount
    }
    private func uniqueDest(_ dir: URL, _ name: String) -> URL {
        let fm = FileManager.default
        var dest = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: dest.path) else { return dest }
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        var i = 2
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"); i += 1
        }
        return dest
    }

    // Name for pasting a file into its own folder: "photo.jpg" -> "photo (1).jpg",
    // then "(2)", "(3)"… (Windows/Explorer-style in-place copy).
    private func numberedCopyDest(_ dir: URL, _ name: String) -> URL {
        let fm = FileManager.default
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        func make(_ n: Int) -> URL {
            dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
        }
        var i = 1, dest = make(1)
        while fm.fileExists(atPath: dest.path) { i += 1; dest = make(i) }
        return dest
    }

    // Explicit paste (⌘V / context menu). Pasting a copied item into its own
    // folder makes a numbered duplicate ("photo.jpg" -> "photo (1).jpg"); a cut
    // item pasted into its own folder is a no-op.
    func pasteFiles() {
        let urls = pasteboardURLs()
        guard !urls.isEmpty else { return }
        let isMove = cutMode && NSPasteboard.general.changeCount == cutChangeCount
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

    // Import (move or copy) dropped items into a target directory (a folder row or another tab).
    func importURLs(_ urls: [URL], into dir: URL, move: Bool) {
        let sources = urls.filter { $0.deletingLastPathComponent().path != dir.path && $0.path != dir.path }
        guard !sources.isEmpty else { return }
        performTransfer(sources, into: dir, move: move, resetCut: false)
    }

    private func performTransfer(_ sources: [URL], into dir: URL, move: Bool, resetCut: Bool) {
        let fm = FileManager.default
        // A copy whose source already lives in the destination is an in-place
        // duplicate ("paste into same folder") — it gets a numbered name silently,
        // so it's never treated as a conflict.
        func isSelfDup(_ src: URL) -> Bool { !move && src.deletingLastPathComponent().path == dir.path }
        // Resolve name conflicts up front with one prompt (applied to all).
        var policy: ConflictPolicy = .keepBoth
        let conflicts = sources.filter { !isSelfDup($0) && fm.fileExists(atPath: dir.appendingPathComponent($0.lastPathComponent).path) }
        if !conflicts.isEmpty {
            let a = NSAlert()
            a.messageText = conflicts.count == 1
                ? "“\(conflicts[0].lastPathComponent)” already exists in “\(dir.lastPathComponent)”"
                : "\(conflicts.count) items already exist in “\(dir.lastPathComponent)”"
            a.informativeText = "Choose how to handle items with the same name."
            a.addButton(withTitle: "Keep Both")
            a.addButton(withTitle: "Replace")
            a.addButton(withTitle: "Skip")
            a.addButton(withTitle: "Cancel")
            switch a.runModal() {
            case .alertFirstButtonReturn: policy = .keepBoth
            case .alertSecondButtonReturn: policy = .replace
            case .alertThirdButtonReturn: policy = .skip
            default: return
            }
        }
        let progress = TransferProgress()
        TransferProgressController.shared.show(progress, title: move ? "Moving…" : "Copying…")
        busy = true; busyText = move ? "Moving…" : "Copying…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var moved: [(from: URL, to: URL)] = []
            var copied: [URL] = []
            var failures: [(name: String, reason: String)] = []
            let total = sources.count
            for (i, src) in sources.enumerated() {
                if progress.cancelled { break }
                DispatchQueue.main.async {
                    progress.current = src.lastPathComponent
                    progress.fraction = total > 0 ? Double(i) / Double(total) : 0
                }
                let target = dir.appendingPathComponent(src.lastPathComponent)
                var dest = target
                if isSelfDup(src) {
                    dest = self.numberedCopyDest(dir, src.lastPathComponent)
                } else if fm.fileExists(atPath: target.path) {
                    switch policy {
                    case .skip: continue
                    case .replace: try? fm.removeItem(at: target)
                    case .keepBoth: dest = self.uniqueDest(dir, src.lastPathComponent)
                    }
                }
                do {
                    if move { try fm.moveItem(at: src, to: dest); moved.append((src, dest)) }
                    else { try fm.copyItem(at: src, to: dest); copied.append(dest) }
                } catch {
                    // Move across volumes fails as a rename → fall back to copy(+delete).
                    do {
                        try fm.copyItem(at: src, to: dest)
                        if move { try? fm.removeItem(at: src); moved.append((src, dest)) }
                        else { copied.append(dest) }
                    } catch let e {
                        failures.append((src.lastPathComponent, e.localizedDescription))
                    }
                }
            }
            DispatchQueue.main.async {
                TransferProgressController.shared.hide()
                if resetCut { self.cutMode = false }
                self.busy = false; self.busyText = ""
                RecentFolders.shared.record(dir)   // you worked in the destination folder
                if move, !moved.isEmpty {
                    UndoStack.shared.push("Move") { [weak self] in
                        for m in moved { try? FileManager.default.moveItem(at: m.to, to: m.from) }
                        self?.load()
                    }
                } else if !copied.isEmpty {
                    UndoStack.shared.push("Copy") { [weak self] in
                        for c in copied { try? FileManager.default.trashItem(at: c, resultingItemURL: nil) }
                        self?.load()
                    }
                }
                Browser.invalidateCache(dir.path)
                self.load()
                if !failures.isEmpty {
                    let verb = move ? "moved" : "copied"
                    let detail = failures.prefix(5).map { "• \($0.name): \($0.reason)" }.joined(separator: "\n")
                    reportFileError(failures.count == 1 ? "“\(failures[0].name)” couldn't be \(verb)"
                                                        : "\(failures.count) items couldn't be \(verb)", detail)
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
            UndoStack.shared.push("Make Alias") { [weak self] in
                for c in created { try? FileManager.default.trashItem(at: c, resultingItemURL: nil) }
                self?.load()
            }
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
        for it in affected {
            var t = it.tags
            if let idx = t.firstIndex(of: tag) { t.remove(at: idx) } else { t.append(tag) }
            Browser.writeTags(it.url, t)
        }
        UndoStack.shared.push("Tag") { [weak self] in
            for (u, old) in undoData { Browser.writeTags(u, old) }
            self?.load()
        }
        load()
    }
    func setTags(_ ids: Set<String>, tags: [String]) {
        let affected = items.filter { ids.contains($0.id) }
        guard !affected.isEmpty else { return }
        let undoData: [(URL, [String])] = affected.map { ($0.url, $0.tags) }
        for it in affected { Browser.writeTags(it.url, tags) }
        UndoStack.shared.push("Tag") { [weak self] in
            for (u, old) in undoData { Browser.writeTags(u, old) }
            self?.load()
        }
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
            if let err { NSLog("setComment error: \(err)") }
        }
    }

    func applyRenames(_ pairs: [(url: URL, newName: String)]) {
        var undo: [(URL, URL)] = []
        var failure: String?
        for (url, newName) in pairs {
            let n = newName.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty, n != url.lastPathComponent else { continue }
            let dest = url.deletingLastPathComponent().appendingPathComponent(n)
            guard !fm.fileExists(atPath: dest.path) else { continue }
            do { try fm.moveItem(at: url, to: dest); undo.append((dest, url)) }
            catch { failure = failure ?? error.localizedDescription }
        }
        if let failure { reportFileError("Some items couldn't be renamed", failure) }
        if !undo.isEmpty { RecentFolders.shared.record(currentURL) }
        if !undo.isEmpty {
            UndoStack.shared.push("Batch Rename") { [weak self] in
                for (newURL, oldURL) in undo { try? FileManager.default.moveItem(at: newURL, to: oldURL) }
                self?.load()
            }
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
            UndoStack.shared.push("Make Symbolic Link") { [weak self] in
                for c in created { try? FileManager.default.trashItem(at: c, resultingItemURL: nil) }
                self?.load()
            }
        }
        load()
    }

    func rename(id: String, to newName: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != item.name else { return }
        let oldURL = item.url
        let dest = oldURL.deletingLastPathComponent().appendingPathComponent(n)
        do {
            try fm.moveItem(at: oldURL, to: dest)
            RecentFolders.shared.record(currentURL)
            UndoStack.shared.push("Rename") { [weak self] in
                try? FileManager.default.moveItem(at: dest, to: oldURL); self?.load()
            }
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
            UndoStack.shared.push("Duplicate") { [weak self] in
                for c in created { try? FileManager.default.trashItem(at: c, resultingItemURL: nil) }
                self?.load()
            }
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
                    UndoStack.shared.push("Compress") { [weak self] in
                        try? FileManager.default.trashItem(at: dest, resultingItemURL: nil); self?.load()
                    }
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
                    UndoStack.shared.push("Extract") { [weak self] in
                        for c in created { try? FileManager.default.trashItem(at: c, resultingItemURL: nil) }
                        self?.load()
                    }
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
        let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        guard let entries = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else { return }
        var failure: String?
        for e in entries {
            do { try fm.removeItem(at: e) } catch { failure = failure ?? error.localizedDescription }
        }
        if let failure { reportFileError("Some items couldn't be removed from the Trash", failure) }
    }
}

// MARK: - App model (tabs)

final class AppModel: ObservableObject {
    @Published var tabs: [Browser]
    @Published var selected: Int = 0 { didSet { saveState() } }
    @Published var showPreview: Bool = Prefs.showPreview { didSet { Prefs.showPreview = showPreview } }
    @Published var showSidebar: Bool = Prefs.showSidebar { didSet { Prefs.showSidebar = showSidebar } }
    @Published var dualPane: Bool = Prefs.dualPane { didSet { Prefs.dualPane = dualPane } }
    lazy var secondary = Browser(start: FileManager.default.homeDirectoryForCurrentUser)
    @Published var columnCustomization: TableColumnCustomization<FileItem> = AppModel.loadColumns() {
        didSet { AppModel.saveColumns(columnCustomization) }
    }
    init() {
        // Restore previously open tabs (falling back to Home).
        let fm = FileManager.default
        let saved = (UserDefaults.standard.stringArray(forKey: "openTabs") ?? []).filter { fm.fileExists(atPath: $0) }
        if saved.isEmpty {
            tabs = [Browser(start: fm.homeDirectoryForCurrentUser)]
        } else {
            tabs = saved.map { Browser(start: URL(fileURLWithPath: $0)) }
            let savedSel = UserDefaults.standard.integer(forKey: "selectedTab")
            selected = max(0, min(savedSel, tabs.count - 1))
        }
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
        UserDefaults.standard.set(tabs.map { $0.currentURL.path }, forKey: "openTabs")
        UserDefaults.standard.set(selected, forKey: "selectedTab")
    }
    static func loadColumns() -> TableColumnCustomization<FileItem> {
        if let data = Prefs.columnData,
           let c = try? JSONDecoder().decode(TableColumnCustomization<FileItem>.self, from: data) { return c }
        return TableColumnCustomization<FileItem>()
    }
    static func saveColumns(_ c: TableColumnCustomization<FileItem>) { Prefs.columnData = try? JSONEncoder().encode(c) }

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
    // Open a folder in the right-hand pane, turning on dual-pane view if needed.
    func openInSecondPane(_ url: URL) {
        dualPane = true
        secondary.navigate(to: url)
    }
}

// MARK: - Components

struct SidebarView: View {
    @ObservedObject var browser: Browser
    @ObservedObject var recents = RecentFolders.shared
    @ObservedObject var network = NetworkBrowser.shared
    @ObservedObject var favStore = FavoritesStore.shared
    @State private var favNodes: [SidebarNode] = []
    @State private var cloudNodes: [SidebarNode] = []

    @ViewBuilder private func row(_ loc: SidebarLocation) -> some View {
        HStack(spacing: 2) {
            Button { browser.navigate(to: loc.url) } label: {
                Label(loc.name, systemImage: loc.symbol).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            if loc.ejectable {
                Button { try? NSWorkspace.shared.unmountAndEjectDevice(at: loc.url) } label: {
                    Image(systemName: "eject.fill").font(.caption2)
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("Eject")
            }
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
                if pinned { Button("Unpin from Sidebar") { favStore.remove(label: n.name, path: n.url.path) } }
            }
        }
    }

    var body: some View {
        let volumes = volumeLocations()
        List {
            Section("Favorites") {
                Button { browser.loadRecents() } label: {
                    Label("Recents", systemImage: "clock").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                ForEach(favNodes) { tree($0, removable: true) }
                    .onMove { from, to in
                        favNodes.move(fromOffsets: from, toOffset: to)   // immediate, smooth
                        favStore.move(fromOffsets: from, toOffset: to)   // persist + anchor Home
                    }
            }
            .dropDestination(for: URL.self) { urls, _ in
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
            Section("Locations") { ForEach(volumes) { row($0) } }
            if !network.servers.isEmpty {
                Section("Network") {
                    ForEach(network.servers) { s in
                        Button { NSWorkspace.shared.open(s.url) } label: {
                            Label(s.name, systemImage: "network").frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).help("Connect to \(s.url.absoluteString)")
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
    @FocusState private var addressFocused: Bool
    @FocusState private var searchFocused: Bool
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
                Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack).keyboardShortcut("[", modifiers: .command).help("Back")
                Button { browser.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!browser.canGoForward).keyboardShortcut("]", modifiers: .command).help("Forward")
                Button { browser.goUp() } label: { Image(systemName: "chevron.up") }
                    .keyboardShortcut(.upArrow, modifiers: .command).help("Up")
                Button { browser.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command).help("Refresh")

                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(.secondary).font(.caption)
                    TextField("Type a path and press Return", text: $browser.pathText)
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        .focused($addressFocused).onSubmit { browser.submitPath() }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .frame(maxWidth: .infinity)

                Button { browser.copyDisplayedPath() } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy Path Shown in Address Bar")

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("Search “\(folderName)”", text: $browser.searchText)
                        .textFieldStyle(.plain).focused($searchFocused)
                        .onSubmit { browser.runSearch() }
                        .onChange(of: browser.searchText) {
                            if browser.searchText.isEmpty && browser.isSearching { browser.clearSearch() }
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
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary) }
                        .menuStyle(.borderlessButton).frame(width: 20).help("Search Scope & Kind")
                        .onChange(of: browser.searchThisMac) { if browser.isSearching { browser.runSearch() } }
                        .onChange(of: browser.searchKind) { if browser.isSearching { browser.runSearch() } }
                }
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .frame(width: 200)

                Button("") { addressFocused = true }.keyboardShortcut("l", modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }

            // Row 2: Windows 11-style command bar
            HStack(spacing: 6) {
                Menu {
                    Button { browser.newFolder() } label: { Label("Folder", systemImage: "folder.badge.plus") }
                    Button { browser.newTextFile() } label: { Label("Text File", systemImage: "doc.badge.plus") }
                } label: { Label("New", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize().help("New")

                sep()
                Button { browser.cutFiles() } label: { Image(systemName: "scissors") }.help("Cut").disabled(!hasSel)
                Button { browser.copyFiles() } label: { Image(systemName: "doc.on.doc") }.help("Copy").disabled(!hasSel)
                Button { browser.pasteFiles() } label: { Image(systemName: "doc.on.clipboard") }.help("Paste")
                Button { if let id = browser.selection.first { promptRename(browser, id) } } label: { Image(systemName: "pencil") }.help("Rename").disabled(!oneSel)
                Button { shareItems(selURLs) } label: { Image(systemName: "square.and.arrow.up") }.help("Share").disabled(!hasSel)
                Button { browser.moveToTrash(browser.selection) } label: { Image(systemName: "trash") }.help("Delete (⌘⌫)").disabled(!hasSel)

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
                    Button { browser.viewMode = .column } label: { Label("Columns", systemImage: "rectangle.split.3x1") }
                    Button { browser.viewMode = .gallery } label: { Label("Gallery", systemImage: "photo.on.rectangle") }
                    Divider()
                    Toggle("Preview pane", isOn: $model.showPreview)
                    Menu("Show") {
                        Toggle("Navigation pane", isOn: $model.showSidebar)
                        Toggle("Hidden items", isOn: $browser.showHidden)
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
    var body: some View {
        let crumbs = browser.breadcrumbs()
        HStack(spacing: 2) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { idx, crumb in
                if idx > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button { browser.navigate(to: crumb.url) } label: { Text(crumb.name).font(.callout).lineLimit(1).fixedSize() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 10).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).clipped()
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
    }
}

struct NameCell: View {
    let item: FileItem
    @ObservedObject var browser: Browser
    var body: some View {
        HStack(spacing: 6) {
            ThumbIcon(item: item, browser: browser)
            Text(item.name).lineLimit(1)
        }
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

struct FileTableView: View {
    let model: AppModel
    @ObservedObject var browser: Browser
    @Binding var columnCustomization: TableColumnCustomization<FileItem>

    private func open(_ ids: Set<String>) {
        let chosen = browser.items.filter { ids.contains($0.id) }
        if chosen.count == 1, let only = chosen.first { openItem(only, browser); return }
        for it in chosen { NSWorkspace.shared.open(it.url) }
    }

    // Columns live in their own builder with an explicit type so the compiler
    // doesn't choke inferring the (large) Table generic signature.
    @TableColumnBuilder<FileItem, KeyPathComparator<FileItem>>
    private var columns: some TableColumnContent<FileItem, KeyPathComparator<FileItem>> {
        Group {
            TableColumn("Name", value: \FileItem.name) { item in
                NameCell(item: item, browser: browser)
            }.customizationID("name")
            TableColumn("Date Modified", value: \FileItem.modified) { item in
                DateCell(date: item.modified)
            }.width(min: 150, ideal: 185).customizationID("modified")
            TableColumn("Size", value: \FileItem.size) { item in
                SizeCell(item: item)
            }.width(min: 70, ideal: 90).customizationID("size")
            TableColumn("Kind", value: \FileItem.kind) { item in
                Text(item.kind).foregroundStyle(.secondary).lineLimit(1)
            }.width(min: 90, ideal: 130).customizationID("kind")
        }
        Group {
            TableColumn("Date Created", value: \FileItem.created) { item in
                DateCell(date: item.created)
            }.width(min: 150, ideal: 185).customizationID("created").defaultVisibility(.hidden)
            TableColumn("Date Last Opened", value: \FileItem.accessed) { item in
                DateCell(date: item.accessed)
            }.width(min: 150, ideal: 185).customizationID("accessed").defaultVisibility(.hidden)
            TableColumn("Date Added", value: \FileItem.dateAdded) { item in
                DateCell(date: item.dateAdded)
            }.width(min: 150, ideal: 185).customizationID("dateAdded").defaultVisibility(.hidden)
            TableColumn("Ext", value: \FileItem.ext) { item in
                Text(item.ext.isEmpty ? "—" : item.ext.uppercased()).foregroundStyle(.secondary)
            }.width(min: 44, ideal: 56).customizationID("extension").defaultVisibility(.hidden)
        }
        Group {
            TableColumn("Time") { (item: FileItem) in
                if item.isDirectory { Text("—").foregroundStyle(.secondary) }
                else { MetadataCell(url: item.url, field: .duration) }
            }.width(min: 50, ideal: 64).customizationID("duration").defaultVisibility(.hidden)
            TableColumn("Dimensions") { (item: FileItem) in
                if item.isDirectory { Text("—").foregroundStyle(.secondary) }
                else { MetadataCell(url: item.url, field: .dimensions) }
            }.width(min: 90, ideal: 110).customizationID("dimensions").defaultVisibility(.hidden)
            TableColumn("Tags") { (item: FileItem) in
                TagsCell(tags: item.tags)
            }.width(min: 90, ideal: 140).customizationID("tags").defaultVisibility(.hidden)
        }
    }

    var body: some View {
        Table(of: FileItem.self, selection: $browser.selection, sortOrder: $browser.sortOrder,
              columnCustomization: $columnCustomization) {
            columns
        } rows: {
            if browser.groupBy == .none {
                ForEach(browser.visibleItems()) { item in tableRow(item) }
            } else {
                ForEach(browser.groups(), id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in tableRow(item) }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            contextMenu(ids)
        } primaryAction: { ids in
            open(ids)
        }
        .onChange(of: browser.selection) { browser.updateStatus() }
    }

    @TableRowBuilder<FileItem>
    private func tableRow(_ item: FileItem) -> some TableRowContent<FileItem> {
        TableRow(item)
            .itemProvider { NSItemProvider(object: item.url as NSURL) }
            .dropDestination(for: URL.self) { urls in
                guard item.isDirectory else { return }
                browser.importURLs(urls, into: item.url, move: true)
            }
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<FileItem.ID>) -> some View {
        if !ids.isEmpty {
            Button("Open") { open(ids) }
            if ids.count == 1, let it = browser.items.first(where: { $0.id == ids.first }), it.isDirectory {
                Button("Open in New Tab") { model.newTab(at: it.url) }
                Button("Open in Second Pane") { model.openInSecondPane(it.url) }
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
            Button("Share…") { shareItems(browser.items.filter { ids.contains($0.id) }.map { $0.url }) }
            if let it = browser.items.first(where: { $0.id == ids.first }) {
                Button("Open in Terminal") { openInTerminal(it.isDirectory ? it.url : browser.currentURL) }
            }
            Divider()
            Button("Copy") { browser.copyFiles() }
            Button("Cut") { browser.cutFiles() }
            Button("Paste") { browser.pasteFiles() }
            if !browser.isGoogleDriveSelection(ids) { Button("Copy Path") { browser.copyPath(ids) } }
            Button("Copy Name") { browser.copyName(ids) }
            if browser.isGoogleDriveSelection(ids) {
                Button { browser.copyGoogleDriveLink(ids) } label: { gdLabel("Copy Web Link") }
                Button { browser.copyGoogleDrivePath(ids) } label: { gdLabel("Copy Local Path") }
                Button { browser.openGoogleDriveLink(ids) } label: { gdLabel("Open in Web") }
            }
            Divider()
            Button("Move to Trash") { browser.moveToTrash(ids) }
        } else {
            Button("Paste") { browser.pasteFiles() }
            Button("New Folder") { browser.newFolder() }
            Button("New Text File") { browser.newTextFile() }
            Button("Calculate All Sizes") {
                for it in browser.items where it.isDirectory { FolderSizeCache.shared.compute(it.url) }
            }
            Button("Reveal in Finder") { browser.revealInFinder([]) }
        }
    }
}

struct IconCell: View {
    let item: FileItem
    @ObservedObject var browser: Browser
    let selected: Bool
    @State private var thumb: NSImage?
    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let t = thumb { Image(nsImage: t).resizable().scaledToFit() }
                else { Image(nsImage: browser.icon(for: item)).resizable().scaledToFit() }
            }
            .frame(width: browser.iconSize, height: browser.iconSize)
            Text(item.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(width: browser.iconSize + 40, height: browser.iconSize + 46)
        .padding(4)
        .background(selected ? Color.accentColor.opacity(0.25) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .draggable(item.url)
        .onAppear { ThumbnailCache.shared.thumbnail(for: item.url) { thumb = $0 } }
    }
}

// Collects each icon cell's frame (in the grid's coordinate space) so a
// rubber-band drag can hit-test which items it covers.
struct ItemFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// AppKit-level drag catcher for rubber-band selection. A SwiftUI DragGesture
// inside a ScrollView is unreliable (the scroll view eats the drag), so we use a
// real NSView that receives mouseDragged directly. It sits behind the cells, so
// only drags/clicks on empty space reach it. Coordinates are top-left (flipped)
// to match SwiftUI's grid space.
struct MarqueeCatcher: NSViewRepresentable {
    var onRect: (CGRect?) -> Void      // drag rect in grid space; nil when the drag ends
    var onEmptyClick: () -> Void        // a click on empty space (no drag) → deselect
    func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.onRect = onRect; v.onEmptyClick = onEmptyClick; return v }
    func updateNSView(_ v: CatcherView, context: Context) { v.onRect = onRect; v.onEmptyClick = onEmptyClick }
    final class CatcherView: NSView {
        var onRect: ((CGRect?) -> Void)?
        var onEmptyClick: (() -> Void)?
        private var start: NSPoint?
        private var dragged = false
        override var isFlipped: Bool { true }
        override func mouseDown(with e: NSEvent) { start = convert(e.locationInWindow, from: nil); dragged = false }
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
    @State private var itemFrames: [String: CGRect] = [:]
    @State private var marquee: CGRect?
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
                                    browser.selection = Set(itemFrames.filter { $0.value.intersects(r) }.map { $0.key })
                                    browser.updateStatus()
                                }
                            },
                            onEmptyClick: { browser.selection = []; browser.updateStatus() }
                        )
                        .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                        LazyVGrid(columns: columns, spacing: 12) {
                            if browser.groupBy == .none {
                                ForEach(browser.visibleItems()) { item in cell(item) }
                            } else {
                                ForEach(browser.groups(), id: \.title) { group in
                                    Section {
                                        ForEach(group.items) { item in cell(item) }
                                    } header: {
                                        HStack {
                                            Text(group.title).font(.headline).foregroundStyle(.secondary)
                                            Spacer()
                                        }.padding(.top, 8).padding(.horizontal, 4)
                                    }
                                }
                            }
                        }
                        .padding(14)
                    }
                    .coordinateSpace(name: "iconGrid")
                    .onPreferenceChange(ItemFramesKey.self) { itemFrames = $0 }
                    .overlay(alignment: .topLeading) {
                        if let m = marquee { MarqueeRect(rect: m) }
                    }
                }
                .onChange(of: browser.keyboardScrollID) {
                    if let id = browser.keyboardScrollID { withAnimation { proxy.scrollTo(id, anchor: .center) } }
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
                Color.clear.preference(key: ItemFramesKey.self, value: [item.id: g.frame(in: .named("iconGrid"))])
            })
            // ONE tap recognizer — no count:2 gesture to disambiguate against, so
            // the select fires on mouse-up with zero double-click delay. A
            // double-click still opens: macOS reports clickCount==2 on the 2nd press.
            .onTapGesture {
                let e = NSApp.currentEvent
                if (e?.clickCount ?? 1) >= 2 { openItem(item, browser) }
                else { browser.click(item.id, modifiers: e?.modifierFlags ?? []) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard item.isDirectory else { return false }
                browser.importURLs(urls, into: item.url, move: true); return true
            }
            .contextMenu {
                Button("Open") { openItem(item, browser) }
                if item.isDirectory {
                    Button("Open in New Tab") { model.newTab(at: item.url) }
                    Button("Open in Second Pane") { model.openInSecondPane(item.url) }
                }
                if !item.isDirectory { OpenWithMenu(urls: [item.url]) }
                Button("Quick Look") { QuickLook.shared.show([item.url]) }
                Button("Reveal in Finder") { browser.revealInFinder([item.id]) }
                Divider()
                Button("Rename…") { promptRename(browser, item.id) }
                TagsMenu(browser: browser, ids: [item.id])
                Button("Edit Comment…") { promptComment(browser, item.id) }
                Button("Duplicate") { browser.duplicate([item.id]) }
                Button("Make Alias") { browser.makeAlias([item.id]) }
                Button("Make Symbolic Link") { browser.makeSymlink([item.id]) }
                if isArchive(item.url) { Button("Extract") { browser.extract([item.id]) } }
                if item.isDirectory {
                    if FavoritesStore.shared.contains(item.url) {
                        Button("Unpin from Sidebar") { FavoritesStore.shared.remove(url: item.url) }
                    } else {
                        Button("Pin to Sidebar") { FavoritesStore.shared.add(item.url) }
                    }
                }
                Button("Get Info") { showInfo(browser, [item.id]) }
                Divider()
                Button("Share…") { shareItems([item.url]) }
                Button("Open in Terminal") { openInTerminal(item.isDirectory ? item.url : browser.currentURL) }
                if !browser.isGoogleDriveSelection([item.id]) { Button("Copy Path") { browser.copyPath([item.id]) } }
                Button("Copy Name") { browser.copyName([item.id]) }
                if browser.isGoogleDriveSelection([item.id]) {
                    Button { browser.copyGoogleDriveLink([item.id]) } label: { gdLabel("Copy Web Link") }
                    Button { browser.copyGoogleDrivePath([item.id]) } label: { gdLabel("Copy Local Path") }
                    Button { browser.openGoogleDriveLink([item.id]) } label: { gdLabel("Open in Web") }
                }
                Button("Move to Trash") { browser.moveToTrash([item.id]) }
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

struct ColumnView: View {
    let model: AppModel
    @ObservedObject var browser: Browser
    @State private var path: [URL] = []   // selected sub-folder chain below the root

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                colList(browser.currentURL, level: 0)
                ForEach(Array(path.enumerated()), id: \.offset) { idx, url in
                    Divider()
                    colList(url, level: idx + 1)
                }
            }
        }
        .onChange(of: browser.currentURL) { path = [] }
    }

    @ViewBuilder private func colList(_ dir: URL, level: Int) -> some View {
        ColumnList(dir: dir, browser: browser,
                   onPickFolder: { folder in path = Array(path.prefix(level)) + [folder] },
                   onPickFile: { path = Array(path.prefix(level)) },
                   onOpen: { openItem($0, browser) })
            .frame(width: 250)
    }
}

struct ColumnList: View {
    let dir: URL
    @ObservedObject var browser: Browser
    let onPickFolder: (URL) -> Void
    let onPickFile: () -> Void
    let onOpen: (FileItem) -> Void
    @State private var items: [FileItem] = []
    @State private var sel: String?

    var body: some View {
        // Native List → robust click handling, real selection highlight, and
        // keyboard arrows within the column. Single-select drills; double-click opens.
        List(selection: $sel) {
            ForEach(items) { item in
                HStack(spacing: 6) {
                    ThumbIcon(item: item, browser: browser)
                    Text(item.name).lineLimit(1)
                    Spacer(minLength: 0)
                    if item.isDirectory { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }
                .tag(item.id)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(item) })
            }
        }
        .listStyle(.plain)
        .onChange(of: sel) { handleSelection() }
        .onAppear { load() }
        .onChange(of: dir) { sel = nil; load() }
    }
    private func handleSelection() {
        guard let id = sel, let item = items.first(where: { $0.id == id }) else { onPickFile(); return }
        browser.selection = [id]; browser.updateStatus()
        if item.isDirectory { onPickFolder(item.url) } else { onPickFile() }
    }
    private func load() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .localizedTypeDescriptionKey]
        var opts: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !browser.showHidden { opts.insert(.skipsHiddenFiles) }
        var result: [FileItem] = []
        if let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: opts) {
            for u in urls { result.append(Browser.item(from: u, try? u.resourceValues(forKeys: Set(Browser.itemKeys)))) }
        }
        items = result.sorted { ($0.isDirectory ? 0 : 1, $0.name.localizedLowercase) < ($1.isDirectory ? 0 : 1, $1.name.localizedLowercase) }
    }
}

// Shared image/thumbnail view with icon fallback, used by Gallery view.
struct ThumbImage: View {
    let item: FileItem
    @ObservedObject var browser: Browser
    @State private var thumb: NSImage?
    var body: some View {
        Group {
            if let t = thumb { Image(nsImage: t).resizable().scaledToFit() }
            else { Image(nsImage: browser.icon(for: item)).resizable().scaledToFit() }
        }
        .onAppear { ThumbnailCache.shared.thumbnail(for: item.url) { thumb = $0 } }
        .onChange(of: item.url) { thumb = nil; ThumbnailCache.shared.thumbnail(for: item.url) { thumb = $0 } }
    }
}

struct GalleryView: View {
    let model: AppModel
    @ObservedObject var browser: Browser
    private var items: [FileItem] { browser.orderedVisibleItems() }
    private var selected: FileItem? { items.first { browser.selection.contains($0.id) } ?? items.first }
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .textBackgroundColor).opacity(0.25)
                if let it = selected {
                    VStack(spacing: 8) {
                        ThumbImage(item: it, browser: browser).padding(24)
                        Text(it.name).font(.callout).lineLimit(1).padding(.bottom, 6)
                    }
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
                                .onTapGesture {
                                    let e = NSApp.currentEvent
                                    if (e?.clickCount ?? 1) >= 2 { openItem(it, browser) }
                                    else { browser.click(it.id, modifiers: e?.modifierFlags ?? []) }
                                }
                        }
                    }.padding(8)
                }
                .frame(height: 92)
                .onChange(of: browser.keyboardScrollID) {
                    if let id = browser.keyboardScrollID { withAnimation { proxy.scrollTo(id) } }
                }
            }
        }
    }
}

struct StatusBar: View {
    @ObservedObject var browser: Browser
    var body: some View {
        HStack {
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
            if browser.viewMode == .icon {
                Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $browser.iconSize, in: 48...192).frame(width: 110).controlSize(.mini)
            }
            Toggle("Show hidden files", isOn: $browser.showHidden).toggleStyle(.checkbox).font(.caption)
        }.padding(.horizontal, 10).padding(.vertical, 4)
    }
}

struct TabItemView: View {
    @ObservedObject var browser: Browser
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
            Image(systemName: "folder").font(.caption2).foregroundStyle(.secondary)
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
        .dropDestination(for: URL.self) { urls, _ in
            browser.importURLs(urls, into: browser.currentURL, move: true)
            onSelect(); return true
        } isTargeted: { dropTargeted = $0 }
    }
}

struct TabStrip: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.tabs.enumerated()), id: \.element.id) { idx, browser in
                TabItemView(browser: browser,
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
                BreadcrumbBar(browser: browser)
                Divider()
            }
            Group {
                switch browser.viewMode {
                case .icon: IconGridView(model: model, browser: browser)
                case .gallery: GalleryView(model: model, browser: browser)
                case .column: ColumnView(model: model, browser: browser)
                case .list: FileTableView(model: model, browser: browser, columnCustomization: $model.columnCustomization)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                browser.copyURLs(urls, move: false); return true
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
    func splitView(_ sv: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        if bypassConstraints { return 0 }
        if i == 0 { return sidebarMin }
        // divider 1: keep content ≥ contentMin and preview ≤ previewMax
        return max(sidebarPane.frame.maxX + thickness + contentMin, total - previewMax)
    }
    func splitView(_ sv: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        if bypassConstraints { return total }
        if i == 0 { return min(sidebarMax, previewPane.frame.minX - thickness - contentMin) }
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
        vc.apply(sidebar: AnyView(SidebarView(browser: browser)),
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
        v.image = NSImage(contentsOf: url)
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) {
        v.image = NSImage(contentsOf: url); v.animates = true
    }
}

// Pannable, zoomable image view. zoom is the display scale relative to the
// image's actual pixels (1.0 = 100%). Scroll wheel zooms toward the cursor,
// drag pans when zoomed in; the SwiftUI bar drives it via ZoomController.
final class ZoomView: NSView {
    var onZoomChange: ((Double, Double) -> Void)?     // (current, fit)
    private var _image: NSImage?
    private var _zoom: Double = 1
    private var offset = CGPoint.zero
    private var didFit = false
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func setImage(_ img: NSImage?) {
        _image = img; offset = .zero; didFit = false
        if bounds.width > 0, bounds.height > 0 { fit() } else { needsDisplay = true }
    }
    private var pixelSize: CGSize {
        guard let rep = _image?.representations.first else { return _image?.size ?? .zero }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
    var fitZoom: Double {
        let s = pixelSize
        guard s.width > 0, s.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return Double(min(bounds.width / s.width, bounds.height / s.height))
    }
    var zoom: Double { _zoom }
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
        NSColor.black.setFill(); bounds.fill()
        guard let img = _image else { return }
        let s = pixelSize
        let w = CGFloat(s.width) * CGFloat(_zoom), h = CGFloat(s.height) * CGFloat(_zoom)
        let x = (bounds.width - w) / 2 + offset.x, y = (bounds.height - h) / 2 + offset.y
        img.draw(in: NSRect(x: x, y: y, width: w, height: h), from: .zero, operation: .sourceOver,
                 fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
    override func scrollWheel(with event: NSEvent) {
        let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        guard d != 0 else { return }
        zoomAt(convert(event.locationInWindow, from: nil), factor: 1 + Double(d) * 0.01)
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
}

struct ZoomableImageView: NSViewRepresentable {
    let url: URL
    let controller: ZoomController
    func makeNSView(context: Context) -> ZoomView {
        let v = ZoomView()
        v.onZoomChange = { z, fit in DispatchQueue.main.async { controller.zoom = z; controller.fitZoom = fit } }
        v.setImage(NSImage(contentsOf: url))
        controller.view = v
        context.coordinator.url = url
        return v
    }
    func updateNSView(_ v: ZoomView, context: Context) {
        controller.view = v
        if context.coordinator.url != url {
            context.coordinator.url = url
            v.setImage(NSImage(contentsOf: url))
        }
    }
    func makeCoordinator() -> Coord { Coord() }
    final class Coord { var url: URL? }
}

struct ImageViewerView: View {
    let urls: [URL]
    var onTitle: (String) -> Void = { _ in }
    @State private var index: Int
    @State private var dims: String = ""
    @State private var sizeStr: String = ""
    @State private var kindStr: String = ""
    @StateObject private var zoomCtl = ZoomController()
    init(urls: [URL], index: Int, onTitle: @escaping (String) -> Void = { _ in }) {
        self.urls = urls; self.onTitle = onTitle; _index = State(initialValue: index)
    }
    private func step(_ d: Int) {
        guard !urls.isEmpty else { return }
        index = (index + d + urls.count) % urls.count
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
        MetadataCache.shared.meta(for: u) { m in
            guard urls.indices.contains(index), urls[index] == u else { return }
            if let w = m.width, let h = m.height, w > 0, h > 0 { dims = "\(w) × \(h)" }
        }
    }
    private var isAnimated: Bool { urls.indices.contains(index) && isAnimatedImage(urls[index]) }
    var body: some View {
        ZStack {
            Color.black
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
            VStack {
                Spacer()
                bottomBar
            }
            // ⌘+ / ⌘= zoom in, ⌘- zoom out, ⌘0 fit (hidden shortcut buttons)
            Group {
                Button("") { zoomCtl.zoomBy(1.25) }.keyboardShortcut("+", modifiers: .command)
                Button("") { zoomCtl.zoomBy(1.25) }.keyboardShortcut("=", modifiers: .command)
                Button("") { zoomCtl.zoomBy(0.8) }.keyboardShortcut("-", modifiers: .command)
                Button("") { zoomCtl.fit() }.keyboardShortcut("0", modifiers: .command)
            }.frame(width: 0, height: 0).opacity(0)
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear { loadInfo() }
        .onChange(of: index) { loadInfo() }
    }
    // Windows Photos-style bottom bar: details on the left, zoom controls on the right.
    private var bottomBar: some View {
        HStack(spacing: 12) {
            if urls.indices.contains(index) {
                Text(urls[index].lastPathComponent).fontWeight(.medium).lineLimit(1)
                detail("photo", dims)
                detail("internaldrive", sizeStr)
                Text("·").foregroundStyle(.white.opacity(0.4))
                Text("\(index + 1) of \(urls.count)").foregroundStyle(.white.opacity(0.85))
            }
            Spacer(minLength: 12)
            if !isAnimated {
                Button { zoomCtl.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.plain).help("Fit to Window (⌘0)")
                Button { zoomCtl.zoomBy(0.8) } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.plain).help("Zoom Out (⌘−)")
                Slider(value: zoomBinding, in: 0.05...8).frame(width: 130)
                Button { zoomCtl.zoomBy(1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.plain).help("Zoom In (⌘+)")
                Text("\(zoomCtl.percent)%").monospacedDigit().frame(width: 46, alignment: .trailing)
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

final class ImageViewerController {
    static let shared = ImageViewerController()
    private var window: NSWindow?
    func show(urls: [URL], index: Int) {
        guard !urls.isEmpty else { NSSound.beep(); return }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.title = urls.indices.contains(index) ? urls[index].lastPathComponent : "Image"
        window?.contentView = NSHostingView(rootView: ImageViewerView(urls: urls, index: index) { [weak self] name in
            self?.window?.title = name
        })
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Rich Get Info window

struct GetInfoView: View {
    @ObservedObject var browser: Browser
    let item: FileItem
    @ObservedObject private var sizeCache = FolderSizeCache.shared
    @State private var name: String
    @State private var comment: String = ""
    @State private var tags: [String]
    @State private var thumb: NSImage?
    @State private var meta = FileMeta()
    private static let df: DateFormatter = { let d = DateFormatter(); d.dateStyle = .long; d.timeStyle = .short; return d }()

    init(browser: Browser, item: FileItem) {
        self.browser = browser; self.item = item
        _name = State(initialValue: item.name)
        _tags = State(initialValue: item.tags)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    Group {
                        if let t = thumb { Image(nsImage: t).resizable().scaledToFit() }
                        else { Image(nsImage: browser.icon(for: item)).resizable().scaledToFit() }
                    }.frame(width: 120, height: 120)
                    Spacer()
                }
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).font(.headline)
                    .onSubmit { if name != item.name { browser.rename(id: item.id, to: name) } }
                Divider()
                Group {
                    row("Kind", item.kind)
                    row("Size", sizeText())
                    if let d = meta.duration, d >= 1 { row("Duration", formatDuration(d)) }
                    if let w = meta.width, let h = meta.height, w > 0, h > 0 { row("Dimensions", "\(w) × \(h)") }
                    row("Created", Self.df.string(from: item.created))
                    row("Modified", Self.df.string(from: item.modified))
                    row("Added", Self.df.string(from: item.dateAdded))
                    row("Where", item.url.deletingLastPathComponent().path)
                    row("Permissions", permString())
                }.font(.callout)
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
            }.padding(16)
        }
        .frame(minWidth: 320, minHeight: 480)
        .onAppear { load() }
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
    private func permString() -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: item.url.path),
              let perm = attrs[.posixPermissions] as? NSNumber else { return "—" }
        let p = perm.uint16Value
        func rwx(_ v: UInt16) -> String { "\(v & 4 != 0 ? "r" : "-")\(v & 2 != 0 ? "w" : "-")\(v & 1 != 0 ? "x" : "-")" }
        return "\(rwx((p >> 6) & 7))\(rwx((p >> 3) & 7))\(rwx(p & 7))"
    }
    private func toggle(_ t: String) {
        if let i = tags.firstIndex(of: t) { tags.remove(at: i) } else { tags.append(t) }
        browser.setTags([item.id], tags: tags)
    }
    private func load() {
        ThumbnailCache.shared.thumbnail(for: item.url, size: 512) { thumb = $0 }
        MetadataCache.shared.meta(for: item.url) { m in meta = m; if let c = m.comment, comment.isEmpty { comment = c } }
        if item.isDirectory { FolderSizeCache.shared.compute(item.url) }
    }
}

final class GetInfoController {
    static let shared = GetInfoController()
    private var windows: [String: NSWindow] = [:]
    func show(_ browser: Browser, _ item: FileItem) {
        if let w = windows[item.id] { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 540),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "\(item.name) Info"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: GetInfoView(browser: browser, item: item))
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows[item.id] = w
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Transfer progress window

struct TransferProgressView: View {
    @ObservedObject var progress: TransferProgress
    let title: String
    let onCancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ProgressView(value: progress.fraction)
            Text(progress.current).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack { Spacer(); Button("Cancel") { progress.cancelled = true; onCancel() } }
        }.padding(18).frame(width: 380)
    }
}

final class TransferProgressController {
    static let shared = TransferProgressController()
    private var window: NSWindow?
    func show(_ progress: TransferProgress, title: String) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: TransferProgressView(progress: progress, title: title) { [weak w] in w?.close() })
        w.center(); w.makeKeyAndOrderFront(nil)
        window = w
    }
    func hide() { window?.close(); window = nil }
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
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
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

final class NavWindow: NSWindow {
    let model = AppModel()

    // ⌘ + scroll wheel resizes/cycles the view (Windows 11 Ctrl+scroll). Handled
    // here in sendEvent so the event is fully consumed — a local event monitor
    // isn't reliable because AppKit's responsive scrolling can still deliver the
    // wheel event to the list, making it scroll while zooming.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
            if dy != 0 { model.active.adjustViewScale(dy) }
            return   // consume — do not forward to the content/scroll view
        }
        super.sendEvent(event)
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
    var body: some View {
        Form {
            Section("Defaults for new windows & tabs") {
                Picker("View", selection: $viewMode) {
                    Text("Details").tag("list"); Text("Icons").tag("icon")
                    Text("Gallery").tag("gallery"); Text("Columns").tag("column")
                }
                Picker("Sort by", selection: $sortKey) {
                    Text("Name").tag("name"); Text("Date Modified").tag("modified")
                    Text("Size").tag("size"); Text("Kind").tag("kind")
                }
                Toggle("Ascending order", isOn: $sortAscending)
                Toggle("Show hidden files", isOn: $showHidden)
            }
            Section("Behavior") {
                Toggle("Confirm before moving to Trash", isOn: $confirmTrash)
                Picker("Thumbnails", selection: $thumbnailMode) {
                    Text("All files").tag("all")
                    Text("Images only").tag("images")
                    Text("Off (fastest on slow drives)").tag("off")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 360)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NavWindow!
    private var extraWindows: [NavWindow] = []
    private var keyMonitor: Any?
    private var mainWindowShown = false
    // Set when we're launched purely to view an image (open handler runs before
    // didFinishLaunching) — then we DON'T pop the browser window behind the viewer.
    private var suppressMainWindow = false

    // Menu commands and keyboard nav target whichever Navigator window is key.
    var appModel: AppModel { (NSApp.keyWindow as? NavWindow)?.model ?? window.model }

    private var pendingFolders: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMenu()
        window = makeWindow(restoreState: true)   // created, but not shown yet
        window.setFrameAutosaveName("NavigatorMainWindow")
        installKeyMonitor()
        ensureSMBTuning()
        Updater.check(userInitiated: false)   // silent, throttled to once/day; prompts only if an update exists
        NetworkBrowser.shared.start()
        NSApp.servicesProvider = self   // powers the "Open in Navigator" Finder Services entry
        NSUpdateDynamicServices()
        // Show the browser shortly — unless we were launched only to view an image
        // (the open handler sets suppressMainWindow first). The tiny delay also lets
        // a folder-open event arrive so it opens as a tab in the same window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.suppressMainWindow else { return }
            self.showMainWindow()
            self.offerDefaultsIfNeeded()   // one-time; only on a normal (visible) launch
        }
    }

    // Bring up the browser window (idempotent) and flush any queued folder opens.
    func showMainWindow() {
        if !mainWindowShown {
            mainWindowShown = true
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        if !pendingFolders.isEmpty { pendingFolders.forEach { window.model.newTab(at: $0) }; pendingFolders = [] }
    }

    // Make network-drive browsing steadier out of the box by disabling SMB
    // change-notifications (needless chatter over the VPN). macOS reads a
    // per-user config at ~/Library/Preferences/nsmb.conf — no sudo, no /etc.
    // We only ADD our setting; we never remove or overwrite existing config,
    // and skip if the user/IT already tuned it. Takes effect on the next mount.
    func ensureSMBTuning() {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Preferences/nsmb.conf")
        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            if existing.contains("notify_off") { return }   // already configured — leave it alone
            // Only append if there's no [default] section to disturb (avoid duplicate sections).
            if existing.range(of: #"(?m)^\s*\[default\]"#, options: .regularExpression) == nil {
                let updated = existing + "\n[default]\nnotify_off=yes\n"
                try? updated.write(toFile: path, atomically: true, encoding: .utf8)
            }
            return
        }
        let content = """
        # Written by Navigator — steadier, faster SMB/network-drive browsing.
        # Disables SMB directory change-notifications (needless chatter over VPN).
        # Per-user, safe, no sudo. Takes effect on the next mount.
        [default]
        notify_off=yes
        """
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
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

    // Receives folders/files the system routes to us (e.g. when Navigator is the
    // default folder handler). Folders open as new tabs; other files open normally.
    func application(_ application: NSApplication, open urls: [URL]) {
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
            let siblings = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { isImageFile($0) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let list = siblings.isEmpty ? images : siblings
            ImageViewerController.shared.show(urls: list, index: list.firstIndex(of: first) ?? 0)
            NSApp.activate(ignoringOtherApps: true)
        }
        for u in others { NSWorkspace.shared.open(u) }   // non-images → their own default app
        guard !folders.isEmpty else { return }
        // Folders always need the browser window.
        if window == nil { pendingFolders += folders; return }   // opened before launch finished
        showMainWindow()
        folders.forEach { window.model.newTab(at: $0) }
    }

    @discardableResult
    private func makeWindow(restoreState: Bool) -> NavWindow {
        let w = NavWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = "Navigator"
        w.contentView = NSHostingView(rootView: ContentView(model: w.model))
        w.center()
        return w
    }

    @objc func newWindowAction(_ sender: Any?) {
        let w = makeWindow(restoreState: false)
        var f = w.frame; f.origin.x += 28; f.origin.y -= 28; w.setFrame(f, display: false)
        extraWindows.append(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Clicking the Dock icon (or reopening) with no window visible brings the
    // browser up — important since an image-only launch keeps it hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { window.model.saveState() }

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
        if let r = keyWin.firstResponder, r is NSText || r is NSTextView { return event }
        let b = keyWin.model.active
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 36, 76: // Return / Enter → open
            if !b.selection.isEmpty { b.openSelection(); return nil }
            return event
        case 51: // Delete/Backspace (no modifier) → enclosing folder
            if flags.isEmpty { b.goUp(); return nil }
            return event
        case 120: // F2 → rename selected (Windows parity)
            if !b.selection.isEmpty { renameAction(nil); return nil }
            return event
        case 49: // Space → Quick Look
            if !b.selection.isEmpty {
                QuickLook.shared.show(b.items.filter { b.selection.contains($0.id) }.map { $0.url }); return nil
            }
            return event
        case 8 where flags == .command: // ⌘C → copy files (text fields handled above)
            if !b.selection.isEmpty { b.copyFiles() }
            return nil
        case 7 where flags == .command: // ⌘X → cut files
            if !b.selection.isEmpty { b.cutFiles() }
            return nil
        case 9 where flags == .command: // ⌘V → paste files into the current folder
            b.pasteFiles(); return nil
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
        fileMenu.addItem(.separator())
        let nf = fileMenu.addItem(withTitle: "New Folder", action: #selector(newFolderAction(_:)), keyEquivalent: "n")
        nf.keyEquivalentModifierMask = [.command, .shift]; nf.target = self
        let ntf = fileMenu.addItem(withTitle: "New Text File", action: #selector(newTextFileAction(_:)), keyEquivalent: "n")
        ntf.keyEquivalentModifierMask = [.command, .option]; ntf.target = self
        fileMenu.addItem(.separator())
        let gi = fileMenu.addItem(withTitle: "Get Info", action: #selector(getInfoAction(_:)), keyEquivalent: "i"); gi.target = self
        let dup = fileMenu.addItem(withTitle: "Duplicate", action: #selector(duplicateAction(_:)), keyEquivalent: "d"); dup.target = self
        let rn = fileMenu.addItem(withTitle: "Rename…", action: #selector(renameAction(_:)), keyEquivalent: ""); rn.target = self
        let ql = fileMenu.addItem(withTitle: "Quick Look", action: #selector(quickLookAction(_:)), keyEquivalent: "y"); ql.target = self
        let zip = fileMenu.addItem(withTitle: "Compress", action: #selector(compressAction(_:)), keyEquivalent: ""); zip.target = self
        fileMenu.addItem(.separator())
        let del = fileMenu.addItem(withTitle: "Move to Trash", action: #selector(moveToTrashAction(_:)), keyEquivalent: "\u{8}")
        del.keyEquivalentModifierMask = [.command]; del.target = self
        let et = fileMenu.addItem(withTitle: "Empty Trash", action: #selector(emptyTrashAction(_:)), keyEquivalent: "\u{8}")
        et.keyEquivalentModifierMask = [.command, .shift]; et.target = self
        fileMenu.addItem(.separator())
        let cs = fileMenu.addItem(withTitle: "Connect to Server…", action: #selector(connectServerAction(_:)), keyEquivalent: "k")
        cs.target = self
        fileMenu.addItem(.separator())
        let expF = fileMenu.addItem(withTitle: "Export Favorites…", action: #selector(exportFavoritesAction(_:)), keyEquivalent: ""); expF.target = self
        let impF = fileMenu.addItem(withTitle: "Import Favorites…", action: #selector(importFavoritesAction(_:)), keyEquivalent: ""); impF.target = self

        // Edit menu uses the STANDARD selectors + titles, so the user's System Settings
        // keyboard-shortcut overrides for Copy/Cut/Paste are applied automatically.
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
        let undo = editMenu.addItem(withTitle: "Undo", action: #selector(undoAction(_:)), keyEquivalent: "z"); undo.target = self
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

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

        NSApp.mainMenu = mainMenu
    }

    // Fallback handlers: reached only when a text field is NOT the first responder,
    // so text fields still do text copy/paste while the file list does file copy/paste.
    @objc func copy(_ sender: Any?) { appModel.active.copyFiles() }
    @objc func cut(_ sender: Any?) { appModel.active.cutFiles() }
    @objc func paste(_ sender: Any?) { appModel.active.pasteFiles() }
    @objc func newTabAction(_ sender: Any?) { appModel.newTab() }
    @objc func closeTabAction(_ sender: Any?) {
        if appModel.tabs.count > 1 { appModel.closeTab(appModel.selected) } else { NSApp.keyWindow?.performClose(nil) }
    }
    @objc func newFolderAction(_ sender: Any?) { appModel.active.newFolder() }
    @objc func newTextFileAction(_ sender: Any?) { appModel.active.newTextFile() }
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
    @objc func togglePreviewAction(_ sender: Any?) { appModel.showPreview.toggle() }
    @objc func toggleSidebarAction(_ sender: Any?) { appModel.showSidebar.toggle() }
    @objc func toggleDualPaneAction(_ sender: Any?) { appModel.dualPane.toggle() }
    @objc func toggleHiddenAction(_ sender: Any?) { appModel.active.showHidden.toggle() }
    @objc func undoAction(_ sender: Any?) {
        // When editing text, let the field's own undo run; otherwise undo file operations.
        if let r = window.firstResponder, r is NSText || r is NSTextView,
           let um = window.undoManager, um.canUndo { um.undo(); return }
        UndoStack.shared.undo()
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

    @objc func checkForUpdatesAction(_ sender: Any?) { Updater.check(userInitiated: true) }
    private var settingsWindow: NSWindow?
    @objc func showSettingsAction(_ sender: Any?) {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Settings"
            w.contentView = NSHostingView(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    // Right-click (or Control-click) the Dock icon → Finder-style shortcuts.
    // macOS appends its own "Options / Show All Windows / Quit" below these.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            m.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self
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

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
