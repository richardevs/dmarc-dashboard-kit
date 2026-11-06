export interface Env {
  DB: D1Database;
  ASSETS: Fetcher;
  // Accepted policy domains (each also covers its subdomains); empty = accept any.
  REPORT_DOMAINS: string[];
  // Cloudflare Access team domain (<team>.cloudflareaccess.com) and the app's AUD tag,
  // set by deploy.sh; empty in local dev.
  ACCESS_TEAM_DOMAIN: string;
  ACCESS_AUD: string;
}

export type DmarcRecordRow = {
  reportMetadataReportId: string;
  reportMetadataOrgName: string;
  reportMetadataDateRangeBegin: number;
  reportMetadataDateRangeEnd: number;
  reportMetadataError: string;

  policyPublishedDomain: string;
  policyPublishedADKIM: AlignmentType;
  policyPublishedASPF: AlignmentType;
  policyPublishedP: DispositionType;
  policyPublishedSP: DispositionType;
  policyPublishedPct: number;

  recordRowSourceIP: string;
  recordRowCount: number;
  recordRowPolicyEvaluatedDKIM: DMARCResultType;
  recordRowPolicyEvaluatedSPF: DMARCResultType;
  recordRowPolicyEvaluatedDisposition: DispositionType;
  recordRowPolicyEvaluatedReasonType: PolicyOverrideType | null;
  recordIdentifiersEnvelopeTo: string;
  recordIdentifiersHeaderFrom: string;
  // The receiver's per-mechanism results (<auth_results>): which domains SPF and DKIM checked.
  authResults: AuthResult[];
};

export type AuthResult = {
  kind: "spf" | "dkim";
  domain: string;
  selector: string; // DKIM only
  scope: string; // SPF only: "mfrom" or "helo" (empty when the reporter omits it)
  result: string;
};

export enum AlignmentType {
  r = 0,
  s = 1,
}

export enum DMARCResultType {
  fail = 0,
  pass = 1,
}

export enum DispositionType {
  none = 0,
  quarantine = 1,
  reject = 2,
}

export enum PolicyOverrideType {
  other = 0,
  forwarded = 1,
  sampled_out = 2,
  trusted_forwarder = 3,
  mailing_list = 4,
  local_policy = 5,
}
