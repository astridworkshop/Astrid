//
//  LMStudioSettingsView.swift
//  Astrid
//
//  Settings subpage for configuring the LM Studio server URL.
//  Presented from SettingsView and used by ContentView for LM Studio connectivity UX.
//  Copyright © 2026 Astrid Workshop.
//  Licensed under the terms in the LICENSE file.
//
//  Session 8A — LM Studio Connection Settings
//
//  Responsibilities:
//  - Allow the user to configure the LM Studio server URL.
//  - Provide clear guidance for local vs network-based setups.
//  - UI only for now; persistence and connection testing can be added later.
//

import SwiftUI

struct LMStudioSettingsView: View {
    // Stub state — replace with persisted settings later
    @AppStorage("lmstudio.serverURL") private var serverURL: String = ""
    @State private var validationState: ValidationState = .idle
    @State private var validationTask: Task<Void, Never>?
    @AppStorage("lmstudio.hasShownMissingURLAlert") private var hasShownMissingURLAlert = false
    @State private var isMissingURLAlertPresented = false

    private let deepSpaceBlack = Color(red: 0.05, green: 0.07, blue: 0.12)
    private let spaceBlue = Color(red: 0.1, green: 0.15, blue: 0.25)

    private enum ValidationState: Equatable {
        case idle
        case checking
        case success(String)
        case failure(String)
    }

    private struct LMModelsResponse: Codable {
        struct Model: Codable {
            let id: String
        }

        let data: [Model]
    }

    var body: some View {
        Form {
            Section {
                TextField("Enter Server Address", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .padding(12)
                    .background(Color(uiColor: .tertiarySystemBackground))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(uiColor: .separator), lineWidth: 1.0)
                    )

                Text("Enter the address where LM Studio is serving requests. This is typically found in LM Studio in the Reachable at box.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.top, 2)
                    Text("Warning: The first response from LM Studio can be slow while the model spins up.")
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.orange.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange.opacity(0.45), lineWidth: 1)
                )
                .cornerRadius(10)
                .listRowSeparator(.hidden)

                Text("Visit Astrid Help for more details.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                SectionHeaderView("Server URL")
            }

            Section {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusLabel)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        if let detail = statusDetail {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                }
            } header: {
                SectionHeaderView("Connection Status")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("• LM Studio must be running with the server enabled.")
                    Text("• Turn on Local Server in LM Studio (Server Settings).")
                    Text("• The server must be reachable from this device.")
                    Text("• Use your Mac's LAN IP, not 127.0.0.1.")
                    Text("• Both devices should be on the same Wi‑Fi network.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                SectionHeaderView("Notes")
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
        .navigationTitle("LM Studio Connection")
        .alert("Server URL Required", isPresented: $isMissingURLAlertPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please enter the server URL provided by the server before continuing.")
        }
        .onChange(of: serverURL) { _, _ in
            scheduleValidation()
        }
        .task {
            scheduleValidation()
        }
    }


    private var statusLabel: String {
        switch validationState {
        case .idle:
            return "Not checked yet"
        case .checking:
            return "Checking…"
        case .success:
            return "Connected"
        case .failure:
            return "Disconnected"
        }
    }
    
    private var statusDetail: String? {
        switch validationState {
        case .success(let detail):
            // Extract model name from "Connected — model-name"
            if detail.contains("—") {
                return detail.components(separatedBy: "—").last?.trimmingCharacters(in: .whitespaces)
            }
            return detail == "Connected — No model loaded" ? "No model loaded" : nil
        case .failure(let detail):
            return detail
        default:
            return nil
        }
    }

    private var statusColor: Color {
        switch validationState {
        case .success:
            return .green
        case .failure:
            return .red
        case .checking:
            return .yellow
        case .idle:
            return .gray
        }
    }

    private func scheduleValidation() {
        validationTask?.cancel()
        if serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationState = .idle
            if !hasShownMissingURLAlert {
                isMissingURLAlertPresented = true
                hasShownMissingURLAlert = true
            }
            return
        }
        validationTask = Task { @MainActor in
            validationState = .checking
            try? await Task.sleep(nanoseconds: 450_000_000)
            await validateConnection()
        }
    }

    @MainActor
    private func validateConnection() async {
        let normalizedBase = LMStudioClient(baseURL: serverURL).baseURLString
        guard let url = URL(string: normalizedBase)?
            .appendingPathComponent("v1")
            .appendingPathComponent("models") else {
            validationState = .failure("Invalid server URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                validationState = .failure("Server unreachable")
                return
            }

            let decoded = try JSONDecoder().decode(LMModelsResponse.self, from: data)
            if let first = decoded.data.first?.id, !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                validationState = .success("Connected — \(first)")
            } else {
                validationState = .success("Connected — No model loaded")
            }
        } catch {
            validationState = .failure("Server unreachable")
        }
    }
}

#Preview {
    NavigationStack {
        LMStudioSettingsView()
    }
}
