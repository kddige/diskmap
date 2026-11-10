import AppKit
import CScan

// DiskMap [path]                        open the app, optionally scanning `path` right away
// DiskMap --render out.png [path] [--size 1400x900] [--zoom name/name]
//                                       scan and write the treemap to a PNG, no window

var arguments = Array(CommandLine.arguments.dropFirst())
// Launch Services may pass a process serial number.
arguments.removeAll { $0.hasPrefix("-psn") }

func takeOption(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    let value = arguments[i + 1]
    arguments.removeSubrange(i...i + 1)
    return value
}

let renderPath = takeOption("--render")
let snapshotPath = takeOption("--snapshot")
let sizeOption = takeOption("--size")
let zoomOption = takeOption("--zoom")
let startPath = arguments.first { !$0.hasPrefix("-") }

if let renderPath {
    var size = CGSize(width: 1400, height: 900)
    if let parts = sizeOption?.split(separator: "x"), parts.count == 2,
       let w = Double(parts[0]), let h = Double(parts[1]) {
        size = CGSize(width: w, height: h)
    }
    guard let session = ScanSession(path: startPath ?? ".") else {
        FileHandle.standardError.write("cannot scan \(startPath ?? ".")\n".data(using: .utf8)!)
        exit(1)
    }
    dm_scan_wait(session.tree)
    var root: UInt32 = 0
    for component in (zoomOption ?? "").split(separator: "/") {
        let info = session.info(root)
        guard let next = (0..<Int(info.child_count)).lazy.map({ session.child(root, $0) })
            .first(where: { session.name($0) == component }) else { break }
        root = next
    }
    let start = CFAbsoluteTimeGetCurrent()
    guard let frame = MapRenderer.render(session: session, root: root, pointSize: size, scale: 2, highlightKind: -1) else {
        exit(1)
    }
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
    let p = session.progress
    print(String(format: "scanned %@ in %.2fs, rendered %dx%d in %.1f ms",
                 formatBytes(p.bytes), p.elapsed, frame.width, frame.height, elapsed))
    exit(MapRenderer.writePNG(frame.image, to: renderPath) ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate(startPath: startPath, snapshotPath: snapshotPath)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
