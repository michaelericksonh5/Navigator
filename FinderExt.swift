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
            return m
        }
        guard menuKind == .contextualMenuForItems else { return nil }
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !urls.isEmpty else { return nil }

        let hasImage = urls.contains { Self.isImage($0) }
        let hasPNG = urls.contains { $0.pathExtension.lowercased() == "png" }
        let hasFolder = urls.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        let hasPSD = urls.contains { ["psd", "psb"].contains($0.pathExtension.lowercased()) }

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

        // Photoshop / After Effects entries only when that app is actually present,
        // matching what Navigator itself shows. Each carries the icon of the app or
        // service that does the work, so you can tell at a glance what a row will
        // launch. One separator divides "open" from "do something", which is the only
        // grouping worth a gap — two of them left the short menu looking sparse.
        if hasImage || hasFolder {
            sub.addItem(.separator())
            if Self.installed("com.adobe.Photoshop") {
                add(sub, "Remove BG", "removebg", Self.psIcon)
            }
            if Self.installed("com.adobe.AfterEffects"), hasPNG || hasFolder {
                add(sub, "Chroma Key BG", "chromakey", Self.aeIcon)
            }
            // Prep for AI is a ratio submenu crossed with a colour submenu in Navigator,
            // which is far too deep to reproduce here. Only the one combination worth a
            // single click is offered: the adaptive fill at the nearest supported ratio.
            // Anything more specific belongs in Navigator, where the depth is affordable.
            add(sub, "Prep for AI (Adaptive)", "prep-adaptive",
                Self.icon(systemSymbol: "wand.and.stars"))

            let up = NSMenuItem(title: "Upscale (AI)", action: nil, keyEquivalent: "")
            up.image = Self.icon(systemSymbol: "arrow.up.left.and.arrow.down.right")
            let upSub = NSMenu()
            // Addressed by INDEX into Navigator's own `upscaleOptions`, so the two menus
            // cannot drift: reorder that list and Finder follows. Titles are duplicated
            // here because the extension is a separate target and can't import them.
            add(upSub, "Crystal (best fidelity) ×4", "upscale-0", Self.falIcon)
            add(upSub, "AuraSR (non-generative) ×4", "upscale-1", Self.falIcon)
            add(upSub, "Topaz ×4", "upscale-2", Self.falIcon)
            add(upSub, "Local resample ×4 (free)", "upscale-3",
                Self.icon(systemSymbol: "desktopcomputer"))
            upSub.addItem(.separator())
            up.submenu = upSub
            sub.addItem(up)

            // Both open or drive Navigator itself rather than running silently, so they
            // read as "…" commands exactly as they do in Navigator's own menu.
            if hasImage {
                add(sub, "Restyle (AI)…", "restyle", Self.icon(systemSymbol: "paintbrush.pointed"))
                add(sub, "Layerize (AI)…", "layerize", Self.falIcon)
            }
        }

        // Photoshop documents are not "images" by extension, so this sits outside the
        // block above — a PSD-only selection reaches nothing else here.
        if hasPSD, Self.installed("com.adobe.Photoshop") {
            if !hasImage && !hasFolder { sub.addItem(.separator()) }
            add(sub, "Quick Export as PNG", "exportpng", Self.psIcon)
        }

        parent.submenu = sub
        root.addItem(parent)
        return root
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: String, _ image: NSImage? = nil) {
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        item.image = image
        menu.addItem(item)
    }

    // MARK: - Dispatch to Navigator

    /// Right-click empty space → open the folder being viewed.
    @objc private func openContainer(_ sender: NSMenuItem) {
        guard let here = FIFinderSyncController.default().targetedURL() else { return }
        openInNavigator([here])
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
        guard let action = sender.representedObject as? String else { return }
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !urls.isEmpty else { return }

        if action == "open" { openInNavigator(urls); return }
        // navigatoraction://<action>?hex=<hex of the newline-joined paths>. Hex keeps
        // spaces, quotes and non-ASCII names intact with no escaping questions.
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
    private static let aeIcon: NSImage? = appIcon("com.adobe.AfterEffects")
    private static let vertexIcon: NSImage? = bundled("vertex", fallback: "sparkles")
    private static let falIcon: NSImage? = bundled("fal", fallback: "bolt.fill")
}
