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

<div class="panel">
  <h3>Alignment by domain</h3>
  <p class="note">DMARC passes when SPF or DKIM aligns with the From domain. When one of them is at 100%, all reported mail from the domain passes DMARC. Click an SPF value to see why SPF does not align.</p>
  {#if data.length === 0}
    <p class="empty">No reports for this period</p>
  {:else}
    <table class="data">
      <thead>
        <tr>
          <th scope="col">Domain</th>
          <th scope="col" class="num">Messages</th>
          <th scope="col" class="num">SPF aligned</th>
          <th scope="col" class="num">DKIM aligned</th>
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
              <a class="rate-cell rate-link" href="#/analyzer/{encodeURIComponent(row.domain)}" title="Show why SPF does not align for {maskDomain(row.domain)}">
                <span class="rate-bar" aria-hidden="true"><span class="rate-fill" style="width:{spfPct}%; background:{barColor(spfPct)}"></span></span>
                <span class="rate-text" style="color:{barColor(spfPct)}">{pct(row.spf_pass, row.total)}</span>
              </a>
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
  tbody tr.selected { background: #fefce8; }
  @media (prefers-color-scheme: dark) {
    tbody tr.selected { background: #3a3520; }
  }
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
  .rate-link { color: var(--muted); text-decoration: underline dotted; text-underline-offset: 3px; }
</style>
