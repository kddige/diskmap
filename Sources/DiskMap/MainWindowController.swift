import AppKit
import CScan

private extension NSToolbarItem.Identifier {
    static let scan = NSToolbarItem.Identifier("scan")
    static let rescan = NSToolbarItem.Identifier("rescan")
    static let zoomOut = NSToolbarItem.Identifier("zoomOut")
    static let reveal = NSToolbarItem.Identifier("reveal")
    static let trash = NSToolbarItem.Identifier("trash")
    static let summary = NSToolbarItem.Identifier("summary")
}

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSMenuItemValidation,
    NSToolbarItemValidation, NSMenuDelegate, NSSplitViewDelegate, TreemapViewDelegate {

    /// Test hook: write a picture of the window once the scan is done, then quit.
    var snapshotPath: String?

    private var session: ScanSession?
    private var scanPath: String?
    private var timer: Timer?
    private var ticks = 0
    private var selected: UInt32 = noNode
    private var hovered: UInt32 = noNode
    private var crumbs: [UInt32] = []
    private var statsGeneration = 0
    private var folderRescan: FolderRescan?
    private var rescanTimer: Timer?
    /// What the last rescan of a single folder changed, for the status bar.
    private var rescanNote: String?

    private let treemap = TreemapView()
    private let pathControl = NSPathControl()
    private let legend = LegendView()
    private let folders = FolderTreeController()
    private let largest = LargestFilesController()
    private let sidebarMode = NSSegmentedControl(labels: ["Folders", "Largest Files"], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let sidebarPlaceholder = NSTextField(labelWithString: "")
    private let statusLeft = NSTextField(labelWithString: "")
    private let statusRight = NSTextField(labelWithString: "")
    private let warning = NSButton(title: "", target: nil, action: nil)
    private let welcome = WelcomeView()
    private let split = NSSplitView()
    private let contextMenu = NSMenu()
    private let summarySheet = SummarySheet()

    private var isScanning: Bool { session != nil && timer != nil }
    private var isReady: Bool { session != nil && timer == nil }

    // MARK: Setup

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "DiskMap"
        window.minSize = NSSize(width: 860, height: 520)
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("DiskMapMain")
        super.init(window: window)

        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        buildContent()
        buildContextMenu()
        showWelcome(true)

        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let guide = window!.contentLayoutGuide as! NSLayoutGuide

        // Sidebar
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebarMode.selectedSegment = 0
        sidebarMode.target = self
        sidebarMode.action = #selector(sidebarModeChanged)
        sidebarMode.segmentDistribution = .fillEqually
        sidebarPlaceholder.textColor = .secondaryLabelColor
        sidebarPlaceholder.alignment = .center
        sidebarPlaceholder.font = .systemFont(ofSize: 12)
        largest.scrollView.isHidden = true
        for view in [sidebarMode, folders.scrollView, largest.scrollView, sidebarPlaceholder] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebarMode.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 8),
            sidebarMode.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            sidebarMode.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            sidebarPlaceholder.centerXAnchor.constraint(equalTo: sidebar.centerXAnchor),
            sidebarPlaceholder.centerYAnchor.constraint(equalTo: sidebar.centerYAnchor),
            sidebarPlaceholder.widthAnchor.constraint(lessThanOrEqualTo: sidebar.widthAnchor, constant: -24),
        ])
        for scroll in [folders.scrollView, largest.scrollView] {
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: sidebarMode.bottomAnchor, constant: 8),
                scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            ])
        }
        folders.onSelect = { [weak self] node in self?.select(node, from: .folders) }
        largest.onSelect = { [weak self] node in self?.select(node, from: .largest) }

        // Map side
        let main = NSView()
        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        pathControl.target = self
        pathControl.action = #selector(crumbClicked)
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: 11.5)
        treemap.delegate = self
        legend.onToggle = { [weak self] kind in
            self?.legend.highlighted = kind
            self?.treemap.highlightKind = kind
        }
        for view in [pathControl, treemap, legend] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            main.addSubview(view)
        }
        NSLayoutConstraint.activate([
            pathControl.topAnchor.constraint(equalTo: main.topAnchor, constant: 4),
            pathControl.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 8),
            pathControl.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -8),
            pathControl.heightAnchor.constraint(equalToConstant: 22),
            treemap.topAnchor.constraint(equalTo: pathControl.bottomAnchor, constant: 4),
            treemap.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            treemap.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            legend.topAnchor.constraint(equalTo: treemap.bottomAnchor),
            legend.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            legend.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            legend.bottomAnchor.constraint(equalTo: main.bottomAnchor),
            legend.heightAnchor.constraint(equalToConstant: 30),
        ])

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(main)
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        // Status bar
        let status = NSView()
        let line = NSBox()
        line.boxType = .separator
        statusLeft.font = .systemFont(ofSize: 11.5)
        statusLeft.lineBreakMode = .byTruncatingMiddle
        statusLeft.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusRight.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        statusRight.textColor = .secondaryLabelColor
        statusRight.alignment = .right
        statusRight.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusRight.setContentHuggingPriority(.required, for: .horizontal)
        warning.bezelStyle = .inline
        warning.controlSize = .small
        warning.target = self
        warning.action = #selector(showSummary(_:))
        warning.contentTintColor = .systemOrange
        warning.isHidden = true
        warning.setContentCompressionResistancePriority(.required, for: .horizontal)
        warning.setContentHuggingPriority(.required, for: .horizontal)
        for view in [line, statusLeft, warning, statusRight] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            status.addSubview(view)
        }
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: status.topAnchor),
            line.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            statusLeft.leadingAnchor.constraint(equalTo: status.leadingAnchor, constant: 10),
            statusLeft.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            warning.leadingAnchor.constraint(greaterThanOrEqualTo: statusLeft.trailingAnchor, constant: 12),
            warning.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            statusRight.leadingAnchor.constraint(equalTo: warning.trailingAnchor, constant: 10),
            statusRight.trailingAnchor.constraint(equalTo: status.trailingAnchor, constant: -10),
            statusRight.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            status.heightAnchor.constraint(equalToConstant: 25),
        ])

        welcome.controller = self
        for view in [split, status, welcome] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: guide.topAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            welcome.topAnchor.constraint(equalTo: guide.topAnchor),
            welcome.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            welcome.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            welcome.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            main.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
        // The divider can only be placed once the split view has a size.
        content.layoutSubtreeIfNeeded()
        split.setPosition(320, ofDividerAt: 0)
        split.autosaveName = "DiskMapSidebar"
    }

    private func buildContextMenu() {
        contextMenu.delegate = self
        contextMenu.autoenablesItems = true
        contextMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "")
        contextMenu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "")
        contextMenu.addItem(withTitle: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "")
        contextMenu.addItem(withTitle: "Rescan Folder", action: #selector(rescanFolder(_:)), keyEquivalent: "")
        contextMenu.addItem(.separator())
        contextMenu.addItem(withTitle: "Move to Trash…", action: #selector(moveToTrash(_:)), keyEquivalent: "")
        for item in contextMenu.items { item.target = self }
        folders.outline.menu = contextMenu
        largest.table.menu = contextMenu
    }

    /// A right-click in a list acts on the row under the pointer.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let event = NSApp.currentEvent, let view = window?.contentView?.hitTest(event.locationInWindow) else { return }
        if view.isDescendant(of: folders.outline), folders.clickedNode != noNode {
            select(folders.clickedNode, from: .other)
        } else if view.isDescendant(of: largest.table), largest.clickedNode != noNode {
            select(largest.clickedNode, from: .other)
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, 560)
    }

    private func showWelcome(_ show: Bool) {
        welcome.isHidden = !show
        split.isHidden = show
        if show {
            welcome.refresh()
            window?.subtitle = ""
        }
    }

    @objc private func appBecameActive() {
        welcome.refresh()
    }

    // MARK: Scanning

    func startScan(path: String) {
        timer?.invalidate()
        timer = nil
        dropFolderRescan()
        session?.cancel()
        guard let session = ScanSession(path: path) else {
            let alert = NSAlert()
            alert.messageText = "Could not open “\(path)”."
            alert.informativeText = "The folder does not exist or cannot be read."
            if let window { alert.beginSheetModal(for: window) }
            return
        }
        self.session = session
        scanPath = path
        selected = noNode
        hovered = noNode
        rescanNote = nil
        statsGeneration += 1
        showWelcome(false)
        window?.title = session.rootDisplayName
        window?.subtitle = "Scanning…"
        warning.isHidden = true
        legend.entries = []
        legend.highlighted = -1
        treemap.highlightKind = -1
        treemap.setSession(session)
        folders.setSession(nil)
        largest.set(session: nil, files: [])
        sidebarPlaceholder.stringValue = "Folders appear here\nwhen the scan finishes."
        sidebarPlaceholder.isHidden = false
        updateCrumbs()
        ticks = 0
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
        window?.toolbar?.validateVisibleItems()
    }

    private func tick() {
        guard let session else { return }
        let progress = session.progress
        ticks += 1
        if progress.state == DM_STATE_DONE {
            finishScan()
            return
        }
        statusRight.stringValue = "Scanning…  \(formatCount(progress.files)) files  ·  \(formatBytes(progress.bytes))  ·  \(Int(progress.elapsed)) s"
        window?.subtitle = "Scanning… \(formatBytes(progress.bytes))"
        // The map fills in live, a few times a second.
        if ticks % 4 == 1 { treemap.reload() }
        updateStatus()
    }

    private func finishScan() {
        timer?.invalidate()
        timer = nil
        guard let session else { return }
        treemap.reload()
        folders.setSession(session)
        sidebarPlaceholder.isHidden = true
        refreshStats()
        updateSummaryLine()
        updateWarning()
        updateStatus()
        window?.toolbar?.validateVisibleItems()

        if let snapshotPath {
            // Give the last render and the lists a moment to land.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // Test hook: rescan this folder first; the picture follows.
                if let folder = ProcessInfo.processInfo.environment["DISKMAP_SNAPSHOT_RESCAN"] {
                    let names = folder.dropFirst(session.rootPath.count).split(separator: "/").map(String.init)
                    self.select(session.descendant(of: 0, along: names), from: .other)
                    self.rescanFolder(nil)
                    if self.folderRescan != nil { return }
                }
                self.writeSnapshot(to: snapshotPath)
            }
        }
    }

    private func updateWarning() {
        let denied = session?.progress.denied ?? 0
        warning.title = "  \(formatCount(denied)) unreadable folder\(denied == 1 ? "" : "s")  "
        warning.isHidden = denied == 0
    }

    private func updateSummaryLine() {
        guard let session else { return }
        let progress = session.progress
        let total = session.info(0).size
        let time = String(format: "%.1f s", locale: Locale.current, progress.elapsed)
        statusRight.stringValue = "\(formatBytes(total)) in \(formatCount(UInt64(session.info(0).file_count))) files  ·  "
            + (rescanNote ?? (progress.cancelled ? "stopped after \(time)" : "scanned in \(time)"))
        window?.subtitle = progress.cancelled ? "\(formatBytes(total)) (incomplete)" : formatBytes(total)
    }

    /// Kind totals and biggest files for the folder on the map.
    private func refreshStats() {
        guard let session, isReady else { return }
        statsGeneration += 1
        let generation = statsGeneration
        let root = treemap.root
        DispatchQueue.global(qos: .userInitiated).async {
            let stats = session.stats(under: root)
            DispatchQueue.main.async {
                guard generation == self.statsGeneration else { return }
                self.largest.set(session: session, files: stats.largestFiles)
                self.largest.reveal(self.selected)
                self.legend.entries = stats.kindBytes.enumerated()
                    .map { (kind: $0.offset, bytes: $0.element) }
                    .sorted { $0.bytes > $1.bytes }
            }
        }
    }

    // MARK: Selection, hover, zoom

    private enum Source { case map, folders, largest, other }

    private func select(_ node: UInt32, from source: Source) {
        guard let session else { return }
        // The map and the lists can still show something for a moment after
        // it went away; a click on that selects nothing.
        let node = session.isAlive(node) ? node : noNode
        selected = node
        treemap.selected = node
        if isReady {
            if source != .folders { folders.reveal(node) }
            if source != .largest { largest.reveal(node) }
        }
        updateStatus()
        window?.toolbar?.validateVisibleItems()
    }

    private func updateStatus() {
        guard let session else {
            statusLeft.stringValue = ""
            return
        }
        let node = hovered != noNode ? hovered : selected
        guard node != noNode else {
            statusLeft.stringValue = isScanning ? "" : "Hover the map to inspect. Double-click a folder to zoom in, Esc to go back."
            statusLeft.textColor = .tertiaryLabelColor
            return
        }
        let info = session.info(node)
        var text = "\(session.path(node))   —   \(formatBytes(info.size))"
        if info.flags & UInt8(DM_F_DIR) != 0 { text += ", \(formatItems(UInt64(info.file_count)))" }
        if info.flags & UInt8(DM_F_UNREADABLE) != 0 { text += "  (unreadable)" }
        if info.flags & UInt8(DM_F_CLONE) != 0 { text += "  (clone: its data is counted on the file it was copied from)" }
        if info.flags & UInt8(DM_F_HARDLINK) != 0 { text += "  (hard link: counted once, elsewhere)" }
        statusLeft.stringValue = text
        statusLeft.textColor = .labelColor
    }

    private func zoom(to node: UInt32) {
        guard let session, node != noNode, session.isDirectory(node), node != treemap.root else { return }
        treemap.zoom(to: node)
        updateCrumbs()
        refreshStats()
        window?.toolbar?.validateVisibleItems()
    }

    private func updateCrumbs() {
        guard let session else {
            pathControl.pathItems = []
            crumbs = []
            return
        }
        crumbs = session.ancestry(treemap.root)
        pathControl.pathItems = crumbs.map { node in
            let item = NSPathControlItem()
            item.title = session.name(node)
            item.image = Self.crumbIcon(node == 0 ? "internaldrive.fill" : "folder.fill")
            return item
        }
    }

    /// A symbol centred in a square image. The path bar stretches whatever it
    /// is given to a square, which squeezes symbols that are wider than tall.
    private static func crumbIcon(_ name: String) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)) else { return nil }
        let side: CGFloat = 16
        let icon = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let scale = min(1, side / max(symbol.size.width, symbol.size.height))
            let width = symbol.size.width * scale, height = symbol.size.height * scale
            symbol.draw(in: NSRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))
            return true
        }
        icon.isTemplate = true
        return icon
    }

    @objc private func crumbClicked() {
        guard let item = pathControl.clickedPathItem, let index = pathControl.pathItems.firstIndex(of: item),
              index < crumbs.count else { return }
        zoom(to: crumbs[index])
    }

    @objc private func sidebarModeChanged() {
        let showFolders = sidebarMode.selectedSegment == 0
        folders.scrollView.isHidden = !showFolders
        largest.scrollView.isHidden = showFolders
    }

    // MARK: TreemapViewDelegate

    func treemap(_ view: TreemapView, didHover node: UInt32) {
        hovered = session?.isAlive(node) == true ? node : noNode
        updateStatus()
    }

    func treemap(_ view: TreemapView, didSelect node: UInt32) { select(node, from: .map) }
    func treemap(_ view: TreemapView, wantsZoomTo node: UInt32) {
        if session?.isAlive(node) == true { zoom(to: node) }
    }
    func treemapWantsZoomOut(_ view: TreemapView) { zoomOut(nil) }
    func treemapContextMenu(_ view: TreemapView) -> NSMenu? { contextMenu }

    // MARK: Actions

    @objc func scanDataVolume(_ sender: Any?) {
        startScan(path: FileManager.default.fileExists(atPath: dataVolumePath) ? dataVolumePath : "/")
    }

    @objc func scanHome(_ sender: Any?) { startScan(path: NSHomeDirectory()) }

    @objc func chooseFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or disk to scan"
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { self.startScan(path: url.path) }
        }
    }

    @objc func rescanOrStop(_ sender: Any?) {
        if let folderRescan {
            folderRescan.cancel()
        } else if isScanning {
            session?.cancel()
        } else if let scanPath {
            startScan(path: scanPath)
        }
    }

    // MARK: Rescanning one folder

    /// The folder "Rescan Folder" would scan: the selected folder, the folder
    /// the selected file is in, or with nothing selected the one on the map.
    private var rescanTarget: UInt32 {
        guard let session, isReady else { return noNode }
        let node = selected != noNode ? selected : treemap.root
        return session.isDirectory(node) ? node : session.parent(node)
    }

    @objc func rescanFolder(_ sender: Any?) {
        guard let session, let window, isReady, folderRescan == nil, window.attachedSheet == nil else { return }
        let node = rescanTarget
        guard node != noNode else { return }
        if node == 0 {
            // The top folder is the whole scan.
            rescanOrStop(nil)
            return
        }
        guard let rescan = FolderRescan(session: session, node: node) else {
            let alert = NSAlert()
            let name = session.name(node)
            if FileManager.default.fileExists(atPath: session.rawPath(node)) {
                alert.messageText = "“\(name)” cannot be rescanned on its own."
                alert.informativeText = "To bring the whole map up to date, choose File > Rescan."
            } else {
                alert.messageText = "“\(name)” is no longer there."
                alert.informativeText = "It was deleted or moved after the scan, so it has been taken off the map."
                didRemove(node, trashed: false)
            }
            alert.beginSheetModal(for: window)
            return
        }
        folderRescan = rescan
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.folderRescanTick() }
        RunLoop.main.add(timer, forMode: .common)
        rescanTimer = timer
        folderRescanTick()
        window.toolbar?.validateVisibleItems()
    }

    private func folderRescanTick() {
        guard let rescan = folderRescan else { return }
        let progress = rescan.progress
        if progress.state == DM_STATE_DONE {
            finishFolderRescan()
            return
        }
        statusRight.stringValue = "Rescanning “\(rescan.session.name(rescan.node))”…  \(formatCount(progress.files)) files  ·  \(formatBytes(progress.bytes))  ·  \(Int(progress.elapsed)) s"
    }

    /// Stops a folder rescan and throws its result away.
    private func dropFolderRescan() {
        rescanTimer?.invalidate()
        rescanTimer = nil
        folderRescan?.cancel()
        folderRescan = nil
    }

    private func finishFolderRescan() {
        guard let rescan = folderRescan, let session, rescan.session === session else {
            dropFolderRescan()
            return
        }
        rescanTimer?.invalidate()
        rescanTimer = nil
        folderRescan = nil
        defer { window?.toolbar?.validateVisibleItems() }

        let node = rescan.node
        // Everything inside the folder gets a new id. Remember by name where
        // the selection and the map were, to find the same places afterwards.
        let selection = selected != noNode && session.isWithin(selected, node)
            ? session.names(from: node, to: selected) : nil
        let zoom = session.isWithin(treemap.root, node) ? session.names(from: node, to: treemap.root) : []
        let before = session.info(node).size

        // Stopped by the user: the map stays as it was.
        guard !rescan.progress.cancelled, rescan.apply() else {
            updateSummaryLine()
            return
        }
        let after = session.info(node).size
        let change = after == before ? "no change in size"
            : after > before ? "\(formatBytes(after - before)) larger" : "\(formatBytes(before - after)) smaller"
        rescanNote = "“\(session.name(node))” rescanned: \(change)"

        hovered = noNode
        if zoom.isEmpty {
            treemap.reload()
        } else {
            // Back to the folder the map was showing, or as close as still exists.
            var target = session.descendant(of: node, along: zoom)
            while target != node && (!session.isDirectory(target) || session.info(target).child_count == 0) {
                target = session.parent(target)
            }
            treemap.zoom(to: target)
            updateCrumbs()
        }
        folders.reload()
        if let selection {
            select(session.descendant(of: node, along: selection), from: .other)
        } else {
            updateStatus()
        }
        refreshStats()
        updateSummaryLine()
        updateWarning()

        if let snapshotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.writeSnapshot(to: snapshotPath) }
        }
    }

    @objc func zoomIn(_ sender: Any?) {
        guard let session, selected != noNode else { return }
        zoom(to: session.isDirectory(selected) ? selected : session.parent(selected))
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let session, treemap.root != 0 else { return }
        let parent = session.parent(treemap.root)
        if parent != noNode { zoom(to: parent) }
    }

    @objc func zoomToRoot(_ sender: Any?) { zoom(to: 0) }

    @objc func revealInFinder(_ sender: Any?) {
        guard let session, selected != noNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.path(selected))])
    }

    @objc func copyPath(_ sender: Any?) {
        guard let session, selected != noNode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.path(selected), forType: .string)
    }

    @objc func showSummary(_ sender: Any?) {
        guard let session, let window, isReady else { return }
        summarySheet.present(on: window, session: session)
    }

    @objc func openPrivacySettings(_ sender: Any?) { Privacy.openFullDiskAccessSettings() }

    @objc func moveToTrash(_ sender: Any?) {
        guard let session, let window, isReady, folderRescan == nil, selected != noNode, selected != 0 else { return }
        let node = selected
        let info = session.info(node)
        let isDir = info.flags & UInt8(DM_F_DIR) != 0
        let alert = NSAlert()
        alert.messageText = "Move “\(session.name(node))” to the Trash?"
        alert.informativeText = "\(session.path(node))\n\n\(formatBytes(info.size))"
            + (isDir ? " in \(formatItems(UInt64(info.file_count)))" : "")
            + ". The space is freed once you empty the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: session.rawPath(node)), resultingItemURL: nil)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
                return
            }
            self.didRemove(node, trashed: true)
        }
    }

    /// Takes `node` off the map: it went to the Trash, or it turned out to be gone.
    private func didRemove(_ node: UInt32, trashed: Bool) {
        guard let session else { return }
        let parent = session.parent(node)
        let zoomedInside = session.isWithin(treemap.root, node)
        if trashed { session.remove(node) } else { session.forget(node) }
        hovered = noNode
        if zoomedInside {
            treemap.zoom(to: parent)
            updateCrumbs()
        } else {
            treemap.reload()
        }
        folders.reload()
        select(parent, from: .other)
        refreshStats()
        updateSummaryLine()
        updateWarning()
    }

    // MARK: Validation

    private func isEnabled(_ action: Selector?) -> Bool {
        switch action {
        case #selector(rescanOrStop(_:)): return scanPath != nil
        case #selector(zoomOut(_:)), #selector(zoomToRoot(_:)): return session != nil && treemap.root != 0
        case #selector(zoomIn(_:)):
            guard let session, selected != noNode else { return false }
            let target = session.isDirectory(selected) ? selected : session.parent(selected)
            return target != noNode && target != treemap.root && session.info(target).child_count > 0
        case #selector(revealInFinder(_:)), #selector(copyPath(_:)): return session != nil && selected != noNode
        // Not while a folder is being rescanned: its result is swapped into the map as it was.
        case #selector(moveToTrash(_:)): return isReady && folderRescan == nil && selected != noNode && selected != 0
        case #selector(rescanFolder(_:)):
            guard let session, folderRescan == nil, rescanTarget != noNode else { return false }
            // Other disks and cloud-only folders are not looked inside.
            return session.info(rescanTarget).flags & UInt8(DM_F_MOUNT | DM_F_DATALESS) == 0
        case #selector(showSummary(_:)): return isReady
        default: return true
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(rescanOrStop(_:)) {
            menuItem.title = isScanning || folderRescan != nil ? "Stop Scan" : "Rescan"
        }
        if menuItem.action == #selector(rescanFolder(_:)) {
            // Says which folder: with a file selected it is the folder around it.
            let node = rescanTarget
            menuItem.title = node == noNode ? "Rescan Folder" : "Rescan “\(session?.name(node) ?? "")”"
        }
        return isEnabled(menuItem.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == .rescan {
            let busy = isScanning || folderRescan != nil
            item.image = NSImage(systemSymbolName: busy ? "stop.fill" : "arrow.clockwise", accessibilityDescription: nil)
            item.label = busy ? "Stop" : "Rescan"
            item.toolTip = busy ? "Stop scanning" : "Scan everything again"
        }
        return isEnabled(item.action)
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.scan, .rescan, .space, .zoomOut, .reveal, .trash, .flexibleSpace, .summary]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func item(_ label: String, _ symbolName: String, _ action: Selector, _ tip: String) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.toolTip = tip
            item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
            item.target = self
            item.action = action
            item.isBordered = true
            return item
        }
        switch id {
        case .scan:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Scan"
            item.toolTip = "Choose what to scan"
            item.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "Scan")
            item.showsIndicator = true
            let menu = NSMenu()
            menu.addItem(withTitle: "Macintosh HD", action: #selector(scanDataVolume(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Home Folder", action: #selector(scanHome(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Choose Folder…", action: #selector(chooseFolder(_:)), keyEquivalent: "")
            for entry in menu.items { entry.target = self }
            item.menu = menu
            return item
        case .rescan: return item("Rescan", "arrow.clockwise", #selector(rescanOrStop(_:)), "Scan everything again")
        case .zoomOut: return item("Zoom Out", "arrow.up.left.and.arrow.down.right", #selector(zoomOut(_:)), "Back to the enclosing folder (Esc)")
        case .reveal: return item("Reveal", "magnifyingglass", #selector(revealInFinder(_:)), "Reveal the selection in Finder")
        case .trash: return item("Trash", "trash", #selector(moveToTrash(_:)), "Move the selection to the Trash")
        case .summary: return item("Disk Summary", "chart.bar.doc.horizontal", #selector(showSummary(_:)), "Compare the scan with what macOS reports as used")
        default: return nil
        }
    }

    // MARK: Snapshot (test hook)

    func writeSnapshot(to path: String) {
        // Exercise selection the way a click would.
        if let session, selected == noNode, let biggest = session.stats(under: 0, top: 1).largestFiles.first {
            select(biggest, from: .other)
        }
        if ProcessInfo.processInfo.environment["DISKMAP_SNAPSHOT_SUMMARY"] != nil { showSummary(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let window = self.window else { exit(1) }
            let target = window.attachedSheet ?? window
            guard let view = target.contentView?.superview ?? target.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            let ok = (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) != nil
            exit(ok ? 0 : 1)
        }
    }
}

// MARK: - Welcome

/// What you see before the first scan: three ways to start, and whether the
/// app is allowed to see everything.
final class WelcomeView: NSView {
    weak var controller: MainWindowController?
    private let volume = NSTextField(labelWithString: "")
    private let accessIcon = NSImageView()
    private let accessText = NSTextField(wrappingLabelWithString: "")
    private let accessButton = NSButton(title: "Open Privacy Settings…", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "square.grid.3x3.topleft.filled", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        icon.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "DiskMap")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        let tagline = NSTextField(labelWithString: "See what is filling your disk.")
        tagline.font = .systemFont(ofSize: 14)
        tagline.textColor = .secondaryLabelColor
        volume.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        volume.textColor = .secondaryLabelColor

        let scanDisk = NSButton(title: "Scan Macintosh HD", target: nil, action: #selector(MainWindowController.scanDataVolume(_:)))
        scanDisk.controlSize = .large
        scanDisk.keyEquivalent = "\r"
        let scanHome = NSButton(title: "Scan Home Folder", target: nil, action: #selector(MainWindowController.scanHome(_:)))
        scanHome.controlSize = .large
        let choose = NSButton(title: "Choose Folder…", target: nil, action: #selector(MainWindowController.chooseFolder(_:)))
        choose.controlSize = .large
        let buttons = NSStackView(views: [scanDisk, scanHome, choose])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        accessText.font = .systemFont(ofSize: 12)
        accessText.textColor = .secondaryLabelColor
        accessText.preferredMaxLayoutWidth = 430
        accessButton.action = #selector(MainWindowController.openPrivacySettings(_:))
        accessButton.controlSize = .small
        let access = NSStackView(views: [accessIcon, accessText])
        access.orientation = .horizontal
        access.alignment = .top
        access.spacing = 8

        let stack = NSStackView(views: [icon, title, tagline, volume, buttons, access, accessButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(22, after: volume)
        stack.setCustomSpacing(30, after: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    func refresh() {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        if let total = values?.volumeTotalCapacity, let free = values?.volumeAvailableCapacity, total > 0 {
            volume.stringValue = "\(values?.volumeName ?? "Macintosh HD"):  \(formatBytes(UInt64(total - free))) used of \(formatBytes(UInt64(total)))  ·  \(formatBytes(UInt64(free))) free"
        }
        let granted = Privacy.hasFullDiskAccess
        accessIcon.image = NSImage(systemSymbolName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                   accessibilityDescription: nil)
        accessIcon.contentTintColor = granted ? .systemGreen : .systemOrange
        accessText.stringValue = granted
            ? "Full Disk Access is on. DiskMap can see every folder you can."
            : "Full Disk Access is off. macOS will hide Mail, Messages, Safari, Photos and other apps' data, and ask before each of Desktop, Documents and Downloads. For the whole picture, turn it on for DiskMap under Privacy & Security, then come back."
        accessButton.isHidden = granted
    }
}
