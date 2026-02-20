//
//  SectionHeaderView.swift
//  Astrid
//
//  Shared section header styling for Settings and Help screens.
//
//  Copyright © 2026 Astrid Workshop.
//  Licensed under the terms in the LICENSE file.
//

import SwiftUI

struct SectionHeaderView: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote)
                .fontWeight(.semibold)
                .textCase(.uppercase)
                .tracking(1.1)
                .foregroundStyle(.white)
            Rectangle()
                .fill(Color.accentColor.opacity(0.7))
                .frame(width: 36, height: 2)
        }
        .padding(.top, 6)
    }
}

#Preview {
    SectionHeaderView("Sample Header")
        .padding()
        .background(Color.black)
}
