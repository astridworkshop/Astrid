//
//  SettingsView.swift
//  Astrid
//
//  Settings landing screen with navigation to subpages.
//  Presents links to ServerSettingsView, PersonalizationView, AboutView, and HelpGettingStartedView.
//  Copyright © 2026 Astrid Workshop.
//  Licensed under the terms in the LICENSE file.
//
//  Responsibilities:
//  - Presents the main Settings landing screen.
//  - Routes to Settings subpages via standard iOS NavigationStack push.
//  - Contains only lightweight explanatory text (no Server wiring here).

import SwiftUI

struct SettingsView: View {
    private let deepSpaceBlack = Color(red: 0.05, green: 0.07, blue: 0.12)
    private let spaceBlue = Color(red: 0.1, green: 0.15, blue: 0.25)

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Server
                Section {
                    NavigationLink {
                        ServerSettingsView()
                    } label: {
                        Label("Server Connection", systemImage: "server.rack")
                    }

                    Text("Tell Astrid what the URL of your Server server is.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.black)

                // MARK: - Personalization
                Section {
                    NavigationLink {
                        PersonalizationView()
                    } label: {
                        Label("Personalization", systemImage: "person.crop.circle")
                    }

                    Text("Set a preferred name and pronouns. These settings are optional.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.black)

                // MARK: - Help
                Section {
                    NavigationLink {
                        HelpGettingStartedView()
                    } label: {
                        Label("Help / Getting Started", systemImage: "questionmark.circle")
                    }
                    Text("The basics of using Astrid.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.black)

                // MARK: - About
                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                    Text("Find out about Astrid.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.black)
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
            .navigationTitle("Settings")
        }
    }
}



#Preview {
    SettingsView()
}
