import AppKit
import CScan

let noNode = UInt32.max

/// The data volume: where everything that is not the sealed macOS system lives.
let dataVolumePath = "/System/Volumes/Data"

// MARK: - File kinds

enum Kind {
    static let count = Int(DM_KIND_COUNT)

    /// Indexed by DM_KIND_*. Eight categorical hues stepped for a dark surface,
    /// plus a neutral for "Other".
    static let rgb: [(UInt8, UInt8, UInt8)] = [
        (0x6b, 0x6a, 0x65), // other
        (0x39, 0x87, 0xe5), // video      blue
        (0xd9, 0x59, 0x26), // images     orange
        (0x19, 0x9e, 0x70), // audio      aqua
        (0xc9, 0x85, 0x00), // archives   yellow
        (0xd5, 0x51, 0x81), // documents  magenta
        (0x00, 0x83, 0x00), // code       green
        (0x90, 0x85, 0xe9), // binaries   violet
        (0xe6, 0x67, 0x67), // data       red
    ]

    static let colors: [NSColor] = rgb.map {
        NSColor(srgbRed: CGFloat($0.0) / 255, green: CGFloat($0.1) / 255, blue: CGFloat($0.2) / 255, alpha: 1)
    }

    static func name(_ kind: Int) -> String { String(cString: dm_kind_name(Int32(kind))) }

    private static var swatches: [Int: NSImage] = [:]

    /// A small rounded square in the kind's color, for list rows.
    static func swatch(_ kind: Int) -> NSImage {
        if let image = swatches[kind] { return image }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            colors[kind].setFill()
            NSBezierPath(roundedRect: NSRect(x: 3, y: 3, width: 10, height: 10), xRadius: 2.5, yRadius: 2.5).fill()
            return true
        }
        swatches[kind] = image
        return image
    }
}

// MARK: - Formatting

func formatBytes(_ bytes: UInt64) -> String {
    if bytes < 1000 { return "\(bytes) bytes" }
    let units = ["KB", "MB", "GB", "TB", "PB"]
    var value = Double(bytes) / 1000
    var unit = 0
    while value >= 999.5 && unit < units.count - 1 {
        value /= 1000
        unit += 1
    }
    let digits = value < 9.995 ? 2 : (value < 99.95 ? 1 : 0)
    return String(format: "%.\(digits)f", locale: Locale.current, value) + " " + units[unit]
}

private let countFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f
}()

func formatCount(_ n: UInt64) -> String {
    countFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
}

func formatItems(_ n: UInt64) -> String {
    n == 1 ? "1 file" : "\(formatCount(n)) files"
}

// MARK: - Scan session

/// Owns one scan and the tree it produced.
final class ScanSession {
    let tree: OpaquePointer
    let rootPath: String
    /// Bytes the user moved to the Trash during this session.
    var trashedBytes: UInt64 = 0

    init?(path: String) {
        guard let tree = dm_scan_start(path, 0) else { return nil }
        self.tree = tree
        self.rootPath = String(cString: dm_root_path(tree))
    }

    deinit {
        // Joins the scan threads; keep that off the main thread.
        let tree = self.tree
        DispatchQueue.global(qos: .utility).async { dm_tree_free(tree) }
    }

    var progress: dm_progress {
        var p = dm_progress()
        dm_progress_get(tree, &p)
        return p
    }

    var isDone: Bool { progress.state == DM_STATE_DONE }
    func cancel() { dm_scan_cancel(tree) }

    func info(_ node: UInt32) -> dm_node_info {
        var info = dm_node_info()
        dm_node_get(tree, node, &info)
        return info
    }

    func isDirectory(_ node: UInt32) -> Bool { info(node).flags & UInt8(DM_F_DIR) != 0 }
    func parent(_ node: UInt32) -> UInt32 { info(node).parent }
    func child(_ dir: UInt32, _ index: Int) -> UInt32 { dm_child_at(tree, dir, UInt32(index)) }

    /// Name for display. The root shows as the volume or folder name.
    func name(_ node: UInt32) -> String {
        if node == 0 { return rootDisplayName }
        return String(cString: info(node).name)
    }

    lazy var rootDisplayName: String = {
        if rootPath == dataVolumePath || rootPath == "/" {
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey])
            return values?.volumeName ?? "Macintosh HD"
        }
        return FileManager.default.displayName(atPath: rootPath)
    }()

    /// The path as scanned.
    func rawPath(_ node: UInt32) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = dm_node_path(tree, node, &buffer, buffer.count)
        if length >= buffer.count {
            buffer = [CChar](repeating: 0, count: length + 1)
            dm_node_path(tree, node, &buffer, buffer.count)
        }
        return String(cString: buffer)
    }

    /// The path the way the user knows it: items on the data volume are
    /// reachable through "/" thanks to firmlinks, so drop the volume prefix
    /// whenever that shorter path points at the same thing.
    func path(_ node: UInt32) -> String {
        let raw = rawPath(node)
        guard raw.hasPrefix(dataVolumePath) else { return raw }
        let short = String(raw.dropFirst(dataVolumePath.count))
        if short.isEmpty { return "/" }
        let firmlinked = ["/Users/", "/Applications/", "/Library/", "/private/", "/opt/", "/usr/local/", "/cores/"]
        return firmlinked.contains { short.hasPrefix($0) || short + "/" == $0 } ? short : raw
    }

    func isWithin(_ node: UInt32, _ ancestor: UInt32) -> Bool { dm_is_within(tree, node, ancestor) }

    /// False for a node that was moved to the Trash or replaced by a rescan of
    /// its folder, and for everything that was inside one.
    func isAlive(_ node: UInt32) -> Bool { node != noNode && dm_node_alive(tree, node) }

    /// The names that lead from `ancestor` down to `node`.
    func names(from ancestor: UInt32, to node: UInt32) -> [String] {
        var names: [String] = []
        var n = node
        while n != ancestor && n != noNode {
            let entry = info(n)
            names.append(String(cString: entry.name))
            n = entry.parent
        }
        return names.reversed()
    }

    /// Follows `names` down from `node` for as long as they exist.
    func descendant(of node: UInt32, along names: [String]) -> UInt32 {
        var current = node
        for name in names {
            let count = info(current).child_count
            let next = name.withCString { wanted in
                (0..<count).lazy.map { dm_child_at(self.tree, current, $0) }
                    .first { strcmp(self.info($0).name, wanted) == 0 }
            }
            guard let next else { break }
            current = next
        }
        return current
    }

    /// Root-first chain of ancestors ending at `node`.
    func ancestry(_ node: UInt32) -> [UInt32] {
        var chain: [UInt32] = []
        var n = node
        while n != noNode {
            chain.append(n)
            n = info(n).parent
        }
        return chain.reversed()
    }

    /// Takes a node that the user moved to the Trash off the map.
    func remove(_ node: UInt32) {
        trashedBytes += info(node).size
        forget(node)
    }

    /// Takes a node that is no longer on disk off the map.
    func forget(_ node: UInt32) { dm_remove_node(tree, node) }

    struct Stats {
        var kindBytes: [UInt64]
        var largestFiles: [UInt32]
    }

    func stats(under node: UInt32, top: Int = 200) -> Stats {
        var kinds = [UInt64](repeating: 0, count: Kind.count)
        var files = [UInt32](repeating: 0, count: top)
        var found: UInt32 = 0
        dm_subtree_stats(tree, node, &kinds, &files, UInt32(top), &found)
        return Stats(kindBytes: kinds, largestFiles: Array(files.prefix(Int(found))))
    }

    var deniedPaths: [String] {
        (0..<dm_denied_count(tree)).map { path(dm_denied_at(tree, $0)) }
    }
}

// MARK: - Rescanning one folder

/// A second scan of one folder of a finished scan. Until it is applied or
/// thrown away, nothing else may change the session's tree.
final class FolderRescan {
    let session: ScanSession
    let node: UInt32
    private let tree: OpaquePointer

    /// Nil if the folder cannot be scanned on its own (see dm_rescan_start).
    init?(session: ScanSession, node: UInt32) {
        guard let tree = dm_rescan_start(session.tree, node, 0) else { return nil }
        self.session = session
        self.node = node
        self.tree = tree
    }

    deinit {
        // The rescan reads the session's tree while it runs, so it has to be
        // stopped and freed before the session may go. Off the main thread:
        // freeing waits for the scan threads.
        let tree = self.tree, session = self.session
        DispatchQueue.global(qos: .utility).async {
            dm_tree_free(tree)
            withExtendedLifetime(session) {}
        }
    }

    var progress: dm_progress {
        var p = dm_progress()
        dm_progress_get(tree, &p)
        return p
    }

    func cancel() { dm_scan_cancel(tree) }

    /// Swaps the result into the session. False if there is nothing to swap in.
    func apply() -> Bool {
        let path = session.rawPath(node)
        guard dm_rescan_apply(session.tree, tree) else { return false }
        // If the Trash is in the folder, the scan has now found what was
        // moved there, and the summary must not add it a second time.
        if contains(trashOf: path) { session.trashedBytes = 0 }
        return true
    }

    /// Whether the Trash that files from `path` go to lies in that folder.
    /// Compared by file identity: /Users and /System/Volumes/Data/Users are
    /// the same folder under two names.
    private func contains(trashOf path: String) -> Bool {
        var folder = stat()
        guard stat(path, &folder) == 0,
              var url = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                     appropriateFor: URL(fileURLWithPath: path), create: false)
        else { return false }
        while true {
            var entry = stat()
            if stat(url.path, &entry) == 0, entry.st_dev == folder.st_dev, entry.st_ino == folder.st_ino { return true }
            if url.path == "/" { return false }
            url.deleteLastPathComponent()
        }
    }
}

// MARK: - Full Disk Access

enum Privacy {
    /// Protected by TCC: readable only with Full Disk Access. Probing it never
    /// triggers a prompt.
    static var hasFullDiskAccess: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        return false
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
