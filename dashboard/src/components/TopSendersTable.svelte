<script lang="ts">
  import { untrack } from "svelte";
  import { getAllSenders, clearPageCache, type TopSender, type SenderList } from "../lib/api";

  let { senders, days, domain }: { senders: TopSender[]; days: string; domain: string } = $props();

  type Tab = "top" | "all";
  let activeTab: Tab = $state("top");

  // All Senders state
  let allSendersData: SenderList | null = $state(null);
  let allLoading: boolean = $state(false);
  let allSort: string = $state("");
  let allDir: string = $state("");

  async function fetchAllSenders(page = 1) {
    allLoading = true;
    try {
      allSendersData = await getAllSenders(days, String(page), "20", domain || undefined, allSort || undefined, allDir || undefined);
    } finally {
      allLoading = false;
    }
  }

  function switchTab(tab: Tab) {
    activeTab = tab;
    if (tab === "all" && !allSendersData) {
      fetchAllSenders();
    }
  }

  // Reset "All Senders" when filters change
  $effect(() => {
    void days;
    void domain;
    clearPageCache();
    allSendersData = null;
    allSort = "";
    allDir = "";
    untrack(() => {
      if (activeTab === "all") {
        fetchAllSenders();
      }
    });
  });

  // Sorting
  type SortKey = "source_ip" | "total_count" | "pass_count" | "fail_count" | "rate";
  let topSortKey: SortKey = $state("total_count");
  let topSortAsc: boolean = $state(false);

  function rateVal(s: TopSender): number {
    return s.total_count === 0 ? 0 : s.pass_count / s.total_count;
  }

  function toggleSort(key: SortKey) {
    if (activeTab === "top") {
      if (topSortKey === key) { topSortAsc = !topSortAsc; }
      else { topSortKey = key; topSortAsc = false; }
    } else {
      if (allSort === key) { allDir = allDir === "asc" ? "desc" : "asc"; }
      else { allSort = key; allDir = "desc"; }
      clearPageCache();
      fetchAllSenders(1);
    }
  }

  function sortIndicator(key: SortKey): string {
    if (activeTab === "top") {
      if (topSortKey !== key) return "";
      return topSortAsc ? " \u25B2" : " \u25BC";
    } else {
      if (allSort !== key) return "";
      return allDir === "asc" ? " \u25B2" : " \u25BC";
    }
  }

  let sorted = $derived(
    [...senders].sort((a, b) => {
      let cmp = 0;
      if (topSortKey === "source_ip") cmp = a.source_ip.localeCompare(b.source_ip);
      else if (topSortKey === "rate") cmp = rateVal(a) - rateVal(b);
      else cmp = (a[topSortKey] as number) - (b[topSortKey] as number);
      return topSortAsc ? cmp : -cmp;
    })
  );

  let displayRows = $derived(activeTab === "top" ? sorted : (allSendersData?.data ?? []));

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

  // Pagination for All Senders
  let totalPages = $derived(allSendersData ? Math.ceil(allSendersData.total / allSendersData.pageSize) : 1);

  function goToPage(p: number) {
    const clamped = Math.max(1, Math.min(p, totalPages));
    if (allSendersData && clamped !== allSendersData.page) {
      fetchAllSenders(clamped);
    }
  }
</script>

<div class="table-container">
  <div class="tab-header">
    <button class="tab-btn" class:active={activeTab === "top"} onclick={() => switchTab("top")}>Top Senders</button>
    <button class="tab-btn" class:active={activeTab === "all"} onclick={() => switchTab("all")}>
      All Senders
      {#if allSendersData}
        <span class="count">({allSendersData.total})</span>
      {/if}
    </button>
  </div>

  {#if activeTab === "all"}
    <p class="note">Pass = DMARC disposition: none. Fail = quarantine or reject.</p>
  {/if}

  {#if activeTab === "all" && allLoading && !allSendersData}
    <p class="loading">Loading...</p>
  {:else}
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
        {#each displayRows as s}
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
        {#if displayRows.length === 0}
          <tr><td colspan="5" class="empty">No data</td></tr>
        {/if}
      </tbody>
    </table>

    {#if activeTab === "all" && allSendersData && totalPages > 1}
      <div class="pagination">
        <button disabled={allSendersData.page <= 1} onclick={() => goToPage(1)}>&laquo;</button>
        <button disabled={allSendersData.page <= 1} onclick={() => goToPage(allSendersData!.page - 1)}>&lsaquo; Prev</button>
        <span class="page-info">{allSendersData.page} / {totalPages}</span>
        <button disabled={allSendersData.page >= totalPages} onclick={() => goToPage(allSendersData!.page + 1)}>Next &rsaquo;</button>
        <button disabled={allSendersData.page >= totalPages} onclick={() => goToPage(totalPages)}>&raquo;</button>
      </div>
    {/if}
  {/if}
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
  .tab-header {
    display: flex;
    gap: 0;
    margin-bottom: 1rem;
  }
  .tab-btn {
    padding: 0.4rem 0.8rem;
    border: 1px solid var(--border, #e2e8f0);
    background: var(--card-bg, #fff);
    color: var(--text, #1e293b);
    cursor: pointer;
    font-size: 0.85rem;
    font-weight: 600;
  }
  .tab-btn:first-child { border-radius: 4px 0 0 4px; }
  .tab-btn:last-child { border-radius: 0 4px 4px 0; }
  .tab-btn:not(:last-child) { border-right: none; }
  .tab-btn.active {
    background: var(--text, #1e293b);
    color: var(--bg, #f8fafc);
  }
  .count { font-weight: 400; opacity: 0.8; font-size: 0.8rem; }
  .loading { text-align: center; color: var(--muted, #64748b); font-size: 0.85rem; padding: 2rem 0; }
  .note { margin: 0 0 0.5rem; font-size: 0.75rem; color: var(--muted, #64748b); }
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
  .pagination {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 0.5rem;
    margin-top: 1rem;
  }
  .page-info {
    font-size: 0.85rem;
    color: var(--muted, #64748b);
  }
  .pagination button {
    padding: 0.4rem 0.6rem;
    border: 1px solid var(--border, #e2e8f0);
    border-radius: 4px;
    background: var(--card-bg, #fff);
    color: var(--text, #1e293b);
    cursor: pointer;
    font-size: 0.85rem;
  }
  .pagination button:hover:not(:disabled) { background: var(--border, #e2e8f0); }
  .pagination button:disabled {
    opacity: 0.4;
    color: var(--muted, #64748b);
    cursor: not-allowed;
  }
</style>
