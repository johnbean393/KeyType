//
//  OpenAICompletionEngine.swift
//  KeyType
//
//  A CompletionEngine that routes prompts to any OpenAI-compatible chat endpoint (LM Studio,
//  Ollama, vLLM, cloud APIs) instead of running a local GGUF model. This saves Mac GPU/RAM
//  resources by offloading inference to an external server.
//

import AutocompleteCore
import Foundation

/// Configuration for an OpenAI-compatible API endpoint.
struct APIModelConfig: Codable, Equatable, Identifiable {
    var id: UUID
    /// User-visible label (e.g. "LM Studio - Qwen 2.5").
    var displayName: String
    /// Base URL of the API (e.g. "http://localhost:1234/v1").
    var endpoint: String
    /// API key, or empty for local servers that don't require one.
    var apiKey: String
    /// Model name sent in the request body (e.g. "qwen2.5-7b-instruct").
    var modelName: String

    init(
        id: UUID = UUID(),
        displayName: String,
        endpoint: String,
        apiKey: String = "",
        modelName: String
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.modelName = modelName
    }
}

/// Completion engine that sends prompts to an OpenAI-compatible chat API.
///
/// Converts the prompt built by KeyType into a chat message, sends it to the configured
/// endpoint, and wraps the response text back into `CompletionCandidate`s.
final class OpenAICompletionEngine: CompletionEngine {
    private let config: APIModelConfig
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(config: APIModelConfig) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - CompletionEngine

    func completions(for request: CompletionRequest) async throws -> [CompletionCandidate] {
        // Build the chat request from the prompt KeyType constructed.
        let url = try buildURL(path: "/chat/completions")
        let body = ChatCompletionRequest(
            model: config.modelName,
            messages: [.init(role: "user", content: request.prompt)],
            maxTokens: max(1, request.maxCompletionTokens),
            temperature: 0,
            stream: false
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<empty>"
            throw OpenAIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        let chatResponse = try decoder.decode(ChatCompletionResponse.self, from: data)

        guard let choice = chatResponse.choices.first else {
            return []
        }

        let text = choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        return [
            CompletionCandidate(
                text: text,
                logProbability: 0,   // remote APIs don't expose per-token logprobs reliably
                displayWidth: text.count,
                mode: request.mode
            )
        ]
    }

    func warmUp(for request: CompletionRequest) async throws {
        // Lightweight connectivity check: list models or just a minimal completion.
        // If the endpoint is unreachable the error surfaces on the first real generation.
        _ = try await completions(for: request)
    }

    func shutdown() async {
        session.invalidateAndCancel()
    }

    // MARK: - Helpers

    private func buildURL(path: String) throws -> URL {
        let base = config.endpoint.hasSuffix("/") ? String(config.endpoint.dropLast()) : config.endpoint
        guard let url = URL(string: base + path) else {
            throw OpenAIError.invalidURL(config.endpoint + path)
        }
        return url
    }
}

// MARK: - OpenAI API types

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let maxTokens: Int
    let temperature: Double
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxTokens = "max_tokens"
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Decodable {
        let role: String?
        let content: String
    }
}

// MARK: - Errors

enum OpenAIError: Error, LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case let .invalidURL(url):
            return "Invalid API endpoint URL: \(url)"
        case .invalidResponse:
            return "Invalid response from API server"
        case let .httpError(code, body):
            return "API returned HTTP \(code): \(body)"
        }
    }
}