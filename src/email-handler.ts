import PostalMime from "postal-mime";
import * as unzipit from "unzipit";
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
  // Parse the raw MIME message. A malformed message will never parse on retry,
  // so log and drop it rather than throwing (which would trigger sender retries).
  let email;
  try {
    const parser = new PostalMime();
    const rawEmail = new Response(message.raw);
    email = await parser.parse(await rawEmail.arrayBuffer());
  } catch (err) {
    console.error("DMARC email parse failed:", {
      from: message.from,
      error: err instanceof Error ? err.message : err,
    });
    return;
  }

  if (!email.attachments || email.attachments.length === 0) {
    console.error("DMARC email rejected: no attachments", { from: message.from });
    return;
  }

  // RFC 9990 §3.5.2: extract the body part with the prescribed media type or
  // filename and ignore the rest (e.g. disclaimer or signature parts). Fall
  // back to the first attachment since senders often mislabel both.
  const attachment =
    email.attachments.find(isReportAttachment) ?? email.attachments[0];
  const content =
    attachment.content instanceof ArrayBuffer
      ? attachment.content
      : typeof attachment.content === "string"
        ? (new TextEncoder().encode(attachment.content).buffer as ArrayBuffer)
        : // Copy just this view: .buffer alone could include bytes outside it.
          (new Uint8Array(attachment.content as Uint8Array).buffer as ArrayBuffer);

  // Extract and parse the report. Senders mislabel the MIME type (e.g. au.com
  // sends gzip as application/octet-stream), so we sniff the content itself.
  // Any failure here is permanent for this message — log and drop, don't retry.
  let rows: DmarcRecordRow[];
  try {
    const reportJSON = await getDMARCReportXML({ content });
    rows = getReportRows(reportJSON);
  } catch (err) {
    console.error("DMARC report extraction failed:", {
      from: message.from,
      filename: attachment.filename,
      mimeType: attachment.mimeType,
      size: content.byteLength,
      error: err instanceof Error ? err.message : err,
    });
    return;
  }

  const reportId = rows[0]?.reportMetadataReportId ?? "unknown";
  const domain = rows[0]?.policyPublishedDomain ?? "unknown";

  // A D1 insert failure is transient — throw so Email Routing retries delivery.
  try {
    await insertReport(env.DB, rows);
  } catch (insertErr) {
    console.error("DMARC insert failed:", {
      reportId,
      domain,
      recordCount: rows.length,
      error: insertErr instanceof Error ? insertErr.message : insertErr,
    });
    throw insertErr;
  }
}

const REPORT_EXTENSIONS = [".xml", ".gz", ".zip"];
const REPORT_MIME_TYPES = new Set([
  "application/gzip",
  "application/x-gzip",
  "application/zip",
  "application/x-zip-compressed",
  "text/xml",
  "application/xml",
]);

function isReportAttachment(attachment: {
  filename?: string | null;
  mimeType?: string;
}): boolean {
  const name = (attachment.filename ?? "").toLowerCase();
  if (REPORT_EXTENSIONS.some((ext) => name.endsWith(ext))) return true;
  return REPORT_MIME_TYPES.has((attachment.mimeType ?? "").toLowerCase());
}

async function getDMARCReportXML(attachment: { content: ArrayBuffer }) {
  const bytes = new Uint8Array(attachment.content);
  if (bytes.length < 4) {
    throw new Error(`attachment too small to parse (${bytes.length} bytes)`);
  }

  const xmlParser = new XMLParser({ parseTagValue: false });
  let xml: string;

  // Detect the container by magic bytes rather than the (often wrong) MIME type.
  if (bytes[0] === 0x1f && bytes[1] === 0x8b) {
    // gzip, decompressed with the runtime's built-in DecompressionStream
    xml = await new Response(
      new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"))
    ).text();
  } else if (bytes[0] === 0x50 && bytes[1] === 0x4b) {
    // zip ("PK")
    xml = await getXMLFromZip(attachment.content);
  } else {
    // assume raw XML — the parser will reject it if it isn't
    xml = new TextDecoder().decode(attachment.content);
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
        AlignmentType[policyPublished.adkim as keyof typeof AlignmentType] ?? AlignmentType.r,
      policyPublishedASPF:
        AlignmentType[policyPublished.aspf as keyof typeof AlignmentType] ?? AlignmentType.r,
      policyPublishedP:
        DispositionType[policyPublished.p as keyof typeof DispositionType] ?? DispositionType.none,
      policyPublishedSP:
        DispositionType[policyPublished.sp as keyof typeof DispositionType] ?? DispositionType.none,
      policyPublishedPct: parseInt(policyPublished.pct) || 0,

      recordRowSourceIP: record.row.source_ip || "",
      recordRowCount: parseInt(record.row.count) || 0,
      recordRowPolicyEvaluatedDKIM:
        DMARCResultType[
          record.row.policy_evaluated.dkim as keyof typeof DMARCResultType
        ] ?? DMARCResultType.fail,
      recordRowPolicyEvaluatedSPF:
        DMARCResultType[
          record.row.policy_evaluated.spf as keyof typeof DMARCResultType
        ] ?? DMARCResultType.fail,
      recordRowPolicyEvaluatedDisposition:
        DispositionType[
          record.row.policy_evaluated
            .disposition as keyof typeof DispositionType
        ] ?? DispositionType.none,
      recordRowPolicyEvaluatedReasonType:
        PolicyOverrideType[
          record.row.policy_evaluated?.reason
            ?.type as keyof typeof PolicyOverrideType
        ] ?? null,
      recordIdentifiersEnvelopeTo: record.identifiers.envelope_to || "",
      recordIdentifiersHeaderFrom: record.identifiers.header_from || "",
    });
  }

  return rows;
}
