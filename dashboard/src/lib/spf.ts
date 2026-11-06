// SPF evaluation in the browser: records come from Cloudflare's DNS-over-HTTPS JSON API
// (CORS-enabled) and are cached in localStorage for their DNS TTL. Source IPs are matched
// locally. An `exists:` term with an IP macro (exists:%{i}._spf.example.com) would need a
// query that contains the IP: checkIp never makes it, and the term counts as undetermined.

const DOH_URL = "https://cloudflare-dns.com/dns-query";
const DNS_CACHE_KEY = "spf-dns-cache";
const DNS_CACHE_MAX = 1000;
const MIN_TTL = 60;
const MAX_TTL = 3600;
const NEGATIVE_TTL = 300;

// RFC 7208 §4.6.4: at most 10 DNS-querying terms and 2 void lookups per evaluation.
export const SPF_LOOKUP_LIMIT = 10;
export const SPF_VOID_LIMIT = 2;
// Our own ceiling, so a looping or huge tree stays cheap; terms past it are not resolved.
const HARD_LOOKUP_CAP = 40;

type RRType = "TXT" | "A" | "AAAA" | "MX";
const RR_CODES: Record<RRType, number> = { A: 1, MX: 15, TXT: 16, AAAA: 28 };

interface DnsAnswer {
  ok: boolean; // false: temporary failure (network, SERVFAIL)
  data: string[]; // empty: NXDOMAIN or no records of this type
}

type DnsCache = Record<string, { exp: number; ok: boolean; data: string[] }>;

let dnsCache: DnsCache | null = null;
const inflight = new Map<string, Promise<DnsAnswer>>();

function loadCache(): DnsCache {
  if (dnsCache) return dnsCache;
  try {
    dnsCache = JSON.parse(localStorage.getItem(DNS_CACHE_KEY) || "{}");
  } catch {
    dnsCache = {};
  }
  return dnsCache!;
}

function saveCache() {
  const cache = loadCache();
  const now = Date.now();
  for (const [k, v] of Object.entries(cache)) if (v.exp <= now) delete cache[k];
  const keys = Object.keys(cache);
  for (const k of keys.slice(0, Math.max(0, keys.length - DNS_CACHE_MAX))) delete cache[k];
  try {
    localStorage.setItem(DNS_CACHE_KEY, JSON.stringify(cache));
  } catch { /* storage full: the in-memory cache still works */ }
}

export function clearSpfCache() {
  dnsCache = {};
  localStorage.removeItem(DNS_CACHE_KEY);
}

export async function query(name: string, type: RRType): Promise<DnsAnswer> {
  const key = `${type} ${name}`;
  const cached = loadCache()[key];
  if (cached && cached.exp > Date.now()) return { ok: cached.ok, data: cached.data };
  let pending = inflight.get(key);
  if (!pending) {
    pending = fetchDns(name, type).finally(() => inflight.delete(key));
    inflight.set(key, pending);
  }
  return pending;
}

async function fetchDns(name: string, type: RRType): Promise<DnsAnswer> {
  const url = `${DOH_URL}?name=${encodeURIComponent(name)}&type=${type}`;
  let body: { Status: number; Answer?: { type: number; TTL: number; data: string }[] };
  try {
    const res = await fetch(url, { headers: { accept: "application/dns-json" } });
    if (!res.ok) return { ok: false, data: [] };
    body = await res.json();
  } catch {
    return { ok: false, data: [] };
  }
  // 0 = NOERROR, 3 = NXDOMAIN; anything else (SERVFAIL, REFUSED) is temporary.
  if (body.Status !== 0 && body.Status !== 3) return { ok: false, data: [] };
  const answers = (body.Answer ?? []).filter((a) => a.type === RR_CODES[type]);
  const ttl = answers.length
    ? Math.min(MAX_TTL, Math.max(MIN_TTL, Math.min(...answers.map((a) => a.TTL))))
    : NEGATIVE_TTL;
  const data = answers.map((a) => (type === "TXT" ? parseTxt(a.data) : a.data));
  loadCache()[`${type} ${name}`] = { exp: Date.now() + ttl * 1000, ok: true, data };
  saveCache();
  return { ok: true, data };
}

// TXT data arrives as one or more quoted strings ("v=spf1 ..." "more"); join them.
function parseTxt(data: string): string {
  if (!data.startsWith('"')) return data;
  const parts = data.match(/"((?:[^"\\]|\\.)*)"/g) ?? [];
  return parts.map((p) => p.slice(1, -1).replace(/\\(.)/g, "$1")).join("");
}

// --- IP addresses and CIDR ranges ---

export interface Cidr {
  v: 4 | 6;
  net: bigint;
  bits: number;
}

function parseIPv4(ip: string): bigint | null {
  const parts = ip.split(".");
  if (parts.length !== 4) return null;
  let n = 0n;
  for (const p of parts) {
    if (!/^\d{1,3}$/.test(p) || Number(p) > 255) return null;
    n = (n << 8n) | BigInt(Number(p));
  }
  return n;
}

function parseIPv6(ip: string): bigint | null {
  let s = ip.toLowerCase();
  // Embedded IPv4 tail (::ffff:192.0.2.1)
  const v4 = s.match(/^(.*:)(\d+\.\d+\.\d+\.\d+)$/);
  if (v4) {
    const n = parseIPv4(v4[2]);
    if (n === null) return null;
    s = `${v4[1]}${(n >> 16n).toString(16)}:${(n & 0xffffn).toString(16)}`;
  }
  const halves = s.split("::");
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(":") : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  const fill = 8 - head.length - tail.length;
  if (halves.length === 1 ? fill !== 0 : fill < 1) return null;
  const groups = [...head, ...Array(halves.length === 2 ? fill : 0).fill("0"), ...tail];
  let n = 0n;
  for (const g of groups) {
    if (!/^[0-9a-f]{1,4}$/.test(g)) return null;
    n = (n << 16n) | BigInt(parseInt(g, 16));
  }
  return n;
}

export function parseIp(ip: string): { v: 4 | 6; n: bigint } | null {
  if (ip.includes(":")) {
    const n = parseIPv6(ip);
    if (n === null) return null;
    // IPv4-mapped addresses are checked as IPv4 (RFC 7208 §5).
    if (n >> 32n === 0xffffn) return { v: 4, n: n & 0xffffffffn };
    return { v: 6, n };
  }
  const n = parseIPv4(ip);
  return n === null ? null : { v: 4, n };
}

function toCidr(addr: string, bits: number | undefined): Cidr | null {
  const ip = parseIp(addr);
  if (!ip) return null;
  const width = ip.v === 4 ? 32 : 128;
  const b = bits ?? width;
  if (b < 0 || b > width) return null;
  return { v: ip.v, net: ip.n, bits: b };
}

function inCidr(ip: { v: 4 | 6; n: bigint }, c: Cidr): boolean {
  if (ip.v !== c.v) return false;
  const shift = BigInt((ip.v === 4 ? 32 : 128) - c.bits);
  return ip.n >> shift === c.net >> shift;
}

// --- SPF record tree ---

export type SpfResult = "pass" | "fail" | "softfail" | "neutral" | "none" | "permerror" | "temperror" | "unknown";
type Qualifier = "+" | "-" | "~" | "?";

interface Term {
  raw: string;
  qualifier: Qualifier;
  kind: "ip" | "a" | "mx" | "include" | "exists" | "all" | "unsupported";
  cidrs: Cidr[];
  spec?: string; // exists: domain-spec, possibly with macros
  child?: SpfNode;
  note?: string; // why an unsupported term was skipped
}

export interface SpfNode {
  domain: string;
  record: string | null;
  error?: "none" | "permerror" | "temperror" | "unknown";
  terms: Term[];
  redirect?: SpfNode;
}

export interface SpfTree {
  domain: string;
  root: SpfNode;
  lookups: number; // DNS-querying terms, counted as receivers do
  voidLookups: number;
  problems: string[];
}

interface Ctx {
  lookups: number;
  voidLookups: number;
  problems: string[];
}

const QUALIFIER_RESULT: Record<Qualifier, SpfResult> = { "+": "pass", "-": "fail", "~": "softfail", "?": "neutral" };

function normalize(domain: string): string {
  return domain.trim().toLowerCase().replace(/\.$/, "");
}

const treeCache = new Map<string, Promise<SpfTree>>();

// Trees are kept for the page's lifetime; the DNS answers underneath expire by TTL.
export function getSpfTree(domain: string): Promise<SpfTree> {
  const d = normalize(domain);
  let tree = treeCache.get(d);
  if (!tree) {
    tree = buildTree(d);
    treeCache.set(d, tree);
    tree.catch(() => treeCache.delete(d));
  }
  return tree;
}

export function resetSpfTrees() {
  treeCache.clear();
}

async function buildTree(domain: string): Promise<SpfTree> {
  const ctx: Ctx = { lookups: 0, voidLookups: 0, problems: [] };
  const root = await buildNode(domain, ctx, []);
  if (ctx.lookups > SPF_LOOKUP_LIMIT) {
    ctx.problems.unshift(`The record needs ${ctx.lookups} DNS lookups, but the limit is ${SPF_LOOKUP_LIMIT}. Receivers return permerror, so SPF fails for all mail.`);
  }
  if (ctx.voidLookups > SPF_VOID_LIMIT) {
    ctx.problems.push(`${ctx.voidLookups} DNS lookups return no records, but the limit is ${SPF_VOID_LIMIT}. Receivers can return permerror.`);
  }
  return { domain, root, lookups: ctx.lookups, voidLookups: ctx.voidLookups, problems: ctx.problems };
}

async function buildNode(domain: string, ctx: Ctx, chain: string[]): Promise<SpfNode> {
  const node: SpfNode = { domain, record: null, terms: [] };
  if (chain.includes(domain)) {
    ctx.problems.push(`The record includes itself: ${[...chain, domain].join(" → ")}. Receivers return permerror.`);
    node.error = "permerror";
    return node;
  }
  const txt = await query(domain, "TXT");
  if (!txt.ok) {
    ctx.problems.push(`The DNS lookup for ${domain} failed. Click "Check DNS again".`);
    node.error = "temperror";
    return node;
  }
  const records = txt.data.filter((t) => /^v=spf1(\s|$)/i.test(t));
  if (records.length === 0) {
    node.error = "none";
    if (chain.length > 0) ctx.problems.push(`${chain[chain.length - 1]} includes ${domain}, but ${domain} has no SPF record. Receivers return permerror.`);
    return node;
  }
  if (records.length > 1) {
    ctx.problems.push(`${domain} has ${records.length} SPF records, but only 1 is permitted. Receivers return permerror.`);
    node.error = "permerror";
    node.record = records.join(" | ");
    return node;
  }
  node.record = records[0];
  const nextChain = [...chain, domain];

  let redirectTarget: string | null = null;
  const pending: Promise<void>[] = [];

  for (const raw of node.record.split(/\s+/).slice(1)) {
    if (!raw) continue;
    const lower = raw.toLowerCase();
    if (lower.startsWith("redirect=")) {
      redirectTarget = lower.slice("redirect=".length);
      continue;
    }
    if (/^[a-z][a-z0-9_.-]*=/.test(lower)) continue; // other modifiers (exp=, unknown)

    const qualifier: Qualifier = "+-~?".includes(raw[0]) ? (raw[0] as Qualifier) : "+";
    const body = "+-~?".includes(raw[0]) ? lower.slice(1) : lower;
    const term: Term = { raw, qualifier, kind: "unsupported", cidrs: [] };
    node.terms.push(term);

    const m = body.match(/^(all|ip4|ip6|a|mx|include|exists|ptr)(?::([^/]*))?(?:\/(\d+))?(?:\/\/(\d+))?$/);
    if (!m) {
      term.note = "not understood";
      ctx.problems.push(`${domain} has a term that is not valid: "${raw}".`);
      continue;
    }
    const [, mech, arg, len4, len6] = m;
    if (mech === "exists") {
      ctx.lookups++;
      if (arg) {
        term.kind = "exists";
        term.spec = arg;
      } else {
        term.note = "missing domain";
      }
      continue;
    }
    if (arg?.includes("%")) {
      term.note = "macros are not evaluated";
      if (mech !== "ip4" && mech !== "ip6") ctx.lookups++;
      continue;
    }

    switch (mech) {
      case "all":
        term.kind = "all";
        break;
      case "ip4":
      case "ip6": {
        const c = arg ? toCidr(arg, len4 !== undefined ? Number(len4) : undefined) : null;
        if (c) {
          term.kind = "ip";
          term.cidrs.push(c);
        } else {
          term.note = "invalid address";
        }
        break;
      }
      case "include": {
        ctx.lookups++;
        if (!arg) { term.note = "missing domain"; break; }
        if (ctx.lookups > HARD_LOOKUP_CAP) { term.note = "not resolved (too many lookups)"; break; }
        term.kind = "include";
        pending.push(buildNode(normalize(arg), ctx, nextChain).then((child) => { term.child = child; }));
        break;
      }
      case "a":
      case "mx": {
        ctx.lookups++;
        if (ctx.lookups > HARD_LOOKUP_CAP) { term.note = "not resolved (too many lookups)"; break; }
        term.kind = mech;
        const target = normalize(arg || domain);
        const bits4 = len4 !== undefined ? Number(len4) : undefined;
        const bits6 = len6 !== undefined ? Number(len6) : undefined;
        pending.push(resolveHosts(mech, target, ctx).then((addrs) => {
          for (const addr of addrs) {
            const c = toCidr(addr, addr.includes(":") ? bits6 : bits4);
            if (c) term.cidrs.push(c);
          }
        }));
        break;
      }
      case "ptr":
        ctx.lookups++;
        term.note = "ptr is not evaluated";
        break;
    }
  }

  if (redirectTarget && !node.terms.some((t) => t.kind === "all")) {
    ctx.lookups++;
    if (redirectTarget.includes("%")) {
      ctx.problems.push(`${domain} has a redirect with a macro. The page cannot check it.`);
    } else if (ctx.lookups <= HARD_LOOKUP_CAP) {
      pending.push(buildNode(normalize(redirectTarget), ctx, nextChain).then((child) => { node.redirect = child; }));
    }
  }

  await Promise.all(pending);
  return node;
}

async function resolveHosts(mech: "a" | "mx", target: string, ctx: Ctx): Promise<string[]> {
  const hosts: string[] = [];
  if (mech === "mx") {
    const mx = await query(target, "MX");
    if (!mx.ok) { ctx.problems.push(`The MX lookup for ${target} failed. Click "Check DNS again".`); return []; }
    if (mx.data.length === 0) ctx.voidLookups++;
    // "10 mx.example.com." → host; RFC 7208 caps MX names at 10.
    hosts.push(...mx.data.map((d) => normalize(d.split(/\s+/)[1] ?? "")).filter(Boolean).slice(0, 10));
  } else {
    hosts.push(target);
  }
  const answers = await Promise.all(hosts.flatMap((h) => [query(h, "A"), query(h, "AAAA")]));
  const addrs = answers.flatMap((a) => a.data);
  if (mech === "a" && addrs.length === 0) ctx.voidLookups++;
  return addrs;
}

// --- Evaluation ---

export interface SpfCheck {
  result: SpfResult;
  via: string[]; // the include chain and term that matched, e.g. ["include:_spf.example.net", "ip4:192.0.2.0/24"]
}

type Ip = { v: 4 | 6; n: bigint };

export async function checkIp(tree: SpfTree, ip: string): Promise<SpfCheck> {
  const addr = parseIp(ip);
  if (!addr) return { result: "unknown", via: [] };
  return evalNode(tree.root, addr);
}

async function evalNode(node: SpfNode, ip: Ip): Promise<SpfCheck> {
  if (node.error) return { result: node.error, via: [] };
  let uncertain = false;
  for (const term of node.terms) {
    let matched: SpfCheck | null = null;
    switch (term.kind) {
      case "ip":
      case "a":
      case "mx":
        if (term.cidrs.some((c) => inCidr(ip, c))) matched = { result: QUALIFIER_RESULT[term.qualifier], via: [term.raw] };
        break;
      case "include": {
        if (!term.child) { uncertain = true; break; }
        const r = await evalNode(term.child, ip);
        if (r.result === "pass") matched = { result: QUALIFIER_RESULT[term.qualifier], via: [term.raw, ...r.via] };
        else if (r.result === "unknown") uncertain = true;
        else if (r.result === "temperror") return { result: "temperror", via: [term.raw] };
        else if (r.result === "none" || r.result === "permerror") return { result: "permerror", via: [term.raw] };
        break;
      }
      case "exists": {
        // The IP never leaves the browser: an IP macro leaves the term undetermined.
        if (/%\{[iv]/i.test(term.spec!)) { uncertain = true; break; }
        const name = expandMacros(term.spec!, node.domain);
        if (name === null) { uncertain = true; break; }
        const answer = await query(normalize(name), "A");
        if (!answer.ok) { uncertain = true; break; }
        if (answer.data.length > 0) matched = { result: QUALIFIER_RESULT[term.qualifier], via: [term.raw] };
        break;
      }
      case "all":
        matched = { result: QUALIFIER_RESULT[term.qualifier], via: [term.raw] };
        break;
      case "unsupported":
        // ptr:, macros outside exists: the term could match, so later non-pass results are not final.
        if (term.note !== "invalid address" && term.note !== "missing domain") uncertain = true;
        break;
    }
    if (matched) return uncertain && matched.result !== "pass" ? { result: "unknown", via: matched.via } : matched;
  }
  if (node.redirect) {
    const r = await evalNode(node.redirect, ip);
    return { result: r.result === "none" ? "permerror" : r.result, via: [`redirect=${node.redirect.domain}`, ...r.via] };
  }
  return { result: uncertain ? "unknown" : "neutral", via: [] };
}

// RFC 7208 §7 macro expansion for %{d}, the current domain. IP macros (i, v) are never
// expanded (the caller skips them); the sender (s, l, o) and HELO (h) are not in DMARC
// reports. Those return null.
function expandMacros(spec: string, domain: string): string | null {
  let failed = false;
  const out = spec.replace(/%(?:\{([a-z])(\d*)(r?)([.\-+,/_=]*)\}|(%)|(_)|(-))/gi, (_m, letter, digits, reverse, delims, pct, us, dash) => {
    if (pct) return "%";
    if (us) return " ";
    if (dash) return "%20";
    if (letter.toLowerCase() !== "d") {
      failed = true;
      return "";
    }
    let parts = domain.split(new RegExp(`[${(delims || ".").replace(/[-\\\]^]/g, "\\$&")}]`));
    if (reverse) parts = parts.reverse();
    if (digits) parts = parts.slice(-Math.max(1, Number(digits)));
    return parts.join(".");
  });
  return failed ? null : out;
}

// --- Alignment ---

// Second-level labels under country-code TLDs that act as public suffixes (co.jp, com.au, ...).
// An approximation of the Public Suffix List, enough to compare organizational domains.
const CC_SECOND_LEVEL = new Set(["co", "com", "net", "org", "ac", "go", "or", "ne", "gr", "ed", "lg", "ad", "gov", "edu", "mil", "ltd", "plc", "sch", "nhs"]);

export function orgDomain(domain: string): string {
  const labels = normalize(domain).split(".");
  const n = labels.length;
  if (n >= 3 && labels[n - 1].length === 2 && CC_SECOND_LEVEL.has(labels[n - 2])) return labels.slice(-3).join(".");
  return labels.slice(-2).join(".");
}

// DMARC identifier alignment: strict needs the same domain, relaxed the same organizational domain.
export function isAligned(a: string, b: string, strict: boolean): boolean {
  const x = normalize(a);
  const y = normalize(b);
  if (!x || !y) return false;
  return strict ? x === y : orgDomain(x) === orgDomain(y);
}
