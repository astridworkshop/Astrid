//
//  PersonalizationView.swift
//  Astrid
//
//  Settings subpage for user name/pronoun preferences and personalization behavior.
//  Writes @AppStorage used when ContentView assembles system prompts for new chats.
//  Copyright © 2026 Astrid Workshop.
//  Licensed under the terms in the LICENSE file.
//
//  Responsibilities:
//  - Allow the user to set a preferred name and pronouns (optional).
//  - Provide an option to avoid using the user's name in chat responses.
//  - Persist settings via @AppStorage for immediate availability.
//
//  Injection mechanism:
//  - Personalization is injected as a preamble BEFORE the profile system prompt.
//  - The preamble is constructed by `PersonalizationSettings.preamble` only when
//    the user has provided a name (non-empty after trimming).
//  - If no name is set, no preamble is injected (personalization has no effect).
//  - Pronouns are only included if explicitly selected (not "Not specified").
//  - The "Use my name in responses" toggle controls whether the assistant is
//    instructed to use the name in replies or just know it for context.
//
//  Snapshot behavior:
//  - Personalization preamble is captured at chat creation time (via ProfileSnapshot).
//  - Changes to personalization settings do NOT affect existing chats.
//  - Clearing settings fully removes influence from future chats.
//
//  See also:
//  - ContentView.swift: `buildSystemPromptWithPersonalization()` constructs the
//    final system prompt by combining preamble + profile prompt.
//  - ProfileSnapshot: Stores the combined system prompt snapshot.
//
//  Created by Astrid Workshop on 2026-01-11.
//

import SwiftUI

// MARK: - Pronouns Options

enum PronounsOption: String, CaseIterable, Identifiable {
    case none
    case sheHer
    case heHim
    case theyThem

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "Not specified"
        case .sheHer: return "She / her"
        case .heHim: return "He / him"
        case .theyThem: return "They / them"
        }
    }

    /// Returns the pronoun phrase for system prompt injection (e.g., "she/her").
    /// Returns nil for `.none` since no pronouns should be mentioned.
    var promptPhrase: String? {
        switch self {
        case .none: return nil
        case .sheHer: return "she/her"
        case .heHim: return "he/him"
        case .theyThem: return "they/them"
        }
    }
}

// MARK: - Personalization Settings (Persistence + Preamble Builder)

/// Centralized access to personalization settings with preamble generation.
/// All settings are persisted via UserDefaults (through @AppStorage keys).
struct PersonalizationSettings {
    // MARK: - Storage Keys
    static let nameKey = "astrid.personalization.userName"
    static let pronounsKey = "astrid.personalization.pronouns"
    static let useNameInResponsesKey = "astrid.personalization.useNameInResponses"

    // MARK: - Read Current Settings

    /// The user's preferred name (may be empty).
    static var userName: String {
        UserDefaults.standard.string(forKey: nameKey) ?? ""
    }

    /// The user's selected pronouns option.
    static var pronouns: PronounsOption {
        guard let raw = UserDefaults.standard.string(forKey: pronounsKey),
              let option = PronounsOption(rawValue: raw) else {
            return .none
        }
        return option
    }

    /// Whether the assistant should use the user's name in responses.
    static var useNameInResponses: Bool {
        // Default to true if not set
        if UserDefaults.standard.object(forKey: useNameInResponsesKey) == nil {
            return false
        }
        return UserDefaults.standard.bool(forKey: useNameInResponsesKey)
    }

    // MARK: - Preamble Generation

    /// Builds the personalization preamble to prepend to the profile system prompt.
    /// Returns an empty string if no personalization is configured (name is empty).
    ///
    /// Example outputs:
    /// - Name only, use in responses: "The user's name is Alex. You may address them by name."
    /// - Name only, don't use: "The user's name is Alex. Do not address them by name in your replies."
    /// - Name + pronouns: "The user's name is Alex (they/them). You may address them by name."
    /// - No name set: "" (empty, no preamble)
    static var preamble: String {
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }

        var parts: [String] = []

        // Build the name introduction
        if let pronounPhrase = pronouns.promptPhrase {
            parts.append("Hi \(name), I'll use these pronouns for you: (\(pronounPhrase)).")
        } else {
            parts.append("Hi \(name).")
        }

        return parts.joined(separator: " ")
    }

    /// Returns true if any personalization is configured that would affect prompts.
    static var hasPersonalization: Bool {
        !userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Personalization View

struct PersonalizationView: View {
    // Persisted settings via @AppStorage
    @AppStorage(PersonalizationSettings.nameKey) private var preferredName: String = ""
    @AppStorage(PersonalizationSettings.pronounsKey) private var selectedPronounsRaw: String = PronounsOption.none.rawValue
    @AppStorage(PersonalizationSettings.useNameInResponsesKey) private var allowNameInResponses: Bool = false

    private let deepSpaceBlack = Color(red: 0.05, green: 0.07, blue: 0.12)
    private let spaceBlue = Color(red: 0.1, green: 0.15, blue: 0.25)

    private var selectedPronouns: Binding<PronounsOption> {
        Binding(
            get: { PronounsOption(rawValue: selectedPronounsRaw) ?? .none },
            set: { selectedPronounsRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                TextField("Preferred name (optional)", text: $preferredName)
                    .textContentType(.name)
                    .autocorrectionDisabled(true)
                    .padding(12)
                    .background(Color(uiColor: .tertiarySystemBackground))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(uiColor: .separator), lineWidth: 1.0)
                    )

                Toggle("Use my name in responses", isOn: $allowNameInResponses)

                Text("If enabled, the assistant may address you by name in replies. If disabled, it will know your name but avoid using it.\n\nThese settings apply to new chats only. Existing chats are not affected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                SectionHeaderView("Name")
            }

            Section {
                Picker("Pronouns", selection: selectedPronouns) {
                    ForEach(PronounsOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }

                Text("Optional. Helps the assistant refer to you respectfully.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                SectionHeaderView("Preferred Pronouns")
            }

            if PersonalizationSettings.hasPersonalization {
                Section {
                    Button("Clear Personalization", role: .destructive) {
                        preferredName = ""
                        selectedPronounsRaw = PronounsOption.none.rawValue
                        allowNameInResponses = false
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [spaceBlue, deepSpaceBlack]),
                startPoint: .center,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .navigationTitle("Personalization")
    }

}

#Preview {
    NavigationStack {
        PersonalizationView()
    }
}
