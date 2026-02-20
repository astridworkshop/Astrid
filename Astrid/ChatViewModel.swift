//
//  ChatViewModel.swift
//  Astrid
//
//  Chat session state manager and persistence layer for the chat UI.
//  Used by ContentView to drive session lists, message display, and actions; its data is passed through to AstridSidebarView.
//  Copyright © 2026 Astrid Workshop.
//  Licensed under the terms in the LICENSE file.
//
//  Responsibilities (current):
//  - Owns chat session lifecycle and identity (`sessions[]`, `activeSessionID`).
//  - Provides a compatibility `messages` view over the active session transcript.
//  - Routes send/retry through Server with request/session isolation so late responses cannot land in the wrong chat.
//  - Manages runtime-only UI state (draft input, sending/typing flags, status, errors).
//  - Persists chat state to disk (JSON in Application Support) and restores on launch.
//
//  Important boundaries / guardrails:
//  - No chat history UI is implemented here (sidebar lives in ContentView).
//  - No persistence UI or cloud sync.
//  - Runtime-only state is never persisted.


import Foundation
import Combine

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var input: String = ""
    /// Compatibility view over the active session transcript.
    /// Source of truth is `sessions[idx].messages`.
    var messages: [ChatMessage] {
        activeSession?.messages ?? []
    }
    @Published var status: String = "Idle"
    @Published var lastError: String?
    @Published var isSending: Bool = false
    @Published var isAssistantTyping: Bool = false

    // MARK: - Session identity (Session 6B)

    /// In-memory list of chat sessions (metadata only). No persistence UI in Session 6B.
    @Published private(set) var sessions: [ChatSession] = []

    /// The currently active session ID (used to associate runtime chat state with a session identity).
    @Published private(set) var activeSessionID: UUID?

    /// Convenience accessor for the active session metadata.
    var activeSession: ChatSession? {
        guard let id = activeSessionID else { return nil }
        return sessions.first(where: { $0.id == id })
    }

    private var persistenceURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Astrid", isDirectory: true)

        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        return dir.appendingPathComponent("chat_state_v1.json", isDirectory: false)
    }


    // MARK: - Server model resolution (Auto-follow current loaded model)

    /// The model id currently reported by Server (/v1/models). When nil, Astrid should block sends.
    @Published private(set) var resolvedModelAPIName: String?

    /// True when Server responds successfully to /v1/models.
    @Published private(set) var isServerReachable: Bool = false

    /// Human-readable status for UI/debug (e.g., "Connected — llama-3.1-8b", "No model loaded", "Unreachable").
    @Published private(set) var ServerModelStatus: String = "Unknown"

    private let client: ServerClient

    private static let serverURLDefaultsKey = "Server.serverURL"

    private func configuredClient() -> ServerClient {
        let fallback = "http://127.0.0.1:1234"
        let raw = UserDefaults.standard.string(forKey: Self.serverURLDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let chosen = (raw?.isEmpty == false) ? raw! : fallback
        return ServerClient(baseURL: chosen)
    }

    private func configuredBaseURLString() -> String {
        let fallback = "http://127.0.0.1:1234"
        let raw = UserDefaults.standard.string(forKey: Self.serverURLDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = (raw?.isEmpty == false) ? raw! : fallback
        return ServerClient(baseURL: chosen).baseURLString
    }

    private var activeRequestID: UUID?
    /// The session ID that initiated the current in-flight request (if any).
    /// Used to ensure responses cannot append into a different session after a session switch.
    private var activeRequestSessionID: UUID?
    private var activeRequestTask: Task<Void, Never>?

    // MARK: - Session 7B: Title generation (neutral, one-shot, non-blocking)
    // MARK: - Server discovery (/v1/models)

    private struct LMModelsResponse: Codable {
        struct Model: Codable {
            let id: String
        }
        let data: [Model]
    }

    /// Refreshes `resolvedModelAPIName` by querying Server's OpenAI-like `/v1/models` endpoint.
    /// Assumption: Server returns the currently loaded model as the first (and often only) entry.
    func refreshServerModel() async {
        // Normalize to avoid double `/v1` or trailing slash issues.
        let normalizedBase = ServerClient(baseURL: configuredBaseURLString()).baseURLString
        guard let url = URL(string: normalizedBase)?.appendingPathComponent("v1").appendingPathComponent("models") else {
            isServerReachable = false
            resolvedModelAPIName = nil
            ServerModelStatus = "Invalid server URL"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                isServerReachable = false
                resolvedModelAPIName = nil
                ServerModelStatus = "Unreachable"
                return
            }

            let decoded = try JSONDecoder().decode(LMModelsResponse.self, from: data)
            isServerReachable = true

            if let first = decoded.data.first?.id, !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resolvedModelAPIName = first
                ServerModelStatus = "Connected — \(first)"
            } else {
                resolvedModelAPIName = nil
                ServerModelStatus = "Connected — No model loaded"
            }
        } catch {
            isServerReachable = false
            resolvedModelAPIName = nil
            ServerModelStatus = "Unreachable"
        }
    }

    /// Runtime-only guard to prevent duplicate title generation tasks per session.
    private var titleGenerationInFlight: Set<UUID> = []

    /// Fixed neutral system prompt for title generation (must NOT use the session profile snapshot).
    private static let titleSystemPrompt: String = "You generate short, neutral chat titles. Return ONLY the title text. 3–7 words. No quotes. No emojis. No trailing punctuation."

    /// Fixed user instruction for title generation.
    private static let titleUserPromptPrefix: String = "Generate a neutral title for this conversation:"

    // MARK: - Persistence (Session 6C)

    nonisolated private struct PersistedState: Codable {
        var schemaVersion: Int
        var activeSessionID: UUID?
        var sessions: [ChatSession]
    }

    private let persistenceSchemaVersion: Int = 1
    private var pendingSaveTask: Task<Void, Never>?

    init(client: ServerClient) {
        self.client = client
        loadPersistedState()
        Task { [weak self] in
            await self?.refreshServerModel()
        }
    }

    // MARK: - Session lifecycle (Session 6B)

    /// Creates a new session from an immutable profile snapshot and makes it active.
    /// This does not touch messages/UI state; call `resetChat()` separately when starting a new chat.
    @discardableResult
    func beginNewSession(profileName: String, systemPromptSnapshot: String) -> ChatSession {
        let snapshot = ProfileSnapshot(profileName: profileName, systemPromptSnapshot: systemPromptSnapshot)
        let session = ChatSession(profileSnapshot: snapshot)
        sessions.append(session)
        activeSessionID = session.id
        scheduleSavePersistedState()

        #if DEBUG
        print("[Session6B] beginNewSession id=\(session.id.uuidString) profile=\(profileName)")
        // 8B-Prime-2: Enhanced logging for profile system prompt verification
        let promptHash = systemPromptSnapshot.hashValue
        let promptLength = systemPromptSnapshot.count
        print("[8B-Prime-2:NewSession] profile=\"\(profileName)\" promptHash=\(promptHash) promptLength=\(promptLength) sessionID=\(session.id.uuidString.prefix(8))")
        #endif

        return session
    }

    /// Session 7A: Switch the active session and reset runtime-only UI state.
    /// - Important: Does not modify transcripts or persisted session data.
    func selectSession(id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }

        // Switching sessions must invalidate any in-flight request from the previous session.
        activeSessionID = id

        // Reset runtime-only state (never persisted).
        isSending = false
        isAssistantTyping = false
        activeRequestID = nil
        activeRequestSessionID = nil
        lastError = nil
        status = "Idle"

        #if DEBUG
        print("[Session7A] selectSession activeSessionID=\(id.uuidString)")
        #endif
    }

    // MARK: - Session 7.5: Delete Chat (Manual Only)

    /// Deletes a single chat session (transcript + title) and persists immediately.
    /// - Returns: `true` if the deleted session was the active session.
    @discardableResult
    func deleteSession(id: UUID) -> Bool {
        let wasActive = (activeSessionID == id)

        // Remove the session and its transcript/title.
        sessions.removeAll(where: { $0.id == id })

        // Session 7.5 hardening: if a title task is in flight for this session, clear the guard.
        titleGenerationInFlight.remove(id)

        if wasActive {
            // Clear active selection. Caller is responsible for starting a new chat.
            activeSessionID = nil

            // Reset runtime-only UI state (never persisted).
            input = ""
            isSending = false
            isAssistantTyping = false
            activeRequestID = nil
            activeRequestSessionID = nil
            lastError = nil
            status = "Idle"

            #if DEBUG
            print("[Session7.5] deleteSession deleted ACTIVE session id=\(id.uuidString)")
            #endif
        } else {
            #if DEBUG
            print("[Session7.5] deleteSession deleted session id=\(id.uuidString)")
            #endif
        }

        // Persist immediately (do not wait for the coalesced scheduler).
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        Task { [weak self] in
            await self?.savePersistedStateNow()
        }

        return wasActive
    }

    /// Updates `lastActivityAt` for the active session (best-effort; no-op if no session is active).
    private func touchActiveSession() {
        guard let id = activeSessionID, let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].lastActivityAt = Date()
        scheduleSavePersistedState()

        #if DEBUG
        print("[Session6B] touchActiveSession id=\(id.uuidString) lastActivityAt=\(sessions[idx].lastActivityAt)")
        #endif
    }

    /// Mutate the active session inside the `sessions` array so observers see updates.
    private func updateActiveSession(_ mutate: (inout ChatSession) -> Void) {
        guard let id = activeSessionID,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        var session = sessions[idx]
        mutate(&session)
        sessions[idx] = session
        scheduleSavePersistedState()
    }

    /// Mutate a specific session inside the `sessions` array so observers see updates.
    private func updateSession(id: UUID, _ mutate: (inout ChatSession) -> Void) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        var session = sessions[idx]
        mutate(&session)
        sessions[idx] = session
        scheduleSavePersistedState()
    }

    /// Deterministic fallback title if generation fails.
    private func fallbackTitle(for session: ChatSession) -> String {
        if let firstUser = session.messages.first(where: { $0.role == .user })?.content {
            let trimmed = firstUser.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(42))
            }
        }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return "Chat — \(df.string(from: session.createdAt))"
    }

    /// Sanitize model output into a stable title.
    private func sanitizeTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        // Remove surrounding quotes if present.
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }

        // Strip common leading prefixes the model might include.
        let lower = s.lowercased()
        let prefixes = ["title:", "chat title:", "conversation title:"]
        if let p = prefixes.first(where: { lower.hasPrefix($0) }) {
            s = String(s.dropFirst(p.count)).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }

        // Strip simple markdown wrappers.
        if s.hasPrefix("**") && s.hasSuffix("**") && s.count >= 4 {
            s = String(s.dropFirst(2).dropLast(2)).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }
        if s.hasPrefix("`") && s.hasSuffix("`") && s.count >= 2 {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }

        // Collapse newlines/tabs into spaces.
        s = s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        // Collapse repeated spaces.
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        // Clamp length.
        if s.count > 60 { s = String(s.prefix(60)) }
        // Remove trailing punctuation.
        while let last = s.last, ".,;:!?".contains(last) { s.removeLast() }
        return s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    /// Session 7B: Generate a neutral title once, after the first assistant reply.
    private func maybeGenerateTitle(for sessionID: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let session = sessions[idx]

        // Only generate once.
        guard session.title == nil else { return }

        // Locked rule: only after first assistant reply exists.
        guard session.messages.contains(where: { $0.role == .assistant }) else { return }

        // Use Server's currently resolved model.
        let model = self.resolvedModelAPIName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if model.isEmpty {
            let fallback = self.fallbackTitle(for: session)
            updateSession(id: sessionID) {
                $0.title = fallback
                $0.titleGeneratedAt = Date()
            }
            return
        }

        // Avoid duplicate in-flight tasks.
        guard !titleGenerationInFlight.contains(sessionID) else { return }
        titleGenerationInFlight.insert(sessionID)

        // Build minimal context: first user + first assistant.
        let firstUser = session.messages.first(where: { $0.role == .user })?.content ?? ""
        let firstAssistant = session.messages.first(where: { $0.role == .assistant })?.content ?? ""
        let context = "User: \(firstUser)\nAssistant: \(firstAssistant)"
        let titleUserPrompt = "\(Self.titleUserPromptPrefix)\n\n\(context)"

        Task { [weak self] in
            guard let self else { return }
            defer {
                // Safe even if the session was deleted and we already removed it.
                self.titleGenerationInFlight.remove(sessionID)
            }

            do {
                // One-shot request using fixed neutral system prompt.
                // IMPORTANT: Use the title-budget client path (short max_tokens) to keep this fast and low-memory.
                let combinedPrompt = "System:\n\(Self.titleSystemPrompt)\n\nUser:\n\(titleUserPrompt)"
                let titleRaw = try await self.configuredClient().send(prompt: combinedPrompt, model: model)

                let title = self.sanitizeTitle(titleRaw)

                guard !title.isEmpty else {
                    let fallback = self.fallbackTitle(for: session)
                    self.updateSession(id: sessionID) {
                        $0.title = fallback
                        $0.titleGeneratedAt = Date()
                    }
                    return
                }

                // Only apply if still untitled.
                if let current = self.sessions.first(where: { $0.id == sessionID }), current.title == nil {
                    self.updateSession(id: sessionID) {
                        $0.title = title
                        $0.titleGeneratedAt = Date()
                    }
                }
            } catch {
                // Persist deterministic fallback once; never regenerate.
                if let current = self.sessions.first(where: { $0.id == sessionID }), current.title == nil {
                    let fallback = self.fallbackTitle(for: current)
                    self.updateSession(id: sessionID) {
                        $0.title = fallback
                        $0.titleGeneratedAt = Date()
                    }
                }
            }
        }
    }

    private func loadPersistedState() {
        let url = persistenceURL
        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)

            // Prefer ISO8601 (current format). If the file is from an earlier build,
            // dates may be numeric; fall back to the default decoder and then rewrite in ISO.
            let decoded: PersistedState
            do {
                let iso = JSONDecoder()
                iso.dateDecodingStrategy = .iso8601
                decoded = try iso.decode(PersistedState.self, from: data)
            } catch {
                let legacy = JSONDecoder() // default date decoding (numeric)
                decoded = try legacy.decode(PersistedState.self, from: data)

                #if DEBUG
                print("[Session6C] Loaded legacy persisted state (numeric dates). Will rewrite as ISO8601.")
                #endif

                // Rewrite in the current (ISO8601) format.
                scheduleSavePersistedState()
            }

            // Basic validation / self-heal
            guard !decoded.sessions.isEmpty else { return }

            self.sessions = decoded.sessions
            self.activeSessionID = decoded.activeSessionID

            // Self-heal activeSessionID if missing/invalid
            if let id = self.activeSessionID,
               !self.sessions.contains(where: { $0.id == id }) {
                self.activeSessionID = nil
            }
            if self.activeSessionID == nil {
                // Pick most recent by lastActivityAt
                if let best = self.sessions.max(by: { $0.lastActivityAt < $1.lastActivityAt }) {
                    self.activeSessionID = best.id
                } else {
                    self.activeSessionID = self.sessions.first?.id
                }
            }

            // Runtime-only flags must always reset on launch
            self.isSending = false
            self.isAssistantTyping = false
            self.activeRequestID = nil
            self.activeRequestSessionID = nil
            self.status = "Idle"
            self.lastError = nil

            #if DEBUG
            let count = self.sessions.count
            let active = self.activeSessionID?.uuidString ?? "nil"
            print("[Session6C] Loaded persisted state sessions=\(count) activeSessionID=\(active)")
            #endif

        } catch {
            // Failure-safe: move the corrupt file aside and continue fresh.
            let ts = Int(Date().timeIntervalSince1970)
            let backup = url.deletingLastPathComponent().appendingPathComponent("chat_state_v1.corrupt.\(ts).json")
            try? fm.moveItem(at: url, to: backup)

            #if DEBUG
            print("[Session6C] Failed to load persisted state. Moved file to \(backup.lastPathComponent). Error: \(error)")
            #endif
        }
    }

    private func scheduleSavePersistedState() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task {
            // Coalesce rapid writes to avoid UI hitching.
            try? await Task.sleep(nanoseconds: 350_000_000)
            await savePersistedStateNow()
        }
    }

    private func savePersistedStateNow() async {
        // Capture immutable snapshots on the main actor first.
        let url = persistenceURL
        let schemaVersion = persistenceSchemaVersion
        let activeID = activeSessionID
        let sessionsSnapshot = sessions

        // Build state locally (still on main actor), then hand off the raw data write off-main.
        let state = PersistedState(
            schemaVersion: schemaVersion,
            activeSessionID: activeID,
            sessions: sessionsSnapshot
        )

        await writePersistedState(state, to: url)
    }

    nonisolated private func writePersistedState(_ state: PersistedState, to url: URL) async {
        await Task.detached(priority: .utility) {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(state)
                try data.write(to: url, options: [.atomic])

                #if DEBUG
                print("[Session6C] Saved persisted state sessions=\(state.sessions.count)")
                #endif
            } catch {
                #if DEBUG
                print("[Session6C] Failed to save persisted state: \(error)")
                #endif
            }
        }.value
    }

    /// Primary send method: always uses Server's resolved model.
    func send(systemPrompt: String) {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard !isSending else { return }

        #if DEBUG
        // 8B-Prime-2: Log profile verification at send time
        if let session = activeSession {
            let snapshot = session.profileSnapshot
            let promptHash = snapshot.systemPromptSnapshot.hashValue
            let promptLength = snapshot.systemPromptSnapshot.count
            print("[8B-Prime-2:Send] profile=\"\(snapshot.profileName)\" promptHash=\(promptHash) promptLength=\(promptLength) sessionID=\(session.id.uuidString.prefix(8))")
        } else {
            print("[8B-Prime-2:Send] WARNING: No active session at send time")
        }
        #endif

        // Append the user message immediately and clear the input box.
        let userMessage = ChatMessage(role: .user, content: prompt)
        updateActiveSession { $0.messages.append(userMessage) }
        input = ""
        touchActiveSession()

        lastError = nil
        status = "Sending…"
        isSending = true
        isAssistantTyping = true

        let requestID = UUID()
        activeRequestID = requestID
        let requestSessionID = activeSessionID
        activeRequestSessionID = requestSessionID

        activeRequestTask?.cancel()
        let requestTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // If a reset or session switch happened mid-flight, a new request may be active; don't stomp its flags.
                if self.activeRequestID == requestID && self.activeRequestSessionID == requestSessionID {
                    self.isSending = false
                    self.isAssistantTyping = false
                    self.activeRequestID = nil
                    self.activeRequestSessionID = nil
                    self.activeRequestTask = nil
                }
            }

            // Resolve current model
            var model = self.resolvedModelAPIName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if model.isEmpty {
                await self.refreshServerModel()
                model = self.resolvedModelAPIName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if model.isEmpty {
                    if self.isServerReachable == false {
                        self.updateActiveSession { $0.messages.append(ChatMessage(role: .error, content: "Server is not reachable. Make sure the server is running and the URL is correct.")) }
                        self.status = "Error"
                        self.lastError = "Server is not reachable"
                        return
                    }
                    self.updateActiveSession { $0.messages.append(ChatMessage(role: .error, content: "No model loaded in Server. Load a model in Server and try again.")) }
                    self.status = "Error"
                    self.lastError = "No model loaded in Server"
                    return
                }
            }

            do {
                let text = try await self.configuredClient().send(messages: self.messages, model: model, systemPrompt: systemPrompt)
                guard self.activeRequestID == requestID,
                      self.activeRequestSessionID == requestSessionID,
                      requestSessionID == self.activeSessionID else { return }
                // Determine if this is the first assistant reply for this session (before append).
                let hadAssistantAlready = (self.activeSession?.messages.contains(where: { $0.role == .assistant }) ?? false)

                self.updateActiveSession { $0.messages.append(ChatMessage(role: .assistant, content: text)) }
                self.touchActiveSession()
                self.status = "Done"

                // Session 7B: Generate title after first assistant reply (non-blocking).
                if !hadAssistantAlready, let sid = requestSessionID {
                    self.maybeGenerateTitle(for: sid)
                }
            } catch {
                if Task.isCancelled { return }
                if let urlError = error as? URLError, urlError.code == .cancelled { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                guard self.activeRequestID == requestID,
                      self.activeRequestSessionID == requestSessionID,
                      requestSessionID == self.activeSessionID else { return }
                self.lastError = message
                self.updateActiveSession { $0.messages.append(ChatMessage(role: .error, content: message)) }
                self.status = "Error"
            }
        }
        activeRequestTask = requestTask
    }

    /// Primary retry method: always uses Server's resolved model.
    func retry(systemPrompt: String) {
        guard !isSending else { return }

        #if DEBUG
        // 8B-Prime-2: Log profile verification at retry time
        if let session = activeSession {
            let snapshot = session.profileSnapshot
            let promptHash = snapshot.systemPromptSnapshot.hashValue
            let promptLength = snapshot.systemPromptSnapshot.count
            print("[8B-Prime-2:Retry] profile=\"\(snapshot.profileName)\" promptHash=\(promptHash) promptLength=\(promptLength) sessionID=\(session.id.uuidString.prefix(8))")
        } else {
            print("[8B-Prime-2:Retry] WARNING: No active session at retry time")
        }
        #endif

        lastError = nil
        status = "Retrying…"
        isSending = true
        isAssistantTyping = true
        touchActiveSession()

        let requestID = UUID()
        activeRequestID = requestID
        let requestSessionID = activeSessionID
        activeRequestSessionID = requestSessionID

        activeRequestTask?.cancel()
        let requestTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // If a reset or session switch happened mid-flight, a new request may be active; don't stomp its flags.
                if self.activeRequestID == requestID && self.activeRequestSessionID == requestSessionID {
                    self.isSending = false
                    self.isAssistantTyping = false
                    self.activeRequestID = nil
                    self.activeRequestSessionID = nil
                    self.activeRequestTask = nil
                }
            }

            // Resolve current model
            var model = self.resolvedModelAPIName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if model.isEmpty {
                await self.refreshServerModel()
                model = self.resolvedModelAPIName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if model.isEmpty {
                    if self.isServerReachable == false {
                        self.updateActiveSession { $0.messages.append(ChatMessage(role: .error, content: "Server is not reachable. Make sure the server is running and the URL is correct.")) }
                        self.status = "Error"
                        self.lastError = "Server is not reachable"
                        return
                    }
                    self.updateActiveSession { $0.messages.append(ChatMessage(role: .error, content: "No model loaded in Server. Load a model in Server and try again.")) }
                    self.status = "Error"
                    self.lastError = "No model loaded in Server"
                    return
                }
            }

            do {
                // Re-send the existing transcript. `.error` messages are excluded by the mapping helper.
                let text = try await self.configuredClient().send(messages: self.messages, model: model, systemPrompt: systemPrompt)
                guard self.activeRequestID == requestID,
                      self.activeRequestSessionID == requestSessionID,
                      requestSessionID == self.activeSessionID else { return }
                // Determine if this is the first assistant reply for this session (before append).
                let hadAssistantAlready = (self.activeSession?.messages.contains(where: { $0.role == .assistant }) ?? false)

                self.updateActiveSession { $0.messages.append(ChatMessage(role: .assistant, content: text)) }
                self.touchActiveSession()
                self.status = "Done"

                // Session 7B: Generate title after first assistant reply (non-blocking).
                if !hadAssistantAlready, let sid = requestSessionID {
                    self.maybeGenerateTitle(for: sid)
                }
            } catch {
                if Task.isCancelled { return }
                if let urlError = error as? URLError, urlError.code == .cancelled { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                guard self.activeRequestID == requestID,
                      self.activeRequestSessionID == requestSessionID,
                      requestSessionID == self.activeSessionID else { return }
                self.lastError = message
                self.updateActiveSession { $0.messages.append(ChatMessage(role: .error, content: message)) }
                self.status = "Error"
            }
        }
        activeRequestTask = requestTask
    }

    func stopSending() {
        guard isSending else { return }
        activeRequestTask?.cancel()
        activeRequestTask = nil
        isSending = false
        isAssistantTyping = false
        activeRequestID = nil
        activeRequestSessionID = nil
        lastError = nil
        status = "Stopped"
    }

    func resetChat() {
        // Session 6C+: Do NOT clear persisted transcripts here.
        // `resetChat()` resets runtime-only UI state and draft input.
        input = ""

        // Stop any in-flight UX state.
        isAssistantTyping = false
        isSending = false
        activeRequestID = nil
        activeRequestSessionID = nil

        // Clear status/error.
        lastError = nil
        status = "Idle"

        #if DEBUG
        let idString = activeSessionID?.uuidString ?? "nil"
        print("[Session6B] resetChat activeSessionID=\(idString)")
        #endif
    }
}
