<script lang="ts">
  import type { Summary } from "../lib/api";

  let { summary }: { summary: Summary | null } = $props();

  function passRateNum(s: Summary): number {
    if (s.total_messages === 0) return 0;
    return (s.pass_count / s.total_messages) * 100;
  }

  let rate = $derived(summary ? passRateNum(summary) : 0);
</script>

<div class="cards" aria-live="polite">
  {#if summary}
    <div class="card">
      <div class="card-label">Total Messages</div>
      <div class="card-value">{summary.total_messages.toLocaleString()}</div>
    </div>
    <div class="card">
      <div class="card-label">Pass Rate</div>
      <div class="card-value" class:good={rate >= 90} class:bad={rate < 90}>
        <span aria-hidden="true">{rate >= 90 ? "\u2713" : "\u2717"}</span> {summary.total_messages === 0 ? "N/A" : rate.toFixed(1) + "%"}
      </div>
      {#if summary.total_messages > 0}
        <div class="threshold" class:threshold-ok={rate >= 90} class:threshold-warn={rate < 90}>
          {rate >= 90 ? "Healthy" : "Below 90% threshold"}
        </div>
      {/if}
    </div>
    <div class="card">
      <div class="card-label">Unique Sources</div>
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
    gap: 1rem;
    margin-bottom: 1.5rem;
  }
  .card {
    background: var(--card-bg, #fff);
    border: 1px solid var(--border, #e2e8f0);
    border-radius: 8px;
    padding: 1.25rem;
  }
  .card-label {
    font-size: 0.85rem;
    color: var(--muted, #64748b);
    margin-bottom: 0.25rem;
  }
  .card-value {
    font-size: 1.75rem;
    font-weight: 700;
  }
  .good { color: #16a34a; }
  .bad { color: #dc2626; }
  .threshold {
    font-size: 0.75rem;
    margin-top: 0.25rem;
  }
  .threshold-ok { color: #16a34a; }
  .threshold-warn { color: #dc2626; }
</style>
