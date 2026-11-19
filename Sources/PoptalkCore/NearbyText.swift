import CoreGraphics

/// Decisions for gathering screen text around the focused field: the AX walk, the OCR crop, when to OCR.
public enum NearbyText {
    /// Texts near `start`, nearest first: climbs up to `maxUp` ancestors and walks each one's other
    /// children depth-first (document order), at most `maxDepth` levels below that ancestor.
    /// Doesn't descend into nodes that have text. Stops at `maxNodes` visited, `maxChars` collected
    /// (cutting the text that overflows), or when `expired()`.
    public static func collect<Node: Equatable>(
        from start: Node, maxUp: Int, maxDepth: Int, maxNodes: Int, maxChars: Int,
        parent: (Node) -> Node?, visit: (Node) -> (text: String?, children: [Node]),
        expired: () -> Bool = { false }
    ) -> [String] {
        var out: [String] = [], chars = 0, nodes = 0
        var from = start
        for _ in 0..<maxUp {
            guard let ancestor = parent(from), nodes < maxNodes, !expired() else { break }
            nodes += 1
            var stack = visit(ancestor).children.filter { $0 != from }.reversed().map { ($0, 0) }
            while let (node, depth) = stack.popLast() {
                guard nodes < maxNodes, !expired() else { return out }
                nodes += 1
                let (text, children) = visit(node)
                if let text, !text.isEmpty {
                    guard chars + text.count <= maxChars else { return out + [String(text.prefix(maxChars - chars))] }
                    out.append(text)
                    chars += text.count
                } else if depth < maxDepth {
                    stack += children.reversed().map { ($0, depth + 1) }
                }
            }
            from = ancestor
        }
        return out
    }

    /// Window-local region to OCR: the window's full width, from `above` points over the field to
    /// `below` points under it, clamped to the window. The whole window when the field is unknown or outside it.
    public static func ocrCrop(field: CGRect?, window: CGRect, above: CGFloat = 600, below: CGFloat = 150) -> CGRect {
        let whole = CGRect(origin: .zero, size: window.size)
        guard let field, field.intersects(window) else { return whole }
        let top = max(0, field.minY - window.minY - above)
        let bottom = min(window.height, field.maxY - window.minY + below)
        return CGRect(x: 0, y: top, width: window.width, height: bottom - top)
    }

    /// OCR when Accessibility gives little: a thin field, or a long field whose surroundings
    /// (a chat thread above a compose box) aren't in the AX tree.
    public static func needsOCR(fieldChars: Int, nearbyChars: Int, threshold: Int = 200) -> Bool {
        fieldChars < threshold || nearbyChars < threshold
    }
}
