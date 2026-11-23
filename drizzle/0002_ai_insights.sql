CREATE TABLE IF NOT EXISTS ai_insight_lenses (
  account TEXT NOT NULL,
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  prompt TEXT NOT NULL,
  category TEXT NOT NULL,
  suggested_range TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (account, id)
);

CREATE INDEX IF NOT EXISTS idx_ai_insight_lenses_account_updated
  ON ai_insight_lenses(account, updated_at DESC);

CREATE TABLE IF NOT EXISTS ai_insight_reports (
  account TEXT NOT NULL,
  id TEXT NOT NULL,
  lens_id TEXT NOT NULL,
  lens_name TEXT NOT NULL,
  title TEXT NOT NULL,
  scope_json TEXT NOT NULL,
  note_count INTEGER NOT NULL,
  tag_count INTEGER NOT NULL,
  day_count INTEGER NOT NULL,
  analyzed_count INTEGER NOT NULL,
  content TEXT NOT NULL,
  citations_json TEXT NOT NULL,
  provider TEXT NOT NULL,
  client_request_id TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY (account, id)
);

CREATE INDEX IF NOT EXISTS idx_ai_insight_reports_account_created
  ON ai_insight_reports(account, created_at DESC, id DESC);
CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_insight_reports_account_req ON ai_insight_reports(account, client_request_id) WHERE client_request_id IS NOT NULL;
