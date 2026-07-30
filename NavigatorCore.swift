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
