import AppKit

/// Snapshots every item and type on a pasteboard, runs `body`, then restores the snapshot.
public enum ClipboardGuard {
    @MainActor
    public static func withPreserved<T>(_ pb: NSPasteboard = .general, _ body: () async throws -> T) async rethrows -> T {
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
        return try await body()
    }
}
