# Demo recording

A scripted tour of the installed app, recorded for the README GIF.

`tour.py` quits and relaunches `/Applications/Bocan.app` (the release build,
never an Xcode build), waits for the launch rescan to finish, places the main
window at an exact frame, records that frame with `screencapture`, and drives
the tour with PyAutoGUI: the cursor glides between targets at a pace a person
would click them. Every target is found in the app's own accessibility tree by
the same identifiers the E2E suite uses (`sidebar.albums`, `tracksTable`,
`toolbar.lyrics`, ...), so nothing is pixel-hunted and a layout change does
not break a beat.

## Once

```
pip3 install -r Scripts/demo/requirements.txt
brew install gifski      # optional, but the GIFs are much better for it
```

Grant the terminal that runs it **Accessibility** and **Screen Recording** in
System Settings, Privacy & Security. macOS prompts on first use; the script
exits with a message if Accessibility is missing.

## Every time

```
make demo        # records build/demo/demo.mov and prints the tour's timings
make demo-gif    # encodes it to build/demo/demo.gif, 1280 wide at 15 fps
```

The tour's beats and waits are in `Tour.run()` in `tour.py`. `--pause` sets
the default wait between beats (1.5 s), `--glide` the cursor's travel time
(0.6 s), and `--no-record` drives without recording, for rehearsal.

## Things the tour allows for

- **Type-to-search.** The first printable key pressed anywhere in the main
  window starts a library search and is swallowed into the field. The tour
  uses that on purpose for the search beat; do not type anywhere else.
- **The launch rescan.** The app rescans on launch and shows a banner. The
  tour waits for the banner to go before recording starts.
- **Single instance.** Launching the app while it is running only brings it
  forward, so the tour quits it first and starts from a clean launch.
- **Your library is on screen.** The recording shows whatever the real
  library shows: artwork, titles, station names. Look before publishing.
