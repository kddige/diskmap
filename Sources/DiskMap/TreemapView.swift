import AppKit
import CScan

protocol TreemapViewDelegate: AnyObject {
    func treemap(_ view: TreemapView, didHover node: UInt32)
    func treemap(_ view: TreemapView, didSelect node: UInt32)
    func treemap(_ view: TreemapView, wantsZoomTo node: UInt32)
    func treemapWantsZoomOut(_ view: TreemapView)
    func treemapContextMenu(_ view: TreemapView) -> NSMenu?
}

/// The map itself. Rendering happens off the main thread into a bitmap; the
/// view shows the latest bitmap and answers hover and click from its id buffer.
final class TreemapView: NSView {
    weak var delegate: TreemapViewDelegate?

    private(set) var session: ScanSession?
    private(set) var root: UInt32 = 0
    var selected: UInt32 = noNode { didSet { updateOverlay() } }
    var highlightKind: Int32 = -1 {
        didSet { if oldValue != highlightKind { setNeedsRender() } }
    }

    private var current: MapFrame?
    private var hovered: UInt32 = noNode
    private var lastMouse: NSPoint?

    private let imageHost = NSView()
    private let overlay = OverlayView()
    private let hud = HoverHUD()

    private let renderQueue = DispatchQueue(label: "diskmap.render", qos: .userInteractive)
    private var rendering = false
    private var dirty = false
    private var generation = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0x12 / 255, green: 0x12 / 255, blue: 0x11 / 255, alpha: 1).cgColor

        imageHost.wantsLayer = true
        imageHost.layer?.contentsGravity = .resize
        imageHost.layer?.actions = ["contents": NSNull()]
        imageHost.frame = bounds
        imageHost.autoresizingMask = [.width, .height]
        addSubview(imageHost)

        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)

        hud.isHidden = true
        addSubview(hud)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Subviews are decoration; all mouse events belong to the map.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    // MARK: State

    func setSession(_ session: ScanSession?) {
        generation += 1
        self.session = session
        root = 0
        current = nil
        hovered = noNode
        selected = noNode
        imageHost.layer?.contents = nil
        hud.isHidden = true
        updateOverlay()
        setNeedsRender()
    }

    func zoom(to node: UInt32) {
        guard session != nil, node != root else { return }
        generation += 1
        root = node
        setNeedsRender()
    }

    /// Call when the tree changed under the map (scan progress, removal).
    func reload() {
        generation += 1
        setNeedsRender()
    }

    // MARK: Rendering

    func setNeedsRender() {
        guard let session, bounds.width >= 8, bounds.height >= 8 else { return }
        if rendering {
            dirty = true
            return
        }
        rendering = true
        dirty = false
        let size = bounds.size
        let scale = window?.backingScaleFactor ?? 2
        let root = self.root
        let kind = highlightKind
        let generation = self.generation
        renderQueue.async {
            let frame = MapRenderer.render(session: session, root: root, pointSize: size, scale: scale,
                                           highlightKind: kind)
            DispatchQueue.main.async {
                self.rendering = false
                if generation == self.generation, let frame { self.present(frame) }
                if self.dirty || generation != self.generation { self.setNeedsRender() }
            }
        }
    }

    private func present(_ frame: MapFrame) {
        current = frame
        imageHost.layer?.contents = frame.image
        if let lastMouse { hover(at: lastMouse) }
        updateOverlay()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setNeedsRender()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        setNeedsRender()
    }

    // MARK: Geometry

    /// Scale from frame pixels to view points (the frame may be a size behind
    /// during a live resize, in which case it is stretched).
    private var pixelScale: (x: CGFloat, y: CGFloat) {
        guard let current, bounds.width > 0, bounds.height > 0 else { return (1, 1) }
        return (CGFloat(current.width) / bounds.width, CGFloat(current.height) / bounds.height)
    }

    private func node(at point: NSPoint) -> UInt32 {
        guard let current else { return noNode }
        let scale = pixelScale
        return current.node(x: Int(point.x * scale.x), y: Int(point.y * scale.y))
    }

    private func viewRect(of node: UInt32) -> NSRect? {
        guard let current, node != noNode, let r = current.visibleRect(of: node) else { return nil }
        let scale = pixelScale
        return NSRect(x: r.minX / scale.x, y: r.minY / scale.y, width: r.width / scale.x, height: r.height / scale.y)
    }

    private func updateOverlay() {
        overlay.selection = session != nil && selected != noNode && current?.root == root
            ? viewRect(of: selected) : nil
        overlay.hover = hovered != noNode ? viewRect(of: hovered) : nil
        overlay.needsDisplay = true
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }

    override func mouseExited(with event: NSEvent) {
        lastMouse = nil
        hud.isHidden = true
        if hovered != noNode {
            hovered = noNode
            updateOverlay()
            delegate?.treemap(self, didHover: noNode)
        }
    }

    private func hover(at point: NSPoint) {
        lastMouse = point
        let node = node(at: point)
        if node != hovered {
            hovered = node
            updateOverlay()
            delegate?.treemap(self, didHover: node)
            if node != noNode, let session {
                let info = session.info(node)
                let isDir = info.flags & UInt8(DM_F_DIR) != 0
                let detail = isDir
                    ? "\(formatBytes(info.size))  ·  \(formatItems(UInt64(info.file_count)))"
                    : "\(formatBytes(info.size))  ·  \(Kind.name(Int(info.kind)))"
                hud.set(title: session.name(node), detail: detail,
                        color: isDir ? nil : Kind.colors[Int(info.kind)])
            }
        }
        guard node != noNode else {
            hud.isHidden = true
            return
        }
        // Below and to the right of the pointer, flipped to stay inside the map.
        var origin = NSPoint(x: point.x + 14, y: point.y + 18)
        let size = hud.frame.size
        if origin.x + size.width > bounds.maxX - 4 { origin.x = point.x - size.width - 10 }
        if origin.y + size.height > bounds.maxY - 4 { origin.y = point.y - size.height - 10 }
        hud.setFrameOrigin(NSPoint(x: max(4, origin.x), y: max(4, origin.y)))
        hud.isHidden = false
    }

    // MARK: Clicks and keys

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let node = node(at: convert(event.locationInWindow, from: nil))
        guard node != noNode else { return }
        if event.clickCount >= 2 {
            if let target = zoomTarget(for: node) { delegate?.treemap(self, wantsZoomTo: target) }
        } else {
            delegate?.treemap(self, didSelect: node)
        }
    }

    /// A folder title zooms straight to that folder; anything else goes one
    /// level down, into the top-level folder that holds it.
    private func zoomTarget(for node: UInt32) -> UInt32? {
        guard let session else { return nil }
        if session.isDirectory(node) {
            return node != root && session.info(node).child_count > 0 ? node : nil
        }
        var n = node
        while true {
            let parent = session.parent(n)
            if parent == root || parent == noNode { break }
            n = parent
        }
        return n != node && session.isDirectory(n) ? n : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let node = node(at: convert(event.locationInWindow, from: nil))
        guard node != noNode else { return nil }
        delegate?.treemap(self, didSelect: node)
        return delegate?.treemapContextMenu(self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // esc
            delegate?.treemapWantsZoomOut(self)
        case 36, 76: // return, enter
            if selected != noNode, let session {
                let target = session.isDirectory(selected) ? selected : session.parent(selected)
                if target != noNode, target != root { delegate?.treemap(self, wantsZoomTo: target) }
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        guard event.phase == .ended || event.phase == .cancelled else { return }
        // Pinch out = closer, pinch in = back.
        if event.magnification < 0 {
            delegate?.treemapWantsZoomOut(self)
        } else if hovered != noNode, let target = zoomTarget(for: hovered) {
            delegate?.treemap(self, wantsZoomTo: target)
        }
    }
}

// MARK: - Overlay

private final class OverlayView: NSView {
    var selection: NSRect?
    var hover: NSRect?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if let hover {
            NSColor.white.withAlphaComponent(0.85).setStroke()
            let path = NSBezierPath(rect: hover.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
        if let selection {
            NSColor.black.withAlphaComponent(0.75).setStroke()
            let outer = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
            outer.lineWidth = 1
            outer.stroke()
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
        }
    }
}

// MARK: - Hover readout

private final class HoverHUD: NSView {
    private let swatch = NSView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.07, alpha: 0.92).cgColor
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 8
            s.shadowOffset = NSSize(width: 0, height: -2)
            s.shadowColor = NSColor.black.withAlphaComponent(0.5)
            return s
        }()

        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = NSColor(white: 0.96, alpha: 1)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = NSColor(white: 0.78, alpha: 1)
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 2.5
        addSubview(title)
        addSubview(detail)
        addSubview(swatch)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(title: String, detail: String, color: NSColor?) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        swatch.isHidden = color == nil
        swatch.layer?.backgroundColor = color?.cgColor

        let pad: CGFloat = 9
        let lead: CGFloat = color == nil ? 0 : 15
        let titleSize = self.title.intrinsicContentSize
        let detailSize = self.detail.intrinsicContentSize
        let width = min(380, max(titleSize.width, detailSize.width + lead))
        setFrameSize(NSSize(width: width + 2 * pad, height: titleSize.height + detailSize.height + 2 * pad + 2))
        self.detail.frame = NSRect(x: pad + lead, y: pad, width: width - lead, height: detailSize.height)
        self.title.frame = NSRect(x: pad, y: pad + detailSize.height + 2, width: width, height: titleSize.height)
        swatch.frame = NSRect(x: pad, y: pad + (detailSize.height - 10) / 2, width: 10, height: 10)
    }
}
