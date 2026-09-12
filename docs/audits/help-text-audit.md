# Help-text audit (#501), baseline

Report only, no fixes. Every interactive control without `.help()` on
2026-09-12 (tree at `f9c926c0`), counted by area, so the backlog has a recorded
size for the first time. The rule these sites are measured against is the
"Hover text" policy in `docs/design-spec/_standards.md`. The fixes are #502 to
#508, and the ratchet that stops the number growing again is #509.

## Method

```
python3 Scripts/audit-help-text.py --warn            # lists every site
python3 Scripts/audit-help-text.py --warn --summary  # the count, what make lint runs
```

The script scans `Modules/UI/Sources` and `App/` for `Button`, `Toggle`,
`Picker`, `Slider` and `Menu` call sites whose modifier chain carries no
`.help(...)`. Menu, alert and dialog contexts, `#Preview` bodies and test
sources are skipped by rule, not by allowlist, because macOS renders no tooltip
in them. `Scripts/audit-help-text-allowlist.txt` holds five entries, all of them
the DEBUG-only audio window.

## Result

**173 controls across 71 files. Every one is in `Modules/UI/Sources`; `App/` is
already clean.**

By control type:

| Type | Sites |
|---|---|
| Button | 113 |
| Picker | 28 |
| Toggle | 24 |
| Slider | 4 |
| Menu | 4 |
| **Total** | **173** |

By area, which is how the fix is sliced:

| Area | Sites | Slice |
|---|---|---|
| `Browse/` (Subsonic, Podcasts, Radio, root) | 45 | #503, #504 |
| `Settings/` | 41 | #502 |
| `Playlists/` (including Smart) | 19 | #505 |
| `MetadataEditor/` | 11 | #506 |
| `Lyrics/` | 11 | #507 |
| `Summary/` | 10 | #508 |
| `DSP/` | 8 | #507 |
| `Tools/` | 5 | #506 |
| `Fingerprint/` | 5 | #506 |
| `Visualizers/` | 4 | #507 |
| `Transport/` | 4 | #507 |
| `MenuBarExtra/` | 4 | #508 |
| `Scrobble/` | 2 | #508 |
| `Common/` | 2 | #508 |
| `DeepDive/` | 1 | #508 |
| `Console/` | 1 | #508 |

The ten densest files carry 58 of the 173:

| Sites | File |
|---|---|
| 12 | `Settings/SubsonicSettingsView.swift` |
| 9 | `Settings/PhoneSyncSettingsView.swift` |
| 7 | `Settings/PodcastSettingsView.swift` |
| 5 | `DSP/PresetManagerView.swift` |
| 5 | `Browse/Podcasts/PodcastShowSettingsView.swift` |
| 5 | `Browse/Podcasts/EpisodeList.swift` |
| 4 | `Tools/BatchCoverArtSheet.swift` |
| 4 | `Settings/PhoneSyncPairingSheet.swift` |
| 4 | `MetadataEditor/TagEditorSheet.swift` |
| 4 | `MenuBarExtra/MenuBarExtraScene.swift` |

Settings is both the largest share and the surface where hover text earns the
most: the controls are dense and their labels are short.

## Why a baseline was the missing piece

`Scripts/audit-help-text.py` landed on 2026-08-10 in warning mode and has run
from `make lint` ever since with `--warn --summary`, which prints a count and
always exits zero. The count was never written down anywhere, so no one could
say whether 173 was up, down or flat. Ten one-off help-text issues were opened
and closed between April and May (#21, #25, #36, #56, #82, #166, #173, #177,
#178, #179, #302) and the number today is still 173.

That is the same lesson #459 taught about `try?`: a rule that cannot fail a
build is advisory, and advisory rules decay. Clearing the backlog matters less
than #509, which drops `--warn` so a control shipped with no hover text fails
`make lint`. Until then, this file is the only trend data there is: re-run the
summary and compare.

## Upper bound on the work

173 new catalogue keys, and the real number should be lower. A control whose
label is genuinely self-sufficient belongs on the allowlist with a reason
rather than carrying hover text that repeats it.
