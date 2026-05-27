import SwiftUI

// MARK: - SubsonicSourcePill

/// Small rounded "source" badge used by multi-source Subsonic search
/// results to identify which server a row, cell, or grid item came from.
struct SubsonicSourcePill: View {
    let name: String

    var body: some View {
        Text(self.name)
            .font(Typography.caption.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.55))
            )
            .accessibilityLabel("Source: \(self.name)")
    }
}

// MARK: - SubsonicSearchFailedBanner

/// Inline banner shown above multi-source search results when one or more
/// servers failed (network / timeout / auth) during the fan-out. Lets the
/// user know the result list may be incomplete without blocking the view.
struct SubsonicSearchFailedBanner: View {
    let serverNames: [String]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
            Text("Some servers didn't respond: \(self.serverNames.joined(separator: ", "))")
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}
