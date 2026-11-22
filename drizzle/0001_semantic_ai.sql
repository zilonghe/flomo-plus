CREATE TABLE IF NOT EXISTS note_embeddings (
  account TEXT NOT NULL,
  note_id TEXT NOT NULL,
  model TEXT NOT NULL,
  dims INTEGER NOT NULL,
  content_hash TEXT NOT NULL,
  vector BLOB NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (account, note_id)
);

CREATE TABLE IF NOT EXISTS ai_sessions (
  account TEXT NOT NULL,
  id TEXT NOT NULL,
  title TEXT NOT NULL,
  source_note_id TEXT,
  turns_json TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1,
  create_request_id TEXT,
  last_request_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (account, id)
);

CREATE INDEX IF NOT EXISTS idx_ai_sessions_account_updated ON ai_sessions(account, updated_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_sessions_account_create_req ON ai_sessions(account, create_request_id) WHERE create_request_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS ai_profile (
  account TEXT PRIMARY KEY NOT NULL,
  content TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  note_count INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS note_fts USING fts5(
  account UNINDEXED, note_id UNINDEXED, tokens, tokenize = 'unicode61'
);
