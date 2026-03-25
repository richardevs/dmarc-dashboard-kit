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

export function getAllSenderIps(days: string, domain?: string, date?: string): Promise<string[]> {
  return cachedFetchJSON("/api/all-sender-ips", { days, domain: domain || "", date: date || "", tz: tzOffset });
}

export interface IpInfo {
  query: string;
  country: string;
  countryCode: string;
  org: string;
}

const IP_CACHE_KEY = "ip-geo-cache";
const IP_CACHE_MAX = 5000;

export interface IpInfoResult {
  data: Record<string, IpInfo>;
  retryAfter: number; // seconds; 0 = not rate-limited
}

export async function fetchIpInfo(ips: string[]): Promise<IpInfoResult> {
  let cache: Record<string, IpInfo> = {};
  try {
    cache = JSON.parse(localStorage.getItem(IP_CACHE_KEY) || "{}");
  } catch { /* ignore corrupt cache */ }

  const uncached = ips.filter((ip) => !cache[ip]);
  let retryAfter = 0;

  if (uncached.length > 0) {
    for (let i = 0; i < uncached.length; i += 100) {
      const chunk = uncached.slice(i, i + 100);
      const res = await fetch("/api/ip-info", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ips: chunk }),
      });
      if (res.status === 429) {
        const body = await res.json() as { retryAfter?: number };
        retryAfter = body.retryAfter ?? 60;
        break; // stop sending remaining chunks
      }
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
  return { data, retryAfter };
}

