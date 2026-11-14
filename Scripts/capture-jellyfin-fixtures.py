#!/usr/bin/env python3
"""Captures real Jellyfin responses as test fixtures (ADR-097).

Run it yourself, against your own server. It signs in, reads a few lists, and
writes one JSON file per call into OUT_DIR. It only reads: no favourite, no
play report, nothing is changed on the server.

Two ways to sign in:

  --quick-connect   No password. The script shows a code; you enter it in the
                    Jellyfin web page (your user menu, Quick Connect) and the
                    script carries on.
  --user NAME       Password sign-in. The password is read from the
                    JELLYFIN_PASSWORD environment variable, or asked for
                    without echo.

Nothing is sent except to the server you name. The access token is used for the
later calls and is replaced with a placeholder before anything is written, so
no file in OUT_DIR holds a credential.

Item names, ids and image tags in the output are real, so look through the
files before you share or commit them.

Usage:
  Scripts/capture-jellyfin-fixtures.py https://jf.example.com OUT_DIR --quick-connect
  Scripts/capture-jellyfin-fixtures.py https://jf.example.com OUT_DIR --user NAME

Add --insecure for a server with a self-signed certificate.
"""

import argparse
import getpass
import json
import os
import pathlib
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PLACEHOLDER_TOKEN = "REDACTED-TEST-TOKEN-0123456789abcdef"
CLIENT = 'MediaBrowser Client="Bocan", Device="Fixture capture", DeviceId="bocan-fixture-capture", Version="0"'
ITEM_FIELDS = ["Genres", "MediaSources", "ChildCount", "ItemCounts"]


def query(pairs):
    """Encodes a list of (name, value) pairs. A list value repeats the name, as the SDK does."""
    items = []
    for name, value in pairs:
        if isinstance(value, (list, tuple)):
            items.extend((name, v) for v in value)
        elif value is not None:
            items.append((name, str(value)))
    return urllib.parse.urlencode(items)


class Server:
    def __init__(self, base, insecure):
        self.base = base.rstrip("/")
        self.token = None
        self.last_error = ""
        self.context = ssl._create_unverified_context() if insecure else None

    def call(self, method, path, params=None, body=None):
        url = self.base + path + ("?" + query(params) if params else "")
        headers = {"Authorization": CLIENT + (f', Token="{self.token}"' if self.token else ""), "Accept": "application/json"}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, context=self.context, timeout=30) as response:
                raw = response.read()
                return response.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as error:
            # The error text is the server's own reason. It never holds the password or the token.
            self.last_error = error.read().decode("utf-8", "replace").strip()[:300]
            return error.code, None


def sign_in_quick_connect(server):
    """Asks for a code, waits (up to ten minutes) for it to be approved, then signs in."""
    status, ticket = server.call("POST", "/QuickConnect/Initiate")
    if status != 200 or not ticket:
        return status, None
    secret = ticket["Secret"]
    print(f"\n  Quick Connect code: {ticket['Code']}")
    print("  In the Jellyfin web page, open your user menu, choose Quick Connect, and enter the code.")
    print("  Waiting for approval...")
    for _ in range(120):
        time.sleep(5)
        status, state = server.call("GET", "/QuickConnect/Connect", [("secret", secret)])
        if status == 200 and state and state.get("Authenticated"):
            return server.call("POST", "/Users/AuthenticateWithQuickConnect", body={"Secret": secret})
        if status != 200:
            return status, None
    print("  The code was not approved in time.")
    return 0, None


def write(out_dir, name, value):
    path = out_dir / f"{name}.json"
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    print(f"  wrote {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("server_url")
    parser.add_argument("out_dir", type=pathlib.Path)
    parser.add_argument("--user", help="sign in with this user name and a password")
    parser.add_argument("--quick-connect", action="store_true", help="sign in with Quick Connect, no password")
    parser.add_argument("--insecure", action="store_true", help="accept a self-signed certificate")
    args = parser.parse_args()
    if bool(args.user) == args.quick_connect:
        parser.error("choose exactly one of --user NAME or --quick-connect")

    password = None
    if args.user:
        password = os.environ.get("JELLYFIN_PASSWORD")
        if password:
            print("  using the password from JELLYFIN_PASSWORD (unset it to be asked instead)")
        else:
            password = getpass.getpass(f"Password for {args.user}: ")
    args.out_dir.mkdir(parents=True, exist_ok=True)
    server = Server(args.server_url, args.insecure)

    status, info = server.call("GET", "/System/Info/Public")
    if status != 200:
        print(f"Could not read the public server info (HTTP {status}).")
        return 1
    write(args.out_dir, "public-info", info)
    print(f"  server version {info.get('Version')}")

    status, enabled = server.call("GET", "/QuickConnect/Enabled")
    print(f"  Quick Connect enabled: {enabled} (HTTP {status})")

    if args.quick_connect:
        status, auth = sign_in_quick_connect(server)
        if status != 200 or not auth:
            print(f"Quick Connect sign-in failed (HTTP {status}). The server said: {server.last_error or '(nothing)'}")
            return 1
    else:
        status, auth = server.call("POST", "/Users/AuthenticateByName", body={"Username": args.user, "Pw": password})
        if status != 200 or not auth:
            print(f"Sign-in failed (HTTP {status}). The server said: {server.last_error or '(nothing)'}")
            print(f"  user name sent: {args.user!r}, password length: {len(password)}")
            print("  A 401 here means the server refused the user name or password.")
            print("  Jellyfin can lock an account after a few failures: use --quick-connect instead of retrying.")
            return 1
    server.token = auth["AccessToken"]
    user_id = auth["User"]["Id"]
    auth["AccessToken"] = PLACEHOLDER_TOKEN
    write(args.out_dir, "auth-result", auth)
    print(f"  user id as the server sent it: {user_id}")

    base = [("userId", user_id), ("recursive", "true"), ("fields", ITEM_FIELDS), ("enableUserData", "true"), ("enableTotalRecordCount", "true")]
    requests = {
        "songs": ("/Items", base + [("includeItemTypes", "Audio"), ("sortBy", ["AlbumArtist", "Album", "ParentIndexNumber", "IndexNumber"]), ("limit", 6)]),
        "albums": ("/Items", base + [("includeItemTypes", "MusicAlbum"), ("sortBy", "SortName"), ("limit", 4)]),
        "artists": ("/Artists/AlbumArtists", [("userId", user_id), ("fields", ITEM_FIELDS), ("enableUserData", "true"), ("enableTotalRecordCount", "true"), ("limit", 4)]),
        "genres": ("/Genres", [("userId", user_id), ("includeItemTypes", "Audio"), ("fields", "ItemCounts"), ("enableTotalRecordCount", "true"), ("limit", 6)]),
        "playlists": ("/Items", base + [("includeItemTypes", "Playlist"), ("limit", 3)]),
        "favorites": ("/Items", base + [("includeItemTypes", "Audio"), ("isFavorite", "true"), ("limit", 3)]),
    }
    results = {}
    for name, (path, params) in requests.items():
        status, body = server.call("GET", path, params)
        print(f"  {name}: HTTP {status}")
        if status == 200 and body is not None:
            write(args.out_dir, name, body)
            results[name] = body

    # Calls that need an id from the lists above: an album that has a cover (so its songs show
    # how the album image reaches a song), an artist's albums, and a search.
    albums = (results.get("albums") or {}).get("Items") or []
    artists = (results.get("artists") or {}).get("Items") or []
    with_art = next((a for a in albums if (a.get("ImageTags") or {}).get("Primary")), None)
    follow_ups = {}
    if with_art:
        follow_ups["songs-of-album"] = ("/Items", base + [("parentId", with_art["Id"]), ("includeItemTypes", "Audio"), ("sortBy", ["ParentIndexNumber", "IndexNumber", "SortName"]), ("limit", 6)])
    if artists:
        follow_ups["artist-albums"] = ("/Items", base + [("includeItemTypes", "MusicAlbum"), ("albumArtistIds", artists[0]["Id"]), ("sortBy", ["ProductionYear", "SortName"]), ("sortOrder", "Descending"), ("limit", 4)])
        follow_ups["search-songs"] = ("/Items", base + [("includeItemTypes", "Audio"), ("searchTerm", artists[0]["Name"].split()[0]), ("limit", 3)])
    for name, (path, params) in follow_ups.items():
        status, body = server.call("GET", path, params)
        print(f"  {name}: HTTP {status}")
        if status == 200 and body is not None:
            write(args.out_dir, name, body)
            results[name] = body

    songs = (results.get("songs") or {}).get("Items") or []
    if songs:
        first = songs[0]
        print(f"  first song id: {first.get('Id')}  album id: {first.get('AlbumId')}")
        print(f"  album id has dashes: {'-' in (first.get('AlbumId') or '')}; song id has dashes: {'-' in first.get('Id', '')}")

    status, _ = server.call("GET", "/Users/Me")
    print(f"  GET /Users/Me with the token: HTTP {status}")
    status, _ = server.call("POST", "/Sessions/Logout")
    print(f"  signed out (HTTP {status}); the token no longer works")
    print(f"\nDone. Look through the files in {args.out_dir} before you share them.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
