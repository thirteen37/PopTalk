import Foundation
import Testing
@testable import PoptalkCore

private final class Capture: @unchecked Sendable { var request: URLRequest? }

private func sse(_ chunks: String...) -> [String] {
    chunks.flatMap { [#"data: {"choices":[{"delta":{"content":\#($0)}}]}"#, ""] } + ["data: [DONE]"]
}

private func client(status: Int = 200, lines: [String] = sse(#""hi""#), capture: Capture = Capture()) -> LLMClient {
    LLMClient(baseURL: URL(string: "http://localhost:1234/v1")!) { req in
        capture.request = req
        let stream = AsyncThrowingStream<String, Error> { c in lines.forEach { c.yield($0) }; c.finish() }
        return (stream, HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Test func sendsOpenAIRequest() async throws {
    let cap = Capture()
    let out = try await client(capture: cap).complete(
        model: "qwen", messages: [ChatMessage(role: "user", content: "x")], json: true, timeout: 3)
    #expect(out == "hi")
    let req = try #require(cap.request)
    #expect(req.url?.absoluteString == "http://localhost:1234/v1/chat/completions")
    #expect(req.httpMethod == "POST")
    let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
    #expect(body["model"] as? String == "qwen")
    #expect((body["messages"] as? [[String: Any]])?.count == 1)
    let format = try #require(body["response_format"] as? [String: Any])
    #expect(format["type"] as? String == "json_schema")
    #expect((format["json_schema"] as? [String: Any])?["schema"] != nil)
}

@Test func plainRequestOmitsResponseFormat() async throws {
    let cap = Capture()
    _ = try await client(capture: cap).complete(model: "g", messages: [], json: false, timeout: 3)
    let body = try JSONSerialization.jsonObject(with: cap.request!.httpBody!) as! [String: Any]
    #expect(body["response_format"] == nil)
}

@Test func timeoutIsApplied() async throws {
    let cap = Capture()
    _ = try await client(capture: cap).complete(model: "g", messages: [], json: false, timeout: 3)
    #expect(cap.request?.timeoutInterval == 3)
}

@Test func non2xxThrows() async {
    await #expect(throws: (any Error).self) {
        try await client(status: 404, lines: ["{}"]).complete(model: "g", messages: [], json: false, timeout: 3)
    }
}

@Test func parsesJSONWrappedInProseAndFences() throws {
    let raw = "Sure!\n```json\n{\"action\":\"correct\",\"text\":\"Todoist\",\"vocabulary\":{\"text\":\"Todoist\",\"aliases\":[\"todo list\"]},\"remember\":false}\n```"
    let r = try LLMClient.parseEditResult(raw)
    #expect(r == EditResult(action: .correct, text: "Todoist",
                            vocabulary: VocabTerm(text: "Todoist", aliases: ["todo list"]), remember: false))
}

@Test func parsesBracesInsideStrings() throws {
    let r = try LLMClient.parseEditResult(#"{"action":"edit","text":"use {x} here","vocabulary":null,"remember":false}"#)
    #expect(r.text == "use {x} here")
}

// Without a server-side JSON schema (mlx, apple) models fence the JSON and drop keys that look optional.
@Test func parsesFencedEditResultMissingOptionalKeys() throws {
    let r = try LLMClient.parseEditResult("```json\n{\n  \"action\": \"edit\",\n  \"text\": \"Could you send the deck?\"\n}\n```")
    #expect(r == EditResult(action: .edit, text: "Could you send the deck?"))
}

@Test func rejectsNonJSON() {
    #expect(throws: (any Error).self) { try LLMClient.parseEditResult("Todoist") }
}

// Reasoning models think for 15 s+ by default; PopTalk needs fast, direct answers.
@Test func disablesThinking() async throws {
    let cap = Capture()
    _ = try await client(capture: cap).complete(model: "g", messages: [], json: false, timeout: 3)
    let body = try JSONSerialization.jsonObject(with: cap.request!.httpBody!) as! [String: Any]
    #expect(body["reasoning_effort"] as? String == "none")
}

// #4: stream so that dropping the connection stops server-side generation.
@Test func requestsStreaming() async throws {
    let cap = Capture()
    _ = try await client(capture: cap).complete(model: "g", messages: [], json: false, timeout: 3)
    let body = try JSONSerialization.jsonObject(with: cap.request!.httpBody!) as! [String: Any]
    #expect(body["stream"] as? Bool == true)
}

@Test func assemblesSSEChunks() async throws {
    let lines = [": keep-alive", #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#] + sse(#""Hello""#, #"" there""#)
    #expect(try await client(lines: lines).complete(model: "g", messages: [], json: false, timeout: 3) == "Hello there")
}

private final class Flag: @unchecked Sendable { var set = false }

@Test func timeoutCancelsStreamAndThrowsTimedOut() async {
    let cancelled = Flag()
    let c = LLMClient(baseURL: URL(string: "http://localhost:1234/v1")!) { req in
        let stream = AsyncThrowingStream<String, Error> { c in c.onTermination = { _ in cancelled.set = true } }  // never ends
        return (stream, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    do {
        _ = try await c.complete(model: "g", messages: [], json: false, timeout: 0.05)
        Issue.record("expected timeout")
    } catch {
        #expect((error as? URLError)?.code == .timedOut)
    }
    #expect(cancelled.set)
}
