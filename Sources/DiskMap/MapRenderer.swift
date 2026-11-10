import AppKit
import CScan
import CoreText

/// One rendered treemap: the picture, plus what is needed to answer "what is
/// under this pixel" and "where is this node".
final class MapFrame {
    let session: ScanSession // keeps the tree alive for the layout
    let root: UInt32
    let width: Int
    let height: Int
    let image: CGImage
    private let layout: OpaquePointer
    private let ids: UnsafeMutablePointer<UInt32>

    fileprivate init(session: ScanSession, root: UInt32, width: Int, height: Int, image: CGImage,
                     layout: OpaquePointer, ids: UnsafeMutablePointer<UInt32>) {
        self.session = session
        self.root = root
        self.width = width
        self.height = height
        self.image = image
        self.layout = layout
        self.ids = ids
    }

    deinit {
        dm_layout_free(layout)
        ids.deallocate()
    }

    /// Node drawn at a pixel (origin top-left), or `noNode`.
    func node(x: Int, y: Int) -> UInt32 {
        guard x >= 0, y >= 0, x < width, y < height else { return noNode }
        return ids[y * width + x]
    }

    /// Pixel bounds of a node, if it is drawn on its own.
    func rect(of node: UInt32) -> CGRect? {
        var x: Float = 0, y: Float = 0, w: Float = 0, h: Float = 0
        guard dm_layout_find(layout, node, &x, &y, &w, &h) else { return nil }
        return CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
    }

    /// Bounds of the node, or of its nearest ancestor that is drawn.
    func visibleRect(of node: UInt32) -> CGRect? {
        var n = node
        while n != noNode {
            if let r = rect(of: n) { return r }
            if n == root { break }
            n = session.info(n).parent
        }
        return nil
    }
}

enum MapRenderer {
    static let background: (UInt8, UInt8, UInt8) = (0x12, 0x12, 0x11)
    static let header: (UInt8, UInt8, UInt8) = (0x2b, 0x2b, 0x29)

    /// Lays out and paints the subtree under `root`. Safe to call off the main
    /// thread, and while the scan is still running.
    static func render(session: ScanSession, root: UInt32, pointSize: CGSize, scale: CGFloat,
                       highlightKind: Int32) -> MapFrame? {
        let width = Int((pointSize.width * scale).rounded())
        let height = Int((pointSize.height * scale).rounded())
        guard width >= 16, height >= 16 else { return nil }
        let s = Float(scale)

        var params = dm_layout_params(
            header_h: 17 * s,
            header_min_w: 84 * s,
            header_min_h: 48 * s,
            header_max_depth: 5,
            pad: 1 * s,
            min_side: 2.5 * s,
            min_area: 3 * s * s,
            cushion_height: 0.20,
            cushion_falloff: 0.70,
            cushion_leaf: 0.14)
        guard let layout = dm_layout_create(session.tree, root, Int32(width), Int32(height), &params) else {
            return nil
        }

        var render = dm_render_params()
        withUnsafeMutableBytes(of: &render.kind_rgb) { bytes in
            for (k, c) in Kind.rgb.enumerated() {
                bytes[k * 3] = c.0
                bytes[k * 3 + 1] = c.1
                bytes[k * 3 + 2] = c.2
            }
        }
        render.background = background
        render.header = header
        render.highlight_kind = highlightKind
        render.ambient = 0.42

        let rgba = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
        defer { rgba.deallocate() }
        let ids = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
        dm_layout_render(layout, rgba, ids, &render)

        guard let ctx = CGContext(data: rgba, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            dm_layout_free(layout)
            ids.deallocate()
            return nil
        }
        drawLabels(ctx, layout: layout, session: session, scale: scale, height: height,
                   dimmedExcept: highlightKind)
        guard let image = ctx.makeImage() else {
            dm_layout_free(layout)
            ids.deallocate()
            return nil
        }
        return MapFrame(session: session, root: root, width: width, height: height, image: image,
                        layout: layout, ids: ids)
    }

    // MARK: Labels

    private static func drawLabels(_ ctx: CGContext, layout: OpaquePointer, session: ScanSession,
                                   scale: CGFloat, height: Int, dimmedExcept: Int32) {
        var count = 0
        guard let cells = dm_layout_cells(layout, &count), count > 0 else { return }

        let titleFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, 11 * scale, nil)!
        let nameFont = CTFontCreateUIFontForLanguage(.system, 11 * scale, nil)!
        let smallFont = CTFontCreateUIFontForLanguage(.system, 10 * scale, nil)!
        let H = CGFloat(height)

        func line(_ text: String, _ font: CTFont, maxWidth: CGFloat) -> (CTLine, CGFloat)? {
            guard maxWidth > 12 * scale else { return nil }
            let attrs = [kCTFontAttributeName: font,
                         kCTForegroundColorFromContextAttributeName: true] as CFDictionary
            let full = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs))
            let width = CGFloat(CTLineGetTypographicBounds(full, nil, nil, nil))
            if width <= maxWidth { return (full, width) }
            let ellipsis = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "…" as CFString, attrs))
            guard let cut = CTLineCreateTruncatedLine(full, Double(maxWidth), .middle, ellipsis) else { return nil }
            return (cut, CGFloat(CTLineGetTypographicBounds(cut, nil, nil, nil)))
        }

        /// `top` is the distance from the top edge of the bitmap to the top of the text.
        func draw(_ l: CTLine, font: CTFont, x: CGFloat, top: CGFloat, white: CGFloat, alpha: CGFloat,
                  shadow: Bool) {
            let baseline = H - top - CTFontGetAscent(font)
            if shadow {
                ctx.setFillColor(gray: 0, alpha: 0.5 * alpha)
                ctx.textPosition = CGPoint(x: x, y: baseline - scale)
                CTLineDraw(l, ctx)
            }
            ctx.setFillColor(gray: white, alpha: alpha)
            ctx.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(l, ctx)
        }

        for i in 0..<count {
            let cell = cells[i]
            let x = CGFloat(cell.x), y = CGFloat(cell.y), w = CGFloat(cell.w), h = CGFloat(cell.h)
            switch Int32(cell.type) {
            case DM_CELL_HEADER:
                let info = session.info(cell.node)
                let inset = 5 * scale
                var available = w - 2 * inset
                let top = y + (h - CTFontGetAscent(titleFont) - CTFontGetDescent(titleFont)) / 2
                // Size on the right when there is room for both.
                if available > 120 * scale, let (sizeLine, sizeWidth) = line(formatBytes(info.size), smallFont, maxWidth: available) {
                    draw(sizeLine, font: smallFont, x: x + w - inset - sizeWidth, top: top + scale * 0.5,
                         white: 1, alpha: 0.5, shadow: false)
                    available -= sizeWidth + 8 * scale
                }
                // Folded single-child chains read as a path: "share/doc/rust". When
                // that does not fit, the outermost name is the one people recognize
                // ("Xcode.app" rather than "Contents").
                var names = [session.name(cell.node)]
                var ancestor = info.parent
                for _ in 0..<cell.chain where ancestor != noNode {
                    names.insert(session.name(ancestor), at: 0)
                    ancestor = session.info(ancestor).parent
                }
                var title = names.joined(separator: "/")
                if names.count > 1, let (full, width) = line(title, titleFont, maxWidth: 10_000), width > available {
                    _ = full
                    title = names[0]
                }
                if let (nameLine, _) = line(title, titleFont, maxWidth: available) {
                    draw(nameLine, font: titleFont, x: x + inset, top: top, white: 1, alpha: 0.86, shadow: false)
                }

            case DM_CELL_FILE, DM_CELL_DIR:
                guard w >= 58 * scale, h >= 21 * scale else { continue }
                let dim: CGFloat = (dimmedExcept >= 0 && Int32(cell.kind) != dimmedExcept) ? 0.45 : 1
                let inset = 5 * scale
                let info = session.info(cell.node)
                if let (nameLine, _) = line(String(cString: info.name), nameFont, maxWidth: w - 2 * inset) {
                    draw(nameLine, font: nameFont, x: x + inset, top: y + 4 * scale, white: 1,
                         alpha: 0.95 * dim, shadow: true)
                }
                if h >= 38 * scale, let (sizeLine, _) = line(formatBytes(info.size), smallFont, maxWidth: w - 2 * inset) {
                    draw(sizeLine, font: smallFont, x: x + inset, top: y + 19 * scale, white: 1,
                         alpha: 0.72 * dim, shadow: true)
                }

            default:
                continue
            }
        }
    }

    /// Writes a frame as PNG (used by the headless `--render` mode).
    static func writePNG(_ image: CGImage, to path: String) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
