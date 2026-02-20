//
//  ContentView.swift
//  Astrid
//
//  Astrid’s primary UI shell and navigation container.
//  Hosts ChatViewModel-driven chat UI and delegates sidebar rendering to AstridSidebarView.
//  Copyright © 2026 Astrid Workshop.
//  Licensed under the terms in the LICENSE file.
//
//  Metadata:
//  - Build-based reset for profile switch warning preference.
//
//  Abstract:
//  Astrid’s primary UI shell.
//
//  This view uses a system-managed `NavigationSplitView` (iPad) and an overlay sidebar (iPhone)
//  to provide a predictable, non-bespoke navigation layout that avoids keyboard/safe-area regressions.
//
//  Detail column responsibilities:
//  - Launch-only splash screen that dismisses ONLY on input focus (one-way per launch).
//  - Chat transcript rendering with deterministic send flow:
//      user message → typing indicator → assistant response.
//  - Stable scrolling behavior (no auto-scroll unless pinned to bottom; preserves reading context).
//  - Bottom growing input bar (newline on Return; Cmd+Enter sends).
//
//  Sidebar responsibilities:
//  - Sidebar UI is rendered by `AstridSidebarView` (extracted to keep this file manageable).
//  - Owns sidebar/navigation state and actions:
//      - New Chat (`startNewChat()`; closes sidebar overlay on iPhone).
//      - History selection + session switching / in-flight request cancellation.
//      - Manual deletion  request + confirmation + immediate persistence.
//      - Settings selection and overlay dismissal behavior.
//  - Owns the data that feeds the sidebar:
//      - History eligibility (show only after first assistant reply).
//      - Title selection: persisted neutral title preferred, deterministic fallbacks.
//
//  Rendering notes:
//  - Assistant messages use a conservative Markdown block parser (paragraphs, bullets, ordered lists, code fences)
//    with inline `AttributedString` for basic emphasis.
//  - Ordered-list markers are fixed-width and non-wrapping to support 3+ digit numbering (e.g., 100.).
//
//  Guardrails (locked):
//  - Splash must not dismiss from menu taps or other UI actions.
//  - Starting a new chat shows a blank transcript area (no branding/hints).
//  - Runtime-only UI state is not persisted.
//  - Avoid regressions to scrolling, typing indicator behavior, and splash rules.
//

import SwiftUI
import Foundation
import UIKit



// MARK: - Profiles (Session 6A Step 1: data model only)

/// A "personality" for the assistant. Profiles are selected as a default for *new chats only*.
/// Existing chats will capture a snapshot of `systemPrompt` at creation time (wired in later steps).
struct Profile: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var systemPrompt: String
    let createdAt: Date

    /// Built-in starter profiles (fixed IDs so the default is deterministic).
    static let builtIns: [Profile] = [
        Profile(
            id: UUID(uuidString: "A9B9C6D6-4B2A-4E2F-8D9D-1C0F0E6A2F01")!,
            name: "Default",
            systemPrompt: "You are Astrid — a helpful, practical assistant. Be clear, kind, and concise.",
            createdAt: Date(timeIntervalSince1970: 0)
        ),
        Profile(
            id: UUID(uuidString: "3F6B8D2A-9F24-4F3F-9C0C-2A8B9A7D4C11")!,
            name: "Concise Coach",
            systemPrompt: "You are a plainspoken, direct coach. Push the user toward productive next steps. Use bullet points. Avoid long explanations unless asked.",
            createdAt: Date(timeIntervalSince1970: 0)
        )
    ]
}


/// In-memory catalog for Session 6A Step 1.
/// Persistence (UserDefaults/JSON) comes in Step 2.
struct ProfileCatalog {
    var profiles: [Profile] = Profile.builtIns
    var defaultProfileID: UUID = Profile.builtIns.first!.id

    var defaultProfile: Profile {
        profiles.first(where: { $0.id == defaultProfileID }) ?? profiles.first ?? Profile.builtIns[0]
    }
}


// MARK: - Profile Persistence (Session 6A Step 2)

/// Minimal persistence for profiles + default selection.
/// Stores JSON in UserDefaults and falls back to built-ins if anything goes wrong.
final class ProfileStore {
    static let shared = ProfileStore()

    private let profilesKey = "astrid.profiles.v1"
    private let defaultIDKey = "astrid.profiles.defaultID.v1"

    private init() {}

    func loadCatalog() -> ProfileCatalog {
        var catalog = ProfileCatalog()

        // Load profiles
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([Profile].self, from: data),
           !decoded.isEmpty {
            catalog.profiles = decoded
        } else {
            catalog.profiles = Profile.builtIns
        }

        // Load default ID
        if let idString = UserDefaults.standard.string(forKey: defaultIDKey),
           let id = UUID(uuidString: idString) {
            catalog.defaultProfileID = id
        } else {
            catalog.defaultProfileID = Profile.builtIns.first!.id
        }

        // Self-heal if the saved default doesn't exist anymore
        if !catalog.profiles.contains(where: { $0.id == catalog.defaultProfileID }) {
            catalog.defaultProfileID = catalog.profiles.first?.id ?? Profile.builtIns.first!.id
        }

        return catalog
    }

    func saveCatalog(_ catalog: ProfileCatalog) {
        // Save profiles
        if let data = try? JSONEncoder().encode(catalog.profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }

        // Save default profile id
        UserDefaults.standard.set(catalog.defaultProfileID.uuidString, forKey: defaultIDKey)
    }

    // Convenience operations (used in later steps)
    func setDefaultProfileID(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: defaultIDKey)
    }
}



struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel(
        client: ServerClient(baseURL: "http://192.168.50.82:1234")
    )

    // NavigationSplitView control
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var didSetInitialSplitViewState: Bool = false
    @State private var didApplyLaunchSplashReset: Bool = false
    @State private var didResetForActivePhase: Bool = false
    
    // For iPhone: present sidebar as an overlay since NavigationSplitView doesn't respond well
    // to programmatic visibility changes in compact mode
    @State private var showSidebarOverlay: Bool = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    private enum SidebarItem: Hashable {
        case chats
        case settings
    }

    @State private var sidebarSelection: SidebarItem? = .chats

    // Server server URL (drives reachability refresh for the sidebar indicator).
    @AppStorage("Server.serverURL") private var ServerServerURL: String = ""
    @AppStorage("astrid.hasCompletedServerOnboarding") private var hasCompletedServerOnboarding: Bool = false
    @State private var onboardingServerURL: String = ""

    // MARK: - Session 7.5: Chat Deletion (Manual Only)
    @State private var pendingDeleteSessionID: UUID? = nil
    @State private var pendingDeleteSessionTitle: String = ""
    @State private var showDeleteChatConfirmation: Bool = false

    // One-way splash for the current app launch/session only; dismissed only by input focus.
    @State private var hasDismissedLaunchSplash: Bool = false
    // Session 7C: after splash dismissal, we always start in a new blank chat (one-time per launch).
    @State private var didAutoStartNewChatAfterSplash: Bool = false
    // @FocusState private var isInputFocused: Bool
    // Bridge SwiftUI FocusState to a plain Bool binding for UIKit-backed input
    @State private var isInputFocusedProxy: Bool = false

    // Tracks whether the user is currently viewing the bottom of the transcript.
    // Used to prevent auto-scrolling when the user has scrolled up to read older content.
    @State private var isPinnedToBottom: Bool = true

    // Shows a "Jump to latest" button when new content arrives while the user is scrolled up.
    @State private var showJumpToLatest: Bool = false

    // Brief toast confirmation for copy actions (ChatGPT-style)
    @State private var showMessageCopiedToast: Bool = false
    @State private var messageCopiedToastToken: UUID = UUID()

    @State private var serverBaseURL: String = "http://192.168.50.82:1234"

    // MARK: - Profiles (Session 6A Step 1)
    // Source of truth for built-in profiles + default selection (persisted via Step 2).
    @State private var profileCatalog: ProfileCatalog = ProfileCatalog()
    @AppStorage("astrid.profileSwitchWarningDisabled.v1") private var suppressProfileSwitchWarning: Bool = false
    @AppStorage("astrid.profileSwitchWarningDefaulted.v1") private var profileSwitchWarningDefaulted: Bool = false
    @AppStorage("astrid.profileSwitchWarningLastSeenBuild.v1") private var profileSwitchWarningLastSeenBuild: String = ""
    @State private var pendingProfileSwitchID: UUID? = nil
    @State private var showProfileSwitchConfirmation: Bool = false
    @State private var profileSwitchDontShowAgain: Bool = false
    @State private var suppressProfileChangeSideEffects: Bool = false

    // MARK: - Profile Manager UI (Session 6A Step 6)
    @State private var showProfilesManager: Bool = false
    @State private var showProfileEditor: Bool = false
    @State private var editingProfileID: UUID? = nil // nil == create new
    @State private var pendingProfileEditorID: UUID? = nil
    @State private var shouldPresentPendingProfileEditor: Bool = false

    // MARK: - Current Chat Profile Snapshot (Session 6A Step 3)
    // These are captured only when a new chat is created. They must NOT change mid-chat.
    @State private var currentProfileName: String = ""
    @State private var currentSystemPromptSnapshot: String = ""
    
    // Dynamic height for the growing multi-line input
    @State private var inputTextHeight: CGFloat = 0
    
    // MARK: - Colors
    let deepSpaceBlack = Color(red: 0.05, green: 0.07, blue: 0.12)
    let spaceBlue = Color(red: 0.1, green: 0.15, blue: 0.25)
    let inputBarColor = Color(red: 0.15, green: 0.18, blue: 0.25)
    let sendButtonColor = Color(red: 0.35, green: 0.45, blue: 0.60)
    // Solid footer color that matches the bottom of the background gradient (hex #0D1626).
    let splashFooterMask = Color(red: 13.0/255.0, green: 22.0/255.0, blue: 38.0/255.0)

    // MARK: - Sidebar Background (Session 8A — Phase 1)
    // A harmonious (not identical) tint derived from the app palette.
    // Kept subtle to preserve List selection/readability on iPad.
    @ViewBuilder
    private var sidebarBackground: some View {
        LinearGradient(
            gradient: Gradient(colors: [
                spaceBlue.opacity(0.95),
                splashFooterMask.opacity(0.98),
                deepSpaceBlack.opacity(1.0)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - Sidebar History Scrolling (Session 8A — Step 2)
    private let historyMaxVisibleRows: Int = 5
    private let historyRowHeight: CGFloat = 52

    private var shouldShowSplash: Bool {
        !hasDismissedLaunchSplash
    }

    private var shouldShowServerOnboarding: Bool {
        !hasCompletedServerOnboarding
            && ServerServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canContinueOnboarding: Bool {
        !onboardingServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func normalizedServerURL(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return trimmed
        }

        return "http://" + trimmed
    }

    private func stripServerURLScheme(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if lower.hasPrefix("http://") {
            return String(trimmed.dropFirst(7))
        }
        if lower.hasPrefix("https://") {
            return String(trimmed.dropFirst(8))
        }

        return trimmed
    }
    
    // Helper to detect if we're on iPhone (compact width)
    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    // Profile selection is only allowed before the first user-visible message in a chat.
    private var hasStartedChat: Bool {
        !viewModel.messages.isEmpty
    }

    private var activeProfileDisplayName: String {
        hasStartedChat ? currentProfileName : profileCatalog.defaultProfile.name
    }

    private var profileSelectionBinding: Binding<UUID> {
        Binding(
            get: { profileCatalog.defaultProfileID },
            set: { newValue in
                handleProfileSelection(newValue)
            }
        )
    }

    // MARK: - Session 7A: Sidebar chat history
    /// Sessions eligible to appear in the history list.
    /// Locked rule: chats appear only after the first assistant reply.
    /// For Session 7A we conservatively gate on "has at least one assistant message".
    private var historySessions: [ChatSession] {
        viewModel.sessions
            .filter { session in
                session.messages.contains(where: { $0.role == .assistant })
            }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// Title to display for a session. Session 7B: Prefer persisted neutral title when available.
    private func historyTitle(for session: ChatSession) -> String {
        // Session 7B: Prefer persisted neutral title when available.
        if let title = session.title {
            let trimmed = title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(60))
            }
        }

        // Fallback: use the first user message (trimmed) or date if unavailable.
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

    private func selectHistorySession(_ id: UUID) {
        // Always return to chat mode
        sidebarSelection = .chats

        // Switch active session safely (resets runtime-only state + invalidates in-flight requests).
        viewModel.selectSession(id: id)

        // Selecting a history session should bypass the "start new chat on first input focus" behavior.
        // Without this, focusing the input field after loading a previous chat would overwrite it.
        hasDismissedLaunchSplash = true
        didAutoStartNewChatAfterSplash = true

        // On iPhone: close the overlay after selecting a chat.
        if isCompact {
            withAnimation(.easeOut(duration: 0.25)) {
                showSidebarOverlay = false
            }
        }
    }

    // MARK: - Session 7.5: Deletion helpers
    private func requestDeleteChat(session: ChatSession) {
        pendingDeleteSessionID = session.id
        pendingDeleteSessionTitle = historyTitle(for: session)
        showDeleteChatConfirmation = true
    }

    private func clearPendingDelete() {
        pendingDeleteSessionID = nil
        pendingDeleteSessionTitle = ""
        showDeleteChatConfirmation = false
    }

    // MARK: - Actions
    private func triggerMessageCopiedToast() {
        let token = UUID()
        messageCopiedToastToken = token
        withAnimation(.easeOut(duration: 0.18)) {
            showMessageCopiedToast = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard messageCopiedToastToken == token else { return }
            withAnimation(.easeIn(duration: 0.18)) {
                showMessageCopiedToast = false
            }
        }
    }

    private func handleProfileSelection(_ newID: UUID) {
        guard newID != profileCatalog.defaultProfileID else { return }

        if suppressProfileSwitchWarning {
            applyProfileSwitch(to: newID)
            return
        }

        pendingProfileSwitchID = newID
        profileSwitchDontShowAgain = false
        showProfileSwitchConfirmation = true
    }

    private func applyProfileSwitch(to newID: UUID) {
        suppressProfileChangeSideEffects = true
        profileCatalog.defaultProfileID = newID
        startNewChat(focusInputIfSplashVisible: false)
    }

    private func clearPendingProfileSwitch() {
        pendingProfileSwitchID = nil
        showProfileSwitchConfirmation = false
    }

    @ViewBuilder
    private var profileSwitchConfirmationOverlay: some View {
        if showProfileSwitchConfirmation {
            ZStack {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 14) {
                    Text("Switch Profile?")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    if let id = pendingProfileSwitchID,
                       let profile = profileCatalog.profiles.first(where: { $0.id == id }) {
                        Text("Switching to \"\(profile.name)\" will start a new chat and clear the current conversation.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Switching profiles will start a new chat and clear the current conversation.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        profileSwitchDontShowAgain.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: profileSwitchDontShowAgain ? "checkmark.square" : "square")
                                .foregroundStyle(.secondary)
                            Text("Don't show this warning again")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 12) {
                        Button("Cancel") {
                            clearPendingProfileSwitch()
                        }
                        .buttonStyle(.bordered)

                        Button("Start New Chat") {
                            guard let id = pendingProfileSwitchID else {
                                clearPendingProfileSwitch()
                                return
                            }
                            if profileSwitchDontShowAgain {
                                suppressProfileSwitchWarning = true
                            }
                            applyProfileSwitch(to: id)
                            clearPendingProfileSwitch()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(UIColor.systemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .padding(.horizontal, 28)
            }
            .transition(.opacity)
            .animation(.easeOut(duration: 0.2), value: showProfileSwitchConfirmation)
        }
    }

    // MARK: - Base System Prompt Preambles

    /// Always-on safety and role boundary for Astrid.
    /// Keep this short to avoid prompt bloat; it is prepended to every chat's system prompt snapshot.
    private let baseSafetyPreamble: String = """
You must not provide instructions or encouragement for self-harm, suicide, or violent wrongdoing.
If a user expresses intent to harm themselves or others, respond calmly and empathetically, encourage seeking appropriate help, and do not provide actionable guidance.
Only mention crisis resources or self-harm warnings when the user's message indicates self-harm or imminent risk. Otherwise, do not bring them up.
You are not a replacement for professional medical, legal, or crisis services.
"""

    /// Builds the final system prompt by combining the base safety preamble, personalization preamble, and the profile prompt.
    /// - Parameter profilePrompt: The profile's system prompt text.
    /// - Returns: The combined system prompt (safety + personalization + profile).
    ///
    /// Personalization injection behavior (8B-Prime-3):
    /// - If the user has set a name, the personalization preamble is prepended.
    /// - If no name is set, only the safety preamble + profile prompt are used.
    /// - This combined prompt is captured at chat creation and never changes mid-chat.
    private func buildSystemPromptWithPersonalization(profilePrompt: String) -> String {
        let safety = baseSafetyPreamble.trimmingCharacters(in: .whitespacesAndNewlines)
        let personalization = PersonalizationSettings.preamble.trimmingCharacters(in: .whitespacesAndNewlines)

        // Build parts in deterministic order: safety → personalization (optional) → profile.
        var parts: [String] = []
        if !safety.isEmpty { parts.append(safety) }
        if !personalization.isEmpty { parts.append(personalization) }
        parts.append(profilePrompt)

        return parts.joined(separator: "\n\n")
    }

    private func startNewChat(focusInputIfSplashVisible: Bool = true) {
        // Always return to chat mode
        sidebarSelection = .chats

        // Reset transcript/state
        viewModel.resetChat()

        // Capture the profile snapshot for THIS chat. (Profiles apply to new chats only.)
        // 8B-Prime-3: Personalization preamble is injected here, combined with the profile prompt.
        let selected = profileCatalog.defaultProfile
        currentProfileName = selected.name
        currentSystemPromptSnapshot = buildSystemPromptWithPersonalization(profilePrompt: selected.systemPrompt)

        #if DEBUG
        let hasPersonalization = PersonalizationSettings.hasPersonalization
        let preamble = PersonalizationSettings.preamble
        let promptHash = currentSystemPromptSnapshot.hashValue
        let promptLength = currentSystemPromptSnapshot.count
        print("[8B-Prime-3] New chat: profile=\(currentProfileName)")
        print("[8B-Prime-3]   hasPersonalization=\(hasPersonalization)")
        print("[8B-Prime-3]   preamble=\"\(preamble)\"")
        print("[8B-Prime-3]   promptHash=\(promptHash) length=\(promptLength)")
        print("[8B-Prime-3]   fullPrompt=\"\(currentSystemPromptSnapshot)\"")
        #endif

        // Session 6B: Create a new in-memory chat session identity using the immutable snapshot.
        viewModel.beginNewSession(profileName: currentProfileName, systemPromptSnapshot: currentSystemPromptSnapshot)

        // On iPhone: always close the overlay after choosing New Chat
        if isCompact {
            withAnimation(.easeOut(duration: 0.25)) {
                showSidebarOverlay = false
            }
        }

        // IMPORTANT: Splash dismissal is locked to input focus only.
        // Only programmatically focus when the splash is still visible AND the caller requested it.
        guard focusInputIfSplashVisible, shouldShowSplash else { return }

        if isCompact {
            // Close first (already requested above), then focus on the next beat so the keyboard reliably appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                isInputFocusedProxy = true
            }
        } else {
            DispatchQueue.main.async {
                isInputFocusedProxy = true
            }
        }
    }
    // MARK: - Profile CRUD Helpers
    private func persistProfiles() {
        ProfileStore.shared.saveCatalog(profileCatalog)
    }

    private func beginCreateProfile() {
        editingProfileID = nil
        showProfileEditor = true
    }

    private func beginEditProfile(id: UUID) {
        editingProfileID = id
        showProfileEditor = true
    }

    private func requestProfileEditor(id: UUID?) {
        if showProfilesManager {
            pendingProfileEditorID = id
            shouldPresentPendingProfileEditor = true
            showProfilesManager = false
            return
        }

        if let id = id {
            beginEditProfile(id: id)
        } else {
            beginCreateProfile()
        }
    }

    private func duplicateProfile(id: UUID) {
        guard let original = profileCatalog.profiles.first(where: { $0.id == id }) else { return }
        var copy = original
        copy.name = original.name + " Copy"
        copy.systemPrompt = original.systemPrompt
        let newProfile = Profile(id: UUID(), name: copy.name, systemPrompt: copy.systemPrompt, createdAt: Date())
        profileCatalog.profiles.append(newProfile)
        persistProfiles()
    }

    private func deleteProfile(id: UUID) {
        // Prevent deleting the last profile.
        guard profileCatalog.profiles.count > 1 else { return }

        profileCatalog.profiles.removeAll(where: { $0.id == id })

        // Self-heal default if needed.
        if profileCatalog.defaultProfileID == id {
            profileCatalog.defaultProfileID = profileCatalog.profiles.first?.id ?? Profile.builtIns.first!.id
        }

        persistProfiles()
    }

    // MARK: - Custom Title View with Profile Name
    @ViewBuilder
    private func titleWithProfileName() -> some View {
        VStack(spacing: 2) {
            Text("Astrid")
                .font(.headline)
                .foregroundStyle(.primary)
            Text(activeProfileDisplayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Haptic Button Style
    /// Fires a haptic immediately on touch-down (press), while keeping the Button action on touch-up.
    private struct HapticOnPressButtonStyle: ButtonStyle {
        let onPress: () -> Void

        func makeBody(configuration: Configuration) -> some View {
            HapticOnPressButtonStyleBody(configuration: configuration, onPress: onPress)
        }

        private struct HapticOnPressButtonStyleBody: View {
            let configuration: Configuration
            let onPress: () -> Void

            @State private var didFireForCurrentPress: Bool = false

            var body: some View {
                configuration.label
                    .onChange(of: configuration.isPressed) { _, isPressed in
                        if isPressed {
                            if !didFireForCurrentPress {
                                didFireForCurrentPress = true
                                onPress()
                            }
                        } else {
                            didFireForCurrentPress = false
                        }
                    }
            }
        }
    }

    // MARK: - View Helpers
    @ViewBuilder
    private func userMessageBubble(text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.white)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(sendButtonColor.opacity(0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            // Frame must come before contextMenu to ensure proper view identity in LazyVStack.
            .frame(maxWidth: 280, alignment: .trailing)
            // Make the whole bubble a hit target so the long-press reliably lands on the bubble.
            .contentShape(RoundedRectangle(cornerRadius: 14))
            // Long-press → Copy menu.
            .contextMenu {
                Button {
                    UIPasteboard.general.string = text
                    triggerMessageCopiedToast()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
    }

    // MARK: - Assistant Markdown Rendering (Block parser + inline AttributedString)

    private enum MarkdownBlock: Hashable {
        case paragraph(String)
        case bullet(level: Int, text: String)
        case numbered(level: Int, number: Int, text: String)
        case code(language: String?, code: String)
    }

    private static func parseMarkdownBlocks(_ input: String) -> [MarkdownBlock] {
        // Normalize newlines, convert tabs to spaces (Markdown engines vary on tab handling),
        // and trim trailing whitespace (but keep meaningful indentation within code).
        let normalized = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return [] }

        let lines = normalized.components(separatedBy: "\n")

        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []

        var inCode = false
        var codeLanguage: String? = nil
        var codeLines: [String] = []

        func flushParagraphIfNeeded() {
            let joined = paragraphLines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushCodeIfNeeded() {
            let code = codeLines.joined(separator: "\n")
            blocks.append(.code(language: codeLanguage, code: code))
            codeLines.removeAll(keepingCapacity: true)
            codeLanguage = nil
        }

        // Helpers
        func leadingSpacesCount(_ s: String) -> Int {
            var count = 0
            for ch in s {
                if ch == " " {
                    count += 1
                } else if ch == "\t" {
                    count += 4
                } else {
                    break
                }
            }
            return count
        }

        func bulletMatch(_ rawLine: String) -> (level: Int, text: String)? {
            // Supports: *, -, + (and tolerates common LLM spacing like "*   item")
            let spaces = leadingSpacesCount(rawLine)
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // Must look like a real bullet: marker + whitespace
            let isStar = trimmed.hasPrefix("* ")
            let isDash = trimmed.hasPrefix("- ")
            let isPlus = trimmed.hasPrefix("+ ")
            let isStarTab = trimmed.hasPrefix("*\t")
            let isDashTab = trimmed.hasPrefix("-\t")
            let isPlusTab = trimmed.hasPrefix("+\t")

            guard isStar || isDash || isPlus || isStarTab || isDashTab || isPlusTab else { return nil }

            // Determine marker and strip it
            var rest = trimmed
            if rest.hasPrefix("*") { rest.removeFirst() }
            else if rest.hasPrefix("-") { rest.removeFirst() }
            else if rest.hasPrefix("+") { rest.removeFirst() }

            rest = rest.trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return nil }

            // Indent level: treat each 2 leading spaces as one level (simple + predictable)
            let level = max(0, spaces / 2)
            return (level, rest)
        }

        func numberedMatch(_ rawLine: String) -> (level: Int, number: Int, text: String)? {
            let spaces = leadingSpacesCount(rawLine)
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // Very small/forgiving numbered-list matcher: "1. text" (also handles 1) text
            var numberStr = ""
            var idx = trimmed.startIndex
            while idx < trimmed.endIndex, trimmed[idx].isNumber {
                numberStr.append(trimmed[idx])
                idx = trimmed.index(after: idx)
            }
            guard !numberStr.isEmpty else { return nil }
            guard idx < trimmed.endIndex else { return nil }

            let sep = trimmed[idx]
            guard sep == "." || sep == ")" else { return nil }

            idx = trimmed.index(after: idx)
            // Require at least one space after separator
            guard idx < trimmed.endIndex, trimmed[idx] == " " else { return nil }
            let textStart = trimmed.index(after: idx)
            let rest = String(trimmed[textStart...]).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return nil }

            let level = max(0, spaces / 2)
            return (level, Int(numberStr) ?? 0, rest)
        }

        for line in lines {
            let raw = line

            // Code fences (nice-to-have, but we handle them safely now)
            let trimmedFence = raw.trimmingCharacters(in: .whitespaces)
            if trimmedFence.hasPrefix("```") {
                if inCode {
                    // closing fence
                    inCode = false
                    flushParagraphIfNeeded()
                    flushCodeIfNeeded()
                } else {
                    // opening fence
                    flushParagraphIfNeeded()
                    inCode = true
                    let after = trimmedFence.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = after.isEmpty ? nil : String(after)
                }
                continue
            }

            if inCode {
                codeLines.append(raw)
                continue
            }

            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Blank line: paragraph boundary
                flushParagraphIfNeeded()
                continue
            }

            if let m = bulletMatch(raw) {
                flushParagraphIfNeeded()
                blocks.append(.bullet(level: m.level, text: m.text))
                continue
            }

            if let n = numberedMatch(raw) {
                flushParagraphIfNeeded()
                blocks.append(.numbered(level: n.level, number: n.number, text: n.text))
                continue
            }

            // Default: part of a paragraph
            paragraphLines.append(raw)
        }

        // Final flush
        if inCode {
            // If model forgot the closing fence, still render what we got
            inCode = false
            flushCodeIfNeeded()
        }
        flushParagraphIfNeeded()

        return blocks
    }

    private static func attributedMarkdown(_ s: String) -> AttributedString {
        // Inline formatting only (bold/italics). If parsing fails, fall back to plain text.
        if let attr = try? AttributedString(markdown: s) {
            return attr
        }
        return AttributedString(s)
    }

    private struct AssistantMarkdownView: View {
        let markdown: String

        // Styling knobs
        let textColor: Color
        let maxWidth: CGFloat

        var body: some View {
            let blocks = parse(markdown)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .paragraph(let p):
                        Text(attr(p))
                            .font(.body)
                            .foregroundStyle(textColor)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)

                    case .bullet(let level, let t):
                        bulletRow(level: level, label: "•", text: t)

                    case .numbered(let level, let number, let t):
                        bulletRow(level: level, label: "\(number).", text: t)

                    case .code(let language, let code):
                        codeBlock(language: language, code: code)
                    }
                }
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
        }

        // MARK: - Helpers
        private func parse(_ s: String) -> [MarkdownBlock] {
            ContentView.parseMarkdownBlocks(s)
        }

        private func attr(_ s: String) -> AttributedString {
            ContentView.attributedMarkdown(s)
        }

        @ViewBuilder
        private func bulletRow(level: Int, label: String, text: String) -> some View {
            let indent = CGFloat(level) * 16

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label)
                    .font(.body)
                    .foregroundStyle(textColor.opacity(0.9))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 34, alignment: .trailing)

                Text(attr(text))
                    .font(.body)
                    .foregroundStyle(textColor)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(.leading, indent)
        }

        @ViewBuilder
        private func codeBlock(language: String?, code: String) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption)
                        .foregroundStyle(textColor.opacity(0.7))
                }

                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(textColor.opacity(0.95))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    #if DEBUG
    private func debugTail(_ s: String, max: Int = 80) -> String {
        let cleaned = s.replacingOccurrences(of: "\n", with: "⏎")
        if cleaned.count <= max { return cleaned }
        return "…" + String(cleaned.suffix(max))
    }
    #endif

    @ViewBuilder
    private func assistantMessage(text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AssistantMarkdownView(
                markdown: text,
                textColor: .white.opacity(0.95),
                maxWidth: 320
            )

            HStack(spacing: 10) {
                // Copy affordance (ChatGPT-style) at the end of the assistant response.
                Button {
                    UIPasteboard.general.string = text
                    triggerMessageCopiedToast()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )
                }
                .buttonStyle(HapticOnPressButtonStyle {
                    // Fire haptic on touch-down (press) so the user feels immediate feedback.
                    let generator = UINotificationFeedbackGenerator()
                    generator.prepare()
                    generator.notificationOccurred(.success)
                })
                .accessibilityLabel("Copy")
                .accessibilityHint("Copies this assistant response to the clipboard")

                Spacer(minLength: 0)

            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func typingIndicator() -> some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.gray)
            Text("Typing…")
                .font(.callout)
                .foregroundStyle(.gray)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
    // MARK: - Growing multi-line input (UIKit-backed)
    private final class CommandSendTextView: UITextView {
        var onCommandSend: (() -> Void)?

        override var keyCommands: [UIKeyCommand]? {
            let cmdEnter = UIKeyCommand(
                input: "\r",
                modifierFlags: .command,
                action: #selector(handleCommandReturn)
            )
            cmdEnter.discoverabilityTitle = "Send"
            
            let shiftEnter = UIKeyCommand(
                input: "\r",
                modifierFlags: .shift,
                action: #selector(handleCommandReturn)
            )
            shiftEnter.discoverabilityTitle = "Send"
            
            return [cmdEnter, shiftEnter]
        }

        @objc private func handleCommandReturn() {
            onCommandSend?()
        }
    }

    private struct GrowingTextView: UIViewRepresentable {
        @Binding var text: String
        @Binding var calculatedHeight: CGFloat
        @Binding var isFocused: Bool

        let maxLines: Int
        let onCommandSend: () -> Void

        func makeUIView(context: Context) -> CommandSendTextView {
            let tv = CommandSendTextView()
            tv.backgroundColor = .clear
            tv.textColor = .white
            tv.font = UIFont.preferredFont(forTextStyle: .body)
            tv.adjustsFontForContentSizeCategory = true
            tv.isScrollEnabled = false
            tv.textContainerInset = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
            tv.textContainer.lineFragmentPadding = 0
            tv.delegate = context.coordinator
            tv.onCommandSend = onCommandSend
            tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return tv
        }

        func updateUIView(_ uiView: CommandSendTextView, context: Context) {
            if uiView.text != text {
                uiView.text = text
                recalculateHeight(view: uiView)
            }

            // Sync focus state.
            if isFocused {
                if !uiView.isFirstResponder {
                    uiView.becomeFirstResponder()
                }
            } else {
                if uiView.isFirstResponder {
                    uiView.resignFirstResponder()
                }
            }

            // Ensure Cmd+Enter handler is always current.
            uiView.onCommandSend = onCommandSend

            // Recalculate height only when needed to avoid update loops while typing.
            // (text changes are handled by the UITextViewDelegate; here we handle initial/layout-driven width changes.)
            let w = uiView.bounds.width
            if w > 0, abs(w - context.coordinator.lastMeasuredWidth) > 0.5 {
                context.coordinator.lastMeasuredWidth = w
                recalculateHeight(view: uiView)
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            var parent: GrowingTextView
            var lastMeasuredWidth: CGFloat = 0

            init(parent: GrowingTextView) {
                self.parent = parent
            }

            func textViewDidChange(_ textView: UITextView) {
                let newText = textView.text ?? ""
                if parent.text != newText {
                    DispatchQueue.main.async { [weak self] in
                        self?.parent.text = newText
                    }
                }
                parent.recalculateHeight(view: textView)
            }

            func textViewDidBeginEditing(_ textView: UITextView) {
                if !parent.isFocused {
                    parent.isFocused = true
                }
            }

            func textViewDidEndEditing(_ textView: UITextView) {
                if parent.isFocused {
                    parent.isFocused = false
                }
            }
        }

        private func recalculateHeight(view: UITextView) {
            let width = max(view.bounds.width, 1)
            let fittingSize = CGSize(width: width, height: .greatestFiniteMagnitude)
            let size = view.sizeThatFits(fittingSize)

            let font = view.font ?? UIFont.preferredFont(forTextStyle: .body)
            let maxHeight = (font.lineHeight * CGFloat(maxLines)) + view.textContainerInset.top + view.textContainerInset.bottom

            let newHeight = min(size.height, maxHeight)
            let shouldScroll = size.height > maxHeight + 0.5

            if view.isScrollEnabled != shouldScroll {
                view.isScrollEnabled = shouldScroll
            }

            if calculatedHeight != newHeight {
                // Avoid mutating SwiftUI state during a view update cycle.
                DispatchQueue.main.async {
                    calculatedHeight = newHeight
                }
            }
        }
    }

    // MARK: - Subviews (to help the compiler type-check)
    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                userMessageBubble(text: message.content)
            }
        } else if message.role == .error {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    assistantMessage(text: message.content)
                    Spacer(minLength: 40)
                }
                Button {
                    viewModel.retry(
                        systemPrompt: viewModel.activeSession?.profileSnapshot.systemPromptSnapshot ?? currentSystemPromptSnapshot
                    )
                } label: {
                    Text("Retry")
                        .font(.callout)
                }
                .disabled(viewModel.isSending)
            }
        } else {
            HStack {
                assistantMessage(text: message.content)
                Spacer(minLength: 40)
            }
        }
    }

    @ViewBuilder
    private var splashCenter: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .foregroundStyle(.white)
                .shadow(color: .white.opacity(0.8), radius: 20, x: 0, y: 0)
                .opacity(0.9)

            VStack(spacing: 8) {
                Text("Astrid")
                    .font(.system(size: 42, weight: .regular, design: .default))
                    .foregroundStyle(.white)

                Text("Your hardware. Your models. Your AI")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
            }
        }
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var serverOnboardingOverlay: some View {
        if shouldShowServerOnboarding {
            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()

                VStack(spacing: 18) {
                    Image(systemName: "sparkles")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .foregroundStyle(.white)
                        .shadow(color: .white.opacity(0.8), radius: 16, x: 0, y: 0)
                        .opacity(0.9)

                    VStack(spacing: 6) {
                        Text("Astrid")
                            .font(.system(size: 34, weight: .regular, design: .default))
                            .foregroundStyle(.white)

                        Text("Your hardware. Your models. Your AI")
                            .font(.subheadline)
                            .foregroundStyle(.gray)
                    }

                    Text("Hello, in order to get started please enter the url of the server you want to connect to")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.center)

                    HStack(spacing: 0) {
                        Text("http://")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)

                        TextField("Server Address", text: $onboardingServerURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.URL)
                            .padding(.vertical, 12)
                            .padding(.trailing, 12)
                    }
                    .background(Color(uiColor: .tertiarySystemBackground))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(uiColor: .separator), lineWidth: 1.0)
                    )
                    .onChange(of: onboardingServerURL) { _, newValue in
                        let stripped = stripServerURLScheme(newValue)
                        if stripped != newValue {
                            onboardingServerURL = stripped
                        }
                    }

                    Button("Continue") {
                        guard let normalized = normalizedServerURL(from: onboardingServerURL) else { return }
                        ServerServerURL = normalized
                        hasCompletedServerOnboarding = true
                        hasDismissedLaunchSplash = true
                        didAutoStartNewChatAfterSplash = true
                        startNewChat(focusInputIfSplashVisible: false)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(sendButtonColor)
                    .disabled(!canContinueOnboarding)
                    .opacity(canContinueOnboarding ? 1.0 : 0.7)
                }
                .padding(24)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [spaceBlue, deepSpaceBlack]),
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .padding(.horizontal, 28)
                .onAppear {
                    if onboardingServerURL.isEmpty {
                        onboardingServerURL = stripServerURLScheme(ServerServerURL)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var chatCenter: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)

                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.messages) { message in
                                messageRow(message)
                                    .id(message.id)
                            }

                            if viewModel.isAssistantTyping {
                                HStack {
                                    typingIndicator()
                                    Spacer(minLength: 40)
                                }
                                .id("typing-indicator")
                            }

                            // Bottom sentinel used to detect whether the user is at the bottom of the scroll view.
                            Color.clear
                                .frame(height: 1)
                                .id("bottom-sentinel")
                                .onAppear {
                                    isPinnedToBottom = true
                                    showJumpToLatest = false
                                }
                                .onDisappear {
                                    isPinnedToBottom = false
                                }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                        // Keep enough bottom space so transcript text never sits behind the input bar.
                        .padding(.bottom, 110)
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: viewModel.messages) { _, _ in
                    guard let last = viewModel.messages.last else { return }

                    // If the user has scrolled up and new assistant content arrives, offer a one-tap way to return.
                    if !isPinnedToBottom, last.role != .user {
                        showJumpToLatest = true
                    }

                    // Always reveal the user's newly-submitted message, even if they've scrolled up.
                    if last.role == .user {
                        isPinnedToBottom = true
                        showJumpToLatest = false
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                        return
                    }

                    // For assistant/error messages, only auto-scroll when the user is already at the bottom.
                    guard isPinnedToBottom else { return }

                    // Keep context: scroll to the previous message (usually the user's prompt) so its last line(s)
                    // remain visible, and the assistant response begins immediately below.
                    if viewModel.messages.count >= 2 {
                        let previous = viewModel.messages[viewModel.messages.count - 2]
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(previous.id, anchor: .center)
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .top)
                        }
                    }
                }
                .onChange(of: viewModel.isAssistantTyping) { _, newValue in
                    guard newValue else { return }

                    // If the user is scrolled up, don't yank them—just offer a "Jump to latest" affordance.
                    guard isPinnedToBottom else {
                        showJumpToLatest = true
                        return
                    }

                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("typing-indicator", anchor: .bottom)
                    }
                }

                if showJumpToLatest {
                    Button {
                        isPinnedToBottom = true
                        showJumpToLatest = false
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                            }
                        }
                    } label: {
                        Label("Jump to latest", systemImage: "chevron.down")
                            .font(.callout)
                            .foregroundStyle(.white)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .background(sendButtonColor.opacity(0.90))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                            )
                            .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 6)
                    }
                    .padding(.trailing, 18)
                    .padding(.bottom, 86) // lifts button above the input bar
                }
            }
        }
    }

    @ViewBuilder
    private var inputBar: some View {
        HStack(spacing: 15) {
            ZStack(alignment: .leading) {
                if viewModel.input.isEmpty {
                    Text("Ask me anything...")
                        .foregroundStyle(.gray.opacity(0.7))
                        // Match the UITextView's textContainerInset (top/bottom = 8)
                        .padding(.vertical, 8)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }
                GrowingTextView(
                    text: $viewModel.input,
                    calculatedHeight: $inputTextHeight,
                    isFocused: $isInputFocusedProxy,
                    maxLines: 6,
                    onCommandSend: {
                        let trimmed = viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, !viewModel.isSending else { return }
                        viewModel.send(
                            systemPrompt: viewModel.activeSession?.profileSnapshot.systemPromptSnapshot ?? currentSystemPromptSnapshot
                        )
                    }
                )
                .frame(minHeight: 40, maxHeight: max(40, inputTextHeight))
            }

            if viewModel.isSending {
                Button(action: {
                    viewModel.stopSending()
                }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(sendButtonColor)
                        .clipShape(Circle())
                }
            } else {
                Button(action: {
                    viewModel.send(
                        systemPrompt: viewModel.activeSession?.profileSnapshot.systemPromptSnapshot ?? currentSystemPromptSnapshot
                    )
                }) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(sendButtonColor)
                        .clipShape(Circle())
                }
                .disabled(viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(inputBarColor)
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .overlay(
            RoundedRectangle(cornerRadius: 32)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.bottom, 10)
        .onChange(of: isInputFocusedProxy) { _, newValue in
            // Splash dismissal is locked to input focus only (one-way).
            if newValue {
                hasDismissedLaunchSplash = true

                // Session 7C: after splash dismissal, always start a new blank chat (one-time per launch).
                if !didAutoStartNewChatAfterSplash {
                    didAutoStartNewChatAfterSplash = true
                    startNewChat()
                }
            }
        }
    }

    
    
    // For iPad NavigationSplitView (needs selection binding)
    @ViewBuilder
    private var sidebarWithSelection: some View {
        AstridSidebarView(
            isServerOnline: viewModel.isServerReachable,
            sessions: historySessions,
            titleForSession: { historyTitle(for: $0) },
            profileCatalog: $profileCatalog,
            selectedProfileID: profileSelectionBinding,
            onCreateProfile: { beginCreateProfile() },
            onManageProfiles: { showProfilesManager = true },
            onNewChat: { startNewChat() },
            onSelectSession: { selectHistorySession($0) },
            onRequestDelete: { requestDeleteChat(session: $0) },
            onOpenSettings: {
                sidebarSelection = .settings
            },
            deepSpaceBlack: deepSpaceBlack,
            spaceBlue: spaceBlue,
            splashFooterMask: splashFooterMask,
            historyMaxVisibleRows: historyMaxVisibleRows,
            historyRowHeight: historyRowHeight
        )
        .alert("Delete Chat?", isPresented: $showDeleteChatConfirmation) {
            Button("Delete", role: .destructive) {
                guard let id = pendingDeleteSessionID else {
                    clearPendingDelete()
                    return
                }

                // Delete + persist immediately.
                let wasActive = viewModel.deleteSession(id: id)

                // If we deleted the active chat, switch to a new blank chat.
                // IMPORTANT: Do NOT programmatically focus input here (avoid dismissing splash).
                if wasActive {
                    startNewChat(focusInputIfSplashVisible: false)
                }

                clearPendingDelete()
            }

            Button("Cancel", role: .cancel) {
                clearPendingDelete()
            }
        } message: {
            if pendingDeleteSessionTitle.isEmpty {
                Text("This will permanently delete this chat.")
            } else {
                Text("This will permanently delete \"\(pendingDeleteSessionTitle)\".")
            }
        }
    }

    // For iPhone overlay (no selection binding needed)
    @ViewBuilder
    private var sidebarWithoutSelection: some View {
        AstridSidebarView(
            isServerOnline: viewModel.isServerReachable,
            sessions: historySessions,
            titleForSession: { historyTitle(for: $0) },
            profileCatalog: $profileCatalog,
            selectedProfileID: profileSelectionBinding,
            onCreateProfile: { beginCreateProfile() },
            onManageProfiles: { showProfilesManager = true },
            onNewChat: { startNewChat() },
            onSelectSession: { selectHistorySession($0) },
            onRequestDelete: { requestDeleteChat(session: $0) },
            onOpenSettings: {
                sidebarSelection = .settings
                if isCompact {
                    withAnimation(.easeOut(duration: 0.25)) {
                        showSidebarOverlay = false
                    }
                }
            },
            deepSpaceBlack: deepSpaceBlack,
            spaceBlue: spaceBlue,
            splashFooterMask: splashFooterMask,
            historyMaxVisibleRows: historyMaxVisibleRows,
            historyRowHeight: historyRowHeight
        )
        .alert("Delete Chat?", isPresented: $showDeleteChatConfirmation) {
            Button("Delete", role: .destructive) {
                guard let id = pendingDeleteSessionID else {
                    clearPendingDelete()
                    return
                }

                // Delete + persist immediately.
                let wasActive = viewModel.deleteSession(id: id)

                // If we deleted the active chat, switch to a new blank chat.
                // IMPORTANT: Do NOT programmatically focus input here (avoid dismissing splash).
                if wasActive {
                    startNewChat(focusInputIfSplashVisible: false)
                }

                clearPendingDelete()
            }

            Button("Cancel", role: .cancel) {
                clearPendingDelete()
            }
        } message: {
            if pendingDeleteSessionTitle.isEmpty {
                Text("This will permanently delete this chat.")
            } else {
                Text("This will permanently delete \"\(pendingDeleteSessionTitle)\".")
            }
        }
    }

    var body: some View {
        Group {
            if isCompact {
                // iPhone: Use a plain NavigationStack + overlay sidebar.
                // NavigationSplitView can behave unpredictably in compact with custom overlays.
                NavigationStack {
                    Group {
                        if sidebarSelection == .settings {
                            SettingsView()
                                .toolbar {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button("Done") {
                                            sidebarSelection = .chats
                                            withAnimation(.easeOut(duration: 0.25)) {
                                                showSidebarOverlay = false
                                            }
                                        }
                                    }
                                }
                        } else {
                            ZStack {
                                LinearGradient(
                                    gradient: Gradient(colors: [spaceBlue, deepSpaceBlack]),
                                    startPoint: .center,
                                    endPoint: .bottom
                                )
                                .ignoresSafeArea()

                                Group {
                                    if shouldShowSplash {
                                        splashCenter
                                    } else {
                                        chatCenter
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: shouldShowSplash ? .center : .bottom)
                            }
                            .safeAreaInset(edge: .bottom) {
                                VStack(spacing: 0) {
                                    inputBar
                                }
                                .frame(maxWidth: .infinity)
                                .background(
                                    Group {
                                        if shouldShowSplash {
                                            splashFooterMask
                                        } else {
                                            LinearGradient(
                                                gradient: Gradient(colors: [spaceBlue, deepSpaceBlack]),
                                                startPoint: .center,
                                                endPoint: .bottom
                                            )
                                        }
                                    }
                                    .ignoresSafeArea(edges: .bottom)
                                )
                            }
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                if !shouldShowSplash {
                                    ToolbarItem(placement: .principal) {
                                        titleWithProfileName()
                                    }
                                }
                            }
                        }
                    }
                    .navigationBarBackButtonHidden(true)
                    .toolbar {
                        if sidebarSelection != .settings {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    // Dismiss keyboard before opening sidebar
                                    isInputFocusedProxy = false

                                    withAnimation(.easeOut(duration: 0.25)) {
                                        showSidebarOverlay = true
                                    }
                                } label: {
                                    Image(systemName: "line.3.horizontal")
                                }
                            }
                            
                            if !shouldShowSplash {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button {
                                        startNewChat()
                                    } label: {
                                        Image(systemName: "square.and.pencil")
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                // iPad: Use NavigationSplitView with the real sidebar.
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebarWithSelection
                } detail: {
                    NavigationStack {
                        Group {
                            if sidebarSelection == .settings {
                                SettingsView()
                            } else {
                                ZStack {
                                    LinearGradient(
                                        gradient: Gradient(colors: [spaceBlue, deepSpaceBlack]),
                                        startPoint: .center,
                                        endPoint: .bottom
                                    )
                                    .ignoresSafeArea()

                                    Group {
                                        if shouldShowSplash {
                                            splashCenter
                                        } else {
                                            chatCenter
                                        }
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: shouldShowSplash ? .center : .bottom)
                                }
                                .safeAreaInset(edge: .bottom) {
                                    VStack(spacing: 0) {
                                        inputBar
                                    }
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        Group {
                                            if shouldShowSplash {
                                                splashFooterMask
                                            } else {
                                                LinearGradient(
                                                    gradient: Gradient(colors: [spaceBlue, deepSpaceBlack]),
                                                    startPoint: .center,
                                                    endPoint: .bottom
                                                )
                                            }
                                        }
                                        .ignoresSafeArea(edges: .bottom)
                                    )
                                }
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar {
                                    if !shouldShowSplash {
                                        ToolbarItem(placement: .principal) {
                                            titleWithProfileName()
                                        }
                                    }
                                }
                            }
                        }
                        .navigationBarBackButtonHidden(true)
                        .toolbar {
                            if sidebarSelection != .settings {
                                if !shouldShowSplash {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button {
                                            startNewChat()
                                        } label: {
                                            Image(systemName: "square.and.pencil")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .onAppear {
            if !didApplyLaunchSplashReset {
                hasDismissedLaunchSplash = false
                didAutoStartNewChatAfterSplash = false
                isInputFocusedProxy = false
                didApplyLaunchSplashReset = true
            }

            // Load persisted profiles/defaults (falls back to built-ins if needed).
            profileCatalog = ProfileStore.shared.loadCatalog()
            print("[Astrid] ContentView appeared — loaded profiles: \(profileCatalog.profiles.count), default=\(profileCatalog.defaultProfile.name)")

            let currentVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
            if profileSwitchWarningLastSeenBuild != currentVersion {
                suppressProfileSwitchWarning = false
                profileSwitchWarningLastSeenBuild = currentVersion
                profileSwitchWarningDefaulted = true
            } else if !profileSwitchWarningDefaulted {
                suppressProfileSwitchWarning = false
                profileSwitchWarningDefaulted = true
            }

            // Initialize the current chat snapshot on first launch so it's never empty.
            // 8B-Prime-3: Apply personalization preamble on initial setup.
            if currentProfileName.isEmpty {
                let selected = profileCatalog.defaultProfile
                currentProfileName = selected.name
                currentSystemPromptSnapshot = buildSystemPromptWithPersonalization(profilePrompt: selected.systemPrompt)
            }

            // Session 7C decision: we do NOT auto-resume a persisted chat into the UI.
            // We only ensure a session exists when the user actually starts a new chat (after splash dismissal).
            // (History remains available via sidebar.)

            // In compact environments, default to showing the chat/detail first (one-time).
            guard !didSetInitialSplitViewState else { return }
            didSetInitialSplitViewState = true
            columnVisibility = .detailOnly
            sidebarSelection = .chats
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                didResetForActivePhase = false
                return
            }

            if hasCompletedServerOnboarding, !didResetForActivePhase {
                hasDismissedLaunchSplash = false
                didAutoStartNewChatAfterSplash = false
                isInputFocusedProxy = false
                didResetForActivePhase = true
            }
        }
        .onChange(of: profileCatalog.defaultProfileID) { _, _ in
            if suppressProfileChangeSideEffects {
                suppressProfileChangeSideEffects = false
                ProfileStore.shared.saveCatalog(profileCatalog)
                return
            }

            // Persist default profile selection.
            ProfileStore.shared.saveCatalog(profileCatalog)

            // Only update the active chat snapshot if the chat hasn't started yet.
            guard viewModel.messages.isEmpty else { return }
            // 8B-Prime-3: Apply personalization preamble when updating profile selection.
            let selected = profileCatalog.defaultProfile
            currentProfileName = selected.name
            currentSystemPromptSnapshot = buildSystemPromptWithPersonalization(profilePrompt: selected.systemPrompt)

            // Session 6B: Keep session metadata aligned with the snapshot when the chat is still empty.
            // This creates a fresh session identity for the would-be new chat context.
            viewModel.beginNewSession(profileName: currentProfileName, systemPromptSnapshot: currentSystemPromptSnapshot)
        }
        .sheet(isPresented: $showProfilesManager) {
            NavigationStack {
                ProfilesManagerView(
                    catalog: $profileCatalog,
                    onPersist: { persistProfiles() },
                    onDuplicate: { duplicateProfile(id: $0) },
                    onDelete: { deleteProfile(id: $0) },
                    onEdit: { requestProfileEditor(id: $0) },
                    onCreate: { requestProfileEditor(id: nil) }
                )
                .navigationTitle("Profiles")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            showProfilesManager = false
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showProfileEditor) {
            NavigationStack {
                ProfileEditorView(
                    initialProfile: editingProfileID.flatMap { id in
                        profileCatalog.profiles.first(where: { $0.id == id })
                    },
                    onCancel: {
                        showProfileEditor = false
                    },
                    onSave: { finalProfile in
                        if let id = editingProfileID {
                            // Edit mode: update existing profile in place.
                            if let idx = profileCatalog.profiles.firstIndex(where: { $0.id == id }) {
                                profileCatalog.profiles[idx].name = finalProfile.name
                                profileCatalog.profiles[idx].systemPrompt = finalProfile.systemPrompt
                            }
                        } else {
                            // Create mode: append the new profile.
                            profileCatalog.profiles.append(finalProfile)
                        }
                        persistProfiles()
                        showProfileEditor = false
                    }
                )
                .navigationTitle(editingProfileID == nil ? "New Profile" : "Edit Profile")
            }
        }
        .onChange(of: showProfilesManager) { _, isShowing in
            guard !isShowing, shouldPresentPendingProfileEditor else { return }
            let pendingID = pendingProfileEditorID
            pendingProfileEditorID = nil
            shouldPresentPendingProfileEditor = false
            requestProfileEditor(id: pendingID)
        }
        .preferredColorScheme(.dark)
        // Overlay-based sidebar for iPhone (slides in from left)
        .overlay {
            if isCompact {
                ZStack(alignment: .leading) {
                    // Dimmed background that dismisses sidebar when tapped
                    Color.black.opacity(showSidebarOverlay ? 0.4 : 0.0)
                        .ignoresSafeArea()
                        .allowsHitTesting(showSidebarOverlay)
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.25)) {
                                showSidebarOverlay = false
                            }
                        }

                    // Sidebar panel (always rendered, but offset and hidden when not visible)
                    HStack(spacing: 0) {
                        NavigationStack {
                            sidebarWithoutSelection
                                .toolbar {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button {
                                            withAnimation(.easeOut(duration: 0.25)) {
                                                showSidebarOverlay = false
                                            }
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.body)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                        }
                        .frame(width: 280)
                        .background(sidebarBackground)

                        Spacer()
                    }
                    .offset(x: showSidebarOverlay ? 0 : -300)
                    .opacity(showSidebarOverlay ? 1.0 : 0.0)
                    .allowsHitTesting(showSidebarOverlay)
                }
                // Important: Prevent hit testing when closed so taps pass through
                .allowsHitTesting(showSidebarOverlay)
            }
        }
        .overlay(alignment: .top) {
            if showMessageCopiedToast {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.95))
                    Text("Message copied")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Color.black.opacity(0.70))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 8)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(profileSwitchConfirmationOverlay)
        .overlay(serverOnboardingOverlay)
        .onChange(of: ServerServerURL) { _, _ in
            Task { await viewModel.refreshServerModel() }
        }
    }
}

#Preview {
    ContentView()
}

    // MARK: - Profiles Manager (Session 6A Step 6)
    private struct ProfilesManagerView: View {
        @Binding var catalog: ProfileCatalog
        let onPersist: () -> Void
        let onDuplicate: (UUID) -> Void
        let onDelete: (UUID) -> Void
        let onEdit: (UUID) -> Void
        let onCreate: () -> Void

        var body: some View {
            List {
                Section {
                    ForEach(catalog.profiles) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.name)
                                    .font(.body)
                                if catalog.defaultProfileID == p.id {
                                    Text("Default")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if catalog.defaultProfileID == p.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            catalog.defaultProfileID = p.id
                            onPersist()
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Edit") {
                                onEdit(p.id)
                            }
                            .tint(.blue)

                            Button("Duplicate") {
                                onDuplicate(p.id)
                            }
                            .tint(.gray)

                            Button(role: .destructive) {
                                onDelete(p.id)
                            } label: {
                                Text("Delete")
                            }
                        }
                    }
                } header: {
                    Text("Profiles")
                } footer: {
                    Text("Edits apply to new chats. Existing chats won’t change.")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onCreate()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    private struct ProfileEditorView: View {
        /// The initial profile data (for edit mode) or nil (for create mode).
        let initialProfile: Profile?
        let onCancel: () -> Void
        /// Called with the finalized profile data when user taps Done.
        let onSave: (Profile) -> Void

        // Local draft state — isolated from catalog until explicit save.
        @State private var draftName: String = ""
        @State private var draftSystemPrompt: String = ""
        // Stable ID for new profiles (generated once on appear, not on every render).
        @State private var draftID: UUID = UUID()
        @State private var draftCreatedAt: Date = Date()
        @State private var didInitialize: Bool = false

        private var isNew: Bool { initialProfile == nil }

        var body: some View {
            Form {
                Section("Name") {
                    TextField("Profile name", text: $draftName)
                        .textInputAutocapitalization(.words)
                }

                Section("System Prompt") {
                    TextEditor(text: $draftSystemPrompt)
                        .frame(minHeight: 200)
                    Text("Applies to new chats. Existing chats won't change.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .onAppear {
                // Initialize draft state exactly once from initialProfile (edit) or defaults (create).
                guard !didInitialize else { return }
                didInitialize = true

                if let existing = initialProfile {
                    // Edit mode: populate from existing profile.
                    draftID = existing.id
                    draftName = existing.name
                    draftSystemPrompt = existing.systemPrompt
                    draftCreatedAt = existing.createdAt
                } else {
                    // Create mode: use empty defaults with stable UUID.
                    draftName = ""
                    draftSystemPrompt = ""
                    // draftID and draftCreatedAt already initialized above.
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        let finalProfile = Profile(
                            id: draftID,
                            name: draftName.trimmingCharacters(in: .whitespacesAndNewlines),
                            systemPrompt: draftSystemPrompt,
                            createdAt: draftCreatedAt
                        )
                        onSave(finalProfile)
                    }
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
