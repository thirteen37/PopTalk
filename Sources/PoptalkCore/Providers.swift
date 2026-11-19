import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Language-model backends shared by the app's `--pipeline` debug mode and PoptalkBench.
public enum Providers {
    /// `provider`: `lmstudio` (any OpenAI-compatible server at `baseURL`), `apple` (on-device
    /// FoundationModels, macOS 26+) or `apple-pcc` (Private Cloud Compute, macOS 27+, needs Apple's entitlement).
    /// `appleVariant` (`core3`/`coreAdvanced3`), when given, must match the device's on-device model.
    /// Returns the completion function and metadata describing the model.
    public static func make(_ provider: String, baseURL: URL, appleVariant: String? = nil) throws -> (Pipeline.Complete, [String: String]) {
        switch provider {
        case "lmstudio":
            let client = LLMClient(baseURL: baseURL)
            return ({ try await client.complete(model: $0, messages: $1, json: $2, timeout: $3) }, ["baseURL": baseURL.absoluteString])
        #if canImport(FoundationModels)
        case "apple":
            guard #available(macOS 26, *) else { throw LLMError(description: "apple needs macOS 26") }
            let model = SystemLanguageModel.default
            guard case .available = model.availability else {
                throw LLMError(description: "Apple Intelligence unavailable: \(model.availability)")
            }
            var meta = ["contextSize": "\(model.contextSize)"]
            if #available(macOS 27, *) {
                meta["variant"] = model.variant.displayName
                if let want = appleVariant {
                    let variants = ["core3": SystemLanguageModel.Variant.core3, "coreAdvanced3": .coreAdvanced3]
                    guard let v = variants[want] else { throw LLMError(description: "unknown Apple variant \(want); use core3 or coreAdvanced3") }
                    guard v == model.variant else {
                        throw LLMError(description: "this device runs \(model.variant.displayName), not \(v.displayName)")
                    }
                }
            }
            return ({ _, messages, _, _ in
                let session = LanguageModelSession(instructions: messages.first { $0.role == "system" }?.content ?? "")
                return try await session.respond(to: messages.last!.content, options: GenerationOptions(temperature: 0)).content
            }, meta)
        case "apple-pcc":
            guard #available(macOS 27, *) else { throw LLMError(description: "apple-pcc needs macOS 27") }
            let pcc = PrivateCloudComputeLanguageModel()
            guard case .available = pcc.availability else { throw LLMError(description: "PCC unavailable: \(pcc.availability)") }
            return ({ _, messages, _, _ in
                let session = LanguageModelSession(model: pcc, instructions: messages.first { $0.role == "system" }?.content ?? "")
                do { return try await session.respond(to: messages.last!.content, options: GenerationOptions(temperature: 0)).content }
                catch { FileHandle.standardError.write(Data("PCC error: \(error)\n".utf8)); throw error }
            }, [:])
        #endif
        default:
            throw LLMError(description: "unknown provider \(provider); use lmstudio, apple or apple-pcc")
        }
    }
}
