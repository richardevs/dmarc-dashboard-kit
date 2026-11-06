-- Per-mechanism results from each record's <auth_results>: 0..n SPF and 0..n DKIM entries
-- per record row, keyed like record_rows. Reports received before this migration have none.
CREATE TABLE IF NOT EXISTS auth_results (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  report_id   TEXT NOT NULL,
  source_ip   TEXT NOT NULL DEFAULT '',
  header_from TEXT NOT NULL DEFAULT '',
  kind        TEXT NOT NULL CHECK (kind IN ('spf', 'dkim')),
  domain      TEXT NOT NULL DEFAULT '',
  selector    TEXT NOT NULL DEFAULT '',
  scope       TEXT NOT NULL DEFAULT '',
  result      TEXT NOT NULL DEFAULT ''
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_auth_results_unique
ON auth_results(report_id, source_ip, header_from, kind, domain, selector, scope);
