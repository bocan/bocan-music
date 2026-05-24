// Re-export SwiftSonic so that consumers of the Subsonic module (UI, etc.)
// can use the model types (`Song`, `AlbumID3`, `ArtistID3`, `ArtistIndex`,
// `Genre`, `AlbumListType`, ...) that appear in `SubsonicService`'s public
// API without each consumer having to depend on SwiftSonic directly.
@_exported import SwiftSonic
