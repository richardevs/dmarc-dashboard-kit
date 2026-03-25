import { Env } from "./types";
import {
  getDomains,
  getSummary,
  getTimeSeries,
  getTopSenders,
  getAllSenders,
  getAllSenderIps,
  getDomainAuth,
  getReports,
  getReportDetail,
} from "./db";

// Module-level rate limit guard for ip-api.com
let rateLimitUntil = 0;

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export async function handleFetch(
  request: Request,
  env: Env,
  _ctx: ExecutionContext
): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;

  // Only handle /api/* routes; static assets are served by wrangler
  if (!path.startsWith("/api/")) return new Response(null, { status: 404 });

  try {
    return await route(path, url.searchParams, env, request);
  } catch {
    return json({ error: "Internal server error" }, 500);
  }
}

async function route(
  path: string,
  params: URLSearchParams,
  env: Env,
  request: Request
): Promise<Response> {
  const days = parseInt(params.get("days") || "30") || 30;
  const domain = params.get("domain") || undefined;
  const date = params.get("date") || undefined;
  const tz = parseInt(params.get("tz") || "0") || 0;

  // GET /api/health
  if (path === "/api/health") {
    return json({ ok: true, timestamp: new Date().toISOString() });
  }

  // GET /api/domains
  if (path === "/api/domains") {
    return json(await getDomains(env.DB));
  }

  // GET /api/summary?days=30&domain=&date=
  if (path === "/api/summary") {
    return json(await getSummary(env.DB, days, domain, date, tz));
  }

  // GET /api/timeseries?days=30&domain=
  if (path === "/api/timeseries") {
    return json(await getTimeSeries(env.DB, days, domain, tz));
  }

  // GET /api/domain-auth?days=30&date=
  if (path === "/api/domain-auth") {
    return json(await getDomainAuth(env.DB, days, date, tz));
  }

  // GET /api/top-senders?days=30&limit=10&domain=&date=
  if (path === "/api/top-senders") {
    const limit = parseInt(params.get("limit") || "10") || 10;
    return json(await getTopSenders(env.DB, days, limit, domain, date, tz));
  }

  // GET /api/all-senders?days=30&page=1&pageSize=20&domain=&sort=&dir=&date=
  if (path === "/api/all-senders") {
    const page = parseInt(params.get("page") || "1") || 1;
    const pageSize = parseInt(params.get("pageSize") || "20") || 20;
    const sort = params.get("sort") || undefined;
    const dir = params.get("dir") || undefined;
    return json(await getAllSenders(env.DB, days, page, pageSize, domain, sort, dir, date, tz));
  }

  // GET /api/reports?page=1&pageSize=20&domain=&sort=&dir=&date=
  if (path === "/api/reports") {
    const page = parseInt(params.get("page") || "1") || 1;
    const pageSize = parseInt(params.get("pageSize") || "20") || 20;
    const sort = params.get("sort") || undefined;
    const dir = params.get("dir") || undefined;
    return json(await getReports(env.DB, page, pageSize, domain, sort, dir, date, tz));
  }

  // GET /api/all-sender-ips?days=30&domain=&date=
  if (path === "/api/all-sender-ips") {
    return json(await getAllSenderIps(env.DB, days, domain, date, tz));
  }

  // POST /api/ip-info — proxies batch IP geolocation to ip-api.com
  if (path === "/api/ip-info" && request.method === "POST") {
    const now = Date.now();
    if (now < rateLimitUntil) {
      const retryAfter = Math.ceil((rateLimitUntil - now) / 1000);
      return json({ error: "rate_limited", retryAfter }, 429);
    }
    const body = await request.json() as { ips?: unknown };
    const ips = body.ips;
    if (!Array.isArray(ips) || ips.length === 0 || ips.length > 100 || !ips.every((i) => typeof i === "string")) {
      return json({ error: "ips must be an array of 1-100 strings" }, 400);
    }
    const payload = (ips as string[]).map((ip) => ({ query: ip, fields: "query,country,countryCode,org" }));
    const upstream = await fetch("http://ip-api.com/batch", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const rl = parseInt(upstream.headers.get("X-Rl") ?? "1");
    const ttl = parseInt(upstream.headers.get("X-Ttl") ?? "60");
    if (rl === 0 || upstream.status === 429) {
      rateLimitUntil = Date.now() + ttl * 1000;
    }
    if (upstream.status === 429) {
      return json({ error: "rate_limited", retryAfter: ttl }, 429);
    }
    return json(await upstream.json());
  }

  // GET /api/reports/:reportId — not called by the dashboard; available for future detail views or external consumers
  const reportMatch = path.match(/^\/api\/reports\/(.+)$/);
  if (reportMatch) {
    const detail = await getReportDetail(env.DB, decodeURIComponent(reportMatch[1]));
    if (!detail) return json({ error: "not found" }, 404);
    return json(detail);
  }

  return new Response(null, { status: 404 });
}
