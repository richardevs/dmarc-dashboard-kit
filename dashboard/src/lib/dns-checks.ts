// Format checks for a domain's DMARC, DKIM and SPF records, fetched with the same cached
// DNS-over-HTTPS lookup as the SPF evaluation (domain names only).
import { query, orgDomain, SPF_LOOKUP_LIMIT, type SpfTree } from "./spf";

export type Level = "error" | "warning" | "info";

export interface Finding {
  level: Level;
  text: string;
}

export interface RecordCheck {
  kind: "DMARC" | "DKIM" | "SPF";
  name: string; // the DNS name that was checked
  record: string | null;
  findings: Finding[];
  status: "ok" | "warning" | "error";
}

function status(findings: Finding[]): RecordCheck["status"] {
  if (findings.some((f) => f.level === "error")) return "error";
  if (findings.some((f) => f.level === "warning")) return "warning";
  return "ok";
}

// "k=v; k=v" → ordered tags; a part without "=" is a finding.
function parseTags(record: string, findings: Finding[]): [string, string][] {
  const tags: [string, string][] = [];
  const seen = new Set<string>();
  for (const part of record.split(";").map((p) => p.trim()).filter(Boolean)) {
    const eq = part.indexOf("=");
    if (eq < 1) {
      findings.push({ level: "error", text: `"${part}" is not a valid tag. Use the format name=value.` });
      continue;
    }
    const key = part.slice(0, eq).trim().toLowerCase();
    const value = part.slice(eq + 1).trim();
    if (seen.has(key)) findings.push({ level: "error", text: `The tag ${key}= occurs more than once.` });
    seen.add(key);
    tags.push([key, value]);
  }
  return tags;
}

async function txtRecords(name: string): Promise<string[] | null> {
  const answer = await query(name, "TXT");
  return answer.ok ? answer.data : null;
}

// --- DMARC ---

const POLICIES = ["none", "quarantine", "reject"];
const DMARC_TAGS = new Set(["v", "p", "sp", "np", "adkim", "aspf", "pct", "rua", "ruf", "fo", "rf", "ri", "t", "psd"]);

export async function checkDmarc(domain: string): Promise<RecordCheck> {
  let name = `_dmarc.${domain}`;
  const findings: Finding[] = [];
  let txt = await txtRecords(name);
  let records = (txt ?? []).filter((t) => /^v=DMARC1/i.test(t.trim()));

  // Receivers fall back to the organizational domain's record.
  const org = orgDomain(domain);
  if (txt && records.length === 0 && org !== domain) {
    const orgName = `_dmarc.${org}`;
    const orgTxt = await txtRecords(orgName);
    const orgRecords = (orgTxt ?? []).filter((t) => /^v=DMARC1/i.test(t.trim()));
    if (orgRecords.length > 0) {
      findings.push({ level: "info", text: `${domain} has no record of its own. Receivers use the record of ${org}.` });
      name = orgName;
      txt = orgTxt;
      records = orgRecords;
    }
  }

  if (txt === null) return { kind: "DMARC", name, record: null, findings: [{ level: "error", text: "The DNS lookup failed. Click \"Check DNS again\"." }], status: "error" };
  if (records.length === 0) {
    const other = txt.find((t) => /dmarc/i.test(t));
    findings.push({
      level: "error",
      text: other ? "The TXT record does not start with v=DMARC1, so receivers ignore it." : "There is no DMARC record. Receivers apply no policy and send no reports.",
    });
    return { kind: "DMARC", name, record: other ?? null, findings, status: "error" };
  }
  if (records.length > 1) findings.push({ level: "error", text: `There are ${records.length} DMARC records. Receivers ignore all of them. Keep only one.` });

  const record = records[0];
  const tags = parseTags(record, findings);
  const get = (k: string) => tags.find(([key]) => key === k)?.[1];

  if (tags[0]?.[0] !== "v" || tags[0][1] !== "DMARC1") findings.push({ level: "error", text: "The record must start with v=DMARC1 (upper case)." });

  const p = get("p");
  if (p === undefined) findings.push({ level: "error", text: "The p= tag is missing. Receivers ignore the record." });
  else if (!POLICIES.includes(p.toLowerCase())) findings.push({ level: "error", text: `p=${p} is not valid. Use none, quarantine or reject.` });
  else if (p.toLowerCase() === "none") findings.push({ level: "warning", text: "p=none only monitors. Spoofed mail is not blocked. Change to quarantine or reject when your senders align." });
  if (tags[1] && tags[1][0] !== "p" && p !== undefined) findings.push({ level: "warning", text: "Put p= directly after v=DMARC1. Some receivers expect this order." });

  for (const k of ["sp", "np"]) {
    const v = get(k);
    if (v !== undefined && !POLICIES.includes(v.toLowerCase())) findings.push({ level: "error", text: `${k}=${v} is not valid. Use none, quarantine or reject.` });
  }
  for (const k of ["adkim", "aspf"]) {
    const v = get(k);
    if (v !== undefined && !["r", "s"].includes(v.toLowerCase())) findings.push({ level: "error", text: `${k}=${v} is not valid. Use r (relaxed) or s (strict).` });
  }
  const pct = get("pct");
  if (pct !== undefined) {
    if (!/^\d{1,3}$/.test(pct) || Number(pct) > 100) findings.push({ level: "error", text: `pct=${pct} is not valid. Use a number from 0 to 100.` });
    else if (Number(pct) < 100) findings.push({ level: "warning", text: `pct=${pct}: the policy applies to only ${pct}% of failing mail.` });
  }
  for (const k of ["rua", "ruf"]) {
    const v = get(k);
    if (v === undefined) {
      if (k === "rua") findings.push({ level: "warning", text: "The rua= tag is missing. Receivers send no aggregate reports." });
      continue;
    }
    for (const uri of v.split(",").map((u) => u.trim())) {
      if (!/^mailto:[^@\s]+@[^@\s!]+(![0-9]+[kmgt]?)?$/i.test(uri)) {
        findings.push({ level: "error", text: `${k}=${uri} is not valid. Use mailto:address@example.com.` });
      }
    }
  }
  const fo = get("fo");
  if (fo !== undefined && !/^[01ds](:[01ds])*$/i.test(fo)) findings.push({ level: "error", text: `fo=${fo} is not valid. Use 0, 1, d or s, separated by ":".` });
  const ri = get("ri");
  if (ri !== undefined && !/^\d+$/.test(ri)) findings.push({ level: "error", text: `ri=${ri} is not valid. Use a number of seconds.` });
  for (const [k] of tags) {
    if (!DMARC_TAGS.has(k)) findings.push({ level: "warning", text: `${k}= is not a DMARC tag. Receivers ignore it.` });
  }

  return { kind: "DMARC", name, record, findings, status: status(findings) };
}

// --- DKIM ---

// The approximate RSA key size from the length of its base64 DER public key.
function rsaBits(base64: string): number {
  const bytes = Math.floor((base64.length * 3) / 4);
  if (bytes < 100) return 512;
  if (bytes < 200) return 1024;
  if (bytes < 330) return 2048;
  if (bytes < 460) return 3072;
  return 4096;
}

export async function checkDkim(domain: string, selector: string): Promise<RecordCheck> {
  const name = `${selector}._domainkey.${domain}`;
  const findings: Finding[] = [];
  const txt = await txtRecords(name);
  if (txt === null) return { kind: "DKIM", name, record: null, findings: [{ level: "error", text: "The DNS lookup failed. Click \"Check DNS again\"." }], status: "error" };
  if (txt.length === 0) {
    findings.push({ level: "error", text: "There is no DKIM key for this selector. Receivers cannot verify signatures that use it." });
    return { kind: "DKIM", name, record: null, findings, status: "error" };
  }
  const keys = txt.filter((t) => /(^|;)\s*p=/i.test(t) || /^v=DKIM1/i.test(t.trim()));
  if (keys.length > 1) findings.push({ level: "error", text: `There are ${keys.length} DKIM records for this selector. Keep only one.` });
  const record = keys[0] ?? txt[0];
  const tags = parseTags(record, findings);
  const get = (k: string) => tags.find(([key]) => key === k)?.[1];

  const v = get("v");
  if (v !== undefined && (v !== "DKIM1" || tags[0][0] !== "v")) findings.push({ level: "error", text: "v= must be DKIM1 and the first tag." });
  const k = (get("k") ?? "rsa").toLowerCase();
  if (!["rsa", "ed25519"].includes(k)) findings.push({ level: "error", text: `k=${k} is not valid. Use rsa or ed25519.` });

  const p = get("p");
  if (p === undefined) {
    findings.push({ level: "error", text: "The p= tag (the public key) is missing." });
  } else if (p === "") {
    findings.push({ level: "error", text: "p= is empty: the key is revoked. Signatures with this selector fail." });
  } else {
    const key = p.replace(/\s+/g, "");
    if (!/^[A-Za-z0-9+/]+={0,2}$/.test(key)) {
      findings.push({ level: "error", text: "The public key in p= is not valid base64." });
    } else if (k === "rsa") {
      const bits = rsaBits(key);
      if (bits < 1024) findings.push({ level: "error", text: `The RSA key is about ${bits} bits. Receivers reject keys shorter than 1024 bits.` });
      else if (bits < 2048) findings.push({ level: "warning", text: `The RSA key is about ${bits} bits. Use a 2048-bit key.` });
      else findings.push({ level: "info", text: `RSA key, about ${bits} bits.` });
    }
  }
  const t = get("t");
  if (t && t.split(":").map((x) => x.trim()).includes("y")) findings.push({ level: "warning", text: "t=y: the key is in testing mode. Some receivers ignore its signatures." });
  const h = get("h");
  if (h && !h.split(":").map((x) => x.trim().toLowerCase()).includes("sha256")) findings.push({ level: "warning", text: `h=${h} does not allow sha256. Receivers do not accept sha1.` });

  return { kind: "DKIM", name, record, findings, status: status(findings) };
}

// --- SPF ---

export function checkSpf(tree: SpfTree): RecordCheck {
  const findings: Finding[] = [];
  const root = tree.root;
  if (!root.record) {
    if (root.error === "temperror") findings.push({ level: "error", text: "The DNS lookup failed. Click \"Check DNS again\"." });
    else findings.push({ level: "error", text: "There is no SPF record. SPF cannot pass for this domain." });
    return { kind: "SPF", name: tree.domain, record: null, findings, status: "error" };
  }
  for (const problem of tree.problems) findings.push({ level: "error", text: problem });

  const terms = root.record.trim().split(/\s+/).slice(1).map((t) => t.toLowerCase());
  const all = terms.find((t) => /^[+\-~?]?all$/.test(t));
  if (all === "+all" || all === "all") findings.push({ level: "error", text: `"${all}" lets every server on the internet pass SPF. Use -all or ~all.` });
  else if (all === "?all") findings.push({ level: "warning", text: "\"?all\" is neutral: it does not tell receivers to distrust other servers. Use -all or ~all." });
  else if (!all && !terms.some((t) => t.startsWith("redirect="))) findings.push({ level: "warning", text: "The record has no \"all\" term. Add -all or ~all at the end." });
  if (all && terms.indexOf(all) !== terms.length - 1 && !terms.slice(terms.indexOf(all) + 1).every((t) => t.includes("="))) {
    findings.push({ level: "warning", text: "Terms after \"all\" have no effect. Put \"all\" at the end." });
  }
  if (terms.some((t) => /^[+\-~?]?ptr(:|$)/.test(t))) findings.push({ level: "warning", text: "The ptr mechanism is slow and deprecated (RFC 7208). Remove it." });
  if (root.record.length > 450) findings.push({ level: "warning", text: `The record has ${root.record.length} characters. Some DNS replies fail above about 450.` });
  if (tree.lookups <= SPF_LOOKUP_LIMIT) findings.push({ level: "info", text: `${tree.lookups} of ${SPF_LOOKUP_LIMIT} DNS lookups.` });

  return { kind: "SPF", name: tree.domain, record: root.record, findings, status: status(findings) };
}
