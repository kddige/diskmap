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
