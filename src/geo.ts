import { Buffer } from "node:buffer";
import { Reader, type AsnResponse, type CountryResponse } from "mmdb-lib";
import { Env } from "./types";

// IP geolocation from the DB-IP Lite databases (CC BY 4.0, attribution in the dashboard).
// deploy.sh downloads them into the static assets; the worker reads them through the
// ASSETS binding, so lookups need no external API, token, or rate limit.
const COUNTRY_DB = "/_geo/dbip-country-lite.mmdb";
const ASN_DB = "/_geo/dbip-asn-lite.mmdb";


export interface IpInfo {
  query: string;
  country: string;
  countryCode: string;
  org: string;
}

// Loaded once per isolate and reused across requests.
let readers: Promise<{ country: Reader<CountryResponse> | null; asn: Reader<AsnResponse> | null }> | null = null;

async function loadReader<T extends CountryResponse | AsnResponse>(env: Env, path: string): Promise<Reader<T> | null> {
  const res = await env.ASSETS.fetch(new Request(`https://assets.local${path}`));
  // Missing databases (e.g. local dev without a deploy) leave the fields empty.
  if (!res.ok || res.headers.get("content-type")?.includes("text/html")) return null;
  return new Reader<T>(Buffer.from(await res.arrayBuffer()));
}

function getReaders(env: Env) {
  readers ??= Promise.all([
    loadReader<CountryResponse>(env, COUNTRY_DB),
    loadReader<AsnResponse>(env, ASN_DB),
  ]).then(([country, asn]) => ({ country, asn }));
  return readers;
}

export async function lookupIps(env: Env, ips: string[]): Promise<IpInfo[]> {
  const { country, asn } = await getReaders(env);
  return ips.map((ip) => {
    let c: CountryResponse | null = null;
    let a: AsnResponse | null = null;
    try {
      c = country?.get(ip) ?? null;
      a = asn?.get(ip) ?? null;
    } catch {
      // Not a valid IP address — return empty fields.
    }
    return {
      query: ip,
      country: c?.country?.names?.en ?? "",
      countryCode: c?.country?.iso_code ?? "",
      org: a?.autonomous_system_organization ?? "",
    };
  });
}
