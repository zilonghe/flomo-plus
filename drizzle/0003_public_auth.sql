CREATE TABLE auth_users (
  id TEXT PRIMARY KEY NOT NULL,
  role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('user','admin')),
  name TEXT,
  email TEXT,
  avatar_url TEXT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE auth_identities (
  provider TEXT NOT NULL,
  subject TEXT NOT NULL,
  user_id TEXT NOT NULL REFERENCES auth_users(id),
  email TEXT,
  login TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY (provider, subject)
);

CREATE TABLE auth_invites (
  code_hash TEXT PRIMARY KEY NOT NULL,
  code_hint TEXT NOT NULL,
  note TEXT,
  max_uses INTEGER NOT NULL CHECK (max_uses > 0),
  used_count INTEGER NOT NULL DEFAULT 0 CHECK (used_count BETWEEN 0 AND max_uses),
  created_by TEXT REFERENCES auth_users(id),
  expires_at TEXT,
  revoked_at TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE auth_sessions (
  id TEXT PRIMARY KEY NOT NULL,
  user_id TEXT NOT NULL REFERENCES auth_users(id),
  token_hash TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL CHECK (kind IN ('web','ios')),
  label TEXT,
  created_at TEXT NOT NULL,
  last_used_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  revoked_at TEXT
);
CREATE INDEX auth_sessions_user ON auth_sessions(user_id);

CREATE TABLE auth_oauth_states (
  id TEXT PRIMARY KEY NOT NULL,
  purpose TEXT NOT NULL CHECK (purpose IN ('oauth_state','invite_ticket','app_code')),
  payload_json TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  consumed_at TEXT
);
CREATE INDEX auth_oauth_states_expiry ON auth_oauth_states(expires_at);
