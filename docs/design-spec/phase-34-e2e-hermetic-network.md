# Phase 34: E2E Hermetic Network (Radio and Podcast Servers)

> Prerequisites: Phases 28-31. Nightly runs must never touch the internet,
> yet radio and podcasts are network features; this phase gives them
> loopback fake servers so their journeys run end to end, hermetically.
> Subsonic stays at the unit tier by decision (its fake server is the
> biggest lift and can become a later phase if wanted).
>
> Read `docs/design-spec/_standards.md` first.

## Goal

A loopback ICY stream server and a loopback podcast RSS server as test
support, plus the radio and podcast journey suites that run against them.

## Non-goals

- A fake Subsonic server.
- Testing real-world stream pathologies beyond the scripted ones below
  (the unit tier's URLProtocol stubs keep covering parser edge cases).

## Implementation plan

1. **`E2EStreamServer` (UITests/Support/).** A small HTTP server (reuse
   the hand-rolled HTTP/1.1 machinery patterns from SyncServer's tests)
   that serves: a looping MP3 fixture as an ICY stream with a real
   `icy-metaint` interleave, scriptable `StreamTitle` sequences, and the
   full `icy-*` header set (name, genre, url, br); an `.m3u` station-list
   endpoint; and control endpoints the tests call to script behavior:
   advance-title, drop-connection, and refuse-connections-for(seconds).
2. **Radio journeys.**
   - Add-by-URL: paste the stream URL into Add Station, play, assert the
     strip shows the scripted title with the station on the artist line,
     and the macOS Now Playing widget path is exercised (assert via the
     app's own state; the system widget itself is out of reach).
   - Stream details: open the player info sheet; assert codec, sample
     rate, bitrate, and "Now-Playing Titles: Supported" match what the
     fixture serves; stop playback; assert the row's info sheet shows the
     persisted profile offline.
   - Playlist-URL indirection: paste the `.m3u` endpoint, assert the
     found-stations sheet offers the scripted station names, Add All,
     assert the catalog.
   - Reconnect: while playing, script a connection drop shorter than the
     engine's reconnect budget; assert playback resumes without user
     action. Then a drop longer than the budget; assert the failure
     surfaces (toast) rather than a silent wedge.
   - Import file: drop a dial file whose URLs point at the fake server;
     assert stations import and the toast reports the count.
3. **`E2EPodcastServer`.** Serves a fixture RSS feed (two episodes, one
   with chapters) and the episode audio files; control endpoint to
   publish a third episode.
4. **Podcast journeys.** Subscribe by URL, episode list renders, download
   an episode (served file), play with resume (seek, quit, relaunch,
   resume position honored), refresh discovers the newly published
   episode.

## Test plan

- All journeys green with servers started/stopped per suite; port 0
  (ephemeral) binding so parallel runs never collide.
- The reconnect pair is the flake watch: three consecutive green nights
  before acceptance.

## Acceptance criteria

- [x] No test in the E2E suite opens a non-loopback connection. Verified
      by a manual code audit tracing every network-touching feature
      reachable from `UITests/` (Subsonic, scrobbling, cover art,
      lyrics, AcoustID, Sparkle, background schedulers), rather than a
      live deny-all-outbound firewall run. Found and fixed two real
      leaks: pasting a podcast feed URL into the add bar also ran it
      as a live search query against iTunes/PodcastIndex
      (`PodcastsViewModel+Search.swift`), and scrobble's "now playing"
      ping (fires on every track start, unlike a full scrobble) read
      the real login-keychain credentials with no E2E isolation
      (`E2EEnvironment.scrobbleCredentialsService`). AcoustID, Sparkle,
      and the LRClib fetch were already correctly gated; Subsonic and
      scrobble "connect"/"test connection" buttons are safe today
      because no current journey clicks them, not because of an
      explicit gate -- worth hardening if a future crawl test reaches
      them.
- [x] Radio journeys cover: add, titles, details, indirection, reconnect
      success, reconnect exhaustion, and file import.
- [x] Podcast journeys cover: subscribe, download, resume, refresh.
- [x] Servers are test-support only (never compiled into the app).

## Gotchas

- The ICY interleave must be byte-correct (length byte x16, padding);
  FFmpeg is unforgiving, and a wrong metaint quietly disables titles,
  which this suite would misread as an app bug.
- `avformat_find_stream_info` reads well past one metaint interval at
  open; the first scripted title must therefore be in the initial buffer
  or tests race the probe (serve title #1 from byte zero).
- App Transport Security: loopback HTTP is allowed by default, but the
  E2E flag should not weaken ATS globally; use `http://127.0.0.1` which
  needs no exception.
- The reconnect budget lives in `AudioEngine+Reconnect`; the journey must
  read its constants from a shared fixture, not hardcode 3 x 5s.

## Handoff

Phase 35 schedules these suites on both tiers (they are CPU-cheap) and
inherits the no-internet guarantee for the whole nightly run.
