# `try?` audit (#459), first pass

Report only, no fixes. Every `try?` in production sources on 2026-09-11 (tree at PR #479's head, `6e759707`), read in context and put into one of three classes. This is the input for the rewritten rule, the allowlist and the per-module fix PRs that #459 asks for next.

## Method

```
rg -n '\btry\?' Modules/*/Sources App --glob '*.swift'   # code lines only, comments dropped
```

The word boundary matters: the issue's count of 334 included four identifiers ending in `try` followed by `?` (`LogEntry?`, `Entry?`). Two more went in #479. Tests are out of scope, as the issue says. Base: **325 sites**.

Each site was read with the lines around it. The class is a judgement about what the caller does with the swallowed error, not about the callee:

| Class | Meaning | The shape to copy |
|---|---|---|
| **(a) idiom** | The failure carries no information the app can act on, or the fallback is the documented contract. No log. | Stays as `try?`; the pattern goes on the allowlist. |
| **(b) log it** | The app recovers, but a person reading the log later would want to know. Today the failure is invisible. | `do { try ... } catch { log.warning("op.failed", ["error": String(reflecting: error)]) }`, or the small helper below. |
| **(c) fail loudly** | Recovery is wrong: the app carries on in a state the user cannot see, a user action reports success it did not have, or a value derived from a swallowed error goes on the wire or into the database. | `try` and let it propagate, or a `log.error` plus a user-visible surface (toast, alert, `lastError`). |

## Result

| Module | Sites | (a) idiom | (b) log it | (c) fail loudly |
|---|---|---|---|---|
| UI | 107 | 41 | 57 | 9 |
| Library | 98 | 33 | 62 | 3 |
| Playback | 28 | 8 | 13 | 7 |
| App | 24 | 9 | 14 | 1 |
| AudioEngine | 23 | 20 | 3 | 0 |
| Podcasts | 18 | 7 | 10 | 1 |
| SyncServer | 11 | 6 | 1 | 4 |
| Persistence | 9 | 9 | 0 | 0 |
| Scrobble | 6 | 1 | 5 | 0 |
| Subsonic | 1 | 1 | 0 | 0 |
| **Total** | **325** | **135** | **165** | **25** |

The issue's estimate ("about 70 harmless, the rest silently swallow") was pessimistic on the idioms and right about the rest: 135 are idioms, 190 swallow something a log or the user should have seen.

## The 25 that should fail loudly

These are the ones to fix first, ahead of any tooling. Each is a place where the app continues as if the operation succeeded.

**User actions that report nothing on failure** (the user clicked, nothing happened, no log):

- `UI/Browse/TracksView+Actions.swift:46` Add to Playlist from the context menu.
- `UI/ViewModels/LibraryViewModel+Rating.swift:44` Love toggle.
- `UI/Console/LogConsoleView.swift:274` Save Log writes the file with a bare `try?`.
- `UI/MetadataEditor/ArtworkEditor.swift:99` and `:126` an unreadable art file picked or dropped by the user.
- `UI/Scrobble/ScrobbleSettingsViewModel.swift:150`, `:173`, `:191` Disconnect from a scrobbler; a Keychain failure leaves the credentials in place and the UI says disconnected after `refreshConnectionState` re-reads them, or worse, keeps flip-flopping.
- `Playback/QueuePlayer.swift:1642`, `:1651`, `:1654`, `:1657`, `:1662`, `:1668`, `:1680` the media-key and remote-command handlers wrap `play`, `next`, `previous` and `seek` in `try?`; the in-app buttons route the same errors to `playbackErrorMessage`.

**Silent loss of a feature for the whole session:**

- `UI/ViewModels/LibraryViewModel.swift:501` `MetadataEditService(database:)` in `try?`: if it throws, the tag editor is `nil` for the session and nothing says so.
- `App/BocanApp.swift:721` `SubsonicStreamCache` init in `try?`: Subsonic streaming is unavailable for the session and nothing says so.

**Data decisions made from a swallowed error:**

- `Library/ScanCoordinator.swift:105` the scan seeds its change detector from `fetchAllIncludingDisabled()`; on a DB error the seed is empty, so removed files are never pruned and every file looks new.
- `Library/ScanCoordinator.swift:296` the existing-row lookup that protects user-edited tracks from being overwritten; on a DB error the track looks new and the conflict path is skipped.
- `Library/Edit/EditTransaction.swift:189` the user's new cover art is not persisted to the cache or propagated to the album, and the edit still reports success.
- `Podcasts/Downloads/DownloadStore.swift:132` and `SyncServer/Manifest/ManifestBuilder.swift:206` `while let chunk = try? handle.read(...)`: a read error mid-file ends the loop and the hash of a partial file is stored, then served to the phone as the file's identity. (`ContentHashService.sha256Hex` does the same loop with `try` and is correct.)

**Protocol answers built from a swallowed error:**

- `SyncServer/Http/ManifestRoutes.swift:18`, `:19` and `SyncServer/SyncServer.swift:55` the ping reply and the Bonjour advertisement send an empty server id and generation 0 when the meta read fails; the phone cannot tell that from a different server.

## The idioms (135)

These stay as they are. Grouped so the allowlist can be written as patterns rather than 135 lines:

| Family | Count | Pattern |
|---|---|---|
| Sleep | 43 | `try? await Task.sleep(...)`: cancellation is the only error, and the code after it re-checks `Task.isCancelled` or is idempotent. Two sites proceed at once on cancellation (`Subsonic/SubsonicAnnotations.swift:110` retries immediately, `UI/Visualizers/FullscreenWindow.swift:66` moves a disappearing window); both are harmless today, and the tighter shape (below) removes the question. |
| File attributes | 10 | `try? url.resourceValues(forKeys:)` with a fallback value. |
| Remove if present | 10 | `try? FileManager.default.removeItem(at:)` on a cache, temp or sentinel file. |
| Close | 8 | `defer { try? handle.close() }` and the inline form on a read handle. |
| Browse cache | 8 | Subsonic view-model cache decode and encode; a bad entry falls through to the network load. |
| Lenient decoding by contract | 12 | CAA's numeric-or-string id and optional sizes, the smart-criterion unknown-field message, podcast persons and podroll (documented tolerant), transcript JSON, chapters JSON. |
| Directory pre-creation | 6 | `try? FileManager.default.createDirectory(...)`; the consumer's write reports the failure. |
| Tooling | 5 | `DebugAudioView`, `E2ESeeder`, the `BocanSchema` tool. |
| Cache miss, conservative fallback, cosmetic | 33 | Listed per site in the appendix; each has a reason. |

The 25 are filed as one issue per module: #480 (UI), #481 (Library), #482 (Playback), #483 (App), #484 (Podcasts), #485 (SyncServer).

## The rule (now in CLAUDE.md and `_standards.md`)

The old wording, "no `try?` without an `else { log.warning }` companion", named a shape that does not exist for an expression, so it was never copyable. The replacement, as written into both files:

> **`try?` is allowed only for the allowlisted idioms in `Scripts/audit-try-optional-allowlist.txt`.** Everything else handles the error in one of two ways:
>
> - **Recover and log.** `do { try ... } catch { log.warning("op.failed", ["error": String(reflecting: error)]) }`, with the context keys the log line needs (id, path, server). For a value with a fallback, the same shape around a `let`.
> - **Propagate.** `try` and let the caller decide. A user action that fails must reach the user (toast, alert, `lastError`); a value that goes into the database or on the wire is never derived from a swallowed error.
>
> The allowlisted idioms are: a `Task.sleep` followed by a cancellation check (or, better, `try await Task.sleep` inside a throwing `Task` closure, which exits cleanly on cancellation with no `try?` and no check); `defer { try? handle.close() }`; remove-if-present of a cache or temp file; directory pre-creation before a write that reports its own failure; a file-attribute read with a fallback; a decode whose fallback is the documented contract. Anything else on the allowlist carries a reason on its line.

A small helper would make the (b) shape a one-liner and keep the log keys uniform; `Observability` already owns the logger, so it can own this:

```swift
/// Runs `body`, logs a failure as `event` on `log`, and returns nil.
func logged<T>(_ event: String, _ log: AppLogger, _ context: [String: Any] = [:], _ body: () async throws -> T) async -> T?
```

## Enforcement (built)

The same mechanism as the help-text audit. `Scripts/audit-try-optional.py` walks `Modules/*/Sources` and `App`, matches every `try?` first against six idiom patterns and then against the per-site allowlist, and fails on any site outside both. `make lint` runs it **strict**, not in `--warn` mode: the per-module fix PRs all landed before the script did, so there was never a rollout window to stage.

The six patterns cover the families that carry no information the app can act on: a cancellation-only `Task.sleep`; a file-handle close; remove-if-present and directory pre-creation; a file-attribute or directory-listing read with a fallback; a documented-contract `Codable` encode or decode; a best-effort file read with a fallback. Between them they clear 118 of the 135 surviving sites.

The remaining 17 sit in `Scripts/audit-try-optional-allowlist.txt`, each with a reason on its line, keyed `<relative-path>|<normalized line>` so ordinary edits do not churn the file. The script prints a note when an entry goes stale, and `--keys` emits paste-ready lines for anything currently failing. `Scripts/tests/audit-try-optional-test.sh` covers it against a fixture tree (`make test-scripts`, and CI runs it on Linux).

## Fix order

As the issue says, one PR per module, biggest first. Suggested cut, so each PR is one review:

1. The 25 (c) sites, one `fix` PR per module issue (#480 to #485): they are behaviour bugs, and the changelog entry writes itself.
2. UI (57 (b) sites), mostly view-model loads that show an empty page on a DB error.
3. Library (62), mostly repository reads in the scanner, the editor and lyrics.
4. Playback, App, Podcasts, Scrobble, AudioEngine, SyncServer (46 between them).
5. The audit script, strict, once the allowlist is the only thing left.

**Status: done.** The 25 (c) sites landed as #480 to #485. The 165 (b) sites landed as one commit per module on `fix/459-quiet-recoveries` (#491 to #498), every fallback value preserved, each one now logging why it was needed. Two catch blocks that held only a comment turned up along the way, in SyncServer and the App layer, plus three more in UI: the same defect, invisible to a search for `try?`, which is why the 165 was a floor rather than a count. The script and its allowlist close the loop.

## Appendix: every site

Class and reason per site. The path is relative to the module's source root.


### UI

| Site | Code | Class | Why |
|---|---|---|---|
| `Browse/AlbumDetailView.swift:174` | `if let name = try? await artistRepo.fetch(id: artistID).name {` | b | album page detail missing on a DB error |
| `Browse/AlbumDetailView.swift:181` | `if let artRec = try? await artRepo.fetch(hash: hash) {` | b | album page detail missing on a DB error |
| `Browse/AlbumsGridView.swift:463` | `if let tracks = try? await repo.fetchAll(albumID: id) {` | b | album tracks silently missing from the collected list |
| `Browse/ArtistsView.swift:282` | `guard let tracks = try? await repo.fetchAll(albumID: id) else { return }` | b | Get Info on an album silently does nothing on a DB error |
| `Browse/ArtistsView.swift:293` | `async let albumsFetch: [Album] = await (try? AlbumRepository(` | b | artist page loads empty on a DB error |
| `Browse/ArtistsView.swift:296` | `async let artistFetch = try? await ArtistRepository(database: self.library.database).fe...` | b | artist page loads empty on a DB error |
| `Browse/ArtistsView.swift:297` | `async let trackCountsFetch = try? await AlbumRepository(database: self.library.database...` | b | artist page loads empty on a DB error |
| `Browse/ComposersView.swift:74` | `async let composersFetch = try? trackRepo.allComposers()` | b | browse page loads empty on a DB error |
| `Browse/ComposersView.swift:75` | `async let countsFetch = try? trackRepo.composerTrackCounts()` | b | browse page loads empty on a DB error |
| `Browse/ComposersView.swift:76` | `async let cardsFetch = try? albumRepo.fetchComposerCards()` | b | browse page loads empty on a DB error |
| `Browse/GenresView.swift:74` | `async let genresFetch = try? trackRepo.allGenres()` | b | browse page loads empty on a DB error |
| `Browse/GenresView.swift:75` | `async let countsFetch = try? trackRepo.genreTrackCounts()` | b | browse page loads empty on a DB error |
| `Browse/GenresView.swift:76` | `async let cardsFetch = try? albumRepo.fetchGenreCards()` | b | browse page loads empty on a DB error |
| `Browse/Podcasts/EpisodeList.swift:102` | `return await (try? actions.chapters(podcastID: item.episode.podcastID, guid: item.episo...` | b | chapters fetch failure shows an empty list |
| `Browse/Podcasts/PodcastsViewModel.swift:220` | `self.podcastEpisodeCounts = await (try? library.episodeCounts()) ?? [:]` | b | counts read failure leaves zero counts |
| `Browse/Podcasts/PodcastsViewModel.swift:221` | `self.podcastUnplayedCounts = await (try? library.unplayedCounts()) ?? [:]` | b | counts read failure leaves zero counts |
| `Browse/Podcasts/PodcastsViewModel.swift:279` | `try? await actions?.refresh(podcastID: id)` | b | background refresh failure per podcast is invisible |
| `Browse/Podcasts/PodcastsViewModel.swift:280` | `try? await Task.sleep(nanoseconds: 500_000_000)` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `Browse/Podcasts/PodcastsViewModel.swift:294` | `self.podcastEpisodeCounts = await (try? library.episodeCounts()) ?? [:]` | b | counts read failure leaves zero counts |
| `Browse/Podcasts/PodcastsViewModel.swift:460` | `self.episodes = await (try? library.episodes(podcastID: podcastID, order: order)) ?? se...` | b | episode list keeps stale rows on a DB error |
| `Browse/Podcasts/TranscriptParser.swift:124` | `let decoded = try? JSONDecoder().decode(JSONTranscriptDocument.self, from: data),` | a | tolerant parse by contract: falls back to plain text |
| `Browse/Subsonic/SubsonicAlbumsViewModel.swift:94` | `guard let cached = try? JSONDecoder().decode([AlbumID3].self, from: data) else { return }` | a | browse cache: a bad entry falls through to the network load |
| `Browse/Subsonic/SubsonicAlbumsViewModel.swift:100` | `guard let payload = try? JSONEncoder().encode(batch) else { return }` | a | browse cache: a bad entry falls through to the network load |
| `Browse/Subsonic/SubsonicArtistsViewModel.swift:70` | `guard let cached = try? JSONDecoder().decode([ArtistIndex].self, from: data) else { ret...` | a | browse cache: a bad entry falls through to the network load |
| `Browse/Subsonic/SubsonicArtistsViewModel.swift:76` | `guard let payload = try? JSONEncoder().encode(sections) else { return }` | a | browse cache: a bad entry falls through to the network load |
| `Browse/Subsonic/SubsonicGenresViewModel.swift:109` | `guard let cached = try? JSONDecoder().decode([Genre].self, from: data) else { return }` | a | browse cache: a bad entry falls through to the network load |
| `Browse/Subsonic/SubsonicGenresViewModel.swift:115` | `guard let payload = try? JSONEncoder().encode(genres) else { return }` | a | browse cache: a bad entry falls through to the network load |
| `Browse/Subsonic/SubsonicMultiSourceSearchViewModel.swift:212` | `try? await Task.sleep(for: timeout)` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `Browse/Subsonic/SubsonicSongDrag.swift:48` | `guard !payloads.isEmpty, let data = try? JSONEncoder().encode(payloads) else { return n...` | a | pasteboard round trip of Codable structs; foreign data yields nothing |
| `Browse/Subsonic/SubsonicSongDrag.swift:65` | `let decoded = try? JSONDecoder().decode([SubsonicSongDragPayload].self, from: data) els...` | a | pasteboard round trip of Codable structs; foreign data yields nothing |
| `Browse/Subsonic/SubsonicSongTableCells.swift:62` | `guard let url = try? await provider.coverArtURL(` | a | per-cell art; placeholder shown, a log per cell would flood |
| `Browse/Subsonic/SubsonicSongTableCells.swift:152` | `guard let (data, _) = try? await URLSession.shared.data(from: url),` | a | per-cell art; placeholder shown, a log per cell would flood |
| `Browse/Subsonic/SubsonicSongTableCoordinator.swift:325` | `try? await Task.sleep(for: .seconds(1))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `Browse/Subsonic/SubsonicSongsViewModel.swift:124` | `guard let cached = try? JSONDecoder().decode([Song].self, from: data) else { return }` | a | browse cache: a bad entry falls through to the network load |
| `Browse/Subsonic/SubsonicSongsViewModel.swift:130` | `guard let payload = try? JSONEncoder().encode(songs) else { return }` | a | browse cache: a bad entry falls through to the network load |
| `Browse/TracksView+Actions.swift:46` | `Task { try? await lib.playlistService.addTracks(ids, to: playlistID) }` | c | user action (Add to Playlist) silently fails |
| `Common/NoticesHTMLView.swift:23` | `let raw = try? String(contentsOf: url, encoding: .utf8) else { return }` | b | bundled resource unreadable is a packaging bug; log it |
| `Console/LogConsoleView.swift:274` | `try? text.write(to: url, atomically: true, encoding: .utf8)` | c | user action (Save Log); a failed write must surface |
| `Console/ViewModels/LogConsoleViewModel.swift:175` | `try? await Task.sleep(for: .milliseconds(100))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `DSP/DSPViewModel.swift:322` | `let resolved = try? await repo.resolvePresetID(trackID: trackID, albumID: albumID)` | b | DB read; a failure silently means 'no scoped EQ preset' |
| `DeepDive/ArtistInfoSheet.swift:126` | `self.artist = try? await self.library.artistRepo.fetch(id: self.artistID)` | b | sheet shows nothing on a DB error |
| `DeepDive/ArtistInfoSheet.swift:127` | `self.albumCount = await (try? self.library.artistRepo.fetchAlbumCounts()[self.artistID]...` | b | sheet shows nothing on a DB error |
| `DeepDive/ArtistInfoSheet.swift:128` | `self.trackCount = await (try? self.library.artistRepo.fetchTrackCounts()[self.artistID]...` | b | sheet shows nothing on a DB error |
| `DockTile/DockTileController.swift:67` | `try? await Task.sleep(nanoseconds: 1_000_000_000)` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `DockTile/DockTileController.swift:91` | `try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 s` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `Fingerprint/ViewModels/IdentifyTrackViewModel.swift:408` | `snapshot.artist = try? await artistRepo.fetch(id: artistID).name` | b | name lookup for the identify snapshot; nil on DB error |
| `Fingerprint/ViewModels/IdentifyTrackViewModel.swift:411` | `snapshot.albumArtist = try? await artistRepo.fetch(id: albumArtistID).name` | b | name lookup for the identify snapshot; nil on DB error |
| `Fingerprint/ViewModels/IdentifyTrackViewModel.swift:415` | `snapshot.album = try? await albumRepo.fetch(id: albumID).title` | b | name lookup for the identify snapshot; nil on DB error |
| `Lyrics/LyricsViewModel.swift:266` | `if let resolved = try? await self.service.lyricsWithSource(for: trackID),` | b | editor opens without stored lyrics on a DB error |
| `Lyrics/LyricsViewModel.swift:332` | `let stored = await (try? self.service.userOffsetMS(for: trackID)) ?? 0` | b | stored offset read failure resets the slider to 0 |
| `Lyrics/LyricsViewModel.swift:344` | `try? await Task.sleep(for: .milliseconds(600))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `MetadataEditor/ArtworkEditor.swift:99` | `if let data = try? Data(contentsOf: scopedURL) {` | c | user picked or dropped an art file; an unreadable file must say so |
| `MetadataEditor/ArtworkEditor.swift:126` | `guard let url, let data = try? Data(contentsOf: url) else { return }` | c | user picked or dropped an art file; an unreadable file must say so |
| `MetadataEditor/ViewModels/CoverArtFetchViewModel.swift:65` | `let data = try? await self.fetcher.image(` | b | thumbnail fetch; a debug log per failed candidate |
| `MetadataEditor/ViewModels/TagEditorViewModel.swift:180` | `if let tags = try? await self.service.readTags(trackID: id) {` | b | tag read failure drops the track from the editor silently |
| `MetadataEditor/ViewModels/TagEditorViewModel.swift:194` | `let tracks = await (try? self.service.readTracks(ids: self.trackIDs)) ?? []` | b | tag read failure drops the track from the editor silently |
| `Playlists/PlaylistFolderRow.swift:69` | `try? await Task.sleep(nanoseconds: 700_000_000)` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `Playlists/Smart/SmartPresetPickerView.swift:61` | `if let sp = try? await self.service.resolve(id: playlist.id ?? -1) {` | b | preset resolve failure hides the preset |
| `Playlists/ViewModels/PlaylistDetailViewModel.swift:85` | `try? await Task.sleep(nanoseconds: 500_000_000)` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `Playlists/ViewModels/PlaylistDetailViewModel.swift:87` | `let paths = await (try? Self.fetchCoverPaths(trackIDs: trackIDs, database: db)) ?? []` | b | mosaic cover paths; DB error leaves no mosaic |
| `Scrobble/ScrobbleSettingsViewModel.swift:150` | `try? await self.credentials.clearLastFmSession()` | c | user action (Disconnect); a Keychain failure must surface |
| `Scrobble/ScrobbleSettingsViewModel.swift:173` | `try? await self.credentials.clearListenBrainz()` | c | user action (Disconnect); a Keychain failure must surface |
| `Scrobble/ScrobbleSettingsViewModel.swift:191` | `try? await self.credentials.clearRocksky()` | c | user action (Disconnect); a Keychain failure must surface |
| `Scrobble/ScrobbleSettingsViewModel.swift:209` | `try? await repo.purgeDead()` | b | user action (purge dead letters) with no feedback on failure |
| `Settings/DiagnosticsExporter.swift:33` | `defer { try? fm.removeItem(at: staging) }` | a | remove-if-present of a cache, temp or sentinel file |
| `Settings/DiagnosticsSettingsView.swift:65` | `try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)` | a | directory pre-creation; the consumer's write reports the failure |
| `Settings/DiagnosticsSettingsView.swift:189` | `self.expandedContent = (try? String(contentsOf: url, encoding: .utf8))` | a | fallback text '(unreadable)' is shown to the user |
| `Settings/GeneralSettingsView.swift:65` | `_ = try? await UNUserNotificationCenter.current()` | b | denied and errored are indistinguishable; log the error |
| `Settings/SubsonicSettingsViewModel.swift:214` | `_ = try? await self.service.ping(serverID: server.id)` | a | result intentionally discarded; the monitor's wakeAll reports status |
| `Tools/BatchCoverArtViewModel.swift:125` | `let artist = try? await self.artistRepo.fetch(id: artistID) {` | b | artist name lookup; DB error searches with an empty artist |
| `ViewModels/AlbumsViewModel.swift:71` | `let artistNames = await (try? artistNamesTask) ?? [:]` | b | albums grid loses names or counts on a DB error |
| `ViewModels/AlbumsViewModel.swift:72` | `let trackCounts = await (try? trackCountsTask) ?? [:]` | b | albums grid loses names or counts on a DB error |
| `ViewModels/AlbumsViewModel.swift:92` | `let artistNames = await (try? artistNamesTask) ?? [:]` | b | albums grid loses names or counts on a DB error |
| `ViewModels/AlbumsViewModel.swift:93` | `let trackCounts = await (try? trackCountsTask) ?? [:]` | b | albums grid loses names or counts on a DB error |
| `ViewModels/AlbumsViewModel.swift:122` | `let artistNames = await (try? artistNamesTask) ?? [:]` | b | albums grid loses names or counts on a DB error |
| `ViewModels/AlbumsViewModel.swift:123` | `let trackCounts = await (try? trackCountsTask) ?? [:]` | b | albums grid loses names or counts on a DB error |
| `ViewModels/ArtistsViewModel.swift:94` | `self.albumCounts = await (try? albumCountsFetch) ?? [:]` | b | artists grid loses counts, art or scope on a DB error |
| `ViewModels/ArtistsViewModel.swift:95` | `self.trackCounts = await (try? trackCountsFetch) ?? [:]` | b | artists grid loses counts, art or scope on a DB error |
| `ViewModels/ArtistsViewModel.swift:96` | `self.coverArtPaths = await (try? coverPathsFetch) ?? [:]` | b | artists grid loses counts, art or scope on a DB error |
| `ViewModels/ArtistsViewModel.swift:97` | `self.albumArtistIDs = await (try? albumArtistIDsFetch) ?? []` | b | artists grid loses counts, art or scope on a DB error |
| `ViewModels/LibraryViewModel+Navigation.swift:236` | `let result = await (try? fetch(trackRepo)) ?? []` | b | smart folder shows empty on a DB error |
| `ViewModels/LibraryViewModel+Rating.swift:44` | `guard var track = try? await repo.fetch(id: trackID) else { return }` | c | user action (Love) silently does nothing on a DB error |
| `ViewModels/LibraryViewModel+Scanning.swift:18` | `self.libraryRoots = await (try? scanner.roots()) ?? []` | b | sidebar shows no roots on a DB error |
| `ViewModels/LibraryViewModel+Scanning.swift:153` | `try? await Task.sleep(for: .milliseconds(500))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `ViewModels/LibraryViewModel+Scanning.swift:184` | `try? await Task.sleep(for: .milliseconds(250))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `ViewModels/LibraryViewModel+Scanning.swift:284` | `let trackCount = await (try? TrackRepository(database: self.database).count()) ?? 0` | b | count failure flips the initial-scan overlay heuristic |
| `ViewModels/LibraryViewModel.swift:243` | `try? await Task.sleep(for: .seconds(2))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `ViewModels/LibraryViewModel.swift:501` | `self.metadataEditService = try? MetadataEditService(database: database)` | c | the whole tag editor is silently unavailable if this init throws |
| `ViewModels/LibraryViewModel.swift:556` | `try? await BuiltInSmartPresets.seed(using: sps)` | b | built-in presets never appear, no log |
| `ViewModels/LibraryViewModel.swift:1313` | `if let tracks = try? await repo.fetchAll(albumID: id) {` | b | tracks silently missing from a play or refresh |
| `ViewModels/LibraryViewModel.swift:1551` | `if let track = try? await repo.fetch(id: id) {` | b | tracks silently missing from a play or refresh |
| `ViewModels/NowPlayingViewModel.swift:375` | `try? await Task.sleep(nanoseconds: 1_000_000_000)` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `ViewModels/NowPlayingViewModel.swift:674` | `try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 s` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `ViewModels/NowPlayingViewModel.swift:688` | `let episode = try? await repo.fetchByGUID(podcastID: podcastID, guid: guid)` | b | now-playing episode or podcast detail missing on a DB error |
| `ViewModels/NowPlayingViewModel.swift:695` | `try? await Task.sleep(for: .seconds(3))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `ViewModels/NowPlayingViewModel.swift:709` | `let podcast = try? await repo.fetchByFeedURL(feedURL.absoluteString)` | b | now-playing episode or podcast detail missing on a DB error |
| `ViewModels/NowPlayingViewModel.swift:833` | `if (try? FileManager.default.copyItem(at: sourceURL, to: tempURL)) != nil,` | a | cosmetic: the notification posts without artwork |
| `ViewModels/NowPlayingViewModel.swift:834` | `let attachment = try? UNNotificationAttachment(identifier: "artwork", url: tempURL) {` | a | cosmetic: the notification posts without artwork |
| `ViewModels/TracksViewModel.swift:338` | `let artists = await (try? self.artistRepository.fetchAll()) ?? []` | b | name lookups; a DB error blanks artist and album columns |
| `ViewModels/TracksViewModel.swift:339` | `let albums = await (try? self.albumRepository.fetchAll()) ?? []` | b | name lookups; a DB error blanks artist and album columns |
| `Visualizers/FullscreenWindow.swift:66` | `try? await Task.sleep(for: .milliseconds(50))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `Visualizers/FullscreenWindow.swift:145` | `try? await Task.sleep(for: .seconds(2))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `Visualizers/NowPlayingOverlay.swift:77` | `try? await Task.sleep(for: .seconds(self.fadeAfter))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `Visualizers/ViewModels/VisualizerViewModel.swift:96` | `try? await Task.sleep(for: .milliseconds(500))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `Visualizers/ViewModels/VisualizerViewModel.swift:163` | `try? await Task.sleep(nanoseconds: 150_000_000) // 150 ms` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `Visualizers/ViewModels/VisualizerViewModel.swift:232` | `try? await Task.sleep(for: self?.toastDismissalDuration ?? .seconds(6))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `Visualizers/VisualizerControlOverlay.swift:171` | `try? await Task.sleep(for: .seconds(self.fadeAfter))` | a | sleep: cancellation is the only error; the caller checks isCancelled |

### Library

| Site | Code | Class | Why |
|---|---|---|---|
| `ArtistEnrichmentService.swift:54` | `try? await Task.sleep(for: delay)` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `ContentHashService.swift:66` | `try? await Task.sleep(for: self.debounce)` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `ContentHashService.swift:155` | `defer { try? handle.close() }` | a | closing a read handle; nothing to do on failure |
| `CoverArt/CoverArtArchiveClient.swift:132` | `if let numeric = try? c.decode(Int64.self, forKey: .id) {` | a | lenient decode by contract (numeric or string id, optional sizes) |
| `CoverArt/CoverArtArchiveClient.swift:135` | `self.id = try? c.decode(String.self, forKey: .id)` | a | lenient decode by contract (numeric or string id, optional sizes) |
| `CoverArt/CoverArtArchiveClient.swift:167` | `self.small = try? c.decode(URL.self, forKey: .small)` | a | lenient decode by contract (numeric or string id, optional sizes) |
| `CoverArt/CoverArtArchiveClient.swift:168` | `self.large = try? c.decode(URL.self, forKey: .large)` | a | lenient decode by contract (numeric or string id, optional sizes) |
| `CoverArt/CoverArtArchiveClient.swift:169` | `self.px500 = try? c.decode(URL.self, forKey: .five)` | a | lenient decode by contract (numeric or string id, optional sizes) |
| `CoverArt/CoverArtArchiveClient.swift:170` | `self.px250 = try? c.decode(URL.self, forKey: .two50)` | a | lenient decode by contract (numeric or string id, optional sizes) |
| `CoverArt/CoverArtSearchService.swift:64` | `if let index = try? await self.caaClient.index(releaseGroupID: group.id) {` | b | index fetch failure per release group; a debug log |
| `CoverArt/CoverArtSearchService.swift:120` | `try? FileManager.default.createDirectory(at: self.cacheDir, withIntermediateDirectories...` | a | directory pre-creation; the consumer's write reports the failure |
| `CoverArt/CoverArtSearchService.swift:125` | `return try? Data(contentsOf: url)` | a | cache miss semantics |
| `CoverArt/CoverArtSearchService.swift:130` | `try? data.write(to: url, options: .atomic)` | b | cache write failure means every search re-downloads |
| `CoverArt/SidecarArt.swift:33` | `guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) ...` | a | no sidecar art on an unreadable folder |
| `CoverArtCache.swift:116` | `try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)` | a | LRU touch on a cache file |
| `CoverArtCache.swift:173` | `guard let values = try? url.resourceValues(forKeys: keys),` | a | file attribute read with a fallback value |
| `CoverArtCache.swift:209` | `try? await self.repo.delete(hash: hash)` | b | sweep leaves a dangling DB row |
| `DeepDive/DeepDiveCache.swift:28` | `guard let data = try? Data(contentsOf: url),` | a | cache miss semantics |
| `DeepDive/DeepDiveCache.swift:29` | `let value = try? JSONDecoder().decode(T.self, from: data) else { return nil }` | a | cache miss semantics |
| `DeepDive/DeepDiveCache.swift:30` | `let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificati...` | a | cache miss semantics |
| `DeepDive/DeepDiveCache.swift:45` | `try? FileManager.default.removeItem(at: self.fileURL(key))` | a | remove-if-present of a cache, temp or sentinel file |
| `DeepDive/DeepDiveService.swift:100` | `if let summary = try? await self.wikipedia.summary(wikidataID: wikidataID) {` | b | bio lookup failure; a debug log (comment says it must not sink the report) |
| `DeepDive/DeepDiveService.swift:192` | `artist = try? await self.artists.fetch(id: artistID)` | b | report built without the artist row on a DB error |
| `DeepDive/DeepDiveService.swift:245` | `guard let owned = try? await self.ownedReleaseKeys(artistID: artist.id ?? 0),` | b | nearby releases empty on any failure, no reason |
| `DeepDive/DeepDiveService.swift:246` | `let groups = try? await self` | b | nearby releases empty on any failure, no reason |
| `DeepDive/DeepDiveService.swift:286` | `if let work = try? await self.mapErrors({ try await self.musicBrainz.fetchWork(mbid: re...` | b | work lookup failure; a debug log |
| `DeepDive/DeepDiveService.swift:380` | `let artist = try? await self.artists.fetch(id: artistID) else { return nil }` | b | report built without the artist row on a DB error |
| `Edit/BackupRing.swift:94` | `try? FileManager.default.removeItem(at: entryURL)` | a | remove-if-present of a cache, temp or sentinel file |
| `Edit/BackupRing.swift:107` | `guard let items = try? FileManager.default.contentsOfDirectory(` | b | unreadable ring directory reads as an empty ring |
| `Edit/BackupRing.swift:113` | `let ld = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distan...` | a | file attribute read with a fallback value |
| `Edit/BackupRing.swift:114` | `let rd = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distan...` | a | file attribute read with a fallback value |
| `Edit/EditTransaction.swift:189` | `guard let persisted = try? await self.coverArtCache.persist(extracted, source: "user") ...` | c | the user's new cover art is silently not persisted to the cache or album |
| `Edit/EditTransaction.swift:199` | `guard let album = try? await self.albumRepo.fetch(id: albumID) else { continue }` | b | album art propagation skipped on a DB error |
| `Edit/EditTransaction.swift:200` | `let total = await (try? self.trackRepo.count(albumID: albumID)) ?? Int.max` | b | album art propagation skipped on a DB error |
| `Edit/EditTransaction.swift:245` | `if let resolved = try? URL(` | b | root scope not acquired; the raw read then fails with a less specific error |
| `Edit/EditTransaction.swift:324` | `if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {` | b | mtime not synced; the next scan raises a false conflict |
| `Edit/EditTransaction.swift:336` | `try? await self.albumRepo.fetch(id: id)` | b | fallback rows for the edit read as absent on a DB error ('ignore errors' by comment) |
| `Edit/EditTransaction.swift:342` | `try? await self.artistRepo.fetch(id: id)` | b | fallback rows for the edit read as absent on a DB error ('ignore errors' by comment) |
| `Edit/EditTransaction.swift:348` | `try? await self.artistRepo.fetch(id: id)` | b | fallback rows for the edit read as absent on a DB error ('ignore errors' by comment) |
| `Edit/EditTransaction.swift:528` | `let roots = await (try? self.rootRepo.fetchAll()) ?? []` | b | root scope not acquired; the raw read then fails with a less specific error |
| `Edit/EditTransaction.swift:535` | `guard let rootURL = try? URL(` | b | root scope not acquired; the raw read then fails with a less specific error |
| `Edit/MetadataEditService.swift:108` | `let track = try? await self.trackRepo.fetch(id: firstID),` | b | edit returns an empty editID; undo unavailable, no log |
| `Edit/MetadataEditService.swift:109` | `let entry = try? await self.backupRing.lastEntry(forFileURL: track.fileURL) {` | b | edit returns an empty editID; undo unavailable, no log |
| `Edit/MetadataEditService.swift:137` | `if let track = try? await self.trackRepo.fetchOne(fileURL: entry.fileURL) {` | b | revert leaves userEdited set on a DB error |
| `Edit/MetadataEditService.swift:152` | `if let track = try? await self.trackRepo.fetch(id: id) {` | b | tracks or lyrics silently missing from the editor |
| `Edit/MetadataEditService.swift:169` | `if let row = try? await lyricsRepo.fetch(trackID: id) {` | b | tracks or lyrics silently missing from the editor |
| `Edit/MetadataEditService.swift:232` | `let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {` | b | mtime not synced; the next scan raises a false conflict |
| `FileWalker.swift:125` | `let resourceValues = try? child.resourceValues(` | a | file attribute read with a fallback value |
| `Fingerprint/FingerprintService.swift:169` | `if let mbRecording = try? await self.mbClient.fetchRecording(mbid: recording.id) {` | b | enrichment lookup failure; a debug log |
| `LibraryLocation.swift:25` | `try? FileManager.default.createDirectory(` | a | directory pre-creation; the consumer's write reports the failure |
| `LibraryLocation.swift:70` | `try? FileManager.default.createDirectory(` | a | directory pre-creation; the consumer's write reports the failure |
| `LibraryScanner.swift:172` | `try? await self.rootRepo.markInaccessible(id: rootID, true)` | b | root stays 'accessible' on a write failure; the warning above it hides that |
| `LibraryScanner.swift:266` | `let allRoots = await (try? self.rootRepo.fetchAll()) ?? []` | b | watcher starts with no roots on a DB error, silently |
| `LibraryScanner.swift:307` | `let roots = await (try? self.rootRepo.fetchAll()) ?? []` | b | watcher starts with no roots on a DB error, silently |
| `LibraryScanner.swift:349` | `if let track = try? await trackRepo.fetchOne(fileURL: url.absoluteString),` | b | removed file not disabled; the info log after it claims success |
| `LibraryScanner.swift:353` | `try? await trackRepo.update(disabled)` | b | removed file not disabled; the info log after it claims success |
| `LibraryScanner.swift:361` | `try? await trackRepo.disableAll(underPath: url.absoluteString)` | b | removed file not disabled; the info log after it claims success |
| `LibraryScanner.swift:450` | `guard let track = try? await trackRepo.fetchOne(fileURL: url.absoluteString),` | a | conservative: an unreadable row or file is treated as changed |
| `LibraryScanner.swift:452` | `let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKe...` | a | file attribute read with a fallback value |
| `Lyrics/LRClibClient.swift:110` | `let results = (try? JSONDecoder().decode([LRClibSearchResult].self, from: data)) ?? []` | b | API shape drift reads as 'no results' (the CAA client had this bug for years) |
| `Lyrics/LRClibClient.swift:130` | `guard let result = try? JSONDecoder().decode(LRClibGetResult.self, from: data) else { r...` | b | API shape drift reads as 'no results' (the CAA client had this bug for years) |
| `Lyrics/LyricsService.swift:198` | `guard let track = try? await trackRepo.fetch(id: trackID) else { return nil }` | b | a DB error reads as 'no lyrics' or an empty artist name |
| `Lyrics/LyricsService.swift:203` | `let artist = try? await artistRepo.fetch(id: aid) {` | b | a DB error reads as 'no lyrics' or an empty artist name |
| `Lyrics/LyricsService.swift:208` | `let albumTitle: String? = if let aid = track.albumID, let album = try? await albumRepo....` | b | a DB error reads as 'no lyrics' or an empty artist name |
| `Lyrics/LyricsService.swift:253` | `guard let track = try? await trackRepo.fetch(id: trackID) else { return nil }` | b | a DB error reads as 'no lyrics' or an empty artist name |
| `Lyrics/LyricsService.swift:257` | `let artistName: String = if let aid = track.artistID, let artist = try? await artistRep...` | b | a DB error reads as 'no lyrics' or an empty artist name |
| `Lyrics/LyricsService.swift:262` | `let albumTitle: String? = if let aid = track.albumID, let album = try? await albumRepo....` | b | a DB error reads as 'no lyrics' or an empty artist name |
| `Lyrics/LyricsService.swift:379` | `guard let track = try? await trackRepo.fetch(id: trackID) else { return }` | b | a DB error reads as 'no lyrics' or an empty artist name |
| `Lyrics/LyricsService.swift:423` | `guard let track = try? await trackRepo.fetch(id: trackID) else { return nil }` | b | a DB error reads as 'no lyrics' or an empty artist name |
| `Lyrics/LyricsService.swift:450` | `let roots = await (try? self.rootRepo.fetchAll()) ?? []` | b | root scope not acquired; the raw read then fails with a less specific error |
| `Lyrics/LyricsService.swift:456` | `guard let rootURL = try? URL(` | b | root scope not acquired; the raw read then fails with a less specific error |
| `PlaylistIO/CueMarkerService.swift:34` | `let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []` | a | no cue files on an unreadable folder |
| `PlaylistIO/CueMarkerService.swift:95` | `guard let track = try? await self.trackRepo.fetchOne(fileURL: canonical),` | b | the debug log after it conflates a DB error with 'not indexed' |
| `PlaylistIO/CueMarkerService.swift:132` | `guard let track = try? await self.trackRepo.fetchOne(fileURL: canonical),` | b | clear skipped on a DB error, markers linger |
| `PlaylistIO/CueMarkerService.swift:134` | `let existing = try? await self.markerRepo.markers(forTrack: trackID),` | b | clear skipped on a DB error, markers linger |
| `PlaylistIO/CueMarkerService.swift:149` | `guard let data = try? Data(contentsOf: url),` | a | conservative: unreadable cue reports targets missing |
| `PlaylistIO/CueMarkerService.swift:150` | `let sheet = try? CUESheetReader.parse(data: data, sourceURL: url) else { return false }` | a | conservative: unreadable cue reports targets missing |
| `PlaylistIO/PlaylistExportService.swift:105` | `let artist = try? Self.lookup(table: "artists", id: track.artistID, column: "name", db:...` | b | exported playlist loses artist or album names silently |
| `PlaylistIO/PlaylistExportService.swift:106` | `let album = try? Self.lookup(table: "albums", id: track.albumID, column: "title", db: db)` | b | exported playlist loses artist or album names silently |
| `PlaylistIO/PlaylistImportService.swift:260` | `guard let roots = try? await libraryRoots.fetchAll() else { return unreadable }` | a | conservative: the unreadable list is returned unchanged |
| `PlaylistIO/RemotePlaylistResolver.swift:84` | `try? M3UReader.parse(data: data, sourceURL: nil)` | b | parse failure of a fetched playlist yields nil with no reason |
| `PlaylistIO/RemotePlaylistResolver.swift:87` | `try? PLSReader.parse(data: data, sourceURL: url)` | b | parse failure of a fetched playlist yields nil with no reason |
| `PlaylistIO/TrackResolver.swift:44` | `if let t = try? await self.trackRepo.fetchOne(fileURL: normalised), let id = t.id {` | b | a DB error reads as 'track not found' in the import report |
| `PlaylistIO/TrackResolver.swift:51` | `let t = try? await self.trackRepo.fetchOne(fileURL: altNorm),` | b | a DB error reads as 'track not found' in the import report |
| `PlaylistIO/TrackResolver.swift:61` | `let candidate = try? await self.trackRepo.findByFilename(filename),` | b | a DB error reads as 'track not found' in the import report |
| `PlaylistIO/TrackResolver.swift:69` | `if let candidate = try? await self.trackRepo.findByMetadata(` | b | a DB error reads as 'track not found' in the import report |
| `ScanCoordinator.swift:105` | `let allTracks = await (try? self.trackRepo.fetchAllIncludingDisabled()) ?? []` | c | scan seeds from an empty list on a DB error: pruning skipped, everything re-imported |
| `ScanCoordinator.swift:129` | `let iCloudDownload: Bool = await (try? self.settingsRepo.get(Bool.self, for: "library.i...` | b | setting read; DB error reads as 'off' |
| `ScanCoordinator.swift:205` | `guard let track = try? await trackRepo.fetchOne(fileURL: urlString) else { continue }` | b | removed track lookup skipped on a DB error |
| `ScanCoordinator.swift:209` | `try? await self.trackRepo.update(disabled)` | b | emits .removed and counts it even when the disable write failed |
| `ScanCoordinator.swift:220` | `_ = try? await self.albumRepo.pruneOrphans()` | b | best-effort prune; a failure should still be logged |
| `ScanCoordinator.swift:269` | `let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])` | a | file attribute read with a fallback value |
| `ScanCoordinator.swift:296` | `let existingTrack = try? await trackRepo.fetchOne(fileURL: url.absoluteString)` | c | a DB read error makes a user-edited track look new; conflict protection bypassed |
| `ScanCoordinator.swift:331` | `try? await self.trackRepo.update(updated)` | b | conflict row update dropped silently |
| `ScanCoordinator.swift:354` | `let bookmark = existingTrack?.fileBookmark ?? (try? url.bookmarkData(` | b | bookmark creation failure leaves the row without sandbox access |
| `SmartPlaylists/Criteria/SmartCriterion.swift:114` | `self.field = try? c.decode(String.self, forKey: .field)` | a | lenient decode by contract (unknown smart-criterion field) |
| `SmartPlaylists/Criteria/SmartCriterion.swift:117` | `guard let lenient = try? container.decode(LenientRule.self, forKey: ._0),` | a | lenient decode by contract (unknown smart-criterion field) |
| `SmartPlaylists/Execution/SmartPlaylistService.swift:368` | `let decoded = try? JSONDecoder().decode(LimitSort.self, from: lsData) {` | b | corrupt stored limit/sort JSON silently falls back to defaults |

### Playback

| Site | Code | Class | Why |
|---|---|---|---|
| `Gapless/CrossfadeScheduler.swift:104` | `try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `Gapless/CrossfadeScheduler.swift:136` | `try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `Gapless/GaplessScheduler.swift:129` | `try? await Task.sleep(nanoseconds: 500_000_000) // 500 ms` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `NowPlaying/NowPlayingCentre.swift:223` | `try? await Task.sleep(nanoseconds: 1_000_000_000)` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `Persistence/QueuePersistence.swift:210` | `try? await Task.sleep(for: debounce)` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `Persistence/QueuePersistence.swift:256` | `try? await self.repo.remove(key: Self.settingsKeyV2)` | b | legacy blob not removed; the migration log repeats every launch |
| `Persistence/QueuePersistence.swift:278` | `try? await self.repo.remove(key: Self.settingsKeyV1)` | b | legacy blob not removed; the migration log repeats every launch |
| `QueuePlayer.swift:771` | `let track = try? await trackRepo.fetch(id: item.trackID)` | b | now playing shows no track on a DB error |
| `QueuePlayer.swift:778` | `let fetched = await (try? self.markerRepo.markers(forTrack: item.trackID)) ?? []` | b | markers empty on a DB error |
| `QueuePlayer.swift:947` | `try? await Task.sleep(for: .seconds(5))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `QueuePlayer.swift:1139` | `try? await self.trackRepo.disable(id: item.trackID)` | b | 'best effort' disable with no log |
| `QueuePlayer.swift:1190` | `let album = try? await albumRepo.fetch(id: nextAlbumID) {` | b | gapless decision made without the album row |
| `QueuePlayer.swift:1308` | `try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `QueuePlayer.swift:1354` | `} else if let track = try? await trackRepo.fetch(id: item.trackID) {` | b | now playing shows no track on a DB error |
| `QueuePlayer.swift:1492` | `let roots = await (try? self.rootRepo.fetchAll()) ?? []` | b | no roots means no security scope; the file open then fails less specifically |
| `QueuePlayer.swift:1517` | `if let url = try? URL(` | b | bookmark resolution failure is the root cause of 'cannot play'; log it here |
| `QueuePlayer.swift:1562` | `let roots = await (try? self.rootRepo.fetchAll()) ?? []` | b | no roots means no security scope; the file open then fails less specifically |
| `QueuePlayer.swift:1578` | `guard let rootURL = try? URL(` | b | bookmark resolution failure is the root cause of 'cannot play'; log it here |
| `QueuePlayer.swift:1594` | `if let freshData = try? handle.url.bookmarkData(` | b | bookmark resolution failure is the root cause of 'cannot play'; log it here |
| `QueuePlayer.swift:1618` | `let artists = await (try? self.artistRepo.fetchAll()) ?? []` | b | queue built with unknown artists on a DB error |
| `QueuePlayer.swift:1642` | `try? await self.play()` | c | media-key and remote commands drop the error the in-app path surfaces |
| `QueuePlayer.swift:1651` | `try? await self?.next()` | c | media-key and remote commands drop the error the in-app path surfaces |
| `QueuePlayer.swift:1654` | `try? await self?.previous()` | c | media-key and remote commands drop the error the in-app path surfaces |
| `QueuePlayer.swift:1657` | `try? await self?.seek(to: time)` | c | media-key and remote commands drop the error the in-app path surfaces |
| `QueuePlayer.swift:1662` | `try? await self.seek(to: max(0, current - interval))` | c | media-key and remote commands drop the error the in-app path surfaces |
| `QueuePlayer.swift:1668` | `try? await self.seek(to: min(dur, current + interval))` | c | media-key and remote commands drop the error the in-app path surfaces |
| `QueuePlayer.swift:1680` | `try? await self.play()` | c | media-key and remote commands drop the error the in-app path surfaces |
| `SleepTimer.swift:171` | `try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 s tick` | a | sleep: cancellation is the only error; the caller checks isCancelled |

### App

| Site | Code | Class | Why |
|---|---|---|---|
| `App/BocanApp.swift:467` | `Task { try? await engine.play() }` | b | resume-on-wake play failure invisible |
| `App/BocanApp.swift:506` | `if await (try? settings.get(Bool.self, for: "backup.enabled")) ?? false {` | b | settings read; a DB error silently picks the default |
| `App/BocanApp.swift:513` | `if await (try? settings.get(Bool.self, for: "backup.local.enabled")) ?? true {` | b | settings read; a DB error silently picks the default |
| `App/BocanApp.swift:514` | `let keep = await (try? settings.get(Int.self, for: "backup.local.keepCount")) ?? 5` | b | settings read; a DB error silently picks the default |
| `App/BocanApp.swift:712` | `let cachesRoot = (try? FileManager.default.url(` | a | caches directory lookup with a fallback path |
| `App/BocanApp.swift:721` | `let subsonicStreamCache: SubsonicStreamCache? = try? SubsonicStreamCache(` | c | Subsonic streaming silently unavailable for the whole session |
| `App/BocanApp.swift:853` | `try? await subsonicService.reloadClients()` | b | Subsonic clients not built, no log: the 'no server with id' symptom |
| `App/BocanApp.swift:949` | `try? await subsonicStore.migrateOrphans()` | b | Subsonic clients not built, no log: the 'no server with id' symptom |
| `App/BocanApp.swift:950` | `try? await subsonicService.reloadClients()` | b | Subsonic clients not built, no log: the 'no server with id' symptom |
| `App/BocanApp.swift:955` | `let servers = await (try? subsonicStore.fetchAll()) ?? []` | b | no servers monitored on a DB error |
| `App/BocanApp.swift:965` | `_ = try? await subsonicService.loadCapabilities(serverID: server.id)` | b | capability probe failure per server invisible |
| `App/BocanApp.swift:970` | `try? await subsonicRepo.pruneStaleCache()` | b | prune failure invisible |
| `App/DebugAudioView.swift:36` | `Button("Play") { Task { try? await self.engine.play() } }` | a | debug or test tooling |
| `App/DebugAudioView.swift:46` | `Task { try? await self.engine.seek(to: self.positionSec) }` | a | debug or test tooling |
| `App/DebugAudioView.swift:64` | `try? await Task.sleep(nanoseconds: 250_000_000)` | a | debug or test tooling |
| `App/E2ESeeder.swift:38` | `try? fm.removeItem(at: stale)` | a | debug or test tooling |
| `App/LaunchSanity.swift:54` | `try? FileManager.default.createDirectory(` | a | directory pre-creation; the consumer's write reports the failure |
| `App/LaunchSanity.swift:81` | `try? FileManager.default.removeItem(at: Self.sentinelURL)` | a | remove-if-present of a cache, temp or sentinel file |
| `App/Lifecycle.swift:23` | `_ = try? await database.vacuum()` | a | documented best effort at quit, bounded by a 2 s wait |
| `App/PhoneSyncController.swift:79` | `let all = await (try? self.playlistRepository.fetchAll()) ?? []` | b | phone sync offers no playlists or devices on an error |
| `App/PhoneSyncController.swift:100` | `await (try? self.server.pairedDevices()) ?? []` | b | phone sync offers no playlists or devices on an error |
| `App/SingleInstance.swift:110` | `try? FileManager.default.createDirectory(` | a | directory pre-creation; the consumer's write reports the failure |
| `App/SubsonicStoreSidebarListing.swift:66` | `return (try? JSONDecoder().decode(SubsonicCapabilities.self, from: data))` | b | corrupt capability cache hides sidebar rows |
| `App/SubsonicStreamResolver.swift:52` | `guard let server = try? await store.fetch(id: serverID), server.precacheNext else { ret...` | b | precache silently skipped on a DB error |

### AudioEngine

| Site | Code | Class | Why |
|---|---|---|---|
| `AudioEngine+AntiPop.swift:30` | `try? await Task.sleep(nanoseconds: stepNanos)` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `AudioEngine+Crossfade.swift:38` | `try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `AudioEngine+Crossfade.swift:67` | `try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `AudioEngine+Reconnect.swift:134` | `try? await Task.sleep(for: .seconds(Self.reconnectStabilizeWindow))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `DSP/DSPChain.swift:228` | `try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `DSP/DSPChain.swift:254` | `try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `DSP/DSPChain.swift:298` | `try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `DSP/DSPState.swift:36` | `let state = try? JSONDecoder().decode(Self.self, from: data) else {` | b | corrupt saved EQ state silently resets the user's settings |
| `DSP/DSPState.swift:43` | `guard let data = try? JSONEncoder().encode(self) else { return }` | a | encoding a Codable value type cannot realistically fail |
| `Decoder/DecoderFactory.swift:53` | `if let ffmpeg = try? FFmpegDecoder(url: url) {` | b | the FFmpeg failure reason is dropped and the earlier error rethrown |
| `Decoder/DecoderFactory.swift:66` | `if let decoder = try? FFmpegDecoder(url: url) {` | b | the FFmpeg failure reason is dropped and the earlier error rethrown |
| `Decoder/FormatSniffer.swift:61` | `defer { try? handle.close() }` | a | closing a read handle; nothing to do on failure |
| `Streaming/SubsonicStreamCache.swift:117` | `try? FileManager.default.removeItem(at: fileURL)` | a | remove-if-present of a cache, temp or sentinel file |
| `Streaming/SubsonicStreamCache.swift:125` | `try? FileManager.default.removeItem(at: fileURL)` | a | remove-if-present of a cache, temp or sentinel file |
| `Streaming/SubsonicStreamCache.swift:198` | `try? FileManager.default.removeItem(at: entry.fileURL)` | a | remove-if-present of a cache, temp or sentinel file |
| `Streaming/SubsonicStreamCache.swift:225` | `defer { try? handle.close() }` | a | closing a read handle; nothing to do on failure |
| `Streaming/SubsonicStreamCache.swift:241` | `try? handle.close()` | a | closing a read handle; nothing to do on failure |
| `Streaming/SubsonicStreamCache.swift:274` | `try? FileManager.default.removeItem(at: newURL)` | a | remove-if-present of a cache, temp or sentinel file |
| `Streaming/SubsonicStreamCache.swift:292` | `guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }` | a | sniff returns nil; the caller keeps the extension it had |
| `Streaming/SubsonicStreamCache.swift:293` | `defer { try? handle.close() }` | a | closing a read handle; nothing to do on failure |
| `Streaming/SubsonicStreamCache.swift:294` | `guard let data = try? handle.read(upToCount: 64) else { return nil }` | a | sniff returns nil; the caller keeps the extension it had |
| `Streaming/SubsonicStreamCache.swift:353` | `try? FileManager.default.removeItem(at: entry.fileURL)` | a | remove-if-present of a cache, temp or sentinel file |
| `Streaming/SubsonicStreamCache.swift:375` | `try? FileManager.default.removeItem(at: entry.fileURL)` | a | remove-if-present of a cache, temp or sentinel file |

### Podcasts

| Site | Code | Class | Why |
|---|---|---|---|
| `Chapters/ChaptersFetcher.swift:73` | `guard let document = try? JSONDecoder().decode(ChaptersDocument.self, from: data),` | a | tolerant parse by contract (documented: unparseable yields empty) |
| `Downloads/AutoDownloadCoordinator.swift:69` | `let state = try? await self.stateRepo.fetch(podcastID: podcastID, guid: episode.guid)` | b | auto-download re-downloads on a DB error |
| `Downloads/DownloadStore.swift:129` | `guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }` | a | no hash on an unopenable file |
| `Downloads/DownloadStore.swift:130` | `defer { try? handle.close() }` | a | closing a read handle; nothing to do on failure |
| `Downloads/DownloadStore.swift:132` | `while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {` | c | a read error mid-file ends the loop and returns the hash of a partial file |
| `Downloads/DownloadStore.swift:160` | `guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),` | a | file attribute read with a fallback value |
| `Downloads/EpisodeDownloadManager.swift:104` | `let state = try? await stateRepo.fetch(podcastID: podcastID, guid: guid),` | b | download state read failure changes the enqueue decision |
| `Downloads/EpisodeDownloadManager.swift:112` | `guard let episode = try? await episodeRepo.fetchByGUID(podcastID: podcastID, guid: guid...` | b | the warning after it conflates a DB error with an unknown episode |
| `Downloads/EpisodeDownloadManager.swift:172` | `let rows = await (try? self.stateRepo.fetchByDownloadState([.downloaded])) ?? []` | b | storage and retention decisions made from an empty list on a DB error |
| `Downloads/EpisodeDownloadManager.swift:188` | `let rows = await (try? self.stateRepo.fetchByDownloadState(` | b | storage and retention decisions made from an empty list on a DB error |
| `Downloads/EpisodeDownloadManager.swift:204` | `let rows = await (try? self.stateRepo.fetchByDownloadState([.downloaded])) ?? []` | b | storage and retention decisions made from an empty list on a DB error |
| `Downloads/EpisodeDownloadManager.swift:229` | `let rows = await (try? self.stateRepo.fetchByDownloadState([.downloaded])) ?? []` | b | storage and retention decisions made from an empty list on a DB error |
| `Downloads/EpisodeDownloadManager.swift:368` | `if let state = try? await stateRepo.fetch(podcastID: podcastID, guid: guid),` | b | download state read failure changes the enqueue decision |
| `FeedParser.swift:34` | `if let stripped = Self.feedDataWithStrippedProlog(data), let retried = try? Feed(data: ...` | a | documented retry; the original error is what gets reported |
| `Mapping/ParsedFeed+Records.swift:20` | `let catJSON = try? JSONEncoder().encode(self.categories)` | a | encoding a Codable value type cannot realistically fail |
| `PodcastService.swift:130` | `let retention = await (try? self.podcastRepo.fetch(id: podcastID))?.retentionLimit` | b | retention not applied on a DB error |
| `PodcastService.swift:156` | `guard let episode = try? await episodeRepo.fetchByGUID(podcastID: podcastID, guid: guid...` | b | episode art skipped on a DB error |
| `PodcastService.swift:726` | `let feedURL = await (try? self.podcastRepo.fetch(id: podcastID)).flatMap { URL(string: ...` | a | fallback URL for an error message |

### SyncServer

| Site | Code | Class | Why |
|---|---|---|---|
| `Http/FileServing.swift:431` | `defer { try? handle.close() }` | a | closing a read handle; nothing to do on failure |
| `Http/ManifestRoutes.swift:18` | `let serverId = await (try? syncMeta.serverId()) ?? ""` | c | protocol answer (ping, advertisement) built with an empty server id on a DB error |
| `Http/ManifestRoutes.swift:19` | `let generation = await (try? syncMeta.generation()) ?? 0` | c | protocol answer (ping, advertisement) built with an empty server id on a DB error |
| `Manifest/LibraryChangeObserver.swift:56` | `try? await Task.sleep(for: debounce)` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `Manifest/ManifestBuilder.swift:174` | `let size = state.downloadBytes ?? Int64((try? fileURL.resourceValues(forKeys: [.fileSiz...` | a | file attribute read with a fallback value |
| `Manifest/ManifestBuilder.swift:203` | `guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }` | a | no hash on an unopenable file |
| `Manifest/ManifestBuilder.swift:204` | `defer { try? handle.close() }` | a | closing a read handle; nothing to do on failure |
| `Manifest/ManifestBuilder.swift:206` | `while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {` | c | a read error mid-file ends the loop and returns the hash of a partial file |
| `Pairing/PairingCoordinator.swift:223` | `try? await Task.sleep(for: .seconds(timeout))` | a | sleep: cancellation is the only error; the caller checks isCancelled |
| `SyncServer.swift:55` | `serverId: { await (try? meta.serverId()) ?? "" }` | c | protocol answer (ping, advertisement) built with an empty server id on a DB error |
| `Transport/HttpConnection.swift:141` | `try? await self.rawSend(response.serialized())` | b | send failure (client gone) deserves a debug log |

### Persistence

| Site | Code | Class | Why |
|---|---|---|---|
| `BocanSchema/main.swift:17` | `try? FileManager.default.removeItem(at: outputURL)` | a | debug or test tooling |
| `Backup/BackupService.swift:156` | `let ld = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distant...` | a | file attribute read with a fallback value |
| `Backup/BackupService.swift:157` | `let rd = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distant...` | a | file attribute read with a fallback value |
| `Database.swift:248` | `guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)...` | a | invalid user regex matches nothing, by contract |
| `Internal/BookmarkBlob.swift:75` | `_ = try? URL(` | a | staleness probe by contract |
| `Records/PodcastPerson.swift:42` | `return (try? JSONDecoder().decode([Self].self, from: data)) ?? []` | a | tolerant decode by contract (documented) |
| `Records/PodcastPerson.swift:48` | `list.isEmpty ? nil : try? JSONEncoder().encode(list)` | a | encoding a Codable value type cannot realistically fail |
| `Records/PodcastPodrollItem.swift:29` | `return (try? JSONDecoder().decode([Self].self, from: data)) ?? []` | a | tolerant decode by contract (documented) |
| `Records/PodcastPodrollItem.swift:35` | `list.isEmpty ? nil : try? JSONEncoder().encode(list)` | a | encoding a Codable value type cannot realistically fail |

### Scrobble

| Site | Code | Class | Why |
|---|---|---|---|
| `Network/ListenBrainzCompatibleTransport.swift:87` | `return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]` | b | 2xx with an unparseable body reads as an empty reply |
| `Providers/LastFmProvider.swift:81` | `let key = try? await self.credentials.lastFmSessionKey()` | b | a Keychain error reads as 'not signed in' |
| `Providers/ListenBrainzProvider.swift:55` | `let token = try? await self.credentials.listenBrainzToken()` | b | a Keychain error reads as 'not signed in' |
| `Providers/ListenBrainzProvider.swift:139` | `let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]` | b | 2xx with an unparseable body reads as an empty reply |
| `Providers/RockskyProvider.swift:53` | `let key = try? await self.credentials.rockskyApiKey()` | b | a Keychain error reads as 'not signed in' |
| `Queue/ScrobbleQueueWorker.swift:260` | `try? await Task.sleep(for: timeout)` | a | sleep: cancellation is the only error; the caller checks isCancelled |

### Subsonic

| Site | Code | Class | Why |
|---|---|---|---|
| `SubsonicAnnotations.swift:110` | `try? await Task.sleep(nanoseconds: UInt64(Self.retryDelay * 1_000_000_000))` | a | sleep: cancellation is the only error; the caller checks isCancelled |

