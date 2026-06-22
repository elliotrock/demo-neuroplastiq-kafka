#!/usr/bin/env python3
"""Build a local text index for quick context lookup."""
import argparse
import os
import sqlite3
from pathlib import Path
from typing import List, Optional, Tuple

DEFAULT_FILES = [
    "handoff-notes.md",
    "tools/context/context-log.md",
]


def connect(db_path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA synchronous=NORMAL;")
    return conn


def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS docs (
            path TEXT PRIMARY KEY,
            mtime REAL NOT NULL,
            content TEXT NOT NULL
        )
        """
    )
    try:
        conn.execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS docs_fts
            USING fts5(path, content)
            """
        )
    except sqlite3.OperationalError:
        conn.execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS docs_fts
            USING fts4(path, content)
            """
        )


def load_file(path: Path) -> Optional[Tuple[str, float, str]]:
    if not path.exists():
        return None
    content = path.read_text(encoding="utf-8", errors="replace")
    return str(path), path.stat().st_mtime, content


def rebuild_index(conn: sqlite3.Connection, files: List[Path]) -> None:
    conn.execute("DELETE FROM docs;")
    conn.execute("DELETE FROM docs_fts;")
    for path in files:
        record = load_file(path)
        if record is None:
            continue
        path_str, mtime, content = record
        conn.execute(
            "INSERT OR REPLACE INTO docs(path, mtime, content) VALUES (?, ?, ?)",
            (path_str, mtime, content),
        )
        conn.execute(
            "INSERT INTO docs_fts(path, content) VALUES (?, ?)",
            (path_str, content),
        )
    conn.commit()


def main() -> None:
    parser = argparse.ArgumentParser(description="Build local context index.")
    parser.add_argument(
        "--db",
        default="tools/context/context.db",
        help="SQLite DB path (default: tools/context/context.db)",
    )
    parser.add_argument(
        "--files",
        nargs="*",
        default=DEFAULT_FILES,
        help="Files to index (default: handoff-notes.md, tools/context/context-log.md)",
    )
    args = parser.parse_args()

    db_path = Path(args.db)
    db_path.parent.mkdir(parents=True, exist_ok=True)

    files = [Path(p) for p in args.files]
    conn = connect(db_path)
    ensure_schema(conn)
    rebuild_index(conn, files)
    conn.close()

    indexed = [str(p) for p in files if p.exists()]
    missing = [str(p) for p in files if not p.exists()]
    print("Indexed:")
    for p in indexed:
        print(f"- {p}")
    if missing:
        print("Missing (skipped):")
        for p in missing:
            print(f"- {p}")


if __name__ == "__main__":
    main()
