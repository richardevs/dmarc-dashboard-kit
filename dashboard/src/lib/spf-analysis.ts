import type { SpfAnalysis, SpfAnalysisRow } from "./api";
import { isAligned, type SpfCheck } from "./spf";

// How a message did on SPF, from the report's <auth_results>:
//   aligned:      SPF passed for a domain that aligns with the From domain
// and, when it did not align, why:
//   return-path:  SPF passed for another (bounce) domain; DKIM aligns, so DMARC passes
//   ip:           SPF was checked on the From domain, and the sending IP is not authorized
//   both:         another domain, and SPF failed there too (typically forwarded mail)
//   unauthorized: SPF passed for an unrelated domain and DKIM does not align: DMARC fails
//                 (typically spoofing: the sender's own domain authorizes the IP)
//   unknown:      the report has SPF details, but they do not explain the result
//   no-data:      the report has no SPF details (stored before 2.5.0); no guess is made
export type Reason = "aligned" | "return-path" | "ip" | "both" | "unauthorized" | "unknown" | "no-data";
export const REASONS: Reason[] = ["aligned", "return-path", "ip", "both", "unauthorized", "unknown", "no-data"];

export const REASON_LABEL: Record<Reason, string> = {
  aligned: "SPF aligned",
  "return-path": "Return-Path on another domain",
  ip: "IP not in your SPF record",
  both: "Another domain, SPF failed",
  unauthorized: "Another domain, DMARC fails",
  unknown: "Unknown reason",
  "no-data": "No SPF details yet",
};

// A source group's aligned and non-aligned messages are separate diagnoses.
export interface Diagnosis {
  row: SpfAnalysisRow;
  messages: number;
  reason: Reason;
  spfDomain: string; // the Return-Path domain that SPF checked ("" when the report has none)
  spfResult: string;
  spfAligned: boolean; // the Return-Path domain aligns with the From domain
  current?: SpfCheck; // "ip" rows only: the IP against the From domain's SPF record today
}

export interface SpfReport {
  diagnoses: Diagnosis[];
  byReason: Record<Reason, number>;
  notAligned: number; // all messages except "aligned"
}

function parseSpf(spf: string | null): { domain: string; result: string } | null {
  if (!spf) return null;
  try {
    const [domain, result] = JSON.parse(spf) as [string, string, string];
    return { domain: domain ?? "", result: result ?? "" };
  } catch {
    return null;
  }
}

export function checkKey(headerFrom: string, ip: string): string {
  return `${headerFrom.toLowerCase()} ${ip}`;
}

function diagnose(row: SpfAnalysisRow, checks: Map<string, SpfCheck>): Diagnosis[] {
  const spf = row.has_auth ? parseSpf(row.spf) : null;
  const out: Diagnosis[] = [];
  const base = { row, spfDomain: spf?.domain ?? "", spfResult: spf?.result ?? "", spfAligned: false };

  if (row.spf_aligned > 0) out.push({ ...base, messages: row.spf_aligned, reason: "aligned", spfAligned: true });

  const notAligned = row.total - row.spf_aligned;
  if (notAligned === 0) return out;
  if (!row.has_auth) return [...out, { ...base, messages: notAligned, reason: "no-data" }];
  if (!spf || !spf.domain) return [...out, { ...base, messages: notAligned, reason: "unknown" }];

  const aligned = isAligned(spf.domain, row.header_from, row.aspf === 1);
  const passed = spf.result === "pass";
  const dkimAligned = row.dkim_aligned * 2 >= row.total;
  let reason: Reason;
  if (passed && !aligned) reason = dkimAligned ? "return-path" : "unauthorized";
  else if (!passed && aligned) reason = "ip";
  else if (!passed && !aligned) reason = "both";
  else reason = "unknown"; // aligned pass the receiver still counted as not aligned
  out.push({
    ...base,
    messages: notAligned,
    reason,
    spfAligned: aligned,
    // Only here does the From domain's own record decide the result.
    current: reason === "ip" ? checks.get(checkKey(row.header_from, row.source_ip)) : undefined,
  });
  return out;
}

// checks: each (From domain, source IP) evaluated against today's SPF record of the From domain.
export function analyzeSpf(analysis: SpfAnalysis, checks: Map<string, SpfCheck>): SpfReport {
  const byReason = Object.fromEntries(REASONS.map((r) => [r, 0])) as Record<Reason, number>;
  const diagnoses = analysis.rows.flatMap((row) => diagnose(row, checks));

  for (const d of diagnoses) byReason[d.reason] += d.messages;

  const notAligned = REASONS.reduce((sum, r) => (r === "aligned" ? sum : sum + byReason[r]), 0);
  diagnoses.sort((a, b) => b.messages - a.messages);
  return { diagnoses, byReason, notAligned };
}
