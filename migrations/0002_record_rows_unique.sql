CREATE UNIQUE INDEX IF NOT EXISTS idx_record_rows_unique
ON record_rows(report_id, source_ip, header_from);
