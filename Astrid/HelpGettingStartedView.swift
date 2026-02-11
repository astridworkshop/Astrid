//
//  HelpGettingStartedView.swift
//  Astrid
//
//  Help and onboarding stub for first-run guidance and troubleshooting.
//  Presented from SettingsView alongside other support-related subpages.
//  Copyright © 2026 Astrid Workshop.
//  Licensed under the terms in the LICENSE file.
//
//  Session 8A — Help / Getting Started (stub)
//
//  Responsibilities (stub version):
//  - Placeholder screen for onboarding and basic troubleshooting.
//  - Will later include quick-start steps and common issues.
//

import SwiftUI

struct HelpGettingStartedView: View {
    private let deepSpaceBlack = Color(red: 0.05, green: 0.07, blue: 0.12)
    private let spaceBlue = Color(red: 0.1, green: 0.15, blue: 0.25)

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Astrid is an iOS app that lets you chat with an AI model running on your own computer through an LM Studio local server.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Your data never leaves your network. You pick the model in LMStudio, control the settings, and keep full ownership of every conversation.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Link("LM Studio documentation", destination: URL(string: "https://lmstudio.ai/docs")!)
                }
                .font(.body)
            } header: {
                SectionHeaderView("About Astrid")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Open **LM Studio** on your computer.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("2. Go to **Server Settings** and turn **On** Local Server.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("3. Load a model in LM Studio.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("4. Copy the `Reachable at:` address from LM Studio.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("5. In Astrid, open `Settings → Server URL` and paste it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("6. Start a new chat in Astrid and send a message.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Warning: the first response from LM Studio can be slow while the model spins up.")
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
                        Text("Make sure LM Studio is open and the Local Server is turned on. Check that the `Reachable at` address in LM Studio matches the Server URL in Astrid's settings. If both look correct, the model may still be loading—give it a moment and try again.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Errors after connecting")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("If LM Studio doesn't have a model loaded, or a model fails to load, you may see an error like `Server returned HTTP 400`. Load or reload a model in LM Studio and try your message again.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wrong address")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("If the Server URL in Astrid doesn't match LM Studio, the connection indicator on the Sidebar will show a red dot. Make sure the url Astrid is the same as the `Reachable at` address in LM Studio.")
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
                        Text("Response speed depends on the LM Studio host machine and model size. The first message can be slow if the model needs to load into memory.")
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
