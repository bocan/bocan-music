# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Scope: the `Metadata` module. For the build system, the module DAG, and commit conventions, see the root `CLAUDE.md`.

## What this module owns

Reading and writing audio-file tags, cover art, and lyrics.

- `TagReader.swift` / `TagWriter.swift` are the Swift API. They sit on top of a thin Objective-C++ bridge to **TagLib** in `Sources/TagLibBridge/` (`BocanTagLib.mm` plus `include/BocanTagLib.h`), declared as a separate C++ target in `Package.swift`.
- `TrackTags.swift` is the value type carried across the bridge. `CoverArtExtractor.swift` pulls embedded artwork. `LRCParser.swift` / `LyricsDocument.swift` parse synced/unsynced lyrics. `ReplayGain.swift` reads/writes loudness tags.

## Things easy to get wrong

- **TagLib is a Homebrew dependency** linked through hard-coded include/lib paths in `Package.swift` (`/opt/homebrew/.../taglib`). `brew install taglib` must be present; `make test-metadata` builds the bridge against it.
- **The bridge is the only C++/ObjC++ in the module.** Keep Swift-side logic out of `BocanTagLib.mm`; it should marshal to/from `TrackTags` and call TagLib, nothing more.
- **An empty `coverArt` array means "delete the embedded art".** `writeTagsToPath` always calls `setComplexProperties("PICTURE", …)`, even with an empty list, so callers that want to preserve art must include it. Do not reintroduce a `count > 0` guard.
- **Strip a leading UTF-8 BOM before parsing LRC.** `.whitespaces` does not include U+FEFF, so a BOM-prefixed first timestamp would otherwise be dropped. Writes are atomic (temp file then move), verified by the round-trip tests.
- Test fixtures (sample audio files) are checked in under the module's `Tests`; do not generate them at test time.

## Testing

Run `make test-metadata` from the repo root before committing any change to this module. If you first ran a narrower check (a single `swift test --filter` under `Modules/Metadata`, or `make test-coverage`), run `make test-metadata` last so the full module suite is the final gate before the commit.
