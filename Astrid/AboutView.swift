//
//  AboutView.swift
//  Astrid
//
//  Copyright © 2026 Astrid Workshop.
//  Licensed under the terms in the LICENSE file.
//
//
//  Responsibilities:
//  - Explain what Astrid is (local LLM client).
//  - Clarify where models run (Server on user's machine).
//  - Provide privacy and data handling information.
//  - Display version information.
//  - Link to external resources and documentation.
//

import SwiftUI

struct AboutView: View {
    private let deepSpaceBlack = Color(red: 0.05, green: 0.07, blue: 0.12)
    private let spaceBlue = Color(red: 0.1, green: 0.15, blue: 0.25)

    var body: some View {
        Form {
            Section {
                Text("""
Astrid is a private, OpenAI-compatible local AI client that works with tools such as LM Studio and other self-hosted model servers. It does not run models on your iPhone — you need a separate computer with a OpenAI-compatible server such as LM Studio installed.

Astrid is an open source independent project and is not affiliated with LM Studio or its creators.
""")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } header: {
                SectionHeaderView("About Astrid")
            }

            Section {
                Link("GitHub repository", destination: URL(string: "https://github.com/astridworkshop/Astrid")!)
                    .font(.body)
            } header: {
                SectionHeaderView("Links")
            }

            Section {
                Text("Version 1.0")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                SectionHeaderView("Version")
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
        .navigationTitle("About")
    }

}

#Preview {
    NavigationStack {
        AboutView()
    }
}
