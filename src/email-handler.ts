import PostalMime from "postal-mime";
import mimeDb from "mime-db";
import * as unzipit from "unzipit";
import * as pako from "pako";
import { XMLParser } from "fast-xml-parser";

import {
  Env,
  DmarcRecordRow,
  AlignmentType,
  DispositionType,
  DMARCResultType,
  PolicyOverrideType,
} from "./types";
import { insertReport } from "./db";

export async function handleEmail(
  message: ForwardableEmailMessage,
  env: Env,
  _ctx: ExecutionContext
): Promise<void> {
  try {
    const parser = new PostalMime();
    const rawEmail = new Response(message.raw);
    const email = await parser.parse(await rawEmail.arrayBuffer());

    if (!email.attachments || email.attachments.length === 0) {
      console.error("DMARC email rejected: no attachments", { from: message.from });
      return;
    }

    const attachment = email.attachments[0];
    const content =
      attachment.content instanceof ArrayBuffer
        ? attachment.content
        : typeof attachment.content === "string"
          ? new TextEncoder().encode(attachment.content).buffer as ArrayBuffer
          : (attachment.content as Uint8Array).buffer as ArrayBuffer;
    const reportJSON = await getDMARCReportXML({ mimeType: attachment.mimeType, content });
    const rows = getReportRows(reportJSON);

    await insertReport(env.DB, rows);
  } catch (err) {
    console.error("DMARC email processing failed:", err instanceof Error ? err.message : err);
  }
}

async function getDMARCReportXML(attachment: {
  mimeType: string;
  content: ArrayBuffer;
}) {
  let xml: string;
  const xmlParser = new XMLParser();
  const mimeEntry = mimeDb[attachment.mimeType];
  const extension = mimeEntry?.extensions?.[0] || "";

  switch (extension) {
    case "gz":
      xml = pako.inflate(new Uint8Array(attachment.content), { to: "string" });
      break;
    case "zip":
      xml = await getXMLFromZip(attachment.content);
      break;
    case "xml":
      xml = new TextDecoder().decode(attachment.content);
      break;
    default:
      throw new Error(`unknown extension: ${extension}`);
  }

  return xmlParser.parse(xml);
}

async function getXMLFromZip(content: ArrayBuffer): Promise<string> {
  const { entries } = await unzipit.unzipRaw(content);
  if (entries.length === 0) {
    throw new Error("no entries in zip");
  }
  return entries[0].text();
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function getReportRows(report: any): DmarcRecordRow[] {
  if (!report?.feedback?.report_metadata || !report.feedback.policy_published || !report.feedback.record) {
    throw new Error("invalid xml");
  }

  const reportMetadata = report.feedback.report_metadata;
  const policyPublished = report.feedback.policy_published;
  const records = Array.isArray(report.feedback.record)
    ? report.feedback.record
    : [report.feedback.record];

  const rows: DmarcRecordRow[] = [];

  for (const record of records) {
    rows.push({
      reportMetadataReportId: reportMetadata.report_id
        .toString()
        .replace("-", "_"),
      reportMetadataOrgName: reportMetadata.org_name || "",
      reportMetadataDateRangeBegin:
        parseInt(reportMetadata.date_range.begin) || 0,
      reportMetadataDateRangeEnd:
        parseInt(reportMetadata.date_range.end) || 0,
      reportMetadataError: JSON.stringify(reportMetadata.error) || "",

      policyPublishedDomain: policyPublished.domain || "",
      policyPublishedADKIM:
        AlignmentType[policyPublished.adkim as keyof typeof AlignmentType],
      policyPublishedASPF:
        AlignmentType[policyPublished.aspf as keyof typeof AlignmentType],
      policyPublishedP:
        DispositionType[policyPublished.p as keyof typeof DispositionType],
      policyPublishedSP:
        DispositionType[policyPublished.sp as keyof typeof DispositionType],
      policyPublishedPct: parseInt(policyPublished.pct) || 0,

      recordRowSourceIP: record.row.source_ip || "",
      recordRowCount: parseInt(record.row.count) || 0,
      recordRowPolicyEvaluatedDKIM:
        DMARCResultType[
          record.row.policy_evaluated.dkim as keyof typeof DMARCResultType
        ],
      recordRowPolicyEvaluatedSPF:
        DMARCResultType[
          record.row.policy_evaluated.spf as keyof typeof DMARCResultType
        ],
      recordRowPolicyEvaluatedDisposition:
        DispositionType[
          record.row.policy_evaluated
            .disposition as keyof typeof DispositionType
        ],
      recordRowPolicyEvaluatedReasonType:
        PolicyOverrideType[
          record.row.policy_evaluated?.reason
            ?.type as keyof typeof PolicyOverrideType
        ],
      recordIdentifiersEnvelopeTo: record.identifiers.envelope_to || "",
      recordIdentifiersHeaderFrom: record.identifiers.header_from || "",
    });
  }

  return rows;
}
