import SwiftUI

/// A centred loading-state placeholder view.
///
/// Shows an animated activity indicator with an optional title and secondary
/// message. Respects the system Reduce Motion preference: when enabled the
/// spinner is replaced by a static hourglass symbol so the view remains
/// informative without any animation.
///
/// Use this instead of a bare `ProgressView()` whenever the loading state
/// occupies a significant portion of the screen (a full pane, a sheet body,
/// etc.). For tiny inline indicators (inside a toolbar label, a row badge,
/// etc.) continue using `ProgressView` directly.
///
/// ```swift
/// if vm.isLoading {
///     LoadingState(title: "Scanning library…")
/// }
/// ```
public struct LoadingState: View {
    private let title: String
    private let message: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        title: String? = nil,
        message: String? = nil
    ) {
        self.title = title ?? L10n.string("Loading…")
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 16) {
            if self.reduceMotion {
                Image(systemName: "hourglass")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .accessibilityHidden(true)
            }

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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.message.map { "\(self.title). \($0)" } ?? self.title)
        .accessibilityValue(L10n.string("Loading"))
    }
}

#if DEBUG
    #Preview("LoadingState – default") {
        LoadingState()
            .frame(width: 600, height: 400)
    }

    #Preview("LoadingState – with message") {
        LoadingState(
            title: "Scanning library…",
            message: "Reading file metadata from your music folders."
        )
        .frame(width: 600, height: 400)
    }

    #Preview("LoadingState – dark") {
        LoadingState(title: "Loading…")
            .frame(width: 600, height: 400)
            .colorScheme(.dark)
    }
#endif
