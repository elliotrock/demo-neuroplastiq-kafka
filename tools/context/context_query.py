#!/usr/bin/env python3
"""Query the local context index."""
import argparse
import sqlite3
from pathlib import Path


def connect(db_path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    return conn


def query(conn: sqlite3.Connection, text: str, limit: int) -> list[tuple[str, str]]:
    sql = (
        "SELECT path, snippet(docs_fts, 1, '[', ']', '…', 10) "
        "FROM docs_fts WHERE docs_fts MATCH ? LIMIT ?"
    )
    return list(conn.execute(sql, (text, limit)))


def main() -> None:
    parser = argparse.ArgumentParser(description="Query local context index.")
    parser.add_argument("query", help="FTS query text")
    parser.add_argument(
        "--db",
        default="tools/context/context.db",
        help="SQLite DB path (default: tools/context/context.db)",
    )
    parser.add_argument("--limit", type=int, default=10, help="Max results")
    args = parser.parse_args()

    db_path = Path(args.db)
    if not db_path.exists():
        raise SystemExit(f"DB not found: {db_path}. Run context_index.py first.")

    conn = connect(db_path)
    rows = query(conn, args.query, args.limit)
    conn.close()

    if not rows:
        print("No matches.")
        return

    for path, snippet in rows:
        print(f"{path}: {snippet}")


if __name__ == "__main__":
    main()
