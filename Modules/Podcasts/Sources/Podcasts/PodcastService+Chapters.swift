import Foundation
import Observability
import Persistence

// MARK: - Chapters

/// Podcasting 2.0 chapters: network-first fetch with the stored copy as the fallback.
public extension PodcastService {
    /// Fetches the chapter list for an episode from its `chapters_url`. Returns
    /// `[]` when the episode has no chapters URL. The fetch may throw (network /
    /// HTTP / size); callers map a throw to "no chapters".
    ///
    /// Network first, so a publisher's correction is picked up. Each downloaded
    /// document is stored in `podcast_episode_chapters` (#608), which is what
    /// Phone Sync serves and what this falls back to when the fetch fails.
    func chapters(podcastID: Int64, guid: String) async throws -> [Chapter] {
        guard let episode = try await episodeRepo.fetchByGUID(podcastID: podcastID, guid: guid),
              let urlString = episode.chaptersURL,
              let url = URL(string: urlString) else {
            return []
        }
        let fetched: ChaptersFetcher.Fetched
        do {
            fetched = try await self.chaptersFetcher.fetch(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let cached = await self.cachedChapters(podcastID: podcastID, guid: guid) {
                return cached
            }
            throw error
        }
        if let body = fetched.body {
            await self.storeChapters(body, chapters: fetched.chapters, podcastID: podcastID, guid: guid, sourceURL: urlString)
        }
        return fetched.chapters
    }

    /// Fetches and stores an episode's chapters without returning them, for a
    /// caller that only wants the cache warm. The App layer runs this when a
    /// download finishes, so a synced episode's chapters reach the phone even
    /// if the episode was never opened on the Mac.
    func cacheChapters(podcastID: Int64, guid: String) async {
        do {
            _ = try await self.chapters(podcastID: podcastID, guid: guid)
        } catch {
            self.log.warning("chapters.cache.failed", ["guid": guid, "error": String(reflecting: error)])
        }
    }
}

// MARK: - Chapters helpers

extension PodcastService {
    /// Stores a downloaded chapters document. Only a body that yields at least
    /// one chapter and is valid UTF-8 is kept: the row is what tells the phone
    /// an episode has chapters, so an empty or unreadable document stays out.
    private func storeChapters(
        _ body: Data,
        chapters: [Chapter],
        podcastID: Int64,
        guid: String,
        sourceURL: String
    ) async {
        guard !chapters.isEmpty, let content = String(data: body, encoding: .utf8) else { return }
        do {
            try await self.chaptersRepo.upsert(
                PodcastChapters(podcastID: podcastID, guid: guid, content: content, sourceURL: sourceURL)
            )
        } catch {
            self.log.warning("chapters.store.failed", ["guid": guid, "error": String(reflecting: error)])
        }
    }

    /// The stored chapters for an episode, or `nil` when there are none (or the
    /// read failed, which is logged). Used when the network fetch fails.
    private func cachedChapters(podcastID: Int64, guid: String) async -> [Chapter]? {
        do {
            guard let cached = try await self.chaptersRepo.fetchCurrent(podcastID: podcastID, guid: guid) else {
                return nil
            }
            return ChaptersFetcher.parse(Data(cached.content.utf8))
        } catch {
            self.log.warning("chapters.cache.readFailed", ["guid": guid, "error": String(reflecting: error)])
            return nil
        }
    }
}
