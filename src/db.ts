import { DmarcRecordRow } from "./types";

const BATCH_LIMIT = 100;

export async function insertReport(
  db: D1Database,
  rows: DmarcRecordRow[]
): Promise<void> {
  if (rows.length === 0) return;

  const first = rows[0];

  const reportStmt = db
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
    );

  // Insert report + record rows in batches (D1 limit: 100 statements per batch).
  // The report INSERT is included in the first batch so it's atomic with record_rows.
  for (let i = 0; i < rows.length; i += BATCH_LIMIT) {
    const chunk = rows.slice(i, i + BATCH_LIMIT);
    const stmts = chunk.map((row) =>
      db
        .prepare(
          `INSERT INTO record_rows (report_id, source_ip, count, disposition, dkim_result, spf_result, reason_type, envelope_to, header_from, date_range_begin)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT DO NOTHING`
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
    if (i === 0) stmts.unshift(reportStmt);
    await db.batch(stmts);
  }

  await insertAuthResults(db, rows);
}

const AUTH_RESULTS_PER_STATEMENT = 200;

// One INSERT per chunk via json_each keeps large reports to a few statements. Only the
// first record per (report_id, source_ip, header_from) counts, as in record_rows, so a
// duplicate record cannot attach its results to the row that was kept.
async function insertAuthResults(db: D1Database, rows: DmarcRecordRow[]): Promise<void> {
  const seen = new Set<string>();
  const entries: Record<string, string>[] = [];
  for (const row of rows) {
    const key = `${row.recordRowSourceIP}\n${row.recordIdentifiersHeaderFrom}`;
    if (seen.has(key)) continue;
    seen.add(key);
    for (const a of row.authResults) {
      entries.push({
        report_id: row.reportMetadataReportId,
        source_ip: row.recordRowSourceIP,
        header_from: row.recordIdentifiersHeaderFrom,
        kind: a.kind,
        domain: a.domain,
        selector: a.selector,
        scope: a.scope,
        result: a.result,
      });
    }
  }

  const stmts: D1PreparedStatement[] = [];
  for (let i = 0; i < entries.length; i += AUTH_RESULTS_PER_STATEMENT) {
    stmts.push(
      db
        .prepare(
          `INSERT INTO auth_results (report_id, source_ip, header_from, kind, domain, selector, scope, result)
           SELECT json_extract(value, '$.report_id'), json_extract(value, '$.source_ip'),
                  json_extract(value, '$.header_from'), json_extract(value, '$.kind'),
                  json_extract(value, '$.domain'), json_extract(value, '$.selector'),
                  json_extract(value, '$.scope'), json_extract(value, '$.result')
           FROM json_each(?)
           WHERE true
           ON CONFLICT DO NOTHING`
        )
        .bind(JSON.stringify(entries.slice(i, i + AUTH_RESULTS_PER_STATEMENT)))
    );
  }
  for (let i = 0; i < stmts.length; i += BATCH_LIMIT) {
    await db.batch(stmts.slice(i, i + BATCH_LIMIT));
  }
}

// Query helpers for the API

function domainFilter(domain?: string): { clause: string; params: unknown[] } {
  if (!domain) return { clause: "", params: [] };
  return { clause: "AND r.domain = ?", params: [domain] };
}

function dateFilter(date?: string, tzMinutes = 0): { clause: string; params: unknown[] } {
  if (!date) return { clause: "", params: [] };
  const tzMod = `${tzMinutes >= 0 ? "+" : ""}${tzMinutes} minutes`;
  return { clause: "AND date(rr.date_range_begin, 'unixepoch', ?) = ?", params: [tzMod, date] };
}

export async function getDomains(db: D1Database) {
  const result = await db
    .prepare("SELECT DISTINCT domain FROM reports ORDER BY domain")
    .all<{ domain: string }>();
  return result.results.map((r) => r.domain);
}

export async function getSummary(db: D1Database, days: number, domain?: string, date?: string, tzMinutes = 0) {
  const { clause, params } = domainFilter(domain);
  const { clause: dateClause, params: dateParams } = dateFilter(date, tzMinutes);
  const result = await db
    .prepare(
      `SELECT
        COALESCE(SUM(rr.count), 0) AS total_messages,
        COALESCE(SUM(CASE WHEN rr.disposition = 0 THEN rr.count ELSE 0 END), 0) AS pass_count,
        COALESCE(SUM(CASE WHEN rr.disposition != 0 THEN rr.count ELSE 0 END), 0) AS fail_count,
        COUNT(DISTINCT rr.source_ip) AS unique_sources,
        COUNT(DISTINCT r.report_id) AS total_reports
      FROM record_rows rr
      JOIN reports r ON r.report_id = rr.report_id
      WHERE rr.date_range_begin >= unixepoch('now', '-' || ? || ' days')
      ${clause}
      ${dateClause}`
    )
    .bind(days, ...params, ...dateParams)
    .first();
  return result;
}

export async function getTimeSeries(
  db: D1Database,
  days: number,
  domain?: string,
  tzMinutes = 0
) {
  const { clause, params } = domainFilter(domain);
  const tzMod = `${tzMinutes >= 0 ? "+" : ""}${tzMinutes} minutes`;
  const result = await db
    .prepare(
      `SELECT
        date(rr.date_range_begin, 'unixepoch', ?) AS date,
        COALESCE(SUM(CASE WHEN rr.disposition = 0 THEN rr.count ELSE 0 END), 0) AS pass_count,
        COALESCE(SUM(CASE WHEN rr.disposition != 0 THEN rr.count ELSE 0 END), 0) AS fail_count,
        COALESCE(SUM(rr.count), 0) AS total
      FROM record_rows rr
      JOIN reports r ON r.report_id = rr.report_id
      WHERE rr.date_range_begin >= unixepoch('now', '-' || ? || ' days')
      ${clause}
      GROUP BY date
      ORDER BY date`
    )
    .bind(tzMod, days, ...params)
    .all();
  return result.results;
}

export async function getTopSenders(
  db: D1Database,
  days: number,
  limit: number,
  domain?: string,
  date?: string,
  tzMinutes = 0
) {
  const { clause, params } = domainFilter(domain);
  const { clause: dateClause, params: dateParams } = dateFilter(date, tzMinutes);
  const result = await db
    .prepare(
      `SELECT
        rr.source_ip,
        SUM(rr.count) AS total_count,
        SUM(CASE WHEN rr.disposition = 0 THEN rr.count ELSE 0 END) AS pass_count,
        SUM(CASE WHEN rr.disposition != 0 THEN rr.count ELSE 0 END) AS fail_count,
        SUM(CASE WHEN rr.spf_result = 0 THEN rr.count ELSE 0 END) AS spf_fail_count,
        SUM(CASE WHEN rr.dkim_result = 0 THEN rr.count ELSE 0 END) AS dkim_fail_count
      FROM record_rows rr
      JOIN reports r ON r.report_id = rr.report_id
      WHERE rr.date_range_begin >= unixepoch('now', '-' || ? || ' days')
      ${clause}
      ${dateClause}
      GROUP BY rr.source_ip
      ORDER BY total_count DESC
      LIMIT ?`
    )
    .bind(days, ...params, ...dateParams, limit)
    .all();
  return result.results;
}

const SENDER_SORT_COLUMNS: Record<string, string> = {
  source_ip: "rr.source_ip",
  total_count: "total_count",
  pass_count: "pass_count",
  fail_count: "fail_count",
  spf_fail: "spf_fail_count",
  dkim_fail: "dkim_fail_count",
  rate: "CAST(SUM(CASE WHEN rr.disposition = 0 THEN rr.count ELSE 0 END) AS REAL) / MAX(SUM(rr.count), 1)",
};

export async function getAllSenders(
  db: D1Database,
  days: number,
  page: number,
  pageSize: number,
  domain?: string,
  sort?: string,
  dir?: string,
  date?: string,
  tzMinutes = 0
) {
  const { clause, params } = domainFilter(domain);
  const { clause: dateClause, params: dateParams } = dateFilter(date, tzMinutes);
  const offset = (page - 1) * pageSize;
  const sortCol = sort && SENDER_SORT_COLUMNS[sort] ? SENDER_SORT_COLUMNS[sort] : "total_count";
  const sortDir = dir === "asc" ? "ASC" : "DESC";

  const countResult = await db
    .prepare(
      `SELECT COUNT(*) AS total FROM (
        SELECT rr.source_ip
        FROM record_rows rr
        JOIN reports r ON r.report_id = rr.report_id
        WHERE rr.date_range_begin >= unixepoch('now', '-' || ? || ' days')
        ${clause}
        ${dateClause}
        GROUP BY rr.source_ip
      )`
    )
    .bind(days, ...params, ...dateParams)
    .first<{ total: number }>();

  const result = await db
    .prepare(
      `SELECT
        rr.source_ip,
        SUM(rr.count) AS total_count,
        SUM(CASE WHEN rr.disposition = 0 THEN rr.count ELSE 0 END) AS pass_count,
        SUM(CASE WHEN rr.disposition != 0 THEN rr.count ELSE 0 END) AS fail_count,
        SUM(CASE WHEN rr.spf_result = 0 THEN rr.count ELSE 0 END) AS spf_fail_count,
        SUM(CASE WHEN rr.dkim_result = 0 THEN rr.count ELSE 0 END) AS dkim_fail_count
      FROM record_rows rr
      JOIN reports r ON r.report_id = rr.report_id
      WHERE rr.date_range_begin >= unixepoch('now', '-' || ? || ' days')
      ${clause}
      ${dateClause}
      GROUP BY rr.source_ip
      ORDER BY ${sortCol} ${sortDir}
      LIMIT ? OFFSET ?`
    )
    .bind(days, ...params, ...dateParams, pageSize, offset)
    .all();

  return {
    data: result.results,
    total: countResult?.total ?? 0,
    page,
    pageSize,
  };
}

export async function getDomainAuth(db: D1Database, days: number, date?: string, tzMinutes = 0) {
  const { clause: dateClause, params: dateParams } = dateFilter(date, tzMinutes);
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
      ${dateClause}
      GROUP BY r.domain
      ORDER BY total DESC`
    )
    .bind(days, ...dateParams)
    .all();
  return result.results;
}

const REPORT_SORT_COLUMNS: Record<string, string> = {
  org_name: "r.org_name",
  domain: "r.domain",
  date_range_begin: "r.date_range_begin",
};

export async function getReports(
  db: D1Database,
  page: number,
  pageSize: number,
  domain?: string,
  sort?: string,
  dir?: string,
  date?: string,
  tzMinutes = 0
) {
  const offset = (page - 1) * pageSize;
  const sortCol = sort && REPORT_SORT_COLUMNS[sort] ? REPORT_SORT_COLUMNS[sort] : "r.date_range_end";
  const sortDir = dir === "asc" ? "ASC" : "DESC";
  const tzMod = `${tzMinutes >= 0 ? "+" : ""}${tzMinutes} minutes`;

  const conditions: string[] = [];
  const filterParams: unknown[] = [];
  if (domain) { conditions.push("domain = ?"); filterParams.push(domain); }
  if (date) { conditions.push("date(date_range_begin, 'unixepoch', ?) = ?"); filterParams.push(tzMod, date); }
  const countWhere = conditions.length > 0 ? "WHERE " + conditions.join(" AND ") : "";

  const dataConditions: string[] = [];
  const dataParams: unknown[] = [];
  if (domain) { dataConditions.push("r.domain = ?"); dataParams.push(domain); }
  if (date) { dataConditions.push("date(r.date_range_begin, 'unixepoch', ?) = ?"); dataParams.push(tzMod, date); }
  const dataWhere = dataConditions.length > 0 ? "WHERE " + dataConditions.join(" AND ") : "";

  const countResult = await db
    .prepare(`SELECT COUNT(*) AS total FROM reports ${countWhere}`)
    .bind(...filterParams)
    .first<{ total: number }>();

  const result = await db
    .prepare(
      `SELECT r.report_id, r.org_name, r.domain, r.date_range_begin, r.date_range_end, r.received_at,
        COALESCE(SUM(rr.count), 0) AS total_count
      FROM reports r
      LEFT JOIN record_rows rr ON rr.report_id = r.report_id
      ${dataWhere}
      GROUP BY r.report_id
      ORDER BY ${sortCol} ${sortDir}
      LIMIT ? OFFSET ?`
    )
    .bind(...dataParams, pageSize, offset)
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

const SPF_ANALYSIS_ROW_LIMIT = 2000;

// SPF alignment analysis: per (header_from, source IP, SPF-checked domain) the counts the
// dashboard needs to show how SPF aligned, and why it did not. The SPF entry of each record row is its
// mfrom result (else a scope-less one, else helo), as one JSON array [domain, result, scope];
// rows from reports stored before auth_results existed have has_auth = 0 and spf = NULL.
export async function getSpfAnalysis(db: D1Database, days: number, domain?: string, date?: string, tzMinutes = 0) {
  const { clause, params } = domainFilter(domain);
  const { clause: dateClause, params: dateParams } = dateFilter(date, tzMinutes);
  const base = `
    WITH base AS (
      SELECT rr.report_id, rr.source_ip, rr.header_from, rr.count, rr.spf_result, rr.dkim_result,
        rr.reason_type, r.aspf, r.domain AS policy_domain,
        EXISTS (SELECT 1 FROM auth_results a
          WHERE a.report_id = rr.report_id AND a.source_ip = rr.source_ip AND a.header_from = rr.header_from) AS has_auth,
        (SELECT json_array(a.domain, a.result, a.scope) FROM auth_results a
          WHERE a.report_id = rr.report_id AND a.source_ip = rr.source_ip AND a.header_from = rr.header_from AND a.kind = 'spf'
          ORDER BY CASE a.scope WHEN 'mfrom' THEN 0 WHEN '' THEN 1 ELSE 2 END, a.id
          LIMIT 1) AS spf
      FROM record_rows rr
      JOIN reports r ON r.report_id = rr.report_id
      WHERE rr.date_range_begin >= unixepoch('now', '-' || ? || ' days')
      ${clause}
      ${dateClause}
    )`;
  const bindings = [days, ...params, ...dateParams];

  const [totals, rows, dkim, dkimBySource] = await Promise.all([
    db
      .prepare(
        `${base}
        SELECT
          COALESCE(SUM(count), 0) AS total,
          COALESCE(SUM(CASE WHEN spf_result = 1 THEN count ELSE 0 END), 0) AS spf_aligned,
          COALESCE(SUM(CASE WHEN dkim_result = 1 THEN count ELSE 0 END), 0) AS dkim_aligned,
          COALESCE(SUM(CASE WHEN has_auth THEN count ELSE 0 END), 0) AS with_auth
        FROM base`
      )
      .bind(...bindings)
      .first(),
    db
      .prepare(
        `${base}
        SELECT
          policy_domain, header_from, source_ip, spf, has_auth,
          MAX(aspf) AS aspf,
          SUM(count) AS total,
          SUM(CASE WHEN spf_result = 1 THEN count ELSE 0 END) AS spf_aligned,
          SUM(CASE WHEN dkim_result = 1 THEN count ELSE 0 END) AS dkim_aligned,
          SUM(CASE WHEN reason_type IN (1, 3, 4) THEN count ELSE 0 END) AS forwarded
        FROM base
        GROUP BY policy_domain, header_from, source_ip, spf, has_auth
        ORDER BY SUM(count) DESC
        LIMIT ?`
      )
      .bind(...bindings, SPF_ANALYSIS_ROW_LIMIT + 1)
      .all(),
    db
      .prepare(
        `${base}
        SELECT a.domain, a.selector, a.result, SUM(b.count) AS messages
        FROM base b
        JOIN auth_results a ON a.report_id = b.report_id AND a.source_ip = b.source_ip
          AND a.header_from = b.header_from AND a.kind = 'dkim'
        GROUP BY a.domain, a.selector, a.result
        ORDER BY messages DESC
        LIMIT 50`
      )
      .bind(...bindings)
      .all(),
    // The same signatures per source, for the source table.
    db
      .prepare(
        `${base}
        SELECT b.header_from, b.source_ip, a.domain, a.selector, a.result, SUM(b.count) AS messages
        FROM base b
        JOIN auth_results a ON a.report_id = b.report_id AND a.source_ip = b.source_ip
          AND a.header_from = b.header_from AND a.kind = 'dkim'
        GROUP BY b.header_from, b.source_ip, a.domain, a.selector, a.result
        ORDER BY messages DESC
        LIMIT ?`
      )
      .bind(...bindings, SPF_ANALYSIS_ROW_LIMIT * 3)
      .all(),
  ]);

  return {
    totals,
    rows: rows.results.slice(0, SPF_ANALYSIS_ROW_LIMIT),
    truncated: rows.results.length > SPF_ANALYSIS_ROW_LIMIT,
    dkim: dkim.results,
    dkimBySource: dkimBySource.results,
  };
}

// The receiving address is public, so junk mail could fill the table: keep at most this
// many failures per day (the log still has every one), each with at most this much content.
const INGEST_ERRORS_PER_DAY = 50;
export const INGEST_CONTENT_MAX = 256 * 1024;

export interface IngestError {
  sender: string;
  stage: "mime" | "attachment" | "report";
  error: string;
  filename?: string;
  mimeType?: string;
  size?: number;
  content?: string;
  contentType?: "xml" | "base64";
}

// Never throws: failing to record a failure must not make Email Routing retry the message.
export async function recordIngestError(db: D1Database, e: IngestError): Promise<void> {
  const content = e.content ?? "";
  try {
    await db
      .prepare(
        `INSERT INTO ingest_errors (sender, stage, error, filename, mime_type, size, content, content_type, content_truncated)
         SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?
         WHERE (SELECT COUNT(*) FROM ingest_errors WHERE received_at >= unixepoch('now', '-1 day')) < ?`
      )
      .bind(
        e.sender,
        e.stage,
        e.error.slice(0, 500),
        e.filename ?? "",
        e.mimeType ?? "",
        e.size ?? 0,
        content.slice(0, INGEST_CONTENT_MAX),
        content ? e.contentType ?? "" : "",
        content.length > INGEST_CONTENT_MAX ? 1 : 0,
        INGEST_ERRORS_PER_DAY
      )
      .run();
  } catch (err) {
    console.error("Recording the ingest error failed:", err instanceof Error ? err.message : err);
  }
}

// All failures not dismissed yet, without their content.
export async function getIngestErrors(db: D1Database) {
  const result = await db
    .prepare(
      `SELECT id, received_at, sender, stage, error, filename, mime_type, size, content_type, content_truncated
       FROM ingest_errors
       ORDER BY received_at DESC, id DESC
       LIMIT 200`
    )
    .all();
  return result.results;
}

export async function getIngestErrorContent(db: D1Database, id: number) {
  return db
    .prepare("SELECT content, content_type, content_truncated, filename FROM ingest_errors WHERE id = ?")
    .bind(id)
    .first();
}

// Dismissing removes the failure for good. ingest_errors holds only diagnostics: this is
// the one delete path that the dashboard exposes, and it never touches report data.
export async function dismissIngestError(db: D1Database, id: number): Promise<boolean> {
  const result = await db.prepare("DELETE FROM ingest_errors WHERE id = ?").bind(id).run();
  return result.meta.changes > 0;
}

// One row per reporting organization: how many reports it sent and its latest report
// (by received time). All time, so a reporter that stopped sending stays visible.
export async function getReporters(db: D1Database, domain?: string) {
  const where = domain ? "WHERE domain = ?" : "";
  const params = domain ? [domain] : [];
  const result = await db
    .prepare(
      `WITH ranked AS (
        SELECT org_name, report_id, received_at, date_range_end,
          ROW_NUMBER() OVER (PARTITION BY org_name ORDER BY received_at DESC, id DESC) AS rn,
          COUNT(*) OVER (PARTITION BY org_name) AS reports
        FROM reports
        ${where}
      )
      SELECT org_name, reports, received_at AS last_received_at, report_id AS last_report_id,
        date_range_end AS last_range_end
      FROM ranked
      WHERE rn = 1
      ORDER BY received_at DESC`
    )
    .bind(...params)
    .all();
  return result.results;
}
