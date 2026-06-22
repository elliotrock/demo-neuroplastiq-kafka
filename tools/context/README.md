# Local Context Index

This folder provides a lightweight, local context log plus a searchable index.
It uses SQLite FTS (full-text search) and requires only Python 3.

## Files

- `tools/context/context-log.md` — append-only notes
- `tools/context/context.db` — local index (generated)
- `tools/context/context_index.py` — build/rebuild index
- `tools/context/context_query.py` — search index

## Usage

Build the index:

```
python tools/context/context_index.py
```

Search the index:

```
python tools/context/context_query.py "kafka controller"
```

Index additional files:

```
python tools/context/context_index.py --files handoff-notes.md tools/context/context-log.md
```

## Notes

- This is keyword search (FTS), not semantic embeddings.
- If you want embeddings later, we can add an optional step and store vectors alongside the FTS table.
