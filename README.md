# Bòcan Music

[![CI](https://github.com/bocan/bocan-music/actions/workflows/ci.yml/badge.svg)](https://github.com/bocan/bocan-music/actions/workflows/ci.yml)
[![CodeQL](https://github.com/bocan/bocan-music/actions/workflows/codeql.yml/badge.svg)](https://github.com/bocan/bocan-music/actions/workflows/codeql.yml)
[![GitHub release](https://img.shields.io/github/v/release/bocan/bocan-music?color=4BC51D)](https://github.com/bocan/bocan-music/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)
![Xcode 26](https://img.shields.io/badge/Xcode-26-1575F9)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](https://swift.org)



**The music player macOS deserves.** No Electron. No Catalyst. No subscription. No cloud. Just your music, played beautifully.

![Bòcan Songs view](website/static/screenshots/Screenshot%202026-05-07%20at%2020.35.08.png)

---

## Why Bòcan?

Most Mac music players are either abandoned, Electron-wrapped, or stripped-down streaming clients that barely tolerate local files. Bòcan is the answer to all three: a **native Swift 6 app** built entirely around owning and enjoying your own library, the way iTunes used to before it became a content storefront.

### 🔊 It sounds better

- **True gapless playback** with nanosecond `AVAudioTime` anchoring. Classical transitions, live albums, and DJ mixes play as the artist intended, with zero silence and zero clicks.
- **10-band graphic EQ**, bass boost, stereo expander, binaural crossfeed, and a **peak limiter**, a full DSP chain between your files and your ears.
- **ReplayGain** applied at playback time; analyses missing tags in the background using EBU R128 loudness.
- **Configurable crossfade** (0–12 s), **playback speed** (0.5×–2.0×) with pitch correction, and a **sleep timer** that fades gracefully rather than cutting mid-note.

### 📻 It plays everything

- Everything AVFoundation handles natively: **FLAC, ALAC, AAC, MP3, WAV, AIFF, CAF, M4A**.
- The awkward ones too, via an integrated FFmpeg bridge: **Ogg Vorbis, Opus, APE (Monkey's Audio), WavPack, DSD**. No plug-ins, no extra installs.

### 📚 It respects your library

- **Folder-based, non-destructive.** Point it at your music directory and it indexes without touching a single file.
- **Live FSEvents watcher** picks up new or changed files automatically; **mtime + fingerprint deduplication** keeps your library clean.
- **AcoustID fingerprinting** against MusicBrainz. Identify any track, preview every proposed tag change side-by-side with what you have now, tick the fields you want to update, and apply.
- **In-app tag editor** with multi-track batch editing, embedded cover-art drag-and-drop, and undo.

### 🎨 It's a pleasure to use

- **Three-pane browser**: Albums grid, Tracks list, Artists view, and Recently Added.
- **Smart Playlists** built from a rule editor, compiled to live SQL and updated automatically as your library changes.
- **Live playlist sync**: add or remove tracks from a manual playlist while it is playing and Up Next updates immediately. Sequential mode keeps your position and reorders around it; shuffle mode drops removed tracks and slots new ones in.
- **Import / export** M3U, PLS, and XSPF playlists, with fuzzy track matching on import.
- **Real-time visualisers**: spectrum bars, oscilloscope, Halo (a breathing spectrum ring with beat ripples), Cascade (a scrolling spectrogram waterfall), Starfield (a frequency-coloured warp field that stretches into streaks on the beat), and Nebula (a luminous gas cloud whose churn, drifting wisps, and pressure waves all follow the music), dockable or full-screen with `⌘⇧F`. All six are GPU-rendered with Metal, which moves the drawing off the CPU and onto per-pixel shaders: they stay smooth at full-screen and native Retina resolution, and can sustain effects a CPU renderer could not (Nebula's churning gas is a live shader simulation, not a looping texture). They ship with six colour palettes, including a music-steered Drift and a magnitude-to-heat Thermal ramp. Hover any visualizer to switch the mode or palette in place with the on-screen steppers.
- **Mini Player** in four layouts (Strip, Compact, Square, Visualizer) with always-on-top mode.
- **Mac-native feel**: gentle trackpad haptics when you love, rate, seek, or release the volume slider, and a soft window cross-fade when swapping between the Mini Player and the main window. Respects Reduce Motion and the system trackpad haptics setting.
- **[Last.fm](https://www.last.fm), [ListenBrainz](https://listenbrainz.org), and [Rocksky](https://rocksky.app/)** scrobbling, offline-resilient with Keychain auth and a dead-letter queue.
- **Subsonic / Navidrome / Airsonic** servers as first-class sources alongside your local library. Federated search across every server, per-server status dots, offline banners with one-tap retry, `⌘⇧1`–`⌘⇧9` to jump straight to a server, and drag a streamed song straight into Up Next.
- **Podcasts** - subscribe by URL or search across Podcast Index and Apple iTunes; RSS and Atom feeds; per-episode resume; download episodes individually or in bulk, plus optional per-show auto-download of new episodes; Podcasting 2.0 chapters (jump-to and read), transcripts, and host/guest credits (`podcast:person`); variable speed and skip intervals.
- **In-app Log Console** : open **Help -> Log Console** (`⌘⇧L`) to tail every log line since launch, filtered by level or category, with free-text search, live tailing, pause and resume, copy to clipboard, and export to a `.log` file. Diagnose a problem without ever leaving the app.

### ♿ It's accessible

I've tried hard to ensure Bòcan is fully navigable without a mouse or a screen:

- **VoiceOver-first track list** : each row announces *"Title, Artist, Album, Duration"* as a single spoken sentence rather than reading every column individually.
- **Live now-playing announcements** : when the track changes, VoiceOver speaks the new track name automatically, without you having to navigate to the transport bar.
- **Full keyboard navigation** with logical focus sections and no focus traps.
- **Dynamic Type** throughout : every label, badge, and table cell scales with your macOS text size setting.
- Album cells, artist rows, and genre chips are grouped with `.combine` so VoiceOver reads them as single logical elements.
- Transport controls carry state via `accessibilityValue` (e.g. *"Shuffle, on, button"*) so you always know what you're toggling.
- EQ band sliders report their gain in the format *"80 Hz, +3.0 dB"* rather than a raw number.

### 🏗️ It's engineered properly

- **Swift 6 strict concurrency** : `@MainActor` isolation, `Sendable` everywhere it matters, zero data races by design.
- **Ten clean SPM modules** with no upward imports and their own test suites.
- **80% line-coverage gate** in CI; the build fails if coverage drops.
- **GRDB 7** with typed repositories, FTS5 full-text search, and `ValueObservation`-based reactive streams.
- **XcodeGen** project generation : no hand-edited `.pbxproj` files in the repo.
- **CodeQL, SwiftLint, SwiftFormat, and Dependabot** on every pull request.

---

## On the name

Naming things is hard. I was up from midnight to almost 3 am trying to figure out a name that wasn’t already taken for another app. In the end, I couldn’t find one that was free, so I went with the name I’ve used on the internet since the internet existed.

Bocán (Old Irish) means a young male deer, the root of which is cognate with the Welsh "boc" and the Breton "bok", both meaning "buck".

Bòcan (Scottish Gaelic, roughly *BAW-khan*) is a hobgoblin or a household spirit.

Bòcan curates your music library while you sleep. The short version is that computers don't like `ò`, so the binary, bundle, and repository all use `bocan`:

| Property | Value |
|----------|-------|
| Display name | Bòcan |
| Binary / package name | `bocan` |
| Bundle ID | `io.cloudcauldron.bocan` |
| Log subsystem | `io.cloudcauldron.bocan` |
| Minimum macOS | 15.0 (Sequoia) |

---

## What's next

- **File management tools**: move, rename, and organise files directly from the library.
- **Remote control**: iPhone and Android apps to control playback on the Mac; the Mac stays the source.
- **Accessibility**: ongoing work; VoiceOver coverage is good but there's more to do.

Contributions and ideas welcome. Open an issue or a pull request.

---

## Install

**Download the DMG** from [bocan.app/download](https://bocan.app/download) or the [GitHub Releases](https://github.com/bocan/bocan-music/releases) page. Open it, drag Bòcan to Applications, done.

**Homebrew**: add the tap once, then install:

```bash
brew tap bocan/bocan
brew install bocan
```

Sparkle keeps the app current automatically. `brew upgrade --greedy bocan` does the same from the terminal if you prefer.

---

## Building from source

See [DEVELOPMENT.md](DEVELOPMENT.md) for prerequisites, environment setup, the build system, common `make` targets, FFmpeg and fpcalc notes, and contribution guidelines.

## Modules

| Module | Description |
|--------|-------------|
| `Observability` | Structured logging (`AppLogger`), in-process ring buffer (`LogStore`), log console support, telemetry, MetricKit |
| `Persistence` | GRDB schema + migrations, repositories, reactive `ValueObservation` |
| `AudioEngine` | AVFoundation + FFmpeg decoder graph, ring buffer, DSP chain, playback actor |
| `Metadata` | TagLib read/write, cover-art extraction, LRC lyric parser |
| `Acoustics` | Chromaprint fingerprinting, AcoustID + MusicBrainz lookup |
| `Subsonic` | Subsonic / Navidrome / Airsonic client, capability detection, Keychain credentials |
| `Library` | Folder scanner, FSEvents watcher, conflict resolver, cover-art cache |
| `Playback` | Queue, history, shuffle strategies, gapless + crossfade scheduler, MPNowPlaying, sleep timer |
| `Scrobble` | Last.fm / ListenBrainz / Rocksky providers, offline-resilient scrobble queue |
| `UI` | SwiftUI views, view models, mini player, settings, theming, snapshot tests |

## Licence

See [LICENSE](LICENSE).

## And Last but Not Least

Much love to the giants whose shoulders I stand on:

- [Christopher Snowhill](https://kode54.net/), maintainer of of the excellent [Cog](https://cog.losno.co/).  The patron saint of native macOS music players and Cog is the direct spiritual ancestor of what I've built here.
- [Fabrice Bellard](https://bellard.org/), creator of [FFmpeg](https://ffmpeg.org/), and QEMU, and TinyCC, and a dozen other earth-shaking projects. The reason Bòcan can play Ogg, Opus, APE, WavPack, and DSD without making users install plugins.
- [Christopher "Monty" Montgomery](https://people.xiph.org/~xiphmont/) and the [Xiph.Org Foundation](https://xiph.org/): Vorbis, FLAC, Opus, Speex. The entire free codec stack on which lossless audio on the open web is built.
- [Peter Pawlowski](https://www.foobar2000.org/), maintainer of [foobar2000](https://www.foobar2000.org/), solo since 2002. Even though no foobar code touches Bòcan, foobar's design DNA (modular DSP, smart playlists, gapless, format breadth) is the spiritual blueprint of every audiophile-flavour music player that has followed.
- [Lukáš Lalinský](https://oxygene.sk/), creator of [Chromaprint](https://acoustid.org/chromaprint) and [AcoustID](https://acoustid.org/). The entire fingerprinting and auto-tagging pipeline in Bòcan exists because of his work. Also a long-time TagLib contributor. A one-person open-source music-metadata hero.
- [Scott Wheeler](https://github.com/wheels/) and the [TagLib](https://taglib.org/) contributors: without TagLib, I'd be reimplementing ID3v2.4 + Vorbis comments + APE tags + MP4 atoms by hand.
- [Robert Kaye](https://blog.metabrainz.org/author/robert/) and the [MetaBrainz Foundation](https://metabrainz.org/): [MusicBrainz](https://musicbrainz.org/), [ListenBrainz](https://listenbrainz.org/), [Cover Art Archive](https://coverartarchive.org/). Bòcan's auto-tagging, lookup, and open scrobbling all sit on this stack.
- [Gwendal Roué](https://github.com/groue), maintainer of [GRDB.swift](https://github.com/groue/GRDB.swift). Quietly one of the best-maintained Swift libraries in existence, solo for over a decade. My entire persistence layer is built on it.
- [Justin Frankel](https://www.cockos.com/~justin/), co-creator of [Winamp](https://en.wikipedia.org/wiki/Winamp) (back in his Nullsoft days), later [REAPER](https://www.reaper.fm/), NSIS, gnutella, and most of [Cockos](https://www.cockos.com/). Winamp basically invented the modern desktop music player. Anyone building one stands on this work whether they realise it or not.
- [Jean-Marc Valin](https://jmvalin.dreamwidth.org/), primary author of [Opus](https://opus-codec.org/) (and Speex before that), one of the great open codec achievements of the last twenty years.
- [Yonas Kolb](https://github.com/yonaskolb), creator of [XcodeGen](https://github.com/yonaskolb/XcodeGen). Saved me (and everyone else) from hand-editing `.pbxproj` and weeping in merge conflicts.
- [Nick Lockwood](https://github.com/nicklockwood), author of [SwiftFormat](https://github.com/nicklockwood/SwiftFormat). Keeps my codebase from looking like it was written by seven different people on seven different keyboards.
- [JP Simard](https://github.com/jpsim), creator of [SwiftLint](https://github.com/realm/SwiftLint), the linter that enforces my `.swiftlint.yml` on every commit.
- [Mathieu Dubart](https://github.com/MathieuDubart), builder of [SwiftSonic](https://github.com/MathieuDubart/SwiftSonic) and [Cassette](https://github.com/MathieuDubart/Cassette). Bòcan's entire Subsonic / Navidrome / Airsonic stack rides on SwiftSonic; without it, talking to OpenSubsonic servers would be a hand-rolled mess.
- [Tsiry Sandratraina](https://github.com/tsirysndr), builder of [Rocksky](https://github.com/tsirysndr/rocksky). The third leg of Bòcan's scrobbling stool, alongside Last.fm and ListenBrainz.

