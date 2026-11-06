<script lang="ts">
  import { untrack } from "svelte";
  import { getAllSenders, fetchIpInfo, type TopSender, type SenderList, type IpInfo } from "../lib/api";

  let { senders, days, domain, date = "" }: { senders: TopSender[]; days: string; domain: string; date?: string } = $props();

  type Tab = "top" | "all";
  let activeTab: Tab = $state("top");
  let showAuthCols: boolean = $state(localStorage.getItem("senders-auth-cols") === "true");

  // Country and network owner of the shown IPs. The worker looks them up in the local DB-IP
  // databases (no external service), so they are always on.
  let ipInfoMap: Record<string, IpInfo> = $state({});
  let ipInfoLoading: boolean = $state(false);
  const ipInfoRequested = new Set<string>();

  async function loadIpInfo(ips: string[]) {
    const missing = ips.filter((ip) => !ipInfoRequested.has(ip));
    if (missing.length === 0) return;
    for (const ip of missing) ipInfoRequested.add(ip);
    ipInfoLoading = true;
    try {
      ipInfoMap = { ...ipInfoMap, ...(await fetchIpInfo(missing)) };
    } finally {
      ipInfoLoading = false;
    }
  }

  function toggleAuthCols() {
    showAuthCols = !showAuthCols;
    localStorage.setItem("senders-auth-cols", String(showAuthCols));
  }

  // All Senders state
  let allSendersData = $state<SenderList | null>(null);
  let allLoading: boolean = $state(false);
  let allSort: string = $state("total_count");
  let allDir: string = $state("desc");

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
    allSort = "total_count";
    allDir = "desc";
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

  $effect(() => {
    const ips = displayRows.map((s) => s.source_ip);
    untrack(() => loadIpInfo(ips));
  });


  // Pagination for All Senders
  let totalPages = $derived(allSendersData ? Math.ceil(allSendersData.total / allSendersData.pageSize) : 1);

  function goToPage(p: number) {
    const clamped = Math.max(1, Math.min(p, totalPages));
    if (allSendersData && clamped !== allSendersData.page) {
      fetchAllSenders(clamped);
    }
  }
</script>

<div class="panel senders">
  <div class="panel-head">
    <div class="tab-group" role="tablist">
      <button class="tab-btn" role="tab" id="tab-top" aria-selected={activeTab === "top"} aria-controls="tabpanel-senders" class:active={activeTab === "top"} onclick={() => switchTab("top")}>Top sources</button>
      <button class="tab-btn" role="tab" id="tab-all" aria-selected={activeTab === "all"} aria-controls="tabpanel-senders" class:active={activeTab === "all"} onclick={() => switchTab("all")}>
        All sources
        {#if allSendersData}
          <span class="count">({allSendersData.total})</span>
        {/if}
      </button>
    </div>
    <div>
      <button class="btn-small" class:active={showAuthCols} aria-pressed={showAuthCols} onclick={toggleAuthCols}>{showAuthCols ? "Hide blocked details" : "Show blocked details"}</button>
    </div>
  </div>

  {#if showAuthCols}
    <p class="note">Blocked: the receiver quarantined or rejected the message. Misaligned: SPF or DKIM did not pass for the From domain. The misaligned counts include delivered messages.</p>
  {:else}
    <p class="note">Delivered: the receiver applied no policy. Blocked: the receiver quarantined or rejected the message.</p>
  {/if}

  <div aria-live="polite">
  {#if activeTab === "all" && allLoading && !allSendersData}
    <p class="empty">Loading…</p>
  {:else}
    <div id="tabpanel-senders" role="tabpanel" aria-labelledby={activeTab === "top" ? "tab-top" : "tab-all"}>
    <table class="data">
      <thead>
        <tr>
          <th scope="col" class="sortable" tabindex="0" aria-sort={ariaSort("source_ip")} onclick={() => toggleSort("source_ip")} onkeydown={(e) => e.key === "Enter" && toggleSort("source_ip")}>Source IP<span aria-hidden="true">{sortIndicator("source_ip")}</span></th>
          <th scope="col" class="sortable num" tabindex="0" aria-sort={ariaSort("total_count")} onclick={() => toggleSort("total_count")} onkeydown={(e) => e.key === "Enter" && toggleSort("total_count")}>Total<span aria-hidden="true">{sortIndicator("total_count")}</span></th>
          {#if !showAuthCols}
            <th scope="col" class="sortable num" tabindex="0" aria-sort={ariaSort("pass_count")} onclick={() => toggleSort("pass_count")} onkeydown={(e) => e.key === "Enter" && toggleSort("pass_count")}>Delivered<span aria-hidden="true">{sortIndicator("pass_count")}</span></th>
          {/if}
          <th scope="col" class="sortable num" title="Quarantined or rejected" tabindex="0" aria-sort={ariaSort("fail_count")} onclick={() => toggleSort("fail_count")} onkeydown={(e) => e.key === "Enter" && toggleSort("fail_count")}>Blocked<span aria-hidden="true">{sortIndicator("fail_count")}</span></th>
          {#if showAuthCols}
            <th scope="col" class="sortable num" tabindex="0" aria-sort={ariaSort("spf_fail")} onclick={() => toggleSort("spf_fail")} onkeydown={(e) => e.key === "Enter" && toggleSort("spf_fail")}>SPF misaligned<span aria-hidden="true">{sortIndicator("spf_fail")}</span></th>
            <th scope="col" class="sortable num" tabindex="0" aria-sort={ariaSort("dkim_fail")} onclick={() => toggleSort("dkim_fail")} onkeydown={(e) => e.key === "Enter" && toggleSort("dkim_fail")}>DKIM misaligned<span aria-hidden="true">{sortIndicator("dkim_fail")}</span></th>
          {:else}
            <th scope="col" class="sortable num" tabindex="0" aria-sort={ariaSort("rate")} onclick={() => toggleSort("rate")} onkeydown={(e) => e.key === "Enter" && toggleSort("rate")}>Delivered %<span aria-hidden="true">{sortIndicator("rate")}</span></th>
          {/if}
        </tr>
      </thead>
      <tbody>
        {#each displayRows as s}
          <tr>
            <td class="mono">
              {s.source_ip}
              {#if ipInfoMap[s.source_ip]?.country}
                <span class="geo-info" title={ipInfoMap[s.source_ip].org}>{ipInfoMap[s.source_ip].countryCode} · {ipInfoMap[s.source_ip].org}</span>
              {:else if ipInfoLoading}
                <span class="geo-info muted">…</span>
              {/if}
            </td>
            <td class="num">{s.total_count.toLocaleString()}</td>
            {#if !showAuthCols}
              <td class="num" class:good={s.pass_count > 0} class:muted={s.pass_count === 0}>{s.pass_count.toLocaleString()}</td>
            {/if}
            <td class="num" class:bad={s.fail_count > 0} class:muted={s.fail_count === 0}>{s.fail_count.toLocaleString()}</td>
            {#if showAuthCols}
              <td class="num" class:bad={s.spf_fail_count > 0} class:muted={s.spf_fail_count === 0}>{s.spf_fail_count.toLocaleString()}</td>
              <td class="num" class:bad={s.dkim_fail_count > 0} class:muted={s.dkim_fail_count === 0}>{s.dkim_fail_count.toLocaleString()}</td>
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
          <tr><td colspan="5" class="empty">No reports for this period</td></tr>
        {/if}
      </tbody>
    </table>
    </div>

    {#if activeTab === "all" && allSendersData && totalPages > 1}
      <div class="pagination">
        <button aria-label="First page" disabled={allSendersData.page <= 1} onclick={() => goToPage(1)}>&laquo;</button>
        <button aria-label="Previous page" disabled={allSendersData.page <= 1} onclick={() => goToPage(allSendersData!.page - 1)}>&lsaquo; Previous</button>
        <span class="page-info">{allSendersData.page} / {totalPages}</span>
        <button aria-label="Next page" disabled={allSendersData.page >= totalPages} onclick={() => goToPage(allSendersData!.page + 1)}>Next &rsaquo;</button>
        <button aria-label="Last page" disabled={allSendersData.page >= totalPages} onclick={() => goToPage(totalPages)}>&raquo;</button>
      </div>
    {/if}

    <!-- DB-IP Lite (CC BY 4.0) requires this link wherever its data is shown. -->
    <p class="geo-credit"><a href="https://db-ip.com" target="_blank" rel="noopener noreferrer">IP Geolocation by DB-IP</a></p>
  {/if}
  </div>
</div>

<style>
  .senders { overflow-x: auto; }
  .geo-info {
    display: block;
    font-size: 0.72rem;
    color: var(--muted);
    max-width: 130px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .geo-credit { margin: var(--gap-sm) 0 0; text-align: right; font-size: 0.7rem; color: var(--muted); }
  .geo-credit a { color: inherit; text-decoration: none; }
  .geo-credit a:hover { color: var(--text); }
  .good { color: #16a34a; }
  .bad { color: #dc2626; }
</style>
