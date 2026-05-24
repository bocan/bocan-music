import Foundation
import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicCoverImage

/// Async-loaded square cover art for a Subsonic entity, with a deterministic
/// gradient placeholder while the URL is being resolved or when the server
/// has no artwork for the entity.
///
/// The URL itself is fetched from `SubsonicCoverArtProvider` (it carries auth
/// tokens, hence the actor hop); `AsyncImage` then performs the HTTP load.
struct SubsonicCoverImage: View {
    let provider: SubsonicCoverArtProvider?
    let serverID: UUID
    let entityID: String?
    let seed: Int
    let pixelSize: Int

    @State private var resolvedURL: URL?

    var body: some View {
        // The gradient placeholder is the layout driver so that its size is
        // never affected by a non-square loaded image.  The image sits in an
        // overlay, matching the technique used by the local `Artwork` component.
        // `.clipShape` then clips any `scaledToFill` overflow, preventing a
        // wildly-shaped album cover from bleeding into neighbouring cells.
        GradientPlaceholder(seed: self.seed)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let url = self.resolvedURL {
                    AsyncImage(url: url) { phase in
                        if case let .success(image) = phase {
                            image
                                .resizable()
                                .scaledToFill()
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.artworkCornerRadius, style: .continuous))
            .task(id: self.taskKey) {
                await self.resolve()
            }
    }

    private var taskKey: String {
        "\(self.serverID.uuidString)|\(self.entityID ?? "-")|\(self.pixelSize)"
    }

    private func resolve() async {
        guard let provider, let entityID else {
            self.resolvedURL = nil
            return
        }
        do {
            self.resolvedURL = try await provider.coverArtURL(
                serverID: self.serverID,
                entityID: entityID,
                size: self.pixelSize
            )
        } catch {
            self.resolvedURL = nil
        }
    }
}
