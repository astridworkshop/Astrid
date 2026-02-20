//
//  ChatSession.swift
//  Astrid
//
//  Canonical chat session model persisted by ChatViewModel and rendered via ContentView.
//  Used as the source of truth for per-session transcript and metadata.
//  Copyright © 2026 Astrid Workshop.
//  Licensed under the terms in the LICENSE file.
//
//  Responsibilities (current):
//  - Defines the canonical ChatSession identity used throughout the app.
//  - Stores immutable session inputs (profile/system prompt snapshot).
//  - Stores per-session transcript messages (source of truth for chat history).
//  - Stores per-session metadata used by history UI (lastActivityAt, title).
//  - Encodes/decodes cleanly for JSON persistence (Application Support).

import Foundation

/// Identifies a single chat "session" (conversation) by ID and immutable snapshot inputs.
/// Messages are stored per session starting in Session 6C to enable per-session transcripts and persistence.
struct ChatSession: Identifiable, Codable {
    /// Bump this if you later persist sessions and need to migrate stored data.
    static let currentSchemaVersion: Int = 2

    /// Stable identity for this chat (future: history list, persistence, deep links).
    let id: UUID

    /// When this session was created.
    let createdAt: Date

    /// Last time this session was active (future: sort by "recently active" without messages).
    var lastActivityAt: Date

    /// Schema version for forward compatibility if/when sessions are persisted.
    let schemaVersion: Int

    /// Immutable snapshot of inputs that must not change mid-chat.
    let profileSnapshot: ProfileSnapshot

    /// Per-session transcript messages (source of truth for the chat transcript).
    var messages: [ChatMessage] = []
    
    // Session 7B: Neutral sidebar title. Persisted once and never regenerated.
    var title: String?

    // Session 7B: When the title was generated (or set via fallback).
    var titleGeneratedAt: Date?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        lastActivityAt: Date? = nil,
        schemaVersion: Int = ChatSession.currentSchemaVersion,
        profileSnapshot: ProfileSnapshot,
        messages: [ChatMessage] = [],
        title: String? = nil,
        titleGeneratedAt: Date? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt ?? createdAt
        self.schemaVersion = schemaVersion
        self.profileSnapshot = profileSnapshot
        self.messages = messages
        self.title = title
        self.titleGeneratedAt = titleGeneratedAt
    }

    // MARK: - Identity semantics

    /// Sessions are identified by `id`. This keeps equality/hash stable even as messages grow.
    static func == (lhs: ChatSession, rhs: ChatSession) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Snapshot of profile-derived inputs that define a chat session.
/// Profile changes elsewhere in the app should not affect an active session.
struct ProfileSnapshot: Codable, Equatable, Hashable {
    /// The profile name at the moment the chat started.
    let profileName: String

    /// The system prompt text captured at the moment the chat started.
    let systemPromptSnapshot: String

    init(profileName: String, systemPromptSnapshot: String) {
        self.profileName = profileName
        self.systemPromptSnapshot = systemPromptSnapshot
    }
}
