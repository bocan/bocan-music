import SwiftUI

/// Transient confirmation toast (e.g. "Re-scanned «Title»") published on
/// ``LibraryViewModel/toast``. Auto-cleared via
/// ``LibraryViewModel/showToast(_:)``.
public struct ToastMessage: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case info, success }

    public let id = UUID()
    public let kind: Kind
    public let text: String

    public init(text: String, kind: Kind = .info) {
        self.text = text
        self.kind = kind
    }
}

/// Lightweight toast banner used for transient confirmations such as
/// "Re-scanned «Title»". Mounted as a top overlay by ``BocanRootView`` and
/// driven by ``LibraryViewModel/toast``; ``LibraryViewModel/showToast(_:)``
/// auto-dismisses after 2 seconds.
public struct ToastBanner: View {
    public let message: ToastMessage

    public init(message: ToastMessage) {
        self.message = message
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: self.iconName)
                .foregroundStyle(self.iconTint)
                .accessibilityHidden(true)
            Text(self.message.text)
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        )
    }

    private var iconName: String {
        switch self.message.kind {
        case .info:
            "info.circle.fill"

        case .success:
            "checkmark.circle.fill"
        }
    }

    private var iconTint: Color {
        switch self.message.kind {
        case .info:
            .accentColor

        case .success:
            .green
        }
    }
}
