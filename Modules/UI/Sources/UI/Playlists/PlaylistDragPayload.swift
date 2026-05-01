import CoreTransferable
import Foundation
import UniformTypeIdentifiers

// MARK: - UTType

extension UTType {
    /// Private UTI for intra-app playlist drag payloads.
    ///
    /// Declared as an `exportedAs` type so macOS can broker the transfer
    /// across windows within the same app. Must match the `UTExportedTypeDeclarations`
    /// entry in `Info.plist` if cross-process transfer is ever needed.
    static let playlistDrag = UTType(exportedAs: "io.cloudcauldron.bocan.playlist-drag")
}

// MARK: - PlaylistDragPayload

/// Drag payload produced by `PlaylistRow` and consumed by `PlaylistFolderRow`.
///
/// Carries the minimum information needed to perform the reparent:
/// - `playlistID`   — primary key of the playlist being dragged.
/// - `sourceFolderID` — current parent folder (`nil` for top-level), so the
///   drop target can cheaply skip a no-op move (already in this folder).
///
/// Encoded as UTF-8 JSON via `CodableRepresentation` so the payload survives
/// the AppKit dragging pasteboard round-trip.
public struct PlaylistDragPayload: Transferable, Codable, Sendable {
    /// Primary key of the playlist being dragged.
    public let playlistID: Int64

    /// The folder the playlist currently lives in, or `nil` for top-level.
    public let sourceFolderID: Int64?

    public init(playlistID: Int64, sourceFolderID: Int64?) {
        self.playlistID = playlistID
        self.sourceFolderID = sourceFolderID
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .playlistDrag)
    }
}
