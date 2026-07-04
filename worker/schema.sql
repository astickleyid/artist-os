CREATE TABLE IF NOT EXISTS accounts (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS tokens (
  hash TEXT PRIMARY KEY, account_id TEXT NOT NULL,
  created_at INTEGER NOT NULL, label TEXT
);
CREATE TABLE IF NOT EXISTS link_codes (
  code TEXT PRIMARY KEY, account_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS entities (
  account_id TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL,
  updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
  data TEXT NOT NULL DEFAULT '', seq INTEGER NOT NULL,
  PRIMARY KEY (account_id, kind, id)
);
CREATE INDEX IF NOT EXISTS entities_account_seq ON entities (account_id, seq);
CREATE TABLE IF NOT EXISTS seq_counter (account_id TEXT PRIMARY KEY, seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS blobs (
  account_id TEXT NOT NULL, asset_id TEXT NOT NULL,
  size INTEGER NOT NULL, content_type TEXT, created_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, asset_id)
);
