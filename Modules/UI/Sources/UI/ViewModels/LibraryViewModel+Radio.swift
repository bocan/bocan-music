import AudioEngine
import Foundation
import Persistence
import Playback

// MARK: - LibraryViewModel + Radio playback

/// Local radio-station playback on `LibraryViewModel` (phase 27-2). Bridges
/// catalog `RadioStation` rows into the shared `QueuePlayer` via the same
/// `.internetRadio` `PlayableSource` path the Subsonic station rows use.
public extension LibraryViewModel {
    /// Starts playback of a catalog radio station. The queue is replaced with
    /// a single open-ended item; nothing pre-caches and no scrobble fires.
    /// Live streams have no fixed duration and don't support seek, so the
    /// engine simply reads frames as they arrive.
    func play(radioStation station: RadioStation) async {
        guard let qp = self.queuePlayer else {
            self.playbackErrorMessage = L10n.string("Playback engine isn't available.")
            return
        }
        guard let url = URL(string: station.streamURL) else {
            self.playbackErrorMessage = L10n.string("\u{201C}\(station.name)\u{201D} has no valid stream URL.")
            return
        }
        let item = QueueItem.makeInternetRadio(
            name: station.name,
            streamURL: url,
            homePage: station.homePageURL
        )
        do {
            try await qp.play(items: [item], startingAt: 0, shuffle: false)
            self.scheduleRadioProfileCapture(for: station)
        } catch {
            self.playbackErrorMessage = L10n.string("Could not start \u{201C}\(station.name)\u{201D}.")
        }
    }

    // MARK: - Station info (phase 27-5)

    /// Payload for `RadioStationInfoSheet`: the catalog row (or an ephemeral
    /// snapshot for a Subsonic server's station) plus live decoder facts.
    struct RadioStationInfoContext: Identifiable {
        public let station: RadioStation
        public let liveDetails: StreamDetails?
        public var id: String {
            self.station.streamURL
        }

        public init(station: RadioStation, liveDetails: StreamDetails?) {
            self.station = station
            self.liveDetails = liveDetails
        }
    }

    /// Live decoder facts for `streamURL`, but only while it is the audible
    /// station; anything else returns nil so a stale sheet cannot show
    /// another stream's numbers.
    func liveRadioDetails(for streamURL: String) async -> StreamDetails? {
        guard self.nowPlaying.nowPlayingRadioStreamURL == streamURL else { return nil }
        return await self.queuePlayer?.currentStreamDetails
    }

    /// Builds the info-sheet payload for the strip's info button while a
    /// station plays. Stations from a Subsonic server are not in the local
    /// catalog; they get an ephemeral snapshot so the sheet still works.
    func nowPlayingRadioInfo() async -> RadioStationInfoContext? {
        guard let url = self.nowPlaying.nowPlayingRadioStreamURL else { return nil }
        let details = await self.liveRadioDetails(for: url)
        var station: RadioStation?
        do {
            station = try await self.radioStations.fetchOne(streamURL: url)
        } catch {
            self.log.warning("radio.info.fetch.failed", ["error": String(reflecting: error)])
        }
        let fallbackName = self.nowPlaying.nowPlayingRadioStationName ?? url
        return RadioStationInfoContext(
            station: station ?? RadioStation(name: fallbackName, streamURL: url, addedAt: 0),
            liveDetails: details
        )
    }

    // MARK: - Profile capture (phase 27-5)

    /// Captures the station profile once playback is up: polls the transport
    /// briefly for the decoder's stream facts (the FFmpeg open happens inside
    /// `engine.load`, normally well within a second), then writes the
    /// machine-owned profile columns. Also rescues a host-fallback name with
    /// `icy-name` when the user never renamed the station.
    private func scheduleRadioProfileCapture(for station: RadioStation) {
        let repo = self.radioStations
        let log = self.log
        Task { [weak self] in
            var details: StreamDetails?
            for attempt in 0 ..< 4 {
                if attempt > 0 {
                    do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
                }
                guard let self,
                      self.nowPlaying.nowPlayingRadioStreamURL == station.streamURL else { return }
                details = await self.queuePlayer?.currentStreamDetails
                if details != nil { break }
            }
            guard let details else { return }
            do {
                try await repo.recordConnection(
                    streamURL: station.streamURL,
                    at: Int64(Date().timeIntervalSince1970),
                    genre: details.icyGenre,
                    stationDescription: details.icyDescription,
                    homePageURL: details.icyURL,
                    lastCodec: details.codecDisplay,
                    lastBitrateKbps: details.claimedBitrateKbps,
                    lastContainer: details.container,
                    lastSampleRateHz: details.sampleRateHz > 0 ? details.sampleRateHz : nil,
                    lastChannels: details.channelCount > 0 ? details.channelCount : nil
                )
                if let icyName = details.icyName, !icyName.isEmpty,
                   let current = try await repo.fetchOne(streamURL: station.streamURL),
                   let host = URL(string: current.streamURL)?.host,
                   current.name == host {
                    var renamed = current
                    renamed.name = icyName
                    try await repo.update(renamed)
                }
            } catch {
                log.warning("radio.profile.capture.failed", ["error": String(reflecting: error)])
            }
        }
    }
}

// MARK: - QueueItem factory

/// Factory for internet-radio queue items, shared by the radio views and
/// the App layer's E2E queue seeding.
public extension QueueItem {
    /// Builds a `QueueItem` representing an internet radio station, local or
    /// Subsonic. `duration = 0` flags the item as live: no scrobble, no
    /// gapless, no scrubbing in the now-playing UI. Public for the App
    /// layer's E2E queue seeding (phase 28).
    static func makeInternetRadio(name: String, streamURL: URL, homePage: String?) -> QueueItem {
        let fmt = AudioSourceFormat(
            sampleRate: 44100,
            bitDepth: 16,
            channelCount: 2,
            isInterleaved: false,
            codec: "stream"
        )
        return QueueItem(
            trackID: -1,
            bookmark: nil,
            fileURL: streamURL.absoluteString,
            duration: 0,
            sourceFormat: fmt,
            title: name,
            artistName: L10n.string("Internet Radio"),
            albumName: homePage,
            genre: nil,
            playableSource: .internetRadio(streamURL: streamURL)
        )
    }
}
