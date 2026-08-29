import Foundation
import Library

// MARK: - Deep Dive tab models (#413)

extension TagEditorViewModel {
    /// Which Deep Dive model the editor gets: the album report when opened for
    /// one album, the recording report for a single track, neither otherwise.
    static func deepDiveModels(
        service: DeepDiveService?,
        trackIDs: [Int64],
        albumID: Int64?
    ) -> (album: DeepDiveAlbumViewModel?, track: DeepDiveTrackViewModel?) {
        guard let service else { return (nil, nil) }
        if let albumID {
            return (DeepDiveAlbumViewModel(service: service, albumID: albumID), nil)
        }
        if trackIDs.count == 1 {
            return (nil, DeepDiveTrackViewModel(service: service, trackID: trackIDs[0]))
        }
        return (nil, nil)
    }
}

// MARK: - String helper

extension String {
    /// Empty strings read as "no value" when comparing tag fields.
    var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}
