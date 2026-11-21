import CoreGraphics

/// Where the overlay goes (#78), in AppKit coordinates (bottom-left origin, y up). The anchor is the overlay's
/// bottom-centre, relative to the screen's visible frame, so it survives size changes and display rearrangement.
public enum OverlayPlacement {
    /// Space kept between the overlay and the focused field or the screen top.
    public static let margin: CGFloat = 8
    /// UserDefaults: display UUID → dragged anchor `[x, y]`.
    public static let anchorsKey = "overlayAnchors"

    /// Bottom-centre (or `anchor`), clamped to `visible`; moved above `field` if it would cover it, or to the top
    /// of the screen if above doesn't fit.
    public static func frame(size: CGSize, visible: CGRect, field: CGRect?, anchor: CGPoint?) -> CGRect {
        let a = anchor ?? CGPoint(x: visible.width / 2, y: 50)
        var f = CGRect(x: (visible.minX + a.x - size.width / 2).rounded(), y: visible.minY + a.y,
                       width: size.width, height: size.height)
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - size.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - size.height)
        guard let field, f.intersects(field.insetBy(dx: -margin, dy: -margin)) else { return f }
        f.origin.y = field.maxY + margin
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - size.height - margin }
        return f
    }

    /// The anchor of a dropped overlay frame.
    public static func anchor(of frame: CGRect, visible: CGRect) -> CGPoint {
        CGPoint(x: frame.midX - visible.minX, y: frame.minY - visible.minY)
    }

    /// Accessibility rect (top-left of the primary screen, y down) to AppKit.
    public static func appKit(_ ax: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: ax.minX, y: primaryHeight - ax.maxY, width: ax.width, height: ax.height)
    }
}
