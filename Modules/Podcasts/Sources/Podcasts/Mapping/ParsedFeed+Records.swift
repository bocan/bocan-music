import Foundation
import Persistence

extension ParsedFeed {
    /// Maps the parsed feed into a `Podcast` record ready for upsert.
    ///
    /// - Parameters:
    ///   - feedURL: The normalized storage URL (https-preferred, no fragment).
    ///   - hints: Optional search result carrying Podcast Index / iTunes IDs.
    ///   - etag: HTTP ETag validator from the fetch response.
    ///   - lastModified: HTTP Last-Modified validator from the fetch response.
    ///   - now: Snapshot date for `addedAt` and `lastRefreshedAt`.
    func toPodcast(
        feedURL: URL,
        hints: PodcastSearchResult? = nil,
        etag: String? = nil,
        lastModified: String? = nil,
        now: Date
    ) -> Podcast {
        let catJSON = try? JSONEncoder().encode(self.categories)
        let ts = now.timeIntervalSince1970
        return Podcast(
            feedURL: feedURL.absoluteString,
            title: self.title,
            author: self.author,
            description: self.description,
            artworkURL: self.artworkURL?.absoluteString,
            link: self.link?.absoluteString,
            language: self.language,
            explicit: self.explicit,
            categoriesJSON: catJSON,
            ownerName: self.ownerName,
            ownerEmail: self.ownerEmail,
            copyright: self.copyright,
            fundingURL: self.fundingURL?.absoluteString,
            fundingText: self.fundingText,
            itunesCollectionID: hints?.itunesCollectionID.map { Int64($0) },
            podcastIndexID: hints?.podcastIndexID.map { Int64($0) },
            podcastGUID: self.podcastGUID,
            httpETag: etag,
            httpLastModified: lastModified,
            lastRefreshedAt: ts,
            lastRefreshError: nil,
            subscribed: true,
            addedAt: ts
        )
    }
}

extension ParsedEpisode {
    /// Maps the parsed episode into a `PodcastEpisode` record ready for upsert.
    func toEpisode(podcastID: Int64, now: Date) -> PodcastEpisode {
        PodcastEpisode(
            podcastID: podcastID,
            guid: self.guid,
            title: self.title,
            subtitle: self.subtitle,
            descriptionHTML: self.descriptionHTML,
            audioURL: self.audioURL.absoluteString,
            audioMIME: self.audioMIME,
            audioByteLength: self.audioByteLength,
            duration: self.duration,
            publishedAt: self.publishedAt?.timeIntervalSince1970,
            season: self.season,
            episodeNumber: self.episodeNumber,
            episodeType: self.episodeType,
            artworkURL: self.artworkURL?.absoluteString,
            chaptersURL: self.chaptersURL?.absoluteString,
            transcriptURL: self.transcriptURL?.absoluteString,
            link: self.link?.absoluteString,
            explicit: self.explicit,
            addedAt: now.timeIntervalSince1970
        )
    }
}
