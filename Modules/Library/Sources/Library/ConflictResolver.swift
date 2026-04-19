import Foundation
import Observability

/// Policy: when a track on disk is modified but `user_edited = 1`,
/// we cannot overwrite user changes without consent.
///
/// For v1 the policy is simple: **user edits win**.  We log a warning
/// and return `.conflict` so the caller can report it.
enum ConflictResolver {
    enum Resolution {
        /// Import should proceed normally (overwrite DB tags from disk).
        case overwrite
        /// The user has pending edits; do not overwrite, surface a conflict.
        case conflict(trackID: Int64)
    }

    /// Determines what to do when a file is modified and an existing track is found.
    ///
    /// - Parameters:
    ///   - existingTrack: The `Track` row already in the DB, or `nil` if new.
    ///   - diskTags: Tags freshly read from disk (unused in v1, reserved for future diff).
    static func resolve(existingTrackID: Int64, userEdited: Bool) -> Resolution {
        guard userEdited else { return .overwrite }
        AppLogger.make(.library).warning(
            "conflict.user_edited_wins",
            ["trackID": existingTrackID]
        )
        return .conflict(trackID: existingTrackID)
    }
}
