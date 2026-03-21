<script lang="ts">
  import { onMount } from "svelte";
  import type { ReportList, ReportListItem } from "../lib/api";

  let { reports, onPageChange, onSortChange, maskDomain }: {
    reports: ReportList | null;
    onPageChange: (page: number) => void;
    onSortChange: (sort: string, dir: string) => void;
    maskDomain: (name: string) => string;
  } = $props();

  let expanded: boolean = $state(false);

  onMount(() => {
    expanded = localStorage.getItem("reports-expanded") === "true";
  });

  function toggleExpanded() {
    expanded = !expanded;
    localStorage.setItem("reports-expanded", String(expanded));
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

<div class="table-container">
  <button class="toggle" onclick={toggleExpanded}>
    <span class="chevron">{expanded ? "\u25BC" : "\u25B6"}</span> Recent Reports
    {#if reports}
      <span class="count">({reports.total})</span>
    {/if}
  </button>
  {#if expanded && reports}
    <table>
      <thead>
        <tr>
          <th class="sortable" onclick={() => toggleSort("org_name")}>Org{sortIndicator("org_name")}</th>
          <th class="sortable" onclick={() => toggleSort("domain")}>Domain{sortIndicator("domain")}</th>
          <th class="sortable" onclick={() => toggleSort("date_range_begin")}>Date Range{sortIndicator("date_range_begin")}</th>
          <th class="records-header">Records</th>
          <th>Report ID</th>
        </tr>
      </thead>
      <tbody>
        {#each reports.data as r}
          <tr>
            <td>{r.org_name}</td>
            <td>{maskDomain(r.domain)}</td>
            <td class="nowrap">{formatDate(r.date_range_begin)} – {formatDate(r.date_range_end)}</td>
            <td class="records">{r.total_count.toLocaleString()}</td>
            <td class="mono truncate" title={String(r.report_id)}>{String(r.report_id)}</td>
          </tr>
        {/each}
        {#if reports.data.length === 0}
          <tr><td colspan="5" class="empty">No reports yet</td></tr>
        {/if}
      </tbody>
    </table>
    {#if totalPages > 1}
      <div class="pagination">
        <button disabled={reports.page <= 1} onclick={() => goToPage(1)}>&laquo;</button>
        <button disabled={reports.page <= 1} onclick={() => goToPage(reports!.page - 1)}>&lsaquo; Prev</button>
        <span class="page-info">
          <input
            type="number"
            class="page-input"
            min="1"
            max={totalPages}
            bind:value={pageInput}
            onblur={handlePageInput}
            onkeydown={handlePageKeydown}
          /> / {totalPages}
        </span>
        <button disabled={reports.page >= totalPages} onclick={() => goToPage(reports!.page + 1)}>Next &rsaquo;</button>
        <button disabled={reports.page >= totalPages} onclick={() => goToPage(totalPages)}>&raquo;</button>
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
    overflow-x: auto;
  }
  .toggle {
    all: unset;
    cursor: pointer;
    user-select: none;
    font-size: 1rem;
    font-weight: 700;
    color: var(--text, #1e293b);
  }
  .toggle:hover { opacity: 0.8; }
  .chevron { display: inline-block; width: 1em; font-size: 0.75rem; }
  .count { font-weight: 400; color: var(--muted, #64748b); font-size: 0.85rem; }
  table { width: 100%; border-collapse: collapse; font-size: 0.85rem; margin-top: 1rem; }
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
  .mono { font-family: monospace; font-size: 0.8rem; }
  .truncate { max-width: 300px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .records { text-align: right; font-variant-numeric: tabular-nums; }
  .records-header { text-align: right; }
  .nowrap { white-space: nowrap; }
  .empty { text-align: center; color: var(--muted, #64748b); }
  .pagination {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 0.5rem;
    margin-top: 1rem;
  }
  .page-info {
    display: flex;
    align-items: center;
    gap: 0.25rem;
    font-size: 0.85rem;
  }
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
  }
  .page-input::-webkit-inner-spin-button,
  .page-input::-webkit-outer-spin-button { -webkit-appearance: none; margin: 0; }
  button {
    padding: 0.4rem 0.6rem;
    border: 1px solid var(--border, #e2e8f0);
    border-radius: 4px;
    background: var(--card-bg, #fff);
    color: var(--text, #1e293b);
    cursor: pointer;
    font-size: 0.85rem;
  }
  button:hover:not(:disabled) { background: var(--border, #e2e8f0); }
  button:disabled {
    opacity: 0.4;
    color: var(--muted, #64748b);
    cursor: not-allowed;
  }
</style>
