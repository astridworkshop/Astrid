//
//  ModelOption.swift
//  Astrid
//
//  Lightweight model descriptor used by Server settings and chat configuration UI.
//  Shared between ServerSettingsView and ChatViewModel as display/API identifiers.
//  Copyright © 2026 Astrid Workshop.
//  Licensed under the terms in the LICENSE file.

import Foundation

struct ModelOption: Identifiable, Hashable {
    let id: String              // e.g. "gemma3n"
    let displayName: String     // e.g. "Gemma 3N"
    let apiName: String         // e.g. "google/gemma-3n-e4b"
}
