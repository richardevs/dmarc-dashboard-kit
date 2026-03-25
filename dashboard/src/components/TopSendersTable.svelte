<script lang="ts">
  import { untrack } from "svelte";
  import { getAllSenders, type TopSender, type SenderList } from "../lib/api";

  let { senders, days, domain, date = "" }: { senders: TopSender[]; days: string; domain: string; date?: string } = $props();

  type Tab = "top" | "all";
  let activeTab: Tab = $state("top");
  let showAuthCols: boolean = $state(localStorage.getItem("senders-auth-cols") === "true");

  function toggleAuthCols() {
    showAuthCols = !showAuthCols;
    localStorage.setItem("senders-auth-cols", String(showAuthCols));
  }

  // All Senders state
  let allSendersData: SenderList | null = $state(null);
  let allLoading: boolean = $state(false);
  let allSort: string = $state("");
  let allDir: string = $state("");

  async function fetchAllSenders(page = 1) {
    allLoading = true;
    try {
      allSendersData = await getAllSenders(days, String(page), "15", domain || undefined, allSort || undefined, allDir || undefined, date || undefined);
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
    void date;
    allSendersData = null;
    allSort = "";
    allDir = "";
    untrack(() => {
      if (activeTab === "all") {
        fetchAllSenders();
      }
    });
  });

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

  // Sorting
  type SortKey = "source_ip" | "total_count" | "pass_count" | "fail_count" | "rate" | "spf_fail" | "dkim_fail";
  let topSortKey: SortKey = $state("total_count");
  let topSortAsc: boolean = $state(false);

  function toggleSort(key: SortKey) {
    if (activeTab === "top") {
      if (topSortKey === key) { topSortAsc = !topSortAsc; }
      else { topSortKey = key; topSortAsc = false; }
    } else {
      if (allSort === key) { allDir = allDir === "asc" ? "desc" : "asc"; }
      else { allSort = key; allDir = "desc"; }
      fetchAllSenders(1);
    }
  }

  function ariaSort(key: SortKey): "ascending" | "descending" | "none" {
    if (activeTab === "top") {
      if (topSortKey !== key) return "none";
      return topSortAsc ? "ascending" : "descending";
    } else {
      if (allSort !== key) return "none";
      return allDir === "asc" ? "ascending" : "descending";
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
      else if (topSortKey === "rate") cmp = pctNum(a.pass_count, a.total_count) - pctNum(b.pass_count, b.total_count);
      else if (topSortKey === "spf_fail") cmp = a.spf_fail_count - b.spf_fail_count;
      else if (topSortKey === "dkim_fail") cmp = a.dkim_fail_count - b.dkim_fail_count;
      else cmp = (a[topSortKey] as number) - (b[topSortKey] as number);
      return topSortAsc ? cmp : -cmp;
    })
  );

  let displayRows = $derived(activeTab === "top" ? sorted : (allSendersData?.data ?? []));


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
    <div class="tab-group" role="tablist">
      <button class="tab-btn" role="tab" id="tab-top" aria-selected={activeTab === "top"} aria-controls="tabpanel-senders" class:active={activeTab === "top"} onclick={() => switchTab("top")}>Top Senders</button>
      <button class="tab-btn" role="tab" id="tab-all" aria-selected={activeTab === "all"} aria-controls="tabpanel-senders" class:active={activeTab === "all"} onclick={() => switchTab("all")}>
        All Senders
        {#if allSendersData}
          <span class="count">({allSendersData.total})</span>
        {/if}
      </button>
    </div>
    <button class="toggle-auth" class:active={showAuthCols} aria-pressed={showAuthCols} onclick={toggleAuthCols}>{showAuthCols ? "Hide Details" : "Show Details"}</button>
  </div>

  <p class="note">Pass = DMARC disposition: none. Fail = quarantine or reject.</p>

  <div aria-live="polite">
  {#if activeTab === "all" && allLoading && !allSendersData}
    <p class="loading">Loading...</p>
  {:else}
    <div id="tabpanel-senders" role="tabpanel" aria-labelledby={activeTab === "top" ? "tab-top" : "tab-all"}>
    <table>
      <thead>
        <tr>
          <th scope="col" class="sortable" tabindex="0" aria-sort={ariaSort("source_ip")} onclick={() => toggleSort("source_ip")} onkeydown={(e) => e.key === "Enter" && toggleSort("source_ip")}>Source IP<span aria-hidden="true">{sortIndicator("source_ip")}</span></th>
          <th scope="col" class="sortable num" tabindex="0" aria-sort={ariaSort("total_count")} onclick={() => toggleSort("total_count")} onkeydown={(e) => e.key === "Enter" && toggleSort("total_count")}>Total<span aria-hidden="true">{sortIndicator("total_count")}</span></th>
          <th scope="col" class="sortable num" tabindex="0" aria-sort={ariaSort("pass_count")} onclick={() => toggleSort("pass_count")} onkeydown={(e) => e.key === "Enter" && toggleSort("pass_count")}>Pass<span aria-hidden="true">{sortIndicator("pass_count")}</span></th>
          <th scope="col" class="sortable num" tabindex="0" aria-sort={ariaSort("fail_count")} onclick={() => toggleSort("fail_count")} onkeydown={(e) => e.key === "Enter" && toggleSort("fail_count")}>Fail<span aria-hidden="true">{sortIndicator("fail_count")}</span></th>
          {#if showAuthCols}
            <th scope="col" class="sortable num" tabindex="0" aria-sort={ariaSort("spf_fail")} onclick={() => toggleSort("spf_fail")} onkeydown={(e) => e.key === "Enter" && toggleSort("spf_fail")}>SPF Fail<span aria-hidden="true">{sortIndicator("spf_fail")}</span></th>
            <th scope="col" class="sortable num" tabindex="0" aria-sort={ariaSort("dkim_fail")} onclick={() => toggleSort("dkim_fail")} onkeydown={(e) => e.key === "Enter" && toggleSort("dkim_fail")}>DKIM Fail<span aria-hidden="true">{sortIndicator("dkim_fail")}</span></th>
          {:else}
            <th scope="col" class="sortable num" tabindex="0" aria-sort={ariaSort("rate")} onclick={() => toggleSort("rate")} onkeydown={(e) => e.key === "Enter" && toggleSort("rate")}>Rate<span aria-hidden="true">{sortIndicator("rate")}</span></th>
          {/if}
        </tr>
      </thead>
      <tbody>
        {#each displayRows as s}
          <tr>
            <td class="mono">{s.source_ip}</td>
            <td class="num">{s.total_count.toLocaleString()}</td>
            <td class="num good">{s.pass_count.toLocaleString()}</td>
            <td class="num bad">{s.fail_count.toLocaleString()}</td>
            {#if showAuthCols}
              <td class="num" class:warn={s.spf_fail_count > 0} class:muted={s.spf_fail_count === 0}>{s.spf_fail_count.toLocaleString()}</td>
              <td class="num" class:warn={s.dkim_fail_count > 0} class:muted={s.dkim_fail_count === 0}>{s.dkim_fail_count.toLocaleString()}</td>
            {:else}
              {@const pct = pctNum(s.pass_count, s.total_count)}
              <td class="num">
                <span class="rate-cell">
                  <span class="rate-bar" aria-hidden="true"><span class="rate-fill" style="width:{pct}%; background:{barColor(pct)}"></span></span>
                  <span class="rate-text" style="color:{barColor(pct)}">{pctStr(s.pass_count, s.total_count)}</span>
                </span>
              </td>
            {/if}
          </tr>
        {/each}
        {#if displayRows.length === 0}
          <tr><td colspan={showAuthCols ? 6 : 5} class="empty">No data</td></tr>
        {/if}
      </tbody>
    </table>
    </div>

    {#if activeTab === "all" && allSendersData && totalPages > 1}
      <div class="pagination">
        <button aria-label="First page" disabled={allSendersData.page <= 1} onclick={() => goToPage(1)}>&laquo;</button>
        <button aria-label="Previous page" disabled={allSendersData.page <= 1} onclick={() => goToPage(allSendersData!.page - 1)}>&lsaquo; Prev</button>
        <span class="page-info">{allSendersData.page} / {totalPages}</span>
        <button aria-label="Next page" disabled={allSendersData.page >= totalPages} onclick={() => goToPage(allSendersData!.page + 1)}>Next &rsaquo;</button>
        <button aria-label="Last page" disabled={allSendersData.page >= totalPages} onclick={() => goToPage(totalPages)}>&raquo;</button>
      </div>
    {/if}
  {/if}
  </div>
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
    align-items: center;
    justify-content: space-between;
    margin-bottom: 1rem;
  }
  .tab-group {
    display: flex;
    gap: 0;
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
  .toggle-auth {
    padding: 0.3rem 0.6rem;
    border: 1px solid var(--border, #e2e8f0);
    border-radius: 4px;
    background: var(--card-bg, #fff);
    color: var(--muted, #64748b);
    cursor: pointer;
    font-size: 0.75rem;
  }
  .toggle-auth.active {
    background: var(--text, #1e293b);
    color: var(--bg, #f8fafc);
    border-color: var(--text, #1e293b);
  }
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
  tbody tr { height: 2.65rem; }
  tbody tr:nth-child(even) { background: var(--row-alt, #f1f5f9); }
  .mono { font-family: monospace; }
  .num { text-align: right; font-variant-numeric: tabular-nums; }
  .good { color: #16a34a; }
  .bad { color: #dc2626; }
  .warn { color: #8b3a3a; }
  .muted { color: var(--muted, #64748b); }
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
