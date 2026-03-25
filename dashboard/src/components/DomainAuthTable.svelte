<script lang="ts">
  import type { DomainAuth } from "../lib/api";

  let { data, onDomainClick, maskDomain, selectedDomain = "" }: { data: DomainAuth[]; onDomainClick: (domain: string) => void; maskDomain: (name: string) => string; selectedDomain?: string } = $props();

  function pct(part: number, total: number): string {
    if (total === 0) return "N/A";
    return (part / total * 100).toFixed(1) + "%";
  }

  function pctNum(part: number, total: number): number {
    if (total === 0) return 0;
    return part / total * 100;
  }

  function barColor(val: number): string {
    if (val >= 95) return "#16a34a";
    if (val >= 80) return "#ca8a04";
    return "#dc2626";
  }

  function policyLabel(p: number): string {
    if (p === 2) return "reject";
    if (p === 1) return "quarantine";
    return "none";
  }

  function policyClass(p: number): string {
    if (p === 2) return "badge badge-green";
    if (p === 1) return "badge badge-amber";
    return "badge badge-red";
  }
</script>

<div class="table-container">
  <h3>Domain Authentication Rates</h3>
  <p class="note">DMARC requires either SPF or DKIM to pass - if either reaches 100%, all reported mail from that domain is passing authentication.</p>
  {#if data.length === 0}
    <p class="empty">No data</p>
  {:else}
    <table>
      <thead>
        <tr>
          <th scope="col">Domain</th>
          <th scope="col" class="num">Total</th>
          <th scope="col" class="num">SPF Pass</th>
          <th scope="col" class="num">DKIM Pass</th>
          <th scope="col">Policy</th>
        </tr>
      </thead>
      <tbody>
        {#each data as row}
          {@const spfPct = pctNum(row.spf_pass, row.total)}
          {@const dkimPct = pctNum(row.dkim_pass, row.total)}
          <tr class:selected={row.domain === selectedDomain}>
            <td><button class="link" aria-pressed={row.domain === selectedDomain} onclick={() => onDomainClick(row.domain)}>{maskDomain(row.domain)}</button></td>
            <td class="num">{row.total.toLocaleString()}</td>
            <td class="num">
              <span class="rate-cell">
                <span class="rate-bar" aria-hidden="true"><span class="rate-fill" style="width:{spfPct}%; background:{barColor(spfPct)}"></span></span>
                <span class="rate-text" style="color:{barColor(spfPct)}">{pct(row.spf_pass, row.total)}</span>
              </span>
            </td>
            <td class="num">
              <span class="rate-cell">
                <span class="rate-bar" aria-hidden="true"><span class="rate-fill" style="width:{dkimPct}%; background:{barColor(dkimPct)}"></span></span>
                <span class="rate-text" style="color:{barColor(dkimPct)}">{pct(row.dkim_pass, row.total)}</span>
              </span>
            </td>
            <td><span class={policyClass(row.policy_p)}>{policyLabel(row.policy_p)}</span></td>
          </tr>
        {/each}
      </tbody>
    </table>
  {/if}
</div>

<style>
  .table-container {
    background: var(--card-bg, #fff);
    border: 1px solid var(--border, #e2e8f0);
    border-radius: 8px;
    padding: 1.25rem;
    margin-bottom: 1.5rem;
  }
  h3 { margin: 0 0 0.25rem 0; font-size: 1rem; }
  .note { margin: 0 0 0.75rem; font-size: 0.75rem; color: var(--muted, #64748b); }
  table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
  th, td {
    padding: 0.65rem 0.75rem;
    text-align: left;
    border-bottom: 1px solid var(--border, #e2e8f0);
  }
  th {
    font-weight: 600;
    color: var(--text, #1e293b);
    opacity: 0.8;
    font-size: 0.8rem;
    border-bottom: 2px solid var(--border, #e2e8f0);
  }
  tbody tr { height: 2.65rem; }
  tbody tr:nth-child(even) { background: var(--row-alt, #f1f5f9); }
  tbody tr.selected { background: #fefce8; }
  @media (prefers-color-scheme: dark) {
    tbody tr.selected { background: #3a3520; }
  }
  .num { text-align: right; font-variant-numeric: tabular-nums; }
  .empty { color: var(--muted, #64748b); font-size: 0.85rem; }
  .link {
    background: none;
    border: none;
    color: #3b82f6;
    cursor: pointer;
    padding: 0;
    font: inherit;
    text-decoration: underline;
    text-underline-offset: 2px;
  }
  .link:hover { color: #2563eb; }
  .rate-cell { display: inline-flex; align-items: center; gap: 0.5rem; }
  .rate-bar {
    display: inline-block;
    width: 40px;
    height: 6px;
    background: var(--border, #e2e8f0);
    border-radius: 3px;
    overflow: hidden;
  }
  .rate-fill { display: block; height: 100%; border-radius: 3px; }
  .rate-text { display: inline-block; min-width: 3.5em; text-align: right; font-variant-numeric: tabular-nums; }
  .badge {
    display: inline-block;
    padding: 0.15rem 0.5rem;
    border-radius: 4px;
    font-size: 0.75rem;
    font-weight: 600;
  }
  .badge-green { background: #dcfce7; color: #166534; }
  .badge-amber { background: #fef3c7; color: #92400e; }
  .badge-red { background: #fef2f2; color: #dc2626; }
</style>
