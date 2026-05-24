# Phase 19: Subsonic / Navidrome / OpenSubsonic Client

> Prerequisites: Phases 0–16 complete. `QueuePlayer` exposes the full `Transport`
> protocol. `AudioEngine` decodes local files. Settings UI exists with a `TabView`.
> The `LibraryViewModel` owns `SidebarDestination` selection.
>
> Read `docs/design-spec/_standards.md` first.

## Where this fits: and the user's brief, reviewed

The user asked for:

1. A full Subsonic / Navidrome client backed by
   [`SwiftSonic`](https://github.com/MathieuDubart/swiftsonic) (currently `0.8.2`).
2. Preferences to manage one or more servers.
3. A new sidebar section, **"Subsonic / Navidrome"**, placed **below "Library"
   and above "Recents"**, with one expandable row per connected server
   exposing `Songs`, `Albums`, `Artists`, `Genres`, the same shape as the
   current Library section.
4. Rename **"Library"** → **"Local Library"** and make the section collapsible.

This spec implements exactly that, with the following deliberate refinements:

- **Section name in the sidebar is "Sources"**, not "Subsonic / Navidrome".
  Rationale: Subsonic is just one source family. A future phase can add Plex,
  Jellyfin, network shares, or DLNA without renaming the section again. Each
  server row is labelled with its user-given name; a subtitle (or trailing icon)
  identifies its kind ("Navidrome", "Subsonic", "Airsonic", "Astiga", etc.) so
  the user's brief is honoured at the row level.
- **All sidebar sections become collapsible**, not just Library. Once one
  section folds, leaving the others rigid feels arbitrary; the user's
  collapse-state is persisted to `settings`.
- **Inside each server we expose more than just Songs/Albums/Artists/Genres**.
  Subsonic/OpenSubsonic gives us much more for free, and a music player that
  ignores it feels broken:
  - `Playlists` (server-side, mutable)
  - `Starred` (the server's "favourites")
  - `Random` (server-side random, actually useful when the catalogue is huge)
  - `Recently Added` (server-side `newest`)
  - `Most Played` (server-side `frequent`)
  - `Internet Radio` (only when the server advertises it)
  - `Podcasts` (only when the server has the podcast extension)
  - `Bookmarks` (resume-points, OpenSubsonic)
  Each of these is hidden unless the server's capability advertisement says it
  exists. Songs/Albums/Artists/Genres are always shown.
- **"Recents" stays local-only for now.** Mixing remote and local Recently
  Played requires a unified play-history that respects both sources, which is a
  bigger problem than this phase should solve. Phase 20 (a future phase) can
  unify recents. This phase only sources Recently Added from the server inside
  the per-server subtree.
- **Search becomes federated.** The existing global search keeps working over
  the local library; results pages additionally show a "From <Server Name>"
  card per connected server, populated by `search3`. The user can disable
  per-server inclusion in search.
- **Star / rating / scrobble are write-through.** Starring a Subsonic track in
  Bòcan stars it on the server. Rating updates `setRating`. Completed plays
  call `scrobble`. Local scrobbling (Phase 13) still runs in parallel, the
  user can choose which targets receive a given play.

If you disagree with any of these, the rest of the spec is structured so
individual refinements can be dropped without unravelling the rest.

## Goal

Allow Bòcan to talk to any Subsonic-API-compatible server (Subsonic, Airsonic,
Airsonic-Advanced, Navidrome, Astiga, Funkwhale's Subsonic shim, gonic,
LMS, …), browse the catalogue with the same UI affordances as the local
library, and play tracks (with gapless and ReplayGain still working) through
the existing `QueuePlayer` / `AudioEngine` pipeline.

## Non-goals

- Re-implementing the Subsonic API. SwiftSonic does that.
- Becoming a Subsonic *server*. Phase 18 covers the remote-control server;
  this phase is purely a client.
- Syncing the remote catalogue into the local SQLite catalogue. The two
  catalogues remain disjoint, local rows live in `tracks/albums/artists`,
  remote rows live in an in-memory cache plus a small `subsonic_cache` table
  for cover-art blobs and last-known metadata snapshots.
- Editing server-side tags or covers. Bòcan's tag editor remains local-only.
  (The Subsonic API exposes no general tag-write endpoint anyway.)
- Offline-first sync of full albums to disk. Cover-art and the *currently
  buffered* audio file are cached; full offline-album downloads are out of
  scope and tracked separately.
- iCloud / Dropbox / WebDAV. These are not Subsonic.

## Outcome shape

```
Modules/Subsonic/
├── Package.swift
├── Sources/Subsonic/
│   ├── SubsonicService.swift          # Actor, owns SwiftSonicClient per server, capability cache
│   ├── SubsonicServerStore.swift      # CRUD over SubsonicServer records + Keychain
│   ├── SubsonicCapabilities.swift     # Cached capability snapshot + freshness rules
│   ├── SubsonicConnectionMonitor.swift# Ping loop, status events, exponential back-off
│   ├── SubsonicTrackResolver.swift    # SongID → QueueItem.PlayableSource
│   ├── SubsonicStreamCache.swift      # Range-fetcher → on-disk temp file the engine can decode
│   ├── SubsonicCoverArtProvider.swift # Plugs into the existing artwork cache
│   ├── SubsonicScrobbler.swift        # Write-through scrobble target
│   ├── SubsonicAnnotations.swift      # star / unstar / setRating write-through
│   ├── Models/
│   │   ├── SubsonicServer.swift       # Persisted server record
│   │   ├── SubsonicAuthKind.swift     # .tokenSalt | .apiKey
│   │   ├── SubsonicConnectionStatus.swift
│   │   └── SubsonicError.swift        # Wraps + classifies SwiftSonicError
│   └── Errors.swift
└── Tests/SubsonicTests/
    ├── SubsonicServiceTests.swift
    ├── SubsonicServerStoreTests.swift
    ├── SubsonicConnectionMonitorTests.swift
    ├── SubsonicStreamCacheTests.swift
    └── SubsonicAnnotationsTests.swift

Modules/Persistence/Sources/Persistence/
├── Migrations/
│   └── M0xx_SubsonicServers.swift
└── Repositories/
    └── SubsonicServerRepository.swift

Modules/Playback/Sources/Playback/
├── QueueItem.swift                    # Adds .playableSource (local | subsonic)
└── PlayableSource.swift               # New protocol-ish enum

Modules/AudioEngine/Sources/AudioEngine/
└── RemoteTrackLoader.swift            # Bridges SubsonicStreamCache → engine input

Modules/UI/Sources/UI/
├── AppRoot/Sidebar.swift              # Renamed labels, collapsible sections, new "Sources" section
├── Sources/
│   ├── SubsonicSidebarSection.swift   # The expandable per-server tree
│   ├── SubsonicServerStatusDot.swift  # Connection-status indicator
│   ├── SubsonicBrowseRoot.swift       # Routes per-server destinations
│   ├── SubsonicSongsView.swift
│   ├── SubsonicAlbumsView.swift
│   ├── SubsonicArtistsView.swift
│   ├── SubsonicGenresView.swift
│   ├── SubsonicPlaylistsView.swift
│   ├── SubsonicStarredView.swift
│   ├── SubsonicRandomView.swift
│   ├── SubsonicRecentlyAddedView.swift
│   ├── SubsonicMostPlayedView.swift
│   ├── SubsonicInternetRadioView.swift
│   ├── SubsonicPodcastsView.swift
│   └── ViewModels/
│       ├── SubsonicSidebarViewModel.swift
│       └── Subsonic<…>ViewModel.swift  # One per destination view
└── Settings/
    └── SubsonicSettingsView.swift     # New Sources tab in Settings TabView
```

---

## User-visible surface

### Sidebar

```
▾ Local Library             ← renamed, collapsible
    Songs
    Albums
    Artists
    Genres
    Composers

▾ Sources                   ← new section, between Local Library and Recents
    ▾  ● Living-Room Navidrome
           Songs
           Albums
           Artists
           Genres
           Playlists
           Starred
           Random
           Recently Added
           Most Played
           Internet Radio        (only if capability advertised)
           Podcasts              (only if capability advertised)
           Bookmarks             (only if OpenSubsonic)
    ▸  ○ Office Airsonic
    ▸  ⚠ Server I Broke
    [+ Add Server…]

▾ Recents                   ← unchanged, collapsible
    Recently Added
    Recently Played
    Most Played

▾ Queue
    Up Next

▾ Playlists  …
```

- A small status dot precedes each server name:
  - **● green**: connected (last ping succeeded within the health-check window)
  - **○ grey**: offline / never connected
  - **⚠ amber**: last request failed (auth / 5xx / timeout); tooltip shows reason
  - **● spinner**: currently testing connection
- Disclosure state per server is persisted to `settings`
  (`ui.subsonic.server.<id>.expanded`).
- Right-click on a server row exposes: **Refresh**, **Test Connection**,
  **Edit…**, **Disable in Sidebar**, **Remove…**.
- Right-click on the "Sources" section header offers **Add Server…** and
  **Manage Sources… ** (opens Settings → Sources).

### Settings → Sources tab

A new `SubsonicSettingsView` lives in the Settings `TabView`, placed between
**Library** and **Playback** (it is closer to "where my music comes from" than
"how it plays").

Top half: a `List` of configured servers with reorder handles. Each row shows
name, URL, status dot, last-error tooltip, and a context menu (Edit/Test/
Remove). Bottom half: when a row is selected, an inline editor for that
server. Two empty-state buttons at the bottom: **+ Add Server** and
**Test All Connections**.

Server editor fields:

| Field                       | Type / values                                                |
|-----------------------------|--------------------------------------------------------------|
| Display name                | String (required, unique)                                    |
| Server URL                  | `URL` with scheme `http` or `https` (required)               |
| Authentication              | Token & password • API key (OpenSubsonic)                    |
| Username                    | String (token & password mode)                               |
| Password                    | Secure field; stored in Keychain (token & password mode)     |
| API key                     | Secure field; stored in Keychain (API-key mode)              |
| Allow self-signed TLS       | Bool, default off; warning when on                           |
| Max stream bitrate          | 96 / 128 / 192 / 256 / 320 / Original                        |
| Preferred stream format     | Original • mp3 • opus • aac • flac                           |
| Pre-cache next track        | Bool, default on                                             |
| Include in global search    | Bool, default on                                             |
| Show in sidebar             | Bool, default on                                             |
| Scrobble plays to server    | Bool, default on                                             |
| Sync star ⇄ favourite        | Bool, default on                                             |
| Sync rating                 | Bool, default on                                             |
| Connection-test result      | Read-only, capability summary after successful Test         |

A **Test Connection** button runs `SwiftSonicClient.ping()` followed by
`loadCapabilities()` and shows the server type, server version, and a list of
advertised extensions ("Subsonic 1.16.1, songLyrics, apiKeyAuthentication,
…").

The user can press **Reveal in Keychain** to confirm the credential is stored
there and not in plain text.

---

## Definitions & contracts

### Subsonic server record

```swift
public struct SubsonicServer: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var serverURL: URL
    public var authKind: SubsonicAuthKind
    public var username: String?              // .tokenSalt only
    public var keychainAccount: String        // opaque pointer to Keychain item
    public var allowSelfSignedTLS: Bool
    public var maxBitrate: SubsonicBitrate    // .original or kbps
    public var preferredFormat: SubsonicStreamFormat
    public var precacheNext: Bool
    public var includeInGlobalSearch: Bool
    public var showInSidebar: Bool
    public var scrobble: Bool
    public var syncStars: Bool
    public var syncRatings: Bool
    public var sortIndex: Int
    public var createdAt: Date
    public var lastConnectedAt: Date?
    public var cachedCapabilitiesJSON: Data?  // SubsonicCapabilities encoded
}

public enum SubsonicAuthKind: String, Sendable, Codable {
    case tokenSalt        // legacy Subsonic + Navidrome default
    case apiKey           // OpenSubsonic apiKeyAuthentication
}

public enum SubsonicBitrate: Sendable, Codable, Hashable {
    case original
    case kbps(Int)
}

public enum SubsonicStreamFormat: String, Sendable, Codable {
    case original, mp3, opus, aac, flac
}
```

### Sidebar destination cases (additions)

Extend `SidebarDestination`:

```swift
case subsonicRoot(UUID)            // server-level row, not selectable
case subsonicSongs(UUID)
case subsonicAlbums(UUID)
case subsonicArtists(UUID)
case subsonicGenres(UUID)
case subsonicPlaylists(UUID)
case subsonicPlaylist(UUID, String)    // serverID, playlistID
case subsonicStarred(UUID)
case subsonicRandom(UUID)
case subsonicRecentlyAdded(UUID)
case subsonicMostPlayed(UUID)
case subsonicInternetRadio(UUID)
case subsonicPodcasts(UUID)
case subsonicBookmarks(UUID)
case subsonicArtist(UUID, String)      // serverID, artistID
case subsonicAlbum(UUID, String)       // serverID, albumID
```

Bump `ui.state.v1` → `ui.state.v2` with a migration that defaults
new fields to empty / off.

### Queue item playable source

Refactor `QueueItem` to carry a `PlayableSource`:

```swift
public enum PlayableSource: Sendable, Codable, Hashable {
    case localBookmark(Data)
    case subsonic(serverID: UUID, songID: String)
}
```

Wherever code currently dereferences a track's local URL, route through a new
`PlayableResolver` actor that returns a local file URL the engine can decode:

- `.localBookmark` → resolve bookmark to URL (existing behaviour).
- `.subsonic(server, song)` → ask `SubsonicStreamCache` to produce a local
  cache file URL (see Streaming below).

Queue persistence (`PlaybackQueue` → `playback_queue` SQLite blob) must
encode/decode `PlayableSource`. Add migration `M0xx_QueueItemSource`.

### Streaming + caching

`SubsonicStreamCache` is an actor that, given `(serverID, songID, format,
bitrate)`, returns a `Future<URL>` for a fully-buffered or partially-buffered
local cache file. Implementation:

1. Resolve a stable cache key
   `<serverID>/<songID>?fmt=<…>&kbps=<…>`.
2. Cache directory:
   `~/Library/Caches/io.cloudcauldron.bocan/Subsonic/<serverID>/<key>.<ext>`.
3. If cached and complete → return URL.
4. Otherwise start a range-download via `URLSession.downloadTask` for
   `SwiftSonicClient.streamURL(...)`; emit `progress` updates to the
   `RemoteTrackLoader`.
5. As soon as the local file has 200 KB or `min(2.0s, fileSize)` of decodable
   data, return the URL; the AudioEngine opens the file and the downloader
   continues writing. This gives us seek + gapless because the engine is
   reading a real file by the time playback starts.
6. Maintain a per-server cache budget (default 1 GB, configurable). LRU
   eviction; tracks currently in the queue are pinned.
7. On `precacheNext = true`, the moment the engine starts a track, kick off
   the download for `queue.peekNext()`.
8. On a `403 / 410 / 401` mid-stream → cancel, invalidate, surface as an
   `engine.load.failed` so the missing-file skip logic from the previous
   playback fix takes over.

Rationale: this approach keeps **everything downstream of the cache identical
to a local file**, which means ReplayGain, gapless scheduling, the EQ chain,
visualizers, FFT analysis, and waveform scrubbing all work without rewriting
the engine for an `AVPlayer` code path.

### Capability detection

`SubsonicService.loadCapabilities(serverID:)` calls
`SwiftSonicClient.loadCapabilities()` once per app launch (or once per server
re-login), persists the snapshot to `SubsonicServer.cachedCapabilitiesJSON`,
and exposes:

```swift
public struct SubsonicCapabilities: Sendable, Codable, Hashable {
    public var serverType: String?           // "navidrome", "airsonic", …
    public var serverVersion: String?        // "0.50.2"
    public var apiVersion: String?           // "1.16.1"
    public var isOpenSubsonic: Bool
    public var supportsLyricsBySongId: Bool
    public var supportsApiKey: Bool
    public var supportsPodcasts: Bool
    public var supportsInternetRadio: Bool
    public var supportsBookmarks: Bool
    public var supportsJukebox: Bool
    public var supportsShares: Bool
    public var supportsRandomSongsByGenre: Bool
}
```

The sidebar uses these flags to decide which child rows to render under a
server. Capabilities older than 24 h are refreshed lazily on the next API
call.

### Connection status

```swift
public enum SubsonicConnectionStatus: Sendable, Equatable {
    case unknown
    case connecting
    case online(lastPing: Date)
    case authFailed(String)
    case unreachable(String)        // DNS / network / cert error
    case serverError(String)        // 5xx / API error
}
```

`SubsonicConnectionMonitor` runs one monitor per enabled server:

- Ping immediately on app start / server save.
- Ping every 60 s while online.
- On failure, switch to back-off (5 s → 10 s → 20 s → … capped at 5 min).
- On any 401, transition to `authFailed`, stop pinging, surface a re-auth
  banner in the per-server views. The user must edit the server to retry.
- Status changes broadcast via an `AsyncStream` to the
  `SubsonicSidebarViewModel`.

### Annotations

`SubsonicAnnotations` is the write-through bridge:

- `star(serverID:, songID:)` → `SwiftSonicClient.star(songId:)`
- `unstar(serverID:, songID:)` → `SwiftSonicClient.unstar(songId:)`
- `setRating(serverID:, songID:, rating:)` → `setRating(id:rating:)`
- Failures are logged as warnings and the action is queued for retry on the
  next successful ping. No user-facing error toast unless the same write has
  failed three times in a row (avoid spam when the server is briefly
  unreachable).

### Scrobble integration

When `SubsonicServer.scrobble == true` and the played track's source is
`.subsonic(server, …)`, the existing scrobble pipeline (Phase 13) calls
`SubsonicScrobbler.scrobble(serverID:, songID:, completed: Bool)` in addition
to Last.fm / ListenBrainz. The Subsonic scrobble is the authoritative
"played" event for the originating server; ListenBrainz still receives it for
unified history.

### Federated search

Extend `SearchResults` to include `Sources`:

```swift
public struct SearchResults: Sendable {
    public var local: LocalSearchSection
    public var remote: [UUID: SubsonicSearchSection]   // serverID → section
}
```

The search view renders the local section first, then one collapsible card
per `includeInGlobalSearch` server. Searches are debounced (250 ms) and
issued in parallel per server with a 1.5 s timeout, slow servers don't
delay local results.

### Keychain

Keychain items use service `io.cloudcauldron.bocan.subsonic` and account
`<serverID>`. Stored payload is:

```json
{ "v": 1, "kind": "tokenSalt", "secret": "<password>" }
{ "v": 1, "kind": "apiKey", "secret": "<api-key>" }
```

`SubsonicServerStore` is the only thing that reads/writes these items. The
`SubsonicServer` value type never carries the secret itself. Deleting a
server deletes the Keychain item.

### Self-signed TLS

When `allowSelfSignedTLS = true` for a server, that server's client uses a
custom `HTTPTransport` that injects a `URLSessionDelegate` allowing the
specific server URL's host to fail validation cleanly. **The exemption is
scoped to that one host**; we never set a global override. The Settings UI
shows an amber banner with the exact wording:

> Allowing self-signed certificates means Bòcan cannot verify that the
> server is who it claims to be. Use only on a network you control.

### Persistence schema

```sql
CREATE TABLE subsonic_servers (
    id                    TEXT PRIMARY KEY,         -- UUID
    name                  TEXT NOT NULL,
    server_url            TEXT NOT NULL,
    auth_kind             TEXT NOT NULL,            -- 'tokenSalt' | 'apiKey'
    username              TEXT,
    keychain_account      TEXT NOT NULL,
    allow_self_signed_tls INTEGER NOT NULL DEFAULT 0,
    max_bitrate           TEXT NOT NULL,            -- 'original' or '320'
    preferred_format      TEXT NOT NULL DEFAULT 'original',
    precache_next         INTEGER NOT NULL DEFAULT 1,
    include_in_search     INTEGER NOT NULL DEFAULT 1,
    show_in_sidebar       INTEGER NOT NULL DEFAULT 1,
    scrobble              INTEGER NOT NULL DEFAULT 1,
    sync_stars            INTEGER NOT NULL DEFAULT 1,
    sync_ratings          INTEGER NOT NULL DEFAULT 1,
    sort_index            INTEGER NOT NULL DEFAULT 0,
    created_at            REAL NOT NULL,
    last_connected_at     REAL,
    capabilities_json     BLOB
);

CREATE UNIQUE INDEX subsonic_servers_name_idx ON subsonic_servers(name);

CREATE TABLE subsonic_metadata_cache (
    server_id    TEXT NOT NULL,
    entity_kind  TEXT NOT NULL,    -- 'album' | 'artist' | 'song' | 'playlist'
    entity_id    TEXT NOT NULL,
    payload_json BLOB NOT NULL,
    fetched_at   REAL NOT NULL,
    PRIMARY KEY (server_id, entity_kind, entity_id)
);
```

`subsonic_metadata_cache` exists so a quick relaunch doesn't need to re-fetch
the catalogue before the sidebar renders. Entries older than 7 days are
discarded on launch.

---

## Implementation plan

Each numbered step is a single commit (Conventional Commits, `feat(subsonic):`
unless otherwise noted).

1. **Scaffold `Modules/Subsonic`** with `Package.swift` declaring SwiftSonic
   `from: "0.8.2"` as a dependency. Empty actor stubs for `SubsonicService`,
   `SubsonicServerStore`. Wire into the workspace dependency graph
   (`AudioEngine` is *not* a dependency of this module; the dependency goes
   the other way at step 6).
2. **Persistence migration** for `subsonic_servers` +
   `subsonic_metadata_cache`. New `SubsonicServerRepository` with CRUD +
   ordered-list fetch. Tests cover migration up/down and unique-name
   constraint.
3. **Keychain integration** in `SubsonicServerStore`: create, read, update,
   delete, plus a `migrateOrphans()` that removes Keychain items whose owning
   server row is gone.
4. **`SubsonicService` actor** that owns a `[UUID: SwiftSonicClient]` pool,
   reconstructs clients on credential change, and exposes typed wrappers for
   the endpoints we use (`ping`, `loadCapabilities`, `getArtists`,
   `getAlbumList2`, `getSongsByGenre`, `getRandomSongs`, `getStarred2`,
   `getPlaylists`, `getPlaylist`, `search3`, `getNowPlaying`,
   `getPodcasts`, `getInternetRadioStations`, `getBookmarks`, `star`,
   `unstar`, `setRating`, `scrobble`, `streamURL`, `coverArtURL`).
5. **`SubsonicConnectionMonitor`** with the ping / back-off behaviour above.
   Emits status via `AsyncStream<(UUID, SubsonicConnectionStatus)>`.
6. **`SubsonicStreamCache` + `RemoteTrackLoader`** in the existing
   `AudioEngine` module. Range-download → cache file → expose URL to the
   engine. Eviction policy. Unit-tested with a stubbed `HTTPTransport`.
7. **`PlayableSource` refactor**: `QueueItem` carries either `.localBookmark`
   or `.subsonic(serverID, songID)`. Update `PlaybackQueue` codable shape +
   migration. Update every callsite that resolves a track to a URL to go
   through a new `PlayableResolver`. Old queue blobs migrate by mapping
   plain-bookmark items to `.localBookmark`.
8. **`SubsonicCoverArtProvider`** that exposes
   `coverArtURL(serverID:entityID:size:)` for the existing artwork cache to
   consume. Mid-render fallback to a placeholder symbol if the server is
   offline.
9. **Sidebar wiring**: rename `"Library"` → `"Local Library"` everywhere
   user-visible, add `DisclosureGroup` semantics for every section, add
   `"Sources"` section with `SubsonicSidebarSection` between Local Library
   and Recents. Persist collapse-state and per-server disclosure state.
10. **Per-server destination views**: Songs, Albums, Artists, Genres first;
    reuse existing `TrackTable` / `AlbumGrid` / `ArtistList` components by
    extracting a `TrackListSource` protocol they can render. Lazy-load with
    paging (`offset/size` for `getAlbumList2`, `pageSize = 100`).
11. **Optional per-server destination views**: Playlists, Starred, Random,
    Recently Added, Most Played, Internet Radio, Podcasts, Bookmarks. Each
    view is only registered when the capability flag is set.
12. **Settings → Sources tab** with the editor described above. Include
    `Test Connection` button that pings + loads capabilities. Validate URLs.
    Show the capability list after a successful test.
13. **Federated search**: parallel per-server search, debounced, with a
    1.5 s soft timeout. New `SearchResultsCard` per server in the existing
    search results UI.
14. **Annotations write-through** (star / rating). Per-track UI uses the
    existing star button; when the track's source is `.subsonic`, the button
    calls `SubsonicAnnotations` and `SubsonicService`, then updates the local
    visual state optimistically. Failures rollback after 5 s if the retry
    queue also fails.
15. **Scrobble write-through** at end-of-track. Hook into the existing
    Phase 13 scrobble dispatch, not the engine.
16. **Capability-driven sidebar refresh**: when capabilities change (e.g. a
    server upgrade adds Podcasts), the sidebar dynamically grows new rows
    without a relaunch.
17. **Polish**: empty states for each per-server view, offline banners with
    "Retry now", error toasts only for user-initiated actions, VoiceOver
    labels for all status dots, keyboard navigation through the new sidebar
    section (`⌘⌥1`–`⌘⌥9` already taken; add `⌘⇧1`–`⌘⇧9` for source servers).
18. **Docs**: update `README.md`'s feature list and add a `docs/sources.md`
    user-facing guide explaining how to add a server.

---

## Context7 lookups

The implementing assistant should run these via Context7 before writing code:

- `MathieuDubart/swiftsonic`: verify the 0.8.x public API and pin a version.
- `apple/swift-async-algorithms`: `AsyncChannel` and `debounce` for the
  search and status streams.
- Apple's `URLSession` background download + range request docs.
- Apple's `Security` framework, adding a custom server-trust override
  scoped to a single host.

## Dependencies

Add to the root `Package.swift` / appropriate module manifests:

```swift
.package(url: "https://github.com/MathieuDubart/swiftsonic.git", from: "0.8.2")
```

Targets that need the product:

- `Subsonic` (consumes `SwiftSonic`).
- No other target should import `SwiftSonic` directly; everything goes through
  `Subsonic`.

No new Homebrew formulae. No new system libraries.

## Test plan

`Modules/Subsonic/Tests/SubsonicTests/`:

- **`SubsonicServerStoreTests`**
  - Create / update / delete persists and round-trips.
  - Unique-name constraint is enforced.
  - Deleting a server removes its Keychain item.
  - `migrateOrphans()` removes stale Keychain items without touching live ones.
- **`SubsonicServiceTests`** (uses a stubbed `HTTPTransport`)
  - `ping()` failure transitions status to `.unreachable`.
  - 401 transitions to `.authFailed` and stops the monitor.
  - Capability loading caches and replays without a second HTTP call.
  - `streamURL` includes salt+token when `authKind == .tokenSalt`.
- **`SubsonicConnectionMonitorTests`**
  - Back-off schedule respects 5 s → 10 s → 20 s → … cap 5 min.
  - Successful ping resets back-off.
- **`SubsonicStreamCacheTests`**
  - Cold fetch returns URL after threshold bytes are written.
  - Concurrent requests for the same key share one download.
  - LRU eviction respects the budget and skips queued tracks.
  - 401 mid-stream cancels and propagates as `engine.load.failed`.
- **`SubsonicAnnotationsTests`**
  - Star → unstar idempotency.
  - Retry queue eventually flushes once the monitor reports `.online`.
  - Three consecutive failures surface a UI error event.
- **`PlaybackQueue` migration test**: old persisted blobs without
  `PlayableSource` upgrade cleanly to `.localBookmark`.
- **UI snapshot / view tests** for the sidebar showing exactly the rows the
  capabilities flag allows (no Podcasts row when the cap is false).
- **End-to-end (manual)**: connect a real Navidrome 0.50+ instance; verify
  browse, play, seek, gapless, ReplayGain, star, rating, scrobble.

## Acceptance criteria

- [ ] Sidebar shows: `Local Library` (renamed) → `Sources` (new) → `Recents`
      → `Queue` → `Playlists`. All sections collapsible. Collapse state
      persisted across launches.
- [ ] At least two servers can be added concurrently and produce
      independent sidebar subtrees.
- [ ] Each server's subtree always shows `Songs`, `Albums`, `Artists`,
      `Genres`. Optional rows appear only when the server advertises the
      capability.
- [ ] Adding a server, entering an invalid URL or wrong password produces a
      clear in-form error and never throws an unhandled exception.
- [ ] Adding a server with `Test Connection` succeeding shows the resolved
      server type and version.
- [ ] Passwords / API keys are never written to disk in plain text and never
      logged. `grep -r '"password"' build/` yields no matches in logs.
- [ ] Selecting a Subsonic track and pressing play streams the track,
      starts within 2 s on a 10 Mbps connection, and plays gaplessly into
      the next item when both are Subsonic tracks on the same server.
- [ ] Seek works on a Subsonic track that has only been partially buffered.
- [ ] ReplayGain, EQ, crossfeed, visualizers, and FFT analyser all work on a
      Subsonic track exactly as they do on a local track.
- [ ] Starring a Subsonic track from any track-list view writes through to
      the server; toggling off un-stars on the server.
- [ ] Setting a rating writes through to the server.
- [ ] Completing a Subsonic track calls `scrobble(id: …, submission: true)`
      on the server in addition to Last.fm / ListenBrainz (when those are
      configured).
- [ ] Pulling the network cable mid-stream surfaces an in-row warning and
      the missing-file skip logic advances the queue.
- [ ] Search results include a "From <Server>" card per connected server
      with results within 1.5 s, or a "Server slow, still searching"
      indicator past that.
- [ ] A server with `Show in sidebar = off` does not appear in the sidebar
      but still participates in search / scrobble if those flags are on.
- [ ] Removing a server clears its Keychain item, its on-disk stream cache,
      and any cached metadata in `subsonic_metadata_cache`.
- [ ] All tests in `SubsonicTests` pass; coverage ≥ 80 % for the module.
- [ ] No SwiftLint / SwiftFormat warnings introduced.

## Gotchas (the things that will bite you)

- **Server URL trailing slash.** Some Subsonic forks 404 on `…/rest/ping`
  but accept `…//rest/ping` and vice versa. Normalise the URL on save by
  stripping trailing slashes; SwiftSonic builds endpoints itself.
- **Salt-token rotation.** Subsonic auth re-hashes the password with a fresh
  salt per request. Never log the rendered URL, it leaks the per-request
  token. Use `SwiftSonicClient`'s built-in logger (`logSubsystem:`), which
  redacts secrets, and never `print` `streamURL(…)`.
- **Capability lies.** Some servers (looking at you, ancient Subsonic
  builds) report capabilities they don't actually support. Always wrap
  capability-gated calls in `do { try await … } catch SwiftSonicError.api {
  capabilities.markUnsupported(...) }` and fall back gracefully.
- **Navidrome ID format.** Album/Artist IDs are 32-char hex strings;
  Subsonic-classic uses short numeric strings. Treat all IDs as opaque
  `String`s; never parse them.
- **Cover art ID ≠ album ID.** Always use the `coverArt` field from the
  album/song payload, not the album/song ID itself.
- **`getAlbumList2(type:"random")` is not idempotent**: calling it twice
  gives two different shuffles. Cache the result for the lifetime of the
  view so paging doesn't bring back the same album the user just scrolled
  past.
- **Cache file MIME ≠ extension.** If `preferredFormat = .original`, the
  server picks the format; rely on `Content-Type` or the file's container
  byte signature, not on `?format=`. Save with a `.bin` extension and have
  the engine probe the container.
- **Bookmark resolution path**: `PlayableResolver` must run all source
  resolution off the main thread; bookmark resolution does I/O.
- **Queue persistence shape change** breaks the user's restored queue if
  the migration is wrong. Add a "queue snapshot version" field and refuse
  to load a queue from a newer version with a clear toast rather than
  crashing.
- **Sleep / wake.** macOS sleep often kills in-flight downloads; the
  connection monitor must re-ping on `NSWorkspace.didWakeNotification`.
- **Network changes (`NWPathMonitor`).** When the user switches Wi-Fi, all
  open `URLSession` tasks for previously reachable hostnames may stall for
  60 s before failing. Force-cancel and restart in-flight stream downloads
  on path changes.
- **Multi-server playlists**. A manual Bòcan playlist (Phase 6) can mix
  local and remote tracks. The playlist UI must not assume `track.localURL`
  exists. Filtering "Play only the local items" should be a one-click
  action when at least one item is remote and offline.
- **Server time skew.** Don't trust the server's clock for "now playing"
  ordering. Use the client's monotonic clock for queue progression.
- **VoiceOver labels.** The status dot is purely visual; the row's
  accessibility label must encode the status ("Office Airsonic, offline,
  last error: authentication failed").

## Handoff

The next phase (Phase 20, future) is expected to:

- Unify Recents across local + Subsonic sources into a single play-history.
- Add offline-album download (full pinning, with track-completion progress).
- Add support for Plex / Jellyfin via the same `PlayableSource` plumbing.
- Add Jukebox-mode remote control (where Bòcan asks the server itself to
  play through *its* output), useful when Bòcan is running on a different
  Mac to the speakers.

When Phase 19 lands:

- `PlayableSource` is the source-of-truth for "where does a track come from".
- The sidebar is no longer hard-coded; sections drive themselves from a
  `SidebarViewModel` so future sources slot in without re-templating.
- The Settings → Sources tab is the home for any future remote source kind.
