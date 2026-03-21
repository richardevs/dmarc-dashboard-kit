<script lang="ts">
  import { onMount } from "svelte";
  import {
    getDomains,
    getSummary,
    getTimeSeries,
    getTopSenders,
    getDomainAuth,
    getReports,
    clearPageCache,
    type Summary,
    type TimeSeriesPoint,
    type TopSender,
    type DomainAuth,
    type ReportList,
  } from "./lib/api";

  import SummaryCards from "./components/SummaryCards.svelte";
  import TimeSeriesChart from "./components/TimeSeriesChart.svelte";
  import TopSendersTable from "./components/TopSendersTable.svelte";
  import DomainAuthTable from "./components/DomainAuthTable.svelte";
  import ReportsTable from "./components/ReportsTable.svelte";

  let domains: string[] = $state([]);
  let selectedDomain: string = $state("");
  let selectedDays: string = $state(localStorage.getItem("selected-days") ?? "30");
  const isMasked = new URLSearchParams(window.location.search).get("maskDomain") === "true";
  let domainMap: Map<string, string> = $derived(new Map(domains.map((d, i) => [d, `Domain ${i + 1}`])));
  function maskDomain(name: string): string {
    if (!isMasked) return name;
    return domainMap.get(name) ?? name;
  }

  let summary: Summary | null = $state(null);
  let timeSeries: TimeSeriesPoint[] = $state([]);
  let topSenders: TopSender[] = $state([]);
  let domainAuth: DomainAuth[] = $state([]);
  let reports: ReportList | null = $state(null);
  let reportSort: string = $state("");
  let reportDir: string = $state("");
  let selectedDate: string = $state("");
  let error: string = $state("");

  async function loadData() {
    clearPageCache();
    selectedDate = "";
    error = "";
    reportSort = "";
    reportDir = "";
    try {
      const domain = selectedDomain || undefined;
      const [s, ts, senders, auth, reps] = await Promise.all([
        getSummary(selectedDays, domain),
        getTimeSeries(selectedDays, domain),
        getTopSenders(selectedDays, "10", domain),
        getDomainAuth(selectedDays),
        getReports("1", "20", domain),
      ]);
      summary = s;
      timeSeries = ts;
      topSenders = senders;
      domainAuth = auth;
      reports = reps;
    } catch (e) {
      error = e instanceof Error ? e.message : "Failed to load data";
    }
  }

  async function loadDateData(date: string) {
    reportSort = "";
    reportDir = "";
    try {
      const domain = selectedDomain || undefined;
      const [s, senders, auth, reps] = await Promise.all([
        getSummary(selectedDays, domain, date),
        getTopSenders(selectedDays, "10", domain, date),
        getDomainAuth(selectedDays, date),
        getReports("1", "20", domain, undefined, undefined, date),
      ]);
      summary = s;
      topSenders = senders;
      domainAuth = auth;
      reports = reps;
    } catch (e) {
      error = e instanceof Error ? e.message : "Failed to load data";
    }
  }

  async function revertData() {
    reportSort = "";
    reportDir = "";
    try {
      const domain = selectedDomain || undefined;
      const [s, ts, senders, auth, reps] = await Promise.all([
        getSummary(selectedDays, domain),
        getTimeSeries(selectedDays, domain),
        getTopSenders(selectedDays, "10", domain),
        getDomainAuth(selectedDays),
        getReports("1", "20", domain),
      ]);
      summary = s;
      timeSeries = ts;
      topSenders = senders;
      domainAuth = auth;
      reports = reps;
    } catch (e) {
      error = e instanceof Error ? e.message : "Failed to load data";
    }
  }

  function handleDateClick(date: string) {
    if (!date) {
      selectedDate = "";
      revertData();
    } else {
      selectedDate = date;
      loadDateData(date);
    }
  }

  async function handlePageChange(page: number) {
    const domain = selectedDomain || undefined;
    reports = await getReports(String(page), "20", domain, reportSort || undefined, reportDir || undefined, selectedDate || undefined);
  }

  async function handleSortChange(sort: string, dir: string) {
    reportSort = sort;
    reportDir = dir;
    const domain = selectedDomain || undefined;
    reports = await getReports("1", "20", domain, sort || undefined, dir || undefined, selectedDate || undefined);
  }

  onMount(async () => {
    try {
      domains = await getDomains();
    } catch {
      // API may not be available yet
    }
    loadData();
  });
</script>

<main>
  <header>
    <h1>DMARC Dashboard</h1>
    <div class="controls">
      <select bind:value={selectedDomain} onchange={loadData}>
        <option value="">All Domains</option>
        {#each domains as d}
          <option value={d}>{maskDomain(d)}</option>
        {/each}
      </select>
      <div class="btn-group">
        {#each ["7", "30", "90"] as d}
          <button class:active={selectedDays === d} onclick={() => { selectedDays = d; localStorage.setItem("selected-days", d); loadData(); }}>
            {d}d
          </button>
        {/each}
      </div>
    </div>
  </header>

  {#if error}
    <div class="error">{error}</div>
  {/if}

  <SummaryCards {summary} />

  {#if timeSeries.length > 0}
    <TimeSeriesChart data={timeSeries} {selectedDate} onDateClick={handleDateClick} />
  {/if}

  <div class="two-col">
    <TopSendersTable senders={topSenders} days={selectedDays} domain={selectedDomain} date={selectedDate} />
    <DomainAuthTable data={domainAuth} onDomainClick={(d) => { selectedDomain = selectedDomain === d ? "" : d; loadData(); }} {maskDomain} {selectedDomain} />
  </div>

  <ReportsTable {reports} onPageChange={handlePageChange} onSortChange={handleSortChange} {maskDomain} />
</main>

<style>
  :root {
    --card-bg: #ffffff;
    --border: #e2e8f0;
    --muted: #64748b;
    --bg: #f8fafc;
    --text: #1e293b;
    --row-alt: #f1f5f9;
  }

  @media (prefers-color-scheme: dark) {
    :root {
      --card-bg: #1e293b;
      --border: #334155;
      --muted: #94a3b8;
      --bg: #0f172a;
      --text: #f1f5f9;
      --row-alt: #1a2235;
    }
  }

  :global(body) {
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: var(--bg);
    color: var(--text);
  }

  :global(*:focus-visible) {
    outline: 2px solid #3b82f6;
    outline-offset: 2px;
  }

  main {
    max-width: 1200px;
    margin: 0 auto;
    padding: 2rem 1rem;
  }

  header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    flex-wrap: wrap;
    gap: 1rem;
    margin-bottom: 1.5rem;
  }

  h1 {
    margin: 0;
    font-size: 1.5rem;
  }

  .controls {
    display: flex;
    gap: 0.75rem;
    align-items: center;
  }

  select {
    padding: 0.4rem 0.6rem;
    border: 1px solid var(--border);
    border-radius: 4px;
    background: var(--card-bg);
    color: var(--text);
  }

  .btn-group {
    display: flex;
    gap: 0;
  }

  .btn-group button {
    padding: 0.4rem 0.8rem;
    border: 1px solid var(--border);
    background: var(--card-bg);
    color: var(--text);
    cursor: pointer;
    font-size: 0.85rem;
  }

  .btn-group button:first-child { border-radius: 4px 0 0 4px; }
  .btn-group button:last-child { border-radius: 0 4px 4px 0; }
  .btn-group button:not(:last-child) { border-right: none; }

  .btn-group button.active {
    background: var(--text);
    color: var(--bg);
  }

  .two-col {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1.5rem;
    margin-bottom: 1.5rem;
  }

  @media (max-width: 768px) {
    .two-col { grid-template-columns: 1fr; }
  }

  .error {
    background: #fef2f2;
    color: #dc2626;
    border: 1px solid #fecaca;
    border-radius: 8px;
    padding: 0.75rem 1rem;
    margin-bottom: 1rem;
  }
</style>
