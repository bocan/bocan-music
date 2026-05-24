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
        ZStack {
            if let url = self.resolvedURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()

                    case .empty, .failure:
                        GradientPlaceholder(seed: self.seed)

                    @unknown default:
                        GradientPlaceholder(seed: self.seed)
                    }
                }
            } else {
                GradientPlaceholder(seed: self.seed)
            }
        }
        .aspectRatio(1, contentMode: .fit)
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
