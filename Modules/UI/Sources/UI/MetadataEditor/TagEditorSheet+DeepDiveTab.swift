import SwiftUI

// MARK: - Deep Dive tab (#413)

extension TagEditorSheet {
    /// The album report when opened for an album, else the recording report
    /// for the single loaded track.
    @ViewBuilder var deepDiveTab: some View {
        if let albumVM = self.vm.deepDiveAlbumVM {
            DeepDiveAlbumView(vm: albumVM)
        } else if let deepDiveVM = self.vm.deepDiveTrackVM {
            DeepDiveTrackView(vm: deepDiveVM)
        } else {
            Text(localized: "Deep Dive is available for a single track.")
                .foregroundStyle(Color.textSecondary)
                .padding()
        }
    }
}
