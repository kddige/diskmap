import CScan
import XCTest

private let mib: UInt64 = 1 << 20

/// Scans real files in a temporary folder and checks what the scanner reports.
final class ScanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diskmap-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    /// Writes `size` bytes that are not all zero, so nothing can store them as a hole.
    @discardableResult
    private func write(_ relativePath: String, _ size: UInt64) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: Int(size))
        var state: UInt32 = 0x9E3779B9
        for i in stride(from: 0, to: bytes.count, by: 512) {
            state = state &* 1664525 &+ 1013904223
            bytes[i] = UInt8(truncatingIfNeeded: state >> 24) | 1
        }
        try Data(bytes).write(to: url)
        return url
    }

    private func scan() -> OpaquePointer {
        let tree = dm_scan_start(root.path, 2)!
        dm_scan_wait(tree)
        return tree
    }

    private func info(_ tree: OpaquePointer, _ node: UInt32) -> dm_node_info {
        var info = dm_node_info()
        dm_node_get(tree, node, &info)
        return info
    }

    private func progress(_ tree: OpaquePointer) -> dm_progress {
        var progress = dm_progress()
        dm_progress_get(tree, &progress)
        return progress
    }

    private func child(_ tree: OpaquePointer, of dir: UInt32, named name: String) -> UInt32? {
        (0..<info(tree, dir).child_count)
            .map { dm_child_at(tree, dir, $0) }
            .first { String(cString: info(tree, $0).name) == name }
    }

    private func clone(_ source: URL, to relativePath: String) throws -> URL {
        let destination = root.appendingPathComponent(relativePath)
        guard clonefile(source.path, destination.path, 0) == 0 else {
            throw XCTSkip("this file system cannot clone files")
        }
        return destination
    }

    /// Scans the folder at `node` again and swaps the result into `tree`.
    @discardableResult
    private func rescan(_ tree: OpaquePointer, _ node: UInt32) -> Bool {
        guard let fresh = dm_rescan_start(tree, node, 2) else { return false }
        defer { dm_tree_free(fresh) }
        dm_scan_wait(fresh)
        return dm_rescan_apply(tree, fresh)
    }

    /// Size of everything in the tree, by path below the root.
    private func sizes(_ tree: OpaquePointer) -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        var pending: [(UInt32, String)] = [(0, "")]
        while let (node, path) = pending.popLast() {
            let entry = info(tree, node)
            result[path] = entry.size
            XCTAssertTrue(dm_node_alive(tree, node), path)
            for i in 0..<entry.child_count {
                let child = dm_child_at(tree, node, i)
                pending.append((child, path + "/" + String(cString: info(tree, child).name)))
            }
        }
        return result
    }

    /// The tree must say what scanning everything again says.
    private func assertMatchesNewScan(_ tree: OpaquePointer, file: StaticString = #filePath, line: UInt = #line) {
        let again = scan()
        defer { dm_tree_free(again) }
        XCTAssertEqual(sizes(tree), sizes(again), file: file, line: line)
        let have = progress(tree), want = progress(again)
        XCTAssertEqual(have.bytes, want.bytes, "bytes", file: file, line: line)
        XCTAssertEqual(have.files, want.files, "files", file: file, line: line)
        XCTAssertEqual(have.dirs, want.dirs, "folders", file: file, line: line)
        XCTAssertEqual(have.denied, want.denied, "unreadable folders", file: file, line: line)
        XCTAssertEqual(have.hardlink_dupes, want.hardlink_dupes, "hard links", file: file, line: line)
        XCTAssertEqual(have.clone_files, want.clone_files, "clones", file: file, line: line)
        XCTAssertEqual(have.clone_bytes, want.clone_bytes, "clone bytes", file: file, line: line)
    }

    private func remove(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(relativePath))
    }

    // MARK: Tests

    func testSizesRollUpToTheRoot() throws {
        try write("a/one.bin", 1 * mib)
        try write("a/deep/two.mov", 2 * mib)
        try write("three.txt", 3 * mib)

        let tree = scan()
        defer { dm_tree_free(tree) }

        let p = progress(tree)
        XCTAssertEqual(p.state, DM_STATE_DONE)
        XCTAssertEqual(p.files, 3)
        XCTAssertEqual(p.bytes, 6 * mib)
        XCTAssertEqual(info(tree, 0).size, 6 * mib)
        XCTAssertEqual(info(tree, 0).file_count, 3)

        let a = try XCTUnwrap(child(tree, of: 0, named: "a"))
        XCTAssertEqual(info(tree, a).size, 3 * mib)
        XCTAssertNotEqual(info(tree, a).flags & UInt8(DM_F_DIR), 0)
        let deep = try XCTUnwrap(child(tree, of: a, named: "deep"))
        XCTAssertEqual(info(tree, deep).size, 2 * mib)
    }

    func testChildrenAreSortedLargestFirst() throws {
        try write("small.bin", 1 * mib)
        try write("large.bin", 3 * mib)
        try write("medium.bin", 2 * mib)

        let tree = scan()
        defer { dm_tree_free(tree) }

        let names = (0..<info(tree, 0).child_count).map {
            String(cString: info(tree, dm_child_at(tree, 0, $0)).name)
        }
        XCTAssertEqual(names, ["large.bin", "medium.bin", "small.bin"])
    }

    func testFileKindsComeFromTheExtension() throws {
        try write("clip.MOV", 4096)
        try write("photo.heic", 4096)
        try write("model.gguf", 4096)
        try write("main.swift", 4096)
        try write("README", 4096)

        let tree = scan()
        defer { dm_tree_free(tree) }

        func kind(_ name: String) throws -> Int32 {
            Int32(info(tree, try XCTUnwrap(child(tree, of: 0, named: name))).kind)
        }
        XCTAssertEqual(try kind("clip.MOV"), DM_KIND_VIDEO)
        XCTAssertEqual(try kind("photo.heic"), DM_KIND_IMAGE)
        XCTAssertEqual(try kind("model.gguf"), DM_KIND_DATA)
        XCTAssertEqual(try kind("main.swift"), DM_KIND_CODE)
        XCTAssertEqual(try kind("README"), DM_KIND_OTHER)
    }

    func testHardLinksAreCountedOnce() throws {
        let original = try write("original.bin", 2 * mib)
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("link.bin"))

        let tree = scan()
        defer { dm_tree_free(tree) }

        XCTAssertEqual(info(tree, 0).size, 2 * mib)
        XCTAssertEqual(progress(tree).hardlink_dupes, 1)
    }

    func testClonesAreCountedOnce() throws {
        let original = try write("original.bin", 2 * mib)
        _ = try clone(original, to: "copy.bin")

        let tree = scan()
        defer { dm_tree_free(tree) }

        XCTAssertEqual(info(tree, 0).size, 2 * mib)
        XCTAssertEqual(progress(tree).clone_files, 1)
        XCTAssertEqual(progress(tree).clone_bytes, 2 * mib)

        // The original keeps its size; the copy shows what it does not share.
        let kept = try XCTUnwrap(child(tree, of: 0, named: "original.bin"))
        let copy = try XCTUnwrap(child(tree, of: 0, named: "copy.bin"))
        XCTAssertEqual(info(tree, kept).size, 2 * mib)
        XCTAssertEqual(info(tree, copy).size, 0)
        XCTAssertNotEqual(info(tree, copy).flags & UInt8(DM_F_CLONE), 0)
    }

    /// Large clones are checked one by one for data of their own.
    func testLargeCloneIsCountedOnce() throws {
        let original = try write("big/original.bin", 9 * mib)
        _ = try clone(original, to: "big/copy.bin")

        let tree = scan()
        defer { dm_tree_free(tree) }

        XCTAssertEqual(info(tree, 0).size, 9 * mib)
        let big = try XCTUnwrap(child(tree, of: 0, named: "big"))
        XCTAssertEqual(info(tree, big).size, 9 * mib)
    }

    func testClonesWithoutTheirOriginalStillCountOnce() throws {
        let original = try write("original.bin", 2 * mib)
        _ = try clone(original, to: "copy-a.bin")
        _ = try clone(original, to: "copy-b.bin")
        try FileManager.default.removeItem(at: original)

        let tree = scan()
        defer { dm_tree_free(tree) }

        XCTAssertEqual(info(tree, 0).size, 2 * mib)
    }

    func testRemovingANodeUpdatesItsAncestors() throws {
        try write("keep.bin", 1 * mib)
        try write("dir/gone.bin", 2 * mib)

        let tree = scan()
        defer { dm_tree_free(tree) }

        let dir = try XCTUnwrap(child(tree, of: 0, named: "dir"))
        let gone = try XCTUnwrap(child(tree, of: dir, named: "gone.bin"))
        dm_remove_node(tree, gone)

        XCTAssertEqual(info(tree, dir).size, 0)
        XCTAssertEqual(info(tree, 0).size, 1 * mib)
    }

    func testRemovingAFolderUpdatesTheCounters() throws {
        let original = try write("original.bin", 2 * mib)
        try write("dir/sub/a.bin", 1 * mib)
        _ = try clone(original, to: "dir/copy.bin")
        XCTAssertEqual(link(original.path, root.appendingPathComponent("dir/sub/link.bin").path), 0)

        let tree = scan()
        defer { dm_tree_free(tree) }
        XCTAssertEqual(progress(tree).dirs, 3)

        let dir = try XCTUnwrap(child(tree, of: 0, named: "dir"))
        let sub = try XCTUnwrap(child(tree, of: dir, named: "sub"))
        dm_remove_node(tree, dir)
        try remove("dir")

        XCTAssertFalse(dm_node_alive(tree, dir))
        XCTAssertFalse(dm_node_alive(tree, sub))
        XCTAssertTrue(dm_node_alive(tree, 0))
        assertMatchesNewScan(tree)
    }

    // MARK: Rescanning one folder

    func testRescanningAFolderPicksUpWhatChanged() throws {
        try write("big.bin", 4 * mib)
        try write("dir/stays.bin", 1 * mib)
        try write("dir/goes.bin", 2 * mib)
        try write("dir/grows.bin", 1 * mib)
        try write("dir/old/a.bin", 1 * mib)
        try write("other/b.bin", 3 * mib)

        let tree = scan()
        defer { dm_tree_free(tree) }
        let dir = try XCTUnwrap(child(tree, of: 0, named: "dir"))
        let goes = try XCTUnwrap(child(tree, of: dir, named: "goes.bin"))
        let old = try XCTUnwrap(child(tree, of: dir, named: "old"))
        let oldFile = try XCTUnwrap(child(tree, of: old, named: "a.bin"))
        let other = try XCTUnwrap(child(tree, of: 0, named: "other"))

        try remove("dir/goes.bin")
        try remove("dir/old")
        try write("dir/grows.bin", 6 * mib)
        try write("dir/new/deep/c.mov", 2 * mib)
        // A change outside the folder is not picked up.
        try write("other/unseen.bin", 1 * mib)

        XCTAssertTrue(rescan(tree, dir))

        XCTAssertEqual(info(tree, dir).size, 9 * mib)
        XCTAssertEqual(info(tree, dir).file_count, 3)
        XCTAssertEqual(info(tree, 0).size, 16 * mib)
        XCTAssertEqual(info(tree, 0).file_count, 5)
        XCTAssertEqual(info(tree, other).size, 3 * mib)
        XCTAssertEqual(progress(tree).dirs, 5) // root, dir, new, deep, other

        // The folder is now the largest thing in the root, and says what it mostly holds.
        XCTAssertEqual(dm_child_at(tree, 0, 0), dir)
        XCTAssertEqual(String(cString: info(tree, dm_child_at(tree, dir, 0)).name), "grows.bin")
        XCTAssertEqual(Int32(info(tree, dir).kind), DM_KIND_DATA)

        // The folder keeps its id; what was inside it does not.
        XCTAssertTrue(dm_node_alive(tree, dir))
        XCTAssertTrue(dm_node_alive(tree, other))
        XCTAssertFalse(dm_node_alive(tree, goes))
        XCTAssertFalse(dm_node_alive(tree, old))
        XCTAssertFalse(dm_node_alive(tree, oldFile))
        XCTAssertNil(child(tree, of: dir, named: "goes.bin"))

        let new = try XCTUnwrap(child(tree, of: dir, named: "new"))
        let deep = try XCTUnwrap(child(tree, of: new, named: "deep"))
        let movie = try XCTUnwrap(child(tree, of: deep, named: "c.mov"))
        XCTAssertEqual(info(tree, movie).parent, deep)
        var buffer = [CChar](repeating: 0, count: 2048)
        dm_node_path(tree, movie, &buffer, buffer.count)
        XCTAssertEqual(String(cString: buffer), dm_root_path(tree).map { String(cString: $0) }! + "/dir/new/deep/c.mov")

        try remove("other/unseen.bin")
        assertMatchesNewScan(tree)
    }

    func testRescanningTwiceAndInsideARescannedFolder() throws {
        try write("dir/a/one.bin", 1 * mib)
        try write("dir/b/two.bin", 2 * mib)
        try write("keep.bin", 1 * mib)

        let tree = scan()
        defer { dm_tree_free(tree) }
        let dir = try XCTUnwrap(child(tree, of: 0, named: "dir"))

        try write("dir/a/three.bin", 3 * mib)
        XCTAssertTrue(rescan(tree, dir))
        assertMatchesNewScan(tree)

        // A folder that only exists since the rescan can be rescanned as well.
        let a = try XCTUnwrap(child(tree, of: dir, named: "a"))
        try remove("dir/a/one.bin")
        try write("dir/a/four.bin", 4 * mib)
        XCTAssertTrue(rescan(tree, a))
        XCTAssertEqual(info(tree, a).size, 7 * mib)
        XCTAssertEqual(info(tree, 0).size, 10 * mib)
        assertMatchesNewScan(tree)

        // Moving something to the Trash still works on the new nodes.
        let four = try XCTUnwrap(child(tree, of: a, named: "four.bin"))
        dm_remove_node(tree, four)
        try remove("dir/a/four.bin")
        assertMatchesNewScan(tree)

        try remove("dir/b")
        try remove("dir/a")
        XCTAssertTrue(rescan(tree, dir))
        XCTAssertEqual(info(tree, dir).size, 0)
        XCTAssertEqual(info(tree, dir).child_count, 0)
        XCTAssertEqual(info(tree, 0).size, 1 * mib)
        assertMatchesNewScan(tree)
    }

    func testRescanCountsHardLinksOnceAcrossTheFolder() throws {
        let first = try write("one/data.bin", 2 * mib)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("two"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(link(first.path, root.appendingPathComponent("two/link.bin").path), 0)

        let tree = scan()
        defer { dm_tree_free(tree) }
        let one = try XCTUnwrap(child(tree, of: 0, named: "one"))
        let two = try XCTUnwrap(child(tree, of: 0, named: "two"))
        XCTAssertEqual(info(tree, 0).size, 2 * mib)

        // Whichever folder holds the link that was counted, rescanning either
        // one must leave the file counted exactly once.
        for folder in [one, two, two, one] {
            XCTAssertTrue(rescan(tree, folder))
            XCTAssertEqual(info(tree, 0).size, 2 * mib)
            XCTAssertEqual(info(tree, one).size + info(tree, two).size, 2 * mib)
            XCTAssertEqual(progress(tree).hardlink_dupes, 1)
        }

        // A second link inside a rescanned folder does not add anything either.
        XCTAssertEqual(link(first.path, root.appendingPathComponent("two/again.bin").path), 0)
        XCTAssertTrue(rescan(tree, two))
        XCTAssertEqual(info(tree, 0).size, 2 * mib)
        XCTAssertEqual(progress(tree).hardlink_dupes, 2)
    }

    func testRescanLeavesAHardLinkCountedOutsideTheFolderAlone() throws {
        // The root is read before the folders in it, so the link in the root
        // is the one that counts.
        let first = try write("data.bin", 2 * mib)
        try write("dir/other.bin", 1 * mib)
        XCTAssertEqual(link(first.path, root.appendingPathComponent("dir/link.bin").path), 0)

        let tree = scan()
        defer { dm_tree_free(tree) }
        let dir = try XCTUnwrap(child(tree, of: 0, named: "dir"))
        XCTAssertEqual(info(tree, dir).size, 1 * mib)

        XCTAssertTrue(rescan(tree, dir))
        XCTAssertEqual(info(tree, dir).size, 1 * mib)
        let linked = try XCTUnwrap(child(tree, of: dir, named: "link.bin"))
        XCTAssertNotEqual(info(tree, linked).flags & UInt8(DM_F_HARDLINK), 0)
        assertMatchesNewScan(tree)

        // Once the counted link is in the Trash, the one in the folder counts.
        dm_remove_node(tree, try XCTUnwrap(child(tree, of: 0, named: "data.bin")))
        try remove("data.bin")
        XCTAssertTrue(rescan(tree, dir))
        XCTAssertEqual(info(tree, dir).size, 3 * mib)
        assertMatchesNewScan(tree)
    }

    func testRescanDoesNotCountAClonedOriginalOutsideTheFolderAgain() throws {
        let original = try write("original.bin", 2 * mib)
        try write("dir/own.bin", 1 * mib)
        _ = try clone(original, to: "dir/copy.bin")

        let tree = scan()
        defer { dm_tree_free(tree) }
        let dir = try XCTUnwrap(child(tree, of: 0, named: "dir"))
        XCTAssertEqual(info(tree, dir).size, 1 * mib)

        _ = try clone(original, to: "dir/another.bin")
        XCTAssertTrue(rescan(tree, dir))

        XCTAssertEqual(info(tree, dir).size, 1 * mib)
        XCTAssertEqual(info(tree, 0).size, 3 * mib)
        XCTAssertEqual(progress(tree).clone_files, 2)
        XCTAssertEqual(progress(tree).clone_bytes, 4 * mib)
        let copy = try XCTUnwrap(child(tree, of: dir, named: "copy.bin"))
        XCTAssertNotEqual(info(tree, copy).flags & UInt8(DM_F_CLONE), 0)
        assertMatchesNewScan(tree)

        // With the original deleted, the data lives on in the copies and one
        // of them has to carry it.
        dm_remove_node(tree, try XCTUnwrap(child(tree, of: 0, named: "original.bin")))
        try remove("original.bin")
        XCTAssertTrue(rescan(tree, dir))
        XCTAssertEqual(info(tree, dir).size, 3 * mib)
        XCTAssertEqual(progress(tree).clone_files, 1)
        assertMatchesNewScan(tree)
    }

    func testRescanKeepsACloneFamilyWithoutItsOriginalCountedOnce() throws {
        let original = try write("original.bin", 2 * mib)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("one"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("two"), withIntermediateDirectories: true)
        _ = try clone(original, to: "one/a.bin")
        _ = try clone(original, to: "two/b.bin")
        try remove("original.bin")

        let tree = scan()
        defer { dm_tree_free(tree) }
        let one = try XCTUnwrap(child(tree, of: 0, named: "one"))
        let two = try XCTUnwrap(child(tree, of: 0, named: "two"))
        XCTAssertEqual(info(tree, 0).size, 2 * mib)

        // The oldest copy carries the data. Rescanning its folder, or the
        // other one, in any order, must not count it a second time.
        for folder in [two, one, two, one, one, two] {
            XCTAssertTrue(rescan(tree, folder))
            XCTAssertEqual(info(tree, 0).size, 2 * mib)
            XCTAssertEqual(info(tree, one).size, 2 * mib)
            XCTAssertEqual(info(tree, two).size, 0)
            XCTAssertEqual(progress(tree).clone_files, 1)
            XCTAssertEqual(progress(tree).clone_bytes, 2 * mib)
        }
        assertMatchesNewScan(tree)
    }

    func testRescanReadsAFolderThatWasLockedBefore() throws {
        try write("locked/inside.bin", 2 * mib)
        try write("open.bin", 1 * mib)
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let tree = scan()
        defer { dm_tree_free(tree) }
        let node = try XCTUnwrap(child(tree, of: 0, named: "locked"))
        try XCTSkipIf(info(tree, node).size != 0, "running as a user who can read everything")
        XCTAssertEqual(dm_denied_count(tree), 1)
        XCTAssertEqual(dm_denied_at(tree, 0), node)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        XCTAssertTrue(rescan(tree, node))
        XCTAssertEqual(dm_denied_count(tree), 0)
        XCTAssertEqual(info(tree, node).flags & UInt8(DM_F_UNREADABLE), 0)
        XCTAssertEqual(info(tree, node).size, 2 * mib)
        XCTAssertEqual(info(tree, 0).size, 3 * mib)

        // And the other way round: locked again, it is reported once.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        XCTAssertTrue(rescan(tree, node))
        XCTAssertEqual(dm_denied_count(tree), 1)
        XCTAssertEqual(dm_denied_at(tree, 0), node)
        XCTAssertEqual(info(tree, 0).size, 1 * mib)
    }

    func testRescanIsRefusedWhereItCannotWork() throws {
        try write("dir/a.bin", 1 * mib)
        try write("gone/b.bin", 1 * mib)
        try write("file.bin", 1 * mib)

        let tree = scan()
        defer { dm_tree_free(tree) }
        let dir = try XCTUnwrap(child(tree, of: 0, named: "dir"))
        let gone = try XCTUnwrap(child(tree, of: 0, named: "gone"))
        let file = try XCTUnwrap(child(tree, of: 0, named: "file.bin"))

        XCTAssertNil(dm_rescan_start(tree, 0, 2), "the root is a full scan")
        XCTAssertNil(dm_rescan_start(tree, file, 2), "not a folder")
        try remove("gone")
        XCTAssertNil(dm_rescan_start(tree, gone, 2), "no longer on disk")

        // A cancelled rescan changes nothing.
        let cancelled = try XCTUnwrap(dm_rescan_start(tree, dir, 2))
        dm_scan_cancel(cancelled)
        dm_scan_wait(cancelled)
        XCTAssertFalse(dm_rescan_apply(tree, cancelled))
        dm_tree_free(cancelled)

        // Neither does one that was overtaken by another change to the tree.
        try write("dir/new.bin", 2 * mib)
        let late = try XCTUnwrap(dm_rescan_start(tree, dir, 2))
        dm_scan_wait(late)
        dm_remove_node(tree, gone)
        XCTAssertFalse(dm_rescan_apply(tree, late))
        dm_tree_free(late)
        XCTAssertEqual(info(tree, dir).size, 1 * mib)

        // And a result is applied once.
        let fresh = try XCTUnwrap(dm_rescan_start(tree, dir, 2))
        dm_scan_wait(fresh)
        XCTAssertTrue(dm_rescan_apply(tree, fresh))
        XCTAssertFalse(dm_rescan_apply(tree, fresh))
        dm_tree_free(fresh)
        XCTAssertEqual(info(tree, dir).size, 3 * mib)
        assertMatchesNewScan(tree)
    }

    func testLayoutAfterARescanDrawsTheNewFiles() throws {
        try write("dir/a.bin", 1 * mib)
        try write("keep.bin", 1 * mib)

        let tree = scan()
        defer { dm_tree_free(tree) }
        let dir = try XCTUnwrap(child(tree, of: 0, named: "dir"))
        try remove("dir/a.bin")
        try write("dir/b.bin", 2 * mib)
        try write("dir/c.bin", 1 * mib)
        XCTAssertTrue(rescan(tree, dir))

        var params = dm_layout_params(
            header_h: 0, header_min_w: 0, header_min_h: 0, header_max_depth: 0,
            pad: 0, min_side: 2.5, min_area: 3,
            cushion_height: 0.2, cushion_falloff: 0.7, cushion_leaf: 0.14)
        let layout = try XCTUnwrap(dm_layout_create(tree, 0, 400, 300, &params))
        defer { dm_layout_free(layout) }
        var count = 0
        let cells = try XCTUnwrap(dm_layout_cells(layout, &count))
        let files = (0..<count).map { cells[$0] }.filter { $0.type == UInt8(DM_CELL_FILE) }
        XCTAssertEqual(Set(files.map { String(cString: info(tree, $0.node).name) }), ["b.bin", "c.bin", "keep.bin"])
        XCTAssertEqual(files.reduce(0) { $0 + Double($1.w * $1.h) }, 400 * 300, accuracy: 400 * 300 * 0.02)
    }

    func testPathsAndAncestry() throws {
        try write("a/b/file.bin", 4096)

        let tree = scan()
        defer { dm_tree_free(tree) }

        let a = try XCTUnwrap(child(tree, of: 0, named: "a"))
        let b = try XCTUnwrap(child(tree, of: a, named: "b"))
        let file = try XCTUnwrap(child(tree, of: b, named: "file.bin"))

        var buffer = [CChar](repeating: 0, count: 4096)
        dm_node_path(tree, file, &buffer, buffer.count)
        XCTAssertTrue(String(cString: buffer).hasSuffix("/a/b/file.bin"))
        XCTAssertTrue(dm_is_within(tree, file, a))
        XCTAssertFalse(dm_is_within(tree, a, file))
    }

    func testLayoutDrawsEveryFile() throws {
        try write("a/one.bin", 3 * mib)
        try write("a/two.bin", 2 * mib)
        try write("three.bin", 1 * mib)

        let tree = scan()
        defer { dm_tree_free(tree) }

        let width = 320, height = 200
        var params = dm_layout_params(
            header_h: 17, header_min_w: 84, header_min_h: 48, header_max_depth: 5,
            pad: 1, min_side: 2.5, min_area: 3,
            cushion_height: 0.2, cushion_falloff: 0.7, cushion_leaf: 0.14)
        let layout = try XCTUnwrap(dm_layout_create(tree, 0, Int32(width), Int32(height), &params))
        defer { dm_layout_free(layout) }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var ids = [UInt32](repeating: DM_NONE, count: width * height)
        var render = dm_render_params()
        render.highlight_kind = -1
        render.ambient = 0.4
        dm_layout_render(layout, &rgba, &ids, &render)

        // Every file owns pixels, in proportion to its size.
        var pixels: [UInt32: Int] = [:]
        for id in ids where id != DM_NONE { pixels[id, default: 0] += 1 }
        let a = try XCTUnwrap(child(tree, of: 0, named: "a"))
        let one = try XCTUnwrap(child(tree, of: a, named: "one.bin"))
        let two = try XCTUnwrap(child(tree, of: a, named: "two.bin"))
        let three = try XCTUnwrap(child(tree, of: 0, named: "three.bin"))
        XCTAssertGreaterThan(pixels[one, default: 0], pixels[two, default: 0])
        XCTAssertGreaterThan(pixels[two, default: 0], pixels[three, default: 0])
        XCTAssertGreaterThan(pixels[three, default: 0], 0)

        var x: Float = 0, y: Float = 0, w: Float = 0, h: Float = 0
        XCTAssertTrue(dm_layout_find(layout, one, &x, &y, &w, &h))
        XCTAssertGreaterThan(w * h, 0)
    }
}
