#!/usr/bin/env python3
"""Cross-references SQLite columns against the Swift source tree.

For every column in the database, counts references in .swift files outside
the migrations (and, by default, outside tests), checking both the raw
snake_case name and its Swift camelCase form. Columns with zero hits exist
only in DDL: nothing reads or writes them. This is the one check that can
see a dead column in a table with no rows, which the data-driven
`audit-db-schema.py` cannot.

The camelCase mapping is acronym-aware to match the codebase's style
(`musicbrainz_artist_id` -> `musicbrainzArtistID`, `server_url` -> `serverURL`,
`http_etag` -> `httpETag`); the naive `...Id` / `...Url` forms are checked too.

Caveats: a column whose only references are its own GRDB record property and
CodingKey still counts as referenced, and a column name that collides with an
unrelated identifier (`stereo_width` vs the global DSP `stereoWidth`) is
invisible here. `--min-hits` raises the bar; `--show-files` lists where the
hits are so a "record-only" column can be spotted by eye.

Exit code 1 when any column falls below --min-hits, else 0.
"""

import argparse
import pathlib
import re
import sqlite3
import sys

ACRONYMS = {
    "id": "ID",
    "url": "URL",
    "json": "JSON",
    "guid": "GUID",
    "tls": "TLS",
    "der": "DER",
    "etag": "ETag",
    "ms": "MS",
    "mbid": "MBID",
    "db": "DB",
    "hz": "Hz",
}


def camel_variants(snake):
    parts = snake.split("_")
    naive = parts[0] + "".join(p.title() for p in parts[1:])
    aware = parts[0] + "".join(ACRONYMS.get(p, p.title()) for p in parts[1:])
    return {snake, naive, aware}


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("db")
    parser.add_argument("source_root")
    parser.add_argument(
        "--exclude",
        default=r"(Migrations?/|\.build/|/Tests/)",
        help="regex of file paths to skip (default: migrations, build dirs, tests)",
    )
    parser.add_argument(
        "--ignore-tables",
        default=r"^(sqlite_|grdb_)|_fts(_|$)",
        help="regex of tables to skip (default: sqlite_*, grdb_*, FTS shadow tables)",
    )
    parser.add_argument(
        "--min-hits",
        type=int,
        default=1,
        help="report columns with fewer references than this (default 1 = only orphans)",
    )
    parser.add_argument(
        "--show-files", action="store_true", help="list the files each reported column appears in"
    )
    args = parser.parse_args()

    excluded = re.compile(args.exclude)
    files = [
        p for p in pathlib.Path(args.source_root).rglob("*.swift") if not excluded.search(str(p))
    ]
    corpus = {p: p.read_text(errors="replace") for p in files}
    skip = re.compile(args.ignore_tables)

    con = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    findings = []
    for (table,) in con.execute("SELECT name FROM sqlite_master WHERE type='table'"):
        if skip.search(table):
            continue
        for (_cid, name, *_rest) in con.execute(f"PRAGMA table_info('{table}')"):
            pattern = re.compile(
                r"\b(" + "|".join(map(re.escape, camel_variants(name))) + r")\b"
            )
            per_file = {p: len(pattern.findall(text)) for p, text in corpus.items()}
            hits = sum(per_file.values())
            if hits < args.min_hits:
                where = sorted(str(p) for p, n in per_file.items() if n)
                findings.append((hits, table, name, where))

    if not findings:
        print(f"no columns below {args.min_hits} reference(s) across {len(files)} files")
        return
    print(f"{'hits':>5}  {'table':<26} {'column':<30}")
    for hits, table, name, where in sorted(findings):
        print(f"{hits:>5}  {table:<26} {name:<30}")
        if args.show_files:
            for path in where:
                print(f"       {path}")
    sys.exit(1)


if __name__ == "__main__":
    main()
