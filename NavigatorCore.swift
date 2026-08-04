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
/// `realpath(3)` and NOT `standardizedFileURL.resolvingSymlinksInPath()`, which is the
/// obvious answer and the wrong one: Foundation deliberately maps `/private/tmp` back to
/// `/tmp` — but only for the root itself, so `/tmp/Photos` and `/private/tmp/Photos`
/// survive that pair of calls as two different strings, which is precisely the bug.
/// realpath resolves every component, and also eats `..` and the trailing slash.
///
/// A path realpath can't resolve — a deleted folder, an unmounted share, a stored key
/// from a volume that isn't here — falls back to Foundation's normalisation rather than
/// failing. A record filed under a folder that no longer exists is only ever going to be
/// evicted anyway; refusing to produce a key for it would just move the crash here.
///
/// Lowercased LAST, and deliberately: macOS volumes are case-insensitive by default, so
/// `Photos` and `photos` are one folder and two records for them is the mistake people
/// actually hit. On a case-SENSITIVE volume two genuinely different folders then share
/// one record — a view arriving wrong, never a file touched, which is much the cheaper
/// of the two mistakes.
func folderKey(_ path: String) -> String {
    guard !path.isEmpty else { return "" }
    if let real = realpath(path, nil) {
        defer { free(real) }
        return String(cString: real).lowercased()
    }
    return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
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
