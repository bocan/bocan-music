# Changelog

All notable changes to Bòcan are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0](https://github.com/bocan/bocan-music/compare/v1.0.1...v1.1.0) (2026-05-16)


### ### Added

* **build:** re-establish macOS 15 Sequoia compatibility
* **audio:** add MP2/MP1, AC-3, DTS, WMA, Wave64, RF64, Matroska, AU support ([5850066](https://github.com/bocan/bocan-music/commit/58500664c2399701589042ea3a9ee05520dd8e56))


### ### Fixed

* **lint:** wrap long FFmpeg format string, extract sync-word checks to reduce cyclomatic complexity ([480e5de](https://github.com/bocan/bocan-music/commit/480e5deaac087286faf19c5a7552948915084323))

## [1.0.1](https://github.com/bocan/bocan-music/compare/v1.0.0...v1.0.1) (2026-05-15)


### ### Fixed

* **ui:** debounce FSEvents watcher reloads to prevent cascade ([8563099](https://github.com/bocan/bocan-music/commit/8563099c21bcf19143a59ab0ad283e805b698ca9))
* **ui:** pre-mark year as edited when file stores a full date string ([b0f14db](https://github.com/bocan/bocan-music/commit/b0f14db0dd299cae6ab81e0aa811ac517a273a3c))
* **ui:** reduce spectrum bars top padding from 12 to 4 points ([74bce4c](https://github.com/bocan/bocan-music/commit/74bce4cd94ce4302c88818194432be4fce9d6a9c))

## [1.0.0](https://github.com/bocan/bocan-music/compare/v0.12.0...v1.0.0) (2026-05-13)


### ⚠ BREAKING CHANGES

* release v1.0.0

### ### Added

* release v1.0.0 ([ef27d43](https://github.com/bocan/bocan-music/commit/ef27d43021cff65c499258fa3df1ea693052fddc))
* **ui:** add read-only track info floating panel ([353b7e5](https://github.com/bocan/bocan-music/commit/353b7e5291d08b56b0e38bba47f233499c21edfd))
* **ui:** complete keyboard focus phase — settings nav, sheet focus restore, tests ([71045b7](https://github.com/bocan/bocan-music/commit/71045b79c9f981c34f3b11f11dd787076bf9835d))
* **ui:** Dynamic Type support — semantic fonts, @ScaledMetric grid, NSTableView cell fonts ([4467185](https://github.com/bocan/bocan-music/commit/4467185ec63c43f417bace1c6359dfb4c80b181b))
* **ui:** keyboard focus — album grid arrow nav, transport focusSection, scrubber a11yValue ([5d85ca3](https://github.com/bocan/bocan-music/commit/5d85ca30f685257686bfe73ed5c8c296ccfd703c))
* **ui:** replace Help Viewer with in-app Help and Notices windows ([3ca7a80](https://github.com/bocan/bocan-music/commit/3ca7a803fc4e30783ccac0fa57a24685d7722ba6))
* **ui:** respect Reduce Motion — freeze visualiser, instant track transitions ([c1d9eb7](https://github.com/bocan/bocan-music/commit/c1d9eb7eb0b55e1556ad852423693e4da707ec02))
* **ui:** respect Reduce Transparency — solid backgrounds for mini-player, strip, lyrics ([0e7bbb4](https://github.com/bocan/bocan-music/commit/0e7bbb4da8990db20186ad32a7ad9a5f35292a1d))
* **ui:** VoiceOver support — row labels, live track announcements, combined album cells ([7eb709c](https://github.com/bocan/bocan-music/commit/7eb709c14034fb9b5777c5a7910025cd97bc9df8))
* **ui:** warm light-mode backgrounds from cold white to cream/linen ([0faa95e](https://github.com/bocan/bocan-music/commit/0faa95e3ff243cfeb173982480d2661a3e78b393))
* **ui:** WCAG AA colour contrast audit and token adjustments ([8d4ec14](https://github.com/bocan/bocan-music/commit/8d4ec147066accfb66d475161bdeea9f409b0a56))
* **ui:** wire native Help Book — move to Bocan.help bundle, replace GitHub fallback ([b82acec](https://github.com/bocan/bocan-music/commit/b82acecef9ad51f649972365a073d33793889e4f))


### ### Fixed

* **ci:** guard Sparkle steps, point DMG at export/ directly ([8e25bac](https://github.com/bocan/bocan-music/commit/8e25bac71bf668b489a44d49a6fd98945fd9e79b))
* **metadata:** use stable taglib opt symlink instead of versioned Cellar path ([5662434](https://github.com/bocan/bocan-music/commit/5662434599238417585f83328e916695caf98f5b))
* **playback:** lower activate() Task priority to .default to silence GRDB QoS inversion warning ([2e5be75](https://github.com/bocan/bocan-music/commit/2e5be7587e0f157baaad055dc28ba4ab0cde9f3d))
* **test:** tighten VisualizerViewModel performance toast timing ([305084d](https://github.com/bocan/bocan-music/commit/305084ded35dcb3754379fbd7ee28fe57a0d7ed8))
* **ui:** consolidate toggleLovedForNowPlaying into Rating extension ([3255859](https://github.com/bocan/bocan-music/commit/32558594bfeb4f6218fcae26a9eaf0c523da0c99))
* **ui:** fix DSP settings layout — use safeAreaInset for segmented picker header ([030dca1](https://github.com/bocan/bocan-music/commit/030dca1e5976b26c9cd753f4a2aa8e6c2152803c))
* **ui:** move DSP section picker into toolbar principal slot ([f4e60b6](https://github.com/bocan/bocan-music/commit/f4e60b65c9d6277abafb41402c29e7cc5cbb48fa))
* **ui:** push fullscreen visualizer overlay below traffic-light buttons ([33daa34](https://github.com/bocan/bocan-music/commit/33daa340fe1bc39ce53bf5500f8c7801394b7f23))
* **ui:** remove focusable TabView causing blue focus ring; increase Settings minHeight to 415 ([88c4c6e](https://github.com/bocan/bocan-music/commit/88c4c6ecdd7f53dde3970289120843cb6d315cac))
* **ui:** remove grey toolbar bar from mini-player window ([46a5fca](https://github.com/bocan/bocan-music/commit/46a5fca4ef0310e4703d440a8019366d568c952a))
* **ui:** remove iOS min-touch-target frames from playbar — restores icon density ([c0cd107](https://github.com/bocan/bocan-music/commit/c0cd1072b6ff287c87f4cf36e0564bb9564758db))
* **ui:** render About Third-Party Notices as HTML; extract shared NoticesHTMLView ([6310289](https://github.com/bocan/bocan-music/commit/63102896a64cd4c20a88c08b21204b4f102f8ed2))
* **ui:** render Notices & Licences window as HTML — headings, links, bold ([def4690](https://github.com/bocan/bocan-music/commit/def4690df6fe009a53ee0df791fc25819dee70f8))
* **ui:** resolve Swift 6 concurrency errors in AirPlayButton.Coordinator ([eed641f](https://github.com/bocan/bocan-music/commit/eed641f80b790e0d4e945735bec91d22d2490162))
* **ui:** restore original transport icon sizes — 24pt play, 18pt prev/next, 15pt secondary ([09be29c](https://github.com/bocan/bocan-music/commit/09be29cb30f4475417a7ebc96146fd152b734e9d))
* **ui:** silence IUO coercion warning — explicitly unwrap NSApp in accessibility post ([94f7f43](https://github.com/bocan/bocan-music/commit/94f7f43a42c7942695516f1f80f387b99a709283))
* **ui:** silence swiftlint violations — file/type length, force_unwrap, multiline_arguments ([e39a5c0](https://github.com/bocan/bocan-music/commit/e39a5c024f6a382e309af89731f1eba2b5f24967))
* **ui:** split DSP & EQ into three separate Settings tabs ([a81132f](https://github.com/bocan/bocan-music/commit/a81132f66106d2dfbab2af4142a586e0d094af6f))

## [0.12.0](https://github.com/bocan/bocan-music/compare/v0.11.0...v0.12.0) (2026-05-12)


### ### Added

* **ui:** add album context menu in Artist view (play, gapless, shuffle, get info, remove) ([a2557ce](https://github.com/bocan/bocan-music/commit/a2557ce207b6b6af4efb4d2b47b8cd0085eb61d2))
* **ui:** add Composer, BPM, Key, Bit Depth, Channels, Lossless, Skips, Last Played, File Size, Date Modified columns (hidden by default) ([4d565a7](https://github.com/bocan/bocan-music/commit/4d565a7bc6ec3cf64a818b6f9b02f644d95b69a0))
* **ui:** add Disc and Discs columns to track table (hidden by default) ([a47e29b](https://github.com/bocan/bocan-music/commit/a47e29b0747d28b40d6e2453a56ee99da8b564f2))
* **ui:** add song counts to Artists list and detail section headers ([9aab293](https://github.com/bocan/bocan-music/commit/9aab2938973d1984b1866b16efdfe4ea70c81856))


### ### Fixed

* **audio:** correct gapless position bar by tracking per-track sample offset ([2b47ceb](https://github.com/bocan/bocan-music/commit/2b47ceb95b0dec12e45cd604ceee0cbef5ab7df2))
* **ci:** split AudioEngine to pass file_length lint; fix ArtistsViewModel syntax ([b5a638c](https://github.com/bocan/bocan-music/commit/b5a638ca32c90dea3ba42664b60585c38a1c5a01))
* **ui:** make DSP settings pane scrollable so all sections are accessible ([d74a59f](https://github.com/bocan/bocan-music/commit/d74a59f0f876d780434de322955ac566df54dc90))
* **ui:** preserve search query when drilling into album/artist detail ([135e663](https://github.com/bocan/bocan-music/commit/135e663a855850e2178d343d99358465910fcde8))
* **ui:** replace nested TabView in DSPSettingsView with segmented picker ([9b95b40](https://github.com/bocan/bocan-music/commit/9b95b40728d5b065652e155308cd209c311456ec))
* **ui:** show compilation albums/songs for track artists in Artists view ([09c4af3](https://github.com/bocan/bocan-music/commit/09c4af3f6872474a0c9a61d0f64ff728218e8620))

## [0.11.0](https://github.com/bocan/bocan-music/compare/v0.10.0...v0.11.0) (2026-05-11)


### ### Added

* **ui:** show song count on album cells in ArtistDetailView ([18881ef](https://github.com/bocan/bocan-music/commit/18881efe293dab1b3be17dc44af925d25918ad1f))


### ### Fixed

* **ui:** Edit Lyrics context menu now edits the right-clicked track ([f6b7135](https://github.com/bocan/bocan-music/commit/f6b7135de4608dfdd4f227ce8920b0125995ddce))
* **ui:** preserve search after delete, prune orphan albums/artists, add Remove context menus ([5bea2fc](https://github.com/bocan/bocan-music/commit/5bea2fcb55e721c821fd0389ea5fbdbf4074222a))

## [0.10.0](https://github.com/bocan/bocan-music/compare/v0.9.4...v0.10.0) (2026-05-11)


### ### Added

* **scrobble,ui:** wire loved toggle to scrobble services + add love button to play bar ([db454d5](https://github.com/bocan/bocan-music/commit/db454d59c2fbff2598aa8b9231f81002553e6e07))
* **ui:** add ♥ Loved column to track list (on by default) ([e4ab248](https://github.com/bocan/bocan-music/commit/e4ab248a311490510c73843f9dc39e8ad36af1d4))


### ### Fixed

* **sparkle:** remove channel tag from stable appcast entries ([37fec24](https://github.com/bocan/bocan-music/commit/37fec246b655ddecdf436acb6e010eefda88a54b))

## [0.9.4](https://github.com/bocan/bocan-music/compare/v0.9.3...v0.9.4) (2026-05-11)


### ### Fixed

* **ui:** add missing Foundation import in LibraryViewModel+Delete.swift ([f17b10b](https://github.com/bocan/bocan-music/commit/f17b10ba276d31ee56919633eb5969e731e474cd))
* **ui:** batch multi-select Delete from Disk with single DB reload ([14c2a54](https://github.com/bocan/bocan-music/commit/14c2a5411569d3d377d2b41a7f9bb2cf96a190e4))


### ### Changed

* **ui:** extract delete methods to LibraryViewModel+Delete.swift ([57842bd](https://github.com/bocan/bocan-music/commit/57842bded1ab8a1c227369529da24cb0600f62de))

## [0.9.3](https://github.com/bocan/bocan-music/compare/v0.9.2...v0.9.3) (2026-05-10)


### ### Fixed

* **audio:** call AudioUnitReset before zeroing EQ band gains in reset() ([fa6783b](https://github.com/bocan/bocan-music/commit/fa6783bcdbc9fa3cf3126df75b8dc03cc4b3d751))

## [0.9.2](https://github.com/bocan/bocan-music/compare/v0.9.1...v0.9.2) (2026-05-10)


### ### Fixed

* **ci:** trigger website redeploy via workflow_run instead of gh workflow run ([eafbec1](https://github.com/bocan/bocan-music/commit/eafbec1c2a29e45b77e6ecb2036035f97bc9d37d))
* **release:** strip 300dpi metadata from DMG background, stage only .app into DMG ([0cb754a](https://github.com/bocan/bocan-music/commit/0cb754a72ac30f1618667c6f394e0b5f8c999ec3))

## [0.9.1](https://github.com/bocan/bocan-music/compare/v0.9.0...v0.9.1) (2026-05-10)


### ### Fixed

* **ci:** checkout actual tagged commit on workflow_dispatch, not main HEAD ([3c8e074](https://github.com/bocan/bocan-music/commit/3c8e074c7ee8c39df34eddc3243ae33cc631c0e4))
* **ci:** switch to main before pushing appcast — detached HEAD at tag caused rejection ([e8e57b4](https://github.com/bocan/bocan-music/commit/e8e57b4570a09c8cfa35d851c571892ed6866bac))
* **release:** fix doubled edSignature in appcast, trigger website redeploy after push ([1ee7c82](https://github.com/bocan/bocan-music/commit/1ee7c829b8930d983d6186ed16698db5b8336e11))
* **release:** make appcast update unconditional — was gated on SPARKLE_ED_PRIVATE_KEY ([d12f5df](https://github.com/bocan/bocan-music/commit/d12f5df830cdd99b6225159c1669af8b372ca738))

## [0.9.0](https://github.com/bocan/bocan-music/compare/v0.8.0...v0.9.0) (2026-05-10)


### ### Added

* **app:** crash recovery via LaunchSanity sentinel and recovery banner ([#208](https://github.com/bocan/bocan-music/issues/208)) ([866e9ca](https://github.com/bocan/bocan-music/commit/866e9caf178a8e7a836c7b62538448e42e65c91d))
* **app:** single-instance enforcement via lock file and distributed notification ([#207](https://github.com/bocan/bocan-music/issues/207)) ([1b6de51](https://github.com/bocan/bocan-music/commit/1b6de51d8206de4e86c574151ddb6d8a932120cf))
* **distribution:** add PrivacyInfo.xcprivacy privacy manifest ([#211](https://github.com/bocan/bocan-music/issues/211)) ([e3fc5e8](https://github.com/bocan/bocan-music/commit/e3fc5e8d42883dfcdda4ddf75a602a1fcbd16bf4))
* **distribution:** add Sparkle EdDSA public key and SUFeedURL to Info.plist ([56c0377](https://github.com/bocan/bocan-music/commit/56c0377ac5ee94c5f9a2b765cac1b2d21e1148f6)), closes [#219](https://github.com/bocan/bocan-music/issues/219)
* **distribution:** branded DMG background and volume icon ([#212](https://github.com/bocan/bocan-music/issues/212)) ([b7044eb](https://github.com/bocan/bocan-music/commit/b7044eb8977fdefbd615df4cc714996f68ee0966))
* **distribution:** deploy appcast.xml to bocan.app on release ([#216](https://github.com/bocan/bocan-music/issues/216)) ([9bdd554](https://github.com/bocan/bocan-music/commit/9bdd554adb2feeec2721156d4aabad8a2789ce35))
* **ui:** add third-party credits and Notices & Licences menu item ([#210](https://github.com/bocan/bocan-music/issues/210)) ([f626da3](https://github.com/bocan/bocan-music/commit/f626da3421c7b06bf65f5d3b412fea4c895fcf93))
* **ui:** wire About window and Check for Updates button ([#206](https://github.com/bocan/bocan-music/issues/206)) ([e86a115](https://github.com/bocan/bocan-music/commit/e86a115c80f16c1f60c4731d1e6f287322951863))
* **updates:** integrate Sparkle 2 — dependency, UpdateController, menu item ([87fce62](https://github.com/bocan/bocan-music/commit/87fce620e6f76d50a8741c9d74120c339f3e72ec)), closes [#205](https://github.com/bocan/bocan-music/issues/205)


### ### Fixed

* **distribution:** use CURRENT_PROJECT_VERSION for CFBundleVersion ([1c74b93](https://github.com/bocan/bocan-music/commit/1c74b93664a36d5115204e19d6d7f0c27ab2d1e1)), closes [#217](https://github.com/bocan/bocan-music/issues/217)
* **lint:** resolve force-unwrap and line-length violations ([512a649](https://github.com/bocan/bocan-music/commit/512a649d86a5c23f0e2ec1c7a1f2fc2b5a928d36))
* **lint:** shorten fatalError message to survive swiftformat collapse ([3afda99](https://github.com/bocan/bocan-music/commit/3afda99e7e95d6536b30600852d8d72b68d69b48))
* **observability:** crash reporter — consent, disk writes, path redaction, report viewer ([#209](https://github.com/bocan/bocan-music/issues/209)) ([0f4f93b](https://github.com/bocan/bocan-music/commit/0f4f93ba399213225a9b236e82cea7a8f55508ad))
* **ui:** inject toastDismissalDuration to eliminate 6-second flaky test ([dcb5e78](https://github.com/bocan/bocan-music/commit/dcb5e7846d8e53ed3d601e3d4f07a7a980908159))
* **updates:** wire Sparkle product to Bocan target in project.yml ([237f713](https://github.com/bocan/bocan-music/commit/237f71350a32261d6a4bbc6dcb60b230838f9d31))

## [0.8.0](https://github.com/bocan/bocan-music/compare/v0.7.0...v0.8.0) (2026-05-10)


### ### Added

* playlist import/export fixes, routing teardown, dock menu, and Phase 16 audit ([ed8129b](https://github.com/bocan/bocan-music/commit/ed8129b6d8091c9d7474da8293fba478c9c11081))
* **ui:** add 'Choose Audio Output…' menu item with ⌘⇧U shortcut ([#202](https://github.com/bocan/bocan-music/issues/202)) ([5893fe5](https://github.com/bocan/bocan-music/commit/5893fe5d7ebf9521fda91f945f805760251a9a6f))
* **ui:** dock right-click menu, play/pause badge, and album-art preference ([06a14a2](https://github.com/bocan/bocan-music/commit/06a14a2eb408f62b9461097440655d3cd5695765))
* **ui:** route dropped playlist files to importer instead of scanner ([257df06](https://github.com/bocan/bocan-music/commit/257df06c86a145d18b4eef2af283a3227dd6ed11)), closes [#188](https://github.com/bocan/bocan-music/issues/188)


### ### Fixed

* **app:** cleanly shut down routing subsystem on app termination ([d5cc1ff](https://github.com/bocan/bocan-music/commit/d5cc1ff719c930665f1e1c5818f1b671a22d48f7))
* **audio-engine:** attach EQUnit node to AVAudioEngine in tests ([9207b3e](https://github.com/bocan/bocan-music/commit/9207b3ebf7e18b259ba082e1caa6a53cd0464048))
* **ci:** use workflow_dispatch tag input for GitHub Release tag_name ([560243a](https://github.com/bocan/bocan-music/commit/560243ab9615c0cebcb529673ccf0ba2501a3b0e))
* **library,persistence:** add step 3 filename-only fallback to TrackResolver ([33b2599](https://github.com/bocan/bocan-music/commit/33b259977b007c5fee54361f775d54acfd315dc4)), closes [#196](https://github.com/bocan/bocan-music/issues/196)
* **library,playback:** wire CUE sheet import and honour start/end offsets ([868ad25](https://github.com/bocan/bocan-music/commit/868ad254b52e924c46aa441f55601b5475d3e472)), closes [#192](https://github.com/bocan/bocan-music/issues/192)
* **library,ui:** populate matched/missed counts in import preview ([e25e881](https://github.com/bocan/bocan-music/commit/e25e881b613d13546be7dac907d98be0a62253d5)), closes [#194](https://github.com/bocan/bocan-music/issues/194)
* **playback:** properly store and remove CoreAudio HAL listener blocks ([#200](https://github.com/bocan/bocan-music/issues/200)) ([54191e4](https://github.com/bocan/bocan-music/commit/54191e49c625e8ed02b601902f0d808e1f6142ce))
* **ui:** add accessibility labels and help tooltips to import/export sheets ([d28ab2f](https://github.com/bocan/bocan-music/commit/d28ab2f84cfcc09a75a8324d1b25367ef11f1629)), closes [#197](https://github.com/bocan/bocan-music/issues/197)
* **ui:** localize ActiveRouteChip strings via xcstrings ([1e24c89](https://github.com/bocan/bocan-music/commit/1e24c89139a61af79f2c6e1ec6b82dc30ca93a2d))
* **ui:** replace runModal() with async panel.begin in import/export sheets ([dfea923](https://github.com/bocan/bocan-music/commit/dfea923c50218ec2fb6cfbda269c3a800a68edd8)), closes [#187](https://github.com/bocan/bocan-music/issues/187)

## [0.7.0](https://github.com/bocan/bocan-music/compare/v0.6.0...v0.7.0) (2026-05-09)


### ### Added

* **scrobble:** add pending indicator to transport strip ([#175](https://github.com/bocan/bocan-music/issues/175)) ([38b6dd1](https://github.com/bocan/bocan-music/commit/38b6dd17190af486f12f1e4350a8ee438fc29fde))
* **scrobble:** add Show Recent Scrobbles menu item and keyboard shortcut ([#176](https://github.com/bocan/bocan-music/issues/176)) ([f56c484](https://github.com/bocan/bocan-music/commit/f56c48446dbb4812005c64baa8ad6dcf6445946f))
* **scrobble:** implement RecentScrobblesView ([#174](https://github.com/bocan/bocan-music/issues/174)) ([5a120c3](https://github.com/bocan/bocan-music/commit/5a120c34561f353a7188678c0d4a63d95e924510))
* **ui:** add drag-to-resize handle to VisualizerPane ([#168](https://github.com/bocan/bocan-music/issues/168)) ([5c57be3](https://github.com/bocan/bocan-music/commit/5c57be35557b0ddf00c1ccb5536f4edda91730d2))
* **ui:** add now-playing overlay to visualizer pane and fullscreen ([#169](https://github.com/bocan/bocan-music/issues/169)) ([fea3627](https://github.com/bocan/bocan-music/commit/fea36271f6d9a65899391fd84f0ce90c1c4afa6f))
* **ui:** auto-simplify visualizer mode on sustained FPS drop ([#172](https://github.com/bocan/bocan-music/issues/172)) ([15134b1](https://github.com/bocan/bocan-music/commit/15134b18109e79dfa0ea4e03a005e85311f2e63b))
* **ui:** multi-display screen picker for fullscreen visualizer ([#171](https://github.com/bocan/bocan-music/issues/171)) ([94f9947](https://github.com/bocan/bocan-music/commit/94f99479c02f9e709651b00885b8b474c08bbff2))
* **ui:** remove Fluid Metal visualizer ([fe50923](https://github.com/bocan/bocan-music/commit/fe5092370d03d66cbc837916889a5c3bcad0a73d))
* **ui:** show lyrics source badge in pane header ([eadc958](https://github.com/bocan/bocan-music/commit/eadc95813dfe8251661094dddb467030b141bec8))


### ### Fixed

* **audio:** bypass EQ at Flat preset; skip redundant ramp tasks ([d38dc5d](https://github.com/bocan/bocan-music/commit/d38dc5dee6ba6c76d7b7b6950d7b2201c1098624))
* **audio:** bypass TimePitch at unity rate by default; add pump starvation logging ([75b9770](https://github.com/bocan/bocan-music/commit/75b977053f784bcb8d53839b92af1508c9852e14))
* **audio:** eliminate CoreAudio render-thread pops + community health files ([978c0ad](https://github.com/bocan/bocan-music/commit/978c0ad30f2af66f65d66a534547bf0d86a67867))
* **audio:** eliminate render-thread overhead and IIR pop sources ([7bade91](https://github.com/bocan/bocan-music/commit/7bade91c1c42eb6f19cc92ec2ef28c56209d112f))
* **audio:** ensure each spectrum bar reads unique FFT bins ([902c9df](https://github.com/bocan/bocan-music/commit/902c9dfb64c8e6ba711b1f75eaa7158e9afc1e3e))
* **audio:** increase I/O buffer size to 1024 frames for pop resilience ([1b398e6](https://github.com/bocan/bocan-music/commit/1b398e6eb0420d451c02095070eff45ff4fedb43))
* **audio:** suppress file_length lint violation in AudioEngine.swift ([f751bfb](https://github.com/bocan/bocan-music/commit/f751bfbb93018536557a72237ce71187172d4391))
* **library:** pass resolved album title to LRClib fetch ([218f01a](https://github.com/bocan/bocan-music/commit/218f01ab1f0df6d2bd244b695ff785e24e0e433d))
* **playback:** honour startingAt when shuffle is enabled ([a317121](https://github.com/bocan/bocan-music/commit/a317121b00240ea12608011ed7fcbfa12c898e54))
* **playback:** strip BookmarkBlob from queue persistence payload to prevent audio pops ([255d7a8](https://github.com/bocan/bocan-music/commit/255d7a84b3431d4fec30a0d231827d51d969782a))
* **ui:** add .help() tooltips and .accessibilityHint to ScrobbleSettingsView ([105363d](https://github.com/bocan/bocan-music/commit/105363d56a659744105063adfc87068a7408609f))
* **ui:** add .help() tooltips and full accessibility labels to font size picker ([d5381c1](https://github.com/bocan/bocan-music/commit/d5381c10df742699f4770aca9bc2eff0bd3d5146))
* **ui:** add accessibility labels and tooltips to ConnectSheet ([bd43b60](https://github.com/bocan/bocan-music/commit/bd43b6008cd603faa550dd3e1a739ee2fce25785))
* **ui:** add lyrics actions to context menu and menu bar ([c26c692](https://github.com/bocan/bocan-music/commit/c26c692b3452e4b579a4e1a73bcec5fbf9acb391))
* **ui:** add lyrics sync-offset slider to pane header ([f3d878f](https://github.com/bocan/bocan-music/commit/f3d878fa6cf084f6ca8fa0c817ed460de627ff8f))
* **ui:** add manual LRClib fetch and replace-lyrics buttons ([a99e3db](https://github.com/bocan/bocan-music/commit/a99e3db2fb8b3470a9ba72dd53c8342a6d5f92b2))
* **ui:** correct Edit Lyrics tooltip shortcut hint in pane header ([a89c3cd](https://github.com/bocan/bocan-music/commit/a89c3cd3ab27a422ed4387e5ea052cbcac1611cd))
* **ui:** detect LRC format when saving editor lyrics ([7f1da9e](https://github.com/bocan/bocan-music/commit/7f1da9e6716321aed26c170d379f4f21a2f10fcb))
* **ui:** fix Fluid Metal particle physics — correct bass direction, add ambient turbulence ([9432d9c](https://github.com/bocan/bocan-music/commit/9432d9c70d4757ff5a791f26e28e0205561b8b6f))
* **ui:** fix visualizer disconnect after track changes and size flutter ([c352c6e](https://github.com/bocan/bocan-music/commit/c352c6ea660826ec82afc0d985aa75b79692e82f))
* **ui:** make Fluid Metal audio reactivity direct and eliminate 30s burst ([84c1ed2](https://github.com/bocan/bocan-music/commit/84c1ed268a7c318e7fda9de50fae2a03ed1664c1))
* **ui:** observe lyricsVM and visualizerVM in BocanCommands so menu labels update ([7f5cf71](https://github.com/bocan/bocan-music/commit/7f5cf71143d2d0f9923e1b196b82ec0f3e4998b2))
* **ui:** ref-count tap so closing fullscreen doesn't disconnect pane audio ([1ecf01a](https://github.com/bocan/bocan-music/commit/1ecf01aa1e02f6bfdd05da4c01d47b64f30e9e43))
* **ui:** remove ignoresSafeArea from VisualizerHost black fill ([e03d212](https://github.com/bocan/bocan-music/commit/e03d2129074c702754b44bd7a51e2c2be7f0cd85))
* **ui:** require confirmation before deleting lyrics in editor sheet ([f131e9e](https://github.com/bocan/bocan-music/commit/f131e9e4cbe3d5350b9758e5fdf7a3dc0c1e0434))
* **ui:** show spinner instead of empty state while fetching lyrics ([a48449f](https://github.com/bocan/bocan-music/commit/a48449fb91cdc62079136d9b83433ae5bf452b95))
* **ui:** split lyrics pane header into two rows, add drag-to-resize handle ([9b4fc61](https://github.com/bocan/bocan-music/commit/9b4fc619190c75895d10d20d97c54064db1460ac))
* **ui:** stop 60fps menu rebuilds from causing audio pops ([902c9df](https://github.com/bocan/bocan-music/commit/902c9dfb64c8e6ba711b1f75eaa7158e9afc1e3e))
* **ui:** stop Fluid Metal particles when no audio is playing ([642ccbb](https://github.com/bocan/bocan-music/commit/642ccbb72958b9ad4a3e809f5ceb0194a7d175bc))
* **ui:** unify lyrics font-size AppStorage key ([6927e13](https://github.com/bocan/bocan-music/commit/6927e1388d5c8451c54eccc7592b3aff3a8c54f3))
* **ui:** use IOKit power source for battery detection in VisualizerViewModel ([#170](https://github.com/bocan/bocan-music/issues/170)) ([befa8c3](https://github.com/bocan/bocan-music/commit/befa8c309df53698c5c282257a08e20c5eb32806))
* **ui:** wire audio analysis into Fluid Metal renderer each display tick ([050daa3](https://github.com/bocan/bocan-music/commit/050daa3606a39d70a04b54cac313a85efc327d98)), closes [#167](https://github.com/bocan/bocan-music/issues/167)
* **ui:** wire lyrics pane search bar to LyricsView filtering ([ad01607](https://github.com/bocan/bocan-music/commit/ad01607eb79982f438fcefb2580207b3aaa601d6))


### ### Changed

* **audio:** split AudioEngine.swift into extension files to fix file_length lint ([d6942b8](https://github.com/bocan/bocan-music/commit/d6942b86c0cc569e4088dc49bdad574d2bfaf71b))

## [0.6.0](https://github.com/bocan/bocan-music/compare/v0.5.1...v0.6.0) (2026-05-07)


### ### Added

* **app:** prompt before quit when scan or RG analysis is active ([321ceb4](https://github.com/bocan/bocan-music/commit/321ceb45b604cfa06d2ef0ed382cdb2587a6d909))
* **persistence,ui:** add local backup with configurable rolling count ([4e0c879](https://github.com/bocan/bocan-music/commit/4e0c879ef1d7bcc26a4f61cd26ed718bb412c469))
* **persistence,ui:** wire iCloud backup toggle into Advanced Settings ([2a15615](https://github.com/bocan/bocan-music/commit/2a156157cfad8d9a18d6a7c62274d34fea024eb0))
* Phase 10 polish — mini player, quit guard, iCloud & local backups ([0c5d06e](https://github.com/bocan/bocan-music/commit/0c5d06e49f56ba3d6f4335e88d22fced83a4250f))
* **ui:** add collapse/expand toggle to Playlists sidebar section ([d6ef432](https://github.com/bocan/bocan-music/commit/d6ef432736f581fbdc67859c7a2f9afde716b246))
* **ui:** add LoadingState and ErrorState reusable views ([#145](https://github.com/bocan/bocan-music/issues/145)) ([812feda](https://github.com/bocan/bocan-music/commit/812fedae7284bf4e46a90d14c123e59cba7009d8))
* **ui:** implement MarqueeText scrolling for Mini Player and menu-bar extra ([1e5e36f](https://github.com/bocan/bocan-music/commit/1e5e36f2c90a597fa177f218ade6b1cefd098cf4)), closes [#138](https://github.com/bocan/bocan-music/issues/138)
* **ui:** show scanning progress pane during initial library scan ([854a18e](https://github.com/bocan/bocan-music/commit/854a18e2efdad52cdc746c653ed8efdec54a9867))
* **ui:** spring-animate mini player layout transitions ([ecbed96](https://github.com/bocan/bocan-music/commit/ecbed961115d3932e05cd37e49fdac6be4c41119))


### ### Fixed

* **audio:** prevent pops from VFS contention and CPU bursts at playback start ([c12c1ce](https://github.com/bocan/bocan-music/commit/c12c1ce547f0e91074cce5f27092ccdfe2f764b1))
* **persistence:** use requiresWriteAccess to avoid WAL snapshot deadlock ([c6fda5e](https://github.com/bocan/bocan-music/commit/c6fda5ea61bb1a810b02dccbba5c6200ea32d56a))
* **ui:** call windowMode.restoreIfNeeded() on launch to honour restore-last-mode setting ([dc2a3f1](https://github.com/bocan/bocan-music/commit/dc2a3f18b4d32398c423e17fe1cc093e3f920025)), closes [#139](https://github.com/bocan/bocan-music/issues/139)
* **ui:** convert HighContrastModifier comments to doc comments for SwiftFormat ([5b36fdf](https://github.com/bocan/bocan-music/commit/5b36fdf2d0a9a506e16c128bec4f400eb82bcc45))
* **ui:** inject libraryViewModel into DSP window; remove About from Settings tabs ([6187626](https://github.com/bocan/bocan-music/commit/61876261ff463475dec1725826426230329032c9))
* **ui:** menu bar extra icon reflects playback state ([7a311fd](https://github.com/bocan/bocan-music/commit/7a311fd9f4c299e40debfba2893cb981f0e852a8)), closes [#143](https://github.com/bocan/bocan-music/issues/143)
* **ui:** strengthen separators and materials under accessibilityIncreaseContrast ([#141](https://github.com/bocan/bocan-music/issues/141)) ([66b4f0e](https://github.com/bocan/bocan-music/commit/66b4f0e5aa7cf31d93c0073c0ec9708325565798))

## [0.5.1](https://github.com/bocan/bocan-music/compare/v0.5.0...v0.5.1) (2026-05-06)


### ### Fixed

* **build:** add stable Homebrew HEADER_SEARCH_PATHS to project.yml ([a5099da](https://github.com/bocan/bocan-music/commit/a5099dab3850602a7d5748ae837ca14cd8d3d723))
* **persistence:** use .async(onQueue:main) scheduler to fix GRDB writer-queue deadlock ([a2a8575](https://github.com/bocan/bocan-music/commit/a2a85752d27eea53ad8c4e33276c12f75d5203c0))

## [0.5.0](https://github.com/bocan/bocan-music/compare/v0.4.0...v0.5.0) (2026-05-06)


### ### Added

* **ui:** add accessibilityIdentifier to all NowPlayingStrip controls ([2c20f4b](https://github.com/bocan/bocan-music/commit/2c20f4bdb4caea76214f6d857794e1f49545083f))
* **ui:** add Compute Missing ReplayGain to Tools menu ([8b43c9f](https://github.com/bocan/bocan-music/commit/8b43c9fcb18d1bfab64f00d8f74a74fd849cafd8))
* **ui:** add keyboard shortcuts for volume control (⌘↑/⌘↓) ([346178b](https://github.com/bocan/bocan-music/commit/346178b6ce838f170ccff8112d8adf8513281ed8))
* **ui:** add mute button to transport bar (⌘⌥Z) ([cc46904](https://github.com/bocan/bocan-music/commit/cc469046428e4a90c00c99ad2fb302f2e54d8077))
* **ui:** add Play Album, Shuffle Album, Play Artist to context menu and Track menu bar ([8451bbf](https://github.com/bocan/bocan-music/commit/8451bbf09c035fa0fe7dfb4ab0f13b3fb7339de5))
* **ui:** add Play Now, Play Next, Add to Queue to Track menu bar ([9a8cc0d](https://github.com/bocan/bocan-music/commit/9a8cc0d6941d84b062273912cd2e1b782b7f80fd))
* **ui:** add Playback Speed menu and keyboard shortcuts ([9f1aebb](https://github.com/bocan/bocan-music/commit/9f1aebb4cf4f371986d4cdafab40b36762209b6e))
* **ui:** add Rate submenu to track context menu; remove dead ContextMenus.swift ([2d28b80](https://github.com/bocan/bocan-music/commit/2d28b804d811a79feb2463453bc10e8fd334e4e0))
* **ui:** add Select All (⌘A) and Deselect All (⌘⇧A) to Track menu and table ([e449c60](https://github.com/bocan/bocan-music/commit/e449c60e90859c3e06e50dd8cfbcdf6edbed15c4))
* **ui:** add Sleep Timer submenu to Playback menu bar ([4a54e16](https://github.com/bocan/bocan-music/commit/4a54e16262c51bbc6fdb065caa8c62f68d26bc6c))
* **ui:** make artwork in NowPlayingStrip navigate to current album ([05a2ef6](https://github.com/bocan/bocan-music/commit/05a2ef608c36d39d121e1ac1e1e5fa1a8fdf7651))
* **ui:** make track title and artist clickable in NowPlayingStrip ([23e2a5c](https://github.com/bocan/bocan-music/commit/23e2a5c39d2b8d255ad615223f369a8b72828ca7))
* **ui:** previous button restarts track after 3 seconds (iTunes semantics) ([ff79723](https://github.com/bocan/bocan-music/commit/ff797238df61de04039eaaabefae8148df45edc8))
* **ui:** replace DSP modal sheet with non-modal floating window ([3d1650e](https://github.com/bocan/bocan-music/commit/3d1650e2c94447c693da4fe7dc40aa40d5f85042))


### ### Fixed

* **ci:** redirect codesign stderr so hardened runtime grep works ([cf03508](https://github.com/bocan/bocan-music/commit/cf035088df8799a597d321f656c629721592bda3))
* **persistence:** remove spurious await from DatabaseWriter.backup call ([c43e521](https://github.com/bocan/bocan-music/commit/c43e5215b8cc2ec700006a8491757fb1a9e640f3))
* **persistence:** set GRDB targetQueue to .userInitiated to prevent priority inversion ([43ff5b2](https://github.com/bocan/bocan-music/commit/43ff5b2c74c8b6e54d9c7784c5aa5da6212d655e))
* **scrobble:** remove spurious await from synchronous authorisationURL call ([1204638](https://github.com/bocan/bocan-music/commit/12046380c551c8375e890341a1edf34a05303db6))
* **ui:** add VoiceOver accessibility labels to track table ([b665a18](https://github.com/bocan/bocan-music/commit/b665a18aee9320f421fe57737cd3f404b5a81c64))
* **ui:** copy action now includes all visible track fields as TSV ([#98](https://github.com/bocan/bocan-music/issues/98)) ([ceff30c](https://github.com/bocan/bocan-music/commit/ceff30c3ac449e36f3925d9006c0aa35ead1451d))
* **ui:** DSP button shows persistent active state when EQ is processing ([cd159cc](https://github.com/bocan/bocan-music/commit/cd159cc75da4e4698f0bad0a121e22267dd084a2))
* **ui:** fix love context-menu label for multi-track selection ([2918bf1](https://github.com/bocan/bocan-music/commit/2918bf188bc07c16e07e3f201e2d94ea0f2d6ae5))
* **ui:** fix Swift 6 concurrency errors in MainWindowTracker.Coordinator ([603fbaa](https://github.com/bocan/bocan-music/commit/603fbaa1802ea33af45927e88bc2991e2d80a899))
* **ui:** migrate NowPlayingViewModel from ObservableObject to @Observable ([#113](https://github.com/bocan/bocan-music/issues/113)) ([e12e380](https://github.com/bocan/bocan-music/commit/e12e3802b0df28fc081e020201ccbec6b188b018))
* **ui:** migrate RouteViewModel to @Observable, remove @ObservedObject from usage sites ([9d2fb83](https://github.com/bocan/bocan-music/commit/9d2fb83c48dafd71d0960c8adccea03dff6c4886))
* **ui:** migrate TracksViewModel to @Observable to eliminate publish-during-update warnings ([b385a2b](https://github.com/bocan/bocan-music/commit/b385a2b64e2c1252f0cb20296f2f8f13fc5b2c08))
* **ui:** persist playback rate to UserDefaults and restore on launch ([636602c](https://github.com/bocan/bocan-music/commit/636602c5002594ab876847e6b32645432a3345a7))
* **ui:** remove duplicate fade-out toggle from custom sleep timer popover ([5e07473](https://github.com/bocan/bocan-music/commit/5e07473af77c2c727f3ac1b6f10848407392a5a1))
* **ui:** remove redundant as? URL cast in ArtworkEditor drop handler ([c88d72b](https://github.com/bocan/bocan-music/commit/c88d72bad0ba428f8663ff00ae8d0cdc16fa42ad))
* **ui:** replace NSAlert.runModal() with non-blocking beginSheetModal continuations ([1909661](https://github.com/bocan/bocan-music/commit/190966139b624659e6326a0d474163ddd495f8c9))
* **ui:** silence nonisolated(unsafe) warning on RouteViewModel.consumer ([693dcf8](https://github.com/bocan/bocan-music/commit/693dcf8357b922ccd2f806a899d39899abff6128))
* **ui:** use textTertiary for idle speed label instead of 0.4 opacity ([84caa5d](https://github.com/bocan/bocan-music/commit/84caa5d1a9b32a27d1ebd98d97f4a486232b6594))
* **ui:** wire Love/Unlove context menu to toggleLovedForCurrentSelection ([07e25f5](https://github.com/bocan/bocan-music/commit/07e25f55a817097862a4fa8c1ec06bcff8f1709b))
* **ui:** wire Return/Enter key to play in track table ([9ebed66](https://github.com/bocan/bocan-music/commit/9ebed66af7646a953c9a23c01a7d3e907b6743d5))

## [0.4.0](https://github.com/bocan/bocan-music/compare/v0.3.0...v0.4.0) (2026-05-04)


### ### Added

* **tests:** add DSPViewModel environment to NowPlayingStrip snapshots ([4f2c448](https://github.com/bocan/bocan-music/commit/4f2c44850735b15b7146b7dad2d1c81102ee0ddf))
* **ui:** add ⌘⌥E keyboard shortcut and menu item for EQ/DSP panel ([#94](https://github.com/bocan/bocan-music/issues/94)) ([37d314b](https://github.com/bocan/bocan-music/commit/37d314b532fbaecfacad891fb3eaa89fd43a7b6f))
* **ui:** implement per-track and per-album EQ scope picker ([#91](https://github.com/bocan/bocan-music/issues/91)) ([7a1da10](https://github.com/bocan/bocan-music/commit/7a1da10906c55b5f841383990ce76783b9333d6e))


### ### Fixed

* **audio:** flush EQ IIR delay lines before un-bypass to prevent pop ([#92](https://github.com/bocan/bocan-music/issues/92)) ([5e82403](https://github.com/bocan/bocan-music/commit/5e8240315b0f99e29cf56850d1a804d88d168506))
* **ui:** A/B compare is press-and-hold, not a toggle ([#93](https://github.com/bocan/bocan-music/issues/93)) ([fe2379d](https://github.com/bocan/bocan-music/commit/fe2379d6533c6e1217678c99d2497ed26e9d7473))
* **ui:** add full EQ/Effects/ReplayGain tabs to DSP Settings view ([#89](https://github.com/bocan/bocan-music/issues/89)) ([3bf54a4](https://github.com/bocan/bocan-music/commit/3bf54a41fc04944c6217d04bb2e01433a1657687))
* **ui:** eliminate 'publishing during view update' warnings in EQ scope picker ([#95](https://github.com/bocan/bocan-music/issues/95)) ([7b41aeb](https://github.com/bocan/bocan-music/commit/7b41aeb99d693fd20f8b7d62e395fb39eea1565c))
* **ui:** wire EQ output gain slider to preset mutation ([#90](https://github.com/bocan/bocan-music/issues/90)) ([8c18761](https://github.com/bocan/bocan-music/commit/8c187613bc00479398c8630be05933a0f5ece26d))

## [0.3.0](https://github.com/bocan/bocan-music/compare/v0.2.0...v0.3.0) (2026-05-04)


### ### Added

* **playback:** wire CrossfadeScheduler end-to-end ([#87](https://github.com/bocan/bocan-music/issues/87)) ([7a4f5ce](https://github.com/bocan/bocan-music/commit/7a4f5ceaa854e85f6211beeba4e6eb019d1a4bfd))
* **settings:** add embed cover art preference (phase-8 audit H5) ([08312f1](https://github.com/bocan/bocan-music/commit/08312f198634956e48e5d9583706ccd3447d9082)), closes [#67](https://github.com/bocan/bocan-music/issues/67)
* **ui:** add Bulk Actions section to multi-track editor (phase-8 audit H6) ([0d987b1](https://github.com/bocan/bocan-music/commit/0d987b19288ff69d9d0f1a94e4e1e528d928b748)), closes [#69](https://github.com/bocan/bocan-music/issues/69)
* **ui:** add CommandMenu("Tools") with batch cover art and duplicate finder ([ea16b84](https://github.com/bocan/bocan-music/commit/ea16b8497830fbac9eb92dcd10c8385b2cfcd9d2)), closes [#68](https://github.com/bocan/bocan-music/issues/68)
* **ui:** add Compute Replay Gain to Track menu and right-click context menu ([#88](https://github.com/bocan/bocan-music/issues/88)) ([0f99e39](https://github.com/bocan/bocan-music/commit/0f99e397fd837631bac8c05ff429f613bb82a244))
* **ui:** add explicit Tab-key focus order to tag editor Details tab ([#80](https://github.com/bocan/bocan-music/issues/80)) ([768dc7d](https://github.com/bocan/bocan-music/commit/768dc7d4c41ac3be27c2608de5167a2de6335abf))
* **ui:** add File Info and Advanced tabs to tag editor (phase-8 audit) ([ce942d0](https://github.com/bocan/bocan-music/commit/ce942d034075cb6f517f379fcc4caf83b1ec26e4)), closes [#66](https://github.com/bocan/bocan-music/issues/66)
* **ui:** add Identify Track toolbar button ([#83](https://github.com/bocan/bocan-music/issues/83)) ([cf69fab](https://github.com/bocan/bocan-music/commit/cf69fabfe31f9c87fc801cfab3710fdf0127a647))
* **ui:** add per-field apply-checkboxes for multi-track tag editing ([cc9817c](https://github.com/bocan/bocan-music/commit/cc9817c2c78d7383c9c2a19099808efe4e87a5a5)), closes [#70](https://github.com/bocan/bocan-music/issues/70)
* **ui:** detect LRC timestamps in lyrics tab, save as synced lyrics ([#74](https://github.com/bocan/bocan-music/issues/74)) ([145a6a8](https://github.com/bocan/bocan-music/commit/145a6a874c0c34d11e3f944760ab251009c775a9))
* **ui:** show conflict-resolution banner in TagEditorSheet ([#73](https://github.com/bocan/bocan-music/issues/73)) ([2bde72e](https://github.com/bocan/bocan-music/commit/2bde72e5f568895ecfe613a66dbfed9b4e799e0f))


### ### Fixed

* **app:** declare playlist-drag UTType in Info.plist, fix conflict log level ([3085d67](https://github.com/bocan/bocan-music/commit/3085d670c85175d67d4be3aafa60ad62497077c2))
* **audio:** ramp bass-boost gain/bypass to prevent audio pop ([#86](https://github.com/bocan/bocan-music/issues/86)) ([e4bb57f](https://github.com/bocan/bocan-music/commit/e4bb57fe06fda6e48e3c1d888646005eeecacbd2))
* **dsp:** improve EQ bypass transitions to prevent audible pops ([f09e2d8](https://github.com/bocan/bocan-music/commit/f09e2d88c562fffe0d10cce1d2ecce2db1a70495))
* **library:** auto-renew stale security-scoped bookmarks on resolution ([317f61c](https://github.com/bocan/bocan-music/commit/317f61cc2f4195c82adf225caa741e75a1e01517))
* **library:** hasCoverArt smart rule checks albums.cover_art_hash not tracks ([e8ab684](https://github.com/bocan/bocan-music/commit/e8ab684426ee80c7056626b00d39cc013de496d4))
* **library:** stamp fileMtime/fileSize after tag write to prevent false-positive conflict ([2340b1e](https://github.com/bocan/bocan-music/commit/2340b1e9c3c8fc5382b7ef56442b9dae9c7ff1df))
* **library:** upgrade http CAA image URLs to https to satisfy ATS ([73856a0](https://github.com/bocan/bocan-music/commit/73856a02824150737cadba20afdb9f240d83ac47))
* **playback:** fire-and-forget nowPlaying to unblock 15s playback delay ([206cd24](https://github.com/bocan/bocan-music/commit/206cd24173a4bc7a6ba69aad06f20d48676abec0))
* **ui,library:** folder-not-found flash + recurring startup conflicts ([5583df3](https://github.com/bocan/bocan-music/commit/5583df3135bd1e30ece3a41244337e6fd97e0ca8))
* **ui,library:** properly fix folder-not-found flash and conflict re-flagging ([ce4767e](https://github.com/bocan/bocan-music/commit/ce4767e92603886dc24618fa380217035c9dc246))
* **ui,persistence:** crash on playlist with duplicate track entries ([9a0fdb9](https://github.com/bocan/bocan-music/commit/9a0fdb9cebec0125564cfd0c10ef8b23cb5b64e9))
* **ui:** acquire security-scoped resource in .fileImporter completion ([#78](https://github.com/bocan/bocan-music/issues/78)) ([fa44a2f](https://github.com/bocan/bocan-music/commit/fa44a2feb20f04e945d03aac6ba9329a73fe1608))
* **ui:** add .accessibilityLabel to TextField in TagFieldRow and IntFieldRow ([#77](https://github.com/bocan/bocan-music/issues/77)) ([bb091d7](https://github.com/bocan/bocan-music/commit/bb091d7992e0058b7d8650a4f9eb83f93940b015))
* **ui:** add .help() to CandidatePickerView buttons ([#83](https://github.com/bocan/bocan-music/issues/83)) ([394d099](https://github.com/bocan/bocan-music/commit/394d099434e0c06fe730f153bc3a45eb1fb1fb74))
* **ui:** add .help() to IdentifyTrackSheet Close button ([#83](https://github.com/bocan/bocan-music/issues/83)) ([43e6a65](https://github.com/bocan/bocan-music/commit/43e6a653f2617f27b247b503a11a1af07a8d6db4))
* **ui:** add .help() tooltip to all ArtworkEditor action buttons ([#82](https://github.com/bocan/bocan-music/issues/82)) ([04d8816](https://github.com/bocan/bocan-music/commit/04d8816911ae8f56e35af11f21c3f32aa16bee16))
* **ui:** add low-confidence warning banner in CandidatePickerView ([#83](https://github.com/bocan/bocan-music/issues/83)) ([bb33629](https://github.com/bocan/bocan-music/commit/bb336291412a19e0a09adee0d781206882a1f125))
* **ui:** Edit Tags button in noMatchView opens tag editor ([#83](https://github.com/bocan/bocan-music/issues/83)) ([07730de](https://github.com/bocan/bocan-music/commit/07730de38b6223f5fbd9df9a6a4a6da346dbb097))
* **ui:** enhance PlaylistSidebarViewModel to handle missing nodes gracefully ([f09e2d8](https://github.com/bocan/bocan-music/commit/f09e2d88c562fffe0d10cce1d2ecce2db1a70495))
* **ui:** guard fieldBinding setter to prevent publish-during-render fault in lyrics tab ([05881ce](https://github.com/bocan/bocan-music/commit/05881ce8278b7549f7267a6fa3566c0cbeb5c65d))
* **ui:** observe sidebar VM in ContentPane so isLoaded triggers re-render ([90f6a34](https://github.com/bocan/bocan-music/commit/90f6a34968562f1dd58bab15f3bcd23f89bd1d61))
* **ui:** refactor TrackTable to simplify scroll view creation ([f09e2d8](https://github.com/bocan/bocan-music/commit/f09e2d88c562fffe0d10cce1d2ecce2db1a70495))
* **ui:** remove duplicate ⌘I shortcut from context menu Get Info button ([#81](https://github.com/bocan/bocan-music/issues/81)) ([d9e2f9b](https://github.com/bocan/bocan-music/commit/d9e2f9bf8ee486bc7cbc9d568bc59f3c81818397))
* **ui:** replace DispatchQueue.main.async with Task in ArtworkEditor.handleDrop ([a7b59c3](https://github.com/bocan/bocan-music/commit/a7b59c3a4a33f7f1978187d8cb1dfd11dfac36bd)), closes [#71](https://github.com/bocan/bocan-music/issues/71)
* **ui:** replace NSOpenPanel.runModal() with .fileImporter() in ArtworkEditor ([#76](https://github.com/bocan/bocan-music/issues/76)) ([b7990ed](https://github.com/bocan/bocan-music/commit/b7990edfd83c5336090f8e9f4c4f5f398e27b670))
* **ui:** streamline TrackTableCoordinator's data handling ([f09e2d8](https://github.com/bocan/bocan-music/commit/f09e2d88c562fffe0d10cce1d2ecce2db1a70495))


### ### Changed

* **ui:** inject CoverArtFetcher into TagEditorViewModel ([#75](https://github.com/bocan/bocan-music/issues/75)) ([a9cb4cb](https://github.com/bocan/bocan-music/commit/a9cb4cb70baee844b93fbe0ce4313abe9838323b))

## [0.2.0](https://github.com/bocan/bocan-music/compare/v0.1.0...v0.2.0) (2026-05-01)


### ### Added

* **acoustics:** implement phase 8.5 AcoustID fingerprinting & MusicBrainz auto-tagging ([2228b28](https://github.com/bocan/bocan-music/commit/2228b28d42008413a85c6dceba9e8a9d79b48d4d))
* **albums:** artist + track count + exclude-from-shuffle toggle ([b621b3b](https://github.com/bocan/bocan-music/commit/b621b3b6c784b5fcc3974710b959d35cfb404789))
* **app:** add BocanApp entry point, RootView, resources, and UI test scaffold ([3514516](https://github.com/bocan/bocan-music/commit/351451687da6c6ca991d21a3e0c030a756d55319))
* **app:** expand Playback menu with Next/Previous/Shuffle/Repeat/Stop-After-Current/Clear Queue/Up Next ([6fdbdab](https://github.com/bocan/bocan-music/commit/6fdbdab505d9fbb1eab77b250b177c8b47fe5e18))
* **app:** phase-2 audit fixes [#5](https://github.com/bocan/bocan-music/issues/5) + [#6](https://github.com/bocan/bocan-music/issues/6) — vacuum on quit, iCloud backup at launch ([c005e75](https://github.com/bocan/bocan-music/commit/c005e75cd504def485d685b381abb070311152ce))
* **app:** wire ⌘⇧N to File ▸ New Playlist… ([1132639](https://github.com/bocan/bocan-music/commit/1132639b8acc68ae494f48b42045d48010fcde7d)), closes [#31](https://github.com/bocan/bocan-music/issues/31)
* **audio:** add AudioEngine module and integrate into project structure ([511b965](https://github.com/bocan/bocan-music/commit/511b965d98e7f6e51ddaeaf2119bb272510c38db))
* **audio:** add AudioEngine module with AVFoundation and FFmpeg decoders ([14b98aa](https://github.com/bocan/bocan-music/commit/14b98aa976a647f330543f4650bf5ff63fb21539))
* **audio:** implement Phase 9 DSP chain — EQ, crossfeed, stereo expander, limiter, ReplayGain ([1f09183](https://github.com/bocan/bocan-music/commit/1f091832d370d4afd561a7ac549dccf5dfa13c68))
* **docs:** add post-phase checks for debugging and feature completeness ([6432d16](https://github.com/bocan/bocan-music/commit/6432d16abae80edfc09872ecce69164f374f5579))
* enable column-header sorting on full Songs library ([75ba115](https://github.com/bocan/bocan-music/commit/75ba1157367791df5c6c1cfd6f7eeb422497a651))
* **import:** add media to library — folder picker, file picker, drag-drop, scan banner ([037aa46](https://github.com/bocan/bocan-music/commit/037aa46300ebbe5bb902785761dd0b16d448c2da))
* **library,ui:** sort playlist contents by title / artist / date added ([76122c9](https://github.com/bocan/bocan-music/commit/76122c90ca6fe34bf176a159a7b9ef15e44af1d0))
* **library:** add hasLyrics smart-playlist field ([5ccac49](https://github.com/bocan/bocan-music/commit/5ccac49e2c220e1d51cbc71e647e3d26b6de46aa))
* **library:** add inLastYears smart-playlist comparator ([3b59d85](https://github.com/bocan/bocan-music/commit/3b59d850cc6328d7d30daa4d3854d6154809b3ca))
* **library:** add Library scanning module (FileWalker, ChangeDetector, TrackImporter, FSWatcher, ScanCoordinator, LibraryScanner) ([026d823](https://github.com/bocan/bocan-music/commit/026d82382eb18ab4f782733a8572006b46052b91))
* **library:** add PlaylistService with sparse-position reorder + folders ([6204bcc](https://github.com/bocan/bocan-music/commit/6204bcc649acfbcc10fbc3e3072b1903aac2a1ad))
* **library:** cap smart-playlist group nesting at 3 levels ([133eebb](https://github.com/bocan/bocan-music/commit/133eebbd2200a4c2c78ebad89fd9c6dadeecd5e3))
* **library:** debounce smart playlist observation storms ([a40fc7b](https://github.com/bocan/bocan-music/commit/a40fc7bfa7b9840d0496e4149e623b4330025bc3))
* **library:** forbid smart-playlist refs from in_playlist rules ([94712cd](https://github.com/bocan/bocan-music/commit/94712cd10304141126738ad5b8a46b6c7adcf275))
* **library:** graceful decode of unknown smart-playlist fields ([a91f345](https://github.com/bocan/bocan-music/commit/a91f345d82d74b6294115178f3f58a7793a6712c))
* **library:** implement Phase 7 smart playlists ([b7ffcca](https://github.com/bocan/bocan-music/commit/b7ffcca65a075d04f0ed128f88c3ebabf9d6800d))
* **library:** live FSEvents watcher + move sources to Settings ([54e68ed](https://github.com/bocan/bocan-music/commit/54e68edf1d29d654834b5b27091bc8f73ccec58b))
* **library:** Phase 5.5 – add/remove/rescan media, Track Inspector, force gapless per album ([f796f30](https://github.com/bocan/bocan-music/commit/f796f30b05e906ac51f377ff95f7da083b647117))
* **library:** scaffold playlist import/export (M3U, PLS, XSPF, CUE, iTunes XML) ([12adfd5](https://github.com/bocan/bocan-music/commit/12adfd57cd5233b83cc55c124ce479ea1e638fb2))
* **library:** snapshot mode for non-live smart playlists ([ea56a01](https://github.com/bocan/bocan-music/commit/ea56a01b37e6e33542559d77fc48af551f361a3e)), closes [#48](https://github.com/bocan/bocan-music/issues/48)
* **lyrics:** Phase 11 — lyrics display, editing, and LRClib fetch ([fdc3b20](https://github.com/bocan/bocan-music/commit/fdc3b20021916de7334716585665113af6d0f330))
* **metadata:** add TagLibBridge ObjC++ wrapper and Metadata Swift module (TagReader, ReplayGain, LRCParser, CoverArtExtractor) ([7f3db4f](https://github.com/bocan/bocan-music/commit/7f3db4f6f0e295a352b7a7e97fab16fc2928453c))
* **metadata:** implement full metadata editor (phase 08) ([09d5b41](https://github.com/bocan/bocan-music/commit/09d5b41cf04f73bfbe190dd46f67131dcd7bbe41))
* **metadata:** preserve raw year/date tag text ([cc4e5ed](https://github.com/bocan/bocan-music/commit/cc4e5ed402078bdf3e93ecc00fa9a870b7a460c9))
* **mini-player:** add shuffle toggle to all three layouts ([0fd3263](https://github.com/bocan/bocan-music/commit/0fd326348da39f716da3ffc7b8a40965b91195cf))
* **mini-player:** add track info button and album to compact/square layouts ([11d27b7](https://github.com/bocan/bocan-music/commit/11d27b700d999b1ef53d26769bc83961d37fcf0b))
* **mini-player:** match main player order; add repeat & stop-after toggles ([80807f4](https://github.com/bocan/bocan-music/commit/80807f46d3cfd7abeb02191362e52ef4e6203551))
* **observability:** add AppLogger, LogCategory, Redaction, Telemetry, MetricKitListener ([bd38754](https://github.com/bocan/bocan-music/commit/bd38754d9421127b42c0668e37855f7d6283c189))
* **persistence:** add M012 scrobble dead-letter, unique queue index, submissions table ([f746327](https://github.com/bocan/bocan-music/commit/f74632700b48bf18798f277dd87ed3bca331ffd0))
* **persistence:** add M013 CUE virtual-track columns ([bdfaae1](https://github.com/bocan/bocan-music/commit/bdfaae16c3d623903f3666bc54a0b37d47362042))
* **persistence:** add Persistence module with SQLite/GRDB schema, repositories, FTS, and observation ([418d965](https://github.com/bocan/bocan-music/commit/418d9659306a5379f25a85519a52e75004d7f7c5))
* **persistence:** add playlist kind + accent_color (M007) ([1ddae2b](https://github.com/bocan/bocan-music/commit/1ddae2b2915e4f774bfb262f1cd88a0111db1cc7))
* **persistence:** expose FTS search and smart-folder queries on repositories ([dc8d65b](https://github.com/bocan/bocan-music/commit/dc8d65b1de57894f9215185eb8845dac293e9abe))
* **persistence:** M002 migration — library_roots table and Track phase-3 fields ([70567b1](https://github.com/bocan/bocan-music/commit/70567b1a68b128c5d6f673279e6ac011e49746d8))
* **playback:** add Playback module — queue, shuffle, repeat, gapless, history, persistence ([07d406e](https://github.com/bocan/bocan-music/commit/07d406ec1f032b72f22240933630216d15d67386))
* **playback:** add Route, RouteManager, and CoreAudio output-device observer ([d2f06e1](https://github.com/bocan/bocan-music/commit/d2f06e15f7df4b3ead0fb8d7cdaed3971239468d))
* **playback:** expose ScrobbleSink hook from PlayHistoryRecorder + QueuePlayer ([a1ea1ca](https://github.com/bocan/bocan-music/commit/a1ea1cafbbec87b9228c9d98c429d50b05f1fb30))
* **playback:** persist and restore playback position across launches ([f0dfa32](https://github.com/bocan/bocan-music/commit/f0dfa3289af704b1d45894e47cd9cffffe3f09fc))
* **playback:** Phase 5 – stop-after-current, playAlbum/playArtist, context menus, NowPlayingTests, gapless fixtures ([1dfc97b](https://github.com/bocan/bocan-music/commit/1dfc97bde712858d02b684a8fac1eb84fe84c5d2))
* **playlists:** add smart reshuffle seed and creation-flow parity ([9ccd43a](https://github.com/bocan/bocan-music/commit/9ccd43a2fc7023df6e08cfd2fb35433ffc8ec2c6))
* **queue:** show proper title/artist/genre in Up Next; fix percent-encoded filenames ([53f9d41](https://github.com/bocan/bocan-music/commit/53f9d417323d0432aff5df8ee6742d791a470887))
* **scrobble:** add Scrobble module with rules, providers, queue worker, service ([389b2e3](https://github.com/bocan/bocan-music/commit/389b2e369a236a59b960eb7796d498116c5bbf34))
* **scrobble:** send now-playing on track start ([4a9b42a](https://github.com/bocan/bocan-music/commit/4a9b42a4d162f7d3464f0f904f99a75ac115903c))
* **settings:** add Smart Playlists preferences section ([5f7a003](https://github.com/bocan/bocan-music/commit/5f7a003b45ecfde962198ed0ec39002ac0e56a07))
* **settings:** add VSCode settings for terminal usage ([9f9c78f](https://github.com/bocan/bocan-music/commit/9f9c78faacf2798fe20f3dfed967e66e0fcd1c25))
* **smart-playlists:** implement true snapshot mode with refresh timestamp ([7ae77a0](https://github.com/bocan/bocan-music/commit/7ae77a07b4d2d0889f4ff592213b362f2c2cf9c0))
* **tracks:** improved column layout, default sort, and column persistence ([2f8bc9e](https://github.com/bocan/bocan-music/commit/2f8bc9e8355e1e902ed047a9e182efb8c2bf51cb))
* **ui:** add AirPlay route picker to now-playing strip ([6cdd9ff](https://github.com/bocan/bocan-music/commit/6cdd9ffc1bb90c588582d7f176a64689109d71b8))
* **ui:** add Sample Rate column to Songs table ([a683b8d](https://github.com/bocan/bocan-music/commit/a683b8da288223a0c8b41cf1e44c091ebeaf306a))
* **ui:** add UI module with library browser, search, and now-playing strip ([6cd1194](https://github.com/bocan/bocan-music/commit/6cd119465ffd6623c403ed554e58a487761981a1))
* **ui:** animated bouncing-bars now-playing indicator in QueueView ([02c1ce6](https://github.com/bocan/bocan-music/commit/02c1ce656755f99282b5148d5e6de956bde7022f))
* **ui:** confirmation alerts before Remove from Library / Move to Trash (Phase 5 audit) ([3795557](https://github.com/bocan/bocan-music/commit/3795557950d9f17b98aa40bf8b98b9b7dcac7d4f))
* **ui:** fire track-change notifications when app is in background ([4554240](https://github.com/bocan/bocan-music/commit/4554240c855a491717899621cb7704afc6275a28))
* **ui:** implement Phase 10 — mini player, speed control, sleep timer, settings window ([7e32d1c](https://github.com/bocan/bocan-music/commit/7e32d1caa02a848025b9c00d7fe156e1578680c5))
* **ui:** manual playlist sidebar, detail view, and creation sheets ([c8bac16](https://github.com/bocan/bocan-music/commit/c8bac167231d76e8fc601386a9feac9abf0fd5e0))
* **ui:** mini player window toggling + menu bar extra wiring ([69b68bc](https://github.com/bocan/bocan-music/commit/69b68bc799d4ca17c4856738fc14ec49f7a41844))
* **ui:** move scan progress to Library settings ([9ff67e9](https://github.com/bocan/bocan-music/commit/9ff67e967649ff14bee9967541e3d4f4e73cceae))
* **ui:** new Songs table columns and Go-to context menu ([5f3764b](https://github.com/bocan/bocan-music/commit/5f3764b9e09a2ec5e7aded8aeefd237fe5263adb))
* **ui:** per-field opt-in selection for AcoustID identify sheet ([5d6b86a](https://github.com/bocan/bocan-music/commit/5d6b86a256f69ec3f6ccf42cdd8ac0701d13c626))
* **ui:** persist expanded playlist folders in UIStateV2 ([10e92b1](https://github.com/bocan/bocan-music/commit/10e92b16a9646afe897c976a34be61a64bf5c1b1))
* **ui:** persist Songs table column customization across launches ([c968afc](https://github.com/bocan/bocan-music/commit/c968afc6ba75dd10f1042f7b533df8cdbbc36085))
* **ui:** Phase 10 polish + fix @AppStorage startup freeze ([5629308](https://github.com/bocan/bocan-music/commit/56293087c9b59affcce8cd9efd70bfbab4af53d5))
* **ui:** playlist cover art mosaic, user cover, and accent colour ([d164107](https://github.com/bocan/bocan-music/commit/d16410718b70329e63831f59b554ae097e9c2828))
* **ui:** playlist drag-and-drop reparent to folder ([05073be](https://github.com/bocan/bocan-music/commit/05073bea3239fbeb9d241c3fed723383e14451e8))
* **ui:** playlist import/export sheets and menu commands ([da10c4a](https://github.com/bocan/bocan-music/commit/da10c4abfd3e40b52806f1aa52943b6e62dfd091))
* **ui:** playlist picker for smart-playlist membership rules ([bfe35cc](https://github.com/bocan/bocan-music/commit/bfe35cc3b00bfd837607611d6ca93b106883dd82)), closes [#49](https://github.com/bocan/bocan-music/issues/49)
* **ui:** polish playlist and smart-playlist creation flows ([7d43a1b](https://github.com/bocan/bocan-music/commit/7d43a1bab3d4f1fcf40a911a591f7345a1705bd3))
* **ui:** redesign Get Info window ([f85d0a2](https://github.com/bocan/bocan-music/commit/f85d0a2a773d326c6b179625a45756686bc38dfd))
* **ui:** richer Up Next row context menu ([6fdbdab](https://github.com/bocan/bocan-music/commit/6fdbdab505d9fbb1eab77b250b177c8b47fe5e18))
* **ui:** route playlist folders to dedicated PlaylistFolderView ([a5cd060](https://github.com/bocan/bocan-music/commit/a5cd0600f81a98dee3d365168f7ed1c03f6400be))
* **ui:** scrobble settings, connect sheet, app wiring ([eb9a1a4](https://github.com/bocan/bocan-music/commit/eb9a1a4b13267d913eff2215b6dba98dee17aae2))
* **ui:** toast on Re-scan success, error sheet on failure (Phase 5.5 audit M2) ([8551904](https://github.com/bocan/bocan-music/commit/8551904715c4d0f013db1e38fce704ab5ebed02b))
* **ui:** update app name and copyright in Info.plist; add settings.local.json for permissions ([8a9a0c1](https://github.com/bocan/bocan-music/commit/8a9a0c1c545cc46e4592bb9ec09e8aa480dc02d1))
* **ui:** wire drag-reorder for manual playlist tracks ([cef2b9b](https://github.com/bocan/bocan-music/commit/cef2b9b0799c5aab10b8ab486c5f3b6fb02ab1a0)), closes [#30](https://github.com/bocan/bocan-music/issues/30)
* **ui:** wire QueuePlayer — Up Next view, transport controls, context menus ([6b788ad](https://github.com/bocan/bocan-music/commit/6b788adf162c860dce6105ccefed1078b76fcc48))
* **ui:** wire up SleepTimerMenu Custom… button ([e334587](https://github.com/bocan/bocan-music/commit/e334587d5508f49e0505b00ce595f6f4b49a95e8))
* use bundled AppIcon.icns for the app icon ([a13abfb](https://github.com/bocan/bocan-music/commit/a13abfb13102e8165d99b3421d9e01ffaa7d8161))
* **visualizer:** add fullscreen triggers — pane button + ⌘⇧F menu item ([3834313](https://github.com/bocan/bocan-music/commit/383431308ede19c82d692c8f2e1809807a740d4d))
* **visualizer:** implement Phase 12 — audio visualizer with Metal particle system ([83d25ad](https://github.com/bocan/bocan-music/commit/83d25adbbc5c18e5cc05b88d35f77720ad50d8b9))


### ### Fixed

* **acoustics:** bundle libchromaprint and add Homebrew sandbox exception ([ebab225](https://github.com/bocan/bocan-music/commit/ebab225381403bdec33a8498dca146c1bf8e542d))
* **acoustics:** correct capitalized(with:) label in titleCased helper ([d084814](https://github.com/bocan/bocan-music/commit/d084814852c6e0c55960d995c1d36cf47eff831e))
* **acoustics:** patch fpcalc rpath to resolve libchromaprint from Homebrew ([e6dc546](https://github.com/bocan/bocan-music/commit/e6dc54607521775995d3f2bce0562ad5c5c797a3))
* **acoustics:** self-contained fpcalc bundle + AcoustID bug fixes ([edd9885](https://github.com/bocan/bocan-music/commit/edd9885f2edef4e773c40bfc804df0f8d437cd98))
* **acoustics:** wire fpcalc binary, AcoustID key, and Secrets.xcconfig into build ([40d3d28](https://github.com/bocan/bocan-music/commit/40d3d288f571614c5dc05ba45ecd688c5401fef0))
* **app:** declare Local Network usage and Bonjour services for AirPlay ([cd4f57e](https://github.com/bocan/bocan-music/commit/cd4f57ee5851c0609192ced3ce04efd51592553f))
* **app:** raise Task.detached priority to .userInitiated to prevent startup freeze ([2c671f5](https://github.com/bocan/bocan-music/commit/2c671f5285412192a513d584c3f7f87a4a00d3fc))
* **app:** resolve MainActor deadlock and Swift 6 Sendability in app init ([7fa5c85](https://github.com/bocan/bocan-music/commit/7fa5c85dda8a1e3ccd297cc2570029bdc92b5439))
* **app:** stop CPU runaway and restore tracks view ([ee108a3](https://github.com/bocan/bocan-music/commit/ee108a330dafa2d671fb9f34c18bf3c24e2dc2e9))
* **audio:** add userInitiated executor to FFmpegDecoder ([9794760](https://github.com/bocan/bocan-music/commit/97947609e54d3a4716fca10443ae5eb6c3bb1794))
* **audio:** anti-pop fades, stereo-layout helper, insertion-point protocol ([0926ea5](https://github.com/bocan/bocan-music/commit/0926ea561c6ac2f8efbffb0b2606f56adbc1c75d))
* **audio:** convert AVFoundationDecoder to actor at userInitiated QoS ([0cd4c7c](https://github.com/bocan/bocan-music/commit/0cd4c7c70ee9f8eb0e041c69732a33f7df8dc059))
* **audio:** don't crash on negative frame delta in AVFoundationDecoder ([7656e70](https://github.com/bocan/bocan-music/commit/7656e70df077c3191f5c38f68d162404b855c74f))
* **audio:** fix ffError lint violations — optional_data_string_conversion, trailing_closure, file_length ([d03ad2a](https://github.com/bocan/bocan-music/commit/d03ad2ab950a057d98665465d11a947b734e793d))
* **audio:** guard empty sample input in EBUR128 and ReplayGain analyzer ([deca1b2](https://github.com/bocan/bocan-music/commit/deca1b25ed25dd994b399c8777beb6d71c478c16))
* **audio:** lower AudioEngine actor QoS to default to avoid priority inversions ([a355dae](https://github.com/bocan/bocan-music/commit/a355dae507b1745f9375e6a8844ae5bd94090cfe))
* **audio:** move playerNode reconnection before engine.prepare() ([ac205cc](https://github.com/bocan/bocan-music/commit/ac205ccf88c88931c8854702b5b5adbc1300af07))
* **audio:** reconnect full playerNode→eq→mixer chain at hardware rate ([2d9eee9](https://github.com/bocan/bocan-music/commit/2d9eee9231e825d945003487ec6037611ef10b0f))
* **audio:** reconnect playerNode at hardware rate after engine.prepare() ([89d95a6](https://github.com/bocan/bocan-music/commit/89d95a615dc4953bf3f95cadfd37c77c9e703715))
* **audio:** resample decoded buffers to hardware rate in BufferPump ([5c662d9](https://github.com/bocan/bocan-music/commit/5c662d97308decfc8ce17d958de8c50ddb744665))
* **audio:** resolve AVAudioFormat Sendable error and deprecated String(cString:) warning ([500ee34](https://github.com/bocan/bocan-music/commit/500ee34092796da8ddb2069d1ce7c531bd4fdb56))
* **audio:** resolve engine-not-running, pump deadlock, and resume judder ([01bc19a](https://github.com/bocan/bocan-music/commit/01bc19a38841f1c7600831c6b93d318ba9f3dfd8))
* **audio:** return Bool from Task closures in AudioTapTests for Swift 6 Sendable ([448a23e](https://github.com/bocan/bocan-music/commit/448a23ec516c95aae198f40410b35d1b1d450d6b))
* **audio:** silence Swift 6 Sendable-capture warning in FormatConverter ([97d3bf6](https://github.com/bocan/bocan-music/commit/97d3bf64934321ebea473ce95192e71f106ccadd))
* build errors in TrackTable + coordinator for Swift 6 strict concurrency ([639dbc4](https://github.com/bocan/bocan-music/commit/639dbc40c448a1b0b2a86469dd98bf70e676fdcf))
* **build:** bundle Resources into app, declare Library dependency ([1cf639d](https://github.com/bocan/bocan-music/commit/1cf639d82ce890075a3f15449e2f60ddcda88782))
* **build:** rewrite [@rpath](https://github.com/rpath) refs to [@loader](https://github.com/loader)_path in bundle-fpcalc script ([b48fec9](https://github.com/bocan/bocan-music/commit/b48fec9ed521a292bae4a05c29199216514a54db))
* **build:** run xcodegen generate after bundle-fpcalc ([1cc07cd](https://github.com/bocan/bocan-music/commit/1cc07cdceb5fdfd6ae51a06df2bc38ab974e2246))
* column-header sort in NSTableView TrackTable ([d43e2b3](https://github.com/bocan/bocan-music/commit/d43e2b3d36a5f0b846a434fc589cc24ffac3e67e))
* **docs:** update minimum macOS version to 26.0 (Tahoe) ([d122566](https://github.com/bocan/bocan-music/commit/d1225661b70c1cfa5e09ba4540cb0dd07429a375))
* **dsp:** equaliser band sliders now persist and update the engine ([ef51f4c](https://github.com/bocan/bocan-music/commit/ef51f4c8e5207d392adbf00395ccc36bbbf1c75b))
* **import:** resolve scan infinite spinner, [@retroactive](https://github.com/retroactive) conformances, nonisolated warning ([f3194ae](https://github.com/bocan/bocan-music/commit/f3194ae6fc778c5509a872250d7a662b49ca0028))
* **library:** allow tag editing for files added as individual roots ([32c8d49](https://github.com/bocan/bocan-music/commit/32c8d498537f7698962261c107f2074cdad7fca7))
* **library:** canonicalize symlinks via realpath in quick-scan seed ([26fe1d8](https://github.com/bocan/bocan-music/commit/26fe1d8fdc8c8fb78240ce7f7a1d87ed185ee289))
* **library:** disabled tracks disappear from FTS search; Remove From Library preserves search ([1ebc627](https://github.com/bocan/bocan-music/commit/1ebc627e8c08cc6b0098de861a70f26f7f1dafb7))
* **library:** handle unknown smart criteria enums safely ([e0237e5](https://github.com/bocan/bocan-music/commit/e0237e586245d31ccbfdecd65c3c6b49e445ea4c))
* **library:** keep security scopes active for the duration of a scan ([38ec74c](https://github.com/bocan/bocan-music/commit/38ec74c47953cad831f86d9cd2776fc4267107ad))
* **library:** link cover art to albums, not just tracks ([2fc121b](https://github.com/bocan/bocan-music/commit/2fc121bd61647bbc0da23f1f4b828dca2aca8d9a))
* **library:** phase-3 audit H6 — multi-value tags + extended_tags column ([b1cdda6](https://github.com/bocan/bocan-music/commit/b1cdda6aab40a73ae10b000033425cbea53912be))
* **library:** phase-3 audit high fixes (H1-H5, H7, H8) ([8ec8e4e](https://github.com/bocan/bocan-music/commit/8ec8e4ec6977964a562e30975697579616124704))
* **library:** phase-3 audit medium fixes (M1-M4) + L4 a11y ([cbae7fb](https://github.com/bocan/bocan-music/commit/cbae7fb6bc181f18bd63b77a0e5bfa40cdebaabc))
* **library:** re-enable user-edited tracks on rescan ([00c0bdc](https://github.com/bocan/bocan-music/commit/00c0bdc195d93cd228ddd7bf28106e570221c74d))
* **library:** register UserDefaults defaults for all @AppStorage keys ([dea4212](https://github.com/bocan/bocan-music/commit/dea42128e6f0d8af7bc18433b108eb56d72c39a5))
* **library:** remove root soft-deletes tracks; FSEvents triggers UI reload ([a921100](https://github.com/bocan/bocan-music/commit/a92110018a2ee4a3f95fffb4329000bf03d2f97d))
* **library:** repair FSWatcher event delivery; clean Library warnings ([7c1ffa5](https://github.com/bocan/bocan-music/commit/7c1ffa5012fdd3581729744cdfaac564fc758335))
* **library:** replace deprecated String(cString:); restrict ARCHS to arm64 ([6035c51](https://github.com/bocan/bocan-music/commit/6035c515c13bb8b96bc88a6e20f60de54ec72839))
* **library:** rescan security scope, disabled filter, gapless URL, inspector window ([fd31970](https://github.com/bocan/bocan-music/commit/fd319708b0f236fb234ba37033777b5da935faa9))
* **library:** scope change-detection to scanned roots only ([e4327ef](https://github.com/bocan/bocan-music/commit/e4327ef057cfeb4faa34467f2a8429ab227ff341))
* **library:** skip redundant DB reads for smart playlists; suppress cancel error ([eb17840](https://github.com/bocan/bocan-music/commit/eb17840e9bebae48738721286efe1b9eedb01a36))
* **library:** smart playlists exclude disabled tracks ([09efdca](https://github.com/bocan/bocan-music/commit/09efdcafdd3724e6c463c9447c8e4102777be122))
* **library:** Unicode-aware case-insensitive text comparators ([3d41284](https://github.com/bocan/bocan-music/commit/3d412846c9339fa475a97809844ddaa85e65decf))
* **library:** Unrated preset matches NULL and 0 ratings ([7f82670](https://github.com/bocan/bocan-music/commit/7f82670912d782f3edc7d1b37474f4e78a3864ad))
* **lint:** resolve all pre-existing SwiftLint violations ([ee9b5fa](https://github.com/bocan/bocan-music/commit/ee9b5fa807b02147e6da78f51873a61d049acd91))
* **lyrics:** move Show Lyrics to Window menu, fix LRClib bypass, implement file embed ([b4f530d](https://github.com/bocan/bocan-music/commit/b4f530d89f3416e3af86e5b19a947479f86ab0b9))
* **lyrics:** update non-goals section to clarify translation status ([547c469](https://github.com/bocan/bocan-music/commit/547c4699e82fb1f95fa0b60e511dd9a2ed88674e))
* **lyrics:** wire LRClib auto-fetch on track change ([d0d1352](https://github.com/bocan/bocan-music/commit/d0d13523d9da72b0f655e4000042b3c5946b95c6))
* **menu,lyrics:** stop menu redraw; source priority; auto-show pane ([303e584](https://github.com/bocan/bocan-music/commit/303e584bc4526a454fa308f1189331fe02c9b062))
* **menu:** extract commands to Commands struct to stop menu bar flashing ([14db0dc](https://github.com/bocan/bocan-music/commit/14db0dcbef931e3c662188ffa7d91a5bdbcd5ad7))
* **metadata-editor:** Get Info shows correct rating, loved, and excluded-from-shuffle ([f8237ed](https://github.com/bocan/bocan-music/commit/f8237edc5f06de1a0c58696a9a7027bb233db068))
* **metadata,library:** phase-3 audit critical fixes (C1, C2, C3) ([d9d409b](https://github.com/bocan/bocan-music/commit/d9d409b13db65407ca537053fad8178f45e486e5))
* **mini-player:** increase compact layout height to 130 pt ([f6dafef](https://github.com/bocan/bocan-music/commit/f6dafefc20b176cfdff112dfa31b13f921dafb38))
* **mini-player:** raise main window when info button is clicked ([fc1b012](https://github.com/bocan/bocan-music/commit/fc1b012fa06cd5c0d5c97e9f043a5c5cc9e898ef))
* **now-playing:** show current track title/artist/artwork during playback ([ef7f2df](https://github.com/bocan/bocan-music/commit/ef7f2dfbfaabe4b4ce6557de305112009d04e641))
* **observability:** remove test for MXMetricPayload which is unavailable on macOS ([c93c10d](https://github.com/bocan/bocan-music/commit/c93c10d42ba84b732db8e3baf058e94b06ddd009))
* **observability:** remove unavailable MXMetricPayload on macOS and fix OSSignpostIntervalState Sendable ([f95a01a](https://github.com/bocan/bocan-music/commit/f95a01a7132a6958a3f55ce97924ae8592813ce9))
* **persistence:** phase-2 audit fixes [#1](https://github.com/bocan/bocan-music/issues/1)–[#4](https://github.com/bocan/bocan-music/issues/4), [#6](https://github.com/bocan/bocan-music/issues/6), [#7](https://github.com/bocan/bocan-music/issues/7), [#17](https://github.com/bocan/bocan-music/issues/17) ([be6bcc9](https://github.com/bocan/bocan-music/commit/be6bcc9ecb44c413230f47b45c3a176a227b17cf))
* **persistence:** pin ValueObservation.start to non-MainActor scheduler ([13695e1](https://github.com/bocan/bocan-music/commit/13695e1e39ea3f09d9641753ab34870f028fb97d))
* **persistence:** update migration test assertions for M002 ([c9cd53c](https://github.com/bocan/bocan-music/commit/c9cd53cf93856e07385356d1e8cc4308f52763b1))
* **phase-1:** debug audio view, WavPack fixture, TSan scheme patch ([50ca5b9](https://github.com/bocan/bocan-music/commit/50ca5b93c77ec4a030642c48862703f83216f732))
* **playback:** auto-load queue item on play, root-scope fallback for nil bookmarks, play-all from library ([54f2fff](https://github.com/bocan/bocan-music/commit/54f2fffdbfceecc9af535f7b3c8e42aba33ec34f))
* **playback:** credit outgoing play on gapless handoff so it scrobbles ([454c9c2](https://github.com/bocan/bocan-music/commit/454c9c2d0ff9c82715d61686e20a2a3c7b1b88e8))
* **playback:** drop redundant 'await' on non-async engine.state access ([7bbdf3e](https://github.com/bocan/bocan-music/commit/7bbdf3e5afc130a9f041601a0d90537846a08957))
* **playback:** fallback to root bookmark when per-file bookmark is stale ([766502f](https://github.com/bocan/bocan-music/commit/766502f0958161b44bc05e3604d1a1e1f42478f6))
* **playback:** forward button, auto-repeat, gapless sandbox scope, UI sync ([7df5457](https://github.com/bocan/bocan-music/commit/7df5457a4da11639c7ff3689e25258c0244565ff))
* **playback:** guard against double-advance when gapless transition + stale .ended race ([4bc9da9](https://github.com/bocan/bocan-music/commit/4bc9da938b140dd173c92100361e876ff0071213))
* **playback:** harden bookmark fallback in QueuePlayer ([3c90c7a](https://github.com/bocan/bocan-music/commit/3c90c7a63ad981ec2afe903ddafc05998667aca2))
* **playback:** honour gapless settings and detect missing restored items ([95ac08f](https://github.com/bocan/bocan-music/commit/95ac08f5c41fd662cb345c54c5d341697cc3e4b3))
* **playback:** log stale root bookmark refresh failure instead of silencing ([8cfa1c9](https://github.com/bocan/bocan-music/commit/8cfa1c9a45208b7e509b57ff8e344cee478ee4f8))
* **playback:** pre-shuffle items before queue load so first track is random ([3475f8f](https://github.com/bocan/bocan-music/commit/3475f8f150d0079f43afa1a14c4ca69f2ed738ea))
* **playback:** prevent double-song, stale-queue, and forward-button failures ([17cbd7d](https://github.com/bocan/bocan-music/commit/17cbd7d30f7f88536fcd8db97bb29186e831f46f))
* **playback:** queue full library on track play; wire volume slider to engine ([16ff006](https://github.com/bocan/bocan-music/commit/16ff006b7a29fe600e81b4295e4265337936e7cb))
* **playback:** replace lastGaplessAdvanceItemID with timestamp settle window ([970dc4f](https://github.com/bocan/bocan-music/commit/970dc4f67d278dcddac127a96c83544390b6aa6f))
* **playback:** restart exhausted queue on play; fix 1-item queue race; fix empty symbol fault ([46a78bc](https://github.com/bocan/bocan-music/commit/46a78bc488f17e3baa9ee95a3bb6695182e1e3a0))
* **playback:** root bookmark fallback was never matching due to URL vs path comparison ([e6a80b7](https://github.com/bocan/bocan-music/commit/e6a80b7d4d969c0294ac557eb1a953df46c0625e))
* **playback:** stop queue wrapping to index 0 on forward; add now-playing indicator ([08976c6](https://github.com/bocan/bocan-music/commit/08976c64ac3bc6361ccc5a1da2b48a87dabb0511))
* **plist:** remove duplicate CFBundleIconFile key ([7ad7402](https://github.com/bocan/bocan-music/commit/7ad7402ec32a51949802db07eee9ef4834c9932a))
* prevent spurious queue.replace racing with track-end callbacks ([2f4e3cd](https://github.com/bocan/bocan-music/commit/2f4e3cd83548c1ae1df050e8306f1b4304949977))
* **project:** disable sandbox/hardened-runtime on UITests target to fix ad-hoc signing mismatch ([0039f30](https://github.com/bocan/bocan-music/commit/0039f30eaaf47a2dcb5f0a8f3e152f5653c0e762))
* **project:** update LastUpgradeCheck and MACOSX_DEPLOYMENT_TARGET values ([36cb2bd](https://github.com/bocan/bocan-music/commit/36cb2bd99c168b771eaa47d5d4d5bc7a5e61c499))
* resolve Sendable warning in FormatConverter and pause blert ([4a657cf](https://github.com/bocan/bocan-music/commit/4a657cf0465fe328d462ea18a75e101398604c67))
* run AudioEngine and BufferPump actors at user-initiated QoS ([2688f4d](https://github.com/bocan/bocan-music/commit/2688f4dbb39b1556692e172acdd2aa75d8a3aa13))
* **search:** correct reactivity, focus loss, and post-navigation state ([83fd515](https://github.com/bocan/bocan-music/commit/83fd5155b6d41206ece97c6c5e47de66bcbaaf6b))
* **search:** prefix matching per token; fix artwork frame in result rows ([a3b82ca](https://github.com/bocan/bocan-music/commit/a3b82ca250b2172b7a0d5bd4a7a37f158fcd06d4))
* **search:** stable focus via overlay; artist name + artwork in track rows ([b6d159d](https://github.com/bocan/bocan-music/commit/b6d159df29c69c72061c4d41dcf538aa69e80a43))
* **search:** use .searchable() to permanently fix toolbar focus ([0b9fa81](https://github.com/bocan/bocan-music/commit/0b9fa81e23d33a70bce6ed238b92609d95863b72))
* **smart-playlists:** show integer stepper for inLastDays / inLastMonths ([d4eac1c](https://github.com/bocan/bocan-music/commit/d4eac1c4ae818f376ba11da7ab13d1491956780a))
* speed selector 1x corruption and playlist click passthrough ([e829b39](https://github.com/bocan/bocan-music/commit/e829b3978b42857bb7635c276194cd79b50b8c2c))
* **tag-editor:** normalise artist/album FKs on save; fix cover art, reload, and UI polish ([d81e1b4](https://github.com/bocan/bocan-music/commit/d81e1b46ea720ae3613b1b79497d0cd40ad10c3c))
* **tests:** fix snapshot flakiness under --enable-code-coverage ([9ff1ef3](https://github.com/bocan/bocan-music/commit/9ff1ef32009fa1b5c73271c78e8b44117812995b))
* **tooling:** disable modifier_order lint rule to resolve SwiftFormat/SwiftLint conflict on nonisolated ([aa59730](https://github.com/bocan/bocan-music/commit/aa59730f9b289d02f1a75d67fb3bb74b934dd385))
* **tooling:** remove stale result bundle before test and add pipefail to Makefile ([c97b3c7](https://github.com/bocan/bocan-music/commit/c97b3c737576eb41b20fee7c1472337ce06679e3))
* **tracks:** bump UIState key to v2 to clear persisted addedAt sort ([f45d83c](https://github.com/bocan/bocan-music/commit/f45d83cd9319f0663a801fefcf3ba8626d6057a4))
* **ui,audio:** per-band spectrum normalization; fix UI test deps ([0ee4721](https://github.com/bocan/bocan-music/commit/0ee4721986d2e8cf4efad5422f72b42fc36da00b))
* **ui:** add @MainActor to notification delegate callbacks; add diagnostic logging ([369c02e](https://github.com/bocan/bocan-music/commit/369c02e02e05df010dd839c5f36f724d4dbc8f70))
* **ui:** add hover text and accessibility metadata for normal playlist controls ([d3dd773](https://github.com/bocan/bocan-music/commit/d3dd773bbd3648fe8a8dc9e20440073b4cd27a60))
* **ui:** add hover text and accessibility metadata for smart rule editor controls ([7f6cd5a](https://github.com/bocan/bocan-music/commit/7f6cd5a650a3021b898f3d68f1d5e030cbee1fe1))
* **ui:** announce Up Next sidebar row is also a drop target (Phase 5 audit L4) ([7671e28](https://github.com/bocan/bocan-music/commit/7671e287808483a7c8b230840f67e533212fbdcb))
* **ui:** attach playlist sheets to PlaylistSidebarSection; wire Add to Playlist menu ([6806f37](https://github.com/bocan/bocan-music/commit/6806f37c18f0343a8167c8516a2431a93b39e552))
* **ui:** clarify Add Files / Add Folder picker copy (Phase 5.5 audit L1) ([64ce199](https://github.com/bocan/bocan-music/commit/64ce1993b295a5c576c17e3739a1c527ad119a02))
* **ui:** clearer ScanBanner summary wording with locale-aware numbers (Phase 5.5 audit M1) ([535c97e](https://github.com/bocan/bocan-music/commit/535c97eaadec56c6ad811ef20a396822afa4cf0a))
* **ui:** copy artwork to temp dir before creating UNNotificationAttachment ([e6759ff](https://github.com/bocan/bocan-music/commit/e6759ff9b46f71092e808e49ce664cbd1a08bb03))
* **ui:** correct database filename in Reveal in Finder button ([8532fc8](https://github.com/bocan/bocan-music/commit/8532fc8b41c5a990634b83edeada5e60b844bb53))
* **ui:** cover art, self-load races, publishing warnings, styled artists/genres ([1622b9e](https://github.com/bocan/bocan-music/commit/1622b9e6dc11f0168d1f0ae7f6c3fefd67dc4c91))
* **ui:** currently-playing row now highlights live, drop waveform icon ([9e92952](https://github.com/bocan/bocan-music/commit/9e929523840e0bc910fcac2cd1f0c615042410c3))
* **ui:** date-based default smart playlist names with sibling collision suffix ([df25722](https://github.com/bocan/bocan-music/commit/df25722b176b4b419bef0e0dbd78ccd261da6a8e))
* **ui:** defer onDidDelete to next tick to prevent crash during sheet dismiss ([571871e](https://github.com/bocan/bocan-music/commit/571871e18bf0e1a975ad8d7ab9855c0c6abc1913))
* **ui:** defer selection publish in tableViewSelectionDidChange ([17907da](https://github.com/bocan/bocan-music/commit/17907daca3f9b0b88f810d60a1f897bd423b943e))
* **ui:** drag tracks to playlists, move-to-folder menu, confirm recursive delete ([7a44cd0](https://github.com/bocan/bocan-music/commit/7a44cd0bb70a7fbfe2ebe04e0bdd3d626650fba7))
* **ui:** finish Phase 5 queue UX (drop-on-Up-Next, opt-dbl-click, missing items) ([0e6c39d](https://github.com/bocan/bocan-music/commit/0e6c39d0a36c783417e33c7a95810779bd1254ed))
* **ui:** fix new-playlist-from-selection adding tracks and double-commit guard ([b07acc5](https://github.com/bocan/bocan-music/commit/b07acc5423c6cb1bdf22bd39c41a997ef978b57a))
* **ui:** hoist playlist sidebar sheets onto parent List ([819ceeb](https://github.com/bocan/bocan-music/commit/819ceebe6a73bc4af8114a6ffa163862bd6f994c)), closes [#63](https://github.com/bocan/bocan-music/issues/63)
* **ui:** keep Artwork strictly square regardless of image aspect ([db7fc12](https://github.com/bocan/bocan-music/commit/db7fc12bcc423e2f3087d97b7c32bb596828dd0c))
* **ui:** live watch toggle, transport hints, album multi-select & info, playlist menu ([e7bba30](https://github.com/bocan/bocan-music/commit/e7bba3072a905a51e44edcb0f7779adaed1e521f))
* **ui:** make Track menu items reactive; fix sandbox file access in tag editor ([e0afdad](https://github.com/bocan/bocan-music/commit/e0afdade7b5b33ad2ff1669c3adb2375381ae27d))
* **ui:** move Folders sidebar section below Playlists ([0f8c937](https://github.com/bocan/bocan-music/commit/0f8c9373b8eff0d2caf5d7a30d1c9569c7ec0b8e))
* **ui:** offer permanent-delete fallback when trash fails (Phase 5.5 audit M3) ([c97f22f](https://github.com/bocan/bocan-music/commit/c97f22fbf8810d2c7fe86af9d8adb9de8ac0f18e))
* **ui:** patch album in-memory instead of full reload on settings toggle ([e3d4f03](https://github.com/bocan/bocan-music/commit/e3d4f03a10df391df53b37b420ba10289238492c))
* **ui:** persist sidebar width, add Album shuffle, wire ⌘F to search ([208acb5](https://github.com/bocan/bocan-music/commit/208acb557ba094c4a908bd51d836b0d137f49608))
* **ui:** prevent hang when sorting large Songs table ([491634a](https://github.com/bocan/bocan-music/commit/491634af766f34e0e0486266d75f9f262e8af596))
* **ui:** prewarm playlist sheet host to reduce first-surface audio hitch risk ([b7ec875](https://github.com/bocan/bocan-music/commit/b7ec8752aa8b465b03062353fea9c963a4f7ce95))
* **ui:** prewarm smart playlist sheets to reduce first-mount audio hitch risk ([74ee75b](https://github.com/bocan/bocan-music/commit/74ee75b4e23060f7eba997d2ea81591a43c01502))
* **ui:** QueueRow accessibility hint + double-click activation (Phase 5 audit L5) ([c744884](https://github.com/bocan/bocan-music/commit/c7448845c556a09aeb73bcc850319efcd627c856))
* **ui:** QueueView empty state offers Add-Music-Folder on fresh install (Phase 5 audit L*) ([39602a3](https://github.com/bocan/bocan-music/commit/39602a332e7b4eb2f4878595196837c2c24aeb27))
* **ui:** re-selection dead zone, UI test window query, cheap artist track count ([fe5c40a](https://github.com/bocan/bocan-music/commit/fe5c40aadb6ce067600cfa4b12b2fff666c9795b))
* **ui:** remove .onDrag from Table cell — breaks row hit-testing ([fdb989a](https://github.com/bocan/bocan-music/commit/fdb989a08067ad7d570bb9859797c3d55217aa89))
* **ui:** remove auto-injected 'Mini Player' item from Window menu ([0e6d73c](https://github.com/bocan/bocan-music/commit/0e6d73c1e9dde5e33afb3d19baa244194dc076de))
* **ui:** remove dual-sort feedback loop in Songs table ([923bc8f](https://github.com/bocan/bocan-music/commit/923bc8f6e7673754ef85e6d6165133d2517a5406))
* **ui:** remove duplicate sidebar toggle button ([0b82126](https://github.com/bocan/bocan-music/commit/0b821260cdce3020746f348eb4679234e4628904))
* **ui:** resolve artist/album columns, file picker, playback bookmark, post-scan refresh ([6b00dfb](https://github.com/bocan/bocan-music/commit/6b00dfbf8b26f39724831ec8fb50c2a70ad5f3f0))
* **ui:** resolve menu shortcut conflicts and wire launchAtLogin ([2783eb2](https://github.com/bocan/bocan-music/commit/2783eb2ddac350f8a41e09a780dbfed95e721822))
* **ui:** row density and notification improvements ([bd7f83b](https://github.com/bocan/bocan-music/commit/bd7f83bfed95c1dc7eea37b7eed51318cd0d5e66))
* **ui:** run Songs table sort off the main actor ([6dda18b](https://github.com/bocan/bocan-music/commit/6dda18bc064b1554c8d3dc79cb889068795f5dee))
* **ui:** ScanBanner Cancel + Dismiss tooltips and a11y hints (Phase 5 audit L6) ([bba3c11](https://github.com/bocan/bocan-music/commit/bba3c1142fff4756776275ec036af679853f9171))
* **ui:** scrubber commits seek on release, not on every mouse move ([69093b6](https://github.com/bocan/bocan-music/commit/69093b61a7e4601885a8a6ac089c9a5f0fa29ad3))
* **ui:** set shuffle mode on QueuePlayer when Shuffle is pressed in SmartPlaylistDetailView ([50d1e90](https://github.com/bocan/bocan-music/commit/50d1e90ad4c0c327775af75b7468d92f11202e11))
* **ui:** simplify Songs table sort to avoid race conditions ([0972828](https://github.com/bocan/bocan-music/commit/0972828084c37cc5e07cc5bed4847b55d055f6fc))
* **ui:** SleepTimerMenu accessibility — tooltips and a11y hint (Phase 5 audit L5) ([da8104c](https://github.com/bocan/bocan-music/commit/da8104c311cc2ab3e817b4d4ceebb20b218ff4f7))
* **ui:** stop crashing on launch when seeding sidebar autosave ([7e86cec](https://github.com/bocan/bocan-music/commit/7e86ceca67d692862dfa59d70f0109cb3d466fe3))
* **ui:** use app accent palette for shuffle/repeat/stop-after buttons ([422c616](https://github.com/bocan/bocan-music/commit/422c61640f2255e437dfc6d3658b8390f86a8e9b))
* **ui:** use NSApp.appearance for theme switching to fix half-repaint bug ([a5b92cd](https://github.com/bocan/bocan-music/commit/a5b92cdee4c1f0ae215586e6de5fa67ea42fd777))
* **ui:** wire appearance settings to app UI ([2a648d8](https://github.com/bocan/bocan-music/commit/2a648d865081271111be6052e4b0d0edefa91955))
* **ui:** wire TagEditorSheet to Get Info and ⌘I ([2f4886e](https://github.com/bocan/bocan-music/commit/2f4886e6471b753f57376bb50d7e8de71286e4e1))
* **visualizer:** pass real AudioSamples to oscilloscope renderer ([78f0060](https://github.com/bocan/bocan-music/commit/78f0060d4a76040348d981b9328aae511ed0c486))
* **visualizer:** replace NSCursor.hide/unhide with setHiddenUntilMouseMoves ([bbf8079](https://github.com/bocan/bocan-music/commit/bbf8079328270dbce9314ca46f688b6564498b5f))
* **visualizer:** rework FluidMetal — additive blending, larger points, correct HSV ([8e3034d](https://github.com/bocan/bocan-music/commit/8e3034d6d85739d68abcd3ca5775c2b8de269cc3))


### ### Changed

* **playback:** eliminate DB round-trips when queueing full library ([315b003](https://github.com/bocan/bocan-music/commit/315b003dad47f15b7e71ed562dd4f7df91f3ab58))
* **search:** in-place filtering via the current view's VM ([e2ec51e](https://github.com/bocan/bocan-music/commit/e2ec51e0e826f7379612e7f9a196403bde44cde4))
* **ui:** coalesce scan progress + non-blocking Add Folder/Files panels (Phase 5.5 audit L2) ([6c472b3](https://github.com/bocan/bocan-music/commit/6c472b3b13b9500a152d2a6aaa51c173c279b34f))
* **ui:** remove unused read-only TrackInspectorPanel (Phase 5.5 audit H5) ([b27fdb6](https://github.com/bocan/bocan-music/commit/b27fdb6fcf97d8d0f93c66a07b54984d22b647df))
* **ui:** replace PlaylistDetailView custom list with TracksView ([d9be477](https://github.com/bocan/bocan-music/commit/d9be477b66b11e3acfee96af97a60fa8da4615ce))

## [Unreleased]

### Added

### Changed

### Fixed

### Removed
