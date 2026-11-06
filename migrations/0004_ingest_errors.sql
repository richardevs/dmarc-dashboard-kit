-- Report emails the worker received but could not read, listed in the dashboard until
-- dismissed. content is the decoded XML (content_type 'xml') or, when the attachment could
-- not be unpacked, the attachment as base64 ('base64'); capped, see src/db.ts.
CREATE TABLE IF NOT EXISTS ingest_errors (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  received_at       INTEGER NOT NULL DEFAULT (unixepoch()),
  sender            TEXT NOT NULL DEFAULT '',
  stage             TEXT NOT NULL DEFAULT '',
  error             TEXT NOT NULL DEFAULT '',
  filename          TEXT NOT NULL DEFAULT '',
  mime_type         TEXT NOT NULL DEFAULT '',
  size              INTEGER NOT NULL DEFAULT 0,
  content           TEXT NOT NULL DEFAULT '',
  content_type      TEXT NOT NULL DEFAULT '',
  content_truncated INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_ingest_errors_received ON ingest_errors(received_at);
