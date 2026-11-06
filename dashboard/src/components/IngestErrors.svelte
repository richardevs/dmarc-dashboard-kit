<script lang="ts">
  import { getIngestErrorContent, dismissIngestError, type IngestErrorItem, type IngestErrorContent } from "../lib/api";

  let { errors, onDismissed }: { errors: IngestErrorItem[]; onDismissed: (id: number) => void } = $props();

  let openId: number | null = $state(null);
  let content = $state<IngestErrorContent | null>(null);
  let loading: boolean = $state(false);
  let copied: boolean = $state(false);
  let actionError: string = $state("");

  const STAGE_LABEL: Record<string, string> = {
    mime: "The worker cannot read the email",
    attachment: "The worker cannot unpack the attachment",
    report: "The worker cannot read the report XML",
  };

  function when(ts: number): string {
    return new Date(ts * 1000).toLocaleString();
  }

  async function toggle(e: IngestErrorItem) {
    copied = false;
    if (openId === e.id) {
      openId = null;
      content = null;
      return;
    }
    openId = e.id;
    content = null;
    if (!e.content_type) return;
    loading = true;
    try {
      const c = await getIngestErrorContent(e.id);
      if (openId === e.id) content = c;
    } catch (err) {
      actionError = err instanceof Error ? err.message : "Failed to load the content";
    } finally {
      loading = false;
    }
  }

  async function copy() {
    if (!content) return;
    await navigator.clipboard.writeText(content.content);
    copied = true;
  }

  function download(e: IngestErrorItem) {
    if (!content) return;
    let blob: Blob;
    let name: string;
    if (content.content_type === "base64") {
      const binary = atob(content.content);
      blob = new Blob([Uint8Array.from(binary, (c) => c.charCodeAt(0))], { type: e.mime_type || "application/octet-stream" });
      name = e.filename || `ingest-error-${e.id}.bin`;
    } else {
      blob = new Blob([content.content], { type: "application/xml" });
      name = `${(e.filename || `ingest-error-${e.id}`).replace(/\.(xml|gz|zip)$/i, "")}.xml`;
    }
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = name;
    a.click();
    URL.revokeObjectURL(url);
  }

  // GitHub issues are public, and a report shows the organization's domains and mail
  // server IPs: in a company, the person who deployed the dashboard decides what to share.
  function confirmIssue(event: MouseEvent) {
    const ok = confirm(
      "GitHub issues are public. A report shows your domains and the IP addresses of your mail servers.\n\n" +
        "If you did not deploy this dashboard, ask the person who deployed it before you share a report.\n\n" +
        "Open GitHub?"
    );
    if (!ok) event.preventDefault();
  }

  async function dismiss(e: IngestErrorItem) {
    if (!confirm(`Dismiss the error from ${e.sender}? This deletes the error and the stored report.`)) return;
    actionError = "";
    try {
      await dismissIngestError(e.id);
      if (openId === e.id) { openId = null; content = null; }
      onDismissed(e.id);
    } catch (err) {
      actionError = err instanceof Error ? err.message : "Failed to dismiss";
    }
  }
</script>

<section class="panel">
  <h3>Report errors</h3>
  <p class="note">
    The worker received these report emails but cannot read them. Their data is not in the dashboard.
    The cause can be a defective report from the sender, or a bug in the parser.
    If a report looks correct, <a href="https://github.com/richardevs/dmarc-dashboard-kit/issues" target="_blank" rel="noopener noreferrer" onclick={confirmIssue}>open an issue</a> with the error and the report.
    Remove the data that you do not want to share. When you do not need an error, dismiss it.
  </p>
  {#if actionError}
    <div class="error-box" role="alert">{actionError}</div>
  {/if}
  {#if errors.length === 0}
    <p class="empty">No report errors</p>
  {:else}
    <table class="data">
      <thead>
        <tr>
          <th scope="col">Received</th>
          <th scope="col">Sender</th>
          <th scope="col">Problem</th>
          <th scope="col">File</th>
          <th scope="col"><span class="visually-hidden">Actions</span></th>
        </tr>
      </thead>
      <tbody>
        {#each errors as e (e.id)}
          <tr>
            <td>{when(e.received_at)}</td>
            <td class="mono">{e.sender}</td>
            <td>{STAGE_LABEL[e.stage] ?? e.stage}<span class="sub mono">{e.error}</span></td>
            <td class="mono">
              {e.filename || "—"}
              {#if e.size}<span class="sub">{e.mime_type} · {e.size.toLocaleString()} bytes</span>{/if}
            </td>
            <td class="actions">
              {#if e.content_type}
                <button class="btn-small" aria-expanded={openId === e.id} onclick={() => toggle(e)}>{openId === e.id ? "Hide" : "Show"}</button>
              {/if}
              <button class="btn-small" onclick={() => dismiss(e)}>Dismiss</button>
            </td>
          </tr>
          {#if openId === e.id}
            <tr class="content-row">
              <td colspan="5">
                {#if loading}
                  <p class="empty">Loading…</p>
                {:else if content}
                  <div class="content-actions">
                    {#if content.content_type === "xml"}
                      <button class="btn-small" onclick={copy}>{copied ? "Copied" : "Copy XML"}</button>
                    {/if}
                    <button class="btn-small" onclick={() => download(e)}>{content.content_type === "xml" ? "Download XML" : "Download attachment"}</button>
                    {#if content.content_truncated}
                      <span class="sub">The dashboard keeps only the first 256 KB.</span>
                    {/if}
                  </div>
                  {#if content.content_type === "xml"}
                    <pre>{content.content}</pre>
                  {:else}
                    <p class="sub">The worker cannot unpack this attachment. Download the attachment to examine it.</p>
                  {/if}
                {/if}
              </td>
            </tr>
          {/if}
        {/each}
      </tbody>
    </table>
  {/if}
</section>

<style>
  .note a { color: #3b82f6; }
  .error-box { margin-bottom: var(--gap-md); }
  .mono { word-break: break-all; }
  .actions { white-space: nowrap; text-align: right; }
  .actions .btn-small + .btn-small { margin-left: var(--gap-xs); }
  .content-row td { background: var(--row-alt); }
  .content-actions { display: flex; align-items: center; gap: var(--gap-sm); margin-bottom: var(--gap-sm); }
  .content-actions .sub { margin: 0; }
  pre {
    max-height: 24rem;
    overflow: auto;
    margin: 0;
    padding: var(--gap-sm) var(--gap-md);
    font-family: var(--mono);
    font-size: var(--text-xs);
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 4px;
    white-space: pre-wrap;
    word-break: break-all;
  }
  .visually-hidden {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip: rect(0 0 0 0);
    white-space: nowrap;
  }
</style>
