# ADR-097: Jellyfin as a Source

> Depends on: ADR-035 (the Subsonic / Navidrome client that Jellyfin mirrors),
> ADR-029 (scrobbling), ADR-006 (queue and `PlayableSource`), ADR-037 (the last
> time a case was added to `PlayableSource`), ADR-085 (hermetic network for E2E).
> Binding docs: `_standards.md`; the root `CLAUDE.md`; `docs/GOTCHAS.md`
> (read "SwiftUI observation", the menu bar, the keychain and the SPM pins
> before the slices that touch them); `docs/localization.md`.
> Status: proposed on 2026-11-14, rewritten the same day. Nothing is built.
> ADR-035's "Handoff" (line 755) already names Jellyfin as a follow-up.

Everything under "Facts the plan rests on" was read from the repository on
`main` at `934b13a9`, or from the Jellyfin OpenAPI document through Context7 on
2026-11-14. What was not checked is listed under "Context7 lookups" and must be
checked before the slice that needs it.

## The brief

A Jellyfin server is added as a **source**, in the same place as a Navidrome
server, and it looks and works as close to the Subsonic source as Jellyfin
allows. That is all the two need to share.

The rule that follows from this is **mirror, do not merge**. Jellyfin is a
sibling of Subsonic. It has its own module, its own table, its own
`PlayableSource` case, its own views and its own settings editor, each shaped
like the Subsonic one. Subsonic code is not refactored, renamed, moved,
generalised or put behind a protocol. A copy of a Subsonic file that has been
adapted to Jellyfin is the intended result, not a defect.

## Goal

1. **Same place.** A Jellyfin server shows in the sidebar "Sources" section,
   under the Subsonic servers, with the same status dot, disclosure, context
   menu and keyboard shortcut. Servers are added and edited on Settings,
   Sources, which gets a kind switch (Subsonic / Navidrome, Jellyfin).
2. **Same look.** A Jellyfin server expands to the same rows with the same
   icons: Songs, Albums, Artists, Genres, Playlists, Starred, Random, Recently
   Added, Most Played. The views look and behave like the Subsonic views:
   grids, album and artist detail, song table, in-view search, offline banner.
3. **Same behaviour.** A Jellyfin track plays through `QueuePlayer`, the stream
   cache and `AudioEngine`, as a Subsonic track does. Star writes through,
   plays are reported, and the per-server options match.
4. **Subsonic is untouched in behaviour.** Subsonic tests and snapshots pass
   unchanged. See "Edits to existing files" for the only edits allowed.

## Non-goals

- **Refactoring Subsonic, or extracting a shared source layer.** Rejected by
  the maintainer. Do not propose it again in this work.
- **Jellyfin video, TV, books, live TV.** Music libraries only.
- **Editing the server.** No tag edits, playlist create, rename or delete, no
  library scan. Read, play, favourite and report plays only.
- **Star ratings.** Jellyfin has no five-star rating for music (D3).
- **Rows Jellyfin has no equivalent for:** Internet Radio, Podcasts, Bookmarks.
  They are not built for Jellyfin, so there is no capability gating to mirror.
- **A Jellyfin API key mode.** A key has no user, so every item query would
  need a user chosen by hand. Password and Quick Connect only (D2).
- **A per-server music library picker.** v1 shows all music libraries the
  user can see. A picker needs a column and waits for a later ADR.
- **ReplayGain, progress heartbeats, Instant Mix, Similar, lyrics, offline
  download, playlist editing.** See "Future work".
- **Changing the release pipeline** (ADR-033, owned by the maintainer).

## Facts the plan rests on

About this repository:

1. **`Subsonic` is a self-contained module** of about 2,100 lines
   (`Modules/Subsonic/Sources/Subsonic`): `SubsonicService` (actor over a pool
   of `SwiftSonicClient`), `SubsonicServerStore` (CRUD and Keychain),
   `SubsonicConnectionMonitor`, `SubsonicAnnotations`, `SubsonicCapabilities`,
   `SubsonicCoverArtProvider`, `SubsonicServer`, `SubsonicError`. It depends on
   `Observability` and `Persistence`.
2. **The sidebar and Settings already take Subsonic data through small UI
   protocols.** `SidebarSectionExpansion.swift` defines `SubsonicSidebarServer`,
   `SubsonicSidebarConnectionState`, `SubsonicConnectionObserving`,
   `SubsonicSidebarListing` and `SubsonicCapabilityChangeObserving`. The App
   implements them (`SubsonicStoreSidebarListing`,
   `SubsonicMonitorConnectionObserver`). A Jellyfin server can follow the same
   path with its own types.
3. **The Sources section is one view.** `SubsonicSidebarSection` renders the
   header, the "+" button, the Hidden Sources menu, the empty-state button and
   one disclosure per server. The sidebar "+" does one thing: it opens
   Settings on the Sources page (`Sidebar.openAddSource`). The server is then
   added there (`SubsonicSettingsViewModel.beginAddServer`).
4. **`LibraryViewModel` carries Subsonic state as separate properties** (about
   a dozen, lines 143 to 520 of `LibraryViewModel.swift`): the server lists,
   connection states, the data source, the cover provider, the metadata cache,
   the search view model, the annotation coordinator. It is an
   `ObservableObject` with `@Published` properties. The file is 1,811 lines.
5. **Only `Subsonic` owns SwiftSonic, but the UI also imports it.** 24 files
   outside `Subsonic` do, mostly under `UI/Browse/Subsonic/`. Their view
   models are typed on SwiftSonic's `Song`, `AlbumID3` and so on. Jellyfin
   gets its own small model types in its own module instead, so its views never
   see the Jellyfin SDK.
6. **Some pieces are neutral already, only the names say Subsonic.**
   `HTTPTransport`, `RemoteTrackLoader` and `URLSessionHTTPTransport` take a
   URL supplier and bytes. `SubsonicStreamCache` is keyed by
   `SubsonicStreamKey(serverID, songID, format, bitrateKbps)` and takes a
   closure that returns a stream URL. A server UUID is unique, so one more
   instance of the same class serves Jellyfin with no edit. The App builds the
   Subsonic instance under `SubsonicStreams` in the caches folder.
7. **Playback reaches the App through small protocols.** `QueuePlayer` takes
   `subsonicResolver: (any SubsonicStreamResolving)?`. `PlayableSource` has
   four cases (`localBookmark`, `subsonic`, `internetRadio`, `podcast`) with a
   `kind` discriminator. `.subsonic` is matched in `QueuePlayer+URLResolution`,
   `QueuePlayer+Loading` (next-track precache and play context) and
   `PlayHistoryRecorder`.
8. **Scrobble rows carry the source.** `scrobble_queue` has
   `subsonic_server_id` and `subsonic_song_id` (M021) and `payload_title`,
   `payload_artist`, `payload_album`, `payload_album_artist`,
   `payload_duration`, with an index on the server, song and played-at. A row
   from a remote source has `track_id` NULL. `SubsonicScrobbleProvider` ignores
   any event that has no Subsonic server pair or whose server is not enabled.
   The scrobble queue and worker are provider-neutral.
9. **Database.** The newest migration is `M054`. `subsonic_servers` (M020) and
   `subsonic_metadata_cache` are the model for the Jellyfin tables.
   `docs/data-dictionary-notes.json` marks the `payload_*` columns
   "Subsonic-only".
10. **Keychain.** Subsonic uses service `io.cloudcauldron.bocan.subsonic`,
    account `<serverID>`, payload `{"v":1,"kind":...,"secret":...}`, and reads
    through `settledKeychainRead` (GOTCHAS: a fresh write can read "not found").
11. **Logging.** `LogCategory` has `subsonic` and no `jellyfin`.
    `Observability.Redaction` lists Subsonic's `u`, `t`, `s`, `p` keys, not
    Jellyfin's `api_key`.
12. **`A11yIdentifiers.swift` is exactly 500 lines**, the size the lint rules
    stop at (GOTCHAS names two other files at 500). New identifiers go in a new
    file.
13. **Remote tracks play without ReplayGain** (GOTCHAS, the ADR-095 entry:
    "so do Subsonic, podcast and radio items"). Jellyfin joins that state.

About Jellyfin, from its OpenAPI document (checked on 2026-11-14):

14. **Auth.** `POST /Users/AuthenticateByName` and
    `POST /Users/AuthenticateWithQuickConnect` exist. Quick Connect is approved
    from a signed-in session through `POST /QuickConnect/Authorize`. The
    official Swift SDK wraps both: `client.signIn(username:password:)` and
    `client.quickConnect.connect()`, an async stream of `.polling(code)` then
    `.authenticated(secret)` (defaults: poll every 5 s, at most 200 polls).
15. **Favourites.** `POST` and `DELETE /UserFavoriteItems/{itemId}` set
    `IsFavorite`. `POST /UserItems/{itemId}/Rating?likes=` sets a boolean
    `Likes`. `UserItemDataDto` has a `Rating` number, but no music client uses
    it as stars.
16. **Items.** `BaseItemDto` carries `Artists`, `ArtistItems`, `AlbumArtists`,
    `Album`, `AlbumId`, `AlbumPrimaryImageTag`, `RunTimeTicks` (100 ns ticks),
    `Genres`, `ProductionYear`, `IndexNumber`, `ParentIndexNumber` (disc),
    `MediaSources`, `UserData` (`IsFavorite`, `PlayCount`).
17. **Streaming.** `GET /Audio/{itemId}/stream?static=true` returns the
    original file; the same path takes `container` and `audioCodec` to
    transcode. `POST /Items/{itemId}/PlaybackInfo` reports the plan.
18. **Playback reports.** `PlaybackStopInfo` carries `ItemId`, `PositionTicks`,
    `PlaySessionId`, `Failed`. `POST /UserPlayedItems/{itemId}` marks played.
19. **IDs are GUID strings.** Treat them as opaque.

## What carries over from previous specs

- **ADR-035** supplies every user-visible behaviour: the Sources section, the
  status dot and its four states, the editor fields, Test Connection, the
  offline banner with "Retry now", the pending-removal alert, in-view search
  with a 1.5 s soft timeout, star write-through with the 10 s retry and the
  three-failure event, scrobble write-through, the host-scoped self-signed TLS
  rule and its warning text, and "secrets never reach disk in plain text or the
  log".
- **ADR-037** supplies the checklist for a new `PlayableSource` case: encode
  and decode arms, existing tests updated, old blobs still decode.
- **ADR-029** supplies the scrobble queue, per-provider status rows and the
  rule that a provider handles only its own events.
- **ADR-085** supplies the E2E rule: loopback stub, no real network.
- **GOTCHAS** supplies the Keychain read-again rule, "no `try?` outside the
  audited idioms", the haptics test seam, and the SwiftUI observation traps.

## Decisions

**D1. Mirror, do not merge.** Every Jellyfin piece is a sibling of a Subsonic
piece. Reuse a Subsonic-named type unchanged only when it carries nothing
Subsonic specific and sits in a module Jellyfin may depend on: the stream
cache class, `HTTPTransport`, `RemoteTrackLoader`, the scrobble queue and
worker, `ScrobbleProvider`, the UI status dot and connection-state types, the
offline banner, `GradientPlaceholder` and theme helpers. Anything that would
need an edit to reuse is copied and adapted instead. The `Jellyfin` module
never imports `Subsonic`, and `Subsonic` never imports `Jellyfin`.

**D2. Authentication.** Password or Quick Connect, both ending in a device
access token and a user id. The password is used once and never stored. The
Keychain holds only the token: service `io.cloudcauldron.bocan.jellyfin`,
account `<serverID>`, payload `{"v":1,"kind":"accessToken","secret":...}`. If
the server revokes the token (HTTP 401) the monitor goes to `authFailed`, as
for Subsonic, and the editor offers "Sign in again". Removing a server also
asks the server to end the token (best effort, logged, never blocks removal).

**D3. Star is Favorite. Ratings are off.** Star and unstar write
`IsFavorite`. The rating menu in Jellyfin views is not built, so there is no
column for it (no `sync_ratings`).

**D4. A sibling `PlayableSource` case.**
`case jellyfin(serverID: UUID, itemID: String)`, with its own discriminator
`"jellyfin"` and keys `serverID` and `itemID`. It is `isRemote` and not live.
`.subsonic` is not touched, so an old build still reads every Subsonic queue.

**D5. Plays are reported the Jellyfin way.** `nowPlaying` sends "playback
started". A counted play sends "playback stopped" with `PositionTicks` equal to
the item's full `RunTimeTicks`, so the result does not depend on the server's
resume percentages. The provider never also calls `UserPlayedItems` (that would
count twice). Last.fm and ListenBrainz still receive the play through the
existing fan-out. No progress heartbeat in v1; the server may drop "now
playing" from its dashboard after its idle timeout. Accepted.

**D6. SDK confined to the `Jellyfin` module.** Use the official
`jellyfin-sdk-swift` (Context7 listed 3.2.0; the spike on 2026-11-14 found 3.4.0
the newest tag and pinned it, see "Spike result" under Dependencies). It is for auth, requests and
typed DTOs. The module exposes its own small models (`JellyfinSong`,
`JellyfinAlbum`, `JellyfinArtist`, `JellyfinGenre`, `JellyfinPlaylist`,
`JellyfinSearchResult`, `JellyfinPage`), so the UI and App never import the
SDK. Slice 2 opens with a spike: Swift 6 strict-concurrency warnings, clean
build time, the licence for `NOTICES.md`, and a way to give one host a trust
exception. If the spike fails, write a thin client of about a dozen endpoints
behind the same `JellyfinClientProtocol`, and ask the maintainer first (the
root `CLAUDE.md` rule on dependencies).

**D7. Credentials in URLs.** The stream cache takes a URL, so the stream URL
carries `api_key`, as Subsonic's carries its token. Cover art uses the same
parameter because `AsyncImage` cannot set headers. These URLs are never logged,
never put in an error, never stored. `api_key`, `ApiKey` and `X-Emby-Token` are
added to `Observability.sensitiveKeys`. (As built: the SDK's own URL helper names the
parameter `ApiKey`, so the module uses that spelling; `api_key` and
`X-Emby-Token` are redacted as well.)

**D8. One table per concern, trimmed to what Jellyfin uses.** Section
"Persistence" gives the columns. A column exists only if this ADR writes it,
reads it and tests it with a real value.

## Edits to existing files

Subsonic-named and shared files may be edited only as listed. An edit adds
lines, or widens a `switch` or condition to include the Jellyfin twin. It does
not remove, rename or rewrite a line. The slice review checks every changed
Subsonic-named file for deleted lines.

| File | Allowed edit |
|---|---|
| `Persistence/Migrations/Migrator.swift` | register M055 and M056 |
| `Observability/LogCategory.swift` | add `jellyfin` |
| `Observability/Redaction.swift` | add the three Jellyfin keys |
| `Playback/PlayableSource.swift` | add `.jellyfin`, its accessors, its codec arms |
| `Playback/QueuePlayer.swift` | add `jellyfinResolver` init parameter (default nil) |
| `Playback/QueuePlayer+URLResolution.swift`, `+Loading.swift`, `+QueueOperations.swift` | add the `.jellyfin` arm beside each `.subsonic` arm |
| `Playback/History/PlayHistoryRecorder.swift` | add the Jellyfin branch |
| `Scrobble/PlayEvent.swift` | add two optional fields at the end, default nil |
| `Scrobble/ScrobbleService.swift`, `Queue/ScrobbleQueueRepository*.swift`, `Queue/ScrobbleQueueWorker.swift` | add the Jellyfin twin of each Subsonic path |
| `UI/SidebarDestination.swift` | add `jellyfin*` cases and `jellyfinServerID` |
| `UI/ViewModels/LibraryViewModel+Navigation.swift`, `UI/Browse/SmartFolders.swift`, `UI/AppRoot/ContentPane.swift` | add `jellyfin*` arms and the offline banner branch |
| `UI/ViewModels/LibraryViewModel.swift` | one stored property, one init parameter, the search and bootstrap hooks |
| `UI/AppRoot/SubsonicSidebarSection.swift` | three injection parameters (see slice 3) |
| `UI/AppRoot/Sidebar.swift`, `RootView.swift` | build the Jellyfin rows; count Jellyfin servers in `hasSource`; bootstrap |
| `UI/Settings/SettingsScene.swift` | wrap the Sources page in the kind switch |
| `UI/Package.swift`, `project.yml`, `Makefile` | add the `Jellyfin` module and its test target |
| `App/BocanApp.swift`, `AppSceneContent.swift`, `BocanCommands.swift` | hooks into the new `JellyfinWiring`; help text |
| Scrobble settings and `RecentScrobblesView` | add the "Jellyfin" provider name |
| Docs and notes | `_standards.md` and root `CLAUDE.md` module tables, `data-dictionary-notes.json`, README, website, `HelpContent.swift`, `NOTICES.md`, `CHANGELOG.md`, `Localizable.xcstrings` |

## Outcome shape

```
Modules/Jellyfin/                              NEW. Depends on Observability, Persistence,
├── Package.swift                              and the Jellyfin SDK (this module only).
├── Sources/Jellyfin/
│   ├── JellyfinClientProtocol.swift           the seam the module is written against (D6)
│   ├── JellyfinService.swift                  actor, client pool, endpoints (mirrors SubsonicService)
│   ├── JellyfinService+Endpoints.swift        browse, lists, playlists, search, favourites, reports
│   ├── JellyfinServerStore.swift              CRUD + Keychain (mirrors SubsonicServerStore)
│   ├── JellyfinAuth.swift                     password sign-in, Quick Connect stream, sign-out
│   ├── JellyfinConnectionMonitor.swift        ping loop, back-off, wake (mirrors the Subsonic one)
│   ├── JellyfinAnnotations.swift              favourite retry queue (mirrors SubsonicAnnotations)
│   ├── JellyfinCoverArtProvider.swift
│   ├── JellyfinStreamURL.swift                static vs transcode URL builder
│   ├── JellyfinMapping.swift                  SDK DTOs -> Jellyfin* models; ticks -> seconds
│   └── Models/                                JellyfinServer, JellyfinConnectionStatus, JellyfinError,
│                                              JellyfinSong/Album/Artist/Genre/Playlist/SearchResult/Page,
│                                              JellyfinBitrate, JellyfinStreamFormat
└── Tests/JellyfinTests/Fixtures/              real responses, redacted, checked in

Modules/Persistence/Sources/Persistence/
├── Migrations/M055_JellyfinServers.swift      jellyfin_servers, jellyfin_metadata_cache
├── Migrations/M056_JellyfinScrobble.swift     jellyfin_* columns on scrobble_queue
└── Repositories/JellyfinServerRepository.swift

Modules/Playback/Sources/Playback/JellyfinStreamResolving.swift

Modules/Scrobble/Sources/Scrobble/Providers/JellyfinScrobbleProvider.swift

Modules/UI/Sources/UI/
├── Browse/Jellyfin/                           mirrors Browse/Subsonic/ (see slice 4)
├── AppRoot/JellyfinSidebarRows.swift          server rows, context menu, removal alert
├── Settings/JellyfinSettingsView.swift        + JellyfinSettingsViewModel.swift
├── Settings/SourcesSettingsPage.swift         the kind switch that hosts both editors
└── Accessibility/A11yIdentifiers+Jellyfin.swift

App/
├── JellyfinWiring.swift                       builds the whole Jellyfin graph (one place)
├── JellyfinStreamResolver.swift               mirrors SubsonicStreamResolver
├── JellyfinStoreSidebarListing.swift          mirrors SubsonicStoreSidebarListing
├── JellyfinMonitorConnectionObserver.swift
├── JellyfinRepositoryMetadataCache.swift
└── JellyfinScrobbleDelivery.swift

Scripts/audit-jellyfin-sdk-imports.py          lint gate: only Modules/Jellyfin imports the SDK
```

File names are a plan. If one collides, keep the meaning and change the name.

## Implementation plan

One branch, `feat/097-jellyfin-source`, one commit per slice (Conventional
Commits, scope = module). Related slices go into one PR, as the maintainer
prefers; push only when told the branch is complete.

**Slice 1: Persistence.**
`M055_JellyfinServers` and `JellyfinServerRepository` (CRUD, ordered fetch,
`pruneStaleCache`), with the DTO. `docs/data-dictionary-notes.json` entries for
every new column, then `make data-dictionary`. Test: real rows round-trip with
non-default values; unique-name index; prune removes only stale rows.

**Slice 2: the `Jellyfin` module, no UI.**
Spike first (D6). Then the module in "Outcome shape": store and Keychain
(`settledKeychainRead` pattern, orphan sweep), service actor, password sign-in,
Quick Connect, sign-out, ping, server-info probe, connection monitor, endpoints
and mapping, stream URL builder, cover art provider. Add `LogCategory.jellyfin`
and the redaction keys. Add the module to `project.yml`, the Makefile
(`test-jellyfin`, `coverage-all` floor) and the module table in `_standards.md`
and the root `CLAUDE.md`. Add `Scripts/audit-jellyfin-sdk-imports.py` to
`make lint`. Everything here is unit tested with a stubbed client.

**Slice 3: a server can be added and shows in the sidebar.**
- `JellyfinWiring` builds repo, store, service, monitor and annotations; the
  App hooks it into `BocanApp` in three places (build, hydration, wake
  observer) and passes it to the scenes.
- UI side: a `JellyfinSourceModel` (one `@MainActor ObservableObject`) holds the
  server lists, connection states, pending removal, data source, cover
  provider and search model. `LibraryViewModel` keeps one `let` reference to
  it. The Sidebar and ContentPane observe it directly (see Gotchas).
- `JellyfinSidebarRows` renders the servers with the Subsonic rows' look.
  `SubsonicSidebarSection` gets three additive parameters: extra server rows,
  extra Hidden Sources menu items, and a flag that says Jellyfin servers exist
  (so the empty-state button hides). Jellyfin shortcut indexes continue after
  the Subsonic ones.
- Settings, Sources becomes `SourcesSettingsPage`: a segmented kind switch
  above the existing `SubsonicSettingsView` (unchanged) and the new
  `JellyfinSettingsView`. The router's pending server id selects the right
  kind. The Jellyfin editor: server URL, "Test server" (name and version),
  sign in by password or Quick Connect (code shown, Cancel stops polling),
  display name, self-signed TLS with the same warning, max bitrate, preferred
  format, pre-cache, include in search, show in sidebar, scrobble, sync stars.
  No password field survives sign-in. "Sign in again" on `authFailed`.
- `SidebarDestination` gets its cases here so rows can be tagged.

**Slice 4: browse views.**
Copy `Browse/Subsonic/` to `Browse/Jellyfin/` and adapt each file to the
`Jellyfin*` models and `JellyfinSourceModel`: songs, albums, artists, genres,
playlists, starred, album and artist detail, song table, cells, drag, search
chrome and in-view search, offline banner use, metadata cache hydration. Skip
Internet Radio, Podcasts, Bookmarks and the rating menu. Add the `ContentPane`,
navigation and title arms. Reuse `SubsonicOfflineBanner`, the status dot and
`GradientPlaceholder` unchanged. Lazy paging with `StartIndex` and `Limit`,
page size 100, as Subsonic pages `getAlbumList2`.

**Slice 5: playback.**
`PlayableSource.jellyfin`; `JellyfinStreamResolving` in `Playback`;
`jellyfinResolver` on `QueuePlayer` and the three `.subsonic` match sites;
`JellyfinStreamResolver` in the App using a second `SubsonicStreamCache`
instance (directory `JellyfinStreams`, same budget rules). Original format
builds the static stream URL; any other format builds the transcode URL with
`container`, `audioCodec` and the bitrate in bits per second (Subsonic's
setting is kbps). Precache next honours the server flag. Remove-server clears
that server's cache folder.

**Slice 6: favourites and play reports.**
`JellyfinAnnotations` (retry, collapse, failure event) and a Jellyfin
annotation coordinator in the UI mirrored from the Subsonic one.
`M056_JellyfinScrobble`: `jellyfin_server_id`, `jellyfin_item_id` and the
matching index on `scrobble_queue`. `PlayEvent` gains two optional fields. Add
`recordJellyfinPlay`, `nowPlayingJellyfin`, `JellyfinPlayContext`, the queue
repository twin, the worker mapping, and `JellyfinScrobbleProvider`
(`id = "jellyfin"`). Register it in the App. Update the "Subsonic-only" notes on
the `payload_*` columns to say remote rows. Read every query that tests
`subsonic_server_id` and give it a Jellyfin twin; `queryRecent` must keep its
LEFT JOIN so Jellyfin rows are not dropped.

**Slice 7: polish.**
Empty states, offline banners with "Retry now", error toasts only for
user-started actions, VoiceOver labels on the status dot (the Subsonic wording),
`.help()` on every new control, A11y identifiers in the new file, all strings in
the catalog, `make pseudolocale`, `Scripts/audit-help-text.py` clean.

**Slice 8: docs.**
README, `/website`, `HelpContent.swift`, `NOTICES.md` (the SDK and its licence),
`CHANGELOG.md` under `[Unreleased]` in listener words, the `BocanCommands` help
text. No em dashes anywhere.

**Slice 9: E2E and the manual pass.**
A loopback Jellyfin stub for the hermetic E2E (the ADR-085 pattern; read how the
Subsonic journeys do it first): add a source, browse, play, favourite, remove.
Then the manual pass in the Test plan, recorded in the PR body.

## Behavioural definitions and contracts

### Persistence

`jellyfin_servers`, mirrored from `subsonic_servers`:

| Column | Written by | Read by | Traces to |
|---|---|---|---|
| `id` (pk, UUID text), `name` (unique), `server_url` | add flow | everywhere | ADR-035 |
| `user_id` | sign-in | every request | D2 |
| `username` | sign-in | editor ("Signed in as") | D2 |
| `device_id` | add flow (made once) | client header | D2 |
| `allow_self_signed_tls`, `max_bitrate`, `preferred_format`, `precache_next` | editor | service, resolver | ADR-035 |
| `include_in_search`, `show_in_sidebar`, `scrobble`, `sync_stars` | editor | search, sidebar, provider, annotations | ADR-035 |
| `sort_index`, `created_at`, `last_connected_at` | store, monitor | sidebar, editor | ADR-035 |

Left out on purpose: `auth_kind` (one method), `keychain_account` (always the
server id), `sync_ratings` (D3), `capabilities_json` (no capability-gated
rows; Test server shows live data and stores none).

`jellyfin_metadata_cache` mirrors `subsonic_metadata_cache`:
`(server_id, entity_kind, entity_id)` key, `payload_json`, `fetched_at`; rows
older than 7 days are pruned at launch.

`scrobble_queue` (M056): `jellyfin_server_id TEXT`, `jellyfin_item_id TEXT`,
and an index on `(jellyfin_server_id, jellyfin_item_id, played_at)`.

### Device identity

`device_id` is a UUID made once when the server row is created and never
changed. Signing in again reuses it, so the Jellyfin Devices page shows one
entry for this Mac. Client header values: `Client="Bocan"` (ASCII, like
Subsonic's `c`), device name from the Mac's computer name (it goes only to the
server the user chose), app version from the bundle.

### Models

Plain `Sendable`, `Hashable` value types. IDs are opaque `String`. A mapper never
invents a value: a field the server did not send is `nil`.

```swift
public struct JellyfinSong: Sendable, Hashable, Identifiable {
    public let id: String
    public var title: String
    public var artistName: String?
    public var artistID: String?
    public var albumTitle: String?
    public var albumID: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?
    public var durationSeconds: Double?      // RunTimeTicks / 10_000_000
    public var bitrateKbps: Int?
    public var container: String?
    public var coverArtID: String?           // id of the item that owns the image
    public var isStarred: Bool
}

public struct JellyfinPage<Element: Sendable>: Sendable {
    public var items: [Element]
    public var total: Int?                   // TotalRecordCount
}
```

`JellyfinAlbum`, `JellyfinArtist`, `JellyfinGenre`, `JellyfinPlaylist` and
`JellyfinSearchResult` follow the same rules.

### Connection status

`JellyfinConnectionStatus` has the same six cases as the Subsonic one
(`unknown`, `connecting`, `online`, `authFailed`, `unreachable`,
`serverError`). The App maps it to the UI's existing
`SubsonicSidebarConnectionState`. The monitor pings every 60 s, backs off
5, 10, 20, 40, 80, 160, 300 s, re-pings on network return and on wake, and stops
on 401. The ping is `GET /Users/Me`, not `/System/Ping`: the ping endpoint needs
no token, so it could never notice a revoked one. The monitor writes
`last_connected_at` when a server comes online and at most every 10 minutes after,
not on every ping.

### Queries

| View | Request shape |
|---|---|
| Songs | `Audio`, recursive, sorted by artist, album, track, paged |
| Albums | `MusicAlbum`, recursive, paged |
| Artists | album artists, paged; the view groups by initial |
| Genres | `MusicGenre`; songs by genre use the genre filter |
| Starred | the favourites filter on `Audio`, `MusicAlbum`, `MusicArtist` |
| Random | `Audio`, random sort, limit |
| Recently Added | `MusicAlbum`, date created descending |
| Most Played | `Audio`, play count descending |
| Playlists | `Playlist` items, minus any the server says hold video, photos or books. Do not require `MediaType = Audio`: a real 12.2.0 server reports `Unknown` for audio playlists imported from an M3U file |
| Search | three parallel queries (songs, albums, artists) with a search term |

Every request carries the user id and asks for the fields the mappers need
(`Genres`, `MediaSources`, `UserData`, `AlbumPrimaryImageTag`) so no view needs a
second round trip. Exact parameter names are checked in slice 2.

### Cover art

A song uses `AlbumId` and the album's image tag whenever the album has one, and
falls back to its own image only when it has no album image. (The first draft
did it the other way round. A real 12.2.0 server gives every song its own copy
of the album picture, so preferring the song's copy would cost one image request
per track where one per album is enough.) The URL is `/Items/{id}/Images/Primary` with `maxWidth`, the image `tag`
(so a changed cover does not show stale) and `api_key`.

### Stream URL

| Preferred format | Request |
|---|---|
| Original | static stream of the original file (a bitrate cap is ignored: it needs a target codec) |
| mp3, aac, opus, flac | transcode with codec, container and a bitrate cap in bit/s |

The Settings editor (slice 3) must grey out the max bitrate while the format is
Original, so the setting never looks active when it is not.

The cache signals ready only after the full download (CLAUDE.md gotcha), so a
transcode with no `Content-Length` is fine and seek works on the finished file.
The cache key's `format` and `bitrateKbps` follow the Subsonic resolver.

### Play reports and favourites

- Star and unstar: `UserFavoriteItems`. Same retry rule as Subsonic: 3 attempts,
  10 s apart, then an `annotationFailed` event; a star then unstar before
  delivery collapses to the last action.
- Now playing: "started" at position zero.
- Counted play: "stopped" with `PositionTicks = RunTimeTicks`; if the runtime
  is unknown, `durationPlayed * 10_000_000`.
- HTTP 401 marks the server `authFailed` and the row `ignored("auth-failed")`.
- The provider ignores events that have no Jellyfin pair or whose server has
  `scrobble` off, as `SubsonicScrobbleProvider` does.

## Context7 lookups

Run before the slice that needs them. Prefer the latest version of each
dependency and avoid deprecated API. If a lookup contradicts this ADR, stop and
ask.

- `/jellyfin/jellyfin-sdk-swift` (slice 2 spike): current version (3.2.0 was
  listed), the product and module name (`JellyfinAPI` is expected), the
  `JellyfinClient` initialiser, whether it accepts a configured `URLSession` or
  delegate for the host trust exception, Swift tools version, strict
  concurrency status, licence.
- `/openapi/api_jellyfin_openapi_jellyfin-openapi-stable_json` (slice 2), the
  paths the first lookup did not return: `GET /Audio/{itemId}/universal`;
  `POST /Sessions/Playing`, `/Sessions/Playing/Progress`,
  `/Sessions/Playing/Stopped`; `GET /Items` and its parameters
  (`includeItemTypes`, `recursive`, `startIndex`, `limit`, `sortBy`,
  `sortOrder`, `filters`, `genreIds`, `searchTerm`, `fields`, `userId`) and
  `TotalRecordCount`; `GET /Artists/AlbumArtists`; `GET /MusicGenres`;
  `GET /System/Info/Public`; `GET /System/Ping`; `GET /QuickConnect/Enabled`;
  `POST /Sessions/Logout`; the image path and its `api_key` parameter.
- The same document, for D5: how the server decides "played" on a stop report
  (the minimum and maximum resume percentages), and which server version
  introduced `UserFavoriteItems` and `UserItems/{id}/Rating` (these are the
  10.9 names; older servers use `/Users/{userId}/FavoriteItems/{itemId}`).
  Set the minimum supported server version from the answer. This ADR assumes
  10.10.
- Apple `Security` docs, if the SDK gives no hook for a per-host trust
  exception: the host-scoped delegate in `TrustBypassTransport` is the pattern.

## Dependencies

- `.package(url: "https://github.com/jellyfin/jellyfin-sdk-swift", from: "3.4.0")`
  in `Modules/Jellyfin/Package.swift` only (the first draft said 3.2.0), and
  `.package(url: "https://github.com/kean/Get", from: "2.2.1")` beside it, because
  the SDK does not re-export `Get` and `APIError.unacceptableStatusCode` is the
  only place a failed request's HTTP status lives. Confirm the licence and add
  it to `NOTICES.md` (slice 8).
- **Spike result (slice 2, 2026-11-14).** Tag 3.4.0 builds with Swift 6.4.2 on
  macOS with `StrictConcurrency` on and zero warnings. The first clean build took
  12 minutes 47 seconds, almost all of it fetching dependencies (GRDB's
  submodule, swift-nio); after that the module compiles in about 12 seconds.
  Licence: **MPL-2.0** (file-level copyleft; linking the library is allowed, and
  `NOTICES.md` must name it and say where its source is). Transitive packages:
  `Get`, `swift-nio-transport-services` and `swift-nio`. The client takes a
  `URLSessionDelegate`, so the host trust exception is a delegate, as for Subsonic.
  The SDK marks `/Artists/AlbumArtists` deprecated; see the Gotchas entry.
- DAG: `Jellyfin` sits in the same layer as `Subsonic` and depends on
  `Observability` and `Persistence`. `UI` and `App` depend on `Jellyfin`.
  `Playback` and `Scrobble` do not depend on it (they use protocols and
  optional ids, as for Subsonic). Update the table in `_standards.md`.
- No new Homebrew formula, system library or FFmpeg change.

## Test plan

No test touches the network. Fixtures are real Jellyfin responses, redacted,
checked in under `Modules/Jellyfin/Tests/JellyfinTests/Fixtures/`.

**Unit**
- `JellyfinTests`: store CRUD and unique name; Keychain create, update, delete,
  orphan sweep, read-again; sign-in success and 401; Quick Connect with a stub
  (polling, approved, timeout, cancelled); every mapper against a fixture
  (ticks to seconds, missing fields stay nil, cover art uses `AlbumId`); stream
  URL for original and each transcode format; monitor back-off, 401 stop and
  reset on success; annotation collapse, retry and failure event; play reports
  (one start, one stop with the full runtime); URLs and errors contain no token.
- `PersistenceTests`: both migrations on a real M054 database; repository
  round-trip with non-default values; prune.
- `PlayableSourceTests`: `.jellyfin` round trip; old blobs unchanged; accessors.
- `QueuePersistenceTests`: a blob that holds an unknown `kind` loses that item
  only, not the whole queue. If this fails today, fix it in slice 5: an older
  build reading a queue with a Jellyfin item must cost one item at most.
- `ScrobbleTests`: each provider ignores the other's events; a Jellyfin play
  still reaches Last.fm and ListenBrainz; `queryRecent` keeps Jellyfin rows.
- `UITests`: a Jellyfin server shows exactly the nine rows; Jellyfin and
  Subsonic rows both show; the kind switch picks the right editor from a
  pending server id; empty state hides when only Jellyfin servers exist; view
  model tests mirrored from the Subsonic ones (paging, search, rollback);
  `L10nTests` and the en-XA test.

**Integration**
- Stream cache with a stub transport and no `Content-Length`.
- Wiring test: `JellyfinWiring` builds with an in-memory database and a stub
  client.

**End to end (ADR-085)**
- The loopback stub journeys from slice 9. New identifiers are added to
  `A11yIdentifiers+Jellyfin.swift` and the identifier coverage (ADR-080).

**Infrequent checks (duplication and dead code)**
- Before the PR, and again after the manual pass: a duplicate-code scan and a
  Periphery scan over `Modules/Jellyfin` and `UI/Browse/Jellyfin`. Hits against
  the Subsonic twin are expected and accepted by this ADR. Hits inside Jellyfin,
  or against non-Subsonic code, are fixed. `make audit-db` shows no new
  finding. Prefix Periphery with the fsmonitor workaround from GOTCHAS if it
  hangs.
- A diff check: no deleted line in any Subsonic-named file.

**Manual**
- A real Jellyfin 10.10 or newer server with a few hundred tracks (FLAC and
  MP3), one multi-disc album, one album with no cover. Add by password and by
  Quick Connect; browse every row; play, seek, gapless; transcode to MP3 and
  Opus; favourite and unfavourite (check in the Jellyfin web UI); play count
  after a counted play (check it rose once); token revoked in the dashboard;
  server removed (check the Devices page); network cut mid-track. Also add a
  Navidrome server beside it and check nothing in the Subsonic source changed.

## Acceptance criteria

- [ ] Settings, Sources has a kind switch. A Jellyfin server can be added by
      password and by Quick Connect. The password is stored nowhere; the
      Keychain holds only the token.
- [ ] A Jellyfin server appears in the Sources section under the Subsonic
      servers, with the same status dot, disclosure, context menu (Refresh,
      Test Connection, Edit, Disable in Sidebar, Remove) and shortcut. Hidden
      Jellyfin servers show in Hidden Sources.
- [ ] A Jellyfin server shows exactly Songs, Albums, Artists, Genres,
      Playlists, Starred, Random, Recently Added, Most Played, with the
      Subsonic icons.
- [ ] Views match the Subsonic ones: paging, album and artist detail, song
      table and drag, in-view search, offline banner with "Retry now".
- [ ] A Jellyfin track plays, seeks, and plays gaplessly into the next one.
      Transcode to MP3 and Opus works. Playback starts within 2 s on a 10 Mbps
      link for an ordinary original FLAC.
- [ ] Favouriting writes through and shows in the Jellyfin web UI.
- [ ] A counted play raises the server play count once, and Last.fm and
      ListenBrainz also receive it when connected.
- [ ] A queue with a Jellyfin track restores. An older build that reads it
      loses at most that item.
- [ ] A revoked token shows an offline banner with "Sign in again" and the
      monitor stops pinging.
- [ ] Removing a server removes its Keychain item, its stream cache folder and
      its cached metadata, and asks the server to end the token (best effort).
- [ ] The log, a debug run and a crash report show no token or `api_key`.
- [ ] No deleted line in a Subsonic-named file. Subsonic tests and snapshots
      pass with no re-record. The sidebar and Settings for a Subsonic-only user
      look and behave as before.
- [ ] `make format`, `make lint`, `make build`, `make test-coverage`,
      `make test-jellyfin` and `make test-ui` are green; `make pseudolocale` is
      run; README, website, in-app Help, `NOTICES.md` and `CHANGELOG.md` are
      updated; `/slice-review` is run before the PR.

## Gotchas

- **Observation.** `JellyfinSourceModel` is its own `ObservableObject`.
  `LibraryViewModel` does not forward its changes. The Sidebar and ContentPane
  must hold it with `@ObservedObject` and read it directly. Read GOTCHAS
  "SwiftUI observation" and the commands staleness entry first. Do not mirror
  server lists in `@AppStorage` and do not use a `RawRepresentable`
  `@AppStorage` for the kind switch (GOTCHAS: it does not propagate across
  instances); use `@State` seeded from the router.
- **Unguarded writes.** Any `didSet` that mirrors to `UserDefaults` must guard
  on a real change, or navigation clicks bring back the old crackle bug.
- **500-line files.** `A11yIdentifiers.swift` is at 500. Put new identifiers in
  a new file. Check `SubsonicSidebarSection.swift` (459) before adding to it;
  the three parameters are small, but keep the rest in `JellyfinSidebarRows`.
- **Adapted copies drift.** When a Subsonic file is copied, copy its current
  behaviour, including recent fixes (#493, #309, #596). Read the file's history
  with `git log -p` for the last few fixes before you adapt it.
- **Type name clash.** `Persistence` and `Subsonic` both export `Podcast`
  types (GOTCHAS). Jellyfin models all start with `Jellyfin`, so none clash.
  Do not name anything `Server`, `Song` or `Album` alone.
- **Ticks.** Durations are 100 ns ticks. `RunTimeTicks / 10_000_000` is seconds.
  Positions go the other way. Use `Int64`.
- **GUIDs.** IDs may come back with or without dashes from different endpoints.
  Do not parse, change case or reformat. If two endpoints disagree, normalise in
  the mapper and test it.
- **Cover art id is not the song id.** Use the item that owns the image, and the
  image tag in the URL.
- **Several music libraries.** Queries span all of them. A duplicated album
  appears twice. Accepted for v1.
- **Token in URLs.** Only stream and image URLs carry `api_key`. Never log them,
  never put them in an error message, a crash breadcrumb, history or the
  metadata cache.
- **Played threshold.** The server decides what "played" means. D5 sends a
  full-length stop so the outcome does not depend on the resume percentages. A
  mocked test cannot prove the count rose; only the manual pass can. Do not
  write "play count verified" without it.
- **No heartbeat.** The server may clear "now playing" after its idle timeout.
  Not a defect for v1. Do not add a timer to the scrobble pipeline to hide it.
- **Quick Connect may be off.** `QuickConnect/Enabled` can be false, and the
  user needs another signed-in session to approve. Show a plain message, never a
  spinner with no end. Stop polling when the sheet closes.
- **Keychain.** Login keychain, no `kSecAttrAccessible*` (GOTCHAS, TN3137). Read
  again before treating "not found" as final.
- **Stream cache name.** The second `SubsonicStreamCache` instance is named for
  Subsonic and used for Jellyfin on purpose. Do not rename it. Use a separate
  folder so removal and eviction stay per kind.
- **Queue downgrade.** An older build cannot decode `jellyfin`. See the queue
  test in the Test plan.
- **Strings and help text.** "Jellyfin" is a brand and is not translated. Every
  new control needs `.help()` (`Scripts/audit-help-text.py`). New keys need
  `make pseudolocale`.
- **Trademark.** Use the word in text only. Do not ship the logo without
  checking its terms.
- **Mirror to GOTCHAS.** Any trap found while building goes into
  `docs/GOTCHAS.md` in the Problem / Rule / Why / Canonical file form.

## Future work (parked)

- A per-server music library picker (needs a column).
- ReplayGain for remote tracks, Jellyfin's `NormalizationGain` included (check
  its target against ReplayGain 2 first). A shared gap with Subsonic.
- Progress heartbeat for the server's now-playing display.
- Instant Mix and Similar albums as extra rows.
- Playlist create, edit and delete.
- Lyrics, offline pinning.
- If a third source is ever added, that is the moment to weigh a shared layer.
  It is not this ADR's job.

## Slice status

| Slice | State |
|---|---|
| 1 Persistence | Done. `M055`, `JellyfinServerRepository`, tests, data dictionary. |
| 2 `Jellyfin` module | Done on 2026-11-14, with these departures from the plan: `Get` is a second declared dependency; the module has its own `JellyfinAuth` that owns the Quick Connect loop; `ApiKey` is the URL parameter; the ping is `/Users/Me`; the checked-in fixtures are hand-written in Jellyfin's response shape. |
| 2, real server check | Done on 2026-11-14 against Jellyfin **12.2.0** (the maintainer's server), with `Scripts/capture-jellyfin-fixtures.py`. SDK 3.4.0 decodes every captured list, the sign-in answer and the public info, and no item is dropped by a mapper. Item and user ids are 32 hex characters with no dashes in every list, so no id normalisation is needed. Genres from `/Genres` have type `Genre`, not `MusicGenre`. Audio playlists imported from M3U report media type `Unknown` (fixed in the mapper). The captures hold a person's own library, so they are not checked in: `JellyfinCapturedFixtureTests` runs them when `JELLYFIN_CAPTURE_DIR` is set. Not yet checked on a real server: favourite, play reports, stream and cover URLs, Quick Connect through the Swift code, and the transcode formats. The minimum server version stays unset; 12.2.0 is the only version seen working. |

## Handoff

This is nine slices on one branch. Run each in a fresh session; the ADR is the
spec. Paste this prompt, changing the slice number:

```
Read docs/design-spec/_standards.md, then docs/design-spec/ADR-097-jellyfin-source.md
in full. Implement slice N only, on branch feat/097-jellyfin-source. Follow
"Decisions", "Edits to existing files" and the slice text exactly. Mirror the
Subsonic file named in the slice; never refactor or delete Subsonic code. Do the
Context7 lookups the slice needs first. Do not start the next slice. Then run
make format, make lint, make build, the module tests the slice touched, and make
test-coverage. Commit with a Conventional Commit (scope = module), no trailers,
no push. Tell me what is left and anything that needs my call.
```

| Session | Slice | Model advice |
|---|---|---|
| 1 | Persistence | cheap |
| 2 | `Jellyfin` module | strong; spike gate, ask before any fallback |
| 3 | Add flow and sidebar | strong; observation traps |
| 4 | Browse views | cheap, mechanical copy and adapt; review by a strong model |
| 5 | Playback | strong; persisted names |
| 6 | Favourites and play reports | cheap, then strong review of the scrobble queries |
| 7 | Polish | cheap |
| 8 | Docs | cheap |
| 9 | E2E and manual pass | the maintainer runs the manual pass |

Decisions that still need the maintainer:

1. **SDK fallback.** If the SDK spike fails, hand-write the thin client or use
   another SDK?
2. **Minimum Jellyfin version.** 10.10 is assumed; confirm after the lookup.
3. **A real Jellyfin server.** Is one available for fixtures and the manual
   pass? Without it, slice 9 stays open and the play count criterion stays
   unchecked.
4. **An issue number.** None exists yet; open one so the PR body can close it.
