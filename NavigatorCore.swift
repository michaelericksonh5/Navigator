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

    /// The new element order after a sidebar drag-reorder, as indices into the
    /// original array, with one element optionally forced back to the front.
    ///
    /// Home is that pinned element: it's the fixed anchor of the Favorites list, so
    /// it returns to the top wherever it gets dropped — and it must also survive
    /// being displaced when something else is dropped above it. Index math after a
    /// move is easy to get subtly wrong, so it lives here where it can be tested.
    /// `to` follows SwiftUI's onMove convention: the dragged items end up just before
    /// whatever was originally at that offset (`count` means "to the end"). The move
    /// is spelled out rather than using Array.move(fromOffsets:toOffset:) because that
    /// lives in SwiftUI, and this file is deliberately UI-free so the tests can reach it.
    static func reorder(count: Int, from: IndexSet, to: Int, pinnedToFront pin: Int? = nil) -> [Int] {
        let picked = from.sorted().filter { $0 >= 0 && $0 < count }
        let moving = picked.map { $0 }
        var order = Array(0..<count)
        for i in picked.reversed() { order.remove(at: i) }
        // Every moved item that sat before the insertion point shifts it left.
        let insertAt = min(max(to - picked.filter { $0 < to }.count, 0), order.count)
        order.insert(contentsOf: moving, at: insertAt)
        if let pin, let at = order.firstIndex(of: pin), at != 0 {
            order.insert(order.remove(at: at), at: 0)
        }
        return order
    }

    /// A File Provider location — Google Drive, iCloud Drive and friends.
    static func isCloudProvider(_ url: URL) -> Bool {
        let p = url.path
        return p.contains("/Library/CloudStorage/") || p.contains("/Library/Mobile Documents/")
    }

    /// True when a drop must be forced to COPY because it takes items OUT of a cloud
    /// provider.
    ///
    /// Cloud providers live on the local volume, so comparing volume identifiers
    /// calls them "same volume" and a drag out would MOVE — deleting the original.
    /// On a shared team drive that removes it for everyone, from a gesture that looks
    /// like "give me a local copy". Rearranging within the provider stays a move.
    static func leavesCloudProvider(_ sources: [URL], into dest: URL) -> Bool {
        !isCloudProvider(dest) && sources.contains(where: isCloudProvider)
    }
}

/// Rules for "Restyle (AI)" — the pure, testable parts.
///
/// Everything here is Vertex-only, on purpose. An earlier version read a dropped
/// reference image's style, and the source image's identity, via a vision model
/// reached through fal — because the metered Vertex service has no endpoint that
/// returns TEXT from an image (confirmed by probing eight plausible route names,
/// all 404, and by watching /v1/images silently drop response_modalities and
/// thinking_level and return image-only no matter what's asked). Told to stop using
/// fal entirely, that vision pre-pass was removed. What replaced it, in order of
/// what was actually measured against the live service:
///
/// 1. Generic preservation wording ("keep the subject exactly as it is") is not an
///    anchor. The exact same single-image request, run twice, turned a lion
///    character into two different human men — reproduced, not noise.
/// 2. Naming concrete identity anchors instead — species/type, face, markings,
///    defining worn items — fixed that 2/2 on a single image.
/// 3. Asking a single Vertex call to "identify then preserve" a real second
///    reference image's subject, IN THE SAME generation pass, failed 3/3 across two
///    phrasings (the source became a fox, a mech-suited cat, a human swordsman) —
///    self-derived anchors inside one call are not reliable.
/// 4. Supplying the SAME kind of anchors as already-known text (not self-derived)
///    alongside a real second reference image, under explicit role labels ("IMAGE 1
///    is the exact character… IMAGE 2 is a style reference only…"), worked 2/2.
///
/// Net effect: identity anchors must exist as text before generation, and nothing
/// on Vertex can produce that text from a photo today, so the person restyling
/// types them. `restylePrompt` handles no reference (anchors + a style
/// description); `restylePromptTwoImage` reproduces the one two-image arrangement
/// proven to hold identity, and must not be reordered without re-testing — the
/// working order (source image first, reference second) is not what a naive
/// "last image wins" rule would predict.
enum RestyleRules {

    // MARK: - Aspect ratio

    /// Ratios the Gemini image endpoint accepts.
    /// "auto" lets the model keep the source's shape — the right default for a restyle,
    /// where reframing is the last thing wanted. The rest are the fixed ratios.
    static let aspects = ["auto", "21:9", "16:9", "3:2", "4:3", "5:4", "1:1", "4:5", "3:4", "2:3", "9:16"]

    /// Fixed ratios only — "auto" has no numeric shape, so nearest-match ignores it.
    static var fixedAspects: [String] { aspects.filter { $0 != "auto" } }

    /// The listed ratio closest to a real image's shape, so the sheet opens on
    /// something that won't reframe the art. Compared in log space, so being 10%
    /// too wide counts the same as 10% too tall — a plain difference of ratios
    /// biases towards the wide end (21:9 and 16:9 are further apart numerically
    /// than 9:16 and 2:3, though both are one step apart perceptually).
    static func nearestAspect(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "1:1" }
        let target = log(Double(width) / Double(height))
        return fixedAspects.min { a, b in
            abs(log(ratio(a)) - target) < abs(log(ratio(b)) - target)
        } ?? "1:1"
    }

    /// "16:9" -> 1.777…  Returns 1 for anything unparseable.
    static func ratio(_ aspect: String) -> Double {
        let p = aspect.split(separator: ":").compactMap { Double($0) }
        guard p.count == 2, p[1] != 0 else { return 1 }
        return p[0] / p[1]
    }

    // MARK: - Models

    /// Resolutions offered per model.
    ///
    /// Driven by the model table rather than a rule of thumb. An earlier version here
    /// hard-limited every flash model to 1K, on the strength of a note in the AI hub's
    /// client rather than a measurement — that was wrong to assert, and it hid sizes
    /// the newer models do render. Anything a model refuses comes back as a plain API
    /// error, which is better than a picker that quietly withholds an option.
    static func sizes(forModelFlag flag: String) -> [String] { ["1K", "2K", "4K"] }

    // MARK: - Prompts

    /// Single-image restyle: no reference, just the source and a typed description of
    /// the desired look. Identity anchors are stated FIRST and the style change LAST —
    /// reordering a working prompt to lead with the change and follow with "but keep X"
    /// measurably let identity drift on live runs; stating what must survive before
    /// what should change did not.
    static func restylePrompt(identityAnchors: String, styleText: String, extra: String = "") -> String {
        let anchors = anchorClause(identityAnchors, fallback: "same subject, same species, same face, same markings, same clothing.")
        var p = "This exact character must remain completely unchanged: " + anchors
            + " Same pose and composition, same aspect ratio, same text and lettering.\n\n"
            + "Redraw ONLY the rendering style, to match the following art style.\n\n"
            + "ART STYLE: \(styleText.trimmingCharacters(in: .whitespacesAndNewlines))"
        let e = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { p += "\n\nADDITIONAL DIRECTION: \(e)" }
        return p
    }

    /// Two-image restyle: a real style-reference image is sent alongside the source.
    /// This exact shape — role labels, source described as "IMAGE 1", reference as
    /// "IMAGE 2", identity anchors named as text before the style instruction — is the
    /// one combination that held identity 2/2 on a live model; generic role labels
    /// alone (no named anchors) failed on the same pairing. `anchors` empty is
    /// possible (the field is optional in the UI) and falls back to generic wording,
    /// same as the single-image path, at the same reduced reliability.
    static func restylePromptTwoImage(identityAnchors: String, extra: String = "") -> String {
        let anchors = anchorClause(identityAnchors, fallback: "keep its subject, species, face, markings and clothing exactly as they are.")
        var p = "IMAGE 1 is the exact character to redraw: " + anchors
            + " Keep this exact character unchanged — same species, same face, same markings, same clothing, "
            + "same pose and composition.\n\n"
            + "IMAGE 2 is a STYLE reference only. Do not copy its subject, objects, or text — "
            + "none of its content may appear in the output.\n\n"
            + "Redraw IMAGE 1's exact character using IMAGE 2's rendering technique, colour palette, "
            + "linework and lighting only."
        let e = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { p += "\n\nADDITIONAL DIRECTION: \(e)" }
        return p
    }

    /// The identity clause used by both prompt shapes: user-typed anchors if present
    /// (with a trailing period ensured, so it doesn't run into the next sentence —
    /// "...leather gloves Keep this exact character..." with no punctuation between
    /// them, which a live run tolerated but shouldn't have needed to), else a generic
    /// fallback.
    private static func anchorClause(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    }

    /// Words that mean a typed style description drifted into describing a subject
    /// rather than a style. Shown as a warning rather than a block — an art style
    /// legitimately called "painterly fur texture" might be intended, and it's the
    /// artist's call, not ours.
    static let leakWords = ["fur", "hair", "scales", "feathers", "skin", "leather",
                            "fabric", "armour", "armor", "face", "eyes", "mane", "fins"]

    /// Subject words that leaked into supposedly style-only text.
    static func styleLeaks(in text: String) -> [String] {
        let lower = text.lowercased()
        return leakWords.filter { w in
            guard let r = lower.range(of: w) else { return false }
            // Whole words only, so "skin" doesn't fire on "skinny" nor "face" on "surface".
            let before = r.lowerBound == lower.startIndex ? " "
                : String(lower[lower.index(before: r.lowerBound)])
            let after = r.upperBound == lower.endIndex ? " " : String(lower[r.upperBound])
            return !before.first!.isLetter && !after.first!.isLetter
        }
    }
}

extension RestyleRules {
    /// True when the source's shape is far enough from every ratio the model accepts
    /// that sending it as-is would get it reframed. 2% covers rounding in real exports
    /// (1920x1081 is 16:9 for our purposes) without waving through a genuinely odd crop.
    static func needsPadding(width: Int, height: Int, tolerance: Double = 0.02) -> Bool {
        guard width > 0, height > 0 else { return false }
        let actual = Double(width) / Double(height)
        let nearest = ratio(nearestAspect(width: width, height: height))
        return abs(actual - nearest) / nearest > tolerance
    }
}
