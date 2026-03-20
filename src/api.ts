import { Env } from "./types";
import {
  getDomains,
  getSummary,
  getTimeSeries,
  getTopSenders,
  getAllSenders,
  getDomainAuth,
  getReports,
  getReportDetail,
} from "./db";

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
    return await route(path, url.searchParams, env);
  } catch {
    return json({ error: "Internal server error" }, 500);
  }
}

async function route(
  path: string,
  params: URLSearchParams,
  env: Env
): Promise<Response> {
  const days = parseInt(params.get("days") || "30") || 30;
  const domain = params.get("domain") || undefined;
  const date = params.get("date") || undefined;

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
    return json(await getSummary(env.DB, days, domain, date));
  }

  // GET /api/timeseries?days=30&domain=
  if (path === "/api/timeseries") {
    return json(await getTimeSeries(env.DB, days, domain));
  }

  // GET /api/domain-auth?days=30&date=
  if (path === "/api/domain-auth") {
    return json(await getDomainAuth(env.DB, days, date));
  }

  // GET /api/top-senders?days=30&limit=10&domain=&date=
  if (path === "/api/top-senders") {
    const limit = parseInt(params.get("limit") || "10") || 10;
    return json(await getTopSenders(env.DB, days, limit, domain, date));
  }

  // GET /api/all-senders?days=30&page=1&pageSize=20&domain=&sort=&dir=&date=
  if (path === "/api/all-senders") {
    const page = parseInt(params.get("page") || "1") || 1;
    const pageSize = parseInt(params.get("pageSize") || "20") || 20;
    const sort = params.get("sort") || undefined;
    const dir = params.get("dir") || undefined;
    return json(await getAllSenders(env.DB, days, page, pageSize, domain, sort, dir, date));
  }

  // GET /api/reports?page=1&pageSize=20&domain=&sort=&dir=&date=
  if (path === "/api/reports") {
    const page = parseInt(params.get("page") || "1") || 1;
    const pageSize = parseInt(params.get("pageSize") || "20") || 20;
    const sort = params.get("sort") || undefined;
    const dir = params.get("dir") || undefined;
    return json(await getReports(env.DB, page, pageSize, domain, sort, dir, date));
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
