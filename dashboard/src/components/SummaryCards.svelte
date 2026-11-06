<script lang="ts">
  import type { Summary } from "../lib/api";

  let { summary }: { summary: Summary | null } = $props();

  // Delivered = the receivers applied no policy (disposition none). A low share is not bad
  // by itself: under p=quarantine or p=reject, blocked spoofing lowers it.
  function deliveredPct(s: Summary): string {
    if (s.total_messages === 0) return "N/A";
    return ((s.pass_count / s.total_messages) * 100).toFixed(1) + "%";
  }
</script>

<div class="cards" aria-live="polite">
  {#if summary}
    <div class="card">
      <div class="card-label">Messages</div>
      <div class="card-value">{summary.total_messages.toLocaleString()}</div>
    </div>
    <div class="card">
      <div class="card-label">Delivered</div>
      <div class="card-value">{deliveredPct(summary)}</div>
      {#if summary.total_messages > 0}
        <div class="sub">{summary.fail_count.toLocaleString()} quarantined or rejected</div>
      {/if}
    </div>
    <div class="card">
      <div class="card-label">Source IPs</div>
      <div class="card-value">{summary.unique_sources.toLocaleString()}</div>
    </div>
    <div class="card">
      <div class="card-label">Reports</div>
      <div class="card-value">{summary.total_reports.toLocaleString()}</div>
    </div>
  {:else}
    <div class="card">Loading...</div>
  {/if}
</div>

<style>
  .cards {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
    gap: var(--gap-section);
    margin-bottom: var(--gap-section);
  }
  .card {
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: var(--gap-lg);
  }
  .card-label {
    font-size: var(--text-sm);
    color: var(--muted);
    margin-bottom: var(--gap-xs);
  }
  .card-value {
    font-size: 1.75rem;
    font-weight: 700;
  }
  .card .sub { margin-top: var(--gap-xs); font-size: var(--text-xs); }
</style>
