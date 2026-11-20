import Foundation
import Testing
@testable import PoptalkCore

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history")
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // whole seconds: ISO 8601 drops fractions

private func sample(_ id: UUID = UUID()) -> HistoryRequest {
    HistoryRequest(id: id, at: t0, app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                   rawTranscript: "send it to todo list", transcript: "send it to Todoist", boost: ["Todoist"],
                   selection: nil, provider: "mlx", model: "gemma",
                   messages: [ChatMessage(role: "user", content: "<transcript>send it to Todoist</transcript>")],
                   reply: "Send it to Todoist.", outcome: .insert(" Send it to Todoist.", label: "Dictated"), latency: 0.8)
}

private func lines(_ store: HistoryStore) throws -> [Data] {
    store.flush()
    return try String(contentsOf: store.file, encoding: .utf8).split(separator: "\n").map { Data($0.utf8) }
}

@Test func requestDerivesActionTextAndLabelFromOutcome() {
    let r = sample()
    #expect(r.action == "insert" && r.text == " Send it to Todoist." && r.outcome == "Dictated")
    let e = HistoryRequest(id: UUID(), at: t0, app: "", rawTranscript: "x", transcript: "x", provider: "mlx",
                           outcome: .error("Model took too long"), latency: 20)
    #expect(e.action == "error" && e.text == nil && e.outcome == "Model took too long")
}

@Test func appendWritesOneJSONLineEachThatRoundTrips() throws {
    let store = HistoryStore(directory: tempDir()) { true }
    let r = sample()
    let ev = HistoryEvent(.correction, id: r.id, at: t0, by: UUID())
    store.append(r)
    store.append(ev)
    let ls = try lines(store)
    #expect(ls.count == 2)
    #expect(try HistoryStore.decoder.decode(HistoryRequest.self, from: ls[0]) == r)
    #expect(try HistoryStore.decoder.decode(HistoryEvent.self, from: ls[1]) == ev)
    #expect(String(decoding: ls[0], as: UTF8.self).contains(#""type":"request""#))
    #expect(String(decoding: ls[1], as: UTF8.self).contains(#""type":"correction""#))
}

@Test func statsCountRequestsAndBytesAndWipeRemovesEverything() throws {
    let store = HistoryStore(directory: tempDir()) { true }
    let r = sample()
    store.append(r)
    store.append(HistoryEvent(.undo, id: r.id, at: t0))
    store.saveFile("\(r.id).m4a") { try Data("audio".utf8).write(to: $0) }
    let s = store.stats()
    #expect(s.requests == 1 && s.bytes > 5)
    store.wipe()
    #expect(store.stats() == HistoryStore.Stats(requests: 0, bytes: 0))
    #expect(!FileManager.default.fileExists(atPath: store.directory.path))
}

@Test func nothingIsWrittenWhenDisabled() {
    let store = HistoryStore(directory: tempDir()) { false }
    store.append(sample())
    store.saveFile("a.m4a") { try Data("audio".utf8).write(to: $0) }
    store.flush()
    #expect(!FileManager.default.fileExists(atPath: store.directory.path))
}

@Test func writeErrorsAreDropped() {
    let store = HistoryStore(directory: URL(fileURLWithPath: "/dev/null/history")) { true }
    store.append(sample())
    store.saveFile("a.m4a") { _ in throw CocoaError(.fileWriteUnknown) }
    #expect(store.stats().requests == 0)
}

@Test func correctionNeedsSameFieldRecentInsertAndOverlappingSelection() {
    let id = UUID()
    let last = LastInsert(target: "slack", text: " Send it to to do list.", at: t0, requestID: id)
    #expect(last.corrected(by: "to do list", in: "slack", now: t0 + 30) == id)  // part of the insert
    #expect(last.corrected(by: "Please: Send it to to do list. Thanks", in: "slack", now: t0 + 30) == id)  // all of it, and more
    #expect(last.corrected(by: "to do list", in: "mail", now: t0 + 30) == nil)  // other field
    #expect(last.corrected(by: "to do list", in: "slack", now: t0 + 600) == nil)  // too late
    #expect(last.corrected(by: "something else", in: "slack", now: t0 + 30) == nil)
    #expect(last.corrected(by: "  ", in: "slack", now: t0 + 30) == nil)
    #expect(last.corrected(by: nil, in: "slack", now: t0 + 30) == nil)
    #expect(LastInsert(target: "slack", text: "hi", at: t0).corrected(by: "hi", in: "slack", now: t0 + 1) == nil)  // no request id
}

@Test func modelCallRecorderKeepsLastCallAndReply() async throws {
    let calls = ModelCallRecorder()
    let complete = calls.wrap { _, _, _, _ in "reply" }
    _ = try await complete("m", [ChatMessage(role: "user", content: "hi")], false, 1)
    #expect(calls.call == ModelCallRecorder.Call(model: "m", messages: [ChatMessage(role: "user", content: "hi")], reply: "reply", kind: "dictation"))
    let failing = calls.wrap { _, _, _, _ in throw Pipeline.ModelLoading() }
    _ = try? await failing("e", [], true, 1)
    #expect(calls.call == ModelCallRecorder.Call(model: "e", messages: [], reply: nil, kind: "edit"))
}

@Test func modelCallRecorderTakesPromptStatsFromTheWrappedCallAndKindFromJSON() async throws {
    let calls = ModelCallRecorder()
    let complete = calls.wrap { _, _, _, _ in
        // From a child task, as MLXProvider reports from inside its task group.
        await Task { ModelCallRecorder.current?.prompt(tokens: 120, shared: 100) }.value
        return "ok"
    }
    _ = try await complete("m", [], false, 1)
    #expect(calls.call?.kind == "dictation" && calls.call?.promptTokens == 120 && calls.call?.sharedPrefix == 100)
    _ = try await calls.wrap { _, _, _, _ in "ok" }("m", [], true, 1)
    #expect(calls.call?.kind == "edit" && calls.call?.promptTokens == nil && calls.call?.sharedPrefix == nil)
    #expect(ModelCallRecorder.current == nil)  // outside a wrapped call MLXProvider's report is a no-op
}

@Test func requestPromptStatsAreOptionalAndRoundTrip() throws {
    var r = sample()
    (r.kind, r.promptTokens, r.sharedPrefix) = ("dictation", 120, 100)
    #expect(try HistoryStore.decoder.decode(HistoryRequest.self, from: HistoryStore.encoder.encode(r)) == r)
    // A line written before these fields existed still decodes.
    let old = try HistoryStore.decoder.decode(HistoryRequest.self, from: HistoryStore.encoder.encode(sample()))
    #expect(old.kind == nil && old.promptTokens == nil && old.sharedPrefix == nil)
}

@Test func requestSpeechModelIsOptionalAndRoundTrips() throws {
    var r = sample()
    r.speechModel = "ultra"
    #expect(try HistoryStore.decoder.decode(HistoryRequest.self, from: HistoryStore.encoder.encode(r)) == r)
    // A line written before #73 has no speechModel and still decodes.
    let line = try HistoryStore.encoder.encode(sample())
    #expect(!String(decoding: line, as: UTF8.self).contains("speechModel"))
    #expect(try HistoryStore.decoder.decode(HistoryRequest.self, from: line).speechModel == nil)
}
