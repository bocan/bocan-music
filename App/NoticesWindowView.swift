import SwiftUI
import UI

// MARK: - NoticesWindowView

/// Full-screen window that renders third-party open-source licence notices.
struct NoticesWindowView: View {
    var body: some View {
        NoticesHTMLView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
