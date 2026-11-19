import AppKit

/// Snapshots every item and type on a pasteboard, runs `body`, then restores the snapshot if the
/// pasteboard changed. Temporary writes and the restore are marked (nspasteboard.org) so clipboard
/// managers don't record them.
public enum ClipboardGuard {
    /// "Don't record this": it will be replaced shortly.
    public static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// "Don't show or store this": dictated text may be private.
    public static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    @MainActor
    public static func withPreserved<T>(_ pb: NSPasteboard = .general, _ body: () async throws -> T) async rethrows -> T {
        let before = pb.changeCount
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            copy.setData(Data(), forType: transient)  // the user's own data is already in their history
            return copy
        }
        defer {
            if pb.changeCount != before {
                pb.clearContents()
                if !saved.isEmpty { pb.writeObjects(saved) }
            }
        }
        return try await body()
    }

    /// Replaces the pasteboard with `s`, marked so clipboard managers skip it.
    @MainActor
    public static func setTemporary(_ s: String, on pb: NSPasteboard = .general) {
        let item = NSPasteboardItem()
        item.setString(s, forType: .string)
        item.setData(Data(), forType: transient)
        item.setData(Data(), forType: concealed)
        pb.clearContents()
        pb.writeObjects([item])
    }
}
