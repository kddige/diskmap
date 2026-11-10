import AppKit
import CScan

// MARK: - Shared cells

private func symbol(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)
}

/// Icon for a row: folders get a glyph, files the color of their kind (the
/// same color they have on the map).
func rowIcon(for info: dm_node_info) -> (image: NSImage?, tint: NSColor?) {
    let flags = Int32(info.flags)
    if flags & DM_F_DIR == 0 { return (Kind.swatch(Int(info.kind)), nil) }
    if flags & DM_F_UNREADABLE != 0 { return (symbol("lock.fill"), .systemOrange) }
    if flags & DM_F_MOUNT != 0 { return (symbol("externaldrive.fill"), .secondaryLabelColor) }
    if flags & DM_F_DATALESS != 0 { return (symbol("icloud"), .secondaryLabelColor) }
    return (symbol("folder.fill"), NSColor(srgbRed: 0.42, green: 0.66, blue: 0.94, alpha: 1))
}

/// Size, right aligned, over a bar showing the share of the enclosing folder.
final class SizeCell: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }

    private static let attributes: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        return [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style]
    }()

    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: 0, y: (bounds.height - 16) / 2, width: bounds.width - 4, height: 16)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
        if fraction > 0 {
            var fill = bar
            fill.size.width = max(3, bar.width * min(1, fraction))
            NSColor.controlAccentColor.withAlphaComponent(0.42).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
        }
        let size = (text as NSString).size(withAttributes: Self.attributes)
        (text as NSString).draw(in: NSRect(x: bar.minX, y: bar.midY - size.height / 2, width: bar.width - 5, height: size.height),
                                withAttributes: Self.attributes)
    }
}

private func makeNameCell(in table: NSTableView) -> NSTableCellView {
    let id = NSUserInterfaceItemIdentifier("name")
    if let cell = table.makeView(withIdentifier: id, owner: nil) as? NSTableCellView { return cell }
    let cell = NSTableCellView()
    cell.identifier = id
    let image = NSImageView()
    let text = NSTextField(labelWithString: "")
    text.lineBreakMode = .byTruncatingMiddle
    text.font = .systemFont(ofSize: 12)
    for view in [image, text] as [NSView] {
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
    }
    cell.imageView = image
    cell.textField = text
    NSLayoutConstraint.activate([
        image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 1),
        image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        image.widthAnchor.constraint(equalToConstant: 16),
        image.heightAnchor.constraint(equalToConstant: 16),
        text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
        text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
}

private func makeSizeCell(in table: NSTableView) -> SizeCell {
    let id = NSUserInterfaceItemIdentifier("size")
    if let cell = table.makeView(withIdentifier: id, owner: nil) as? SizeCell { return cell }
    let cell = SizeCell()
    cell.identifier = id
    return cell
}

private func makeScrollView(for table: NSTableView) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.automaticallyAdjustsContentInsets = false
    return scroll
}

// MARK: - Folder tree

final class NodeItem: NSObject {
    let node: UInt32 // for a "more" row: the folder whose tail it stands for
    let isMore: Bool
    init(node: UInt32, isMore: Bool = false) {
        self.node = node
        self.isMore = isMore
    }
}

/// The scanned tree as an outline, biggest first.
final class FolderTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Rows shown per folder; the tail is summarized in one row. Keeps a folder
    /// with half a million files from becoming half a million rows.
    static let cap = 300

    let outline = NSOutlineView()
    private(set) lazy var scrollView = makeScrollView(for: outline)
    var onSelect: ((UInt32) -> Void)?

    private var session: ScanSession?
    private var items: [UInt32: NodeItem] = [:]
    private var moreItems: [UInt32: NodeItem] = [:]
    private var syncing = false

    override init() {
        super.init()
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.resizingMask = .autoresizingMask
        name.minWidth = 100
        let size = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        size.resizingMask = []
        size.width = 82
        outline.addTableColumn(name)
        outline.addTableColumn(size)
        outline.outlineTableColumn = name
        outline.headerView = nil
        outline.rowHeight = 22
        outline.indentationPerLevel = 13
        outline.style = .fullWidth
        outline.backgroundColor = .clear
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.autoresizesOutlineColumn = false
        outline.allowsEmptySelection = true
        outline.dataSource = self
        outline.delegate = self
    }

    func setSession(_ session: ScanSession?) {
        self.session = session
        items.removeAll()
        moreItems.removeAll()
        outline.reloadData()
        if session != nil { outline.expandItem(item(0)) }
    }

    /// Re-reads sizes and order, keeping what is expanded.
    func reload() {
        if let session {
            items = items.filter { session.isAlive($0.key) }
            moreItems = moreItems.filter { session.isAlive($0.key) }
        }
        outline.reloadData()
    }

    private func item(_ node: UInt32) -> NodeItem {
        if let existing = items[node] { return existing }
        let created = NodeItem(node: node)
        items[node] = created
        return created
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let session else { return 0 }
        guard let item = item as? NodeItem else { return 1 }
        if item.isMore { return 0 }
        let count = Int(session.info(item.node).child_count)
        return count > Self.cap ? Self.cap + 1 : count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let session, let item = item as? NodeItem else { return self.item(0) }
        if index >= Self.cap {
            if let more = moreItems[item.node] { return more }
            let more = NodeItem(node: item.node, isMore: true)
            moreItems[item.node] = more
            return more
        }
        return self.item(session.child(item.node, index))
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let session, let item = item as? NodeItem, !item.isMore else { return false }
        let info = session.info(item.node)
        return info.flags & UInt8(DM_F_DIR) != 0 && info.child_count > 0
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let session, let item = item as? NodeItem, let column = tableColumn else { return nil }
        let info = session.info(item.node)

        if item.isMore {
            // Everything past the cap, as one line.
            var shown: UInt64 = 0
            for i in 0..<Self.cap { shown += session.info(session.child(item.node, i)).size }
            let rest = info.size > shown ? info.size - shown : 0
            if column.identifier.rawValue == "name" {
                let cell = makeNameCell(in: outlineView)
                cell.imageView?.image = symbol("ellipsis")
                cell.imageView?.contentTintColor = .tertiaryLabelColor
                cell.textField?.stringValue = "\(formatCount(UInt64(Int(info.child_count) - Self.cap))) smaller items"
                cell.textField?.textColor = .secondaryLabelColor
                return cell
            }
            let cell = makeSizeCell(in: outlineView)
            cell.text = formatBytes(rest)
            cell.fraction = info.size > 0 ? CGFloat(Double(rest) / Double(info.size)) : 0
            return cell
        }

        if column.identifier.rawValue == "name" {
            let cell = makeNameCell(in: outlineView)
            let icon = rowIcon(for: info)
            cell.imageView?.image = icon.image
            cell.imageView?.contentTintColor = icon.tint
            cell.textField?.stringValue = session.name(item.node)
            cell.textField?.textColor = info.flags & UInt8(DM_F_UNREADABLE) != 0 ? .secondaryLabelColor : .labelColor
            cell.toolTip = session.path(item.node)
            return cell
        }
        let cell = makeSizeCell(in: outlineView)
        cell.text = formatBytes(info.size)
        let parentSize = info.parent != noNode ? session.info(info.parent).size : info.size
        cell.fraction = parentSize > 0 ? CGFloat(Double(info.size) / Double(parentSize)) : 0
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !((item as? NodeItem)?.isMore ?? true)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let item = outline.item(atRow: outline.selectedRow) as? NodeItem else { return }
        onSelect?(item.node)
    }

    /// Node of the row that was right-clicked, if any.
    var clickedNode: UInt32 {
        guard outline.clickedRow >= 0, let item = outline.item(atRow: outline.clickedRow) as? NodeItem,
              !item.isMore else { return noNode }
        return item.node
    }

    /// Expands down to `node` and selects it. A node hidden in the tail of a
    /// huge folder selects that folder instead.
    func reveal(_ node: UInt32) {
        guard let session, node != noNode else {
            syncing = true
            outline.deselectAll(nil)
            syncing = false
            return
        }
        var target = item(0)
        for n in session.ancestry(node).dropFirst() {
            let parent = session.parent(n)
            let shown = min(Int(session.info(parent).child_count), Self.cap)
            guard (0..<shown).contains(where: { session.child(parent, $0) == n }) else { break }
            outline.expandItem(target)
            target = item(n)
        }
        let row = outline.row(forItem: target)
        guard row >= 0 else { return }
        syncing = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        syncing = false
        outline.scrollRowToVisible(row)
    }
}

// MARK: - Largest files

private final class FileCell: NSTableCellView {
    let name = NSTextField(labelWithString: "")
    let location = NSTextField(labelWithString: "")
    let size = NSTextField(labelWithString: "")
    let icon = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        location.font = .systemFont(ofSize: 10.5)
        location.textColor = .secondaryLabelColor
        location.lineBreakMode = .byTruncatingHead
        size.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        size.alignment = .right
        size.setContentCompressionResistancePriority(.required, for: .horizontal)
        size.setContentHuggingPriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        location.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [icon, name, location, size] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            size.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            size.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            size.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            location.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            location.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            location.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The biggest individual files under the folder the map is showing.
final class LargestFilesController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    private(set) lazy var scrollView = makeScrollView(for: table)
    var onSelect: ((UInt32) -> Void)?

    private var session: ScanSession?
    private var files: [UInt32] = []
    private var syncing = false

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 38
        table.style = .fullWidth
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
    }

    func set(session: ScanSession?, files: [UInt32]) {
        self.session = session
        self.files = files
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let session, row < files.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("file")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? FileCell ?? {
            let cell = FileCell()
            cell.identifier = id
            return cell
        }()
        let node = files[row]
        let info = session.info(node)
        cell.icon.image = Kind.swatch(Int(info.kind))
        cell.name.stringValue = session.name(node)
        cell.location.stringValue = info.parent != noNode ? session.path(info.parent) : ""
        cell.size.stringValue = formatBytes(info.size)
        cell.toolTip = session.path(node)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, table.selectedRow >= 0, table.selectedRow < files.count else { return }
        onSelect?(files[table.selectedRow])
    }

    var clickedNode: UInt32 {
        table.clickedRow >= 0 && table.clickedRow < files.count ? files[table.clickedRow] : noNode
    }

    func reveal(_ node: UInt32) {
        syncing = true
        if let row = files.firstIndex(of: node) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
        syncing = false
    }
}

// MARK: - Legend

/// What the colors mean, with totals for the folder the map is showing. Click
/// a kind to make it stand out on the map.
final class LegendView: NSView {
    var entries: [(kind: Int, bytes: UInt64)] = [] { didSet { needsDisplay = true } }
    var highlighted: Int32 = -1 { didSet { needsDisplay = true } }
    var onToggle: ((Int32) -> Void)?

    private var chips: [(rect: NSRect, kind: Int)] = []

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        chips.removeAll()
        let nameFont = NSFont.systemFont(ofSize: 11.5)
        let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let shown = entries.filter { $0.bytes > 0 }
        func texts(_ entry: (kind: Int, bytes: UInt64)) -> (name: NSAttributedString, size: NSAttributedString) {
            let dim = highlighted >= 0 && Int(highlighted) != entry.kind
            return (NSAttributedString(string: Kind.name(entry.kind), attributes: [
                        .font: nameFont,
                        .foregroundColor: dim ? NSColor.tertiaryLabelColor : NSColor.labelColor]),
                    NSAttributedString(string: formatBytes(entry.bytes), attributes: [
                        .font: sizeFont,
                        .foregroundColor: dim ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor]))
        }
        // Sizes are dropped before whole kinds are when the row gets tight.
        let full = shown.reduce(CGFloat(8)) { total, entry in
            let text = texts(entry)
            return total + 8 + 10 + 6 + ceil(text.name.size().width) + 6 + ceil(text.size.size().width) + 8 + 2
        }
        let withSizes = full <= bounds.width - 4
        var x: CGFloat = 8
        for entry in shown {
            let dim = highlighted >= 0 && Int(highlighted) != entry.kind
            let (name, size) = texts(entry)
            let nameWidth = ceil(name.size().width), sizeWidth = withSizes ? ceil(size.size().width) + 6 : 0
            let width = 8 + 10 + 6 + nameWidth + sizeWidth + 8
            if x + width > bounds.width - 4 { break }
            let chip = NSRect(x: x, y: 4, width: width, height: bounds.height - 8)
            if Int(highlighted) == entry.kind {
                NSColor.labelColor.withAlphaComponent(0.13).setFill()
                NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5).fill()
            }
            Kind.colors[entry.kind].withAlphaComponent(dim ? 0.4 : 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x + 8, y: bounds.midY - 5, width: 10, height: 10), xRadius: 2.5, yRadius: 2.5).fill()
            name.draw(at: NSPoint(x: x + 24, y: bounds.midY - name.size().height / 2))
            if withSizes {
                size.draw(at: NSPoint(x: x + 24 + nameWidth + 6, y: bounds.midY - size.size().height / 2))
            }
            chips.append((chip, entry.kind))
            x += width + 2
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let chip = chips.first(where: { $0.rect.contains(point) }) {
            onToggle?(Int(highlighted) == chip.kind ? -1 : Int32(chip.kind))
        } else if highlighted >= 0 {
            onToggle?(-1)
        }
    }
}
