//
//  AstridSidebarView.swift
//  Astrid
//
//  Sidebar UI extracted from ContentView for session history and settings entry points.
//  Receives state and callbacks from ContentView (data originates in ChatViewModel).
//  Copyright © 2026 Astrid Workshop.
//  Licensed under the terms in the LICENSE file.
//
//
//

import SwiftUI

/// Sidebar UI extracted from ContentView (Session 8A).
/// - Fixed sidebar layout (header/sections do not scroll)
/// - Only chat history scrolls (capped rows) with partial-row peek + fade affordance
/// - Harmonious sidebar background styling
/// - Delegates all actions to parent via callbacks
struct AstridSidebarView: View {
    // Inputs
    let isServerOnline: Bool
    let sessions: [ChatSession]
    let titleForSession: (ChatSession) -> String

    // Profile UI inputs
    @Binding var profileCatalog: ProfileCatalog
    @Binding var selectedProfileID: UUID
    let onCreateProfile: () -> Void
    let onManageProfiles: () -> Void

    // Actions
    let onNewChat: () -> Void
    let onSelectSession: (UUID) -> Void
    let onRequestDelete: (ChatSession) -> Void
    let onOpenSettings: () -> Void

    // Styling palette (derived from ContentView constants)
    let deepSpaceBlack: Color
    let spaceBlue: Color
    let splashFooterMask: Color

    // Step 2 behavior
    let historyMaxVisibleRows: Int
    let historyRowHeight: CGFloat

    // MARK: - Sidebar Background
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

    // MARK: - Rows
    @ViewBuilder
    private var serverStatusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Circle()
                    .fill(isServerOnline ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                    .shadow(color: (isServerOnline ? Color.green : Color.red).opacity(0.5), radius: 4)
                Text(isServerOnline ? "Local Server Online" : "No Local AI Server Detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if !isServerOnline {
                Text("Start your local AI server and ensure it's connected to the same Wi-Fi network.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.orange.opacity(0.95))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var newChatRow: some View {
        Button { onNewChat() } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.bubble")
                    .foregroundStyle(.white.opacity(0.9))
                Text("New Chat")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Chat")
    }

    @ViewBuilder
    private var historyList: some View {
        if sessions.isEmpty {
            Label("Previous Chats", systemImage: "clock")
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        } else {
            let visibleRows = min(sessions.count, historyMaxVisibleRows)
            let peekFraction: CGFloat = (sessions.count > historyMaxVisibleRows) ? 0.50 : 0.0
            let targetHeight = (CGFloat(visibleRows) + peekFraction) * historyRowHeight

            ZStack(alignment: .bottom) {
                List {
                    ForEach(sessions) { session in
                        Button {
                            onSelectSession(session.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "bubble.left")
                                    .foregroundStyle(.secondary)
                                Text(titleForSession(session))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) { onRequestDelete(session) } label: {
                                Label("Delete Chat", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { onRequestDelete(session) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .environment(\.defaultMinListRowHeight, historyRowHeight)
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
                .frame(height: targetHeight)
                .clipped()

                if sessions.count > historyMaxVisibleRows {
                    LinearGradient(
                        gradient: Gradient(colors: [Color.clear, Color.black.opacity(0.22)]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 28)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private var profileRow: some View {
        Menu {
            Picker("Profile", selection: $selectedProfileID) {
                ForEach(profileCatalog.profiles) { p in
                    Text(p.name).tag(p.id)
                }
            }

            Divider()

            Button("Create New Profile…") { onCreateProfile() }
            Button("Manage Profiles…") { onManageProfiles() }
        } label: {
            HStack {
                Text(profileCatalog.defaultProfile.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private var settingsRow: some View {
        Button { onOpenSettings() } label: {
            Label("Settings", systemImage: "gearshape")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Astrid")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 8)

            serverStatusRow

            Divider().opacity(0.35)

            Text("CHAT")
                .font(.caption)
                .foregroundStyle(.secondary)

            newChatRow

            Text("CHAT HISTORY")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            historyList

            Text("PROFILE")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)

            profileRow

            Text("APP")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)

            settingsRow

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .background(sidebarBackground)
    }
}
