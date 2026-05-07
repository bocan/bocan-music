import SwiftUI

/// A centred error-state placeholder view.
///
/// Shows a symbol, a required title, an optional descriptive message, and an
/// optional recovery-action button. Matches the visual language of
/// `EmptyState` and `LoadingState` so all three placeholder states look
/// consistent across the app.
///
/// ```swift
/// if let err = vm.lastError {
///     ErrorState(
///         title: "Could Not Load",
///         message: err,
///         actionLabel: "Try Again",
///         action: { Task { await vm.reload() } }
///     )
/// }
/// ```
public struct ErrorState: View {
    private let symbol: String
    private let title: String
    private let message: String?
    private let actionLabel: String?
    private let action: (() -> Void)?

    public init(
        title: String,
        symbol: String = "exclamationmark.triangle",
        message: String? = nil,
        actionLabel: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionLabel = actionLabel
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: self.symbol)
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(self.title)
                    .font(Typography.title)
                    .foregroundStyle(Color.textPrimary)

                if let message {
                    Text(message)
                        .font(Typography.body)
                        .foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
            }

            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.message.map { "\(self.title). \($0)" } ?? self.title)
        .accessibilityAddTraits(.isStaticText)
    }
}

#if DEBUG
    #Preview("ErrorState – default") {
        ErrorState(
            title: "Could Not Load",
            message: "The playlist could not be read from the database."
        )
        .frame(width: 600, height: 400)
    }

    #Preview("ErrorState – with retry") {
        ErrorState(
            title: "Could Not Load",
            message: "Something went wrong loading your smart playlist.",
            actionLabel: "Try Again"
        ) {}
            .frame(width: 600, height: 400)
    }

    #Preview("ErrorState – dark") {
        ErrorState(
            title: "Scan Failed",
            message: "The library folder could not be read. Check permissions in System Settings."
        )
        .frame(width: 600, height: 400)
        .colorScheme(.dark)
    }
#endif
