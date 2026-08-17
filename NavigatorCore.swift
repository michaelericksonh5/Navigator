// Pure path rules, shared by the app and its tests.
//
// Everything here is a plain function over paths/URLs with no UI, no Browser, and
// no app state — which is exactly why it lives in its own file: the test bundle
// compiles THIS file, not main.swift (a single-file SwiftUI app can't be imported
// by a test target). The rules below are the ones that actually caused damage in
// real use, so they're the ones worth pinning down with tests.

import Foundation
// CoreGraphics only — no AppKit. The pixel sampling behind the adaptive backing colour
// lives here so `swift test` exercises the SHIPPED code rather than a copy of it.
import CoreGraphics

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

    /// The deepest of `roots` that contains `url`, or nil if none do.
    ///
    /// Used to answer "which mounted volume is this folder actually on?" for Eject.
    /// Deepest, not first match: "/" contains every path, and a volume can be
    /// mounted inside another one — the longer mount point is always the real owner.
    static func deepestRoot(containing url: URL, among roots: [URL]) -> URL? {
        roots.filter { isSelfOrDescendant(url, of: $0) }
             .max { $0.standardizedFileURL.path.count < $1.standardizedFileURL.path.count }
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

    /// True when renaming an item to `dest` would clobber a DIFFERENT item, so the
    /// user has to be asked before anything touches the disk.
    ///
    /// `isSameItem` must be a file-IDENTITY check (fileResourceIdentifier), never a
    /// path or string comparison. macOS volumes are case-insensitive by default, so
    /// renaming "photo.png" -> "Photo.png" finds the file ITSELF sitting at the
    /// destination: a bare `exists` check calls that a collision and refuses a rename
    /// that FileManager.moveItem performs perfectly happily.
    static func renameCollides(dest: String,
                               exists: (String) -> Bool,
                               isSameItem: (String) -> Bool) -> Bool {
        exists(dest) && !isSameItem(dest)
    }

    /// Why `name` can't be used as a filename, or nil if it can.
    ///
    /// "/" is the POSIX path separator and ":" is the classic-Mac one the Finder still
    /// swaps with "/" when it displays a name. Handed to FileManager they either build
    /// a path into some other directory or fail with "the file doesn't exist" —
    /// an error naming a folder the user never mentioned, which explains nothing.
    static func invalidNameReason(_ name: String) -> String? {
        if name.contains("/") { return "A file name can’t contain “/”." }
        if name.contains(":") { return "A file name can’t contain “:”." }
        return nil
    }

    /// The extension change a rename makes, or nil when there's nothing worth raising
    /// Finder's "are you sure you want to change the extension?" prompt over.
    ///
    /// Directories are exempt: Foundation happily reports a pathExtension for a folder
    /// named "My.Backups", but nothing opens a folder by extension, so warning about it
    /// is pure noise. Only the LAST dot component counts, which is why "archive.tar.gz"
    /// -> "archive.tar.bz2" reports gz -> bz2 and says nothing about ".tar". Case
    /// differences count ("a.PNG" -> "a.png"): the name on disk really does change.
    static func extensionChange(from old: String, to new: String,
                                isDirectory: Bool) -> (from: String, to: String)? {
        guard !isDirectory else { return nil }
        let o = (old as NSString).pathExtension, n = (new as NSString).pathExtension
        return o == n ? nil : (o, n)
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

    /// Every way a Google Drive location can be written down, re-anchored onto ONE
    /// Mac's Drive account root (".../Library/CloudStorage/GoogleDrive-me@x.com").
    ///
    /// Four inputs, one answer: a full path from ANOTHER Mac (different home folder,
    /// different account email), the username-free "Google Drive/…" form Navigator's
    /// own Copy Local Path produces, a bare "Shared drives/…" or "My Drive/…", and —
    /// for free, because it carries the same marker — a path that is already correct
    /// here, which re-anchors onto itself and comes back byte-identical.
    ///
    /// nil means "not a Drive path", never "couldn't fix it": callers keep whatever
    /// they had rather than substituting a guess. The account folder is the one
    /// component always dropped, because it is the one thing that is never portable.
    static func googleDrivePath(_ input: String, accountRoot: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var rel: String?
        if let r = s.range(of: "/CloudStorage/GoogleDrive-") {
            let after = s[r.upperBound...]
            if let slash = after.firstIndex(of: "/") { rel = String(after[after.index(after: slash)...]) }
        } else if s.hasPrefix("Google Drive/") {
            rel = String(s.dropFirst("Google Drive/".count))
        // Matched on a whole component, not a prefix: "Shared drivesXYZ" is somebody
        // else's folder name, and anchoring it under Drive would invent a path.
        } else if driveRoots.contains(where: { s == $0 || s.hasPrefix($0 + "/") }) {
            rel = s
        }
        // A leading "/" would make appending produce "…/GoogleDrive-me//Shared drives",
        // and an empty tail would silently hand back the account root — neither is a
        // location anyone asked for.
        guard let rel, !rel.isEmpty, !rel.hasPrefix("/") else { return nil }
        return accountRoot + "/" + rel
    }

    /// The two folders Drive for desktop always mounts at the account root.
    private static let driveRoots = ["Shared drives", "My Drive"]

    /// The drive-relative path ("Shared drives/A/B") for a chain of folder titles
    /// walked from an item UP to its root — the order a parent walk produces.
    ///
    /// A shared drive's root folder is the drive itself, and Drive for desktop mounts
    /// those one level down under "Shared drives"; a My Drive walk already ends at a
    /// folder called "My Drive", so that one needs no prefix. Feed the result back
    /// through `googleDrivePath` rather than joining a real path here — one place
    /// knows where the mount lives.
    static func driveRelativePath(leafFirst chain: [String], isSharedDrive: Bool) -> String? {
        guard !chain.isEmpty, !chain.contains(where: { $0.isEmpty }) else { return nil }
        let parts = (isSharedDrive ? ["Shared drives"] : []) + chain.reversed()
        guard driveRoots.contains(parts[0]) else { return nil }
        return parts.joined(separator: "/")
    }

    /// The Drive item id inside a drive.google.com / docs.google.com link, which is
    /// the only part of such a URL that means anything locally — Drive for desktop
    /// stamps that same id on the synced file as an xattr.
    ///
    /// Covers the three shapes Google hands out: /drive/folders/<id>, /file/d/<id>/view
    /// (and every /<kind>/d/<id> Docs variant), and the legacy /open?id=<id>.
    static func googleDriveItemID(webURL: String) -> String? {
        guard let c = URLComponents(string: webURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = c.host, host == "drive.google.com" || host == "docs.google.com"
        else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(where: { $0 == "folders" || $0 == "d" }), i + 1 < parts.count {
            return validDriveID(parts[i + 1])
        }
        return validDriveID(c.queryItems?.first { $0.name == "id" }?.value)
    }

    /// Drive ids are long base64url-ish strings. Checked so that a truncated or
    /// decorative URL ("/drive/folders/" + nothing, ".../d/view") yields nil instead
    /// of a lookup for a word.
    private static func validDriveID(_ s: String?) -> String? {
        guard let s, s.count >= 12,
              s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return s
    }
}

/// Index Tab / ⇧Tab should land on, given where the selection is now.
///
/// Split out from the Browser because the two ends are where this goes wrong and a
/// UI test can't pin them down: Swift's `%` returns a NEGATIVE remainder for a
/// negative left operand, so the obvious `(cur + delta) % count` sends ⇧Tab on the
/// first item to index -1 and traps. Adding `count` before the modulo is what makes
/// the backwards wrap land on the last item. `nil` (nothing selected yet) starts at
/// the first item going forward and the last going backward, so Tab into an empty
/// selection always picks the end you're heading away from.
func cycledSelectionIndex(from current: Int?, delta: Int, count: Int) -> Int? {
    guard count > 0 else { return nil }
    guard let cur = current else { return delta < 0 ? count - 1 : 0 }
    return ((cur + delta) % count + count) % count
}

/// Rules for "Restyle (AI)" — the pure, testable parts.
///
/// Everything here is Vertex-only. Two things were wrong at different points and
/// are worth recording so they don't get re-learned the hard way:
///
/// 1. There is no Vertex endpoint that returns TEXT from an image — confirmed by
///    probing ~15 plausible route names (all 404) and by posting real vision
///    models straight to /v1/images, which correctly rejects anything outside its
///    four-model image-generation allowlist. A vision pre-pass briefly went
///    through fal to work around that; told to stop, which is how /v1/vision came
///    to exist instead — a small endpoint on the SAME Vertex service, added
///    specifically for this (see the ops runbook).
/// 2. Separately, and discovered only while wiring up /v1/vision: the image
///    generation call (H5GService.image) was silently sending every input image
///    under the wrong JSON key ("data" instead of "base64", the key the service
///    actually reads). No error, no 400 — the image was just never attached.
///    Proved directly: a request naming a completely different subject, with a
///    real photo attached under the wrong key, generated the wrong subject with
///    zero trace of the real photo. Every restyle before that fix was pure
///    text-to-image generation from the prompt, not an edit of the source — it
///    only ever looked like editing when the prompt's identity anchors were
///    specific enough to regenerate something recognizable from scratch.
///
/// With that fixed, the source image is a genuine edit target and a reference
/// image is a genuine second input. Named identity anchors ("golden mane, lion
/// face" rather than "the subject") remain the right call regardless — it's
/// Google's own documented guidance for holding identity through an edit, not a
/// workaround for the transport bug — but they're no longer trying to make up
/// for an image that was never there. `restylePrompt` handles no reference;
/// `restylePromptTwoImage` handles a real second reference image, source first,
/// reference second — re-test before reordering.

/// Which of the two possible images actually reach the model: the SOURCE (the file
/// being restyled) and the style REFERENCE. Either can be withheld, leaving its side
/// of the job to text alone — a content description instead of the source, style notes
/// instead of the reference.
///
/// This exists as one named type rather than two loose Bools because four things have
/// to stay in agreement about the mode: which prompt shape is used ("preserve this
/// image" vs "create a new image"), whether padding means anything (it only protects a
/// source image that's actually being sent), whether an empty content description is
/// fatal (it is, when the description is the only thing defining the subject), and what
/// gets recorded in the output's metadata. Deriving each of those separately from
/// `sendSource`/`sendReference` is how they'd drift apart.
enum RestyleInputMode: String {
    /// Source + reference: redraw this image in that image's style. The original mode.
    case editWithStyleImage
    /// Source only: redraw this image in a described style.
    case editWithStyleText
    /// Reference only: build the subject from its description, in that image's style.
    case createWithStyleImage
    /// Neither: pure text-to-image from a described subject and a described style.
    case createWithStyleText

    init(sendSource: Bool, sendReference: Bool) {
        switch (sendSource, sendReference) {
        case (true, true):   self = .editWithStyleImage
        case (true, false):  self = .editWithStyleText
        case (false, true):  self = .createWithStyleImage
        case (false, false): self = .createWithStyleText
        }
    }

    var sendsSource: Bool { self == .editWithStyleImage || self == .editWithStyleText }
    var sendsReference: Bool { self == .editWithStyleImage || self == .createWithStyleImage }

    /// True when the content description is the ONLY thing defining the subject, so an
    /// empty one can't produce a restyle of anything — it produces an unrelated image.
    var needsContentText: Bool { !sendsSource }

    /// Padding exists to stop Nano Banana flattening a transparent SOURCE to black.
    /// With no source image being sent there is nothing to pad.
    var padApplies: Bool { sendsSource }

    /// Recorded in the output PNG so a file can still say how it was made months later.
    var label: String {
        switch self {
        case .editWithStyleImage:   return "source + style image"
        case .editWithStyleText:    return "source + style text"
        case .createWithStyleImage: return "text content + style image"
        case .createWithStyleText:  return "text only"
        }
    }
}

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

    // MARK: - Vision prompts (describe an image in text, via /v1/vision)

    /// Describes WHAT IS IN the source image and HOW IT IS LAID OUT, so a restyle can
    /// change the rendering without losing content. Read on the SOURCE image.
    ///
    /// This started out character-centric — "describe the persistent IDENTITY of the
    /// main subject" — and that failed badly on real work. Given a slot pay table
    /// holding ~20 symbols, four pay panels and dozens of numbers, it picked the one
    /// hooded avatar inside it and returned "a mysterious shadowy figure wearing a
    /// hooded sweatshirt"; the restyle then dutifully produced exactly that, one
    /// character full-frame, and the entire layout was gone. Most art here is a sheet
    /// or art board, not a single subject, so "the main subject" was the wrong frame.
    ///
    /// It also used to invite "distinguishing markings or colouring" and "colour
    /// scheme", which is actively counterproductive: colour and texture are precisely
    /// what a restyle replaces, so naming them drags the old look into the new one.
    /// Style is now explicitly forbidden here and lives only in styleSystemPrompt.
    static let identitySystemPrompt = """
        Describe WHAT IS IN this image and HOW IT IS LAID OUT, so it can be redrawn in a completely different art style without losing any content.

        The image may be any of these — describe whichever it actually is:
        - a sheet or art board holding many symbols, icons and labels (very common)
        - a single character, creature, or object
        - a background, environment or scene with no characters at all
        - a UI element: panel, frame, banner, button, badge, pay table

        Always cover:
        - What kind of image it is, in an opening clause.
        - The layout: how many distinct elements there are and how they are arranged (grid, rows, columns, groups) and roughly where each sits.
        - Every distinct element, briefly — what it depicts. Account for all of them.
        - ALL visible text, numbers and labels, transcribed EXACTLY, and where each belongs.
        - Structural parts: frames, panels, borders, dividers, badges.

        NEVER mention: colour, shade, tone or hue of ANYTHING — not the background, not a border, not a material. "wooden", "metal", "leaf" are fine as WHAT something is; "dark reddish-brown wood", "green leaf", "gold border" are not, because the colour word alone is enough to drag the old palette into a restyle that changes it. If you would name a colour, describe the material or shape instead and stop there. Also never mention: art style, palette, texture, shading, lighting, glow, finish, or mood — all replaced, all forbidden for the same reason.

        Be complete rather than brief — if there are twenty symbols, account for twenty. Plain prose or a compact list. No preamble.
        """

    /// Extracts a reusable ART STYLE from a reference image, read on the REFERENCE.
    /// The hard rules are load-bearing and were tuned against a live model: a version
    /// that only said "don't mention the subject" still returned "fine strands of fur"
    /// and "sheen of leather" for a lion in leather robes — material nouns that would
    /// grow fur on a fish. Naming the banned materials explicitly, and asking for
    /// rendering behaviour instead, produced zero leakage.
    static let styleSystemPrompt = """
        You extract a reusable ART STYLE from a reference image so it can be applied \
        to a COMPLETELY DIFFERENT subject.

        Describe ONLY: medium and rendering technique, brush/line quality, palette and \
        colour temperature, lighting character and direction, contrast and value range, \
        surface finish, edge treatment, level of detail, grain/texture, and overall mood.

        HARD RULES — breaking these ruins the result:
        - Never name or imply the subject: no species, creature, person, character, \
        clothing, props, setting, or body parts.
        - Never name materials that belong to the subject (e.g. fur, hair, scales, \
        feathers, skin, leather, fabric, metal armour). Describe HOW surfaces are \
        rendered instead — "fine high-frequency detail on organic surfaces", \
        "soft specular sheen".
        - No composition, framing, pose, or background layout.
        - Output style directives only, as one dense paragraph under 110 words, no preamble.
        """

    // MARK: - Prompts

    /// Single-image restyle: no reference, just the source and a typed description of
    /// the desired look. Contents are stated FIRST and the style change LAST —
    /// reordering to lead with the change and follow with "but keep X" measurably let
    /// content drift on live runs.
    ///
    /// The preservation clause used to read "This exact character must remain
    /// unchanged… same species, same face, same markings, same clothing", which is
    /// meaningless for a pay table or a background and actively harmful: it told the
    /// model to think in terms of a creature, and a 20-symbol art board came back as
    /// one hooded figure. It now protects elements, counts, layout and text instead.
    static func restylePrompt(identityAnchors: String, styleText: String, extra: String = "") -> String {
        let contents = anchorClause(identityAnchors,
                                    fallback: "everything currently in the image, exactly as arranged.")
        let style = styleText.trimmingCharacters(in: .whitespacesAndNewlines)
        var p = """
            \(preserveClause)

            CONTENTS TO PRESERVE: \(contents)

            Now replace the art style of this image with the following:

            ART STYLE: \(style)
            """
        let e = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { p += "\n\nADDITIONAL STYLE NOTES: \(e)" }
        return p
    }

    /// Two-image restyle: a real style-reference image alongside the source. Role
    /// labels ("IMAGE 1 is…", "IMAGE 2 is a style reference only…") are what keep the
    /// reference's own subject out of the output; without them the reference took the
    /// output over entirely on live runs.
    static func restylePromptTwoImage(identityAnchors: String, extra: String = "") -> String {
        let contents = anchorClause(identityAnchors,
                                    fallback: "everything currently in IMAGE 1, exactly as arranged.")
        var p = """
            IMAGE 1 is the artwork to redraw. \(preserveClause)

            CONTENTS OF IMAGE 1 TO PRESERVE: \(contents)

            IMAGE 2 is a STYLE reference ONLY. Do not copy its subject, objects, layout \
            or text — none of its content may appear in the output.

            Now replace the art style of IMAGE 1 with the art style of IMAGE 2 — its \
            rendering technique, colour palette, linework and lighting only.
            """
        let e = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { p += "\n\nADDITIONAL STYLE NOTES: \(e)" }
        return p
    }

    /// The contents clause used by both prompt shapes: the description if there is one
    /// (with a trailing period ensured so it doesn't run into the next sentence), else a
    /// generic fallback that still forbids reinterpretation.
    private static func anchorClause(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    }

    /// The content-preservation demand shared by both prompt shapes. Deliberately about
    /// elements, counts, layout and text rather than a character — a pay table, a
    /// background and a UI panel all have to survive this, not just a creature.
    private static let preserveClause = """
        Keep every part of the content exactly as it is: each element, its position, size \
        and count, the overall layout, and all text and numbers character-for-character. Do \
        not add, remove, merge, crop, rearrange or reinterpret anything, and do not collapse \
        a multi-element layout into a single subject.
        """

    /// The counterpart to preserveClause for the two modes that send NO source image.
    /// There is no existing image to protect, so this demands completeness of the
    /// DESCRIPTION instead of fidelity to a source — but it keeps preserveClause's
    /// hard-won lessons, because they apply just as much when drawing a pay table
    /// from a description as when redrawing one: account for every element, don't
    /// invent extras, and get the text exactly right.
    private static let createClause = """
        Create a NEW image from the description below. Draw every element it names, in the \
        arrangement it describes, and reproduce all text and numbers character-for-character. \
        Do not add elements it does not mention, and do not collapse a multi-element layout \
        into a single subject.
        """

    /// Text-to-image: no source image and no reference image. The content description
    /// IS the subject here, not a set of anchors protecting an existing image, so the
    /// wording flips from "preserve" to "create" — telling a model to "keep every part
    /// exactly as it is" when it has no image to look at invites it to invent one and
    /// call that faithful.
    ///
    /// Contents first, style last, mirroring restylePrompt for the same measured
    /// reason: leading with the style change let the subject drift on live runs.
    static func generatePrompt(contents: String, styleText: String, extra: String = "") -> String {
        let c = anchorClause(contents, fallback: "the subject described by the art style notes below.")
        let style = styleText.trimmingCharacters(in: .whitespacesAndNewlines)
        var p = """
            \(createClause)

            CONTENTS TO CREATE: \(c)

            Render it in the following art style:

            ART STYLE: \(style)
            """
        let e = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { p += "\n\nADDITIONAL STYLE NOTES: \(e)" }
        return p
    }

    /// One image is attached and it is the STYLE reference — no source image. The role
    /// label carries even more weight than in restylePromptTwoImage: with nothing to
    /// redraw, an unlabelled reference is simply "the image", and the model returns its
    /// subject straight back. Same failure the two-image prompt already had to defend
    /// against, minus the source image that used to compete for the model's attention.
    static func generatePromptStyleImage(contents: String, extra: String = "") -> String {
        let c = anchorClause(contents, fallback: "the subject described by the style notes below.")
        var p = """
            \(createClause)

            CONTENTS TO CREATE: \(c)

            The attached image is a STYLE reference ONLY. Do not copy its subject, objects, \
            layout or text — none of its content may appear in the output. Take from it only \
            the rendering technique, colour palette, linework and lighting.
            """
        let e = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { p += "\n\nADDITIONAL STYLE NOTES: \(e)" }
        return p
    }

    /// The single place that turns "which images are we sending?" into a prompt, so the
    /// UI, the metadata and the prompt can never disagree about the mode.
    ///
    /// The styleText/extra split is NOT uniform across modes, and that asymmetry is
    /// deliberate and pre-existing: when an IMAGE carries the style, typed style text is
    /// demoted to supplementary notes, because a full style paragraph competing with a
    /// style reference wins and defeats the point of attaching the reference at all.
    /// When no image carries the style, that same text IS the style.
    static func prompt(mode: RestyleInputMode, contents: String,
                       styleText: String, extra: String = "") -> String {
        let folded = [styleText, extra].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: ". ")
        switch mode {
        case .editWithStyleImage:   return restylePromptTwoImage(identityAnchors: contents, extra: folded)
        case .editWithStyleText:    return restylePrompt(identityAnchors: contents, styleText: styleText, extra: extra)
        case .createWithStyleImage: return generatePromptStyleImage(contents: contents, extra: folded)
        case .createWithStyleText:  return generatePrompt(contents: contents, styleText: styleText, extra: extra)
        }
    }

    /// Style words that should NOT appear in a CONTENTS description. The contents field
    /// says what must survive; naming colour or texture there fights the new style
    /// instead of protecting the layout. Shown as a caution, not a block — the artist
    /// may have a reason.
    ///
    /// Started as a dozen buzzwords curated from one earlier failure (a neon slot
    /// symbol description) and that was too narrow: tested on a real vision-model
    /// output, it missed "dark reddish-brown wooden plank" entirely, and an A/B
    /// restyle proved that leak was not cosmetic — the version WITH "dark
    /// reddish-brown" in the contents came back with a visibly darker, redder panel
    /// than the version with it removed, on an otherwise identical prompt. Broadened
    /// to plain colour names, since those are what actually constrain a recolor, not
    /// just the buzzwords one bad example happened to use.
    static let styleWordsInContent = ["neon", "glowing", "glow", "glitchy", "pixelated",
                                      "aesthetic", "aesthetics", "palette", "gradient",
                                      "shading", "textured", "retro", "vibrant", "hued",
                                      "colour", "color", "shade", "tone", "hue",
                                      "red", "reddish", "orange", "yellow", "green",
                                      "blue", "cyan", "magenta", "purple", "violet",
                                      "pink", "brown", "black", "white", "grey", "gray",
                                      "gold", "golden", "silver", "bronze", "copper",
                                      "dark", "light", "bright", "pale", "deep", "muted",
                                      "pastel", "warm-toned", "cool-toned"]

    /// Style words found in a contents description, OUTSIDE quoted text.
    ///
    /// A contents description legitimately quotes on-image text verbatim — "VOLCANO
    /// GOLD" as a wordmark — and that quoted colour word is required transcription,
    /// not a style leak; scanning it anyway flagged a clean, fully-compliant
    /// description as if it had a problem. Quoted spans are blanked out before the
    /// scan so only the surrounding prose (which is where a real leak lives) counts.
    static func styleLeaksInContents(_ text: String) -> [String] {
        var scan = text
        for quote in ["\"", "\u{201C}\u{201D}"] {
            let opens = quote == "\"" ? "\"" : "\u{201C}"
            let closes = quote == "\"" ? "\"" : "\u{201D}"
            while let start = scan.range(of: opens),
                  let end = scan.range(of: closes, range: start.upperBound..<scan.endIndex) {
                scan.replaceSubrange(start.lowerBound..<end.upperBound,
                                     with: String(repeating: " ", count: scan.distance(from: start.lowerBound, to: end.upperBound)))
            }
        }
        let lower = scan.lowercased()
        return styleWordsInContent.filter { w in
            guard let r = lower.range(of: w) else { return false }
            let before = r.lowerBound == lower.startIndex ? " "
                : String(lower[lower.index(before: r.lowerBound)])
            let after = r.upperBound == lower.endIndex ? " " : String(lower[r.upperBound])
            return !before.first!.isLetter && !after.first!.isLetter
        }
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

extension RestyleRules {
    /// Default output resolution. 2K, not 1K: measured 2026-07-30, NB2 with
    /// `image_size: "2K"` really does return 2K pixels (2528x1684 from a 1024px
    /// source, 1680 image tokens, $0.1014) — the AI hub runbook's old "flash caps
    /// ~1K" note was wrong and has been corrected. Art going into a game wants the
    /// larger render, and the price difference is a few cents.
    static let defaultSize = "2K"

    /// Default backing colour for transparent art. Magenta, not white: it's the
    /// least likely colour to appear in real artwork, so anything the model leaves
    /// behind from the padding is unmistakable rather than blending into pale
    /// linework — and it matches the greenscreen/magenta convention already in
    /// Prep for AI's colour list.
    static let defaultPadColorName = "MagentaScreen"

    /// True when a Vertex error is worth retrying rather than failing the item.
    ///
    /// Vertex returns transient 503 UNAVAILABLE under load — seen repeatedly while
    /// testing. On a one-off restyle that's a visible annoyance; in a batch of
    /// twenty it would abandon the rest of the queue for a condition that clears in
    /// seconds, so these are retried and everything else fails fast.
    static func isTransient(_ error: String) -> Bool {
        let e = error.lowercased()
        return e.contains("503") || e.contains("unavailable")
            || e.contains("429") || e.contains("resource_exhausted")
            || e.contains("timed out") || e.contains("timeout")
            || e.contains("network connection was lost")
    }
}

// MARK: - Undo / redo of file operations

/// One half of an undoable operation. Returns nil on success, or a message naming
/// what went wrong.
///
/// It reports rather than just running because the filesystem changes underneath
/// recorded operations all the time — the user bins the file in Finder, a share
/// drops, a folder gets renamed. The old `try?`-and-shrug closures turned that into
/// a silent no-op, which reads as "Undo is broken"; the returned message is what
/// the user actually gets shown.
typealias UndoAction = () -> String?

/// Undo/redo stack for file operations.
///
/// Both halves are supplied at push time rather than having `undo()` hand back its
/// own inverse. Several operations land somewhere different every time they re-run
/// — re-trashing an item gets a fresh, de-duplicated path inside the Trash — so the
/// two halves must share mutable state. Capturing one local `var` in both closures
/// does that in a line; threading an inverse back out through every early return of
/// fifteen call sites does not.
final class UndoStack {
    static let shared = UndoStack()
    struct Entry { let desc: String; let undo: UndoAction; let redo: UndoAction }

    /// 200, not the old 50: an entry is two closures over a handful of URLs, a few
    /// hundred bytes, so history is essentially free and the old cap threw away a
    /// morning's work to save nothing. The drop stays silent — an alert about a
    /// ceiling nobody reaches is pure nagging.
    static let limit = 200

    private(set) var undoStack: [Entry] = []
    private(set) var redoStack: [Entry] = []

    /// Injected by the app. This type is compiled into the test bundle, which has no
    /// business beeping or opening alerts, so the two user-visible outcomes are hooks
    /// rather than direct AppKit calls.
    var onEmpty: () -> Void = {}
    var onFailure: (_ summary: String, _ detail: String) -> Void = { _, _ in }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var topDescription: String? { undoStack.last?.desc }
    var topRedoDescription: String? { redoStack.last?.desc }

    func push(_ desc: String, undo: @escaping UndoAction, redo: @escaping UndoAction) {
        undoStack.append(Entry(desc: desc, undo: undo, redo: redo))
        if undoStack.count > Self.limit { undoStack.removeFirst() }
        // Any NEW operation invalidates every pending redo. Those closures hold paths
        // the new operation may have just renamed, moved or binned, so replaying one
        // would act on files the user never asked about — the classic corruption bug
        // in hand-rolled undo.
        redoStack.removeAll()
    }

    func undo() {
        guard let e = undoStack.popLast() else { onEmpty(); return }
        // A failed half DROPS the entry (popLast already removed it and we return
        // without re-filing it): its recorded state is demonstrably wrong now, and
        // offering to replay it would only compound the mess.
        if let problem = e.undo() { onFailure("Couldn’t undo \(e.desc)", problem); return }
        redoStack.append(e)
        if redoStack.count > Self.limit { redoStack.removeFirst() }
    }

    func redo() {
        guard let e = redoStack.popLast() else { onEmpty(); return }
        if let problem = e.redo() { onFailure("Couldn’t redo \(e.desc)", problem); return }
        // Straight append, NOT push(): push() clears the redo stack, which would make
        // a redo wipe out every remaining redo behind it.
        undoStack.append(e)
        if undoStack.count > Self.limit { undoStack.removeFirst() }
    }

    /// Only for tests and for a fresh app state — the app never discards history.
    func clear() { undoStack.removeAll(); redoStack.removeAll() }
}

/// Sequence a batch of moves so none of them lands on a path another move in the same
/// batch has not vacated yet.
///
/// The bug this fixes: Batch Rename records its undo pairs in the order it renamed, and
/// undo replayed them in exactly that order. Rename B→C and then A→B — a chain, and the
/// order the listing hands the pairs over whenever B sorts ahead of A — records undo as
/// C→B, B→A, and replaying that moves C onto the B that A is still sitting on. moveItem
/// fails, so Undo reported an error and left the batch half restored.
///
/// Emitting only the moves whose destination nothing else still holds is the whole fix
/// for a chain, and it leaves a batch with no interdependencies in its original order —
/// which is every other caller of restoreItems. A true CYCLE (A→B, B→A) has no such move
/// at all, so one member is parked under a name nobody wants and finished last.
/// `applyRenames`' own `fileExists` guard means a cycle cannot currently reach here — it
/// skips any rename whose destination already exists, so a swap renames nothing — but
/// undo is the path that moves the user's files back, and "the caller filters that out
/// today" is exactly the guarantee that stops being true without anyone noticing.
///
/// `tempSuffix` is a parameter only so a test can pin it; nothing in the app passes it.
func collisionSafeOrder(_ pairs: [(from: URL, to: URL)],
                        tempSuffix: @autoclosure () -> String = UUID().uuidString) -> [(from: URL, to: URL)] {
    var remaining = pairs
    var out: [(from: URL, to: URL)] = []
    while !remaining.isEmpty {
        let occupied = Set(remaining.map { $0.from.path })
        var ready: [(from: URL, to: URL)] = []
        var blocked: [(from: URL, to: URL)] = []
        for p in remaining { occupied.contains(p.to.path) ? blocked.append(p) : ready.append(p) }
        if ready.isEmpty {
            // Every move left wants a path another one still holds: park the first out of
            // the way, which frees its own path and unblocks whoever was waiting on it.
            var p = blocked.removeFirst()
            let parked = p.from.appendingPathExtension(tempSuffix())
            out.append((from: p.from, to: parked))
            p.from = parked
            blocked.append(p)
        } else {
            out += ready
        }
        remaining = blocked
    }
    return out
}

/// Moves each `from` back to its `to`, collecting what failed into one message.
///
/// Every undo/redo closure funnels through this so an item the user deleted or moved
/// in Finder after the operation names itself in a single alert, instead of being
/// swallowed by `try?` and looking like Undo did nothing. That single funnel is also
/// why the collision ordering lives here rather than in Batch Rename: any caller whose
/// pairs overlap gets it without having to know it exists.
func restoreItems(_ pairs: [(from: URL, to: URL)]) -> String? {
    var failed: [String] = []
    for p in collisionSafeOrder(pairs) {
        do { try FileManager.default.moveItem(at: p.from, to: p.to) }
        catch { failed.append("• \(p.to.lastPathComponent): \(error.localizedDescription)") }
    }
    return failed.isEmpty ? nil : failed.prefix(5).joined(separator: "\n")
}

/// Bins each URL and hands back where each one landed, so the matching half can
/// restore exactly these items.
///
/// Restoring from the Trash, rather than re-running the original operation, is what
/// makes redo safe for anything that CREATES items: re-running would rebuild an
/// empty "New Folder" and throw away whatever the user had dropped into it, or
/// re-zip contents that have since changed.
func trashItems(_ urls: [URL]) -> (restores: [(from: URL, to: URL)], problem: String?) {
    var restores: [(from: URL, to: URL)] = []
    var failed: [String] = []
    for u in urls {
        var out: NSURL?
        do {
            try FileManager.default.trashItem(at: u, resultingItemURL: &out)
            if let t = out as URL? { restores.append((from: t, to: u)) }
        } catch { failed.append("• \(u.lastPathComponent): \(error.localizedDescription)") }
    }
    // Remember where each one came from, so the Trash view's Put Back can restore it
    // even after the app has been quit and relaunched. Recorded HERE because every
    // trash operation in the app funnels through either this or moveToTrash — putting
    // it in only one of them is how half the Trash ends up unrestorable.
    TrashOrigins.record(restores)
    return (restores, failed.isEmpty ? nil : failed.prefix(5).joined(separator: "\n"))
}

// MARK: - Clipboard text forms for a selection

/// The text forms the "Copy …" context-menu items put on the clipboard.
///
/// These live here — and are tested — because every one of them is a quoting rule,
/// and quoting is exactly what goes wrong invisibly: a path holding a space, a
/// double quote or a `]` looks correct in the menu and then breaks whatever it was
/// pasted into. Multi-selection joins with newlines to match the existing
/// `Copy Path`, so the plain and the quoted item differ ONLY in the quoting.
enum PathText {

    /// Windows' "Copy as path": the path wrapped in double quotes so pasting it into a
    /// shell survives spaces. Backslash and double quote are escaped because those are
    /// the two characters a POSIX filename may legally contain that a double-quoted
    /// shell word still interprets — leaving a raw `"` in would end the quoted run
    /// early and hand the shell a mangled command.
    static func quoted(_ paths: [String]) -> String {
        paths.map { p in
            let esc = p.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(esc)\""
        }.joined(separator: "\n")
    }

    /// `file://` URLs. Percent-encoded by URL itself, which is what a browser or a
    /// Markdown link needs — a raw path with a space in it is not a usable URL.
    static func fileURLs(_ paths: [String]) -> String {
        paths.map { URL(fileURLWithPath: $0).absoluteString }.joined(separator: "\n")
    }

    /// Base names with the extension dropped: "shot.png" → "shot".
    ///
    /// A dotfile (".gitignore") is deliberately returned whole: its dot starts the
    /// name rather than an extension, and treating it as one would copy an empty
    /// string. A name with no dot at all is likewise returned unchanged.
    static func namesWithoutExtension(_ names: [String]) -> String {
        names.map { n -> String in
            guard let dot = n.lastIndex(of: "."), dot != n.startIndex else { return n }
            return String(n[n.startIndex..<dot])
        }.joined(separator: "\n")
    }

    /// `[name](file:///…)`, pasteable into Markdown.
    ///
    /// BOTH brackets are escaped, not just the closing one. CommonMark accepts raw
    /// brackets in link text only as a matched pair, so a filename like "shot [1].png"
    /// with only its `]` escaped leaves an unmatched `[` and the whole link stops
    /// parsing — it pastes as visible junk instead of a link.
    static func markdownLinks(_ items: [(name: String, path: String)]) -> String {
        items.map { i in
            let label = i.name.replacingOccurrences(of: "\\", with: "\\\\")
                              .replacingOccurrences(of: "[", with: "\\[")
                              .replacingOccurrences(of: "]", with: "\\]")
            return "[\(label)](\(URL(fileURLWithPath: i.path).absoluteString))"
        }.joined(separator: "\n")
    }
}

// MARK: - Tab context-menu enablement

/// Which items a tab's right-click menu may offer, as plain index arithmetic.
///
/// Kept here so "would this actually do anything?" is decided once and pinned by
/// tests: an off-by-one shows up as a menu item that looks enabled and then does
/// nothing at all, which reads as a broken app rather than a disabled command.
enum TabMenuRules {
    static func canCloseOthers(index: Int, count: Int) -> Bool {
        count > 1 && (0..<count).contains(index)
    }
    static func canCloseToRight(index: Int, count: Int) -> Bool {
        index >= 0 && index < count - 1
    }
    /// Moving the ONLY tab out would leave an empty window behind, so it's refused
    /// rather than silently producing one.
    static func canMoveToNewWindow(index: Int, count: Int) -> Bool {
        count > 1 && (0..<count).contains(index)
    }
}

/// What ⌘W / File ▸ Close Tab should actually do.
enum CloseTabOutcome: Equatable {
    /// Something that isn't a browser window (Settings, Get Info, a viewer) holds key and
    /// owns ⌘W — closing a tab behind it would take a tab the user can still see.
    case closeKeyWindow
    case closeTab
    /// Last tab: closing it would leave an empty window, so close the window instead.
    case closeBrowserWindow
}

/// Extracted and tested because the inline version had a silent-no-op hole: it gated on
/// `NSApp.keyWindow is NavWindow`, so when there was NO key window at all (the app can be
/// frontmost with none — dismissing an alert or a non-activating panel leaves it that way)
/// the guard failed and the fallback ran `nil?.performClose(nil)`. ⌘W and File ▸ Close Tab
/// did nothing whatsoever, silently, while both stayed enabled.
///
/// `hasKeyWindow == false` must therefore still act on the front browser window, which is
/// what the caller's `lastKeyNavWindow` fallback resolves.
enum CloseTabRules {
    static func outcome(hasKeyWindow: Bool, keyWindowIsBrowser: Bool, tabCount: Int) -> CloseTabOutcome {
        if hasKeyWindow && !keyWindowIsBrowser { return .closeKeyWindow }
        return tabCount > 1 ? .closeTab : .closeBrowserWindow
    }
}

/// Turns an Adobe script failure into something worth showing a person.
///
/// The raw strings are internal: `ERROR: [open]` is the .jsx's own step marker, and
/// "the open options are incorrect" is Photoshop's way of saying a file isn't really a PSD.
/// Shown verbatim in a summary dialog it reads as a Navigator malfunction rather than
/// "this one file is broken", which is the opposite of the truth.
enum AdobeErrorText {
    /// Ordered: the first match wins, so specific phrases must precede generic ones.
    private static let plain: [(needle: String, text: String)] = [
        ("open options are incorrect",
         "not a readable Photoshop file — it may be damaged, or another format renamed .psd"),
        ("cannot open the file",
         "Photoshop couldn’t open this file — it may be damaged or still copying"),
        ("could not be found",       "the file wasn’t there when Photoshop looked for it"),
        ("is not a valid",           "not a valid Photoshop document"),
        ("damaged",                  "the file appears to be damaged"),
        ("unsupported",              "Photoshop doesn’t support this file type"),
        ("is not currently available",
         "Photoshop was busy and never answered — try again in a moment"),
        ("timed out",                "Photoshop took too long to respond"),
        ("disk",                     "Photoshop ran out of scratch disk space"),
    ]

    /// `"stub.psd: ERROR: [open] Cannot open the file because…"`
    ///   → `"stub.psd: not a readable Photoshop file — it may be damaged, or another…"`
    /// An unrecognised message keeps its text, just without the internal step marker — never
    /// swallowed, because an unexplained failure still has to be reportable.
    static func friendly(_ line: String) -> String {
        // Split "<file>: <message>" so the filename survives untouched.
        let head: String, body: String
        if let r = line.range(of: ": ") {
            head = String(line[line.startIndex..<r.lowerBound]) + ": "
            body = String(line[r.upperBound...])
        } else {
            head = ""; body = line
        }
        let lower = body.lowercased()
        if let hit = plain.first(where: { lower.contains($0.needle) }) { return head + hit.text }
        // Strip "ERROR: " and any "[step]" marker from anything we don't have wording for.
        var rest = body
        if let r = rest.range(of: "ERROR: ") { rest.removeSubrange(r) }
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            rest = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        return head + rest
    }
}

// MARK: - When an Adobe app is actually wedged (vs. just handed a bad file)

/// Decides whether repeated Photoshop/After Effects failures mean the APP is wedged — the
/// only condition a restart can fix.
///
/// The old rule was purely "two attempts failed, restart the app", which never asked why.
/// Feeding it one corrupt .psd made it quit and relaunch Photoshop: the file was invalid, the
/// app was perfectly healthy, and a restart could not possibly help. That matters beyond
/// being useless — the restart escalates to `forceTerminate()` when a polite quit is blocked,
/// and what blocks a polite quit is precisely an unsaved-changes dialog. So the old rule could
/// destroy someone's unsaved work because one file in a batch was corrupt.
enum AdobeRecoveryRules {
    /// Signatures of a genuinely unresponsive app: it briefly cannot service scripting at all.
    private static let wedgeSignatures = [
        "is not currently available",          // 'The command "Get" is not currently available'
        "timed out",
        "connection is invalid",
        "application isn’t running",
        "application isn't running",
        "no document open",
    ]

    /// Signatures of a file the app looked at and refused. Nothing to recover from.
    private static let badFileSignatures = [
        "cannot open the file",
        "open options are incorrect",
        "could not be found",
        "is not a valid",
        "damaged",
        "unsupported",
        "no such file",
    ]

    static func looksWedged(_ message: String) -> Bool {
        let m = message.lowercased()
        // A bad file wins outright: an [open]-step refusal naming the file is never a wedge,
        // even though Photoshop dresses it up in the same "General Photoshop error" wrapper.
        if badFileSignatures.contains(where: { m.contains($0) }) { return false }
        if wedgeSignatures.contains(where: { m.contains($0) }) { return true }
        // Failing at the very first step, repeatedly, with no file-specific reason given, is
        // the shape of an app that cannot answer — treat that as wedged.
        return m.contains("[open]") || m.contains("[activedocument]")
    }
}

// MARK: - Seedream 5.0 Pro Layerize

enum LayerizeCheck: Equatable {
    case ok
    /// Outside the endpoint's limits but fixable by resampling. Never done silently.
    case needsResize(reason: String, to: (w: Int, h: Int))
    case reject(reason: String)

    static func == (a: LayerizeCheck, b: LayerizeCheck) -> Bool {
        switch (a, b) {
        case (.ok, .ok): return true
        case let (.needsResize(r1, t1), .needsResize(r2, t2)): return r1 == r2 && t1 == t2
        case let (.reject(r1), .reject(r2)): return r1 == r2
        default: return false
        }
    }
}

/// Rules for `bytedance/seedream/v5/pro/layerize`, all established by measurement against the
/// live endpoint rather than assumed.
enum LayerizeRules {
    // Documented input limits.
    static let minSide = 512, maxSide = 6000
    static let minPixels = 512 * 512, maxPixels = 6000 * 6000
    static let maxBytes = 30 * 1024 * 1024
    static let minAspect = 1.0 / 16, maxAspect = 16.0
    /// base + up to 16 layers.
    static let maxLayers = 17

    /// Output sizes to try, in order.
    ///
    /// `auto` FIRST, because that is the API's own default and its documented behaviour is exactly
    /// what we want: "auto adapts to the input image while preserving each element's aspect ratio."
    ///
    /// This code used to never send it. It computed an explicit tier from a pixel-count threshold
    /// because an earlier session saw one 422 at `auto` and concluded there was a resolution
    /// "floor" — a mechanism that appears nowhere in fal's schema. We now know refusals are
    /// sometimes TRANSIENT: SF2_Pearl was declined once and then accepted on a byte-identical
    /// request. So that single 422 was most likely transient, and an entire tier system was built
    /// to work around it, which then produced its own refusals and inconsistent output sizes.
    ///
    /// Second attempt is `auto` again — the cheap fix for a transient refusal.
    ///
    /// Third is ONE explicit tier, and only as a last resort. Capped at three attempts because
    /// each one is a paid generation.
    static func sizeLadder(width: Int, height: Int) -> [String] {
        ["auto", "auto", lastResortSize(width: width, height: height)]
    }

    /// The explicit tier to fall back to when `auto` will not play.
    ///
    /// Empirical, and narrow: SF1_Red (632×791) was refused at `auto_1K` and accepted at
    /// `auto_1.5K`, so for a stubborn image asking for MORE output resolution is what worked.
    /// Hence one step above whatever the input would naturally suggest.
    static func lastResortSize(width: Int, height: Int) -> String {
        (width * height >= 1536 * 1536) ? "auto_2K" : "auto_1.5K"
    }

    /// Preflight against fal's DOCUMENTED limits, which are a pixel COUNT, not a per-side one:
    /// "The image must contain between 512x512 and 6000x6000 total pixels, have an aspect ratio
    /// between 1/16 and 16, and be no larger than 30 MB."
    ///
    /// The old version enforced 512 and 6000 as per-SIDE bounds, which is stricter than the API.
    /// A 300×1000 image (300,000 px) or an 8000×4000 one (32 MP) both satisfy the real limits and
    /// were being resampled for no reason — losing quality to a rule fal never stated.
    static func check(width w: Int, height h: Int, bytes: Int) -> LayerizeCheck {
        guard w > 0, h > 0 else { return .reject(reason: "not a readable image") }
        let ar = Double(w) / Double(h)
        guard ar >= minAspect, ar <= maxAspect else {
            return .reject(reason: "aspect ratio \(String(format: "%.2f", ar)):1 is outside the supported 1:16–16:1 range")
        }
        let px = w * h
        if px > maxPixels {
            let s = (Double(maxPixels) / Double(px)).squareRoot()
            let t = (max(1, Int((Double(w) * s).rounded(.down))), max(1, Int((Double(h) * s).rounded(.down))))
            return .needsResize(reason: "\(w)×\(h) is \(String(format: "%.1f", Double(px) / 1e6)) MP, over Layerize's 36 MP total", to: t)
        }
        if px < minPixels {
            let s = (Double(minPixels) / Double(px)).squareRoot()
            let t = (max(1, Int((Double(w) * s).rounded(.up))), max(1, Int((Double(h) * s).rounded(.up))))
            return .needsResize(reason: "\(w)×\(h) is \(String(format: "%.2f", Double(px) / 1e6)) MP, under Layerize's 0.26 MP total", to: t)
        }
        if bytes > maxBytes {
            return .needsResize(reason: "file is \(String(format: "%.1f", Double(bytes) / 1_048_576)) MB, over the 30 MB limit", to: (w, h))
        }
        return .ok
    }

    /// A layer that came back empty or isn't a PNG must never be written or recorded.
    ///
    /// `Data(contentsOf:)` succeeds on a ZERO-BYTE response, so a failed download was being
    /// written as an empty file, counted as saved, and listed in _layers.json — while the
    /// filesystem (Google Drive, in the observed case) quietly discarded it. Two real layers went
    /// missing that way: L01_Outer_black_background and L00_base.
    static func isPlausiblePNG(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 100 && Array(bytes.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    }

    /// VERIFIED 2026-08-12 by keeping the base on a mostly-transparent input (frame.png): fal
    /// returned a 2477x1703 plate that was 100% opaque with a colour standard deviation of 0.53 —
    /// blank white, none of the artwork in it. Discarding it is right, and it is NOT where a missing
    /// element hides. For a mostly-OPAQUE input the base is instead a real inpainted background
    /// (SF4_Blue's came back as the full underwater scene), which is why it is kept there.
    /// Keep fal's base image, or throw it away?
    ///
    /// The base is worth keeping only when fal had a real background to inpaint. For a CUTOUT it has
    /// nothing to work from and invents a backdrop, which arrives as grey and white blocks behind
    /// the art — that is what a user saw on a dragon symbol saved with its background removed.
    ///
    /// The test is the OUTER EDGE, not the overall transparent fraction. Overall cannot separate the
    /// cases: that dragon measured 15.7% transparent and an opaque framed symbol 15.4%, so the cutout
    /// slipped under a 20% bar and its invented base was kept. Measured around the border instead,
    /// cutouts sit at 96-99% and real scenes at 0%, so the bar can go anywhere in that gap.
    /// Two signals, because either one alone has a blind spot.
    ///
    /// The border catches the ordinary cutout. But art that runs to the edge on some sides — a
    /// character cropped at the bottom, a full-bleed panel with a transparent corner — can show an
    /// opaque border while still being a cutout, and would keep an invented base. Overall
    /// transparency catches that: measured, real scenes are at 0.0% and every cutout at 15% or more,
    /// so anything with meaningful transparency anywhere is treated as a cutout.
    ///
    /// Verified against six real assets — border / overall:
    ///     bluebird 0.0/0.0   mockup 0.0/0.0                      -> keep
    ///     dragon 96.7/15.7   frame 96.9/22.9   character 96.0/54.8   framed symbol 98.8/15.4 -> discard
    static func shouldKeepBase(borderTransparentFraction: Double,
                               overallTransparentFraction: Double) -> Bool {
        borderTransparentFraction < 0.50 && overallTransparentFraction < 0.02
    }

    /// The line that must be in EVERY layerize prompt.
    ///
    /// fal returns names and descriptions in Chinese without it, and the layer filenames are built
    /// from those names — an early run produced twelve layers all called "unnamed". It is never
    /// replaced by the user's text, only prepended to it.
    static let basePrompt = "Return name and description in english."

    /// What actually gets sent as `prompt`.
    ///
    /// fal documents this field as "instructions describing which elements to separate", and it is
    /// the only lever over WHAT comes back: with it empty the model separates "the major elements",
    /// which for a single character is three or four blobs. Naming the parts — "Separate guns,
    /// triggers, hands, and arms out from image" — is what produces per-limb layers, including
    /// left/right instances as their own layers.
    ///
    /// A GENERIC completeness instruction was measured and does NOT help: "separate every distinct
    /// structural element, leaving no part unassigned" scored 1.378% uncovered against 1.144% for no
    /// instruction at all. Specific beats generic, so nothing generic is added here — only what the
    /// user actually asked for.
    static func composePrompt(_ userText: String?) -> String {
        guard let raw = userText else { return basePrompt }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return basePrompt }
        // Someone pasting the whole prompt back in shouldn't get the base line twice.
        if t.hasPrefix(basePrompt) { return t }
        return basePrompt + "\n" + t
    }

    /// fal bills this endpoint by COMPUTE SECONDS at $0.00017 — from fal's own pricing API, checked
    /// 2026-08-12. The previous estimate invented a per-layer price and reported roughly 10x too
    /// much; it also chose a tier from `image.width` in the response, and that field is never
    /// present, so it silently fell to the cheap tier on every call anyway.
    ///
    /// Wall-clock is the only timing Navigator can see and it includes queueing, so this can only
    /// ever be an upper bound — display it as approximate, never as a billed figure.
    static let costPerComputeSecond = 0.00017
    static func estimatedCost(seconds: Double) -> Double { max(0, seconds) * costPerComputeSecond }

    /// Filesystem-safe WITHOUT destroying non-ASCII.
    ///
    /// Layerize returns Chinese names unless the prompt asks for English, and an ASCII-only
    /// sanitiser turned every one of them into an empty string — twelve layers all landed as
    /// "unnamed", distinguished only by index. Keep the characters; strip only what a
    /// filesystem genuinely cannot take.
    static func safeName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let illegal = Set("/:\\<>\"|?*")
        var out = String(raw.unicodeScalars.filter { !illegal.contains(Character($0)) && !CharacterSet.controlCharacters.contains($0) })
        out = out.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: "_")
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_. "))
        return String(out.prefix(60))
    }

    /// `<Original>_L03_Left_Dragon_Frame.png`. Index is included because layer NAMES can repeat
    /// and z_index ordering is NOT stable between runs — the same image ordered its layers
    /// differently on two separate calls, so the index alone can't identify a layer either.
    static func fileName(stem: String, zIndex: Int, name: String?) -> String {
        let label = safeName(name)
        let suffix = label.isEmpty ? (zIndex == 0 ? "base" : "layer") : label
        return String(format: "%@_L%02d_%@.png", stem, zIndex, suffix)
    }

    // The per-layer cost model that used to live here was invented — fal bills this endpoint by
    // compute second (see estimatedCost). It reported roughly 10x too much, and picked its tier from
    // `image.width`, a field fal never actually returns, so it always fell to the cheap rate anyway.
}

// MARK: - Columns that are too expensive to show on a network volume

/// Which Details columns are worth their cost on a slow volume.
///
/// Measured on two real SMB shares:
///
/// * **Owner** was the worst by a distance. `FileItem.owner` did a fresh `stat` per read, and
///   the cell reads it on every SwiftUI render pass — 669 rows on //fileserver-a/Games cost
///   ~60 SECONDS per pass, repeatably, because the SMB client never cached it. Memoizing that
///   fixed the repeat cost; not asking for it at all fixes the first pass too.
/// * **Date Created / Last Opened / Added / Tags** need attributes beyond the ones the listing
///   already fetches. On //fileserver-b/data those extras cost ~187 ms per entry on first
///   fetch, even with name/size/date for the same folder already cached.
///
/// Everything left is genuinely free: Name and Ext come straight off the filename, Kind is
/// derived from the extension by `localKind` with no I/O at all, and Size and Date Modified
/// arrive with the directory listing whether asked for or not.
enum NetworkColumnRules {
    static let costlyOnNetwork: Set<String> = ["created", "accessed", "owner", "duration", "dimensions"]

    /// Hidden on network volumes even when enabled globally — the point is that browsing a
    /// share never pays for a column, not that the preference is edited behind the user's back.
    /// Local folders always show exactly what was asked for.
    /// The DEFAULT column set for a network folder nobody has arranged by hand.
    ///
    /// Name, Ext and Kind and nothing else, because these three are the only columns
    /// that cost NOTHING: the name comes from readdir, and Ext and Kind are derived from
    /// it with no I/O at all. Whether a row is a folder comes free too, from readdir's
    /// d_type. So this set renders a complete, correct listing with zero per-file I/O —
    /// measured at 429 ms for artSource's 669 files.
    ///
    /// Size and Date Modified are deliberately NOT here. An earlier version of this
    /// comment claimed they were free because they "ride along in the same stat"; that
    /// was wrong — they ARE the stat, at 89 ms PER ENTRY on //fileserver-a/Games (a DFS
    /// namespace). That is 59 s for artSource, and 10.9 s for a 116-item folder. The cost
    /// is the server's, not the API's: resourceValues, raw lstat, 8/16/32-way concurrent
    /// lstat, and getattrlistbulk (all 669 in a single syscall) all land within
    /// 73-106 ms/entry cold. Concurrency buys nothing — the SMB client serializes them.
    ///
    /// None of them are forbidden. Turn Size on for a share and you get Size, and the
    /// slow load that comes with it, and the choice is remembered for that folder.

    /// Size and Date Modified are back on by default as of the shared index. When Size cost 89 ms
    /// per row and 59 s for a folder, leaving it on was indefensible; with an index the same
    /// folder answers in ~1 s, and rows render blank (not "0 bytes") until their real values
    /// arrive, so nothing is ever wrong on screen and navigation is never held up. The five in
    /// costlyOnNetwork stay off — Owner is a stat per cell render, Duration and Dimensions read
    /// file headers, and no index covers those.
    static let networkDefaults: Set<String> = ["name", "extension", "kind", "size", "modified"]

    /// Columns that cannot be filled without a per-file attribute fetch. On a network
    /// volume each one of these is what turns a 0.4 s listing into a 59 s one.
    /// These are the real column ids from fileColumnDefs. "duration" and "dimensions" are
    /// the worst of them by far: they read the file's HEADER, not just its stat, so on a
    /// share they cost a transfer per row rather than a round trip per row.
    static let attributeColumns: Set<String> =
        ["size", "modified", "created", "accessed", "owner", "duration", "dimensions"]

    /// Sort keys that need the same per-file data, whatever the columns say — sorting by
    /// size with no Size column still has to know every size.
    static let attributeSortKeys: Set<String> = ["size", "modified", "created", "accessed", "added"]

    /// Whether the metadata pass has to run at all. False means the names-only listing IS
    /// the finished answer and the expensive enumerate can be skipped outright.
    static func needsAttributePass(columns: Set<String>, sortKey: String) -> Bool {
        !columns.isDisjoint(with: attributeColumns) || attributeSortKeys.contains(sortKey)
    }

    /// Seed columns for a folder with nothing saved yet.
    static func seed(isNetwork: Bool, localDefaults: Set<String>) -> Set<String> {
        isNetwork ? networkDefaults : localDefaults
    }

    /// Strip the expensive columns (and an expensive sort) out of an arrangement that was
    /// saved for a NETWORK folder. Run once, as a migration: most saved network arrangements
    /// were never a deliberate choice — they got persisted as a side effect of visiting the
    /// folder — and they are what keeps a share on the 89 ms-per-row path. Turning a column
    /// back on afterwards is a deliberate act and is kept.
    static func cleaned(columns: Set<String>) -> Set<String> {
        // costlyOnNetwork, not all of attributeColumns: Size and Date Modified are affordable now
        // that the shared index answers them in bulk, and they are the two people actually want.
        // Owner, Duration and Dimensions are not indexable and stay off.
        let kept = columns.subtracting(costlyOnNetwork)
        // Never hand back something with no name column; that would render an empty table.
        return kept.contains("name") ? kept : kept.union(["name"])
    }

    /// Seed sort for a folder with nothing saved yet. Cheap columns alone are not enough to
    /// get an instant listing: sorting by size or date needs every file's attributes just
    /// as much as showing them does, so an unarranged network folder sorts by name. A
    /// folder sorted by size on purpose keeps it — this only fills in a default.
    static func seedSortKey(isNetwork: Bool, localDefault: String) -> String {
        isNetwork && attributeSortKeys.contains(localDefault) ? "name" : localDefault
    }

    /// Which of the user's columns are being withheld right now, so the UI can say so instead
    /// of leaving someone wondering where their column went.
    /// Which of the requested columns are the expensive ones — for a "this is why the
    /// folder is slow" hint, not for hiding anything.
    static func costly(in requested: Set<String>) -> Set<String> {
        requested.intersection(costlyOnNetwork)
    }
}

// MARK: - Search query parsing and matching

/// Turns what someone typed into something that actually finds files.
///
/// The old behaviour was a single raw substring test, and it meant **multi-word searches
/// returned nothing at all**. Measured against this project's own naming convention:
/// "phoenix v2" matched 0 files, while requiring each word separately matched 17 — including
/// `HP2_Phoenix_Direct_NB2_v2.png`, which is obviously what was wanted. Anyone whose files are
/// named `Thing_Detail_v3.png` could never search for them with a space.
///
/// So: split on whitespace and require EVERY token, in any order, anywhere in the name — which
/// is how Finder and Explorer both behave. A `"quoted phrase"` stays one token for the times
/// you really do want the literal string.
enum SearchQueryRules {
    /// Case- and diacritic-folded, so the two search backends agree. The recursive walk used
    /// plain `lowercased()` while Spotlight used `[cd]`, which meant "café" matched in one
    /// place and not the other.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Splits on whitespace, keeping `"quoted phrases"` intact. Already folded.
    static func tokens(_ raw: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            if ch == "\"" {
                inQuotes.toggle()
                continue
            }
            if !inQuotes, ch.isWhitespace {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out.map(fold).filter { !$0.isEmpty }
    }

    /// Every token must appear somewhere in the name. Order doesn't matter.
    static func matches(name: String, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let n = fold(name)
        return tokens.allSatisfy { n.contains($0) }
    }

    /// A single bare token that looks like an extension ("png", ".png", "*.png") should also
    /// match by extension, so `png` finds every PNG even when the name doesn't contain "png".
    /// Only for a lone token — "logo png" already works by name.
    static func extensionQuery(_ tokens: [String]) -> String? {
        guard tokens.count == 1 else { return nil }
        let t = tokens[0].trimmingCharacters(in: CharacterSet(charactersIn: "*."))
        guard !t.isEmpty, t.count <= 5, t.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return t
    }

    /// Does this file match, by name tokens or by an extension-style query?
    static func matchesFile(name: String, ext: String, tokens: [String]) -> Bool {
        if matches(name: name, tokens: tokens) { return true }
        if let e = extensionQuery(tokens) { return fold(ext) == e }
        return false
    }
}

/// Why a result list stopped where it did — so a capped search can say so instead of quietly
/// looking like a complete answer.
enum SearchTruncation: Equatable {
    case complete(Int)
    case capped(shown: Int, cap: Int)

    var statusText: String {
        switch self {
        case .complete(let n):
            return "\(n) found"
        case .capped(let shown, let cap):
            // Naming the cap matters: "500 items" reads as the truth, and someone then
            // concludes the file they wanted doesn't exist.
            return "first \(shown) of more than \(cap) — narrow the search to see the rest"
        }
    }

    static func of(shown: Int, cap: Int, hitCap: Bool) -> SearchTruncation {
        hitCap ? .capped(shown: shown, cap: cap) : .complete(shown)
    }
}

// MARK: - Thumbnail cache keys

/// Builds the thumbnail cache key.
///
/// This used to be just `path@size`, which meant a file REWRITTEN AT THE SAME PATH kept its old
/// thumbnail forever — the cache had no way to know the bytes had changed. That is the normal
/// case in this workflow, not an edge case: art gets re-exported over itself constantly, and a
/// dragon whose green cloud background had been removed still showed the cloud in Navigator
/// while opening the file showed it correctly gone. Refresh couldn't fix it either, because
/// refresh only cleared the FAILURE cache.
///
/// Including a content stamp fixes it everywhere at once — scroll, folder re-entry, background
/// change, ⌘R — instead of only where someone remembered to purge.
enum ThumbnailKeyRules {
    /// `mtime`/`bytes` come from a stat. Both are used, not just mtime: a file rewritten inside
    /// the same mtime tick (or on a filesystem with coarse timestamps — network shares and some
    /// cloud providers round to the second) still changes length in almost every real case.
    static func key(path: String, size: Int, mtime: TimeInterval?, bytes: Int64?) -> String {
        guard let m = mtime, let b = bytes else {
            // stat failed. Fall back to the old form rather than inventing a key that can never
            // hit — an unreadable file is about to fail thumbnailing anyway.
            return "\(path)@\(size)"
        }
        return "\(path)@\(size)#\(Int64((m * 1000).rounded())).\(b)"
    }

    /// Everything for one path+size regardless of content stamp — used to cancel in-flight work,
    /// which must not miss just because the file changed while a thumbnail was being generated.
    static func prefix(path: String, size: Int) -> String { "\(path)@\(size)" }
}

// MARK: - Photoshop Generative Upscale (Firefly / Gigapixel / Bloom) preflight

/// What to do with one image before handing it to Generative Upscale.
enum FireflyUpscalePlan: Equatable {
    /// Ready as-is at this scale.
    case upscale(scale: Int)
    /// Aspect is outside 1:4–4:1, so pad the short side first (adaptive backing), upscale,
    /// then crop the padding back off.
    case padThenUpscale(scale: Int, padTo: (w: Int, h: Int))
    /// No scale fits the output cap. `maxSide` is what the long edge would have to be.
    case tooLargeForAnyScale(longEdge: Int, maxInputLongEdge: Int)
    case notAnImage

    static func == (a: FireflyUpscalePlan, b: FireflyUpscalePlan) -> Bool {
        switch (a, b) {
        case let (.upscale(x), .upscale(y)): return x == y
        case let (.padThenUpscale(s1, p1), .padThenUpscale(s2, p2)): return s1 == s2 && p1 == p2
        case let (.tooLargeForAnyScale(l1, m1), .tooLargeForAnyScale(l2, m2)): return l1 == l2 && m1 == m2
        case (.notAnImage, .notAnImage): return true
        default: return false
        }
    }
}

/// Constraints read straight out of Photoshop 2026's own Generative Upscale dialog, which is
/// more authoritative than the docs:
///
///   "Output too large. Width or height exceeds 6144px. Try a smaller scale or reduce the
///    image size."
///   "Aspect ratio not supported. Please crop the image to be tall or wide, between 1:4 and 4:1."
///
/// Both were triggered by a real 2224×355 sheet (6.26:1), which fails aspect at ×2 and fails
/// the size cap at ×4. Note the cap moved between versions — it was 4096 in the 2025 beta —
/// so it is deliberately one constant here.
enum FireflyUpscaleRules {
    static let maxOutputSide = 6144
    static let aspectMin = 0.25          // 1:4
    static let aspectMax = 4.0           // 4:1
    static let scales = [4, 2]           // preferred first

    /// Largest input long edge that still fits the output cap at a given scale.
    static func maxInputLongEdge(scale: Int) -> Int { maxOutputSide / max(scale, 1) }

    static func aspectOK(width w: Int, height h: Int) -> Bool {
        guard w > 0, h > 0 else { return false }
        let r = Double(w) / Double(h)
        return r >= aspectMin && r <= aspectMax
    }

    /// Smallest canvas containing the image whose aspect is inside the allowed band. Only the
    /// SHORT side grows, so the long edge — and therefore which scales fit — never changes.
    static func aspectPadCanvas(width w: Int, height h: Int) -> (w: Int, h: Int) {
        guard w > 0, h > 0 else { return (max(w, 1), max(h, 1)) }
        let r = Double(w) / Double(h)
        if r > aspectMax { return (w, Int((Double(w) / aspectMax).rounded(.up))) }
        if r < aspectMin { return (Int((Double(h) * aspectMin).rounded(.up)), h) }
        return (w, h)
    }

    static func plan(width w: Int, height h: Int, preferred: Int? = nil) -> FireflyUpscalePlan {
        guard w > 0, h > 0 else { return .notAnImage }
        let longEdge = max(w, h)
        let wanted = preferred.map { [$0] } ?? scales
        guard let scale = wanted.first(where: { longEdge * $0 <= maxOutputSide }) else {
            let smallest = scales.min() ?? 2
            return .tooLargeForAnyScale(longEdge: longEdge, maxInputLongEdge: maxInputLongEdge(scale: smallest))
        }
        if aspectOK(width: w, height: h) { return .upscale(scale: scale) }
        return .padThenUpscale(scale: scale, padTo: aspectPadCanvas(width: w, height: h))
    }

    /// Plain-language reason, for the batch preflight dialog and the log.
    static func explain(_ plan: FireflyUpscalePlan, width w: Int, height h: Int) -> String {
        switch plan {
        case .notAnImage:
            return "not a readable image"
        case .upscale(let s):
            return "×\(s) → \(w * s)×\(h * s)"
        case .padThenUpscale(let s, let p):
            let r = Double(w) / Double(max(h, 1))
            return "\(w)×\(h) is \(String(format: "%.2f", r)):1, outside Generative Upscale's 1:4–4:1 range — pad to \(p.w)×\(p.h) first, then ×\(s) → \(p.w * s)×\(p.h * s), then crop the padding off"
        case .tooLargeForAnyScale(let long, let maxIn):
            return "\(w)×\(h) is already too big: even ×2 would exceed the 6144px output cap (long edge \(long) → \(long * 2)). The largest input that fits ×2 is \(maxIn)px on the long edge — split it or reduce it first"
        }
    }
}

// MARK: - Swipe Compare across N images

/// Which image the right-hand side of Swipe Compare is showing.
///
/// Compare used to be strictly two images. Judging a bake-off means holding ONE reference on
/// the left and stepping the right side through every candidate, so the eye compares each one
/// against the same baseline instead of against whichever file happened to be next to it.
enum CompareCycle {
    /// Wraps, so stepping past the end returns to the first candidate rather than dead-ending.
    static func step(index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }

    /// Right-hand candidates are every image except the fixed left one. With exactly two
    /// images that degenerates to the old behaviour: one candidate, nothing to cycle.
    static func candidates(total: Int, leftIndex: Int) -> [Int] {
        guard total > 0, leftIndex >= 0, leftIndex < total else { return [] }
        return (0..<total).filter { $0 != leftIndex }
    }

    /// Compare needs a reference plus at least one candidate.
    static func isAvailable(imageCount: Int) -> Bool { imageCount >= 2 }
}

// MARK: - Adaptive backing colour (Prep for AI)

struct RGB8: Equatable, Hashable {
    let r: UInt8, g: UInt8, b: UInt8
    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
}

enum BackingChoice: Equatable {
    /// The image ALREADY sits on a flat field (an LP sheet on magenta). Extend that exact
    /// colour: the pad becomes invisible and the whole canvas stays ONE keyable colour.
    /// Choosing a "maximally distant" colour here would be actively wrong — it would leave
    /// two different colours to key.
    case extendField(RGB8)
    /// A cutout (alpha) or a busy border. Pick the colour furthest from every colour in the
    /// subject, so keying can never eat part of the art.
    case keyColour(RGB8, marginDeltaE: Double)
}

/// Picks the background colour "Prep for AI" fills with.
///
/// The old fixed 7-colour menu could collide with the art: measured on real assets,
/// `HP4_Tortoise.png` contains pure white (ΔE 0.0 from the "White" option) and the frames
/// sheet contains near-black (ΔE 4.6 from "Black"). Filling with a colour the subject also
/// contains means a later chroma key removes part of the subject.
enum KeyColorRules {
    /// A border this uniform means the image is already on a flat field.
    static let flatFieldFraction = 0.90

    static func lab(_ c: RGB8) -> (L: Double, a: Double, b: Double) {
        func lin(_ v: UInt8) -> Double {
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let r = lin(c.r), g = lin(c.g), b = lin(c.b)
        // sRGB -> XYZ (D65), then XYZ -> L*a*b*
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        let d = 6.0 / 29.0
        func f(_ t: Double) -> Double { t > d * d * d ? cbrt(t) : t / (3 * d * d) + 4.0 / 29.0 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func deltaE(_ a: RGB8, _ b: RGB8) -> Double {
        let l1 = lab(a), l2 = lab(b)
        let dL = l1.L - l2.L, da = l1.a - l2.a, db = l1.b - l2.b
        return (dL * dL + da * da + db * db).squareRoot()
    }

    /// Saturated hues around the wheel plus the classic keys. Saturated colours key far more
    /// reliably than near-neutrals, which is why the score below rewards saturation.
    static let candidates: [RGB8] = {
        var out: [RGB8] = []
        for step in stride(from: 0, to: 360, by: 12) {
            for (s, v) in [(1.0, 1.0), (1.0, 0.75), (1.0, 0.5), (0.85, 1.0)] {
                out.append(hsv(Double(step) / 360, s, v))
            }
        }
        out += [RGB8(0, 255, 0), RGB8(255, 0, 255), RGB8(0, 0, 255),
                RGB8(255, 255, 0), RGB8(255, 255, 255), RGB8(0, 0, 0)]
        return out
    }()

    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> RGB8 {
        let i = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return RGB8(UInt8((r * 255).rounded()), UInt8((g * 255).rounded()), UInt8((b * 255).rounded()))
    }

    static func saturation(_ c: RGB8) -> Double {
        let r = Double(c.r), g = Double(c.g), b = Double(c.b)
        let mx = max(r, g, b), mn = min(r, g, b)
        return mx == 0 ? 0 : (mx - mn) / mx
    }

    /// `subject` is the colours actually present in the art (transparent pixels excluded —
    /// they are what we're about to fill, so they must not count as "present").
    static func choose(subject: [RGB8], flatField: (colour: RGB8, fraction: Double)?) -> BackingChoice {
        if let f = flatField, f.fraction >= flatFieldFraction { return .extendField(f.colour) }
        guard !subject.isEmpty else { return .keyColour(RGB8(0, 255, 0), marginDeltaE: .infinity) }
        let subjectLab = subject.map(lab)
        var best = candidates[0], bestScore = -Double.infinity, bestMargin = 0.0
        for cand in candidates {
            let cl = lab(cand)
            var margin = Double.infinity
            for s in subjectLab {
                let dL = cl.L - s.L, da = cl.a - s.a, db = cl.b - s.b
                margin = min(margin, (dL * dL + da * da + db * db).squareRoot())
                if margin <= bestMargin - 12 { break }   // can't win even with a full sat bonus
            }
            let score = margin + 12 * saturation(cand)
            if score > bestScore { bestScore = score; best = cand; bestMargin = margin }
        }
        return .keyColour(best, marginDeltaE: bestMargin)
    }
}

/// Draws into RGBA8 at up to `cap` on the long edge and hands back the buffer.
///
/// `interpolationQuality = .none` is REQUIRED, not a performance choice. With smoothing on,
/// the downscale AVERAGES neighbouring pixels: small saturated regions get washed out and
/// blended in-between colours appear that exist nowhere in the art. Both errors push the
/// computed margin UP, which is the dangerous direction — it would let the picker choose a
/// colour that a small element actually contains and key that element away. Caught by
/// cross-checking against a reference implementation: pure green measured ΔE 102 against a
/// sheet that really only stands 80 away from it.
///
/// The cap is 4096 for the same reason: at 2048 a 2224px-wide sheet still lost ~8% of its
/// pixels and over-stated the margin by 3.4 ΔE against ground truth, because the colour that
/// decides it is a one-pixel fringe. At 4096 essentially no real asset is subsampled at all.
/// Worst case is a transient 67 MB buffer on a background thread; `subjectColours` scores it
/// with a flat occupancy grid rather than millions of hash inserts.
func rgbaSample(_ cg: CGImage, cap: Int = 4096) -> (px: [UInt8], w: Int, h: Int)? {
    let scale = max(1.0, Double(max(cg.width, cg.height)) / Double(cap))
    let w = max(1, Int(Double(cg.width) / scale)), h = max(1, Int(Double(cg.height) / scale))
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .none    // see the note above — averaging hides colours
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? (buf, w, h) : nil
}

/// Colours actually present in the art. Transparent pixels are EXCLUDED — they are exactly
/// what we're about to fill, so counting them would make the fill avoid itself.
/// An occupancy grid over the quantised colour cube, not a Set.
///
/// The colour that decides the margin is often a 1–2px anti-aliased FRINGE (measured: the
/// closest colour to pure blue on one real sheet was `rgb(178,15,125)`, residual magenta
/// fringe one pixel wide). Subsampling skips exactly those pixels and over-states the
/// margin, so every pixel has to be looked at — and a flat 80k-entry grid makes that cheap,
/// where millions of Set inserts would not be.
func subjectColours(_ cg: CGImage) -> [RGB8] {
    guard let s = rgbaSample(cg) else { return [] }
    // q = 2 keeps the quantisation error under ~1 ΔE, which matters because the reported
    // margin must not be OPTIMISTIC — an over-stated margin is what would let the picker
    // choose a colour some thin fringe actually contains. Coarser bins (q = 6) over-stated it
    // by 3–5 against ground truth; keeping one arbitrary real colour per coarse bin was worse
    // still, because scan order keeps the bulk colour and throws the fringe away.
    // 129³ bins is a 2 MB flag array — cheaper than the alternative it replaced.
    let q = 2, side = 256 / q + 1
    let n = side * side * side
    var present = [Bool](repeating: false, count: n)
    var i = 0
    while i + 3 < s.px.count {
        let a = Int(s.px[i + 3])
        if a > 16 {
            var r = Int(s.px[i]), g = Int(s.px[i + 1]), b = Int(s.px[i + 2])
            // CG bitmap contexts only do PREMULTIPLIED alpha, so a semi-transparent fringe
            // pixel arrives darkened by its own alpha. Un-premultiply to recover the colour
            // the artwork actually is: that's the hue a key must stay away from, and counting
            // the darkened version instead over-stated one real asset's margin by 3.4 ΔE.
            if a < 255 {
                r = min(255, r * 255 / a); g = min(255, g * 255 / a); b = min(255, b * 255 / a)
            }
            present[(r / q * side + g / q) * side + b / q] = true
        }
        i += 4
    }
    var out: [RGB8] = []
    out.reserveCapacity(4096)
    for k in 0..<n where present[k] {
        let b = k % side, g = (k / side) % side, r = k / (side * side)
        out.append(RGB8(UInt8(min(255, r * q + q / 2)),
                        UInt8(min(255, g * q + q / 2)),
                        UInt8(min(255, b * q + q / 2))))
    }
    return out
}

/// The modal 1px-border colour and what fraction of the border matches it. A high fraction
/// means the image already sits on a flat field, which KeyColorRules extends rather than
/// contrasts against.
func flatFieldColour(_ cg: CGImage, tolerance: Int = 8) -> (colour: RGB8, fraction: Double)? {
    guard let s = rgbaSample(cg), s.w > 2, s.h > 2 else { return nil }
    func at(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let i = (y * s.w + x) * 4
        return (s.px[i], s.px[i + 1], s.px[i + 2], s.px[i + 3])
    }
    var edge: [(UInt8, UInt8, UInt8)] = []
    for x in 0..<s.w {
        for y in [0, s.h - 1] { let p = at(x, y); if p.3 > 250 { edge.append((p.0, p.1, p.2)) } }
    }
    for y in 0..<s.h {
        for x in [0, s.w - 1] { let p = at(x, y); if p.3 > 250 { edge.append((p.0, p.1, p.2)) } }
    }
    guard !edge.isEmpty else { return nil }
    var counts: [RGB8: Int] = [:]
    for e in edge { counts[RGB8(e.0 / 8 * 8, e.1 / 8 * 8, e.2 / 8 * 8), default: 0] += 1 }
    guard let modal = counts.max(by: { $0.value < $1.value })?.key else { return nil }
    // refine to the mean of the pixels in that bucket, so we extend the true field colour
    var sum = (0, 0, 0), n = 0
    for e in edge where abs(Int(e.0) - Int(modal.r)) <= 8 && abs(Int(e.1) - Int(modal.g)) <= 8 && abs(Int(e.2) - Int(modal.b)) <= 8 {
        sum = (sum.0 + Int(e.0), sum.1 + Int(e.1), sum.2 + Int(e.2)); n += 1
    }
    guard n > 0 else { return nil }
    let mean = RGB8(UInt8(sum.0 / n), UInt8(sum.1 / n), UInt8(sum.2 / n))
    let matching = edge.filter {
        abs(Int($0.0) - Int(mean.r)) <= tolerance && abs(Int($0.1) - Int(mean.g)) <= tolerance
            && abs(Int($0.2) - Int(mean.b)) <= tolerance
    }.count
    return (mean, Double(matching) / Double(edge.count))
}

// MARK: - Aspect-ratio prep for the Gemini image models

/// Measured, not assumed: a 5:1 sheet sent straight to NB2 with `--aspect 21:9` came back
/// with TWO OF FIVE symbols deleted and the survivors distorted 16.7%. The same sheet padded
/// to exactly 21:9 first kept all five to within 0.2% of the original. So anything whose
/// ratio isn't a supported one has to be padded, never sent raw.
enum AspectPrepRules {
    /// Supported width/height ratios for the Gemini image models.
    static let supported: [(name: String, ratio: Double)] = [
        ("21:9", 21.0/9), ("16:9", 16.0/9), ("3:2", 1.5), ("5:4", 1.25), ("4:3", 4.0/3),
        ("1:1", 1), ("4:5", 0.8), ("3:4", 0.75), ("2:3", 2.0/3), ("9:16", 9.0/16), ("9:21", 9.0/21),
    ]

    /// Nearest by log-distance, which is symmetric for ratios (2× too wide and 2× too tall
    /// are equally wrong — plain subtraction would not say that).
    static func nearest(width: Int, height: Int) -> (name: String, ratio: Double) {
        let r = Double(width) / Double(max(height, 1))
        return supported.min { abs(log($0.ratio) - log(r)) < abs(log($1.ratio) - log(r)) }!
    }

    /// The canvas to pad into: the smallest box of the target ratio that CONTAINS the image,
    /// times `pad`. The subject is never scaled or cropped — only centred.
    ///
    /// `pad` 1.0 = pad only as far as the ratio demands (the auto-prep path, where fidelity is
    /// the whole point). 1.2 = the manual "Prep for AI" default, which deliberately leaves the
    /// model breathing room. Scaling BOTH sides preserves the ratio, so padding never undoes
    /// the fit it just computed.
    static func canvas(width w: Int, height h: Int, ratio rt: Double, pad: Double = 1.0) -> (w: Int, h: Int) {
        guard w > 0, h > 0, rt > 0 else { return (max(w, 1), max(h, 1)) }
        let tight: (Double, Double) = Double(w) / Double(h) > rt
            ? (Double(w), Double(w) / rt)
            : (Double(h) * rt, Double(h))
        return (max(1, Int((tight.0 * pad).rounded())), max(1, Int((tight.1 * pad).rounded())))
    }

    /// How far off a supported ratio this image is, as a fraction (0 = already exact).
    /// Padding is nearly free, so the caller pads whenever this is non-zero; at 0 the pad is
    /// 0px and the whole step is a no-op.
    static func mismatch(width w: Int, height h: Int) -> Double {
        guard w > 0, h > 0 else { return 0 }
        let r = Double(w) / Double(h)
        return abs(r / nearest(width: w, height: h).ratio - 1)
    }

    /// Where the subject sits inside the padded canvas, in that canvas's own pixels.
    static func subjectOrigin(width w: Int, height h: Int, canvas c: (w: Int, h: Int)) -> (x: Int, y: Int) {
        ((c.w - w) / 2, (c.h - h) / 2)
    }

    /// The subject's rect inside a RESULT of a different resolution than the padded canvas —
    /// the model returns its own size, so the crop-back has to scale proportionally. Doing it
    /// this way means no resample: we crop, we never stretch.
    static func cropBack(canvas c: (w: Int, h: Int), subject s: (w: Int, h: Int),
                         result r: (w: Int, h: Int)) -> (x: Int, y: Int, w: Int, h: Int) {
        guard c.w > 0, c.h > 0 else { return (0, 0, r.w, r.h) }
        let sx = Double(r.w) / Double(c.w), sy = Double(r.h) / Double(c.h)
        let o = subjectOrigin(width: s.w, height: s.h, canvas: c)
        let x = Int((Double(o.x) * sx).rounded()), y = Int((Double(o.y) * sy).rounded())
        let w = Int((Double(s.w) * sx).rounded()), h = Int((Double(s.h) * sy).rounded())
        return (max(0, x), max(0, y), min(w, r.w - max(0, x)), min(h, r.h - max(0, y)))
    }
}

/// Where every tab ends up after one is dragged onto another (Chrome/Safari reorder).
///
/// Returns the new order as indices INTO THE OLD ARRAY rather than mutating anything,
/// so the caller can carry the selection across by identity instead of by index — a
/// reorder that keeps `selected` pointing at the same slot silently switches which
/// folder you are looking at, which is the bug this shape exists to make impossible.
enum TabMoveRules {
    /// nil when the drag changes nothing (bad index, single tab, dropped on itself) —
    /// the caller then skips the mutation AND the state save entirely.
    static func reordered(count: Int, from: Int, to: Int) -> [Int]? {
        guard count > 1, (0..<count).contains(from), (0..<count).contains(to), from != to else { return nil }
        var order = Array(0..<count)
        order.remove(at: from)
        order.insert(from, at: to)
        return order
    }
}

/// Does releasing a tab drag mean "pull this tab out into its own window"?
///
/// BUG CLASS — a polled watchdog as the PRIMARY mechanism (same class as the one that made
/// drag and drop wedge until relaunch). The tear-off used to be decided and applied by a
/// bare 0.25s mouse-release poll: nothing arbitrated it, so a poll left over from the
/// previous tab drag completed the NEXT one, and it could fire `moveTabToNewWindow` while a
/// drop on a tab was still being delivered. SwiftUI `.onDrag` really does offer no end
/// callback, so a poll still has to be what NOTICES the release — but it may only ACT
/// through a DragSessionLedger ticket, which is what makes a stale one silent. Do not put a
/// bare timer back in front of this.
///
/// Vertical travel only, and generously: a release this far from where the drag started is
/// far outside a ~26pt tab strip, so it cannot also have landed on a tab. Sideways travel,
/// however far, is a reorder — releasing in the 6pt gap between two tabs must leave the
/// strip alone rather than surprising the user with a new window.
enum TabTearOffRules {
    /// ~1.5 tab heights. Big enough that no reorder along the strip trips it.
    static let pullOut: CGFloat = 40

    static func shouldTearOff(verticalTravel: CGFloat, index: Int, tabCount: Int) -> Bool {
        // The SAME rule the context-menu item is enabled by, so the tear-off log line can
        // never claim a move that moveTabToNewWindow is about to refuse. Its refusal to move
        // the ONLY tab out is what keeps this from leaving an empty ghost window behind.
        abs(verticalTravel) > pullOut && TabMenuRules.canMoveToNewWindow(index: index, count: tabCount)
    }
}

// MARK: - Spring-loaded folders

/// When hovering a folder mid-drag is allowed to open it (Finder/Explorer spring-loading).
///
/// The rules are here rather than inline at each of the four drop surfaces because a
/// surface that disagrees with the others is exactly how "it springs in the list but
/// not in the grid" happens — and because two of them are genuinely dangerous to get
/// wrong (see below).
enum SpringRules {
    /// 0.7s. Under ~0.5s an ordinary sweep across a folder on the way to somewhere else
    /// trips it, which is worse than not having the feature: you lose your place while
    /// still holding the drag. Over ~1s and people give up and let go, assuming nothing
    /// is going to happen. Finder sits in the same window; 0.7 is the middle of it.
    static let dwell: TimeInterval = 0.7

    static func canSpring(into folder: URL, from current: URL, dragging sources: [URL]) -> Bool {
        // No file in the payload means this isn't a file drag at all — it's the sidebar's
        // own reorder token, or something from another app we would refuse anyway. Opening
        // folders under a drag we can't accept would just lose the user's place.
        guard !sources.isEmpty else { return false }
        // Already looking at it: springing would be a no-op navigation that still pushes a
        // history entry and re-runs a directory read over what may be a slow SMB mount.
        // Compared as PATHS, never as URLs: "file:///tmp/a/" and "file:///tmp/a" are the
        // same folder but two different URL values, and URL equality is string equality.
        let f = folder.standardizedFileURL.resolvingSymlinksInPath().path
        if f == current.standardizedFileURL.resolvingSymlinksInPath().path { return false }
        // Dragging a folder into itself or its own subtree can never be dropped (see
        // PathRules.isSelfOrDescendant), so opening it would strand the user inside the
        // thing they are carrying, with the drag still live and nowhere valid to release.
        return !sources.contains { PathRules.isSelfOrDescendant(folder, of: $0) }
    }
}

// MARK: - Per-folder view options (⌘J)

/// Everything one folder can remember about how to display itself — the exact set the
/// ⌘J panel shows.
///
/// Deliberately a COMPLETE record rather than six independent optionals. Finder's ⌘J
/// writes the whole arrangement for a folder, and a full record makes "what applies
/// here?" a single `?? defaults` instead of six separate merges, each of which can be
/// half-applied. The half-applied case is the one that bites: a folder remembering only
/// `groupBy` while inheriting a sort key that the global default later changes shows an
/// arrangement the user never chose and can't explain.
///
/// `sortKey` is a Details COLUMN id ("name", "size", "dimensions", …), not the
/// four-case SortField the toolbar Sort menu exposes — a folder sorted by a column the
/// toolbar can't name must still come back sorted that way.
struct ViewOptions: Codable, Equatable {
    var viewMode: String
    var iconSize: Double
    var sortKey: String
    var sortAscending: Bool
    var groupBy: String
    var columns: [String]

    init(viewMode: String, iconSize: Double, sortKey: String, sortAscending: Bool,
         groupBy: String, columns: [String]) {
        self.viewMode = viewMode
        self.iconSize = iconSize
        self.sortKey = sortKey
        self.sortAscending = sortAscending
        self.groupBy = groupBy
        self.columns = columns
    }
}

/// The one key any per-folder record is filed under.
///
/// The bug this exists to end: everything per-folder was keyed on the raw
/// `currentURL.path`, and the same directory has more than one raw path. `/tmp` is a
/// symlink to `/private/tmp`, so the sidebar and the address bar reached one folder
/// under two keys and each kept its own view options — a folder silently forgot the
/// view you had just set on it, depending on how you got there. Same for a trailing
/// slash, for a path carrying `..`, and for the case someone typed.
///
/// NO FILESYSTEM ACCESS. This function must never touch the disk, and that is the whole point of
/// the version you are reading.
///
/// It used to call `realpath(3)`, which resolves every component by asking the filesystem. That is
/// correct and it is also a blocking call, and this key is computed in two places that cannot
/// tolerate blocking: on every folder render, and inside `FolderViewOptionsStore`'s one-time init,
/// which runs under `dispatch_once` on the main thread and normalises EVERY remembered folder path.
/// One remembered folder on a network mount that has stopped answering therefore froze the entire
/// application before it could draw a window — measured, with the main thread parked in
/// `realpath -> __getattrlist` on a wedged SMB path and no window on screen at all.
///
/// The reason realpath was reached for was real: Foundation maps `/private/tmp` back to `/tmp` for
/// the root only, so `/tmp/Photos` and `/private/tmp/Photos` survived
/// `standardizedFileURL.resolvingSymlinksInPath()` as two different strings. But the symlinks that
/// causes it are a FIXED, DOCUMENTED set on macOS — /tmp, /var and /etc are firmlinks into
/// /private — so the same unification is available lexically, for nothing.
///
/// What is given up: a symlink someone made themselves no longer unifies with its target, so a
/// folder reached both ways can hold two view records. That is a view arriving wrong in a rare case,
/// against an app that would not start. Not a close call.
///
/// Lowercased LAST, and deliberately: macOS volumes are case-insensitive by default, so `Photos` and
/// `photos` are one folder and two records for them is the mistake people actually hit. On a
/// case-SENSITIVE volume two genuinely different folders then share one record — a view arriving
/// wrong, never a file touched, which is much the cheaper of the two mistakes.
func folderKey(_ path: String) -> String {
    guard !path.isEmpty else { return "" }
    // Foundation's path APIs are NOT usable here. `resolvingSymlinksInPath()` obviously reads the
    // disk, but `standardizedFileURL` does too - measured: standardizing
    // /Volumes/<wedged>/deep/file.png never returned, and it resolved a symlink to its target on a
    // local path, which it could only do by asking the filesystem. A first attempt at this fix used
    // it and would have left the freeze exactly where it was.
    //
    // So the components are walked as strings and nothing here can block.
    var p = path
    if p.hasPrefix("~") { p = (p as NSString).expandingTildeInPath }   // reads NSHomeDirectory, not the disk
    let absolute = p.hasPrefix("/")
    var parts: [String] = []
    for comp in p.split(separator: "/", omittingEmptySubsequences: true) {
        switch comp {
        case ".":  continue
        case "..": if !parts.isEmpty && parts.last != ".." { parts.removeLast() } else if !absolute { parts.append("..") }
        default:   parts.append(String(comp))
        }
    }
    var joined = (absolute ? "/" : "") + parts.joined(separator: "/")
    if absolute && joined.isEmpty { joined = "/" }
    // /tmp, /var and /etc are firmlinks into /private on every macOS install. Canonicalising INTO
    // /private matches what realpath produced for folders that existed, so keys already stored for
    // real folders keep matching.
    for root in ["/tmp", "/var", "/etc"] {
        if joined == root || joined.hasPrefix(root + "/") { joined = "/private" + joined; break }
    }
    return joined.lowercased()
}

/// Whether a path may live on a volume that can stop answering — decided from the STRING ALONE.
///
/// Exists because asking the filesystem is the thing being avoided. Browser.icon(for:) used to fall
/// back to `NSWorkspace.icon(forFile:)`, which stats the file, whenever `currentIsNetwork` was false
/// — and that flag is only assigned partway through load(), so at launch it is false for every item.
/// Restoring a folder on a mount that had stopped answering therefore froze the app inside a SwiftUI
/// view body, with the main thread parked in `stat`. Measured: no window ever appeared.
///
/// `isNetworkURL` cannot be used for this. It reads `.volumeIsLocalKey`, which is exactly the kind of
/// call that blocks on the volume in question.
///
/// Everything under /Volumes is treated as possibly-remote. That includes local external drives, so
/// those lose a custom per-file icon and get a type icon instead — a slightly plainer row, against an
/// app that would not open. The boot volume is "/" and is unaffected, which is where most browsing
/// happens.
enum VolumePathRules {
    static func mayBlockOnIO(_ path: String) -> Bool {
        path == "/Volumes" || path.hasPrefix("/Volumes/")
    }
}

/// Per-folder view options keyed by path, with a hard cap and least-recently-used
/// eviction.
///
/// Why a cap at all: this is ONE UserDefaults blob, not Finder's per-folder .DS_Store.
/// Nothing ever deletes a folder's entry when the folder is deleted or renamed, so
/// without a bound the dictionary only ever grows — and it is decoded in full on every
/// launch.
///
/// The cap was 200 when a folder only got a record by ticking a checkbox. Remembering is
/// automatic now, so a record appears every time anyone changes a view setting anywhere —
/// still not once per folder VISITED (browsing writes nothing), but a far bigger working
/// set than "folders I deliberately arranged". 400 covers a year of that for a heavy
/// user, and at roughly 150 bytes per record it holds the blob near 60 KB: still a
/// sub-millisecond launch decode, still nowhere near a size UserDefaults minds.
///
/// Recency is refreshed on READ (`touch`), not only on write. Evicting by insertion
/// order instead would throw away the folder you open every day in favour of one you
/// customized once and never returned to — which is exactly backwards.
struct ViewOptionsLRU: Codable, Equatable {
    /// Paths, most-recently-used FIRST. Kept in step with `byPath`: every key in one
    /// appears in the other, which is what makes eviction a plain `order.last`.
    private(set) var order: [String] = []
    private(set) var byPath: [String: ViewOptions] = [:]
    static let cap = 400

    init() {}

    var count: Int { byPath.count }
    func contains(_ path: String) -> Bool { byPath[folderKey(path)] != nil }
    func value(for path: String) -> ViewOptions? { byPath[folderKey(path)] }

    /// Save (or replace) one folder's options, making it the most recently used and
    /// evicting the least recently used once past the cap.
    mutating func set(_ options: ViewOptions, for path: String) {
        let path = folderKey(path)
        byPath[path] = options
        order.removeAll { $0 == path }
        order.insert(path, at: 0)
        while order.count > ViewOptionsLRU.cap, let victim = order.popLast() {
            byPath[victim] = nil
        }
    }

    mutating func remove(_ path: String) {
        let path = folderKey(path)
        byPath[path] = nil
        order.removeAll { $0 == path }
    }

    /// Mark a folder as just used. Returns true only when the order actually moved, so
    /// the caller can skip a UserDefaults write on the common case of re-reading the
    /// folder that is already at the front (every refresh of the current folder).
    @discardableResult
    mutating func touch(_ path: String) -> Bool {
        let path = folderKey(path)
        guard byPath[path] != nil, order.first != path else { return false }
        order.removeAll { $0 == path }
        order.insert(path, at: 0)
        return true
    }

    /// Re-file a decoded store whose keys were written before `folderKey` existed.
    ///
    /// Migrating rather than dropping: these records are the user's own arrangements and
    /// there is no way to earn them back except by redoing every one of them by hand.
    /// Two raw keys can collapse onto one normalised key (`/tmp/x` and `/private/tmp/x`),
    /// and the more recently used of the pair wins — rebuilding least-recent-first means
    /// the later `set` both overwrites the value and lifts it to the front, which is the
    /// same answer the LRU would have given had the records never split.
    /// One-time cleanup of arrangements saved for NETWORK folders: drop the columns that cost
    /// a round trip per row, and downgrade a size/date sort to name (which needs the same data).
    /// Most of these arrangements were never chosen deliberately — visiting a folder persists
    /// one — and they are exactly what keeps a share off the fast path. Takes the network test
    /// as a parameter so this stays pure and testable.
    func strippingCostlyNetworkColumns(isNetwork: (String) -> Bool) -> ViewOptionsLRU {
        var out = self
        for (key, o) in byPath where isNetwork(key) {
            let keep = NetworkColumnRules.cleaned(columns: Set(o.columns))
            let sort = NetworkColumnRules.attributeSortKeys.contains(o.sortKey) ? "name" : o.sortKey
            guard keep != Set(o.columns) || sort != o.sortKey else { continue }
            out.byPath[key] = ViewOptions(viewMode: o.viewMode, iconSize: o.iconSize,
                                         sortKey: sort, sortAscending: o.sortAscending,
                                         groupBy: o.groupBy,
                                         columns: o.columns.filter { keep.contains($0) })
        }
        return out
    }

    func migratedToNormalizedKeys() -> ViewOptionsLRU {
        guard order.contains(where: { $0 != folderKey($0) }) else { return self }
        var out = ViewOptionsLRU()
        for path in order.reversed() {
            guard let o = byPath[path] else { continue }   // a blob whose halves disagree
            out.set(o, for: path)
        }
        return out
    }

    /// The options that apply to a folder: its own if it has any, otherwise the global
    /// defaults. The whole point of the feature in one line — and the reason a folder
    /// that was never arranged by hand behaves exactly as it did before any of this
    /// existed.
    func effective(for path: String, defaults: ViewOptions) -> ViewOptions {
        byPath[folderKey(path)] ?? defaults
    }
}

// MARK: - Guessing what a folder is for (Windows-style folder-type detection)

/// Extensions worth seeing as a picture. Here rather than beside `isImageFile` in
/// main.swift so the folder classifier below — which the test bundle compiles, and
/// main.swift cannot be imported into — judges from the SAME list the thumbnailer and
/// the image viewer use, instead of a second copy that quietly drifts from it.
let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp", "ico"]
let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg", "3gp", "m2ts", "mts", "m2v", "ts"]

/// What a folder appears to BE, judged only from the names the listing already holds.
///
/// This is Explorer's folder-type detection, and it exists for one reason: a folder full
/// of pictures is useless as a list of names. It runs on every folder load, including on
/// an SMB share over VPN, so it may only look at what enumeration already returned — a
/// name and an isDirectory flag. Never opens a file, never reads an image header, never
/// asks for a thumbnail.
enum FolderKind {
    /// Mostly pictures or video: worth the screen space of big thumbnails.
    case media
    /// Subfolders, documents, code, or a genuine mix — nothing a thumbnail helps with,
    /// so it stays with whatever the user's default view is (Details, out of the box).
    case general

    /// Countable entries needed before this will call a folder anything at all.
    ///
    /// Below this, "mostly images" is one or two files' worth of evidence: a folder
    /// holding a README and two screenshots is not a photo library, and blowing it up to
    /// giant icons on a 2-1 split is exactly the guess that sends people looking for the
    /// off switch. Five is the smallest count where a 60% lean means at least three files
    /// agreeing.
    static let minimumEvidence = 5

    /// Share of countable entries that must be media before the folder is called one.
    ///
    /// A plain majority tips on a single file in an even split, which makes the view mode
    /// jitter as a working folder fills up. 60% needs a real lean. Deliberately not
    /// higher: a photo folder with a few exports, a contact sheet and a notes file in it
    /// is still a photo folder.
    static let mediaShare = 0.6

    static func isMediaName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    /// nil = not enough to go on; leave the folder with the user's default view.
    ///
    /// Two things get discounted before the ratio is taken, both because they describe
    /// the folder's plumbing rather than its purpose:
    ///
    /// • Dotfiles (.DS_Store, .picasa.ini) — invisible in the listing unless Show Hidden
    ///   is on, so they must not be able to swing what the user sees either way.
    /// • Sidecars: a non-media file sharing its base name with a media file right beside
    ///   it (IMG_0431.xmp next to IMG_0431.cr2, clip.mov next to clip.srt). A raw
    ///   workflow writes one per shot, so counting them makes every raw folder exactly
    ///   50/50 and no photo folder ever reaches the threshold — the single most likely
    ///   way for this feature to look broken to the person who most wants it. The same
    ///   rule collapses a RAW+JPEG pair back to one shot for free.
    ///   ponytail: a raw-ONLY folder has no jpg to anchor that rule to and stays general.
    ///   Fix by classifying against thumbnailExtensions instead, if anyone asks.
    static func infer(_ entries: [(name: String, isDirectory: Bool)]) -> FolderKind? {
        let visible = entries.filter { !$0.name.hasPrefix(".") }
        func base(_ name: String) -> String { (name as NSString).deletingPathExtension.lowercased() }
        var mediaBases = Set<String>()
        for e in visible where !e.isDirectory && isMediaName(e.name) { mediaBases.insert(base(e.name)) }

        var media = 0, counted = 0
        for e in visible {
            if !e.isDirectory, isMediaName(e.name) { media += 1; counted += 1; continue }
            // A subfolder always counts — 25 project folders are the whole reason this
            // can't just be "does it contain images".
            if e.isDirectory || !mediaBases.contains(base(e.name)) { counted += 1 }
        }
        guard counted >= minimumEvidence else { return nil }
        return Double(media) >= mediaShare * Double(counted) ? .media : .general
    }
}

// MARK: - Remembering where you were in a folder

/// Your place in one folder: the item that was at the top of the view, plus what was
/// selected. Recorded when you leave a folder and replayed when you come back, so Back
/// returns you to the row you were reading instead of the top of the listing.
struct FolderPlace: Equatable {
    /// The item that was at the top of the viewport when you left.
    ///
    /// An ITEM, deliberately, not a pixel offset. A scroll offset recorded before three
    /// files were deleted (or before the sort order changed, or the icon size did) points
    /// at whatever happens to live at that y now — which is how you come back to a folder
    /// and land somewhere you have never been. The item you were looking at is still the
    /// item you were looking at.
    var anchorID: String?
    /// Where `anchorID` sat in the visible order. Used ONLY when the anchor itself is
    /// gone — deleted, renamed or filtered out while you were away. Coming back to the
    /// same POSITION is the closest thing to "where I was" that survives losing the
    /// anchor, and it is bounded by construction (see restoreAnchor).
    var anchorIndex: Int = 0
    var selection: Set<String> = []

    /// The id to put back at the top of the view, or nil to leave the scroll alone.
    ///
    /// `settled == false` means the listing is still filling in — the network loader
    /// commits partial batches while a slow share enumerates. A missing anchor then means
    /// "not there YET", not "gone", so we decline instead of falling back to the index
    /// and scrolling to a position computed from a tenth of the folder. The caller keeps
    /// the record and asks again on the next batch.
    func restoreAnchor(among ids: [String], settled: Bool) -> String? {
        if let a = anchorID, ids.contains(a) { return a }
        // anchorIndex 0 means you were already at the top: there is nothing to restore,
        // and scrolling to ids[0] would fight a view that is already showing it.
        guard settled, anchorIndex > 0, !ids.isEmpty else { return nil }
        return ids[min(anchorIndex, ids.count - 1)]
    }
}

/// Bounded, most-recently-used-first store of `FolderPlace` by folder path — the same
/// shape, and the same reason, as ViewOptionsLRU: a session that walks a deep tree visits
/// hundreds of folders, and an unbounded dictionary of them only ever grows.
///
/// Deliberately NOT Codable and never persisted, unlike ViewOptionsLRU: where you were
/// scrolled to is worth remembering while you are working, not across a relaunch — and
/// persisting it would mean paying a UserDefaults write on every single navigation.
struct FolderPlaceLRU: Equatable {
    /// Paths, most-recently-used FIRST, kept in step with `byPath` — same invariant as
    /// ViewOptionsLRU, which is what makes eviction a plain `order.last`.
    private(set) var order: [String] = []
    private(set) var byPath: [String: FolderPlace] = [:]
    /// Smaller than ViewOptionsLRU's 200 because nothing here is persisted or
    /// user-visible: it only has to cover the folders you are actually moving between.
    static let cap = 100

    var count: Int { byPath.count }
    func value(for path: String) -> FolderPlace? { byPath[folderKey(path)] }

    /// Record (or replace) one folder's place, making it the most recently used. Recency
    /// needs no separate `touch` here: you cannot return to a folder without having left
    /// one, so every visit ends in a `set`.
    mutating func set(_ place: FolderPlace, for path: String) {
        let path = folderKey(path)
        byPath[path] = place
        order.removeAll { $0 == path }
        order.insert(path, at: 0)
        while order.count > FolderPlaceLRU.cap, let victim = order.popLast() {
            byPath[victim] = nil
        }
    }
}

// MARK: - Sorting the lazily-loaded media columns (Time, Dimensions)

/// Sort key for the two Details columns whose values arrive asynchronously from
/// Spotlight: Time (duration) and Dimensions.
///
/// Two things this has to get right, both of which a bare `Double` key path gets wrong:
///
/// 1. **Missing and not-yet-loaded values must not scatter.** A text file has no
///    duration and a freshly listed video hasn't been asked yet; both come through as
///    nil and both map to 0, so they land together at the low end instead of wherever
///    an uninitialized read happened to put them. This matches what the Size column
///    already does with folders (size 0, so they clump), which is the behaviour this app
///    has always had for "no meaningful number here".
///    ponytail: the low end means unknowns lead when ascending and trail when
///    descending, rather than always trailing the way Finder does. Always-trailing is
///    not expressible as a KeyPathComparator — reversing the order reverses the whole
///    key — so it would mean replacing the comparator type everywhere `sortOrder` is
///    used. Worth doing only if the asymmetry actually annoys someone.
///
/// 2. **Ties must be deterministic.** Swift's sort is not documented as stable, so two
///    files with equal duration (or, far more common, the whole block of 0s) could come
///    back in a different order every time the list re-sorts — which reads as the list
///    shuffling itself for no reason. Folding the name into the key makes every
///    comparison total, so equal values always land in name order.
struct MediaSortKey: Comparable {
    /// Seconds for Time, width × height for Dimensions. 0 when absent or not yet loaded.
    let value: Double
    /// Tie-break, so equal values can never reorder between sorts.
    let name: String

    /// Duration in seconds, 0 when unknown. Negative durations (which some broken
    /// media files report) are clamped, or they would sort below genuinely unknown
    /// files and look like a rendering bug in the Time column.
    static func duration(_ seconds: Double?, name: String) -> MediaSortKey {
        MediaSortKey(value: max(0, seconds ?? 0), name: name)
    }

    /// Total pixel area, 0 when either dimension is unknown or non-positive.
    ///
    /// Area rather than width-then-height because area is the single number people
    /// mean by "bigger image": it ranks a 4000×3000 photo above a 5000×200 banner,
    /// which is the answer someone sorting a folder of images is looking for, whereas
    /// width-first would put the banner on top.
    static func pixelArea(width: Int?, height: Int?, name: String) -> MediaSortKey {
        guard let w = width, let h = height, w > 0, h > 0 else { return MediaSortKey(value: 0, name: name) }
        return MediaSortKey(value: Double(w) * Double(h), name: name)
    }

    static func < (l: MediaSortKey, r: MediaSortKey) -> Bool {
        l.value == r.value
            ? l.name.localizedStandardCompare(r.name) == .orderedAscending
            : l.value < r.value
    }
}

// MARK: - Collapsible group headers

/// Which items a set of collapsed groups leaves visible, and in what order.
///
/// Keeping `NSTableView.sortDescriptors` down to the ONE descriptor the app actually
/// sorts on.
///
/// AppKit does not replace the stack when a header is clicked — it PREPENDS the clicked
/// column's descriptor and keeps every earlier one as a secondary sort, and
/// `autosaveTableColumns` then persists that growing stack across launches (seen live:
/// ["modified:false", "kind:true", "name:true", "size:false"]). Navigator sorts on the
/// first descriptor only, so the leftovers never change the row order — but AppKit reuses
/// a remembered entry's DIRECTION, so clicking a column you last sorted descending brings
/// it back descending instead of starting ascending, which is not what a header click
/// promises. Rewriting down to the single active descriptor is what keeps "click a new
/// column → ascending, click again → descending" true.
enum TableSortRules {
    /// True when the table's stack is anything other than exactly the active sort.
    /// Deliberately also true for a stack whose FIRST entry already matches — that is the
    /// case that leaves stale directions behind for every other column.
    static func needsRewrite(current: [(key: String, ascending: Bool)],
                             desiredKey: String, desiredAscending: Bool) -> Bool {
        guard current.count == 1, let only = current.first else { return true }
        return only.key != desiredKey || only.ascending != desiredAscending
    }
}

/// This is here, tested, and used by BOTH renderers because of one subtle bug it
/// prevents: keyboard navigation (arrows, Tab/⇧Tab, type-to-select) walks the flat
/// visible order, and if that order still contains the items inside a collapsed group
/// then Tab silently selects something the user cannot see — the status bar changes,
/// Return opens a file that isn't on screen, and nothing on screen explains why.
/// Filtering the flat order is the fix, so it has to be the SAME filter the views use.
enum GroupCollapse {

    /// A group can only be collapsed if it has a header to click. `groups()` returns a
    /// single untitled group when Group By is off, and collapsing that would hide the
    /// entire folder with no header left to click to get it back.
    static func canCollapse(title: String) -> Bool { !title.isEmpty }

    /// The flat item order the given collapsed set leaves on screen. Group headers stay
    /// (they are what you click to expand again); only their contents disappear.
    static func visibleOrder<T>(groups: [(title: String, items: [T])], collapsed: Set<String>) -> [T] {
        groups.flatMap { g in
            canCollapse(title: g.title) && collapsed.contains(g.title) ? [] : g.items
        }
    }

    /// Toggling one group, with the untitled group refused for the reason above.
    static func toggled(_ collapsed: Set<String>, title: String) -> Set<String> {
        guard canCollapse(title: title) else { return collapsed }
        var out = collapsed
        if out.contains(title) { out.remove(title) } else { out.insert(title) }
        return out
    }

    /// Group titles that no longer exist are dropped: the folder changed (different
    /// Group By, files added, a filter typed) and keeping a stale title alive means a
    /// group that reappears later comes back mysteriously collapsed.
    static func pruned(_ collapsed: Set<String>, toTitles titles: [String]) -> Set<String> {
        collapsed.intersection(titles)
    }
}

// MARK: - Search filters (Date Modified / Size)

/// The Date Modified buckets in the search filter menu, as CALENDAR-DAY ranges.
///
/// Day boundaries, not "now minus 24 hours": a file saved at 9am does not stop
/// matching "Today" as the afternoon wears on, which is what an elapsed-seconds
/// window would do and is never what "Today" means to anyone.
///
/// Every range is half-open [from, to) so a file whose mtime is EXACTLY midnight
/// belongs to the day that is starting, in exactly one bucket — an inclusive upper
/// bound would put midnight in both "Yesterday" and "Today".
enum SearchDateFilter: String, CaseIterable, Codable {
    case any = "Any Date"
    case today = "Today"
    case yesterday = "Yesterday"
    case last7 = "Last 7 Days"
    case last30 = "Last 30 Days"
    case thisYear = "This Year"
    case custom = "Custom Range…"

    /// `from` inclusive, `to` exclusive; nil means unbounded on that side.
    ///
    /// `custom` takes whole days from the two date pickers — the pickers only offer a
    /// day, so treating `customTo` as an instant would silently exclude everything
    /// written on the last day the user picked.
    func range(now: Date, calendar: Calendar = .current,
               customFrom: Date? = nil, customTo: Date? = nil) -> (from: Date?, to: Date?) {
        let sod = calendar.startOfDay(for: now)
        func day(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: sod) ?? sod }
        switch self {
        case .any:       return (nil, nil)
        case .today:     return (sod, day(1))
        case .yesterday: return (day(-1), sod)
        // "Last 7 Days" is today plus the six days before it — the same seven calendar
        // days Explorer's "Last week" covers, and it must include today.
        case .last7:     return (day(-6), day(1))
        case .last30:    return (day(-29), day(1))
        case .thisYear:
            let start = calendar.date(from: calendar.dateComponents([.year], from: now)) ?? sod
            return (start, day(1))
        case .custom:
            let lo = customFrom.map { calendar.startOfDay(for: $0) }
            let hi = customTo.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
            return (lo, hi)
        }
    }
}

/// The Size buckets in the search filter menu.
///
/// Non-overlapping, so picking one bucket can never also mean "and everything
/// smaller" — the labels carry the exact edges because "Small" means nothing on its
/// own and a filter you can't predict is worse than no filter.
///
/// Decimal KB/MB/GB (1000-based), NOT 1024: every size this app displays comes from
/// ByteCountFormatter with .file, which is decimal. A 1024-based threshold here
/// would reject a file the size column calls "100 KB" for being 100 KB.
enum SearchSizeFilter: String, CaseIterable, Codable {
    case any = "Any Size"
    case empty = "Empty (0 bytes)"
    case tiny = "Tiny (< 100 KB)"
    case small = "Small (100 KB – 1 MB)"
    case medium = "Medium (1 MB – 100 MB)"
    case large = "Large (100 MB – 1 GB)"
    case huge = "Huge (> 1 GB)"
    case custom = "Custom Range…"

    static let kb: Int64 = 1_000
    static let mb: Int64 = 1_000_000
    static let gb: Int64 = 1_000_000_000

    /// `from` inclusive, `to` exclusive; nil means unbounded on that side.
    /// Custom bounds arrive in BYTES (the UI multiplies its KB/MB field out).
    func range(customFrom: Int64? = nil, customTo: Int64? = nil) -> (from: Int64?, to: Int64?) {
        switch self {
        case .any:    return (nil, nil)
        case .empty:  return (0, 1)
        case .tiny:   return (1, 100 * Self.kb)
        case .small:  return (100 * Self.kb, Self.mb)
        case .medium: return (Self.mb, 100 * Self.mb)
        case .large:  return (100 * Self.mb, Self.gb)
        case .huge:   return (Self.gb, nil)
        case .custom: return (customFrom, customTo)
        }
    }
}

/// The one place a search result is tested against the Date/Size filters.
///
/// BOTH backends run this: the Spotlight path builds an equivalent NSMetadataQuery
/// predicate to keep the result set small, then re-checks here, and the recursive
/// walkSearch (SMB / Google Drive, which Spotlight cannot index) has only this. Two
/// separate implementations is how a filter ends up silently ignored on one path —
/// and Spotlight's own index can be stale about size, so the re-check is not
/// redundant even where the predicate already ran.
struct SearchFilters {
    var date: SearchDateFilter = .any
    var size: SearchSizeFilter = .any
    var customDateFrom: Date?
    var customDateTo: Date?
    var customSizeFrom: Int64?
    var customSizeTo: Int64?

    var isActive: Bool { date != .any || size != .any }

    func dateRange(now: Date = Date(), calendar: Calendar = .current) -> (from: Date?, to: Date?) {
        date.range(now: now, calendar: calendar, customFrom: customDateFrom, customTo: customDateTo)
    }
    func sizeRange() -> (from: Int64?, to: Int64?) {
        size.range(customFrom: customSizeFrom, customTo: customSizeTo)
    }

    /// `isDirectory` items are exempt from the SIZE filter: a folder's `size` in a
    /// listing is its directory-entry size (a few hundred bytes), not its contents, so
    /// judging folders by it would drop every folder from "Large" and file every folder
    /// under "Tiny" — both plainly wrong. Dates apply to folders normally.
    func matches(modified: Date, size bytes: Int64, isDirectory: Bool,
                 now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let d = dateRange(now: now, calendar: calendar)
        if let f = d.from, modified < f { return false }
        if let t = d.to, modified >= t { return false }
        if !isDirectory {
            let s = sizeRange()
            if let f = s.from, bytes < f { return false }
            if let t = s.to, bytes >= t { return false }
        }
        return true
    }
}

// MARK: - Sharing & Permissions (Get Info)

/// A POSIX permission triad shown the way Finder shows it, because "rwxr-xr-x" is
/// not something most people can read and is certainly not something they can edit.
///
/// The execute bit is deliberately NOT part of the level: stripping it turns a
/// directory into one you cannot enter (and a tool into one you cannot run), so a
/// user picking "Read only" for a group must not silently break traversal. See
/// `bits(existing:isDirectory:)`.
enum PosixAccess: String, CaseIterable, Codable {
    case readWrite = "Read & Write"
    case readOnly = "Read only"
    case writeOnly = "Write only (Drop Box)"
    case noAccess = "No Access"

    /// From one octal digit (0...7).
    static func from(bits: UInt16) -> PosixAccess {
        switch (bits & 4 != 0, bits & 2 != 0) {
        case (true, true):   return .readWrite
        case (true, false):  return .readOnly
        case (false, true):  return .writeOnly
        case (false, false): return .noAccess
        }
    }

    /// The octal digit for this level.
    ///
    /// `existing` supplies the execute/search bit, which is carried through unchanged
    /// for files — chmod'ing a script to "Read only" should not also un-run it.
    /// Directories are the exception: read access to a directory is useless without
    /// search permission (you can list names but cannot stat anything inside), so
    /// granting read to a directory grants search with it, which is what Finder does.
    func bits(existing: UInt16, isDirectory: Bool) -> UInt16 {
        guard self != .noAccess else { return 0 }   // no access means none, execute included
        // A directory always keeps search permission alongside any granted access: a
        // "Write only (Drop Box)" you cannot enter is not a drop box, and a readable
        // directory you cannot search lists names whose contents nothing can stat.
        let x: UInt16 = isDirectory ? 1 : (existing & 1)
        switch self {
        case .readWrite: return 6 | x
        case .readOnly:  return 4 | x
        case .writeOnly: return 2 | x
        case .noAccess:  return 0
        }
    }
}

/// Which triad of a mode a change applies to.
enum PosixClass: Int, CaseIterable { case owner = 6, group = 3, other = 0 }

enum PosixMode {
    /// The three levels of a full mode, for display.
    static func levels(_ mode: UInt16) -> (owner: PosixAccess, group: PosixAccess, other: PosixAccess) {
        (.from(bits: (mode >> 6) & 7), .from(bits: (mode >> 3) & 7), .from(bits: mode & 7))
    }
    /// `mode` with one triad replaced. Only the 12 permission bits are touched —
    /// setuid/setgid/sticky live above them and dropping them silently would break
    /// shared drop folders that rely on setgid.
    static func setting(_ mode: UInt16, _ cls: PosixClass, to level: PosixAccess, isDirectory: Bool) -> UInt16 {
        let shift = UInt16(cls.rawValue)
        let existing = (mode >> shift) & 7
        let replaced = level.bits(existing: existing, isDirectory: isDirectory)
        return (mode & ~(7 << shift)) | (replaced << shift)
    }
    /// "rwxr-xr-x" — kept because it's the form you can paste into a chmod discussion.
    static func string(_ mode: UInt16) -> String {
        func rwx(_ v: UInt16) -> String { "\(v & 4 != 0 ? "r" : "-")\(v & 2 != 0 ? "w" : "-")\(v & 1 != 0 ? "x" : "-")" }
        return rwx((mode >> 6) & 7) + rwx((mode >> 3) & 7) + rwx(mode & 7)
    }
}

// MARK: - Trash put-back

/// Where a trashed item came from, so "Put Back" lands it where Finder would.
struct TrashOrigin: Equatable {
    /// Absolute directory the item was in.
    var directory: String
    /// The name it had BEFORE the Trash renamed it for a collision — "New Folder",
    /// not "New Folder 08-27-42-686". Restoring under the trash-mangled name is the
    /// classic way a Restore feature quietly returns the wrong thing.
    var name: String
    var url: URL { URL(fileURLWithPath: directory).appendingPathComponent(name) }
}

/// Reads Finder's put-back records out of a Trash folder's `.DS_Store`.
///
/// This is the only place the original location of an item trashed by ANOTHER app
/// is recorded — there is no xattr and no metadata attribute for it (checked: a
/// freshly trashed file carries only com.apple.provenance). The records are
/// `ptbL` (original directory, as a path with no leading slash) and `ptbN`
/// (original name), keyed by the item's name inside the Trash.
///
/// The file is an undocumented "Bud1" buddy-allocator wrapping a B-tree, and it is
/// UNTRUSTED input: every read below is bounds-checked and every failure returns
/// what has been decoded so far rather than trapping. A corrupt .DS_Store must
/// degrade Restore to "origin unknown", never crash the app.
///
/// It is also written LAZILY by Finder, so an item trashed seconds ago may have no
/// record yet. That is why Navigator persists its own trash→origin map as well and
/// consults it first (see TrashOrigins); this parser is the fallback that makes
/// Restore work for the rest of the Trash.
enum DSStore {
    static func putBackRecords(_ data: Data) -> [String: TrashOrigin] {
        var out: [String: TrashOrigin] = [:]
        let b = [UInt8](data)
        func u32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
        }
        guard u32(0) == 1, b.count > 8,
              b[4] == 0x42, b[5] == 0x75, b[6] == 0x64, b[7] == 0x31 else { return out }  // "Bud1"
        // Header: allocator-info offset at 0x08. All block offsets in this format are
        // relative to the end of the 4-byte magic, hence the +4 everywhere.
        guard let infoOff = u32(0x08).map({ Int($0) + 4 }), let blockCount = u32(infoOff) else { return out }
        guard blockCount > 0, blockCount < 100_000 else { return out }
        let addrStart = infoOff + 8
        // The address list is padded out to a whole multiple of 256 entries.
        let addrSlots = ((Int(blockCount) + 255) / 256) * 256
        var dirOff = addrStart + addrSlots * 4
        guard let dirCount = u32(dirOff), dirCount < 10_000 else { return out }
        dirOff += 4
        var dsdbBlock: Int?
        for _ in 0..<Int(dirCount) {
            guard dirOff < b.count else { return out }
            let nameLen = Int(b[dirOff]); dirOff += 1
            guard dirOff + nameLen + 4 <= b.count else { return out }
            let name = String(decoding: b[dirOff..<(dirOff + nameLen)], as: UTF8.self)
            dirOff += nameLen
            let block = u32(dirOff); dirOff += 4
            if name == "DSDB" { dsdbBlock = block.map(Int.init) }
        }
        // A block's address packs its offset and its log2 size into one word.
        func block(_ n: Int) -> Int? {
            guard let a = u32(addrStart + n * 4) else { return nil }
            return Int(a & ~0x1f) + 4
        }
        guard let dsdb = dsdbBlock, let dsdbOff = block(dsdb), let rootNode = u32(dsdbOff) else { return out }

        /// One key/value record. Returns the offset just past it, or nil to abandon
        /// the walk — an unrecognised value type means we no longer know how many
        /// bytes to skip, and guessing would read garbage as a filesystem path.
        func record(_ off: Int) -> Int? {
            guard let nameLen = u32(off), nameLen < 4096 else { return nil }
            var o = off + 4
            let nameBytes = Int(nameLen) * 2
            guard o + nameBytes + 8 <= b.count else { return nil }
            // Decode as UTF-16, not scalar-at-a-time: an emoji in a filename is a
            // surrogate PAIR, and treating each half as a scalar throws the name away.
            var units: [UInt16] = []
            var i = o
            while i + 1 < o + nameBytes {
                units.append((UInt16(b[i]) << 8) | UInt16(b[i + 1]))
                i += 2
            }
            let key = String(decoding: units, as: UTF16.self)
            o += nameBytes
            let sid = String(decoding: b[o..<(o + 4)], as: UTF8.self); o += 4
            let type = String(decoding: b[o..<(o + 4)], as: UTF8.self); o += 4
            var text: String?
            switch type {
            case "long", "shor", "type": o += 4
            case "bool": o += 1
            case "comp", "dutc": o += 8
            case "blob":
                guard let n = u32(o), n < 1 << 24 else { return nil }
                o += 4 + Int(n)
            case "ustr":
                guard let n = u32(o), n < 1 << 20 else { return nil }
                o += 4
                let bytes = Int(n) * 2
                guard o + bytes <= b.count else { return nil }
                var vu: [UInt16] = []
                var j = o
                while j + 1 < o + bytes {
                    vu.append((UInt16(b[j]) << 8) | UInt16(b[j + 1]))
                    j += 2
                }
                text = String(decoding: vu, as: UTF16.self)
                o += bytes
            default: return nil
            }
            guard o <= b.count else { return nil }
            if let text {
                switch sid {
                case "ptbL": out[key, default: TrashOrigin(directory: "", name: "")].directory = normalize(text)
                case "ptbN": out[key, default: TrashOrigin(directory: "", name: "")].name = text
                default: break
                }
            }
            return o
        }

        // Depth-first over the B-tree, with an EXPLICIT stack rather than recursion.
        //
        // The node-count bound below does not bound DEPTH: a corrupt file whose nodes
        // form a 10,000-long chain (each one naming the next, none of them repeating)
        // was 10,000 live stack frames deep. This runs from loadTrashPutBack on a
        // DispatchQueue.global worker, whose stack is 512 KB — deep enough to overflow
        // and take the whole app down with no error anyone could act on. A worklist has
        // no such ceiling. `visited` is still not paranoia: a block number that points
        // back at an ancestor would otherwise loop forever.
        //
        // Visiting order changes (LIFO, so `next` before the children) and that is safe:
        // `out` is keyed by filename+field and a B-tree holds each key once, so no
        // ordering of the same node set can produce a different result.
        var visited = Set<Int>()
        var stack = [Int(rootNode)]
        while let n = stack.popLast() {
            guard !visited.contains(n), visited.count < 10_000, let off = block(n) else { continue }
            visited.insert(n)
            guard let next = u32(off), let count = u32(off + 4), count < 100_000 else { continue }
            var o = off + 8
            if next == 0 {
                for _ in 0..<Int(count) {
                    guard let after = record(o) else { break }
                    o = after
                }
            } else {
                // An unreadable record abandons the REST of this node — including its
                // right-hand `next` sibling — exactly as the recursive form's early
                // return did. Children already read are still walked: they were read
                // before the bad record and are as trustworthy as anything else here.
                var truncated = false
                for _ in 0..<Int(count) {
                    guard let child = u32(o) else { truncated = true; break }
                    o += 4
                    // Bounded, and skipping the already-seen: `count` is only bounded at
                    // 100,000, so a corrupt node claiming that many children would
                    // otherwise queue work no visit budget can ever consume — trading the
                    // stack overflow this rewrite fixes for an out-of-memory one.
                    // Anything past the visit budget is unreachable by definition.
                    if !visited.contains(Int(child)), stack.count < 10_000 { stack.append(Int(child)) }
                    guard let after = record(o) else { truncated = true; break }
                    o = after
                }
                if !truncated, !visited.contains(Int(next)) { stack.append(Int(next)) }
            }
        }
        return out.filter { !$0.value.directory.isEmpty && !$0.value.name.isEmpty }
    }

    /// A `ptbL` value into a path you can hand to FileManager.
    ///
    /// Two fixups. The leading "/" is absent from the stored form. And Finder often
    /// records the firmlink path "/System/Volumes/Data/Users/…", which is the SAME
    /// directory as "/Users/…" but is a second name for it — restoring through it
    /// works, yet every path we then show the user, compare, or navigate to would be
    /// a path they have never seen anywhere else in the OS.
    static func normalize(_ raw: String) -> String {
        var p = raw
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        let firmlink = "/System/Volumes/Data"
        if p == firmlink { return "/" }
        if p.hasPrefix(firmlink + "/") { p = String(p.dropFirst(firmlink.count)) }
        return p
    }
}

/// Navigator's own record of where the things IT trashed came from — the
/// authoritative half of Put Back.
///
/// Finder's `.DS_Store` put-back records are written lazily (a file trashed seconds
/// ago is often not in them yet, measured), so relying on them alone would make
/// Restore fail exactly when it is most likely to be used: right after a delete.
/// Every trash operation records here immediately instead.
///
/// Keyed by the item's path INSIDE the Trash, which is unique — the Trash renames
/// collisions — and pruned to a bounded, recent set so this can't grow without end.
enum TrashOrigins {
    static let key = "trashOrigins"
    private static let limit = 500
    /// Injected in tests; UserDefaults.standard in the app.
    static var defaults: UserDefaults = .standard

    static func record(_ pairs: [(from: URL, to: URL)]) {
        guard !pairs.isEmpty else { return }
        var map = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        for p in pairs { map[p.from.path] = p.to.path }
        // Drop entries whose trashed item is gone (emptied, or put back already);
        // that both prunes and keeps the map honest about what it can still restore.
        map = map.filter { FileManager.default.fileExists(atPath: $0.key) }
        // Age = when the item entered the Trash, which is exactly what
        // .addedToDirectoryDate records. An unreadable date sorts oldest, so an entry
        // we can no longer date is the first to go rather than the last.
        map = evict(map, limit: limit) {
            (try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.addedToDirectoryDateKey]))?
                .addedToDirectoryDate ?? .distantPast
        }
        defaults.set(map, forKey: key)
    }

    /// Keep the `limit` most recently trashed entries.
    ///
    /// The bug this replaces: `Array(map).suffix(limit)` over a Dictionary. Dictionary
    /// iteration order is unspecified AND seeded per process, so eviction dropped an
    /// arbitrary set that differed on every launch — a Put Back that worked yesterday
    /// could silently have no origin today, for no reason the user could see or undo.
    /// Ordering by age makes the survivors the ones anybody would actually reach for.
    static func evict(_ map: [String: String], limit: Int, age: (String) -> Date) -> [String: String] {
        guard map.count > limit else { return map }
        let dated: [(path: String, at: Date)] = map.keys.map { (path: $0, at: age($0)) }
        // Path breaks ties, so two items trashed in the same instant still evict
        // deterministically instead of by hash order.
        let sorted = dated.sorted { $0.at == $1.at ? $0.path < $1.path : $0.at < $1.at }
        var out: [String: String] = [:]
        for e in sorted.suffix(limit) { out[e.path] = map[e.path] }
        return out
    }

    static func origin(of trashedPath: String) -> TrashOrigin? {
        guard let p = (defaults.dictionary(forKey: key) as? [String: String])?[trashedPath] else { return nil }
        let u = URL(fileURLWithPath: p)
        return TrashOrigin(directory: u.deletingLastPathComponent().path, name: u.lastPathComponent)
    }

    static func forget(_ trashedPaths: [String]) {
        guard var map = defaults.dictionary(forKey: key) as? [String: String], !map.isEmpty else { return }
        for p in trashedPaths { map[p] = nil }
        defaults.set(map, forKey: key)
    }
}

// MARK: - Permissions (Setup Assistant + deny-at-use-time wording)

/// The answer a capability probe gives about one macOS permission.
///
/// `.notAsked` is a distinct answer, not a flavour of "no": macOS decides a
/// Files-&-Folders permission only at the moment an app first attempts the access, so
/// before that there genuinely is nothing recorded. Folding it into `.denied` would cry
/// wolf on every fresh install; folding it into `.granted` would hide the one row that
/// is about to break. `.unknown` is for what a normal app simply cannot observe — a
/// volume class with no such volume mounted — and the UI says "unknown" rather than
/// guessing, because a confident wrong status is worse than no status.
/// `.off` is kept apart from `.denied` for the same reason: a Finder extension nobody
/// has ever ticked was not "denied" by anyone, and saying so would have the user hunting
/// System Settings for a refusal that never happened.
/// `.covered` is the answer to a question macOS never lets an app ask directly: the
/// permission was never recorded, and never will be, because a broader one already
/// stands in for it. It reads as satisfied — because it IS — without claiming the
/// probe proved anything, which `.granted` would.
enum PermissionState: String, Equatable {
    case granted, denied, notAsked, unknown, off, covered

    var label: String {
        switch self {
        case .granted:  return "Granted"
        case .denied:   return "Denied"
        case .notAsked: return "Not yet asked"
        case .unknown:  return "Unknown"
        case .off:      return "Off"
        case .covered:  return "Covered by Full Disk Access"
        }
    }

    var symbol: String {
        switch self {
        case .granted:  return "checkmark.circle.fill"
        case .denied:   return "exclamationmark.octagon.fill"
        case .notAsked: return "circle.dashed"
        case .unknown:  return "questionmark.circle"
        case .off:      return "circle.slash"
        case .covered:  return "checkmark.circle"
        }
    }

    /// Drives the assistant's one-line summary. `.unknown` is deliberately NOT counted:
    /// we have no evidence anything is wrong, and sending someone to System Settings to
    /// fix a permission that may well be fine is how a setup screen loses its credibility.
    var needsAttention: Bool { self == .denied || self == .notAsked || self == .off }
}

/// The rules the Setup Assistant's rows and its footer count BOTH read.
///
/// They live together here because they used to be worked out separately and disagreed:
/// the footer counted rows whose only offered fix was a switch macOS was not showing, so
/// the very first screen of a fresh install announced work that did not exist and pointed
/// at a pane where the named row could not appear. A setup screen that cries wolf once is
/// worse than no setup screen, so both numbers now come out of the same three functions.
enum SetupAudit {

    /// The rows Full Disk Access makes moot.
    ///
    /// FDA (kTCCServiceSystemPolicyAllFiles) is a strict superset of the per-folder and
    /// per-volume-class Files & Folders grants, and macOS acts on that: an app holding it
    /// gets ONE greyed "Full Disk Access" line in the Files & Folders pane INSTEAD of the
    /// individual switches. So a row saying "go turn Desktop on" names a control that is
    /// provably not on the screen we just sent the user to.
    ///
    /// Automation and the Finder extension are deliberately absent: FDA says nothing about
    /// either, and folding them in would swap one false statement for another.
    static let coveredByFullDisk: Set<String> = ["Desktop", "Documents", "Downloads", "network", "removable"]

    /// What a row should actually say, given its own probe and the Full Disk Access answer.
    ///
    /// Only an answer that would otherwise raise an alarm gets rewritten. A probe that came
    /// back `.granted` keeps that word because it is proof — the access was performed — and
    /// `.unknown` stays unknown because FDA tells us nothing about a volume class with no
    /// volume mounted, and unknown is already not an alarm.
    static func effectiveState(id: String, probed: PermissionState, fullDisk: PermissionState) -> PermissionState {
        guard probed.needsAttention, fullDisk == .granted, coveredByFullDisk.contains(id) else { return probed }
        return .covered
    }

    /// The footer's number, from the same inputs the rows draw themselves from.
    ///
    /// Optional rows never count: Navigator is fully usable without Full Disk Access, so an
    /// unlit optional switch is a choice the user has made, not a job they still owe.
    static func attentionCount(_ rows: [(id: String, probed: PermissionState, optional: Bool)],
                               fullDisk: PermissionState) -> Int {
        rows.filter { !$0.optional && effectiveState(id: $0.id, probed: $0.probed, fullDisk: fullDisk).needsAttention }
            .count
    }

    /// Which of a row's two buttons lead somewhere the user can actually do something.
    ///
    /// `listedOnlyAfterRequest` is the whole point: macOS creates a Files & Folders (or
    /// Automation) row for an app only once the app has attempted the access — before that
    /// the pane has no switch to flip, so "Open Settings" is a guaranteed dead end and the
    /// only thing that works is provoking the real system prompt. A `.covered` row offers
    /// neither: there is nothing to ask for and nothing in Settings to look at.
    static func buttons(state: PermissionState, canAsk: Bool,
                        listedOnlyAfterRequest: Bool) -> (ask: Bool, settings: Bool) {
        let unrequested = state == .notAsked || state == .unknown
        return (ask: canAsk && unrequested,
                settings: state != .covered && !(listedOnlyAfterRequest && unrequested))
    }
}

enum PermissionDiagnosis {

    /// Is this NSError macOS refusing on permission grounds, as opposed to the file
    /// being missing, locked, or on a full disk?
    ///
    /// Both domains matter because the two engines Navigator copies with report
    /// differently: FileManager raises NSCocoaErrorDomain 257/513, while the copyfile()
    /// path builds its error straight from `errno` (EPERM/EACCES).
    static func isDenial(domain: String, code: Int) -> Bool {
        switch domain {
        case NSCocoaErrorDomain: return code == 257 || code == 513   // NSFileRead/WriteNoPermissionError
        case NSPOSIXErrorDomain: return code == 1 || code == 13      // EPERM / EACCES
        default: return false
        }
    }

    /// Same question, asked of a message rather than an error.
    ///
    /// Needed because the app funnels every file failure through one alert helper that
    /// only ever receives `localizedDescription` — threading a structured error through
    /// forty call sites to reach the same alert would be a far bigger change than the
    /// problem deserves. Known ceiling: these are the English strings Cocoa and strerror
    /// produce, so on a non-English system the alert falls back to the generic wording it
    /// has always shown. Upgrade path if that ever matters: pass the NSError down and use
    /// `isDenial` above, which is locale-proof.
    static func looksLikeDenial(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("permission denied")
            || t.contains("don't have permission") || t.contains("don\u{2019}t have permission")
            || t.contains("not permitted")
    }

    /// Which macOS-protected folder a path sits in, so a denial can name the folder the
    /// user was actually aiming at ("your Desktop") instead of lecturing about TCC.
    ///
    /// Only these three: they are exactly the home folders macOS gates behind their own
    /// Files-&-Folders switches. Pictures/Music/Movies are NOT gated, and claiming they
    /// were would send people looking for a switch that doesn't exist.
    static func protectedFolder(for path: String, home: String) -> String? {
        let h = URL(fileURLWithPath: home)
        return ["Desktop", "Documents", "Downloads"].first {
            PathRules.isSelfOrDescendant(URL(fileURLWithPath: path), of: h.appendingPathComponent($0))
        }
    }
}

// MARK: - Open/Save dialog bridge

/// The decisions behind "put my location where another app's Open/Save panel can reach
/// it". Pure, so the four selection cases and the chord table are pinned by tests — the
/// hotkey itself fires while Navigator is in the background, where a wrong answer is
/// invisible until it has already sent someone's dialog to the wrong folder.
///
/// Why a clipboard at all: macOS has no picker role. An Open/Save panel is always
/// NSOpenPanel/NSSavePanel (drawn by Powerbox for sandboxed apps), LaunchServices only
/// knows Viewer/Editor/Shell, and nothing in macOS 26 changed that — so a third-party
/// browser cannot be substituted for the panel. What every one of those panels DOES
/// accept is a POSIX path pasted into ⌘⇧G, which is the supported bridge this builds on.
enum PickerBridgeRules {

    /// The one path to hand a dialog's ⌘⇧G.
    ///
    /// A single selected FILE is deliberately returned as the file itself, not its
    /// folder: an Open panel's ⌘⇧G navigates to it *and* preselects it, so the user is
    /// one Return from done. A single folder is likewise itself — for a Save panel that
    /// is the destination, and for an Open panel it is where you wanted to look.
    static func pathToCopy(folder: String, selection: [String]) -> String {
        if selection.count == 1, !selection[0].isEmpty { return selection[0] }
        // Several items: a dialog can only go one place, so it goes to the folder they
        // live in. Taken from the items themselves rather than assumed to be `folder`,
        // because in search results the hits come from anywhere below it — and the
        // folder they share is a far better answer than the search root. Falls back to
        // `folder` when they genuinely don't share one.
        let parents = Set(selection.map { ($0 as NSString).deletingLastPathComponent })
        if parents.count == 1, let only = parents.first, !only.isEmpty { return only }
        return folder
    }

    /// A global hot key, described in the two forms both consumers need: Carbon's
    /// (keyCode, modifiers) pair for RegisterEventHotKey, and glyphs for the menu.
    struct Chord: Equatable {
        /// Stored in UserDefaults, so it must never change for an existing chord.
        let id: String
        /// The printable key, both for `display` and for the menu item's key equivalent.
        let key: String
        /// Carbon virtual key code (kVK_ANSI_*). Spelled numerically because this file
        /// deliberately imports nothing but Foundation.
        let keyCode: UInt32
        /// Carbon modifier mask: controlKey 0x1000, optionKey 0x800, shiftKey 0x200,
        /// cmdKey 0x100.
        let carbonModifiers: UInt32
        var display: String { PickerBridgeRules.glyphs(carbonModifiers) + key }
    }

    static let controlKeyMask: UInt32 = 0x1000
    static let optionKeyMask: UInt32  = 0x0800
    static let shiftKeyMask: UInt32   = 0x0200
    static let commandKeyMask: UInt32 = 0x0100

    /// The offered chords, rather than a free-form key recorder: every one of these is
    /// ⌃⌥⌘ + a letter, which no shipping macOS shortcut and nothing in Navigator's own
    /// menus uses, so picking one can't quietly shadow a chord the user relies on.
    ///
    /// None of them include Shift, and that is load-bearing: `teleportChord` derives the
    /// second hot key by ADDING Shift, so a Shift-bearing choice here would make the two
    /// chords identical.
    static let chords: [Chord] = [
        // ⌃⌥⌘G — G as in the ⌘⇧G it feeds. kVK_ANSI_G.
        Chord(id: "ctrl-opt-cmd-g", key: "G", keyCode: 5,
              carbonModifiers: controlKeyMask | optionKeyMask | commandKeyMask),
        // kVK_ANSI_P
        Chord(id: "ctrl-opt-cmd-p", key: "P", keyCode: 35,
              carbonModifiers: controlKeyMask | optionKeyMask | commandKeyMask),
        // kVK_ANSI_K
        Chord(id: "ctrl-opt-cmd-k", key: "K", keyCode: 40,
              carbonModifiers: controlKeyMask | optionKeyMask | commandKeyMask)
    ]

    /// Falls back to the first chord for an unknown or absent id, so a pref written by a
    /// later version (or a hand-edited plist) leaves the feature working rather than off.
    static func chord(id: String?) -> Chord {
        chords.first { $0.id == id } ?? chords[0]
    }

    /// The one-keystroke variant is always the copy chord plus Shift: one pref to set,
    /// and the pair stays memorable ("the same thing, harder").
    static func teleportChord(for c: Chord) -> Chord {
        Chord(id: c.id + "-shift", key: c.key, keyCode: c.keyCode,
              carbonModifiers: c.carbonModifiers | shiftKeyMask)
    }

    /// Modifier glyphs in Apple's canonical ⌃⌥⇧⌘ order — any other order reads as a
    /// typo next to the system's own menus.
    static func glyphs(_ carbonModifiers: UInt32) -> String {
        var s = ""
        if carbonModifiers & controlKeyMask != 0 { s += "\u{2303}" }
        if carbonModifiers & optionKeyMask  != 0 { s += "\u{2325}" }
        if carbonModifiers & shiftKeyMask   != 0 { s += "\u{21E7}" }
        if carbonModifiers & commandKeyMask != 0 { s += "\u{2318}" }
        return s
    }

    /// Path shortened for the confirmation HUD, from the LEFT: the tail names the file
    /// or folder the user just aimed at, and that is the part they need to recognise.
    static func hudLabel(_ path: String, max: Int = 56) -> String {
        guard path.count > max else { return path }
        var parts = path.split(separator: "/").map(String.init)
        while parts.count > 1 {
            parts.removeFirst()
            let candidate = "\u{2026}/" + parts.joined(separator: "/")
            if candidate.count <= max { return candidate }
        }
        // One component longer than the whole budget (a very long file name): keep its
        // end, since that is where the extension and any numbering live.
        return "\u{2026}" + String(path.suffix(max - 1))
    }

    // MARK: The Save-panel escape (bug: "one-key teleport wrote a file")
    //
    // The one-key variant used to post ⌘⇧G, wait a fixed 250 ms, ⌘V, wait 150 ms, ⏎.
    // In a Save panel that combination CREATED A FILE — once into a real Google Drive
    // shared-drive folder. The mechanism, measured rather than guessed:
    //
    //   Return is NOT delivered twice. When the Go-to-Folder sheet is genuinely up, one
    //   Return only navigates and the Save panel stays open. What goes wrong is the ⌘V:
    //   whenever the sheet has NOT appeared — the app doesn't honour ⌘⇧G, the panel is
    //   busy, 250 ms simply wasn't enough — the paste lands in the panel's OWN filename
    //   field, and NSSavePanel reads an absolute path there as a destination. The single
    //   Return then completes a real Save.
    //
    // So both halves get closed here: nothing is pasted until the Go-to-Folder field is
    // observed to hold focus, and Return is posted only into a panel proven to be an
    // Open panel. Neither is sufficient alone — the first makes the paste land where it
    // was aimed, the second means that even a misaimed paste can't be committed by us.

    /// What kind of Open/Save panel has keyboard focus, as far as the Accessibility tree
    /// will admit. `unknown` is a real and common answer — Photoshop's own Save As sheet,
    /// an ordinary window, an app that won't answer AX — and it is treated exactly like a
    /// Save panel, because the only safe reading of "I can't tell what this Return will
    /// do" is "then don't press it".
    enum PanelKind: Equatable { case openPanel, savePanel, unknown }

    /// Decided on AXIdentifiers, never on button titles: `open-panel`, `save-panel` and
    /// `saveAsNameTextField` are AppKit's own identifiers and are not localized, so this
    /// still works on a French Mac where the default button says "Enregistrer".
    static func panelKind(identifier: String?, hasFilenameField: Bool) -> PanelKind {
        // The filename field OUTRANKS the identifier: a panel that can name a new file is
        // a panel that can create one, whatever the panel calls itself.
        if hasFilenameField { return .savePanel }
        switch identifier {
        case "open-panel": return .openPanel
        case "save-panel": return .savePanel
        default:           return .unknown
        }
    }

    /// The hard constraint, in one line. Do not "simplify" this to `kind != .savePanel`:
    /// `unknown` must stay on the no-Return side or the guarantee is gone.
    static func mayPostReturn(_ kind: PanelKind) -> Bool { kind == .openPanel }

    /// Identifiers that mean "focus is in a dialog's Go-to-Folder field". `PathTextField`
    /// is the field itself and `GoToWindow` its sheet; either proves the sheet is up and
    /// listening, which is the precondition for pasting at all.
    static let goToFolderIdentifiers: Set<String> = ["PathTextField", "GoToWindow"]

    /// `chain` is the focused element and its ancestors, outward.
    static func isGoToFolderFocused(_ chain: [String]) -> Bool {
        chain.contains { goToFolderIdentifiers.contains($0) }
    }

    /// What actually happened, so the HUD can say it. Behaviour that differs between an
    /// Open and a Save panel is only acceptable if the user is told which one they got.
    enum TeleportOutcome: Equatable {
        /// Open panel: pasted and Return sent — the original one-press behaviour.
        case jumped
        /// Save panel or unidentifiable: pasted into Go to Folder, Return left to the user.
        case pastedAwaitingReturn
        /// Go to Folder never opened, so nothing was pasted anywhere.
        case noGoToFolder
    }

    static func teleportHUD(label: String, app: String, rescued: Bool,
                            outcome: TeleportOutcome) -> String {
        // Names the SOURCE, not just the path: when the clipboard's Drive path overrode
        // Navigator's own folder, the one case where it guessed wrong must be visible.
        let what = (rescued ? "clipboard\u{2019}s Drive path " : "") + label
        switch outcome {
        case .jumped:
            return "Jumped to \(what) in \(app)"
        case .pastedAwaitingReturn:
            return "Pasted \(what) in \(app) \u{00B7} press Return to go \u{2014} Navigator won\u{2019}t, in case it saves"
        case .noGoToFolder:
            return "Copied \(what) \u{00B7} \(app) didn\u{2019}t open Go to Folder \u{2014} press \u{2318}\u{21E7}G then \u{2318}V"
        }
    }
}

// MARK: - Drag state invariant

/// The one rule every drag flag in the app has to obey: **drag state may only be set while
/// a drag can actually be in flight.** Anything still claiming "a drag is over me" outside
/// those windows is a leak, and a leaked drag flag is invisible — the app stays responsive
/// and only *drag and drop* quietly stops working until the process is restarted.
///
/// This is worth a testable rule of its own because the flags are set and cleared from
/// AppKit callbacks that are not symmetric. `draggingEntered`/`draggingExited` fire on the
/// destination, the source's session-end fires on the source, `acceptDrop` fires on
/// neither reliably (a cancelled drag never reaches it), and some of the notifications have
/// to be published on a deferred main-queue hop because writing SwiftUI state synchronously
/// inside a drag callback destroys the drop targeting. Enumerating every AppKit path that
/// could skip a clear is not possible from outside AppKit; asserting the invariant at
/// moments when no drag CAN be running is.
///
/// Pure and parameterised on the button mask instead of reading `NSEvent` itself, so the
/// decision can be tested without a real drag.
enum DragStateRules {
    /// The left button's bit in `NSEvent.pressedMouseButtons`.
    private static let leftButtonMask = 1

    static func leftButtonIsDown(_ pressedMouseButtons: Int) -> Bool {
        pressedMouseButtons & leftButtonMask != 0
    }

    /// How long the drag callbacks have to have been silent before the WEAKER boundary is
    /// allowed to act. A live drag over the file list calls `validateDrop` on every mouse
    /// move, so ongoing callbacks are the signal that a session is still running; only a
    /// pointer held perfectly still for this long looks the same as no drag at all.
    ///
    /// Generous on purpose. Costing this boundary some eagerness is free, because the
    /// `mouseDown` boundary is exact and fires on the user's very next click in the list —
    /// whereas being too eager here breaks a live drop, which is the one unacceptable
    /// outcome. Ordered the same way the risk is.
    static let quietPeriod: TimeInterval = 2

    /// May a safety net clear drag state right now?
    ///
    /// Two INDEPENDENT proofs that no drag can be running, either of which is enough. They
    /// are NOT equally strong, and that asymmetry is the whole reason this is a function:
    ///
    ///  • a fresh `mouseDown` — EXACT. At a mouseDown the button is down, so the button
    ///    test below would never fire here; but a drag session runs its own event-tracking
    ///    loop and swallows the events it tracks, so an ordinary mouseDown arriving at a
    ///    view at all proves no session is running. True even for a drag that started in
    ///    another app, where this app's views get dragging callbacks and never a mouseDown.
    ///    This is also the proof that survives Drag Lock and three-finger drag.
    ///
    ///  • no mouse button down, AND the drag callbacks have gone quiet — INFERRED, which is
    ///    why it needs both halves. The button test alone reads "no drag" during macOS's
    ///    three-finger drag and Drag Lock, where a session continues with NO button
    ///    pressed. That matters because the boundaries this branch serves — app-activation
    ///    and window-became-key — are NOT actually drag-free moments: hovering the Dock
    ///    icon mid-drag activates the app, and an alert opening mid-drag (a background job
    ///    finishing, say) makes a new window key. Firing there would call reload() straight
    ///    into a live drag and silently kill the drop — the exact bug the lock exists to
    ///    prevent, converted from intermittent to reproducible. The quiet period is what
    ///    keeps that from happening.
    static func shouldClearStaleDragState(dragStateSet: Bool, pressedMouseButtons: Int,
                                          isFreshMouseDown: Bool,
                                          secondsSinceDragCallback: TimeInterval) -> Bool {
        guard dragStateSet else { return false }
        if isFreshMouseDown { return true }
        return !leftButtonIsDown(pressedMouseButtons) && secondsSinceDragCallback >= quietPeriod
    }

    /// Is a dragging session we believe is still in flight provably ORPHANED?
    ///
    /// Bug this serves: "drag and drop stops working; restarting Navigator fixes it."
    /// Measured with a standalone AppKit probe — while AppKit believes a session is in
    /// flight, `beginDraggingSession` returns nil (Swift types the result non-optional, so
    /// the nil arrives as a bogus reference and simply nothing happens: no willBeginAt, no
    /// drop, no endedAt). One leaked session therefore refuses every later drag anywhere in
    /// the app, which is why only a relaunch clears it.
    ///
    /// The only boundary allowed to declare an orphan is a fresh mouseDown, and it is
    /// EXACT rather than inferred — same proof `shouldClearStaleDragState` already relies
    /// on: a session runs its own event-tracking loop and swallows the events it tracks, so
    /// an ordinary mouseDown reaching a view at all proves no session of ours is running.
    /// Deliberately NOT "the button is up": macOS Drag Lock and three-finger drag both
    /// continue a live session with no button pressed, and firing there would tear down a
    /// drag the user is still performing — turning an occasional bug into a constant one.
    ///
    /// `endWatchStillArmed` is the one thing that can make the mouseDown boundary lie. The
    /// polled end-of-session watch only fires once the button comes back up and then waits
    /// out a short grace delay, so a user who clicks again inside that window has a session
    /// whose end is legitimately still pending — not a leak. Suppressing the claim there
    /// keeps the log line trustworthy as a bug report.
    static func isDragSessionOrphaned(sessionInFlight: Bool, isFreshMouseDown: Bool,
                                      endWatchStillArmed: Bool) -> Bool {
        sessionInFlight && isFreshMouseDown && !endWatchStillArmed
    }

    /// How long AppKit's real `draggingSession(_:endedAt:operation:)` gets to arrive after
    /// the button comes up before the polled watchdog is allowed to call the session leaked.
    ///
    /// BUG (drag-and-drop wedge), second half: at the old 0.25s this watchdog BEAT the real
    /// callback on every healthy drag — the log showed both, watchdog first, genuine end a
    /// moment later. A last resort that wins every race is not a last resort; it meant the
    /// leaked-session path ran mid-teardown on every single drag instead of on the rare leak
    /// it was written for. The real callback lands in milliseconds when it lands at all, so
    /// seconds of slack costs nothing and makes the watchdog's line mean what it says.
    ///
    /// The cost of a long interval is that the PREVIOUS drag's watchdog is still armed when
    /// the next drag starts — which is exactly why the watchdog now presents a ticket
    /// (`DragSessionLedger`) instead of trusting an in-flight flag.
    static let endWatchdogGrace: TimeInterval = 3
}

/// Which of the two competing ends of one dragging session is allowed to speak.
///
/// BUG (drag and drop stops working until Navigator is relaunched), second half of it. Two
/// paths report the end of a drag: AppKit's own `draggingSession(_:endedAt:operation:)`,
/// and a polled watchdog for the sources AppKit never calls it on. They were both firing,
/// unreconciled, on every healthy drag.
///
/// Tickets rather than a Bool, and that is the part worth reading. Making the watchdog wait
/// long enough to genuinely lose the race widens the window in which the PREVIOUS drag's
/// watchdog is still armed as the NEXT drag begins. Against a plain "is something in
/// flight" flag that stale watchdog would end the new, LIVE drag — tearing down a drag the
/// user is still performing, which is the one outcome worse than the bug being fixed. A
/// ticket names exactly one session, so a late watchdog can only ever be silent.
struct DragSessionLedger {
    /// Monotonic and never reused, so a ticket identifies one session for the life of the
    /// process — a wrapped or recycled ticket would reintroduce the confusion it prevents.
    private var issued = 0
    private var open: (source: String, ticket: Int)?

    /// What started the session believed to still be running; nil means idle.
    var inFlightSource: String? { open?.source }

    /// How many sessions this ledger has ever opened. Diagnostics only: "12 drags this session,
    /// none in flight" and "12 drags, one in flight since the third" are the same log with
    /// completely different meanings, and the count is what separates them.
    var sessionsOpened: Int { issued }

    /// Drops the open session without logging or arbitration — the manual "Reset Drag & Drop"
    /// command, and nothing else. Deliberately NOT one of the two ends: neither end may be
    /// silent about a session it closes, and this one has to be, because the command logs its
    /// own before/after snapshot instead.
    mutating func abandon() -> String? {
        defer { open = nil }
        return open?.source
    }

    /// Opens a session and returns the ticket its watchdog must present to close it.
    mutating func begin(_ source: String) -> Int {
        issued += 1
        open = (source, issued)
        return issued
    }

    /// The authoritative end — AppKit's own callback, or a source-side signal that the drag
    /// is definitively over. It arrives for whatever session is open and so needs no ticket.
    /// Returns the source to log, or nil when the session is already closed and this end
    /// must stay silent (the idempotence: whichever end lands first wins).
    mutating func closeAuthoritatively() -> String? {
        defer { open = nil }
        return open?.source
    }

    /// The watchdog's end. Returns the source to log, or nil when it must stay silent —
    /// either the authoritative end already closed this session, or `ticket` names an OLDER
    /// session and the one now open is still running.
    mutating func closeIfCurrent(ticket: Int) -> String? {
        guard let o = open, o.ticket == ticket else { return nil }
        open = nil
        return o.source
    }
}

/// What to do about a dragging session AppKit refused to start.
///
/// BUG (drag and drop stops working until Navigator is relaunched), the recovery half.
/// `beginDraggingSession` returning nil means AppKit still believes an earlier drag is in
/// flight, and until now that was detected and merely logged. This is the ladder that turns
/// detection into repair: try once, then tell the user once, then shut up forever.
///
/// "Once" is counted per WEDGE, not per process — a drag that demonstrably starts again
/// clears the counters, so a second wedge later in the session still gets its own attempt
/// and its own notice. Never nagging is a requirement, not a nicety: a notice that repeats
/// on every failed drag would be worse than the silence it replaces.
enum DragWedgeRules {
    enum Action: Equatable {
        case none
        /// Nudge AppKit into reconciling the phantom session, then re-attempt the drag once.
        case recoverAndRetry
        /// Recovery has already been tried and the drag is still refused: say so, once.
        case notifyUser
    }

    static func action(refused: Bool, recoveryAttempted: Bool, userNotified: Bool) -> Action {
        guard refused else { return .none }
        if !recoveryAttempted { return .recoverAndRetry }
        return userNotified ? .none : .notifyUser
    }
}

/// THE BUG (drag and drop stops working until Navigator is relaunched), reduced to the one
/// fact that actually defines it.
///
/// ROOT CAUSE, found and fixed: `ClickTimingTableView.draggingEnded(_:)` called
/// `super.draggingEnded(sender)`, and NSTableView does not implement that optional method.
/// The unrecognized-selector exception was raised inside AppKit's own NSCoreDragCompletionProc,
/// swallowed by the try/catch AppKit wraps drags in, and the unwind skipped the call that
/// removes the session from NSCoreDragManager's registry. AppKit then believed a drag was
/// in flight forever, so `beginDraggingSession` returned nil process-wide.
///
/// So the ONE observable that means "wedged" is: AppKit still has the finished drag registered.
/// Two earlier proxies for it were measured to be wrong and must not come back:
///   • "the NSDraggingSession object is still alive" — retired sessions routinely stay alive
///     for ten seconds and more in a healthy process;
///   • "no `endedAt` callback arrived" — AppKit never sends it to an NSTableView that is also a
///     registered drop destination, which the file list has to be.
/// Either one alone fired on every healthy list-view drag, which is how the real signal got
/// lost the first two times this bug was chased.
enum DragLeakRules {
    /// How long after a drag ends AppKit still gets to be "finishing the slide-back animation"
    /// before a session it has not retired counts as never. A cancelled drag's slide-back is a
    /// few hundred ms; seconds are decisive.
    static let retirementGrace: TimeInterval = 5

    /// Whether a finished drag should be reported as leaked — i.e. whether the process is now
    /// wedged. Unlike the proxies above this one is not a heuristic: an entry AppKit has not
    /// removed is exactly what makes the next `beginDraggingSession` return nil.
    static func isLeaked(stillRegisteredWithAppKit: Bool,
                         secondsSinceDragEnd: TimeInterval) -> Bool {
        stillRegisteredWithAppKit && secondsSinceDragEnd >= retirementGrace
    }
}

// MARK: - Running build vs installed build

/// `rebuild.sh` deletes and recreates `/Applications/Navigator.app` while the old process
/// keeps running the binary it already mapped. Nothing in the app noticed: the in-app updater
/// compares the INSTALLED bundle's version against GitHub, so both read the same number and it
/// answers "up to date" while the process is executing hours-old code. That is not a
/// hypothetical — it is how a fixed drag-and-drop bug went on reproducing for an afternoon,
/// with the log showing behaviour the source no longer contained.
///
/// The executable's modification date rather than the version string, because during
/// development the version does NOT change between builds — the whole failure mode is two
/// different binaries claiming the same version. A hash would be equally sound and costs a
/// full read of a 19 MB fat binary on every app activation; a stat costs nothing.
enum RunningBuildRules {
    /// Filesystem timestamps and the copy that installs the bundle are not atomic with the
    /// launch that reads them, so an equal-or-barely-newer stamp must not count as a new
    /// build. Anything shorter than this reported the CURRENT build as stale on some launches.
    static let tolerance: TimeInterval = 2

    static func isStale(runningBuiltAt: Date, onDiskBuiltAt: Date) -> Bool {
        onDiskBuiltAt.timeIntervalSince(runningBuiltAt) > tolerance
    }

    /// Once per DETECTED BUILD, never once per activation. `alreadyNoticed` is the on-disk
    /// stamp the user was last told about, so a second rebuild while the notice is still
    /// pending gets its own notice and a hundred app switches get none.
    static func shouldNotify(runningBuiltAt: Date, onDiskBuiltAt: Date, alreadyNoticed: Date?) -> Bool {
        guard isStale(runningBuiltAt: runningBuiltAt, onDiskBuiltAt: onDiskBuiltAt) else { return false }
        guard let alreadyNoticed else { return true }
        return abs(onDiskBuiltAt.timeIntervalSince(alreadyNoticed)) > tolerance
    }

    /// Coarse, human units. A build age is read to answer "is that the one I just made?", and
    /// seconds of precision get in the way of that.
    static func age(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86_400)d \((s % 86_400) / 3600)h"
    }

    static func stamp(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    /// The one line that says which of two same-numbered builds is actually running. Used by
    /// the log, by Check for Updates… and by the diagnostics dump, so all three agree.
    static func describe(runningBuiltAt: Date, onDiskBuiltAt: Date) -> String {
        let running = "running \(stamp(runningBuiltAt)), installed \(stamp(onDiskBuiltAt))"
        guard isStale(runningBuiltAt: runningBuiltAt, onDiskBuiltAt: onDiskBuiltAt) else {
            return running + " — same build"
        }
        return running + " — the installed build is \(age(onDiskBuiltAt.timeIntervalSince(runningBuiltAt))) NEWER than the one running"
    }
}

// MARK: - Drop diagnostics

/// Why a drop that ARRIVED at a surface was not acted on.
///
/// The blind spot this closes: a drop Navigator silently declines and a drop that never
/// reached Navigator at all produced identical logs — nothing. The owner's report was "drag
/// and drop is broken again" against a log showing twelve clean drag sessions, because every
/// one of those lines is the SOURCE side. Destination-side refusals are where the silence was.
///
/// A closed set rather than free-text at each call site, so every surface names the same cause
/// the same way and the reasons can be asserted in tests instead of eyeballed in a log.
enum DropRejection: Equatable {
    /// The pasteboard offered nothing this surface can read at all.
    case noReadableTypes
    /// Only Navigator's own private drag tokens (`navreorder:` / `navtab:`) — a sidebar row or
    /// a tab released somewhere that only accepts files. Counted, because "1 token" is a
    /// mis-aimed reorder and "8 tokens" would mean something quite different.
    case noFileURLs(tokens: Int)
    /// A reorder token landed on a row that is not an entry in the favorites store, so there
    /// is nothing to reorder it against (Locations, Recents, Cloud, expanded subfolders).
    case notAReorderTarget
    /// Every item was the destination folder itself or lived inside it.
    case selfOrDescendant(count: Int)
    /// The drop resolved to no destination — the surface had no folder to hand.
    case missingTarget
    /// The surface takes files, but not THESE files (the style reference well wants an image).
    case wrongKind(String)
    /// Accepted, then found to have nothing left to do. The most deceptive failure of all:
    /// the drop "worked" and moved nothing.
    case nothingToDo(String)

    var reason: String {
        switch self {
        case .noReadableTypes:
            return "the pasteboard offered no types this surface can read"
        case .noFileURLs(let tokens):
            return "no file URLs on the pasteboard — \(tokens) private drag token(s) only (a sidebar row or a tab, released on a surface that only takes files)"
        case .notAReorderTarget:
            return "a reorder token landed on a row that is not a reorderable favorite"
        case .selfOrDescendant(let count):
            return "\(count) item(s) are the destination itself or live inside it"
        case .missingTarget:
            return "no destination folder resolved for this drop"
        case .wrongKind(let what):
            return "this surface accepts \(what) and none of the dropped items are"
        case .nothingToDo(let why):
            return "accepted but nothing to transfer — \(why)"
        }
    }

    /// The reason a surface that only takes files must decline, or nil when it can proceed.
    /// One rule for every such surface: the alternative was each of eight call sites deciding
    /// for itself what "unusable" means, which is how they came to disagree.
    static func forFileDrop(items: Int, fileURLs: Int) -> DropRejection? {
        if items == 0 { return .noReadableTypes }
        if fileURLs == 0 { return .noFileURLs(tokens: items) }
        return nil
    }
}

/// One dense line per drop event, in the style of the refusal-preconditions line: everything
/// needed to tell an arrival from a refusal from a no-op, and nothing that has to be
/// correlated across lines to be useful. A skimmable log, not a trace.
enum DropLogLine {
    enum Outcome: Equatable {
        /// Handled. The string says what was done with it ("into folder", "favorite reorder").
        case accepted(String)
        case refused(DropRejection)
        /// The drop was ACCEPTED — the handler returned true, the drag animation showed
        /// success — and then nothing happened. Its own category, because it is the failure the
        /// owner cannot see from the outside and the one a plain accept/reject log would hide:
        /// "drag and drop is broken" with a log full of clean drags is exactly this shape.
        case acceptedButInert(DropRejection)
    }

    static func text(surface: String, types: [String], items: Int, fileURLs: Int,
                     target: String?, outcome: Outcome) -> String {
        let head: String
        switch outcome {
        case .accepted:         head = "drop received: \(surface)"
        case .refused:          head = "drop REFUSED: \(surface)"
        case .acceptedButInert: head = "drop NO-OP: \(surface)"
        }
        // Types are the first thing to check when a drop from Photoshop or Chrome behaves
        // differently from the same drag out of Finder, so they are always present — even on
        // the accepted line, where they are the record of what a WORKING drop looked like.
        let payload = "\(items) item(s), \(fileURLs) usable file URL(s), types [\(types.joined(separator: ", "))]"
        let where_ = target.map { " → \($0)" } ?? " → (no target)"
        switch outcome {
        case .accepted(let what):                        return "\(head) — \(payload)\(where_) — \(what)"
        case .refused(let r), .acceptedButInert(let r):   return "\(head) — \(payload)\(where_) — \(r.reason)"
        }
    }
}

/// The transfer's own reporting, which the user-facing alert cannot replace: the alert shows
/// at most five failures and only when there are any, so a drop that moved two of three files
/// looked like a complete success. Per-file failures are logged with the underlying error at
/// the point they happen; this is the closing summary.
enum TransferLogLine {
    static func summary(move: Bool, moved: Int, copied: Int, failed: Int, skipped: Int,
                        total: Int, cancelled: Bool, target: String) -> String {
        let settled = move ? moved : copied
        var s = "transfer done: \(move ? "move" : "copy") \(settled)/\(total) → \(target)"
        if failed > 0 { s += ", \(failed) FAILED" }
        if skipped > 0 { s += ", \(skipped) skipped (name conflict)" }
        if cancelled { s += ", CANCELLED by the user" }
        // The line that makes a silent no-op visible. Everything else about such a drop looks
        // exactly like a success: a progress sheet appeared, no error was raised, nothing moved.
        if settled == 0, failed == 0, !cancelled { s += " — NOTHING WAS TRANSFERRED" }
        return s
    }
}

// MARK: - Reset Drag & Drop

/// What the manual "Reset Drag & Drop" command is allowed to do, and what it must not claim.
///
/// Two honesty constraints, both of which the command is worthless without:
///   • it must be INERT during a live drag. Clearing the ledger and the spring state mid-drag
///     is precisely the failure this whole subsystem has been bitten by (a reload during a
///     drag discards its drop targeting), so a reset fired by accident would MANUFACTURE the
///     bug it is meant to relieve;
///   • it must not report success it cannot deliver. Our reset clears only state this app
///     owns. If AppKit's own registry is still holding a session, dragging stays broken no
///     matter what we clear, and saying "fixed" would send the owner back to a dead feature.
enum DragResetRules {
    /// Same asymmetry `DragStateRules` documents: the button being up is NOT proof no drag is
    /// running (Drag Lock and three-finger drag continue a session with no button pressed), so
    /// an open session whose callbacks are still fresh blocks the reset as well.
    static func mayReset(leftButtonDown: Bool, sessionInFlight: Bool,
                         secondsSinceDragActivity: TimeInterval) -> Bool {
        if leftButtonDown { return false }
        if sessionInFlight, secondsSinceDragActivity < DragStateRules.quietPeriod { return false }
        return true
    }

    enum Outcome: Equatable {
        /// Nothing is holding a session: dragging should work again.
        case cleared
        /// AppKit still lists the last session as in flight. Nothing this process can do fixes
        /// that — see DragSessionTracker for the measurements behind that claim.
        case relaunchRequired
        /// The private AppKit registry could not be read on this system, so the one observable
        /// that distinguishes the two cases above is unavailable. Say so rather than guess.
        case cannotTell
    }

    static func outcome(appKitStillHoldsSession: Bool?) -> Outcome {
        switch appKitStillHoldsSession {
        case .some(true):  return .relaunchRequired
        case .some(false): return .cleared
        case nil:          return .cannotTell
        }
    }

    static func message(_ o: Outcome) -> String {
        switch o {
        case .cleared:
            return "Navigator’s drag state has been cleared and macOS is not holding a drag, so dragging should work again. If it still doesn’t, the log now says why — send Drag Diagnostics."
        case .relaunchRequired:
            return "Navigator’s own drag state is cleared, but macOS still has a finished drag registered as in flight. Nothing Navigator can do clears that, so dragging will keep failing until Navigator is relaunched."
        case .cannotTell:
            return "Navigator’s drag state has been cleared. Whether macOS is still holding a drag of its own can’t be read on this version of macOS, so if dragging is still broken, relaunching is the fix."
        }
    }
}

// MARK: - Drag diagnostics dump

/// Everything about the drag subsystem's live state, in one clipboard-sized report.
///
/// Written to be pasted into a conversation with someone who cannot touch the machine — which
/// is the actual constraint this exists under. So: no interactive follow-up, no "check whether
/// X"; every observable that the last three rounds of this bug turned on is in here, including
/// the ones whose value is "cannot tell".
struct DragDiagnosticsSnapshot {
    var appVersion = ""
    /// The running-vs-installed comparison in full (see RunningBuildRules.describe) — first,
    /// because a report from a stale binary describes code that no longer exists.
    var buildComparison = ""
    var buildIsStale = false
    /// The source of a session the ledger still believes is open; nil when idle.
    var sessionInFlight: String?
    var sessionsOpened = 0
    var refusals = 0
    var leaksReported = 0
    var isDragActive = false
    /// How long ago that lock was last written, when it is known. A `true` written seconds ago is
    /// a live drag; the same `true` written twenty minutes ago is a stuck lock, and the whole
    /// value of the field is telling those two apart.
    var isDragActiveAge: TimeInterval?
    var springState = ""
    var mouseUpWatches = ""
    var keepAliveHeld = 0
    var lastSessionSequence: Int?
    /// nil means the private AppKit registry could not be read — a real and distinct answer.
    var appKitHoldsLastSession: Bool?
    var pressedMouseButtons = 0
    var logTail: [String] = []
}

enum DragDiagnosticsReport {
    /// Enough lines to hold a whole failed drag and the healthy ones before it, few enough to
    /// paste into a message without being trimmed.
    static let logTailLimit = 40

    /// The drag-relevant tail of the dev log. Filtered rather than dumped whole because the
    /// same log carries Imagen batches and network polling, and a report that has to be
    /// scrolled past is a report that gets skimmed.
    static func dragLines(from log: String, limit: Int = logTailLimit) -> [String] {
        let keys = ["drag", "drop", "spring", "tear-off", "transfer", "build"]
        let hits = log.split(separator: "\n", omittingEmptySubsequences: true).filter { line in
            let l = line.lowercased()
            return keys.contains { l.contains($0) }
        }
        return hits.suffix(limit).map(String.init)
    }

    static func text(_ s: DragDiagnosticsSnapshot) -> String {
        var out = ["Navigator drag & drop diagnostics"]
        out.append("app version: \(s.appVersion)")
        out.append("build: \(s.buildComparison)")
        if s.buildIsStale {
            // Stated as a warning and not just a fact: every other line below describes a
            // binary that is not the one on disk, and a diagnosis made against the wrong
            // source is worse than no diagnosis.
            out.append("WARNING: this report comes from a STALE running build — relaunch and reproduce before trusting anything below")
        }
        out.append("session in flight: \(s.sessionInFlight ?? "none")")
        out.append("sessions opened this process: \(s.sessionsOpened), refusals: \(s.refusals), leaks reported: \(s.leaksReported)")
        let lockAge = s.isDragActiveAge.map { ", last written \(RunningBuildRules.age($0)) ago" } ?? ""
        out.append("isDragActive (file list lock): \(s.isDragActive)\(lockAge)")
        out.append("spring loader: \(s.springState)")
        out.append("mouse-up watches: \(s.mouseUpWatches)")
        out.append("drag source keep-alive holding: \(s.keepAliveHeld) view(s)")
        out.append("pressed mouse buttons: \(s.pressedMouseButtons)")
        let seq = s.lastSessionSequence.map(String.init) ?? "none"
        switch s.appKitHoldsLastSession {
        case .some(true):
            out.append("AppKit registry: STILL HOLDS drag \(seq) as in flight — this process is wedged, relaunch is the only fix")
        case .some(false):
            out.append("AppKit registry: no in-flight drag (last session \(seq) was retired normally)")
        case nil:
            out.append("AppKit registry: cannot tell — NSCoreDragManager could not be read on this macOS (last session \(seq))")
        }
        out.append("")
        out.append("last \(s.logTail.count) drag-related log line(s):")
        out.append(contentsOf: s.logTail)
        return out.joined(separator: "\n") + "\n"
    }
}

// MARK: - Shared folder index (.navigator)
//
// A share costs ~89 ms per file for size/date — one network round trip each, and no macOS
// API batches it (see PERFORMANCE.md). But the ANSWER is the same for everyone on the team,
// so one person paying 59 s for artSource can spell it for everybody: 669 entries land in a
// 56 KB file that reads back in 1.2 s. Measured 51x.
//
// The safety property that makes this usable on a drive full of Windows users who have never
// heard of Navigator: THE INDEX NEVER DECIDES WHAT EXISTS. Presence always comes from a live
// readdir, which is free. The index only supplies attributes for names that readdir already
// confirmed. So a file someone added is simply unindexed and gets fetched; a file someone
// deleted has an entry nobody ever looks up. A stale index cannot invent or hide anything.
//
// The residual gap is a file edited IN PLACE — same name, new size. maxAge bounds how long a
// wrong size can survive, and visible-rows-first re-fetches whatever is actually on screen,
// so anything you look at is corrected from the server regardless.
enum ShareIndexRules {
    static let version = 3   // v3 separates fullSweptAt from dirMtime; older files are rewritten
    /// One hidden directory at the volume root rather than a file in every folder: the same
    /// read cost, one place to exclude from Perforce or delete. (Thumbs.db, the convention
    /// this follows, is 469 KB per folder; an index of 669 entries is 56 KB.)
    static let directoryName = ".navigator"
    /// How long an entry may be trusted for a file that still exists under the same name.
    static let maxAge: TimeInterval = 7 * 24 * 3600
    /// Never parse more than this from a shared location written by other machines.
    static let maxBytes = 8 << 20
    /// Below this an index isn't worth a round trip — readdir plus a few stats is cheaper.
    static let minEntriesToWrite = 40

    /// Stable filename for a folder, keyed on its path relative to the volume root so the
    /// index survives the share being mounted at a different point (/Volumes/Games vs
    /// Games-1, or a coworker's own mount name).
    static func filename(forRelative rel: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325            // FNV-1a, 64-bit
        for b in Array(rel.utf8) {
            h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3   // FNV-64 prime; grouped in 4s so the
                                                           // digit count is checkable at a glance
        }
        // String(format: "%016llx", h) mangles the top bits of a Swift UInt64 passed as a C
        // variadic — deterministic, so it still round-trips, but it threw away 24 bits of the
        // hash and that much collision resistance. Format it directly instead.
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex + ".json"
    }

    /// Split a live listing against what the index knows. Names the index has are free; names it
    /// doesn't are the only ones needing a round trip. This is what makes repair incremental:
    /// readdir hands us the truth about which files exist at no cost, so a folder where someone
    /// added three files costs three stats to repair, not 669.
    ///
    /// Names the index has but the listing doesn't are simply not carried forward — that is how
    /// deletions leave the index, without needing to be detected.
    static func repairPlan(liveNames: [String], indexedNames: Set<String>)
        -> (carryForward: [String], mustStat: [String]) {
        var carry: [String] = [], stat: [String] = []
        for n in liveNames {
            if indexedNames.contains(n) { carry.append(n) } else { stat.append(n) }
        }
        return (carry, stat)
    }

    /// An index is worth reading if we wrote the format and it isn't ancient.
    /// `fullSweptAt` is when every entry was last read from the server, NOT when the file was last
    /// touched. Incremental repairs deliberately do not advance it: carrying it forward is what
    /// guarantees a full sweep eventually happens, which is the only thing that catches a file
    /// edited IN PLACE (same name, same directory mtime, different size). Without that
    /// distinction an actively-changing folder would be patched forever and never re-read.
    static func isUsable(version v: Int, savedAt: Double, now: Double) -> Bool {
        v == version && now - savedAt < maxAge && savedAt <= now + 60   // tolerate small clock skew
    }

    /// Split the live listing into "the index can answer this" and "must be fetched".
    /// liveNames is the truth; indexedNames is whatever the file happened to contain.
    static func partition(liveNames: [String], indexedNames: Set<String>)
        -> (fromIndex: [String], mustFetch: [String]) {
        var fromIndex: [String] = [], mustFetch: [String] = []
        for n in liveNames {
            if indexedNames.contains(n) { fromIndex.append(n) } else { mustFetch.append(n) }
        }
        return (fromIndex, mustFetch)
    }

    /// Is the index complete enough that fetching the few names it missed beats re-sweeping the
    /// whole folder? A handful of new files is worth a handful of round trips; an index that only
    /// knows a third of the folder is not worth 400 individual fetches.
    static func coversEnoughToSkipSweep(fromIndex: Int, total: Int) -> Bool {
        total > 0 && Double(fromIndex) / Double(total) >= 0.8
    }

    /// Rewrite when there is nothing there, when what's there is stale, or when the folder
    /// changed. Not on every visit — that would put a 5 s write on the share per user per look.
    static func shouldWrite(existingSavedAt: Double?, now: Double, dirChanged: Bool, entryCount: Int) -> Bool {
        guard entryCount >= minEntriesToWrite else { return false }
        guard let saved = existingSavedAt else { return true }
        return dirChanged || (now - saved) > maxAge / 2
    }

    /// Does the index need rebuilding in the background after we've already shown its contents?
    ///
    /// The trigger is the folder's own mtime, and ONLY that: adding or removing a file bumps it,
    /// so it detects exactly the changes an index can get wrong about which files exist.
    ///
    /// Deliberately NOT "the live listing had names the index lacks". That looks like a sensible
    /// second trigger and is a trap: the index is written from the enumerator, which filters
    /// DOS-hidden files, while the live listing comes from readdir, which only filters dot-names.
    /// On a Windows-authored share those two never agree (measured 670 vs 672 on artSource —
    /// Thumbs.db and desktop.ini), so that condition is permanently true and would rebuild the
    /// whole folder in the background on EVERY visit, forever.
    static func needsBackgroundRefresh(indexDirMtime: Double?, actualDirMtime: Double?) -> Bool {
        guard let a = actualDirMtime, let i = indexDirMtime else { return false }
        return abs(a - i) > 1     // whole-second resolution over SMB
    }
}

// MARK: - Share URLs in shared files

enum ShareURLRules {
    /// Strip the user (and any password) from a share URL.
    ///
    /// The mount table reports `//alice@fileserver.example.com/Games`, so a mount URL derived
    /// from it carries whose account it was. Favorites get EXPORTED and handed to coworkers — a
    /// file that tells their Mac to authenticate as someone else is both a small privacy leak and
    /// a support call, because NetFS will try that account and fail. Sanitizing here makes it a
    /// rule rather than an accident of which dialog happened to create the favorite.
    static func withoutUser(_ raw: String) -> String {
        guard var c = URLComponents(string: raw), c.user != nil || c.password != nil else { return raw }
        c.user = nil
        c.password = nil
        return c.string ?? raw
    }
}

// MARK: - Why a mount failed

/// NetFSMountURLSync reports POSIX errno values. Telling a coworker "check the address and that
/// you're on the VPN" for every failure is a guess that makes them doubt the part they got right —
/// and on these shares the VPN is the usual culprit, so it's worth naming precisely.
/// A network folder that hangs because macOS is stuck trying to mount it, not because the share is
/// down.
///
/// Measured on a real domain share: /Volumes/Games listed instantly while /Volumes/Games/artSource
/// hung a plain `ls` indefinitely, with a mount_url helper for that exact path running for five and
/// a half minutes and never producing a mount. Those subfolders are DFS links — listing the parent
/// makes macOS auto-mount each one, and a referral whose target is unreachable simply never returns.
///
/// This matters because the existing "isn't responding" panel offered to RECONNECT THE SHARE, and
/// the share was never the problem: reconnecting a healthy parent does nothing for a wedged child.
/// The stuck helper has to be cancelled instead.
enum StuckMountRules {
    /// PIDs of mount helpers wedged on `path`, parsed from `ps -Ao pid=,command=` output.
    ///
    /// Matched on the MOUNTPOINT argument, which is the last path on the line, rather than anywhere
    /// in the command: the same line also carries the smb:// source, and matching that would let a
    /// helper working on a different mountpoint of the same share be killed.
    static func wedgedPIDs(psOutput: String, mountPoint path: String) -> [Int32] {
        var out: [Int32] = []
        let target = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !target.isEmpty, target != "/" else { return [] }
        for line in psOutput.split(separator: "\n") {
            let text = String(line)
            guard text.contains("mount_url") || text.contains("mount_smbfs") else { continue }
            // The mountpoint is the trailing argument. Compared whole so /Volumes/Games never
            // matches a helper for /Volumes/Games Extra.
            guard text.hasSuffix(" " + target) || text.hasSuffix("\t" + target) else { continue }
            let head = text.trimmingCharacters(in: .whitespaces)
            let pidText = head.prefix(while: { $0.isNumber })
            if let pid = Int32(pidText), pid > 1 { out.append(pid) }
        }
        return out
    }

    /// What to tell someone whose folder will not open, given whether a helper is wedged on it.
    static func explain(name: String, wedged: Bool) -> (title: String, detail: String, action: String?) {
        if wedged {
            // The copy here was WRONG in the first version and the correction is the point of this
            // comment. It said cancelling "releases the folder". It does not: SIGKILLing the helper
            // was measured, and macOS spawned a fresh automount within seconds of anything touching
            // the path again. Cancelling stops the wedged attempt; it cannot make an unreachable
            // server answer. So the honest action is to stop trying AND leave the folder alone.
            return ("“\(name)” points at a server that isn’t answering",
                    "The drive itself is fine. This folder is a link to another server, and that "
                    + "server hasn’t responded — so macOS keeps trying to connect and anything "
                    + "touching the folder waits with it. Leaving it alone is the fix until that "
                    + "server is back. No files are affected.",
                    "Stop Trying & Go Up")
        }
        return ("“\(name)” isn’t responding",
                "The network drive stopped answering. Reconnecting drops the stuck connection and "
                + "mounts the share again.",
                nil)
    }
}

enum MountFailureRules {
    enum Cause: Equatable { case unreachable, credentials, noSuchShare, cancelled, other }

    static func cause(errno rc: Int32) -> Cause {
        switch rc {
        // The server never answered. Off-VPN, this is what you get.
        case ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH, ETIMEDOUT, ECONNREFUSED, ECONNABORTED:
            return .unreachable
        case EAUTH, EACCES, EPERM:                      return .credentials
        case ENOENT, ENODEV:                            return .noSuchShare
        case ECANCELED:                                 return .cancelled
        default:                                        return .other
        }
    }

    /// Headline and detail for the alert. `host` is shown so it's obvious which server is meant.
    static func message(for cause: Cause, host: String) -> (title: String, detail: String)? {
        switch cause {
        case .unreachable:
            return ("Can’t reach “\(host)”",
                    "The server didn’t respond. If this share is only available over the VPN, "
                    + "connect the VPN and try again — your address and password are probably fine.")
        case .credentials:
            return ("“\(host)” refused those credentials",
                    "The server was reachable, so the VPN is working. Check the username and "
                    + "password — use your normal work login, not a personal account.")
        case .noSuchShare:
            return ("“\(host)” has no share by that name",
                    "The server answered but doesn’t recognise the share. Check the part of the "
                    + "address after the server name.")
        case .cancelled:
            return nil          // the user closed the sheet on purpose; saying anything is noise
        case .other:
            return ("Couldn’t connect to “\(host)”",
                    "Check the address, and that you’re on the VPN if this share needs it.")
        }
    }
}

// MARK: - Team drives, pasted as text

/// Setting a coworker up used to mean opening Add Network Drive once per share and typing an
/// address each time. This parses the whole list in one paste, so onboarding is: connect the VPN,
/// paste, done.
enum TeamDrivesRules {
    struct Drive: Equatable { let label: String; let url: String }

    /// Accepted per line, blanks and `#` comments ignored:
    ///   smb://server/share
    ///   G Drive = smb://server/share
    /// Usernames are stripped (see ShareURLRules) so a list shared between people never tells
    /// someone else's Mac to authenticate as the author.
    static func parse(_ text: String) -> [Drive] {
        var out: [Drive] = []
        var seen = Set<String>()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var label: String?
            // "Label = url" — split on the FIRST '=' only, so a '=' inside the URL survives.
            if let eq = line.firstIndex(of: "="), line[line.startIndex..<eq].contains("://") == false {
                let l = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
                let r = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !l.isEmpty, !r.isEmpty { label = l; line = r }
            }
            let url = ShareURLRules.withoutUser(line)
            guard let scheme = url.split(separator: ":").first?.lowercased(),
                  ["smb", "afp", "cifs"].contains(String(scheme)),
                  url.contains("://"),
                  let u = URLComponents(string: url), (u.host?.isEmpty == false)
            else { continue }
            guard seen.insert(url.lowercased()).inserted else { continue }
            out.append(Drive(label: label ?? shareName(from: url), url: url))
        }
        return out
    }

    /// Last path component of the share, which is what people call the drive ("Games", "data").
    static func shareName(from url: String) -> String {
        let afterScheme = url.components(separatedBy: "://").last ?? url
        let parts = afterScheme.split(separator: "/").map(String.init)
        return parts.count > 1 ? parts[parts.count - 1] : (parts.first ?? url)
    }
}

// MARK: - Exporting a converted copy, without eating the original

enum ExportRules {
    /// Formats "Save a Copy As" offers. WebP is encoded by the external `cwebp` because
    /// CGImageDestination on macOS can DECODE WebP but not write it (verified: it is absent from
    /// CGImageDestinationCopyTypeIdentifiers()).
    enum Format: String, CaseIterable {
        case png, webp, jpeg, tiff, heic

        var ext: String { self == .jpeg ? "jpg" : rawValue }
        var menuTitle: String { self == .jpeg ? "JPEG" : rawValue.uppercased() }
        /// Nil means there is no ImageIO encoder and an external tool is required.
        var uti: String? {
            switch self {
            case .png:  return "public.png"
            case .jpeg: return "public.jpeg"
            case .tiff: return "public.tiff"
            case .heic: return "public.heic"
            case .webp: return nil
            }
        }
        var isLossy: Bool { self == .jpeg || self == .heic || self == .webp }
        /// JPEG is the only one here that cannot carry alpha at all.
        var dropsAlpha: Bool { self == .jpeg }
    }

    /// Two paths pointing at the same file. Compared case-insensitively and in canonical
    /// composed form, because macOS filesystems are usually case-insensitive and APFS/HFS hand
    /// back decomposed unicode — "Ü" typed in a save panel is not the same bytes as the "Ü" in
    /// a directory listing, and a naive == would call them different and happily overwrite.
    static func isSameFile(_ a: String, _ b: String) -> Bool {
        a.precomposedStringWithCanonicalMapping.lowercased()
            == b.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Default name for the copy. Never the source's own name: exporting a PNG as a PNG used to
    /// pre-fill the original's exact filename, so one Return overwrote the original.
    /// `taken` reports whether a candidate already exists in the destination folder.
    static func suggestedName(sourceName: String, format: Format, taken: (String) -> Bool) -> String {
        let base = (sourceName as NSString).deletingPathExtension
        let first = "\(base).\(format.ext)"
        // A different extension is already distinct from the source, so only guard the collision.
        if !taken(first), !isSameFile(first, sourceName) { return first }
        var i = 2
        while true {
            let candidate = "\(base) \(i).\(format.ext)"
            if !taken(candidate), !isSameFile(candidate, sourceName) { return candidate }
            i += 1
            if i > 999 { return "\(base) copy.\(format.ext)" }   // pathological folder; still safe
        }
    }
}

// MARK: - Adobe generative credits

/// Navigator can spend Adobe generative credits (Firefly Generative Upscale is a *standard*
/// feature at 1 credit each). On an enterprise plan without premium access that allowance is
/// **25 a month** — measured, not assumed: the account page read "0/25 credits left, next reset
/// August 30, 2026". Three exploratory calls is over a tenth of a month, which is how this app
/// once drained a user's entire allowance without asking.
///
/// So: count every generative call Navigator issues, and never issue one without saying what it
/// costs and what has already been spent.
enum AdobeCreditRules {
    /// What Adobe charges for the things Navigator can trigger. Firefly Generative Upscale is
    /// absent from Adobe's premium table and from its "does not use credits" list, which makes it
    /// a standard feature — "1 credit per generation".
    static let fireflyUpscaleCost = 1

    /// The line shown before spending. Navigator knows what IT has spent exactly; it does not
    /// know Adobe's live balance and must never imply otherwise.
    static func confirmation(count: Int, cost: Int, spentThisCycle: Int,
                             allowance: Int) -> (title: String, detail: String) {
        let credits = count * cost
        let unit = credits == 1 ? "credit" : "credits"
        let title = count == 1
            ? "Upscaling this image uses \(credits) Adobe \(unit)."
            : "Upscaling \(count) images uses \(credits) Adobe \(unit)."
        var lines: [String] = []
        if spentThisCycle > 0 {
            lines.append("Navigator has spent \(spentThisCycle) this cycle" +
                         (allowance > 0 ? " of your \(allowance)." : "."))
            if allowance > 0, spentThisCycle + credits > allowance {
                lines.append("That would take you past your allowance.")
            }
        } else if allowance > 0 {
            lines.append("Your monthly allowance is \(allowance).")
        }
        lines.append("Navigator only counts its own spending, so check Adobe for the real balance.")
        return (title, lines.joined(separator: " "))
    }
}

// MARK: - Layerize batches

enum LayerizeBatchRules {
    /// How many layerize calls run at once.
    ///
    /// Each call takes 50–180 s, so a serial batch of ten is 8–30 minutes. fal.ai does not
    /// document a per-key concurrency limit, so this is deliberately conservative: three is a
    /// 3x speed-up while staying well clear of anything that looks like hammering, and a 429
    /// would cost a paid generation to discover. Raise it only with evidence.
    static let maxConcurrent = 3

    /// Output folder names for a batch, with collisions broken.
    ///
    /// The folder is derived from the file's base name, so `key.png` and `key.jpg` in the SAME
    /// directory both want `key_Layers`. Serially that silently mixed two images' layers into one
    /// folder; in parallel it is a race — two threads creating the same directory and writing
    /// files whose names can collide. Both get a distinct folder instead.
    ///
    /// `exists` reports whether a candidate is already taken on disk, so a re-run beside an
    /// unrelated folder of the same name doesn't clobber it. Input order is preserved.
    static func dedupedOutputDirs(_ proposed: [String], exists: (String) -> Bool = { _ in false }) -> [String] {
        var used = Set<String>()
        var out: [String] = []
        for p in proposed {
            if !used.contains(p), !exists(p) {
                used.insert(p); out.append(p); continue
            }
            // "…_Layers" -> "…_Layers 2", " 3", … Matches the Keep Both convention elsewhere.
            var i = 2
            var candidate = "\(p) \(i)"
            while used.contains(candidate) || exists(candidate) {
                i += 1
                candidate = "\(p) \(i)"
            }
            used.insert(candidate); out.append(candidate)
        }
        return out
    }

    /// Progress text for a parallel run. "3 of 10" is a lie when three are in flight at once.
    static func progressLabel(done: Int, running: Int, total: Int, current: String?) -> String {
        if total == 1 {
            return "Layerizing \(current ?? "image") — this takes a minute or two"
        }
        var s = "Layerizing \(done) of \(total) done"
        if running > 0 { s += ", \(running) running" }
        return s
    }
}

// MARK: - What a Layerize failure actually means

enum LayerizeErrorRules {
    /// Turn fal's 422 body into an honest explanation.
    ///
    /// The old text asserted one cause for every 422: "it rejects a tier that overshoots the input,
    /// and also anything below its ~1K output floor". A real batch disproved that. Five images,
    /// byte-for-byte comparable — all 632×791, all `auto_1K`, all 712–741 KB — and three produced
    /// 5, 9 and 11 layers while two were refused. Same size, same tier, same everything
    /// structural. The tier was never the problem, and saying so sent the user looking in the
    /// wrong place.
    ///
    /// fal says which it is, in the body. When it reports that the image "could not be processed
    /// for layer decomposition", that is the model declining THAT PICTURE — not a parameter fault
    /// — and it is worth saying plainly, because the fix is to retry or use a different image, not
    /// to fiddle with settings.
    /// fal's OWN message, extracted from the error body.
    ///
    /// Classifying on the whole body is a trap: fal echoes the request back inside `"input"`, so
    /// `"enable_safety_checker":true` puts the word "safety" in every single error — which made
    /// worthRetrying() treat every refusal as a safety rejection and skip the retry entirely.
    /// Only the `msg` field carries fal's verdict, so only that is classified.
    static func falMessage(in body: String) -> String {
        guard let r = body.range(of: #""msg"\s*:\s*"(([^"\\]|\\.)*)""#, options: .regularExpression) else {
            // No msg field — fall back to the body with the echoed request removed, so the same
            // trap can't reappear through a different key.
            if let inputAt = body.range(of: #""input"\s*:"#, options: .regularExpression) {
                return String(body[body.startIndex..<inputAt.lowerBound])
            }
            return body
        }
        return String(body[r])
    }

    static func explain422(body: String, tier: String) -> String {
        let b = falMessage(in: body).lowercased()
        if b.contains("could not be processed for layer decomposition") {
            return " — the Layerize model couldn’t decompose this particular image. "
                 + "Nothing is wrong with its size or format: images identical in size and tier "
                 + "succeed alongside it. Retrying sometimes works; otherwise the picture itself "
                 + "is one the model won’t split."
        }
        if b.contains("image_size") || b.contains("resolution") || b.contains("too small") || b.contains("too large") {
            return " — Layerize refused the \(tier) tier for this input. It rejects a tier that "
                 + "overshoots the image, and anything below its ~1K output floor."
        }
        if b.contains("safety") || b.contains("nsfw") || b.contains("flagged") {
            return " — fal's safety checker flagged this image, which is a content decision on "
                 + "their side rather than anything about the file."
        }
        return " — Layerize rejected the request. fal's own message follows."
    }

    /// The next resolution tier up, for escalating a stubborn refusal.
    ///
    /// Repeating an identical request catches a TRANSIENT refusal — SF2_Pearl was declined once and
    /// then succeeded unchanged. It cannot help a DETERMINISTIC one, so a second retry asks for a
    /// different output size instead, which changes what the model is being asked to do. Returns
    /// nil at the top tier, where there is nothing left to escalate to.
    static func nextTierUp(_ tier: String) -> String? {
        switch tier {
        case "auto_1K":   return "auto_1.5K"
        case "auto_1.5K": return "auto_2K"
        default:          return nil
        }
    }

    /// Is this failure worth one automatic retry?
    ///
    /// A model that declines a picture may well accept it on a second pass — the refusal is not a
    /// parameter error, so the same request can legitimately produce a different answer. A tier or
    /// safety rejection will not change, and retrying those only spends money.
    static func worthRetrying(body: String) -> Bool {
        let b = falMessage(in: body).lowercased()
        if b.contains("safety") || b.contains("nsfw") || b.contains("flagged") { return false }
        if b.contains("image_size") || b.contains("too small") || b.contains("too large") { return false }
        return b.contains("could not be processed for layer decomposition")
    }
}

// MARK: - Rebuilding a layered document from a _Layers folder

/// The arithmetic for putting Layerize's output back together as a real layered document.
///
/// Verified by reconstructing SF4_Blue from nothing but `_layers.json`: 86% of pixels within
/// 8/255 of the original and a mean difference of 6.6/255, the residual being resampling noise.
///
/// THE TRAP: a layer's PNG is NOT the size of its bounding box. Each element is rendered at its
/// own resolution — measured factors of 1.00x, 1.73x, 2.73x and 2.21x within a single image — which
/// is what fal means by "preserving each element's aspect ratio". A plugin that drops each PNG at
/// (left, top) at native size puts everything 2-3x too big and overlapping. The bounding box is
/// both the POSITION and the TARGET SIZE.
enum LayerAssemblyRules {
    /// Percentage to scale a layer by so it fills its bounding box. Photoshop's
    /// ArtLayer.resize takes percentages, not pixels.
    static func scalePercent(pngSide: Int, boxSide: Int) -> Double {
        guard pngSide > 0, boxSide > 0 else { return 100 }
        return Double(boxSide) / Double(pngSide) * 100
    }

    /// Width and height scale separately only if the render's aspect drifted from the box's.
    /// Reported so a caller can notice, because a big divergence means the bbox and the render
    /// disagree and the result will look stretched.
    static func aspectDrift(pngW: Int, pngH: Int, boxW: Int, boxH: Int) -> Double {
        guard pngW > 0, pngH > 0, boxW > 0, boxH > 0 else { return 0 }
        let a = Double(pngW) / Double(pngH), b = Double(boxW) / Double(boxH)
        return abs(a - b) / max(a, b)
    }

    /// Measured drift on real output was under 1%; anything past this is worth flagging rather
    /// than silently stretching a layer.
    static let maxTolerableDrift = 0.05

    /// Is a bounding box usable — inside the canvas and not degenerate?
    static func boxIsSane(_ box: [Int], canvasW: Int, canvasH: Int) -> Bool {
        guard box.count == 4 else { return false }
        let (l, t, r, b) = (box[0], box[1], box[2], box[3])
        return r > l && b > t && l >= 0 && t >= 0 && r <= canvasW && b <= canvasH
    }

    /// Name for the rebuilt document, beside the _Layers folder it came from.
    /// "Foo_Layers" -> "Foo_assembled.psd", so it never collides with the source image.
    static func assembledName(fromLayersFolder folder: String) -> String {
        var stem = folder
        if stem.hasSuffix("_Layers") { stem = String(stem.dropLast("_Layers".count)) }
        // A deduped folder ("Foo_Layers 2") keeps its distinguishing suffix.
        stem = stem.trimmingCharacters(in: .whitespaces)
        return stem.isEmpty ? "assembled.psd" : "\(stem)_assembled.psd"
    }

    /// True when the script produced a PSD but some layers didn't make it in. The rebuild succeeded,
    /// so it must not be reported as a failure — but staying silent would hand back a document that
    /// is quietly incomplete, which is how the old zero-byte-download bug went unnoticed for a whole
    /// batch. The script spells MISSING/FAILED in its OK line precisely so this can spot it.
    static func isPartial(_ message: String) -> Bool {
        message.contains("MISSING ") || message.contains("FAILED ")
    }
}

/// Naming the elements for Layerize, with a vision model's help.
///
/// fal's `prompt` decides WHAT comes back, but writing a good one means looking at the image and
/// listing its parts — which is exactly what the restyle path already asks Gemini to do. Measured on
/// a character: an empty prompt returned 4 blobs, the same image with a 16-element list returned 16
/// named parts at 0.64% uncovered, and the analysis cost $0.0007 — a rounding error next to the
/// 2-3 cents of the layerize call itself.
/// Ordering for version-manager directory names like "v26.5.0".
///
/// Exists because sorting those names as strings puts "v9.0.0" above "v26.5.0", so a machine with
/// both installed would be handed a years-old node. The same mistake was shipped in the Photoshop
/// script, where it surfaced as "Node.js isn't installed" on a machine running node 26.
enum NodeVersion {
    static func parts(_ name: String) -> [Int] {
        let trimmed = name.hasPrefix("v") || name.hasPrefix("V")
            ? String(name.dropFirst()) : name
        let fields = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        return (0..<3).map { i in
            i < fields.count ? (Int(fields[i].prefix(while: \.isNumber)) ?? 0) : 0
        }
    }

    /// True when `a` sorts before `b` in a newest-first list.
    static func isDescending(_ a: String, _ b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<3 where x[i] != y[i] { return x[i] > y[i] }
        // Equal numerically: fall back to the name so the sort stays deterministic.
        return a > b
    }
}

enum LayerizeElementRules {
    /// fal returns "the base image followed by up to 16 separated layers", so 16 is a hard ceiling.
    /// A longer list is not an error — the tail is simply never returned — so it is trimmed here and
    /// the caller is told what was dropped rather than left wondering where the hat went.
    static let maxElements = 16

    /// Asks for three granularities in one call, because the useful level depends on the image and
    /// on the job: a slot UI is already well served by the model's own "major elements", while a
    /// character for animation needs left and right split apart.
    ///
    /// The FIRST version of this prompt just asked for elements "ordered back to front (background
    /// first)" and produced lists that were half scenery — a slot mockup came back as "sky and sun,
    /// mountains and forests, lake and shore, boat hull and floor" plus the UI, spending four of ten
    /// slots on a background that layerize returns intact anyway. The prompt now states the budget
    /// and the fact that silence keeps something merged, which is the whole trick: naming nothing is
    /// how you keep the background whole. Measured on the same image, medium went from 10 elements
    /// (4 wasted) to 8 with none wasted, and `fine` fell from 25 to 15 — under the ceiling without
    /// truncating anything.
    /// Ask for JOBS, not sizes.
    ///
    /// Two earlier versions of this failed in instructive ways. The first ordered elements "back to
    /// front (background first)" and spent four of ten slots on sky, mountains, lake and boat hull —
    /// scenery that layerize hands back in the base for free. The second fixed that but kept fixed
    /// COUNTS ("coarse 3-6, medium 8-14, fine up to 16"), so an image with three genuinely useful
    /// pieces got padded to reach the number: a fish symbol came back with "pectoral fin" at the
    /// medium tier, which nobody wanted. The counts were the bug — a granularity slider is the wrong
    /// abstraction because usefulness is not a quantity, it is a purpose.
    ///
    /// So the model now proposes named JOBS suited to what it actually sees. The same fish symbol
    /// offers "structure" (frame / bass / splash — matching how these symbols are split by hand) and
    /// separately "animate" (jaw, fins, body). The pectoral fin is not junk, it was simply filed
    /// under the wrong job. A plain frame offers one element and says so instead of inventing five.
    static let systemPrompt = """
        You plan how to split a flat 2D image into layers for a game-art pipeline.

        HOW THE TOOL WORKS, and why it constrains you:
        - It returns a BASE image plus AT MOST 16 named elements.
        - Anything you do NOT name stays merged in the base, and the base is kept as the bottom
          layer. So the leftover background is ALWAYS returned — you never need to name it just to
          keep it.
        - Name a background ONLY when it is a distinct designed plate someone would reuse or replace
          on its own (a symbol's backdrop, a parallax band), NOT when it is ambient scenery sitting
          behind UI.

        Propose 1-4 DIFFERENT ways to split THIS image, each aimed at a real job someone would do:
         - structure: the reusable compositional pieces (backdrop / frame / subject / UI chrome)
         - extract:   lift the interactive or foreground items off a scene, leaving the scene whole
         - animate:   split ONE subject into moving parts (limbs, jaw, fins, held objects)
         - parallax:  split a background plate into depth bands
         - inventory: one layer per repeated item in a sheet or grid
        Only propose options that make sense for what you actually see. ONE option is a perfectly
        good answer.

        PICK ONE LEVEL PER THING inside any single option. Never list a container and its own parts
        together — "ornate frame with corner gems" and "top left corner gem" cannot both be layers,
        because the gems are inside the frame. The same goes for a subject: either the whole dragon
        as one layer, or its head, jaw, claw and tail as several, never both.

        RULES:
        - NEVER pad a list to reach a number. Return only elements that genuinely earn their own
          layer. Three good elements beat eight with filler. Do not invent sub-parts nobody asked
          for.
        - Order elements MOST VALUABLE FIRST; the list is truncated at 16.
        - If a job would need more than 16 elements, still give the best 16 and set "warning".

        Return STRICT JSON only, no prose, no markdown fence:
        {
          "kind": "<what this image is, short>",
          "options": [
            {"label": "<3-5 words>", "job": "structure|extract|animate|parallax|inventory",
             "why": "<one short line>", "elements": ["..."], "warning": "<optional>"}
          ]
        }
        Order options best-first for this image.
        """

    struct Option: Equatable {
        var label: String = ""
        var job: String = ""
        var why: String = ""
        var elements: [String] = []
        var warning: String = ""

        /// What the popup shows.
        ///
        /// Counts the BASE. Naming N elements yields N+1 layers, because everything unnamed comes
        /// back merged as the bottom layer — verified in a real run, where a manifest for two named
        /// elements contained z0 (no bounding box) plus the two. Reporting "2 layers" for that made
        /// it look like the background had been missed, when the background was layer one.
        var layerCount: Int { elements.count + 1 }
        var menuTitle: String {
            "\(label.isEmpty ? job : label)  (\(layerCount) layers)"
        }
    }

    struct Plan: Equatable {
        var kind: String = ""
        var options: [Option] = []
    }

    /// A gateway hiccup, not a real refusal — worth retrying rather than reporting.
    ///
    /// Observed in the wild: the vision endpoint answered `AI service HTTP 502: {"error":"Vertex
    /// 502: <!DOCTYPE html>…` mid-session and the dialog gave up on the first try, having spent the
    /// wait and produced nothing.
    static func isTransient(_ error: String) -> Bool {
        let e = error.lowercased()
        for code in ["http 502", "http 503", "http 504", "http 429"] where e.contains(code) { return true }
        for phrase in ["timed out", "timeout", "connection was lost", "network connection",
                       "bad gateway", "temporarily unavailable"] where e.contains(phrase) { return true }
        return false
    }

    /// Something a person can read. The service wraps upstream failures in JSON that contains a whole
    /// HTML error page, which floods the one line of status the dialog has.
    static func friendlyError(_ error: String) -> String {
        if isTransient(error) {
            return "the AI service is busy — try Analyze again in a moment"
        }
        // Cut at the first sign of markup, then cap: nobody needs a stack of HTML in a status line.
        var s = error
        if let r = s.range(of: "<!DOCTYPE") ?? s.range(of: "<html") {
            s = String(s[s.startIndex..<r.lowerBound])
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " {}\"\\:,"))
        return s.count > 140 ? String(s.prefix(140)) + "…" : s
    }

    /// Parse the model's reply. Tolerates a ```json fence and surrounding prose, because "STRICT
    /// JSON only" is an instruction, not a guarantee.
    static func parse(_ reply: String) -> Plan? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              start < end else { return nil }
        let json = String(reply[start...end])
        guard let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        func str(_ o: [String: Any], _ k: String) -> String {
            (o[k] as? String ?? "").trimmingCharacters(in: .whitespaces)
        }
        let options: [Option] = (obj["options"] as? [[String: Any]] ?? []).compactMap { o in
            let els = (o["elements"] as? [Any] ?? []).compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !els.isEmpty else { return nil }      // an option that separates nothing is noise
            return Option(label: str(o, "label"), job: str(o, "job"), why: str(o, "why"),
                          elements: els, warning: str(o, "warning"))
        }
        guard !options.isEmpty else { return nil }
        return Plan(kind: str(obj, "kind"), options: options)
    }

    // There is deliberately NO automatic "do everything at once" option here.
    //
    // Merging the proposals in code produced incoherent requests: a dragon symbol came back asking
    // for "Outer gold square frame with corner green gems" AND "Top left corner green gem" as
    // separate layers, plus "Golden dragon head and body" alongside "Lower jaw" and "Body and tail
    // coil". A container and its own parts cannot both be layers, and code cannot tell that gems sit
    // inside a frame — only the model knows that, and substring matching catches just the trivial
    // cases ("bass fish" inside "bass fish body").
    //
    // Asking the MODEL to return a combined option did not work either. It was tried twice, the
    // second time as a required schema field with an explicit container-versus-parts rule, and both
    // times it returned the jobs as alternatives anyway — for a symbol whose two jobs need eight of
    // sixteen slots.
    //
    // So combining is left to the person, who can see the list and edit it. The dialog appends one
    // proposal's elements to another on request, and they resolve the overlap by deleting a line.

    /// Recover the element names from an instruction this class produced, so a second proposal can
    /// be appended to a first. Anything the person typed freehand that isn't in that shape is
    /// treated as one item, which keeps their words rather than discarding them.
    static func elements(inInstruction text: String) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        let marker = "individual layers:"
        let body = t.range(of: marker).map { String(t[$0.upperBound...]) } ?? t
        return body.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Turn a list of element names into the instruction sent as `prompt`.
    ///
    /// "background" is dropped: it is the base image, which layerize returns anyway and which
    /// Navigator discards for a transparent input. Asking for it wastes one of the 16 slots.
    static func instruction(for names: [String]) -> (text: String, dropped: [String]) {
        let usable = names
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased() != "background" }
        let kept = Array(usable.prefix(maxElements))
        let dropped = Array(usable.dropFirst(maxElements))
        guard !kept.isEmpty else { return ("", dropped) }
        return ("Separate these elements out from the image as individual layers: "
                + kept.joined(separator: ", "), dropped)
    }
}

/// Completeness checking for a layerize result.
///
/// fal's API reference states there is no guarantee of coverage, and measurement bears that out: two
/// runs of frame.png with the IDENTICAL prompt left 1.144% and 7.253% of the artwork with no layer
/// covering it, the worse one losing an entire frame rail. A decomposition therefore cannot be
/// trusted, it has to be measured — and measuring is free, local and deterministic, which is more
/// than can be said for anything prompt-based. A generic "separate everything, leave nothing out"
/// prompt was tried and produced no measurable improvement (1.378% vs 1.144%), so it isn't used;
/// what did work was feeding the measured gap back as a coordinate hint.
enum LayerCoverageRules {
    /// Only meaningful when the base was DISCARDED.
    ///
    /// With the base kept, fal's base is a real inpainted background holding everything it didn't
    /// separate, so the composite has no holes and nothing is truly lost — bluebird's boat deck
    /// measured 93% within 32/255 in the very region it was twice claimed to be missing from. It is
    /// only when the base is dropped (a transparent input, whose base is a blank plate) that an
    /// unseparated element actually disappears. That is the one case worth spending a repair call on.
    static func applies(keptBase: Bool) -> Bool { !keptBase }

    /// Repair only when the decomposition is UNAMBIGUOUSLY broken.
    ///
    /// The uncovered fraction turns out to be a weak predictor of whether a retry will help. Measured
    /// on frame.png: a 1.91% run repaired to 1.07% (helped) while a 1.06% run repaired to 1.06%
    /// (gained nothing and cost 139 seconds). Those two are adjacent with opposite outcomes, so a
    /// threshold tuned to sit between them would be fitting a mechanism to four noisy points — the
    /// same error that produced the invented tier ladder. What IS clear is the 7.64% run, which lost
    /// a whole frame rail and repaired to 1.64%, a 4.7x gain.
    ///
    /// So the bar is set where the evidence is unambiguous. Everything below it is reported and left
    /// alone: a 2-minute call is too expensive to spend on a coin flip, and coverage appears in the
    /// log either way so a borderline result can be re-run deliberately.
    static let repairThreshold = 0.05

    static func needsRepair(uncoveredFraction: Double) -> Bool {
        uncoveredFraction > repairThreshold
    }

    /// Two targeted retries at most. Measured on frame.png, each one paid for itself:
    /// 7.64% -> 1.91% -> 1.07% uncovered, at roughly two cents a call, and the second attempt is what
    /// finally filled in the top frame rail. A third was not measured, so it is not taken — and the
    /// strict-improvement guard means the only thing an unlucky roll costs is the call.
    static let maxRepairAttempts = 2

    /// fal's `prompt` accepts `<bbox>left top right bottom</bbox>` in NORMALIZED coordinates. Its own
    /// manifest reports normalized boxes in per-mille (0-1000), so per-mille is the convention used
    /// here — and this exact form recovered a top frame rail that two unprompted runs both lost.
    /// Returns nil for a degenerate box, so a bad measurement can never spend a call.
    /// `userText` is threaded through deliberately: a repair is a whole fresh decomposition, so
    /// dropping the user's element instruction here would hand back a repaired set that no longer
    /// separates what they asked for — a worse result that scores better on coverage.
    static func repairPrompt(gap: [Int], canvasW: Int, canvasH: Int, userText: String? = nil) -> String? {
        guard gap.count == 4, canvasW > 0, canvasH > 0 else { return nil }
        let l = max(0, min(1000, gap[0] * 1000 / canvasW))
        let t = max(0, min(1000, gap[1] * 1000 / canvasH))
        let r = max(0, min(1000, gap[2] * 1000 / canvasW))
        let b = max(0, min(1000, gap[3] * 1000 / canvasH))
        guard r > l, b > t else { return nil }
        return LayerizeRules.composePrompt(userText) + "\n"
             + "The region <bbox>\(l) \(t) \(r) \(b)</bbox> was left out of the previous "
             + "decomposition — return the element occupying it as its own separate layer."
    }

    /// Which attempt to keep. STRICTLY better only: a repair that covers no better must not replace
    /// the original, or a worse roll of the dice gets shipped in exchange for the extra call. The
    /// same prompt measured 1.144% then 7.253%, so this is not hypothetical.
    static func repairIsBetter(original: Double, repaired: Double) -> Bool {
        repaired < original
    }

    /// Did the repair keep what was actually asked for?
    ///
    /// Coverage alone is the wrong test. A repair is a whole fresh decomposition, so it can cover
    /// more of the picture while having separated DIFFERENT things — ask for "gold frame, leaping
    /// bass, water splash", get back a tighter-covering set that merged the fish into the background
    /// and split the frame in four. Adopting that on coverage would silently throw away the request
    /// and look like an improvement in the log.
    ///
    /// Matching is deliberately loose: fal renames freely ("leaping bass" comes back as "Jumping
    /// largemouth bass"), so a requested name counts as kept when any returned name shares a
    /// distinctive word with it. Short words are ignored because "the", "and", "left" match anything.
    static func repairKeptRequestedElements(requested: [String], returned: [String]) -> Bool {
        let wanted = requested
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased() != "background" }
        guard !wanted.isEmpty else { return true }      // nothing specific was asked for

        func keywords(_ s: String) -> Set<String> {
            Set(s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 4 })
        }
        let returnedWords = returned.reduce(into: Set<String>()) { $0.formUnion(keywords($1)) }
        var kept = 0
        for w in wanted {
            let k = keywords(w)
            // A request with no distinctive word can't be checked; don't punish the repair for it.
            if k.isEmpty || !k.isDisjoint(with: returnedWords) { kept += 1 }
        }
        // Losing more than a third of what was asked for is a different result, not a better one.
        // Integer arithmetic on purpose: two-of-three is 0.6666… and would fail a `>= 0.67` test.
        return kept * 3 >= wanted.count * 2
    }

    /// One line for the log, so a run's completeness is on the record rather than inferred later.
    static func summary(uncoveredFraction: Double) -> String {
        String(format: "coverage %.2f%% uncovered", uncoveredFraction * 100)
    }

    /// A layer ready to be placed: its normalized per-mille box and its decoded pixels.
    struct Placement {
        let normalized: [Int]
        let image: CGImage
        init(normalized: [Int], image: CGImage) {
            self.normalized = normalized
            self.image = image
        }
    }

    /// Long-edge ceiling for the measurement raster, purely a memory bound: two RGBA contexts plus
    /// two masks at fal's maximum 6000x6000 input would be about 360 MB, and three images layerize
    /// concurrently. Below this there is NO resampling at all, which is the point — measuring at
    /// 700px reported 1.06% where the truth was 1.21%, and a check that UNDER-states gaps is biased
    /// in the one direction that matters, since it can skip a repair it should have made.
    static let measureLongEdgeCap = 2500

    /// Fraction of the SOURCE's opaque pixels that no layer covers, plus the bounding box of the
    /// largest connected gap cluster in source-pixel coordinates. Returns nil when the question
    /// doesn't apply — no layers, or a source with no opaque pixels to be missing from.
    ///
    /// Layers are placed by their NORMALIZED boxes against the source's own dimensions, so this never
    /// needs to know what canvas size fal chose. Verified equivalent to what the assembly script
    /// actually builds from `absolute` boxes: 1.21% measured on the real PSD versus 1.21% here.
    static func measure(source: CGImage, layers: [Placement]) -> (fraction: Double, gap: [Int])? {
        guard !layers.isEmpty, source.width > 0, source.height > 0 else { return nil }
        let longEdge = max(source.width, source.height)
        let scale = longEdge > measureLongEdgeCap ? Double(measureLongEdgeCap) / Double(longEdge) : 1.0
        let w = max(1, Int((Double(source.width) * scale).rounded()))
        let h = max(1, Int((Double(source.height) * scale).rounded()))

        func canvas() -> CGContext? {
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let comp = canvas(), let srcCtx = canvas() else { return nil }

        for l in layers {
            guard l.normalized.count == 4 else { continue }
            let x0 = Double(l.normalized[0]) / 1000 * Double(w)
            let y0 = Double(l.normalized[1]) / 1000 * Double(h)
            let x1 = Double(l.normalized[2]) / 1000 * Double(w)
            let y1 = Double(l.normalized[3]) / 1000 * Double(h)
            guard x1 > x0, y1 > y0 else { continue }
            // CoreGraphics' origin is bottom-left; fal's boxes are top-left.
            comp.draw(l.image, in: CGRect(x: x0, y: Double(h) - y1, width: x1 - x0, height: y1 - y0))
        }
        srcCtx.draw(source, in: CGRect(x: 0, y: 0, width: Double(w), height: Double(h)))

        guard let cRaw = comp.data, let sRaw = srcCtx.data else { return nil }
        let c = cRaw.assumingMemoryBound(to: UInt8.self)
        let s = sRaw.assumingMemoryBound(to: UInt8.self)
        var mask = [Bool](repeating: false, count: w * h)
        var gapCount = 0, srcCount = 0
        for p in 0..<(w * h) {
            let i = p * 4 + 3
            guard s[i] > 128 else { continue }       // only where the ORIGINAL has real content
            srcCount += 1
            guard c[i] < 32 else { continue }
            mask[p] = true
            gapCount += 1
        }
        guard srcCount > 0 else { return nil }
        let fraction = Double(gapCount) / Double(srcCount)
        guard gapCount > 0 else { return (0, [0, 0, 0, 0]) }

        // The box handed back is the LARGEST CONNECTED CLUSTER, not the extent of every gap pixel.
        // Measured on a real residual: one box around all 61,153 stray pixels spanned 98.3% of the
        // canvas — "the element occupying the whole image is missing", which is no hint at all. The
        // largest cluster of that same residual was 1.0% of the canvas and held 40% of the pixels.
        // Scattered specks are antialiasing seams; a genuinely missing element is one big blob.
        var seen = [Bool](repeating: false, count: w * h)
        var best = (size: 0, minX: 0, minY: 0, maxX: 0, maxY: 0)
        var queue: [Int] = []
        for start in 0..<(w * h) where mask[start] && !seen[start] {
            seen[start] = true
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            var size = 0, minX = w, minY = h, maxX = 0, maxY = 0
            var head = 0
            while head < queue.count {
                let p = queue[head]; head += 1
                let x = p % w, y = p / w
                size += 1
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
                // 4-connectivity keeps a solid element together while letting a 1px diagonal seam
                // fall apart into the noise it is.
                if x > 0, mask[p - 1], !seen[p - 1] { seen[p - 1] = true; queue.append(p - 1) }
                if x < w - 1, mask[p + 1], !seen[p + 1] { seen[p + 1] = true; queue.append(p + 1) }
                if y > 0, mask[p - w], !seen[p - w] { seen[p - w] = true; queue.append(p - w) }
                if y < h - 1, mask[p + w], !seen[p + w] { seen[p + w] = true; queue.append(p + w) }
            }
            if size > best.size { best = (size, minX, minY, maxX, maxY) }
        }
        guard best.size > 0 else { return (fraction, [0, 0, 0, 0]) }
        return (fraction, [Int(Double(best.minX) / scale), Int(Double(best.minY) / scale),
                           Int(Double(best.maxX + 1) / scale), Int(Double(best.maxY + 1) / scale)])
    }

    /// fal returns `bounding_box.normalized` as numbers that may decode as Int or Double.
    static func normalizedBox(_ bb: [String: Any]?) -> [Int]? {
        guard let arr = bb?["normalized"] as? [Any], arr.count == 4 else { return nil }
        let v = arr.compactMap { ($0 as? NSNumber)?.intValue }
        return v.count == 4 ? v : nil
    }
}
