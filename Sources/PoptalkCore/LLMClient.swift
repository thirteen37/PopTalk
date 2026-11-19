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
}

public struct LLMError: Error, CustomStringConvertible {
    public var description: String
}

/// Minimal OpenAI-compatible `/chat/completions` client (LM Studio, Ollama).
public struct LLMClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let baseURL: URL
    let transport: Transport

    public init(baseURL: URL, transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.baseURL = baseURL
        self.transport = transport
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
            "stream": false,
        ]
        if json { body["response_format"] = ["type": "json_schema", "json_schema": Self.editSchema] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport(req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError(description: "HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        struct Reply: Decodable {
            struct Choice: Decodable { struct Message: Decodable { var content: String }; var message: Message }
            var choices: [Choice]
        }
        guard let content = try JSONDecoder().decode(Reply.self, from: data).choices.first?.message.content else {
            throw LLMError(description: "No choices in response")
        }
        return content
    }

    /// Decodes the first balanced JSON object in `raw`, tolerating prose and code fences around it.
    public static func parseEditResult(_ raw: String) throws -> EditResult {
        let chars = Array(raw)
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
