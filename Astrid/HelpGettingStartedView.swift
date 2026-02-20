//
//  HelpGettingStartedView.swift
//  Astrid
//
//  Help and onboarding for first-run guidance and troubleshooting.
//  Presented from SettingsView alongside other support-related subpages.
//  Copyright © 2026 Astrid Workshop.
//  Licensed under the terms in the LICENSE file.
//

import SwiftUI

struct HelpGettingStartedView: View {
    private let deepSpaceBlack = Color(red: 0.05, green: 0.07, blue: 0.12)
    private let spaceBlue = Color(red: 0.1, green: 0.15, blue: 0.25)

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Astrid is an iOS app that lets you chat with an AI model running on your own computer through a local LLM server.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Your data never leaves your network. You pick the model in your server, control the settings, and keep full ownership of every conversation.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Consult your LM Server's documentation for how to set up a server.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .font(.body)
            } header: {
                SectionHeaderView("About Astrid")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Set up a local LLM server on your computer (e.g., LM Studio, Ollama, or any OpenAI-compatible server).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("2. Load a model and start the server.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("3. Note the server's address (e.g., `http://192.168.1.100:1234`).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("4. In Astrid, open `Settings → Server Address` and enter it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("5. Start a new chat in Astrid and send a message.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Note: The first response may be slow while the model loads into memory.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .italic()
                }

            } header: {
                SectionHeaderView("Getting Started")
            }

            Section {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Can't connect")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Make sure your LLM server is running and accepting connections. Check that the server address matches the Server Address in Astrid's settings. If both look correct, the model may still be loading—give it a moment and try again.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Errors after connecting")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("If your server doesn't have a model loaded, or a model fails to load, you may see an error like `Server returned HTTP 400`. Load or reload a model on your server and try your message again.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wrong address")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("If the Server Address in Astrid doesn't match your server, the connection indicator on the Sidebar will show a red dot. Make sure the address in Astrid matches the one shown by your server software.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Network requirements")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Your phone or tablet and your computer must be on the same Wi‑Fi network. VPNs, firewalls, and iCloud Private Relay can also block local connections—try disabling them temporarily if you're having trouble.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Slow responses")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Response speed depends on your computer's hardware and the model size. The first message can be slow if the model needs to load into memory.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                SectionHeaderView("Common Issues")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Profiles change how the AI talks to you. Each profile sends a behind-the-scenes instruction to the model — so one profile might give you short, casual answers while another gives detailed technical explanations.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Select a profile from the dropdown in the chat toolbar before starting a conversation. Profiles cannot be changed mid‑chat—start a new chat to use a different one.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .font(.body)
            } header: {
                SectionHeaderView("Profiles")
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
        .navigationTitle("Help")
        .onAppear {
            UILabel.appearance(whenContainedInInstancesOf: [UITableView.self]).textColor = .label
        }
    }

}

#Preview {
    NavigationStack {
        HelpGettingStartedView()
    }
}
