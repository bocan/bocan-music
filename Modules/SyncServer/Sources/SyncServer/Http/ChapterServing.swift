import Foundation
import Observability
import Persistence

/// `GET /v1/chapters/{episodeId}` (sync-protocol.md section 6): the episode's
/// Podcasting 2.0 chapters JSON, passed through as the Mac cached it.
///
/// The handler reads `podcast_episode_chapters` and nothing else: a serving
/// handler makes no outbound request, so an episode whose chapters the Mac has
/// not fetched answers `404`. The Podcasts module fills the cache when chapters
/// are shown and when a download finishes (#608), and the manifest's
/// `hasChapters` is true exactly when this route has a document to serve.
///
/// The id is resolved the way the episode file route resolves it: against the
/// downloaded episodes only, and only while the profile includes podcasts, so
/// the route never serves an episode the manifest does not list.
struct ChapterServing {
    private let episodeStateRepository: EpisodeStateRepository
    private let chaptersRepository: ChaptersRepository
    private let profileRepository: SyncProfileRepository
    private let log = AppLogger.make(.sync)

    init(database: Database) {
        self.episodeStateRepository = EpisodeStateRepository(database: database)
        self.chaptersRepository = ChaptersRepository(database: database)
        self.profileRepository = SyncProfileRepository(database: database)
    }

    func respond(_ match: Router.RouteMatch) async -> HttpResponse {
        guard let episodeIdHash = match.parameters["episodeId"] else { return Self.notFound }
        do {
            guard await ManifestRoutes.loadProfile(self.profileRepository).includesPodcasts else {
                return Self.notFound
            }
            let downloaded = try await self.episodeStateRepository.fetchByDownloadState([.downloaded])
            guard let state = downloaded.first(where: { FileServing.guidHash($0.guid) == episodeIdHash }) else {
                return Self.notFound
            }
            guard let cached = try await self.chaptersRepository.fetchCurrent(
                podcastID: state.podcastID,
                guid: state.guid
            ) else {
                return Self.notFound
            }
            return .json(data: Data(cached.content.utf8))
        } catch {
            self.log.error("file.chapters.failed", ["id": episodeIdHash, "error": String(reflecting: error)])
            return .error(.internal, message: "Error", status: 500)
        }
    }

    private static var notFound: HttpResponse {
        .error(.notFound, message: "Not found", status: 404)
    }
}
