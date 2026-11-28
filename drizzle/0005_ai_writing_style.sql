CREATE TABLE IF NOT EXISTS ai_writing_style (
  account TEXT PRIMARY KEY NOT NULL,
  rules TEXT NOT NULL DEFAULT '',
  anchor_note_ids_json TEXT NOT NULL DEFAULT '[]',
  scope_json TEXT NOT NULL DEFAULT '{"range":"all","tzOffsetMinutes":0,"tags":[],"tagMode":"any"}',
  note_count INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);
