import AppKit
import Testing
@testable import PoptalkCore

@MainActor @Test func pasteRestoresClipboard() async throws {
    let pb = NSPasteboard(name: NSPasteboard.Name("poptalk-test-\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }
    let custom = NSPasteboard.PasteboardType("io.lyx.poptalk.test")
    let item = NSPasteboardItem()
    item.setString("original", forType: .string)
    item.setData(Data([1, 2, 3]), forType: custom)
    pb.clearContents()
    pb.writeObjects([item])

    let seen = await ClipboardGuard.withPreserved(pb) {
        pb.clearContents()
        pb.setString("temp", forType: .string)
        return pb.string(forType: .string)
    }

    #expect(seen == "temp")
    #expect(pb.string(forType: .string) == "original")
    #expect(pb.data(forType: custom) == Data([1, 2, 3]))
}
