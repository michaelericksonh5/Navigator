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
    func testQuotedWrapsSoSpacesSurviveAShell() {
        XCTAssertEqual(PathText.quoted(["/Users/me/My Files/a.txt"]), "\"/Users/me/My Files/a.txt\"")
    }

    // A double quote is legal in a POSIX filename and would end the quoted run early,
    // handing the shell a command split in the wrong place.
    func testQuotedEscapesQuotesAndBackslashes() {
        XCTAssertEqual(PathText.quoted(["/tmp/a\"b"]), "\"/tmp/a\\\"b\"")
        XCTAssertEqual(PathText.quoted(["/tmp/a\\b"]), "\"/tmp/a\\\\b\"")
    }

    func testQuotedJoinsAMultiSelectionOnePerLine() {
        XCTAssertEqual(PathText.quoted(["/a", "/b"]), "\"/a\"\n\"/b\"")
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
        XCTAssertEqual(lru.order, ["/tmp/a"])
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
        XCTAssertEqual(back.order, ["/tmp/b", "/tmp/a"])
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
        XCTAssertEqual(lru.order, ["/tmp/a"])
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

    func testSymlinkedFolderKeysAsItsTarget() {
        XCTAssertEqual(folderKey(root + "/Link"), folderKey(root + "/Real"))
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
