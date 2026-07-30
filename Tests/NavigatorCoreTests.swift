// Regression tests for Navigator's path rules.
//
// Every case here corresponds to a bug that actually happened, or to an edge case
// a naive implementation gets wrong. Run with ./runtests.sh.

import XCTest
@testable import NavigatorCore

final class SelfOrDescendantTests: XCTestCase {

    private func u(_ p: String) -> URL { URL(fileURLWithPath: p) }

    // The bug: copying a folder into its own subfolder made FileManager recurse
    // into the copy it was creating, producing 231 junk directories nested 1000+
    // characters deep before the filesystem refused the path.
    func testRefusesCopyIntoItself() {
        XCTAssertTrue(PathRules.isSelfOrDescendant(u("/tmp/a"), of: u("/tmp/a")))
    }

    func testRefusesCopyIntoOwnSubfolder() {
        XCTAssertTrue(PathRules.isSelfOrDescendant(u("/tmp/a/b"), of: u("/tmp/a")))
        XCTAssertTrue(PathRules.isSelfOrDescendant(u("/tmp/a/b/c/d"), of: u("/tmp/a")))
    }

    // The trap a plain hasPrefix falls into: "/tmp/bc" starts with "/tmp/b" as a
    // string, but it is a SIBLING, not a descendant. Refusing it would break
    // legitimate copies.
    func testAllowsSiblingWithSharedPrefix() {
        XCTAssertFalse(PathRules.isSelfOrDescendant(u("/tmp/bc"), of: u("/tmp/b")))
        XCTAssertFalse(PathRules.isSelfOrDescendant(u("/tmp/a-copy"), of: u("/tmp/a")))
        XCTAssertFalse(PathRules.isSelfOrDescendant(u("/tmp/abc"), of: u("/tmp/ab")))
    }

    // Copying a folder into its PARENT is the ordinary "duplicate" case and must
    // stay allowed — this is what makes "photo (1).jpg" style duplication work.
    func testAllowsCopyIntoParent() {
        XCTAssertFalse(PathRules.isSelfOrDescendant(u("/tmp"), of: u("/tmp/a")))
    }

    func testAllowsUnrelatedDestination() {
        XCTAssertFalse(PathRules.isSelfOrDescendant(u("/tmp/x"), of: u("/tmp/a")))
        XCTAssertFalse(PathRules.isSelfOrDescendant(u("/Users/me/Desktop"), of: u("/tmp/a")))
    }

    func testTrailingSlashIsStillTheSameFolder() {
        XCTAssertTrue(PathRules.isSelfOrDescendant(u("/tmp/a/"), of: u("/tmp/a")))
        XCTAssertTrue(PathRules.isSelfOrDescendant(u("/tmp/a"), of: u("/tmp/a/")))
    }

    // ".." and doubled separators must not sneak past the check.
    func testNormalisesBeforeComparing() {
        XCTAssertTrue(PathRules.isSelfOrDescendant(u("/tmp/a/b/.."), of: u("/tmp/a")))
        XCTAssertTrue(PathRules.isSelfOrDescendant(u("/tmp//a//b"), of: u("/tmp/a")))
    }

    // The caller applies this rule WITHOUT first checking whether the source is a
    // directory, because that check would be a stat per source on the main thread
    // (a round trip each over SMB). That's only safe because a destination
    // directory can never equal, nor live inside, a file's path — so a plain file
    // source must never be flagged. These pin that reasoning down.
    func testFileSourcesAreNeverFlagged() {
        // The ordinary duplicate case: file's parent is the destination.
        XCTAssertFalse(PathRules.isSelfOrDescendant(u("/tmp/a"), of: u("/tmp/a/photo.jpg")))
        // Dropping a file into some unrelated folder.
        XCTAssertFalse(PathRules.isSelfOrDescendant(u("/tmp/dest"), of: u("/tmp/a/photo.jpg")))
        // A destination whose name merely starts with the file's name.
        XCTAssertFalse(PathRules.isSelfOrDescendant(u("/tmp/photo.jpg.backup"), of: u("/tmp/photo.jpg")))
    }
}

final class ShareRelativePathTests: XCTestCase {

    // The bug: a share can return on a different mountpoint ("Games-1" instead of
    // "Games"). Favourites storing the old literal path then pointed at nothing and
    // the drive looked broken while being mounted and healthy. Re-anchoring needs
    // the path BELOW the volume root.
    func testStripsVolumeRoot() {
        XCTAssertEqual(PathRules.shareRelativePath("/Volumes/Games/artSource"), "artSource")
        XCTAssertEqual(PathRules.shareRelativePath("/Volumes/Games-1/artSource"), "artSource")
        XCTAssertEqual(PathRules.shareRelativePath("/Volumes/Games/Tools/sub"), "Tools/sub")
    }

    func testVolumeRootItselfHasNoRelativePart() {
        XCTAssertEqual(PathRules.shareRelativePath("/Volumes/Games"), "")
        XCTAssertEqual(PathRules.shareRelativePath("/Volumes"), "")
    }

    func testNonVolumePathsAreIgnored() {
        XCTAssertEqual(PathRules.shareRelativePath("/Users/me/Documents"), "")
        XCTAssertEqual(PathRules.shareRelativePath("/tmp/a/b"), "")
    }

    // Re-anchoring must survive a round trip: strip the relative part off the old
    // mountpoint, re-attach it to the new one, and get the right path.
    func testRoundTripOntoNewMountpoint() {
        let rel = PathRules.shareRelativePath("/Volumes/Games/artSource")
        XCTAssertEqual(("/Volumes/Games-1" as NSString).appendingPathComponent(rel),
                       "/Volumes/Games-1/artSource")
    }
}

final class DestinationNamingTests: XCTestCase {

    private let dir = URL(fileURLWithPath: "/tmp/dest")
    /// Pretend these paths are taken.
    private func taken(_ paths: String...) -> (String) -> Bool {
        let set = Set(paths); return { set.contains($0) }
    }

    func testUniqueDestKeepsNameWhenFree() {
        let d = PathRules.uniqueDest(dir, "file.txt", exists: taken())
        XCTAssertEqual(d.lastPathComponent, "file.txt")
    }

    // Keep Both on a name clash.
    func testUniqueDestNumbersFromTwo() {
        let d = PathRules.uniqueDest(dir, "file.txt", exists: taken("/tmp/dest/file.txt"))
        XCTAssertEqual(d.lastPathComponent, "file 2.txt")
    }

    func testUniqueDestSkipsRunsOfTakenNames() {
        let d = PathRules.uniqueDest(dir, "file.txt",
                                     exists: taken("/tmp/dest/file.txt",
                                                   "/tmp/dest/file 2.txt",
                                                   "/tmp/dest/file 3.txt"))
        XCTAssertEqual(d.lastPathComponent, "file 4.txt")
    }

    // The number goes before the extension, never after it.
    func testUniqueDestPreservesExtension() {
        let d = PathRules.uniqueDest(dir, "archive.tar.gz", exists: taken("/tmp/dest/archive.tar.gz"))
        XCTAssertEqual(d.lastPathComponent, "archive.tar 2.gz")
    }

    func testUniqueDestHandlesExtensionlessNames() {
        let d = PathRules.uniqueDest(dir, "New Folder", exists: taken("/tmp/dest/New Folder"))
        XCTAssertEqual(d.lastPathComponent, "New Folder 2")
    }

    // Pasting a file into its own folder duplicates with (1), (2)… starting at 1,
    // which is a different rule from Keep Both above.
    func testNumberedCopyStartsAtOne() {
        let d = PathRules.numberedCopyDest(dir, "photo.jpg", exists: taken())
        XCTAssertEqual(d.lastPathComponent, "photo (1).jpg")
    }

    func testNumberedCopyIncrementsPastExisting() {
        let d = PathRules.numberedCopyDest(dir, "photo.jpg",
                                           exists: taken("/tmp/dest/photo (1).jpg",
                                                         "/tmp/dest/photo (2).jpg"))
        XCTAssertEqual(d.lastPathComponent, "photo (3).jpg")
    }

    // Names with spaces, quotes and non-ASCII all survived a real 10-file paste;
    // keep them working.
    func testAwkwardNamesSurvive() {
        XCTAssertEqual(PathRules.uniqueDest(dir, "name with spaces.txt",
                                            exists: taken("/tmp/dest/name with spaces.txt")).lastPathComponent,
                       "name with spaces 2.txt")
        XCTAssertEqual(PathRules.uniqueDest(dir, "üñïçôdé-名前.png",
                                            exists: taken("/tmp/dest/üñïçôdé-名前.png")).lastPathComponent,
                       "üñïçôdé-名前 2.png")
    }
}

final class OwnOutputTests: XCTestCase {

    private func u(_ p: String) -> URL { URL(fileURLWithPath: p) }

    // Batch runs must skip their own results, or re-running a folder keys the keyed
    // files again and upscales the upscales.
    func testRecognisesOwnOutputs() {
        XCTAssertTrue(PathRules.isOwnOutput(u("/a/pic_rmbg.png"), suffix: "_rmbg"))
        XCTAssertTrue(PathRules.isOwnOutput(u("/a/pic_upscaled.png"), suffix: "_upscaled"))
    }

    func testLeavesOriginalsAlone() {
        XCTAssertFalse(PathRules.isOwnOutput(u("/a/pic.png"), suffix: "_rmbg"))
        XCTAssertFalse(PathRules.isOwnOutput(u("/a/pic_rmbg.png"), suffix: "_upscaled"))
        // "_rmbg" in the middle is not an output name.
        XCTAssertFalse(PathRules.isOwnOutput(u("/a/pic_rmbg_final.png"), suffix: "_rmbg"))
    }
}

// Sidebar drag-to-reorder. The move itself is stdlib; what's worth pinning down is
// the interaction with Home being pinned to the front, and that a reorder never
// loses or duplicates an entry.
final class FavoriteReorderTests: XCTestCase {

    func testMovesItemDown() {
        // [0,1,2,3], drag 0 to sit after 2
        XCTAssertEqual(PathRules.reorder(count: 4, from: IndexSet(integer: 0), to: 3), [1, 2, 0, 3])
    }

    func testMovesItemUp() {
        XCTAssertEqual(PathRules.reorder(count: 4, from: IndexSet(integer: 3), to: 1), [0, 3, 1, 2])
    }

    func testMultiSelectionMovesTogether() {
        XCTAssertEqual(PathRules.reorder(count: 5, from: IndexSet([0, 1]), to: 4), [2, 3, 0, 1, 4])
    }

    func testDroppingInPlaceChangesNothing() {
        XCTAssertEqual(PathRules.reorder(count: 3, from: IndexSet(integer: 1), to: 1), [0, 1, 2])
        XCTAssertEqual(PathRules.reorder(count: 3, from: IndexSet(integer: 1), to: 2), [0, 1, 2])
    }

    // Home is the fixed anchor: dragged away from the top, it snaps back.
    func testPinnedHomeReturnsToTop() {
        XCTAssertEqual(PathRules.reorder(count: 4, from: IndexSet(integer: 0), to: 3, pinnedToFront: 0),
                       [0, 1, 2, 3])
    }

    // The subtler case: Home isn't the thing being dragged, but something is dropped
    // above it. Home must still end up first.
    func testPinnedHomeSurvivesBeingDisplaced() {
        XCTAssertEqual(PathRules.reorder(count: 4, from: IndexSet(integer: 3), to: 0, pinnedToFront: 0),
                       [0, 3, 1, 2])
    }

    // Home partway down the list still gets hoisted.
    func testPinnedHomeHoistedFromMiddle() {
        XCTAssertEqual(PathRules.reorder(count: 4, from: IndexSet(integer: 0), to: 2, pinnedToFront: 2),
                       [2, 1, 0, 3])
    }

    // Whatever the drag, every entry must appear exactly once — a reorder that drops
    // or duplicates a favorite would quietly lose someone's pinned drive.
    func testNeverLosesOrDuplicatesEntries() {
        for from in 0..<5 {
            for to in 0...5 {
                for pin in [nil, 0, 2] as [Int?] {
                    let r = PathRules.reorder(count: 5, from: IndexSet(integer: from), to: to,
                                              pinnedToFront: pin)
                    XCTAssertEqual(r.sorted(), [0, 1, 2, 3, 4],
                                   "from \(from) to \(to) pin \(String(describing: pin))")
                    if let pin { XCTAssertEqual(r.first, pin) }
                }
            }
        }
    }
}

// The Move Up / Move Down / Move to Top menu items, in terms of the offsets they
// hand to reorder(). Move Down is the off-by-one trap: toOffset means "before the
// item originally at this index", so going down one place is i+2, not i+1.
final class FavoriteNudgeTests: XCTestCase {

    private func up(_ i: Int, of n: Int) -> [Int] {
        PathRules.reorder(count: n, from: IndexSet(integer: i), to: i - 1)
    }
    private func down(_ i: Int, of n: Int) -> [Int] {
        PathRules.reorder(count: n, from: IndexSet(integer: i), to: i + 2)
    }
    private func top(_ i: Int, of n: Int) -> [Int] {
        PathRules.reorder(count: n, from: IndexSet(integer: i), to: 0)
    }

    func testMoveUpSwapsWithPrevious() {
        XCTAssertEqual(up(3, of: 5), [0, 1, 3, 2, 4])
        XCTAssertEqual(up(1, of: 4), [1, 0, 2, 3])
    }

    // If this returned [0,1,2,3,4] the item wouldn't move at all — the i+1 bug.
    func testMoveDownSwapsWithNext() {
        XCTAssertEqual(down(1, of: 5), [0, 2, 1, 3, 4])
        XCTAssertEqual(down(0, of: 3), [1, 0, 2])
    }

    func testMoveDownOnLastItemIsCallerGuarded() {
        // The store refuses this case; reorder itself must still not corrupt anything.
        XCTAssertEqual(down(4, of: 5).sorted(), [0, 1, 2, 3, 4])
    }

    func testMoveToTop() {
        XCTAssertEqual(top(3, of: 5), [3, 0, 1, 2, 4])
    }

    // Move to Top on a list where Home is pinned puts the item second, not first.
    func testMoveToTopLandsUnderPinnedHome() {
        let r = PathRules.reorder(count: 4, from: IndexSet(integer: 3), to: 0, pinnedToFront: 0)
        XCTAssertEqual(r, [0, 3, 1, 2])
        XCTAssertEqual(r[1], 3, "the moved item should sit directly under Home")
    }

    // Up then Down returns to the original order.
    func testUpThenDownIsIdentity() {
        for n in 2...6 {
            for i in 1..<n {
                let afterUp = up(i, of: n)
                let pos = afterUp.firstIndex(of: i)!
                let back = PathRules.reorder(count: n, from: IndexSet(integer: pos), to: pos + 2)
                    .map { afterUp[$0] }
                XCTAssertEqual(back, Array(0..<n), "n=\(n) i=\(i)")
            }
        }
    }
}

final class DropDirectionTests: XCTestCase {

    private func u(_ p: String) -> URL { URL(fileURLWithPath: p) }
    private let drive = "/Users/me/Library/CloudStorage/GoogleDrive-me@corp.com/Shared drives/Art"
    private let icloud = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Notes"

    // The dangerous case: cloud providers sit on the local volume, so a volume
    // comparison says "same volume" and the drop would MOVE — deleting the file out
    // of a shared team drive for everyone, from a drag that looks like "copy this
    // out". Must be forced to copy.
    func testDraggingOutOfCloudMustCopy() {
        XCTAssertTrue(PathRules.leavesCloudProvider([u(drive + "/logo.png")], into: u("/Users/me/Desktop")))
        XCTAssertTrue(PathRules.leavesCloudProvider([u(icloud + "/todo.txt")], into: u("/tmp")))
    }

    // Reorganising inside the provider is a legitimate move.
    func testMovingWithinCloudIsStillAMove() {
        XCTAssertFalse(PathRules.leavesCloudProvider([u(drive + "/logo.png")],
                                                     into: u(drive + "/archive")))
        XCTAssertFalse(PathRules.leavesCloudProvider([u(icloud + "/a.txt")], into: u(icloud)))
    }

    // Dropping local files INTO the provider is an upload, not a rescue — normal
    // volume rules apply, so this rule must not fire.
    func testDroppingIntoCloudIsNotAffected() {
        XCTAssertFalse(PathRules.leavesCloudProvider([u("/Users/me/Desktop/a.png")], into: u(drive)))
    }

    // A mixed selection with even one cloud item must copy, or that one file would
    // be deleted from the share.
    func testMixedSelectionErrsTowardCopy() {
        XCTAssertTrue(PathRules.leavesCloudProvider(
            [u("/Users/me/Desktop/local.png"), u(drive + "/shared.png")],
            into: u("/Users/me/Documents")))
    }

    func testOrdinaryLocalDropIsUnaffected() {
        XCTAssertFalse(PathRules.leavesCloudProvider([u("/Users/me/Desktop/a.png")],
                                                     into: u("/Users/me/Documents")))
    }
}

// Restyle: aspect matching, per-model size gating, and the style-leak detector.
final class RestyleRulesTests: XCTestCase {

    func testNearestAspectForCommonShapes() {
        XCTAssertEqual(RestyleRules.nearestAspect(width: 1024, height: 1024), "1:1")
        XCTAssertEqual(RestyleRules.nearestAspect(width: 1920, height: 1080), "16:9")
        XCTAssertEqual(RestyleRules.nearestAspect(width: 1080, height: 1920), "9:16")
        XCTAssertEqual(RestyleRules.nearestAspect(width: 2496, height: 1664), "3:2")
        XCTAssertEqual(RestyleRules.nearestAspect(width: 1200, height: 1500), "4:5")
    }

    // A shape between two listed ratios must pick one, never crash or default to 1:1.
    func testNearestAspectHandlesOddShapes() {
        XCTAssertTrue(RestyleRules.aspects.contains(RestyleRules.nearestAspect(width: 1000, height: 733)))
        XCTAssertTrue(RestyleRules.aspects.contains(RestyleRules.nearestAspect(width: 3000, height: 1000)))
    }

    // Log-space comparison means a portrait image can never match a landscape ratio.
    func testPortraitNeverMatchesLandscape() {
        for h in [1100, 1400, 1800, 2400] {
            let a = RestyleRules.nearestAspect(width: 1000, height: h)
            XCTAssertLessThanOrEqual(RestyleRules.ratio(a), 1.0, "1000x\(h) picked \(a)")
        }
    }

    func testDegenerateSizesDoNotCrash() {
        XCTAssertEqual(RestyleRules.nearestAspect(width: 0, height: 0), "1:1")
        XCTAssertEqual(RestyleRules.nearestAspect(width: -5, height: 10), "1:1")
    }

    // Every model offers the full set; the API rejects what it won't render rather
    // than the picker deciding on its behalf.
    func testAllModelsOfferFullSizeRange() {
        for m in ["nb1", "nb2", "nb-lite", "nb-pro"] {
            XCTAssertEqual(RestyleRules.sizes(forModelFlag: m), ["1K", "2K", "4K"], m)
        }
    }

    // The real leak from a live run: "fine strands of fur", "sheen of leather".
    func testDetectsSubjectLeakage() {
        let leaked = "highly detailed textures, fine strands of fur and the subtle sheen of leather"
        XCTAssertEqual(Set(RestyleRules.styleLeaks(in: leaked)), Set(["fur", "leather"]))
    }

    // The hardened prompt's actual output — must come back clean.
    func testCleanStyleTextHasNoLeaks() {
        let clean = """
            Photorealistic digital rendering with fine, high-frequency detail on organic \
            surfaces and soft specular sheen on structured elements. The palette is warm \
            and earthy. Lighting is soft, directional, and slightly dramatic. Edges are \
            sharp and well-defined.
            """
        XCTAssertEqual(RestyleRules.styleLeaks(in: clean), [])
    }

    // "surface" contains "face"; "skinny" contains "skin". Whole words only, or the
    // warning cries wolf on every clean description.
    func testLeakDetectorMatchesWholeWordsOnly() {
        XCTAssertEqual(RestyleRules.styleLeaks(in: "matte surface, skinny highlights"), [])
        XCTAssertEqual(RestyleRules.styleLeaks(in: "a face in profile"), ["face"])
    }

    func testRestylePromptKeepsTextAndAddsExtra() {
        let p = RestyleRules.restylePrompt(identityAnchors: "a lion character", styleText: "warm earthy palette", extra: "more contrast")
        XCTAssertTrue(p.contains("warm earthy palette"))
        XCTAssertTrue(p.contains("a lion character"))
        XCTAssertTrue(p.contains("character-for-character"))
        XCTAssertTrue(p.contains("ADDITIONAL STYLE NOTES: more contrast"))
    }

    // Identity anchors must come before the style directive — reordering a working
    // prompt to lead with the change measurably let identity drift on live runs.
    func testIdentityAnchorsPrecedeStyle() {
        let p = RestyleRules.restylePrompt(identityAnchors: "ANCHOR_MARKER", styleText: "STYLE_MARKER")
        XCTAssertLessThan(p.range(of: "ANCHOR_MARKER")!.lowerBound, p.range(of: "STYLE_MARKER")!.lowerBound)
    }

    // Empty anchors (analysis failed, or was skipped) must not produce a blank or
    // malformed preservation clause — fall back to generic wording rather than crash
    // or silently drop the constraint.
    func testEmptyIdentityAnchorsFallBackToGenericWording() {
        let p = RestyleRules.restylePrompt(identityAnchors: "  ", styleText: "x")
        XCTAssertTrue(p.contains("everything currently in the image"))
    }

    func testRestylePromptOmitsEmptyExtra() {
        XCTAssertFalse(RestyleRules.restylePrompt(identityAnchors: "a", styleText: "x", extra: "   ").contains("ADDITIONAL"))
    }

    // Two-image prompt: the exact shape that held identity 2/2 on a live model.
    // Regression-testing its structure, not just its substring contents, matters here
    // — a refactor that keeps the words but drops the role labels would reintroduce
    // the subject-bleed bug this shape exists to prevent.
    func testTwoImagePromptLabelsBothImageRoles() {
        let p = RestyleRules.restylePromptTwoImage(identityAnchors: "a lion character")
        XCTAssertTrue(p.contains("IMAGE 1 is the artwork to redraw"))
        XCTAssertTrue(p.lowercased().contains("image 2 is a style reference only"))
        XCTAssertTrue(p.contains("a lion character"))
    }

    func testTwoImagePromptIdentityPrecedesStyleRole() {
        let p = RestyleRules.restylePromptTwoImage(identityAnchors: "ANCHOR_MARKER")
        XCTAssertLessThan(p.range(of: "ANCHOR_MARKER")!.lowerBound, p.range(of: "IMAGE 2")!.lowerBound)
    }

    func testTwoImagePromptEmptyAnchorsFallBackToGenericWording() {
        let p = RestyleRules.restylePromptTwoImage(identityAnchors: "  ")
        XCTAssertTrue(p.contains("everything currently in IMAGE 1"))
    }

    func testTwoImagePromptAddsExtra() {
        let p = RestyleRules.restylePromptTwoImage(identityAnchors: "a", extra: "brighter gold trim")
        XCTAssertTrue(p.contains("ADDITIONAL STYLE NOTES: brighter gold trim"))
    }

    func testTwoImagePromptOmitsEmptyExtra() {
        XCTAssertFalse(RestyleRules.restylePromptTwoImage(identityAnchors: "a", extra: "  ").contains("ADDITIONAL"))
    }
}

// Padding decision: an odd shape needs a backing canvas, a standard one doesn't.
final class RestylePaddingTests: XCTestCase {

    func testStandardRatiosNeedNoPadding() {
        XCTAssertFalse(RestyleRules.needsPadding(width: 1024, height: 1024))
        XCTAssertFalse(RestyleRules.needsPadding(width: 1920, height: 1080))
        XCTAssertFalse(RestyleRules.needsPadding(width: 2496, height: 1664))   // 3:2
        XCTAssertFalse(RestyleRules.needsPadding(width: 1080, height: 1920))
    }

    // Rounding in real exports must not trigger a needless canvas.
    func testNearMissesAreTolerated() {
        XCTAssertFalse(RestyleRules.needsPadding(width: 1920, height: 1081))
        XCTAssertFalse(RestyleRules.needsPadding(width: 1001, height: 1000))
    }

    // Shapes that sit between listed ratios would be reframed, so they get padded.
    func testOddShapesNeedPadding() {
        XCTAssertTrue(RestyleRules.needsPadding(width: 1000, height: 300))   // 3.33:1
        XCTAssertTrue(RestyleRules.needsPadding(width: 500, height: 1200))   // very tall
        // 1600x1150 sits between 5:4, 4:3 and 3:2 — 4.4% off the nearest.
        XCTAssertTrue(RestyleRules.needsPadding(width: 1600, height: 1150))
        // 1600x1200 is exactly 4:3, so it must NOT pad — the case that caught a bad
        // test assumption here.
        XCTAssertFalse(RestyleRules.needsPadding(width: 1600, height: 1200))
    }

    func testDegenerateSizesNeverPad() {
        XCTAssertFalse(RestyleRules.needsPadding(width: 0, height: 0))
    }
}

// Batch restyle defaults and retry classification.
final class RestyleBatchTests: XCTestCase {

    // 2K is deliberate and measured — NB2 really returns 2K pixels. A regression to
    // "1K" would silently halve every output's resolution.
    func testDefaultSizeIs2K() {
        XCTAssertEqual(RestyleRules.defaultSize, "2K")
        XCTAssertTrue(RestyleRules.sizes(forModelFlag: "nb2").contains(RestyleRules.defaultSize))
    }

    // Magenta, not white — the default backing for transparent art.
    func testDefaultPadColorIsMagenta() {
        XCTAssertEqual(RestyleRules.defaultPadColorName, "MagentaScreen")
    }

    // Vertex 503s are real and frequent under load; a batch must survive them.
    func testTransientErrorsAreRetryable() {
        XCTAssertTrue(RestyleRules.isTransient("AI service HTTP 502: Vertex 503: UNAVAILABLE"))
        XCTAssertTrue(RestyleRules.isTransient("The service is currently unavailable."))
        XCTAssertTrue(RestyleRules.isTransient("HTTP 429 RESOURCE_EXHAUSTED"))
        XCTAssertTrue(RestyleRules.isTransient("The request timed out."))
        XCTAssertTrue(RestyleRules.isTransient("The network connection was lost."))
    }

    // A real content/config failure must NOT be retried — retrying a safety block or
    // a bad model name just burns time and money for the same answer.
    func testPermanentErrorsAreNotRetried() {
        XCTAssertFalse(RestyleRules.isTransient("Unsupported image model \"gemini-9\""))
        XCTAssertFalse(RestyleRules.isTransient("Model returned no image: safety-filtered"))
        XCTAssertFalse(RestyleRules.isTransient("prompt is required"))
        XCTAssertFalse(RestyleRules.isTransient("Couldn’t read photo.png."))
    }
}


// Content preservation must work for art boards, backgrounds and UI — not just
// characters. A pay table holding ~20 symbols came back as a single hooded figure
// because both the vision prompt and the restyle prompt were character-centric.
final class RestyleContentPreservationTests: XCTestCase {

    // The restyle prompts must not talk about creatures. "same species / same face /
    // same markings / same clothing" is meaningless for a pay table and is what told
    // the model to produce one character.
    func testPromptsAreNotCharacterCentric() {
        for p in [RestyleRules.restylePrompt(identityAnchors: "a pay table", styleText: "x"),
                  RestyleRules.restylePromptTwoImage(identityAnchors: "a pay table")] {
            let lower = p.lowercased()
            for banned in ["same species", "same face", "same markings", "same clothing",
                           "exact character to redraw"] {
                XCTAssertFalse(lower.contains(banned), "prompt still says \"\(banned)\"")
            }
        }
    }

    // What replaced it has to actually protect a layout.
    func testPromptsProtectLayoutCountsAndText() {
        for p in [RestyleRules.restylePrompt(identityAnchors: "a pay table", styleText: "x"),
                  RestyleRules.restylePromptTwoImage(identityAnchors: "a pay table")] {
            let lower = p.lowercased()
            XCTAssertTrue(lower.contains("layout"))
            XCTAssertTrue(lower.contains("count"))
            XCTAssertTrue(lower.contains("character-for-character"))
            XCTAssertTrue(lower.contains("single subject"), "must forbid collapsing to one subject")
        }
    }

    // The vision prompt must invite every image type, not "the main subject".
    func testVisionPromptCoversEveryImageKind() {
        let sp = RestyleRules.identitySystemPrompt.lowercased()
        for kind in ["art board", "background", "ui element", "single character"] {
            XCTAssertTrue(sp.contains(kind), "vision prompt never mentions \(kind)")
        }
        XCTAssertTrue(sp.contains("transcribed exactly"), "must demand exact text transcription")
        XCTAssertFalse(sp.contains("the main subject"), "'the main subject' is what caused the failure")
    }

    // …and must forbid describing style — colour explicitly and repeatedly, since a
    // live vision model was measured NOT fully complying with a single soft mention
    // of "colour" ("dark reddish-brown wooden plank" slipped through) — plus the
    // other style axes a restyle replaces.
    func testVisionPromptForbidsStyleWords() {
        let sp = RestyleRules.identitySystemPrompt.lowercased()
        XCTAssertTrue(sp.contains("never mention"))
        XCTAssertTrue(sp.contains("colour, shade, tone or hue"), "must forbid colour explicitly, not just generically")
        for banned in ["colour scheme", "distinguishing markings or colouring"] {
            XCTAssertFalse(sp.contains(banned), "vision prompt still invites \(banned)")
        }
    }

    // The real description that came back for download (11) — heavy with style words,
    // which is what fights the new style. Should be flagged.
    func testFlagsStyleWordsInAContentsDescription() {
        let real = "A collection of neon-hued, pixelated slot machine symbols featuring "
                 + "glitchy textures, glowing colors of cyan, magenta, and purple, with "
                 + "retro arcade aesthetics."
        let found = Set(RestyleRules.styleLeaksInContents(real))
        XCTAssertTrue(found.contains("neon"), "should flag neon")
        XCTAssertTrue(found.contains("pixelated"), "should flag pixelated")
        XCTAssertTrue(found.contains("glitchy"), "should flag glitchy")
        XCTAssertTrue(found.contains("cyan"), "should flag cyan")
    }

    // A clean structural description must NOT be flagged, or the warning is noise.
    func testCleanContentsDescriptionIsNotFlagged() {
        let clean = "A pay table art board. Top row: ten labelled icons — BONUS, PIXEL PATH, "
                  + "VOID RESPINS, SCATTER, ADD WILDS, GAMES, WILD, MINOR, MAJOR, GRAND. "
                  + "Below, a heading \"BASE AND BONUS : PAY TABLES\" over four panels."
        XCTAssertEqual(RestyleRules.styleLeaksInContents(clean), [])
    }
}

extension RestyleContentPreservationTests {
    // The prompt should hand off explicitly into the style section, so the model reads
    // "preserve all this… now replace the art style with the following" as one
    // instruction rather than two unrelated ones.
    func testPromptHandsOffIntoTheStyleSection() {
        let one = RestyleRules.restylePrompt(identityAnchors: "a pay table", styleText: "STYLE_MARKER")
        XCTAssertTrue(one.contains("Now replace the art style of this image with the following:"))
        XCTAssertLessThan(one.range(of: "CONTENTS TO PRESERVE")!.lowerBound,
                          one.range(of: "Now replace the art style")!.lowerBound)
        XCTAssertLessThan(one.range(of: "Now replace the art style")!.lowerBound,
                          one.range(of: "STYLE_MARKER")!.lowerBound)

        let two = RestyleRules.restylePromptTwoImage(identityAnchors: "a pay table")
        XCTAssertTrue(two.contains("Now replace the art style of IMAGE 1 with the art style of IMAGE 2"))
        XCTAssertLessThan(two.range(of: "CONTENTS OF IMAGE 1 TO PRESERVE")!.lowerBound,
                          two.range(of: "Now replace the art style")!.lowerBound)
    }
}


// The A/B regression that proved leaked colour language actually constrains a
// restyle's output, not just reads badly, plus the fix's own false-positive fix.
final class RestyleColorLeakTests: XCTestCase {

    // The exact failure: a real vision-model output described the panel as "dark
    // reddish-brown wood" despite being told never to mention colour. The narrow
    // original word list (curated from a single earlier example) missed it entirely.
    func testCatchesTheRealMaterialColorLeak() {
        let leaked = "A wide, dark reddish-brown wooden plank board with subtle carved "
                   + "tribal patterns."
        XCTAssertTrue(RestyleRules.styleLeaksInContents(leaked).contains("brown"),
                      "must catch \"reddish-brown\" as a whole-word \"brown\" match")
    }

    // Quoted on-image text is required transcription, not a style leak. A fully
    // compliant description that quotes a wordmark like "VOLCANO GOLD" must not be
    // flagged just because the wordmark happens to contain a colour word.
    func testQuotedTextIsExemptFromTheColorScan() {
        let clean = "Bottom word: \"VOLCANO GOLD\" in rounded block letters curving along a ribbon."
        XCTAssertEqual(RestyleRules.styleLeaksInContents(clean), [])
    }

    // The same sentence WITHOUT quotes around the colour word must still be caught —
    // proves the exemption is quote-scoped, not accidentally global.
    func testUnquotedColorNearQuotedTextIsStillCaught() {
        let mixed = "A gold-trimmed panel below the text \"VOLCANO GOLD\"."
        XCTAssertEqual(RestyleRules.styleLeaksInContents(mixed), ["gold"])
    }

    // Real remaining leaks (lighting/texture words the model still let through after
    // the strengthened system prompt) must still be caught — the quote fix must not
    // have accidentally widened the exemption.
    func testStillCatchesNonColorStyleWordsOutsideQuotes() {
        let leaked = "Framed by a soft ambient outer glow, with a textured pattern inside the letters."
        let found = Set(RestyleRules.styleLeaksInContents(leaked))
        XCTAssertTrue(found.contains("glow"))
        XCTAssertTrue(found.contains("textured"))
    }

    func testMultipleQuotedSpansAreAllExempt() {
        let clean = "Label below: \"BONUS\" ... Label below: \"GOLD RUSH\" ... Label below: \"RED HOT\"."
        XCTAssertEqual(RestyleRules.styleLeaksInContents(clean), [])
    }

    // An unterminated quote must not eat the rest of the string and hide a real leak
    // — a malformed/truncated vision response should fail safe (still warn), not
    // silently swallow everything after a stray quote mark.
    func testUnterminatedQuoteDoesNotSwallowRealLeaks() {
        let text = "A gold frame with the text \"UNFINISHED"
        XCTAssertEqual(RestyleRules.styleLeaksInContents(text), ["gold"])
    }
}
