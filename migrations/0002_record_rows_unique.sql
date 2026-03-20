-- Remove duplicate rows, keeping the one with the lowest id
DELETE FROM record_rows
WHERE id NOT IN (
  SELECT MIN(id)
  FROM record_rows
  GROUP BY report_id, source_ip, header_from
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_record_rows_unique
ON record_rows(report_id, source_ip, header_from);
