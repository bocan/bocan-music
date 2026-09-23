#!/usr/bin/env python3
"""Drive the installed Bòcan through a scripted tour and record it.

The tour is for the README GIF: the cursor glides between the places a
person would click, at a pace a person would click them, on the release
app in /Applications with the real library. PyAutoGUI does the moving and
clicking; the targets come from the app's own accessibility tree, by the
same identifiers the E2E suite uses, so a layout change never breaks a
beat. No screenshots are taken, so the Retina scale never enters into it.

Run it through `make demo`. It needs Accessibility and Screen Recording
permission for whatever runs it (Terminal, usually); macOS asks on first
use. See Scripts/demo/README.md.
"""

from __future__ import annotations

import argparse
import os
import signal
import sqlite3
import subprocess
import sys
import time
from dataclasses import dataclass

import pyautogui
from ApplicationServices import (
    AXIsProcessTrusted,
    AXUIElementCopyAttributeValue,
    AXUIElementCreateApplication,
    AXUIElementSetAttributeValue,
    AXValueCreate,
    AXValueGetValue,
    kAXChildrenAttribute,
    kAXCloseButtonAttribute,
    kAXDescriptionAttribute,
    kAXIdentifierAttribute,
    kAXPositionAttribute,
    kAXRowsAttribute,
    kAXSizeAttribute,
    kAXTitleAttribute,
    kAXValueAttribute,
    kAXValueTypeCGPoint,
    kAXValueTypeCGSize,
    kAXWindowAttribute,
)

APP_PATH = "/Applications/Bocan.app"
APP_BINARY = f"{APP_PATH}/Contents/MacOS/Bocan"
BUNDLE_ID = "io.cloudcauldron.bocan"
# The release build is not sandboxed, so its library is here, not in a container.
LIBRARY_DB = os.path.expanduser("~/Library/Application Support/Bocan/library.sqlite")
# The queue the app restores at launch: a JSON blob in the settings table.
# Removing the row is what the app itself does to clear its queue.
QUEUE_KEYS = ("playback.queue.v2", "playback.queue.v1")

pyautogui.FAILSAFE = True  # slam the cursor into a corner to abort
GLIDE = pyautogui.easeInOutQuad


# MARK: - Shell helpers


def osascript(source: str) -> str:
    """Runs AppleScript and returns its output, raising on failure."""
    result = subprocess.run(["osascript", "-e", source], capture_output=True, text=True, check=True)
    return result.stdout.strip()


def app_pid() -> int | None:
    """The installed app's pid, ignoring any Xcode build of the same name."""
    result = subprocess.run(["pgrep", "-f", APP_BINARY], capture_output=True, text=True)
    pids = [int(p) for p in result.stdout.split()]
    return pids[0] if pids else None


def quit_app(timeout: float = 15) -> None:
    if app_pid() is None:
        return
    osascript(f'tell application id "{BUNDLE_ID}" to quit')
    deadline = time.monotonic() + timeout
    while app_pid() is not None and time.monotonic() < deadline:
        time.sleep(0.2)
    if app_pid() is not None:
        raise SystemExit("Bòcan did not quit; stop it by hand and run again.")


def clear_restored_queue() -> None:
    """Forgets the saved queue, so the app opens on Not playing.

    Only with the app quit: two writers on the library is the one thing the
    app's own WAL discipline is built to avoid.
    """
    if app_pid() is not None:
        raise SystemExit("Refusing to touch the library while Bòcan is running.")
    if not os.path.exists(LIBRARY_DB):
        print(f"no library at {LIBRARY_DB}; nothing to clear", flush=True)
        return
    connection = sqlite3.connect(LIBRARY_DB)
    try:
        placeholders = ",".join("?" for _ in QUEUE_KEYS)
        removed = connection.execute(f"DELETE FROM settings WHERE key IN ({placeholders})", QUEUE_KEYS).rowcount
        connection.commit()
    finally:
        connection.close()
    print(f"cleared the restored queue ({removed} row{'s' if removed != 1 else ''})", flush=True)


def launch_app(timeout: float = 30) -> int:
    subprocess.run(["open", "-a", APP_PATH], check=True)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        pid = app_pid()
        if pid is not None:
            return pid
        time.sleep(0.2)
    raise SystemExit("Bòcan did not launch.")


def place_window(x: int, y: int, w: int, h: int, timeout: float = 30) -> None:
    """Puts the main window at an exact frame, so the recording region is known."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            # By bundle id: the process is named "Bòcan Music", and an Xcode
            # build of the same app carries the same name.
            osascript(
                f'tell application "System Events"\n'
                f'  set theApp to first process whose bundle identifier is "{BUNDLE_ID}"\n'
                f"  set position of window 1 of theApp to {{{x}, {y}}}\n"
                f"  set size of window 1 of theApp to {{{w}, {h}}}\n"
                f"end tell"
            )
            osascript(f'tell application id "{BUNDLE_ID}" to activate')
            return
        except subprocess.CalledProcessError:
            time.sleep(0.5)
    raise SystemExit("The main window never appeared.")


# MARK: - Accessibility


@dataclass(frozen=True)
class Frame:
    x: float
    y: float
    w: float
    h: float

    @property
    def center(self) -> tuple[int, int]:
        return int(self.x + self.w / 2), int(self.y + self.h / 2)


def ax_attr(element, name):
    err, value = AXUIElementCopyAttributeValue(element, name, None)
    return value if err == 0 else None


def ax_frame(element) -> Frame | None:
    position = ax_attr(element, kAXPositionAttribute)
    size = ax_attr(element, kAXSizeAttribute)
    if position is None or size is None:
        return None
    ok_p, point = AXValueGetValue(position, kAXValueTypeCGPoint, None)
    ok_s, dims = AXValueGetValue(size, kAXValueTypeCGSize, None)
    if not (ok_p and ok_s):
        return None
    return Frame(point.x, point.y, dims.width, dims.height)


def identifier(element) -> str:
    return ax_attr(element, kAXIdentifierAttribute) or ""


def ax_move_window(window, x: float, y: float) -> None:
    """Moves a window by its accessibility element. (Its size cannot be set
    this way: a SwiftUI Settings window is fixed-size.)"""
    point = AXValueCreate(kAXValueTypeCGPoint, (x, y))
    if AXUIElementSetAttributeValue(window, kAXPositionAttribute, point) != 0:
        raise SystemExit("Could not move the Settings window.")


def contains(outer: Frame, inner: Frame) -> bool:
    return (
        inner.x >= outer.x
        and inner.y >= outer.y
        and inner.x + inner.w <= outer.x + outer.w
        and inner.y + inner.h <= outer.y + outer.h
    )


# The AppKit song tables can hold fifteen thousand rows, each with twenty
# cells. A search that walks into one spends its whole budget there and never
# reaches the sidebar. Nothing the tour looks for is inside them, and the one
# row it needs comes from the table's rows attribute directly.
BIG_TABLES = {"tracksTable", "subsonicSongsTable", "history.table"}


def ax_find(root, predicate, limit: int = 20000):
    """Breadth-first search of the accessibility tree; first match wins.
    Matches a big table itself but never descends into it."""
    queue = [root]
    seen = 0
    while queue and seen < limit:
        element = queue.pop(0)
        seen += 1
        if predicate(element):
            return element
        if identifier(element) in BIG_TABLES:
            continue
        queue.extend(ax_attr(element, kAXChildrenAttribute) or [])
    return None


class App:
    """The running app's accessibility root, plus the lookups the tour needs."""

    def __init__(self, pid: int):
        self.root = AXUIElementCreateApplication(pid)

    def wait_for(self, describe: str, find, timeout: float = 20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            element = find()
            if element is not None:
                return element
            time.sleep(0.25)
        raise SystemExit(f"Timed out waiting for {describe}.")

    def by_identifier(self, ident: str, timeout: float = 20):
        return self.wait_for(f'"{ident}"', lambda: ax_find(self.root, lambda e: identifier(e) == ident), timeout)

    def find_identifier(self, ident: str):
        """One look, no wait: for elements that may legitimately not exist."""
        return ax_find(self.root, lambda e: identifier(e) == ident)

    def by_identifier_prefix(self, prefix: str, timeout: float = 20):
        return self.wait_for(
            f'an identifier starting "{prefix}"',
            lambda: ax_find(self.root, lambda e: identifier(e).startswith(prefix)),
            timeout,
        )

    def absent(self, ident: str, timeout: float = 60) -> None:
        """Waits until no element carries `ident` (the scan banner, mainly)."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if ax_find(self.root, lambda e: identifier(e) == ident) is None:
                return
            time.sleep(0.5)
        raise SystemExit(f'"{ident}" never went away.')

    def table_row(self, table_ident: str, index: int, min_rows: int, timeout: float = 20):
        """Row `index` (0-based) of the table with `table_ident`, once it has `min_rows`."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            table = ax_find(self.root, lambda e: identifier(e) == table_ident)
            rows = ax_attr(table, kAXRowsAttribute) if table is not None else None
            if rows and len(rows) >= min_rows:
                return rows[index]
            time.sleep(0.25)
        raise SystemExit(f'"{table_ident}" never showed {min_rows} rows.')


def describe(element) -> str:
    for name in (kAXTitleAttribute, kAXDescriptionAttribute):
        value = ax_attr(element, name)
        if value:
            return str(value)
    # A table row has neither; read the text of its first few cells instead.
    texts: list[str] = []
    queue = ax_attr(element, kAXChildrenAttribute) or []
    while queue and len(texts) < 3:
        child = queue.pop(0)
        value = ax_attr(child, kAXValueAttribute)
        if isinstance(value, str) and value.strip():
            texts.append(value.strip())
        queue.extend(ax_attr(child, kAXChildrenAttribute) or [])
    return ", ".join(texts) or identifier(element) or "?"


# MARK: - The tour


# The Settings sidebar, top to bottom. Scrobbling only appears once a
# scrobbler is configured, so it is skipped when absent.
SETTINGS_PAGES = (
    "general",
    "appearance",
    "library",
    "sources",
    "smartPlaylists",
    "podcasts",
    "phoneSync",
    "playback",
    "equaliser",
    "effects",
    "replayGain",
    "lyrics",
    "visualizer",
    "scrobble",
    "advanced",
    "diagnostics",
)


class Tour:
    def __init__(self, app: App, pause: float, glide: float, frame: Frame, settings: bool):
        self.app = app
        self.pause = pause
        self.glide = glide
        self.frame = frame
        self.settings = settings
        self.started = time.monotonic()

    def log(self, message: str) -> None:
        print(f"[{time.monotonic() - self.started:6.2f}s] {message}", flush=True)

    def wait(self, seconds: float | None = None) -> None:
        time.sleep(self.pause if seconds is None else seconds)

    def glide_to(self, element) -> tuple[int, int]:
        frame = ax_frame(element)
        if frame is None:
            raise SystemExit(f"{describe(element)} has no frame.")
        x, y = frame.center
        pyautogui.moveTo(x, y, duration=self.glide, tween=GLIDE)
        return x, y

    def click(self, element, label: str) -> None:
        self.glide_to(element)
        pyautogui.click()
        self.log(f"click {label}")

    def double_click(self, element, label: str) -> None:
        self.glide_to(element)
        pyautogui.doubleClick(interval=0.12)
        self.log(f"double-click {label} ({describe(element)})")

    def sidebar(self, name: str) -> None:
        self.click(self.app.by_identifier(f"sidebar.{name}"), f"sidebar {name}")

    def run(self) -> None:
        app = self.app
        self.log("settle")
        self.wait(1.5)

        for name in ("albums", "artists", "podcasts", "radio"):
            self.sidebar(name)
            self.wait()

        self.double_click(app.by_identifier_prefix("radio.row."), "top radio station")
        self.wait(2)

        self.sidebar("songs")
        self.wait()

        # The first key anywhere in the window starts a library search and is
        # swallowed into the field; the rest type into it.
        pyautogui.typewrite("metallica", interval=0.09)
        self.log('type "metallica"')
        row = app.table_row("tracksTable", index=2, min_rows=3)
        self.wait()
        self.double_click(row, "third result")

        lyrics = app.by_identifier("toolbar.lyrics")
        self.click(lyrics, "Toggle Lyrics Pane")
        self.wait(2)
        self.click(app.by_identifier("toolbar.lyrics"), "Toggle Lyrics Pane again")
        self.wait()

        self.click(app.by_identifier("toolbar.visualizer"), "Toggle Visualizer Pane")
        self.wait(2.5)
        self.click(app.by_identifier("toolbar.visualizer"), "Toggle Visualizer Pane again")
        self.wait(1)

        if self.settings:
            self.settings_tour()
        self.log("end")

    def settings_tour(self) -> None:
        """Opens Settings, shows every pane for a second, then closes it again."""
        app = self.app
        # The menu bar sits above the recorded frame, so the shortcut looks the
        # same on the recording as a click on Bòcan, Settings... would.
        pyautogui.hotkey("command", ",")
        self.log("open Settings")
        first = app.by_identifier("settings.sidebar.general")

        # Settings opens wherever macOS puts it; centre it in the recorded frame.
        window = ax_attr(first, kAXWindowAttribute)
        current = ax_frame(window)
        if window is None or current is None:
            raise SystemExit("The Settings window has no frame.")
        ax_move_window(
            window,
            self.frame.x + (self.frame.w - current.w) / 2,
            self.frame.y + (self.frame.h - current.h) / 2,
        )
        self.wait(1)
        # The sidebar column, read now: General itself scrolls away later.
        column_x = ax_frame(first).center[0]

        for page in SETTINGS_PAGES[1:]:
            # Scrobbling is only listed once a scrobbler is configured; it is
            # absent for good once the row after it is in view.
            after = "advanced" if page == "scrobble" else None
            row = self.settings_row(window, column_x, page, absent_once_visible=after)
            if row is None:
                self.log(f"skip settings {page} (not configured)")
                continue
            self.click(row, f"settings {page}")
            self.wait(1)

        self.click(ax_attr(window, kAXCloseButtonAttribute), "close Settings")
        self.wait(1)

    def settings_row(self, window, column_x: int, page: str, absent_once_visible: str | None = None):
        """The sidebar row for `page`, scrolled into view.

        The window is fixed-size and its sidebar is taller than it is. A row
        below the fold is not in the accessibility tree at all, or reports a
        frame below the window, where a click would land on the main window
        behind. So the list is scrolled, a wheel step at a time over the
        sidebar, until the row sits wholly inside the window. Returns None
        when the row is not there once `absent_once_visible` (the row that
        would follow it) is in view.
        """
        window_frame = ax_frame(window)
        anchor = column_x, window_frame.center[1]  # over the sidebar, mid-window

        def visible(name: str):
            row = self.app.find_identifier(f"settings.sidebar.{name}")
            frame = ax_frame(row) if row is not None else None
            return row if frame is not None and contains(window_frame, frame) else None

        for _ in range(12):
            row = visible(page)
            if row is not None:
                return row
            if absent_once_visible is not None and visible(absent_once_visible) is not None:
                return None
            pyautogui.moveTo(*anchor, duration=self.glide / 2, tween=GLIDE)
            pyautogui.scroll(-5)
            time.sleep(0.3)
        raise SystemExit(f"The {page} row never scrolled into the Settings window.")


# MARK: - Recording


def start_recording(path: str, x: int, y: int, w: int, h: int) -> subprocess.Popen:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    if os.path.exists(path):
        os.remove(path)
    return subprocess.Popen(["screencapture", "-v", "-R", f"{x},{y},{w},{h}", path])


def stop_recording(proc: subprocess.Popen) -> None:
    proc.send_signal(signal.SIGINT)
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()


# MARK: - Main


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", default="build/demo/demo.mov", help="where the recording goes")
    parser.add_argument("--x", type=int, default=100)
    parser.add_argument("--y", type=int, default=80)
    parser.add_argument("--width", type=int, default=1440)
    parser.add_argument("--height", type=int, default=900)
    parser.add_argument("--pause", type=float, default=1.5, help="the default wait between beats")
    parser.add_argument("--glide", type=float, default=0.6, help="seconds the cursor takes to reach a target")
    parser.add_argument("--no-record", action="store_true", help="drive only, record nothing")
    parser.add_argument("--keep-queue", action="store_true", help="keep the saved queue instead of opening on Not playing")
    parser.add_argument("--settings", action="store_true", help="end with a tour of every Settings pane")
    args = parser.parse_args()

    if not AXIsProcessTrusted():
        print(
            "This process needs Accessibility permission: System Settings, Privacy & Security, "
            "Accessibility, then add the terminal running it.",
            file=sys.stderr,
        )
        return 2

    quit_app()
    if not args.keep_queue:
        clear_restored_queue()
    pid = launch_app()
    place_window(args.x, args.y, args.width, args.height)
    app = App(pid)
    app.by_identifier("sidebar.songs")
    # The launch runs a quick rescan; its banner would open the recording.
    app.absent("scanBanner.dismiss")
    time.sleep(0.5)

    recorder = None if args.no_record else start_recording(args.out, args.x, args.y, args.width, args.height)
    time.sleep(1.0)  # let screencapture start before the first beat
    frame = Frame(args.x, args.y, args.width, args.height)
    tour = Tour(app, pause=args.pause, glide=args.glide, frame=frame, settings=args.settings)
    try:
        tour.run()
    finally:
        if recorder is not None:
            stop_recording(recorder)
    total = time.monotonic() - tour.started
    print(f"tour took {total:.1f}s" + ("" if args.no_record else f"; recording at {args.out}"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
