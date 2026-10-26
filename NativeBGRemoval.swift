// Native BG Removal — background removal for art generated on a flat key colour, with no Adobe app.
//
// Its own file because it is built TWICE: as the optimized helper inside Navigator.app
// (Contents/MacOS/NavigatorNativeBG, built by rebuild.sh / quickbuild.sh with -O -D NATIVE_BG_TOOL), and into the
// SwiftPM test target. The app itself is compiled without optimization (compile.sh), where this code measured 63 s
// for one 2048 px image against 1 s optimized; so the app runs the helper rather than linking this file.
//
import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import Vision

// Background removal for art generated on a flat key colour, without After Effects or Photoshop.
// Built and measured on 2026-10-12 against both, on 30 shipped symbols composited Navigator-style
// (true alpha known; clean and with real-world backing noise) and 19 real Navigator AI outputs:
//
//                       anti-aliased rim error   colour error   visible key-colour px (19 real)
//   After Effects        17.3                      1.23           250,541
//   Photoshop            -                         -               44,109
//   Native               14.3  (17.3 noisy)        0.94 (2.75)         25
//
// Two parts, because colour alone cannot do the whole job:
// 1. A known-backing matte. Every pixel is C = a*F + (1-a)*B: B is the backing (a smooth local map, so
//    gradients and vignettes are fine), F the art colour next to the pixel, a its share. Precise rims.
// 2. AI generators paint glows that fade from the art into the key colour, haze beside it and key colour
//    between feathers. A keyer keeps all of that as a tinted fringe. Apple Vision's subject mask (on
//    device, free) says what is subject, but it alone also deletes real art (a painting's background
//    inside its frame, a neon frame's stroke) and its edge is soft. So Vision only picks REGIONS to
//    delete, and only ones that hold a lot of key colour and fade softly into the backing; the key
//    matte keeps every rim. Then the rim's colour is unmixed and de-spilled.
// Solid symbols only: soft FX (sparkles, rays) want Chroma Key's Soft FX setting.
enum NativeBGRemoval {

    /// Remove the backing of `source` and write "<name>_rmbg.png" beside it, like Remove BG and Chroma Key.
    /// Validated before the write, so a failure leaves an earlier output alone.
    /// `soft`: Soft FX (glows, sparkles, rays) keep every transitional alpha (softMatte); otherwise a solid symbol (matte).
    /// `original`: the picture with see-through parts this one was redrawn from (`matched`); `soft` is then ignored.
    static func export(source: URL, soft: Bool = false, original: URL? = nil) throws -> URL {
        func failure(_ message: String) -> NSError {
            NSError(domain: "NativeBGRemoval", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(reader, 0, nil) else { throw failure("Could not read \(source.lastPathComponent)") }
        let w = image.width, h = image.height
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let rgba = pixels(image, width: w, height: h, space: space) else { throw failure("Could not decode \(source.lastPathComponent)") }
        // A cut-out has no backing left: its transparent black corners would be keyed as the backing.
        guard [0, w - 1, (h - 1) * w, h * w - 1].allSatisfy({ rgba[$0 * 4 + 3] == 255 }) else {
            throw failure("\(source.lastPathComponent) already has a transparent background")
        }
        guard var out = soft && original == nil ? softFX(rgba: rgba, width: w, height: h) : matte(rgba: rgba, width: w, height: h, subject: subjectMask(image)) else {
            throw failure("\(source.lastPathComponent) is not on a flat key colour. Native BG Removal is for art generated on a key colour; Remove BG (Photoshop) handles other images.")
        }
        if let original {
            guard let r = CGImageSourceCreateWithURL(original as CFURL, nil), let o = CGImageSourceCreateImageAtIndex(r, 0, nil) else {
                throw failure("Could not read \(original.lastPathComponent)")
            }
            // The right placement measured 8-11 on real redraws, the other 85-95, and a different picture's original 55.
            let tries = placements(original: (o.width, o.height), picture: (w, h)).compactMap { b in
                pixels(o, width: b.x1 - b.x0, height: b.y1 - b.y0, space: space).map { (box: b, fitted: $0, miss: miss(rgba: rgba, width: w, height: h, fitted: $0, box: b)) }
            }
            guard let best = tries.min(by: { $0.miss < $1.miss }), best.miss <= 24 else {
                throw failure("\(source.lastPathComponent) does not look like \(original.lastPathComponent) laid on its backing: choose the picture it was made from, or use Solid subject or Soft FX.")
            }
            var fitted = best.fitted
            for i in stride(from: 0, to: fitted.count, by: 4) where fitted[i + 3] > 0 {     // straight colour, as the rule reads it
                for k in 0..<3 { fitted[i + k] = UInt8(min(255, Int(fitted[i + k]) * 255 / Int(fitted[i + 3]))) }
            }
            out = matched(rgba: rgba, width: w, height: h, solid: out, original: fitted, box: best.box)
        }
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                               decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let encoder = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw failure("Could not encode PNG") }
        CGImageDestinationAddImage(encoder, cg, nil)
        guard CGImageDestinationFinalize(encoder) else { throw failure("Could not finish PNG") }
        let url = source.deletingLastPathComponent().appendingPathComponent(source.deletingPathExtension().lastPathComponent + "_rmbg.png")
        try (data as Data).write(to: url, options: .atomic)
        return url
    }

    /// `image` drawn at `width` x `height`, premultiplied RGBA8 (straight for an opaque image).
    private static func pixels(_ image: CGImage, width w: Int, height h: Int, space: CGColorSpace) -> [UInt8]? {
        guard w > 0, h > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? rgba : nil
    }

    typealias Box = (x0: Int, y0: Int, x1: Int, y1: Int)

    /// Solid keying for the art, Soft FX where the original was partly see-through: for a picture an AI model redrew
    /// from an original with see-through parts (a localized panel, a glow round lettering). The solid keyer keeps the
    /// backing in a soft edge (a green line round a gold panel's see-through border); Soft FX alone turns art in the
    /// backing's colours see-through. Measured 2026-10-26 in the H5G Localization Tool (7.21.19, the same keyers in
    /// Python): 99th-percentile error 0.8-0.9 against 3-6 on exact tests, and 22 of 24 real redraws better, none worse.
    /// Soft FX goes where the original is partly see-through (alpha 5-250), in a patch at least 3 px thick, in a colour
    /// at least 192 from the backing in some channel (a green glow on green stays solid), grown by 1 px.
    /// `solid` is `matte`'s result; `original` straight RGBA8 at the size of `box`, where it sits on this picture.
    static func matched(rgba: [UInt8], width w: Int, height h: Int, solid: [UInt8], original: [UInt8], box: Box) -> [UInt8] {
        let g = Grid(w: w, h: h), B = cornerBacking(rgba: rgba, width: w, height: h) * 255, bw = box.x1 - box.x0
        var zone = [Bool](repeating: false, count: g.n)
        for y in max(0, box.y0)..<min(h, box.y1) { for x in max(0, box.x0)..<min(w, box.x1) {
            let o = ((y - box.y0) * bw + x - box.x0) * 4
            guard original[o + 3] > 5, original[o + 3] < 250 else { continue }
            zone[y * w + x] = simd_abs(SIMD3(Float(original[o]), Float(original[o + 1]), Float(original[o + 2])) - B).max() >= 192
        } }
        zone = square(square(square(zone, g, grow: false), g, grow: true), g, grow: true)
        guard zone.contains(true) else { return solid }
        var out = solid
        let soft = softFX(rgba: rgba, width: w, height: h)
        for i in 0..<g.n where zone[i] { for k in 0..<4 { out[i * 4 + k] = soft[i * 4 + k] } }
        return out
    }

    /// Where an original of `o` pixels may sit on a picture of `p` pixels redrawn from it: centred in the smallest box of
    /// the picture's ratio that holds it, padded x1.0 (Restyle's auto-prep and crop-back, the Localization Tool) or x1.2
    /// (Fill Background, FX Alpha Upscale).
    static func placements(original o: (w: Int, h: Int), picture p: (w: Int, h: Int)) -> [Box] {
        let rt = Double(p.w) / Double(p.h)
        let tight = Double(o.w) / Double(o.h) > rt ? (Double(o.w), Double(o.w) / rt) : (Double(o.h) * rt, Double(o.h))
        return [1.0, 1.2].map { pad in
            let cw = tight.0 * pad, ch = tight.1 * pad, fx = Double(p.w) / cw, fy = Double(p.h) / ch
            let r = [(cw - Double(o.w)) / 2 * fx, (ch - Double(o.h)) / 2 * fy, (cw + Double(o.w)) / 2 * fx, (ch + Double(o.h)) / 2 * fy].map { Int($0.rounded()) }
            return (max(0, r[0]), max(0, r[1]), min(p.w, r[2]), min(p.h, r[3]))
        }
    }

    /// How far the picture is from the original laid on the backing at `box`: the mean over the box of the largest
    /// channel difference, 0-255. The model redraws only the lettering, so the right place is close everywhere else.
    /// `fitted` is the original drawn premultiplied at the box's size.
    static func miss(rgba: [UInt8], width w: Int, height h: Int, fitted: [UInt8], box: Box) -> Double {
        let B = cornerBacking(rgba: rgba, width: w, height: h) * 255, bw = box.x1 - box.x0
        var sum = 0.0
        for y in box.y0..<box.y1 { for x in box.x0..<box.x1 {
            let f = ((y - box.y0) * bw + x - box.x0) * 4, i = (y * w + x) * 4, a = Float(fitted[f + 3]) / 255
            let laid = SIMD3(Float(fitted[f]), Float(fitted[f + 1]), Float(fitted[f + 2])) + B * (1 - a)
            sum += Double(simd_abs(laid - SIMD3(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2]))).max())
        } }
        return sum / Double(max(1, bw * (box.y1 - box.y0)))
    }

    /// Apple Vision's subject mask at the image's own size, 0...1; nil when Vision finds no subject.
    static func subjectMask(_ image: CGImage) -> [Float]? {
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([request])) != nil, let obs = request.results?.first,
              let buf = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) else { return nil }
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), row = CVPixelBufferGetBytesPerRow(buf)
        guard w == image.width, h == image.height, let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        var out = [Float](repeating: 0, count: w * h)
        switch CVPixelBufferGetPixelFormatType(buf) {
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<h { let p = (base + y * row).assumingMemoryBound(to: Float.self); for x in 0..<w { out[y * w + x] = p[x] } }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<h { let p = (base + y * row).assumingMemoryBound(to: UInt8.self); for x in 0..<w { out[y * w + x] = Float(p[x]) / 255 } }
        default: return nil
        }
        return out
    }

    /// Straight RGBA8 in (the source, alpha ignored), straight RGBA8 out, same size; nil when the image is not on a
    /// flat key colour (less than half its border is backing). `subject` is `subjectMask`; nil runs the key matte alone.
    static func matte(rgba: [UInt8], width w: Int, height h: Int, subject: [Float]?) -> [UInt8]? {
        let g = Grid(w: w, h: h)
        let c = par(g, SIMD3<Float>.zero) { SIMD3<Float>(Float(rgba[$0 * 4]), Float(rgba[$0 * 4 + 1]), Float(rgba[$0 * 4 + 2])) / 255 }
        guard let key = keyMatte(c, g) else { return nil }
        var a = key.0, col = key.1
        let keyB = key.2
        let field = a.map { $0 == 0 }                                         // backing as the matte sees it
        let V = subject ?? [Float](repeating: 1, count: g.n)
        let side = Float(min(w, h))

        // ---- glows, haze and tinted pockets Vision calls background
        var B = par(g, SIMD3<Float>.zero) { field[$0] ? c[$0] : keyB[$0] }        // the key matte's backing map
        let share = par(g, Float(0)) { backingShare(c[$0], B[$0]) }
        let canHold = share.map { $0 >= 0.1 }
        let R = par(g, false) { a[$0] > 0 && V[$0] < 0.5 && share[$0] >= 0.3 }
        let fromField = edt(field, g).dist
        let wideSoft = par(g, false) { a[$0] > 0 && a[$0] < 0.9 && fromField[$0] >= 3 }
        let nearSoft = dilate(wideSoft, 2, g)
        let core = flood((0..<g.n).map { R[$0] && nearSoft[$0] }, within: R, g)
        var unmixed = [Bool](repeating: false, count: g.n)
        if core.contains(true) {
            for i in 0..<g.n where core[i] { a[i] = 0 }
            B = localMean(c, a.map { $0 == 0 }, g, max(4, side / 256))       // backing incl. the haze just removed
            // fringe: what is left of a glow next to the cut, if it is a clean mix of the backing and the art
            let reach = dilate(core, 8, g)
            let near = (0..<g.n).filter { reach[$0] && a[$0] > 0 && V[$0] < 0.85 && canHold[$0] }
            if !near.isEmpty {
                let normal = inwardNormals(a, g)
                let fit = inwardFit(c, B, a.map { $0 >= 0.99 }, near, normal, 8, g)
                var mix = [Bool](repeating: false, count: g.n)
                for (j, i) in near.enumerated() where fit.r[j] < 0.08 && fit.t[j] < 0.85 { mix[i] = true }
                let touching = dilate(core, 1, g)
                let fringe = flood((0..<g.n).map { mix[$0] && touching[$0] }, within: mix, g)
                for (j, i) in near.enumerated() where fringe[i] {
                    let t = fit.t[j]
                    a[i] = min(a[i], t)
                    col[i] = a[i] < 0.3 ? fit.F[j] : clamp01((c[i] - (1 - t) * B[i]) / max(t, 1e-3))
                    unmixed[i] = true
                }
            }
            // anti-alias the cut: the keep/remove decisions leave a staircase; smooth alpha 2 px either side
            let kept = a.map { $0 > 0 }
            let keptArt = (0..<g.n).map { kept[$0] && !core[$0] }
            let cutA = dilate(core, 2, g), cutB = dilate(keptArt, 2, g)
            let cut = (0..<g.n).map { cutA[$0] && cutB[$0] && !field[$0] }
            let sm = blur(a, g, 0.8)
            let nearestArt = edt(keptArt, g).idx
            for i in 0..<g.n where cut[i] {
                if a[i] == 0 && sm[i] > 0.02, nearestArt[i] >= 0 { col[i] = col[Int(nearestArt[i])] }
                a[i] = sm[i]
            }
        }
        for i in 0..<g.n where a[i] < 0.02 { a[i] = 0 }

        // ---- rim colour: the outer 2 px unmixed against the best-fitting art colour 1-4 px in, alpha kept
        // (a tinted rim may be opaque art with spill); pixels no art colour explains are left to the de-spill
        let inside = edt(a.map { $0 == 0 }, g).dist                          // distance to the nearest clear pixel
        let rim = (0..<g.n).filter { a[$0] > 0 && inside[$0] <= 2 && !unmixed[$0] }
        if !rim.isEmpty {
            let fit = inwardFit(c, B, a.map { $0 >= 0.99 }, rim, inwardNormals(a, g), 4, g)
            for (j, i) in rim.enumerated() where fit.r[j] < 0.2 && fit.t[j] < 0.98 {
                let t = fit.t[j]
                col[i] = min(t, a[i]) < 0.3 ? fit.F[j] : clamp01((c[i] - (1 - t) * B[i]) / max(t, 1e-3))
                unmixed[i] = true
            }
        }
        // ---- sideways-safe de-spill of the whole rim against the art colour 4 px in. Unmixed pixels too: a tint
        // 2+ px deep is in the colour they were unmixed against (measured: no change on the 60 test symbols)
        let deep = erode(a.map { $0 >= 1 }, 4, g)
        if deep.contains(true) {
            let nearestDeep = edt(deep, g).idx
            for i in 0..<g.n where a[i] > 0 && !deep[i] && nearestDeep[i] >= 0 {
                col[i] = despill(col[i], c[Int(nearestDeep[i])], B[i], 2.0)
            }
        }
        // ---- safety net: a rim pixel still key-coloured is dropped when faint, else takes the nearest art colour
        let keyish = (0..<g.n).map { a[$0] > 0 && inside[$0] <= 2 && simd_length(col[$0] - B[$0]) < 0.35 }
        if keyish.contains(true) {
            let clean = (0..<g.n).map { a[$0] >= 0.99 && !keyish[$0] }
            let nearestClean = edt(clean, g).idx
            for i in 0..<g.n where keyish[i] {
                if a[i] < 0.3 { a[i] = 0 } else if nearestClean[i] >= 0 { col[i] = col[Int(nearestClean[i])] }
            }
        }
        // ---- a colourless backing (black, white, grey) has art of its own colour: black outlines on black, white
        // highlights on white, which no colour test can tell from it. There, what Vision is confident is subject stays
        // (measured on 30 shipped symbols: symbols with holes 27 -> 8 on black, 29 -> 14 on white, none gaining backing).
        let b = keyB[0], chroma = max(b.x, b.y, b.z) - min(b.x, b.y, b.z)
        if chroma < 80 / 255, let V = subject {
            for i in 0..<g.n {
                let keep = min(1, max(0, (V[i] - 0.75) / 0.2))
                if keep > a[i] { a[i] = keep; col[i] = c[i] }
            }
        }
        removeSpecks(&a, g)

        var out = [UInt8](repeating: 0, count: g.n * 4)
        for i in 0..<g.n where a[i] > 0 {
            let p = clamp01(col[i]) * 255 + 0.5
            out[i * 4] = UInt8(p.x); out[i * 4 + 1] = UInt8(p.y); out[i * 4 + 2] = UInt8(p.z)
            out[i * 4 + 3] = UInt8(min(255, a[i] * 255 + 0.5))
        }
        return out
    }

    // MARK: key matte

    /// Alpha, colour and the smooth backing map, from the backing field (key colour reaching the border, plus
    /// enclosed pockets).
    private static func keyMatte(_ c: [SIMD3<Float>], _ g: Grid) -> ([Float], [SIMD3<Float>], [SIMD3<Float>])? {
        let w = g.w, h = g.h, n = g.n
        // backing: median of the four 8x8 corner means
        func cornerMean(_ x0: Int, _ y0: Int) -> SIMD3<Float> {
            var s = SIMD3<Float>(repeating: 0), k: Float = 0
            for y in y0..<min(h, y0 + 8) { for x in x0..<min(w, x0 + 8) { s += c[y * w + x]; k += 1 } }
            return s / max(k, 1)
        }
        let corners = [cornerMean(0, 0), cornerMean(max(0, w - 8), 0), cornerMean(0, max(0, h - 8)), cornerMean(max(0, w - 8), max(0, h - 8))]
        var B0 = SIMD3<Float>(repeating: 0)
        for k in 0..<3 { let v = corners.map { $0[k] }.sorted(); B0[k] = (v[1] + v[2]) / 2 }
        let d0 = par(g, Float(0)) { simd_length(c[$0] - B0) }
        // field threshold from the border's own noise
        var border: [Float] = []
        for y in 0..<h { for x in 0..<w where y < 6 || y >= h - 6 || x < 6 || x >= w - 6 { if d0[y * w + x] < 0.25 { border.append(d0[y * w + x]) } } }
        let tField = border.isEmpty ? 0.05 : min(0.22, max(0.05, percentile(border, 99) * 1.6))
        let cand = d0.map { $0 < tField }
        var seeds = [Bool](repeating: false, count: n)
        for x in 0..<w { seeds[x] = true; seeds[(h - 1) * w + x] = true }
        for y in 0..<h { seeds[y * w] = true; seeds[y * w + w - 1] = true }
        var field = flood(zip(seeds, cand).map { $0 && $1 }, within: cand, g)
        let edge = (0..<n).filter { seeds[$0] }
        guard edge.filter({ field[$0] }).count * 2 >= edge.count else { return nil }
        // enclosed pockets of backing colour (gaps through the art): big enough and as close as the field itself
        let (label, count) = components((0..<n).map { cand[$0] && !field[$0] }, g)
        if count > 0 {
            var size = [Int](repeating: 0, count: count + 1), sum = [Float](repeating: 0, count: count + 1)
            for i in 0..<n where label[i] > 0 { size[Int(label[i])] += 1; sum[Int(label[i])] += d0[i] }
            for i in 0..<n where label[i] > 0 {
                let l = Int(label[i])
                if size[l] >= 40 && sum[l] / Float(size[l]) < tField * 0.6 { field[i] = true }
            }
        }
        // smooth local backing map
        let s = max(4, Float(min(w, h)) / 64)
        let B = localMean(c, field, g, s, inside: false, fallback: B0)
        let d = par(g, Float(0)) { simd_length(c[$0] - B[$0]) }
        let fieldD = (0..<n).filter { field[$0] }.map { d[$0] }
        let near = min(0.2, max(0.03, fieldD.isEmpty ? 0.06 : percentile(fieldD, 99) * 1.3))
        let besideField = dilate(field, 1, g)
        var interior = (0..<n).map { d[$0] > 0.40 && !besideField[$0] }
        if !interior.contains(true) { interior = d.map { $0 > 0.40 } }
        var a = [Float](repeating: 0, count: n)
        var col = c
        guard interior.contains(true) else { return (a, col, B) }
        let nearestInterior = edt(interior, g).idx
        a = par(g, Float(0)) { i in
            let F = c[Int(nearestInterior[i])], FB = F - B[i], L2 = simd_length_squared(FB), L = L2.squareRoot()
            var v = min(1, max(0, simd_dot(c[i] - B[i], FB) / max(L2, 1e-6)))
            if L < 0.15 { v = min(1, max(0, d[i] / max(L, 1e-6))) }
            if d[i] < near || field[i] { v = 0 }
            if interior[i] { v = 1 }
            let snap = near / max(L, 1e-6)
            return v < snap ? 0 : (v > 1 - snap * 0.5 ? 1 : v)
        }
        col = par(g, SIMD3<Float>.zero) { interior[$0] ? c[$0] : c[Int(nearestInterior[$0])] }
        removeSpecks(&a, g)
        return (a, col, B)
    }

    // MARK: soft FX

    /// Soft FX on ANY backing colour (black included, which a chroma keyer cannot key: Keylight measures distance from
    /// the screen's dominant channel, and black has none). Every pixel is C = a*F + (1-a)*B, and for light (glows,
    /// sparkles, rays) the right reading is the most transparent one that is still a valid colour: the smallest a with
    /// F = (C - (1-a)*B)/a inside [0,1]. On black that is the compositors' Unmult (a = brightest channel); on magenta,
    /// green or grey it is the same idea against that colour. On the measured FX set (glows, rings, sparkles, bubbles,
    /// fire, a real ring) the error over white, grey and blue was under 1.5/255 clean on black, green, blue and grey,
    /// 3-10/255 with real-world backing noise. Two limits are physics, not the keyer: white light on a white backing
    /// leaves no trace, and an FX colour sharing a full channel with the backing (gold on magenta: red) is ambiguous.
    /// Straight RGBA8 in and out; nil when the image is not on a flat backing.
    static func softMatte(rgba: [UInt8], width w: Int, height h: Int) -> [UInt8]? {
        let g = Grid(w: w, h: h)
        let c = par(g, SIMD3<Float>.zero) { SIMD3<Float>(Float(rgba[$0 * 4]), Float(rgba[$0 * 4 + 1]), Float(rgba[$0 * 4 + 2])) / 255 }
        func cornerMean(_ x0: Int, _ y0: Int) -> SIMD3<Float> {
            var s = SIMD3<Float>(repeating: 0), k: Float = 0
            for y in y0..<min(h, y0 + 8) { for x in x0..<min(w, x0 + 8) { s += c[y * w + x]; k += 1 } }
            return s / max(k, 1)
        }
        let corners = [cornerMean(0, 0), cornerMean(max(0, w - 8), 0), cornerMean(0, max(0, h - 8)), cornerMean(max(0, w - 8), max(0, h - 8))]
        var B0 = SIMD3<Float>(repeating: 0)
        for k in 0..<3 { let v = corners.map { $0[k] }.sorted(); B0[k] = (v[1] + v[2]) / 2 }
        let band = par(g, false) { i in let y = i / w, x = i % w; return y < 6 || y >= h - 6 || x < 6 || x >= w - 6 }
        let ring = par(g, false) { i in let y = i / w, x = i % w; return y == 0 || y == h - 1 || x == 0 || x == w - 1 }
        let side = Float(min(w, h)), s = max(4, side / 64)
        // pass 1: the backing as the border's own noise sees it (a faint glow is the asset, so a tight floor of 3/255)
        let d0 = par(g, Float(0)) { simd_length(c[$0] - B0) }
        let border = (0..<g.n).filter { band[$0] && d0[$0] < 0.25 }.map { d0[$0] }
        // a border too varied to be a flat backing (FX running off the frame) is not one: UnMult takes those
        guard !border.isEmpty, percentile(border, 99) * 1.6 < 0.22 else { return nil }
        let t = min(0.22, max(3 / 255, percentile(border, 99) * 1.6))
        var field = flood(par(g, false) { ring[$0] && d0[$0] < t }, within: d0.map { $0 < t }, g)
        guard (0..<g.n).filter({ ring[$0] }).filter({ field[$0] }).count * 2 >= 2 * (w + h) - 4 else { return nil }
        var B = localMean(c, field, g, s, inside: false, fallback: B0)
        // pass 2: within 4 sigma of that map, so a faint glow near the edge is never taken for backing. Sigma is p99/2.6,
        // not a median: a backing at 0 or 255 clips half its noise away, and a median then reads a third of it.
        var sigma = SIMD3<Float>(repeating: 1 / 255)
        let edgeOf = { (f: [Bool]) in (0..<g.n).filter { band[$0] && f[$0] } }
        var edge = edgeOf(field)
        if !edge.isEmpty {
            for k in 0..<3 { sigma[k] = max(percentile(edge.map { abs(c[$0][k] - B[$0][k]) }, 99) / 2.6, 0.5 / 255) }
        }
        let thr = simd_max(3 * sigma, SIMD3(repeating: 1.5 / 255))
        let near = par(g, false) { i in let d = simd_abs(c[i] - B[i]); return d.x < thr.x && d.y < thr.y && d.z < thr.z }
        let f2 = flood(par(g, false) { ring[$0] && near[$0] }, within: near, g)
        if (0..<g.n).filter({ ring[$0] && f2[$0] }).count * 2 >= 2 * (w + h) - 4 {
            field = f2
            // winsorised: a faint glow just inside the field must not lift the backing map. A lifted map made pure
            // black read as 'darker than the backing', i.e. opaque black (a bubble burst's last ring came out black).
            let B1 = B
            let clipped = par(g, SIMD3<Float>.zero) { simd_clamp(c[$0], B1[$0] - 2 * sigma, B1[$0] + 2 * sigma) }
            B = localMean(clipped, field, g, s, inside: false, fallback: B0)
            edge = edgeOf(field)
        }
        // alpha: colour to alpha, noise-aware; then values within the backing's own noise gated smoothly to 0
        var a = par(g, Float(0)) { colourToAlpha(c[$0], B[$0], sigma) }
        let gate = edge.isEmpty ? 1 / 255 : max(percentile(edge.map { a[$0] }, 99), 1 / 255)
        a = par(g, Float(0)) { field[$0] ? 0 : a[$0] * min(1, max(0, (a[$0] - gate) / gate)) }
        var out = [UInt8](repeating: 0, count: g.n * 4)
        for i in 0..<g.n where a[i] > 0 {
            let F = clamp01((c[i] - (1 - a[i]) * B[i]) / max(a[i], 1e-4)) * 255 + 0.5
            out[i * 4] = UInt8(F.x); out[i * 4 + 1] = UInt8(F.y); out[i * 4 + 2] = UInt8(F.z)
            out[i * 4 + 3] = UInt8(min(255, a[i] * 255 + 0.5))
        }
        return out
    }

    /// Soft FX: UnMult on a black or white backing, or when no flat backing border is showing (FX running off the frame,
    /// sprite sheets); softMatte's colour-to-alpha on a coloured backing.
    static func softFX(rgba: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        let B0 = cornerBacking(rgba: rgba, width: w, height: h)
        let neutral = B0.max() - B0.min() < 0.06
        if neutral && (B0.max() < 0.15 || B0.min() > 0.85) { return unmult(rgba: rgba, width: w, height: h) }
        return softMatte(rgba: rgba, width: w, height: h) ?? unmult(rgba: rgba, width: w, height: h)
    }

    /// The backing's colour, 0...1: per channel, the middle two of the four 8 px corners' means.
    static func cornerBacking(rgba: [UInt8], width w: Int, height h: Int) -> SIMD3<Float> {
        var corners: [SIMD3<Float>] = []
        for (x0, y0) in [(0, 0), (max(0, w - 8), 0), (0, max(0, h - 8)), (max(0, w - 8), max(0, h - 8))] {
            var s = SIMD3<Float>(repeating: 0), k: Float = 0
            for y in y0..<min(h, y0 + 8) { for x in x0..<min(w, x0 + 8) {
                let i = (y * w + x) * 4; s += SIMD3(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2])) / 255; k += 1 } }
            corners.append(s / max(k, 1))
        }
        var B0 = SIMD3<Float>(repeating: 0)
        for k in 0..<3 { let v = corners.map { $0[k] }.sorted(); B0[k] = (v[1] + v[2]) / 2 }
        return B0
    }

    /// UnMult, measured instead of tuned. After Effects' Unmult (and Red Giant's before it) makes alpha the brightest
    /// channel and divides it back out, with a manual Black Level threshold per pixel: AI 'black' is lifted and noisy, so
    /// at 0 it leaves a haze over the frame (31-51% of it, measured) and any level high enough to clear the haze clips the
    /// faint glow by as much. Here:
    /// - the black level is the backing's own colour (the densest dark colour; 0 when the darkest colour is clearly FX),
    ///   and a plane through the backing pixels follows a vignette;
    /// - light FX on black only ever ADD light, so everything darker than the backing is pure noise: its spread, on a
    ///   1.5 px average of the brightness above the backing, is the noise floor, wherever the FX are;
    /// - faint regions above 3 noise-sigma are kept when connected to a region above 6 sigma, so a glow's tail survives
    ///   and isolated noise does not; colour of faint glow is smoothed from its neighbours.
    /// Against After Effects' Black Level at its best setting per image (picked with the truth in hand): lifted black
    /// error 1.5 vs 2.3/255 and haze 0.4% vs 15%; webp AI output 2.0 vs 2.0, haze 0.2% vs 1.2%. White backing: the
    /// same on the inverted image (dark FX on white).
    static func unmult(rgba: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        let g = Grid(w: w, h: h)
        let c0 = par(g, SIMD3<Float>.zero) { SIMD3<Float>(Float(rgba[$0 * 4]), Float(rgba[$0 * 4 + 1]), Float(rgba[$0 * 4 + 2])) / 255 }
        var whiteEdge = 0, edgeCount = 0
        for i in 0..<g.n {
            let y = i / w, x = i % w
            guard y < 3 || y >= h - 3 || x < 3 || x >= w - 3 else { continue }
            edgeCount += 1
            if c0[i].min() > 0.75 && c0[i].max() - c0[i].min() < 0.08 { whiteEdge += 1 }
        }
        let white = whiteEdge * 2 > edgeCount
        let c = white ? c0.map { SIMD3<Float>(repeating: 1) - $0 } : c0
        // black level and noise
        let m = c.map { $0.max() }
        let p20 = percentile(m, 20)
        let dark = m.map { $0 <= p20 }
        let darkM = (0..<g.n).filter { dark[$0] }.map { m[$0] }
        let top = max(darkM.max() ?? 0, 1e-3)
        var hist = [Int](repeating: 0, count: 256)
        for v in darkM { hist[min(255, Int(v / top * 256))] += 1 }
        let bin = hist.indices.max { hist[$0] < hist[$1] } ?? 0
        let peak = (Float(bin) + 0.5) / 256 * top
        var sigma = SIMD3<Float>(repeating: 1 / 255)
        let sel = (0..<g.n).filter { dark[$0] && abs(m[$0] - peak) < 0.05 }
        if !sel.isEmpty {
            for k in 0..<3 {
                var res = [Float](repeating: 0, count: sel.count)
                var v = [Float](repeating: 0, count: 9)
                for (j, i) in sel.enumerated() {          // pixel-to-pixel scatter: distance from its 3x3 median
                    let y = i / w, x = i % w
                    var n = 0
                    for dy in -1...1 { for dx in -1...1 {
                        v[n] = c[min(h - 1, max(0, y + dy)) * w + min(w - 1, max(0, x + dx))][k]; n += 1 } }
                    v.sort()
                    res[j] = abs(c[i][k] - v[4])
                }
                res.sort()
                sigma[k] = max(1.4826 * res[res.count / 2] * 1.25, 0.5 / 255)
            }
        }
        // the darkest fifth only FINDS the backing; its level is the median of ALL pixels near it (the darkest fifth of a
        // noisy black sits a noise-width low, and then the whole backing reads as faintly lit)
        var L = SIMD3<Float>(repeating: 0)
        for centre in [peak, Float.nan] {
            let at = centre.isNaN ? L.max() : centre
            let nearPeak = (0..<g.n).filter { abs(m[$0] - at) < 3 * sigma.max() + 1 / 255 }
            if !nearPeak.isEmpty { for k in 0..<3 { let v = nearPeak.map { c[$0][k] }.sorted(); L[k] = v[v.count / 2] } }
        }
        if L.max() - L.min() > 6 / 255 && L.max() > 12 / 255 { L = .zero }     // the darkest colour is FX, not backing
        L = simd_min(simd_min(L, SIMD3(repeating: L.min() + 3 / 255)), SIMD3(repeating: 24 / 255))
        var B = [SIMD3<Float>](repeating: L, count: g.n)
        var region = [Bool](repeating: false, count: g.n)
        let floor: Float = 0.3 / 255
        for pass in 0..<3 {
            let u = blur(par(g, Float(0)) { i in let d = c[i] - B[i]; return (d.x + d.y + d.z) / 3 }, g, 1.5)
            var neg = u.filter { $0 < 0 }.map { -$0 }
            var su = max(0.12 * (sigma.x + sigma.y + sigma.z) / 3, floor)
            if neg.count > 100 { neg.sort(); su = max(1.4826 * neg[neg.count / 2], floor) }
            let (lab, n) = components(u.map { $0 > 3 * su }, g, eight: true)
            var strong = [Bool](repeating: false, count: n + 1)
            for i in 0..<g.n where u[i] > 6 * su { strong[Int(lab[i])] = true }
            strong[0] = false
            region = dilate(lab.map { strong[Int($0)] }, 2, g)
            if pass < 2 {
                let away = dilate(region, 6, g)
                let bg = (0..<g.n).filter { u[$0] < 3 * su && !away[$0] }
                if bg.count > 1000 {
                    let cap = SIMD3<Float>(repeating: L.min() + 0.06)
                    let plane = fitPlane(c, bg, g)
                    B = par(g, SIMD3<Float>.zero) { i in simd_min(simd_clamp(plane(i), .zero, .one), cap) }
                }
            }
        }
        let a = par(g, Float(0)) { region[$0] ? colourToAlpha(c[$0], B[$0], sigma) : 0 }
        var F = par(g, SIMD3<Float>.zero) { clamp01((c[$0] - (1 - a[$0]) * B[$0]) / max(a[$0], 1e-4)) }
        // faint glow: colour from its neighbourhood, weighted by alpha (dividing a 2/255 pixel by its alpha is noise)
        let den = blur(a, g, 2)
        let num = (0..<3).map { k in blur(par(g, Float(0)) { F[$0][k] * a[$0] }, g, 2) }
        F = par(g, SIMD3<Float>.zero) { i in
            guard den[i] > 1e-6 else { return F[i] }
            let wgt = min(1, a[i] / 0.25)
            return wgt * F[i] + (1 - wgt) * SIMD3(num[0][i], num[1][i], num[2][i]) / den[i]
        }
        var out = [UInt8](repeating: 0, count: g.n * 4)
        for i in 0..<g.n where a[i] > 0 {
            let f = (white ? SIMD3<Float>(repeating: 1) - F[i] : F[i])
            let p = clamp01(f) * 255 + 0.5
            out[i * 4] = UInt8(p.x); out[i * 4 + 1] = UInt8(p.y); out[i * 4 + 2] = UInt8(p.z)
            out[i * 4 + 3] = UInt8(min(255, a[i] * 255 + 0.5))
        }
        return out
    }

    /// Least-squares plane per channel through the listed pixels: follows a vignette or gradient, and under a big glow
    /// extrapolates linearly (a quadratic overshoots there).
    private static func fitPlane(_ c: [SIMD3<Float>], _ pixels: [Int], _ g: Grid) -> (Int) -> SIMD3<Float> {
        let step = max(1, pixels.count / 100_000)
        var s = [Double](repeating: 0, count: 9)                 // sums: 1, y, x, yy, xx, xy
        var r = [[Double]](repeating: [0, 0, 0], count: 3)       // per channel: c, c*y, c*x
        for j in stride(from: 0, to: pixels.count, by: step) {
            let i = pixels[j], y = Double(i / g.w) / Double(g.h) - 0.5, x = Double(i % g.w) / Double(g.w) - 0.5
            s[0] += 1; s[1] += y; s[2] += x; s[3] += y * y; s[4] += x * x; s[5] += x * y
            for k in 0..<3 { let v = Double(c[i][k]); r[k][0] += v; r[k][1] += v * y; r[k][2] += v * x }
        }
        // normal equations [n Sy Sx; Sy Syy Sxy; Sx Sxy Sxx] p = r, solved by Cramer's rule
        let A = [[s[0], s[1], s[2]], [s[1], s[3], s[5]], [s[2], s[5], s[4]]]
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let D = det(A)
        var coef = [[Double]](repeating: [0, 0, 0], count: 3)
        for k in 0..<3 {
            guard abs(D) > 1e-12 else { coef[k] = [r[k][0] / max(s[0], 1), 0, 0]; continue }
            for col in 0..<3 {
                var M = A
                for row in 0..<3 { M[row][col] = r[k][row] }
                coef[k][col] = det(M) / D
            }
        }
        let c0 = SIMD3<Float>(Float(coef[0][0]), Float(coef[1][0]), Float(coef[2][0]))
        let cy = SIMD3<Float>(Float(coef[0][1]), Float(coef[1][1]), Float(coef[2][1]))
        let cx = SIMD3<Float>(Float(coef[0][2]), Float(coef[1][2]), Float(coef[2][2]))
        return { i in c0 + cy * (Float(i / g.w) / Float(g.h) - 0.5) + cx * (Float(i % g.w) / Float(g.w) - 0.5) }
    }

    /// Smallest a with (C - (1-a)B)/a inside [0,1], noise-aware. A channel moving toward a near limit (down from a dark
    /// backing channel, up from a bright one) has little room, so its noise would read as nearly opaque: it must clear
    /// 2.5 sigma first (fully at no room, not at all from a room of 0.25). Toward the far side it counts as it is.
    static func colourToAlpha(_ c: SIMD3<Float>, _ B: SIMD3<Float>, _ sigma: SIMD3<Float>) -> Float {
        let room: Float = 8 / 255, tight: Float = 0.25
        var a: Float = 0
        for k in 0..<3 {
            let upRoom = 1 - B[k], downRoom = B[k]
            let upTol = 2.5 * sigma[k] * min(1, max(0, (tight - upRoom) / tight))
            let downTol = 2.5 * sigma[k] * min(1, max(0, (tight - downRoom) / tight))
            a = max(a, max(c[k] - B[k] - upTol, 0) / max(upRoom, room), max(B[k] - c[k] - downTol, 0) / max(downRoom, room))
        }
        return a
    }

    // MARK: colour helpers

    /// Largest share b of the backing B that (C - b*B)/(1 - b) can hold while staying a valid colour.
    /// `tol` is noise, so a channel at 255 does not pin b to 0. Art far from the key holds ~0, glows 0.4-0.9.
    static func backingShare(_ c: SIMD3<Float>, _ B: SIMD3<Float>, tol: Float = 0.03) -> Float {
        var b: Float = .infinity
        for k in 0..<3 { b = min(b, (1 - c[k] + tol) / (1 - B[k] + tol), (c[k] + tol) / (B[k] + tol)) }
        return min(1, max(0, b))
    }

    /// Remove only the part of (col - ref) that points toward B, when it clearly dominates the sideways part:
    /// spill points at the key colour, a dark outline or a painted edge colour points elsewhere and stays.
    static func despill(_ col: SIMD3<Float>, _ ref: SIMD3<Float>, _ B: SIMD3<Float>, _ ratio: Float) -> SIMD3<Float> {
        let L = simd_length(B - ref)
        guard L > 1e-6 else { return col }
        let u = (B - ref) / L, v = col - ref, k = simd_dot(v, u)
        let side = max(0, simd_length_squared(v) - k * k).squareRoot()
        return k > 0 && k > ratio * side ? col - k * u : col
    }

    /// For each pixel: the art colour 1...depth px inward (along `normal`) that best explains C = t*F + (1-t)*B.
    private static func inwardFit(_ c: [SIMD3<Float>], _ B: [SIMD3<Float>], _ solid: [Bool], _ pixels: [Int],
                                  _ normal: [SIMD2<Float>], _ depth: Int, _ g: Grid) -> (r: [Float], t: [Float], F: [SIMD3<Float>]) {
        var r = [Float](repeating: .infinity, count: pixels.count), t = [Float](repeating: 1, count: pixels.count)
        var F = pixels.map { c[$0] }
        for (j, i) in pixels.enumerated() {
            let y = Float(i / g.w), x = Float(i % g.w), nv = normal[i], C = c[i], Bp = B[i]
            for k in 1...depth {
                let sy = y + Float(k) * nv.y, sx = x + Float(k) * nv.x
                let ry = min(g.h - 1, max(0, Int(sy.rounded()))), rx = min(g.w - 1, max(0, Int(sx.rounded())))
                guard solid[ry * g.w + rx] else { continue }
                let Fk = bilinear(c, sy, sx, g), u = Fk - Bp, L2 = simd_length_squared(u)
                guard L2 > 0.15 * 0.15 else { continue }
                let tk = min(1, max(0, simd_dot(C - Bp, u) / max(L2, 1e-6)))
                let rk = simd_length(C - Bp - tk * u)
                if rk < r[j] { r[j] = rk; t[j] = tk; F[j] = Fk }
            }
        }
        return (r, t, F)
    }

    /// Unit normals pointing into the art: the gradient of the smoothed signed distance to the edge.
    private static func inwardNormals(_ a: [Float], _ g: Grid) -> [SIMD2<Float>] {
        let inArt = edt(a.map { $0 == 0 }, g).dist, outArt = edt(a.map { $0 > 0 }, g).dist
        let sd = blur(par(g, Float(0)) { inArt[$0] - outArt[$0] }, g, 1.0)
        return par(g, SIMD2<Float>.zero) { i in
            let y = i / g.w, x = i % g.w
            let gy = y == 0 ? sd[i + g.w] - sd[i] : y == g.h - 1 ? sd[i] - sd[i - g.w] : (sd[i + g.w] - sd[i - g.w]) / 2
            let gx = x == 0 ? sd[i + 1] - sd[i] : x == g.w - 1 ? sd[i] - sd[i - 1] : (sd[i + 1] - sd[i - 1]) / 2
            let len = max((gx * gx + gy * gy).squareRoot(), 1e-6)
            return SIMD2(gx / len, gy / len)
        }
    }

    private static func bilinear(_ c: [SIMD3<Float>], _ y: Float, _ x: Float, _ g: Grid) -> SIMD3<Float> {
        let y = min(Float(g.h - 1), max(0, y)), x = min(Float(g.w - 1), max(0, x))
        let y0 = Int(y), x0 = Int(x), y1 = min(g.h - 1, y0 + 1), x1 = min(g.w - 1, x0 + 1)
        let fy = y - Float(y0), fx = x - Float(x0)
        let top = c[y0 * g.w + x0] * (1 - fx) + c[y0 * g.w + x1] * fx
        let bottom = c[y1 * g.w + x0] * (1 - fx) + c[y1 * g.w + x1] * fx
        return top * (1 - fy) + bottom * fy
    }

    private static func clamp01(_ v: SIMD3<Float>) -> SIMD3<Float> { simd_clamp(v, .zero, .one) }

    // MARK: image operators (scipy.ndimage semantics where the measurements were made)

    private struct Grid { let w: Int, h: Int; var n: Int { w * h } }

    /// Normalised mean of `c` over `mask` (gaussian `sigma`); inside the mask, c itself. A wide mean is smooth,
    /// so it is taken on a grid `sigma`/4 times coarser and read back bilinearly (one 2048 px map: 0.3 s -> 0.02 s).
    private static func localMean(_ c: [SIMD3<Float>], _ mask: [Bool], _ g: Grid, _ sigma: Float,
                                  inside: Bool = true, fallback: SIMD3<Float>? = nil) -> [SIMD3<Float>] {
        let f = max(1, Int(sigma / 4)), lg = Grid(w: (g.w + f - 1) / f, h: (g.h + f - 1) / f)
        var planes = [[Float]](repeating: [Float](repeating: 0, count: lg.n), count: 4)   // r*m, g*m, b*m, m
        for y in 0..<g.h {
            for x in 0..<g.w where mask[y * g.w + x] {
                let i = y * g.w + x, j = (y / f) * lg.w + x / f
                planes[0][j] += c[i].x; planes[1][j] += c[i].y; planes[2][j] += c[i].z; planes[3][j] += 1
            }
        }
        let cells = Float(f * f)
        planes = planes.map { blur($0.map { $0 / cells }, lg, sigma / Float(f)) }
        let backup = fallback ?? meanColour(c, mask)
        return par(g, SIMD3<Float>.zero) { i in
            if inside && mask[i] { return c[i] }
            // centre of full-res pixel i on the coarse grid
            let y = i / g.w, x = i - y * g.w
            let fy = (Float(y) + 0.5) / Float(f) - 0.5, fx = (Float(x) + 0.5) / Float(f) - 0.5
            let wsum = sample(planes[3], fy, fx, lg)
            guard wsum >= 1e-4 else { return backup }
            return SIMD3(sample(planes[0], fy, fx, lg), sample(planes[1], fy, fx, lg), sample(planes[2], fy, fx, lg)) / wsum
        }
    }

    private static func sample(_ p: [Float], _ y: Float, _ x: Float, _ g: Grid) -> Float {
        let y = min(Float(g.h - 1), max(0, y)), x = min(Float(g.w - 1), max(0, x))
        let y0 = Int(y), x0 = Int(x), y1 = min(g.h - 1, y0 + 1), x1 = min(g.w - 1, x0 + 1)
        let fy = y - Float(y0), fx = x - Float(x0)
        return (p[y0 * g.w + x0] * (1 - fx) + p[y0 * g.w + x1] * fx) * (1 - fy) + (p[y1 * g.w + x0] * (1 - fx) + p[y1 * g.w + x1] * fx) * fy
    }

    /// Element-wise map over the grid, rows in parallel.
    private static func par<T>(_ g: Grid, _ initial: T, _ f: (Int) -> T) -> [T] {
        var out = [T](repeating: initial, count: g.n)
        out.withUnsafeMutableBufferPointer { o in
            DispatchQueue.concurrentPerform(iterations: g.h) { y in
                for i in (y * g.w)..<((y + 1) * g.w) { o[i] = f(i) }
            }
        }
        return out
    }

    private static func meanColour(_ c: [SIMD3<Float>], _ mask: [Bool]) -> SIMD3<Float> {
        var s = SIMD3<Float>(repeating: 0), k: Float = 0
        for i in 0..<c.count where mask[i] { s += c[i]; k += 1 }
        return k > 0 ? s / k : SIMD3(repeating: 0)
    }

    /// gaussian_filter(mode='nearest'): the exact kernel below sigma 3, three box passes above (same result to
    /// within a few thousandths, at a cost that does not grow with sigma).
    private static func blur(_ src: [Float], _ g: Grid, _ sigma: Float) -> [Float] {
        if sigma < 3 {
            let r = Int(4 * sigma + 0.5)
            var k = (-r...r).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
            let s = k.reduce(0, +); k = k.map { $0 / s }
            return convolve(convolve(src, g, k, horizontal: true), g, k, horizontal: false)
        }
        // box sizes for three passes (Kovesi)
        let n: Float = 3, wIdeal = (12 * sigma * sigma / n + 1).squareRoot()
        var wl = Int(wIdeal); if wl % 2 == 0 { wl -= 1 }
        let wu = wl + 2
        let m = Int(((12 * sigma * sigma - n * Float(wl * wl) - 4 * n * Float(wl) - 3 * n) / (-4 * Float(wl) - 4)).rounded())
        var out = src
        for pass in 0..<3 {
            let r = ((pass < m ? wl : wu) - 1) / 2
            out = box(box(out, g, r, horizontal: true), g, r, horizontal: false)
        }
        return out
    }

    private static func convolve(_ src: [Float], _ g: Grid, _ k: [Float], horizontal: Bool) -> [Float] {
        let r = k.count / 2, len = horizontal ? g.w : g.h, lines = horizontal ? g.h : g.w
        let step = horizontal ? 1 : g.w, lineStep = horizontal ? g.w : 1
        var out = [Float](repeating: 0, count: g.n)
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                DispatchQueue.concurrentPerform(iterations: lines) { line in
                    let base = line * lineStep
                    for p in 0..<len {
                        var acc: Float = 0
                        for j in -r...r { acc += k[j + r] * s[base + min(len - 1, max(0, p + j)) * step] }
                        o[base + p * step] = acc
                    }
                }
            }
        }
        return out
    }

    private static func box(_ src: [Float], _ g: Grid, _ r: Int, horizontal: Bool) -> [Float] {
        let len = horizontal ? g.w : g.h, lines = horizontal ? g.h : g.w
        let step = horizontal ? 1 : g.w, lineStep = horizontal ? g.w : 1
        let inv = 1 / Double(2 * r + 1)
        var out = [Float](repeating: 0, count: g.n)
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                DispatchQueue.concurrentPerform(iterations: lines) { line in
                    let base = line * lineStep
                    var acc = 0.0
                    for j in -r...r { acc += Double(s[base + min(len - 1, max(0, j)) * step]) }
                    for p in 0..<len {
                        o[base + p * step] = Float(acc * inv)
                        acc += Double(s[base + min(len - 1, p + r + 1) * step]) - Double(s[base + max(0, p - r) * step])
                    }
                }
            }
        }
        return out
    }

    /// City-block distance to the nearest `set` pixel (binary_dilation/erosion with the cross, iterated). Separable:
    /// along each row, then along each column, both in parallel.
    private static func cityBlock(_ set: [Bool], _ g: Grid, outsideIsSet: Bool) -> [Int32] {
        let w = g.w, h = g.h, far = Int32.max / 4
        var d = [Int32](repeating: far, count: g.n)
        d.withUnsafeMutableBufferPointer { o in
            set.withUnsafeBufferPointer { s in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    let r = y * w
                    var run = outsideIsSet ? Int32(0) : far
                    for x in 0..<w { run = s[r + x] ? 0 : min(far, run + 1); o[r + x] = run }
                    run = outsideIsSet ? 0 : far
                    for x in stride(from: w - 1, through: 0, by: -1) { run = s[r + x] ? 0 : min(far, run + 1); o[r + x] = min(o[r + x], run) }
                }
                DispatchQueue.concurrentPerform(iterations: w) { x in
                    var run = outsideIsSet ? Int32(0) : far
                    for y in 0..<h { let i = y * w + x; run = min(o[i], min(far, run + 1)); o[i] = run }
                    run = outsideIsSet ? 0 : far
                    for y in stride(from: h - 1, through: 0, by: -1) { let i = y * w + x; run = min(o[i], min(far, run + 1)); o[i] = run }
                }
            }
        }
        return d
    }

    private static func dilate(_ m: [Bool], _ k: Int, _ g: Grid) -> [Bool] {
        cityBlock(m, g, outsideIsSet: false).map { $0 <= Int32(k) }
    }

    /// A 3 x 3 square grown (dilation) or shrunk (erosion; the outside counts as set, as OpenCV's).
    private static func square(_ m: [Bool], _ g: Grid, grow: Bool) -> [Bool] {
        par(g, false) { i in
            let x = i % g.w, y = i / g.w
            for yy in max(0, y - 1)...min(g.h - 1, y + 1) { for xx in max(0, x - 1)...min(g.w - 1, x + 1) where m[yy * g.w + xx] == grow { return grow } }
            return !grow
        }
    }

    /// binary_erosion with border_value 0: the image's outside counts as not-set.
    private static func erode(_ m: [Bool], _ k: Int, _ g: Grid) -> [Bool] {
        cityBlock(m.map { !$0 }, g, outsideIsSet: true).map { $0 > Int32(k) }
    }

    /// Exact Euclidean distance to the nearest `feature` pixel and that pixel's index (-1, infinity: none).
    private static func edt(_ feature: [Bool], _ g: Grid) -> (dist: [Float], idx: [Int32]) {
        let w = g.w, h = g.h
        var colD = [Int32](repeating: -1, count: g.n), colY = [Int32](repeating: -1, count: g.n)
        feature.withUnsafeBufferPointer { f in
            colD.withUnsafeMutableBufferPointer { cd in
                colY.withUnsafeMutableBufferPointer { cy in
                    DispatchQueue.concurrentPerform(iterations: w) { x in
                        var last = -1
                        for y in 0..<h {
                            let i = y * w + x
                            if f[i] { last = y }
                            if last >= 0 { cd[i] = Int32(y - last); cy[i] = Int32(last) }
                        }
                        last = -1
                        for y in stride(from: h - 1, through: 0, by: -1) {
                            let i = y * w + x
                            if f[i] { last = y }
                            if last >= 0, cd[i] < 0 || Int32(last - y) < cd[i] { cd[i] = Int32(last - y); cy[i] = Int32(last) }
                        }
                    }
                }
            }
        }
        var dist = [Float](repeating: .infinity, count: g.n), idx = [Int32](repeating: -1, count: g.n)
        colD.withUnsafeBufferPointer { cd in
            colY.withUnsafeBufferPointer { cy in
                dist.withUnsafeMutableBufferPointer { dd in
                    idx.withUnsafeMutableBufferPointer { ii in
                        DispatchQueue.concurrentPerform(iterations: h) { y in
                            // lower envelope of parabolas (Felzenszwalb & Huttenlocher) over this row
                            let row = y * w
                            var v = [Int](repeating: 0, count: w), z = [Double](repeating: 0, count: w + 1)
                            var k = -1
                            for q in 0..<w where cd[row + q] >= 0 {
                                if k < 0 { k = 0; v[0] = q; z[0] = -.infinity; z[1] = .infinity; continue }
                                let fq = Double(cd[row + q]) * Double(cd[row + q]) + Double(q * q)
                                var fk = Double(cd[row + v[k]]) * Double(cd[row + v[k]]) + Double(v[k] * v[k])
                                var s = (fq - fk) / Double(2 * q - 2 * v[k])
                                while s <= z[k] {
                                    k -= 1
                                    fk = Double(cd[row + v[k]]) * Double(cd[row + v[k]]) + Double(v[k] * v[k])
                                    s = (fq - fk) / Double(2 * q - 2 * v[k])
                                }
                                k += 1; v[k] = q; z[k] = s; z[k + 1] = .infinity
                            }
                            guard k >= 0 else { return }
                            k = 0
                            for x in 0..<w {
                                while z[k + 1] < Double(x) { k += 1 }
                                let q = v[k], dx = Double(x - q), dy = Double(cd[row + q])
                                dd[row + x] = Float((dx * dx + dy * dy).squareRoot())
                                ii[row + x] = cy[row + q] * Int32(w) + Int32(q)
                            }
                        }
                    }
                }
            }
        }
        return (dist, idx)
    }

    /// binary_propagation: `seeds` grown through 4-connected `mask` pixels.
    private static func flood(_ seeds: [Bool], within mask: [Bool], _ g: Grid) -> [Bool] {
        var out = seeds, stack: [Int] = []
        for i in 0..<g.n where seeds[i] { stack.append(i) }
        func visit(_ j: Int) { if mask[j] && !out[j] { out[j] = true; stack.append(j) } }
        while let i = stack.popLast() {
            let y = i / g.w, x = i - y * g.w
            if x > 0 { visit(i - 1) }; if x < g.w - 1 { visit(i + 1) }
            if y > 0 { visit(i - g.w) }; if y < g.h - 1 { visit(i + g.w) }
        }
        return out
    }

    /// 4-connected components: labels 1...count (0 = not in mask).
    private static func components(_ mask: [Bool], _ g: Grid, eight: Bool = false) -> ([Int32], Int) {
        var label = [Int32](repeating: 0, count: g.n), count: Int32 = 0, stack: [Int] = []
        for s in 0..<g.n where mask[s] && label[s] == 0 {
            count += 1; label[s] = count; stack.append(s)
            func visit(_ j: Int) { if mask[j] && label[j] == 0 { label[j] = count; stack.append(j) } }
            while let i = stack.popLast() {
                let y = i / g.w, x = i - y * g.w
                if x > 0 { visit(i - 1) }; if x < g.w - 1 { visit(i + 1) }
                if y > 0 { visit(i - g.w) }; if y < g.h - 1 { visit(i + g.w) }
                if eight {
                    if y > 0 && x > 0 { visit(i - g.w - 1) }; if y > 0 && x < g.w - 1 { visit(i - g.w + 1) }
                    if y < g.h - 1 && x > 0 { visit(i + g.w - 1) }; if y < g.h - 1 && x < g.w - 1 { visit(i + g.w + 1) }
                }
            }
        }
        return (label, Int(count))
    }

    /// Visible islands under 12 px are noise, unless they are the only thing there.
    private static func removeSpecks(_ a: inout [Float], _ g: Grid) {
        let (label, count) = components(a.map { $0 > 0 }, g)
        guard count > 1 else { return }
        var size = [Int](repeating: 0, count: count + 1)
        for l in label where l > 0 { size[Int(l)] += 1 }
        for i in 0..<g.n where label[i] > 0 && size[Int(label[i])] < 12 { a[i] = 0 }
    }

    /// numpy.percentile (linear), on a stride sample when there are very many values.
    private static func percentile(_ values: [Float], _ p: Float) -> Float {
        let stride = max(1, values.count / 262_144)
        let v = Swift.stride(from: 0, to: values.count, by: stride).map { values[$0] }.sorted()
        let pos = p / 100 * Float(v.count - 1), lo = Int(pos), hi = min(v.count - 1, lo + 1)
        return v[lo] + (v[hi] - v[lo]) * (pos - Float(lo))
    }
}

#if NATIVE_BG_TOOL
/// The helper: `NavigatorNativeBG [--soft | --match <original>] <image>...` prints each output path; a failure goes to
/// stderr and exits 1.
@main
struct NativeBGRemovalTool {
    static func main() {
        var failed = false
        var args = Array(CommandLine.arguments.dropFirst())
        let soft = args.contains("--soft")
        var original: URL?
        if let m = args.firstIndex(of: "--match"), m + 1 < args.count { original = URL(fileURLWithPath: args[m + 1]); args.removeSubrange(m...(m + 1)) }
        for path in args where path != "--soft" {
            do { print(try NativeBGRemoval.export(source: URL(fileURLWithPath: path), soft: soft, original: original).path) }
            catch { failed = true; FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)) }
        }
        exit(failed ? 1 : 0)
    }
}
#endif
