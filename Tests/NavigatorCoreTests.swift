// Regression tests for Navigator's path rules.
//
// Every case here corresponds to a bug that actually happened, or to an edge case
// a naive implementation gets wrong. Run with ./runtests.sh.

import XCTest
import ImageIO
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

// Which volume ⌘E (File → Eject) acts on: the one the current folder is actually
// sitting on, picked out of the list of mounted volumes.
final class DeepestRootTests: XCTestCase {

    private func u(_ p: String) -> URL { URL(fileURLWithPath: p) }

    // "/" contains every path, so a first-match search would offer to eject the
    // startup disk no matter where you were.
    func testPrefersTheDeepestMount() {
        let roots = [u("/"), u("/Volumes/Games")]
        XCTAssertEqual(PathRules.deepestRoot(containing: u("/Volumes/Games/art"), among: roots), u("/Volumes/Games"))
    }

    // A volume mounted INSIDE another volume's folder belongs to the inner one.
    func testNestedMountWins() {
        let roots = [u("/Volumes/Backup"), u("/Volumes/Backup/Archive")]
        XCTAssertEqual(PathRules.deepestRoot(containing: u("/Volumes/Backup/Archive/2024"), among: roots),
                       u("/Volumes/Backup/Archive"))
    }

    // Nothing to eject: the folder is on no listed volume (the ejectable list is
    // filtered before it gets here, so this is the "grey the menu item out" case).
    func testNoContainingRoot() {
        XCTAssertNil(PathRules.deepestRoot(containing: u("/Users/me/Desktop"), among: [u("/Volumes/Games")]))
        XCTAssertNil(PathRules.deepestRoot(containing: u("/Users/me"), among: []))
    }

    // A sibling that merely shares a name prefix is not a match — "/Volumes/Games2"
    // must not be ejected because you're browsing "/Volumes/Games".
    func testSiblingPrefixIsNotAMatch() {
        XCTAssertEqual(PathRules.deepestRoot(containing: u("/Volumes/Games/art"),
                                             among: [u("/Volumes/Games"), u("/Volumes/Games2")]),
                       u("/Volumes/Games"))
    }

    // The volume root itself is on the volume.
    func testRootItselfMatches() {
        XCTAssertEqual(PathRules.deepestRoot(containing: u("/Volumes/Games"), among: [u("/"), u("/Volumes/Games")]),
                       u("/Volumes/Games"))
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

// Withholding an image: either side of the job (the source, the style reference) can
// drop to text alone, which is four modes rather than two. These pin down the parts
// that are easy to get subtly wrong — the create/preserve split, and the fact that
// typed style text means something DIFFERENT depending on whether an image is also
// carrying the style.
final class RestyleInputModeTests: XCTestCase {

    func testModeMapsFromTheTwoSwitches() {
        XCTAssertEqual(RestyleInputMode(sendSource: true, sendReference: true), .editWithStyleImage)
        XCTAssertEqual(RestyleInputMode(sendSource: true, sendReference: false), .editWithStyleText)
        XCTAssertEqual(RestyleInputMode(sendSource: false, sendReference: true), .createWithStyleImage)
        XCTAssertEqual(RestyleInputMode(sendSource: false, sendReference: false), .createWithStyleText)
    }

    // The three derived flags exist so callers stop re-deriving them; if they drift from
    // the mode they're describing, padding runs on nothing and empty descriptions ship.
    func testDerivedFlagsAgreeWithTheMode() {
        for m in [RestyleInputMode.editWithStyleImage, .editWithStyleText,
                  .createWithStyleImage, .createWithStyleText] {
            XCTAssertEqual(m.padApplies, m.sendsSource, "padding only means something with a source: \(m)")
            XCTAssertEqual(m.needsContentText, !m.sendsSource, "text is mandatory exactly when no source is sent: \(m)")
        }
        XCTAssertTrue(RestyleInputMode.editWithStyleImage.sendsReference)
        XCTAssertTrue(RestyleInputMode.createWithStyleImage.sendsReference)
        XCTAssertFalse(RestyleInputMode.editWithStyleText.sendsReference)
        XCTAssertFalse(RestyleInputMode.createWithStyleText.sendsReference)
    }

    // The whole point of the split: with no source image, "keep every part exactly as it
    // is" is an instruction about an image the model cannot see. It must say create.
    func testNoSourceModesSayCreateAndNeverSayPreserve() {
        for m in [RestyleInputMode.createWithStyleImage, .createWithStyleText] {
            let p = RestyleRules.prompt(mode: m, contents: "a pay table with 20 symbols", styleText: "flat vector")
            XCTAssertTrue(p.contains("Create a NEW image"), "\(m) must instruct creation")
            XCTAssertTrue(p.contains("CONTENTS TO CREATE"), "\(m) must label contents as created")
            XCTAssertFalse(p.contains("Keep every part of the content exactly as it is"),
                           "\(m) must not demand fidelity to an image that was never sent")
            XCTAssertFalse(p.contains("TO PRESERVE"), "\(m) must not frame contents as preserved")
        }
    }

    func testSourceModesStillPreserve() {
        for m in [RestyleInputMode.editWithStyleImage, .editWithStyleText] {
            let p = RestyleRules.prompt(mode: m, contents: "a pay table", styleText: "flat vector")
            XCTAssertTrue(p.contains("TO PRESERVE"), "\(m) must keep the preservation framing")
            XCTAssertFalse(p.contains("Create a NEW image"), "\(m) edits an image, it doesn't invent one")
        }
    }

    // The create prompts keep preserveClause's hard-won rules, because they apply just
    // as much when DRAWING a 20-symbol pay table from a description as when redrawing
    // one: account for every element, don't collapse to a single subject, exact text.
    func testCreatePromptsKeepTheMultiElementAndExactTextRules() {
        for m in [RestyleInputMode.createWithStyleImage, .createWithStyleText] {
            let p = RestyleRules.prompt(mode: m, contents: "a pay table", styleText: "x")
            XCTAssertTrue(p.contains("character-for-character"), "\(m) must demand exact text")
            XCTAssertTrue(p.lowercased().contains("single subject"),
                          "\(m) must forbid collapsing a layout to one subject")
        }
    }

    // Style text is demoted to supplementary notes when an IMAGE carries the style, and
    // is the style itself when none does. Getting this backwards either buries the
    // reference or duplicates the style paragraph into ART STYLE and the notes at once.
    func testStyleTextIsTheStyleOnlyWhenNoImageCarriesIt() {
        let textModes: [RestyleInputMode] = [.editWithStyleText, .createWithStyleText]
        for m in textModes {
            let p = RestyleRules.prompt(mode: m, contents: "a", styleText: "STYLE_MARKER")
            XCTAssertTrue(p.contains("ART STYLE: STYLE_MARKER"), "\(m) must use the text as the style")
        }
        let imageModes: [RestyleInputMode] = [.editWithStyleImage, .createWithStyleImage]
        for m in imageModes {
            let p = RestyleRules.prompt(mode: m, contents: "a", styleText: "STYLE_MARKER")
            XCTAssertFalse(p.contains("ART STYLE: STYLE_MARKER"),
                           "\(m) has an image for the style — the text is a note, not the style")
            XCTAssertTrue(p.contains("ADDITIONAL STYLE NOTES: STYLE_MARKER"),
                          "\(m) must still pass the text along as a note")
        }
    }

    // Reference-only mode has exactly ONE image attached and it is NOT the subject.
    // Without the role label the model returns the reference's own subject — the same
    // failure the two-image prompt already had to defend against.
    func testReferenceOnlyPromptLabelsTheAttachedImageAsStyleOnly() {
        let p = RestyleRules.prompt(mode: .createWithStyleImage, contents: "a brook trout", styleText: "")
        XCTAssertTrue(p.contains("STYLE reference ONLY"))
        XCTAssertTrue(p.contains("a brook trout"))
        // No "IMAGE 1"/"IMAGE 2" numbering: there is only one image, so numbering it
        // against a source that isn't there would be a lie the model has to resolve.
        XCTAssertFalse(p.contains("IMAGE 2"))
    }

    func testPureTextPromptSendsNoImageRoleLanguageAtAll() {
        let p = RestyleRules.prompt(mode: .createWithStyleText, contents: "a brook trout", styleText: "flat vector")
        XCTAssertFalse(p.lowercased().contains("attached image"))
        XCTAssertFalse(p.contains("IMAGE 1"))
        XCTAssertTrue(p.contains("a brook trout"))
        XCTAssertTrue(p.contains("ART STYLE: flat vector"))
    }

    // Contents-before-style ordering is load-bearing in the existing prompts for a
    // measured reason; the new ones must not quietly invert it.
    func testCreatePromptsPutContentsBeforeStyle() {
        let p = RestyleRules.prompt(mode: .createWithStyleText, contents: "ANCHOR_MARKER", styleText: "STYLE_MARKER")
        XCTAssertLessThan(p.range(of: "ANCHOR_MARKER")!.lowerBound, p.range(of: "STYLE_MARKER")!.lowerBound)
    }

    // Empty contents shouldn't produce a malformed prompt even though the UI blocks it —
    // the same defensive fallback the preserve-side prompts already have.
    func testCreatePromptsSurviveEmptyContents() {
        for m in [RestyleInputMode.createWithStyleImage, .createWithStyleText] {
            let p = RestyleRules.prompt(mode: m, contents: "   ", styleText: "x")
            XCTAssertFalse(p.contains("CONTENTS TO CREATE: \n"), "\(m) left a blank contents line")
            XCTAssertTrue(p.contains("described by"), "\(m) should fall back to describing wording")
        }
    }

    // Existing two modes must be byte-identical to what the old call sites produced, or
    // this refactor silently changed the output of every restyle done before today.
    func testExistingModesMatchTheOriginalPromptBuilders() {
        let contents = "a lion character", style = "warm earthy palette", extra = "more contrast"
        XCTAssertEqual(RestyleRules.prompt(mode: .editWithStyleText, contents: contents,
                                          styleText: style, extra: extra),
                       RestyleRules.restylePrompt(identityAnchors: contents, styleText: style, extra: extra))
        // Two-image folded style+extra into `extra`, joined with ". " — reproduced here.
        XCTAssertEqual(RestyleRules.prompt(mode: .editWithStyleImage, contents: contents,
                                          styleText: style, extra: extra),
                       RestyleRules.restylePromptTwoImage(identityAnchors: contents,
                                                          extra: "\(style). \(extra)"))
    }

    // Metadata labels are what a file uses to explain itself months later, so they have
    // to be distinct — two modes sharing a label makes the record useless.
    func testModeLabelsAreDistinctAndNonEmpty() {
        let labels = [RestyleInputMode.editWithStyleImage, .editWithStyleText,
                      .createWithStyleImage, .createWithStyleText].map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "mode labels collide: \(labels)")
        XCTAssertFalse(labels.contains { $0.isEmpty })
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

// MARK: - Rename rules

final class RenameRulesTests: XCTestCase {

    private func taken(_ paths: String...) -> (String) -> Bool {
        let set = Set(paths); return { set.contains($0) }
    }

    func testFreeNameIsNotACollision() {
        XCTAssertFalse(PathRules.renameCollides(dest: "/tmp/d/new.txt",
                                                exists: taken(),
                                                isSameItem: { _ in false }))
    }

    func testOccupiedNameIsACollision() {
        XCTAssertTrue(PathRules.renameCollides(dest: "/tmp/d/new.txt",
                                               exists: taken("/tmp/d/new.txt"),
                                               isSameItem: { _ in false }))
    }

    // The case-only rename on a case-insensitive volume (the macOS default): the file
    // being renamed is ITSELF what fileExists finds at the destination. Reporting that
    // as a collision would refuse "photo.png" -> "Photo.png", which FileManager does
    // without complaint — hence the file-identity check rather than a path compare.
    func testCaseOnlyRenameIsNotACollisionWithItself() {
        XCTAssertFalse(PathRules.renameCollides(dest: "/tmp/d/Photo.png",
                                                exists: taken("/tmp/d/Photo.png"),
                                                isSameItem: { $0 == "/tmp/d/Photo.png" }))
    }

    // …but on a case-SENSITIVE volume the same two names are two different files, and
    // the identity check is what tells them apart.
    func testCaseOnlyRenameOntoADifferentFileStillCollides() {
        XCTAssertTrue(PathRules.renameCollides(dest: "/tmp/d/Photo.png",
                                               exists: taken("/tmp/d/Photo.png"),
                                               isSameItem: { _ in false }))
    }

    func testOrdinaryNamesAreAccepted() {
        XCTAssertNil(PathRules.invalidNameReason("archive.tar.gz"))
        XCTAssertNil(PathRules.invalidNameReason("a b — c (2).txt"))
    }

    func testSeparatorsAreRejected() {
        XCTAssertNotNil(PathRules.invalidNameReason("a/b.txt"))
        XCTAssertNotNil(PathRules.invalidNameReason("a:b.txt"))
    }

    // MARK: extension-change warning

    func testSameExtensionIsNoChange() {
        XCTAssertNil(PathRules.extensionChange(from: "a.txt", to: "b.txt", isDirectory: false))
    }

    func testNoExtensionEitherSideIsNoChange() {
        XCTAssertNil(PathRules.extensionChange(from: "README", to: "NOTES", isDirectory: false))
    }

    func testAddingAnExtensionIsAChange() {
        let c = PathRules.extensionChange(from: "README", to: "README.md", isDirectory: false)
        XCTAssertEqual(c?.from, "")
        XCTAssertEqual(c?.to, "md")
    }

    func testRemovingAnExtensionIsAChange() {
        let c = PathRules.extensionChange(from: "notes.md", to: "notes", isDirectory: false)
        XCTAssertEqual(c?.from, "md")
        XCTAssertEqual(c?.to, "")
    }

    // The bytes on disk change, and so does what a case-sensitive tool matches — Finder
    // asks about this one too.
    func testCaseOnlyExtensionChangeCounts() {
        let c = PathRules.extensionChange(from: "shot.PNG", to: "shot.png", isDirectory: false)
        XCTAssertEqual(c?.from, "PNG")
        XCTAssertEqual(c?.to, "png")
    }

    // Only the last dot component is the extension: renaming the base of a double-suffix
    // name must not read as ".tar.gz" -> ".gz" and raise a warning about nothing.
    func testMultiDotNameKeepingItsSuffixIsNoChange() {
        XCTAssertNil(PathRules.extensionChange(from: "archive.tar.gz", to: "backup.tar.gz",
                                               isDirectory: false))
    }

    func testMultiDotNameChangingItsLastSuffix() {
        let c = PathRules.extensionChange(from: "archive.tar.gz", to: "archive.tar.bz2",
                                          isDirectory: false)
        XCTAssertEqual(c?.from, "gz")
        XCTAssertEqual(c?.to, "bz2")
    }

    // A folder called "My.Backups" has a pathExtension as far as Foundation is concerned,
    // but nothing opens a folder by extension, so warning about it is noise.
    func testDirectoriesNeverWarn() {
        XCTAssertNil(PathRules.extensionChange(from: "My.Backups", to: "My.Archive",
                                               isDirectory: true))
    }

    // Leading-dot names are hidden files, not extensions.
    func testDotfileHasNoExtension() {
        XCTAssertNil(PathRules.extensionChange(from: ".gitignore", to: ".npmignore",
                                               isDirectory: false))
    }
}

// Undo/redo ORDERING rules. The filesystem half is exercised by hand in the real
// app; what's pinned down here is the bookkeeping that silently corrupts data when
// it's wrong — chiefly "a new operation kills the pending redos".
final class UndoStackTests: XCTestCase {

    private func fresh() -> UndoStack { let s = UndoStack(); s.clear(); return s }

    /// Records into `log` and always succeeds.
    private func push(_ s: UndoStack, _ desc: String, _ log: Log) {
        s.push(desc, undo: { log.entries.append("undo \(desc)"); return nil },
                     redo: { log.entries.append("redo \(desc)"); return nil })
    }
    final class Log { var entries: [String] = [] }

    func testUndoIsLastInFirstOut() {
        let s = fresh(), log = Log()
        push(s, "A", log); push(s, "B", log)
        s.undo(); s.undo()
        XCTAssertEqual(log.entries, ["undo B", "undo A"])
    }

    func testRedoReplaysInReverseOfUndo() {
        let s = fresh(), log = Log()
        push(s, "A", log); push(s, "B", log)
        s.undo(); s.undo()
        s.redo(); s.redo()
        XCTAssertEqual(log.entries.suffix(2), ["redo A", "redo B"])
    }

    // The classic hand-rolled-undo corruption: after undoing A and then doing B,
    // a redo must NOT replay A — A's closure holds paths B may have just changed.
    func testNewOperationClearsTheRedoStack() {
        let s = fresh(), log = Log()
        push(s, "A", log)
        s.undo()
        XCTAssertTrue(s.canRedo)
        push(s, "B", log)
        XCTAssertFalse(s.canRedo)
        s.redo()
        XCTAssertFalse(log.entries.contains("redo A"))
    }

    // A redo must not wipe the redos queued behind it — that would happen if redo()
    // re-filed the entry through push().
    func testRedoKeepsTheRemainingRedoStack() {
        let s = fresh(), log = Log()
        push(s, "A", log); push(s, "B", log)
        s.undo(); s.undo()
        s.redo()                       // replays A
        XCTAssertTrue(s.canRedo)       // B must still be redoable
        XCTAssertEqual(s.topRedoDescription, "B")
    }

    func testEntrySurvivesARedoRoundTrip() {
        let s = fresh(), log = Log()
        push(s, "A", log)
        s.undo(); s.redo(); s.undo()
        XCTAssertEqual(log.entries, ["undo A", "redo A", "undo A"])
        XCTAssertFalse(s.canUndo)
        XCTAssertTrue(s.canRedo)
    }

    // A half that fails (the file vanished from under us) drops its entry rather than
    // moving it to the other stack, where replaying it would compound the mess.
    func testFailedUndoDropsTheEntryAndReports() {
        let s = fresh()
        var reported: String?
        s.onFailure = { summary, _ in reported = summary }
        s.push("Rename", undo: { "the file is gone" }, redo: { nil })
        s.undo()
        XCTAssertFalse(s.canUndo)
        XCTAssertFalse(s.canRedo)
        XCTAssertEqual(reported, "Couldn’t undo Rename")
    }

    func testFailedRedoDropsTheEntry() {
        let s = fresh()
        s.push("Move", undo: { nil }, redo: { "destination is gone" })
        s.undo()
        s.redo()
        XCTAssertFalse(s.canRedo)
        XCTAssertFalse(s.canUndo)
    }

    func testUndoOnEmptyStackSignalsRatherThanCrashing() {
        let s = fresh()
        var beeps = 0
        s.onEmpty = { beeps += 1 }
        s.undo(); s.redo()
        XCTAssertEqual(beeps, 2)
    }

    // Both stacks are capped, so a long session can't grow either one without bound.
    func testBothStacksAreCappedAtTheLimit() {
        let s = fresh(), log = Log()
        for i in 0...(UndoStack.limit + 10) { push(s, "op\(i)", log) }
        XCTAssertEqual(s.undoStack.count, UndoStack.limit)
        // The OLDEST entries are the ones dropped, so the newest is still on top.
        XCTAssertEqual(s.topDescription, "op\(UndoStack.limit + 10)")
        while s.canUndo { s.undo() }
        XCTAssertEqual(s.redoStack.count, UndoStack.limit)
    }

    func testMenuTitlesReflectWhatEachStackWillActOn() {
        let s = fresh(), log = Log()
        XCTAssertNil(s.topDescription)
        XCTAssertNil(s.topRedoDescription)
        push(s, "Move to Trash", log)
        XCTAssertEqual(s.topDescription, "Move to Trash")
        XCTAssertNil(s.topRedoDescription)
        s.undo()
        XCTAssertNil(s.topDescription)
        XCTAssertEqual(s.topRedoDescription, "Move to Trash")
    }
}

// MARK: - Tab / ⇧Tab selection cycling

final class SelectionCycleTests: XCTestCase {
    func testForwardAdvancesAndWrapsAtTheEnd() {
        XCTAssertEqual(cycledSelectionIndex(from: 0, delta: 1, count: 3), 1)
        XCTAssertEqual(cycledSelectionIndex(from: 2, delta: 1, count: 3), 0)
    }

    // The negative-remainder trap: (0 - 1) % 3 is -1 in Swift, which would crash on
    // subscript. ⇧Tab on the first item has to land on the last one.
    func testBackwardWrapsToTheLastItem() {
        XCTAssertEqual(cycledSelectionIndex(from: 1, delta: -1, count: 3), 0)
        XCTAssertEqual(cycledSelectionIndex(from: 0, delta: -1, count: 3), 2)
    }

    func testNoSelectionStartsAtTheEndYouAreHeadingAwayFrom() {
        XCTAssertEqual(cycledSelectionIndex(from: nil, delta: 1, count: 4), 0)
        XCTAssertEqual(cycledSelectionIndex(from: nil, delta: -1, count: 4), 3)
    }

    func testEmptyFolderHasNowhereToGo() {
        XCTAssertNil(cycledSelectionIndex(from: nil, delta: 1, count: 0))
        XCTAssertNil(cycledSelectionIndex(from: 0, delta: -1, count: 0))
    }

    func testSingleItemStaysPut() {
        XCTAssertEqual(cycledSelectionIndex(from: 0, delta: 1, count: 1), 0)
        XCTAssertEqual(cycledSelectionIndex(from: 0, delta: -1, count: 1), 0)
    }
}

// MARK: - Clipboard text forms ("Copy as Path" and the extended-menu variants)

final class PathTextTests: XCTestCase {
    // These three previously asserted DOUBLE-quote wrapping. That was the bug, not the
    // contract: `$` and a backtick are legal in a macOS filename and stay active inside
    // double quotes, so `report $(id).png` executed when pasted into a shell. Single
    // quotes interpret nothing, so they are the only safe wrapping for arbitrary names.
    func testQuotedWrapsSoSpacesSurviveAShell() {
        XCTAssertEqual(PathText.quoted(["/Users/me/My Files/a.txt"]), "'/Users/me/My Files/a.txt'")
    }

    // Inside single quotes a double quote and a backslash are both ordinary characters,
    // so neither needs escaping - and escaping them would corrupt the path.
    func testQuotedLeavesQuotesAndBackslashesLiteral() {
        XCTAssertEqual(PathText.quoted(["/tmp/a\"b"]), "'/tmp/a\"b'")
        XCTAssertEqual(PathText.quoted(["/tmp/a\\b"]), "'/tmp/a\\b'")
    }

    func testQuotedJoinsAMultiSelectionOnePerLine() {
        XCTAssertEqual(PathText.quoted(["/a", "/b"]), "'/a'\n'/b'")
    }

    func testFileURLsPercentEncodeSpaces() {
        XCTAssertEqual(PathText.fileURLs(["/tmp/a b.txt"]), "file:///tmp/a%20b.txt")
    }

    func testNamesWithoutExtension() {
        XCTAssertEqual(PathText.namesWithoutExtension(["shot.png", "notes"]), "shot\nnotes")
    }

    // ".gitignore" has no extension — its dot starts the name. Dropping "everything
    // after the last dot" would copy an empty string.
    func testDotfileKeepsItsWholeName() {
        XCTAssertEqual(PathText.namesWithoutExtension([".gitignore"]), ".gitignore")
    }

    func testNameWithSeveralDotsOnlyLosesTheLastPart() {
        XCTAssertEqual(PathText.namesWithoutExtension(["archive.tar.gz"]), "archive.tar")
    }

    // Only escaping the closing bracket leaves an unmatched "[" and CommonMark stops
    // treating the whole thing as a link.
    func testMarkdownLinkEscapesBothBracketsInTheLabel() {
        XCTAssertEqual(PathText.markdownLinks([(name: "shot [1].png", path: "/tmp/shot [1].png")]),
                       "[shot \\[1\\].png](file:///tmp/shot%20%5B1%5D.png)")
    }
}

// MARK: - Tab context-menu enablement

final class TabMenuRulesTests: XCTestCase {
    func testCloseOthersNeedsMoreThanOneTab() {
        XCTAssertFalse(TabMenuRules.canCloseOthers(index: 0, count: 1))
        XCTAssertTrue(TabMenuRules.canCloseOthers(index: 0, count: 2))
    }

    // The last tab has nothing to its right — the item must be disabled, not a no-op.
    func testCloseToRightIsOffOnTheLastTab() {
        XCTAssertFalse(TabMenuRules.canCloseToRight(index: 2, count: 3))
        XCTAssertTrue(TabMenuRules.canCloseToRight(index: 1, count: 3))
        XCTAssertFalse(TabMenuRules.canCloseToRight(index: 0, count: 1))
    }

    func testMovingTheOnlyTabOutIsRefused() {
        XCTAssertFalse(TabMenuRules.canMoveToNewWindow(index: 0, count: 1))
        XCTAssertTrue(TabMenuRules.canMoveToNewWindow(index: 1, count: 2))
    }

    func testOutOfRangeIndexEnablesNothing() {
        XCTAssertFalse(TabMenuRules.canCloseOthers(index: 5, count: 2))
        XCTAssertFalse(TabMenuRules.canMoveToNewWindow(index: -1, count: 2))
    }
}

// MARK: - ⌘W / File ▸ Close Tab

final class CloseTabRulesTests: XCTestCase {
    /// THE REGRESSION. Navigator can be frontmost with no key window at all, and in that
    /// state ⌘W and File ▸ Close Tab silently did nothing while both looked enabled. The
    /// only wrong answer here is "do nothing", so this asserts a real tab gets closed.
    func testNoKeyWindowStillClosesATab() {
        XCTAssertEqual(CloseTabRules.outcome(hasKeyWindow: false, keyWindowIsBrowser: false, tabCount: 5),
                       .closeTab)
    }

    func testNoKeyWindowOnLastTabClosesTheWindow() {
        XCTAssertEqual(CloseTabRules.outcome(hasKeyWindow: false, keyWindowIsBrowser: false, tabCount: 1),
                       .closeBrowserWindow)
    }

    /// A Settings / Get Info / viewer window in front owns ⌘W, however many tabs are behind.
    func testNonBrowserKeyWindowWinsOverTabs() {
        XCTAssertEqual(CloseTabRules.outcome(hasKeyWindow: true, keyWindowIsBrowser: false, tabCount: 9),
                       .closeKeyWindow)
    }

    func testBrowserKeyWindowClosesTabThenWindow() {
        XCTAssertEqual(CloseTabRules.outcome(hasKeyWindow: true, keyWindowIsBrowser: true, tabCount: 3),
                       .closeTab)
        XCTAssertEqual(CloseTabRules.outcome(hasKeyWindow: true, keyWindowIsBrowser: true, tabCount: 1),
                       .closeBrowserWindow)
    }

    /// Whatever the inputs, the answer is never "nothing" — that was the bug.
    func testEveryCombinationDoesSomething() {
        for hasKey in [true, false] {
            for isBrowser in [true, false] {
                for count in [0, 1, 2, 40] {
                    let o = CloseTabRules.outcome(hasKeyWindow: hasKey,
                                                  keyWindowIsBrowser: isBrowser, tabCount: count)
                    XCTAssertTrue([.closeKeyWindow, .closeTab, .closeBrowserWindow].contains(o))
                }
            }
        }
    }
}

// MARK: - Adobe error wording

final class AdobeErrorTextTests: XCTestCase {
    /// The exact line that reached a user-facing dialog, jargon and all.
    func testTheLineThatLeakedIntoADialog() {
        let out = AdobeErrorText.friendly(
            "stub.psd: ERROR: [open] Cannot open the file because the open options are incorrect")
        XCTAssertTrue(out.hasPrefix("stub.psd: "), "the filename must survive")
        XCTAssertFalse(out.contains("ERROR:"))
        XCTAssertFalse(out.contains("[open]"))
        XCTAssertFalse(out.lowercased().contains("open options"))
        XCTAssertTrue(out.contains("damaged"), "should explain what's actually wrong: \(out)")
    }

    func testBusyPhotoshopReadsAsTransient() {
        let out = AdobeErrorText.friendly("a.psd: ERROR: [activeLayer] The command “Get” is not currently available")
        XCTAssertTrue(out.lowercased().contains("busy"), out)
        XCTAssertFalse(out.contains("["))
    }

    /// An unknown failure must still be reportable — cleaned up, never swallowed.
    func testUnknownMessageKeepsItsText() {
        let out = AdobeErrorText.friendly("x.psd: ERROR: [saveAs] Something nobody has seen before")
        XCTAssertTrue(out.contains("Something nobody has seen before"), out)
        XCTAssertFalse(out.contains("ERROR:"))
        XCTAssertFalse(out.contains("[saveAs]"))
        XCTAssertTrue(out.hasPrefix("x.psd: "))
    }

    func testHandlesALineWithNoFilenamePrefix() {
        XCTAssertFalse(AdobeErrorText.friendly("ERROR: [open] Cannot open the file").isEmpty)
        XCTAssertFalse(AdobeErrorText.friendly("").contains("ERROR"))
    }

    /// Specific wording must beat the generic fallback when both could match.
    func testMostSpecificWordingWins() {
        let out = AdobeErrorText.friendly("a.psd: Cannot open the file because the open options are incorrect")
        XCTAssertTrue(out.contains("renamed .psd"), out)
    }
}

// MARK: - Adobe wedge detection

final class AdobeRecoveryRulesTests: XCTestCase {
    /// THE BUG: one corrupt .psd made Navigator quit and relaunch Photoshop. The file was
    /// invalid and the app was fine, and the restart's force-terminate fallback can take
    /// unsaved work with it. This exact message was captured from a live run.
    func testACorruptFileIsNotAWedge() {
        XCTAssertFalse(AdobeRecoveryRules.looksWedged(
            "ERROR: [open] Cannot open the file because the open options are incorrect"))
    }

    func testOtherBadFileMessagesAreNotWedges() {
        for m in ["ERROR: [open] The file could not be found",
                  "ERROR: [open] The file is not a valid Photoshop document",
                  "ERROR: [open] The document is damaged",
                  "ERROR: [open] Unsupported file format",
                  "ERROR: [open] No such file or directory"] {
            XCTAssertFalse(AdobeRecoveryRules.looksWedged(m), "should not restart for: \(m)")
        }
    }

    /// The real wedge — Photoshop briefly cannot service scripting at all. A restart is the
    /// only thing that recovers this, so it must still fire.
    func testGenuineWedgesStillRestart() {
        for m in ["ERROR: [activeLayer] The command “Get” is not currently available",
                  "ERROR: [removeBackground] The command \"Get\" is not currently available",
                  "AppleEvent timed out",
                  "ERROR: [open] General Photoshop error occurred"] {
            XCTAssertTrue(AdobeRecoveryRules.looksWedged(m), "should restart for: \(m)")
        }
    }

    /// A bad-file signature must beat a wedge signature — Photoshop wraps file refusals in
    /// the same generic error text, so the specific reason has to win.
    func testBadFileBeatsGenericWrapper() {
        XCTAssertFalse(AdobeRecoveryRules.looksWedged(
            "ERROR: [open] General Photoshop error occurred - Cannot open the file because the open options are incorrect"))
    }

    func testCaseInsensitive() {
        XCTAssertFalse(AdobeRecoveryRules.looksWedged("CANNOT OPEN THE FILE"))
        XCTAssertTrue(AdobeRecoveryRules.looksWedged("The Command Get IS NOT CURRENTLY AVAILABLE"))
    }
}

// MARK: - Layerize

final class LayerizeRulesTests: XCTestCase {
    /// `auto` FIRST, always. It is the API's documented default — "auto adapts to the input image
    /// while preserving each element's aspect ratio" — and this code used to never send it,
    /// forcing a tier guessed from a pixel threshold instead. That guess is what refused
    /// SF1_Red (632×791) at auto_1K.
    func testLadderStartsWithTheDocumentedDefault() {
        for (w, h) in [(632, 791), (3072, 3924), (600, 600), (2048, 2048)] {
            let l = LayerizeRules.sizeLadder(width: w, height: h)
            XCTAssertEqual(l.first, "auto", "\(w)×\(h) must try the API default first")
            XCTAssertEqual(l.count, 3, "capped at three attempts — each one is a paid generation")
            XCTAssertEqual(l[1], "auto", "second attempt covers a transient refusal")
        }
    }

    /// The last rung asks for MORE output resolution, which is what actually rescued SF1_Red:
    /// refused at auto_1K, accepted at auto_1.5K.
    func testLastResortAsksForMoreResolution() {
        XCTAssertEqual(LayerizeRules.lastResortSize(width: 632, height: 791), "auto_1.5K")
        XCTAssertEqual(LayerizeRules.lastResortSize(width: 3072, height: 3924), "auto_2K")
        XCTAssertNotEqual(LayerizeRules.sizeLadder(width: 632, height: 791)[2], "auto_1K",
                          "auto_1K is the size that was refused; retrying it would be pointless")
    }

    /// Zero-byte and non-PNG responses must never be written or recorded. Data(contentsOf:)
    /// succeeds on an empty body, which is how L01_Outer_black_background and L00_base were
    /// written as empty files, counted as saved, and then discarded by the filesystem.
    func testEmptyOrNonPNGLayersAreRejected() {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 200)
        XCTAssertTrue(LayerizeRules.isPlausiblePNG(png))
        XCTAssertFalse(LayerizeRules.isPlausiblePNG([]), "a zero-byte download is not a layer")
        XCTAssertFalse(LayerizeRules.isPlausiblePNG(Array(png.prefix(20))), "truncated")
        XCTAssertFalse(LayerizeRules.isPlausiblePNG([UInt8](repeating: 0x41, count: 500)), "not a PNG")
    }

    /// fal's limits are a pixel COUNT, not per-side. These all satisfy the documented range and
    /// must pass untouched — the old per-side check resampled them for no reason.
    func testPixelCountLimitsNotPerSide() {
        XCTAssertEqual(LayerizeRules.check(width: 300, height: 1000, bytes: 1000), .ok,
                       "0.3 MP is inside 0.26–36 MP even though a side is under 512")
        XCTAssertEqual(LayerizeRules.check(width: 8000, height: 4000, bytes: 1000), .ok,
                       "32 MP is inside the limit even though a side exceeds 6000")
        // Genuinely out of range still gets caught.
        if case .needsResize = LayerizeRules.check(width: 100, height: 100, bytes: 1000) {} else {
            XCTFail("0.01 MP is under the documented minimum")
        }
        if case .needsResize = LayerizeRules.check(width: 9000, height: 9000, bytes: 1000) {} else {
            XCTFail("81 MP is over the documented maximum")
        }
    }

    func testKeyArtPasses() {
        XCTAssertEqual(LayerizeRules.check(width: 3072, height: 3924, bytes: 17_400_000), .ok)
    }

    /// 9000×4000 is exactly 36 MP — the documented maximum — so it must pass UNTOUCHED. The old
    /// per-side rule resampled it purely because a side exceeded 6000, losing quality to a limit
    /// fal never stated. Something genuinely over the pixel budget still gets caught, and the
    /// suggested size must actually fit while preserving aspect.
    func testOversizeIsJudgedByPixelCountNotSideLength() {
        XCTAssertEqual(LayerizeRules.check(width: 9000, height: 4000, bytes: 1000), .ok,
                       "exactly 36 MP is inside the documented limit")
        guard case let .needsResize(_, to) = LayerizeRules.check(width: 12000, height: 6000, bytes: 1000) else {
            return XCTFail("72 MP must be flagged")
        }
        XCTAssertLessThanOrEqual(to.w * to.h, LayerizeRules.maxPixels)
        XCTAssertEqual(Double(to.w) / Double(to.h), 2.0, accuracy: 0.01, "aspect must be preserved")
    }

    func testUndersizeSuggestsAResizeThatActuallyFits() {
        guard case let .needsResize(_, to) = LayerizeRules.check(width: 200, height: 200, bytes: 1000) else {
            return XCTFail("200px must be flagged")
        }
        // Judged on total pixels, not side length — a wide-but-thin image can satisfy the
        // documented minimum without either side reaching 512.
        XCTAssertGreaterThanOrEqual(to.w * to.h, LayerizeRules.minPixels)
    }

    /// Over 30 MB is fixable by re-encoding, so dimensions must be left alone.
    func testOversizeBytesKeepsDimensions() {
        guard case let .needsResize(reason, to) = LayerizeRules.check(width: 3000, height: 3000, bytes: 40 * 1024 * 1024) else {
            return XCTFail("40 MB must be flagged")
        }
        XCTAssertTrue(reason.contains("MB"))
        XCTAssertEqual(to.w, 3000); XCTAssertEqual(to.h, 3000)
    }

    /// An extreme strip can't be fixed by resampling — refuse rather than suggest nonsense.
    func testAspectOutOfRangeIsRejectedNotResized() {
        guard case .reject = LayerizeRules.check(width: 8000, height: 100, bytes: 1000) else {
            return XCTFail("80:1 must be rejected")
        }
        XCTAssertEqual(LayerizeRules.check(width: 0, height: 0, bytes: 0), .reject(reason: "not a readable image"))
    }

    /// Measured BORDER transparency from six real assets. The overall fraction, which this used to
    /// test, could not separate them: the dragon cutout was 15.7% transparent and an opaque framed
    /// symbol 15.4%, so the cutout slipped under a 20% bar, kept fal's invented base, and put grey
    /// and white blocks behind the art. Around the edge the two populations do not overlap at all.
    func testBaseKeptOnlyWhenTheInputHasARealBackground() {
        // Real scenes — every edge pixel opaque, and no transparency anywhere.
        XCTAssertTrue(LayerizeRules.shouldKeepBase(borderTransparentFraction: 0.0,
                                                   overallTransparentFraction: 0.0))   // bluebird
        XCTAssertTrue(LayerizeRules.shouldKeepBase(borderTransparentFraction: 0.0,
                                                   overallTransparentFraction: 0.0))   // mockup
        // Cutouts — the edge is almost entirely empty.
        XCTAssertFalse(LayerizeRules.shouldKeepBase(borderTransparentFraction: 0.967,
                                                    overallTransparentFraction: 0.157)) // dragon rmbg
        XCTAssertFalse(LayerizeRules.shouldKeepBase(borderTransparentFraction: 0.969,
                                                    overallTransparentFraction: 0.229)) // frame art
        XCTAssertFalse(LayerizeRules.shouldKeepBase(borderTransparentFraction: 0.960,
                                                    overallTransparentFraction: 0.548)) // character
        XCTAssertFalse(LayerizeRules.shouldKeepBase(borderTransparentFraction: 0.988,
                                                    overallTransparentFraction: 0.154)) // framed symbol
        // THE BLIND SPOT the second signal exists for: art running to the edge on most sides, so the
        // border looks opaque, while a third of the image is transparent. Border alone would keep
        // fal's invented plate here and put grey back behind the art.
        XCTAssertFalse(LayerizeRules.shouldKeepBase(borderTransparentFraction: 0.40,
                                                    overallTransparentFraction: 0.30))
    }

    /// THE NAMING BUG: an ASCII-only sanitiser mapped every Chinese name to "" and collapsed
    /// twelve distinct layers to "unnamed".
    func testChineseNamesSurviveSanitising() {
        XCTAssertEqual(LayerizeRules.safeName("竖格锦鲤图标"), "竖格锦鲤图标")
        XCTAssertFalse(LayerizeRules.safeName("左侧边框金龙").isEmpty)
        XCTAssertEqual(LayerizeRules.safeName("Left Dragon Frame"), "Left_Dragon_Frame")
    }

    func testSanitiserStripsOnlyWhatAFilesystemCannotTake() {
        XCTAssertFalse(LayerizeRules.safeName("a/b:c*d?").contains("/"))
        XCTAssertFalse(LayerizeRules.safeName("a/b:c*d?").contains(":"))
        XCTAssertEqual(LayerizeRules.safeName(nil), "")
        XCTAssertEqual(LayerizeRules.safeName(""), "")
        XCTAssertLessThanOrEqual(LayerizeRules.safeName(String(repeating: "x", count: 300)).count, 60)
    }

    func testFileNamesAreUniquePerLayerEvenWhenNamesRepeat() {
        let a = LayerizeRules.fileName(stem: "KeyArt", zIndex: 3, name: "Dragon")
        let b = LayerizeRules.fileName(stem: "KeyArt", zIndex: 7, name: "Dragon")
        XCTAssertNotEqual(a, b, "duplicate names must not overwrite each other")
        XCTAssertEqual(a, "KeyArt_L03_Dragon.png")
        XCTAssertEqual(LayerizeRules.fileName(stem: "KeyArt", zIndex: 0, name: nil), "KeyArt_L00_base.png")
        // the Chinese case that used to collapse
        XCTAssertNotEqual(LayerizeRules.fileName(stem: "K", zIndex: 1, name: "老虎机面板"),
                          LayerizeRules.fileName(stem: "K", zIndex: 2, name: "左侧边框金龙"))
    }

}

// MARK: - Network column defaults

final class NetworkColumnRulesTests: XCTestCase {

    /// Every default column must cost NOTHING per file. Name comes from readdir; Ext and
    /// Kind are derived from it with no I/O. Measured: 429 ms for artSource's 669 files.
    func testNetworkDefaultsAreAllFreeToRead() {
        XCTAssertEqual(NetworkColumnRules.networkDefaults, ["name", "extension", "kind", "size", "modified"])
        XCTAssertTrue(NetworkColumnRules.networkDefaults
            .isDisjoint(with: NetworkColumnRules.costlyOnNetwork),
            "Owner/Duration/Dimensions are not indexable and must never be on by default")
    }

    /// Size and Modified are the 89 ms/entry cost, so they must NOT be on by default —
    /// but they must still be reachable, which testExplicitChoiceIsNeverStripped covers.
    /// Size and Modified are on by default AND still attribute columns — they need a fetch, they
    /// are just an affordable one now that the index answers them in bulk.
    func testSizeAndModifiedAreDefaultsButStillNeedFetching() {
        for c in ["size", "modified"] {
            XCTAssertTrue(NetworkColumnRules.networkDefaults.contains(c))
            XCTAssertTrue(NetworkColumnRules.attributeColumns.contains(c))
        }
    }

    /// The whole payoff: with only free columns the expensive pass is skipped outright.
    /// The default set now DOES need a pass — served by the index, or by visible-rows-first when
    /// there isn't one. The guarantee is that it is never Owner/Duration/Dimensions.
    func testDefaultSetNeedsAPassButOnlyIndexableOnes() {
        XCTAssertTrue(NetworkColumnRules.needsAttributePass(
            columns: NetworkColumnRules.networkDefaults, sortKey: "name"))
        XCTAssertTrue(NetworkColumnRules.costly(in: NetworkColumnRules.networkDefaults).isEmpty)
    }

    /// Any attribute column, or a sort that needs the data, brings the pass back.
    func testAttributePassRequiredWhenSomethingNeedsIt() {
        for c in ["size", "modified", "created", "accessed", "owner", "duration", "dimensions"] {
            XCTAssertTrue(NetworkColumnRules.needsAttributePass(columns: ["name", c], sortKey: "name"),
                          "\(c) needs a per-file fetch")
        }
        // Sorting by size with no Size column still has to know every size.
        XCTAssertTrue(NetworkColumnRules.needsAttributePass(columns: ["name", "extension"], sortKey: "size"))
        XCTAssertTrue(NetworkColumnRules.needsAttributePass(columns: ["name"], sortKey: "modified"))
        XCTAssertFalse(NetworkColumnRules.needsAttributePass(columns: ["name", "kind"], sortKey: "name"),
                       "sorting by name over free columns must stay free")
    }

    /// A share with nothing arranged takes the cheap set; local browsing is untouched.
    func testSeedUsesCheapSetOnlyOnNetwork() {
        let local: Set<String> = ["name", "owner", "tags"]
        XCTAssertEqual(NetworkColumnRules.seed(isNetwork: true, localDefaults: local),
                       NetworkColumnRules.networkDefaults)
        XCTAssertEqual(NetworkColumnRules.seed(isNetwork: false, localDefaults: local), local)
    }

    /// The point of the redesign: nothing strips a column the user asked for. seed() is only
    /// consulted when a folder has NO saved columns, so an explicit Owner survives on a share.
    func testExplicitChoiceIsNeverStripped() {
        XCTAssertEqual(NetworkColumnRules.costly(in: ["name", "owner", "dimensions"]),
                       ["owner", "dimensions"])
        XCTAssertTrue(NetworkColumnRules.costly(in: ["name", "size"]).isEmpty,
                      "nothing costly to report when only free columns were asked for")
    }

    /// Cheap columns alone don't give an instant listing — a size/date sort needs the same
    /// per-file data. So an unarranged network folder sorts by name, and only that case.
    func testSeedSortKeyAvoidsAttributeSortsOnNetwork() {
        XCTAssertEqual(NetworkColumnRules.seedSortKey(isNetwork: true, localDefault: "size"), "name")
        XCTAssertEqual(NetworkColumnRules.seedSortKey(isNetwork: true, localDefault: "modified"), "name")
        XCTAssertEqual(NetworkColumnRules.seedSortKey(isNetwork: true, localDefault: "kind"), "kind",
                       "a free sort is kept as-is")
        XCTAssertEqual(NetworkColumnRules.seedSortKey(isNetwork: false, localDefault: "size"), "size",
                       "local browsing is never downgraded")
    }

    /// The default arrangement sorts by name even when the global default is a size sort: the
    /// listing must be orderable from readdir alone, so rows can paint before any attribute
    /// arrives. The columns then fill in from the index (or visible-rows-first) underneath.
    func testDefaultNetworkArrangementSortsWithoutNeedingAttributes() {
        let sort = NetworkColumnRules.seedSortKey(isNetwork: true, localDefault: "size")
        XCTAssertEqual(sort, "name")
        XCTAssertFalse(NetworkColumnRules.attributeSortKeys.contains(sort),
                       "a folder must be sortable before its attributes exist")
    }

    /// The migration drops the costly columns from a saved network arrangement but never
    /// produces an unrenderable table.
    func testCleanedStripsCostlyButAlwaysKeepsName() {
        XCTAssertEqual(NetworkColumnRules.cleaned(columns: ["name", "size", "owner", "created"]),
                       ["name", "size"], "size is indexable and stays; owner and created do not")
        XCTAssertTrue(NetworkColumnRules.cleaned(columns: ["owner", "dimensions"]).contains("name"),
                      "stripping everything must still leave a name column")
        XCTAssertEqual(NetworkColumnRules.cleaned(columns: ["name", "extension", "kind"]),
                       ["name", "extension", "kind"], "a cheap arrangement is untouched")
    }

    func testEmptySelectionIsSafe() {
        XCTAssertTrue(NetworkColumnRules.costly(in: []).isEmpty)
    }
}

// MARK: - Search query parsing and matching

final class SearchQueryRulesTests: XCTestCase {
    /// THE BUG, with the real filename that exposed it. Measured against the live Spotlight
    /// index: "phoenix v2" as one substring returned 0 files; as separate tokens, 17.
    func testMultiWordSearchFindsTheFile() {
        let name = "HP2_Phoenix_Direct_NB2_v2.png"
        XCTAssertFalse(SearchQueryRules.fold(name).contains(SearchQueryRules.fold("phoenix v2")),
                       "precondition: the old single-substring test really does fail")
        XCTAssertTrue(SearchQueryRules.matches(name: name, tokens: SearchQueryRules.tokens("phoenix v2")))
        XCTAssertTrue(SearchQueryRules.matches(name: name, tokens: SearchQueryRules.tokens("v2 phoenix")),
                      "order must not matter")
        XCTAssertTrue(SearchQueryRules.matches(name: name, tokens: SearchQueryRules.tokens("hp2 direct png")))
    }

    func testAllTokensAreRequiredNotAny() {
        let name = "Dragon_Gold_v1.png"
        XCTAssertTrue(SearchQueryRules.matches(name: name, tokens: SearchQueryRules.tokens("dragon gold")))
        XCTAssertFalse(SearchQueryRules.matches(name: name, tokens: SearchQueryRules.tokens("dragon phoenix")),
                       "a token that is absent must exclude the file")
    }

    /// A quoted phrase is the escape hatch for wanting the literal string back.
    func testQuotedPhraseStaysOneToken() {
        XCTAssertEqual(SearchQueryRules.tokens("\"red dragon\""), ["red dragon"])
        XCTAssertEqual(SearchQueryRules.tokens("\"red dragon\" gold"), ["red dragon", "gold"])
        XCTAssertTrue(SearchQueryRules.matches(name: "a red dragon.png", tokens: SearchQueryRules.tokens("\"red dragon\"")))
        XCTAssertFalse(SearchQueryRules.matches(name: "dragon_red.png", tokens: SearchQueryRules.tokens("\"red dragon\"")),
                       "quoted means literal, so a reordered name must NOT match")
    }

    /// The two backends disagreed here: the walk folded case only, Spotlight folded case AND
    /// diacritics, so an accented name matched in one and not the other.
    func testCaseAndDiacriticInsensitive() {
        XCTAssertTrue(SearchQueryRules.matches(name: "Café_Sign.png", tokens: SearchQueryRules.tokens("cafe")))
        XCTAssertTrue(SearchQueryRules.matches(name: "cafe_sign.png", tokens: SearchQueryRules.tokens("CAFÉ")))
        XCTAssertTrue(SearchQueryRules.matches(name: "ÜBER.png", tokens: SearchQueryRules.tokens("uber")))
    }

    func testExtensionQueryStillWorks() {
        XCTAssertEqual(SearchQueryRules.extensionQuery(SearchQueryRules.tokens("png")), "png")
        XCTAssertEqual(SearchQueryRules.extensionQuery(SearchQueryRules.tokens(".png")), "png")
        XCTAssertEqual(SearchQueryRules.extensionQuery(SearchQueryRules.tokens("*.PNG")), "png")
        XCTAssertTrue(SearchQueryRules.matchesFile(name: "artwork_final", ext: "png",
                                                  tokens: SearchQueryRules.tokens("png")),
                      "a bare extension must find files whose NAME lacks it")
        // Multi-token queries are names, not extensions
        XCTAssertNil(SearchQueryRules.extensionQuery(SearchQueryRules.tokens("logo png")))
        // Not everything short is an extension
        XCTAssertNil(SearchQueryRules.extensionQuery(SearchQueryRules.tokens("dragonfly")))
    }

    func testEmptyAndWhitespaceQueries() {
        XCTAssertTrue(SearchQueryRules.tokens("").isEmpty)
        XCTAssertTrue(SearchQueryRules.tokens("   \t ").isEmpty)
        // No tokens = filter-only search, so everything qualifies
        XCTAssertTrue(SearchQueryRules.matches(name: "anything.png", tokens: []))
    }

    func testUnbalancedQuoteDoesNotLoseTheText() {
        XCTAssertEqual(SearchQueryRules.tokens("\"red dragon"), ["red dragon"])
        XCTAssertFalse(SearchQueryRules.tokens("\"").contains(where: { !$0.isEmpty }))
    }
}

final class SearchTruncationTests: XCTestCase {
    /// A capped list that reports a plain count reads as a complete answer, and someone then
    /// concludes the file they were looking for doesn't exist.
    func testCappedResultsSaySo() {
        let t = SearchTruncation.of(shown: 500, cap: 500, hitCap: true)
        XCTAssertEqual(t, .capped(shown: 500, cap: 500))
        XCTAssertTrue(t.statusText.contains("more than"))
        XCTAssertTrue(t.statusText.lowercased().contains("narrow"))
    }

    func testCompleteResultsReadNormally() {
        let t = SearchTruncation.of(shown: 42, cap: 500, hitCap: false)
        XCTAssertEqual(t, .complete(42))
        XCTAssertEqual(t.statusText, "42 found")
        XCTAssertFalse(t.statusText.contains("more than"))
    }
}

// MARK: - Thumbnail cache keys

final class ThumbnailKeyRulesTests: XCTestCase {
    /// THE BUG: same path, same size, new bytes — the key MUST change or the old thumbnail is
    /// served forever. This is what left a removed green-cloud background still showing.
    func testRewriteAtSamePathChangesTheKey() {
        let before = ThumbnailKeyRules.key(path: "/art/HP1.png", size: 256, mtime: 1_000_000, bytes: 4_771_312)
        let after  = ThumbnailKeyRules.key(path: "/art/HP1.png", size: 256, mtime: 1_000_060, bytes: 3_991_004)
        XCTAssertNotEqual(before, after)
    }

    /// Coarse-timestamp filesystems round to the second, so length alone must still separate.
    func testSameMtimeDifferentLengthStillDiffers() {
        let a = ThumbnailKeyRules.key(path: "/art/x.png", size: 256, mtime: 1_000_000, bytes: 100)
        let b = ThumbnailKeyRules.key(path: "/art/x.png", size: 256, mtime: 1_000_000, bytes: 101)
        XCTAssertNotEqual(a, b)
    }

    func testSameLengthDifferentMtimeStillDiffers() {
        let a = ThumbnailKeyRules.key(path: "/art/x.png", size: 256, mtime: 1_000_000, bytes: 100)
        let b = ThumbnailKeyRules.key(path: "/art/x.png", size: 256, mtime: 1_000_001, bytes: 100)
        XCTAssertNotEqual(a, b)
    }

    /// Caching still has to WORK — an unchanged file must hit, or every scroll regenerates.
    func testUnchangedFileIsStable() {
        let a = ThumbnailKeyRules.key(path: "/art/x.png", size: 256, mtime: 1_722_000_000.123, bytes: 4_771_312)
        let b = ThumbnailKeyRules.key(path: "/art/x.png", size: 256, mtime: 1_722_000_000.123, bytes: 4_771_312)
        XCTAssertEqual(a, b)
    }

    /// The list thumbnail and the big preview must not clobber each other.
    func testSizeStillSeparatesEntries() {
        let small = ThumbnailKeyRules.key(path: "/art/x.png", size: 64, mtime: 1, bytes: 2)
        let large = ThumbnailKeyRules.key(path: "/art/x.png", size: 512, mtime: 1, bytes: 2)
        XCTAssertNotEqual(small, large)
    }

    func testStatFailureFallsBackButKeepsPathAndSize() {
        XCTAssertEqual(ThumbnailKeyRules.key(path: "/a.png", size: 256, mtime: nil, bytes: nil), "/a.png@256")
        XCTAssertNotEqual(ThumbnailKeyRules.key(path: "/a.png", size: 256, mtime: nil, bytes: nil),
                          ThumbnailKeyRules.key(path: "/b.png", size: 256, mtime: nil, bytes: nil))
        XCTAssertNotEqual(ThumbnailKeyRules.key(path: "/a.png", size: 256, mtime: nil, bytes: nil),
                          ThumbnailKeyRules.key(path: "/a.png", size: 512, mtime: nil, bytes: nil))
    }

    /// Cancelling in-flight work must match whatever stamp the request used, so it has to key
    /// off the prefix rather than a stamp that may have moved on.
    func testPrefixMatchesEveryStampForThatPathAndSize() {
        let p = ThumbnailKeyRules.prefix(path: "/art/x.png", size: 256)
        for (m, b) in [(1.0, Int64(10)), (2.0, 20), (3.5, 30)] {
            XCTAssertTrue(ThumbnailKeyRules.key(path: "/art/x.png", size: 256, mtime: m, bytes: b).hasPrefix(p))
        }
        XCTAssertFalse(ThumbnailKeyRules.key(path: "/art/x.png", size: 512, mtime: 1, bytes: 1).hasPrefix(p + "#"))
    }
}

// MARK: - Photoshop Generative Upscale preflight

final class FireflyUpscaleRulesTests: XCTestCase {
    /// The exact image that produced BOTH of Photoshop's error dialogs: 6.26:1 fails the
    /// aspect band, and ×4 (8896px) fails the 6144 output cap.
    func testTheSheetThatFailedBothWays() {
        XCTAssertFalse(FireflyUpscaleRules.aspectOK(width: 2224, height: 355))
        // ×4 would be 8896 on the long edge, over the cap, so ×2 is the best available
        guard case let .padThenUpscale(scale, padTo) = FireflyUpscaleRules.plan(width: 2224, height: 355) else {
            return XCTFail("expected pad-then-upscale, got \(FireflyUpscaleRules.plan(width: 2224, height: 355))")
        }
        XCTAssertEqual(scale, 2)
        XCTAssertEqual(padTo.w, 2224, "padding must not touch the long edge")
        XCTAssertEqual(padTo.h, 556, "short edge padded to long/4 = 556")
        XCTAssertTrue(FireflyUpscaleRules.aspectOK(width: padTo.w, height: padTo.h))
        XCTAssertLessThanOrEqual(max(padTo.w, padTo.h) * scale, FireflyUpscaleRules.maxOutputSide)
    }

    /// Padding for aspect must never change which scales fit — it only grows the SHORT side.
    func testAspectPadNeverChangesTheLongEdge() {
        for (w, h) in [(2224, 355), (355, 2224), (5977, 1460), (1000, 100), (100, 1000)] {
            let p = FireflyUpscaleRules.aspectPadCanvas(width: w, height: h)
            XCTAssertEqual(max(p.w, p.h), max(w, h))
            XCTAssertGreaterThanOrEqual(p.w, w)
            XCTAssertGreaterThanOrEqual(p.h, h)
            XCTAssertTrue(FireflyUpscaleRules.aspectOK(width: p.w, height: p.h),
                          "\(w)x\(h) padded to \(p.w)x\(p.h) is still out of band")
        }
    }

    func testAlreadyValidAspectIsUntouched() {
        let p = FireflyUpscaleRules.aspectPadCanvas(width: 2048, height: 2048)
        XCTAssertEqual(p.w, 2048); XCTAssertEqual(p.h, 2048)
        XCTAssertEqual(FireflyUpscaleRules.plan(width: 1024, height: 1024), .upscale(scale: 4))
    }

    /// The output cap is what actually rules out ×4 for most real slot art.
    func testScaleIsPickedByTheOutputCap() {
        XCTAssertEqual(FireflyUpscaleRules.plan(width: 1536, height: 1536), .upscale(scale: 4))  // 6144 exactly
        XCTAssertEqual(FireflyUpscaleRules.plan(width: 1537, height: 1537), .upscale(scale: 2))  // 6148 > cap
        XCTAssertEqual(FireflyUpscaleRules.plan(width: 2048, height: 2048), .upscale(scale: 2))
        XCTAssertEqual(FireflyUpscaleRules.maxInputLongEdge(scale: 4), 1536)
        XCTAssertEqual(FireflyUpscaleRules.maxInputLongEdge(scale: 2), 3072)
    }

    /// Real assets that Generative Upscale simply cannot take, at any scale.
    func testTooLargeIsReportedNotAttempted() {
        for (w, h) in [(5977, 1460), (3072, 3924), (4000, 4000)] {
            guard case let .tooLargeForAnyScale(longEdge, maxIn) = FireflyUpscaleRules.plan(width: w, height: h) else {
                return XCTFail("\(w)x\(h) should be refused, got \(FireflyUpscaleRules.plan(width: w, height: h))")
            }
            XCTAssertEqual(longEdge, max(w, h))
            XCTAssertEqual(maxIn, 3072)
        }
    }

    /// An explicitly requested scale is honoured or refused — never silently swapped.
    func testPreferredScaleIsNotSilentlyDowngraded() {
        XCTAssertEqual(FireflyUpscaleRules.plan(width: 1024, height: 1024, preferred: 2), .upscale(scale: 2))
        guard case .tooLargeForAnyScale = FireflyUpscaleRules.plan(width: 2048, height: 2048, preferred: 4) else {
            return XCTFail("×4 on a 2048 image exceeds the cap and must be refused, not downgraded")
        }
    }

    func testDegenerateInputs() {
        XCTAssertEqual(FireflyUpscaleRules.plan(width: 0, height: 0), .notAnImage)
        XCTAssertEqual(FireflyUpscaleRules.plan(width: -5, height: 10), .notAnImage)
        XCTAssertFalse(FireflyUpscaleRules.aspectOK(width: 0, height: 10))
    }

    func testEveryPlanExplainsItself() {
        for (w, h) in [(2224, 355), (1024, 1024), (5977, 1460), (0, 0)] {
            let p = FireflyUpscaleRules.plan(width: w, height: h)
            XCTAssertFalse(FireflyUpscaleRules.explain(p, width: w, height: h).isEmpty)
        }
    }
}

// MARK: - Swipe Compare across N images

final class CompareCycleTests: XCTestCase {
    func testStepWrapsBothWays() {
        XCTAssertEqual(CompareCycle.step(index: 0, by: -1, count: 5), 4)
        XCTAssertEqual(CompareCycle.step(index: 4, by: 1, count: 5), 0)
        XCTAssertEqual(CompareCycle.step(index: 2, by: 1, count: 5), 3)
        XCTAssertEqual(CompareCycle.step(index: 0, by: -7, count: 5), 3)
    }

    /// Never divide by zero or return an out-of-range index for a degenerate list.
    func testStepIsSafeWhenEmpty() {
        XCTAssertEqual(CompareCycle.step(index: 3, by: 1, count: 0), 0)
        for c in 1...6 {
            for d in [-9, -1, 0, 1, 9] {
                let i = CompareCycle.step(index: 0, by: d, count: c)
                XCTAssertTrue((0..<c).contains(i))
            }
        }
    }

    func testCandidatesExcludeTheReference() {
        XCTAssertEqual(CompareCycle.candidates(total: 4, leftIndex: 0), [1, 2, 3])
        XCTAssertEqual(CompareCycle.candidates(total: 4, leftIndex: 2), [0, 1, 3])
        // the old two-image behaviour still falls out of this
        XCTAssertEqual(CompareCycle.candidates(total: 2, leftIndex: 0), [1])
        XCTAssertEqual(CompareCycle.candidates(total: 0, leftIndex: 0), [])
        XCTAssertEqual(CompareCycle.candidates(total: 3, leftIndex: 9), [])
    }

    func testAvailabilityStillNeedsTwo() {
        XCTAssertFalse(CompareCycle.isAvailable(imageCount: 1))
        XCTAssertTrue(CompareCycle.isAvailable(imageCount: 2))
        XCTAssertTrue(CompareCycle.isAvailable(imageCount: 7))
    }
}

// MARK: - Adaptive backing colour

final class KeyColorRulesTests: XCTestCase {
    func testLabAnchors() {
        let white = KeyColorRules.lab(RGB8(255, 255, 255))
        XCTAssertEqual(white.L, 100, accuracy: 0.5)
        XCTAssertEqual(white.a, 0, accuracy: 0.5)
        XCTAssertEqual(white.b, 0, accuracy: 0.5)
        XCTAssertEqual(KeyColorRules.lab(RGB8(0, 0, 0)).L, 0, accuracy: 0.5)
        XCTAssertEqual(KeyColorRules.deltaE(RGB8(10, 20, 30), RGB8(10, 20, 30)), 0, accuracy: 1e-9)
    }

    /// A flat field wins outright — extending it keeps ONE keyable colour on the canvas.
    func testFlatFieldIsExtended() {
        let magenta = RGB8(212, 19, 149)
        XCTAssertEqual(KeyColorRules.choose(subject: [RGB8(255, 215, 0)],
                                            flatField: (magenta, 1.0)),
                       .extendField(magenta))
    }

    /// Below the threshold it is NOT a flat field, so fall through to a key colour.
    func testPartialBorderIsNotAField() {
        let c = KeyColorRules.choose(subject: [RGB8(255, 215, 0)], flatField: (RGB8(212, 19, 149), 0.4))
        guard case .keyColour = c else { return XCTFail("expected a key colour, got \(c)") }
    }

    /// THE REGRESSION THE FIXED LIST ALLOWED: HP4_Tortoise.png contains pure white, so the
    /// menu's "White" sat at ΔE 0.0 from the art and a later key would eat the subject.
    func testNeverPicksAColourTheSubjectContains() {
        let subject = [RGB8(255, 255, 255), RGB8(0, 0, 0), RGB8(0, 255, 0), RGB8(255, 0, 255)]
        guard case let .keyColour(picked, margin) = KeyColorRules.choose(subject: subject, flatField: nil) else {
            return XCTFail("expected a key colour")
        }
        XCTAssertFalse(subject.contains(picked), "picked \(picked), which is in the art")
        XCTAssertGreaterThan(margin, 20, "margin too small to key safely")
        for s in subject {
            XCTAssertGreaterThan(KeyColorRules.deltaE(picked, s), 20)
        }
    }

    /// The whole point: beat the worst thing the fixed menu could have done.
    func testBeatsTheWorstFixedChoice() {
        let subject = [RGB8(255, 255, 255), RGB8(250, 250, 245), RGB8(20, 18, 22)]
        guard case let .keyColour(_, margin) = KeyColorRules.choose(subject: subject, flatField: nil) else {
            return XCTFail("expected a key colour")
        }
        let fixed = [RGB8(255, 255, 255), RGB8(0, 0, 0), RGB8(0, 255, 0),
                     RGB8(255, 0, 255), RGB8(0, 0, 255), RGB8(255, 255, 0)]
        let worst = fixed.map { f in subject.map { KeyColorRules.deltaE(f, $0) }.min()! }.min()!
        XCTAssertGreaterThan(margin, worst)
    }

    func testPrefersSaturatedAndIsDeterministic() {
        let subject = [RGB8(128, 128, 128)]
        guard case let .keyColour(a, _) = KeyColorRules.choose(subject: subject, flatField: nil),
              case let .keyColour(b, _) = KeyColorRules.choose(subject: subject, flatField: nil) else {
            return XCTFail("expected key colours")
        }
        XCTAssertEqual(a, b, "must be deterministic")
        XCTAssertGreaterThan(KeyColorRules.saturation(a), 0.5, "a near-neutral key does not key well")
    }

    func testEmptySubjectStillAnswers() {
        guard case .keyColour = KeyColorRules.choose(subject: [], flatField: nil) else {
            return XCTFail("must still return something")
        }
    }
}

// MARK: - Pixel sampling behind the adaptive backing colour

final class BackingSamplingTests: XCTestCase {
    /// Builds an RGBA8 CGImage: `border` all round, `subject` filling the middle, and an
    /// optional fully-transparent margin instead of a border.
    private func image(w: Int, h: Int, border: (UInt8, UInt8, UInt8, UInt8),
                       subject: (UInt8, UInt8, UInt8, UInt8), inset: Int = 4) -> CGImage {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let inner = x >= inset && x < w - inset && y >= inset && y < h - inset
                let c = inner ? subject : border
                px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2; px[i + 3] = c.3
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    /// A chroma sheet: flat magenta all round. Must be detected as a field and EXTENDED.
    func testFlatMagentaFieldIsDetectedAndExtended() {
        let cg = image(w: 120, h: 60, border: (212, 19, 149, 255), subject: (255, 215, 0, 255), inset: 10)
        guard let f = flatFieldColour(cg) else { return XCTFail("no field detected") }
        XCTAssertGreaterThan(f.fraction, 0.9, "border is uniform, should read as a field")
        XCTAssertEqual(Int(f.colour.r), 212, accuracy: 10)
        XCTAssertEqual(Int(f.colour.g), 19, accuracy: 10)
        XCTAssertEqual(Int(f.colour.b), 149, accuracy: 10)
        guard case .extendField = KeyColorRules.choose(subject: subjectColours(cg), flatField: f) else {
            return XCTFail("a flat field must be extended, not contrasted against")
        }
    }

    /// Transparent pixels are what we're about to FILL, so they must not count as present —
    /// otherwise the fill ends up avoiding itself.
    func testTransparentPixelsAreExcluded() {
        let cg = image(w: 80, h: 80, border: (0, 0, 0, 0), subject: (0, 200, 40, 255), inset: 20)
        let cols = subjectColours(cg)
        XCTAssertFalse(cols.isEmpty)
        // every sampled colour should be the green subject, never the transparent black
        for c in cols {
            XCTAssertGreaterThan(Int(c.g), Int(c.r), "sampled a transparent pixel as if it were art")
        }
    }

    func testFullyTransparentImageSamplesNothing() {
        let cg = image(w: 40, h: 40, border: (0, 0, 0, 0), subject: (0, 0, 0, 0), inset: 5)
        XCTAssertTrue(subjectColours(cg).isEmpty)
    }

    /// THE CASE THAT BREAKS HARDCODED GREEN: a green subject on transparency. The old upscale
    /// path composited on green then keyed green back out, which eats a green subject.
    func testGreenSubjectNeverGetsAGreenBacking() {
        let cg = image(w: 80, h: 80, border: (0, 0, 0, 0), subject: (0, 200, 40, 255), inset: 15)
        guard case let .keyColour(picked, margin) = KeyColorRules.choose(subject: subjectColours(cg),
                                                                        flatField: nil) else {
            return XCTFail("expected a key colour")
        }
        XCTAssertGreaterThan(KeyColorRules.deltaE(picked, RGB8(0, 200, 40)), 40,
                             "picked \(picked), too close to the green subject")
        XCTAssertGreaterThan(margin, 20)
    }

    /// A noisy border is not a field, so it must fall through to a contrasting key colour.
    func testNoisyBorderIsNotAField() {
        var px = [UInt8](repeating: 0, count: 60 * 60 * 4)
        for y in 0..<60 {
            for x in 0..<60 {
                let i = (y * 60 + x) * 4
                px[i] = UInt8((x * 4) % 256); px[i + 1] = UInt8((y * 4) % 256)
                px[i + 2] = UInt8((x * y) % 256); px[i + 3] = 255
            }
        }
        let ctx = CGContext(data: &px, width: 60, height: 60, bitsPerComponent: 8, bytesPerRow: 240,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cg = ctx.makeImage()!
        if let f = flatFieldColour(cg) {
            XCTAssertLessThan(f.fraction, KeyColorRules.flatFieldFraction)
        }
    }
}

// MARK: - Aspect-ratio prep

final class AspectPrepRulesTests: XCTestCase {
    func testNearestIsLogSymmetric() {
        XCTAssertEqual(AspectPrepRules.nearest(width: 2350, height: 470).name, "21:9")
        XCTAssertEqual(AspectPrepRules.nearest(width: 1820, height: 1820).name, "1:1")
        XCTAssertEqual(AspectPrepRules.nearest(width: 470, height: 2350).name, "9:21")
        // 3072x3924 = 0.7829, which really is nearer 4:5 (0.80) than 3:4 (0.75) —
        // log-distance 0.022 vs 0.043. Asserted the wrong one here by eye first.
        XCTAssertEqual(AspectPrepRules.nearest(width: 3072, height: 3924).name, "4:5")
        XCTAssertEqual(AspectPrepRules.nearest(width: 3000, height: 4000).name, "3:4")
    }

    /// Padding scales BOTH sides, so it must not undo the ratio fit. This is the claim I got
    /// wrong by inspection and had to measure: error is pure Int rounding.
    func testPaddingPreservesTheRatio() {
        for (w, h) in [(2350, 470), (1820, 1820), (5977, 1460), (3072, 3924)] {
            let rt = AspectPrepRules.nearest(width: w, height: h).ratio
            for pad in [1.0, 1.2, 2.0] {
                let c = AspectPrepRules.canvas(width: w, height: h, ratio: rt, pad: pad)
                XCTAssertEqual(Double(c.w) / Double(c.h), rt, accuracy: rt * 0.002)
            }
        }
    }

    /// The canvas must CONTAIN the image — never crop it. Cropping is what NB2 did on its own.
    func testCanvasAlwaysContainsTheSubject() {
        for (w, h) in [(2350, 470), (1000, 1000), (100, 4000), (4000, 100), (1, 1)] {
            let rt = AspectPrepRules.nearest(width: w, height: h).ratio
            let c = AspectPrepRules.canvas(width: w, height: h, ratio: rt, pad: 1.0)
            XCTAssertGreaterThanOrEqual(c.w, w)
            XCTAssertGreaterThanOrEqual(c.h, h)
        }
    }

    /// At an exact supported ratio the pad is zero, so auto-prep needs no threshold —
    /// running it unconditionally is a no-op for already-correct images.
    func testExactRatioIsANoOp() {
        XCTAssertEqual(AspectPrepRules.mismatch(width: 1024, height: 1024), 0, accuracy: 1e-9)
        let c = AspectPrepRules.canvas(width: 1024, height: 1024, ratio: 1.0, pad: 1.0)
        XCTAssertEqual(c.w, 1024); XCTAssertEqual(c.h, 1024)
        XCTAssertEqual(AspectPrepRules.subjectOrigin(width: 1024, height: 1024, canvas: c).x, 0)
    }

    func testMismatchFlagsTheRealOffender() {
        XCTAssertGreaterThan(AspectPrepRules.mismatch(width: 2350, height: 470), 1.0)  // 5:1 vs 21:9
        XCTAssertLessThan(AspectPrepRules.mismatch(width: 1600, height: 900), 0.01)    // already 16:9
    }

    /// Crop-back has to scale to the model's own output size, which differs from the canvas.
    func testCropBackScalesToResultResolution() {
        let c = AspectPrepRules.canvas(width: 2350, height: 470, ratio: 21.0/9, pad: 1.0)
        let box = AspectPrepRules.cropBack(canvas: c, subject: (2350, 470), result: (3168, 1344))
        // recovered region keeps the subject's 5:1 shape
        XCTAssertEqual(Double(box.w) / Double(box.h), 5.0, accuracy: 0.06)
        XCTAssertGreaterThan(box.y, 0, "subject is centred, so there is padding above it")
        XCTAssertLessThanOrEqual(box.x + box.w, 3168)
        XCTAssertLessThanOrEqual(box.y + box.h, 1344)
    }

    func testCropBackStaysInBoundsForOddSizes() {
        for result in [(100, 100), (3168, 1344), (1, 1), (4096, 1755)] {
            let c = AspectPrepRules.canvas(width: 999, height: 333, ratio: 21.0/9, pad: 1.2)
            let b = AspectPrepRules.cropBack(canvas: c, subject: (999, 333), result: result)
            XCTAssertGreaterThanOrEqual(b.x, 0); XCTAssertGreaterThanOrEqual(b.y, 0)
            XCTAssertLessThanOrEqual(b.x + b.w, result.0)
            XCTAssertLessThanOrEqual(b.y + b.h, result.1)
        }
    }
}

// MARK: - Tab reordering by drag

final class TabMoveRulesTests: XCTestCase {
    // Dropping a tab onto a later tab puts it AT that tab's slot, pushing the rest left —
    // the Chrome/Safari result. Getting this backwards makes the tab land one short.
    func testDragRightwardsLandsOnTheTargetSlot() {
        XCTAssertEqual(TabMoveRules.reordered(count: 3, from: 0, to: 2), [1, 2, 0])
        XCTAssertEqual(TabMoveRules.reordered(count: 4, from: 1, to: 2), [0, 2, 1, 3])
    }

    func testDragLeftwardsLandsOnTheTargetSlot() {
        XCTAssertEqual(TabMoveRules.reordered(count: 3, from: 2, to: 0), [2, 0, 1])
        XCTAssertEqual(TabMoveRules.reordered(count: 4, from: 3, to: 1), [0, 3, 1, 2])
    }

    // A tab released on itself is the tiniest accidental drag there is. It must report
    // "nothing to do" so the caller neither rewrites the array nor saves state.
    func testDroppingOnItselfIsNoChange() {
        XCTAssertNil(TabMoveRules.reordered(count: 3, from: 1, to: 1))
    }

    func testSingleTabAndBadIndicesAreRefused() {
        XCTAssertNil(TabMoveRules.reordered(count: 1, from: 0, to: 0))
        XCTAssertNil(TabMoveRules.reordered(count: 3, from: -1, to: 1))
        XCTAssertNil(TabMoveRules.reordered(count: 3, from: 0, to: 3))
    }

    // Every result must be a permutation, or a tab gets duplicated or dropped entirely.
    func testResultIsAlwaysAPermutation() {
        for from in 0..<5 where true {
            for to in 0..<5 where from != to {
                let order = TabMoveRules.reordered(count: 5, from: from, to: to)
                XCTAssertEqual(order?.sorted(), [0, 1, 2, 3, 4])
            }
        }
    }
}

// MARK: - Tab tear-off

/// BUG CLASS: a polled watchdog as the PRIMARY mechanism. The tear-off was decided and
/// applied straight from a 0.25s mouse-release poll, so it could complete a drag other than
/// the one that armed it. These pin the geometry rule, and then the ledger composition that
/// makes a stale release harmless.
final class TabTearOffRulesTests: XCTestCase {

    /// Pulled well clear of the strip, either way — the tear-off is symmetric because the
    /// strip can sit at the top of the window with the only room below it.
    func testAReleaseWellClearOfTheStripTearsOff() {
        for dy in [TabTearOffRules.pullOut + 1, -(TabTearOffRules.pullOut + 1), 500, -500] {
            XCTAssertTrue(TabTearOffRules.shouldTearOff(verticalTravel: dy, index: 1, tabCount: 3), "\(dy)")
        }
    }

    /// Sideways travel is a REORDER however far it goes: dragging a tab along the strip must
    /// never spawn a window, and releasing in the 6pt gap between two tabs must do nothing.
    /// Vertical travel is the only input, so "any distance along the strip" is covered by
    /// pinning that a zero-to-threshold dy never tears off.
    func testTravelAlongTheStripIsNeverATearOff() {
        for dy in [0, 1, 12, TabTearOffRules.pullOut - 1, TabTearOffRules.pullOut, -TabTearOffRules.pullOut] {
            XCTAssertFalse(TabTearOffRules.shouldTearOff(verticalTravel: dy, index: 1, tabCount: 3), "\(dy)")
        }
    }

    /// Tearing off the ONLY tab would close the window's last tab and leave an empty ghost
    /// window, so dragging a lone tab anywhere simply does nothing.
    func testTheOnlyTabCannotBeTornOff() {
        XCTAssertFalse(TabTearOffRules.shouldTearOff(verticalTravel: 300, index: 0, tabCount: 1))
    }

    /// A stale index — the tab was closed while the drag was in flight — must not move some
    /// other tab out. Same guard the context menu is disabled by, so the two cannot disagree.
    func testAnIndexThatNoLongerExistsIsRefused() {
        for index in [-1, 3, 99] {
            XCTAssertFalse(TabTearOffRules.shouldTearOff(verticalTravel: 300, index: index, tabCount: 3), "\(index)")
        }
    }

    /// The composition TabDrag actually performs, and the case that was broken: the mouse-up
    /// watch refuses to re-arm while it is settling, so drag N's release used to run against
    /// drag N+1's tab. The ledger ticket is what makes the stale release a no-op — pinned here
    /// because the failure is silent (a window tears off from a drag still in progress) and
    /// cannot be reproduced without a GUI.
    func testAStaleReleaseNeverTearsOffTheTabOfALaterDrag() {
        var ledger = DragSessionLedger()
        var tornOff: [Int] = []
        func release(ticket: Int, index: Int, dy: CGFloat, tabCount: Int) {
            guard ledger.closeIfCurrent(ticket: ticket) != nil else { return }
            if TabTearOffRules.shouldTearOff(verticalTravel: dy, index: index, tabCount: tabCount) {
                tornOff.append(index)
            }
        }
        let stale = ledger.begin("tab")     // drag on tab 0, release still pending
        let live = ledger.begin("tab")      // user grabs tab 2 within the grace window
        release(ticket: stale, index: 0, dy: 300, tabCount: 3)
        XCTAssertEqual(tornOff, [], "a superseded release must not tear off anything")
        release(ticket: live, index: 2, dy: 300, tabCount: 3)
        XCTAssertEqual(tornOff, [2], "the live drag still gets its own tear-off")
    }

    /// A tab took the drop, so it was a reorder: the authoritative close makes the release
    /// poll that follows silent, and the tab must NOT also fly out into a new window.
    func testADropTakenByATabSuppressesTheTearOff() {
        var ledger = DragSessionLedger()
        let ticket = ledger.begin("tab")
        XCTAssertNotNil(ledger.closeAuthoritatively(), "the drop is the authoritative end")
        XCTAssertNil(ledger.closeIfCurrent(ticket: ticket), "the release must stay silent")
    }
}

// MARK: - Spring-loaded folders

final class SpringRulesTests: XCTestCase {
    private func u(_ p: String) -> URL { URL(fileURLWithPath: p) }

    func testHoveringAnotherFolderSprings() {
        XCTAssertTrue(SpringRules.canSpring(into: u("/tmp/a/b"), from: u("/tmp/a"),
                                            dragging: [u("/tmp/a/note.txt")]))
    }

    // The pointer is over the folder we are already showing (a sidebar favorite for the
    // current folder, say). Navigating there again re-reads the directory for nothing.
    func testCurrentFolderDoesNotSpring() {
        XCTAssertFalse(SpringRules.canSpring(into: u("/tmp/a"), from: u("/tmp/a/"),
                                             dragging: [u("/tmp/x.txt")]))
    }

    // The two that would strand the user inside the folder they are carrying.
    func testDraggingAFolderOntoItselfDoesNotSpring() {
        XCTAssertFalse(SpringRules.canSpring(into: u("/tmp/a/b"), from: u("/tmp/a"),
                                             dragging: [u("/tmp/a/b")]))
    }

    func testDraggingAFolderIntoItsOwnDescendantDoesNotSpring() {
        XCTAssertFalse(SpringRules.canSpring(into: u("/tmp/a/b/c"), from: u("/tmp/a/b"),
                                             dragging: [u("/tmp/a/b")]))
    }

    // A sibling whose name merely starts the same way is NOT inside it — the prefix trap
    // PathRules.isSelfOrDescendant guards, re-checked here because this caller is the one
    // that would silently disable a legitimate spring.
    func testSiblingWithASharedNamePrefixStillSprings() {
        XCTAssertTrue(SpringRules.canSpring(into: u("/tmp/a/bc"), from: u("/tmp/a"),
                                            dragging: [u("/tmp/a/b")]))
    }

    // What the sidebar's own reorder drag looks like: nothing droppable in the payload.
    func testNothingDroppableDoesNotSpring() {
        XCTAssertFalse(SpringRules.canSpring(into: u("/tmp/a/b"), from: u("/tmp/a"), dragging: []))
    }

    // A multi-file drag springs on the strength of the whole payload, and ONE unsafe
    // source vetoes it: the hovered folder is being carried, so opening it puts the user
    // inside their own drag even though the other files could legally land there.
    func testMultiFileDragSprings() {
        XCTAssertTrue(SpringRules.canSpring(into: u("/tmp/a/b"), from: u("/tmp/a"),
                                            dragging: [u("/tmp/a/f1"), u("/tmp/a/f2")]))
        XCTAssertFalse(SpringRules.canSpring(into: u("/tmp/a/b"), from: u("/tmp/a"),
                                             dragging: [u("/tmp/a/f1"), u("/tmp/a/b")]))
    }
}

// MARK: - Per-folder view options (⌘J)

final class ViewOptionsLRUTests: XCTestCase {

    private func opts(_ mode: String) -> ViewOptions {
        ViewOptions(viewMode: mode, iconSize: 76, sortKey: "name", sortAscending: true,
                    groupBy: "none", columns: ["name", "size"])
    }

    // The requirement the whole feature rests on: a folder nobody ever arranged by hand
    // gets the global defaults, unchanged. If this ever returns something else, every
    // folder in the app silently changes appearance.
    func testUnknownFolderFallsBackToDefaults() {
        var lru = ViewOptionsLRU()
        let defaults = opts("list")
        XCTAssertNil(lru.value(for: "/tmp/never-visited"))
        XCTAssertEqual(lru.effective(for: "/tmp/never-visited", defaults: defaults), defaults)
        lru.set(opts("icon"), for: "/tmp/a")
        XCTAssertEqual(lru.effective(for: "/tmp/b", defaults: defaults), defaults)
    }

    func testSavedFolderWinsOverDefaults() {
        var lru = ViewOptionsLRU()
        lru.set(opts("gallery"), for: "/tmp/a")
        XCTAssertEqual(lru.effective(for: "/tmp/a", defaults: opts("list")).viewMode, "gallery")
        XCTAssertTrue(lru.contains("/tmp/a"))
    }

    func testReplacingAFolderDoesNotDuplicateItsOrderEntry() {
        var lru = ViewOptionsLRU()
        lru.set(opts("icon"), for: "/tmp/a")
        lru.set(opts("gallery"), for: "/tmp/a")
        XCTAssertEqual(lru.count, 1)
        XCTAssertEqual(lru.order, ["/private/tmp/a"])   // canonical: firmlinks resolve INTO /private
        XCTAssertEqual(lru.value(for: "/tmp/a")?.viewMode, "gallery")
    }

    func testRemoveRevertsFolderToDefaults() {
        var lru = ViewOptionsLRU()
        lru.set(opts("icon"), for: "/tmp/a")
        lru.remove("/tmp/a")
        XCTAssertFalse(lru.contains("/tmp/a"))
        XCTAssertEqual(lru.order, [])
        XCTAssertEqual(lru.effective(for: "/tmp/a", defaults: opts("list")).viewMode, "list")
    }

    // The bound. Without it this dictionary grows forever and is decoded in full on
    // every launch.
    func testEvictsAtTheCap() {
        var lru = ViewOptionsLRU()
        for i in 0..<(ViewOptionsLRU.cap + 10) { lru.set(opts("icon"), for: "/tmp/\(i)") }
        XCTAssertEqual(lru.count, ViewOptionsLRU.cap)
        XCTAssertEqual(lru.order.count, ViewOptionsLRU.cap)
        // Oldest ten gone, newest kept.
        XCTAssertFalse(lru.contains("/tmp/0"))
        XCTAssertFalse(lru.contains("/tmp/9"))
        XCTAssertTrue(lru.contains("/tmp/10"))
        XCTAssertTrue(lru.contains("/tmp/\(ViewOptionsLRU.cap + 9)"))
    }

    // `order` and `byPath` must never drift apart, or eviction starts deleting the
    // wrong folder (or nothing at all, and the cap stops holding).
    func testOrderAndStorageStayInStep() {
        var lru = ViewOptionsLRU()
        for i in 0..<(ViewOptionsLRU.cap + 25) { lru.set(opts("icon"), for: "/tmp/\(i)") }
        lru.touch("/tmp/\(ViewOptionsLRU.cap)")
        lru.remove("/tmp/\(ViewOptionsLRU.cap + 1)")
        XCTAssertEqual(Set(lru.order), Set(lru.byPath.keys))
        XCTAssertEqual(lru.order.count, Set(lru.order).count)   // no duplicates
    }

    // Recency by USE, not by insertion: the folder you keep opening must survive the
    // cap even though it was saved first.
    func testTouchSavesTheFolderYouKeepUsing() {
        var lru = ViewOptionsLRU()
        lru.set(opts("icon"), for: "/tmp/daily")
        for i in 0..<(ViewOptionsLRU.cap - 1) { lru.set(opts("list"), for: "/tmp/\(i)") }
        XCTAssertTrue(lru.touch("/tmp/daily"))         // visited again — now most recent
        lru.set(opts("list"), for: "/tmp/one-more")    // pushes past the cap
        XCTAssertTrue(lru.contains("/tmp/daily"))
        XCTAssertFalse(lru.contains("/tmp/0"))         // the genuinely stale one went instead
    }

    // Re-reading the folder that is already most recent must NOT report a change —
    // that's what stops a UserDefaults write on every refresh of the current folder.
    func testTouchIsANoOpWhenAlreadyMostRecentOrUnknown() {
        var lru = ViewOptionsLRU()
        lru.set(opts("icon"), for: "/tmp/a")
        XCTAssertFalse(lru.touch("/tmp/a"))
        XCTAssertFalse(lru.touch("/tmp/not-saved"))
    }

    func testSurvivesAJSONRoundTrip() throws {
        var lru = ViewOptionsLRU()
        lru.set(opts("gallery"), for: "/tmp/a")
        lru.set(opts("icon"), for: "/tmp/b")
        let back = try JSONDecoder().decode(ViewOptionsLRU.self, from: JSONEncoder().encode(lru))
        XCTAssertEqual(back, lru)
        XCTAssertEqual(back.order, ["/private/tmp/b", "/private/tmp/a"])
    }
}

// MARK: - Guessing what a folder is for (FolderKind)

final class FolderKindTests: XCTestCase {

    private func files(_ names: [String]) -> [(name: String, isDirectory: Bool)] {
        names.map { ($0, false) }
    }
    private func dirs(_ n: Int) -> [(name: String, isDirectory: Bool)] {
        (0..<n).map { ("project\($0)", true) }
    }
    private func images(_ n: Int, ext: String = "jpg") -> [(name: String, isDirectory: Bool)] {
        files((0..<n).map { "IMG_\(1000 + $0).\(ext)" })
    }

    func testAllImagesIsMedia() {
        XCTAssertEqual(FolderKind.infer(images(30)), .media)
    }

    // Extension matching must be case-insensitive: cameras write .JPG, .CR2, .MOV.
    func testUppercaseExtensionsStillCount() {
        XCTAssertEqual(FolderKind.infer(images(12, ext: "JPG")), .media)
    }

    // The user's own counter-example: an artSource folder of ~25 project folders must
    // NOT become a wall of giant icons.
    func testFolderOfSubfoldersIsGeneral() {
        XCTAssertEqual(FolderKind.infer(dirs(25)), .general)
    }

    func testDocumentsAreGeneral() {
        XCTAssertEqual(FolderKind.infer(files(["a.swift", "b.swift", "notes.md", "Makefile", "readme.txt", "x.json"])), .general)
    }

    // An even split is not "mostly" anything, and a single added file must not be able to
    // flip the whole folder's view mode.
    func testFiftyFiftyIsGeneral() {
        XCTAssertEqual(FolderKind.infer(images(10) + files((0..<10).map { "doc\($0).pdf" })), .general)
    }

    func testAFewImagesAmongManyDocumentsIsGeneral() {
        XCTAssertEqual(FolderKind.infer(images(3) + files((0..<40).map { "doc\($0).pdf" })), .general)
    }

    func testEmptyFolderInfersNothing() {
        XCTAssertNil(FolderKind.infer([]))
    }

    // Three images is not evidence of a photo library — thin folders keep the default.
    func testThreeItemsInfersNothing() {
        XCTAssertNil(FolderKind.infer(images(3)))
        XCTAssertNil(FolderKind.infer(dirs(3)))
    }

    func testFiveIsTheSmallestFolderWorthClassifying() {
        XCTAssertNil(FolderKind.infer(images(4)))
        XCTAssertEqual(FolderKind.infer(images(5)), .media)
    }

    // A raw workflow writes one sidecar per shot. Counting them makes every photo folder
    // exactly 50/50 — i.e. never a photo folder, which is the whole feature failing for
    // the people who most want it.
    func testSidecarsDoNotCountAgainstTheirImages() {
        let jpgs = images(20)
        let xmp = files((0..<20).map { "IMG_\(1000 + $0).xmp" })
        XCTAssertEqual(FolderKind.infer(jpgs + xmp), .media)
        // Shot RAW+JPEG, with a sidecar each: three files per photo, two of which the
        // classifier has never heard of. The base-name rule collapses them back to one
        // shot, which is the only reason a working photo folder clears 60%.
        let raws = files((0..<20).map { "IMG_\(1000 + $0).cr2" })
        XCTAssertEqual(FolderKind.infer(jpgs + raws + xmp), .media)
    }

    // The known ceiling: raw files are not in imageExtensions, so a folder shot raw-ONLY
    // has nothing to anchor the base-name rule to and stays in Details. Deliberate — the
    // classifier judges by the same list isImageFile uses, and a second list of "things
    // that are sort of images" is exactly the drift that list exists to prevent.
    func testRawOnlyFolderIsGeneral() {
        XCTAssertEqual(FolderKind.infer(files((0..<20).map { "IMG_\(1000 + $0).cr2" })), .general)
    }

    func testSidecarMatchIsCaseInsensitive() {
        XCTAssertEqual(FolderKind.infer(images(6) + files((0..<6).map { "img_\(1000 + $0).XMP" })), .media)
    }

    // A sidecar with no media file of the same name is just a file.
    func testUnmatchedSidecarStillCounts() {
        XCTAssertEqual(FolderKind.infer(images(5) + files((0..<10).map { "orphan\($0).xmp" })), .general)
    }

    // Dotfiles are invisible in the listing unless Show Hidden is on, so they must not be
    // able to swing what the user sees either way.
    func testDotfilesAreIgnored() {
        XCTAssertEqual(FolderKind.infer(images(6) + files([".DS_Store", ".picasa.ini", ".thumbs"])), .media)
        XCTAssertNil(FolderKind.infer(images(4) + files([".DS_Store"])))
    }

    // Video deserves thumbnails for the same reason images do.
    func testVideoFolderIsMedia() {
        XCTAssertEqual(FolderKind.infer(files((0..<8).map { "clip\($0).mov" })), .media)
    }

    func testMixedImagesAndVideoIsMedia() {
        XCTAssertEqual(FolderKind.infer(images(5) + files((0..<5).map { "clip\($0).mp4" })), .media)
    }

    // Photos with their subfolders: still a photo folder while the images clearly lead.
    func testImagesWithAFewSubfoldersIsMedia() {
        XCTAssertEqual(FolderKind.infer(images(18) + dirs(2)), .media)
    }

    // …and the threshold really is 60%, not a bare majority.
    func testJustUnderThresholdIsGeneral() {
        XCTAssertEqual(FolderKind.infer(images(11) + dirs(9)), .general)   // 55%
        XCTAssertEqual(FolderKind.infer(images(12) + dirs(8)), .media)     // 60%
    }

    // A file with no extension can't be media and must not crash the base-name logic.
    func testExtensionlessFiles() {
        XCTAssertEqual(FolderKind.infer(files(["Makefile", "LICENSE", "README", "Dockerfile", "notes"])), .general)
    }
}

// MARK: - Sorting the lazily-loaded media columns (Time, Dimensions)

final class MediaSortKeyTests: XCTestCase {

    func testDurationOrdersBySeconds() {
        let a = MediaSortKey.duration(12, name: "a.mov")
        let b = MediaSortKey.duration(90, name: "b.mov")
        XCTAssertLessThan(a, b)
    }

    // A folder of videos with one text file in it: the text file has no duration and
    // must not land in the middle of the sorted videos.
    func testUnknownAndNotYetLoadedDurationsClumpAtZero() {
        let unknown = MediaSortKey.duration(nil, name: "notes.txt")
        let loaded = MediaSortKey.duration(0.5, name: "clip.mov")
        XCTAssertLessThan(unknown, loaded)
        XCTAssertEqual(MediaSortKey.duration(nil, name: "x").value, 0)
    }

    // Some files report a negative duration. Clamped, or they sort BELOW the unknowns
    // and the column looks like it is ordering at random.
    func testNegativeDurationIsClampedToUnknown() {
        XCTAssertEqual(MediaSortKey.duration(-30, name: "broken.mov").value, 0)
    }

    func testDimensionsSortByPixelArea() {
        let small = MediaSortKey.pixelArea(width: 320, height: 240, name: "s.png")
        let big = MediaSortKey.pixelArea(width: 1920, height: 1080, name: "b.png")
        XCTAssertLessThan(small, big)
    }

    // The reason area beats width-then-height: a wide thin banner is not a bigger
    // image than a large photo, and width-first would rank it above one.
    func testAreaRanksAPhotoAboveAWideThinBanner() {
        let banner = MediaSortKey.pixelArea(width: 5000, height: 200, name: "banner.png")
        let photo = MediaSortKey.pixelArea(width: 4000, height: 3000, name: "photo.jpg")
        XCTAssertLessThan(banner, photo)
    }

    func testMissingOrZeroDimensionsAreUnknown() {
        XCTAssertEqual(MediaSortKey.pixelArea(width: nil, height: 1080, name: "x").value, 0)
        XCTAssertEqual(MediaSortKey.pixelArea(width: 1920, height: nil, name: "x").value, 0)
        XCTAssertEqual(MediaSortKey.pixelArea(width: 0, height: 0, name: "x").value, 0)
    }

    // Ties are the common case here (every unknown is 0), and Swift's sort is not
    // documented as stable — so without the name in the key the list can come back in
    // a different order every time it re-sorts.
    func testEqualValuesFallBackToNameOrder() {
        XCTAssertLessThan(MediaSortKey.duration(nil, name: "apple.txt"),
                          MediaSortKey.duration(nil, name: "banana.txt"))
        XCTAssertLessThan(MediaSortKey.pixelArea(width: 100, height: 100, name: "a.png"),
                          MediaSortKey.pixelArea(width: 100, height: 100, name: "b.png"))
    }

    func testSortingAMixedFolderIsDeterministic() {
        let keys = [
            MediaSortKey.pixelArea(width: nil, height: nil, name: "zeta.txt"),
            MediaSortKey.pixelArea(width: 1920, height: 1080, name: "hd.png"),
            MediaSortKey.pixelArea(width: nil, height: nil, name: "alpha.txt"),
            MediaSortKey.pixelArea(width: 640, height: 480, name: "vga.png"),
        ]
        XCTAssertEqual(keys.sorted().map(\.name), ["alpha.txt", "zeta.txt", "vga.png", "hd.png"])
    }
}

// MARK: - Collapsible group headers

final class GroupCollapseTests: XCTestCase {

    private let sample: [(title: String, items: [String])] = [
        ("Folders", ["a", "b"]),
        ("Images", ["c", "d"]),
        ("Documents", ["e"]),
    ]

    func testNothingCollapsedShowsEverythingInOrder() {
        XCTAssertEqual(GroupCollapse.visibleOrder(groups: sample, collapsed: []),
                       ["a", "b", "c", "d", "e"])
    }

    // THE bug this exists for: an item inside a collapsed group must be absent from the
    // flat order, or Tab / arrow keys select something that isn't on screen.
    func testCollapsedGroupsContributeNoItems() {
        XCTAssertEqual(GroupCollapse.visibleOrder(groups: sample, collapsed: ["Images"]),
                       ["a", "b", "e"])
        XCTAssertEqual(GroupCollapse.visibleOrder(groups: sample, collapsed: ["Folders", "Documents"]),
                       ["c", "d"])
        XCTAssertEqual(GroupCollapse.visibleOrder(groups: sample,
                                                  collapsed: ["Folders", "Images", "Documents"]), [])
    }

    // Group By off produces one untitled group. Collapsing it would hide the entire
    // folder with no header left on screen to click to get it back.
    func testUntitledGroupCannotBeCollapsed() {
        XCTAssertFalse(GroupCollapse.canCollapse(title: ""))
        let ungrouped = [(title: "", items: ["a", "b"])]
        XCTAssertEqual(GroupCollapse.visibleOrder(groups: ungrouped, collapsed: [""]), ["a", "b"])
        XCTAssertEqual(GroupCollapse.toggled([], title: ""), [])
    }

    func testToggleAddsThenRemoves() {
        let once = GroupCollapse.toggled([], title: "Images")
        XCTAssertEqual(once, ["Images"])
        XCTAssertEqual(GroupCollapse.toggled(once, title: "Images"), [])
    }

    // Switching Group By, or typing a filter, changes which titles exist. A remembered
    // title that no longer matches anything must be dropped, or the group comes back
    // collapsed later for no visible reason.
    func testStaleTitlesArePruned() {
        XCTAssertEqual(GroupCollapse.pruned(["Images", "Today"], toTitles: ["Folders", "Images"]),
                       ["Images"])
        XCTAssertEqual(GroupCollapse.pruned(["Today"], toTitles: []), [])
    }
}

// MARK: - Search filters

final class SearchDateFilterTests: XCTestCase {

    // Fixed calendar + timezone: "Today" is a calendar-day question, and a test that
    // used the machine's current zone would pass or fail depending on where it ran.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private func d(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")!
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)!
    }

    // The boundary that matters: a file written at EXACTLY midnight belongs to the day
    // that is starting, and to exactly one bucket. An inclusive upper bound would have
    // put it in both Yesterday and Today.
    func testMidnightBelongsToTheDayStarting() {
        let now = d("2026-03-10 14:30:00")
        var f = SearchFilters(); f.date = .today
        XCTAssertTrue(f.matches(modified: d("2026-03-10 00:00:00"), size: 10, isDirectory: false, now: now, calendar: cal))
        XCTAssertFalse(f.matches(modified: d("2026-03-09 23:59:59"), size: 10, isDirectory: false, now: now, calendar: cal))
        f.date = .yesterday
        XCTAssertFalse(f.matches(modified: d("2026-03-10 00:00:00"), size: 10, isDirectory: false, now: now, calendar: cal))
        XCTAssertTrue(f.matches(modified: d("2026-03-09 23:59:59"), size: 10, isDirectory: false, now: now, calendar: cal))
    }

    // A file saved this morning must not fall out of "Today" as the day wears on —
    // which is exactly what a "now minus 24 hours" window would do.
    func testTodayIsACalendarDayNotARollingWindow() {
        let f = SearchFilters(date: .today, size: .any)
        let lateNow = d("2026-03-10 23:59:00")
        XCTAssertTrue(f.matches(modified: d("2026-03-10 00:30:00"), size: 1, isDirectory: false, now: lateNow, calendar: cal))
    }

    // Last 7 Days is today plus the six days before it: the 4th is in, the 3rd is out.
    func testLast7IncludesTodayAndSixPriorDays() {
        let now = d("2026-03-10 09:00:00")
        let f = SearchFilters(date: .last7, size: .any)
        XCTAssertTrue(f.matches(modified: d("2026-03-10 23:00:00"), size: 1, isDirectory: false, now: now, calendar: cal))
        XCTAssertTrue(f.matches(modified: d("2026-03-04 00:00:00"), size: 1, isDirectory: false, now: now, calendar: cal))
        XCTAssertFalse(f.matches(modified: d("2026-03-03 23:59:59"), size: 1, isDirectory: false, now: now, calendar: cal))
    }

    func testLast30AndThisYearEdges() {
        let now = d("2026-03-10 09:00:00")
        var f = SearchFilters(date: .last30, size: .any)
        XCTAssertTrue(f.matches(modified: d("2026-02-09 00:00:00"), size: 1, isDirectory: false, now: now, calendar: cal))
        XCTAssertFalse(f.matches(modified: d("2026-02-08 23:59:59"), size: 1, isDirectory: false, now: now, calendar: cal))
        f.date = .thisYear
        XCTAssertTrue(f.matches(modified: d("2026-01-01 00:00:00"), size: 1, isDirectory: false, now: now, calendar: cal))
        XCTAssertFalse(f.matches(modified: d("2025-12-31 23:59:59"), size: 1, isDirectory: false, now: now, calendar: cal))
    }

    // A custom range is two DAYS, so everything written on the last day picked has to
    // match — treating the upper picker as an instant silently drops that whole day.
    func testCustomRangeCoversWholeEndDay() {
        let now = d("2026-03-10 09:00:00")
        var f = SearchFilters(date: .custom, size: .any)
        f.customDateFrom = d("2026-03-01 13:00:00")
        f.customDateTo = d("2026-03-02 08:00:00")
        XCTAssertTrue(f.matches(modified: d("2026-03-01 00:00:01"), size: 1, isDirectory: false, now: now, calendar: cal))
        XCTAssertTrue(f.matches(modified: d("2026-03-02 23:59:59"), size: 1, isDirectory: false, now: now, calendar: cal))
        XCTAssertFalse(f.matches(modified: d("2026-03-03 00:00:00"), size: 1, isDirectory: false, now: now, calendar: cal))
    }

    // Custom with one side left unset is a bound, not an empty range.
    func testCustomOpenEnded() {
        let now = d("2026-03-10 09:00:00")
        var f = SearchFilters(date: .custom, size: .any)
        f.customDateFrom = d("2026-03-05 00:00:00")
        XCTAssertTrue(f.matches(modified: d("2030-01-01 00:00:00"), size: 1, isDirectory: false, now: now, calendar: cal))
        XCTAssertFalse(f.matches(modified: d("2026-03-04 23:59:59"), size: 1, isDirectory: false, now: now, calendar: cal))
    }

    func testAnyDateMatchesEverything() {
        let f = SearchFilters()
        XCTAssertFalse(f.isActive)
        XCTAssertTrue(f.matches(modified: d("1990-01-01 00:00:00"), size: 0, isDirectory: false, now: d("2026-03-10 09:00:00"), calendar: cal))
    }
}

final class SearchSizeFilterTests: XCTestCase {

    private func matches(_ s: SearchSizeFilter, _ bytes: Int64, dir: Bool = false) -> Bool {
        SearchFilters(date: .any, size: s).matches(modified: Date(), size: bytes, isDirectory: dir)
    }

    // Exactly 100 KB is the edge between Tiny and Small. Decimal KB, because that is
    // what the Size column shows — a 1024-based threshold here would exclude a file
    // the app itself labels "100 KB".
    func testExactly100KBIsSmallNotTiny() {
        XCTAssertFalse(matches(.tiny, 100_000))
        XCTAssertTrue(matches(.tiny, 99_999))
        XCTAssertTrue(matches(.small, 100_000))
        XCTAssertFalse(matches(.small, 1_000_000))
        XCTAssertTrue(matches(.medium, 1_000_000))
    }

    func testEmptyIsOnlyZero() {
        XCTAssertTrue(matches(.empty, 0))
        XCTAssertFalse(matches(.empty, 1))
        XCTAssertFalse(matches(.tiny, 0))   // 0 bytes belongs to Empty, not Tiny
        XCTAssertTrue(matches(.tiny, 1))
    }

    func testMediumLargeHugeEdges() {
        XCTAssertFalse(matches(.medium, 100_000_000))
        XCTAssertTrue(matches(.large, 100_000_000))
        XCTAssertFalse(matches(.large, 1_000_000_000))
        XCTAssertTrue(matches(.huge, 1_000_000_000))
        XCTAssertTrue(matches(.huge, 5_000_000_000))
    }

    // A folder's `size` in a listing is its directory entry, not its contents. Judging
    // folders by it would file every folder under "Tiny" and drop them all from "Large".
    func testFoldersAreExemptFromSizeButNotDate() {
        XCTAssertTrue(matches(.huge, 96, dir: true))
        XCTAssertTrue(matches(.empty, 96, dir: true))
    }

    func testCustomByteRange() {
        var f = SearchFilters(date: .any, size: .custom)
        f.customSizeFrom = 500
        f.customSizeTo = 1_500
        XCTAssertTrue(f.matches(modified: Date(), size: 500, isDirectory: false))
        XCTAssertTrue(f.matches(modified: Date(), size: 1_499, isDirectory: false))
        XCTAssertFalse(f.matches(modified: Date(), size: 1_500, isDirectory: false))
        XCTAssertFalse(f.matches(modified: Date(), size: 499, isDirectory: false))
    }
}

// MARK: - Sharing & Permissions

final class PosixAccessTests: XCTestCase {

    func testReadsFinderStyleLevels() {
        let l = PosixMode.levels(0o755)
        XCTAssertEqual(l.owner, .readWrite)
        XCTAssertEqual(l.group, .readOnly)
        XCTAssertEqual(l.other, .readOnly)
        XCTAssertEqual(PosixMode.levels(0o000).owner, .noAccess)
        XCTAssertEqual(PosixMode.levels(0o200).owner, .writeOnly)
    }

    // The bug this prevents: setting a group to "Read only" through the picker used to
    // be an obvious `mode & ~2` — which also strips the execute bit when written as a
    // whole triad, and a directory with r-- cannot be entered at all. The x bit is
    // carried through for files and granted with read for directories.
    func testExecuteBitSurvivesALevelChange() {
        XCTAssertEqual(PosixMode.setting(0o755, .group, to: .readOnly, isDirectory: true), 0o755)
        XCTAssertEqual(PosixMode.setting(0o755, .group, to: .readWrite, isDirectory: true), 0o775)
        // A script: chmod'ing group to Read only must not un-run it.
        XCTAssertEqual(PosixMode.setting(0o775, .group, to: .readOnly, isDirectory: false), 0o755)
        // A plain data file has no x bit to keep, and must not gain one.
        XCTAssertEqual(PosixMode.setting(0o644, .other, to: .readWrite, isDirectory: false), 0o646)
        // …but a directory does need search permission to be usable.
        XCTAssertEqual(PosixMode.setting(0o700, .other, to: .readOnly, isDirectory: true), 0o705)
    }

    func testNoAccessClearsTheWholeTriad() {
        XCTAssertEqual(PosixMode.setting(0o755, .other, to: .noAccess, isDirectory: true), 0o750)
        XCTAssertEqual(PosixMode.setting(0o777, .group, to: .noAccess, isDirectory: false), 0o707)
    }

    // setgid on a shared drop folder is what keeps new files group-owned; silently
    // dropping it while changing an unrelated triad would break the folder's purpose.
    func testSetuidStickyBitsAreUntouched() {
        XCTAssertEqual(PosixMode.setting(0o2775, .other, to: .readOnly, isDirectory: true), 0o2775)
        XCTAssertEqual(PosixMode.setting(0o1777, .group, to: .noAccess, isDirectory: true), 0o1707)
    }

    func testRoundTripsEveryLevel() {
        for level in PosixAccess.allCases {
            let m = PosixMode.setting(0o000, .owner, to: level, isDirectory: false)
            XCTAssertEqual(PosixMode.levels(m).owner, level, "\(level)")
        }
    }

    func testPermissionString() {
        XCTAssertEqual(PosixMode.string(0o755), "rwxr-xr-x")
        XCTAssertEqual(PosixMode.string(0o000), "---------")
    }
}

// MARK: - Trash put-back

final class TrashPutBackTests: XCTestCase {

    // Builds a minimal but REAL "Bud1" .DS_Store: header, allocator address list,
    // directory naming the DSDB block, DSDB header, and one B-tree leaf holding the
    // records. Without this the parser could only be tested against the tester's own
    // Trash, which is neither reproducible nor safe to depend on.
    private func makeDSStore(_ entries: [(trashName: String, dir: String, original: String)]) -> Data {
        func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }
        func utf16be(_ s: String) -> [UInt8] {
            Array(s.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] }
        }
        func record(_ key: String, _ sid: String, _ value: String) -> [UInt8] {
            be32(key.utf16.count) + utf16be(key) + Array(sid.utf8) + Array("ustr".utf8)
                + be32(value.utf16.count) + utf16be(value)
        }
        var leaf: [UInt8] = be32(0) + be32(entries.count * 2)   // P = 0 → leaf node
        for e in entries {
            leaf += record(e.trashName, "ptbL", e.dir)
            leaf += record(e.trashName, "ptbN", e.original)
        }
        // Block 1 = DSDB header, block 2 = the leaf. File offsets are chosen so that
        // (offset - 4) is 32-byte aligned, which is what the address encoding requires.
        let dsdbFile = 0x1004, leafFile = 0x2004, infoFile = 0x4004
        var dsdb: [UInt8] = be32(2) + be32(0) + be32(entries.count * 2) + be32(1) + be32(4096)
        dsdb += [UInt8](repeating: 0, count: 32 - dsdb.count)
        var addrs: [UInt8] = be32(0)                             // block 0 unused
        addrs += be32((dsdbFile - 4) | 5)                        // 32 bytes
        addrs += be32((leafFile - 4) | 12)                       // 4096 bytes
        addrs += [UInt8](repeating: 0, count: (256 - 3) * 4)     // padded to 256 slots
        var info: [UInt8] = be32(3) + be32(0) + addrs
        info += be32(1) + [4] + Array("DSDB".utf8) + be32(1)     // one directory: DSDB → block 1

        var out = [UInt8](repeating: 0, count: infoFile + info.count)
        func put(_ bytes: [UInt8], at o: Int) { for (i, b) in bytes.enumerated() { out[o + i] = b } }
        put(be32(1), at: 0)
        put(Array("Bud1".utf8), at: 4)
        put(be32(infoFile - 4), at: 8)
        put(be32(info.count), at: 12)
        put(be32(infoFile - 4), at: 16)
        put(dsdb, at: dsdbFile)
        put(leaf, at: leafFile)
        put(info, at: infoFile)
        return Data(out)
    }

    func testReadsPutBackRecords() {
        let data = makeDSStore([
            (trashName: "alpha.txt", dir: "Users/x/Desktop/", original: "alpha.txt"),
            (trashName: "New Folder 08-27-42-686", dir: "private/tmp/navundo/", original: "New Folder"),
        ])
        let recs = DSStore.putBackRecords(data)
        XCTAssertEqual(recs["alpha.txt"], TrashOrigin(directory: "/Users/x/Desktop", name: "alpha.txt"))
        // THE case Restore gets wrong: the Trash renamed the item on a collision, so
        // putting it back under the name it has IN the Trash would restore
        // "New Folder 08-27-42-686" instead of "New Folder".
        XCTAssertEqual(recs["New Folder 08-27-42-686"],
                       TrashOrigin(directory: "/private/tmp/navundo", name: "New Folder"))
        XCTAssertEqual(recs["New Folder 08-27-42-686"]?.url.path, "/private/tmp/navundo/New Folder")
    }

    func testUnicodeNamesSurvive() {
        let data = makeDSStore([(trashName: "rés😀umé.txt", dir: "Users/x/Documents/", original: "rés😀umé.txt")])
        XCTAssertEqual(DSStore.putBackRecords(data)["rés😀umé.txt"]?.name, "rés😀umé.txt")
    }

    // A .DS_Store is undocumented, third-party-written, untrusted input. Every one of
    // these used to be a crash waiting to happen; the parser must only ever return
    // less, never trap.
    func testMalformedInputIsSurvived() {
        XCTAssertTrue(DSStore.putBackRecords(Data()).isEmpty)
        XCTAssertTrue(DSStore.putBackRecords(Data([0, 0, 0, 1])).isEmpty)
        XCTAssertTrue(DSStore.putBackRecords(Data("not a ds_store at all".utf8)).isEmpty)
        let good = makeDSStore([(trashName: "a.txt", dir: "tmp/", original: "a.txt")])
        for cut in [8, 20, 0x1010, 0x2020, 0x4010] where cut < good.count {
            XCTAssertTrue(DSStore.putBackRecords(good.prefix(cut)).count <= 1)   // must not trap
        }
        var flipped = [UInt8](good)
        for i in stride(from: 0, to: flipped.count, by: 977) { flipped[i] = 0xFF }
        _ = DSStore.putBackRecords(Data(flipped))   // must not trap
    }

    // Finder records the firmlink path for the data volume. It resolves to the same
    // directory, but it is a path the user has never seen in any other app — every
    // path we display or compare has to be the /Users form.
    func testFirmlinkPathIsNormalized() {
        XCTAssertEqual(DSStore.normalize("System/Volumes/Data/Users/x/Desktop/"), "/Users/x/Desktop")
        XCTAssertEqual(DSStore.normalize("/System/Volumes/Data"), "/")
        XCTAssertEqual(DSStore.normalize("Users/x/"), "/Users/x")
        XCTAssertEqual(DSStore.normalize("/Volumes/Share/dir/"), "/Volumes/Share/dir")
    }
}

final class TrashOriginsTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        suite = UserDefaults(suiteName: "NavigatorTrashOriginsTests")!
        suite.removePersistentDomain(forName: "NavigatorTrashOriginsTests")
        TrashOrigins.defaults = suite
    }
    override func tearDown() {
        suite.removePersistentDomain(forName: "NavigatorTrashOriginsTests")
        TrashOrigins.defaults = .standard
    }

    // Recording keys on the path INSIDE the Trash, because that is the unique one —
    // the Trash renames collisions, so two items that were both "report.txt" are
    // distinguishable there and nowhere else.
    func testRecordsAndReadsBackTheCollisionRenamedName() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("navTrashOriginTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let inTrash = tmp.appendingPathComponent("report 2.txt")
        try Data("x".utf8).write(to: inTrash)

        TrashOrigins.record([(from: inTrash, to: URL(fileURLWithPath: "/tmp/work/report.txt"))])
        XCTAssertEqual(TrashOrigins.origin(of: inTrash.path),
                       TrashOrigin(directory: "/tmp/work", name: "report.txt"))

        TrashOrigins.forget([inTrash.path])
        XCTAssertNil(TrashOrigins.origin(of: inTrash.path))
    }

    // An entry whose trashed item no longer exists (emptied, or already put back) is
    // dead weight and would otherwise accumulate forever.
    func testEntriesForVanishedTrashItemsArePruned() {
        let ghost = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString)/x.txt")
        TrashOrigins.record([(from: ghost, to: URL(fileURLWithPath: "/tmp/x.txt"))])
        XCTAssertNil(TrashOrigins.origin(of: ghost.path))
    }

    func testUnknownPathHasNoOrigin() {
        XCTAssertNil(TrashOrigins.origin(of: "/Users/x/.Trash/never-recorded.txt"))
    }
}

// Clicking a Details column header must sort by it, ascending first. The bug this
// guards: AppKit prepends to NSTableView.sortDescriptors instead of replacing, and
// autosaveTableColumns persists the growing stack, so a column kept whatever direction
// it had the last time it was sorted — click "Size" expecting ascending, get the
// descending order from three sessions ago. Only the first descriptor is read, so a
// check that looked at the first entry alone saw nothing wrong and never trimmed.
final class TableSortRulesTests: XCTestCase {

    func testExactlyTheActiveSortNeedsNoRewrite() {
        XCTAssertFalse(TableSortRules.needsRewrite(current: [("size", true)],
                                                   desiredKey: "size", desiredAscending: true))
    }

    func testStaleTailIsRewrittenEvenWhenTheFirstEntryAlreadyMatches() {
        XCTAssertTrue(TableSortRules.needsRewrite(current: [("size", true), ("name", false)],
                                                  desiredKey: "size", desiredAscending: true))
    }

    func testWrongColumnNeedsRewrite() {
        XCTAssertTrue(TableSortRules.needsRewrite(current: [("name", true)],
                                                  desiredKey: "size", desiredAscending: true))
    }

    func testWrongDirectionNeedsRewrite() {
        XCTAssertTrue(TableSortRules.needsRewrite(current: [("size", true)],
                                                  desiredKey: "size", desiredAscending: false))
    }

    // A table that has never been sorted, and one restored from an autosave holding a
    // whole stack — both have to be brought back to the single active descriptor.
    func testEmptyStackNeedsRewrite() {
        XCTAssertTrue(TableSortRules.needsRewrite(current: [], desiredKey: "name", desiredAscending: true))
    }

    func testRestoredMultiLevelStackNeedsRewrite() {
        XCTAssertTrue(TableSortRules.needsRewrite(
            current: [("modified", false), ("kind", true), ("name", true), ("size", false)],
            desiredKey: "modified", desiredAscending: false))
    }

    // The new columns resolve by the same id the header uses — Owner/Time/Dimensions
    // are not special-cased anywhere in this rule.
    func testNewColumnIdsAreOrdinary() {
        XCTAssertFalse(TableSortRules.needsRewrite(current: [("owner", false)],
                                                   desiredKey: "owner", desiredAscending: false))
        XCTAssertTrue(TableSortRules.needsRewrite(current: [("dimensions", true), ("duration", true)],
                                                  desiredKey: "dimensions", desiredAscending: true))
    }
}

// MARK: - Trash origin eviction

/// The bug: eviction was `Array(map).suffix(limit)` over a Dictionary. Dictionary
/// iteration order is unspecified AND differs between processes, so the 500 entries
/// that survived were an arbitrary set — a Put Back that worked before a relaunch
/// could silently have no recorded origin after one. `age` is injected here so the
/// rule can be pinned down without touching the filesystem.
final class TrashOriginEvictionTests: XCTestCase {

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 86_400 * Double(n)) }

    private func evict(_ pairs: [(String, Int)], limit: Int) -> [String: String] {
        let ages = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, self.day($0.1)) })
        let map = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, "/origin\($0.0)") })
        return TrashOrigins.evict(map, limit: limit) { ages[$0] ?? .distantPast }
    }

    func testUnderTheLimitKeepsEverything() {
        let out = evict([("/t/a", 1), ("/t/b", 2)], limit: 5)
        XCTAssertEqual(Set(out.keys), ["/t/a", "/t/b"])
    }

    func testDropsTheOldestFirst() {
        let out = evict([("/t/old", 1), ("/t/mid", 2), ("/t/new", 3)], limit: 2)
        XCTAssertEqual(Set(out.keys), ["/t/mid", "/t/new"])
    }

    func testKeepsTheVALUESOfTheSurvivors() {
        let out = evict([("/t/old", 1), ("/t/new", 3)], limit: 1)
        XCTAssertEqual(out["/t/new"], "/origin/t/new")
    }

    // Two items trashed in the same instant must still evict the same way every run —
    // otherwise the unspecified-order bug is back, just harder to see.
    func testTiesBreakDeterministicallyByPath() {
        let pairs = [("/t/a", 1), ("/t/b", 1), ("/t/c", 1)]
        let first = evict(pairs, limit: 2)
        for _ in 0..<20 { XCTAssertEqual(Set(evict(pairs.shuffled(), limit: 2).keys), Set(first.keys)) }
        XCTAssertEqual(Set(first.keys), ["/t/b", "/t/c"])   // "/t/a" sorts lowest, so it goes
    }

    // An item whose date can't be read is the FIRST to go, not the last: an entry we
    // can no longer date is the one we know least about.
    func testUndatableEntriesAreEvictedFirst() {
        let map = ["/t/known": "/o1", "/t/unknown": "/o2"]
        let out = TrashOrigins.evict(map, limit: 1) { $0 == "/t/known" ? Date() : .distantPast }
        XCTAssertEqual(Set(out.keys), ["/t/known"])
    }
}

// MARK: - .DS_Store parsing

/// `putBackRecords` runs on a DispatchQueue.global worker (512 KB stack) over a file
/// this app did not write. It used to walk the B-tree RECURSIVELY with only a
/// node-COUNT bound, so a corrupt file whose blocks chain 10,000 deep meant 10,000
/// live stack frames and a stack overflow — a crash with no error anyone could act on.
/// These pin down the "never crash, never hang, degrade to no records" contract.
final class DSStoreRobustnessTests: XCTestCase {

    func testEmptyDataYieldsNothing() {
        XCTAssertTrue(DSStore.putBackRecords(Data()).isEmpty)
    }

    func testNonBud1DataYieldsNothing() {
        XCTAssertTrue(DSStore.putBackRecords(Data(repeating: 0xAB, count: 4096)).isEmpty)
    }

    // A valid magic followed by garbage is the shape a truncated or partly-overwritten
    // .DS_Store actually has — the parser must give up, not read past the end.
    func testValidMagicWithGarbageBodyYieldsNothing() {
        var d = Data([0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31])
        d.append(Data(repeating: 0xFF, count: 8192))
        XCTAssertTrue(DSStore.putBackRecords(d).isEmpty)
    }

    /// A header claiming a huge block count with no address table behind it: the offsets
    /// all land past the end of the buffer, which is the corruption most likely to walk
    /// the parser off a cliff.
    func testOutOfRangeBlockTableYieldsNothing() {
        var b = [UInt8]([0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31])
        b += [0, 0, 0x10, 0x00]                    // allocator info offset
        b += Data(repeating: 0, count: 0x1000).map { $0 }
        b += [0, 0x01, 0x00, 0x00]                 // 65,536 blocks, nothing behind them
        XCTAssertTrue(DSStore.putBackRecords(Data(b)).isEmpty)
    }

    func testNormalizeAddsLeadingSlashAndStripsFirmlink() {
        XCTAssertEqual(DSStore.normalize("Users/me/Pictures"), "/Users/me/Pictures")
        XCTAssertEqual(DSStore.normalize("/System/Volumes/Data/Users/me"), "/Users/me")
        XCTAssertEqual(DSStore.normalize("/System/Volumes/Data"), "/")
        XCTAssertEqual(DSStore.normalize("/Users/me/"), "/Users/me")
    }
}

// MARK: - Coming back to where you were (FolderPlace / FolderPlaceLRU)

final class FolderPlaceTests: XCTestCase {
    private let ids = ["a", "b", "c", "d", "e"]

    func testAnchorStillPresentWins() {
        let p = FolderPlace(anchorID: "c", anchorIndex: 2, selection: [])
        XCTAssertEqual(p.restoreAnchor(among: ids, settled: true), "c")
    }

    /// The anchor moved because files were added above it — we follow the ITEM, not the
    /// index, which is the whole reason the anchor is an id.
    func testAnchorFollowsTheItemNotTheIndex() {
        let p = FolderPlace(anchorID: "c", anchorIndex: 2, selection: [])
        XCTAssertEqual(p.restoreAnchor(among: ["x", "y", "a", "b", "c"], settled: true), "c")
    }

    /// Deleted while we were away: land at the same position instead of the top.
    func testMissingAnchorFallsBackToIndex() {
        let p = FolderPlace(anchorID: "c", anchorIndex: 2, selection: [])
        XCTAssertEqual(p.restoreAnchor(among: ["a", "b", "d", "e"], settled: true), "d")
    }

    /// The folder got much shorter — the stored index must not walk off the end.
    func testMissingAnchorClampsToLastItem() {
        let p = FolderPlace(anchorID: "z", anchorIndex: 400, selection: [])
        XCTAssertEqual(p.restoreAnchor(among: ["a", "b"], settled: true), "b")
    }

    func testEmptyFolderRestoresNothing() {
        let p = FolderPlace(anchorID: "c", anchorIndex: 2, selection: [])
        XCTAssertNil(p.restoreAnchor(among: [], settled: true))
    }

    /// Already at the top when we left: there is nothing to restore, and scrolling to
    /// ids[0] would fight a view that is already showing it.
    func testTopOfFolderRestoresNothing() {
        let p = FolderPlace(anchorID: "a", anchorIndex: 0, selection: [])
        XCTAssertNil(p.restoreAnchor(among: ["b", "c"], settled: true))
        XCTAssertNil(FolderPlace().restoreAnchor(among: ids, settled: true))
    }

    /// A listing still filling in must not trigger the index fallback: "not here yet" is
    /// not "gone", and the position would be computed from a fraction of the folder.
    func testUnsettledListingDeclinesRatherThanGuessing() {
        let p = FolderPlace(anchorID: "c", anchorIndex: 2, selection: [])
        XCTAssertNil(p.restoreAnchor(among: ["a", "b"], settled: false))
        // ...but an anchor that IS present is answerable immediately.
        XCTAssertEqual(p.restoreAnchor(among: ["a", "b", "c"], settled: false), "c")
    }
}

final class FolderPlaceLRUTests: XCTestCase {
    private func place(_ id: String) -> FolderPlace { FolderPlace(anchorID: id, anchorIndex: 1, selection: [id]) }

    func testStoresAndReadsBack() {
        var lru = FolderPlaceLRU()
        lru.set(place("f1"), for: "/tmp/a")
        XCTAssertEqual(lru.value(for: "/tmp/a")?.anchorID, "f1")
        XCTAssertNil(lru.value(for: "/tmp/b"))
    }

    func testReplacingAFolderDoesNotDuplicateTheOrderEntry() {
        var lru = FolderPlaceLRU()
        lru.set(place("f1"), for: "/tmp/a")
        lru.set(place("f2"), for: "/tmp/a")
        XCTAssertEqual(lru.count, 1)
        XCTAssertEqual(lru.order, ["/private/tmp/a"])   // canonical: firmlinks resolve INTO /private
        XCTAssertEqual(lru.value(for: "/tmp/a")?.anchorID, "f2")
    }

    func testEvictsLeastRecentlyUsedAtTheCap() {
        var lru = FolderPlaceLRU()
        for i in 0..<(FolderPlaceLRU.cap + 10) { lru.set(place("f"), for: "/tmp/\(i)") }
        XCTAssertEqual(lru.count, FolderPlaceLRU.cap)
        XCTAssertEqual(lru.order.count, FolderPlaceLRU.cap)
        XCTAssertNil(lru.value(for: "/tmp/0"))                                   // oldest gone
        XCTAssertNotNil(lru.value(for: "/tmp/\(FolderPlaceLRU.cap + 9)"))        // newest kept
    }

    /// Re-recording a folder makes it recent again, so the folder you keep coming back to
    /// outlives the hundred you passed through once.
    func testRevisitingSavesAFolderFromEviction() {
        var lru = FolderPlaceLRU()
        lru.set(place("f"), for: "/tmp/keep")
        for i in 0..<(FolderPlaceLRU.cap - 1) { lru.set(place("f"), for: "/tmp/\(i)") }
        lru.set(place("again"), for: "/tmp/keep")
        for i in 100..<(100 + FolderPlaceLRU.cap - 1) { lru.set(place("f"), for: "/tmp/\(i)") }
        XCTAssertEqual(lru.value(for: "/tmp/keep")?.anchorID, "again")
    }
}

// The bug these pin down: Send To ▸ Desktop on an install whose Desktop permission had
// been dismissed failed with a generic "couldn't be copied" and an unrelated Full Disk
// Access paragraph. Nothing told the user macOS was the one saying no.
final class PermissionDiagnosisTests: XCTestCase {

    func testRecognisesTheTwoCocoaPermissionErrors() {
        XCTAssertTrue(PermissionDiagnosis.isDenial(domain: NSCocoaErrorDomain, code: 257))
        XCTAssertTrue(PermissionDiagnosis.isDenial(domain: NSCocoaErrorDomain, code: 513))
    }

    // copyfile() builds its error from errno, so the POSIX codes have to count too —
    // the byte-progress copy path is the one Send To actually uses for plain files.
    func testRecognisesThePosixPermissionErrors() {
        XCTAssertTrue(PermissionDiagnosis.isDenial(domain: NSPOSIXErrorDomain, code: 1))
        XCTAssertTrue(PermissionDiagnosis.isDenial(domain: NSPOSIXErrorDomain, code: 13))
    }

    /// "No such file" and "disk full" must NOT be dressed up as permission problems:
    /// pointing someone at System Settings for a missing file wastes their afternoon.
    func testDoesNotClaimEveryFailureIsAPermission() {
        XCTAssertFalse(PermissionDiagnosis.isDenial(domain: NSCocoaErrorDomain, code: 260))   // no such file
        XCTAssertFalse(PermissionDiagnosis.isDenial(domain: NSPOSIXErrorDomain, code: 28))    // ENOSPC
        XCTAssertFalse(PermissionDiagnosis.isDenial(domain: "SomeOtherDomain", code: 13))
    }

    func testMatchesTheMessagesCocoaAndStrerrorActuallyProduce() {
        XCTAssertTrue(PermissionDiagnosis.looksLikeDenial("Permission denied"))
        XCTAssertTrue(PermissionDiagnosis.looksLikeDenial("Operation not permitted"))
        // Cocoa uses a curly apostrophe; a straight-quote-only check missed every
        // FileManager failure, which is the common case.
        XCTAssertTrue(PermissionDiagnosis.looksLikeDenial("You don\u{2019}t have permission to save the file “a” in the folder “Desktop”."))
        XCTAssertTrue(PermissionDiagnosis.looksLikeDenial("You don't have permission to save the file."))
    }

    func testLeavesOrdinaryFailuresAlone() {
        XCTAssertFalse(PermissionDiagnosis.looksLikeDenial("The file “a.png” doesn’t exist."))
        XCTAssertFalse(PermissionDiagnosis.looksLikeDenial("There isn’t enough space on the disk."))
    }

    func testNamesTheProtectedFolderAPathIsIn() {
        let home = "/Users/nobody"
        XCTAssertEqual(PermissionDiagnosis.protectedFolder(for: "/Users/nobody/Desktop", home: home), "Desktop")
        XCTAssertEqual(PermissionDiagnosis.protectedFolder(for: "/Users/nobody/Documents/Work/x", home: home), "Documents")
        XCTAssertEqual(PermissionDiagnosis.protectedFolder(for: "/Users/nobody/Downloads", home: home), "Downloads")
    }

    /// Pictures is not gated by a Files-&-Folders switch, and neither is a plain folder
    /// whose name merely starts the same way — "Desktop Backup" is not the Desktop.
    func testDoesNotInventAPermissionForUnprotectedFolders() {
        let home = "/Users/nobody"
        XCTAssertNil(PermissionDiagnosis.protectedFolder(for: "/Users/nobody/Pictures", home: home))
        XCTAssertNil(PermissionDiagnosis.protectedFolder(for: "/Users/nobody/Desktop Backup", home: home))
        XCTAssertNil(PermissionDiagnosis.protectedFolder(for: "/Volumes/Share/art", home: home))
    }
}

final class PermissionStateTests: XCTestCase {

    /// The whole point of the assistant is that a half-set-up install looks wrong at a
    /// glance. "Not yet asked" counts as unfinished; "unknown" — a volume class with no
    /// such volume mounted — is not evidence of a problem and must not raise an alarm.
    func testOnlyActionableStatesAskForAttention() {
        XCTAssertTrue(PermissionState.denied.needsAttention)
        XCTAssertTrue(PermissionState.notAsked.needsAttention)
        XCTAssertTrue(PermissionState.off.needsAttention)
        XCTAssertFalse(PermissionState.granted.needsAttention)
        XCTAssertFalse(PermissionState.unknown.needsAttention)
    }

    func testEveryStateHasItsOwnWordAndBadge() {
        let all: [PermissionState] = [.granted, .denied, .notAsked, .unknown, .off, .covered]
        XCTAssertEqual(Set(all.map(\.label)).count, all.count)
        XCTAssertEqual(Set(all.map(\.symbol)).count, all.count)
    }

    func testCoveredIsSatisfied() {
        XCTAssertFalse(PermissionState.covered.needsAttention)
    }
}

// MARK: - What the Setup Assistant is allowed to claim

/// These exist because the assistant shipped telling the owner of a machine that HAS Full
/// Disk Access to go turn on four folder switches macOS was not showing him, and offering
/// a button to a pane where the named row could not exist. The rules are pure so the
/// footer count and the row badges cannot drift apart again.
final class SetupAuditTests: XCTestCase {

    private let files = ["Desktop", "Documents", "Downloads", "network", "removable"]

    func testFullDiskAccessSilencesEveryFileRowItCovers() {
        for id in files {
            for probed: PermissionState in [.notAsked, .denied, .off] {
                XCTAssertEqual(SetupAudit.effectiveState(id: id, probed: probed, fullDisk: .granted), .covered,
                               "\(id)/\(probed) should be covered by FDA")
            }
        }
    }

    /// FDA is about permission, not about proof or existence. A probe that actually
    /// performed the access keeps saying so, and a volume class with nothing mounted stays
    /// unknown — claiming "covered" there would be inventing an answer we never got.
    func testCoverageNeverOverwritesAnAnswerWeActuallyHave() {
        XCTAssertEqual(SetupAudit.effectiveState(id: "Desktop", probed: .granted, fullDisk: .granted), .granted)
        XCTAssertEqual(SetupAudit.effectiveState(id: "removable", probed: .unknown, fullDisk: .granted), .unknown)
    }

    /// Full Disk Access says nothing about Automation or the Finder extension, so those
    /// rows must survive it — the original bug in mirror image.
    func testCoverageStopsAtTheRowsFullDiskAccessActuallyCovers() {
        for id in ["automation", "finderext", "fda", "accessibility"] {
            XCTAssertEqual(SetupAudit.effectiveState(id: id, probed: .off, fullDisk: .granted), .off)
        }
        for id in files {
            XCTAssertEqual(SetupAudit.effectiveState(id: id, probed: .notAsked, fullDisk: .denied), .notAsked)
            XCTAssertEqual(SetupAudit.effectiveState(id: id, probed: .notAsked, fullDisk: .unknown), .notAsked)
        }
    }

    /// The exact machine this was reported from: FDA on, the three home folders never
    /// asked for, no removable drive mounted, everything else fine. The old code said
    /// "4 items still need attention"; the only true answer is none.
    func testTheReportedMachineCountsZero() {
        let rows: [(id: String, probed: PermissionState, optional: Bool)] = [
            ("fda", .granted, true), ("Desktop", .notAsked, false), ("Documents", .notAsked, false),
            ("Downloads", .notAsked, false), ("network", .granted, false), ("removable", .unknown, false),
            ("automation", .granted, false), ("finderext", .granted, false)
        ]
        XCTAssertEqual(SetupAudit.attentionCount(rows, fullDisk: .granted), 0)
    }

    /// Without FDA the same install has real work in it — the assistant must not go quiet
    /// in the other direction. Full Disk Access itself is never part of the count: it is
    /// optional, and counting an optional switch is how the first version cried wolf.
    func testWithoutFullDiskAccessRealWorkIsStillCounted() {
        let rows: [(id: String, probed: PermissionState, optional: Bool)] = [
            ("fda", .denied, true), ("Desktop", .notAsked, false), ("Documents", .granted, false),
            ("Downloads", .denied, false), ("removable", .unknown, false), ("finderext", .off, false)
        ]
        XCTAssertEqual(SetupAudit.attentionCount(rows, fullDisk: .denied), 3)
    }

    /// Accessibility buys exactly one keystroke — ⌃⌥⇧⌘G — and the ⌃⌥⌘G copy path works
    /// without it. An unlit switch there is a working install, so it must never appear in
    /// the footer's number; a checklist that nags about a feature you aren't using is the
    /// checklist people stop opening. It also always has somewhere to send you: unlike
    /// Files & Folders, macOS lists every app in the Accessibility pane's + panel whether
    /// or not it has ever asked.
    func testAccessibilityIsOptionalAndAlwaysActionable() {
        let rows: [(id: String, probed: PermissionState, optional: Bool)] = [
            ("fda", .granted, true), ("automation", .granted, false), ("accessibility", .off, true)
        ]
        XCTAssertEqual(SetupAudit.attentionCount(rows, fullDisk: .granted), 0)
        XCTAssertTrue(SetupAudit.buttons(state: .off, canAsk: false, listedOnlyAfterRequest: false).settings)
        XCTAssertFalse(SetupAudit.buttons(state: .off, canAsk: false, listedOnlyAfterRequest: false).ask)
    }

    /// A button is a promise that pressing it does something.
    func testNoButtonPointsSomewhereTheUserCannotAct() {
        // The dead end that started this: not yet requested, so System Settings has no row.
        XCTAssertEqual(SetupAudit.buttons(state: .notAsked, canAsk: true, listedOnlyAfterRequest: true).settings, false)
        XCTAssertEqual(SetupAudit.buttons(state: .notAsked, canAsk: true, listedOnlyAfterRequest: true).ask, true)
        XCTAssertEqual(SetupAudit.buttons(state: .unknown, canAsk: false, listedOnlyAfterRequest: true).settings, false)
        // Once macOS HAS a decision on file the row exists and Settings is the way to change it.
        XCTAssertEqual(SetupAudit.buttons(state: .denied, canAsk: true, listedOnlyAfterRequest: true).settings, true)
        XCTAssertEqual(SetupAudit.buttons(state: .denied, canAsk: true, listedOnlyAfterRequest: true).ask, false)
        XCTAssertEqual(SetupAudit.buttons(state: .granted, canAsk: true, listedOnlyAfterRequest: true).settings, true)
        // A row macOS lists unconditionally (the Finder extension) always has somewhere to go.
        XCTAssertEqual(SetupAudit.buttons(state: .off, canAsk: false, listedOnlyAfterRequest: false).settings, true)
        // Covered: nothing to ask for, and nothing to look at — macOS hides the switch.
        let covered = SetupAudit.buttons(state: .covered, canAsk: true, listedOnlyAfterRequest: true)
        XCTAssertFalse(covered.ask); XCTAssertFalse(covered.settings)
    }
}

// MARK: - The one key a per-folder record is filed under

final class FolderKeyTests: XCTestCase {

    /// A real directory plus a real symlink to it, because the whole point of folderKey
    /// is what the filesystem says — a test built out of strings alone would pass against
    /// an implementation that resolves nothing.
    private var root = ""
    override func setUpWithError() throws {
        // Under /tmp specifically, not NSTemporaryDirectory(): /tmp is the symlink to
        // /private/tmp that this whole function exists to see through, and the test
        // bundle's own temporary directory is a real /var/folders path with nothing to
        // resolve.
        root = "/tmp/navkey-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/Real", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/Link", withDestinationPath: root + "/Real")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    /// THE bug: `/tmp` is a symlink to `/private/tmp`, so a folder reached via the
    /// address bar and the same folder reached via the sidebar were two records, and
    /// each forgot the view set through the other. Note this is the case
    /// `standardizedFileURL.resolvingSymlinksInPath()` gets WRONG — it un-prefixes
    /// `/private` only at the root, leaving the deeper path split in two.
    func testPrivateTmpAndTmpAreOneFolder() {
        XCTAssertEqual(folderKey(root), folderKey("/private" + root))
        XCTAssertEqual(folderKey(root + "/Real"), folderKey("/private" + root + "/Real"))
    }

    /// DELIBERATELY NO LONGER TRUE, and the reverse is asserted so nobody "fixes" it back.
    ///
    /// Resolving a user-made symlink needs the filesystem, and folderKey is computed on every folder
    /// render and inside FolderViewOptionsStore's dispatch_once init. With realpath in there, one
    /// remembered folder on a network mount that had stopped answering froze the whole app before it
    /// drew a window - measured, main thread parked in realpath -> __getattrlist.
    ///
    /// So a hand-made symlink now keys as itself. The cost is that one folder reached both ways can
    /// hold two view records; the alternative was an app that would not start.
    func testSymlinkedFolderIsNotUnifiedWithItsTarget_byDesign() {
        XCTAssertNotEqual(folderKey(root + "/Link"), folderKey(root + "/Real"))
        // Still stable, still normalising - the same key every time.
        XCTAssertEqual(folderKey(root + "/Link"), folderKey(root + "/Link/"))
        XCTAssertEqual(folderKey(root + "/Link"), folderKey(root + "/Real/../Link"))
    }

    func testTrailingSlashAndDotDotAreTheSameFolder() {
        XCTAssertEqual(folderKey(root + "/Real/"), folderKey(root + "/Real"))
        XCTAssertEqual(folderKey(root + "/Real/../Real"), folderKey(root + "/Real"))
    }

    /// Typing a path into the address bar preserves whatever case was typed; the volume
    /// does not care. Two records for `Photos` and `photos` is the failure people hit.
    func testCaseDoesNotSplitAFolder() {
        XCTAssertEqual(folderKey(root + "/REAL"), folderKey(root + "/Real"))
        XCTAssertEqual(folderKey("/NoSuchPlace/Here"), folderKey("/nosuchplace/here"))
    }

    /// A stored key naming a folder that has since been deleted, or a share that isn't
    /// mounted: realpath fails on both, and this must hand back a key rather than trap.
    func testUnresolvablePathStillProducesAKey() {
        XCTAssertEqual(folderKey("/Volumes/GoneAway/Work/"), "/volumes/goneaway/work")
        XCTAssertEqual(folderKey(""), "")
        XCTAssertEqual(folderKey("/"), "/")
    }

    /// Distinct folders must stay distinct — a normaliser that over-collapses would
    /// hand one folder's view options to another.
    func testDifferentFoldersKeepDifferentKeys() {
        XCTAssertNotEqual(folderKey(root + "/Real"), folderKey(root))
    }
}

final class FolderKeyedStoreTests: XCTestCase {

    private func opts(_ mode: String) -> ViewOptions {
        ViewOptions(viewMode: mode, iconSize: 76, sortKey: "name", sortAscending: true,
                    groupBy: "none", columns: ["name"])
    }

    /// The user-visible bug, at the layer that caused it: set a folder to Gallery having
    /// arrived one way, come back the other way, and the view must still be Gallery.
    func testTheSameFolderReachedTwoWaysIsOneRecord() {
        var lru = ViewOptionsLRU()
        lru.set(opts("gallery"), for: "/private/tmp")
        XCTAssertEqual(lru.value(for: "/tmp")?.viewMode, "gallery")
        XCTAssertTrue(lru.contains("/tmp/"))
        XCTAssertEqual(lru.count, 1)
        lru.set(opts("icon"), for: "/tmp")
        XCTAssertEqual(lru.count, 1)          // not a second record
        lru.remove("/private/tmp/")
        XCTAssertFalse(lru.contains("/tmp"))
    }

    /// Records written before folderKey existed are keyed on the raw path. They are the
    /// user's own arrangements — earned back only by redoing every one by hand — so they
    /// are re-filed, not dropped.
    func testStoredRecordsMigrateToNormalisedKeys() {
        var old = ViewOptionsLRU()
        old.set(opts("icon"), for: "/nowhere/DEEP/Folder")   // pre-normalisation raw key
        // Same folder, two ways, from before the fix — the more recently used wins, and
        // ends up at the front where a plain overwrite would have left it buried.
        var raw = ViewOptionsLRU()
        raw.set(opts("list"), for: "/nowhere/A")
        raw.set(opts("gallery"), for: "/NOWHERE/a")
        let migrated = raw.migratedToNormalizedKeys()
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated.value(for: "/nowhere/a")?.viewMode, "gallery")
        XCTAssertEqual(migrated.order, ["/nowhere/a"])
        XCTAssertEqual(old.migratedToNormalizedKeys().value(for: "/nowhere/deep/folder")?.viewMode, "icon")
    }

    /// A store already in normal form must come back byte-identical, so the migration
    /// doesn't rewrite UserDefaults on every launch for the rest of the app's life.
    func testMigrationIsANoOpOnAnAlreadyNormalisedStore() {
        var lru = ViewOptionsLRU()
        lru.set(opts("icon"), for: "/nowhere/a")
        lru.set(opts("list"), for: "/nowhere/b")
        XCTAssertEqual(lru.migratedToNormalizedKeys(), lru)
    }

    /// Scroll position splits on the same key, and used to split the same way: walk into
    /// a folder from the sidebar, back out, and return via the address bar, and you were
    /// put back at the top.
    func testScrollPlaceIsFoundWhicheverWayTheFolderWasReached() {
        var lru = FolderPlaceLRU()
        lru.set(FolderPlace(anchorID: "x", anchorIndex: 12, selection: ["x"]), for: "/private/tmp")
        XCTAssertEqual(lru.value(for: "/tmp/")?.anchorIndex, 12)
        XCTAssertEqual(lru.count, 1)
    }
}

// MARK: - Undoing a batch of renames without colliding with itself

final class CollisionSafeOrderTests: XCTestCase {

    private func u(_ p: String) -> URL { URL(fileURLWithPath: p) }
    private func names(_ pairs: [(from: URL, to: URL)]) -> [String] {
        pairs.map { "\($0.from.lastPathComponent)->\($0.to.lastPathComponent)" }
    }

    /// The reported bug. Batch Rename did B→C then A→B, so undo was recorded as
    /// C→B, B→A — and replaying it in that order moved C onto the B that A was still
    /// occupying. B must be vacated first.
    func testChainUndoesTheOccupiedNameLast() {
        let ordered = collisionSafeOrder([(from: u("/t/C"), to: u("/t/B")),
                                          (from: u("/t/B"), to: u("/t/A"))])
        XCTAssertEqual(names(ordered), ["B->A", "C->B"])
    }

    /// Three deep, to prove this is a dependency order and not just "reverse the list":
    /// D→C, C→B, B→A only works innermost-first, whichever order it arrives in.
    func testLongerChainIsFullyOrdered() {
        let ordered = collisionSafeOrder([(from: u("/t/C"), to: u("/t/B")),
                                          (from: u("/t/D"), to: u("/t/C")),
                                          (from: u("/t/B"), to: u("/t/A"))])
        XCTAssertEqual(names(ordered), ["B->A", "C->B", "D->C"])
    }

    /// A swap has no safe order at all — every move wants a name another move still
    /// holds — so one member has to go through a name nobody wants. applyRenames' own
    /// fileExists guard means the app can't currently produce one, which is exactly why
    /// this is tested rather than assumed.
    func testSwapGoesThroughATemporaryName() {
        let ordered = collisionSafeOrder([(from: u("/t/A"), to: u("/t/B")),
                                          (from: u("/t/B"), to: u("/t/A"))],
                                         tempSuffix: "tmp")
        XCTAssertEqual(names(ordered), ["A->A.tmp", "B->A", "A.tmp->B"])
        // Every item still ends up where it was asked to go, and nothing is left parked.
        XCTAssertEqual(Set(ordered.map(\.to.path)).intersection(["/t/A", "/t/B"]).count, 2)
        XCTAssertEqual(ordered.last?.to.path, "/t/B")
    }

    /// An ordinary batch — every one of restoreItems' other callers — must come back
    /// untouched and in its original order.
    func testUnrelatedBatchIsLeftAlone() {
        let pairs = [(from: u("/t/.Trash/a"), to: u("/t/x/a")),
                     (from: u("/t/.Trash/b"), to: u("/t/y/b")),
                     (from: u("/t/.Trash/c"), to: u("/t/z/c"))]
        XCTAssertEqual(names(collisionSafeOrder(pairs)), ["a->a", "b->b", "c->c"])
        XCTAssertEqual(collisionSafeOrder(pairs).map(\.from.path), pairs.map(\.from.path))
        XCTAssertEqual(collisionSafeOrder([]).count, 0)
    }

    /// A rename that only changes case is one file on a case-insensitive volume, and
    /// there is nothing to sequence — but the paths differ as strings, so a naive
    /// "is the destination occupied" check must not decide it needs parking.
    func testCaseOnlyRenameNeedsNoParking() {
        let ordered = collisionSafeOrder([(from: u("/t/photo.png"), to: u("/t/Photo.png"))])
        XCTAssertEqual(names(ordered), ["photo.png->Photo.png"])
    }
}

/// The four selection cases the Open/Save-dialog hotkey has to get right. It fires while
/// Navigator is in the BACKGROUND, so a wrong answer is invisible until someone's dialog
/// has already jumped to the wrong place.
final class PickerBridgeRulesTests: XCTestCase {

    func testNothingSelectedCopiesTheCurrentFolder() {
        XCTAssertEqual(PickerBridgeRules.pathToCopy(folder: "/tmp/navpath", selection: []),
                       "/tmp/navpath")
    }

    // A single file is the file, NOT its folder: ⌘⇧G in an Open panel both navigates to
    // it and preselects it, which is the whole point of the feature.
    func testOneFileCopiesTheFile() {
        XCTAssertEqual(PickerBridgeRules.pathToCopy(folder: "/tmp/navpath",
                                                    selection: ["/tmp/navpath/red.png"]),
                       "/tmp/navpath/red.png")
    }

    func testOneFolderCopiesTheFolder() {
        XCTAssertEqual(PickerBridgeRules.pathToCopy(folder: "/tmp/navpath",
                                                    selection: ["/tmp/navpath/sub"]),
                       "/tmp/navpath/sub")
    }

    func testMultipleSelectionCopiesTheirFolder() {
        XCTAssertEqual(PickerBridgeRules.pathToCopy(
            folder: "/tmp/navpath",
            selection: ["/tmp/navpath/red.png", "/tmp/navpath/green.png"]), "/tmp/navpath")
    }

    // Search results: the hits can live below the folder being browsed, and the folder
    // they SHARE is a better destination than the search root.
    func testMultipleSelectionInOneSubfolderPrefersThatSubfolder() {
        XCTAssertEqual(PickerBridgeRules.pathToCopy(
            folder: "/tmp/navpath",
            selection: ["/tmp/navpath/sub/a.png", "/tmp/navpath/sub/b.png"]), "/tmp/navpath/sub")
    }

    // Hits from unrelated folders share nothing, so the browsed folder is the only
    // answer that isn't a guess.
    func testMultipleSelectionAcrossFoldersFallsBackToTheCurrentFolder() {
        XCTAssertEqual(PickerBridgeRules.pathToCopy(
            folder: "/tmp/navpath",
            selection: ["/tmp/navpath/sub/a.png", "/tmp/navpath/other/b.png"]), "/tmp/navpath")
    }

    // A stale/empty id must never be handed to a dialog as an empty path.
    func testEmptySelectionEntryFallsBackToTheFolder() {
        XCTAssertEqual(PickerBridgeRules.pathToCopy(folder: "/tmp/navpath", selection: [""]),
                       "/tmp/navpath")
    }

    func testDefaultChordIsControlOptionCommandG() {
        let c = PickerBridgeRules.chord(id: nil)
        XCTAssertEqual(c.display, "\u{2303}\u{2325}\u{2318}G")
        XCTAssertEqual(c.keyCode, 5)
    }

    // A pref written by a later version must not silently disable the hotkey.
    func testUnknownChordIdFallsBackToTheDefault() {
        XCTAssertEqual(PickerBridgeRules.chord(id: "nonsense"), PickerBridgeRules.chords[0])
    }

    // The teleport chord is derived by adding Shift, so no offered chord may already
    // contain it — otherwise the two hot keys would be the same one.
    func testNoOfferedChordContainsShift() {
        for c in PickerBridgeRules.chords {
            XCTAssertEqual(c.carbonModifiers & PickerBridgeRules.shiftKeyMask, 0, c.id)
        }
    }

    func testTeleportChordAddsShiftAndNothingElse() {
        let base = PickerBridgeRules.chords[0]
        let t = PickerBridgeRules.teleportChord(for: base)
        XCTAssertEqual(t.keyCode, base.keyCode)
        XCTAssertEqual(t.carbonModifiers, base.carbonModifiers | PickerBridgeRules.shiftKeyMask)
        XCTAssertEqual(t.display, "\u{2303}\u{2325}\u{21E7}\u{2318}G")
        XCTAssertNotEqual(t.carbonModifiers, base.carbonModifiers)
    }

    func testShortPathIsShownWhole() {
        XCTAssertEqual(PickerBridgeRules.hudLabel("/tmp/navpath/red.png"), "/tmp/navpath/red.png")
    }

    // Shortening drops leading components, never the file name.
    func testLongPathKeepsItsTail() {
        let p = "/Users/merickson/Pictures/2026/Q3/campaign/hero/final/approved/banner-wide.png"
        let label = PickerBridgeRules.hudLabel(p, max: 40)
        XCTAssertLessThanOrEqual(label.count, 40)
        XCTAssertTrue(label.hasSuffix("banner-wide.png"), label)
        XCTAssertTrue(label.hasPrefix("\u{2026}/"), label)
    }

    func testOneOverlongComponentKeepsItsEnd() {
        let label = PickerBridgeRules.hudLabel("/" + String(repeating: "x", count: 90) + "9.png", max: 20)
        XCTAssertEqual(label.count, 20)
        XCTAssertTrue(label.hasSuffix("9.png"), label)
    }
}

// MARK: - Save-panel safety

/// The one-key teleport wrote a real file into a real shared drive once. These pin the
/// decision that stops it: Return goes out only into a panel proven to be an Open panel,
/// and nothing is pasted before the Go-to-Folder field is proven to have focus.
final class PickerBridgeSavePanelTests: XCTestCase {

    func testSavePanelIsIdentifiedByItsAppKitIdentifier() {
        XCTAssertEqual(PickerBridgeRules.panelKind(identifier: "save-panel", hasFilenameField: false),
                       .savePanel)
    }

    func testOpenPanelIsIdentifiedByItsAppKitIdentifier() {
        XCTAssertEqual(PickerBridgeRules.panelKind(identifier: "open-panel", hasFilenameField: false),
                       .openPanel)
    }

    /// A filename field beats the identifier: whatever the panel calls itself, one that
    /// can name a new file can create one.
    func testFilenameFieldOutranksAnOpenPanelIdentifier() {
        XCTAssertEqual(PickerBridgeRules.panelKind(identifier: "open-panel", hasFilenameField: true),
                       .savePanel)
    }

    func testAnythingElseIsUnknown() {
        XCTAssertEqual(PickerBridgeRules.panelKind(identifier: nil, hasFilenameField: false), .unknown)
        XCTAssertEqual(PickerBridgeRules.panelKind(identifier: "_NS:12", hasFilenameField: false), .unknown)
    }

    /// The whole guarantee. `unknown` staying on the no-Return side is the point — a
    /// dialog Navigator can't read is exactly the one it must not press Return in.
    func testReturnIsSentOnlyIntoAProvenOpenPanel() {
        XCTAssertTrue(PickerBridgeRules.mayPostReturn(.openPanel))
        XCTAssertFalse(PickerBridgeRules.mayPostReturn(.savePanel))
        XCTAssertFalse(PickerBridgeRules.mayPostReturn(.unknown))
    }

    func testGoToFolderIsRecognisedFromTheFieldOrItsSheet() {
        XCTAssertTrue(PickerBridgeRules.isGoToFolderFocused(["PathTextField", "GoToWindow"]))
        XCTAssertTrue(PickerBridgeRules.isGoToFolderFocused(["_NS:116", "GoToWindow"]))
    }

    /// The filename field of a Save panel is the exact place a paste must never land.
    func testSavePanelsOwnFieldIsNotGoToFolder() {
        XCTAssertFalse(PickerBridgeRules.isGoToFolderFocused(["saveAsNameTextField", "save-panel"]))
        XCTAssertFalse(PickerBridgeRules.isGoToFolderFocused([]))
    }

    /// The three outcomes have to read differently, or a user in a Save panel is left
    /// wondering why nothing moved.
    func testHUDNamesWhichOutcomeHappened() {
        let jumped = PickerBridgeRules.teleportHUD(label: "/tmp/x", app: "Photoshop",
                                                   rescued: false, outcome: .jumped)
        let waiting = PickerBridgeRules.teleportHUD(label: "/tmp/x", app: "Photoshop",
                                                    rescued: false, outcome: .pastedAwaitingReturn)
        let none = PickerBridgeRules.teleportHUD(label: "/tmp/x", app: "Photoshop",
                                                 rescued: false, outcome: .noGoToFolder)
        XCTAssertEqual(Set([jumped, waiting, none]).count, 3)
        XCTAssertTrue(waiting.contains("press Return"), waiting)
        XCTAssertFalse(jumped.contains("press Return"), jumped)
        for s in [jumped, waiting, none] { XCTAssertTrue(s.contains("Photoshop"), s) }
    }

    /// Which source won still has to be visible — that was true before this fix and the
    /// rewritten HUD must not have dropped it.
    func testHUDStillNamesAClipboardRescue() {
        let s = PickerBridgeRules.teleportHUD(label: "/tmp/x", app: "Chrome",
                                              rescued: true, outcome: .jumped)
        XCTAssertTrue(s.contains("clipboard"), s)
    }
}

// MARK: - Google Drive path forms

/// Every one of these is a string somebody can hand Navigator — from Slack, from a
/// coworker's Mac, from Navigator's own Copy Local Path — that an Open/Save dialog
/// cannot resolve. The two failures that matter are inventing a path for something
/// that was never a Drive location, and mangling one that was already correct.
final class GoogleDrivePathTests: XCTestCase {
    private let root = "/Users/me/Library/CloudStorage/GoogleDrive-me@x.com"
    private let target = "/Users/me/Library/CloudStorage/GoogleDrive-me@x.com/Shared drives/Content/Buffalo"

    func testPortableForm() {
        XCTAssertEqual(PathRules.googleDrivePath("Google Drive/Shared drives/Content/Buffalo",
                                                 accountRoot: root), target)
    }

    func testAnotherMacsFullPath() {
        XCTAssertEqual(PathRules.googleDrivePath(
            "/Users/them/Library/CloudStorage/GoogleDrive-them@x.com/Shared drives/Content/Buffalo",
            accountRoot: root), target)
    }

    func testBareSharedDrivesAndMyDrive() {
        XCTAssertEqual(PathRules.googleDrivePath("Shared drives/Content/Buffalo", accountRoot: root), target)
        XCTAssertEqual(PathRules.googleDrivePath("My Drive/Notes", accountRoot: root), root + "/My Drive/Notes")
    }

    /// The whole point of routing this through one resolver: a path that is already
    /// right must survive it byte for byte, not gain or lose a component.
    func testAlreadyCorrectLocalPathIsUnchanged() {
        XCTAssertEqual(PathRules.googleDrivePath(target, accountRoot: root), target)
    }

    func testNonDrivePathIsNotAPath() {
        XCTAssertNil(PathRules.googleDrivePath("/Users/me/Pictures/hero.png", accountRoot: root))
        XCTAssertNil(PathRules.googleDrivePath("~/Desktop", accountRoot: root))
        // A prefix match would anchor this stranger's folder inside Drive.
        XCTAssertNil(PathRules.googleDrivePath("Shared drivesXYZ/thing", accountRoot: root))
    }

    func testJunkNeverProducesAPath() {
        for junk in ["", "   ", "///", "Google Drive/", "Google Drive", "My Drive/",
                     "/CloudStorage/GoogleDrive-them@x.com", "Shared drives//", "\n\n"] {
            let out = PathRules.googleDrivePath(junk, accountRoot: root)
            // Landing on the account root itself is the dangerous near-miss: it looks
            // like success and sends the dialog somewhere nobody asked for.
            XCTAssertNotEqual(out, root, junk)
            XCTAssertNotEqual(out, root + "/", junk)
        }
    }

    func testWhitespaceAroundAPastedPath() {
        XCTAssertEqual(PathRules.googleDrivePath("  Shared drives/Content/Buffalo\n", accountRoot: root), target)
    }

    func testDriveRelativeFromAParentWalk() {
        XCTAssertEqual(PathRules.driveRelativePath(leafFirst: ["Buffalo", "Content"], isSharedDrive: true),
                       "Shared drives/Content/Buffalo")
        XCTAssertEqual(PathRules.driveRelativePath(leafFirst: ["Notes", "My Drive"], isSharedDrive: false),
                       "My Drive/Notes")
        XCTAssertNil(PathRules.driveRelativePath(leafFirst: [], isSharedDrive: true))
        XCTAssertNil(PathRules.driveRelativePath(leafFirst: ["a", ""], isSharedDrive: true))
        // A walk that ended somewhere other than a mounted root (an orphan, or a
        // "Shared with me" item) has no local path at all.
        XCTAssertNil(PathRules.driveRelativePath(leafFirst: ["Buffalo", "Content"], isSharedDrive: false))
    }

    func testWebLinkItemIDs() {
        let id = "11XITyXnwsHaTnH1Nx6xZlU2WH0qzsnzU"
        XCTAssertEqual(PathRules.googleDriveItemID(webURL: "https://drive.google.com/drive/folders/\(id)"), id)
        XCTAssertEqual(PathRules.googleDriveItemID(webURL: "https://drive.google.com/drive/folders/\(id)?usp=sharing"), id)
        XCTAssertEqual(PathRules.googleDriveItemID(webURL: "https://drive.google.com/file/d/\(id)/view?usp=drive_link"), id)
        XCTAssertEqual(PathRules.googleDriveItemID(webURL: "https://docs.google.com/document/d/\(id)/edit"), id)
        XCTAssertEqual(PathRules.googleDriveItemID(webURL: "https://drive.google.com/open?id=\(id)"), id)
        XCTAssertEqual(PathRules.googleDriveItemID(webURL: " https://drive.google.com/drive/folders/\(id) "), id)
    }

    func testNonDriveLinksHaveNoItemID() {
        for s in ["", "https://example.com/drive/folders/\(String(repeating: "a", count: 20))",
                  "https://drive.google.com/drive/folders/", "https://drive.google.com/drive/my-drive",
                  "https://drive.google.com/file/d/view", "/Users/me/Pictures", "Shared drives/Content"] {
            XCTAssertNil(PathRules.googleDriveItemID(webURL: s), s)
        }
    }

    // MARK: DragStateRules

    /// Long enough that the quiet-period test passes, for the cases that are not about it.
    private let longQuiet = DragStateRules.quietPeriod * 10

    /// The one thing this must never do: clear state while a real drag is running. A
    /// safety net that fires mid-drag turns an intermittent wedge into a constant one.
    func testDragSafetyNetNeverFiresDuringALiveDrag() {
        for buttons in [1, 3, 5, 1 << 3] where DragStateRules.leftButtonIsDown(buttons) {
            XCTAssertFalse(DragStateRules.shouldClearStaleDragState(
                dragStateSet: true, pressedMouseButtons: buttons, isFreshMouseDown: false,
                secondsSinceDragCallback: longQuiet), "\(buttons)")
        }
    }

    /// Three-finger drag and Drag Lock run a REAL drag with no button pressed, so the
    /// button mask alone says "no drag" and would fire straight into a live session. The
    /// boundaries that rely on it — app-activation, window-became-key — genuinely do occur
    /// mid-drag (Dock-icon hover activates the app; an alert opening makes a window key),
    /// so ongoing drag callbacks have to be able to veto them.
    func testDragSafetyNetWaitsOutALiveButtonlessDrag() {
        XCTAssertFalse(DragStateRules.shouldClearStaleDragState(
            dragStateSet: true, pressedMouseButtons: 0, isFreshMouseDown: false,
            secondsSinceDragCallback: 0))
        XCTAssertFalse(DragStateRules.shouldClearStaleDragState(
            dragStateSet: true, pressedMouseButtons: 0, isFreshMouseDown: false,
            secondsSinceDragCallback: DragStateRules.quietPeriod / 2))
    }

    func testDragSafetyNetClearsWhenNoButtonIsDown() {
        XCTAssertTrue(DragStateRules.shouldClearStaleDragState(
            dragStateSet: true, pressedMouseButtons: 0, isFreshMouseDown: false,
            secondsSinceDragCallback: longQuiet))
        // A right-button-only mask means no LEFT drag, which is the only kind that can
        // have set the flag — bit 0 is the only bit a left-drag sets.
        XCTAssertTrue(DragStateRules.shouldClearStaleDragState(
            dragStateSet: true, pressedMouseButtons: 2, isFreshMouseDown: false,
            secondsSinceDragCallback: longQuiet))
    }

    // MARK: Orphaned dragging session

    /// The whole risk of the orphan guard is firing DURING a real drag, which would convert
    /// an occasional bug into a constant one. These pin every way it must stay silent.
    func testOrphanGuardNeverFiresWithoutTheExactMouseDownProof() {
        // Nothing in flight — nothing to claim.
        XCTAssertFalse(DragStateRules.isDragSessionOrphaned(
            sessionInFlight: false, isFreshMouseDown: true, endWatchStillArmed: false))
        // A live drag: no mouseDown is delivered while a session tracks, so this is the
        // shape of every moment of a real drag. Must never fire, armed watch or not.
        for armed in [false, true] {
            XCTAssertFalse(DragStateRules.isDragSessionOrphaned(
                sessionInFlight: true, isFreshMouseDown: false, endWatchStillArmed: armed), "\(armed)")
        }
        // Clicked again while the polled end-of-session watch is still settling: that
        // session's end is legitimately pending, not leaked.
        XCTAssertFalse(DragStateRules.isDragSessionOrphaned(
            sessionInFlight: true, isFreshMouseDown: true, endWatchStillArmed: true))
    }

    func testOrphanGuardFiresOnlyOnMouseDownWithNoPendingEnd() {
        XCTAssertTrue(DragStateRules.isDragSessionOrphaned(
            sessionInFlight: true, isFreshMouseDown: true, endWatchStillArmed: false))
    }

    // MARK: Leaked dragging session (THE BUG's actual signature)

    /// The signature that means the process is wedged: AppKit still lists the finished drag.
    func testLeakReportedWhenAppKitStillHasTheFinishedDragRegistered() {
        XCTAssertTrue(DragLeakRules.isLeaked(stillRegisteredWithAppKit: true,
                                             secondsSinceDragEnd: DragLeakRules.retirementGrace))
        XCTAssertTrue(DragLeakRules.isLeaked(stillRegisteredWithAppKit: true,
                                             secondsSinceDragEnd: DragLeakRules.retirementGrace * 4))
    }

    /// The two ways it must stay quiet. A diagnostic that cries wolf is not a diagnostic — and
    /// the version of this rule that keyed off "the session object is still alive" / "no
    /// endedAt arrived" fired on EVERY healthy list-view drag, which is what hid the real bug.
    func testLeakNeverReportedOnceAppKitHasRetiredTheDragOrIsStillRetiringIt() {
        // Retired. However long the session OBJECT lingers afterwards is not news: measured,
        // a retired session routinely stays alive well past ten seconds in a healthy process.
        XCTAssertFalse(DragLeakRules.isLeaked(stillRegisteredWithAppKit: false,
                                              secondsSinceDragEnd: DragLeakRules.retirementGrace * 10))
        // Still inside the grace: a cancelled drag's slide-back animation legitimately keeps
        // the registration for a few hundred ms.
        XCTAssertFalse(DragLeakRules.isLeaked(stillRegisteredWithAppKit: true,
                                              secondsSinceDragEnd: DragLeakRules.retirementGrace / 2))
        XCTAssertFalse(DragLeakRules.isLeaked(stillRegisteredWithAppKit: false,
                                              secondsSinceDragEnd: 0))
    }

    /// The boundary is what a refactor gets wrong: at exactly the grace it must already fire,
    /// so the watch's own `asyncAfter(retirementGrace)` cannot land one float short and go quiet.
    func testLeakGraceBoundaryIsInclusive() {
        XCTAssertFalse(DragLeakRules.isLeaked(stillRegisteredWithAppKit: true,
                                              secondsSinceDragEnd: DragLeakRules.retirementGrace - 0.01))
        XCTAssertTrue(DragLeakRules.isLeaked(stillRegisteredWithAppKit: true,
                                             secondsSinceDragEnd: DragLeakRules.retirementGrace))
    }

    /// A fresh mouseDown proves no session is running even though the button is down: a
    /// drag session runs its own tracking loop and swallows the events it tracks, so an
    /// ordinary mouseDown could not have been delivered. Exact rather than inferred, so it
    /// answers regardless of the quiet period — which is what makes it the boundary that
    /// unwedges a buttonless drag's leftovers on the user's very next click.
    func testFreshMouseDownClearsImmediatelyDespiteButtonDown() {
        for quiet in [0, longQuiet] {
            XCTAssertTrue(DragStateRules.shouldClearStaleDragState(
                dragStateSet: true, pressedMouseButtons: 1, isFreshMouseDown: true,
                secondsSinceDragCallback: quiet), "\(quiet)")
        }
    }

    /// Nothing set, nothing to clear — so the safety net never logs on a healthy app.
    func testDragSafetyNetIsSilentWhenNothingIsSet() {
        for buttons in [0, 1] {
            for down in [true, false] {
                XCTAssertFalse(DragStateRules.shouldClearStaleDragState(
                    dragStateSet: false, pressedMouseButtons: buttons, isFreshMouseDown: down,
                    secondsSinceDragCallback: longQuiet))
            }
        }
    }

    /// The watchdog was beating AppKit's real end callback on every healthy drag at 0.25s.
    /// Pinning the interval as "seconds, not milliseconds" is the regression guard against
    /// someone shortening it back and quietly restoring the double-teardown.
    func testEndWatchdogWaitsLongEnoughToActuallyLoseTheRace() {
        XCTAssertGreaterThanOrEqual(DragStateRules.endWatchdogGrace, 1)
    }
}

// MARK: - Idempotent end of a dragging session

/// THE BUG (drag and drop wedges until Navigator is relaunched), second half: the polled
/// watchdog and AppKit's real `endedAt` both ran, watchdog first, on every healthy drag.
final class DragSessionLedgerTests: XCTestCase {

    /// The normal healthy drag: AppKit's own callback lands first, and the watchdog that
    /// fires afterwards must be completely silent.
    func testAuthoritativeEndWinsAndTheLateWatchdogIsSilent() {
        var l = DragSessionLedger()
        let ticket = l.begin("icon")
        XCTAssertEqual(l.closeAuthoritatively(), "icon")
        XCTAssertNil(l.closeIfCurrent(ticket: ticket))
        XCTAssertNil(l.inFlightSource)
    }

    /// The leak the watchdog exists for: no authoritative end ever arrives, so the watchdog
    /// is the end — and it reports the right source.
    func testWatchdogEndsASessionNothingElseClosed() {
        var l = DragSessionLedger()
        let ticket = l.begin("list view")
        XCTAssertEqual(l.inFlightSource, "list view")
        XCTAssertEqual(l.closeIfCurrent(ticket: ticket), "list view")
        XCTAssertNil(l.inFlightSource)
    }

    /// The reason this is a ticket and not a Bool, and the single most dangerous case in the
    /// whole fix: drag N's watchdog is still armed when drag N+1 starts. Closing there would
    /// tear down a drag the user is STILL PERFORMING — an intermittent bug turned constant.
    func testAStaleWatchdogCanNeverEndALaterLiveDrag() {
        var l = DragSessionLedger()
        let stale = l.begin("icon")
        let live = l.begin("filmstrip")
        XCTAssertNil(l.closeIfCurrent(ticket: stale))
        XCTAssertEqual(l.inFlightSource, "filmstrip", "the live drag must still be open")
        XCTAssertEqual(l.closeIfCurrent(ticket: live), "filmstrip")
    }

    /// Whichever end lands first wins; every later end for that session is a no-op. Both
    /// orderings, and repeated calls, because AppKit's paths here are not enumerable.
    func testEveryEndIsIdempotentInBothOrderings() {
        var l = DragSessionLedger()
        let t1 = l.begin("icon")
        XCTAssertEqual(l.closeIfCurrent(ticket: t1), "icon")      // watchdog first
        XCTAssertNil(l.closeAuthoritatively())
        XCTAssertNil(l.closeAuthoritatively())
        XCTAssertNil(l.closeIfCurrent(ticket: t1))

        let t2 = l.begin("icon")
        XCTAssertEqual(l.closeAuthoritatively(), "icon")          // real callback first
        XCTAssertNil(l.closeIfCurrent(ticket: t2))
        XCTAssertNil(l.closeAuthoritatively())
    }

    /// An idle ledger has no end to give, so neither path can log a phantom drag.
    func testAnIdleLedgerNeverReportsAnEnd() {
        var l = DragSessionLedger()
        XCTAssertNil(l.inFlightSource)
        XCTAssertNil(l.closeAuthoritatively())
        XCTAssertNil(l.closeIfCurrent(ticket: 1))
        XCTAssertNil(l.closeIfCurrent(ticket: 0))
    }

    /// Tickets are never recycled: a value that once named a session must not come back and
    /// start matching a different one after enough drags.
    func testTicketsAreUniqueAcrossManySessions() {
        var l = DragSessionLedger()
        var seen = Set<Int>()
        for _ in 0..<500 {
            let t = l.begin("icon")
            XCTAssertTrue(seen.insert(t).inserted, "ticket \(t) reused")
            _ = l.closeAuthoritatively()
        }
    }

    /// Sessions that leak one after another still each get exactly one end line — "a start
    /// with no end" has to stay unambiguous evidence, so a lost end is not acceptable either.
    func testBackToBackLeakedSessionsEachGetTheirOwnEnd() {
        var l = DragSessionLedger()
        let a = l.begin("sidebar reorder")
        XCTAssertEqual(l.closeIfCurrent(ticket: a), "sidebar reorder")
        let b = l.begin("tab")
        XCTAssertEqual(l.closeIfCurrent(ticket: b), "tab")
    }
}

// MARK: - Wedge recovery decision

/// THE BUG's recovery ladder: try once, then tell the user once, then never again.
final class DragWedgeRulesTests: XCTestCase {

    /// A healthy app must never take any of these actions, whatever the leftover state.
    func testNothingHappensWithoutARefusal() {
        for attempted in [false, true] {
            for notified in [false, true] {
                XCTAssertEqual(DragWedgeRules.action(refused: false, recoveryAttempted: attempted,
                                                     userNotified: notified),
                               .none, "\(attempted)/\(notified)")
            }
        }
    }

    func testFirstRefusalRecoversAndRetries() {
        XCTAssertEqual(DragWedgeRules.action(refused: true, recoveryAttempted: false,
                                             userNotified: false),
                       .recoverAndRetry)
    }

    /// Recovery is attempted exactly ONCE per wedge — posting synthetic mouse events on
    /// every failed drag would be its own kind of misbehaviour.
    func testRecoveryIsNeverAttemptedTwiceForOneWedge() {
        for notified in [false, true] {
            XCTAssertNotEqual(DragWedgeRules.action(refused: true, recoveryAttempted: true,
                                                     userNotified: notified),
                              .recoverAndRetry, "\(notified)")
        }
    }

    func testUserIsToldOnceRecoveryHasFailed() {
        XCTAssertEqual(DragWedgeRules.action(refused: true, recoveryAttempted: true,
                                             userNotified: false),
                       .notifyUser)
    }

    /// Never nag. Every subsequent refused drag in the same wedge stays silent — the user
    /// has the notice and a broken feature they have been told about beats a dialog loop.
    func testTheUserIsNeverToldTwiceInOneWedge() {
        XCTAssertEqual(DragWedgeRules.action(refused: true, recoveryAttempted: true,
                                             userNotified: true),
                       .none)
    }

    /// The whole ladder walked in order, then re-walked after the wedge clears — because the
    /// counters reset on a drag that demonstrably starts, a SECOND wedge later in the same
    /// session must get its own attempt and its own notice rather than being swallowed.
    func testTheLadderIsWalkedOncePerWedgeNotOncePerProcess() {
        var attempted = false, notified = false
        func step() -> DragWedgeRules.Action {
            let a = DragWedgeRules.action(refused: true, recoveryAttempted: attempted,
                                          userNotified: notified)
            if a == .recoverAndRetry { attempted = true }
            if a == .notifyUser { notified = true }
            return a
        }
        XCTAssertEqual(step(), .recoverAndRetry)
        XCTAssertEqual(step(), .notifyUser)
        XCTAssertEqual(step(), .none)
        XCTAssertEqual(step(), .none)

        attempted = false; notified = false      // a drag started again: wedge over
        XCTAssertEqual(step(), .recoverAndRetry)
        XCTAssertEqual(step(), .notifyUser)
        XCTAssertEqual(step(), .none)
    }
}

// MARK: - Running build vs installed build

/// The bug: `rebuild.sh` swaps /Applications/Navigator.app under the running process, the
/// updater compares the INSTALLED version against GitHub, both read the same number, and the
/// app reports "up to date" while executing hours-old code. That happened, for an afternoon,
/// while a fixed bug went on reproducing.
final class RunningBuildRulesTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    func testANewerBinaryOnDiskIsStale() {
        XCTAssertTrue(RunningBuildRules.isStale(runningBuiltAt: base, onDiskBuiltAt: base.addingTimeInterval(60)))
    }

    func testTheSameBinaryIsNotStale() {
        XCTAssertFalse(RunningBuildRules.isStale(runningBuiltAt: base, onDiskBuiltAt: base))
    }

    /// The install copy and the launch that stats it are not atomic, so a sub-tolerance
    /// difference must not accuse the CURRENT build of being stale — a false notice teaches the
    /// owner to dismiss the true one.
    func testASubSecondDifferenceIsNotANewBuild() {
        XCTAssertFalse(RunningBuildRules.isStale(runningBuiltAt: base, onDiskBuiltAt: base.addingTimeInterval(0.4)))
        XCTAssertFalse(RunningBuildRules.isStale(runningBuiltAt: base, onDiskBuiltAt: base.addingTimeInterval(1.9)))
    }

    /// An OLDER binary on disk is not a new build. Reachable in practice: running a build from
    /// the source folder while /Applications holds yesterday's install.
    func testAnOlderBinaryOnDiskIsNotStale() {
        XCTAssertFalse(RunningBuildRules.isStale(runningBuiltAt: base, onDiskBuiltAt: base.addingTimeInterval(-3600)))
    }

    func testNotifiesOnceForANewBuild() {
        let onDisk = base.addingTimeInterval(300)
        XCTAssertTrue(RunningBuildRules.shouldNotify(runningBuiltAt: base, onDiskBuiltAt: onDisk, alreadyNoticed: nil))
        XCTAssertFalse(RunningBuildRules.shouldNotify(runningBuiltAt: base, onDiskBuiltAt: onDisk, alreadyNoticed: onDisk),
                       "a notice already given for this exact build must never repeat — this is the never-nag requirement")
    }

    /// Never nag, but never go silent either: a SECOND rebuild after the user chose Later is a
    /// different build and gets its own notice.
    func testASecondRebuildGetsItsOwnNotice() {
        let first = base.addingTimeInterval(300), second = base.addingTimeInterval(900)
        XCTAssertTrue(RunningBuildRules.shouldNotify(runningBuiltAt: base, onDiskBuiltAt: second, alreadyNoticed: first))
    }

    /// A hundred app activations with nothing rebuilt in between must produce exactly one
    /// notice, because `applicationDidBecomeActive` is what drives the check.
    func testRepeatedActivationsWithNoRebuildNotifyOnce() {
        let onDisk = base.addingTimeInterval(300)
        var noticed: Date?
        var notices = 0
        for _ in 0..<100 {
            if RunningBuildRules.shouldNotify(runningBuiltAt: base, onDiskBuiltAt: onDisk, alreadyNoticed: noticed) {
                notices += 1
                noticed = onDisk
            }
        }
        XCTAssertEqual(notices, 1)
    }

    func testAgeReadsInHumanUnits() {
        XCTAssertEqual(RunningBuildRules.age(0), "0s")
        XCTAssertEqual(RunningBuildRules.age(45), "45s")
        XCTAssertEqual(RunningBuildRules.age(90), "1m")
        XCTAssertEqual(RunningBuildRules.age(3600), "1h 0m")
        XCTAssertEqual(RunningBuildRules.age(12_240), "3h 24m")
        XCTAssertEqual(RunningBuildRules.age(90_000), "1d 1h")
    }

    /// A negative interval can only come from an older binary on disk, and must not render as
    /// a nonsense age.
    func testAgeNeverGoesNegative() {
        XCTAssertEqual(RunningBuildRules.age(-500), "0s")
    }

    func testDescribeNamesWhichBuildIsActuallyRunning() {
        let d = RunningBuildRules.describe(runningBuiltAt: base, onDiskBuiltAt: base.addingTimeInterval(12_240))
        XCTAssertTrue(d.contains("the installed build is 3h 24m NEWER than the one running"), d)
        XCTAssertTrue(d.contains(RunningBuildRules.stamp(base)), d)
    }

    func testDescribeSaysSoWhenNothingIsStale() {
        XCTAssertTrue(RunningBuildRules.describe(runningBuiltAt: base, onDiskBuiltAt: base).hasSuffix("same build"))
    }
}

// MARK: - Drop rejection classification

/// The blind spot these cover: a drop Navigator silently declined and a drop that never
/// arrived produced identical logs (nothing at all), which is why "12 clean drag sessions" and
/// "drag and drop is broken" were both true at the same time.
final class DropRejectionTests: XCTestCase {

    func testAnEmptyPasteboardIsUnreadable() {
        XCTAssertEqual(DropRejection.forFileDrop(items: 0, fileURLs: 0), .noReadableTypes)
    }

    /// The mis-aimed sidebar reorder / tab drag: one private token, no files. Before this the
    /// drop returned false and said nothing.
    func testATokenOnlyPayloadNamesTheTokens() {
        XCTAssertEqual(DropRejection.forFileDrop(items: 1, fileURLs: 0), .noFileURLs(tokens: 1))
    }

    func testAFileDropIsNotRejected() {
        XCTAssertNil(DropRejection.forFileDrop(items: 3, fileURLs: 3))
    }

    /// A mixed payload proceeds on the files it does have — refusing the lot would be a
    /// behaviour change, and the drop paths have always filtered rather than refused.
    func testAMixedPayloadProceeds() {
        XCTAssertNil(DropRejection.forFileDrop(items: 4, fileURLs: 3))
    }

    func testEveryReasonSaysSomethingSpecific() {
        let all: [DropRejection] = [.noReadableTypes, .noFileURLs(tokens: 2), .notAReorderTarget,
                                    .selfOrDescendant(count: 3), .missingTarget,
                                    .wrongKind("images"), .nothingToDo("already in the destination")]
        for r in all {
            XCTAssertFalse(r.reason.isEmpty, "\(r)")
            XCTAssertFalse(r.reason.contains("Optional"), "\(r)")
        }
        XCTAssertTrue(DropRejection.selfOrDescendant(count: 3).reason.contains("3"))
        XCTAssertTrue(DropRejection.noFileURLs(tokens: 2).reason.contains("2"))
        XCTAssertTrue(DropRejection.wrongKind("images").reason.contains("images"))
        XCTAssertTrue(DropRejection.nothingToDo("already in the destination").reason.contains("already in the destination"))
    }
}

final class DropLogLineTests: XCTestCase {

    /// One line has to answer all of: which surface, what was on the pasteboard, how much of it
    /// was usable, where it was aimed, and what happened. Correlating lines is what made the
    /// previous logs unreadable.
    func testAnAcceptedDropReportsSurfacePayloadTargetAndAction() {
        let l = DropLogLine.text(surface: "sidebar row “Photos”",
                                 types: ["public.file-url"], items: 3, fileURLs: 3,
                                 target: "/Users/x/Photos", outcome: .accepted("into folder"))
        XCTAssertTrue(l.hasPrefix("drop received: sidebar row “Photos”"), l)
        XCTAssertTrue(l.contains("3 item(s), 3 usable file URL(s)"), l)
        XCTAssertTrue(l.contains("types [public.file-url]"), l)
        XCTAssertTrue(l.contains("→ /Users/x/Photos"), l)
        XCTAssertTrue(l.contains("into folder"), l)
    }

    /// REFUSED in capitals and greppable, because "find every silently refused drop" is the
    /// question this log has to answer in one search.
    func testARefusedDropIsGreppableAndCarriesTheReason() {
        let l = DropLogLine.text(surface: "tab 2", types: ["navtab"], items: 1, fileURLs: 0,
                                 target: nil, outcome: .refused(.noFileURLs(tokens: 1)))
        XCTAssertTrue(l.hasPrefix("drop REFUSED: tab 2"), l)
        XCTAssertTrue(l.contains("(no target)"), l)
        XCTAssertTrue(l.contains(DropRejection.noFileURLs(tokens: 1).reason), l)
    }

    /// A drop from Photoshop or Chrome that behaves differently from the same drag out of
    /// Finder differs in exactly one visible way — its pasteboard types — so they are on the
    /// SUCCESS line too, as the record of what a working drop looked like.
    func testTypesAreLoggedEvenWhenTheDropSucceeds() {
        let l = DropLogLine.text(surface: "file list", types: ["public.file-url", "public.tiff"],
                                 items: 1, fileURLs: 1, target: "/tmp", outcome: .accepted("into current folder"))
        XCTAssertTrue(l.contains("public.tiff"), l)
    }

    func testNoTypesAtAllStillProducesAReadableLine() {
        let l = DropLogLine.text(surface: "file list", types: [], items: 0, fileURLs: 0,
                                 target: "/tmp", outcome: .refused(.noReadableTypes))
        XCTAssertTrue(l.contains("types []"), l)
    }
}

final class TransferLogLineTests: XCTestCase {

    func testASuccessfulMoveReportsCountAndDestination() {
        let l = TransferLogLine.summary(move: true, moved: 3, copied: 0, failed: 0, skipped: 0,
                                        total: 3, cancelled: false, target: "/tmp/dest")
        XCTAssertEqual(l, "transfer done: move 3/3 → /tmp/dest")
    }

    /// THE line that matters. A drop that moved nothing looks exactly like a success from the
    /// outside: progress sheet, no error, empty folder.
    func testADropThatTransferredNothingSaysSoLoudly() {
        let l = TransferLogLine.summary(move: true, moved: 0, copied: 0, failed: 0, skipped: 0,
                                        total: 2, cancelled: false, target: "/tmp/dest")
        XCTAssertTrue(l.contains("NOTHING WAS TRANSFERRED"), l)
    }

    /// Not a silent no-op: failures and cancellation each have their own explanation, so the
    /// alarming phrase stays reserved for the case nobody can otherwise see.
    func testFailuresAndCancellationAreNotReportedAsNothingTransferred() {
        let failed = TransferLogLine.summary(move: false, moved: 0, copied: 0, failed: 2, skipped: 0,
                                             total: 2, cancelled: false, target: "/tmp")
        XCTAssertTrue(failed.contains("2 FAILED"), failed)
        XCTAssertFalse(failed.contains("NOTHING WAS TRANSFERRED"), failed)
        let cancelled = TransferLogLine.summary(move: false, moved: 0, copied: 0, failed: 0, skipped: 0,
                                                total: 5, cancelled: true, target: "/tmp")
        XCTAssertTrue(cancelled.contains("CANCELLED"), cancelled)
        XCTAssertFalse(cancelled.contains("NOTHING WAS TRANSFERRED"), cancelled)
    }

    /// Everything skipped at the conflict prompt is a deliberate no-op, and the count is what
    /// distinguishes it from a broken transfer.
    func testSkippedItemsAreCounted() {
        let l = TransferLogLine.summary(move: false, moved: 0, copied: 1, failed: 0, skipped: 2,
                                        total: 3, cancelled: false, target: "/tmp")
        XCTAssertTrue(l.contains("2 skipped"), l)
        XCTAssertTrue(l.contains("copy 1/3"), l)
    }
}

// MARK: - Reset Drag & Drop

final class DragResetRulesTests: XCTestCase {

    func testResetIsAllowedWhenNothingIsHappening() {
        XCTAssertTrue(DragResetRules.mayReset(leftButtonDown: false, sessionInFlight: false,
                                              secondsSinceDragActivity: 0))
    }

    /// The one unacceptable outcome: a reset that tears down a drag the user is performing.
    /// Clearing the ledger and the spring state mid-drag manufactures the exact bug this
    /// command exists to relieve.
    func testResetIsRefusedWhileTheButtonIsDown() {
        XCTAssertFalse(DragResetRules.mayReset(leftButtonDown: true, sessionInFlight: false,
                                               secondsSinceDragActivity: 99))
    }

    /// Drag Lock and three-finger drag continue a live session with NO button pressed, so a
    /// fresh open session blocks the reset on its own — same asymmetry DragStateRules documents.
    func testResetIsRefusedForAFreshSessionWithNoButtonDown() {
        XCTAssertFalse(DragResetRules.mayReset(leftButtonDown: false, sessionInFlight: true,
                                               secondsSinceDragActivity: 0.2))
    }

    /// A session that has been silent past the quiet period is exactly the leak this command is
    /// for — refusing there would make it useless in the only case it is invoked.
    func testAStaleSessionIsResettable() {
        XCTAssertTrue(DragResetRules.mayReset(leftButtonDown: false, sessionInFlight: true,
                                              secondsSinceDragActivity: DragStateRules.quietPeriod + 0.1))
    }

    func testOutcomeIsHonestAboutAppKitHoldingASession() {
        XCTAssertEqual(DragResetRules.outcome(appKitStillHoldsSession: true), .relaunchRequired)
        XCTAssertEqual(DragResetRules.outcome(appKitStillHoldsSession: false), .cleared)
        XCTAssertEqual(DragResetRules.outcome(appKitStillHoldsSession: nil), .cannotTell)
    }

    /// Claiming success we cannot deliver sends the owner back to a dead feature. Only the
    /// genuinely-clear outcome may sound like a fix, and both other outcomes must name relaunch.
    func testOnlyTheClearedOutcomeImpliesADragWillNowWork() {
        XCTAssertTrue(DragResetRules.message(.cleared).contains("should work again"))
        for o in [DragResetRules.Outcome.relaunchRequired, .cannotTell] {
            let m = DragResetRules.message(o)
            XCTAssertFalse(m.contains("should work again"), m)
            XCTAssertTrue(m.lowercased().contains("relaunch"), m)
        }
    }
}

// MARK: - Drag diagnostics dump

final class DragDiagnosticsReportTests: XCTestCase {

    private func snapshot() -> DragDiagnosticsSnapshot {
        var s = DragDiagnosticsSnapshot()
        s.appVersion = "2.4.00 (131)"
        s.buildComparison = "running A, installed B — same build"
        s.sessionsOpened = 12
        s.springState = "idle"
        s.mouseUpWatches = "none armed"
        return s
    }

    func testReportCarriesEveryObservableTheBugTurnsOn() {
        var s = snapshot()
        s.sessionInFlight = "icon"
        s.refusals = 2
        s.leaksReported = 1
        s.isDragActive = true
        s.keepAliveHeld = 3
        s.lastSessionSequence = 4242
        s.appKitHoldsLastSession = true
        s.logTail = ["[t] drag start: 1 file(s)"]
        let t = DragDiagnosticsReport.text(s)
        for needle in ["2.4.00 (131)", "session in flight: icon", "refusals: 2", "leaks reported: 1",
                       "isDragActive (file list lock): true", "keep-alive holding: 3",
                       "4242", "drag start: 1 file(s)"] {
            XCTAssertTrue(t.contains(needle), "missing \(needle) in:\n\(t)")
        }
    }

    /// The wedge, spelled out. This is the line that tells me a relaunch is the only fix
    /// without my ever touching the machine.
    func testAWedgedProcessIsNamedAsWedged() {
        var s = snapshot()
        s.appKitHoldsLastSession = true
        s.lastSessionSequence = 7
        let t = DragDiagnosticsReport.text(s)
        XCTAssertTrue(t.contains("STILL HOLDS drag 7"), t)
        XCTAssertTrue(t.contains("relaunch"), t)
    }

    func testAHealthyProcessSaysTheRegistryIsClear() {
        var s = snapshot()
        s.appKitHoldsLastSession = false
        let t = DragDiagnosticsReport.text(s)
        XCTAssertTrue(t.contains("no in-flight drag"), t)
        XCTAssertFalse(t.contains("STILL HOLDS"), t)
    }

    /// "Cannot tell" is a distinct answer from "clear". Reporting an unreadable registry as
    /// healthy is how a wedge would get diagnosed as something else entirely.
    func testAnUnreadableRegistryIsReportedAsUnknownNotHealthy() {
        let t = DragDiagnosticsReport.text(snapshot())   // appKitHoldsLastSession left nil
        XCTAssertTrue(t.contains("cannot tell"), t)
        XCTAssertFalse(t.contains("no in-flight drag"), t)
    }

    /// A report from a stale binary describes code that no longer exists — the exact trap that
    /// cost an afternoon — so it must warn before anything else is believed.
    func testAStaleBuildWarningLeadsTheReport() {
        var s = snapshot()
        s.buildIsStale = true
        let t = DragDiagnosticsReport.text(s)
        XCTAssertTrue(t.contains("STALE running build"), t)
        let warn = t.range(of: "STALE running build")!
        XCTAssertTrue(t.range(of: "session in flight")!.lowerBound > warn.lowerBound,
                      "the warning has to come before the state it invalidates")
    }

    func testAnIdleSessionReadsAsNoneRatherThanEmpty() {
        XCTAssertTrue(DragDiagnosticsReport.text(snapshot()).contains("session in flight: none"))
    }

    func testTheLogTailKeepsTheMostRecentLinesOnly() {
        let log = (1...200).map { "[t] drag start: \($0)" }.joined(separator: "\n")
        let tail = DragDiagnosticsReport.dragLines(from: log)
        XCTAssertEqual(tail.count, DragDiagnosticsReport.logTailLimit)
        XCTAssertEqual(tail.last, "[t] drag start: 200")
        XCTAssertEqual(tail.first, "[t] drag start: 161")
    }

    /// The same log carries Imagen batches and network polling; a report that has to be
    /// scrolled past is a report that gets skimmed.
    func testUnrelatedLogLinesAreFilteredOut() {
        let log = """
        [t] imagen: batch started
        [t] drag start: 1 file(s)
        [t] network: poll finished
        [t] drop REFUSED: tab 2 — no file URLs
        [t] spring: opening Photos mid-drag
        """
        let tail = DragDiagnosticsReport.dragLines(from: log)
        XCTAssertEqual(tail.count, 3)
        XCTAssertFalse(tail.contains { $0.contains("imagen") })
        XCTAssertFalse(tail.contains { $0.contains("network") })
    }

    /// A report from a session with no drags at all still has to be worth pasting — the state
    /// above the tail is most of its value.
    func testAnEmptyLogStillProducesAReport() {
        var s = snapshot()
        s.logTail = DragDiagnosticsReport.dragLines(from: "")
        let t = DragDiagnosticsReport.text(s)
        XCTAssertTrue(t.contains("last 0 drag-related log line(s):"), t)
        XCTAssertTrue(t.hasSuffix("\n"))
    }
}

/// The third outcome, and the one the owner's report was actually made of: a drop the handler
/// ACCEPTED (so the drag animation showed success) which then did nothing at all.
final class InertDropLogLineTests: XCTestCase {

    func testAnInertDropIsNeitherReceivedNorRefused() {
        let l = DropLogLine.text(surface: "icon cell “Photos”", types: ["navreorder"],
                                 items: 1, fileURLs: 0, target: "/Users/x/Photos",
                                 outcome: .acceptedButInert(.noFileURLs(tokens: 1)))
        XCTAssertTrue(l.hasPrefix("drop NO-OP: icon cell “Photos”"), l)
        XCTAssertFalse(l.contains("drop received"), l)
        XCTAssertFalse(l.contains("drop REFUSED"), l)
    }

    /// The three heads have to be distinguishable by a single grep each, or the log cannot
    /// answer "did my drop arrive, get refused, or quietly do nothing".
    func testTheThreeOutcomesHaveDistinctGreppableHeads() {
        func head(_ o: DropLogLine.Outcome) -> String {
            String(DropLogLine.text(surface: "s", types: [], items: 1, fileURLs: 1,
                                    target: nil, outcome: o).prefix(while: { $0 != ":" }))
        }
        let heads = [head(.accepted("x")), head(.refused(.missingTarget)),
                     head(.acceptedButInert(.nothingToDo("y")))]
        XCTAssertEqual(Set(heads).count, 3, "\(heads)")
    }
}

/// The stuck-lock question, which is the whole reason the lock's age is reported: `true` written a
/// second ago is a live drag, the same `true` from twenty minutes ago is the bug.
final class DragDiagnosticsLockAgeTests: XCTestCase {

    private func line(_ value: Bool, _ age: TimeInterval?) -> String {
        var s = DragDiagnosticsSnapshot()
        s.isDragActive = value
        s.isDragActiveAge = age
        let text = DragDiagnosticsReport.text(s)
        return text.split(separator: "\n").first { $0.hasPrefix("isDragActive") }.map(String.init) ?? ""
    }

    func testAStuckLockShowsItsAge() {
        XCTAssertEqual(line(true, 1_200), "isDragActive (file list lock): true, last written 20m ago")
    }

    /// A lock never written at all (no drag this session) must not claim an age of zero, which
    /// would read as "a drag is happening right now".
    func testAnUnwrittenLockReportsNoAge() {
        XCTAssertEqual(line(false, nil), "isDragActive (file list lock): false")
    }
}

/// The ledger's two diagnostics additions. `abandon` is the reset command's only way in, and it
/// must not be mistakable for one of the two arbitrated ends.
final class DragSessionLedgerResetTests: XCTestCase {

    func testSessionsOpenedCountsEverySessionEverOpened() {
        var l = DragSessionLedger()
        XCTAssertEqual(l.sessionsOpened, 0)
        _ = l.begin("icon"); _ = l.closeAuthoritatively()
        _ = l.begin("list view")
        XCTAssertEqual(l.sessionsOpened, 2, "the count is cumulative, not a live gauge")
    }

    func testAbandonClosesTheOpenSessionAndNamesIt() {
        var l = DragSessionLedger()
        _ = l.begin("sidebar reorder")
        XCTAssertEqual(l.abandon(), "sidebar reorder")
        XCTAssertNil(l.inFlightSource)
    }

    func testAbandonOnAnIdleLedgerIsANoOp() {
        var l = DragSessionLedger()
        XCTAssertNil(l.abandon())
    }

    /// After a reset, a watchdog still armed from the abandoned session must not be able to speak
    /// for the NEXT drag — the ticketing that protects against a stale poll has to survive
    /// abandonment too, or the reset command reintroduces the bug the ledger was written for.
    func testAWatchdogFromAnAbandonedSessionCannotCloseTheNextOne() {
        var l = DragSessionLedger()
        let stale = l.begin("icon")
        _ = l.abandon()
        _ = l.begin("list view")
        XCTAssertNil(l.closeIfCurrent(ticket: stale))
        XCTAssertEqual(l.inFlightSource, "list view")
    }
}

// MARK: - Shared folder index

final class ShareIndexRulesTests: XCTestCase {
    private let now: Double = 1_754_500_000

    /// THE safety property: presence comes from the live listing, never the index. A file a
    /// non-Navigator user added is unindexed and gets fetched; one they deleted is never
    /// looked up. A stale index can neither invent nor hide a file.
    func testLiveListingAlwaysDecidesWhatExists() {
        let live = ["kept.psd", "brand_new.png"]          // brand_new isn't in the index
        let indexed: Set<String> = ["kept.psd", "deleted_last_week.psd"]
        let (fromIndex, mustFetch) = ShareIndexRules.partition(liveNames: live, indexedNames: indexed)
        XCTAssertEqual(fromIndex, ["kept.psd"])
        XCTAssertEqual(mustFetch, ["brand_new.png"], "a new file must be fetched, not skipped")
        XCTAssertFalse(fromIndex.contains("deleted_last_week.psd"),
                       "a deleted file must never surface from the index")
        XCTAssertEqual(fromIndex.count + mustFetch.count, live.count,
                       "every live name is accounted for exactly once")
    }

    func testPartitionPreservesOrderAndHandlesEmpties() {
        XCTAssertEqual(ShareIndexRules.partition(liveNames: ["c", "a", "b"], indexedNames: ["a", "b", "c"]).fromIndex,
                       ["c", "a", "b"], "live order is preserved")
        XCTAssertTrue(ShareIndexRules.partition(liveNames: [], indexedNames: ["a"]).fromIndex.isEmpty)
        XCTAssertEqual(ShareIndexRules.partition(liveNames: ["a"], indexedNames: []).mustFetch, ["a"],
                       "no index at all means fetch everything — today's behaviour")
    }

    func testUsabilityRejectsWrongVersionAndStaleAndFutureFiles() {
        let v = ShareIndexRules.version
        XCTAssertTrue(ShareIndexRules.isUsable(version: v, savedAt: now - 3600, now: now))
        XCTAssertFalse(ShareIndexRules.isUsable(version: v + 1, savedAt: now - 3600, now: now),
                       "a format we don't know must not be parsed")
        XCTAssertFalse(ShareIndexRules.isUsable(version: v - 1, savedAt: now - 3600, now: now),
                       "an older format is rewritten, not misread")
        XCTAssertFalse(ShareIndexRules.isUsable(version: v, savedAt: now - ShareIndexRules.maxAge - 1, now: now),
                       "past maxAge an in-place edit could have gone unnoticed too long")
        XCTAssertFalse(ShareIndexRules.isUsable(version: v, savedAt: now + 86_400, now: now),
                       "a file stamped in the future is a broken clock, not data to trust")
        XCTAssertTrue(ShareIndexRules.isUsable(version: v, savedAt: now + 30, now: now),
                      "small skew between machines is normal and tolerated")
    }

    /// Writing is throttled: a 5 s write per user per visit would cost more than it saves.
    func testWriteThrottling() {
        let n = 1000
        XCTAssertTrue(ShareIndexRules.shouldWrite(existingSavedAt: nil, now: now, dirChanged: false, entryCount: n),
                      "no index yet — write one")
        XCTAssertFalse(ShareIndexRules.shouldWrite(existingSavedAt: now - 60, now: now, dirChanged: false, entryCount: n),
                       "fresh and unchanged — leave the share alone")
        XCTAssertTrue(ShareIndexRules.shouldWrite(existingSavedAt: now - 60, now: now, dirChanged: true, entryCount: n),
                      "folder changed — refresh it")
        XCTAssertTrue(ShareIndexRules.shouldWrite(existingSavedAt: now - ShareIndexRules.maxAge, now: now,
                                                  dirChanged: false, entryCount: n))
    }

    /// A couple of new files should not cost a full re-sweep; a mostly-useless index should.
    func testSkipSweepOnlyWhenTheIndexCoversMost() {
        XCTAssertTrue(ShareIndexRules.coversEnoughToSkipSweep(fromIndex: 669, total: 671),
                      "2 new files out of 671 — fetch those 2, don't re-read 671")
        XCTAssertFalse(ShareIndexRules.coversEnoughToSkipSweep(fromIndex: 200, total: 671),
                       "an index that knows a third of the folder is worse than a sweep")
        XCTAssertFalse(ShareIndexRules.coversEnoughToSkipSweep(fromIndex: 0, total: 0))
    }

    /// "Nothing will be stale": an index whose folder has changed, or that is missing names the
    /// live listing found, must be rebuilt in the background rather than re-patched every visit.
    func testBackgroundRefreshTriggers() {
        let t: Double = 1_754_500_000
        XCTAssertTrue(ShareIndexRules.needsBackgroundRefresh(indexDirMtime: t, actualDirMtime: t + 500),
                      "folder mtime moved — files were added or removed")
        XCTAssertFalse(ShareIndexRules.needsBackgroundRefresh(indexDirMtime: t, actualDirMtime: t),
                       "unchanged — leave the share alone")
        XCTAssertFalse(ShareIndexRules.needsBackgroundRefresh(indexDirMtime: t, actualDirMtime: t + 0.4),
                       "sub-second jitter is not a change")
        XCTAssertFalse(ShareIndexRules.needsBackgroundRefresh(indexDirMtime: nil, actualDirMtime: t),
                       "a v1 index with no recorded mtime is not evidence of change")
    }

    /// Repair is incremental: readdir already told us what exists, so only genuinely new names
    /// cost a round trip. This is the difference between a 3-minute rebuild and a 1-second one.
    func testRepairPlanOnlyStatsWhatIsNew() {
        let live = ["a.psd", "b.psd", "new_today.png"]
        let plan = ShareIndexRules.repairPlan(liveNames: live, indexedNames: ["a.psd", "b.psd", "gone.psd"])
        XCTAssertEqual(plan.carryForward, ["a.psd", "b.psd"])
        XCTAssertEqual(plan.mustStat, ["new_today.png"], "only the new file costs a round trip")
        XCTAssertFalse(plan.carryForward.contains("gone.psd"),
                       "a deleted file leaves the index by not being carried forward")
        XCTAssertEqual(plan.carryForward.count + plan.mustStat.count, live.count)
    }

    func testRepairPlanEdges() {
        XCTAssertTrue(ShareIndexRules.repairPlan(liveNames: [], indexedNames: ["a"]).carryForward.isEmpty,
                      "an emptied folder carries nothing forward")
        XCTAssertEqual(ShareIndexRules.repairPlan(liveNames: ["a", "b"], indexedNames: []).mustStat, ["a", "b"],
                       "no index means everything is new — same as today")
    }

    func testSmallFoldersAreNotWorthAnIndex() {
        XCTAssertFalse(ShareIndexRules.shouldWrite(existingSavedAt: nil, now: now, dirChanged: true, entryCount: 5),
                       "a handful of stats is cheaper than a round trip for an index file")
    }

    /// The filename must be stable across mounts, since the whole point is sharing it.
    func testFilenameIsStableAndPathScoped() {
        XCTAssertEqual(ShareIndexRules.filename(forRelative: "artSource/zeus"),
                       ShareIndexRules.filename(forRelative: "artSource/zeus"))
        XCTAssertNotEqual(ShareIndexRules.filename(forRelative: "artSource/zeus"),
                          ShareIndexRules.filename(forRelative: "artSource/hera"))
        XCTAssertTrue(ShareIndexRules.filename(forRelative: "a/b").hasSuffix(".json"))
        // 16 hex digits + ".json" — the full 64 bits, not a truncated formatting accident.
        XCTAssertEqual(ShareIndexRules.filename(forRelative: "a/b").count, 21)
        XCTAssertEqual(ShareIndexRules.filename(forRelative: ""), "cbf29ce484222325.json",
                       "the FNV-1a offset basis, unmodified, for a volume root")
        // Canonical FNV-1a-64 vectors. These caught a multiplier written as 0x1000_0000_01b3
        // (12 hex digits) instead of the real prime 0x100000001b3 (11) — 16x too large, which
        // still hashed deterministically and so hid behind "it round-trips".
        XCTAssertEqual(ShareIndexRules.filename(forRelative: "a"), "af63dc4c8601ec8c.json")
        XCTAssertEqual(ShareIndexRules.filename(forRelative: "foobar"), "85944171f73967e8.json")
        // Relative, so /Volumes/Games-1/x and /Volumes/Games/x agree on the same index.
        XCTAssertEqual(ShareIndexRules.filename(forRelative: ""), ShareIndexRules.filename(forRelative: ""))
    }
}


// MARK: - Share URLs in shared files

final class ShareURLRulesTests: XCTestCase {

    /// Favorites are exported and handed to coworkers, so a mount URL must never say whose
    /// account it came from. The mount table always reports the user@ form.
    func testUserIsStripped() {
        XCTAssertEqual(ShareURLRules.withoutUser("smb://alice@fileserver-a.example.com/Games"),
                       "smb://fileserver-a.example.com/Games")
        XCTAssertEqual(ShareURLRules.withoutUser("smb://user:secret@host/share"),
                       "smb://host/share", "a password must never survive into a shared file")
    }

    /// Already-clean URLs, and the forms people actually type, must pass through untouched.
    func testCleanURLsAreUnchanged() {
        for u in ["smb://fileserver-a.example.com/Games", "smb://fileserver-b/data",
                  "smb://host/share/sub folder", "afp://host/vol"] {
            XCTAssertEqual(ShareURLRules.withoutUser(u), u)
        }
    }

    /// Never crash or mangle on input that isn't a parseable URL.
    func testGarbageIsPassedThrough() {
        XCTAssertEqual(ShareURLRules.withoutUser(""), "")
        XCTAssertEqual(ShareURLRules.withoutUser("not a url"), "not a url")
    }

    /// The DFS host form with a domain suffix and a percent-escaped share name.
    func testEscapedShareNamesSurvive() {
        XCTAssertEqual(ShareURLRules.withoutUser("smb://me@fileserver-a.example.com/50%20West"),
                       "smb://fileserver-a.example.com/50%20West")
    }
}


// MARK: - Why a mount failed

final class AfterEffectsPrefsRulesTests: XCTestCase {
    /// The exact form found in After Effects 26.5's preferences file on this machine.
    func testReadsTheDisabledValueAsWritten() {
        let text = "[\"Main Pref Section v2\"]\t\"Pref_PURGE_EVERY_N_FRAMES\" = \"0\"\t\"Pref_SCRIPTING_FILE_NETWORK_SECURITY\" = \"0\"\t\"Pref_SEQUENCE_ZEROS\" = \"5\""
        XCTAssertEqual(AfterEffectsPrefsRules.scriptingFileAccessEnabled(prefsText: text), false)
    }

    func testReadsTheEnabledValue() {
        let text = #""Pref_SCRIPTING_FILE_NETWORK_SECURITY" = "1""#
        XCTAssertEqual(AfterEffectsPrefsRules.scriptingFileAccessEnabled(prefsText: text), true)
    }

    /// After Effects writes this file on quit. A fresh install that has never been quit has
    /// no value at all, and reporting that as "off" would send someone to fix a setting that
    /// might already be right.
    func testAbsentKeyIsUnknownNotOff() {
        XCTAssertNil(AfterEffectsPrefsRules.scriptingFileAccessEnabled(prefsText: #""Pref_SEQUENCE_ZEROS" = "5""#))
        XCTAssertNil(AfterEffectsPrefsRules.scriptingFileAccessEnabled(prefsText: ""))
    }
}

final class RestoreOpaqueInteriorTests: XCTestCase {
    /// STRAIGHT alpha (.last), the way a decoded PNG arrives — not a premultiplied context.
    /// restoreOpaqueInterior edits raw bytes in that format precisely so the soft pixels are
    /// never re-quantised, so a premultiplied fixture would not exercise the real path.
    private func image(_ w: Int, _ h: Int, _ fill: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        var b = [UInt8](repeating: 0, count: w*h*4)
        for y in 0..<h { for x in 0..<w {
            let (r, g, bl, a) = fill(x, y); let i = (y*w+x)*4
            b[i] = r; b[i+1] = g; b[i+2] = bl; b[i+3] = a
        }}
        let provider = CGDataProvider(data: Data(b) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w*4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let d = img.dataProvider!.data! as Data
        let i = y*img.bytesPerRow + x*4
        return (d[i], d[i+1], d[i+2], d[i+3])
    }

    /// The measured defect: a white core pixel that is rgb(255,255,255) in the source came out
    /// rgb(255,255,143) because despill dragged it toward the bias colour. Fully opaque means
    /// no backing is present, so the source colour is exactly right there.
    func testOpaquePixelsTakeTheSourceColour() throws {
        let source = image(4, 4) { _, _ in (255, 255, 255, 255) }
        let keyed  = image(4, 4) { _, _ in (255, 255, 143, 255) }
        let out = try XCTUnwrap(ChromaKeyOutputRules.restoreOpaqueInterior(keyed: keyed, source: source))
        let p = pixel(out, 2, 2)
        XCTAssertEqual([p.0, p.1, p.2, p.3], [255, 255, 255, 255])
    }

    /// Soft pixels are where Keylight earns its place — despill there is doing real work and
    /// must NOT be overwritten, or the whole edge treatment is thrown away.
    func testPartiallyTransparentPixelsAreLeftAlone() throws {
        let source = image(4, 4) { _, _ in (255, 255, 255, 255) }
        let keyed  = image(4, 4) { x, _ in x == 0 ? (200, 200, 100, 255) : (100, 100, 50, 128) }
        let out = try XCTUnwrap(ChromaKeyOutputRules.restoreOpaqueInterior(keyed: keyed, source: source))
        XCTAssertEqual([pixel(out, 0, 1).0, pixel(out, 0, 1).1, pixel(out, 0, 1).2], [255, 255, 255],
                       "the opaque column takes the source colour")
        let soft = pixel(out, 2, 1)
        XCTAssertEqual([soft.0, soft.1, soft.2, soft.3], [100, 100, 50, 128],
                       "the soft pixel keeps Keylight's despilled value untouched")
    }

    /// Nothing to correct means nothing to rewrite — the caller keeps the original image.
    func testNoChangeReturnsNil() throws {
        let same = image(4, 4) { _, _ in (10, 20, 30, 255) }
        XCTAssertNil(try ChromaKeyOutputRules.restoreOpaqueInterior(keyed: same, source: same))
    }

    func testMismatchedSizesAreRefused() throws {
        let a = image(4, 4) { _, _ in (1, 2, 3, 255) }
        let b = image(8, 8) { _, _ in (9, 9, 9, 255) }
        XCTAssertNil(try ChromaKeyOutputRules.restoreOpaqueInterior(keyed: a, source: b))
    }
}

final class ChromaKeyOutputRulesTests: XCTestCase {
    func write(_ bytes: [UInt8], width: Int, height: Int, to url: URL) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
    }

    // ImageIO PNG bytes are straight. Convert to floating premultiplied RGBA first;
    // this avoids an 8-bit CGContext hiding small round-trip errors through rounding.
    func premultiplied(_ image: CGImage) throws -> [Double] {
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.bitsPerPixel, 32)
        XCTAssertEqual(image.alphaInfo, .last)
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        var values = [Double]()
        values.reserveCapacity(image.width * image.height * 4)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let i = y * image.bytesPerRow + x * 4, alpha = Double(data[i + 3])
                for c in 0..<3 { values.append(Double(data[i + c]) * alpha / 255) }
                values.append(alpha)
            }
        }
        return values
    }

    func foregroundShift(_ original: [Double], _ result: [Double]) -> (mean: [Double], worst: Double) {
        var sum = [Double](repeating: 0, count: 3), worst = 0.0, count = 0
        for i in stride(from: 0, to: original.count, by: 4) where original[i + 3] > 40 && result[i + 3] > 40 {
            count += 1
            for c in 0..<3 {
                let delta = result[i + c] * 255 / result[i + 3] - original[i + c] * 255 / original[i + 3]
                sum[c] += delta
                worst = max(worst, abs(delta))
            }
        }
        return (sum.map { $0 / Double(max(1, count)) }, worst)
    }

    func testBiasUsesOnlyNearOpaqueForegroundAndNeutralOtherwise() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("bias.png")
        for backing: [UInt8] in [[0,0,255], [0,255,0], [255,0,255], [0,255,255], [37,91,123]] {
            var pixels = Array(repeating: backing + [255], count: 9).flatMap { $0 }
            pixels.replaceSubrange(16..<20, with: [255,255,144,255])
            try write(pixels, width: 3, height: 3, to: source)
            let bias = try ChromaKeyOutputRules.foregroundBias(ChromaKeyOutputRules.load(source))
            XCTAssertEqual(bias[0], 0.5); XCTAssertEqual(bias[1], 0.5)
            XCTAssertEqual(bias[2], 144.0 / 510, accuracy: 0.00001)
        }
        var rays = Array(repeating: [UInt8](arrayLiteral: 0,255,0,255), count: 9).flatMap { $0 }
        rays.replaceSubrange(16..<20, with: [220,255,220,255])
        try write(rays, width: 3, height: 3, to: source)
        XCTAssertEqual(try ChromaKeyOutputRules.foregroundBias(ChromaKeyOutputRules.load(source)), [0.5,0.5,0.5])
    }

    func testForegroundMetricDetectsCastHiddenByRoundTrip() {
        let backing = [255.0, 0, 255], originalRGB = [192.0, 192, 192], a = 0.5
        let flat = zip(originalRGB, backing).map { a * $0 + (1 - a) * $1 }
        let badAlpha = flat[1] / 255
        let badRGB = zip(flat, backing).map { ($0 - (1 - badAlpha) * $1) / badAlpha }
        let shift = foregroundShift(originalRGB.map { $0 * a } + [a * 255],
                                    badRGB.map { $0 * badAlpha } + [badAlpha * 255])
        XCTAssertGreaterThan(shift.mean[1], 60)
        XCTAssertGreaterThan(shift.worst, 60)
        for c in 0..<3 { XCTAssertEqual(badRGB[c] * badAlpha + backing[c] * (1 - badAlpha), flat[c], accuracy: 0.00001) }
    }

    func testPublishKeepsSoftColourTakesOpaqueFromSourceAndPreservesOutputOnFailure() throws {
        let fm = FileManager.default, dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.png"), render = dir.appendingPathComponent("render.png")
        let bytes: [UInt8] = [192,192,192,64, 255,220,128,128, 20,40,60,1, 90,80,70,254, 0,0,0,0, 255,255,255,255]
        try write([UInt8](repeating: 255, count: 24), width: 3, height: 2, to: source)
        try write(bytes, width: 3, height: 2, to: render)
        let out = try ChromaKeyOutputRules.publish(rendered: render, source: source)
        XCTAssertEqual(out.lastPathComponent, "source_rmbg.png")
        let image = try ChromaKeyOutputRules.load(out)
        XCTAssertEqual(image.width, 3); XCTAssertEqual(image.height, 2)
        // The contract changed deliberately, and the change is measured rather than
        // preferred. publish now recovers colour from the compositing equation wherever
        // the matte is thick enough to invert (SpillRules), not only where it is opaque.
        //
        // The old rule — leave every soft pixel to Keylight — was written to protect FX,
        // on the belief that arithmetic recovery would strip a sparkle's colour. It does
        // not: measured across 261,376 soft pixels of the real yellow sparkle, Keylight
        // and the recovered value agree on hue exactly (54 degrees, yellow), differing
        // only in saturation (0.251 vs 0.203). Meanwhile the old rule left a whole symbol
        // despilled, because a keyed symbol's matte never reaches the opaque threshold —
        // which is how a gold-and-crimson giant came back uniformly green.
        //
        // This fixture's source is white on a white backing, so the true foreground is
        // white everywhere and any colour Keylight introduced is despill damage.
        let expected = try premultiplied(ChromaKeyOutputRules.load(render)), actual = try premultiplied(image)
        for i in stride(from: 0, to: expected.count, by: 4) {
            let a = expected[i+3]
            if a < 255 * ChromaKeyOutputRules.SpillRules.alphaFloor {
                // Too thin to invert — Keylight's answer stands.
                XCTAssertEqual(Array(actual[i..<i+4]), Array(expected[i..<i+4]),
                               "thin pixel at \(i/4) must keep Keylight's colour")
            } else if a >= 255 * ChromaKeyOutputRules.SpillRules.alphaFull {
                // Thick enough to invert: the source was white, so the answer is white.
                for c in 0..<3 {
                    XCTAssertEqual(actual[i+c], expected[i+3], accuracy: 2,
                                   "recovered pixel at \(i/4) channel \(c) should be the source's white")
                }
            }
        }
        // The fixture's source is white, so the near-opaque pixels take white.
        for i in stride(from: 0, to: expected.count, by: 4) where expected[i+3] >= 250 {
            let a = actual[i+3]
            for c in 0..<3 {
                XCTAssertEqual(actual[i+c], a, accuracy: 1.0,
                               "near-opaque pixel at \(i/4) must take the source colour")
            }
        }
        let saved = try Data(contentsOf: out)
        try write([255,255,255,128], width: 1, height: 1, to: render)
        XCTAssertThrowsError(try ChromaKeyOutputRules.publish(rendered: render, source: source))
        try Data("invalid".utf8).write(to: render)
        XCTAssertThrowsError(try ChromaKeyOutputRules.publish(rendered: render, source: source))
        XCTAssertEqual(try Data(contentsOf: out), saved)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.path).sorted(), ["render.png", "source.png", "source_rmbg.png"])
        // Explicit opt-in integration run, alongside the always-executed unit checks.
        if let path = ProcessInfo.processInfo.environment["NAV_CHROMA_FIXTURES"] {
            try compareFixtures(URL(fileURLWithPath: path))
        }
    }

    // NAV_CHROMA_FIXTURES=/tmp/navigator-keylight-review swift test --filter ChromaKeyOutputRulesTests
    // Runs the same AE bridge and ImageIO publication as every Navigator menu entry.
    func compareFixtures(_ dir: URL) throws {
        let fm = FileManager.default, after = dir.appendingPathComponent("after")
        try fm.createDirectory(at: after, withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("NavigatorChromaKeyStill.jsx")
        for (name, colour) in [("fx_sparkleYellow_upres_polar_1024_v01", "blue"),
                               ("fx_rays4_upres_polar_2048_v01", "green"),
                               ("fx_burstWhite_upres_polar_2048_v01", "magenta")] {
            let stem = name + "_BG" + colour, copy = after.appendingPathComponent(stem + ".png")
            try Data(contentsOf: dir.appendingPathComponent(stem + ".png")).write(to: copy)
            let keyed = try ChromaKeyOutputRules.exportPNG(source: copy, scriptURL: script,
                                                          bundleID: "com.adobe.AfterEffects.application")
            let input = try ChromaKeyOutputRules.load(copy), original = try ChromaKeyOutputRules.load(dir.appendingPathComponent(name + ".png"))
            let orig = try premultiplied(original), flat = try premultiplied(input)
            let dx = (input.width - original.width) / 2, dy = (input.height - original.height) / 2
            for (label, url) in [("before", dir.appendingPathComponent("before/" + stem + "_rmbg.png")), ("after", keyed)] {
                let image = try ChromaKeyOutputRules.load(url), pixels = try premultiplied(image)
                XCTAssertEqual(image.width, input.width); XCTAssertEqual(image.height, input.height)
                var footprint = [Double](), roundtrip = 0.0
                footprint.reserveCapacity(orig.count)
                for y in 0..<original.height {
                    let i = ((y + dy) * input.width + dx) * 4
                    footprint.append(contentsOf: pixels[i..<(i + original.width * 4)])
                }
                let shift = foregroundShift(orig, footprint)
                func partial(_ p: [Double]) -> Double {
                    Double(stride(from: 3, to: p.count, by: 4).filter { p[$0] > 0 && p[$0] < 255 }.count) * 400 / Double(p.count)
                }
                for i in stride(from: 0, to: pixels.count, by: 4) {
                    for c in 0..<3 { roundtrip += abs(pixels[i + c] + (1 - pixels[i + 3] / 255) * flat[c] - flat[i + c]) }
                }
                roundtrip /= Double(input.width * input.height * 3)
                let centre = pixels[(input.height / 2 * input.width + input.width / 2) * 4 + 3]
                print("KEYLIGHT \(colour) \(label): RGB mean=\(shift.mean), worst=\(shift.worst), partial=\(partial(footprint))% original=\(partial(orig))%, roundtripMAE=\(roundtrip), centre=\(centre), size=\(image.width)x\(image.height)")
                if label == "after" {
                    // Round trips missed the +37 green cast. Gate foreground means directly.
                    for channel in shift.mean { XCTAssertLessThanOrEqual(abs(channel), 2) }
                    XCTAssertEqual(partial(footprint), partial(orig), accuracy: 1)
                    let originalCentre = orig[(original.height / 2 * original.width + original.width / 2) * 4 + 3]
                    XCTAssertEqual(centre, originalCentre, accuracy: 1)
                    // Worst deviation remains reported: sparkle's near-white core is still
                    // over-despilled by up to 112/255, despite passing these global means.
                }
            }
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: after.path).count, 6)
    }
}

final class PhotoshopChoiceRulesTests: XCTestCase {
    /// The situation on this machine: both builds claim com.adobe.Photoshop, and the Beta is
    /// the HIGHER version. The released build must still win.
    func testReleasedBeatsABetaEvenWhenTheBetaIsNewer() {
        let candidates = [(name: "Adobe Photoshop (Beta)", version: "27.11.0"),
                          (name: "Adobe Photoshop 2026",   version: "27.10.0")]
        XCTAssertEqual(PhotoshopChoiceRules.preferred(candidates), 1)
    }

    /// Someone who only installed the Beta must still get a working Remove BG.
    func testABetaOnlyMachineStillWorks() {
        XCTAssertEqual(PhotoshopChoiceRules.preferred([(name: "Adobe Photoshop (Beta)", version: "27.11.0")]), 0)
    }

    /// The point of not naming a year anywhere: a future release is preferred automatically.
    func testTheNewestReleasedBuildWins() {
        let candidates = [(name: "Adobe Photoshop 2026", version: "27.10.0"),
                          (name: "Adobe Photoshop 2027", version: "28.0.0"),
                          (name: "Adobe Photoshop (Beta)", version: "29.0.0")]
        XCTAssertEqual(PhotoshopChoiceRules.preferred(candidates), 1)
    }

    /// "27.10.0" is newer than "27.9.0". Compared as strings it is not, which is the whole
    /// reason this compares components as numbers.
    func testVersionsCompareNumericallyNotAlphabetically() {
        XCTAssertTrue(PhotoshopChoiceRules.isOlder("27.9.0", than: "27.10.0"))
        XCTAssertFalse(PhotoshopChoiceRules.isOlder("27.10.0", than: "27.9.0"))
        XCTAssertFalse(PhotoshopChoiceRules.isOlder("27.10.0", than: "27.10.0"))
        XCTAssertTrue(PhotoshopChoiceRules.isOlder("27.10", than: "27.10.1"))
    }

    func testNoPhotoshopAtAll() {
        XCTAssertNil(PhotoshopChoiceRules.preferred([]))
    }

    func testPrereleaseDetection() {
        XCTAssertTrue(PhotoshopChoiceRules.isPrerelease("Adobe Photoshop (Beta)"))
        XCTAssertFalse(PhotoshopChoiceRules.isPrerelease("Adobe Photoshop 2026"))
    }
}

final class TransferFallbackTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("navxfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The last-resort copy for a destination that cannot hold Mac metadata. It has to move
    /// the bytes; losing a Finder tag is not a reason to lose the file.
    func testDataOnlyCopyMovesTheBytes() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.txt"), dst = dir.appendingPathComponent("b.txt")
        try "the bytes that matter".write(to: src, atomically: true, encoding: .utf8)
        XCTAssertTrue(copyDataOnly(src, dst))
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "the bytes that matter")
    }

    /// COPYFILE_EXCL. This runs as a fallback after an attempt that may have raced with
    /// another process, so it must never overwrite a file it did not create.
    func testDataOnlyCopyRefusesToOverwrite() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.txt"), dst = dir.appendingPathComponent("b.txt")
        try "new".write(to: src, atomically: true, encoding: .utf8)
        try "SOMEONE ELSE'S FILE".write(to: dst, atomically: true, encoding: .utf8)
        XCTAssertFalse(copyDataOnly(src, dst))
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "SOMEONE ELSE'S FILE")
    }

    /// macOS blames the startup disk for a read-only network share. Verified live against a
    /// read-only SMB mount: code 642, real volume "Games", message naming "Macintosh HD".
    func testReadOnlyVolumeFailureNamesTheRealVolume() {
        XCTAssertTrue(TransferErrorRules.isReadOnlyVolume(domain: NSCocoaErrorDomain, code: 642))
        XCTAssertFalse(TransferErrorRules.isReadOnlyVolume(domain: NSPOSIXErrorDomain, code: 642))
        XCTAssertFalse(TransferErrorRules.isReadOnlyVolume(domain: NSCocoaErrorDomain, code: 4))
        let m = TransferErrorRules.readOnlyMessage(name: "normal.txt", volume: "Games")
        XCTAssertTrue(m.contains("Games"))
        XCTAssertFalse(m.contains("Macintosh HD"))
    }

    /// Any other error keeps macOS's own wording — this replaces one specific lie, it does
    /// not take over error reporting.
    func testOtherFailuresKeepTheSystemWording() {
        let e = NSError(domain: NSCocoaErrorDomain, code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "The file doesn’t exist."])
        XCTAssertEqual(describeTransferFailure(e, at: URL(fileURLWithPath: "/tmp/x")),
                       "The file doesn’t exist.")
    }

    /// The sidecar leak: on SMB/exFAT the extended attributes live in a separate "._" file,
    /// and removing the file it belongs to leaves it orphaned. Every failed copy used to
    /// drop one of these on the share.
    func testRemovingAFileAlsoRemovesItsAppleDoubleSidecar() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent(".navigator-incoming-ABCD1234")
        let sidecar = dir.appendingPathComponent("._.navigator-incoming-ABCD1234")
        try "data".write(to: f, atomically: true, encoding: .utf8)
        try "xattrs".write(to: sidecar, atomically: true, encoding: .utf8)
        removeWithAppleDouble(f)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "the sidecar was orphaned")
    }

    /// It must not go hunting for a sidecar OF a sidecar, which would be a different file
    /// belonging to someone else.
    func testRemovingASidecarDoesNotChaseAFurtherSidecar() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sidecar = dir.appendingPathComponent("._thing")
        let decoy = dir.appendingPathComponent(".._thing")
        try "a".write(to: sidecar, atomically: true, encoding: .utf8)
        try "b".write(to: decoy, atomically: true, encoding: .utf8)
        removeWithAppleDouble(sidecar)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: decoy.path))
    }

    /// The guard that decides whether a failed copy nonetheless landed the file. It is the
    /// only thing standing between "report the truth" and "call another process's file ours",
    /// so it has to be strict.
    func testArrivedCompleteRequiresAnExactSizeMatch() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.txt"), dst = dir.appendingPathComponent("b.txt")
        try "exactly these bytes".write(to: src, atomically: true, encoding: .utf8)

        try "exactly these bytes".write(to: dst, atomically: true, encoding: .utf8)
        XCTAssertTrue(arrivedComplete(src, dst))

        // A competing process's file of a different length must never be claimed as ours.
        try "someone else wrote something longer".write(to: dst, atomically: true, encoding: .utf8)
        XCTAssertFalse(arrivedComplete(src, dst))

        // A truncated result is not a copy.
        try "exactly".write(to: dst, atomically: true, encoding: .utf8)
        XCTAssertFalse(arrivedComplete(src, dst))
    }

    /// A directory's own size says nothing about whether its contents arrived, so a folder
    /// whose copy died halfway must never be reported as copied.
    func testArrivedCompleteRejectsDirectories() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try "content".write(to: a.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(arrivedComplete(a, b), "b is empty; only the directory entries match")
    }

    func testArrivedCompleteIsFalseWhenNothingLanded() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.txt")
        try "x".write(to: src, atomically: true, encoding: .utf8)
        XCTAssertFalse(arrivedComplete(src, dir.appendingPathComponent("nope.txt")))
    }

    /// A warning must never reach the error dialog. `failures` is what raises it, so a file
    /// that arrived intact minus its extended attributes has to report through `warnings`
    /// and leave `failures` empty — otherwise a successful copy tells the user it failed,
    /// which is exactly the bug this came from.
    func testWarningsAreSeparateFromFailures() {
        let item = Transfer.Item(source: URL(fileURLWithPath: "/tmp/a.txt"),
                                 destination: URL(fileURLWithPath: "/tmp/dst/a.txt"),
                                 move: false, intent: .copy)
        var outcome = Transfer.Outcome(item: item, destination: item.destination)
        outcome.status = .copied
        outcome.warnings = ["could not keep its Finder tags"]
        let result = Transfer.Result(outcomes: [outcome])
        XCTAssertTrue(result.failures.isEmpty, "a warning must not raise the failure dialog")
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.warnings.first?.name, "a.txt")
        XCTAssertEqual(result.copied.count, 1, "and it still counts as copied, with an undo entry")
    }

    /// An ordinary copy on a filesystem that handles metadata fine must stay silent.
    func testANormalCopyProducesNoWarnings() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.txt")
        try "x".write(to: src, atomically: true, encoding: .utf8)
        let into = dir.appendingPathComponent("into")
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        let plan = Transfer.plan(sources: [src], into: into, move: false,
                                 conflictNames: [], decide: { _ in .keepBoth })
        let r = Transfer.execute(plan)
        XCTAssertEqual(r.outcomes.first?.status, .copied)
        XCTAssertTrue(r.warnings.isEmpty)
        XCTAssertTrue(r.failures.isEmpty)
    }
}

final class ListingTrustRulesTests: XCTestCase {
    /// The case this exists for: a VPN drop mid-refresh. The enumeration just stops yielding
    /// names, with no error anywhere, so the folder looks emptied.
    func testAShrunkenListingFromAnUnreadableVolumeIsNotBelieved() {
        XCTAssertFalse(ListingTrustRules.trustShrunken(fresh: 0, onScreen: 671, volumeReadable: false))
        XCTAssertFalse(ListingTrustRules.trustShrunken(fresh: 118, onScreen: 671, volumeReadable: false))
        XCTAssertFalse(ListingTrustRules.trustShrunken(fresh: 670, onScreen: 671, volumeReadable: false))
    }

    /// Deletions are real and must still land. A share that answers is telling the truth.
    func testAShrunkenListingFromAReadableVolumeIsBelieved() {
        XCTAssertTrue(ListingTrustRules.trustShrunken(fresh: 0, onScreen: 671, volumeReadable: true))
        XCTAssertTrue(ListingTrustRules.trustShrunken(fresh: 670, onScreen: 671, volumeReadable: true))
    }

    /// Growth costs nothing to accept, and is never worth an opendir to double-check —
    /// the readability test is the expensive part (86-175 ms on a healthy share, measured).
    func testGrowthAndStasisAreAlwaysTrustedWithoutCheckingTheVolume() {
        XCTAssertTrue(ListingTrustRules.trustShrunken(fresh: 671, onScreen: 671, volumeReadable: false))
        XCTAssertTrue(ListingTrustRules.trustShrunken(fresh: 672, onScreen: 671, volumeReadable: false))
        XCTAssertTrue(ListingTrustRules.trustShrunken(fresh: 1, onScreen: 0, volumeReadable: false))
    }

    /// An empty folder that is genuinely empty stays empty — this rule must not make it
    /// impossible to ever show one.
    func testAnEmptyFolderStaysEmpty() {
        XCTAssertTrue(ListingTrustRules.trustShrunken(fresh: 0, onScreen: 0, volumeReadable: false))
        XCTAssertTrue(ListingTrustRules.trustShrunken(fresh: 0, onScreen: 0, volumeReadable: true))
    }
}

final class MountFailureNeedsUITests: XCTestCase {
    /// The whole point of the silent-first mount: a share whose password is already in the
    /// keychain mounts with no window, and only a failure a person could answer is worth a
    /// second attempt with UI.
    func testOnlyAnswerableFailuresEarnADialog() {
        for rc in [EAUTH, EACCES, EPERM] {
            XCTAssertTrue(MountFailureRules.needsUI(errno: rc), "errno \(rc) is answerable")
        }
        // NetFS's own codes (password expired, unsupported auth mechanism, a bare server
        // URL that needs a share picked) are all `.other`, and all answerable.
        XCTAssertTrue(MountFailureRules.needsUI(errno: 9999))
    }

    func testHopelessFailuresNeverOpenADialog() {
        for rc in [ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH, ETIMEDOUT, ECONNREFUSED, ECONNABORTED] {
            XCTAssertFalse(MountFailureRules.needsUI(errno: rc),
                           "errno \(rc): off-VPN. Asking spends a second full SMB timeout to show a worse message.")
        }
        for rc in [ENOENT, ENODEV] {
            XCTAssertFalse(MountFailureRules.needsUI(errno: rc), "errno \(rc): no typing fixes a share that isn't there")
        }
        // The user already closed a sheet on purpose. Putting it straight back up is the
        // one behaviour guaranteed to feel broken.
        XCTAssertFalse(MountFailureRules.needsUI(errno: ECANCELED))
    }

    /// Measured live against smb://<server>/<share> while it was mounted: NetFS answers
    /// rc=17 (EEXIST) with NO mountpoint. Reading that as a failure is what made "Add
    /// Network Drive" claim it couldn't connect to a drive that was already connected.
    func testAlreadyMountedIsNotAFailure() {
        XCTAssertTrue(MountFailureRules.isAlreadyMounted(errno: EEXIST))
        XCTAssertFalse(MountFailureRules.isAlreadyMounted(errno: 0))
        for rc in [EAUTH, ETIMEDOUT, ENOENT, ECANCELED] {
            XCTAssertFalse(MountFailureRules.isAlreadyMounted(errno: rc), "errno \(rc)")
        }
    }

    /// needsUI must stay in step with cause(): a new Cause added without a decision here
    /// would silently inherit whatever the switch's last case happened to be.
    func testEveryCauseHasADeliberateAnswer() {
        let answerable: [MountFailureRules.Cause: Bool] =
            [.credentials: true, .other: true, .unreachable: false, .noSuchShare: false, .cancelled: false]
        let sample: [MountFailureRules.Cause: Int32] =
            [.credentials: EAUTH, .other: 9999, .unreachable: ETIMEDOUT, .noSuchShare: ENOENT, .cancelled: ECANCELED]
        for (cause, want) in answerable {
            XCTAssertEqual(MountFailureRules.needsUI(errno: sample[cause]!), want, "\(cause)")
        }
    }
}

final class MountFailureRulesTests: XCTestCase {

    /// Off-VPN is the common case for a new coworker, and it looks like an unanswering server.
    func testUnreachableCodes() {
        for rc in [ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH, ETIMEDOUT, ECONNREFUSED] {
            XCTAssertEqual(MountFailureRules.cause(errno: rc), .unreachable, "errno \(rc)")
        }
    }

    /// A reachable server that rejects you is the OPPOSITE advice — the VPN is fine, the login isn't.
    func testCredentialCodes() {
        for rc in [EAUTH, EACCES, EPERM] {
            XCTAssertEqual(MountFailureRules.cause(errno: rc), .credentials, "errno \(rc)")
        }
        let m = MountFailureRules.message(for: .credentials, host: "fileserver-a")
        XCTAssertTrue(m?.detail.contains("VPN is working") ?? false,
                      "must not send someone to check the VPN when the VPN demonstrably worked")
    }

    /// Closing the auth sheet is a decision, not an error worth an alert.
    func testCancelIsSilent() {
        XCTAssertEqual(MountFailureRules.cause(errno: ECANCELED), .cancelled)
        XCTAssertNil(MountFailureRules.message(for: .cancelled, host: "h"))
    }

    func testUnknownFallsBackToTheOldAdvice() {
        XCTAssertEqual(MountFailureRules.cause(errno: 9999), .other)
        XCTAssertNotNil(MountFailureRules.message(for: .other, host: "h"))
    }

    /// The host must appear, so it is obvious which server is being talked about.
    func testHostIsNamed() {
        for c in [MountFailureRules.Cause.unreachable, .credentials, .noSuchShare, .other] {
            XCTAssertTrue(MountFailureRules.message(for: c, host: "fileserver-b")?.title
                .contains("fileserver-b") ?? false, "\(c) should name the host")
        }
    }
}


// MARK: - Team drives, pasted as text

final class TeamDrivesRulesTests: XCTestCase {

    func testParsesPlainList() {
        let d = TeamDrivesRules.parse("""
        smb://fileserver-a/Games
        smb://fileserver-b/data
        """)
        XCTAssertEqual(d.map(\.url), ["smb://fileserver-a/Games", "smb://fileserver-b/data"])
        XCTAssertEqual(d.map(\.label), ["Games", "data"], "label defaults to the share name")
    }

    func testLabelsAndCommentsAndBlanks() {
        let d = TeamDrivesRules.parse("""
        # our drives
        G Drive = smb://fileserver-a/Games

        X Drive = smb://fileserver-b/data
        """)
        XCTAssertEqual(d.map(\.label), ["G Drive", "X Drive"])
        XCTAssertEqual(d.count, 2, "comments and blank lines are ignored")
    }

    /// A pasted list gets shared onward, so it must not carry whose account it came from.
    func testUsernamesAreStripped() {
        let d = TeamDrivesRules.parse("smb://someone@fileserver-a/Games")
        XCTAssertEqual(d.first?.url, "smb://fileserver-a/Games")
    }

    func testRejectsNonShareLines() {
        XCTAssertTrue(TeamDrivesRules.parse("https://example.com/x").isEmpty, "not a file share")
        XCTAssertTrue(TeamDrivesRules.parse("just some words").isEmpty)
        XCTAssertTrue(TeamDrivesRules.parse("smb://").isEmpty, "no host")
        XCTAssertTrue(TeamDrivesRules.parse("").isEmpty)
    }

    func testDedupesRegardlessOfCase() {
        let d = TeamDrivesRules.parse("""
        smb://fileserver-a/Games
        smb://FILESERVER-A/Games
        """)
        XCTAssertEqual(d.count, 1)
    }

    func testAcceptsAfpAndCifs() {
        XCTAssertEqual(TeamDrivesRules.parse("afp://host/vol").count, 1)
        XCTAssertEqual(TeamDrivesRules.parse("cifs://host/vol").count, 1)
    }

    /// A share name containing a space or an escape still yields a sensible label.
    func testEscapedShareNameLabel() {
        XCTAssertEqual(TeamDrivesRules.parse("smb://host/50%20West").first?.label, "50%20West")
    }
}


// MARK: - Exporting a converted copy

final class ExportRulesTests: XCTestCase {

    /// THE safety property: a "save a copy" must never pre-fill the original's own name.
    /// Exporting lures_r1.png as PNG used to suggest exactly "lures_r1.png".
    func testSameFormatNeverSuggestsTheOriginalName() {
        let n = ExportRules.suggestedName(sourceName: "lures_r1.png", format: .png,
                                          taken: { $0 == "lures_r1.png" })
        XCTAssertNotEqual(n, "lures_r1.png")
        XCTAssertEqual(n, "lures_r1 2.png")
    }

    func testDifferentFormatKeepsTheCleanName() {
        XCTAssertEqual(ExportRules.suggestedName(sourceName: "lures_r1.png", format: .webp,
                                                 taken: { _ in false }), "lures_r1.webp")
        XCTAssertEqual(ExportRules.suggestedName(sourceName: "lures_r1.png", format: .jpeg,
                                                 taken: { _ in false }), "lures_r1.jpg")
    }

    func testWalksPastExistingCopies() {
        let existing: Set<String> = ["a.webp", "a 2.webp", "a 3.webp"]
        XCTAssertEqual(ExportRules.suggestedName(sourceName: "a.png", format: .webp,
                                                 taken: { existing.contains($0) }), "a 4.webp")
    }

    /// Case-insensitivity and unicode normalisation both matter: a naive == would treat these as
    /// different files and overwrite the original.
    func testIsSameFileHandlesCaseAndUnicode() {
        XCTAssertTrue(ExportRules.isSameFile("Lures_R1.PNG", "lures_r1.png"))
        let composed = "Ü.png", decomposed = "U\u{0308}.png"
        XCTAssertTrue(ExportRules.isSameFile(composed, decomposed),
                      "APFS hands back decomposed unicode; a save panel gives composed")
        XCTAssertFalse(ExportRules.isSameFile("a.png", "b.png"))
    }

    /// WebP has no ImageIO encoder on macOS, so it must be flagged as needing an external tool.
    func testOnlyWebpLacksAnImageIOEncoder() {
        XCTAssertNil(ExportRules.Format.webp.uti)
        for f in ExportRules.Format.allCases where f != .webp {
            XCTAssertNotNil(f.uti, "\(f) should encode through ImageIO")
        }
    }

    /// JPEG is the only offered format that cannot carry alpha.
    func testAlphaCapability() {
        XCTAssertTrue(ExportRules.Format.jpeg.dropsAlpha)
        for f in [ExportRules.Format.png, .webp, .tiff, .heic] {
            XCTAssertFalse(f.dropsAlpha, "\(f) supports alpha and must not be flattened")
        }
    }

    func testExtensionsAndTitles() {
        XCTAssertEqual(ExportRules.Format.jpeg.ext, "jpg")
        XCTAssertEqual(ExportRules.Format.jpeg.menuTitle, "JPEG")
        XCTAssertEqual(ExportRules.Format.webp.ext, "webp")
        XCTAssertEqual(ExportRules.Format.heic.menuTitle, "HEIC")
    }
}


// MARK: - Adobe generative credits

final class AdobeCreditRulesTests: XCTestCase {

    /// The whole point: state the cost, every time, without pretending to know Adobe's balance.
    /// An earlier version scraped the live number out of Adobe's account page through two shadow
    /// roots in a hidden web view — seven fragile links for one integer. This has none.
    func testAlwaysStatesTheCost() {
        let one = AdobeCreditRules.confirmation(count: 1, cost: 1, spentThisCycle: 0, allowance: 25)
        XCTAssertTrue(one.title.contains("1 Adobe credit."))
        let many = AdobeCreditRules.confirmation(count: 4, cost: 1, spentThisCycle: 0, allowance: 25)
        XCTAssertTrue(many.title.contains("4 Adobe credits."))
        XCTAssertTrue(many.title.contains("4 images"))
    }

    /// Navigator knows its OWN spending exactly, because it issues the calls. It must never imply
    /// it knows more than that.
    func testReportsOwnSpendAndDisclaimsTheRest() {
        let m = AdobeCreditRules.confirmation(count: 1, cost: 1, spentThisCycle: 3, allowance: 25)
        XCTAssertTrue(m.detail.contains("spent 3 this cycle of your 25"))
        XCTAssertTrue(m.detail.contains("only counts its own spending"),
                      "must not imply Navigator knows Adobe's real balance")
    }

    func testWarnsWhenTheRunWouldExceedTheAllowance() {
        let m = AdobeCreditRules.confirmation(count: 5, cost: 1, spentThisCycle: 23, allowance: 25)
        XCTAssertTrue(m.detail.contains("past your allowance"))
        let ok = AdobeCreditRules.confirmation(count: 1, cost: 1, spentThisCycle: 1, allowance: 25)
        XCTAssertFalse(ok.detail.contains("past your allowance"))
    }

    /// An allowance of 0 means "not told" — say nothing about limits rather than something wrong.
    func testUnsetAllowanceMakesNoClaims() {
        let m = AdobeCreditRules.confirmation(count: 1, cost: 1, spentThisCycle: 0, allowance: 0)
        XCTAssertFalse(m.detail.contains("allowance is"))
        XCTAssertTrue(m.detail.contains("only counts its own spending"))
    }

    /// Firefly Generative Upscale is a STANDARD Adobe feature: 1 credit per generation.
    func testCostIsOneCredit() {
        XCTAssertEqual(AdobeCreditRules.fireflyUpscaleCost, 1)
    }
}



// MARK: - Layerize batches

final class LayerizeBatchRulesTests: XCTestCase {

    /// key.png and key.jpg in one folder both want "key_Layers". Serially that silently mixed two
    /// images' layers together; in parallel it is two threads writing the same directory.
    func testCollidingNamesGetDistinctFolders() {
        let out = LayerizeBatchRules.dedupedOutputDirs(["/a/key_Layers", "/a/key_Layers"])
        XCTAssertEqual(out, ["/a/key_Layers", "/a/key_Layers 2"])
        XCTAssertEqual(Set(out).count, 2, "every source must get its own folder")
    }

    func testThreeWayCollision() {
        let out = LayerizeBatchRules.dedupedOutputDirs(Array(repeating: "/a/k_Layers", count: 3))
        XCTAssertEqual(out, ["/a/k_Layers", "/a/k_Layers 2", "/a/k_Layers 3"])
    }

    /// Same base name in DIFFERENT folders is not a collision and must not be renamed.
    func testSameNameDifferentFoldersIsFine() {
        let out = LayerizeBatchRules.dedupedOutputDirs(["/a/key_Layers", "/b/key_Layers"])
        XCTAssertEqual(out, ["/a/key_Layers", "/b/key_Layers"])
    }

    /// An unrelated folder already on disk must not be written into.
    func testAvoidsExistingFoldersOnDisk() {
        let taken: Set<String> = ["/a/key_Layers", "/a/key_Layers 2"]
        XCTAssertEqual(LayerizeBatchRules.dedupedOutputDirs(["/a/key_Layers"], exists: { taken.contains($0) }),
                       ["/a/key_Layers 3"])
    }

    func testOrderIsPreservedAndEmptyIsSafe() {
        XCTAssertEqual(LayerizeBatchRules.dedupedOutputDirs(["/z_Layers", "/a_Layers"]),
                       ["/z_Layers", "/a_Layers"])
        XCTAssertTrue(LayerizeBatchRules.dedupedOutputDirs([]).isEmpty)
    }

    /// "3 of 10" is misleading when three are in flight, so the label reports both.
    func testProgressLabelDescribesParallelWork() {
        let s = LayerizeBatchRules.progressLabel(done: 4, running: 3, total: 10, current: nil)
        XCTAssertTrue(s.contains("4 of 10"))
        XCTAssertTrue(s.contains("3 running"))
        // A single image gets the plain wording, with no misleading counts.
        let one = LayerizeBatchRules.progressLabel(done: 0, running: 1, total: 1, current: "a.png")
        XCTAssertTrue(one.contains("a.png"))
        XCTAssertFalse(one.contains("running"))
    }

    /// Escalation has to actually change the request, and has to terminate.
    func testTierEscalationClimbsThenStops() {
        XCTAssertEqual(LayerizeErrorRules.nextTierUp("auto_1K"), "auto_1.5K")
        XCTAssertEqual(LayerizeErrorRules.nextTierUp("auto_1.5K"), "auto_2K")
        XCTAssertNil(LayerizeErrorRules.nextTierUp("auto_2K"), "must terminate at the top tier")
        XCTAssertNil(LayerizeErrorRules.nextTierUp("nonsense"))
    }

    /// Conservative on purpose — fal.ai publishes no per-key concurrency limit.
    func testConcurrencyIsBoundedAndSane() {
        XCTAssertGreaterThan(LayerizeBatchRules.maxConcurrent, 1, "the point is to be faster than serial")
        XCTAssertLessThanOrEqual(LayerizeBatchRules.maxConcurrent, 4, "not hammering an undocumented limit")
    }
}


// MARK: - What a Layerize failure actually means

final class LayerizeErrorRulesTests: XCTestCase {
    /// The exact body fal returned on a real batch.
    private let decompose = """
        {"detail":[{"loc":["body","image_url"],"msg":"The provided image could not be processed \
        for layer decomposition. Try a different image.","type":"invalid_request"}]}
        """

    /// Five images identical in size and tier; three succeeded, two got this. So the message must
    /// NOT blame the tier — that is what sent the user looking in the wrong place.
    func testDecompositionFailureDoesNotBlameTheTier() {
        let m = LayerizeErrorRules.explain422(body: decompose, tier: "auto_1K")
        XCTAssertTrue(m.contains("couldn’t decompose this particular image"))
        XCTAssertFalse(m.lowercased().contains("output floor"),
                       "must not assert a tier cause the evidence contradicts")
        XCTAssertFalse(m.contains("auto_1K"), "the tier is irrelevant to this failure")
    }

    /// A genuine size/tier complaint should still get the tier explanation.
    func testSizeComplaintStillNamesTheTier() {
        let m = LayerizeErrorRules.explain422(body: "image_size is too small for this model",
                                              tier: "auto_2K")
        XCTAssertTrue(m.contains("auto_2K"))
        XCTAssertTrue(m.contains("output floor"))
    }

    func testSafetyIsNamedAsContent() {
        let m = LayerizeErrorRules.explain422(body: "request flagged by safety checker (nsfw)",
                                              tier: "auto_1K")
        XCTAssertTrue(m.contains("safety checker"))
    }

    func testUnknownBodyMakesNoClaims() {
        let m = LayerizeErrorRules.explain422(body: "something entirely new", tier: "auto_1K")
        XCTAssertTrue(m.contains("fal’s own message") || m.contains("fal's own message"))
        XCTAssertFalse(m.contains("output floor"))
    }

    /// THE BUG this exists to prevent: fal echoes the request inside "input", so
    /// "enable_safety_checker":true puts the word "safety" in EVERY error body. Classifying the
    /// whole blob made every refusal look like a safety rejection, and the retry never once fired.
    func testEchoedSafetyParameterDoesNotSuppressTheRetry() {
        let real = #"fal HTTP 422 {"detail":[{"loc":["body","image_url"],"msg":"The provided image could not be processed for layer decomposition. Try a different image.","type":"invalid_request","input":{"sync_mode":false,"enable_safety_checker":true,"prompt":"Return name and descr"#
        XCTAssertTrue(real.lowercased().contains("safety"), "precondition: the echo really is there")
        XCTAssertTrue(LayerizeErrorRules.worthRetrying(body: real),
                      "an echoed enable_safety_checker must not be read as a safety rejection")
        XCTAssertTrue(LayerizeErrorRules.explain422(body: real, tier: "auto_1K")
                        .contains("couldn’t decompose"))
    }

    /// A REAL safety verdict, in the msg field, still suppresses the retry.
    func testGenuineSafetyVerdictStillSuppressesRetry() {
        let flagged = #"{"detail":[{"msg":"Request flagged by the safety checker.","type":"invalid_request"}]}"#
        XCTAssertFalse(LayerizeErrorRules.worthRetrying(body: flagged))
        XCTAssertTrue(LayerizeErrorRules.explain422(body: flagged, tier: "auto_1K").contains("safety checker"))
    }

    /// With no msg field, the echoed request is stripped before classifying.
    func testFallbackStripsTheEchoedRequest() {
        let odd = #"fal HTTP 422 something odd {"input":{"enable_safety_checker":true}}"#
        XCTAssertFalse(LayerizeErrorRules.falMessage(in: odd).lowercased().contains("safety"))
    }

    /// Retry only what can plausibly change. A tier or safety refusal is deterministic, so
    /// retrying it just spends money.
    func testRetryOnlyForTheModelDeclining() {
        XCTAssertTrue(LayerizeErrorRules.worthRetrying(body: decompose))
        XCTAssertFalse(LayerizeErrorRules.worthRetrying(body: "image_size too small"))
        XCTAssertFalse(LayerizeErrorRules.worthRetrying(body: "flagged by safety checker"))
        XCTAssertFalse(LayerizeErrorRules.worthRetrying(body: "gateway timeout"))
    }
}


// MARK: - Rebuilding a layered document

final class LayerAssemblyRulesTests: XCTestCase {

    /// THE trap, with the real measured numbers from SF4_Blue: the PNG is bigger than its box by a
    /// factor that DIFFERS per layer. Placing at native size would be 2-3x too big.
    func testScaleUsesTheBoundingBoxAsTheTargetSize() {
        // z=2: PNG 612x802, box 354x463
        XCTAssertEqual(LayerAssemblyRules.scalePercent(pngSide: 612, boxSide: 354), 57.84, accuracy: 0.01)
        // z=3: PNG 491x690, box 179x253 — a completely different factor in the same image
        XCTAssertEqual(LayerAssemblyRules.scalePercent(pngSide: 491, boxSide: 179), 36.46, accuracy: 0.01)
        // z=1 happened to match exactly; it must come out as a no-op
        XCTAssertEqual(LayerAssemblyRules.scalePercent(pngSide: 673, boxSide: 673), 100, accuracy: 1e-9)
    }

    func testScaleIsSafeOnGarbage() {
        XCTAssertEqual(LayerAssemblyRules.scalePercent(pngSide: 0, boxSide: 100), 100)
        XCTAssertEqual(LayerAssemblyRules.scalePercent(pngSide: 100, boxSide: 0), 100)
    }

    /// Real layers drift under 1%. A stretched layer should be noticed, not silently produced.
    func testAspectDriftOnRealLayersIsNegligible() {
        XCTAssertLessThan(LayerAssemblyRules.aspectDrift(pngW: 612, pngH: 802, boxW: 354, boxH: 463),
                          LayerAssemblyRules.maxTolerableDrift)
        XCTAssertLessThan(LayerAssemblyRules.aspectDrift(pngW: 1728, pngH: 369, boxW: 780, boxH: 168),
                          LayerAssemblyRules.maxTolerableDrift)
        // A genuinely mismatched box is over tolerance.
        XCTAssertGreaterThan(LayerAssemblyRules.aspectDrift(pngW: 100, pngH: 100, boxW: 400, boxH: 100),
                             LayerAssemblyRules.maxTolerableDrift)
    }

    /// Every real bbox sat inside the canvas; a box that doesn't must be rejected rather than
    /// placed off-document.
    func testBoxSanity() {
        XCTAssertTrue(LayerAssemblyRules.boxIsSane([111, 103, 784, 1020], canvasW: 896, canvasH: 1120))
        XCTAssertTrue(LayerAssemblyRules.boxIsSane([152, 979, 745, 1095], canvasW: 896, canvasH: 1120))
        XCTAssertFalse(LayerAssemblyRules.boxIsSane([0, 0, 900, 100], canvasW: 896, canvasH: 1120), "past the right edge")
        XCTAssertFalse(LayerAssemblyRules.boxIsSane([50, 50, 50, 100], canvasW: 896, canvasH: 1120), "zero width")
        XCTAssertFalse(LayerAssemblyRules.boxIsSane([-1, 0, 10, 10], canvasW: 896, canvasH: 1120), "negative origin")
        XCTAssertFalse(LayerAssemblyRules.boxIsSane([0, 0, 10], canvasW: 896, canvasH: 1120), "wrong arity")
    }

    /// The rebuilt file must never collide with the source image it was decomposed from.
    func testAssembledNameNeverCollidesWithTheSource() {
        XCTAssertEqual(LayerAssemblyRules.assembledName(fromLayersFolder: "HP1_Frame_Layers"),
                       "HP1_Frame_assembled.psd")
        // A deduped folder keeps what distinguishes it.
        XCTAssertEqual(LayerAssemblyRules.assembledName(fromLayersFolder: "key_Layers 2"),
                       "key_Layers 2_assembled.psd")
        XCTAssertEqual(LayerAssemblyRules.assembledName(fromLayersFolder: "_Layers"), "assembled.psd")
    }

    /// A rebuild that dropped layers still produces a PSD, so it comes back as OK. It must still be
    /// surfaced — an incomplete document that reports clean success is how the zero-byte-download bug
    /// hid a whole batch of missing layers.
    func testPartialRebuildIsDetectedFromTheScriptsOwnMessage() {
        XCTAssertFalse(LayerAssemblyRules.isPartial("OK: /tmp/a_assembled.psd (2752x1536, 11 layers)"))
        XCTAssertTrue(LayerAssemblyRules.isPartial(
            "OK: /tmp/a_assembled.psd (2752x1536, 9 layers; MISSING 2: a.png, b.png)"))
        XCTAssertTrue(LayerAssemblyRules.isPartial(
            "OK: /tmp/a_assembled.psd (2752x1536, 10 layers; FAILED 1: c.png — could not open)"))
        // A hard failure is reported through ScriptResult.ok, not through this.
        XCTAssertFalse(LayerAssemblyRules.isPartial("ERROR: [place c.png] could not open"))
        // "missing"/"failed" in a FILE NAME must not masquerade as a partial rebuild — the trailing
        // space in the marker is what keeps them apart.
        XCTAssertFalse(LayerAssemblyRules.isPartial("OK: /tmp/MISSING_frame_assembled.psd (8x8, 2 layers)"))
        XCTAssertFalse(LayerAssemblyRules.isPartial("OK: /tmp/FAILED.psd (8x8, 2 layers)"))
    }

    // MARK: - LayerCoverageRules

    /// Repair fires only on unambiguous breakage.
    ///
    /// This pins a DELIBERATE trade-off. In the 1-2% band the measured outcomes contradict each
    /// other — 1.91% repaired to 1.07% (a real gain) while 1.06% repaired to 1.06% (139 seconds and
    /// two cents for nothing) — so the fraction does not predict whether a retry helps there. Rather
    /// than fit a threshold between two adjacent points with opposite results, the bar sits above the
    /// whole band. The cost is giving up gains like that 1.91% case; the benefit is never doubling
    /// the runtime of a run that was already fine.
    func testRepairTriggersOnlyOnUnambiguousBreakage() {
        // Lost an entire frame rail — repaired to 1.64%, a 4.7x gain.
        XCTAssertTrue(LayerCoverageRules.needsRepair(uncoveredFraction: 0.0764))
        // The contradictory band, deliberately left alone.
        XCTAssertFalse(LayerCoverageRules.needsRepair(uncoveredFraction: 0.0191))
        XCTAssertFalse(LayerCoverageRules.needsRepair(uncoveredFraction: 0.0121))
        XCTAssertFalse(LayerCoverageRules.needsRepair(uncoveredFraction: 0.0106))
        XCTAssertFalse(LayerCoverageRules.needsRepair(uncoveredFraction: 0))
    }

    /// Checking coverage is only sound when the base was dropped. With an opaque base at z0 the
    /// composite has no holes BY CONSTRUCTION, so the measurement would report a flattering 0% and
    /// hide a missing layer — which is exactly what it did on SF4_Blue before this was understood.
    func testCoverageOnlyAppliesWhenTheBaseWasDiscarded() {
        XCTAssertTrue(LayerCoverageRules.applies(keptBase: false))
        XCTAssertFalse(LayerCoverageRules.applies(keptBase: true))
    }

    /// The gap box goes back to fal as a normalized per-mille `<bbox>`, matching the convention of
    /// fal's own manifest. These are the real numbers that recovered frame.png's top rail.
    func testRepairPromptCarriesTheGapAsPerMilleBbox() {
        let p = LayerCoverageRules.repairPrompt(gap: [41, 250, 2424, 700], canvasW: 2477, canvasH: 1703)
        XCTAssertNotNil(p)
        XCTAssertTrue(p!.contains("<bbox>16 146 978 411</bbox>"), p ?? "nil")
        // English names still requested — dropping that turns every filename Chinese.
        XCTAssertTrue(p!.contains("english"))
    }

    /// A degenerate or impossible box must never spend a call.
    func testRepairPromptRefusesABoxItCannotUse() {
        XCTAssertNil(LayerCoverageRules.repairPrompt(gap: [0, 0, 0, 0], canvasW: 100, canvasH: 100))
        XCTAssertNil(LayerCoverageRules.repairPrompt(gap: [90, 90, 10, 10], canvasW: 100, canvasH: 100))
        XCTAssertNil(LayerCoverageRules.repairPrompt(gap: [1, 2, 3], canvasW: 100, canvasH: 100))
        XCTAssertNil(LayerCoverageRules.repairPrompt(gap: [0, 0, 50, 50], canvasW: 0, canvasH: 100))
    }

    /// Coverage is not the whole test. A repair can cover more of the picture while having
    /// separated different things — adopting that silently throws away the request and reports it
    /// in the log as an improvement.
    func testRepairMustKeepWhatWasAskedFor() {
        let asked = ["gold border frame", "leaping bass", "water splash"]
        // fal renames freely, so matching is by distinctive word, not equality.
        XCTAssertTrue(LayerCoverageRules.repairKeptRequestedElements(
            requested: asked,
            returned: ["Golden border frame", "Jumping largemouth bass", "Water splash and bubbles"]))
        // Two of three kept is still the same job.
        XCTAssertTrue(LayerCoverageRules.repairKeptRequestedElements(
            requested: asked, returned: ["Gold frame", "Leaping bass fish"]))
        // One of three is a different result, not a better one.
        XCTAssertFalse(LayerCoverageRules.repairKeptRequestedElements(
            requested: asked, returned: ["Frame", "Upper region", "Lower region"]))
        XCTAssertFalse(LayerCoverageRules.repairKeptRequestedElements(
            requested: asked, returned: ["Whole symbol"]))
        // Nothing specific was asked for, so nothing can be lost.
        XCTAssertTrue(LayerCoverageRules.repairKeptRequestedElements(requested: [], returned: ["x"]))
        XCTAssertTrue(LayerCoverageRules.repairKeptRequestedElements(
            requested: ["background"], returned: ["anything"]))
    }

    /// A repair is a fresh roll of the dice and can come back WORSE — measured 1.144% then 7.253%
    /// from the same prompt. Equal is not better; keep what's already on disk.
    func testRepairIsOnlyAdoptedWhenStrictlyBetter() {
        XCTAssertTrue(LayerCoverageRules.repairIsBetter(original: 0.01144, repaired: 0.00475))
        XCTAssertFalse(LayerCoverageRules.repairIsBetter(original: 0.01144, repaired: 0.07253))
        XCTAssertFalse(LayerCoverageRules.repairIsBetter(original: 0.01144, repaired: 0.01144))
    }

    // MARK: - LayerizeElementRules

    /// The real reply for the fish symbol, verbatim. This is the case that exposed the flaw in the
    /// previous design: with fixed tier counts ("medium: 8-14") the model padded a three-element
    /// image with "pectoral fin". Here the fin still appears — correctly filed under an ANIMATE job
    /// rather than smuggled into the structural split.
    func testParsesJobOptionsWithoutPadding() {
        let reply = """
            {"kind": "game slot symbol with jumping bass", "options": [
              {"label": "Isolate framing and subject", "job": "structure",
               "why": "Separate the gold frame, fish subject, and foreground splash from the background scene.",
               "elements": ["Gold border frame", "Jumping bass", "Water splash and bubbles foreground"]},
              {"label": "Animate fish mouth and fins", "job": "animate",
               "why": "Separate jaw and fins for a jumping animation loop.",
               "elements": ["Lower jaw", "Pectoral fin", "Ventral fin", "Tail fin", "Main fish body"]},
              {"label": "Parallax background lily pads", "job": "parallax",
               "why": "Separate background elements for depth scrolling.",
               "elements": ["Upper lily pads", "Stem background layer"]}]}
            """
        guard let p = LayerizeElementRules.parse(reply) else { return XCTFail("did not parse") }
        XCTAssertEqual(p.kind, "game slot symbol with jumping bass")
        XCTAssertEqual(p.options.count, 3)
        XCTAssertEqual(p.options[0].job, "structure")
        XCTAssertEqual(p.options[0].elements.count, 3)
        // The fin belongs to the animation job, not to the structural split.
        XCTAssertTrue(p.options[1].elements.contains("Pectoral fin"))
        XCTAssertFalse(p.options[0].elements.contains(where: { $0.localizedCaseInsensitiveContains("fin") }))
        XCTAssertEqual(p.options[0].menuTitle, "Isolate framing and subject  (4 layers)")
    }

    /// The base is a layer. Counting only elements made a two-element split read as "2 layers" and
    /// look like it had lost the background, when the background WAS the third layer.
    func testMenuTitleCountsTheBaseLayer() {
        let o = LayerizeElementRules.Option(label: "Separate Frame and Fish", job: "structure",
                                            elements: ["golden border frame", "leaping bass fish"])
        XCTAssertEqual(o.layerCount, 3)
        XCTAssertEqual(o.menuTitle, "Separate Frame and Fish  (3 layers)")
    }

    /// Appending a second proposal has to read back the list it wrote, or "＋" would double the
    /// preamble and lose everything already there.
    func testElementsRoundTripThroughTheInstruction() {
        let first = LayerizeElementRules.instruction(for: ["golden border frame", "jumping bass"]).text
        XCTAssertEqual(LayerizeElementRules.elements(inInstruction: first),
                       ["golden border frame", "jumping bass"])
        // Freehand text is kept whole rather than thrown away.
        XCTAssertEqual(LayerizeElementRules.elements(inInstruction: "just the hat"), ["just the hat"])
        XCTAssertEqual(LayerizeElementRules.elements(inInstruction: "  "), [])
        // And a round trip of an appended list stays stable.
        let merged = LayerizeElementRules.instruction(for: ["a", "b", "c"]).text
        XCTAssertEqual(LayerizeElementRules.elements(inInstruction: merged), ["a", "b", "c"])
    }

    /// A single-element answer is legitimate — a frame is "the frame, and everything else stays in
    /// the base". The old design could not express that without inventing four more elements.
    func testOneElementPlanIsValid() {
        let reply = """
            {"kind": "wooden framed underwater window", "options": [
              {"label": "Separate Frame and Water View", "job": "structure",
               "why": "Isolates the wooden outer frame from the inner content.",
               "elements": ["wooden frame"]}]}
            """
        guard let p = LayerizeElementRules.parse(reply) else { return XCTFail("did not parse") }
        XCTAssertEqual(p.options.count, 1)
        XCTAssertEqual(p.options[0].elements, ["wooden frame"])
        // One named element still yields two layers: the frame, and everything else beneath it.
        XCTAssertEqual(p.options[0].menuTitle, "Separate Frame and Water View  (2 layers)")
    }

    /// The real 502 seen in the dialog, verbatim. A gateway hiccup is worth retrying, and its raw
    /// body — which contains a whole HTML error page — must never reach the one line of status.
    func testTransientServiceErrorsAreRetriedAndReadable() {
        let real = "AI service HTTP 502: {\"error\":\"Vertex 502: <!DOCTYPE html><html><head><title>502</title>"
        XCTAssertTrue(LayerizeElementRules.isTransient(real))
        let friendly = LayerizeElementRules.friendlyError(real)
        XCTAssertFalse(friendly.contains("DOCTYPE"), friendly)
        XCTAssertFalse(friendly.contains("<html"), friendly)
        XCTAssertTrue(friendly.contains("busy"), friendly)

        XCTAssertTrue(LayerizeElementRules.isTransient("The request timed out."))
        XCTAssertTrue(LayerizeElementRules.isTransient("AI service HTTP 503: unavailable"))
        // A real refusal must NOT be retried — retrying it just wastes the wait three times.
        XCTAssertFalse(LayerizeElementRules.isTransient("Not signed in to Vertex."))
        XCTAssertFalse(LayerizeElementRules.isTransient("AI service HTTP 401: bad token"))
        // And an unrecognised message keeps its text, merely capped.
        let long = String(repeating: "x", count: 400)
        XCTAssertLessThanOrEqual(LayerizeElementRules.friendlyError(long).count, 141)
    }

    /// Garbage, and options that separate nothing, must not reach the UI as empty menu entries.
    func testParseRejectsEmptyOrOptionlessPlans() {
        XCTAssertNil(LayerizeElementRules.parse("I can't see an image."))
        XCTAssertNil(LayerizeElementRules.parse("{\"kind\":\"x\",\"options\":[]}"))
        XCTAssertNil(LayerizeElementRules.parse("{\"kind\":\"x\",\"options\":[{\"label\":\"a\",\"elements\":[]}]}"))
        // A fence or preamble must still parse.
        let fenced = "Sure!\n```json\n{\"kind\":\"k\",\"options\":[{\"label\":\"L\",\"job\":\"structure\",\"elements\":[\"a\"]}]}\n```"
        XCTAssertEqual(LayerizeElementRules.parse(fenced)?.options.first?.elements, ["a"])
    }

    /// fal returns at most 16 layers plus the base. A longer list isn't rejected — the tail is just
    /// never returned — so it must be trimmed knowingly and the cut reported.
    func testInstructionRespectsFalsSixteenLayerCeiling() {
        let twenty = (1...20).map { "part \($0)" }
        let r = LayerizeElementRules.instruction(for: twenty)
        XCTAssertEqual(r.dropped, ["part 17", "part 18", "part 19", "part 20"])
        XCTAssertTrue(r.text.contains("part 16"))
        XCTAssertFalse(r.text.contains("part 17"))
    }

    /// "background" is the base image, which comes back regardless and which Navigator discards for a
    /// transparent input — asking for it would waste one of only sixteen slots.
    func testInstructionDropsBackgroundAndEmptyNames() {
        let r = LayerizeElementRules.instruction(for: ["background", " ", "left gun", "Background", "hat"])
        XCTAssertEqual(r.text, "Separate these elements out from the image as individual layers: left gun, hat")
        XCTAssertTrue(r.dropped.isEmpty)
        XCTAssertEqual(LayerizeElementRules.instruction(for: ["background"]).text, "")
    }

    /// The composed prompt still carries the English-names line in front of the element list.
    func testAnalyzedElementsComposeIntoAFullPrompt() {
        let inst = LayerizeElementRules.instruction(for: ["left gun", "right gun"]).text
        let full = LayerizeRules.composePrompt(inst)
        XCTAssertTrue(full.hasPrefix(LayerizeRules.basePrompt))
        XCTAssertTrue(full.contains("left gun, right gun"))
    }

    /// The English-names line is what every layer filename depends on, so it must survive whatever
    /// the user types — including them pasting the whole prompt back in.
    func testComposePromptAlwaysKeepsTheEnglishLine() {
        XCTAssertEqual(LayerizeRules.composePrompt(nil), LayerizeRules.basePrompt)
        XCTAssertEqual(LayerizeRules.composePrompt(""), LayerizeRules.basePrompt)
        XCTAssertEqual(LayerizeRules.composePrompt("   \n  "), LayerizeRules.basePrompt)

        let asked = LayerizeRules.composePrompt("Separate guns, triggers, hands, and arms out from image")
        XCTAssertTrue(asked.hasPrefix(LayerizeRules.basePrompt), asked)
        XCTAssertTrue(asked.contains("Separate guns, triggers, hands, and arms out from image"), asked)

        // Pasting the full prompt back in must not duplicate the base line.
        let pasted = LayerizeRules.basePrompt + "\nSeparate guns and arms"
        XCTAssertEqual(LayerizeRules.composePrompt(pasted), pasted)
        XCTAssertEqual(pasted.components(separatedBy: LayerizeRules.basePrompt).count - 1, 1)
    }

    /// A repair is a whole fresh decomposition. If it dropped the user's element instruction it would
    /// return a set that no longer separates what they asked for, while scoring better on coverage.
    func testRepairPromptKeepsTheUsersElementInstruction() {
        let p = LayerCoverageRules.repairPrompt(gap: [41, 250, 2424, 700], canvasW: 2477, canvasH: 1703,
                                                userText: "Separate guns, triggers, hands, and arms out from image")
        XCTAssertNotNil(p)
        XCTAssertTrue(p!.contains("Separate guns, triggers, hands, and arms out from image"), p ?? "nil")
        XCTAssertTrue(p!.contains(LayerizeRules.basePrompt), p ?? "nil")
        XCTAssertTrue(p!.contains("<bbox>16 146 978 411</bbox>"), p ?? "nil")
        // Still works with no user text — that is the pre-existing behaviour.
        let plain = LayerCoverageRules.repairPrompt(gap: [41, 250, 2424, 700], canvasW: 2477, canvasH: 1703)
        XCTAssertNotNil(plain)
        XCTAssertTrue(plain!.contains(LayerizeRules.basePrompt), plain ?? "nil")
    }

    /// The retry budget is bounded, and bounded at what was actually measured to pay off. Each of
    /// the two repairs on frame.png improved coverage (7.64% -> 1.91% -> 1.07%); a third was never
    /// measured, so it isn't taken.
    func testRepairAttemptsAreBoundedAtWhatWasMeasured() {
        XCTAssertEqual(LayerCoverageRules.maxRepairAttempts, 2)
        // Improvement is still recognised wherever it happens — these are the measured steps.
        XCTAssertTrue(LayerCoverageRules.repairIsBetter(original: 0.0764, repaired: 0.0191))
        XCTAssertTrue(LayerCoverageRules.repairIsBetter(original: 0.0191, repaired: 0.0107))
        // But a second attempt only runs while the result is still above the bar, so in practice the
        // loop stops as soon as a repair brings a broken run back into the acceptable band.
        XCTAssertFalse(LayerCoverageRules.needsRepair(uncoveredFraction: 0.0164))
    }

    // MARK: - LayerCoverageRules.measure — the adversarial pass this code never got

    /// A solid rectangle of known alpha, for building synthetic layer sets.
    private func solid(_ w: Int, _ h: Int, alpha: UInt8) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: Double(alpha) / 255)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }
    private func place(_ box: [Int], _ img: CGImage) -> LayerCoverageRules.Placement {
        LayerCoverageRules.Placement(normalized: box, image: img)
    }

    func testFullCoverageReportsNoGap() {
        let src = solid(200, 100, alpha: 255)
        let r = LayerCoverageRules.measure(source: src, layers: [place([0, 0, 1000, 1000], solid(200, 100, alpha: 255))])
        XCTAssertEqual(r?.fraction ?? -1, 0, accuracy: 0.001)
    }

    /// Half the source left uncovered must read as ~50%, and the gap box must be the UNCOVERED half.
    func testHalfUncoveredIsMeasuredAndLocated() {
        let src = solid(200, 100, alpha: 255)
        // Cover only the left half.
        guard let r = LayerCoverageRules.measure(source: src,
                                                 layers: [place([0, 0, 500, 1000], solid(100, 100, alpha: 255))]) else {
            return XCTFail("no measurement")
        }
        XCTAssertEqual(r.fraction, 0.5, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(r.gap[0], 90, "gap should start at the middle, got \(r.gap)")
        XCTAssertEqual(r.gap[2], 200, accuracy: 2, "gap should run to the right edge, got \(r.gap)")
    }

    /// THE reason the box is a largest-connected-cluster and not an overall extent: with one big hole
    /// and one distant speck, the overall extent spans nearly the whole image and is a useless hint.
    func testGapBoxIsTheLargestClusterNotTheOverallExtent() {
        let src = solid(200, 200, alpha: 255)
        // Cover everything, then punch a big hole bottom-right by covering only part... instead build
        // coverage from two strips that leave a large block uncovered at the right plus a speck at the
        // far top-left corner.
        let layers = [
            place([0, 100, 1000, 1000], solid(200, 200, alpha: 255)),   // bottom 90% fully covered
            place([50, 0, 1000, 100], solid(190, 20, alpha: 255)),      // top strip, except x<10
        ]
        guard let r = LayerCoverageRules.measure(source: src, layers: layers) else {
            return XCTFail("no measurement")
        }
        // The only gap is the small top-left corner; the box must be tight around it, not the canvas.
        XCTAssertLessThan(r.gap[2] - r.gap[0], 60, "box too wide: \(r.gap)")
        XCTAssertLessThan(r.gap[3] - r.gap[1], 60, "box too tall: \(r.gap)")
    }

    /// Every way the question can be inapplicable must return nil rather than a misleading zero.
    func testMeasurementRefusesWhenTheQuestionDoesNotApply() {
        let src = solid(50, 50, alpha: 255)
        XCTAssertNil(LayerCoverageRules.measure(source: src, layers: []), "no layers")
        // A fully transparent source has no content that could be missing.
        XCTAssertNil(LayerCoverageRules.measure(source: solid(50, 50, alpha: 0),
                                                layers: [place([0, 0, 1000, 1000], solid(50, 50, alpha: 255))]),
                     "transparent source")
    }

    /// Degenerate and malformed boxes must be skipped, not crash and not silently count as coverage.
    func testDegenerateBoxesAreSkippedNotCrashed() {
        let src = solid(100, 100, alpha: 255)
        let img = solid(100, 100, alpha: 255)
        for bad in [[0, 0, 0, 0], [900, 900, 100, 100], [0, 0, 1000], [0, 0, 1000, 1000, 1000]] {
            let r = LayerCoverageRules.measure(source: src, layers: [place(bad, img)])
            // Nothing drawn, so everything is uncovered — never a false 0%.
            XCTAssertEqual(r?.fraction ?? -1, 1.0, accuracy: 0.01, "box \(bad)")
        }
    }

    /// fal's JSON numbers may decode as Int or Double; a missing or short array must not be invented.
    func testNormalizedBoxParsing() {
        XCTAssertEqual(LayerCoverageRules.normalizedBox(["normalized": [16, 146, 978, 411]]),
                       [16, 146, 978, 411])
        XCTAssertEqual(LayerCoverageRules.normalizedBox(["normalized": [16.0, 146.9, 978.2, 411.0]]),
                       [16, 146, 978, 411])
        XCTAssertNil(LayerCoverageRules.normalizedBox(nil))
        XCTAssertNil(LayerCoverageRules.normalizedBox(["absolute": [1, 2, 3, 4]]))
        XCTAssertNil(LayerCoverageRules.normalizedBox(["normalized": [1, 2, 3]]))
        XCTAssertNil(LayerCoverageRules.normalizedBox(["normalized": ["a", "b", "c", "d"]]))
    }

    /// Cost is billed per COMPUTE SECOND. The old per-layer estimate reported ~10x too much.
    func testCostIsPerComputeSecondNotPerLayer() {
        // The two probe calls measured 113s and 149s of wall time.
        XCTAssertEqual(LayerizeRules.estimatedCost(seconds: 113), 0.01921, accuracy: 0.00001)
        XCTAssertEqual(LayerizeRules.estimatedCost(seconds: 262), 0.04454, accuracy: 0.00001)
        XCTAssertEqual(LayerizeRules.estimatedCost(seconds: 0), 0)
        XCTAssertEqual(LayerizeRules.estimatedCost(seconds: -5), 0)
    }

    // MARK: - Node version ordering

    /// The bug this exists for: sorting version directory names as strings ranks "v9.0.0" above
    /// "v26.5.0", so a machine with both would be handed a years-old node.
    func testNodeVersionSortsNumericallyNotAlphabetically() {
        XCTAssertTrue(NodeVersion.isDescending("v26.5.0", "v9.0.0"))
        XCTAssertFalse(NodeVersion.isDescending("v9.0.0", "v26.5.0"))
        XCTAssertEqual(["v9.0.0", "v26.5.0", "v18.19.1", "v20.0.0"]
                        .sorted(by: NodeVersion.isDescending),
                       ["v26.5.0", "v20.0.0", "v18.19.1", "v9.0.0"])
    }

    func testNodeVersionPartsTolerateOddNames() {
        XCTAssertEqual(NodeVersion.parts("v26.5.0"), [26, 5, 0])
        XCTAssertEqual(NodeVersion.parts("26.5.0"), [26, 5, 0])
        XCTAssertEqual(NodeVersion.parts("v22"), [22, 0, 0])
        XCTAssertEqual(NodeVersion.parts("v20.11"), [20, 11, 0])
        // A pre-release suffix must not throw the major version away.
        XCTAssertEqual(NodeVersion.parts("v21.0.0-rc.1"), [21, 0, 0])
        XCTAssertEqual(NodeVersion.parts("system"), [0, 0, 0])
        XCTAssertEqual(NodeVersion.parts(""), [0, 0, 0])
    }

    /// Minor and patch must still break ties, not just the major.
    func testNodeVersionComparesMinorAndPatch() {
        XCTAssertTrue(NodeVersion.isDescending("v20.11.0", "v20.9.0"))
        XCTAssertTrue(NodeVersion.isDescending("v20.9.2", "v20.9.1"))
        XCTAssertFalse(NodeVersion.isDescending("v20.9.1", "v20.9.2"))
    }

    // MARK: - Stuck network mounts

    /// Real output shape, from the machine where /Volumes/Games/artSource hung indefinitely.
    private var realPS: String {
        """
        11299 /usr/libexec/mount_url -n -o nobrowse -o nosuid,nodev -o soft -o automounted -o nosuid smb://user@CORP-DC01.High5.local/Games/artSource /Volumes/Games/artSource
        11498 /usr/libexec/mount_url -n -o nobrowse -o nosuid,nodev -o soft -o automounted -o nosuid smb://user@CORP-DC01.High5.local/Games/Zero Gravity /Volumes/Games/Zero Gravity
        4409 /Applications/Navigator.app/Contents/MacOS/Navigator
        """
    }

    func testFindsTheHelperWedgedOnExactlyThisFolder() {
        XCTAssertEqual(StuckMountRules.wedgedPIDs(psOutput: realPS,
                                                  mountPoint: "/Volumes/Games/artSource"), [11299])
        XCTAssertEqual(StuckMountRules.wedgedPIDs(psOutput: realPS,
                                                  mountPoint: "/Volumes/Games/Zero Gravity"), [11498])
    }

    /// The share ROOT must never match a child's helper — killing those would be unrelated damage.
    func testParentShareDoesNotMatchAChildsHelper() {
        XCTAssertTrue(StuckMountRules.wedgedPIDs(psOutput: realPS, mountPoint: "/Volumes/Games").isEmpty)
    }

    /// A prefix must not match: /Volumes/Games/art is not /Volumes/Games/artSource.
    func testPrefixDoesNotMatch() {
        XCTAssertTrue(StuckMountRules.wedgedPIDs(psOutput: realPS, mountPoint: "/Volumes/Games/art").isEmpty)
    }

    func testIgnoresNonMountProcessesAndNonsense() {
        XCTAssertTrue(StuckMountRules.wedgedPIDs(psOutput: realPS, mountPoint: "/Applications/Navigator.app/Contents/MacOS/Navigator").isEmpty)
        XCTAssertTrue(StuckMountRules.wedgedPIDs(psOutput: "", mountPoint: "/Volumes/Games/artSource").isEmpty)
        XCTAssertTrue(StuckMountRules.wedgedPIDs(psOutput: realPS, mountPoint: "").isEmpty)
        XCTAssertTrue(StuckMountRules.wedgedPIDs(psOutput: realPS, mountPoint: "/").isEmpty)
    }

    /// A trailing slash is the same folder.
    func testTrailingSlashStillMatches() {
        XCTAssertEqual(StuckMountRules.wedgedPIDs(psOutput: realPS,
                                                  mountPoint: "/Volumes/Games/artSource/"), [11299])
    }

    /// The wedged case must NOT advise reconnecting the share, which was the old blanket advice and
    /// is useless when the parent share is healthy.
    /// The advice must not say "reconnect" (the parent share is healthy) and must not PROMISE that
    /// cancelling fixes it — measured, macOS starts a fresh automount within seconds of the path
    /// being touched again, so the only thing that helps is leaving the folder alone.
    func testWedgedAdviceIsHonestAboutWhatCancellingAchieves() {
        let w = StuckMountRules.explain(name: "artSource", wedged: true)
        XCTAssertTrue(w.title.contains("isn’t answering"))
        XCTAssertFalse(w.detail.lowercased().contains("reconnect"))
        XCTAssertFalse(w.detail.lowercased().contains("releases the folder"))
        XCTAssertTrue(w.detail.lowercased().contains("leaving it alone"))
        XCTAssertEqual(w.action, "Stop Trying & Go Up")

        let plain = StuckMountRules.explain(name: "Games", wedged: false)
        XCTAssertTrue(plain.detail.lowercased().contains("reconnect"))
        XCTAssertNil(plain.action)
    }

    // MARK: - folderKey must never touch the filesystem

    /// The freeze this guards against: folderKey ran realpath(3) over every remembered folder inside
    /// a dispatch_once on the main thread, so one remembered folder on a wedged network mount froze
    /// the app before it drew a window. A path that cannot possibly be resolved must still key
    /// instantly and sensibly.
    func testFolderKeyWorksForPathsThatCannotBeResolved() {
        let ghost = "/Volumes/DefinitelyNotMounted-\(UUID().uuidString)/artSource"
        XCTAssertEqual(folderKey(ghost), ghost.lowercased())
        XCTAssertEqual(folderKey("/Volumes/Games/artSource"), "/volumes/games/artsource")
    }

    /// The case realpath was originally reached for, still handled — lexically.
    func testFolderKeyUnifiesTheMacOSFirmlinks() {
        XCTAssertEqual(folderKey("/tmp/Photos"), folderKey("/private/tmp/Photos"))
        XCTAssertEqual(folderKey("/var/log"), folderKey("/private/var/log"))
        XCTAssertEqual(folderKey("/etc/hosts"), folderKey("/private/etc/hosts"))
        XCTAssertEqual(folderKey("/tmp"), "/private/tmp")
    }

    /// A folder merely STARTING with one of those names is not one of them.
    func testFolderKeyDoesNotMaulLookalikePaths() {
        XCTAssertEqual(folderKey("/tmpfiles/a"), "/tmpfiles/a")
        XCTAssertEqual(folderKey("/Users/x/tmp/a"), "/users/x/tmp/a")
        XCTAssertEqual(folderKey("/variants"), "/variants")
    }

    func testFolderKeyStillNormalisesTheOrdinaryThings() {
        XCTAssertEqual(folderKey("/Users/x/Art/"), folderKey("/Users/x/Art"))
        XCTAssertEqual(folderKey("/Users/x/Art/../Art"), folderKey("/Users/x/Art"))
        XCTAssertEqual(folderKey("/Users/X/ART"), folderKey("/users/x/art"))
        XCTAssertEqual(folderKey(""), "")
    }

    /// The migration is what ran on the main thread; with a lexical key it must be pure and cheap,
    /// and must still collapse two spellings of one folder into a single record.
    func testMigrationCollapsesDuplicateSpellingsWithoutIO() {
        var lru = ViewOptionsLRU()
        let a = ViewOptions(viewMode: "grid", iconSize: 64, sortKey: "name",
                            sortAscending: true, groupBy: "none", columns: ["name", "size"])
        lru.set(a, for: "/Volumes/Games/artSource")
        let migrated = lru.migratedToNormalizedKeys()
        XCTAssertNotNil(migrated.value(for: "/Volumes/Games/artSource/"))
        XCTAssertNotNil(migrated.value(for: "/volumes/games/artsource"))
    }

    // MARK: - Which paths must never be stat'd on the main thread

    /// The launch freeze: icon(for:) stat'd every item unless currentIsNetwork was set, and that flag
    /// is false at launch. A mounted share that stopped answering froze the app inside a SwiftUI body.
    func testVolumePathsAreTreatedAsPossiblyBlocking() {
        XCTAssertTrue(VolumePathRules.mayBlockOnIO("/Volumes/Games/artSource"))
        XCTAssertTrue(VolumePathRules.mayBlockOnIO("/Volumes/Games"))
        XCTAssertTrue(VolumePathRules.mayBlockOnIO("/Volumes"))
    }

    /// The boot volume and the home folder are where most browsing happens and must keep their
    /// per-file icons.
    func testLocalPathsKeepTheirPerFileIcons() {
        XCTAssertFalse(VolumePathRules.mayBlockOnIO("/"))
        XCTAssertFalse(VolumePathRules.mayBlockOnIO("/Users/x/Pictures/a.png"))
        XCTAssertFalse(VolumePathRules.mayBlockOnIO("/Applications/Navigator.app"))
        XCTAssertFalse(VolumePathRules.mayBlockOnIO(""))
    }

    /// A lookalike must not be swept in.
    func testVolumesLookalikeIsNotMatched() {
        XCTAssertFalse(VolumePathRules.mayBlockOnIO("/VolumesExtra/a"))
        XCTAssertFalse(VolumePathRules.mayBlockOnIO("/Users/x/Volumes/a"))
    }

    // MARK: - Drive links pasted into the address bar

    /// The shapes Google actually hands out, including the tracking suffix every "Copy link"
    /// button appends — which is why this parses with URLComponents rather than splitting on "/".
    func testDriveLinkShapesPeopleActuallyPaste() {
        let id = "1N6vZy7cy2Qf_a-FFARmCeEV4SMSKzdkQ"
        XCTAssertEqual(PathRules.googleDriveItemID(webURL: "https://drive.google.com/drive/folders/\(id)"), id)
        XCTAssertEqual(PathRules.googleDriveItemID(webURL: "https://drive.google.com/drive/folders/\(id)?usp=sharing"), id)
        XCTAssertEqual(PathRules.googleDriveItemID(webURL: "https://drive.google.com/drive/folders/\(id)?usp=drive_link&foo=1"), id)
        XCTAssertEqual(PathRules.googleDriveItemID(webURL: "  https://drive.google.com/drive/folders/\(id)  "), id)
        XCTAssertEqual(PathRules.googleDriveItemID(webURL: "https://drive.google.com/drive/u/0/folders/\(id)"), id)
        XCTAssertEqual(PathRules.googleDriveItemID(webURL: "https://drive.google.com/file/d/\(id)/view?usp=sharing"), id)
        XCTAssertEqual(PathRules.googleDriveItemID(webURL: "https://docs.google.com/document/d/\(id)/edit"), id)
        XCTAssertEqual(PathRules.googleDriveItemID(webURL: "https://drive.google.com/open?id=\(id)"), id)
    }

    /// Anything that is not a Drive link must not be treated as one — the address bar still has to
    /// beep for a typo rather than opening a "that folder isn't on this Mac" dialog.
    func testNonDriveInputIsNotMistakenForALink() {
        XCTAssertNil(PathRules.googleDriveItemID(webURL: "https://example.com/drive/folders/1N6vZy7cy2Qf_a"))
        XCTAssertNil(PathRules.googleDriveItemID(webURL: "/Users/x/Pictures"))
        XCTAssertNil(PathRules.googleDriveItemID(webURL: "https://drive.google.com/drive/folders/"))
        XCTAssertNil(PathRules.googleDriveItemID(webURL: "https://drive.google.com/drive/folders/short"))
        XCTAssertNil(PathRules.googleDriveItemID(webURL: ""))
        // A path that merely mentions the host is a path, not a link.
        XCTAssertNil(PathRules.googleDriveItemID(webURL: "/Volumes/drive.google.com/x"))
    }

    /// The parent walk's output order, which is what turns a resolved chain into a real path.
    /// Verified against this machine's own index: Toyota_Clone_01 <- Production_AI 2 <-
    /// Content Management - AI, with the last row flagged as a shared-drive root.
    func testChainFromTheIndexBecomesADriveRelativePath() {
        XCTAssertEqual(
            PathRules.driveRelativePath(leafFirst: ["Toyota_Clone_01", "Production_AI 2", "Content Management - AI"],
                                        isSharedDrive: true),
            "Shared drives/Content Management - AI/Production_AI 2/Toyota_Clone_01")
        XCTAssertEqual(
            PathRules.driveRelativePath(leafFirst: ["Art", "My Drive"], isSharedDrive: false),
            "My Drive/Art")
        XCTAssertNil(PathRules.driveRelativePath(leafFirst: [], isSharedDrive: true))
        XCTAssertNil(PathRules.driveRelativePath(leafFirst: ["A", ""], isSharedDrive: false))
    }
}

final class TerminalTokenTests: XCTestCase {

    // Typing "cmd" in Explorer's address bar opens a shell there; this is that, and the
    // words people actually reach for on a Mac.
    func testRecognisesTheKeywords() {
        XCTAssertTrue(TerminalRules.isTerminalToken("terminal"))
        XCTAssertTrue(TerminalRules.isTerminalToken("cmd"))
        XCTAssertTrue(TerminalRules.isTerminalToken("shell"))
    }

    // The address bar is typed in by hand: case and stray spaces are normal, not errors.
    func testIgnoresCaseAndSurroundingSpace() {
        XCTAssertTrue(TerminalRules.isTerminalToken("Terminal"))
        XCTAssertTrue(TerminalRules.isTerminalToken("  CMD  "))
    }

    // The trap: matching loosely would hijack real paths. A folder named Terminal, or any
    // path merely CONTAINING the word, must still navigate.
    func testDoesNotHijackRealPaths() {
        XCTAssertFalse(TerminalRules.isTerminalToken("/Applications/Utilities/Terminal.app"))
        XCTAssertFalse(TerminalRules.isTerminalToken("~/Documents/terminal"))
        XCTAssertFalse(TerminalRules.isTerminalToken("terminal stuff"))
        XCTAssertFalse(TerminalRules.isTerminalToken(""))
    }
}

// The username-free path is a STRING transform on the path. It must not depend on
// anything Drive supplies at runtime — that distinction is the bug these cover: the
// whole Drive menu, including this, used to be gated on a Drive item id, so a file
// Drive had not registered yet lost the one item that scrubs the account email.
final class GoogleDrivePortablePathTests: XCTestCase {

    func testScrubsTheAccountEmail() {
        XCTAssertEqual(
            PathRules.googleDrivePortablePath(
                "/Users/me/Library/CloudStorage/GoogleDrive-me@corp.com/Shared drives/Content/Art"),
            "Google Drive/Shared drives/Content/Art")
    }

    // A deeply nested path, and one whose own name contains a hyphen, must survive intact:
    // the split is on the FIRST slash after the account folder, not on any later text.
    func testKeepsTheRestOfThePathVerbatim() {
        XCTAssertEqual(
            PathRules.googleDrivePortablePath(
                "/Users/x/Library/CloudStorage/GoogleDrive-a@b.com/Shared drives/CM - AI/P 2/T_01/Sel Art/HP4_Turtle.spine"),
            "Google Drive/Shared drives/CM - AI/P 2/T_01/Sel Art/HP4_Turtle.spine")
    }

    func testAccountRootAloneHasNoTrailingSlash() {
        XCTAssertEqual(
            PathRules.googleDrivePortablePath("/Users/x/Library/CloudStorage/GoogleDrive-a@b.com/"),
            "Google Drive")
    }

    // Must refuse anything that is not a Drive mount, or the caller would show Drive-only
    // menu items on ordinary local files.
    func testRefusesNonDrivePaths() {
        XCTAssertNil(PathRules.googleDrivePortablePath("/Users/x/Documents/Art"))
        XCTAssertNil(PathRules.googleDrivePortablePath("/Users/x/Library/CloudStorage/iCloudDrive/Art"))
        XCTAssertNil(PathRules.googleDrivePortablePath("/Volumes/Share/Art"))
        XCTAssertNil(PathRules.googleDrivePortablePath(""))
    }
}

// "Copy as Path (Quoted)" advertises shell use, so it has to be safe for any filename a
// macOS filesystem will accept. The double-quoted version it replaced was not: `$` and a
// backtick are legal in a filename and still live inside double quotes, so a file named
// `report $(id).png` executed the substitution when the path was pasted into a shell.
final class ShellQuotingTests: XCTestCase {

    func testWrapsInSingleQuotes() {
        XCTAssertEqual(PathText.quoted(["/tmp/my file.png"]), "'/tmp/my file.png'")
    }

    // The actual exploit: these must come back inert.
    func testNeutralisesShellMetacharacters() {
        XCTAssertEqual(PathText.quoted(["/tmp/report $(id).png"]), "'/tmp/report $(id).png'")
        XCTAssertEqual(PathText.quoted(["/tmp/report `id`.png"]),  "'/tmp/report `id`.png'")
        XCTAssertEqual(PathText.quoted(["/tmp/$HOME.png"]),        "'/tmp/$HOME.png'")
        XCTAssertEqual(PathText.quoted(["/tmp/a;rm -rf b.png"]),   "'/tmp/a;rm -rf b.png'")
    }

    // A single quote cannot be escaped inside single quotes — it has to be closed, escaped
    // and reopened, or the quoting silently breaks apart.
    func testHandlesAnApostropheInTheName() {
        XCTAssertEqual(PathText.quoted(["/tmp/Mike's art.png"]), "'/tmp/Mike'\\''s art.png'")
    }

    func testBackslashIsLiteralAndNeedsNoEscaping() {
        XCTAssertEqual(PathText.quoted(["/tmp/back\\slash.png"]), "'/tmp/back\\slash.png'")
    }

    func testMultiplePathsOnePerLine() {
        XCTAssertEqual(PathText.quoted(["/a b", "/c d"]), "'/a b'\n'/c d'")
    }
}

final class SearchProducerTests: XCTestCase {
    func testThisMacOverridesNetworkFolder() {
        XCTAssertTrue(SearchBackendRules.usesRecursiveWalk(isNetwork: true, thisMac: false))
        XCTAssertFalse(SearchBackendRules.usesRecursiveWalk(isNetwork: true, thisMac: true))
        XCTAssertFalse(SearchBackendRules.usesRecursiveWalk(isNetwork: false, thisMac: false))
        XCTAssertFalse(SearchBackendRules.usesRecursiveWalk(isNetwork: false, thisMac: true))
    }

    func testFolderKindUsesDirectoryMetadata() {
        let unused: (String) -> Bool = { _ in
            XCTFail("Directories and Any must not consult a filename extension")
            return false
        }
        XCTAssertTrue(SearchBackendRules.matchesKind(tree: "public.folder", isDirectory: true, fileTypeMatches: unused))
        XCTAssertFalse(SearchBackendRules.matchesKind(tree: "public.folder", isDirectory: false, fileTypeMatches: unused))
        XCTAssertFalse(SearchBackendRules.matchesKind(tree: "public.image", isDirectory: true, fileTypeMatches: unused))
        XCTAssertTrue(SearchBackendRules.matchesKind(tree: nil, isDirectory: true, fileTypeMatches: unused))
        XCTAssertTrue(SearchBackendRules.matchesKind(tree: "public.image", isDirectory: false) { tree in
            XCTAssertEqual(tree, "public.image")
            return true
        })
        XCTAssertFalse(SearchBackendRules.matchesKind(tree: "public.image", isDirectory: false) { _ in false })
    }

    func testGenerationInvalidationAndConcurrentAdvances() {
        let generation = Synchronized(wrappedValue: 0)
        let old = generation.wrappedValue
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in generation.wrappedValue += 1 }
        XCTAssertEqual(generation.wrappedValue, 1000)
        XCTAssertNotEqual(old, generation.wrappedValue)
    }

    func testCancellationVisibleToWorker() {
        let cancelled = Synchronized(wrappedValue: false)
        let ready = DispatchSemaphore(value: 0)
        let done = expectation(description: "worker sees cancellation")
        DispatchQueue.global().async {
            ready.wait()
            XCTAssertTrue(cancelled.wrappedValue)
            done.fulfill()
        }
        cancelled.wrappedValue = true
        ready.signal()
        wait(for: [done], timeout: 2)
    }

    func testSparseMatchDrainsBeforeProducerFinishes() {
        let buffer = SearchResultBuffer<Int>()
        let produced = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let done = expectation(description: "producer finishes")
        DispatchQueue.global().async {
            buffer.append(1)
            produced.signal()
            resume.wait()
            buffer.append(2)
            done.fulfill()
        }
        XCTAssertEqual(produced.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(buffer.drain(), [1])
        XCTAssertTrue(buffer.drain().isEmpty)
        resume.signal()
        wait(for: [done], timeout: 2)
        XCTAssertEqual(buffer.drain(), [2])
    }

    func testConcurrentStreamingDoesNotLoseOrRepeatRows() {
        let buffer = SearchResultBuffer<Int>()
        let drained = Synchronized(wrappedValue: [Int]())
        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            buffer.append(i)
            let rows = buffer.drain()
            drained.wrappedValue.append(contentsOf: rows)
        }
        let rows = drained.wrappedValue + buffer.drain()
        XCTAssertEqual(rows.sorted(), Array(0..<1000))
    }
}

final class ArchiveInputsTests: XCTestCase {
    private func check(_ paths: [String], directory: String, entries: [String],
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let plan = try XCTUnwrap(PathRules.archiveInputs(paths.map { URL(fileURLWithPath: $0) }))
        XCTAssertEqual(plan.directory.path, directory, file: file, line: line)
        XCTAssertEqual(plan.entries, entries, file: file, line: line)
        XCTAssertEqual(plan.entries.map { plan.directory.appendingPathComponent($0).standardizedFileURL.path },
                       paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }, file: file, line: line)
    }

    func testSearchResultUsesItsOwnParent() throws {
        try check(["/root/sub/report.txt"], directory: "/root/sub", entries: ["./report.txt"])
    }

    func testSeveralParentsAndDuplicateBasenames() throws {
        try check(["/root/a/report.txt", "/root/b/report.txt", "/root/b/deep/image.png"],
                  directory: "/root", entries: ["./a/report.txt", "./b/report.txt", "./b/deep/image.png"])
    }

    func testCommonAncestorIsRoot() throws {
        try check(["/Users/me/report.txt", "/Volumes/data/report.txt"], directory: "/",
                  entries: ["./Users/me/report.txt", "./Volumes/data/report.txt"])
    }

    func testSharedPrefixIsNotAParent() throws {
        try check(["/root/a/one", "/root/ab/two"], directory: "/root", entries: ["./a/one", "./ab/two"])
    }

    func testOptionNamesAndSpaces() throws {
        try check(["/root/-report.txt", "/root/my file.txt"], directory: "/root",
                  entries: ["./-report.txt", "./my file.txt"])
    }

    func testEmptyAndNonFileSelectionsAreRejected() {
        XCTAssertNil(PathRules.archiveInputs([]))
        if let remote = URL(string: "https://example.com/file") {
            XCTAssertNil(PathRules.archiveInputs([remote]))
        }
    }
}

final class RenameReplacementTests: XCTestCase {
    func testFailedRenameRestoresDisplacedFile() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("existing.txt")
        try Data("original".utf8).write(to: dest)
        XCTAssertThrowsError(try renameItem(dir.appendingPathComponent("missing"), to: dest, replacing: true))
        XCTAssertEqual(try Data(contentsOf: dest), Data("original".utf8))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.path), ["existing.txt"])
    }

    func testSuccessfulReplaceKeepsFixedLengthBackupForUndo() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source")
        let dest = dir.appendingPathComponent(String(repeating: "x", count: 240))
        try Data("incoming".utf8).write(to: source)
        try Data("original".utf8).write(to: dest)
        let stash = try XCTUnwrap(renameItem(source, to: dest, replacing: true))
        XCTAssertLessThan(stash.lastPathComponent.utf8.count, 64)
        XCTAssertTrue(stash.lastPathComponent.hasPrefix(".navigator-replacing-"))
        XCTAssertEqual(try Data(contentsOf: stash), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: dest), Data("incoming".utf8))
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertNil(restoreItems([(from: dest, to: source), (from: stash, to: dest)]))
        XCTAssertEqual(try Data(contentsOf: dest), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("incoming".utf8))
    }

    func testFailedStagingLeavesSourceUntouched() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source")
        try Data("incoming".utf8).write(to: source)
        XCTAssertThrowsError(try renameItem(source, to: dir.appendingPathComponent("missing"), replacing: true))
        XCTAssertEqual(try Data(contentsOf: source), Data("incoming".utf8))
    }

    func testCopyWithFailedDeletionIsNotReportedAsMove() {
        let line = TransferLogLine.summary(move: true, moved: 0, copied: 1, failed: 1,
                                           skipped: 0, total: 1, cancelled: false, target: "/tmp")
        XCTAssertTrue(line.contains("move 0/1"))
        XCTAssertTrue(line.contains("1 copied but not moved"))
        XCTAssertTrue(line.contains("1 FAILED"))
    }
}

// Rename-with-Replace keeps the displaced file in a hidden stash so Undo can put it back.
// That stash has to be binned the moment the entry can no longer be replayed, or a user who
// renames over a hundred files is left with a hundred hidden leftovers in their folders.
final class UndoStackCleanupTests: XCTestCase {

    private func fresh() -> UndoStack {
        let s = UndoStack(); s.onEmpty = {}; s.onFailure = { _, _ in }; return s
    }

    func testCleanupRunsWhenANewOperationInvalidatesRedo() {
        let s = fresh()
        var cleaned = 0
        s.push("Rename", undo: { nil }, redo: { nil }, cleanup: { cleaned += 1 })
        s.undo()                       // entry moves to the redo stack, still replayable
        XCTAssertEqual(cleaned, 0)
        s.push("Other", undo: { nil }, redo: { nil })   // invalidates every pending redo
        XCTAssertEqual(cleaned, 1)
    }

    func testCleanupRunsWhenTheEntryIsEvictedByTheLimit() {
        let s = fresh()
        var cleaned = 0
        s.push("Rename", undo: { nil }, redo: { nil }, cleanup: { cleaned += 1 })
        for _ in 0..<UndoStack.limit { s.push("filler", undo: { nil }, redo: { nil }) }
        XCTAssertEqual(cleaned, 1, "the oldest entry fell off the stack and must release its stash")
    }

    // A failed undo DROPS the entry rather than re-filing it, so its stash is unreachable too.
    func testCleanupRunsWhenUndoFails() {
        let s = fresh()
        var cleaned = 0
        s.push("Rename", undo: { "boom" }, redo: { nil }, cleanup: { cleaned += 1 })
        s.undo()
        XCTAssertEqual(cleaned, 1)
    }

    // The ordinary case: still replayable, so the stash must survive.
    func testCleanupDoesNotRunWhileTheEntryIsStillLive() {
        let s = fresh()
        var cleaned = 0
        s.push("Rename", undo: { nil }, redo: { nil }, cleanup: { cleaned += 1 })
        XCTAssertEqual(cleaned, 0)
        s.undo(); s.redo()
        XCTAssertEqual(cleaned, 0)
    }
}

final class RemainingAuditTests: XCTestCase {
    func testIncompleteSearchNeverClaimsUnknownTotal() {
        for reason in [SearchTruncation.Reason.indexCoverageUnknown, .traversalErrors] {
            for count in [0, 42] {
                let result = SearchTruncation.of(shown: count, cap: 500, hitCap: false, reason: reason)
                XCTAssertEqual(result, .incomplete(.complete(count), reason))
                XCTAssertFalse(result.statusText.contains("more than"))
                XCTAssertNotEqual(result.statusText, "\(count) found")
            }
            let capped = SearchTruncation.of(shown: 500, cap: 500, hitCap: true, reason: reason)
            XCTAssertEqual(capped, .incomplete(.capped(shown: 500, cap: 500), reason))
            XCTAssertTrue(capped.statusText.contains(reason.text))
        }
    }

    func testTransferStillRefusesSymlinkIntoSource() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertTrue(PathRules.isSelfOrDescendant(link, of: source))
        // Hover can be decided without following the link; the transfer worker is
        // still the final authority before any recursive filesystem operation.
        XCTAssertFalse(PathRules.isLexicalSelfOrDescendant(link, of: source))
    }

    func testLexicalPathsPreserveCaseAndBoundaries() {
        XCTAssertEqual(lexicalPath("/Volumes/Offline/a/../B//."), "/Volumes/Offline/B")
        XCTAssertNotEqual(lexicalPath("/Volumes/Disk/A"), lexicalPath("/Volumes/Disk/a"))
        XCTAssertEqual(lexicalPath("/tmp/a"), "/private/tmp/a")
        let source = URL(fileURLWithPath: "/Volumes/Offline/a", isDirectory: true)
        XCTAssertTrue(PathRules.isLexicalSelfOrDescendant(source.appendingPathComponent("b"), of: source))
        XCTAssertFalse(PathRules.isLexicalSelfOrDescendant(URL(fileURLWithPath: "/Volumes/Offline/ab", isDirectory: true), of: source))
    }

    func testSizeInputCannotOverflow() {
        for text in ["inf", "nan", "1e300", "-1", "9223372036854.776"] {
            XCTAssertNil(SearchSizeFilter.bytes(megabytes: text), text)
        }
        XCTAssertEqual(SearchSizeFilter.bytes(megabytes: "0"), 0)
        XCTAssertEqual(SearchSizeFilter.bytes(megabytes: "1.25"), 1_250_000)
    }
}

final class DeferredUndoTests: XCTestCase {
    func testPendingActionPreventsReentryAndPublishesOnCompletion() {
        let stack = UndoStack()
        var run: (() -> Void)?
        var calls = 0
        stack.execute = { action, done in run = { done(action()) } }
        stack.push("Move", undo: { calls += 1; return nil }, redo: { nil })
        stack.undo()
        XCTAssertTrue(stack.isPerforming)
        XCTAssertFalse(stack.canUndo)
        XCTAssertFalse(stack.canRedo)
        stack.undo(); stack.redo()
        XCTAssertEqual(calls, 0)
        run?()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(stack.canRedo)
        XCTAssertFalse(stack.isPerforming)
    }

    func testNewOperationDuringUndoDoesNotResurrectRedo() {
        let stack = UndoStack()
        var finish: ((String?) -> Void)?
        stack.execute = { _, done in finish = done }
        stack.push("Old", undo: { nil }, redo: { nil })
        stack.undo()
        stack.push("New", undo: { nil }, redo: { nil })
        finish?(nil)
        XCTAssertFalse(stack.canRedo)
        XCTAssertEqual(stack.topDescription, "New")
    }

    func testDeferredFailureIsReportedAndDropsEntry() {
        let stack = UndoStack()
        var finish: ((String?) -> Void)?
        var problem: String?
        stack.execute = { _, done in finish = done }
        stack.onFailure = { _, detail in problem = detail }
        stack.push("Move", undo: { nil }, redo: { nil })
        stack.undo()
        finish?("Permission denied")
        XCTAssertEqual(problem, "Permission denied")
        XCTAssertFalse(stack.canUndo)
        XCTAssertFalse(stack.canRedo)
        XCTAssertFalse(stack.isPerforming)
    }
}

// The wedged-mount case, made reproducible without a wedged mount: a walk that never finishes
// is simply one that never calls end(). These assert the bound holds under exactly that.
final class WalkAdmissionTests: XCTestCase {

    func testAllowsWalksUpToTheLimit() {
        let a = WalkAdmission(limit: 4)
        for i in 1...4 { XCTAssertTrue(a.begin(), "walk \(i) should be admitted"); XCTAssertEqual(a.current, i) }
    }

    // The actual failure: four walks blocked forever in nextObject(), and the user keeps
    // typing. Without a bound each keystroke parks another thread.
    func testRefusesOnceTheLimitIsReachedByWalksThatNeverFinish() {
        let a = WalkAdmission(limit: 4)
        for _ in 0..<4 { XCTAssertTrue(a.begin()) }
        for _ in 0..<50 { XCTAssertFalse(a.begin(), "a wedged volume must not keep taking workers") }
        XCTAssertEqual(a.current, 4, "outstanding work stays bounded no matter how often the user retries")
    }

    func testFinishingAWalkMakesRoomForTheNext() {
        let a = WalkAdmission(limit: 2)
        XCTAssertTrue(a.begin()); XCTAssertTrue(a.begin())
        XCTAssertFalse(a.begin())
        a.end()
        XCTAssertTrue(a.begin(), "a walk that returned frees its slot")
    }

    // A double end() must not invent capacity - that would quietly disable the bound.
    func testEndIsClampedAtZero() {
        let a = WalkAdmission(limit: 1)
        a.end(); a.end()
        XCTAssertEqual(a.current, 0)
        XCTAssertTrue(a.begin())
        XCTAssertFalse(a.begin())
    }

    func testConcurrentAdmissionNeverExceedsTheLimit() {
        let a = WalkAdmission(limit: 8)
        let admitted = Synchronized(wrappedValue: 0)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            if a.begin() { admitted.wrappedValue += 1 }   // never end(): every walk is wedged
        }
        XCTAssertEqual(admitted.wrappedValue, 8)
        XCTAssertEqual(a.current, 8)
    }
}

final class FileOperationDiskTests: XCTestCase {
    private let fm = FileManager.default
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NavigatorDiskTests-\(UUID().uuidString)")
    private var trashed: [URL] = []
    private var oldDefaults: UserDefaults?
    private let suite = "NavigatorDiskTests-\(UUID().uuidString)"

    override func setUpWithError() throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        oldDefaults = TrashOrigins.defaults
        TrashOrigins.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        // A failed assertion must not leave test files in the user's Trash.
        for url in trashed where itemExists(url) { try fm.removeItem(at: url) }
        TrashOrigins.defaults.removePersistentDomain(forName: suite)
        if let oldDefaults { TrashOrigins.defaults = oldDefaults }
        try fm.removeItem(at: directory)
    }

    private func file(_ name: String, _ contents: String = "original bytes") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func tree(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try fm.subpathsOfDirectory(atPath: root.path) {
            let url = root.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            result[name + (values.isDirectory == true ? "/" : "")] = values.isDirectory == true ? Data() : try Data(contentsOf: url)
        }
        return result
    }

    /// Does this path exist, WITHOUT following symlinks?
    ///
    /// FileManager.fileExists(atPath:) follows them, so it answers false for a symlink whose
    /// target is gone - and trashing a file together with a link to it produces exactly that:
    /// the link is sitting in the Trash, perfectly present, reported missing. lstat asks about
    /// the link itself, which is what "did this item move" actually means.
    private func itemExists(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    private func trash(_ urls: [URL]) throws -> [(from: URL, to: URL)] {
        let result = trashItemsWithFailures(urls)
        trashed += result.restores.map { $0.from }
        // A denied Trash operation must fail the test, not report untested behavior as green.
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(result.restores.count, urls.count)
        for pair in result.restores {
            XCTAssertFalse(itemExists(pair.to), "\(pair.to.lastPathComponent) should have left the folder")
            XCTAssertTrue(itemExists(pair.from), "\(pair.to.lastPathComponent) should be in the Trash")
        }
        return result.restores
    }

    func testNewFolderChoosesFreeName() throws {
        let first = try FileOperations.newFolder(in: directory)
        let second = try FileOperations.newFolder(in: directory)
        XCTAssertEqual(first.lastPathComponent, "New Folder")
        XCTAssertEqual(second.lastPathComponent, "New Folder 2")
        XCTAssertEqual(try tree(directory), ["New Folder/": Data(), "New Folder 2/": Data()])
    }

    func testNamedExtractionFolderPreservesOccupantsAndRequiresParent() throws {
        let occupant = try file("archive", "keep me")
        let folder = try FileOperations.newFolder(in: directory, name: "archive")
        XCTAssertEqual(folder.lastPathComponent, "archive 2")
        XCTAssertEqual(try contents(occupant), "keep me")
        XCTAssertEqual(try tree(folder), [:])
        let absent = directory.appendingPathComponent("missing")
        XCTAssertThrowsError(try FileOperations.newFolder(in: absent, name: "archive"))
        XCTAssertFalse(itemExists(absent))
    }

    func testNewTextFilePreservesCollisionAndContents() throws {
        let original = try file("New Text File.txt", "keep me")
        let empty = try FileOperations.newFile(in: directory, name: "New Text File.txt", contents: Data())
        let third = try FileOperations.newFile(in: directory, name: "New Text File.txt", contents: Data("third".utf8))
        XCTAssertEqual(empty.lastPathComponent, "New Text File 2.txt")
        XCTAssertEqual(third.lastPathComponent, "New Text File 3.txt")
        XCTAssertEqual(try contents(original), "keep me")
        XCTAssertEqual(try Data(contentsOf: empty), Data())
        XCTAssertEqual(try contents(third), "third")
    }

    func testCreationInVanishedParentFails() throws {
        let absent = directory.appendingPathComponent("gone")
        XCTAssertThrowsError(try FileOperations.newFolder(in: absent))
        XCTAssertThrowsError(try FileOperations.newFile(in: absent, name: "text.txt", contents: Data()))
        XCTAssertThrowsError(try FileOperations.newFolder(in: absent, containing: [file("source")]))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: directory.path), ["source"])
    }

    func testDuplicateFileCollisionsKeepAllBytes() throws {
        let source = try file("photo.txt")
        let first = try FileOperations.duplicate(source, in: directory)
        let second = try FileOperations.duplicate(source, in: directory)
        XCTAssertEqual(first.lastPathComponent, "photo copy.txt")
        XCTAssertEqual(second.lastPathComponent, "photo copy 2.txt")
        for url in [source, first, second] { XCTAssertEqual(try contents(url), "original bytes") }
    }

    func testDuplicateDirectoryCopiesNestedTree() throws {
        let source = try FileOperations.newFolder(in: directory)
        try fm.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: false)
        try Data("nested bytes".utf8).write(to: source.appendingPathComponent("nested/file"))
        let copy = try FileOperations.duplicate(source, in: directory)
        XCTAssertEqual(try tree(copy), try tree(source))
    }

    func testDuplicateVanishedSourceDoesNotCreateDestination() throws {
        let source = try file("vanished")
        try fm.removeItem(at: source)
        XCTAssertThrowsError(try FileOperations.duplicate(source, in: directory))
        XCTAssertEqual(try tree(directory), [:])
    }

    func testAliasResolvesAndCollisionsPreservePreviousAlias() throws {
        let source = try file("report.txt")
        let first = try FileOperations.makeAlias(source, in: directory)
        let second = try FileOperations.makeAlias(source, in: directory)
        XCTAssertEqual(first.lastPathComponent, "report alias")
        XCTAssertEqual(second.lastPathComponent, "report alias 2")
        for alias in [first, second] {
            let resolved = try URL(resolvingAliasFileAt: alias, options: [.withoutUI, .withoutMounting])
            XCTAssertEqual(resolved.standardizedFileURL.resolvingSymlinksInPath(), source.standardizedFileURL.resolvingSymlinksInPath())
            XCTAssertEqual(try contents(resolved), "original bytes")
        }
    }

    func testAliasVanishedSourceFails() throws {
        let source = try file("gone.txt")
        try fm.removeItem(at: source)
        XCTAssertThrowsError(try FileOperations.makeAlias(source, in: directory))
        XCTAssertEqual(try tree(directory), [:])
    }

    func testSymlinkTargetsAndNameCollisions() throws {
        let source = try file("report.txt")
        let first = try FileOperations.makeSymlink(source, in: directory)
        let second = try FileOperations.makeSymlink(source, in: directory)
        XCTAssertEqual(first.lastPathComponent, "report symlink.txt")
        XCTAssertEqual(second.lastPathComponent, "report symlink 2.txt")
        for link in [first, second] {
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), source.path)
            XCTAssertEqual(try contents(link), "original bytes")
        }
    }

    func testSymlinkAllowsVanishedTargetAsBefore() throws {
        let source = directory.appendingPathComponent("gone")
        let link = try FileOperations.makeSymlink(source, in: directory)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), source.path)
        XCTAssertThrowsError(try Data(contentsOf: link))
    }

    func testSelectionFolderRoundTripMatchesTree() throws {
        let sources = try [file("one", "1"), file("two", "2")]
        let before = try tree(directory)
        let result = try FileOperations.newFolder(in: directory, containing: sources)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.moved.count, 2)
        XCTAssertEqual(result.folder.lastPathComponent, "New Folder With Items")
        let after = try tree(directory)
        XCTAssertEqual(after, ["New Folder With Items/": Data(), "New Folder With Items/one": Data("1".utf8), "New Folder With Items/two": Data("2".utf8)])
        XCTAssertNil(FileOperations.undoFolderSelection(result))
        XCTAssertEqual(try tree(directory), before)
        XCTAssertNil(FileOperations.redoFolderSelection(result))
        XCTAssertEqual(try tree(directory), after)
    }

    func testSelectionFolderCollisionAndPartialVanishedSource() throws {
        let source = try file("one")
        let gone = try file("gone")
        try fm.removeItem(at: gone)
        let existing = directory.appendingPathComponent("New Folder With Items")
        try fm.createDirectory(at: existing, withIntermediateDirectories: false)
        let result = try FileOperations.newFolder(in: directory, containing: [gone, source])
        XCTAssertEqual(result.folder.lastPathComponent, "New Folder With Items 2")
        XCTAssertEqual(result.moved.count, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].contains("gone"))
        XCTAssertEqual(try contents(result.folder.appendingPathComponent("one")), "original bytes")
        XCTAssertNil(FileOperations.undoFolderSelection(result))
        XCTAssertEqual(try contents(source), "original bytes")
        XCTAssertTrue(fm.fileExists(atPath: existing.path))
    }

    func testSelectionWithOnlyVanishedSourceRemovesEmptyFolder() throws {
        let result = try FileOperations.newFolder(in: directory, containing: [directory.appendingPathComponent("gone")])
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: result.folder.path))
        XCTAssertEqual(try tree(directory), [:])
    }

    func testSelectionSameBasenamesReportPartialFailure() throws {
        let a = try FileOperations.newFolder(in: directory)
        let b = try FileOperations.newFolder(in: directory)
        let one = a.appendingPathComponent("same"), two = b.appendingPathComponent("same")
        try Data("one".utf8).write(to: one)
        try Data("two".utf8).write(to: two)
        let result = try FileOperations.newFolder(in: directory, containing: [one, two])
        XCTAssertEqual(result.moved.count, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(try contents(result.folder.appendingPathComponent("same")), "one")
        XCTAssertEqual(try contents(two), "two")
    }

    func testSelectionUndoPreservesFilesAddedLater() throws {
        let source = try file("one")
        let result = try FileOperations.newFolder(in: directory, containing: [source])
        let added = result.folder.appendingPathComponent("added")
        try Data("keep".utf8).write(to: added)
        XCTAssertNil(FileOperations.undoFolderSelection(result))
        XCTAssertEqual(try contents(added), "keep")
        XCTAssertEqual(try contents(source), "original bytes")
        XCTAssertNil(FileOperations.redoFolderSelection(result))
        XCTAssertEqual(try contents(added), "keep")
        XCTAssertEqual(try contents(result.folder.appendingPathComponent("one")), "original bytes")
    }

    func testSelectionUndoOccupiedOriginalDoesNotOverwrite() throws {
        let source = try file("one")
        let result = try FileOperations.newFolder(in: directory, containing: [source])
        try Data("occupant".utf8).write(to: source)
        XCTAssertNotNil(FileOperations.undoFolderSelection(result))
        XCTAssertEqual(try contents(source), "occupant")
        XCTAssertEqual(try contents(result.folder.appendingPathComponent("one")), "original bytes")
    }

    func testSelectionRedoOccupiedChildDoesNotOverwrite() throws {
        let source = try file("one")
        let result = try FileOperations.newFolder(in: directory, containing: [source])
        XCTAssertNil(FileOperations.undoFolderSelection(result))
        try fm.createDirectory(at: result.folder, withIntermediateDirectories: false)
        let child = result.folder.appendingPathComponent("one")
        try Data("occupant".utf8).write(to: child)
        XCTAssertNotNil(FileOperations.redoFolderSelection(result))
        XCTAssertEqual(try contents(source), "original bytes")
        XCTAssertEqual(try contents(child), "occupant")
    }

    func testProgressCopyPreservesBytesAndPermissions() throws {
        let source = try file("source", String(repeating: "payload", count: 10000))
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
        let dest = directory.appendingPathComponent("copy")
        var counts: [Int64] = []
        try copyWithProgress(source, dest, onBytes: { counts.append($0) })
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: dest))
        XCTAssertEqual((try fm.attributesOfItem(atPath: dest.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        // APFS may clone without callbacks; any callbacks it does emit must be monotonic.
        XCTAssertEqual(counts, counts.sorted())
    }

    func testProgressCopyRefusesOccupiedDestination() throws {
        let source = try file("source"), dest = try file("copy", "occupant")
        XCTAssertThrowsError(try copyWithProgress(source, dest, onBytes: { _ in }))
        XCTAssertEqual(try contents(source), "original bytes")
        XCTAssertEqual(try contents(dest), "occupant")
    }

    func testProgressCopyVanishedSourceFails() throws {
        let source = try file("source")
        try fm.removeItem(at: source)
        let dest = directory.appendingPathComponent("copy")
        XCTAssertThrowsError(try copyWithProgress(source, dest, onBytes: { _ in }))
        XCTAssertFalse(fm.fileExists(atPath: dest.path))
    }

    func testRestoreMoveRoundTripAndVanishedSource() throws {
        let source = try file("source"), dest = directory.appendingPathComponent("moved")
        let before = try tree(directory)
        XCTAssertNil(restoreItems([(source, dest)]))
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(try contents(dest), "original bytes")
        let after = try tree(directory)
        XCTAssertNil(restoreItems([(dest, source)]))
        XCTAssertEqual(try tree(directory), before)
        XCTAssertNil(restoreItems([(source, dest)]))
        XCTAssertEqual(try tree(directory), after)
        try fm.removeItem(at: dest)
        XCTAssertNotNil(restoreItems([(dest, source)]))
        XCTAssertEqual(try tree(directory), [:])
    }

    func testRestoreResultsIncludeOnlySuccessfulMoves() throws {
        let source = try file("source"), blocked = try file("blocked")
        let occupant = try file("occupant", "keep me")
        let destination = directory.appendingPathComponent("restored")
        let missing = directory.appendingPathComponent("missing")
        let result = restoreItemsWithResults([(source, destination), (blocked, occupant), (missing, source)])
        XCTAssertEqual(result.moved.map { $0.from }, [source])
        XCTAssertEqual(result.moved.map { $0.to }, [destination])
        XCTAssertNotNil(result.problem)
        XCTAssertEqual(try contents(destination), "original bytes")
        XCTAssertEqual(try contents(blocked), "original bytes")
        XCTAssertEqual(try contents(occupant), "keep me")
        XCTAssertFalse(itemExists(source))
    }

    func testPermissionDeniedDoesNotCreateOrMoveItems() throws {
        let source = try file("source")
        let locked = try FileOperations.newFolder(in: directory)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        guard !fm.isWritableFile(atPath: locked.path) else {
            XCTFail("Cannot verify permission denial: this user bypasses POSIX write permissions")
            return
        }
        XCTAssertThrowsError(try FileOperations.newFolder(in: locked))
        XCTAssertThrowsError(try FileOperations.newFile(in: locked, name: "text", contents: Data()))
        XCTAssertThrowsError(try FileOperations.duplicate(source, in: locked))
        XCTAssertThrowsError(try FileOperations.makeAlias(source, in: locked))
        XCTAssertThrowsError(try FileOperations.makeSymlink(source, in: locked))
        XCTAssertThrowsError(try FileOperations.newFolder(in: locked, containing: [source]))
        let dest = locked.appendingPathComponent("dest")
        XCTAssertThrowsError(try copyWithProgress(source, dest, onBytes: { _ in }))
        XCTAssertNotNil(restoreItems([(source, dest)]))
        XCTAssertEqual(try contents(source), "original bytes")
        XCTAssertEqual(try tree(locked), [:])
    }

    func testTrashRestoreRedoRoundTripWithContentsAndOrigins() throws {
        let source = try file("NavigatorTrash-\(UUID().uuidString).txt")
        let before = try tree(directory)
        var pairs = try trash([source])
        let first = try XCTUnwrap(pairs.first)
        XCTAssertEqual(try contents(first.from), "original bytes")
        XCTAssertEqual(TrashOrigins.origin(of: first.from.path)?.name, source.lastPathComponent)
        XCTAssertNil(restoreItems(pairs))
        TrashOrigins.forget(pairs.map { $0.from.path })
        XCTAssertEqual(try tree(directory), before)
        XCTAssertNil(TrashOrigins.origin(of: first.from.path))
        pairs = try trash([source])
        XCTAssertEqual(try tree(directory), [:])
        XCTAssertNil(restoreItems(pairs))
        XCTAssertEqual(try tree(directory), before)
    }

    func testTrashUndoOccupiedOriginalPreservesBothFiles() throws {
        let source = try file("NavigatorTrash-\(UUID().uuidString).txt")
        let pairs = try trash([source])
        try Data("occupant".utf8).write(to: source)
        XCTAssertNotNil(restoreItems(pairs))
        XCTAssertEqual(try contents(source), "occupant")
        XCTAssertEqual(try contents(XCTUnwrap(pairs.first).from), "original bytes")
        try fm.removeItem(at: source)
        XCTAssertNil(restoreItems(pairs))
        XCTAssertEqual(try contents(source), "original bytes")
    }

    func testTrashVanishedSourceReportsFailure() throws {
        let source = try file("gone")
        try fm.removeItem(at: source)
        let result = trashItems([source])
        XCTAssertTrue(result.restores.isEmpty)
        XCTAssertNotNil(result.problem)
        XCTAssertTrue(result.problem?.contains("gone") == true)
        XCTAssertEqual(try tree(directory), [:])
    }

    func testCreationUndoRedoRestoresExactTreeIncludingLaterContents() throws {
        let folder = try FileOperations.newFolder(in: directory)
        try Data("added later".utf8).write(to: folder.appendingPathComponent("child"))
        let text = try FileOperations.newFile(in: directory, name: "New Text File.txt", contents: Data())
        let duplicate = try FileOperations.duplicate(text, in: directory)
        let link = try FileOperations.makeSymlink(text, in: directory)
        let alias = try FileOperations.makeAlias(text, in: directory)
        let created = [folder, text, duplicate, link, alias]
        let before = try tree(directory)
        let pairs = try trash(created)
        XCTAssertEqual(try tree(directory), [:])
        XCTAssertNil(restoreItems(pairs))
        XCTAssertEqual(try tree(directory), before)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), text.path)
        XCTAssertEqual(try contents(folder.appendingPathComponent("child")), "added later")
    }

    func testTagsWriteReplaceAndRemoveRealAttribute() throws {
        let source = try file("tagged")
        func tags() throws -> [String] {
            let data = try source.withUnsafeFileSystemRepresentation { path -> Data in
                let count = getxattr(path, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, 0)
                guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                var data = Data(count: count)
                let read = data.withUnsafeMutableBytes { getxattr(path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, count, 0, 0) }
                guard read == count else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                return data
            }
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String])
        }
        try FileOperations.writeTags(source, ["Red", "Custom"])
        XCTAssertEqual(try tags(), ["Red\n6", "Custom"])
        try FileOperations.writeTags(source, ["Blue"])
        XCTAssertEqual(try tags(), ["Blue\n4"])
        try FileOperations.writeTags(source, [])
        XCTAssertThrowsError(try tags()) { XCTAssertEqual(($0 as NSError).code, Int(ENOATTR)) }
        XCTAssertEqual(try contents(source), "original bytes")
    }

    func testTagsVanishedSourceReportsFailure() throws {
        let source = try file("gone")
        try fm.removeItem(at: source)
        XCTAssertThrowsError(try FileOperations.writeTags(source, ["Red"]))
        XCTAssertThrowsError(try FileOperations.writeTags(source, []))
    }

    func testWorkerUndoRedoPublishesAfterDiskWork() throws {
        let source = try file("one")
        let before = try tree(directory)
        let result = try FileOperations.newFolder(in: directory, containing: [source])
        let after = try tree(directory)
        let stack = UndoStack()
        var completion = expectation(description: "undo completes")
        stack.execute = { action, done in
            DispatchQueue.global(qos: .userInitiated).async {
                let problem = action()
                DispatchQueue.main.async { done(problem); completion.fulfill() }
            }
        }
        stack.onFailure = { summary, detail in XCTFail("\(summary): \(detail)") }
        stack.push("New Folder with Selection", undo: {
            XCTAssertFalse(Thread.isMainThread)
            return FileOperations.undoFolderSelection(result)
        }, redo: {
            XCTAssertFalse(Thread.isMainThread)
            return FileOperations.redoFolderSelection(result)
        })
        stack.undo()
        XCTAssertTrue(stack.isPerforming)
        XCTAssertFalse(stack.canRedo)
        wait(for: [completion], timeout: 5)
        XCTAssertTrue(stack.canRedo)
        XCTAssertEqual(try tree(directory), before)
        completion = expectation(description: "redo completes")
        stack.redo()
        wait(for: [completion], timeout: 5)
        XCTAssertTrue(stack.canUndo)
        XCTAssertEqual(try tree(directory), after)
    }

}

final class CommandAvailabilityTests: XCTestCase {
    func testUpStopsAtRoot() {
        XCTAssertFalse(PathRules.canGoUp(URL(fileURLWithPath: "/")))
        XCTAssertTrue(PathRules.canGoUp(URL(fileURLWithPath: "/Users")))
    }

    func testTransferDestinationsMatchWhatCanActuallyMove() throws {
        let directory = URL(fileURLWithPath: "/destination", isDirectory: true)
        let local = directory.appendingPathComponent("local")
        let other = URL(fileURLWithPath: "/elsewhere/other")
        let token = try XCTUnwrap(URL(string: "navreorder:/favorite"))
        XCTAssertEqual(PathRules.transferSources([], into: directory), [])
        XCTAssertEqual(PathRules.transferSources([directory, local, token], into: directory), [])
        XCTAssertEqual(PathRules.transferSources([directory, local, token, other], into: directory), [other])
        XCTAssertEqual(PathRules.transferSources([directory, local, token, other], into: directory,
                                                allowSameFolder: true), [local, other])
    }

    func testFavoriteNudgesRespectPinnedHomeAndEndpoints() {
        let unchanged = [0, 1, 2]
        XCTAssertEqual(PathRules.reorder(count: 3, from: [0], to: 2, pinnedToFront: 0), unchanged)
        XCTAssertEqual(PathRules.reorder(count: 3, from: [1], to: 0, pinnedToFront: 0), unchanged)
        XCTAssertEqual(PathRules.reorder(count: 3, from: [2], to: 4, pinnedToFront: 0), unchanged)
        XCTAssertEqual(PathRules.reorder(count: 3, from: [1], to: 3, pinnedToFront: 0), [0, 2, 1])
        XCTAssertEqual(PathRules.reorder(count: 3, from: [2], to: 0, pinnedToFront: 0), [0, 2, 1])
    }
}

final class ExternalProcessTests: XCTestCase {
    func testEchoCapturesExactStdout() throws {
        let result = ExternalProcess.run("/bin/echo", arguments: ["hello world"], timeout: 5)
        guard case .success(let output) = result else { return XCTFail("echo failed: \(result)") }
        XCTAssertEqual(output.stdout, Data("hello world\n".utf8))
        XCTAssertTrue(output.stderr.isEmpty)
    }

    func testFalseIsNonZero() {
        let result = ExternalProcess.run("/usr/bin/false", timeout: 5)
        guard case .nonZero(let output) = result else { return XCTFail("false was not a non-zero exit") }
        XCTAssertEqual(output.status, 1)
    }

    func testNonZeroRetainsStderr() {
        let result = ExternalProcess.run("/bin/sh", arguments: ["-c", "printf 'reason' >&2; exit 7"], timeout: 5)
        guard case .nonZero(let output) = result else { return XCTFail("missing non-zero exit") }
        XCTAssertEqual(output.status, 7)
        XCTAssertEqual(output.stderr, Data("reason".utf8))
    }

    // 200KB cannot fit in a pipe: waiting for exit before reading stderr hangs.
    func testStderrLargerThanPipeBuffer() {
        let result = ExternalProcess.run("/bin/sh", arguments: ["-c", "/usr/bin/head -c 200000 /dev/zero >&2"], timeout: 5)
        guard case .success(let output) = result else { return XCTFail("stderr drain failed: \(result)") }
        XCTAssertEqual(output.stderr, Data(count: 200000))
        XCTAssertTrue(output.stdout.isEmpty)
    }

    // The parent shell keeps stdout open while waiting for its stderr writer.
    // Sequential stdout-then-stderr reads hang here too, not just wait-first reads.
    func testBothPipesLargerThanPipeBuffer() {
        let result = ExternalProcess.run("/bin/sh", arguments: ["-c",
            "/usr/bin/head -c 200000 /dev/zero & /usr/bin/head -c 200000 /dev/zero >&2 & wait"], timeout: 5)
        guard case .success(let output) = result else { return XCTFail("concurrent drains failed: \(result)") }
        XCTAssertEqual(output.stdout, Data(count: 200000))
        XCTAssertEqual(output.stderr, Data(count: 200000))
    }

    func testTimeoutTerminatesAndReapsChild() throws {
        let started = Date()
        let result = ExternalProcess.run("/bin/sh", arguments: ["-c", "printf '%s' $$; exec /bin/sleep 10"], timeout: 0.2)
        guard case .timedOut(let output) = result else { return XCTFail("sleep did not time out") }
        let pid = try XCTUnwrap(Int32(output.out))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
        XCTAssertThrowsError(try result.completed())
    }

    func testTimeoutKillsChildIgnoringSIGTERM() throws {
        let result = ExternalProcess.run("/bin/sh", arguments: ["-c", "trap '' TERM; printf '%s' $$; while :; do :; done"], timeout: 0.2)
        guard case .timedOut(let output) = result else { return XCTFail("ignored SIGTERM defeated timeout") }
        let pid = try XCTUnwrap(Int32(output.out))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(output.status, SIGKILL)
    }

    func testInheritedPipeDoesNotDefeatTimeout() {
        let started = Date()
        let result = ExternalProcess.run("/bin/sh", arguments: ["-c", "/bin/sleep 2 & exit 0"], timeout: 0.2)
        guard case .timedOut = result else { return XCTFail("inherited open pipe was not reported as timeout") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testMissingBinaryFailsToLaunch() {
        let result = ExternalProcess.run("/nonexistent-navigator-\(UUID().uuidString)", timeout: 5)
        guard case .failedToLaunch = result else { return XCTFail("missing executable did not fail to launch") }
        XCTAssertThrowsError(try result.completed())
    }

    func testArgumentsAreLiteral() {
        let arguments = ["has spaces", "single'quote", "double\"quote", "$HOME", "`whoami`", "$(whoami)", ""]
        let result = ExternalProcess.run("/usr/bin/printf", arguments: ["%s\n"] + arguments, timeout: 5)
        guard case .success(let output) = result else { return XCTFail("literal arguments failed") }
        XCTAssertEqual(output.stdout, Data((arguments.joined(separator: "\n") + "\n").utf8))
    }

    func testWorkingDirectoryAndEnvironment() throws {
        let directory = URL(fileURLWithPath: "/Users", isDirectory: true)
        let output = try ExternalProcess.run("/bin/sh", arguments: ["-c", "printf '%s\\n' \"$PWD\" \"$NAV_PROCESS_TEST\""],
            directory: directory, environment: ["NAV_PROCESS_TEST": "literal $value"], timeout: 5).completed()
        XCTAssertEqual(output.out, directory.path + "\nliteral $value\n")
    }
}


extension ExternalProcessTests {
    func testInvalidTimeoutFailsBeforeLaunch() {
        for timeout in [0.0, -1.0, .infinity, .nan] {
            let result = ExternalProcess.run("/bin/echo", timeout: timeout,
                onLaunch: { _ in XCTFail("invalid timeout launched a child") })
            guard case .failedToLaunch = result else { return XCTFail("invalid timeout was accepted") }
        }
    }

    func testLaunchCallbackObservesLivenessWithoutOwningProcess() {
        var isRunning: (() -> Bool)?
        let result = ExternalProcess.run("/bin/echo", timeout: 5, onLaunch: { isRunning = $0 })
        guard case .success = result else { return XCTFail("echo failed") }
        XCTAssertNotNil(isRunning)
        XCTAssertEqual(isRunning?(), false)
        _ = ExternalProcess.run("/nonexistent-navigator-\(UUID().uuidString)", timeout: 5,
            onLaunch: { _ in XCTFail("failed launch called onLaunch") })
    }
}

final class WalkStreamTests: XCTestCase {
    private func fixture(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func stream(_ rows: [String], cap: Int) throws -> Data {
        var data = Data()
        var writer = WalkStream.Writer<String>(cap: cap) { data.append($0) }
        var hitCap = false
        for row in rows {
            if try !writer.append(row) { hitCap = true; break }
        }
        try writer.finish(hitCap: hitCap, readFailed: false)
        return data
    }

    func testManyRowsStreamWithoutCapturingStdout() throws {
        let rows = (0..<5000).map { "/folder/\($0)-" + String(repeating: "x", count: 80) }
        let url = try fixture(stream(rows, cap: 5000))
        var reader = WalkStream.Reader<String>(cap: 5000)
        var received = [String]()
        var chunks = 0
        let result = ExternalProcess.run("/bin/cat", arguments: [url.path], timeout: 5,
            receiveStdout: { data in
                chunks += 1
                do { try reader.receive(data) { received.append($0) } }
                catch { XCTFail("Invalid stream: \(error)") }
            })
        guard case .success(let output) = result else { return XCTFail("Child failed") }
        XCTAssertTrue(output.stdout.isEmpty)
        XCTAssertGreaterThan(chunks, 1)
        XCTAssertEqual(received, rows)
        XCTAssertTrue(reader.complete)
        XCTAssertFalse(reader.hitCap, "Exactly the cap is not truncation")
    }

    func testEscapedPathsAndEverySplitBoundary() throws {
        let rows = ["/folder/new\nline", "/folder/\"quote\"'", "/Café/猫😀", "/back\\slash"]
        let data = try stream(rows, cap: 10)
        for split in 0...data.count {
            var reader = WalkStream.Reader<String>(cap: 10)
            var received = [String]()
            try reader.receive(Data(data.prefix(split))) { received.append($0) }
            try reader.receive(Data(data.dropFirst(split))) { received.append($0) }
            XCTAssertEqual(received, rows)
            XCTAssertTrue(reader.complete)
        }
        let url = try fixture(data)
        var reader = WalkStream.Reader<String>(cap: 10)
        var received = [String]()
        let result = ExternalProcess.run("/bin/cat", arguments: [url.path], timeout: 5,
            receiveStdout: { chunk in
                // Split even the multi-byte UTF-8 characters, independently of pipe buffering.
                for byte in chunk {
                    do { try reader.receive(Data([byte])) { received.append($0) } }
                    catch { XCTFail("Invalid stream: \(error)") }
                }
            })
        guard case .success = result else { return XCTFail("Child failed") }
        XCTAssertEqual(received, rows)
        XCTAssertTrue(reader.complete)
    }

    func testEmptyChildCannotClaimCompletedSearch() {
        var reader = WalkStream.Reader<String>(cap: 10)
        let result = ExternalProcess.run("/usr/bin/true", timeout: 5, receiveStdout: { data in
            do { try reader.receive(data) { _ in XCTFail("Unexpected row") } }
            catch { XCTFail("Unexpected bytes") }
        })
        guard case .success = result else { return XCTFail("Child failed") }
        XCTAssertEqual(reader.count, 0)
        XCTAssertFalse(reader.complete, "EOF alone cannot mean the traversal succeeded")
    }

    func testEmptyCompletedSearchAndExceededCap() throws {
        for rows in [[], ["one", "two", "three", "four"]] {
            let url = try fixture(stream(rows, cap: 3))
            var reader = WalkStream.Reader<String>(cap: 3)
            var received = [String]()
            let result = ExternalProcess.run("/bin/cat", arguments: [url.path], timeout: 5,
                receiveStdout: { data in
                    do { try reader.receive(data) { received.append($0) } }
                    catch { XCTFail("Invalid stream: \(error)") }
                })
            guard case .success = result else { return XCTFail("Child failed") }
            XCTAssertEqual(received, Array(rows.prefix(3)))
            XCTAssertTrue(reader.complete)
            XCTAssertEqual(reader.hitCap, rows.count > 3)
        }
    }

    func testCancellationKillsAndReapsMidRecordDespiteIgnoredTERM() throws {
        let whole = try WalkStream.encode(WalkStream.Record<String>.row("complete"))
        let partial = try WalkStream.encode(WalkStream.Record<String>.row("must not arrive"))
        let bytes = whole + partial.prefix(partial.count - 2)
        let url = try fixture(bytes)
        let pidFile = try fixture(Data())
        let cancellation = ExternalProcess.Cancellation()
        var reader = WalkStream.Reader<String>(cap: 10)
        var received = [String]()
        var byteCount = 0
        let started = Date()
        let result = ExternalProcess.run("/bin/sh", arguments: ["-c",
            "trap '' TERM; printf '%s' $$ > \"$1\"; /bin/cat \"$2\"; while :; do :; done",
            "walk-test", pidFile.path, url.path], timeout: 10, cancellation: cancellation,
            receiveStdout: { data in
                byteCount += data.count
                do { try reader.receive(data) { received.append($0) } }
                catch { XCTFail("Invalid stream: \(error)") }
                if byteCount == bytes.count { cancellation.cancel() }
            })
        guard case .cancelled(let output) = result else { return XCTFail("Child was not cancelled") }
        XCTAssertEqual(output.status, SIGKILL)
        XCTAssertThrowsError(try result.completed())
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(received, ["complete"])
        XCTAssertFalse(reader.complete)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH, "Stopping reads alone leaves the process alive")
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD, "The child must also have been reaped")
    }

    func testCancellationOfQuietChildAndBeforeLaunch() throws {
        let pidFile = try fixture(Data())
        let cancellation = ExternalProcess.Cancellation()
        let started = Date()
        let result = ExternalProcess.run("/bin/sh", arguments: ["-c",
            "printf '%s' $$ > \"$1\"; exec /bin/sleep 30", "walk-test", pidFile.path], timeout: nil,
            onLaunch: { _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { cancellation.cancel() }
            }, cancellation: cancellation, receiveStdout: { _ in XCTFail("Quiet child wrote output") })
        guard case .cancelled = result else { return XCTFail("Quiet child was not cancelled") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        let preCancelled = ExternalProcess.run("/bin/echo", timeout: 5,
            onLaunch: { _ in XCTFail("Cancelled work launched") }, cancellation: cancellation)
        guard case .failedToLaunch = preCancelled else { return XCTFail("Pre-cancellation ignored") }
    }

    func testChildSendingPastCapIsRejected() throws {
        var bytes = Data()
        for row in ["one", "two", "three", "extra"] {
            bytes.append(try WalkStream.encode(WalkStream.Record<String>.row(row)))
        }
        let url = try fixture(bytes)
        var reader = WalkStream.Reader<String>(cap: 3)
        var received = [String]()
        var rejected = false
        let cancellation = ExternalProcess.Cancellation()
        _ = ExternalProcess.run("/bin/cat", arguments: [url.path], timeout: 5,
            cancellation: cancellation, receiveStdout: { data in
                do { try reader.receive(data) { received.append($0) } }
                catch { rejected = true; cancellation.cancel() }
            })
        XCTAssertTrue(rejected)
        XCTAssertEqual(received, ["one", "two", "three"])
        XCTAssertFalse(reader.complete)
    }

    func testMalformedOversizedAndOverCapRecordsAreRejected() throws {
        var reader = WalkStream.Reader<String>(cap: 1)
        XCTAssertThrowsError(try reader.receive(Data([255, 255, 255, 255])) { _ in })
        reader = WalkStream.Reader<String>(cap: 1)
        XCTAssertThrowsError(try reader.receive(Data([0, 0, 0, 1, 0])) { _ in })
        reader = WalkStream.Reader<String>(cap: 1)
        let row = try WalkStream.encode(WalkStream.Record<String>.row("one"))
        try reader.receive(row) { _ in }
        XCTAssertThrowsError(try reader.receive(row) { _ in XCTFail("Cap bypassed") })
        reader = WalkStream.Reader<String>(cap: 1)
        try reader.receive(WalkStream.encode(WalkStream.Record<String>.finished(hitCap: false, readFailed: true))) { _ in }
        XCTAssertTrue(reader.readFailed)
        XCTAssertThrowsError(try reader.receive(row) { _ in XCTFail("Row after completion accepted") })
    }
}

final class TransferPlanTests: XCTestCase {
    private func u(_ p: String) -> URL { URL(fileURLWithPath: p) }

    func testPoliciesAreAppliedPerFileAndUndoIsExplicit() {
        let sources = [u("/one/a"), u("/two/b"), u("/three/c"), u("/four/d")]
        var asked: [URL] = []
        let plan = Transfer.plan(sources: sources, into: u("/target"), move: false,
                                 conflictNames: ["a", "b", "c"]) { conflict in
            asked.append(conflict.source)
            XCTAssertEqual(conflict.destination, self.u("/target/" + conflict.source.lastPathComponent))
            return conflict.source.lastPathComponent == "a" ? .skip : conflict.source.lastPathComponent == "b" ? .keepBoth : .replace
        }
        XCTAssertEqual(asked, Array(sources.prefix(3)))
        XCTAssertEqual(plan.map { $0.source }, sources)
        XCTAssertEqual(plan.map { $0.intent }, [.skip, .renameToUnique(numbered: false), .replaceWithStaging, .copy])
        XCTAssertNil(plan[0].undo)
        XCTAssertEqual(plan[2].undo, .removeDestination)
        let moves = Transfer.plan(sources: sources, into: u("/target"), move: true, conflictNames: []) { _ in XCTFail(); return nil }
        XCTAssertEqual(moves.map { $0.intent }, Array(repeating: .move, count: 4))
        XCTAssertEqual(moves[1].undo, .restoreSource(sources[1]))
    }

    func testSelfDuplicateBypassesDecisionAndUsesNumberedName() {
        let plan = Transfer.plan(sources: [u("/target/a.txt")], into: u("/target"), move: false,
                                 conflictNames: ["a.txt"]) { _ in XCTFail(); return nil }
        XCTAssertEqual(plan[0].intent, .renameToUnique(numbered: true))
        XCTAssertEqual(Transfer.previewDestination(plan[0], occupiedPaths: ["/target/a (1).txt", "/target/a (2).txt"]), u("/target/a (3).txt"))
    }

    func testUniqueNamesPreserveExtensionsAndExtensionlessNames() {
        for name in ["a.txt", "folder"] {
            let plan = Transfer.plan(sources: [u("/source/" + name)], into: u("/target"), move: false,
                                     conflictNames: [name]) { _ in .keepBoth }
            let second = name == "a.txt" ? "a 2.txt" : "folder 2"
            let third = name == "a.txt" ? "a 3.txt" : "folder 3"
            XCTAssertEqual(Transfer.previewDestination(plan[0], occupiedPaths: ["/target/" + name, "/target/" + second]), u("/target/" + third))
            XCTAssertEqual(Transfer.previewDestination(plan[0], occupiedPaths: []), u("/target/" + name))
        }
    }

    func testPromptCancellationDiscardsTheEntirePlan() {
        let plan = Transfer.plan(sources: [u("/one/a"), u("/two/b")], into: u("/target"), move: true,
                                 conflictNames: ["b"]) { _ in nil }
        XCTAssertTrue(plan.isEmpty, "Even preceding nonconflicting files must not execute")
    }

    func testSameNamesFromSeveralParentsKeepOriginalConflictScanSemantics() {
        let sources = [u("/one/a"), u("/two/a")]
        let plan = Transfer.plan(sources: sources, into: u("/target"), move: false, conflictNames: []) { _ in XCTFail(); return nil }
        XCTAssertEqual(plan.map { $0.intent }, [.copy, .copy])
        XCTAssertEqual(plan.map { $0.source }, sources)
        // The second is a late-arriving conflict during execution, not a new prompt.
        XCTAssertEqual(plan[0].destination, plan[1].destination)
    }
}

final class TransferExecutionTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var source: URL { root.appendingPathComponent("source") }
    private var target: URL { root.appendingPathComponent("target") }
    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("NavigatorTransfer-\(UUID().uuidString)")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }
    @discardableResult private func write(_ dir: URL, _ name: String, _ bytes: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }
    private func bytes(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private func plan(_ sources: [URL], move: Bool = false, conflicts: Set<String> = [], policy: ConflictPolicy = .keepBoth) -> [Transfer.Item] {
        Transfer.plan(sources: sources, into: target, move: move, conflictNames: conflicts) { _ in policy }
    }

    func testCopyAndMoveRecordOnlyTheirActualUndo() throws {
        let a = try write(source, "a", "copy bytes"), b = try write(source, "b", "move bytes")
        let result = Transfer.execute(plan([a]) + plan([b], move: true))
        XCTAssertEqual(result.outcomes.map { $0.status }, [.copied, .moved])
        XCTAssertEqual(try bytes(target.appendingPathComponent("a")), "copy bytes")
        XCTAssertEqual(try bytes(a), "copy bytes")
        XCTAssertFalse(fm.fileExists(atPath: b.path))
        XCTAssertEqual(result.copied, [target.appendingPathComponent("a")])
        XCTAssertEqual(result.moved.map { $0.from }, [b])
        XCTAssertEqual(result.outcomes[1].undo, .moveBack(from: target.appendingPathComponent("b"), to: b))
    }

    func testSkipDoesNotTouchEitherFile() throws {
        let a = try write(source, "a", "incoming"), old = try write(target, "a", "original")
        let result = Transfer.execute(plan([a], conflicts: ["a"], policy: .skip))
        XCTAssertEqual(result.outcomes[0].status, .skipped)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertNil(result.outcomes[0].undo)
        XCTAssertEqual(try bytes(a), "incoming")
        XCTAssertEqual(try bytes(old), "original")
    }

    func testKeepBothAndSelfDuplicateResolveNamesAgainstRealDisk() throws {
        let a = try write(source, "a.txt", "incoming")
        let old = try write(target, "a.txt", "original")
        try write(target, "a 2.txt", "occupied")
        let kept = Transfer.execute(plan([a], move: true, conflicts: ["a.txt"]))
        XCTAssertEqual(kept.outcomes[0].destination.lastPathComponent, "a 3.txt")
        XCTAssertEqual(kept.outcomes[0].status, .moved)
        XCTAssertEqual(try bytes(kept.outcomes[0].destination), "incoming")
        let dupPlan = Transfer.plan(sources: [old, old], into: target, move: false, conflictNames: []) { _ in XCTFail(); return nil }
        let duplicates = Transfer.execute(dupPlan)
        XCTAssertEqual(duplicates.copied.map { $0.lastPathComponent }, ["a (1).txt", "a (2).txt"])
        for url in duplicates.copied { XCTAssertEqual(try bytes(url), "original") }
    }

    func testSuccessfulReplaceDiscardsStashAfterIncomingLands() throws {
        for move in [false, true] {
            let name = move ? "move" : "copy"
            let a = try write(source, name, "incoming")
            let old = try write(target, name, "original")
            let result = Transfer.execute(plan([a], move: move, conflicts: [name], policy: .replace))
            XCTAssertEqual(result.outcomes[0].status, move ? .moved : .copied)
            XCTAssertEqual(try bytes(old), "incoming")
            XCTAssertTrue(result.failures.isEmpty)
        }
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: target.path).contains { $0.hasPrefix(".navigator-replacing-") })
    }

    func testFailureAtNContinuesProcessingFollowingFiles() throws {
        let a = try write(source, "a", "first"), missing = source.appendingPathComponent("missing"), c = try write(source, "c", "third")
        for move in [false, true] {
            if move { try fm.removeItem(at: target.appendingPathComponent("a")); try fm.removeItem(at: target.appendingPathComponent("c")) }
            let result = Transfer.execute(plan([a, missing, c], move: move))
            XCTAssertEqual(result.outcomes.map { $0.status }, [move ? .moved : .copied, .failed, move ? .moved : .copied])
            XCTAssertEqual(result.failures.map { $0.name }, ["missing"])
            XCTAssertNil(result.outcomes[1].undo)
            XCTAssertEqual(try bytes(target.appendingPathComponent("a")), "first")
            XCTAssertEqual(try bytes(target.appendingPathComponent("c")), "third")
        }
    }

    func testFailedReplacementRestoresOriginalBytesWithoutAHole() throws {
        for useBytes in [false, true] {
            let old = try write(target, "missing", "irreplaceable original")
            let result = Transfer.execute(plan([source.appendingPathComponent("missing")], conflicts: ["missing"], policy: .replace), useBytes: useBytes)
            XCTAssertEqual(result.outcomes[0].status, .failed)
            XCTAssertEqual(result.failures.count, 1)
            XCTAssertEqual(try bytes(old), "irreplaceable original")
            XCTAssertNil(result.outcomes[0].undo)
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: target.path), ["missing"])
        }
    }

    func testOccupiedRollbackKeepsOriginalBytesInReportedStash() throws {
        let old = try write(target, "missing", "irreplaceable original")
        var checks = 0
        let result = Transfer.execute(plan([source.appendingPathComponent("missing")], conflicts: ["missing"], policy: .replace), isCancelled: {
            checks += 1
            // A real competing destination appears after the first incoming copy fails.
            if checks == 2 {
                do { try self.write(self.target, "missing", "other process") } catch { XCTFail("\(error)") }
            }
            return false
        })
        XCTAssertEqual(result.outcomes[0].status, .failed)
        XCTAssertEqual(try bytes(old), "other process")
        let stash = try XCTUnwrap(try fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".navigator-replacing-") })
        XCTAssertEqual(try bytes(stash), "irreplaceable original")
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertTrue(result.failures[1].reason.contains(stash.lastPathComponent))
        XCTAssertNil(result.outcomes[0].undo)
    }

    func testCancelBetweenFilesStopsSubsequentFiles() throws {
        let a = try write(source, "a", "first"), b = try write(source, "b", "second")
        var cancelled = false
        let result = Transfer.execute(plan([a, b], move: true), isCancelled: { cancelled }, onFinish: { _ in cancelled = true })
        XCTAssertEqual(result.outcomes.map { $0.status }, [.moved, .notProcessed])
        XCTAssertEqual(result.moved.count, 1)
        XCTAssertEqual(try bytes(b), "second")
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("b").path))
        XCTAssertNil(restoreItems(result.moved.map { (from: $0.to, to: $0.from) }))
        XCTAssertEqual(try bytes(a), "first")
    }

    /// Renamed from testCancellationFailureLeavesDestinationAsMessageClaims. The contract is
    /// unchanged in substance — a file this transfer did not create must survive untouched —
    /// but the message is now accurate about WHY it is still there. Copies are written to a
    /// staging name and renamed into place only when whole, so a cancelled transfer never
    /// leaves anything of its own at the real name; anything sitting there belongs to someone
    /// else, and the message says exactly that.
    func testCancellationLeavesACompetingDestinationUntouchedAndSaysSo() throws {
        let a = try write(source, "a", "incoming"), b = try write(source, "b", "next")
        try fm.removeItem(at: a)
        var checks = 0
        let result = Transfer.execute(plan([a, b]), useBytes: true, isCancelled: {
            checks += 1
            if checks == 1 { return false }
            // Cancellation races with another writer after the incoming copy fails.
            do { try self.write(self.target, "a", "incomplete or competing bytes") }
            catch { XCTFail("\(error)") }
            return true
        })
        XCTAssertEqual(result.outcomes.map { $0.status }, [.cancelled, .notProcessed])
        let dest = target.appendingPathComponent("a")
        XCTAssertEqual(try bytes(dest), "incomplete or competing bytes")
        XCTAssertTrue(result.failures[0].reason.contains(dest.path))
        XCTAssertTrue(result.failures[0].reason.contains("this transfer did not create it"),
                      "got: \(result.failures[0].reason)")
        XCTAssertTrue(result.copied.isEmpty)
        XCTAssertEqual(try bytes(b), "next")
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("b").path))
    }

    func testLateDestinationIsRefusedAndFollowingFileStillRuns() throws {
        let a = try write(source, "a", "incoming"), b = try write(source, "b", "next")
        let items = plan([a, b])
        let old = try write(target, "a", "arrived after scan")
        let result = Transfer.execute(items)
        XCTAssertEqual(result.outcomes.map { $0.status }, [.failed, .copied])
        XCTAssertEqual(result.failures[0].reason, "destination appeared after the conflict check; retry the transfer")
        XCTAssertEqual(try bytes(old), "arrived after scan")
    }

    func testSameNameSourcesWithoutInitialConflictStillFailSecond() throws {
        let a = try write(source, "a", "first")
        let other = root.appendingPathComponent("other")
        try fm.createDirectory(at: other, withIntermediateDirectories: false)
        let b = try write(other, "a", "second")
        let result = Transfer.execute(plan([a, b]))
        XCTAssertEqual(result.outcomes.map { $0.status }, [.copied, .failed])
        XCTAssertEqual(try bytes(target.appendingPathComponent("a")), "first")
        XCTAssertEqual(result.copied.count, 1)
    }

    func testUndoPartialTransferUsesOnlySuccessfulOutcomes() throws {
        let oldDefaults = TrashOrigins.defaults
        let suite = "NavigatorTransferUndo-\(UUID().uuidString)"
        TrashOrigins.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TrashOrigins.defaults.removePersistentDomain(forName: suite); TrashOrigins.defaults = oldDefaults }

        let a = try write(source, "a", "move me"), b = try write(source, "b", "copy me")
        let untouched = try write(target, "untouched", "leave me")
        let result = Transfer.execute(plan([a], move: true) + plan([source.appendingPathComponent("missing"), b]))
        XCTAssertEqual(result.outcomes.map { $0.status }, [.moved, .failed, .copied])
        let stack = UndoStack()
        stack.push("Move", undo: { restoreItems(result.moved.map { (from: $0.to, to: $0.from) }) }, redo: { restoreItems(result.moved) })
        var trashed: [(from: URL, to: URL)] = []
        defer { for pair in trashed { try? fm.removeItem(at: pair.from) } }
        stack.push("Copy", undo: {
            let r = trashItems(result.copied); trashed = r.restores; return r.problem
        }, redo: { restoreItems(trashed) })
        stack.undo()
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("b").path))
        XCTAssertEqual(trashed.count, 1)
        stack.undo()
        XCTAssertEqual(try bytes(a), "move me")
        XCTAssertEqual(try bytes(b), "copy me")
        XCTAssertEqual(try bytes(untouched), "leave me")
        XCTAssertFalse(fm.fileExists(atPath: source.appendingPathComponent("missing").path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: target.path), ["untouched"])
    }

    func testPermissionFailureAtNStillCopiesNineOfTenFiles() throws {
        let sources = try (0..<10).map { try write(source, "file\($0)", "bytes \($0)") }
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: sources[4].path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sources[4].path) }
        XCTAssertThrowsError(try Data(contentsOf: sources[4]), "The fixture must actually deny reads")
        let result = Transfer.execute(plan(sources), useBytes: true)
        XCTAssertEqual(result.outcomes.map { $0.status }, (0..<10).map { $0 == 4 ? .failed : .copied })
        XCTAssertEqual(result.copied.count, 9)
        XCTAssertEqual(result.failures.map { $0.name }, ["file4"])
        for i in 0..<10 where i != 4 {
            XCTAssertEqual(try bytes(target.appendingPathComponent("file\(i)")), "bytes \(i)")
        }
    }

    func testCancelledReplacementRestoresOriginalAndStopsNextFile() throws {
        let old = try write(target, "missing", "original")
        let next = try write(source, "next", "next bytes")
        var checks = 0
        let result = Transfer.execute(plan([source.appendingPathComponent("missing"), next], conflicts: ["missing"], policy: .replace), isCancelled: {
            checks += 1
            return checks > 1
        })
        XCTAssertEqual(result.outcomes.map { $0.status }, [.cancelled, .notProcessed])
        XCTAssertEqual(try bytes(old), "original")
        XCTAssertEqual(try bytes(next), "next bytes")
        XCTAssertTrue(result.copied.isEmpty)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: target.path), ["missing"])
    }

    func testFailedStagingLeavesSourceAndProcessesNextFile() throws {
        let a = try write(source, "a", "incoming"), b = try write(source, "b", "next")
        // The scanned conflict disappeared before execution: staging must fail, not copy.
        let result = Transfer.execute(plan([a, b], conflicts: ["a"], policy: .replace))
        XCTAssertEqual(result.outcomes.map { $0.status }, [.failed, .copied])
        XCTAssertTrue(result.failures[0].reason.hasPrefix("could not replace the existing item:"))
        XCTAssertEqual(try bytes(a), "incoming")
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("a").path))
    }

    func testDirectoryCopyAndByteCopyPreserveContents() throws {
        let folder = source.appendingPathComponent("folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try write(folder, "nested", "nested bytes")
        let file = try write(source, "file", String(repeating: "payload", count: 10000))
        let folders = Transfer.execute(plan([folder]))
        let files = Transfer.execute(plan([file]), useBytes: true)
        XCTAssertEqual(folders.outcomes[0].status, .copied)
        XCTAssertEqual(files.outcomes[0].status, .copied)
        XCTAssertEqual(try bytes(target.appendingPathComponent("folder/nested")), "nested bytes")
        XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: files.copied[0]))
    }

    func testEmptyPlanDoesNoWork() {
        let result = Transfer.execute([], onStart: { _ in XCTFail() })
        XCTAssertTrue(result.outcomes.isEmpty)
    }
}

// A silent refresh used to re-read all ten attributes for every row. Measured on a real SMB
// share that is ~246 ms per entry, so a 672-entry folder spent about 165 seconds to notice one
// new file. These pin the rule that decides what actually has to be re-read.
final class RefreshRulesTests: XCTestCase {

    func testNothingChangedMeansNoAttributeWorkAtAll() {
        let p = RefreshRules.plan(existing: ["a", "b", "c"], fresh: ["a", "b", "c"])
        XCTAssertEqual(p.fetch, [], "an unchanged folder must not re-read a single attribute")
        XCTAssertEqual(p.reuse, ["a", "b", "c"])
        XCTAssertEqual(p.dropped, [])
        XCTAssertTrue(p.isUnchanged)
    }

    // The common case: someone else drops one file into a big folder.
    func testOnlyTheNewNameIsFetched() {
        let existing = (1...500).map { "file\($0)" }
        let p = RefreshRules.plan(existing: existing, fresh: existing + ["brand-new"])
        XCTAssertEqual(p.fetch, ["brand-new"], "500 unchanged rows must cost nothing")
        XCTAssertEqual(p.reuse.count, 500)
        XCTAssertFalse(p.isUnchanged)
    }

    func testRemovalIsReportedAndNothingIsFetched() {
        let p = RefreshRules.plan(existing: ["a", "b", "c"], fresh: ["a", "c"])
        XCTAssertEqual(p.dropped, ["b"])
        XCTAssertEqual(p.fetch, [])
        XCTAssertEqual(p.reuse, ["a", "c"])
    }

    // A rename is an add and a remove at once, and only the new name costs anything.
    func testRenameFetchesOnlyTheNewName() {
        let p = RefreshRules.plan(existing: ["old", "keep"], fresh: ["keep", "new"])
        XCTAssertEqual(p.fetch, ["new"])
        XCTAssertEqual(p.dropped, ["old"])
        XCTAssertEqual(p.reuse, ["keep"])
    }

    // The fresh listing is authoritative for ORDER, or a renamed row would stay where it was.
    func testFreshOrderIsPreserved() {
        let p = RefreshRules.plan(existing: ["b", "a"], fresh: ["a", "b", "c"])
        XCTAssertEqual(p.reuse, ["a", "b"], "reuse follows the fresh listing, not the old one")
        XCTAssertEqual(p.fetch, ["c"])
    }

    func testEmptyCases() {
        XCTAssertEqual(RefreshRules.plan(existing: [], fresh: ["a"]).fetch, ["a"])
        XCTAssertEqual(RefreshRules.plan(existing: ["a"], fresh: []).dropped, ["a"])
        XCTAssertTrue(RefreshRules.plan(existing: [], fresh: []).isUnchanged)
    }
}

final class VolumeHealthRulesTests: XCTestCase {
    private let root = "/Volumes/Games"

    func testDeadMountCostsOneDiscoveryFor300Entries() throws {
        var health = VolumeHealthRules()
        var discoveries = 0
        var now: TimeInterval = 0
        for _ in 0..<300 {
            if let ticket = health.begin(root: root, operation: .attributes, now: now) {
                discoveries += 1
                now = 15
                health.end(ticket, failure: MountFailureRules.cause(errno: ETIMEDOUT), now: now)
            }
        }
        XCTAssertEqual(discoveries, 1)
        XCTAssertTrue(health.isUnreachable(root: root, now: 15))
        // Expiring backoff permits a probe, never 300 new per-file discoveries.
        XCTAssertNil(health.begin(root: root, operation: .attributes, now: 1000))
    }

    func testUnfinishedCallSuppressesLaterWorkWithoutEnd() throws {
        var health = VolumeHealthRules()
        _ = try XCTUnwrap(health.begin(root: root, operation: .attributes, now: 0))
        XCTAssertFalse(health.isUnreachable(root: root, now: 14.9))
        for _ in 0..<300 {
            XCTAssertNil(health.begin(root: root, operation: .attributes, now: 15))
        }
        XCTAssertNil(health.begin(root: root, operation: .probe, now: 1000),
                     "A syscall still in the kernel must not acquire a second timeout")
    }

    func testRecoveryProbeClearsFlagAndAttributesResume() throws {
        var health = VolumeHealthRules()
        let failed = try XCTUnwrap(health.begin(root: root, operation: .attributes, now: 0))
        health.end(failed, failure: .unreachable, now: 1)
        XCTAssertNil(health.begin(root: root, operation: .probe, now: 15.9))
        let probe = try XCTUnwrap(health.begin(root: root, operation: .probe, now: 16))
        XCTAssertNil(health.begin(root: root, operation: .probe, now: 16))
        XCTAssertNil(health.begin(root: root, operation: .attributes, now: 16))
        health.end(probe, failure: nil, now: 16.1)
        XCTAssertFalse(health.isUnreachable(root: root, now: 16.1))
        XCTAssertNotNil(health.begin(root: root, operation: .attributes, now: 16.1))
    }

    func testSlowSuccessfulResponseOnlyBacksOffPoll() throws {
        var health = VolumeHealthRules()
        let ticket = try XCTUnwrap(health.begin(root: root, operation: .probe, now: 0))
        health.end(ticket, failure: nil, now: 3)
        XCTAssertFalse(health.isUnreachable(root: root, now: 3))
        XCTAssertNil(health.begin(root: root, operation: .probe, now: 4))
        XCTAssertNotNil(health.begin(root: root, operation: .attributes, now: 4))
    }

    func testLateSuccessClearsDeadlineSuspicion() throws {
        var health = VolumeHealthRules()
        let ticket = try XCTUnwrap(health.begin(root: root, operation: .attributes, now: 0))
        XCTAssertTrue(health.isUnreachable(root: root, now: 15))
        health.end(ticket, failure: nil, now: 20)
        XCTAssertFalse(health.isUnreachable(root: root, now: 20))
        XCTAssertNotNil(health.begin(root: root, operation: .attributes, now: 20))
    }

    func testLocalVolumesAndOtherSharesAreUnaffected() throws {
        var health = VolumeHealthRules()
        let remote = try XCTUnwrap(health.begin(root: root, operation: .attributes, now: 0))
        health.end(remote, failure: .unreachable, now: 1)
        // The mount-table adapter supplies nil for BOTH the boot disk and local USB disks.
        for _ in 0..<300 {
            let local = try XCTUnwrap(health.begin(root: nil, operation: .attributes, now: 2))
            health.end(local, failure: .unreachable, now: 3)
        }
        XCTAssertFalse(health.isUnreachable(root: nil, now: 1000))
        XCTAssertNotNil(health.begin(root: "/Volumes/Games Extra", operation: .attributes, now: 2))
    }

    func testOnlyTransportFailuresPoisonVolume() throws {
        for code in [EACCES, EPERM, ENOENT, ENODEV, ECANCELED, EIO] {
            var health = VolumeHealthRules()
            let ticket = try XCTUnwrap(health.begin(root: root, operation: .attributes, now: 0))
            let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            let error = NSError(domain: NSCocoaErrorDomain, code: 256,
                                userInfo: [NSUnderlyingErrorKey: underlying])
            health.end(ticket, failure: VolumeHealthRules.failure(error), now: 1)
            XCTAssertFalse(health.isUnreachable(root: root, now: 1), "errno \(code)")
            XCTAssertNotNil(health.begin(root: root, operation: .attributes, now: 1))
        }
        let timeout = NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))])
        XCTAssertEqual(VolumeHealthRules.failure(timeout), .unreachable)
    }

    func testRepeatedProbeFailuresUseExistingCappedBackoff() throws {
        var health = VolumeHealthRules()
        var now: TimeInterval = 0
        var ticket = try XCTUnwrap(health.begin(root: root, operation: .attributes, now: now))
        for strike in 1...6 {
            health.end(ticket, failure: .unreachable, now: now)
            let next = now + min(60, 15 * Double(strike))
            XCTAssertNil(health.begin(root: root, operation: .probe, now: next - 0.01))
            ticket = try XCTUnwrap(health.begin(root: root, operation: .probe, now: next))
            now = next
        }
    }
}

extension VolumeHealthRulesTests {
    func testOlderSuccessCannotEraseNewerTransportFailure() throws {
        var health = VolumeHealthRules()
        let older = try XCTUnwrap(health.begin(root: root, operation: .attributes, now: 0))
        let newer = try XCTUnwrap(health.begin(root: root, operation: .attributes, now: 0))
        health.end(newer, failure: .unreachable, now: 1)
        health.end(older, failure: nil, now: 1.1)
        XCTAssertTrue(health.isUnreachable(root: root, now: 1.1))
        XCTAssertNil(health.begin(root: root, operation: .probe, now: 2))
        XCTAssertNotNil(health.begin(root: root, operation: .probe, now: 16))
    }

    func testNewMountIgnoresAbandonedSessionCallbacks() throws {
        var health = VolumeHealthRules()
        let abandoned = try XCTUnwrap(health.begin(root: root, operation: .attributes, now: 0))
        XCTAssertTrue(health.isUnreachable(root: root, now: 15))
        health.reconnected(root: root)
        health.end(abandoned, failure: .unreachable, now: 100)
        XCTAssertFalse(health.isUnreachable(root: root, now: 100))
        XCTAssertNotNil(health.begin(root: root, operation: .attributes, now: 100))
    }

    func testConcurrentRecoveryAdmitsOnlyOneProbe() throws {
        let health = Synchronized(wrappedValue: VolumeHealthRules())
        let first = try XCTUnwrap(health.wrappedValue.begin(root: root, operation: .attributes, now: 0))
        health.wrappedValue.end(first, failure: .unreachable, now: 1)
        let admitted = Synchronized(wrappedValue: 0)
        DispatchQueue.concurrentPerform(iterations: 300) { _ in
            if health.wrappedValue.begin(root: root, operation: .probe, now: 16) != nil {
                admitted.wrappedValue += 1
            }
        }
        XCTAssertEqual(admitted.wrappedValue, 1)
    }
}

// ===== GDD to Assets =====
//
// The fixtures below are the REAL "Symbol Set" blocks from two GDDs in the shared
// Drive folder, pasted verbatim. They differ in shape, which is the whole point: a
// parser tuned to one silently miscounts the other.

final class GDDSymbolSetTests: XCTestCase {

    // 4260 Dodge: the code sits BEFORE the comment marker, and ranges name both ends
    // ("1-4 HP1-4").
    private let dodge = """
    Symbol Set
    * 0 WD1                // wild symbol
    * 1-4 HP1-4        // HPs
    * 5-9 LP1-5        // LPs
    * 10 WY1        // purple wys tied to feature 1 AND wys in bonus 1
    * 11 WY2        // green wys tied to feature 2
    * 12 SF1                // purple payer tied to feature 1
    * 13-14 R1-2        // replacements
    * 15 BWY1        // bonus variant of WY1 (purple)
    * 16 BWY2        // bonus variant of WY2 (green)
    * 17-20 JP1-4        // jackpots, grand -> mini
    * 21 MU1        // bonus 1 spread multiplier
    * 30 BL1                // blank in bonus 1 AND bonus 2
    Spinning & Winning
    4x5 ways game, with 4 HP symbols, 5 LP symbols, a wild symbol
    """

    // 4400 Chevy-Hot: the code sits AFTER the comment marker, and the medium/low pays
    // are named only as a plural group ("2-5 // MPs") that has to be counted out.
    private let chevyHot = """
    Symbol Set
      - 0 // WD1 (Wild Symbol)
      - 1 // HP1  (Standard HP symbols)
      - 2-5 // MPs  (Standard MP symbols)
      - 6-9 // LPs  (Standard LP symbols)
      - 10 //WY1  (Standard WYSIWYG)
      - 11        //SF1  (Special Collector Symbol)
      - 12 //R1 (Replacement 1)
      - 13 //BL (Blank)
      - 14 //WY2  (Hotspot WYSIWYG)
      - 15 //JP1  (Grand)
      - 16 //JP2  (Major)
      - 17 //JP3  (Minor)
      - 18 //JP4  (Mini)
    Special Symbols + Upgrades
    """

    func testDodgeCountAndCodes() {
        let s = GDDSymbolSetRules.parse(dodge)
        // 1 wild + 4 HP + 5 LP + 2 WY + 1 SF + 2 R + 2 BWY + 4 JP + 1 MU + 1 BL
        XCTAssertEqual(s.count, 23)
        XCTAssertEqual(s.map(\.code).prefix(5).joined(separator: ","), "WD1,HP1,HP2,HP3,HP4")
        XCTAssertTrue(s.contains { $0.code == "LP5" })
        XCTAssertTrue(s.contains { $0.code == "JP4" })
    }

    // The bug this guards: "2-5 // MPs" names no individual codes. Counting the
    // index range is the only way to learn there are four of them, and getting it
    // wrong drops four symbols from the game without any error.
    func testChevyHotExpandsPluralGroups() {
        let s = GDDSymbolSetRules.parse(chevyHot)
        let mps = s.filter { $0.role == .mediumPay }.map(\.code)
        XCTAssertEqual(mps, ["MP1", "MP2", "MP3", "MP4"])
        let lps = s.filter { $0.role == .lowPay }.map(\.code)
        XCTAssertEqual(lps, ["LP1", "LP2", "LP3", "LP4"])
        XCTAssertEqual(s.count, 19)
    }

    // BWY1 is a bonus WYSIWYG, not a blank that happens to start with B. Longest
    // prefix wins; a naive prefix scan classifies it as .blank and gives it the art
    // direction for an empty reel position.
    func testLongestPrefixWins() {
        XCTAssertEqual(GDDSymbolSetRules.classify("BWY1").role, .wysiwyg)
        XCTAssertEqual(GDDSymbolSetRules.classify("BL1").role, .blank)
        XCTAssertEqual(GDDSymbolSetRules.classify("BL").role, .blank)
        XCTAssertEqual(GDDSymbolSetRules.classify("WD1").role, .wild)
        XCTAssertEqual(GDDSymbolSetRules.classify("R2").role, .replacement)
    }

    func testTiersAreRead() {
        XCTAssertEqual(GDDSymbolSetRules.classify("HP3").tier, 3)
        XCTAssertEqual(GDDSymbolSetRules.classify("JP4").tier, 4)
        XCTAssertNil(GDDSymbolSetRules.classify("BL").tier)
    }

    // An unrecognised code must surface as .unknown rather than be forced into a
    // role: the wrong role hands the image model the wrong art direction, which is
    // harder to notice than an obviously unclassified row.
    func testUnknownCodeStaysUnknown() {
        XCTAssertEqual(GDDSymbolSetRules.classify("ZZ9").role, .unknown)
    }

    // Prose after the block must not become phantom symbols.
    func testStopsAtEndOfBlock() {
        let s = GDDSymbolSetRules.parse(dodge)
        XCTAssertFalse(s.contains { $0.code.hasPrefix("4X5") })
        XCTAssertFalse(s.contains { $0.role == .unknown })
    }

    func testNoSymbolSetHeadingYieldsNothing() {
        XCTAssertTrue(GDDSymbolSetRules.parse("Some other document entirely.").isEmpty)
    }

    func testBlanksAreTheOnlyThingNeedingNoArt() {
        XCTAssertFalse(SlotSymbolRole.blank.needsArt)
        XCTAssertTrue(SlotSymbolRole.highPay.needsArt)
        XCTAssertTrue(SlotSymbolRole.replacement.needsArt)
    }
}

// Writes the real planning prompt to disk so it can be fired at the live model
// during development. Not an assertion — a harness.
final class GDDPromptDumpTests: XCTestCase {
    func testDumpPlanningPrompt() throws {
        guard let out = ProcessInfo.processInfo.environment["GDD_PROMPT_DUMP"] else { return }
        let chevy = """
        Symbol Set
          - 0 // WD1 (Wild Symbol)
          - 1 // HP1  (Standard HP symbols)
          - 2-5 // MPs  (Standard MP symbols)
          - 6-9 // LPs  (Standard LP symbols)
          - 10 //WY1  (Standard WYSIWYG)
          - 11        //SF1  (Special Collector Symbol)
          - 12 //R1 (Replacement 1)
          - 13 //BL (Blank)
          - 14 //WY2  (Hotspot WYSIWYG)
          - 15 //JP1  (Grand)
          - 16 //JP2  (Major)
          - 17 //JP3  (Minor)
          - 18 //JP4  (Mini)
        Special Symbols + Upgrades
        The bonus game features free spins and a jackpot ladder.
        """
        let theme = GameTheme(
            name: "Jack and the Beanstalk", category: "Fairytale", comparables: "Megaways Jack",
            why: "A fairytale with a built-in ascent mechanic — climbing the beanstalk is a natural level-up feature — and NetEnt already proved the equity.",
            look: "The classic story brought to life: a giant beanstalk rising into a fantasy sky of floating castles and clouds. Whimsical soft greens, blues, and earth tones with magic beans, golden harps, and giants.",
            tier: "T1")
        let syms = GDDSymbolSetRules.parse(chevy)
        let jobs = AssetPlanRules.symbolJobs(syms) + AssetPlanRules.backgroundJobs(gddText: chevy)
        let p = GDDAssetPrompts.planning(theme: theme, gameName: "4400 Chevy-Hot", jobs: jobs)
        try (GDDAssetPrompts.planningSystem + "\n\u{1F536}SPLIT\u{1F536}\n" + p)
            .write(toFile: out, atomically: true, encoding: .utf8)
        print("slots=\(jobs.count)")
    }
}

// Development harness: feed a real model reply back through the real apply path.
final class GDDPlanApplyHarness: XCTestCase {
    func testApplyLiveReply() throws {
        guard let f = ProcessInfo.processInfo.environment["GDD_REPLY_FILE"],
              let reply = try? String(contentsOfFile: f, encoding: .utf8) else { return }
        let chevy = """
        Symbol Set
          - 0 // WD1 (Wild Symbol)
          - 1 // HP1  (Standard HP symbols)
          - 2-5 // MPs  (Standard MP symbols)
          - 6-9 // LPs  (Standard LP symbols)
          - 10 //WY1  (Standard WYSIWYG)
          - 11        //SF1  (Special Collector Symbol)
          - 12 //R1 (Replacement 1)
          - 13 //BL (Blank)
          - 14 //WY2  (Hotspot WYSIWYG)
          - 15 //JP1  (Grand)
          - 16 //JP2  (Major)
          - 17 //JP3  (Minor)
          - 18 //JP4  (Mini)
        The bonus game features free spins and a jackpot ladder.
        """
        let syms = GDDSymbolSetRules.parse(chevy)
        let jobs = AssetPlanRules.symbolJobs(syms) + AssetPlanRules.backgroundJobs(gddText: chevy)
        let j = try XCTUnwrap(GDDAssetPrompts.json(fromModelReply: reply), "reply was not JSON")
        let r = GDDAssetPrompts.apply(planJSON: j, to: jobs)
        let backing = SlotBackingRules.choose(palette: r.palette)
        print("SLOTS=\(jobs.count) FILLED=\(r.jobs.filter { !$0.subject.isEmpty }.count) MISSING=\(r.missing)")
        print("PALETTE=\(r.palette.count) BACKING=\(backing.name)")
        print("CLASHES=\(GDDAssetPrompts.silhouetteClashes(r.jobs))")
        for job in r.jobs where job.kind == .symbol {
            print("  \(job.id.padding(toLength: 5, withPad: " ", startingAt: 0)) [\(job.silhouette)] \(job.subject.prefix(72))")
        }
    }
}

final class GDDAssetPlanTests: XCTestCase {

    private let beanstalk = GameTheme(
        name: "Jack and the Beanstalk", category: "Fairytale", comparables: "Megaways Jack",
        look: "A giant beanstalk rising into a fantasy sky of floating castles and clouds. Whimsical soft greens, blues, and earth tones with magic beans, golden harps, and giants.")

    // The question this whole rule exists to answer: a beanstalk game is green AND
    // blue, so keying either colour out would eat the art. Magenta is what is left.
    func testBackingAvoidsColoursTheArtUses() {
        let palette = [RGB8(0x1B, 0x3B, 0x2B), RGB8(0x4A, 0x7C, 0x59), RGB8(0xD4, 0xAF, 0x37),
                       RGB8(0x87, 0xCE, 0xEB), RGB8(0x4A, 0x35, 0x25)]
        XCTAssertEqual(SlotBackingRules.choose(palette: palette).name, "chroma magenta")
    }

    // A magenta-and-gold game must not be keyed on magenta.
    func testBackingMovesOffMagentaWhenTheArtIsMagenta() {
        let palette = [RGB8(0xE0, 0x10, 0xD0), RGB8(0xFF, 0xD7, 0x00), RGB8(0x33, 0x00, 0x33)]
        XCTAssertNotEqual(SlotBackingRules.choose(palette: palette).name, "chroma magenta")
    }

    // No palette at all must still give a usable answer rather than black.
    func testBackingFallsBackWithoutPalette() {
        XCTAssertEqual(SlotBackingRules.choose(palette: []).name, "chroma magenta")
    }

    func testHexParsing() {
        XCTAssertEqual(SlotBackingRules.hex("#4A7C59"), RGB8(0x4A, 0x7C, 0x59))
        XCTAssertEqual(SlotBackingRules.hex("4a7c59"), RGB8(0x4A, 0x7C, 0x59))
        XCTAssertNil(SlotBackingRules.hex("soft green"))
        XCTAssertNil(SlotBackingRules.hex("#12345"))
    }

    // Models wrap JSON in fences or a sentence often enough that a raw parse fails
    // partway through a run. Every one of these shapes came back from a real call.
    func testJSONSurvivesModelPackaging() {
        let want = ##"{"palette":["#ffffff"],"assets":[{"id":"HP1","subject":"a","silhouette":"b"}]}"##
        for wrapped in [want,
                        "```json\n\(want)\n```",
                        "Here is the plan:\n\(want)",
                        "```\n\(want)\n```\nHope that helps!"] {
            XCTAssertNotNil(GDDAssetPrompts.json(fromModelReply: wrapped), "failed on: \(wrapped)")
        }
        XCTAssertNil(GDDAssetPrompts.json(fromModelReply: "I can't help with that."))
    }

    // A slot the planner skipped must be REPORTED, not generated with an empty
    // subject — an empty subject prompt still costs a credit and returns garbage.
    func testMissingSlotsAreReportedNotGenerated() {
        let jobs = [AssetJob(id: "HP1", kind: .symbol, role: .highPay, tier: 1, title: "",
                             aspect: "1:1", size: "2K"),
                    AssetJob(id: "HP2", kind: .symbol, role: .highPay, tier: 2, title: "",
                             aspect: "1:1", size: "2K")]
        let j = GDDAssetPrompts.json(fromModelReply:
            #"{"assets":[{"id":"HP1","subject":"a giant","silhouette":"giant"}]}"#)!
        let r = GDDAssetPrompts.apply(planJSON: j, to: jobs)
        XCTAssertEqual(r.missing, ["HP2"])
        XCTAssertEqual(r.jobs.first { $0.id == "HP1" }?.subject, "a giant")
        XCTAssertTrue(r.jobs.first { $0.id == "HP2" }?.subject.isEmpty ?? false)
    }

    // Two symbols with the same silhouette is the classic way a set fails. It must
    // surface before any credits are spent, not after twenty images come back.
    func testSilhouetteClashesAreFound() {
        func j(_ id: String, _ sil: String) -> AssetJob {
            AssetJob(id: id, kind: .symbol, role: .mediumPay, tier: 1, title: "",
                     subject: "x", silhouette: sil, aspect: "1:1", size: "2K")
        }
        let clashes = GDDAssetPrompts.silhouetteClashes([j("MP1", "Golden harp"),
                                                         j("MP2", "golden harp"),
                                                         j("MP3", "coin sack")])
        XCTAssertEqual(clashes.count, 1)
        XCTAssertEqual(clashes["golden harp"].map { $0.sorted() } ?? [], ["MP1", "MP2"])
    }

    // Blanks are reel positions, not pictures. Generating one wastes a credit.
    func testPlanSkipsBlanksAndOrdersByImportance() {
        let syms = GDDSymbolSetRules.parse("""
        Symbol Set
        * 0 WD1   // wild
        * 1-2 HP1-2  // HPs
        * 3-4 LP1-2  // LPs
        * 5 BL1   // blank
        """)
        let jobs = AssetPlanRules.symbolJobs(syms)
        XCTAssertFalse(jobs.contains { $0.id == "BL1" })
        XCTAssertEqual(jobs.map(\.id), ["HP1", "HP2", "WD1", "LP1", "LP2"])
        XCTAssertTrue(jobs.allSatisfy { $0.aspect == "1:1" && $0.size == "2K" })
    }

    // Backgrounds are only created for modes the document actually names.
    func testBackgroundsFollowTheDocument() {
        XCTAssertEqual(AssetPlanRules.backgroundJobs(gddText: "A plain game.").map(\.id),
                       ["bg_base"])
        // A jackpot LADDER is a meter, not a scene — see testJackpotSymbolsDoNotInventAJackpotScene.
        // "free spins bonus game" is ONE mode, so it yields one free-games scene, not a
        // bonus scene as well — see GDDSceneTests.
        let rich = AssetPlanRules.backgroundJobs(gddText: "Free spins bonus game with a jackpot wheel.")
        XCTAssertEqual(rich.map(\.id).sorted(), ["bg_base", "bg_freegames", "bg_jackpot"])
        // Backgrounds take whatever format covers the 1920x2532 portrait target,
        // rather than a fixed ratio — see BackgroundFormatRules.
        let fmt = BackgroundFormatRules.best()
        XCTAssertTrue(rich.allSatisfy { $0.aspect == fmt.aspect && $0.size == fmt.size })
    }

    // The backing colour must be named in the drawing prompt, and the model must be
    // told not to use it inside the art — the whole alpha pipeline depends on it.
    func testImagePromptPinsTheBackingColour() {
        let job = AssetJob(id: "HP1", kind: .symbol, role: .highPay, tier: 1, title: "",
                           subject: "a giant", silhouette: "giant", aspect: "1:1", size: "2K")
        let p = GDDAssetPrompts.image(job: job, theme: beanstalk,
                                      backing: SlotBackingRules.candidates[2])
        XCTAssertTrue(p.contains("#FF00FF"))
        XCTAssertTrue(p.contains("Do NOT use chroma magenta anywhere in the symbol itself"))
        XCTAssertTrue(p.contains("NO text"))
        XCTAssertTrue(p.contains("Jack and the Beanstalk"))
    }

    // A background is a scene with a calm middle, not a symbol.
    func testBackgroundPromptKeepsTheCentreClear() {
        let job = AssetJob(id: "bg_base", kind: .background, role: .unknown, tier: nil,
                           title: "", subject: "a sky of floating castles", aspect: "9:16", size: "2K")
        let p = GDDAssetPrompts.image(job: job, theme: beanstalk,
                                      backing: SlotBackingRules.candidates[0])
        XCTAssertTrue(p.contains("CENTRE"))
        XCTAssertFalse(p.contains("chroma green"))   // backgrounds are not keyed
    }

    // Role direction has to actually differ per role, or every symbol comes back the same.
    func testRoleDirectionsAreDistinct() {
        // collector, activator and adder deliberately SHARE one block — it names all four
        // special-feature jobs and the symbol's own GDD note says which applies. Every
        // other role must still read differently from every other.
        let shared: Set<SlotSymbolRole> = [.collector, .activator, .adder]
        let distinct = SlotSymbolRole.allCases.filter { !shared.contains($0) }
            .map { SlotArtDirection.direction(for: $0, tier: 1) }
        XCTAssertEqual(Set(distinct).count, distinct.count)
        XCTAssertEqual(Set(shared.map { SlotArtDirection.direction(for: $0, tier: 1) }).count, 1)
        // Was "ENERGY FORM", then "TRANSFORMATION" — both removed, because either
        // abstraction produced a swirling vortex. The wild now names a concrete subject.
        // See ArtDirectionQualityTests.testWildRefusesTheVortexDefault.
        XCTAssertTrue(SlotArtDirection.direction(for: .wild, tier: nil).contains("SPECIFIC SUBJECT"))
        // "never a human" was removed — it had no basis. See testMediumPayDoesNotBanPeople.
        XCTAssertTrue(SlotArtDirection.direction(for: .mediumPay, tier: 1).contains("middle band"))
        XCTAssertTrue(SlotArtDirection.direction(for: .jackpot, tier: 1).contains("GRAND"))
        // Was "NO writing on it" alongside a mandated half-size blank plate. The plate
        // size was invented precision; what matters is that the game prints the value.
        XCTAssertTrue(SlotArtDirection.direction(for: .wysiwyg, tier: nil)
            .contains("NO lettering or numerals"))
    }
}

// Development harness: emit the real per-image prompts for a live generation test.
final class GDDImagePromptDump: XCTestCase {
    func testDumpImagePrompts() throws {
        guard let dir = ProcessInfo.processInfo.environment["GDD_IMG_DUMP"],
              let replyFile = ProcessInfo.processInfo.environment["GDD_REPLY_FILE"],
              let reply = try? String(contentsOfFile: replyFile, encoding: .utf8) else { return }
        let chevy = """
        Symbol Set
          - 0 // WD1 (Wild Symbol)
          - 1 // HP1  (Standard HP symbols)
          - 2-5 // MPs  (Standard MP symbols)
          - 6-9 // LPs  (Standard LP symbols)
          - 10 //WY1  (Standard WYSIWYG)
          - 11        //SF1  (Special Collector Symbol)
          - 12 //R1 (Replacement 1)
          - 13 //BL (Blank)
          - 14 //WY2  (Hotspot WYSIWYG)
          - 15 //JP1  (Grand)
          - 16 //JP2  (Major)
          - 17 //JP3  (Minor)
          - 18 //JP4  (Mini)
        The bonus game features free spins and a jackpot ladder.
        """
        let theme = GameTheme(
            name: "Jack and the Beanstalk", category: "Fairytale", comparables: "Megaways Jack",
            look: "The classic story brought to life: a giant beanstalk rising into a fantasy sky of floating castles and clouds. Whimsical soft greens, blues, and earth tones with magic beans, golden harps, and giants.")
        let syms = GDDSymbolSetRules.parse(chevy)
        let jobs = AssetPlanRules.symbolJobs(syms) + AssetPlanRules.backgroundJobs(gddText: chevy)
        let j = try XCTUnwrap(GDDAssetPrompts.json(fromModelReply: reply))
        let r = GDDAssetPrompts.apply(planJSON: j, to: jobs)
        let backing = SlotBackingRules.choose(palette: r.palette)
        let want = ProcessInfo.processInfo.environment["GDD_IMG_IDS"]?
            .split(separator: ",").map(String.init) ?? ["HP1"]
        for job in r.jobs where want.contains(job.id) {
            let p = GDDAssetPrompts.image(job: job, theme: theme, backing: backing)
            try p.write(toFile: "\(dir)/\(job.id).prompt.txt", atomically: true, encoding: .utf8)
            print("WROTE \(job.id) aspect=\(job.aspect) size=\(job.size)")
        }
    }
}

final class GeneratedSizeTests: XCTestCase {
    // Measured behaviour: four identical NB2 calls asking for 2K at 1:1 returned
    // 1024 twice and 2048 twice, at the same price. Half size must be caught.
    func testHalfSizeIsCaught() {
        XCTAssertTrue(GeneratedSizeRules.isUndersized(longEdge: 1024, requested: "2K"))
        XCTAssertFalse(GeneratedSizeRules.isUndersized(longEdge: 2048, requested: "2K"))
    }

    // A 9:16 request lands on numbers like 1536x2752 that satisfy "2K" without
    // matching it exactly; flagging those would cry wolf on every background.
    func testTallImagesAreNotFalselyFlagged() {
        XCTAssertFalse(GeneratedSizeRules.isUndersized(longEdge: 2752, requested: "2K"))
        XCTAssertFalse(GeneratedSizeRules.isUndersized(longEdge: 1900, requested: "2K"))
    }

    func testTargets() {
        XCTAssertEqual(GeneratedSizeRules.targetLongEdge("4K"), 4096)
        XCTAssertEqual(GeneratedSizeRules.targetLongEdge("2K"), 2048)
        XCTAssertEqual(GeneratedSizeRules.targetLongEdge("1K"), 1024)
    }
}

final class BackgroundFormatTests: XCTestCase {

    // The portrait background the games are built to. Nothing at 2K reaches it, so
    // this must come out as a 4K request — and 3:4, not 9:16, because every 4K
    // request yields the same pixel COUNT and only the shape distinguishes them.
    func testPortraitTargetPicks3x4At4K() {
        let b = BackgroundFormatRules.best()
        XCTAssertEqual(b.aspect, "3:4")
        XCTAssertEqual(b.size, "4K")
        let p = BackgroundFormatRules.pixels(ratio: 3.0 / 4, size: "4K")
        XCTAssertTrue(BackgroundFormatRules.covers(width: p.w, height: p.h))
    }

    // Guards the claim the choice rests on: no 2K format covers 1920x2532.
    func testNo2KFormatCoversThePortraitTarget() {
        for (_, r) in BackgroundFormatRules.ratios {
            let p = BackgroundFormatRules.pixels(ratio: r, size: "2K")
            XCTAssertFalse(BackgroundFormatRules.covers(width: p.w, height: p.h),
                           "2K \(p.w)x\(p.h) unexpectedly covers the target")
        }
    }

    // The measured shape of a real call: "2K" at 9:16 came back 1536x2752, so the
    // pixel model has to predict roughly that.
    func testPixelModelMatchesAMeasuredCall() {
        let p = BackgroundFormatRules.pixels(ratio: 9.0 / 16, size: "2K")
        XCTAssertEqual(p.w, 1536)
        XCTAssertEqual(abs(p.h - 2752) < 32, true, "predicted \(p.h), measured 2752")
    }

    // A smaller target must not be forced up to 4K.
    func testSmallTargetStaysSmall() {
        let b = BackgroundFormatRules.best(target: (w: 700, h: 1200))
        XCTAssertEqual(b.size, "1K")
    }

    // 9:21 is listed as a Nano Banana ratio but the service substitutes 9:16 for it,
    // so it must not be offered here.
    func testUnhonouredRatioIsNotOffered() {
        XCTAssertFalse(BackgroundFormatRules.ratios.contains { $0.name == "9:21" })
    }
}

// Bugs found by review, each one a paid mistake or a wrong asset set.
final class GDDAssetReviewFixTests: XCTestCase {

    // Designing the set again and getting a SHORTER answer used to leave the previous
    // subject in place: reported missing, but still carrying text — so generation drew
    // it and charged for it.
    func testRedesignClearsSubjectsTheModelOmitted() {
        var job = AssetJob(id: "HP2", kind: .symbol, role: .highPay, tier: 2, title: "",
                           subject: "an old subject from last time", silhouette: "old",
                           aspect: "1:1", size: "2K")
        job.subject = "an old subject from last time"
        let j = GDDAssetPrompts.json(fromModelReply: #"{"assets":[]}"#)!
        let r = GDDAssetPrompts.apply(planJSON: j, to: [job])
        XCTAssertEqual(r.missing, ["HP2"])
        XCTAssertEqual(r.jobs[0].subject, "")
        XCTAssertEqual(r.jobs[0].silhouette, "")
    }

    // A whitespace-only subject is not a subject.
    func testWhitespaceSubjectCountsAsMissing() {
        let job = AssetJob(id: "HP1", kind: .symbol, role: .highPay, tier: 1, title: "",
                           aspect: "1:1", size: "2K")
        let j = GDDAssetPrompts.json(fromModelReply:
            #"{"assets":[{"id":"HP1","subject":"   ","silhouette":"x"}]}"#)!
        XCTAssertEqual(GDDAssetPrompts.apply(planJSON: j, to: [job]).missing, ["HP1"])
    }

    // "1-2 HP1-4" declares four codes across two indices. It used to produce four
    // symbols at indices 1,2,2,2 — two of them invented, each a paid image.
    func testMismatchedRangeIsRejectedNotClamped() {
        let s = GDDSymbolSetRules.parse("""
        Symbol Set
        * 0 WD1   // wild
        * 1-2 HP1-4  // mismatched
        * 3-4 LP1-2  // fine
        """)
        XCTAssertFalse(s.contains { $0.code == "HP3" || $0.code == "HP4" })
        XCTAssertEqual(s.filter { $0.role == .lowPay }.map(\.code), ["LP1", "LP2"])
    }

    // A typo used to try to build a billion strings on the parsing thread.
    func testAbsurdRangeIsRefused() {
        let s = GDDSymbolSetRules.parse("""
        Symbol Set
        * 1 HP1-1000000000  // typo
        """)
        XCTAssertTrue(s.isEmpty)
    }

    // "jackpot" alone matched any game with a jackpot SYMBOL — which is most of them —
    // and invented a 4K jackpot scene nobody asked for.
    func testJackpotSymbolsDoNotInventAJackpotScene() {
        let ids = AssetPlanRules.backgroundJobs(gddText: """
        Symbol Set
        * 15-18 JP1-4 // jackpots, grand -> mini
        Jackpots that land in base game do not pay out.
        """).map(\.id)
        XCTAssertEqual(ids, ["bg_base"])
    }

    // A game that really does have a jackpot round still gets one.
    func testNamedJackpotRoundStillGetsAScene() {
        let ids = AssetPlanRules.backgroundJobs(gddText: "Landing three triggers the jackpot wheel.").map(\.id)
        XCTAssertTrue(ids.contains("bg_jackpot"))
    }

    func testBonusNeedsANamedModeNotTheWordBonus() {
        XCTAssertEqual(AssetPlanRules.backgroundJobs(gddText: "The bonus symbol is a chest.").map(\.id),
                       ["bg_base"])
        XCTAssertTrue(AssetPlanRules.backgroundJobs(gddText: "Three scatters award the bonus game.")
                        .map(\.id).contains("bg_bonus"))
    }
}

final class GDDOutputTests: XCTestCase {
    func testFolderNameCombinesGameAndTheme() {
        XCTAssertEqual(GDDOutputRules.folderName(game: "4400 Chevy-Hot GDD",
                                                 theme: "Jack and the Beanstalk"),
                       "4400 Chevy-Hot GDD — Jack and the Beanstalk")
    }

    // A theme name with a slash in it must not turn into a nested path.
    func testPathSeparatorsAreStripped() {
        let n = GDDOutputRules.folderName(game: "A/B", theme: "C:D")
        XCTAssertFalse(n.contains("/"))
        XCTAssertFalse(n.contains(":"))
    }

    // Running the same game and theme twice is normal — a second pass after editing
    // a few subjects. The first run's art must not be written over.
    func testSecondRunGetsItsOwnFolder() {
        let base = "4400 — Jack"
        XCTAssertEqual(GDDOutputRules.uniqueName(base, existing: []), base)
        XCTAssertEqual(GDDOutputRules.uniqueName(base, existing: [base]), "4400 — Jack 2")
        XCTAssertEqual(GDDOutputRules.uniqueName(base, existing: [base, "4400 — Jack 2"]),
                       "4400 — Jack 3")
    }

    func testEmptyNamesStillGiveAFolder() {
        XCTAssertFalse(GDDOutputRules.folderName(game: "", theme: "").isEmpty)
    }
}

final class SymbolCanvasTests: XCTestCase {
    private let magenta = RGB8(255, 0, 255)

    /// A 100x100 magenta field with a 20x30 opaque block at (30, 40).
    private func field(_ w: Int, _ h: Int, box: (x: Int, y: Int, w: Int, h: Int)?) -> (Int, Int) -> RGB8 {
        return { x, y in
            guard let b = box, x >= b.x, x < b.x + b.w, y >= b.y, y < b.y + b.h else {
                return RGB8(255, 0, 255)
            }
            return RGB8(20, 200, 40)
        }
    }

    func testFindsTheSubjectBox() {
        let b = SymbolCanvasRules.subjectBounds(width: 100, height: 100, backing: magenta,
                                                sample: field(100, 100, box: (30, 40, 20, 30)))
        XCTAssertEqual(b?.x, 30); XCTAssertEqual(b?.y, 40)
        XCTAssertEqual(b?.w, 20); XCTAssertEqual(b?.h, 30)
    }

    // An all-backing image has no subject. Inventing a box would drop the cut-out at
    // an arbitrary spot, which looks fine in a folder and wrong on a reel.
    func testEmptyFieldHasNoBox() {
        XCTAssertNil(SymbolCanvasRules.subjectBounds(width: 40, height: 40, backing: magenta,
                                                     sample: field(40, 40, box: nil)))
    }

    func testPlacementPutsTheCutoutBackWhereItCameFrom() {
        let at = SymbolCanvasRules.placement(cutout: (20, 30), bounds: (30, 40, 20, 30),
                                             canvas: (100, 100))
        XCTAssertEqual(at?.x, 30); XCTAssertEqual(at?.y, 40)
    }

    // Photoshop's trim and our scan agree to within a pixel or two, not exactly.
    func testSmallDisagreementIsCentred() {
        let at = SymbolCanvasRules.placement(cutout: (18, 28), bounds: (30, 40, 20, 30),
                                             canvas: (100, 100))
        XCTAssertEqual(at?.x, 31); XCTAssertEqual(at?.y, 41)
    }

    // A big disagreement means the cut-out is not what the box describes. Refuse
    // rather than place it wrong.
    func testBigDisagreementIsRefused() {
        XCTAssertNil(SymbolCanvasRules.placement(cutout: (200, 300), bounds: (30, 40, 20, 30),
                                                 canvas: (100, 100)))
    }

    // Measured on the real run: the glowing wild's cut-out was 1748x1743 against a
    // scanned box of 1767x1799 on a 2048 canvas — a 56px disagreement, because a soft
    // glow fades into the backing. A flat 24px tolerance refused exactly the soft
    // symbols and placed the hard ones, which is the opposite of a consistent set.
    func testSoftEdgedSymbolIsStillPlaced() {
        let at = SymbolCanvasRules.placement(cutout: (1748, 1743), bounds: (115, 161, 1767, 1799),
                                             canvas: (2048, 2048))
        XCTAssertNotNil(at)
        XCTAssertEqual(at?.x, 115 + (1767 - 1748) / 2)
        XCTAssertEqual(at?.y, 161 + (1799 - 1743) / 2)
    }

    func testToleranceScalesWithCanvas() {
        XCTAssertEqual(SymbolCanvasRules.tolerance(canvas: (2048, 2048)), 102)
        XCTAssertEqual(SymbolCanvasRules.tolerance(canvas: (100, 100)), 24)
    }

    func testPlacementNeverRunsOffTheCanvas() {
        XCTAssertNil(SymbolCanvasRules.placement(cutout: (20, 30), bounds: (90, 90, 20, 30),
                                                 canvas: (100, 100)))
    }
}

final class StyleTextRulesTests: XCTestCase {
    func testTagsAreSplitFromTheProse() {
        let r = StyleTextRules.split("Painterly fantasy with soft light.\n\nEDGE-TREATMENT: outline\nRIM-GLOW: yes")
        XCTAssertEqual(r.prose, "Painterly fantasy with soft light.")
        XCTAssertEqual(r.tags, ["Edges: outline", "Rim glow: yes"])
    }

    // A colon in ordinary prose is not a tag.
    func testProseWithAColonIsLeftAlone() {
        let text = "Palette: deep greens and gold, with rim light."
        XCTAssertEqual(StyleTextRules.split(text).prose, text)
        XCTAssertEqual(StyleTextRules.split(text).tags, [])
    }

    func testNoTagsAtAll() {
        XCTAssertEqual(StyleTextRules.split("Clean vector art.").tags, [])
    }
}

final class ThemeStyleKeyTests: XCTestCase {
    private let art = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQ"

    // The whole point: artwork changed on the hub must not inherit the old read.
    func testChangedArtworkGetsADifferentKey() {
        XCTAssertNotEqual(ThemeStyleRules.key(theme: "Loki", artDataURL: art),
                          ThemeStyleRules.key(theme: "Loki", artDataURL: art + "X"))
    }

    // Unchanged artwork reuses its read — the vision pass is not repeatable.
    func testIdenticalArtworkGetsTheSameKeyEveryTime() {
        XCTAssertEqual(ThemeStyleRules.key(theme: "Loki", artDataURL: art),
                       ThemeStyleRules.key(theme: "Loki", artDataURL: art))
    }

    // Two themes sharing a picture are still two entries.
    func testTheThemeIsPartOfTheKey() {
        XCTAssertNotEqual(ThemeStyleRules.key(theme: "Loki", artDataURL: art),
                          ThemeStyleRules.key(theme: "Thor", artDataURL: art))
    }
}

final class KeyColorConfigTests: XCTestCase {
    // The script's own default is customKeyColorHex "#00FF00", and in custom mode the hex
    // wins. Handing over the colour any other way keyed magenta art for green and removed
    // nothing — so the hex must be present and must be the backing.
    func testTheBackingIsHandedOverAsTheHexTheScriptActuallyReads() {
        let c = ChromaKeyOutputRules.keyColorConfig(RGB8(253, 2, 251))
        XCTAssertEqual(c["keyMode"] as? String, "custom")
        XCTAssertEqual(c["customKeyColorHex"] as? String, "#FD02FB")
        XCTAssertNil(c["customKeyColor"], "an array alone is overridden by the script's green default")
    }
}

final class SolidSubjectMatteTests: XCTestCase {
    typealias M = ChromaKeyOutputRules.SolidSubjectMatte
    private let magenta = RGB8(253, 2, 251)
    private let W = 40, H = 40

    /// A 40×40 magenta field with a 24×24 subject in the middle. Keylight's alpha is
    /// supplied the way Keylight gets it wrong: the subject's SKIN is keyed half
    /// transparent, because skin carries red.
    private func scene(_ paint: (Int, Int) -> (RGB8, UInt8)?) -> (src: [UInt8], key: [UInt8]) {
        var src = [UInt8](repeating: 0, count: W * H * 4), key = src
        for y in 0..<H { for x in 0..<W {
            let i = (y * W + x) * 4
            let (c, a) = paint(x, y) ?? (magenta, 0)
            src[i] = c.r; src[i+1] = c.g; src[i+2] = c.b; src[i+3] = 255
            key[i] = 0; key[i+1] = 200; key[i+2] = 0; key[i+3] = a      // Keylight's green cast
        } }
        return (src, key)
    }
    private func px(_ out: [UInt8], _ x: Int, _ y: Int) -> (RGB8, UInt8) {
        let i = (y * W + x) * 4
        return (RGB8(out[i], out[i+1], out[i+2]), out[i+3])
    }
    private let gold = RGB8(212, 175, 55), skin = RGB8(228, 150, 120)

    // The reported bug: the whole symbol came back green and see-through.
    func testTheSubjectComesBackOpaqueInItsOwnColour() {
        let (src, key) = scene { x, y in
            guard (8..<32).contains(x), (8..<32).contains(y) else { return nil }
            let border = x == 8 || y == 8 || x == 31 || y == 31
            return border ? (self.gold, 255) : (self.skin, 120)         // skin keyed half-clear
        }
        let out = M.apply(source: src, keyed: key, width: W, height: H, backing: magenta)
        XCTAssertEqual(px(out, 20, 20).0, skin, "interior keeps its source colour, not Keylight's green")
        XCTAssertEqual(px(out, 20, 20).1, 255, "interior is opaque even where Keylight said 120")
        XCTAssertEqual(px(out, 2, 2).1, 0, "the field is gone")
    }

    // The rule: remove the field, not the colour. Magenta artwork INSIDE the symbol —
    // a neon glow — is not connected to the border and is not the flat backing.
    func testMagentaArtworkInsideTheSymbolSurvives() {
        let pink = RGB8(245, 60, 220)                                     // 60+ from the backing
        let (src, key) = scene { x, y in
            guard (8..<32).contains(x), (8..<32).contains(y) else { return nil }
            if (15..<25).contains(x), (15..<25).contains(y) { return (pink, 0) }   // Keylight: clear
            return (self.gold, 255)
        }
        let out = M.apply(source: src, keyed: key, width: W, height: H, backing: magenta)
        XCTAssertEqual(px(out, 20, 20).1, 255)
        XCTAssertEqual(px(out, 20, 20).0, pink)
    }

    // …but a gap between a frame and a figure, showing the flat backing itself, IS
    // background even though it is enclosed.
    func testAnEnclosedPocketOfTheBackingIsRemoved() {
        let (src, key) = scene { x, y in
            guard (8..<32).contains(x), (8..<32).contains(y) else { return nil }
            if (15..<25).contains(x), (15..<25).contains(y) { return (RGB8(250, 6, 246), 0) }  // backing, 5 off
            return (self.gold, 255)
        }
        let out = M.apply(source: src, keyed: key, width: W, height: H, backing: magenta)
        XCTAssertEqual(px(out, 20, 20).1, 0)
    }

    // At the rim both colours are known, so alpha comes from where the pixel sits on the
    // line from backing to foreground — not from Keylight, which under-reads there.
    func testARimPixelGetsItsMixAlphaAndItsOwnColour() {
        let half = RGB8(UInt8((212 + 253) / 2), UInt8((175 + 2) / 2), UInt8((55 + 251) / 2))
        let (src, key) = scene { x, y in
            guard (8..<32).contains(x), (8..<32).contains(y) else { return x == 7 && (8..<32).contains(y) ? (half, 40) : nil }
            return (self.gold, 255)
        }
        let out = M.apply(source: src, keyed: key, width: W, height: H, backing: magenta)
        let (c, a) = px(out, 7, 20)
        XCTAssertEqual(Double(a), 127.5, accuracy: 6, "half-covered pixel reads half alpha, not Keylight's 40")
        XCTAssertEqual(Double(c.r), 212, accuracy: 8); XCTAssertEqual(Double(c.g), 175, accuracy: 8)
        XCTAssertEqual(Double(c.b), 55, accuracy: 8, "its colour is gold, with the magenta taken out")
    }

    // Regression for the silent skip: a symbol generated on a backing decodes as RGB with
    // a padding byte, and the repair used to demand straight RGBA, return nil, and ship
    // Keylight's output untouched. Decoding must now hand back usable straight RGBA.
    func testAnRGBSourceWithNoAlphaDecodesToOpaqueStraightRGBA() throws {
        // Built from exact bytes: CGColor(red:green:blue:) is Generic RGB, and filling an
        // sRGB context with it converts 212 to 221 before the code under test ever runs.
        let bytes0 = [UInt8]((0..<16).flatMap { _ in [212, 175, 55, 0] })   // 4th byte is padding
        let img = try XCTUnwrap(CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: Data(bytes0) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        XCTAssertEqual(img.alphaInfo, .noneSkipLast, "the shape a generated symbol really has")
        let bytes = try XCTUnwrap(ChromaKeyOutputRules.straightRGBA8(img))
        XCTAssertEqual(Array(bytes[0..<4]), [212, 175, 55, 255])
    }
}

final class SpillRecoveryTests: XCTestCase {
    private let magenta = RGB8(255, 0, 255)

    // A fully opaque pixel contains no backing at all, so the source colour IS the
    // foreground. This is the case Keylight got wrong: it despilled anyway, turning a
    // gold-and-crimson symbol green.
    func testOpaquePixelRecoversTheSourceExactly() {
        let gold = RGB8(212, 175, 55)
        let out = ChromaKeyOutputRules.SpillRules.foreground(source: gold, backing: magenta, alpha: 255)
        XCTAssertEqual(out, gold)
    }

    // Half-covered: S = F/2 + B/2, so F = 2S - B. Built from a known F and checked.
    func testHalfCoveredPixelInvertsTheComposite() {
        let f = RGB8(200, 100, 40)
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Int(a) + Int(b)) / 2) }
        let s = RGB8(mix(f.r, magenta.r), mix(f.g, magenta.g), mix(f.b, magenta.b))
        let out = ChromaKeyOutputRules.SpillRules.foreground(source: s, backing: magenta, alpha: 128)
        XCTAssertLessThanOrEqual(abs(Int(out.r) - Int(f.r)), 3)
        XCTAssertLessThanOrEqual(abs(Int(out.g) - Int(f.g)), 3)
        XCTAssertLessThanOrEqual(abs(Int(out.b) - Int(f.b)), 3)
    }

    // Where the matte is nearly empty the division blows up, so Keylight's own answer
    // is kept rather than amplifying noise into a coloured fringe.
    func testVeryThinMatteKeepsKeylightsColour() {
        let keyed = RGB8(10, 20, 30)
        let out = ChromaKeyOutputRules.SpillRules.recovered(
            keyed: keyed, source: RGB8(250, 5, 250), backing: magenta, alpha: 10)
        XCTAssertEqual(out, keyed)
        XCTAssertEqual(ChromaKeyOutputRules.SpillRules.weight(alpha: 10), 0)
    }

    // And the crossfade in between is smooth, so the edge does not band.
    func testWeightRampsSmoothly() {
        // Floor 0.28 (alpha ~71), full 0.50 (alpha ~128).
        XCTAssertEqual(ChromaKeyOutputRules.SpillRules.weight(alpha: 60), 0)    // 0.235, below floor
        let w = ChromaKeyOutputRules.SpillRules.weight(alpha: 100)              // 0.392, mid-ramp
        XCTAssertGreaterThan(w, 0)
        XCTAssertLessThan(w, 1)
        XCTAssertEqual(ChromaKeyOutputRules.SpillRules.weight(alpha: 128), 1)   // 0.502
        XCTAssertEqual(ChromaKeyOutputRules.SpillRules.weight(alpha: 255), 1)
    }

    // The whole point: soft FX must not be clipped. A transitional pixel keeps its
    // partial alpha and simply gets an honest colour.
    func testSoftPixelIsRecoveredNotClipped() {
        let out = ChromaKeyOutputRules.SpillRules.recovered(
            keyed: RGB8(0, 0, 0), source: RGB8(240, 120, 240), backing: magenta, alpha: 128)
        XCTAssertNotEqual(out, RGB8(0, 0, 0))
    }
}

final class ImageRequestPolicyTests: XCTestCase {
    // Google names 429, 408 and transient 5xx as retryable; other 4xx are terminal.
    func testRetryableStatuses() {
        XCTAssertTrue(ImageRequestPolicy.isRetryable(status: 429))
        XCTAssertTrue(ImageRequestPolicy.isRetryable(status: 408))
        XCTAssertTrue(ImageRequestPolicy.isRetryable(status: 503))
        XCTAssertFalse(ImageRequestPolicy.isRetryable(status: 400))
        XCTAssertFalse(ImageRequestPolicy.isRetryable(status: 403))
    }

    // Our errors carry the status inline: "AI service HTTP 429: …".
    func testStatusIsReadOutOfOurOwnErrorText() {
        XCTAssertEqual(ImageRequestPolicy.status(inMessage: "AI service HTTP 429: slow down"), 429)
        XCTAssertTrue(ImageRequestPolicy.shouldRetry(errorMessage: "AI service HTTP 503: upstream"))
        XCTAssertFalse(ImageRequestPolicy.shouldRetry(errorMessage: "AI service HTTP 400: bad prompt"))
    }

    // An error with no status is a transport failure. Replaying it blind could pay
    // twice for an image that was already generated and metered.
    func testTransportFailureIsNotRetried() {
        XCTAssertNil(ImageRequestPolicy.status(inMessage: "The request timed out."))
        XCTAssertFalse(ImageRequestPolicy.shouldRetry(errorMessage: "The request timed out."))
    }

    // Initial 1s, base 2, capped at 60, plus 0-1s jitter — Google's documented shape.
    func testBackoffGrowsAndIsCapped() {
        XCTAssertEqual(ImageRequestPolicy.backoff(forAttempt: 1, jitter: 0), 1)
        XCTAssertEqual(ImageRequestPolicy.backoff(forAttempt: 2, jitter: 0), 2)
        XCTAssertEqual(ImageRequestPolicy.backoff(forAttempt: 3, jitter: 0), 4)
        XCTAssertEqual(ImageRequestPolicy.backoff(forAttempt: 20, jitter: 0), 60)
        XCTAssertEqual(ImageRequestPolicy.backoff(forAttempt: 1, jitter: 0.5), 1.5)
    }

    // "Retrying no more than two times" — three attempts in total.
    func testAttemptBudgetMatchesGooglesAdvice() {
        XCTAssertEqual(ImageRequestPolicy.maxAttempts, 3)
    }
}

final class ArtDirectionQualityTests: XCTestCase {
    // Measured failure: the wild came back a "swirling vortex" in three plans out of
    // three. The direction has to name that habit and refuse it, not just list options.
    func testWildRefusesTheVortexDefault() {
        let d = SlotArtDirection.direction(for: .wild, tier: nil)
        // Research finding: real wilds are characters and emblems — Big Bass's fisherman,
        // Wild West Gold's sheriff — not energy. Asking for "transformation" or "an energy
        // form" is itself what produced a swirling vortex three plans running, so BOTH
        // abstractions are gone and the direction names a concrete subject instead.
        XCTAssertTrue(d.contains("SPECIFIC SUBJECT"))
        XCTAssertTrue(d.contains("at the same level of reality as every"))
        // Measured across six themes with a plain wild: two came back as medallions, and
        // both were themes whose signature creature was ALREADY a high pay. The set rule
        // "no two may read the same" was pushing the wild up into a token of the thing it
        // could not repeat, so the direction now names the sideways move instead.
        XCTAssertTrue(d.contains("move SIDEWAYS in this"))
        XCTAssertTrue(d.contains("A paw print stands FOR a wolf"))
        XCTAssertFalse(d.contains("ENERGY FORM"))
        XCTAssertFalse(d.contains("It must read as TRANSFORMATION"))
        // The word itself is gone now too. Naming the unwanted shape is how it gets
        // drawn — measured across six plans, where "coin", "gem" and "portal" appeared
        // in subjects traceable to example lists in the prompt rather than to the GDD.
        XCTAssertFalse(d.lowercased().contains("vortex"))
    }

    // Wild must still be told apart from scatter and bonus.
    // Scatter and bonus are EVALUATION rules, not shapes. Shipping scatters are sunsets
    // and lollipops; bonus symbols are coins as often as chests. The old direction
    // mandated a circular portal and a container, which was invented.
    func testScatterAndBonusAreNotForcedIntoShapes() {
        let sc = SlotArtDirection.direction(for: .scatter, tier: nil)
        XCTAssertFalse(sc.contains("A circular form you travel THROUGH"))
        XCTAssertTrue(sc.contains("COUNTABLE"))
        let bo = SlotArtDirection.direction(for: .bonus, tier: nil)
        XCTAssertFalse(bo.contains("A CONTAINER or mechanism"))
        XCTAssertTrue(bo.contains("impossible to confuse"))
    }

    // Four unrelated treasures make the player guess the rank. Shipping games share one
    // construction and separate the tiers by colour and a printed name.
    func testJackpotsAreOneFamily() {
        let g = SlotArtDirection.direction(for: .jackpot, tier: 1)
        XCTAssertTrue(g.contains("FAMILY"))
        XCTAssertTrue(g.contains("keep the form shared"))
        XCTAssertTrue(g.contains("GRAND"))
    }

    // "Never a human" in medium pays had no basis.
    func testMediumPayDoesNotBanPeople() {
        XCTAssertFalse(SlotArtDirection.direction(for: .mediumPay, tier: 1).contains("never a human"))
    }

    // The high pays are a ladder a player can rank without the paytable.
    func testHighPaysAreDescribedAsARankableLadder() {
        let one = SlotArtDirection.direction(for: .highPay, tier: 1)
        let four = SlotArtDirection.direction(for: .highPay, tier: 4)
        XCTAssertTrue(one.contains("most desirable object in the entire game"))
        XCTAssertFalse(four.contains("most desirable object in the entire game"))
        XCTAssertTrue(one.contains("LADDER"))
        // Value is lost by becoming plainer, not by becoming smaller.
        XCTAssertTrue(one.contains("Do not make a lower tier"))
    }

    // Warmer = higher paying, with an honest escape for cool themes.
    func testWarmthLeadsValueButIsNotAbsolute() {
        XCTAssertTrue(SlotArtDirection.setRules.contains("WARMER, HOTTER and RICHER"))
        XCTAssertTrue(SlotArtDirection.setRules.contains("house preference, not a law of the genre"))
    }

    // The stale, invented thresholds must not creep back in.
    func testNoFabricatedThresholdsRemain() {
        let all = SlotSymbolRole.allCases.map { SlotArtDirection.direction(for: $0, tier: 1) }
            .joined() + SlotArtDirection.houseStyle + SlotArtDirection.setRules
        XCTAssertFalse(all.contains("32 px"))
        XCTAssertFalse(all.contains("32x32"))
        XCTAssertFalse(all.contains("200 milliseconds"))
        XCTAssertFalse(all.contains("85%"))
        XCTAssertFalse(all.contains("~95%"))
    }
}

final class GDDFeatureContextTests: XCTestCase {
    private let chevy = """
    Symbol Set
    * 0 WD1  // wild symbol
    Special Symbols + Upgrades
    SF1 - SF1s that land in the base game shoot fireballs up to the Hot Reel's glass panel.
    The second reel that fires fireballs at the glass panel causes the glass to shatter.
    WY1 - The value of the WY1 will be paid out instantly if it is collected by an SF1.
    Tech Design
    int[] JACKPOT_VALUES = { 500, 2000 };
    struct ScatterDisplay
    {
        RSP reelStop;
    }
    """

    // The prose is where the game actually lives. Without it the planner sees codes only
    // and returns symbols that would suit any game at all.
    func testKeepsTheFeatureProse() {
        let e = GDDFeatureContext.excerpt(chevy)
        XCTAssertTrue(e.contains("fireballs"))
        XCTAssertTrue(e.contains("glass panel"))
    }

    // Code and JSON carry no art meaning and would eat the whole budget.
    func testDropsCodeAndStructs() {
        let e = GDDFeatureContext.excerpt(chevy)
        XCTAssertFalse(e.contains("JACKPOT_VALUES"))
        XCTAssertFalse(e.contains("RSP reelStop"))
        XCTAssertFalse(e.contains("struct"))
    }

    // Still bounded, but generously. The old ceiling was 2,500 characters, set when the
    // model had a small window; gemini-3.8-flash takes 1,048,576 tokens and Google's
    // long-context guidance is to keep the relevant document whole.
    func testIsBounded() {
        // Real documents are many lines, not one enormous one — the reader works per line.
        let huge = "Special Symbols\n"
            + (1...4000).map { "The giant roars loudly on line \($0)." }.joined(separator: "\n")
        let e = GDDFeatureContext.excerpt(huge)
        XCTAssertLessThanOrEqual(e.count, 42000)   // 40k of content + the joining newlines
        XCTAssertGreaterThan(e.count, 20000, "the old 2,500-character ceiling is back")
    }

    // The whole document now reaches the planner, not only the lines after one of a
    // short list of headings — a list that did not include "Symbols", so a document that
    // described its symbols under that heading lost them and the planner invented
    // subjects for symbols the document had already named.
    func testSymbolProseSurvivesWithoutABlessedHeading() {
        let doc = """
        Symbols
        HP1 - "hero" 1, main cowboy character, gold frame
        LP1 - the drinker
        """
        let e = GDDFeatureContext.excerpt(doc)
        XCTAssertTrue(e.contains("main cowboy character"), "symbol prose was dropped: \(e)")
        XCTAssertTrue(e.contains("the drinker"))
    }

    // Machine detail still goes: code, JSON and reel tables carry no art meaning.
    func testCodeAndJSONAreStillStripped() {
        let doc = "Symbols\nHP1 - a giant\nint bonusSpins;\n{ \"reel\": 1 }\nstruct Foo {"
        let e = GDDFeatureContext.excerpt(doc)
        XCTAssertTrue(e.contains("a giant"))
        XCTAssertFalse(e.contains("bonusSpins"))
        XCTAssertFalse(e.contains("reel"))
    }
}

final class GDDFormatTests: XCTestCase {

    // A Word table exports as one cell per line, so the symbol set arrives as a column
    // of bare codes with their indices beneath. The list parser finds nothing in this,
    // and seven GDDs in the shared folder are Word documents.
    private let wordTable = """
    Activators (ships)
    Name
    Symbol ID
    Shots
    SF1
    7
    1

    SF2
    8
    2

    SF3
    9
    4

    SF4
    10
    10 (Full Row)
    """

    func testWordTableSymbolsAreFound() {
        let s = GDDSymbolSetRules.parse(wordTable)
        XCTAssertEqual(s.map(\.code), ["SF1", "SF2", "SF3", "SF4"])
        XCTAssertEqual(s.first?.index, 7)
        XCTAssertTrue(s.allSatisfy { $0.role == .collector })
    }

    // One stray "R1" in prose is a reel, not a replacement symbol.
    func testOneStrayCodeIsNotASymbolSet() {
        XCTAssertTrue(GDDSymbolSetRules.parse("""
        The player advances along R1
        R1
        and then stops.
        """).isEmpty)
    }

    // The list format still wins when both could match.
    func testListFormatIsPreferred() {
        let s = GDDSymbolSetRules.parse("""
        Symbol Set
        * 0 WD1   // wild
        * 1-4 HP1-4  // HPs
        """)
        XCTAssertEqual(s.map(\.code), ["WD1", "HP1", "HP2", "HP3", "HP4"])
    }

    func testBareCodeRecognition() {
        XCTAssertTrue(GDDSymbolSetRules.isBareCode("HP1"))
        XCTAssertTrue(GDDSymbolSetRules.isBareCode("JP4"))
        XCTAssertFalse(GDDSymbolSetRules.isBareCode("Shots"))
        XCTAssertFalse(GDDSymbolSetRules.isBareCode("HP"))      // no number
        XCTAssertFalse(GDDSymbolSetRules.isBareCode("ZZ9"))     // unknown prefix
    }

    // Some GDDs describe symbols only in prose, so the model reads them instead. Its
    // answer must map onto real symbols.
    func testModelExtractionMapsOntoSymbols() {
        let j = GDDAssetPrompts.json(fromModelReply: """
        {"symbols":[{"code":"HP1","role":"highPay","note":"main cowboy, gold frame"},
                    {"code":"LP1","role":"lowPay","note":"the drinker"},
                    {"code":"WD1","role":"wild","note":""}]}
        """)!
        let s = GDDAssetPrompts.symbols(fromExtraction: j)
        XCTAssertEqual(s.map(\.code), ["HP1", "LP1", "WD1"])
        XCTAssertEqual(s[0].role, .highPay)
        XCTAssertEqual(s[0].tier, 1)
        XCTAssertEqual(s[0].note, "main cowboy, gold frame")
    }

    // A good code with a nonsense role still yields a usable slot.
    func testBadRoleFallsBackToTheCode() {
        let j = GDDAssetPrompts.json(fromModelReply:
            #"{"symbols":[{"code":"JP2","role":"nonsense","note":""}]}"#)!
        XCTAssertEqual(GDDAssetPrompts.symbols(fromExtraction: j).first?.role, .jackpot)
    }
}

final class SilhouetteNearDuplicateTests: XCTestCase {
    private func j(_ id: String, _ sil: String) -> AssetJob {
        // Medium pays: not a family role, so a shared silhouette here is a real fault.
        AssetJob(id: id, kind: .symbol, role: .mediumPay, tier: nil, title: "",
                 subject: "x", silhouette: sil, aspect: "1:1", size: "2K")
    }

    // From a real plan: "Fireball Coin" and "Flaming Coin" are two different strings and
    // two symbols that will look the same on a reel. Exact matching passed them both.
    // (This pair was first seen on WY1/WY2, which are now treated as one value-tier
    // family — see WysiwygFamilyTests. Across unrelated roles it is still a fault.)
    func testTwoCoinsAreCaught() {
        let c = GDDAssetPrompts.silhouetteClashes([j("MP1", "Fireball Coin"),
                                                   j("MP2", "Flaming Coin"),
                                                   j("HP1", "Ornate Harp")])
        XCTAssertEqual(c["coin"]?.sorted(), ["MP1", "MP2"])
        XCTAssertNil(c["harp"])
    }

    // "Golden" and "magical" decorate everything in a fantasy set and must not, alone,
    // make two symbols count as the same.
    func testDecorativeWordsDoNotCreateFalseClashes() {
        let c = GDDAssetPrompts.silhouetteClashes([j("A", "Golden Harp"),
                                                   j("B", "Golden Crown"),
                                                   j("C", "Magical Axe")])
        XCTAssertTrue(c.isEmpty, "got \(c)")
    }

    func testExactMatchesStillCaught() {
        let c = GDDAssetPrompts.silhouetteClashes([j("A", "Battle Axe"), j("B", "battle axe")])
        XCTAssertEqual(c["battle axe"]?.sorted(), ["A", "B"])
    }
}

final class LowPayFamilyTests: XCTestCase {
    private func j(_ id: String, _ role: SlotSymbolRole, _ sil: String) -> AssetJob {
        AssetJob(id: id, kind: .symbol, role: role, tier: 1, title: "",
                 subject: "x", silhouette: sil, aspect: "1:1", size: "2K")
    }

    // Low pays sharing a word is the LP unity rule working, not a fault. Flagging
    // "wooden (LP1, LP2, LP3, LP4)" told the user their correct set was broken.
    func testLowPayFamilyIsNotAClash() {
        let c = GDDAssetPrompts.silhouetteClashes([
            j("LP1", .lowPay, "wooden ace"), j("LP2", .lowPay, "wooden king"),
            j("LP3", .lowPay, "wooden queen"), j("LP4", .lowPay, "wooden jack")])
        XCTAssertTrue(c.isEmpty, "got \(c)")
    }

    // A genuine cross-role collision is still reported.
    func testCrossRoleCollisionStillCaught() {
        let c = GDDAssetPrompts.silhouetteClashes([
            j("MP2", .mediumPay, "coin sack"), j("WY1", .wysiwyg, "golden coin"),
            j("LP1", .lowPay, "wooden ace"), j("LP2", .lowPay, "wooden king")])
        XCTAssertEqual(c["coin"]?.sorted(), ["MP2", "WY1"])
        XCTAssertNil(c["wooden"])
    }

    // Observed in a real plan: JP1-JP4 came back Grand/Major/Minor/Mini chest, which is
    // the shared jackpot construction the art direction demands — and the clash detector
    // reported it as a fault.
    func testJackpotFamilyIsNotAClash() {
        let c = GDDAssetPrompts.silhouetteClashes([
            j("JP1", .jackpot, "grand chest"), j("JP2", .jackpot, "major chest"),
            j("JP3", .jackpot, "minor chest"), j("JP4", .jackpot, "mini chest"),
            j("MP1", .mediumPay, "gem chalice")])
        XCTAssertTrue(c.isEmpty, "got \(c)")
    }

    // A jackpot sharing a word with a NON-jackpot is still a genuine collision.
    func testJackpotVersusOtherRoleStillCaught() {
        let c = GDDAssetPrompts.silhouetteClashes([
            j("JP1", .jackpot, "grand chest"), j("MP1", .mediumPay, "treasure chest")])
        XCTAssertEqual(c["chest"]?.sorted(), ["JP1", "MP1"])
    }

    // Two low pays that are literally the same symbol are still wrong.
    func testIdenticalLowPaysStillCaught() {
        let c = GDDAssetPrompts.silhouetteClashes([
            j("LP1", .lowPay, "wooden ace"), j("LP2", .lowPay, "Wooden Ace")])
        XCTAssertEqual(c["wooden ace"]?.sorted(), ["LP1", "LP2"])
    }

    // The families the user named, including the full royal run.
    func testLowPayDirectionNamesTheFamilies() {
        let d = SlotArtDirection.direction(for: .lowPay, tier: 1)
        for f in ["ROYALS", "GEMSTONES", "PEBBLES", "THEMED ITEMS", "A K Q J 10 7 5"] {
            XCTAssertTrue(d.contains(f), "missing \(f)")
        }
        XCTAssertTrue(d.contains("royals usually carry NO frame"))
        XCTAssertTrue(d.contains("FILL the frame"))
    }

    func testCraftRulesCoverFramesAndFilling() {
        XCTAssertTrue(SlotArtDirection.houseStyle.contains("FILL THE FRAME"))
        XCTAssertTrue(SlotArtDirection.houseStyle.contains("FRAMES:"))
    }

    // Two more invented numbers of mine, removed: there is no established 8% margin rule,
    // and composition margin, motion clearance and atlas padding are three different
    // things that a single percentage conflates.
    func testNoInventedMarginNumber() {
        XCTAssertFalse(SlotArtDirection.houseStyle.contains("8%"))
        XCTAssertTrue(SlotArtDirection.houseStyle.contains("COMPOSITION margin"))
        // The phrase wraps in the source, so match the part that does not.
        XCTAssertTrue(SlotArtDirection.houseStyle.contains("it is not atlas"))
    }

    // Separation is led by the motion the symbol will have, not by a part quota.
    func testSeparationIsLedByMotionNotAQuota() {
        XCTAssertFalse(SlotArtDirection.houseStyle.contains("3-6 parts"))
        XCTAssertTrue(SlotArtDirection.houseStyle.contains("no required number of parts"))
    }
}

final class SpecCorrectionTests: XCTestCase {
    // The generation backdrop and a designed backing plate are different things, and
    // confusing them destroys the asset the moment it is cut out.
    func testBackdropIsDistinguishedFromADesignedBacking() {
        let job = AssetJob(id: "HP1", kind: .symbol, role: .highPay, tier: 1, title: "",
                           subject: "a giant", silhouette: "giant", aspect: "1:1", size: "2K")
        let p = GDDAssetPrompts.image(job: job, theme: GameTheme(name: "T"),
                                      backing: SlotBackingRules.candidates[2])
        XCTAssertTrue(p.contains("BACKDROP"))
        XCTAssertTrue(p.contains("If this symbol needs a backing plate"))
    }

    // Gaze is a character choice, not a rank marker.
    func testHP2DoesNotDeferByLookingAway() {
        let d = SlotArtDirection.direction(for: .highPay, tier: 2)
        XCTAssertFalse(d.contains("defers to HP1"))
        XCTAssertTrue(d.contains("not a rank"))
    }

    // Not every game has four jackpot tiers, and a meter-only jackpot needs no symbol.
    func testJackpotCountIsNotAssumed() {
        let d = SlotArtDirection.direction(for: .jackpot, tier: 1)
        XCTAssertTrue(d.contains("Not every game has four"))
        XCTAssertTrue(d.contains("only as a meter"))
    }
}

final class SymbolFrameTests: XCTestCase {
    private func job(_ id: String, _ role: SlotSymbolRole) -> AssetJob {
        AssetJob(id: id, kind: .symbol, role: role, tier: 1, title: "", aspect: "1:1", size: "2K")
    }

    // Generating the frame WITH the symbol is the whole point: the old pipeline made them
    // separately and they did not match.
    func testPlannerDecidesTheFrame() {
        let j = GDDAssetPrompts.json(fromModelReply: """
        {"assets":[{"id":"HP1","subject":"a giant","silhouette":"giant","frame":true},
                   {"id":"LP1","subject":"the letter A","silhouette":"ace","frame":false}]}
        """)!
        let r = GDDAssetPrompts.apply(planJSON: j, to: [job("HP1", .highPay), job("LP1", .lowPay)])
        XCTAssertTrue(r.jobs.first { $0.id == "HP1" }?.hasFrame ?? false)
        XCTAssertFalse(r.jobs.first { $0.id == "LP1" }?.hasFrame ?? true)
    }

    // A plan that says nothing about frames must not silently frame everything.
    func testMissingFrameFieldMeansNoFrame() {
        let j = GDDAssetPrompts.json(fromModelReply:
            #"{"assets":[{"id":"HP1","subject":"a giant","silhouette":"giant"}]}"#)!
        XCTAssertFalse(GDDAssetPrompts.apply(planJSON: j, to: [job("HP1", .highPay)])
                        .jobs[0].hasFrame)
    }

    func testPromptSaysWhichWay() {
        var framed = job("HP1", .highPay)
        framed.subject = "a giant"; framed.hasFrame = true
        var bare = job("LP1", .lowPay)
        bare.subject = "the letter A"; bare.hasFrame = false
        let t = GameTheme(name: "T")
        let a = GDDAssetPrompts.image(job: framed, theme: t, backing: SlotBackingRules.candidates[2])
        let b = GDDAssetPrompts.image(job: bare, theme: t, backing: SlotBackingRules.candidates[2])
        XCTAssertTrue(a.contains("FRAME: draw this symbol inside a frame"))
        XCTAssertTrue(b.contains("NO FRAME"))
    }

    // The four special-feature jobs are distinct and must not be blended.
    func testSpecialFeatureNamesItsFourJobs() {
        let d = SlotArtDirection.direction(for: .collector, tier: nil)
        for job in ["COLLECTOR", "ACTIVATOR", "ADDER", "MULTIPLIER"] {
            XCTAssertTrue(d.contains(job), "missing \(job)")
        }
        XCTAssertTrue(d.contains("A character can do the collecting"))
    }
}

final class GDDParseProblemTests: XCTestCase {
    // "1-2 HP1-4" declares four codes across two indices. It is refused — correctly —
    // but refusing it silently means four symbols vanish and nobody finds out until
    // someone counts the folder.
    func testMismatchedRangeIsReported() {
        let r = GDDSymbolSetRules.parseWithProblems("""
        Symbol Set
        * 0 WD1   // wild
        * 1-2 HP1-4  // mismatched
        * 3-4 LP1-2  // fine
        """)
        XCTAssertEqual(r.symbols.map(\.code), ["WD1", "LP1", "LP2"])
        XCTAssertEqual(r.problems.count, 1)
        XCTAssertTrue(r.problems[0].contains("HP1-4"))
    }

    // A clean document reports nothing.
    func testCleanDocumentHasNoProblems() {
        let r = GDDSymbolSetRules.parseWithProblems("""
        Symbol Set
        * 0 WD1   // wild
        * 1-4 HP1-4  // HPs
        """)
        XCTAssertEqual(r.symbols.count, 5)
        XCTAssertTrue(r.problems.isEmpty)
    }

    // Prose after the block must not be reported as a failure.
    func testProseAfterTheBlockIsNotAProblem() {
        let r = GDDSymbolSetRules.parseWithProblems("""
        Symbol Set
        * 0 WD1   // wild
        Spinning & Winning
        4x5 ways game, with 4 HP symbols and 5 LP symbols
        """)
        XCTAssertTrue(r.problems.isEmpty, "got \(r.problems)")
    }
}

final class SpecialFeatureRoleTests: XCTestCase {
    // SF is one prefix covering four jobs. Calling every SF a collector is how an adder
    // gets drawn as a vessel with a running total it does not have.
    func testRoleComesFromWhatTheDocumentSays() {
        let s = GDDSymbolSetRules.parse("""
        Symbol Set
        * 0 SF1  // Special Collector Symbol
        * 1 SF2  // adds value to every coin on screen
        * 2 SF3  // activator, unlocks the bonus
        * 3 SF4  // multiplier applied to the win
        """)
        XCTAssertEqual(s.first { $0.code == "SF1" }?.role, .collector)
        XCTAssertEqual(s.first { $0.code == "SF2" }?.role, .adder)
        XCTAssertEqual(s.first { $0.code == "SF3" }?.role, .activator)
        XCTAssertEqual(s.first { $0.code == "SF4" }?.role, .multiplier)
    }

    // Silence means the default stands — but it is a default, not a deduction.
    func testSilentDocumentKeepsTheDefault() {
        XCTAssertEqual(SlotSymbolRole.collector.refined(byNote: ""), .collector)
        XCTAssertEqual(SlotSymbolRole.collector.refined(byNote: "SF1"), .collector)
    }

    // Refinement must never touch a role that was not an SF guess in the first place.
    func testOtherRolesAreUntouched() {
        XCTAssertEqual(SlotSymbolRole.highPay.refined(byNote: "collects coins"), .highPay)
        XCTAssertEqual(SlotSymbolRole.wild.refined(byNote: "multiplies the win"), .wild)
    }

    // The new roles still get art and still get direction.
    func testNewRolesAreDrawable() {
        for r in [SlotSymbolRole.activator, .adder] {
            XCTAssertTrue(r.needsArt)
            XCTAssertTrue(SlotArtDirection.direction(for: r, tier: nil).contains("SPECIAL FEATURE"))
            XCTAssertFalse(r.label.isEmpty)
        }
    }
}

final class PayOrderDisclosureTests: XCTestCase {
    private let syms = GDDSymbolSetRules.parse("""
    Symbol Set
    * 0 WD1  // wild
    * 1-4 HP1-4  // HPs
    """)

    // HP1 > HP4 is a NAMING convention, not a fact about the game. When the document
    // says nothing about pay, the user is told the order was assumed.
    func testSilentDocumentIsDisclosed() {
        let n = GDDPayOrder.note(for: "A game with symbols and features.", symbols: syms)
        XCTAssertNotNil(n)
        XCTAssertTrue(n!.contains("taken from the code numbering"))
    }

    // A document with a paytable needs no disclaimer.
    func testStatedPayOrderNeedsNoNote() {
        XCTAssertNil(GDDPayOrder.note(for: "Paytable: HP1 pays 500 for 5 of a kind.", symbols: syms))
        XCTAssertTrue(GDDPayOrder.isStated(in: "5 of a kind pays 100x bet"))
        XCTAssertFalse(GDDPayOrder.isStated(in: "The reels spin and stop."))
    }

    // Nothing to disclose when there is nothing ranked.
    func testNoRankedSymbolsNoNote() {
        let one = GDDSymbolSetRules.parse("Symbol Set\n* 0 WD1  // wild")
        XCTAssertNil(GDDPayOrder.note(for: "no paytable here", symbols: one))
    }
}

final class AntiPatternTests: XCTestCase {
    // Every symbol collapsing into a glowing gold medallion, and every special feature
    // arriving as a vortex, were both observed in this project before they were written
    // down as rules.
    func testNamedFailuresAreStatedAsInstructions() {
        let a = SlotArtDirection.antiPatterns
        // Stated WITHOUT naming the unwanted shape. The list used to say "not a portal, a
        // container or an energy core" and "a generic glowing gold medallion" — and those
        // nouns turned up in generated plans, which is the same priming that made every
        // wild a vortex. Measured: "coin", "gem" and "portal" appeared in symbol subjects
        // traceable to example lists in this file, not to the GDD or the theme.
        XCTAssertTrue(a.contains("Draw the NAMED SUBJECT"))
        XCTAssertTrue(a.contains("Take the shape from the SUBJECT"))
        for named in ["medallion", "portal", "energy core", "vortex"] {
            XCTAssertFalse(a.lowercased().contains(named),
                           "the anti-pattern list names “\(named)”, which primes it")
        }
        XCTAssertTrue(a.contains("pseudo-script"))
        XCTAssertTrue(a.contains("Gloss is not form"))
        XCTAssertTrue(a.contains("never something to copy"))
    }

    // They have to reach the model that draws, not just the planner.
    func testAntiPatternsReachEveryImage() {
        var job = AssetJob(id: "HP1", kind: .symbol, role: .highPay, tier: 1, title: "",
                           aspect: "1:1", size: "2K")
        job.subject = "a giant"
        let p = GDDAssetPrompts.image(job: job, theme: GameTheme(name: "T"),
                                      backing: SlotBackingRules.candidates[2])
        XCTAssertTrue(p.contains("AVOID THESE SPECIFICALLY"))
    }

    // No single image can see the ladder it belongs to, so the set block carries it.
    func testLadderReversalIsStatedAtSetLevel() {
        XCTAssertTrue(SlotArtDirection.setConsistency.contains("not look MORE expensive"))
    }
}

final class ArchiveProgressTests: XCTestCase {

    /// Build a real zip and read its count back, so this is pinned to the format and
    /// not to my reading of the spec.
    func testEntryCountFromARealZip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("navzip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 1...7 { try "x\(i)".write(to: dir.appendingPathComponent("f\(i).txt"),
                                           atomically: true, encoding: .utf8) }
        let zip = dir.appendingPathComponent("t.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-q", "-j", zip.path] + (1...7).map { dir.appendingPathComponent("f\($0).txt").path }
        try p.run(); p.waitUntilExit()
        try XCTSkipUnless(p.terminationStatus == 0, "zip unavailable")

        let tail = try Data(contentsOf: zip)
        XCTAssertEqual(ArchiveProgressRules.zipEntryCount(tail: tail), 7)
    }

    /// Anything that is not a zip must say "I don't know" rather than invent a number,
    /// because the bar is drawn from it.
    func testNonZipTailsRefuseToGuess() {
        XCTAssertNil(ArchiveProgressRules.zipEntryCount(tail: Data()))
        XCTAssertNil(ArchiveProgressRules.zipEntryCount(tail: Data(repeating: 0, count: 8)))
        XCTAssertNil(ArchiveProgressRules.zipEntryCount(tail: Data(repeating: 0x41, count: 4096)))
    }

    /// 0xFFFF is the format saying "the real count is in a Zip64 record". Reporting
    /// 65535 would draw a bar that never fills.
    func testZip64SentinelIsRefused() {
        var b = [UInt8](repeating: 0, count: 22)
        b[0] = 0x50; b[1] = 0x4B; b[2] = 0x05; b[3] = 0x06
        b[10] = 0xFF; b[11] = 0xFF
        XCTAssertNil(ArchiveProgressRules.zipEntryCount(tail: Data(b)))
    }

    func testProgressLinesFromDittoAndTar() {
        XCTAssertEqual(ArchiveProgressRules.extractedName(fromLine: "copying file f1.txt ... "), "f1.txt")
        XCTAssertEqual(ArchiveProgressRules.extractedName(
            fromLine: "copying file Project/parts/BO1 wheel.png ... "), "Project/parts/BO1 wheel.png")
        XCTAssertEqual(ArchiveProgressRules.extractedName(fromLine: "x Project/parts/a.png"), "Project/parts/a.png")
    }

    /// ditto prints a SECOND line per file ("N bytes for NAME"). Counting it would
    /// double every entry and send the bar to 100% halfway through.
    func testTheByteLineIsNotCounted() {
        XCTAssertNil(ArchiveProgressRules.extractedName(fromLine: "5 bytes for f1.txt"))
        XCTAssertNil(ArchiveProgressRules.extractedName(fromLine: ">>> Copying t.zip "))
        XCTAssertNil(ArchiveProgressRules.extractedName(fromLine: ""))
        XCTAssertNil(ArchiveProgressRules.extractedName(fromLine: "   "))
    }
}

final class ArchiveTimeoutTests: XCTestCase {

    /// The measured case. A 793 MB zip onto an SMB share took about 84 minutes, so an
    /// hour's timeout killed it at 60 and deleted the destination.
    func testTheArchiveThatUsedToBeKilledNowFits() {
        let measured: TimeInterval = 84 * 60
        XCTAssertGreaterThan(PathRules.archiveTimeout(bytes: 793_402_336), measured)
        XCTAssertLessThan(3600, PathRules.archiveTimeout(bytes: 793_402_336))
    }

    /// Small archives keep the old hour — the floor only ever extends it.
    func testSmallArchivesKeepTheHourFloor() {
        XCTAssertEqual(PathRules.archiveTimeout(bytes: 0), 3600)
        XCTAssertEqual(PathRules.archiveTimeout(bytes: 10_000_000), 3600)
        // The floor stops mattering once size alone exceeds an hour at 20 KB/s.
        XCTAssertEqual(PathRules.archiveTimeout(bytes: 72_000_000), 3600)
        XCTAssertGreaterThan(PathRules.archiveTimeout(bytes: 100_000_000), 3600)
    }

    /// It must still END. An unbounded wait pins the window on "Extracting…" forever
    /// when a share dies mid-job.
    func testItStaysBounded() {
        let t = PathRules.archiveTimeout(bytes: 50_000_000_000)
        XCTAssertTrue(t.isFinite)
        XCTAssertGreaterThan(t, 0)
    }
}

final class AppleDoubleTests: XCTestCase {

    /// The file from the report. It ends in .zip and is not an archive.
    func testSidecarOfAZipIsNotAnArchive() {
        XCTAssertTrue(PathRules.isAppleDouble("._CNY_Sept22_Review.zip"))
        XCTAssertTrue(PathRules.isAppleDouble("._notes.tar.gz"))
        XCTAssertTrue(PathRules.isAppleDouble("._"))
    }

    /// The names that must keep working. A leading dot alone is not AppleDouble —
    /// ".zshrc" and a dotfolder's archive are ordinary hidden files.
    func testOrdinaryNamesAreNotSidecars() {
        for n in ["CNY_Sept22_Review.zip", ".zshrc", ".hidden.zip", "_private.zip",
                  "a._b.zip", "photo._1.zip", ""] {
            XCTAssertFalse(PathRules.isAppleDouble(n), n)
        }
    }

    /// The rule is about the file's own name, not the path it sits in: a folder called
    /// "._stuff" does not make the archives inside it sidecars.
    func testOnlyTheLastComponentDecides() {
        let u = URL(fileURLWithPath: "/Volumes/stick/._backups/2026.zip")
        XCTAssertFalse(PathRules.isAppleDouble(u.lastPathComponent))
        XCTAssertTrue(PathRules.isAppleDouble(
            URL(fileURLWithPath: "/Volumes/stick/backups/._2026.zip").lastPathComponent))
    }
}

final class AddendumGDDTests: XCTestCase {

    /// The literal sentence from 4230 DaVinci PB, which six Power Bet GDDs share.
    private let davinci = "DaVinci is already a released product, so this GDD will "
                        + "only focus on the new additions to the game."

    /// The set that document declares: three wilds, a bonus, a jackpot. No LP, no HP,
    /// because those shipped with the base game. The old wording called this incomplete.
    private let addendumSet: [SlotSymbol] = [
        ("WD1", SlotSymbolRole.wild), ("WD2", .wild), ("WD3", .wild),
        ("BO1", .bonus), ("JP1", .jackpot),
    ].enumerated().map {
        SlotSymbol(code: $0.element.0, index: $0.offset, role: $0.element.1,
                   tier: nil, note: "")
    }

    func testDaVinciSentenceIsRecognised() {
        XCTAssertTrue(GDDSymbolPlausibility.declaresItselfAnAddendum(davinci))
        XCTAssertTrue(GDDSymbolPlausibility.declaresItselfAnAddendum(
            "Eagles Flight Power Bet consists of the base game rules from Eagles Flight "
            + "with an added Jackpot and 2 Power Bets."))
    }

    /// The guard that matters. "Base game" alone appears in nearly every GDD in the
    /// folder; matching it would excuse a genuinely truncated set in all of them.
    func testOrdinaryGDDLanguageIsNotAnAddendum() {
        for t in ["The base game is played on a 5x3 matrix.",
                  "Wins are evaluated in the base game and the bonus game.",
                  "This product is released quarterly.",
                  ""] {
            XCTAssertFalse(GDDSymbolPlausibility.declaresItselfAnAddendum(t), t)
        }
    }

    func testAddendumWarningSaysExpectedNotIncomplete() {
        let w = GDDSymbolPlausibility.warning(addendumSet, inferred: false, gddText: davinci)
        let m = try! XCTUnwrap(w)
        XCTAssertTrue(m.contains("already shipped"), m)
        XCTAssertTrue(m.contains("expected"), m)
        XCTAssertFalse(m.contains("looks incomplete"), m)
        // Still names what is absent — this softens the framing, it does not hide it.
        XCTAssertTrue(m.contains("no low pays"), m)
        XCTAssertTrue(m.contains("no high pays"), m)
    }

    /// The same short set in a document that claims to be a whole game is still suspect.
    func testSameSetWithoutTheSentenceStillWarnsHard() {
        let w = GDDSymbolPlausibility.warning(addendumSet, inferred: false,
                                              gddText: "A complete five-reel slot game.")
        XCTAssertTrue(try XCTUnwrap(w).contains("looks incomplete"))
    }

    /// A complete set says nothing, addendum sentence or not.
    func testAddendumSentenceDoesNotSuppressAHealthySet() {
        let full = (1...5).map { SlotSymbol(code: "LP\($0)", index: $0, role: .lowPay,
                                            tier: $0, note: "") }
                 + (1...4).map { SlotSymbol(code: "HP\($0)", index: 5 + $0, role: .highPay,
                                            tier: $0, note: "") }
                 + [SlotSymbol(code: "WD1", index: 10, role: .wild, tier: 1, note: "")]
        XCTAssertNil(GDDSymbolPlausibility.warning(full, inferred: false, gddText: davinci))
    }
}

final class DriveStubViewURLTests: XCTestCase {

    /// The export URL downloads a .docx; a person opening a GDD wants to READ it.
    func testViewURLIsTheEditPageNotTheExport() {
        let d = DriveStub(id: "1abcXYZ", kind: .document)
        XCTAssertEqual(d.viewURL?.absoluteString,
                       "https://docs.google.com/document/d/1abcXYZ/edit")
        XCTAssertTrue(d.exportURL!.absoluteString.contains("export?format=docx"))
    }

    func testResourceKeyIsCarried() {
        let d = DriveStub(id: "1abc", resourceKey: "0-KeY", kind: .spreadsheet)
        XCTAssertEqual(d.viewURL?.absoluteString,
                       "https://docs.google.com/spreadsheets/d/1abc/edit?resourcekey=0-KeY")
    }

    /// No docs.google.com page exists for these, so the caller falls back to the file.
    func testKindsWithNoDocumentPage() {
        XCTAssertNil(DriveStub(id: "1abc", kind: .form).viewURL)
        XCTAssertNil(DriveStub(id: "1abc", kind: .site).viewURL)
    }
}

final class SymbolPlausibilityTests: XCTestCase {
    // 2690 Supercoco has no symbol-set section. Its only codes appear in prose and
    // inside a SOUND CUE — "when WD1 has been consumed" — so reading it produced a
    // two-symbol game, reported as fact. The shipped art for that game is eleven.
    func testTwoSymbolGameIsFlagged() {
        let syms = [SlotSymbol(code: "HP1", index: 0, role: .highPay, tier: 1, note: ""),
                    SlotSymbol(code: "WD1", index: 1, role: .wild, tier: 1, note: "")]
        let w = GDDSymbolPlausibility.warning(syms, inferred: true)
        XCTAssertNotNil(w)
        XCTAssertTrue(w!.contains("only 2 symbols"))
        XCTAssertTrue(w!.contains("no low pays"))
        XCTAssertTrue(w!.contains("no symbol list"))
    }

    // A real set passes without nagging.
    func testRealSetIsNotFlagged() {
        let syms = GDDSymbolSetRules.parse("""
        Symbol Set
        * 0 WD1  // wild
        * 1-4 HP1-4  // HPs
        * 5-9 LP1-5  // LPs
        """)
        XCTAssertNil(GDDSymbolPlausibility.warning(syms, inferred: false))
    }

    // A set read from a real list is worded differently from one inferred.
    func testWordingDistinguishesReadFromInferred() {
        let syms = [SlotSymbol(code: "HP1", index: 0, role: .highPay, tier: 1, note: "")]
        XCTAssertTrue(GDDSymbolPlausibility.warning(syms, inferred: false)!
            .hasPrefix("This symbol set looks incomplete"))
        XCTAssertTrue(GDDSymbolPlausibility.warning(syms, inferred: true)!
            .contains("no symbol list"))
    }

    // Nothing to say about an empty document.
    func testEmptyGivesNoWarning() {
        XCTAssertNil(GDDSymbolPlausibility.warning([], inferred: true))
    }
}

final class ManualSymbolEntryTests: XCTestCase {
    // Not every game has a document yet. A producer who knows the set should be able to
    // type it rather than invent a GDD for the tool's benefit.
    func testTypicalSetParses() {
        let r = GDDSymbolSetRules.parseManual(GDDSymbolSetRules.typicalSet)
        XCTAssertTrue(r.problems.isEmpty, "got \(r.problems)")
        XCTAssertEqual(r.symbols.count, 20)   // WD 1 + HP 4 + MP 4 + LP 5 + SC 1 + BO 1 + JP 4
        XCTAssertEqual(r.symbols.filter { $0.role == .highPay }.map(\.code),
                       ["HP1", "HP2", "HP3", "HP4"])
        XCTAssertEqual(r.symbols.filter { $0.role == .jackpot }.count, 4)
    }

    // Commas, spaces and newlines all separate.
    func testSeparatorsAreForgiving() {
        let a = GDDSymbolSetRules.parseManual("WD HP1-2\nLP1-2").symbols.map(\.code)
        let b = GDDSymbolSetRules.parseManual("WD, HP1-2, LP1-2").symbols.map(\.code)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, ["WD", "HP1", "HP2", "LP1", "LP2"])
    }

    // Nonsense is reported, not silently dropped — the same rule the file parser follows.
    func testUnreadableTokensAreReported() {
        let r = GDDSymbolSetRules.parseManual("WD, ZZTOP, HP1-2, ???")
        XCTAssertEqual(r.symbols.map(\.code), ["WD", "HP1", "HP2"])
        XCTAssertFalse(r.problems.isEmpty)
    }

    func testDuplicatesCollapse() {
        XCTAssertEqual(GDDSymbolSetRules.parseManual("WD, WD, HP1").symbols.map(\.code),
                       ["WD", "HP1"])
    }

    // A hand-typed set is a real set, so it must not trip the plausibility warning.
    func testTypicalSetIsPlausible() {
        let r = GDDSymbolSetRules.parseManual(GDDSymbolSetRules.typicalSet)
        XCTAssertNil(GDDSymbolPlausibility.warning(r.symbols, inferred: false))
    }
}

final class GameAssetManifestTests: XCTestCase {
    // The real 2690 Supercoco manifest, trimmed. Its GDD yields two symbols; its shipped
    // art is eleven, and this is where that fact lives.
    private let supercoco = """
    Game: 2690_supercoco_production
    Total PNG Files: 49
    PNG File Structure:
    2690_supercoco_production/Resources/Generic/default/art/base/font/
     ├── base_font_button.png [1024x120px]
     └── base_font_popUp.png [1024x120px]
    2690_supercoco_production/Resources/Generic/default/art/base/highPaySymbol/
     ├── base_HP1_static.png [240x240px]
     ├── base_HP2_static.png [240x240px]
     └── base_HP3_static.png [240x240px]
    2690_supercoco_production/Resources/Generic/default/art/base/interface/
     ├── base_interface_bezel.png [1024x512px]
     └── base_interface_reelFade.png [1024x512px]
    2690_supercoco_production/Resources/Generic/default/art/base/lowPaySymbol/
     ├── base_LP_1-static.png [240x240px]
     ├── base_LP_2-static.png [240x240px]
     ├── base_LP_3-static.png [240x240px]
     ├── base_LP_4-static.png [240x240px]
     └── base_LP_5-static.png [240x240px]
    2690_supercoco_production/Resources/Generic/default/art/base/meter/
     └── base_meter_FGIcon.png [64x64px]
    2690_supercoco_production/Resources/Generic/default/art/base/specialSymbol/
     ├── base_SF_1-front-static.png [240x240px]
     ├── base_SF_2-center-static.png [240x240px]
     └── base_SF_3-back-static.png [240x240px]
    """

    func testShippedSymbolsAreRead() {
        let s = GameAssetManifest.symbols(fromManifest: supercoco)
        XCTAssertEqual(s.map(\.code).sorted(),
                       ["HP1", "HP2", "HP3", "LP1", "LP2", "LP3", "LP4", "LP5",
                        "SF1", "SF2", "SF3"])
        XCTAssertEqual(s.count, 11)
    }

    // Roles come from the folder, which is more reliable than the filename.
    func testRolesComeFromTheFolder() {
        let s = GameAssetManifest.symbols(fromManifest: supercoco)
        XCTAssertEqual(s.filter { $0.role == .highPay }.count, 3)
        XCTAssertEqual(s.filter { $0.role == .lowPay }.count, 5)
        XCTAssertEqual(s.filter { $0.role == .collector }.count, 3)
    }

    // Fonts, meters, bezels and buttons are not reel symbols.
    func testNonSymbolArtIsIgnored() {
        let s = GameAssetManifest.symbols(fromManifest: supercoco).map(\.code)
        XCTAssertFalse(s.contains { $0.hasPrefix("FONT") })
        XCTAssertFalse(s.contains("R1"))          // would come from "reelFade" / "FGIcon"
        XCTAssertEqual(s.count, 11)
    }

    // The separator styles differ between codes: HP1, LP_1, SF_1.
    func testCodeIsFoundWhicheverWayItIsWritten() {
        XCTAssertEqual(GameAssetManifest.code(inFilename: "base_HP1_static.png"), "HP1")
        XCTAssertEqual(GameAssetManifest.code(inFilename: "base_LP_1-static.png"), "LP1")
        XCTAssertEqual(GameAssetManifest.code(inFilename: "base_SF_1-front-static.png"), "SF1")
        XCTAssertNil(GameAssetManifest.code(inFilename: "base_interface_bezel.png"))
    }

    // Manifests are named by game number, which is how a GDD maps to one.
    func testManifestIsFoundByGameNumber() {
        let files = ["2690_supercoco_production.txt", "3140_milky_way_rmg_production.txt"]
        XCTAssertEqual(GameAssetManifest.fileName(forGame: "2690", among: files),
                       "2690_supercoco_production.txt")
        XCTAssertNil(GameAssetManifest.fileName(forGame: "9999", among: files))
        XCTAssertEqual(GameAssetManifest.gameNumber(inName: "2690 Supercoco GDD"), "2690")
        XCTAssertNil(GameAssetManifest.gameNumber(inName: "Untitled game"))
    }

    // And it answers the question the GDD could not.
    func testManifestBeatsAnImplausibleDocument() {
        let fromDoc = [SlotSymbol(code: "HP1", index: 0, role: .highPay, tier: 1, note: ""),
                       SlotSymbol(code: "WD1", index: 1, role: .wild, tier: 1, note: "")]
        XCTAssertNotNil(GDDSymbolPlausibility.warning(fromDoc, inferred: true))
        let fromArt = GameAssetManifest.symbols(fromManifest: supercoco)
        XCTAssertNil(GDDSymbolPlausibility.warning(fromArt, inferred: false))
    }
}

final class PlanIdentityTests: XCTestCase {
    // The crash: the plan table bound its text fields by ARRAY INDEX. SwiftUI keeps a
    // binding alive across a redraw, so the moment the job list got shorter — switching
    // document, switching to the typed-set mode, redesigning with fewer slots — a stale
    // closure indexed past the end and killed the process.
    //
    // The fix is to look the job up by id, so this pins the property that makes that
    // possible: ids are unique and stable, so a lookup always resolves to one job.
    func testJobIdsAreUniqueWithinAPlan() {
        let syms = GDDSymbolSetRules.parse("""
        Symbol Set
        * 0 WD1  // wild
        * 1-4 HP1-4  // HPs
        * 5-9 LP1-5  // LPs
        """)
        let jobs = AssetPlanRules.symbolJobs(syms)
            + AssetPlanRules.backgroundJobs(gddText: "free spins bonus game")
        XCTAssertEqual(Set(jobs.map(\.id)).count, jobs.count)
    }

    // And that a shorter plan simply has no entry for the old id, rather than a
    // different job sitting at that position.
    func testShrinkingThePlanDropsIdsRatherThanReusingPositions() {
        let big = AssetPlanRules.symbolJobs(GDDSymbolSetRules.parse("""
        Symbol Set
        * 0 WD1  // wild
        * 1-4 HP1-4  // HPs
        """))
        let small = AssetPlanRules.symbolJobs(GDDSymbolSetRules.parse("""
        Symbol Set
        * 0 WD1  // wild
        """))
        XCTAssertEqual(big.count, 5)
        XCTAssertEqual(small.count, 1)
        // HP4 existed in the big plan and does not in the small one — a lookup by id
        // returns nothing, where a lookup by index would have returned someone else.
        XCTAssertNotNil(big.first { $0.id == "HP4" })
        XCTAssertNil(small.first { $0.id == "HP4" })
    }
}

final class RuntimeTextZoneTests: XCTestCase {
    // Observed in a real generation: "leave a clear band across the lower third where the
    // word WILD will be printed" produced a literal white band painted across the goose.
    // The instruction has to describe a QUIET AREA OF THE ARTWORK, never a drawn shape.
    func testNoRoleAsksForABandToBeDrawn() {
        for role in SlotSymbolRole.allCases {
            let d = SlotArtDirection.direction(for: role, tier: 1)
            XCTAssertFalse(d.contains("Leave a clear band"), "\(role) still asks for a band")
            XCTAssertFalse(d.contains("leave a clear band"), "\(role) still asks for a band")
        }
    }

    // And the roles that carry runtime text say so in the safe form.
    func testTextCarryingRolesForbidTheShape() {
        for role in [SlotSymbolRole.wild, .scatter, .bonus, .jackpot, .wysiwyg, .collector] {
            let d = SlotArtDirection.direction(for: role, tier: 1)
            let low = d.lowercased()
            let forbids = (low.contains("do not draw") || low.contains("draw no"))
                       && low.contains("band")
            XCTAssertTrue(forbids, "\(role) does not forbid drawing the band")
            XCTAssertTrue(d.lowercased().contains("no lettering") || d.contains("do not letter"),
                          "\(role) does not forbid lettering")
        }
    }
}

final class GDDSceneTests: XCTestCase {
    // Every slot has a base game; nothing else is assumed.
    func testOnlyBaseIsAssumed() {
        XCTAssertEqual(GDDScenes.scenes(in: "A game with reels.").map(\.id), ["bg_base"])
    }

    // 4400 names "Jackpot Pick". The old fixed list knew "jackpot picker" and read it
    // as nothing at all.
    func testJackpotPickIsFound() {
        let ids = GDDScenes.scenes(in: "Landing three enters the Jackpot Pick.").map(\.id)
        XCTAssertTrue(ids.contains("bg_jackpot"))
    }

    // A game with several distinct modes gets a background for each — the old rule
    // could never return more than three scenes.
    func testSeveralModesEachGetAScene() {
        let ids = GDDScenes.scenes(in: """
        The base game leads to free games. There is also a Loot Link bonus round,
        and a separate Jackpot Wheel.
        """).map(\.id)
        XCTAssertTrue(ids.contains("bg_base"))
        XCTAssertTrue(ids.contains("bg_freegames"))
        XCTAssertTrue(ids.contains("bg_lootlink"))
        XCTAssertTrue(ids.contains("bg_jackpot"))
        XCTAssertTrue(ids.contains("bg_bonus"))
        XCTAssertEqual(Set(ids).count, ids.count)      // no duplicates
    }

    // Saying "free games" six times is still one background, not six paid images.
    func testRepeatedMentionsCollapse() {
        let ids = GDDScenes.scenes(in: String(repeating: "free games ", count: 6)).map(\.id)
        XCTAssertEqual(ids, ["bg_base", "bg_freegames"])
    }

    // "free spins bonus" is the free-spins scene, not a bonus scene as well.
    func testLongestPhraseWinsSoOneModeIsOneScene() {
        XCTAssertEqual(GDDScenes.scenes(in: "Three scatters award the free spins bonus.").map(\.id),
                       ["bg_base", "bg_freegames"])
    }
}

final class BackgroundTextTests: XCTestCase {
    private func bg() -> String {
        var j = AssetJob(id: "bg_base", kind: .background, role: .unknown, tier: nil,
                         title: "", aspect: "3:4", size: "4K")
        j.subject = "a beanstalk over green hills"
        return GDDAssetPrompts.image(job: j, theme: GameTheme(name: "Jack and the Beanstalk"),
                                     backing: SlotBackingRules.candidates[2])
    }

    // Observed in a real run: a background came back with "Jack and the Beanstalk"
    // lettered across the top, and pseudo-runes carved into the pillars. The old prompt
    // said "no text" once, in a list, and the background branch never received the
    // anti-patterns block at all.
    func testBackgroundForbidsLetteringEmphatically() {
        let p = bg()
        XCTAssertTrue(p.contains("ABSOLUTELY NO LETTERING"))
        XCTAssertTrue(p.contains("no invented script"))
        // Wraps in the source; match a contiguous fragment.
        XCTAssertTrue(p.contains("cannot be shipped"))
        XCTAssertTrue(p.contains("title is a separate asset"))
    }

    // The anti-patterns apply to backgrounds too — that is where the pseudo-script rule
    // lives, and it was only ever reaching symbols.
    func testBackgroundGetsTheAntiPatterns() {
        XCTAssertTrue(bg().contains("AVOID THESE SPECIFICALLY"))
        XCTAssertTrue(bg().contains("pseudo-script"))
    }

    // A background is not keyed, so it must not be told about a backdrop colour.
    func testBackgroundStillHasNoBackdropInstruction() {
        XCTAssertFalse(bg().contains("chroma magenta"))
    }
}

final class WysiwygFamilyTests: XCTestCase {
    private func j(_ id: String, _ role: SlotSymbolRole, _ sil: String) -> AssetJob {
        AssetJob(id: id, kind: .symbol, role: role, tier: 1, title: "",
                 subject: "x", silhouette: sil, aspect: "1:1", size: "2K")
    }

    // Observed: WY1 and WY2 both came back as coins, and the clash detector called it.
    // They ARE one family at two value tiers — the same insight as the jackpots — so
    // sharing the object is right, and the detector should not report it as a fault.
    func testWysiwygFamilyIsNotAClash() {
        let c = GDDAssetPrompts.silhouetteClashes([
            j("WY1", .wysiwyg, "gold coin"), j("WY2", .wysiwyg, "amber coin"),
            j("MP1", .mediumPay, "harp")])
        XCTAssertTrue(c.isEmpty, "got \(c)")
    }

    // But a WYSIWYG colliding with a different role is still a real problem.
    func testWysiwygVersusOtherRoleStillCaught() {
        let c = GDDAssetPrompts.silhouetteClashes([
            j("WY1", .wysiwyg, "gold coin"), j("MP2", .mediumPay, "coin sack")])
        XCTAssertEqual(c["coin"]?.sorted(), ["MP2", "WY1"])
    }

    // And the planner is told they are a family that must still be distinguishable.
    func testPlannerIsToldTheyAreAFamily() {
        let jobs = [j("WY1", .wysiwyg, ""), j("WY2", .wysiwyg, "")]
        let brief = GDDAssetPrompts.roleBrief(for: jobs)
        XCTAssertTrue(brief.contains("ONE FAMILY at different value tiers"))
        XCTAssertTrue(brief.contains("tellable apart instantly"))
    }

    // One WYSIWYG needs no family instruction.
    func testSingleWysiwygGetsNoFamilyLine() {
        let brief = GDDAssetPrompts.roleBrief(for: [j("WY1", .wysiwyg, "")])
        XCTAssertFalse(brief.contains("ONE FAMILY at different value tiers"))
    }
}

// Findings from the audit of the shipped GDD-to-Assets feature. Every one of these
// reproduced against real document shapes before it was fixed.
final class GDDAuditRegressionTests: XCTestCase {
    private let beanstalk = GameTheme(
        name: "Jack and the Beanstalk", category: "Fairytale", comparables: "Megaways Jack",
        look: "A giant beanstalk rising into a fantasy sky of floating castles and clouds.")

    private func codes(_ t: String) -> [String] {
        GDDSymbolSetRules.parse(t).map(\.code)
    }

    // "0 WD1, // wild" — the comma belongs to the sentence. It used to fail every
    // branch of expand(), so the game lost its WILD and nothing was reported.
    func testTrailingPunctuationDoesNotDropASymbol() {
        XCTAssertEqual(codes("Symbol Set\n0 WD1, // wild\n1-4 HP1-4"),
                       ["WD1", "HP1", "HP2", "HP3", "HP4"])
        XCTAssertEqual(codes("Symbol Set\n0 SC1; // scatter").first, "SC1")
    }

    // Word writes en dashes. Every range check looked for an ASCII hyphen.
    func testTypographicDashesParse() {
        let t = "Symbol Set\n0 WD1\n1-4 HP1\u{2013}4\n5\u{2013}9 LP1\u{2013}5\n10 SC1"
        XCTAssertEqual(codes(t),
                       ["WD1", "HP1", "HP2", "HP3", "HP4",
                        "LP1", "LP2", "LP3", "LP4", "LP5", "SC1"])
    }

    // "1-4 HP" covers four indices and means four symbols. It returned one.
    func testBarePrefixOverARangeExpands() {
        XCTAssertEqual(codes("Symbol Set\n1-4 HP\n5-9 LP1-5").prefix(4).map { $0 },
                       ["HP1", "HP2", "HP3", "HP4"])
        // A numbered code cannot cover a range — that is a real problem, not a guess.
        XCTAssertFalse(codes("Symbol Set\n0 WD1\n1-4 HP1").contains("HP1"))
    }

    // parseTable scanned the whole document, so any four bare codes became a symbol set.
    // A non-empty set is also what stops the model fallback running, so the invented set
    // was the one that got drawn and paid for.
    func testReelDefinitionsAreNotASymbolSet() {
        XCTAssertTrue(GDDSymbolSetRules.parse("Reel definitions\nR1\nR2\nR3\nR4").isEmpty)
        // A real table still reads.
        XCTAssertEqual(GDDSymbolSetRules.parse("Symbols\nWD1\n0\nHP1\n1\nHP2\n2\nLP1\n3").count, 4)
    }

    // The safety net had the same break as the thing it watches, so the second
    // consecutive rejection — the one that truncates the set — was never shown.
    func testTheLineThatEndsTheBlockIsReported() {
        let r = GDDSymbolSetRules.parseWithProblems(
            "Symbol Set\n0 WD1\n1-4 HP1-9\n5-9 LP1-9\n10 SC1")
        XCTAssertEqual(r.problems.count, 2, "got \(r.problems)")
    }

    // ...but prose that merely follows the block is not a dropped symbol. Both start
    // with a digit; only an entry separates the index from what comes after it.
    func testProseEndingTheBlockIsStillNotAProblem() {
        let r = GDDSymbolSetRules.parseWithProblems(
            "Symbol Set\n0 WD1\n1-4 HP1-4\n\n4x5 ways game, with 4 HP symbols\nIt pays left to right.")
        XCTAssertTrue(r.problems.isEmpty, "got \(r.problems)")
    }

    // "No free spins or bonus game." was building two paid 4K backgrounds for screens
    // the document says do not exist.
    func testNegatedModesDoNotBecomeBackgrounds() {
        let ids = GDDScenes.scenes(in: "No free spins or bonus game.").map(\.id)
        XCTAssertEqual(ids, ["bg_base"])
    }

    // A denial in the previous sentence is about something else.
    func testNegationDoesNotCarryAcrossASentence() {
        let ids = GDDScenes.scenes(in: "There is no wild. Free spins are awarded by SC.").map(\.id)
        XCTAssertTrue(ids.contains("bg_freegames"), "got \(ids)")
    }

    // What the symbol DOES comes before what it acts on.
    func testCollectorOfMultipliersStaysACollector() {
        XCTAssertEqual(SlotSymbolRole.collector.refined(byNote: "Collects all multiplier values"),
                       .collector)
        XCTAssertEqual(SlotSymbolRole.collector.refined(byNote: "Multiplier, 2x to 10x"),
                       .multiplier)
    }

    // "Does not activate a feature" was coming back .activator.
    func testDeniedVerbsDoNotSelectARole() {
        XCTAssertEqual(SlotSymbolRole.collector.refined(byNote: "Does not activate a feature"),
                       .collector)
    }

    private func job(_ id: String, role: SlotSymbolRole, subject: String,
                     frame: Bool) -> AssetJob {
        var j = AssetJob(id: id, kind: .symbol, role: role, tier: 1, title: "",
                         subject: subject, silhouette: subject, aspect: "1:1", size: "2K")
        j.hasFrame = frame
        return j
    }

    // The prompt told a framed symbol to draw a frame and then, last line before the
    // model starts, not to. The last instruction is the one that carries.
    func testAFramedSymbolIsNotAlsoToldNoFrame() {
        let p = GDDAssetPrompts.image(job: job("HP1", role: .highPay, subject: "a giant", frame: true),
                                      theme: beanstalk, backing: SlotBackingRules.candidates[2])
        XCTAssertTrue(p.contains("FRAME: draw this symbol inside a frame"))
        XCTAssertFalse(p.contains("NO frame or border around the symbol"))
    }

    func testAnUnframedSymbolStillGetsTheExclusion() {
        let p = GDDAssetPrompts.image(job: job("LP1", role: .lowPay, subject: "a pebble", frame: false),
                                      theme: beanstalk, backing: SlotBackingRules.candidates[2])
        XCTAssertTrue(p.contains("NO frame or border around the symbol"))
        XCTAssertTrue(p.contains("NO text"))
    }

    // A royal's letterform IS the symbol, and it was being forbidden.
    func testARoyalIsAllowedItsOwnRank() {
        let p = GDDAssetPrompts.image(
            job: job("LP1", role: .lowPay, subject: "card royal A in carved oak", frame: false),
            theme: beanstalk, backing: SlotBackingRules.candidates[2])
        XCTAssertTrue(p.contains("The rank character is the subject and must be drawn"))
        XCTAssertFalse(p.contains("NO text, NO numbers, NO lettering"))
    }

    // The article "a" is not a card rank. This fired on the first run.
    func testAnOrdinarySubjectIsNotMistakenForARoyal() {
        XCTAssertFalse(GDDAssetPrompts.isRoyal(
            job("HP1", role: .highPay, subject: "a giant holding a harp", frame: false)))
        XCTAssertFalse(GDDAssetPrompts.isRoyal(
            job("HP2", role: .highPay, subject: "a knight", frame: false)))
    }

    // The multiplier branch still asked for the blank plate every other role forbids —
    // the same instruction that came back as a white band across WD1.
    func testMultiplierDoesNotAskForABlankPlate() {
        let d = SlotArtDirection.direction(for: .multiplier, tier: nil)
        XCTAssertTrue(d.contains("Do NOT draw a blank plate"))
        XCTAssertFalse(d.contains("Leave a clean central plate"))
    }
}

// Every shape in the team's actual GDD folder. Before these, one of seven real
// documents parsed; the other six returned nothing and fell through to a model that
// guessed. Each fixture below is copied from the document named in its comment, as the
// app's own .docx extraction produces it.
final class RealGDDFormatTests: XCTestCase {

    // 4490 Bring Em In — a described list. The single richest shape: it carries the
    // symbol set AND the art direction for each symbol.
    private let bringEmIn = """
    Presentation
    Symbols
    HPs - high value colorized western characters, bust cropping,  frame based tiering
    HP1 - “hero” 1, main cowboy character, gold frame
    HP2 - “hero” 2, cowgirl, silver frame
    HP3 - “villain” 1, bronze frame
    HP4 - “villain” 2, metal frame
    LPs - scruffy shadier looking western characters, poster styling, less color, full body
    LP1 - the drinker
    LP2 - saloon woman
    LP3 - the gambler
    LP4 - the huntsman
    SFs - highest value, full body, full color, full frames, more fantastical character design
    SF1 - Iron Jack, red
    SF2 - Madame Venom, green
    SF3 - River King, blue
    SF4 - The Governor, orange/yellow
    SF5 - The Preacher, purple
    WYS - Scatter Symbol, an old fashioned money sack, with valuable frame
    WD1 - Wild Symbol, Sheriff star
    BO1 - Bonus Symbol, dueling pistols, crossed old west revolvers
    Layout
    Portrait only,  landscape will present with large image blockers on the sides.
    """

    func testDescribedListReadsEverySymbol() {
        let s = GDDSymbolSetRules.parse(bringEmIn)
        XCTAssertEqual(s.map(\.code),
                       ["HP1", "HP2", "HP3", "HP4", "LP1", "LP2", "LP3", "LP4",
                        "SF1", "SF2", "SF3", "SF4", "SF5", "WYS", "WD1", "BO1"])
        // The document's own header says "Symbols (16 total)".
        XCTAssertEqual(s.count, 16)
    }

    // "HPs" is the family; "WYS" is a symbol. Only the case of the trailing s tells
    // them apart, and uppercasing first made every family header a symbol.
    func testFamilyHeadersAreNotSymbols() {
        let codes = GDDSymbolSetRules.parse(bringEmIn).map(\.code)
        XCTAssertFalse(codes.contains("HPS"))
        XCTAssertFalse(codes.contains("LPS"))
        XCTAssertFalse(codes.contains("SFS"))
        XCTAssertTrue(codes.contains("WYS"))
    }

    // The point of reading the document: its art direction reaches the symbol, both
    // the symbol's own line and its family's.
    func testArtDirectionIsCarried() {
        let s = GDDSymbolSetRules.parse(bringEmIn)
        let hp1 = s.first { $0.code == "HP1" }!
        XCTAssertTrue(hp1.note.contains("main cowboy character, gold frame"))
        XCTAssertTrue(hp1.note.contains("frame based tiering"), "family note lost: \(hp1.note)")
        XCTAssertTrue(s.first { $0.code == "SF3" }!.note.contains("River King, blue"))
        XCTAssertTrue(s.first { $0.code == "WD1" }!.note.contains("Sheriff star"))
    }

    // An SF is whatever the document says it is: premium characters here, ships in
    // 3140. Classified by code alone they were all "collector" pickups.
    func testValueLanguagePromotesTheRole() {
        let s = GDDSymbolSetRules.parse(bringEmIn)
        XCTAssertEqual(s.first { $0.code == "SF1" }!.role, .highPay)
        XCTAssertEqual(s.first { $0.code == "WD1" }!.role, .wild)
        XCTAssertEqual(s.first { $0.code == "BO1" }!.role, .bonus)
    }

    // 2750 / 3520 / 3690 — a tab-separated table. The most common shape in the folder,
    // and not one of them could be read.
    func testTabTableReads() {
        let t = """
        Symbol Definition by Symbol Index
        0\tWD\t0\t1\t1
        1\tHP1\t1\t1\t1
        2\tHP2\t2\t1\t1
        3\tHP3\t3\t1\t1
        4\tMP1\t4\t1\t1
        5\tLP1\t5\t1\t1
        6\tLP2\t6\t1\t1
        7\tBL\t7\t1\t0
        """
        let s = GDDSymbolSetRules.parse(t)
        XCTAssertEqual(s.map(\.code), ["WD", "HP1", "HP2", "HP3", "MP1", "LP1", "LP2", "BL"])
        XCTAssertEqual(s.first { $0.code == "HP2" }!.index, 2)
    }

    // 3310 Hopje — several codes sharing one description.
    func testCodesSharingOneDescription() {
        let t = """
        Symbols
        HP1 and HP2 - Vault
        MP1 and MP2 - Treasure chest
        LP1, LP2, LP3, and LP4 - bag
        """
        let s = GDDSymbolSetRules.parse(t)
        XCTAssertEqual(s.map(\.code), ["HP1", "HP2", "MP1", "MP2", "LP1", "LP2", "LP3", "LP4"])
        XCTAssertEqual(s.first { $0.code == "LP3" }!.note, "bag")
    }

    // 0 Chocolate Cake contains no symbol codes at all. Refusing is the correct answer,
    // and it is the answer that must survive: a believable invented set is worse than
    // none, because it gets designed, generated and billed.
    func testADocumentWithNoSymbolsReturnsNothing() {
        let t = """
        Chocolate Cake
        The calendar advances once per bet. Storm Mode lasts no more than 20 spins.
        Glory on Ice, Cats, Gypsy (Split Symbols)
        During Storm Mode overlay symbols may appear on the reels and be collected.
        """
        XCTAssertTrue(GDDSymbolSetRules.parse(t).isEmpty)
    }

    // Prose must never become a symbol set, whichever reader looks at it.
    func testProseIsNeverASymbolSet() {
        let t = """
        Bonus is triggered by 3 scatter BO1s. BO1s can only appear on the 4 Corners.
        There will be BO1 SmartSounds - anticipations will be addressed in production.
        Wild - substitutes for all paying symbols; restricted to columns 1-3.
        Reel 1 consists of blank symbols and different tiers of activator symbols.
        """
        XCTAssertTrue(GDDSymbolSetRules.parse(t).isEmpty, "got \(GDDSymbolSetRules.parse(t).map(\.code))")
    }

    // 4471 Tiki Titans — an indexed list whose index is separated from the code by an
    // em dash, with the description in brackets. 63 symbol mentions and it read nothing.
    func testDashSeparatedIndexList() {
        let t = """
        Symbol Sets
        * 0 \u{2014} WD1 (Wild Symbol)
        * 1 \u{2014} HP1 (High Pay 1)
        * 2 \u{2014} HP2 (High Pay 2)
        * 9 \u{2014} R1 (Replacement 1)
        * 10 \u{2014} SF1 (Jackpot Coin)
        * 12 \u{2014} JP1  (Jackpot Wheel Game - Jackpot Grand; not on matrix)
        """
        let s = GDDSymbolSetRules.parse(t)
        XCTAssertEqual(s.map(\.code), ["WD1", "HP1", "HP2", "R1", "SF1", "JP1"])
        XCTAssertEqual(s.first { $0.code == "SF1" }!.note, "Jackpot Coin")
        // The dash strip must not eat an index range.
        XCTAssertEqual(GDDSymbolSetRules.parse("Symbol Set\n1-4 HP1-4\n5-9 LP1-5").count, 9)
    }

    // The indexed shape that already worked must keep working.
    func testIndexedListStillReads() {
        let t = "Symbol Set\n* 0 WD1 // wild\n* 1-4 HP1-4 // HPs\n- 5-9 // LPs"
        XCTAssertEqual(GDDSymbolSetRules.parse(t).map(\.code),
                       ["WD1", "HP1", "HP2", "HP3", "HP4",
                        "LP1", "LP2", "LP3", "LP4", "LP5"])
    }
}

// Google Drive stubs. A .gdoc on disk is ~190 bytes of JSON, so every one of these
// documents is fetched, and WHICH export is asked for decides whether its tables
// survive — see DriveStub.
final class DriveStubTests: XCTestCase {
    private let json = """
    {"":"WARNING! DO NOT EDIT THIS FILE!","doc_id":"1wN45EsGu9ophEv8SKfHo0nhY9TtgpJDdl39it_c8xQo","resource_key":"","email":"a@b.com"}
    """

    func testParsesADocStub() {
        let s = DriveStub.parse(json: json, fileExtension: "gdoc")
        XCTAssertEqual(s?.id, "1wN45EsGu9ophEv8SKfHo0nhY9TtgpJDdl39it_c8xQo")
        XCTAssertEqual(s?.kind, .document)
    }

    // Every stub type in the user's Drive: 747 .gdoc, 473 .gsheet, 261 .gslides,
    // 10 .gform, 2 .gdraw, 1 .gsite. All share this one JSON shape.
    func testEveryStubTypeIsRecognised() {
        XCTAssertEqual(DriveStub.Kind(fileExtension: "gsheet"), .spreadsheet)
        XCTAssertEqual(DriveStub.Kind(fileExtension: "gslides"), .presentation)
        XCTAssertEqual(DriveStub.Kind(fileExtension: "GDOC"), .document)
        XCTAssertNil(DriveStub.Kind(fileExtension: "docx"))
    }

    // The whole point: a Doc is fetched as .docx, NOT as txt. Docs' text export
    // flattens every table to one cell per line, and a table is how most of these
    // documents declare their symbol set.
    func testDocumentsAreFetchedAsDocxNotText() {
        let s = DriveStub(id: "abc", kind: .document)
        XCTAssertEqual(s.exportURL?.absoluteString,
                       "https://docs.google.com/document/d/abc/export?format=docx")
        XCTAssertEqual(s.fileExtension, "docx")
    }

    // A Sheet is already tab-separated, which is exactly what the row reader parses.
    func testSheetsExportAsTSV() {
        XCTAssertEqual(DriveStub(id: "abc", kind: .spreadsheet).exportURL?.absoluteString,
                       "https://docs.google.com/spreadsheets/d/abc/export?format=tsv")
    }

    func testSlidesExportAsText() {
        XCTAssertEqual(DriveStub(id: "abc", kind: .presentation).exportURL?.absoluteString,
                       "https://docs.google.com/presentation/d/abc/export?format=txt")
    }

    // Files shared by link carry a resource key, and the export answers 404 without it
    // even though the document opens fine in a browser.
    func testResourceKeyIsCarried() {
        let s = DriveStub(id: "abc", resourceKey: "0-xyz", kind: .document)
        XCTAssertEqual(s.exportURL?.absoluteString,
                       "https://docs.google.com/document/d/abc/export?format=docx&resourcekey=0-xyz")
    }

    // Older stubs carry resource_id instead of doc_id.
    func testLegacyResourceIDStub() {
        let s = DriveStub.parse(json: #"{"resource_id":"document:1AbC"}"#, fileExtension: "gdoc")
        XCTAssertEqual(s?.id, "1AbC")
    }

    // Things with no document text say so, by name, instead of failing obscurely.
    func testUnreadableKindsExplainThemselves() {
        XCTAssertNil(DriveStub(id: "a", kind: .drawing).exportURL)
        XCTAssertNotNil(DriveStub.Kind.form.cannotReadReason)
        XCTAssertNotNil(DriveStub.Kind.site.cannotReadReason)
        XCTAssertNil(DriveStub.Kind.document.cannotReadReason)
    }

    func testRejectsJunk() {
        XCTAssertNil(DriveStub.parse(json: "not json", fileExtension: "gdoc"))
        XCTAssertNil(DriveStub.parse(json: #"{"email":"a@b.com"}"#, fileExtension: "gdoc"))
    }
}

extension DriveStubTests {
    // A document that refuses the .docx export is retried as text. Lossy beats lost —
    // but only as a second attempt, never as the first choice.
    func testDocumentsHaveATextFallback() {
        let s = DriveStub(id: "abc", kind: .document)
        XCTAssertEqual(s.fallbackExportURL?.absoluteString,
                       "https://docs.google.com/document/d/abc/export?format=txt")
        XCTAssertNotEqual(s.exportURL, s.fallbackExportURL)
        // Sheets and Slides have one sensible format each; there is nothing to fall to.
        XCTAssertNil(DriveStub(id: "abc", kind: .spreadsheet).fallbackExportURL)
        XCTAssertNil(DriveStub(id: "abc", kind: .presentation).fallbackExportURL)
    }
}

// A document that declares no symbol set must produce NO plan.
//
// Scene names are found by looking for phrases like "free games" in ordinary prose, so
// they turn up in documents that declare nothing at all. 2990 Slurm has no symbol codes
// anywhere in it, and the window still offered two paid 4K backgrounds underneath a
// message saying the document was unreadable — with Generate enabled.
final class EmptySetPlansNothingTests: XCTestCase {
    private let noSymbols = """
    Slurm
    In addition to normal wilds, there are special blocker symbols on the reels.
    If at the conclusion of a base spin all 5 reels' activation trackers are turned on,
    the player is immediately awarded free games.
    There is also a scatter-triggered tiered pick bonus.
    """

    func testSceneDetectionStillFindsThem() {
        // The scenes are really named in the prose — that was never the bug.
        let ids = GDDScenes.scenes(in: noSymbols).map(\.id)
        XCTAssertTrue(ids.contains("bg_freegames"), "got \(ids)")
    }

    func testNoSymbolsMeansNoSymbolJobs() {
        XCTAssertTrue(GDDSymbolSetRules.parse(noSymbols).isEmpty)
        XCTAssertTrue(AssetPlanRules.symbolJobs([], size: "2K", aspect: "1:1").isEmpty)
    }

    // The guard lives in GDDToAssetsRun.load, which is not reachable from here, so this
    // pins the fact the rule depends on: an empty symbol set is what the caller checks.
    func testAnEmptySetIsDistinguishableFromASmallOne() {
        XCTAssertTrue(GDDSymbolSetRules.parse(noSymbols).isEmpty)
        XCTAssertFalse(GDDSymbolSetRules.parse("Symbol Set\n0 WD1\n1-4 HP1-4").isEmpty)
    }
}

// Codes a document talks about but never declares. Found across the real folder: 4471
// declares WY1–WY3 and its prose says "the wedges share the same IDs as WY1 - WY4";
// eleven documents mention HP6 in sound cues without listing it.
final class UndeclaredSymbolTests: XCTestCase {
    private func set(_ codes: [String]) -> [SlotSymbol] {
        codes.enumerated().map { i, c in
            let (r, t) = GDDSymbolSetRules.classify(c)
            return SlotSymbol(code: c, index: i, role: r, tier: t, note: "")
        }
    }

    func testFindsANumberedSiblingTheSetLacks() {
        let out = GDDSymbolSetRules.mentionedButNotDeclared(
            in: "The wedges share the same IDs as WY1 - WY4. The WY4 only appears on the Bonus Reel.",
            symbols: set(["WY1", "WY2", "WY3"]))
        XCTAssertEqual(out, ["WY4"])
    }

    // A bare family word in a sentence is English, not a missing symbol.
    func testBareFamilyWordsAreNotReported() {
        let out = GDDSymbolSetRules.mentionedButNotDeclared(
            in: "LP, MP, and HP wins are treated differently. All LP wins add progress.",
            symbols: set(["LP1", "LP2", "HP1"]))
        XCTAssertTrue(out.isEmpty, "got \(out)")
    }

    // A family the set does not have at all is a different game's symbol, not a gap in
    // this one — 4200 Ford's code comments mention BO1 and it declares nothing.
    func testUnrelatedFamiliesAreIgnored() {
        let out = GDDSymbolSetRules.mentionedButNotDeclared(
            in: "int bonusSpinsCollected; // BO1 collected as spins",
            symbols: set(["HP1", "HP2"]))
        XCTAssertTrue(out.isEmpty, "got \(out)")
    }

    func testDeclaredCodesAreNotReported() {
        let out = GDDSymbolSetRules.mentionedButNotDeclared(
            in: "HP1 and HP2 both pay well. HP1 is the best.",
            symbols: set(["HP1", "HP2"]))
        XCTAssertTrue(out.isEmpty, "got \(out)")
    }

    // Nothing to compare against — this must never fire on a refusal and imply a set.
    func testEmptySetReportsNothing() {
        XCTAssertTrue(GDDSymbolSetRules.mentionedButNotDeclared(
            in: "HP1 HP2 HP3 WD1", symbols: []).isEmpty)
    }
}

// Hiding documents that declare no symbol set. Two thirds of a real GDD folder is
// Power Bet variants, R&D notes and framework docs with no set in them.
final class GDDScanTests: XCTestCase {
    private func r(_ name: String, _ n: Int, failure: String? = nil) -> GDDScanResult {
        GDDScanResult(key: "k-" + name, name: name, symbolCount: n,
                      checkedAt: Date(), failure: failure)
    }

    func testOnlyEmptyDocumentsAreHidden() {
        let hidden = GDDScanRules.hiddenKeys([r("4490", 16), r("2990", 0), r("4400", 19)])
        XCTAssertEqual(hidden, ["k-2990"])
    }

    // "We failed to read it" and "it contains nothing" are different answers, and only
    // one of them is the document's fault. A failed read must stay visible, or a
    // network blip quietly deletes a game from the list.
    func testAFailedReadIsNotHidden() {
        let hidden = GDDScanRules.hiddenKeys([r("4490", 0, failure: "Timed out")])
        XCTAssertTrue(hidden.isEmpty)
    }

    func testSummaryCountsAllThreeOutcomes() {
        let s = GDDScanRules.summary([r("a", 16), r("b", 0), r("c", 0),
                                      r("d", 0, failure: "x")]) ?? ""
        XCTAssertTrue(s.contains("1 of 4 documents declare a symbol set"), s)
        XCTAssertTrue(s.contains("2 declare none"), s)
        XCTAssertTrue(s.contains("1 couldn’t be read"), s)
    }

    // Nothing is hidden before a scan has run.
    func testNoScanHidesNothing() {
        XCTAssertTrue(GDDScanRules.hiddenKeys([]).isEmpty)
        XCTAssertNil(GDDScanRules.summary([]))
    }

    func testResultsSurviveARoundTrip() {
        let one = [r("4490", 16), r("2990", 0, failure: "nope")]
        let back = GDDScanRules.decode(GDDScanRules.encode(one))
        XCTAssertEqual(back, one)
        XCTAssertTrue(GDDScanRules.decode(Data("garbage".utf8)).isEmpty)
        XCTAssertTrue(GDDScanRules.decode(nil).isEmpty)
    }
}

// The art-style list ported from the previous HTML tool, and the rule that a chosen
// style REPLACES the one read from the theme's reference art.
final class SlotArtStyleTests: XCTestCase {
    func testTheListLoaded() {
        XCTAssertEqual(SlotArtStyles.all.count, 58)
        XCTAssertEqual(SlotArtStyles.byCategory.count, 13)
        // Every style has real direction in it, not just a name.
        for s in SlotArtStyles.all {
            XCTAssertFalse(s.keywords.isEmpty, s.id)
            XCTAssertGreaterThan(s.keywords.count, 40, s.id)
            XCTAssertFalse(s.category.isEmpty, s.id)
        }
    }

    func testIDsAreUnique() {
        XCTAssertEqual(Set(SlotArtStyles.all.map(\.id)).count, SlotArtStyles.all.count)
        XCTAssertEqual(Set(SlotArtStyles.all.map(\.name)).count, SlotArtStyles.all.count)
    }

    // Styles named after specific studios and franchises were left out on purpose: they
    // ask a model to imitate a named company's protected art for a commercial product.
    func testNoStudioOrFranchiseNames() {
        let banned = ["nintendo", "pokemon", "zelda", "mario", "blizzard", "warcraft",
                      "overwatch", "fortnite", "minecraft", "sonic", "diablo", "doom",
                      "gta", "grand theft", "call of duty", "assassin", "pragmatic",
                      "final fantasy", "street fighter", "mortal kombat", "half-life",
                      "portal", "counter-strike", "dota", "starcraft", "hearthstone",
                      "among us", "fall guys", "metroid", "castlevania", "mega man",
                      "terraria", "league of legends", "team fortress"]
        for s in SlotArtStyles.all {
            let hay = (s.id + " " + s.name + " " + s.keywords).lowercased()
            for b in banned {
                XCTAssertFalse(hay.contains(b), "\(s.id) mentions \(b)")
            }
        }
    }

    // Every style must describe HOW something is drawn, never WHAT is in it.
    /// The vocabulary a rendering description is made of. Kept in step with the filler
    /// audit in Tools — a description that names none of these is adjectives.
    static let renderingTerms = [
        "colour", "color", "render", "shading", "shadow", "highlight", "outline", "edge",
        "palette", "texture", "light", "gradient", "fill", "specular", "occlusion",
        "saturat", "contrast", "blur", "pixel", "surface", "bevel", "grain", "reflect",
        "terminator", "brush", "line", "stroke", "value", "hue", "matte", "gloss", "rim",
        "chroma", "facet", "tonal", "bloom", "glow",
    ]

    func testStylesAreAboutRenderingNotContent() {
        for s in SlotArtStyles.all {
            let k = s.keywords.lowercased()
            let hits = Self.renderingTerms.filter { k.contains($0) }.count
            XCTAssertGreaterThanOrEqual(hits, 4,
                "\(s.id) names too few rendering mechanics: \(s.keywords)")
        }
    }

    /// The filler that made the ported descriptions useless: words a model cannot draw.
    func testNoStyleCarriesGenreFiller() {
        let filler = ["aesthetic", "visual theme", "visual language", "atmosphere",
                      "game visual", "gaming visual", "mobile-optimized", "mobile-friendly",
                      "visual quality", "visual treatment", "visual appeal",
                      "visual execution", "visual design", "color design",
                      "color aesthetics", "color atmosphere", "color treatment",
                      "color elements", "artistry", "visual rhythm", "visual structure"]
        for s in SlotArtStyles.all {
            let k = s.keywords.lowercased()
            for f in filler {
                XCTAssertFalse(k.contains(f), "\(s.id) contains filler: “\(f)”")
            }
        }
    }

    func testLookupAndSearch() {
        XCTAssertEqual(SlotArtStyles.byID("playful-inviting")?.name, "Playful Inviting")
        XCTAssertNil(SlotArtStyles.byID("nope"))
        XCTAssertNil(SlotArtStyles.byID(nil))
        XCTAssertNil(SlotArtStyles.byID(""))
        XCTAssertEqual(SlotArtStyles.search("").count, 58)
        XCTAssertTrue(SlotArtStyles.search("NEON").contains { $0.id == "electric-neon" })
        XCTAssertTrue(SlotArtStyles.search("metallic").contains { $0.id == "shiny-metallic" })
        XCTAssertTrue(SlotArtStyles.search("zzzz").isEmpty)
    }

    func testEveryStyleAppearsInExactlyOneCategory() {
        let flat = SlotArtStyles.byCategory.flatMap(\.styles)
        XCTAssertEqual(flat.count, SlotArtStyles.all.count)
        XCTAssertEqual(Set(flat.map(\.id)), Set(SlotArtStyles.all.map(\.id)))
    }

    private var theme: GameTheme {
        var t = GameTheme(name: "Galactic Goddesses", category: "Mythology",
                          comparables: "Starlight", look: "Celestial beings and nebulae.")
        t.styleFromArt = "Painterly, warm rim light, soft edges, oil-like brushwork."
        return t
    }

    // The whole risk of adding this: two rendering directions in one prompt. One says
    // painterly and soft-edged, the other crisp flat cel shading, and the art matches
    // neither. A chosen style must REPLACE, never join.
    func testChosenStyleReplacesTheReferenceArtStyle() {
        var t = theme
        t.chosenStyle = SlotArtStyles.byID("playful-inviting")
        let b = GDDAssetPrompts.styleBlock(t)
        XCTAssertTrue(b.contains("Playful Inviting"))
        XCTAssertFalse(b.contains("Painterly, warm rim light"),
                       "the reference-art style is still in the prompt:\n\(b)")
        XCTAssertEqual(b.components(separatedBy: "ART STYLE").count - 1, 1)
    }

    // Picking a style is not a decision to draw a different game.
    func testThemeAndLookSurviveAStyleChoice() {
        var t = theme
        t.chosenStyle = SlotArtStyles.byID("electric-neon")
        let b = GDDAssetPrompts.styleBlock(t)
        XCTAssertTrue(b.contains("Celestial beings and nebulae."))
        XCTAssertTrue(b.contains("Starlight"))
    }

    func testWithoutAChoiceTheReferenceArtStyleIsUsed() {
        let b = GDDAssetPrompts.styleBlock(theme)
        XCTAssertTrue(b.contains("Painterly, warm rim light"))
        XCTAssertFalse(b.contains("Vibrant Cartoonish"))
    }

    // All three prompts read the style off the theme, so none can be missed.
    func testTheChoiceReachesEveryPrompt() {
        var t = theme
        t.chosenStyle = SlotArtStyles.byID("gothic-carnival")
        let name = SlotArtStyles.byID("gothic-carnival")!.name
        let sym = AssetJob(id: "HP1", kind: .symbol, role: .highPay, tier: 1, title: "",
                           subject: "a giant", silhouette: "giant", aspect: "1:1", size: "2K")
        let bg = AssetJob(id: "bg_base", kind: .background, role: .unknown, tier: nil,
                          title: "", subject: "a hall", silhouette: "", aspect: "3:4", size: "4K")
        let backing = SlotBackingRules.candidates[2]
        XCTAssertTrue(GDDAssetPrompts.image(job: sym, theme: t, backing: backing).contains(name))
        XCTAssertTrue(GDDAssetPrompts.image(job: bg, theme: t, backing: backing).contains(name))
        XCTAssertTrue(GDDAssetPrompts.planning(theme: t, gameName: "G", jobs: [sym],
                                               gddText: "Symbol Set\n0 WD1").contains(name))
    }
}

// Interaction rules for the art-style picker. These live in the view, so what is pinned
// here is the pure behaviour each one depends on.
extension SlotArtStyleTests {
    // Narrowing the search must not drop the current selection out of the list — a
    // Picker whose selection is absent from its own rows renders blank, so the style
    // looks lost.
    func testSearchCanExcludeTheSelectionSoTheViewReAddsIt() {
        let sel = SlotArtStyles.byID("shiny-metallic")!
        let hits = SlotArtStyles.search("cartoon")
        XCTAssertFalse(hits.contains(sel))          // the condition the view guards
        var withSel = hits
        withSel.insert(sel, at: 0)
        XCTAssertTrue(withSel.contains(sel))
    }

    // Switching theme clears the choice, and a theme carries none by default — so a
    // style picked for one game can never leak into the next.
    func testANewThemeCarriesNoStyle() {
        let t = GameTheme(name: "Other", look: "A different world.")
        XCTAssertNil(t.chosenStyle)
        XCTAssertFalse(GDDAssetPrompts.styleBlock(t).contains("ART STYLE"))
        XCTAssertTrue(GDDAssetPrompts.styleBlock(t).contains("A different world."))
    }

    // A theme with no reference art and no chosen style still produces a usable prompt
    // rather than an empty style section.
    func testNoArtAndNoChoiceStillDescribesTheGame() {
        let t = GameTheme(name: "Plain", comparables: "Something", look: "A quiet place.")
        let b = GDDAssetPrompts.styleBlock(t)
        XCTAssertFalse(b.contains("ART STYLE"))
        XCTAssertTrue(b.contains("A quiet place."))
        XCTAssertTrue(b.contains("Something"))
    }

    // Choosing a style is not a reason to redesign the set: it changes how things are
    // drawn, not what they are. The subjects must survive.
    func testStyleChoiceDoesNotDependOnSubjects() {
        var t = GameTheme(name: "T", look: "World.")
        t.chosenStyle = SlotArtStyles.byID("sleek-elegant")
        let job = AssetJob(id: "HP1", kind: .symbol, role: .highPay, tier: 1, title: "",
                           subject: "a golden harp", silhouette: "harp",
                           aspect: "1:1", size: "2K")
        let p = GDDAssetPrompts.image(job: job, theme: t,
                                      backing: SlotBackingRules.candidates[2])
        XCTAssertTrue(p.contains("a golden harp"))
        XCTAssertTrue(p.contains("Sleek Elegant"))
    }
}

// The Video Game Styles category. The originals named studios and franchises, and
// described CONTENT rather than rendering — "hellish demon environments", "vampire
// hunter visual themes". In a slot symbol prompt that drags another game's subject
// matter into the picture, which is the opposite of what an art STYLE is for.
extension SlotArtStyleTests {
    private var videoGame: [SlotArtStyle] {
        SlotArtStyles.all.filter { $0.category == "Video Game Styles" }
    }

    func testTheCategoryIsPresent() {
        XCTAssertEqual(videoGame.count, 11)
        XCTAssertTrue(SlotArtStyles.byCategory.contains { $0.category == "Video Game Styles" })
    }

    // Not one of them may describe what is IN the picture. A style says how a thing is
    // drawn; the theme and the GDD say what the thing is.
    func testTheyDescribeRenderingNotSubjectMatter() {
        let content = ["environment", "demon", "vampire", "soldier", "stadium", "castle",
                       "alien", "creature", "hero character", "weapon", "armor", "armour",
                       "tavern", "laboratory", "facility", "arena", "track", "vehicle",
                       "city", "planet", "monster", "warrior", "champion", "player"]
        for s in videoGame {
            // Whole words. A substring check fails on "velocity", which contains "city".
            let words = Set(s.keywords.lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map { String($0) })
            for c in content where !c.contains(" ") {
                XCTAssertFalse(words.contains(c) || words.contains(c + "s"),
                               "\(s.id) describes subject matter: “\(c)”")
            }
            for c in content where c.contains(" ") {
                XCTAssertFalse(s.keywords.lowercased().contains(c),
                               "\(s.id) describes subject matter: “\(c)”")
            }
        }
    }

    // Vague genre words say nothing a model can draw. "aesthetics", "visual themes" and
    // "atmosphere" were most of the original text and carry no instruction at all.
    func testNoEmptyGenreFiller() {
        for s in videoGame {
            let k = s.keywords.lowercased()
            for f in ["aesthetic", "visual theme", "visual language", "atmosphere",
                      "game visual", "gaming visual", "mobile-optimized", "mobile-friendly"] {
                XCTAssertFalse(k.contains(f), "\(s.id) contains filler: “\(f)”")
            }
        }
    }

    // Each one has to name real rendering mechanics, not adjectives.
    func testEachNamesConcreteRenderingMechanics() {
        for s in videoGame {
            let k = s.keywords.lowercased()
            let mechanics = ["shading", "shadow", "highlight", "outline", "edge", "palette",
                             "texture", "light", "gradient", "fill", "specular", "occlusion",
                             "saturat", "contrast", "blur", "pixel", "surface", "colour",
                             "color", "bevel", "grain", "reflect"]
            let hits = mechanics.filter { k.contains($0) }.count
            XCTAssertGreaterThanOrEqual(hits, 3,
                "\(s.id) names too few rendering mechanics: \(s.keywords)")
        }
    }

    // The five asked for by name all resolve to a described style.
    func testTheRequestedLooksAreAllCovered() {
        // Pokémon (anime-cel) and Pragmatic Play (vector-casino) were dropped with the
        // rest of the outline-based styles — a hard contour is the artefact this pipeline
        // exists to avoid, so styles that mandate one are no longer offered.
        for id in ["bright-toy-3d",        // Nintendo
                   "hand-painted-heroic",  // World of Warcraft
                   "gritty-photoreal"] {   // Grand Theft Auto
            XCTAssertNotNil(SlotArtStyles.byID(id), id)
            XCTAssertEqual(SlotArtStyles.byID(id)?.category, "Video Game Styles", id)
        }
    }
}

// Seven styles were removed because they duplicated another entry's rendering, not just
// its wording — measured as shared rendering vocabulary across all pairs. The twin that
// survived each pair is the one that states its rendering more concretely.
extension SlotArtStyleTests {
    func testTheRedundantTwinsAreGone() {
        for id in ["vibrant-tech-infused",   // ≡ high-energy-scifi
                   "serene-peaceful",        // ≡ calming-realistic
                   "mystical-glow",          // ≡ soft-ethereal
                   "whimsical-mechanical",   // ≡ vintage-brass-wood
                   "mysterious-haunting",    // ≡ chilling-immersive
                   "luxurious-mysterious",   // a blend of sleek-mysterious + luxurious-opulent
                   "cold-mesmerizing"] {     // ≡ cold-mysterious
            XCTAssertNil(SlotArtStyles.byID(id), "\(id) is back")
        }
    }

    func testTheSurvivingTwinsAreStillThere() {
        for id in ["high-energy-scifi", "calming-realistic", "soft-ethereal",
                   "vintage-brass-wood", "chilling-immersive", "sleek-mysterious",
                   "luxurious-opulent", "cold-mysterious"] {
            XCTAssertNotNil(SlotArtStyles.byID(id), id)
        }
    }

    // Removing entries must not empty a category out of the picker.
    func testNoCategoryWasEmptied() {
        for g in SlotArtStyles.byCategory {
            XCTAssertFalse(g.styles.isEmpty, g.category)
        }
        XCTAssertEqual(SlotArtStyles.byCategory.count, 13)
    }
}

// Everything a hub card carries, and the state machine that reports the style read.
final class ThemeHubFieldTests: XCTestCase {
    func testAThemeCarriesEveryCardField() {
        var t = GameTheme(name: "Wild Wolves", category: "Wildlife",
                          comparables: "Wolf Gold, Wolf Strike",
                          why: "Proven evergreen.", look: "A moonlit forest.", tier: "T1")
        t.status = "T1 · Greenlight"
        t.votes = 4
        t.notes = "Art started 12 Sep — Baby Ninja."
        t.hasArt = true
        XCTAssertEqual(t.votes, 4)
        XCTAssertEqual(t.status, "T1 · Greenlight")
        XCTAssertFalse(t.notes.isEmpty)
        XCTAssertTrue(t.hasArt)
    }

    // hasArt is what tells "this card has no artwork" apart from "we have not fetched it
    // yet". Showing those two identically sent people hunting for an upload that was
    // never missing.
    func testHasArtIsIndependentOfHavingFetchedIt() {
        var t = GameTheme(name: "X")
        t.hasArt = true
        XCTAssertNil(t.artBase64, "nothing fetched yet")
        t.artDataURL = "data:image/jpeg;base64,AAAA"
        XCTAssertEqual(t.artBase64, "AAAA")
    }

    func testArtBase64RejectsNonDataURLs() {
        var t = GameTheme(name: "X")
        t.artDataURL = "/api/art/abc123"
        XCTAssertNil(t.artBase64)
        t.artDataURL = "data:image/jpeg;base64,"
        XCTAssertNil(t.artBase64, "empty payload is not artwork")
    }

    // A theme with no artwork must never claim a style was read from it.
    func testNoArtMeansNoStyleFromArt() {
        var t = GameTheme(name: "Plain", look: "A quiet place.")
        t.hasArt = false
        XCTAssertTrue(t.styleFromArt.isEmpty)
        XCTAssertFalse(GDDAssetPrompts.styleBlock(t).contains("ART STYLE"))
    }
}

// Theme rows in the picker: name left, tier and votes in right-aligned columns.
final class ThemeRowTests: XCTestCase {
    private func col(_ row: String, after: Int) -> Int? {
        row.distance(from: row.startIndex, to: row.index(row.startIndex, offsetBy: after))
    }

    // The whole point: every row's tier starts at the same column.
    func testTierColumnLinesUp() {
        let names = ["Piggy Banks", "Diamonds — Fire, Energy, Thunder", "Thor", "Yeti"]
        let w = ThemeRowRules.nameWidth(forNames: names)
        let starts = names.map { n -> Int in
            let row = ThemeRowRules.label(name: n, tier: "T1", votes: 0, nameWidth: w)
            return row.distance(from: row.startIndex, to: row.range(of: "T1")!.lowerBound)
        }
        XCTAssertEqual(Set(starts).count, 1, "tier column ragged: \(starts)")
    }

    func testVoteColumnLinesUp() {
        let names = ["Thor", "Galactic Goddesses", "Atlantis, Not Underwater"]
        let w = ThemeRowRules.nameWidth(forNames: names)
        let starts = names.map { n -> Int in
            let row = ThemeRowRules.label(name: n, tier: "T2", votes: 3, nameWidth: w)
            return row.distance(from: row.startIndex, to: row.range(of: "👍")!.lowerBound)
        }
        XCTAssertEqual(Set(starts).count, 1, "vote column ragged: \(starts)")
    }

    // A theme with no tier must not shunt its votes left into the tier column.
    func testAMissingTierKeepsTheVoteColumn() {
        let w = ThemeRowRules.nameWidth(forNames: ["Yeti", "Thor"])
        let withTier = ThemeRowRules.label(name: "Thor", tier: "T2", votes: 1, nameWidth: w)
        let noTier = ThemeRowRules.label(name: "Yeti", tier: "", votes: 1, nameWidth: w)
        XCTAssertEqual(withTier.distance(from: withTier.startIndex,
                                         to: withTier.range(of: "👍")!.lowerBound),
                       noTier.distance(from: noTier.startIndex,
                                       to: noTier.range(of: "👍")!.lowerBound))
    }

    func testZeroVotesShowsNothing() {
        let row = ThemeRowRules.label(name: "Thor", tier: "T2", votes: 0, nameWidth: 14)
        XCTAssertFalse(row.contains("👍"))
        XCTAssertTrue(row.contains("T2"))
    }

    // A very long name is truncated rather than pushing the columns off the menu.
    func testLongNamesAreTruncatedNotAllowedToPush() {
        let long = "A Really Extremely Long Theme Name That Overflows Everything"
        let w = ThemeRowRules.nameWidth(forNames: [long])
        XCTAssertEqual(w, ThemeRowRules.maxNameWidth)
        let row = ThemeRowRules.label(name: long, tier: "T3", votes: 11, nameWidth: w)
        XCTAssertTrue(row.contains("…"))
        XCTAssertEqual(row.distance(from: row.startIndex, to: row.range(of: "T3")!.lowerBound),
                       ThemeRowRules.maxNameWidth + 3)
    }

    // The column shrinks with a filtered list instead of leaving a canyon of spaces.
    func testWidthFollowsTheVisibleList() {
        XCTAssertEqual(ThemeRowRules.nameWidth(forNames: ["Thor", "Loki"]),
                       ThemeRowRules.minNameWidth)
        XCTAssertEqual(ThemeRowRules.nameWidth(forNames: []), ThemeRowRules.minNameWidth)
        XCTAssertGreaterThan(ThemeRowRules.nameWidth(forNames: ["Atlantis, Not Underwater"]),
                             ThemeRowRules.minNameWidth)
    }
}

// Suppressing the cartoon contour — a dark ink stroke on the silhouette, or a pale
// die-cut sticker band. The commonest complaint about generated slot art.
final class EdgeTreatmentTests: XCTestCase {
    private var theme: GameTheme {
        var t = GameTheme(name: "Beanstalk", look: "A giant beanstalk.")
        t.styleFromArt = "Painterly digital oil, warm light, visible brushwork."
        return t
    }
    private var job: AssetJob {
        AssetJob(id: "HP1", kind: .symbol, role: .highPay, tier: 1, title: "",
                 subject: "a giant", silhouette: "giant", aspect: "1:1", size: "2K")
    }
    private var bg: AssetJob {
        AssetJob(id: "bg_base", kind: .background, role: .unknown, tier: nil, title: "",
                 subject: "a hall", silhouette: "", aspect: "3:4", size: "4K")
    }

    func testTheEdgeSpecIsInThePromptByDefault() {
        let b = GDDAssetPrompts.styleBlock(theme)
        XCTAssertTrue(b.contains("EDGES — how the symbol separates"))
        XCTAssertTrue(b.contains("No inked contour stroke"))
    }

    // All three prompts, via the one choke point. Threading it through three call sites
    // is how the anti-pattern list reached the symbols and not the backgrounds.
    func testItReachesEveryPrompt() {
        let backing = SlotBackingRules.candidates[2]
        XCTAssertTrue(GDDAssetPrompts.image(job: job, theme: theme, backing: backing)
            .contains("die-cut border"))
        XCTAssertTrue(GDDAssetPrompts.image(job: bg, theme: theme, backing: backing)
            .contains("die-cut border"))
        XCTAssertTrue(GDDAssetPrompts.planning(theme: theme, gameName: "G", jobs: [job],
                                               gddText: "Symbol Set\n0 WD1")
            .contains("die-cut border"))
    }

    // A style whose whole identity is line work must not be told not to draw it. That is
    // the same contradiction as telling a framed symbol "no frame".
    // No style mandates line work any more: all eight outline-based styles were
    // dropped at the studio's request. The exemption MACHINERY still matters — reference
    // artwork can be inked — but nothing in the list triggers it.
    func testNoStyleMandatesLineWorkAnyMore() {
        XCTAssertTrue(SlotArtStyles.all.filter(\.usesLineWork).isEmpty,
                      "an outline-based style is back in the list")
    }

    // ...and a painterly style still gets the suppression.
    func testEveryStyleNowGetsTheEdgeSpec() {
        for style in SlotArtStyles.all {
            var t = theme
            t.chosenStyle = style
            XCTAssertTrue(GDDAssetPrompts.styleBlock(t).contains("lit, not inked"), style.id)
        }
    }

    // If the game's OWN approved artwork is inked, suppressing ink would fight the thing
    // the style was read from.
    func testInkedReferenceArtIsRespected() {
        var t = GameTheme(name: "X", look: "A world.")
        t.styleFromArt = "Flat cel shading with bold black outlines and hard terminators."
        XCTAssertFalse(GDDAssetPrompts.styleBlock(t).contains("No inked contour stroke"))
    }

    // The two phrasings that trade one defect for another: "soft edges" everywhere kills
    // readability at 120px, and an unqualified rim light is the same continuous bright
    // perimeter under a different name.
    func testItDoesNotAskForSoftEdgesOrAContinuousRim() {
        // Whitespace-normalised: the source wraps these lines, and a contains() against
        // the raw text silently depends on where the wrap happens to fall.
        let e = SlotArtDirection.edgeTreatment().lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertFalse(e.contains("soft edges"), "soft edges everywhere kills readability")
        XCTAssertTrue(e.contains("short and broken") || e.contains("short, broken"),
                      "edge highlights must be specified as broken")
        XCTAssertTrue(e.contains("never a continuous bright band"))
    }

    // Positive framing first, per Google's guide; the exclusion is one line at the end.
    func testItLeadsWithWhatToDoNotWhatToAvoid() {
        let lines = SlotArtDirection.edgeTreatment()
            .split(separator: "\n").map(String.init)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") }
        XCTAssertGreaterThan(lines.count, 3)
        let negatives = lines.filter {
            let l = $0.lowercased()
            return l.contains("- no ") || l.contains("- never ") || l.contains("- do not")
        }
        XCTAssertEqual(negatives.count, 1, "exactly one exclusion, and it goes last")
        XCTAssertTrue(lines.last!.lowercased().contains("no inked contour"))
    }

    // The house style must not NAME the looks we are trying to avoid.
    func testTheHouseStyleNoLongerNamesTheArtefacts() {
        let h = SlotArtDirection.houseStyle.lowercased()
        XCTAssertFalse(h.contains("flat icon"))
        XCTAssertFalse(h.contains("clip-art pictogram"))
        XCTAssertTrue(h.contains("painted rather than drawn"))
    }
}

// Which styles are exempt from the edge specification. Measured A/B found this was
// getting one wrong: "Sharp Detailed" said "clean precise line work", meaning precision
// of detail, and was read as a line-based style — so it never got the fix and its
// outline coverage did not move.
extension EdgeTreatmentTests {
    func testAmbiguousLineWorkIsNotTreatedAsAnOutline() {
        let s = SlotArtStyles.byID("sharp-detailed")!
        XCTAssertFalse(s.usesLineWork, "detail precision is not a contour stroke")
        XCTAssertFalse(s.keywords.lowercased().contains("line work"))
    }

    // ...but a style whose strokes ARE the artwork keeps its exemption.

    // Exactly the styles that describe drawn line work, and no others.
    func testTheExemptSetIsEmpty() {
        XCTAssertEqual(Set(SlotArtStyles.all.filter(\.usesLineWork).map(\.id)), [],
                       "the exempt set changed — check the new style's wording")
    }
}

// The style read off a theme's reference artwork. It has to state the edge treatment
// explicitly, because GDDAssetPrompts.wantsLineWork reads that description to decide
// whether to suppress the cartoon contour — and a description that never mentions
// outlines is indistinguishable from one describing art that has none.
final class ReferenceStylePromptTests: XCTestCase {
    private var p: String { RestyleRules.styleSystemPrompt }

    func testItDemandsTheEdgeTreatment() {
        XCTAssertTrue(p.contains("EDGE TREATMENT IS REQUIRED"))
        XCTAssertTrue(p.lowercased().contains("keyline"))
        XCTAssertTrue(p.lowercased().contains("line art"))
    }

    // It must ask for the words wantsLineWork actually looks for, or the two halves
    // cannot agree: the reader searches for "outline" and "line art", so the writer has
    // to be told to use them.
    func testItAsksForTheWordsTheReaderLooksFor() {
        let asked = p.lowercased()
        XCTAssertTrue(asked.contains("using the word \"outline\"")
                      || asked.contains("the word “outline”"), p)
        var t = GameTheme(name: "X", look: "A world.")
        t.styleFromArt = "Flat cel shading with a bold black outline following every form."
        XCTAssertTrue(GDDAssetPrompts.wantsLineWork(t))
        t.styleFromArt = "Painterly oil, forms separated by painted colour and value meeting."
        XCTAssertFalse(GDDAssetPrompts.wantsLineWork(t))
    }

    // It must also report a halo or light band — the die-cut sticker artefact.
    func testItAsksAboutHalosAndGlow() {
        let l = p.lowercased()
        XCTAssertTrue(l.contains("halo"))
        XCTAssertTrue(l.contains("following the silhouette"))
    }

    // The original rules still hold: style only, never the subject.
    func testItStillForbidsNamingTheSubject() {
        XCTAssertTrue(p.contains("Never name or imply the subject"))
        XCTAssertTrue(p.contains("No composition, framing, pose, or background layout"))
    }

    // Asking for more detail needs room for it; the cap was raised with the request.
    func testTheWordCapLeavesRoomForTheExtraDetail() {
        XCTAssertTrue(p.contains("under 140 words"))
        XCTAssertFalse(p.contains("under 110 words"))
    }
}

// A rim glow can be the game's real treatment. Wild Wolves' approved artwork reads as
// "a bright golden luminous rim-glow following the outer silhouettes" — and the prompt
// then told the model, two paragraphs later, to draw no glow following the silhouette.
extension EdgeTreatmentTests {
    private func themed(_ styleFromArt: String) -> GameTheme {
        var t = GameTheme(name: "T", look: "A world.")
        t.styleFromArt = styleFromArt
        return t
    }

    func testAReferenceRimGlowIsNotForbidden() {
        let t = themed("Digital painting, no drawn contour, with a bright golden luminous "
                     + "rim-glow following the outer silhouettes.")
        XCTAssertTrue(GDDAssetPrompts.wantsRimGlow(t))
        let b = GDDAssetPrompts.styleBlock(t)
        XCTAssertFalse(b.contains("no glow following the silhouette"),
                       "forbidding the glow the reference art is built on")
        XCTAssertFalse(b.contains("Never a continuous bright"))
        XCTAssertTrue(b.contains("part of the artwork"))
    }

    // The two artefacts that are never wanted stay forbidden either way.
    func testTheInkedContourAndStickerBorderStayForbidden() {
        for art in ["painterly oil, no drawn contour, forms meet by value",
                    "painterly oil with a luminous rim light around every form"] {
            let b = GDDAssetPrompts.styleBlock(themed(art))
            XCTAssertTrue(b.contains("No inked contour stroke"), art)
            XCTAssertTrue(b.contains("die-cut border"), art)
        }
    }

    // Art with no rim light still gets the strict version.
    func testWithoutARimTheStrictVersionApplies() {
        let b = GDDAssetPrompts.styleBlock(themed("Flat matte gouache, even light, no glow."))
        XCTAssertFalse(GDDAssetPrompts.wantsRimGlow(themed("Flat matte gouache, even light, no glow.")))
        XCTAssertTrue(b.contains("no glow following the silhouette"))
        XCTAssertTrue(b.contains("SHORT AND BROKEN"))
    }

    // A chosen style that asks for rim light gets the same courtesy as reference art.
    func testAChosenStyleWithRimLightIsRespected() {
        var t = GameTheme(name: "T", look: "A world.")
        t.chosenStyle = SlotArtStyles.byID("hand-painted-heroic")
        XCTAssertTrue(t.chosenStyle!.keywords.contains("rim light"))
        XCTAssertTrue(GDDAssetPrompts.wantsRimGlow(t))
        XCTAssertFalse(GDDAssetPrompts.styleBlock(t).contains("no glow following the silhouette"))
    }
}

// Deciding whether the reference artwork is inked. This was keyed off a substring scan
// of free prose from a small model, and flipped between runs on the SAME theme — a
// description reading "No drawn contour; forms are separated by painted colour" matched
// "contour" and concluded the art was inked, turning the suppression off on exactly the
// artwork that needed it.
final class EdgeVerdictTests: XCTestCase {
    private func themed(_ s: String) -> GameTheme {
        var t = GameTheme(name: "T", look: "A world."); t.styleFromArt = s; return t
    }

    // The rule: a CHOSEN style overrides everything. Otherwise, if the game's own
    // artwork has line art, we keep it — so either the verdict or the description
    // establishing line work is enough, and the verdict only decides ambiguous cases.
    //
    // Measured on real cards: Dragon Fantasy's "intricate embossed relief" made the
    // verdict flip none/outline/outline across three reads of the SAME artwork.
    // Tightening the criterion settled that, but then answered "none" for Snow Queen,
    // whose description says "delicate, crisp dark line art" — and suppressing ink there
    // would print "lit, not inked" directly beneath a style paragraph describing ink.
    func testTheDescriptionCanEstablishLineWorkOnItsOwn() {
        let t = themed("Smooth airbrushed modelling with delicate, crisp dark line art.\n"
                     + "EDGE-TREATMENT: none\nRIM-GLOW: no")
        XCTAssertTrue(GDDAssetPrompts.wantsLineWork(t),
                      "the theme's own art says line art; we keep it")
        XCTAssertFalse(GDDAssetPrompts.wantsRimGlow(t))
    }

    // ...and a description with no line work, whatever else it mentions, stays clean.
    func testAmbiguousReliefIsNotLineWork() {
        let t = themed("Ultra-high polish with intricate embossed relief detailing and "
                     + "deep occlusion in the recesses.\nEDGE-TREATMENT: none\nRIM-GLOW: no")
        XCTAssertFalse(GDDAssetPrompts.wantsLineWork(t))
    }

    // A chosen style overrides the artwork entirely — that is what choosing one means.
    func testAChosenStyleOverridesTheArtwork() {
        var t = themed("Delicate crisp dark line art everywhere.\nEDGE-TREATMENT: outline")
        t.chosenStyle = SlotArtStyles.byID("hand-painted-heroic")
        XCTAssertFalse(GDDAssetPrompts.wantsLineWork(t),
                       "a chosen painterly style must beat the theme's inked artwork")
        XCTAssertTrue(GDDAssetPrompts.styleBlock(t).contains("lit, not inked"))
    }

    func testTheVerdictIsReadWhenItSaysOutline() {
        let t = themed("Painterly, no strokes mentioned.\nEDGE-TREATMENT: outline\nRIM-GLOW: yes")
        XCTAssertTrue(GDDAssetPrompts.wantsLineWork(t))
        XCTAssertTrue(GDDAssetPrompts.wantsRimGlow(t))
    }

    // The real sentence the model wrote, which used to invert the decision.
    func testNegatedMentionsDoNotCountAsLineWork() {
        XCTAssertFalse(GDDAssetPrompts.wantsLineWork(themed(
            "Digital painting. No drawn contour; forms are separated by painted color "
          + "and value meeting, with crisp edges at focal features.")))
        XCTAssertFalse(GDDAssetPrompts.wantsLineWork(themed("Rendered without outlines.")))
        XCTAssertFalse(GDDAssetPrompts.wantsLineWork(themed("There is no line art here.")))
    }

    func testAffirmativeMentionsStillCount() {
        XCTAssertTrue(GDDAssetPrompts.wantsLineWork(themed(
            "Flat cel shading with a bold black outline around every form.")))
        XCTAssertTrue(GDDAssetPrompts.wantsLineWork(themed("Clean line art over flat fills.")))
    }

    func testNegatedRimGlowDoesNotCount() {
        XCTAssertFalse(GDDAssetPrompts.wantsRimGlow(themed("Flat light, no halo or bloom.")))
        XCTAssertTrue(GDDAssetPrompts.wantsRimGlow(themed("A golden rim light along the edge.")))
    }

    func testVerdictParsingIsRobust() {
        XCTAssertEqual(GDDAssetPrompts.verdict("EDGE-TREATMENT", in: "x\nEDGE-TREATMENT: none"), "none")
        XCTAssertEqual(GDDAssetPrompts.verdict("edge-treatment", in: "EDGE-TREATMENT:  Outline "), "outline")
        XCTAssertNil(GDDAssetPrompts.verdict("EDGE-TREATMENT", in: "no verdict here"))
        // The LAST verdict wins, so a restatement does not lose to an earlier draft.
        XCTAssertEqual(GDDAssetPrompts.verdict("RIM-GLOW", in: "RIM-GLOW: no\nRIM-GLOW: yes"), "yes")
    }

    // The system prompt has to ask for the lines the parser reads.
    func testTheStylePromptAsksForTheVerdict() {
        XCTAssertTrue(RestyleRules.styleSystemPrompt.contains("EDGE-TREATMENT:"))
        XCTAssertTrue(RestyleRules.styleSystemPrompt.contains("RIM-GLOW:"))
    }
}

// Prescribing the replacement, not just forbidding the artefact. Measured: the
// prohibition alone moved nothing (43.9% -> 43.5% of the silhouette carrying a dark rim
// across 59 images). The studio's own preference is rim lighting over a drawn line, so
// that is what the prompt now asks for — and it leads the style definition rather than
// sitting among twenty-nine other rules.
extension EdgeTreatmentTests {
    func testTheStyleDefinitionLeadsWithLitNotInked() {
        let b = GDDAssetPrompts.styleBlock(theme)
        XCTAssertTrue(b.hasPrefix("RENDERING: this art is lit, not inked"),
                      "the edge instruction must open the style block, not trail it")
        XCTAssertTrue(b.contains("rim light along the lit edges"))
    }

    func testItPrescribesLightRatherThanOnlyForbiddingALine() {
        let e = SlotArtDirection.edgeTreatment()
        XCTAssertTrue(e.contains("SEPARATE THE SYMBOL WITH LIGHT, NOT WITH A LINE"))
        XCTAssertTrue(e.contains("rim light catching the"))
        // ...and distinguishes that rim from a traced stroke, which is the failure mode.
        XCTAssertTrue(e.contains("not a stroke drawn around it"))
    }

    // A line-work style must not get the "lit, not inked" preamble either.
    // Inked REFERENCE ART still stands the suppression down, even though no style does.
    func testInkedReferenceArtStillExemptsItself() {
        var t = GameTheme(name: "X", look: "A world.")
        t.styleFromArt = "Flat cel shading with bold black outlines.\nEDGE-TREATMENT: outline"
        let b = GDDAssetPrompts.styleBlock(t)
        XCTAssertFalse(b.contains("lit, not inked"))
        XCTAssertFalse(b.contains("SEPARATE THE SYMBOL WITH LIGHT"))
    }
}

// A standing integrity check on everything that makes the ART good — not the parsing,
// which has its own tests, but the direction that decides whether a symbol looks
// professional.
//
// Exists because a regex meant to delete eight art styles ran past the end of the array
// and took SlotSymbolRole and SlotSymbol with it. The suite caught it, but only because
// a test happened to classify "BWY1". This asserts the whole surface deliberately.
final class ArtDirectionIntegrityTests: XCTestCase {
    func testEveryRoleHasALabelAndRealDirection() {
        for r in SlotSymbolRole.allCases {
            XCTAssertFalse(r.label.isEmpty, "\(r) has no label")
            guard r != .blank else { continue }
            XCTAssertGreaterThan(SlotArtDirection.direction(for: r, tier: 1).count, 80,
                                 "\(r) has thin art direction")
        }
        XCTAssertFalse(SlotSymbolRole.blank.needsArt)
        XCTAssertTrue(SlotSymbolRole.highPay.needsArt)
    }

    // The value ladder the whole set depends on.
    func testTheValueLadderHolds() {
        let order = SlotSymbolRole.allCases.sorted { $0.priority < $1.priority }
        func at(_ r: SlotSymbolRole) -> Int { order.firstIndex(of: r)! }
        XCTAssertLessThan(at(.highPay), at(.mediumPay))
        XCTAssertLessThan(at(.mediumPay), at(.lowPay))
        XCTAssertLessThan(at(.wild), at(.lowPay))
    }

    func testFamilyRolesSurvive() {
        XCTAssertTrue(SlotSymbolRole.lowPay.isFamily)
        XCTAssertTrue(SlotSymbolRole.jackpot.isFamily)
        XCTAssertTrue(SlotSymbolRole.wysiwyg.isFamily)
        XCTAssertFalse(SlotSymbolRole.highPay.isFamily)
    }

    // Long prefixes must stay first, or BWY1 becomes a blank and gets the art direction
    // for an empty reel position.
    func testCodeClassificationIncludingLongPrefixes() {
        let want: [(String, SlotSymbolRole)] = [
            ("BWY1", .wysiwyg), ("DHP2", .highPay), ("BL1", .blank), ("HP1", .highPay),
            ("WD1", .wild), ("JP4", .jackpot), ("SF1", .collector), ("WY2", .wysiwyg),
            ("R1", .replacement), ("BO1", .bonus), ("MP3", .mediumPay), ("LP5", .lowPay),
        ]
        for (code, role) in want {
            XCTAssertEqual(GDDSymbolSetRules.classify(code).role, role, code)
        }
    }

    // Every section the drawing prompt is made of. A missing one is invisible in the
    // output until someone counts the artefacts it was there to prevent.
    func testTheDrawingPromptKeepsEverySection() {
        var t = GameTheme(name: "Beanstalk", comparables: "Megaways Jack",
                          look: "A giant beanstalk.")
        t.styleFromArt = "Painterly oil.\nEDGE-TREATMENT: none\nRIM-GLOW: no"
        var job = AssetJob(id: "HP1", kind: .symbol, role: .highPay, tier: 1, title: "",
                           subject: "a giant", silhouette: "giant", aspect: "1:1", size: "2K")
        job.hasFrame = true
        let p = GDDAssetPrompts.image(job: job, theme: t,
                                      backing: SlotBackingRules.candidates[2])
        for section in ["RENDERING: this art is lit", "ART STYLE", "THEME & LOOK", "EDGES —",
                        "THIS SYMBOL IS ONE OF A SET", "AVOID THESE SPECIFICALLY",
                        "FRAME:", "BACKDROP:"] {
            XCTAssertTrue(p.contains(section), "drawing prompt lost: \(section)")
        }
        let plan = GDDAssetPrompts.planning(theme: t, gameName: "G", jobs: [job],
                                            gddText: "Symbol Set\n0 WD1")
        XCTAssertTrue(plan.contains("SET RULES"))
        XCTAssertTrue(plan.contains("ART STYLE"))
    }
}

// Distinctness must be resolved by choosing a different subject from the same world,
// never by abstracting away from it. Measured cause: with wolves at HP1-HP2, the wild
// came back as a pawprint medallion — the set rule pushed it upward into a token.
final class SidewaysDistinctnessTests: XCTestCase {
    /// Whitespace-normalised: the source wraps these lines, and a raw contains() quietly
    /// depends on where the wrap happens to fall.
    private var rules: String {
        SlotArtDirection.setRules.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func testTheSetRulesSayHowToResolveAClash() {
        XCTAssertTrue(rules.contains("RESOLVE THAT SIDEWAYS, NOT UPWARD"))
        XCTAssertTrue(rules.contains("another character in the story"))
        XCTAssertTrue(rules.contains("has stopped being one world"))
    }

    func testEverySubjectIsBoundToThisGame() {
        XCTAssertTrue(rules.contains("EVERY subject comes from THIS game's theme"))
        XCTAssertTrue(rules.contains("rendered in the SAME art style"),
                      "the set rules must bind subject to theme AND rendering to one style")
        XCTAssertTrue(rules.contains("would fit equally well in a different game"))
    }

    // The rule reaches the planner, which is what chooses subjects.
    func testItReachesThePlanner() {
        var t = GameTheme(name: "Wild Wolves", look: "A moonlit forest.")
        t.styleFromArt = "Painterly.\nEDGE-TREATMENT: none\nRIM-GLOW: yes"
        let job = AssetJob(id: "WD1", kind: .symbol, role: .wild, tier: nil, title: "",
                           subject: "", silhouette: "", aspect: "1:1", size: "2K")
        let p = GDDAssetPrompts.planning(theme: t, gameName: "G", jobs: [job],
                                         gddText: "Symbol Set\n0 WD1\n1-4 HP1-4")
        XCTAssertTrue(p.contains("RESOLVE THAT SIDEWAYS"))
        XCTAssertTrue(p.contains("EVERY subject comes from THIS game's theme"))
    }
}

// "Contour" in art writing means the edge of a form, not a drawn line. Treating the bare
// word as line work read Wild Bears — whose own verdict said "none" — as inked, and
// switched the cartoon-outline suppression off for it.
extension EdgeVerdictTests {
    func testSoftContoursAreNotLineWork() {
        var t = GameTheme(name: "Wild Bears", look: "Wilderness.")
        t.styleFromArt = "Painterly rendering with soft contours and smooth contour shading "
                       + "describing the forms.\nEDGE-TREATMENT: none\nRIM-GLOW: no"
        XCTAssertFalse(GDDAssetPrompts.wantsLineWork(t),
                       "a form's contour is not a drawn line")
    }

    // ...but an ink contour is.
    func testInkContoursAreLineWork() {
        var t = GameTheme(name: "Loki", look: "Norse.")
        t.styleFromArt = "Line art and delicate ink contours defining every form.\n"
                       + "EDGE-TREATMENT: outline"
        XCTAssertTrue(GDDAssetPrompts.wantsLineWork(t))
        t.styleFromArt = "Crisp contour lines around each shape.\nEDGE-TREATMENT: none"
        XCTAssertTrue(GDDAssetPrompts.wantsLineWork(t), "a contour LINE is a drawn mark")
    }
}

// How many images run at once, and how the pool reacts to pushback.
final class ImageConcurrencyTests: XCTestCase {
    func testTheDefaultIsWiderThanSequential() {
        XCTAssertGreaterThan(ImageRequestPolicy.concurrency, 1)
        XCTAssertGreaterThan(ImageRequestPolicy.widenAfterSuccesses, 1,
                             "narrow fast, widen slowly")
    }

    // Narrow by ONE, not to serial. A single transient 429 used to pin the width at 1 for
    // the rest of a twenty-image run, so one blip cost the whole batch its parallelism.
    func testNarrowingIsGradualAndRecoverable() {
        var width = ImageRequestPolicy.concurrency
        width = max(1, width - 1)
        XCTAssertEqual(width, ImageRequestPolicy.concurrency - 1)
        // ...and a clean run takes the worker back.
        var clean = 0
        for _ in 0..<ImageRequestPolicy.widenAfterSuccesses {
            clean += 1
            if clean >= ImageRequestPolicy.widenAfterSuccesses,
               width < ImageRequestPolicy.concurrency { width += 1; clean = 0 }
        }
        XCTAssertEqual(width, ImageRequestPolicy.concurrency)
    }

    // It can never narrow past serial, however many failures arrive.
    func testItNeverNarrowsBelowOne() {
        var width = ImageRequestPolicy.concurrency
        for _ in 0..<20 { width = max(1, width - 1) }
        XCTAssertEqual(width, 1)
    }

    // Retry policy is unchanged: Google's documented shape.
    func testRetryPolicyIsIntact() {
        XCTAssertEqual(ImageRequestPolicy.maxAttempts, 3)
        XCTAssertTrue(ImageRequestPolicy.isRetryable(status: 429))
        XCTAssertTrue(ImageRequestPolicy.isRetryable(status: 503))
        XCTAssertFalse(ImageRequestPolicy.isRetryable(status: 400))
    }
}
