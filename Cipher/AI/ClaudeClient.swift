import Foundation

struct Suggestion: Codable, Identifiable, Hashable, Sendable {
    /// The line as it would appear in the verse.
    let text: String
    /// One sentence on the device at work.
    let note: String

    var id: String { text }
}

/// What a word means and evokes across the writer's languages.
struct Meanings: Codable, Sendable {
    struct Word: Codable, Identifiable, Hashable, Sendable {
        /// "English", "Hindi", ...
        let language: String
        let word: String
        /// Roman-letter form when the word is in another script; otherwise empty.
        let roman: String
        let note: String

        var id: String { language + word }
    }

    struct Image: Codable, Identifiable, Hashable, Sendable {
        let image: String
        let note: String

        var id: String { image }
    }

    /// The same sense in the other languages.
    let literal: [Word]
    /// What the word stands for: its associations, connotations and cultural weight.
    let symbolic: [Image]
    /// Words in any of the languages that sound like it but mean something else.
    let wordplay: [Word]
}

enum AssistError: LocalizedError {
    case missingKey, invalidKey, rateLimited, overloaded, refused, truncated, unreadable
    case api(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add your Anthropic API key in Settings to use Assist."
        case .invalidKey: "Anthropic rejected the API key. Check it in Settings."
        case .rateLimited: "Rate limited. Give it a moment and try again."
        case .overloaded: "Claude is overloaded right now. Try again shortly."
        case .refused: "Claude declined this one. Try rephrasing the direction."
        case .truncated: "The response was cut off. Try again."
        case .unreadable: "Couldn't read the response. Try again."
        case .api(let message): message
        case .network(let message): message
        }
    }
}

/// Minimal Messages API client. There is no official Swift SDK, so this is raw HTTP.
/// A pair Claude found that holds the writer's relation.
struct AnalogyPair: Codable, Identifiable, Hashable, Sendable {
    let left: String
    let right: String
    /// "strict", "close" or "loose".
    let strictness: String
    let note: String

    var id: String { left + " : " + right }
    var text: String { "\(left) : \(right)" }
    var looseness: Double {
        switch strictness {
        case "strict": 0
        case "close": 0.5
        default: 1
        }
    }
}

/// A far jump Claude proposed from the current word: an idiom twisted, a reference, a pun.
struct LeapStep: Codable, Identifiable, Hashable, Sendable {
    let text: String
    /// The move: "idiom twist", "reference", "re-segmentation", "reversal", "register jump", "cross-language pun", "sense drift".
    let move: String
    let why: String
    /// 1 tight to the word, 0 a lateral leap.
    let weight: Double

    var id: String { text }
}

struct ClaudeClient: Sendable {
    static let model = "claude-opus-5-5"

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": Array(properties.keys).sorted(), "additionalProperties": false]
    }

    private static func list(_ item: [String: Any]) -> [String: Any] { ["type": "array", "items": item] }

    private static let string: [String: Any] = ["type": "string"]

    // Structured outputs: the API guarantees the reply parses against these schemas.
    private static let suggestionSchema = object(["suggestions": list(object(["text": string, "note": string]))])

    private static let meaningsSchema: [String: Any] = {
        let word = object(["language": string, "word": string, "roman": string, "note": string])
        return object(["literal": list(word), "symbolic": list(object(["image": string, "note": string])), "wordplay": list(word)])
    }()

    private struct Reply: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stop_reason: String?
    }

    private struct SuggestionPayload: Decodable { let suggestions: [Suggestion] }
    private struct AnalogyPayload: Decodable { let pairs: [AnalogyPair] }
    private struct LeapPayload: Decodable { let steps: [LeapStep] }
    private static let leapSchema = object(["steps": list(object(["text": string, "move": string, "why": string, "weight": ["type": "number"]]))])
    private static let analogySchema = object(["pairs": list(object(["left": string, "right": string, "strictness": string, "note": string]))])

    private struct APIFailure: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    func suggestions(prompt: String, depth: AssistDepth) async throws -> [Suggestion] {
        let payload: SuggestionPayload = try await request(prompt: prompt, schema: Self.suggestionSchema, depth: depth)
        return payload.suggestions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The decoded answer and its raw JSON, so it can be cached as-is.
    func leaps(prompt: String, depth: AssistDepth) async throws -> [LeapStep] {
        let payload: LeapPayload = try await request(prompt: prompt, schema: Self.leapSchema, depth: depth)
        return payload.steps
    }

    func analogies(prompt: String, depth: AssistDepth) async throws -> [AnalogyPair] {
        let payload: AnalogyPayload = try await request(prompt: prompt, schema: Self.analogySchema, depth: depth)
        return payload.pairs
    }

    func meanings(prompt: String, depth: AssistDepth) async throws -> (Meanings, Data) {
        let data = try await send(prompt: prompt, schema: Self.meaningsSchema, depth: depth)
        guard let meanings = try? JSONDecoder().decode(Meanings.self, from: data) else { throw AssistError.unreadable }
        return (meanings, data)
    }

    private func request<T: Decodable>(prompt: String, schema: [String: Any], depth: AssistDepth) async throws -> T {
        let data = try await send(prompt: prompt, schema: schema, depth: depth)
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw AssistError.unreadable }
        return decoded
    }

    /// Returns the model's JSON text.
    private func send(prompt: String, schema: [String: Any], depth: AssistDepth) async throws -> Data {
        do {
            return try await send(prompt: prompt, schema: schema, depth: depth, withFallbacks: true)
        } catch AssistError.api(let message) where message.localizedCaseInsensitiveContains("fallback") {
            // The fallback beta isn't enabled for every account; the request is fine without it.
            return try await send(prompt: prompt, schema: schema, depth: depth, withFallbacks: false)
        }
    }

    private func send(prompt: String, schema: [String: Any], depth: AssistDepth, withFallbacks: Bool) async throws -> Data {
        guard let key = Keychain.apiKey else { throw AssistError.missingKey }
        var body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "system": Prompts.system,
            "output_config": [
                "effort": depth.rawValue,
                "format": ["type": "json_schema", "schema": schema],
            ],
            "messages": [["role": "user", "content": prompt]],
        ]
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if withFallbacks {
            // If a safety classifier declines, retry server-side on Anthropic's recommended fallback.
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AssistError.network(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            switch status {
            case 401, 403: throw AssistError.invalidKey
            case 429: throw AssistError.rateLimited
            case 500...599: throw AssistError.overloaded
            default:
                let message = (try? JSONDecoder().decode(APIFailure.self, from: data))?.error.message
                throw AssistError.api(message ?? "Request failed (\(status)).")
            }
        }

        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw AssistError.unreadable }
        // A refusal is a normal 200; its content is not guaranteed to match the schema.
        if reply.stop_reason == "refusal" { throw AssistError.refused }
        if reply.stop_reason == "max_tokens" { throw AssistError.truncated }
        return Data(reply.content.filter { $0.type == "text" }.compactMap(\.text).joined().utf8)
    }
}
