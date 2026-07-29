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
        // Finder only offers our menu for items inside directories we observe.
        // Watch the places people actually keep work: home, every mounted volume
        // (network drives included), and the cloud providers.
        // Observe the whole filesystem root. Finder only offers an extension's menu
        // for items inside an observed directory, and Navigator's actions make sense
        // anywhere — home, network volumes, cloud folders. Narrower roots (home,
        // /Volumes) are not honoured for this purpose.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/", isDirectory: true)]
    }

    // MARK: - Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // Only for a selection of items; the container/sidebar menus would just be
        // noise since every action needs something selected.
        guard menuKind == .contextualMenuForItems else { return nil }
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !urls.isEmpty else { return nil }

        let hasImage = urls.contains { Self.isImage($0) }
        let hasPNG = urls.contains { $0.pathExtension.lowercased() == "png" }
        let hasFolder = urls.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }

        let root = NSMenu()
        let parent = NSMenuItem(title: "Navigator", action: nil, keyEquivalent: "")
        parent.image = Self.appIcon
        let sub = NSMenu()

        add(sub, "Open in Navigator", "open")

        // Photoshop / After Effects entries only when that app is actually present,
        // matching what Navigator itself shows.
        if hasImage || hasFolder {
            if Self.installed("com.adobe.Photoshop") {
                sub.addItem(.separator())
                add(sub, "Remove BG", "removebg")
            }
            if Self.installed("com.adobe.AfterEffects"), hasPNG || hasFolder {
                add(sub, "Chroma Key BG", "chromakey")
            }
            sub.addItem(.separator())
            let up = NSMenuItem(title: "Upscale (AI)", action: nil, keyEquivalent: "")
            let upSub = NSMenu()
            add(upSub, "Upscale Low Quality ×4", "upscale-lowq")
            add(upSub, "Upscale (Imagen 4) ×2", "upscale-imagen2")
            add(upSub, "Upscale (Imagen 4) ×4", "upscale-imagen4")
            up.submenu = upSub
            sub.addItem(up)
        }

        parent.submenu = sub
        root.addItem(parent)
        return root
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: String) {
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        menu.addItem(item)
    }

    // MARK: - Dispatch to Navigator

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !urls.isEmpty else { return }

        if action == "open" {
            NSWorkspace.shared.open(urls, withApplicationAt: Self.appURL,
                                    configuration: NSWorkspace.OpenConfiguration())
            return
        }
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
    private static let appIcon: NSImage? = {
        let img = NSWorkspace.shared.icon(forFile: appURL.path)
        img.size = NSSize(width: 16, height: 16)
        return img
    }()
}
