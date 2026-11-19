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

@MainActor @Test func untouchedClipboardIsNotRewritten() async {
    let pb = NSPasteboard(name: NSPasteboard.Name("poptalk-test-\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }
    pb.clearContents()
    pb.setString("original", forType: .string)
    let before = pb.changeCount
    await ClipboardGuard.withPreserved(pb) {}
    #expect(pb.changeCount == before)
}

@MainActor @Test func temporaryWritesAndRestoreAreMarkedForClipboardManagers() async {
    let pb = NSPasteboard(name: NSPasteboard.Name("poptalk-test-\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }
    pb.clearContents()
    pb.setString("original", forType: .string)

    let types = await ClipboardGuard.withPreserved(pb) {
        ClipboardGuard.setTemporary("dictated", on: pb)
        return pb.types ?? []
    }

    #expect(types.contains(.string))
    #expect(types.contains(ClipboardGuard.transient))
    #expect(types.contains(ClipboardGuard.concealed))
    #expect(pb.string(forType: .string) == "original")
    #expect(pb.types?.contains(ClipboardGuard.transient) == true)  // the restore isn't a new history entry
    #expect(pb.types?.contains(ClipboardGuard.concealed) == false)
}
