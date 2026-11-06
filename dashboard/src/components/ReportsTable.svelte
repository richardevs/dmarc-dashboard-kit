<script lang="ts">
  import { getReporters, type ReportList, type Reporter } from "../lib/api";

  let { reports, domain, onPageChange, onSortChange, maskDomain }: {
    reports: ReportList | null;
    domain: string;
    onPageChange: (page: number) => void;
    onSortChange: (sort: string, dir: string) => void;
    maskDomain: (name: string) => string;
  } = $props();

  // "reporters" (default): one row per organization that sends reports. "all": every report.
  type View = "reporters" | "all";
  let view: View = $state(localStorage.getItem("reports-view") === "all" ? "all" : "reporters");

  function setView(v: View) {
    view = v;
    localStorage.setItem("reports-view", v);
  }

  let reporters = $state<Reporter[] | null>(null);

  $effect(() => {
    const d = domain;
    getReporters(d || undefined)
      .then((r) => { if (d === domain) reporters = r; })
      .catch(() => { reporters = []; });
  });

  // received_at is stored as UTC "YYYY-MM-DD HH:MM:SS".
  function receivedDate(utc: string): Date {
    return new Date(utc.replace(" ", "T") + "Z");
  }

  const relative = new Intl.RelativeTimeFormat("en", { numeric: "auto" });

  // A reporter quiet for this long has probably stopped sending.
  const STALE_DAYS = 30;

  function isStale(utc: string): boolean {
    return Date.now() - receivedDate(utc).getTime() > STALE_DAYS * 86_400_000;
  }

  function ago(utc: string): string {
    const hours = (receivedDate(utc).getTime() - Date.now()) / 3_600_000;
    if (hours > -1) return "less than 1 hour ago";
    if (hours > -48) return relative.format(Math.round(hours), "hour");
    return relative.format(Math.round(hours / 24), "day");
  }

  function formatDate(ts: number): string {
    return new Date(ts * 1000).toLocaleDateString();
  }

  type SortKey = "org_name" | "domain" | "date_range_begin";
  let sortKey: SortKey | null = $state(null);
  let sortAsc: boolean = $state(true);

  function toggleSort(key: SortKey) {
    if (sortKey === key) { sortAsc = !sortAsc; }
    else { sortKey = key; sortAsc = true; }
    onSortChange(key, sortAsc ? "asc" : "desc");
  }

  function sortIndicator(key: SortKey): string {
    if (sortKey !== key) return "";
    return sortAsc ? " \u25B2" : " \u25BC";
  }

  let totalPages = $derived(reports ? Math.ceil(reports.total / reports.pageSize) : 1);
  let pageInput: number = $state(1);

  $effect(() => {
    if (reports) pageInput = reports.page;
  });

  function goToPage(p: number) {
    const clamped = Math.max(1, Math.min(p, totalPages));
    if (reports && clamped !== reports.page) onPageChange(clamped);
  }

  function handlePageInput(e: Event) {
    const target = e.target as HTMLInputElement;
    goToPage(parseInt(target.value) || 1);
  }

  function handlePageKeydown(e: KeyboardEvent) {
    if (e.key === "Enter") {
      const target = e.target as HTMLInputElement;
      goToPage(parseInt(target.value) || 1);
    }
  }
</script>

<div class="panel reports">
  <div class="panel-head">
  <div class="tab-group" role="tablist" aria-label="Reports">
    <button class="tab-btn" role="tab" aria-selected={view === "reporters"} class:active={view === "reporters"} onclick={() => setView("reporters")}>
      Reporters{#if reporters}<span class="count">({reporters.length})</span>{/if}
    </button>
    <button class="tab-btn" role="tab" aria-selected={view === "all"} class:active={view === "all"} onclick={() => setView("all")}>
      All reports{#if reports}<span class="count">({reports.total})</span>{/if}
    </button>
  </div>
  </div>

  {#if view === "reporters"}
    <p class="note">All time. A grey date is older than {STALE_DAYS} days.</p>
    {#if !reporters}
      <p class="empty">Loading…</p>
    {:else}
      <table class="data compact">
        <thead>
          <tr>
            <th scope="col">Reporter</th>
            <th scope="col" class="num">Reports</th>
            <th scope="col">Last received</th>
            <th scope="col">Last report ID</th>
          </tr>
        </thead>
        <tbody>
          {#each reporters as r}
            <tr>
              <td>{r.org_name || "—"}</td>
              <td class="num">{r.reports.toLocaleString()}</td>
              <td class="nowrap" class:stale={isStale(r.last_received_at)} title="{receivedDate(r.last_received_at).toLocaleString()} ({ago(r.last_received_at)})">
                {receivedDate(r.last_received_at).toLocaleDateString()}
              </td>
              <td class="mono truncate" title={r.last_report_id}>{r.last_report_id}</td>
            </tr>
          {/each}
          {#if reporters.length === 0}
            <tr><td colspan="4" class="empty">No reports</td></tr>
          {/if}
        </tbody>
      </table>
    {/if}
  {:else if reports}
    <table class="data">
      <thead>
        <tr>
          <th scope="col" class="sortable" tabindex="0" aria-sort={sortKey === "org_name" ? (sortAsc ? "ascending" : "descending") : "none"} onclick={() => toggleSort("org_name")} onkeydown={(e) => e.key === "Enter" && toggleSort("org_name")}>Reporter<span aria-hidden="true">{sortIndicator("org_name")}</span></th>
          <th scope="col" class="sortable" tabindex="0" aria-sort={sortKey === "domain" ? (sortAsc ? "ascending" : "descending") : "none"} onclick={() => toggleSort("domain")} onkeydown={(e) => e.key === "Enter" && toggleSort("domain")}>Domain<span aria-hidden="true">{sortIndicator("domain")}</span></th>
          <th scope="col" class="sortable" tabindex="0" aria-sort={sortKey === "date_range_begin" ? (sortAsc ? "ascending" : "descending") : "none"} onclick={() => toggleSort("date_range_begin")} onkeydown={(e) => e.key === "Enter" && toggleSort("date_range_begin")}>Period<span aria-hidden="true">{sortIndicator("date_range_begin")}</span></th>
          <th scope="col" class="num">Messages</th>
          <th scope="col">Report ID</th>
        </tr>
      </thead>
      <tbody>
        {#each reports.data as r}
          <tr>
            <td>{r.org_name}</td>
            <td>{maskDomain(r.domain)}</td>
            <td class="nowrap">{formatDate(r.date_range_begin)} – {formatDate(r.date_range_end)}</td>
            <td class="num">{r.total_count.toLocaleString()}</td>
            <td class="mono truncate" title={String(r.report_id)}>{String(r.report_id)}</td>
          </tr>
        {/each}
        {#if reports.data.length === 0}
          <tr><td colspan="5" class="empty">No reports</td></tr>
        {/if}
      </tbody>
    </table>
    {#if totalPages > 1}
      <div class="pagination">
        <button aria-label="First page" disabled={reports.page <= 1} onclick={() => goToPage(1)}>&laquo;</button>
        <button aria-label="Previous page" disabled={reports.page <= 1} onclick={() => goToPage(reports!.page - 1)}>&lsaquo; Previous</button>
        <span class="page-info">
          <input
            type="number"
            class="page-input"
            aria-label="Page number"
            min="1"
            max={totalPages}
            bind:value={pageInput}
            onblur={handlePageInput}
            onkeydown={handlePageKeydown}
          /> / {totalPages}
        </span>
        <button aria-label="Next page" disabled={reports.page >= totalPages} onclick={() => goToPage(reports!.page + 1)}>Next &rsaquo;</button>
        <button aria-label="Last page" disabled={reports.page >= totalPages} onclick={() => goToPage(totalPages)}>&raquo;</button>
      </div>
    {/if}
  {/if}
</div>

<style>
  .reports { overflow-x: auto; }
  .compact th, .compact td { padding: 0.35rem 0.6rem; }
  .compact td { font-size: 0.8rem; }
  .stale { color: var(--muted); }
  .truncate { max-width: 300px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .nowrap { white-space: nowrap; }
  .page-input {
    width: 3.5em;
    padding: 0.3rem 0.4rem;
    border: 1px solid var(--border, #e2e8f0);
    border-radius: 4px;
    background: var(--card-bg, #fff);
    color: var(--text, #1e293b);
    font-size: 0.85rem;
    text-align: center;
    -moz-appearance: textfield;
    appearance: textfield;
  }
  .page-input::-webkit-inner-spin-button,
  .page-input::-webkit-outer-spin-button { -webkit-appearance: none; margin: 0; }
</style>
