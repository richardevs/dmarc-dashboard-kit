CREATE TABLE IF NOT EXISTS reports (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  report_id        TEXT NOT NULL UNIQUE,
  org_name         TEXT NOT NULL DEFAULT '',
  date_range_begin INTEGER NOT NULL,
  date_range_end   INTEGER NOT NULL,
  error            TEXT NOT NULL DEFAULT '',
  domain           TEXT NOT NULL DEFAULT '',
  adkim            INTEGER NOT NULL DEFAULT 0,
  aspf             INTEGER NOT NULL DEFAULT 0,
  policy_p         INTEGER NOT NULL DEFAULT 0,
  policy_sp        INTEGER NOT NULL DEFAULT 0,
  policy_pct       INTEGER NOT NULL DEFAULT 0,
  received_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS record_rows (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  report_id        TEXT NOT NULL REFERENCES reports(report_id),
  source_ip        TEXT NOT NULL DEFAULT '',
  count            INTEGER NOT NULL DEFAULT 0,
  disposition      INTEGER NOT NULL DEFAULT 0,
  dkim_result      INTEGER NOT NULL DEFAULT 0,
  spf_result       INTEGER NOT NULL DEFAULT 0,
  reason_type      INTEGER,
  envelope_to      TEXT NOT NULL DEFAULT '',
  header_from      TEXT NOT NULL DEFAULT '',
  date_range_begin INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_record_rows_report_id ON record_rows(report_id);
CREATE INDEX IF NOT EXISTS idx_record_rows_date ON record_rows(date_range_begin);
CREATE INDEX IF NOT EXISTS idx_record_rows_header_from ON record_rows(header_from);
CREATE INDEX IF NOT EXISTS idx_reports_domain ON reports(domain);
