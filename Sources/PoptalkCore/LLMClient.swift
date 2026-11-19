import Foundation

public enum EditAction: String, Codable, Sendable { case replace, correct, edit, insertBefore, insertAfter }

public struct EditResult: Codable, Sendable, Equatable {
    public var action: EditAction
    public var text: String
    public var vocabulary: VocabTerm?
    public var remember: Bool

    public init(action: EditAction, text: String, vocabulary: VocabTerm? = nil, remember: Bool = false) {
        self.action = action
        self.text = text
        self.vocabulary = vocabulary
        self.remember = remember
    }

    // Without a server-side schema, models omit `remember` when it would be false.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(action: try c.decode(EditAction.self, forKey: .action), text: try c.decode(String.self, forKey: .text),
                  vocabulary: try c.decodeIfPresent(VocabTerm.self, forKey: .vocabulary),
                  remember: try c.decodeIfPresent(Bool.self, forKey: .remember) ?? false)
    }
}

public struct LLMError: Error, CustomStringConvertible {
    public var description: String
    public init(description: String) { self.description = description }
}

/// Minimal OpenAI-compatible `/chat/completions` client (LM Studio, Ollama).
public struct LLMClient: Sendable {
    /// Response body as lines. Ending the stream early must drop the connection.
    public typealias Transport = @Sendable (URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse)
    let baseURL: URL
    let transport: Transport

    public init(baseURL: URL, transport: @escaping Transport = LLMClient.urlSession) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// Cancels the URLSession task when the reader stops, so LM Studio aborts generation.
    public static let urlSession: Transport = { req in
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        let task = bytes.task
        let stream = AsyncThrowingStream<String, Error> { c in
            let reader = Task {
                do { for try await line in bytes.lines { c.yield(line) }; c.finish() } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in reader.cancel(); task.cancel() }
        }
        return (stream, response)
    }

    nonisolated(unsafe) static let editSchema: [String: Any] = [
        "name": "edit_result", "strict": true,
        "schema": [
            "type": "object", "additionalProperties": false,
            "required": ["action", "text", "vocabulary", "remember"],
            "properties": [
                "action": ["type": "string", "enum": ["replace", "correct", "edit", "insertBefore", "insertAfter"]],
                "text": ["type": "string"],
                "remember": ["type": "boolean"],
                "vocabulary": ["anyOf": [
                    ["type": "null"],
                    ["type": "object", "additionalProperties": false, "required": ["text", "aliases"],
                     "properties": ["text": ["type": "string"], "aliases": ["type": "array", "items": ["type": "string"]]]],
                ]],
            ],
        ] as [String: Any],
    ]

    /// - Parameter json: constrain output to the `EditResult` schema.
    public func complete(model: String, messages: [ChatMessage], json: Bool, timeout: TimeInterval) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"), timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": 0,
            "stream": true,  // dropping the connection stops server-side generation
            "reasoning_effort": "none",  // LM Studio: skip thinking on reasoning models (0.7 s vs 17 s+)
        ]
        if json { body["response_format"] = ["type": "json_schema", "json_schema": Self.editSchema] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Overall deadline; timeoutInterval alone only bounds the gap between chunks.
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [req] in try await self.read(req) }
            group.addTask { try await Task.sleep(for: .seconds(timeout)); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Concatenates the `delta.content` of each SSE `data:` chunk.
    private func read(_ req: URLRequest) async throws -> String {
        let (lines, response) = try await transport(req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var body = ""
            for try await line in lines where body.count < 300 { body += line }
            throw LLMError(description: "HTTP \(status): \(body.prefix(300))")
        }
        struct Chunk: Decodable {
            struct Choice: Decodable { struct Delta: Decodable { var content: String? }; var delta: Delta }
            var choices: [Choice]
        }
        var content = ""
        for try await line in lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            content += try JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)).choices.first?.delta.content ?? ""
        }
        return content
    }

    /// Decodes the first balanced JSON object in `raw`, tolerating prose and code fences around it.
    public static func parseEditResult(_ raw: String) throws -> EditResult {
        let chars = Array(Pipeline.stripChatter(raw))
        guard let start = chars.firstIndex(of: "{") else { throw LLMError(description: "No JSON in reply") }
        var depth = 0, inString = false, escaped = false
        for i in start..<chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return try JSONDecoder().decode(EditResult.self, from: Data(String(chars[start...i]).utf8))
                }
            default: break
            }
        }
        throw LLMError(description: "Unterminated JSON in reply")
    }
}
