import SwiftUI

/// Placeholder root view displayed until Phase 4 (Library UI) replaces it.
struct RootView: View {
    var body: some View {
        Text("Hello, Bòcan")
            .font(.largeTitle)
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Hello, Bòcan")
    }
}

#if DEBUG
    #Preview {
        RootView()
            .frame(width: 900, height: 600)
    }
#endif
