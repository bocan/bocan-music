import SwiftUI

/// A centred empty-state placeholder view.
///
/// Shows a symbol, a title, and an optional message. All secondary chrome
/// (columns, toolbars) should be hidden when the parent data is empty.
public struct EmptyState: View {
    private let symbol: String
    private let title: String
    private let message: String?
    private let action: (() -> Void)?
    private let actionLabel: String?

    public init(
        symbol: String,
        title: String,
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
    }
}

#if DEBUG
    #Preview {
        EmptyState(
            symbol: "music.note",
            title: "No Songs",
            message: "Add a music folder to start building your library.",
            actionLabel: "Add Folder"
        ) {}
            .frame(width: 600, height: 400)
    }
#endif
