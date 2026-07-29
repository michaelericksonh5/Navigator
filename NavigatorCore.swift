// Pure path rules, shared by the app and its tests.
//
// Everything here is a plain function over paths/URLs with no UI, no Browser, and
// no app state — which is exactly why it lives in its own file: the test bundle
// compiles THIS file, not main.swift (a single-file SwiftUI app can't be imported
// by a test target). The rules below are the ones that actually caused damage in
// real use, so they're the ones worth pinning down with tests.

import Foundation

enum PathRules {

    /// True when `dir` is `src` itself or sits inside it.
    ///
    /// Copying or moving a folder into its own subtree must be refused: FileManager
    /// happily recurses into the copy it is creating and only stops when the path
    /// gets too long — a real run produced 231 junk directories nested over 1000
    /// characters deep. The `/` suffix matters: "/a/bc" is NOT inside "/a/b".
    static func isSelfOrDescendant(_ dir: URL, of src: URL) -> Bool {
        let s = src.standardizedFileURL.resolvingSymlinksInPath().path
        let d = dir.standardizedFileURL.resolvingSymlinksInPath().path
        return d == s || d.hasPrefix(s.hasSuffix("/") ? s : s + "/")
    }

    /// A favourite's location beneath its volume root:
    /// "/Volumes/Games/artSource" -> "artSource". Empty when the path IS the volume
    /// root. Used to re-anchor a network favourite when its share comes back on a
    /// different mountpoint (e.g. "Games-1" instead of "Games").
    static func shareRelativePath(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 2, parts[0] == "Volumes" else { return "" }
        return parts.dropFirst(2).joined(separator: "/")
    }

    /// First free "name", "name 2", "name 3"… in `dir`. Used for Keep Both on a
    /// name clash and for new folders/aliases/archives.
    static func uniqueDest(_ dir: URL, _ name: String, exists: (String) -> Bool) -> URL {
        var dest = dir.appendingPathComponent(name)
        guard exists(dest.path) else { return dest }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var i = 2
        while exists(dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            i += 1
        }
        return dest
    }

    /// Name for pasting a file into its own folder: "photo.jpg" -> "photo (1).jpg",
    /// then "(2)", "(3)"… (Explorer-style in-place duplicate).
    static func numberedCopyDest(_ dir: URL, _ name: String, exists: (String) -> Bool) -> URL {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        func make(_ n: Int) -> URL {
            dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
        }
        var i = 1, dest = make(1)
        while exists(dest.path) { i += 1; dest = make(i) }
        return dest
    }

    /// True for an output this app produced, so batch runs skip their own results
    /// and re-running is safe. `suffix` is "_rmbg" or "_upscaled".
    static func isOwnOutput(_ url: URL, suffix: String) -> Bool {
        url.deletingPathExtension().lastPathComponent.lowercased().hasSuffix(suffix)
    }
}
