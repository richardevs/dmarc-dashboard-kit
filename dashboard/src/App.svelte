<script lang="ts">
  import { onMount } from "svelte";
  import {
    getDomains,
    getSummary,
    getTimeSeries,
    getTopSenders,
    getDomainAuth,
    getReports,
    getIngestErrors,
    type IngestErrorItem,
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
  import Analyzer from "./components/Analyzer.svelte";
  import IngestErrors from "./components/IngestErrors.svelte";

  type Page = "overview" | "analyzer" | "errors";
  // #/analyzer/<domain> opens the Analyzer for one policy domain; there the URL decides the domain.
  function parseHash(): { page: Page; domain: string } {
    if (/^#\/errors\/?$/.test(window.location.hash)) return { page: "errors", domain: "" };
    const m = window.location.hash.match(/^#\/analyzer(?:\/([^/]+))?\/?$/);
    if (!m) return { page: "overview", domain: "" };
    return { page: "analyzer", domain: m[1] ? decodeURIComponent(m[1]) : "" };
  }
  const initialRoute = parseHash();
  let page: Page = $state(initialRoute.page);

  let domains: string[] = $state([]);
  let selectedDomain: string = $state(initialRoute.page === "analyzer" ? initialRoute.domain : "");
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

  let requestToken = 0;

  async function fetchAll() {
    reportSort = "";
    reportDir = "";
    const token = ++requestToken;
    try {
      const domain = selectedDomain || undefined;
      const [s, ts, senders, auth, reps] = await Promise.all([
        getSummary(selectedDays, domain),
        getTimeSeries(selectedDays, domain),
        getTopSenders(selectedDays, "10", domain),
        getDomainAuth(selectedDays),
        getReports("1", "20", domain),
      ]);
      if (token !== requestToken) return;
      summary = s;
      timeSeries = ts;
      topSenders = senders;
      domainAuth = auth;
      reports = reps;
    } catch (e) {
      if (token !== requestToken) return;
      error = e instanceof Error ? e.message : "Failed to load data";
    }
  }

  async function loadData() {
    clearPageCache();
    selectedDate = "";
    error = "";
    await fetchAll();
  }

  async function loadDateData(date: string) {
    reportSort = "";
    reportDir = "";
    const token = ++requestToken;
    try {
      const domain = selectedDomain || undefined;
      const [s, senders, auth, reps] = await Promise.all([
        getSummary(selectedDays, domain, date),
        getTopSenders(selectedDays, "10", domain, date),
        getDomainAuth(selectedDays, date),
        getReports("1", "20", domain, undefined, undefined, date),
      ]);
      if (token !== requestToken) return;
      summary = s;
      topSenders = senders;
      domainAuth = auth;
      reports = reps;
    } catch (e) {
      if (token !== requestToken) return;
      error = e instanceof Error ? e.message : "Failed to load data";
    }
  }

  function handleDateClick(date: string) {
    if (!date) {
      selectedDate = "";
      fetchAll();
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

  function onHashChange() {
    const route = parseHash();
    page = route.page;
    if (route.page === "analyzer" && route.domain !== selectedDomain) {
      selectedDomain = route.domain;
      loadData();
    }
  }

  function onDomainChange() {
    if (page === "analyzer") window.location.hash = selectedDomain ? `#/analyzer/${encodeURIComponent(selectedDomain)}` : "#/analyzer";
    loadData();
  }

  // Failures stay until dismissed, independent of the date range.
  let ingestErrors: IngestErrorItem[] = $state([]);

  async function loadIngestErrors() {
    try {
      ingestErrors = await getIngestErrors();
    } catch {
      // Keep the last list; the main data load reports API errors.
    }
  }

  onMount(async () => {
    loadIngestErrors();
    try {
      domains = await getDomains();
    } catch {
      // API may not be available yet
    }
    loadData();
  });
</script>

<svelte:window onhashchange={onHashChange} />

<main>
  <header>
    <h1>DMARC Dashboard <a class="commit-badge" href="https://github.com/richardevs/dmarc-dashboard-kit" target="_blank" rel="noopener noreferrer">{__GIT_HASH__}</a></h1>
    <nav class="tabs" aria-label="Pages">
      <a href="#/" class:active={page === "overview"} aria-current={page === "overview" ? "page" : undefined}>Overview</a>
      <a href={selectedDomain ? `#/analyzer/${encodeURIComponent(selectedDomain)}` : "#/analyzer"} class:active={page === "analyzer"} aria-current={page === "analyzer" ? "page" : undefined}>Analyzer</a>
      {#if ingestErrors.length > 0 || page === "errors"}
        <a href="#/errors" class:active={page === "errors"} aria-current={page === "errors" ? "page" : undefined}>
          Report errors{#if ingestErrors.length > 0}<span class="count">{ingestErrors.length}</span>{/if}
        </a>
      {/if}
    </nav>
    <div class="controls">
      <select bind:value={selectedDomain} onchange={onDomainChange} aria-label="Filter by domain">
        <option value="">All domains</option>
        {#each domains as d}
          <option value={d}>{maskDomain(d)}</option>
        {/each}
      </select>
      <div class="btn-group">
        {#each ["7", "30", "90"] as d}
          <button class:active={selectedDays === d} aria-pressed={selectedDays === d} title="Last {d} days" onclick={() => { selectedDays = d; localStorage.setItem("selected-days", d); loadData(); }}>
            {d}d
          </button>
        {/each}
      </div>
    </div>
  </header>

  {#if error}
    <div class="error-box" role="alert">{error}</div>
  {/if}

  {#if page === "errors"}
    <IngestErrors errors={ingestErrors} onDismissed={(id) => { ingestErrors = ingestErrors.filter((e) => e.id !== id); }} />
  {:else if page === "analyzer"}
    <Analyzer days={selectedDays} domain={selectedDomain} {domainAuth} {maskDomain} />
  {:else}
    {#if ingestErrors.length > 0}
      <div class="ingest-warning" role="status">
        <span><strong>The worker cannot read {ingestErrors.length} report email{ingestErrors.length === 1 ? "" : "s"}.</strong> {ingestErrors.length === 1 ? "Its" : "Their"} data is not in the dashboard.</span>
        <a href="#/errors">Show the errors</a>
      </div>
    {/if}

    <SummaryCards {summary} />

    {#if timeSeries.length > 0}
      <TimeSeriesChart data={timeSeries} {selectedDate} onDateClick={handleDateClick} />
    {/if}

    <div class="two-col">
      <TopSendersTable senders={topSenders} days={selectedDays} domain={selectedDomain} date={selectedDate} />
      <DomainAuthTable data={domainAuth} onDomainClick={(d) => { selectedDomain = selectedDomain === d ? "" : d; loadData(); }} {maskDomain} {selectedDomain} />
    </div>

    <ReportsTable {reports} domain={selectedDomain} onPageChange={handlePageChange} onSortChange={handleSortChange} {maskDomain} />
  {/if}
</main>

<style>
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
    margin-bottom: var(--gap-section);
  }

  h1 {
    margin: 0;
    font-size: 1.5rem;
  }

  .tabs {
    display: flex;
    gap: 0.25rem;
    margin-right: auto;
  }

  .tabs a {
    padding: 0.35rem 0.75rem;
    border-radius: 4px;
    color: var(--muted);
    text-decoration: none;
    font-size: 0.9rem;
  }

  .tabs a:hover { color: var(--text); }

  .tabs .count {
    margin-left: 0.4rem;
    padding: 0 0.4rem;
    border-radius: 999px;
    background: #f59e0b;
    color: #1e293b;
    font-size: 0.72rem;
    font-weight: 700;
  }

  .ingest-warning {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: var(--gap-md);
    background: #fffbeb;
    border: 1px solid #fcd34d;
    color: #78350f;
    border-radius: 8px;
    padding: var(--gap-md) var(--gap-lg);
    margin-bottom: var(--gap-section);
    font-size: var(--text-sm);
  }

  .ingest-warning a { color: inherit; font-weight: 600; }

  @media (prefers-color-scheme: dark) {
    .ingest-warning { background: #2d2410; border-color: #78591a; color: #fde68a; }
  }

  .tabs a.active {
    color: var(--text);
    background: var(--card-bg);
    border: 1px solid var(--border);
    font-weight: 600;
  }

  .controls {
    display: flex;
    gap: 0.75rem;
    align-items: center;
  }

  .commit-badge {
    font-family: monospace;
    font-size: 11px;
    font-weight: 500;
    color: #3C3489;
    background: #EEEDFE;
    border-radius: 4px;
    padding: 2px 7px;
    vertical-align: middle;
    position: relative;
    top: -2px;
    text-decoration: none;
  }

  @media (prefers-color-scheme: dark) {
    .commit-badge {
      color: #CECBF6;
      background: #26215C;
    }
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

  /* The panels inside keep their own bottom margin, so the grid adds only the column gap. */
  .two-col {
    display: grid;
    grid-template-columns: 1fr 1fr;
    column-gap: var(--gap-section);
  }

  @media (max-width: 768px) {
    .two-col { grid-template-columns: 1fr; }
  }

</style>
