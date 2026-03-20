import { DmarcRecordRow } from "./types";

const BATCH_LIMIT = 100;

export async function insertReport(
  db: D1Database,
  rows: DmarcRecordRow[]
): Promise<void> {
  if (rows.length === 0) return;

  const first = rows[0];

  // Insert report metadata (idempotent via ON CONFLICT)
  await db
    .prepare(
      `INSERT INTO reports (report_id, org_name, date_range_begin, date_range_end, error, domain, adkim, aspf, policy_p, policy_sp, policy_pct)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(report_id) DO NOTHING`
    )
    .bind(
      first.reportMetadataReportId,
      first.reportMetadataOrgName,
      first.reportMetadataDateRangeBegin,
      first.reportMetadataDateRangeEnd,
      first.reportMetadataError,
      first.policyPublishedDomain,
      first.policyPublishedADKIM,
      first.policyPublishedASPF,
      first.policyPublishedP,
      first.policyPublishedSP,
      first.policyPublishedPct
    )
    .run();

  // Insert record rows in batches (D1 limit: 100 statements per batch)
  for (let i = 0; i < rows.length; i += BATCH_LIMIT) {
    const chunk = rows.slice(i, i + BATCH_LIMIT);
    const stmts = chunk.map((row) =>
      db
        .prepare(
          `INSERT INTO record_rows (report_id, source_ip, count, disposition, dkim_result, spf_result, reason_type, envelope_to, header_from, date_range_begin)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
        )
        .bind(
          row.reportMetadataReportId,
          row.recordRowSourceIP,
          row.recordRowCount,
          row.recordRowPolicyEvaluatedDisposition,
          row.recordRowPolicyEvaluatedDKIM,
          row.recordRowPolicyEvaluatedSPF,
          row.recordRowPolicyEvaluatedReasonType,
          row.recordIdentifiersEnvelopeTo,
          row.recordIdentifiersHeaderFrom,
          row.reportMetadataDateRangeBegin
        )
    );
    await db.batch(stmts);
  }
}

// Query helpers for the API

function domainFilter(domain?: string): { clause: string; params: unknown[] } {
  if (!domain) return { clause: "", params: [] };
  return { clause: "AND r.domain = ?", params: [domain] };
}

export async function getDomains(db: D1Database) {
  const result = await db
    .prepare("SELECT DISTINCT domain FROM reports ORDER BY domain")
    .all<{ domain: string }>();
  return result.results.map((r) => r.domain);
}

export async function getSummary(db: D1Database, days: number, domain?: string) {
  const { clause, params } = domainFilter(domain);
  const result = await db
    .prepare(
      `SELECT
        COALESCE(SUM(rr.count), 0) AS total_messages,
        COALESCE(SUM(CASE WHEN rr.dkim_result = 1 AND rr.spf_result = 1 THEN rr.count ELSE 0 END), 0) AS pass_count,
        COALESCE(SUM(CASE WHEN rr.dkim_result = 0 OR rr.spf_result = 0 THEN rr.count ELSE 0 END), 0) AS fail_count,
        COUNT(DISTINCT rr.source_ip) AS unique_sources,
        COUNT(DISTINCT r.report_id) AS total_reports
      FROM record_rows rr
      JOIN reports r ON r.report_id = rr.report_id
      WHERE rr.date_range_begin >= unixepoch('now', '-' || ? || ' days')
      ${clause}`
    )
    .bind(days, ...params)
    .first();
  return result;
}

export async function getTimeSeries(
  db: D1Database,
  days: number,
  domain?: string
) {
  const { clause, params } = domainFilter(domain);
  const result = await db
    .prepare(
      `SELECT
        date(rr.date_range_begin, 'unixepoch') AS date,
        COALESCE(SUM(CASE WHEN rr.dkim_result = 1 AND rr.spf_result = 1 THEN rr.count ELSE 0 END), 0) AS pass_count,
        COALESCE(SUM(CASE WHEN rr.dkim_result = 0 OR rr.spf_result = 0 THEN rr.count ELSE 0 END), 0) AS fail_count,
        COALESCE(SUM(rr.count), 0) AS total
      FROM record_rows rr
      JOIN reports r ON r.report_id = rr.report_id
      WHERE rr.date_range_begin >= unixepoch('now', '-' || ? || ' days')
      ${clause}
      GROUP BY date
      ORDER BY date`
    )
    .bind(days, ...params)
    .all();
  return result.results;
}

export async function getTopSenders(
  db: D1Database,
  days: number,
  limit: number,
  domain?: string
) {
  const { clause, params } = domainFilter(domain);
  const result = await db
    .prepare(
      `SELECT
        rr.source_ip,
        SUM(rr.count) AS total_count,
        SUM(CASE WHEN rr.dkim_result = 1 AND rr.spf_result = 1 THEN rr.count ELSE 0 END) AS pass_count,
        SUM(CASE WHEN rr.dkim_result = 0 OR rr.spf_result = 0 THEN rr.count ELSE 0 END) AS fail_count
      FROM record_rows rr
      JOIN reports r ON r.report_id = rr.report_id
      WHERE rr.date_range_begin >= unixepoch('now', '-' || ? || ' days')
      ${clause}
      GROUP BY rr.source_ip
      ORDER BY total_count DESC
      LIMIT ?`
    )
    .bind(days, ...params, limit)
    .all();
  return result.results;
}

export async function getDomainAuth(db: D1Database, days: number) {
  const result = await db
    .prepare(
      `SELECT
        r.domain,
        SUM(rr.count) AS total,
        SUM(CASE WHEN rr.spf_result = 1 THEN rr.count ELSE 0 END) AS spf_pass,
        SUM(CASE WHEN rr.dkim_result = 1 THEN rr.count ELSE 0 END) AS dkim_pass,
        MAX(r.policy_p) AS policy_p
      FROM record_rows rr
      JOIN reports r ON r.report_id = rr.report_id
      WHERE rr.date_range_begin >= unixepoch('now', '-' || ? || ' days')
      GROUP BY r.domain
      ORDER BY total DESC`
    )
    .bind(days)
    .all();
  return result.results;
}

const REPORT_SORT_COLUMNS: Record<string, string> = {
  org_name: "r.org_name",
  domain: "r.domain",
  date_range_begin: "r.date_range_begin",
  disposition: "MAX(rr.disposition)",
};

export async function getReports(
  db: D1Database,
  page: number,
  pageSize: number,
  domain?: string,
  sort?: string,
  dir?: string
) {
  const offset = (page - 1) * pageSize;
  const domainClause = domain ? "WHERE domain = ?" : "";
  const domainParams = domain ? [domain] : [];

  const countResult = await db
    .prepare(`SELECT COUNT(*) AS total FROM reports ${domainClause}`)
    .bind(...domainParams)
    .first<{ total: number }>();

  const whereClause = domain ? "WHERE r.domain = ?" : "";
  const sortCol = sort && REPORT_SORT_COLUMNS[sort] ? REPORT_SORT_COLUMNS[sort] : "r.date_range_end";
  const sortDir = dir === "asc" ? "ASC" : "DESC";

  const result = await db
    .prepare(
      `SELECT r.report_id, r.org_name, r.domain, r.date_range_begin, r.date_range_end, r.received_at,
        COALESCE(SUM(rr.count), 0) AS total_count,
        COALESCE(SUM(CASE WHEN rr.disposition = 0 THEN rr.count ELSE 0 END), 0) AS none_count,
        COALESCE(SUM(CASE WHEN rr.disposition = 1 THEN rr.count ELSE 0 END), 0) AS quarantine_count,
        COALESCE(SUM(CASE WHEN rr.disposition = 2 THEN rr.count ELSE 0 END), 0) AS reject_count,
        COALESCE(SUM(CASE WHEN rr.spf_result = 0 THEN rr.count ELSE 0 END), 0) AS spf_fail_count,
        COALESCE(SUM(CASE WHEN rr.dkim_result = 0 THEN rr.count ELSE 0 END), 0) AS dkim_fail_count
      FROM reports r
      LEFT JOIN record_rows rr ON rr.report_id = r.report_id
      ${whereClause}
      GROUP BY r.report_id
      ORDER BY ${sortCol} ${sortDir}
      LIMIT ? OFFSET ?`
    )
    .bind(...domainParams, pageSize, offset)
    .all();

  return {
    data: result.results,
    total: countResult?.total ?? 0,
    page,
    pageSize,
  };
}

export async function getReportDetail(db: D1Database, reportId: string) {
  const report = await db
    .prepare("SELECT * FROM reports WHERE report_id = ?")
    .bind(reportId)
    .first();

  if (!report) return null;

  const rows = await db
    .prepare("SELECT * FROM record_rows WHERE report_id = ? ORDER BY count DESC")
    .bind(reportId)
    .all();

  return { report, rows: rows.results };
}
