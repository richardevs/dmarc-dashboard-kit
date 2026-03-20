export interface Env {
  DB: D1Database;
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
  recordRowPolicyEvaluatedReasonType: PolicyOverrideType;
  recordIdentifiersEnvelopeTo: string;
  recordIdentifiersHeaderFrom: string;
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
