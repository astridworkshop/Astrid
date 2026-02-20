//
//  ServerSettingsView.swift
//  Astrid
//
//  Settings subpage for configuring the Server URL and validating connectivity.
//  Presented from SettingsView and used by ContentView for Server connectivity UX.
//  Copyright © 2026 Astrid Workshop.
//  Licensed under the terms in the LICENSE file.
//
//  Responsibilities:
//  - Allow the user to configure and persist the Server URL via AppStorage.
//  - Validate connectivity by checking the server's `/v1/models` response.
//  - Provide clear guidance for local vs network-based setups.
//

import SwiftUI

struct ServerSettingsView: View {
    // Stub state — replace with persisted settings later
    @AppStorage("Server.serverURL") private var serverURL: String = ""
    @State private var validationState: ValidationState = .idle
    @State private var validationTask: Task<Void, Never>?
    @AppStorage("Server.hasShownMissingURLAlert") private var hasShownMissingURLAlert = false
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

    var body: some View {
        Form {
            Section {
                HStack(spacing: 0) {
                    Text("http://")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)

                    TextField("Server Address", text: $serverURL)
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
                .onAppear {
                    let stripped = stripServerURLScheme(serverURL)
                    if stripped != serverURL {
                        serverURL = stripped
                    }
                }
                .onChange(of: serverURL) { _, newValue in
                    let stripped = stripServerURLScheme(newValue)
                    if stripped != newValue {
                        serverURL = stripped
                    }
                }

                Text("Enter the address where your local LLM server is serving requests (e.g., http://192.168.1.100:1234). Check your server software for the exact address.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.top, 2)
                    Text("Note: The first response may be slow while the model loads into memory.")
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

                        if case .failure = validationState {
                            Text("Ensure your OpenAI-compatible server is running and on the same Wi-Fi network.")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.orange.opacity(0.95))
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .background(
                                    Color.orange.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )
                        }
                    }
                    
                    Spacer()
                }
            } header: {
                SectionHeaderView("Connection Status")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("• Your local LLM server must be running and accepting connections.")
                    Text("• The server must be reachable from this device.")
                    Text("• Use your computer's LAN IP address, not 127.0.0.1 or localhost.")
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
        .navigationTitle("Server Connection")
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
        let normalizedBase = ServerClient(baseURL: serverURL).baseURLString
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
        ServerSettingsView()
    }
}
