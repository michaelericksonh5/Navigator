import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Quartz

enum ViewMode { case list, icon }
enum SortField: String, CaseIterable { case name, modified, size, kind }
enum GroupBy: String, CaseIterable { case none, kind, date, size }

// MARK: - Persistence (UserDefaults-backed view settings)

enum Prefs {
    static let d = UserDefaults.standard
    static var showHidden: Bool { get { d.bool(forKey: "showHidden") } set { d.set(newValue, forKey: "showHidden") } }
    static var viewModeIcon: Bool { get { d.bool(forKey: "viewModeIcon") } set { d.set(newValue, forKey: "viewModeIcon") } }
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
    static var columnData: Data? { get { d.data(forKey: "columnCustomization") } set { d.set(newValue, forKey: "columnCustomization") } }
    static var recentFolders: [String] { get { d.stringArray(forKey: "recentFolders") ?? [] } set { d.set(newValue, forKey: "recentFolders") } }
}

// MARK: - Recent folders (Windows Quick Access-style MRU list)

final class RecentFolders: ObservableObject {
    static let shared = RecentFolders()
    @Published var urls: [URL]
    private let cap = 12
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

// Async image-thumbnail cache (falls back to file-type icons for non-images).
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    func thumbnail(for url: URL, completion: @escaping (NSImage?) -> Void) {
        let key = url.path as NSString
        if let c = cache.object(forKey: key) { completion(c); return }
        DispatchQueue.global(qos: .utility).async {
            var img: NSImage?
            if isImageFile(url), let src = NSImage(contentsOf: url) { img = src }
            if let i = img { self.cache.setObject(i, forKey: key) }
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

struct FileItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    let kind: String

    static func == (l: FileItem, r: FileItem) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct SidebarLocation: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
    let symbol: String
    var ejectable: Bool = false
}

// Shared dialogs / actions usable from menus and context menus.
func promptRename(_ browser: Browser, _ id: String) {
    guard let item = browser.items.first(where: { $0.id == id }) else { return }
    let a = NSAlert(); a.messageText = "Rename"; a.informativeText = "Enter a new name:"
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); f.stringValue = item.name
    a.accessoryView = f; a.addButton(withTitle: "Rename"); a.addButton(withTitle: "Cancel")
    if a.runModal() == .alertFirstButtonReturn { browser.rename(id: id, to: f.stringValue) }
}
func showInfo(_ browser: Browser, _ ids: Set<String>) {
    guard !ids.isEmpty else { return }
    let a = NSAlert(); a.messageText = "Get Info"; a.informativeText = browser.infoText(ids)
    a.addButton(withTitle: "OK"); a.runModal()
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
        let imgs = browser.items.filter { !$0.isDirectory && isImageFile($0.url) }.map { $0.url }
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

let imageExtensions: Set<String> = ["jpg","jpeg","png","gif","bmp","tiff","tif","heic","heif","webp","ico"]
func isImageFile(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }

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
    @Published var isRecents = false
    @Published var viewMode: ViewMode = .list { didSet { Prefs.viewModeIcon = (viewMode == .icon) } }
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
        pathText = start.path
        showHidden = Prefs.showHidden
        viewMode = Prefs.viewModeIcon ? .icon : .list
        iconSize = Prefs.iconSize
        groupBy = GroupBy(rawValue: Prefs.groupBy) ?? .none
        sortOrder = [Browser.comparator(for: SortField(rawValue: Prefs.sortKey) ?? .name, ascending: Prefs.sortAscending)]
        load()
        RecentFolders.shared.record(start)
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

    func icon(for item: FileItem) -> NSImage { NSWorkspace.shared.icon(forFile: item.url.path) }

    private func makeItem(_ u: URL) -> FileItem {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey]
        let rv = try? u.resourceValues(forKeys: keys)
        let isDir = rv?.isDirectory ?? false
        return FileItem(id: u.path, url: u, name: u.lastPathComponent,
                        isDirectory: isDir, size: Int64(rv?.fileSize ?? 0),
                        modified: rv?.contentModificationDate ?? Date.distantPast,
                        kind: rv?.localizedTypeDescription ?? (isDir ? "Folder" : "File"))
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
    func loadRecents() {
        isRecents = true
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
        selection = []
        items = []
        status = "Searching…"
        searchQuery?.stop()
        let q = NSMetadataQuery()
        q.searchScopes = [currentURL]
        q.predicate = NSPredicate(format: "kMDItemDisplayName LIKE[cd] %@ OR kMDItemTextContent CONTAINS[cd] %@", "*\(query)*", query)
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

    func load() {
        isRecents = false
        isSearching = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey,
                                      .contentModificationDateKey, .localizedTypeDescriptionKey]
        var opts: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !showHidden { opts.insert(.skipsHiddenFiles) }
        var result: [FileItem] = []
        if let urls = try? fm.contentsOfDirectory(at: currentURL, includingPropertiesForKeys: keys, options: opts) {
            for u in urls {
                let rv = try? u.resourceValues(forKeys: Set(keys))
                let isDir = rv?.isDirectory ?? false
                let size = Int64(rv?.fileSize ?? 0)
                let mod = rv?.contentModificationDate ?? Date.distantPast
                let kind = rv?.localizedTypeDescription ?? (isDir ? "Folder" : "File")
                result.append(FileItem(id: u.path, url: u, name: u.lastPathComponent,
                                       isDirectory: isDir, size: size, modified: mod, kind: kind))
            }
        }
        items = result
        pathText = currentURL.path
        selection = []
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
        RecentFolders.shared.record(url)
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
        guard !p.isEmpty else { pathText = currentURL.path; return }
        let url = URL(fileURLWithPath: p)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue { navigate(to: url) } else { NSWorkspace.shared.open(url); pathText = currentURL.path }
        } else { NSSound.beep(); pathText = currentURL.path }
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
    func copyName(_ ids: Set<String>) {
        let names = items.filter { ids.contains($0.id) }.map { $0.name }
        guard !names.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
    }
    func moveToTrash(_ ids: Set<String>) {
        let urls = items.filter { ids.contains($0.id) }.map { $0.url }
        var restores: [(trash: URL, original: URL)] = []
        for u in urls {
            var out: NSURL?
            do { try fm.trashItem(at: u, resultingItemURL: &out); if let t = out as URL? { restores.append((t, u)) } } catch {}
        }
        if !restores.isEmpty {
            UndoStack.shared.push("Move to Trash") { [weak self] in
                for r in restores { try? FileManager.default.moveItem(at: r.trash, to: r.original) }
                self?.load()
            }
        }
        load()
    }
    func newFolder() {
        let target = uniqueDest(currentURL, "New Folder")
        try? fm.createDirectory(at: target, withIntermediateDirectories: false)
        UndoStack.shared.push("New Folder") { [weak self] in
            try? FileManager.default.trashItem(at: target, resultingItemURL: nil); self?.load()
        }
        load()
    }
    func newTextFile() {
        let target = uniqueDest(currentURL, "New Text File.txt")
        fm.createFile(atPath: target.path, contents: Data())
        UndoStack.shared.push("New Text File") { [weak self] in
            try? FileManager.default.trashItem(at: target, resultingItemURL: nil); self?.load()
        }
        load()
    }

    // File clipboard
    var cutMode = false
    private func selectedURLs() -> [URL] { items.filter { selection.contains($0.id) }.map { $0.url } }
    func copyFiles() {
        let urls = selectedURLs(); guard !urls.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(urls as [NSURL]); cutMode = false
    }
    func cutFiles() {
        let urls = selectedURLs(); guard !urls.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(urls as [NSURL]); cutMode = true
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

    func pasteFiles() { copyURLs(pasteboardURLs(), move: cutMode) }

    private func pasteboardURLs() -> [URL] {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
    }

    // Background copy/move with a busy indicator (keeps the UI responsive on big transfers).
    func copyURLs(_ urls: [URL], move: Bool) {
        // Skip items that already live in this folder — dropping into the same
        // folder is a no-op (cancel), not a self-copy.
        let sources = urls.filter {
            $0.path != currentURL.path && $0.deletingLastPathComponent().path != currentURL.path
        }
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
        busy = true; busyText = move ? "Moving…" : "Copying…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var moved: [(from: URL, to: URL)] = []
            var copied: [URL] = []
            for src in sources {
                let dest = self.uniqueDest(dir, src.lastPathComponent)
                do {
                    if move { try FileManager.default.moveItem(at: src, to: dest); moved.append((src, dest)) }
                    else { try FileManager.default.copyItem(at: src, to: dest); copied.append(dest) }
                } catch {
                    // Cross-volume fallback: copy, then remove source if this was a move.
                    do {
                        try FileManager.default.copyItem(at: src, to: dest)
                        if move { try? FileManager.default.removeItem(at: src); moved.append((src, dest)) }
                        else { copied.append(dest) }
                    } catch {}
                }
            }
            DispatchQueue.main.async {
                if resetCut { self.cutMode = false }
                self.busy = false; self.busyText = ""
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
                self.load()
            }
        }
    }

    func makeAlias(_ ids: Set<String>) {
        var created: [URL] = []
        for it in items.filter({ ids.contains($0.id) }) {
            let aliasURL = uniqueDest(currentURL, it.url.deletingPathExtension().lastPathComponent + " alias")
            do {
                let data = try it.url.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                try URL.writeBookmarkData(data, to: aliasURL)
                created.append(aliasURL)
            } catch { NSSound.beep() }
        }
        if !created.isEmpty {
            UndoStack.shared.push("Make Alias") { [weak self] in
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
            UndoStack.shared.push("Rename") { [weak self] in
                try? FileManager.default.moveItem(at: dest, to: oldURL); self?.load()
            }
            load()
        } catch { NSSound.beep() }
    }

    func duplicate(_ ids: Set<String>) {
        var created: [URL] = []
        for it in items.filter({ ids.contains($0.id) }) {
            let ext = it.url.pathExtension
            let base = it.url.deletingPathExtension().lastPathComponent
            let name = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
            let dest = uniqueDest(currentURL, name)
            do { try fm.copyItem(at: it.url, to: dest); created.append(dest) } catch {}
        }
        if !created.isEmpty {
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
            try? p.run(); p.waitUntilExit()
            DispatchQueue.main.async {
                self?.busy = false; self?.busyText = ""
                UndoStack.shared.push("Compress") { [weak self] in
                    try? FileManager.default.trashItem(at: dest, resultingItemURL: nil); self?.load()
                }
                self?.load()
            }
        }
    }

    func emptyTrash() {
        let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        if let entries = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) {
            for e in entries { try? fm.removeItem(at: e) }
        }
    }
}

// MARK: - App model (tabs)

final class AppModel: ObservableObject {
    @Published var tabs: [Browser]
    @Published var selected: Int = 0
    @Published var showPreview: Bool = Prefs.showPreview { didSet { Prefs.showPreview = showPreview } }
    @Published var showSidebar: Bool = Prefs.showSidebar { didSet { Prefs.showSidebar = showSidebar } }
    @Published var columnCustomization: TableColumnCustomization<FileItem> = AppModel.loadColumns() {
        didSet { AppModel.saveColumns(columnCustomization) }
    }
    init() {
        tabs = [Browser(start: FileManager.default.homeDirectoryForCurrentUser)]
        // Refresh the sidebar the instant a disk/USB/network share mounts or ejects,
        // so new volumes appear (and stale ones disappear) automatically.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
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
    }
    func closeTab(_ index: Int) {
        guard tabs.indices.contains(index), tabs.count > 1 else { return }
        tabs.remove(at: index)
        if selected >= tabs.count { selected = tabs.count - 1 }
    }
}

// MARK: - Components

struct SidebarView: View {
    @ObservedObject var browser: Browser
    @ObservedObject var recents = RecentFolders.shared
    @ObservedObject var network = NetworkBrowser.shared
    let favorites: [SidebarLocation]

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

    var body: some View {
        let clouds = cloudLocations()
        let volumes = volumeLocations()
        List {
            Section("Favorites") {
                Button { browser.loadRecents() } label: {
                    Label("Recents", systemImage: "clock").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                ForEach(favorites) { row($0) }
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
            if !clouds.isEmpty {
                Section("Cloud") { ForEach(clouds) { row($0) } }
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
        }.listStyle(.sidebar)
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
            // Row 1: navigation + search + tools
            HStack(spacing: 8) {
                Button { model.showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help("Show/Hide Sidebar (⌥⌘S)")
                    .foregroundStyle(model.showSidebar ? Color.accentColor : .secondary)
                Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack).keyboardShortcut("[", modifiers: .command).help("Back")
                Button { browser.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!browser.canGoForward).keyboardShortcut("]", modifiers: .command).help("Forward")
                Button { browser.goUp() } label: { Image(systemName: "chevron.up") }
                    .keyboardShortcut(.upArrow, modifiers: .command).help("Enclosing Folder")

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("Search “\(folderName)”", text: $browser.searchText)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { browser.runSearch() }
                        .onChange(of: browser.searchText) {
                            if browser.searchText.isEmpty && browser.isSearching { browser.clearSearch() }
                        }
                    if !browser.searchText.isEmpty {
                        Button { browser.clearSearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .frame(maxWidth: .infinity)

                TextField("Filter", text: $browser.filterText).textFieldStyle(.roundedBorder).frame(width: 130)

                Menu {
                    Picker("Sort By", selection: sortFieldBinding) {
                        Text("Name").tag(SortField.name)
                        Text("Date Modified").tag(SortField.modified)
                        Text("Size").tag(SortField.size)
                        Text("Kind").tag(SortField.kind)
                    }
                    Toggle("Ascending", isOn: ascendingBinding)
                    Divider()
                    Picker("Group By", selection: $browser.groupBy) {
                        Text("None").tag(GroupBy.none)
                        Text("Kind").tag(GroupBy.kind)
                        Text("Date Modified").tag(GroupBy.date)
                        Text("Size").tag(GroupBy.size)
                    }
                    Divider()
                    Toggle("Show Hidden Files", isOn: $browser.showHidden)
                    Toggle("Show Preview Pane", isOn: $model.showPreview)
                } label: { Image(systemName: "slider.horizontal.3") }
                    .menuStyle(.borderlessButton).frame(width: 40).help("Sort, Group & View Options")

                Button { browser.newFolder() } label: { Image(systemName: "folder.badge.plus") }.help("New Folder")
                Button { browser.isSearching ? browser.runSearch() : browser.load() } label: { Image(systemName: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command).help("Refresh")
                Button { model.showPreview.toggle() } label: {
                    Image(systemName: model.showPreview ? "sidebar.right" : "sidebar.squares.right")
                }.help("Toggle Preview Pane").foregroundStyle(model.showPreview ? Color.accentColor : .secondary)
                Picker("", selection: $browser.viewMode) {
                    Image(systemName: "list.bullet").tag(ViewMode.list)
                    Image(systemName: "square.grid.2x2").tag(ViewMode.icon)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 86).help("View")
            }
            // Row 2: full-width address bar on its own line
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                TextField("Type a path and press Return", text: $browser.pathText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($addressFocused)
                    .onSubmit { browser.submitPath() }
                    .frame(maxWidth: .infinity)
                Button("") { addressFocused = true }.keyboardShortcut("l", modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
        }.padding(.horizontal, 10).padding(.vertical, 8)
    }

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

struct NameCell: View {
    let item: FileItem
    @ObservedObject var browser: Browser
    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: browser.icon(for: item)).resizable().frame(width: 16, height: 16)
            Text(item.name).lineLimit(1)
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

    var body: some View {
        Table(of: FileItem.self, selection: $browser.selection, sortOrder: $browser.sortOrder,
              columnCustomization: $columnCustomization) {
            TableColumn("Name", value: \.name) { item in
                NameCell(item: item, browser: browser)
            }.customizationID("name")
            TableColumn("Date Modified", value: \.modified) { item in
                Text(item.modified, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
            }.width(min: 150, ideal: 185).customizationID("modified")
            TableColumn("Size", value: \.size) { item in
                Text(item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).foregroundStyle(.secondary)
            }.width(min: 70, ideal: 90).customizationID("size")
            TableColumn("Kind", value: \.kind) { item in
                Text(item.kind).foregroundStyle(.secondary).lineLimit(1)
            }.width(min: 90, ideal: 130).customizationID("kind")
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
            }
            Button("Quick Look") { QuickLook.shared.show(browser.items.filter { ids.contains($0.id) }.map { $0.url }) }
            Button("Reveal in Finder") { browser.revealInFinder(ids) }
            Divider()
            if ids.count == 1 { Button("Rename…") { promptRename(browser, ids.first!) } }
            Button("Duplicate") { browser.duplicate(ids) }
            Button("Make Alias") { browser.makeAlias(ids) }
            Button("Get Info") { showInfo(browser, ids) }
            Button("Compress") { browser.compress(ids) }
            Divider()
            Button("Share…") { shareItems(browser.items.filter { ids.contains($0.id) }.map { $0.url }) }
            if let it = browser.items.first(where: { $0.id == ids.first }) {
                Button("Open in Terminal") { openInTerminal(it.isDirectory ? it.url : browser.currentURL) }
            }
            Divider()
            Button("Copy") { browser.copyFiles() }
            Button("Cut") { browser.cutFiles() }
            Button("Paste") { browser.pasteFiles() }
            Button("Copy Path") { browser.copyPath(ids) }
            Button("Copy Name") { browser.copyName(ids) }
            Divider()
            Button("Move to Trash") { browser.moveToTrash(ids) }
        } else {
            Button("Paste") { browser.pasteFiles() }
            Button("New Folder") { browser.newFolder() }
            Button("New Text File") { browser.newTextFile() }
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

struct IconGridView: View {
    let model: AppModel
    @ObservedObject var browser: Browser
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: browser.iconSize + 44), spacing: 12)] }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
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
            .onTapGesture(count: 2) { openItem(item, browser) }
            .onTapGesture(count: 1) { browser.selection = [item.id]; browser.updateStatus() }
            .dropDestination(for: URL.self) { urls, _ in
                guard item.isDirectory else { return false }
                browser.importURLs(urls, into: item.url, move: true); return true
            }
            .contextMenu {
                Button("Open") { openItem(item, browser) }
                if item.isDirectory { Button("Open in New Tab") { model.newTab(at: item.url) } }
                Button("Quick Look") { QuickLook.shared.show([item.url]) }
                Button("Reveal in Finder") { browser.revealInFinder([item.id]) }
                Divider()
                Button("Rename…") { promptRename(browser, item.id) }
                Button("Duplicate") { browser.duplicate([item.id]) }
                Button("Make Alias") { browser.makeAlias([item.id]) }
                Button("Get Info") { showInfo(browser, [item.id]) }
                Divider()
                Button("Share…") { shareItems([item.url]) }
                Button("Open in Terminal") { openInTerminal(item.isDirectory ? item.url : browser.currentURL) }
                Button("Copy Path") { browser.copyPath([item.id]) }
                Button("Copy Name") { browser.copyName([item.id]) }
                Button("Move to Trash") { browser.moveToTrash([item.id]) }
            }
    }
}

struct PreviewPane: View {
    @ObservedObject var browser: Browser
    @State private var thumb: NSImage?
    private static let df: DateFormatter = { let d = DateFormatter(); d.dateStyle = .medium; d.timeStyle = .short; return d }()
    private var item: FileItem? {
        let sel = browser.items.filter { browser.selection.contains($0.id) }
        return sel.count == 1 ? sel.first : nil
    }
    var body: some View {
        VStack(spacing: 12) {
            if let it = item {
                Group {
                    if let t = thumb { Image(nsImage: t).resizable().scaledToFit() }
                    else { Image(nsImage: browser.icon(for: it)).resizable().scaledToFit() }
                }.frame(maxWidth: 200, maxHeight: 200)
                Text(it.name).font(.headline).multilineTextAlignment(.center).lineLimit(3)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    infoRow("Kind", it.kind)
                    infoRow("Size", it.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: it.size, countStyle: .file))
                    infoRow("Modified", Self.df.string(from: it.modified))
                    if let c = (try? it.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate {
                        infoRow("Created", Self.df.string(from: c))
                    }
                    if let t = thumb { infoRow("Dimensions", "\(Int(t.size.width)) × \(Int(t.size.height))") }
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
        .onChange(of: browser.selection) { loadThumb() }
        .onAppear { loadThumb() }
    }
    @ViewBuilder private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(k).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Text(v).textSelection(.enabled).lineLimit(3)
        }
    }
    private func loadThumb() {
        guard let it = item else { thumb = nil; return }
        thumb = nil
        ThumbnailCache.shared.thumbnail(for: it.url) { img in
            if self.item?.url == it.url { self.thumb = img }
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
            ControlBar(model: model, browser: browser)
            Divider()
            if browser.isSearching {
                SearchBanner(browser: browser)
                Divider()
            } else {
                BreadcrumbBar(browser: browser)
                Divider()
            }
            Group {
                if browser.viewMode == .icon { IconGridView(model: model, browser: browser) }
                else { FileTableView(model: model, browser: browser, columnCustomization: $model.columnCustomization) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                browser.copyURLs(urls, move: false); return true
            }
            Divider()
            StatusBar(browser: browser)
        }
    }
}

// A real AppKit NSSplitView gives Finder-quality resizing: per-pane min/max,
// the file list absorbs window resizing while the sidebar/preview hold their
// width, remembered divider positions, and animated collapse of the side panes.
final class PaneSplitController: NSSplitViewController {
    let sidebarHC = NSHostingController(rootView: AnyView(EmptyView()))
    let contentHC = NSHostingController(rootView: AnyView(EmptyView()))
    let previewHC = NSHostingController(rootView: AnyView(EmptyView()))
    private var sidebarItem: NSSplitViewItem!
    private var previewItem: NSSplitViewItem!
    private let initialSidebarCollapsed: Bool
    private let initialPreviewCollapsed: Bool

    init(sidebarCollapsed: Bool, previewCollapsed: Bool) {
        initialSidebarCollapsed = sidebarCollapsed
        initialPreviewCollapsed = previewCollapsed
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "NavigatorPanes"   // remembers divider positions across launches
        splitView.identifier = NSUserInterfaceItemIdentifier("NavigatorPanes")

        // Critical: stop each SwiftUI host from pushing its intrinsic size back into
        // AppKit. Otherwise dragging a divider makes the split view (and the window)
        // resize to fit content instead of just trading width between two panes.
        // With this cleared, the split view's min/max + holding priorities are the
        // sole authority — a divider drag only redistributes its two neighbours.
        for hc in [sidebarHC, contentHC, previewHC] { hc.sizingOptions = [] }

        sidebarItem = NSSplitViewItem(viewController: sidebarHC)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        sidebarItem.isCollapsed = initialSidebarCollapsed

        let contentItem = NSSplitViewItem(viewController: contentHC)
        contentItem.minimumThickness = 420
        contentItem.canCollapse = false
        contentItem.holdingPriority = NSLayoutConstraint.Priority(250) // lowest → absorbs window resize

        previewItem = NSSplitViewItem(viewController: previewHC)
        previewItem.minimumThickness = 220
        previewItem.maximumThickness = 560
        previewItem.canCollapse = true
        previewItem.holdingPriority = NSLayoutConstraint.Priority(260)
        previewItem.isCollapsed = initialPreviewCollapsed

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(previewItem)
    }

    func setSidebar(collapsed: Bool) {
        guard let sidebarItem, sidebarItem.isCollapsed != collapsed else { return }
        sidebarItem.animator().isCollapsed = collapsed
    }
    func setPreview(collapsed: Bool) {
        guard let previewItem, previewItem.isCollapsed != collapsed else { return }
        previewItem.animator().isCollapsed = collapsed
    }
}

struct BrowserPane: NSViewControllerRepresentable {
    @ObservedObject var model: AppModel
    var browser: Browser

    func makeNSViewController(context: Context) -> PaneSplitController {
        let vc = PaneSplitController(sidebarCollapsed: !model.showSidebar, previewCollapsed: !model.showPreview)
        _ = vc.view // force viewDidLoad so items exist
        applyRootViews(vc)
        return vc
    }
    func updateNSViewController(_ vc: PaneSplitController, context: Context) {
        applyRootViews(vc)
        vc.setSidebar(collapsed: !model.showSidebar)
        vc.setPreview(collapsed: !model.showPreview)
    }
    private func applyRootViews(_ vc: PaneSplitController) {
        vc.sidebarHC.rootView = AnyView(SidebarView(browser: browser, favorites: defaultLocations()))
        vc.contentHC.rootView = AnyView(BrowserContent(model: model, browser: browser).id(browser.id))
        vc.previewHC.rootView = AnyView(PreviewPane(browser: browser))
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: model)
            Divider()
            BrowserPane(model: model, browser: model.active)
        }.frame(minWidth: 880, minHeight: 560)
    }
}

// MARK: - Image viewer (left/right scroll through folder images)

struct ImageViewerView: View {
    let urls: [URL]
    @State private var index: Int
    init(urls: [URL], index: Int) { self.urls = urls; _index = State(initialValue: index) }
    private func step(_ d: Int) {
        guard !urls.isEmpty else { return }
        index = (index + d + urls.count) % urls.count
    }
    var body: some View {
        ZStack {
            Color.black
            if urls.indices.contains(index), let img = NSImage(contentsOf: urls[index]) {
                Image(nsImage: img).resizable().scaledToFit().padding(44)
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
                if urls.indices.contains(index) {
                    Text("\(urls[index].lastPathComponent)    ·    \(index + 1) of \(urls.count)")
                        .font(.callout).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.black.opacity(0.55)).clipShape(Capsule()).padding(.bottom, 16)
                }
            }
        }.frame(minWidth: 520, minHeight: 420)
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
        window?.title = "Preview"
        window?.contentView = NSHostingView(rootView: ImageViewerView(urls: urls, index: index))
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - AppKit entry point

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let appModel = AppModel()
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMenu()
        let hosting = NSHostingView(rootView: ContentView(model: appModel))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Navigator"
        window.contentView = hosting
        window.setFrameAutosaveName("NavigatorMainWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor()
        NetworkBrowser.shared.start()
        // (No auto TCC prompt on launch — use the "Grant Full Disk Access…" menu command.)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Keyboard navigation for the file list/grid. Runs only when our window is key
    // and a text field isn't being edited, so typing in the address/search/filter
    // fields (and modal dialogs) is never disturbed.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
    }
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard NSApp.keyWindow == window else { return event }
        if let r = window.firstResponder, r is NSText || r is NSTextView { return event }
        let b = appModel.active
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 36, 76: // Return / Enter → open
            if !b.selection.isEmpty { b.openSelection(); return nil }
            return event
        case 51: // Delete/Backspace (no modifier) → enclosing folder
            if flags.isEmpty { b.goUp(); return nil }
            return event
        case 49: // Space → Quick Look
            if !b.selection.isEmpty {
                QuickLook.shared.show(b.items.filter { b.selection.contains($0.id) }.map { $0.url }); return nil
            }
            return event
        case 125: // Down
            if b.viewMode == .icon, flags.isEmpty { b.moveSelection(dy: 1); return nil }
            return event
        case 126: // Up
            if b.viewMode == .icon, flags.isEmpty { b.moveSelection(dy: -1); return nil }
            return event
        case 123: // Left
            if b.viewMode == .icon, flags.isEmpty { b.moveSelection(dx: -1); return nil }
            return event
        case 124: // Right
            if b.viewMode == .icon, flags.isEmpty { b.moveSelection(dx: 1); return nil }
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
        appMenu.addItem(.separator())
        let fda = appMenu.addItem(withTitle: "Grant Full Disk Access…", action: #selector(openFullDiskAccessAction(_:)), keyEquivalent: "")
        fda.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Navigator", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Navigator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File"); fileItem.submenu = fileMenu
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
        if appModel.tabs.count > 1 { appModel.closeTab(appModel.selected) } else { window.performClose(nil) }
    }
    @objc func newFolderAction(_ sender: Any?) { appModel.active.newFolder() }
    @objc func newTextFileAction(_ sender: Any?) { appModel.active.newTextFile() }
    @objc func moveToTrashAction(_ sender: Any?) { appModel.active.moveToTrash(appModel.active.selection) }
    @objc func getInfoAction(_ sender: Any?) { showInfo(appModel.active, appModel.active.selection) }
    @objc func duplicateAction(_ sender: Any?) { appModel.active.duplicate(appModel.active.selection) }
    @objc func renameAction(_ sender: Any?) { if let id = appModel.active.selection.first { promptRename(appModel.active, id) } }
    @objc func quickLookAction(_ sender: Any?) {
        let b = appModel.active
        QuickLook.shared.show(b.items.filter { b.selection.contains($0.id) }.map { $0.url })
    }
    @objc func compressAction(_ sender: Any?) { appModel.active.compress(appModel.active.selection) }
    @objc func emptyTrashAction(_ sender: Any?) { confirmEmptyTrash(appModel.active) }
    @objc func togglePreviewAction(_ sender: Any?) { appModel.showPreview.toggle() }
    @objc func toggleSidebarAction(_ sender: Any?) { appModel.showSidebar.toggle() }
    @objc func toggleHiddenAction(_ sender: Any?) { appModel.active.showHidden.toggle() }
    @objc func undoAction(_ sender: Any?) {
        // When editing text, let the field's own undo run; otherwise undo file operations.
        if let r = window.firstResponder, r is NSText || r is NSTextView,
           let um = window.undoManager, um.canUndo { um.undo(); return }
        UndoStack.shared.undo()
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
            if !s.isEmpty, let url = URL(string: s) { NSWorkspace.shared.open(url) }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
