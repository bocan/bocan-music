#!/usr/bin/env python3
"""Finds dead, default-only, and sparse columns in a Bòcan SQLite library.

Opens the database read-only and, for every column of every table, reports:

  EMPTY         every row is NULL (or '' with --treat-empty-as-null)
  DEFAULT_ONLY  every row holds exactly the DDL default; no code ever set it
  SPARSE        null ratio above --sparse-threshold (default 0.90)
  NO_ROWS       table has no rows, nothing can be concluded (only with --verbose)

FTS5 shadow tables and GRDB / SQLite internals are skipped. Point it at a copy
of the real library (see `make audit-db`) rather than a test fixture: the
SPARSE tier is calibrated for a real collection and will fire on almost every
column of a small fixture.

Exit codes for CI:  --fail-on empty  -> 1 if any EMPTY / DEFAULT_ONLY
                    --fail-on sparse -> 1 if any finding at all
"""

import argparse
import re
import sqlite3
import sys


def norm_default(value):
    if value is None:
        return None
    text = str(value).strip()
    if text.upper() == "NULL":
        return None
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        text = text[1:-1]
    return text


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("db")
    parser.add_argument("--sparse-threshold", type=float, default=0.90)
    parser.add_argument(
        "--ignore-tables",
        default=r"^(sqlite_|grdb_)|_fts(_|$)",
        help="regex of tables to skip (default: sqlite_*, grdb_*, FTS shadow tables)",
    )
    parser.add_argument(
        "--treat-empty-as-null", action="store_true", help="count empty strings as NULL"
    )
    parser.add_argument("--fail-on", choices=["none", "empty", "sparse"], default="none")
    parser.add_argument("--verbose", action="store_true", help="also print OK columns")
    args = parser.parse_args()

    con = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    skip = re.compile(args.ignore_tables)

    def expr(column):
        return f"NULLIF(\"{column}\", '')" if args.treat_empty_as_null else f'"{column}"'

    fmt = "{:<26} {:<30} {:>8} {:>9} {:>9} {:>7}  {}"
    print(fmt.format("table", "column", "rows", "non-null", "distinct", "null%", "verdict"))
    counts = {"EMPTY": 0, "DEFAULT_ONLY": 0, "SPARSE": 0}

    tables = [r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")]
    for table in tables:
        if skip.search(table):
            continue
        nrows = con.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
        for _cid, name, _type, _notnull, dflt, pk in con.execute(f"PRAGMA table_info('{table}')"):
            if nrows == 0:
                if args.verbose:
                    print(fmt.format(table, name, 0, 0, 0, "-", "NO_ROWS"))
                continue
            e = expr(name)
            nonnull, distinct = con.execute(
                f'SELECT COUNT({e}), COUNT(DISTINCT {e}) FROM "{table}"'
            ).fetchone()
            nullpct = 100.0 * (nrows - nonnull) / nrows
            verdict = "OK"
            if nonnull == 0:
                verdict = "EMPTY"
            elif distinct == 1 and not pk:
                only = con.execute(
                    f'SELECT {e} FROM "{table}" WHERE {e} IS NOT NULL LIMIT 1'
                ).fetchone()[0]
                default = norm_default(dflt)
                if default is not None and str(only) == default and nullpct == 0.0:
                    verdict = "DEFAULT_ONLY"
                elif nullpct > args.sparse_threshold * 100:
                    verdict = "SPARSE"
            elif nullpct > args.sparse_threshold * 100:
                verdict = "SPARSE"
            if verdict in counts:
                counts[verdict] += 1
            if verdict != "OK" or args.verbose:
                print(fmt.format(table, name, nrows, nonnull, distinct, f"{nullpct:.1f}", verdict))

    total = sum(counts.values())
    print(
        f"\nfindings: {counts['EMPTY']} empty, {counts['DEFAULT_ONLY']} default-only, "
        f"{counts['SPARSE']} sparse ({total} total)"
    )
    if args.fail_on == "empty" and (counts["EMPTY"] or counts["DEFAULT_ONLY"]):
        sys.exit(1)
    if args.fail_on == "sparse" and total:
        sys.exit(1)


if __name__ == "__main__":
    main()
