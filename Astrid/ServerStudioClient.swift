//
//  ServerStudioClient.swift
//  Astrid
//
//  HTTP client and shared chat message model for Server's OpenAI-compatible API.
//  Used by ChatViewModel to send chat completions and auxiliary requests.
//  Also used by ServerSettingsView to normalize the base URL for validation.
//  Copyright © 2026 Astrid Workshop.
//  Licensed under the terms in the LICENSE file.
//
//  Responsibilities (current):
//  - Thin HTTP client for Server’s OpenAI-compatible endpoint: `/v1/chat/completions`.
//  - Defines UI-facing `ChatMessage` + role model and converts transcripts to API payloads.
//  - Sends non-streaming chat completions for:
//      - Full chat replies (system prompt + transcript)
//      - Short auxiliary completions (e.g., title generation)
//  - Decodes `finish_reason` and token `usage` for diagnostics.
//
//  Token budgets (intentional):
//  - Chat replies: higher `max_tokens` to avoid premature cutoffs.
//  - Title generation: low `max_tokens` to keep it fast and low-memory.
//
//  Networking notes:
//  - Uses a conservative request timeout to avoid client disconnects during long generations.
//  - Streaming is intentionally OFF for Milestone 1 (reserved for a future milestone).
//
//  Debugging:
//  - DEBUG-only logs print `finish_reason`, token usage, character counts, and content tail to
//    help diagnose truncation vs model stop conditions.

import Foundation

// MARK: - UI Chat Message Model

enum ChatRole: String, Codable {
    case system
    case user
    case assistant
    case error
}

/// App-facing chat message used by the UI transcript.
/// (Separate from the API request model below.)
struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    var role: ChatRole
    var content: String
    var createdAt: Date

    init(id: UUID = UUID(), role: ChatRole, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

extension Array where Element == ChatMessage {
    /// Converts UI messages into the OpenAI-style role/content array.
    /// `.error` messages are excluded from the payload by default.
    func asAPIMessageArray() -> [ChatCompletionRequest.Message] {
        self.compactMap { msg in
            guard msg.role != .error else { return nil }
            return .init(role: msg.role.rawValue, content: msg.content)
        }
    }
}

// MARK: - Models (OpenAI-style /v1/chat/completions)

struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double?
    let max_tokens: Int?
    let stream: Bool?
}

struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct AssistantMessage: Decodable {
            let role: String
            let content: String
        }
        let index: Int
        let message: AssistantMessage
        let finish_reason: String?
    }

    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
    }

    let choices: [Choice]
    let usage: Usage?
}

// MARK: - Server Client

final class ServerClient {
    enum ClientError: Error, LocalizedError {
        case badURL
        case serverUnreachable(String)
        case requestTimedOut
        case httpStatus(Int, String)
        case noChoices
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .badURL:
                return "Bad server URL. Check your Server connection settings."
            case .serverUnreachable(let detail):
                return "Server is not reachable. Make sure the server is running and the URL is correct.\n\n\(detail)"
            case .requestTimedOut:
                return "The request timed out. Server may be busy or the model may be too slow to respond."
            case .httpStatus(let code, let body):
                return "Server returned HTTP \(code).\n\(body)"
            case .noChoices:
                return "Server returned an empty response. The model may still be loading — try again in a moment."
            case .decodingFailed(let detail):
                return "Unexpected response from Server. The server may be loading a model or returned an invalid response.\n\n\(detail)"
            }
        }
    }

    private let baseURL: URL
    var baseURLString: String { baseURL.absoluteString }

    // MARK: - Token budgets
    // Keep chat completions generous to avoid premature cutoffs.
    private let chatMaxTokens: Int = 4096
    // Titles must be fast and short.
    private let titleMaxTokens: Int = 64

    // MARK: - Timeout configuration
    // Connection timeout: how long to wait for initial server contact.
    private static let connectionTimeout: TimeInterval = 10
    // Chat response timeout: total time allowed for a full chat completion.
    private static let chatResponseTimeout: TimeInterval = 60
    // Title response timeout: titles are short; no need to wait as long.
    private static let titleResponseTimeout: TimeInterval = 30

    /// Shared URLSession with connection timeout configured.
    /// `timeoutIntervalForRequest` controls connection/idle timeout.
    /// Per-request `timeoutInterval` on URLRequest controls total request duration.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = connectionTimeout
        return URLSession(configuration: config)
    }()

    init(baseURL: String) {
        let fallback = "http://127.0.0.1:1234"

        // Trim outer whitespace/newlines.
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = fallback }

        // Remove any accidental internal spaces (common when copy/pasting).
        s = s.replacingOccurrences(of: " ", with: "")

        // Normalize scheme check to be case-insensitive.
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            s = "http://" + s
        }

        // Remove trailing slashes for consistency.
        while s.hasSuffix("/") { s.removeLast() }

        // If user pastes /v1 or /v1/ (common in docs), normalize to host:port.
        if s.hasSuffix("/v1") {
            s = String(s.dropLast(3))
            while s.hasSuffix("/") { s.removeLast() }
        }

        self.baseURL = URL(string: s) ?? URL(string: fallback)!
    }

    func send(prompt: String, model: String) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("v1/chat/completions")

        let reqBody = ChatCompletionRequest(
            model: model,
            messages: [
                .init(role: "user", content: prompt)
            ],
            temperature: 0.7,
            max_tokens: titleMaxTokens,
            stream: false
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(reqBody)
        request.timeoutInterval = Self.titleResponseTimeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let urlError as URLError {
            throw Self.classifyURLError(urlError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.serverUnreachable("No HTTP response received.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            throw ClientError.httpStatus(http.statusCode, body)
        }

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "(unreadable)"
            throw ClientError.decodingFailed("Could not parse response: \(error.localizedDescription)\nResponse start: \(snippet)")
        }
        guard let first = decoded.choices.first else { throw ClientError.noChoices }

        return first.message.content
    }

    /// Sends a full transcript (non-streaming) using OpenAI-style /v1/chat/completions.
    /// - Note: `systemPrompt` is inserted as the first message unless the transcript already contains a `.system` message.
    func send(messages: [ChatMessage], model: String, systemPrompt: String) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("v1/chat/completions")

        var apiMessages = messages.asAPIMessageArray()
        let hasSystem = apiMessages.contains(where: { $0.role == "system" })
        if !hasSystem {
            apiMessages.insert(.init(role: "system", content: systemPrompt), at: 0)
        }

        #if DEBUG
        // 8B-Prime-2: Log system prompt verification info
        let promptHash = systemPrompt.hashValue
        let promptLength = systemPrompt.count
        let promptPreview = systemPrompt.prefix(80).replacingOccurrences(of: "\n", with: "⏎")
        print("[8B-Prime-2:API] systemPrompt hash=\(promptHash) length=\(promptLength) preview=\"\(promptPreview)...\"")
        #endif

        let reqBody = ChatCompletionRequest(
            model: model,
            messages: apiMessages,
            temperature: 0.7,
            max_tokens: chatMaxTokens,
            stream: false
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(reqBody)
        request.timeoutInterval = Self.chatResponseTimeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let urlError as URLError {
            throw Self.classifyURLError(urlError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.serverUnreachable("No HTTP response received.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            throw ClientError.httpStatus(http.statusCode, body)
        }

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "(unreadable)"
            throw ClientError.decodingFailed("Could not parse response: \(error.localizedDescription)\nResponse start: \(snippet)")
        }
        guard let first = decoded.choices.first else { throw ClientError.noChoices }

        return first.message.content
    }

    // MARK: - Error Classification

    /// Maps URLError codes to user-friendly ClientError cases.
    private static func classifyURLError(_ error: URLError) -> ClientError {
        switch error.code {
        case .timedOut:
            return .requestTimedOut
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost:
            return .serverUnreachable("Connection failed: \(error.localizedDescription)")
        case .notConnectedToInternet:
            return .serverUnreachable("This device is not connected to the internet.")
        case .secureConnectionFailed:
            return .serverUnreachable("Secure connection failed. Server typically uses http://, not https://.")
        default:
            return .serverUnreachable("Network error: \(error.localizedDescription)")
        }
    }
}
