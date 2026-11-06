const tzOffset = String(-new Date().getTimezoneOffset());

async function fetchJSON<T>(path: string, params: Record<string, string> = {}): Promise<T> {
  const url = new URL(path, window.location.origin);
  for (const [k, v] of Object.entries(params)) {
    if (v) url.searchParams.set(k, v);
  }
  const res = await fetch(url.toString());
  if (!res.ok) throw new Error(`API error: ${res.status}`);
  return res.json();
}

const pageCache = new Map<string, any>();

async function cachedFetchJSON<T>(path: string, params: Record<string, string> = {}): Promise<T> {
  const url = new URL(path, window.location.origin);
  for (const [k, v] of Object.entries(params)) {
    if (v) url.searchParams.set(k, v);
  }
  const key = url.toString();
  if (pageCache.has(key)) return pageCache.get(key);
  const res = await fetch(key);
  if (!res.ok) throw new Error(`API error: ${res.status}`);
  const data = await res.json();
  pageCache.set(key, data);
  return data;
}

export function clearPageCache() {
  pageCache.clear();
}

export interface Summary {
  total_messages: number;
  pass_count: number;
  fail_count: number;
  unique_sources: number;
  total_reports: number;
}

export interface TimeSeriesPoint {
  date: string;
  pass_count: number;
  fail_count: number;
  total: number;
}

export interface TopSender {
  source_ip: string;
  total_count: number;
  pass_count: number;
  fail_count: number;
  spf_fail_count: number;
  dkim_fail_count: number;
}

export interface DomainAuth {
  domain: string;
  total: number;
  spf_pass: number;
  dkim_pass: number;
  policy_p: number;
}

export interface ReportListItem {
  report_id: string;
  org_name: string;
  domain: string;
  date_range_begin: number;
  date_range_end: number;
  received_at: string;
  total_count: number;
}

export interface ReportList {
  data: ReportListItem[];
  total: number;
  page: number;
  pageSize: number;
}


export function getDomains(): Promise<string[]> {
  return fetchJSON("/api/domains");
}

export function getSummary(days: string, domain?: string, date?: string): Promise<Summary> {
  return cachedFetchJSON("/api/summary", { days, domain: domain || "", date: date || "", tz: tzOffset });
}

export function getTimeSeries(days: string, domain?: string): Promise<TimeSeriesPoint[]> {
  return cachedFetchJSON("/api/timeseries", { days, domain: domain || "", tz: tzOffset });
}

export function getDomainAuth(days: string, date?: string): Promise<DomainAuth[]> {
  return cachedFetchJSON("/api/domain-auth", { days, date: date || "", tz: tzOffset });
}

export interface SenderList {
  data: TopSender[];
  total: number;
  page: number;
  pageSize: number;
}

export function getTopSenders(days: string, limit = "10", domain?: string, date?: string): Promise<TopSender[]> {
  return cachedFetchJSON("/api/top-senders", { days, limit, domain: domain || "", date: date || "", tz: tzOffset });
}

export function getAllSenders(days: string, page = "1", pageSize = "20", domain?: string, sort?: string, dir?: string, date?: string): Promise<SenderList> {
  return cachedFetchJSON("/api/all-senders", { days, page, pageSize, domain: domain || "", sort: sort || "", dir: dir || "", date: date || "", tz: tzOffset });
}

export function getReports(page = "1", pageSize = "20", domain?: string, sort?: string, dir?: string, date?: string): Promise<ReportList> {
  return cachedFetchJSON("/api/reports", { page, pageSize, domain: domain || "", sort: sort || "", dir: dir || "", date: date || "", tz: tzOffset });
}

export interface IpInfo {
  query: string;
  country: string;
  countryCode: string;
  org: string;
}

const IP_CACHE_KEY = "ip-geo-cache";
const IP_CACHE_MAX = 5000;

export async function fetchIpInfo(ips: string[]): Promise<Record<string, IpInfo>> {
  let cache: Record<string, IpInfo> = {};
  try {
    cache = JSON.parse(localStorage.getItem(IP_CACHE_KEY) || "{}");
  } catch { /* ignore corrupt cache */ }

  const uncached = ips.filter((ip) => !cache[ip]);

  if (uncached.length > 0) {
    for (let i = 0; i < uncached.length; i += 100) {
      const chunk = uncached.slice(i, i + 100);
      const res = await fetch("/api/ip-info", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ips: chunk }),
      });
      if (res.ok) {
        const results: IpInfo[] = await res.json();
        for (const r of results) {
          cache[r.query] = r;
        }
      }
    }

    // Enforce max cache size: drop oldest entries
    const keys = Object.keys(cache);
    if (keys.length > IP_CACHE_MAX) {
      const toDelete = keys.slice(0, keys.length - IP_CACHE_MAX);
      for (const k of toDelete) delete cache[k];
    }
    localStorage.setItem(IP_CACHE_KEY, JSON.stringify(cache));
  }

  const data: Record<string, IpInfo> = {};
  for (const ip of ips) {
    if (cache[ip]) data[ip] = cache[ip];
  }
  return data;
}


export interface SpfAnalysisRow {
  policy_domain: string;
  header_from: string;
  source_ip: string;
  spf: string | null; // JSON [domain, result, scope] from auth_results; null for older reports
  has_auth: number;
  aspf: number;
  total: number;
  spf_aligned: number;
  dkim_aligned: number;
  forwarded: number;
}

export interface DkimSignature {
  domain: string;
  selector: string;
  result: string;
  messages: number;
}

export interface SourceDkimSignature extends DkimSignature {
  header_from: string;
  source_ip: string;
}

export interface SpfAnalysis {
  totals: { total: number; spf_aligned: number; dkim_aligned: number; with_auth: number };
  rows: SpfAnalysisRow[];
  truncated: boolean;
  dkim: DkimSignature[]; // all sources; picks the selectors for the DNS record checks
  dkimBySource: SourceDkimSignature[];
}

export function getSpfAnalysis(days: string, domain?: string, date?: string): Promise<SpfAnalysis> {
  return cachedFetchJSON("/api/spf-analysis", { days, domain: domain || "", date: date || "", tz: tzOffset });
}

export interface IngestErrorItem {
  id: number;
  received_at: number;
  sender: string;
  stage: "mime" | "attachment" | "report";
  error: string;
  filename: string;
  mime_type: string;
  size: number;
  content_type: "" | "xml" | "base64";
  content_truncated: number;
}

export interface IngestErrorContent {
  content: string;
  content_type: "" | "xml" | "base64";
  content_truncated: number;
  filename: string;
}

// Not cached: the list changes when a failure is dismissed.
export function getIngestErrors(): Promise<IngestErrorItem[]> {
  return fetchJSON("/api/ingest-errors");
}

export function getIngestErrorContent(id: number): Promise<IngestErrorContent> {
  return fetchJSON(`/api/ingest-errors/${id}`);
}

export async function dismissIngestError(id: number): Promise<void> {
  const res = await fetch(new URL(`/api/ingest-errors/${id}`, window.location.origin), { method: "DELETE" });
  if (!res.ok && res.status !== 404) throw new Error(`API error: ${res.status}`);
}

export interface Reporter {
  org_name: string;
  reports: number;
  last_received_at: string; // UTC, "YYYY-MM-DD HH:MM:SS"
  last_report_id: string;
  last_range_end: number;
}

export function getReporters(domain?: string): Promise<Reporter[]> {
  return cachedFetchJSON("/api/reporters", { domain: domain || "" });
}
