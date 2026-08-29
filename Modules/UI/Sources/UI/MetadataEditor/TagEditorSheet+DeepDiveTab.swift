import SwiftUI

// MARK: - Deep Dive tab (#413)

extension TagEditorSheet {
    /// The recording report for the single loaded track.
    @ViewBuilder var deepDiveTab: some View {
        if let deepDiveVM = self.vm.deepDiveTrackVM {
            DeepDiveTrackView(vm: deepDiveVM)
        } else {
            Text(localized: "Deep Dive is available for a single track.")
                .foregroundStyle(Color.textSecondary)
                .padding()
        }
    }
}
