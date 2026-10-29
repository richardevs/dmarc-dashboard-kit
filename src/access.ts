import { createRemoteJWKSet, jwtVerify } from "jose";
import { Env } from "./types";

// Cloudflare Access already guards the dashboard host; this check keeps the API closed
// if Access ever stops covering it (app deleted, a Bypass policy, another route).
// The team domain and AUD come from deploy.sh, never from the token: every Zero Trust
// team signs valid tokens, so only a pinned issuer and audience identify ours.

// One key set per isolate; jose caches the keys and refetches on rotation.
let jwks: { team: string; set: ReturnType<typeof createRemoteJWKSet> } | undefined;

export async function isAccessAuthorized(request: Request, env: Env): Promise<boolean> {
  const team = env.ACCESS_TEAM_DOMAIN;
  const aud = env.ACCESS_AUD;
  if (!team || !aud) {
    // Only local dev (`cf dev`) runs without them; a deployed worker fails closed.
    const host = new URL(request.url).hostname;
    return host === "localhost" || host === "127.0.0.1";
  }
  const token = request.headers.get("Cf-Access-Jwt-Assertion");
  if (!token) return false;
  if (jwks?.team !== team) {
    jwks = { team, set: createRemoteJWKSet(new URL(`https://${team}/cdn-cgi/access/certs`)) };
  }
  try {
    await jwtVerify(token, jwks.set, { issuer: `https://${team}`, audience: aud, algorithms: ["RS256"] });
    return true;
  } catch {
    return false;
  }
}
