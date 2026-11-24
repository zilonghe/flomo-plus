CREATE TABLE IF NOT EXISTS obsidian_sync_objects (
  account TEXT NOT NULL,
  object_key TEXT NOT NULL,
  etag TEXT NOT NULL,
  last_modified TEXT,
  synced_at TEXT NOT NULL,
  PRIMARY KEY (account, object_key)
);

CREATE TABLE IF NOT EXISTS obsidian_sync_notes (
  account TEXT NOT NULL,
  object_key TEXT NOT NULL,
  entry_key TEXT NOT NULL,
  note_id TEXT NOT NULL,
  synced_body_sha256 TEXT NOT NULL,
  synced_revision INTEGER NOT NULL,
  PRIMARY KEY (account, note_id),
  UNIQUE (account, object_key, entry_key)
);
