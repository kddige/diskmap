import AppKit
import CScan

/// What macOS says about the disk, to set against what a scan found. The gap
/// between the two is the space "you cannot account for".
struct VolumeReport {
    struct Volume {
        var name: String
        var mount: String
        var used: UInt64
    }

    var volumeName = ""
    var mount = ""
    var capacity: UInt64 = 0 // of the whole APFS container
    var free: UInt64 = 0
    var purgeable: UInt64 = 0
    var volumeUsed: UInt64 = 0 // this volume alone
    var siblings: [Volume] = [] // other volumes sharing the container
    var snapshots: Int?

    private struct Mount {
        var mount: String
        var device: String
        var type: String
        var total: UInt64
        var used: UInt64
        var free: UInt64
    }

    private static func mount(from s: statfs) -> Mount {
        var s = s
        let on = withUnsafePointer(to: &s.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let from = withUnsafePointer(to: &s.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let type = withUnsafePointer(to: &s.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        let block = UInt64(s.f_bsize)
        // On APFS every volume reports the container's size and free space, so
        // a volume's own usage has to be asked for separately.
        return Mount(mount: on, device: from, type: type,
                     total: UInt64(s.f_blocks) * block,
                     used: spaceUsed(on) ?? UInt64(s.f_blocks - s.f_bfree) * block,
                     free: UInt64(s.f_bavail) * block)
    }

    /// Bytes this one volume occupies (what `df` prints as "Used").
    private static func spaceUsed(_ mount: String) -> UInt64? {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        var buffer = [UInt8](repeating: 0, count: 16) // u32 length, then u64 bytes used
        guard getattrlist(mount, &list, &buffer, buffer.count, 0) == 0 else { return nil }
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
    }

    /// "disk3s3" for "/dev/disk3s3s1": a snapshot mount belongs to its volume.
    private static func volume(of device: String) -> String {
        let parts = device.dropFirst("/dev/disk".count).split(separator: "s")
        return parts.count >= 2 ? "disk\(parts[0])s\(parts[1])" : device
    }

    /// "disk3" for "/dev/disk3s1s1".
    private static func container(of device: String) -> String? {
        guard device.hasPrefix("/dev/disk") else { return nil }
        let digits = device.dropFirst("/dev/disk".count).prefix { $0.isNumber }
        return digits.isEmpty ? nil : "disk" + digits
    }

    static func make(for path: String) -> VolumeReport? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let own = mount(from: s)
        var report = VolumeReport()
        report.mount = own.mount
        report.capacity = own.total
        report.free = own.free
        report.volumeUsed = own.used

        let url = URL(fileURLWithPath: own.mount)
        let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey])
        report.volumeName = own.mount == dataVolumePath
            ? ((try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? "Macintosh HD")
            : (values?.volumeName ?? own.mount)
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0,
           UInt64(important) > own.free {
            report.purgeable = UInt64(important) - own.free
        }

        if own.type == "apfs", let container = container(of: own.device) {
            var list: UnsafeMutablePointer<statfs>?
            let count = getmntinfo(&list, MNT_NOWAIT)
            var seen: Set<String> = [volume(of: own.device)]
            for i in 0..<Int(max(0, count)) {
                guard let entry = list?[i] else { continue }
                let other = mount(from: entry)
                guard other.type == "apfs", Self.container(of: other.device) == container,
                      seen.insert(volume(of: other.device)).inserted, other.used >= 10_000_000 else { continue }
                let name: String
                switch other.mount {
                case "/": name = "macOS (system volume)"
                case "/System/Volumes/VM": name = "VM (swap and sleep image)"
                case "/System/Volumes/Data": name = "Data"
                default: name = (other.mount as NSString).lastPathComponent
                }
                report.siblings.append(Volume(name: name, mount: other.mount, used: other.used))
            }
            report.siblings.sort { $0.used > $1.used }
        }
        report.snapshots = localSnapshotCount(mount: own.mount)
        return report
    }

    /// Local Time Machine snapshots pin deleted files' blocks until they expire.
    private static func localSnapshotCount(mount: String) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", mount]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        // The list covers the whole volume group; "com.apple.os.update-" ones
        // sit on the sealed system volume and hold none of the user's data.
        return text.split(separator: "\n").filter { $0.hasPrefix("com.apple.TimeMachine.") }.count
    }
}

// MARK: - Sheet

/// "Where is the rest?" - reconciles the scan with what macOS reports.
final class SummarySheet: NSObject {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                                styleMask: [.titled], backing: .buffered, defer: true)
    private weak var parent: NSWindow?
    var onRescan: (() -> Void)?

    private func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor, mono: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11.5)
        field.textColor = .secondaryLabelColor
        field.isSelectable = true
        field.preferredMaxLayoutWidth = 472
        return field
    }

    private func row(_ title: String, _ value: String, emphasized: Bool = false, indent: Bool = false,
                     color: NSColor = .labelColor) -> NSView {
        let left = label(title, weight: emphasized ? .semibold : .regular, color: indent ? .secondaryLabelColor : color)
        let right = label(value, weight: emphasized ? .semibold : .regular, color: indent ? .secondaryLabelColor : color, mono: true)
        right.alignment = .right
        left.lineBreakMode = .byTruncatingMiddle
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [left, spacer, right])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 0, left: indent ? 14 : 0, bottom: 0, right: 0)
        return stack
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    func present(on window: NSWindow, session: ScanSession) {
        parent = window
        let progress = session.progress
        let report = VolumeReport.make(for: session.rootPath)
        let wholeVolume = report.map { $0.mount == session.rootPath || (session.rootPath == "/" && $0.mount == "/") } ?? false
        let scanned = progress.bytes

        var views: [NSView] = []
        views.append(label(session.rootDisplayName, size: 15, weight: .semibold))
        views.append(label(session.path(0), size: 11, color: .secondaryLabelColor))
        views.append(NSView())

        views.append(row("Found by this scan", formatBytes(scanned), emphasized: true))
        views.append(row("in \(formatCount(progress.files)) files and \(formatCount(progress.dirs)) folders", "", indent: true))
        if progress.clone_bytes > 0 {
            views.append(row("\(formatCount(progress.clone_files)) clones share their data, counted once",
                             "−" + formatBytes(progress.clone_bytes), indent: true))
        }
        if session.trashedBytes > 0 {
            views.append(row("Moved to the Trash since", formatBytes(session.trashedBytes), indent: true))
        }

        var notes: [String] = []
        if let report {
            if wholeVolume {
                views.append(row("Used on this volume, says macOS", formatBytes(report.volumeUsed)))
                let found = scanned + session.trashedBytes
                if report.volumeUsed > found {
                    let gap = report.volumeUsed - found
                    views.append(row("Not found by the scan", formatBytes(gap), emphasized: true,
                                     color: gap > report.volumeUsed / 10 ? .systemOrange : .labelColor))
                    if gap > report.volumeUsed / 100 {
                        notes.append("Space that no file accounts for is held by folders the scan was not allowed to read, by local snapshots, and by the file system's own bookkeeping, which grows with the number of files.")
                    }
                } else if found > report.volumeUsed {
                    views.append(row("Counted more than is used", formatBytes(found - report.volumeUsed)))
                    notes.append("Copies that were changed after being cloned still share part of their data with the original, but are counted in full here.")
                }
            }
            views.append(separator())
            views.append(row("Disk capacity", formatBytes(report.capacity)))
            views.append(row(wholeVolume ? "This volume" : "Volume “\(report.volumeName)”", formatBytes(report.volumeUsed), indent: true))
            for sibling in report.siblings {
                views.append(row(sibling.name, formatBytes(sibling.used), indent: true))
            }
            views.append(row("Free", formatBytes(report.free), indent: true))
            if report.purgeable > 0 {
                views.append(row("Purgeable (macOS frees it when needed)", formatBytes(report.purgeable), indent: true))
            }
            if let snapshots = report.snapshots, snapshots > 0 {
                notes.append("\(snapshots) local Time Machine snapshot\(snapshots == 1 ? "" : "s") on this volume. Snapshots keep deleted files on disk until they expire (usually within 24 hours), so freed space can take a while to show up. They are not visible to a file scan.")
            }
        }

        let denied = Int(progress.denied)
        let hasAccess = Privacy.hasFullDiskAccess
        if denied > 0 {
            views.append(separator())
            views.append(row("Folders that could not be read", formatCount(UInt64(denied)), emphasized: true, color: .systemOrange))
            let paths = session.deniedPaths.map {
                $0.hasPrefix(dataVolumePath + "/") ? String($0.dropFirst(dataVolumePath.count)) : $0
            }
            var listing = paths.prefix(8).joined(separator: "\n")
            if paths.count > 8 { listing += "\n… and \(formatCount(UInt64(paths.count - 8))) more" }
            let list = note(listing)
            list.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            list.lineBreakMode = .byTruncatingMiddle
            list.maximumNumberOfLines = 9
            views.append(list)
            notes.append(hasAccess
                ? "The remaining unreadable folders belong to the system or to other users. To include them, run DiskMap as root from Terminal:  sudo DiskMap.app/Contents/MacOS/DiskMap"
                : "DiskMap does not have Full Disk Access, so macOS hides Mail, Messages, Safari, Photos and other apps' data from it. Turn it on in Privacy & Security, then scan again.")
        }
        if progress.cancelled {
            notes.append("This scan was stopped early, so the totals are incomplete.")
        }
        if !notes.isEmpty {
            views.append(separator())
            views.append(contentsOf: notes.map(note))
        }

        // Buttons
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.keyEquivalent = "\r"
        var buttons: [NSView] = []
        if !hasAccess {
            buttons.append(NSButton(title: "Open Privacy Settings…", target: self, action: #selector(openSettings)))
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.append(spacer)
        buttons.append(done)
        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        views.append(NSView())
        views.append(buttonRow)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 18, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views where !(view is NSTextField) {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: 520),
        ])
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        window.beginSheet(panel)
    }

    @objc private func close() {
        parent?.endSheet(panel)
    }

    @objc private func openSettings() {
        Privacy.openFullDiskAccessSettings()
    }
}
