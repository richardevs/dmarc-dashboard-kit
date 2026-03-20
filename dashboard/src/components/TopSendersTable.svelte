<script lang="ts">
  import type { TopSender } from "../lib/api";

  let { senders }: { senders: TopSender[] } = $props();

  type SortKey = "source_ip" | "total_count" | "pass_count" | "fail_count" | "rate";
  let sortKey: SortKey = $state("total_count");
  let sortAsc: boolean = $state(false);

  function rateVal(s: TopSender): number {
    return s.total_count === 0 ? 0 : s.pass_count / s.total_count;
  }

  function toggleSort(key: SortKey) {
    if (sortKey === key) { sortAsc = !sortAsc; }
    else { sortKey = key; sortAsc = false; }
  }

  function sortIndicator(key: SortKey): string {
    if (sortKey !== key) return "";
    return sortAsc ? " \u25B2" : " \u25BC";
  }

  let sorted = $derived(
    [...senders].sort((a, b) => {
      let cmp = 0;
      if (sortKey === "source_ip") cmp = a.source_ip.localeCompare(b.source_ip);
      else if (sortKey === "rate") cmp = rateVal(a) - rateVal(b);
      else cmp = (a[sortKey] as number) - (b[sortKey] as number);
      return sortAsc ? cmp : -cmp;
    })
  );

  function pctStr(pass: number, total: number): string {
    if (total === 0) return "N/A";
    return ((pass / total) * 100).toFixed(1) + "%";
  }

  function pctNum(pass: number, total: number): number {
    if (total === 0) return 0;
    return (pass / total) * 100;
  }

  function barColor(pct: number): string {
    if (pct >= 95) return "#16a34a";
    if (pct >= 80) return "#ca8a04";
    return "#dc2626";
  }
</script>

<div class="table-container">
  <h3>Top Senders</h3>
  <table>
    <thead>
      <tr>
        <th class="sortable" onclick={() => toggleSort("source_ip")}>Source IP{sortIndicator("source_ip")}</th>
        <th class="sortable num" onclick={() => toggleSort("total_count")}>Total{sortIndicator("total_count")}</th>
        <th class="sortable num" onclick={() => toggleSort("pass_count")}>Pass{sortIndicator("pass_count")}</th>
        <th class="sortable num" onclick={() => toggleSort("fail_count")}>Fail{sortIndicator("fail_count")}</th>
        <th class="sortable num" onclick={() => toggleSort("rate")}>Rate{sortIndicator("rate")}</th>
      </tr>
    </thead>
    <tbody>
      {#each sorted as s}
        {@const pct = pctNum(s.pass_count, s.total_count)}
        <tr>
          <td class="mono">{s.source_ip}</td>
          <td class="num">{s.total_count.toLocaleString()}</td>
          <td class="num good">{s.pass_count.toLocaleString()}</td>
          <td class="num bad">{s.fail_count.toLocaleString()}</td>
          <td class="num">
            <span class="rate-cell">
              <span class="rate-bar"><span class="rate-fill" style="width:{pct}%; background:{barColor(pct)}"></span></span>
              <span class="rate-text" style="color:{barColor(pct)}">{pctStr(s.pass_count, s.total_count)}</span>
            </span>
          </td>
        </tr>
      {/each}
      {#if senders.length === 0}
        <tr><td colspan="5" class="empty">No data</td></tr>
      {/if}
    </tbody>
  </table>
</div>

<style>
  .table-container {
    background: var(--card-bg, #fff);
    border: 1px solid var(--border, #e2e8f0);
    border-radius: 8px;
    padding: 1.25rem;
    margin-bottom: 1.5rem;
    overflow-x: auto;
  }
  h3 { margin: 0 0 1rem 0; font-size: 1rem; }
  table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
  th, td {
    text-align: left;
    padding: 0.65rem 0.75rem;
    border-bottom: 1px solid var(--border, #e2e8f0);
  }
  th {
    font-size: 0.8rem;
    font-weight: 600;
    color: var(--text, #1e293b);
    opacity: 0.8;
    border-bottom: 2px solid var(--border, #e2e8f0);
  }
  .sortable { cursor: pointer; user-select: none; white-space: nowrap; }
  .sortable:hover { opacity: 1; }
  tbody tr:nth-child(even) { background: var(--row-alt, #f1f5f9); }
  .mono { font-family: monospace; }
  .num { text-align: right; font-variant-numeric: tabular-nums; }
  .good { color: #16a34a; }
  .bad { color: #dc2626; }
  .empty { text-align: center; color: var(--muted, #64748b); }
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
</style>
