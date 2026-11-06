<script lang="ts">
  import { tick } from "svelte";
  import { getSpfAnalysis, fetchIpInfo, type SpfAnalysis, type IpInfo, type DomainAuth } from "../lib/api";
  import { getSpfTree, resetSpfTrees, clearSpfCache, checkIp, isAligned, SPF_LOOKUP_LIMIT, type SpfTree, type SpfCheck } from "../lib/spf";
  import { checkDmarc, checkDkim, checkSpf, type RecordCheck } from "../lib/dns-checks";
  import { analyzeSpf, checkKey, REASONS, REASON_LABEL, type Reason } from "../lib/spf-analysis";

  // domain: the policy domain from the URL (#/analyzer/<domain>); empty shows the domain list.
  let { days, domain, domainAuth, maskDomain }: { days: string; domain: string; domainAuth: DomainAuth[]; maskDomain: (name: string) => string } = $props();

  // The From domains whose SPF record is fetched, by non-aligned volume.
  const MAX_TREES = 20;
  const SOURCE_ROWS = 50;
  const MAX_DKIM_SELECTORS = 10;
  // DKIM signatures listed per source row; more are counted as "+N more".
  const DKIM_PER_SOURCE = 3;

  let analysis = $state<SpfAnalysis | null>(null);
  let trees: Map<string, SpfTree> = $state(new Map());
  let checks: Map<string, SpfCheck> = $state(new Map());
  let recordChecks: RecordCheck[] = $state([]);
  let resolving: boolean = $state(false);
  let error: string = $state("");
  let ipInfo: Record<string, IpInfo> = $state({});
  let showAllSources: boolean = $state(false);
  let token = 0;

  async function load() {
    const t = ++token;
    error = "";
    analysis = null;
    trees = new Map();
    checks = new Map();
    recordChecks = [];
    reasonFilter = null;
    if (!domain) return;
    try {
      const a = await getSpfAnalysis(days, domain);
      if (t !== token) return;
      analysis = a;
      resolveTrees(a, t);
      const ips = [...new Set(a.rows.slice(0, SOURCE_ROWS).map((r) => r.source_ip))];
      if (ips.length) fetchIpInfo(ips).then((info) => { if (t === token) ipInfo = info; });
    } catch (e) {
      if (t === token) error = e instanceof Error ? e.message : "Failed to load data";
    }
  }

  async function resolveTrees(a: SpfAnalysis, t: number) {
    const volume = new Map<string, number>([[domain.toLowerCase(), Infinity]]);
    for (const r of a.rows) {
      const d = r.header_from.toLowerCase();
      if (d) volume.set(d, (volume.get(d) ?? 0) + r.total - r.spf_aligned);
    }
    const domains = [...volume.entries()].sort((x, y) => y[1] - x[1]).slice(0, MAX_TREES).map(([d]) => d);
    resolving = true;
    try {
      const results = await Promise.all(domains.map((d) => getSpfTree(d).catch(() => null)));
      if (t !== token) return;
      const resolved = new Map(domains.flatMap((d, i) => (results[i] ? [[d, results[i]] as [string, SpfTree]] : [])));
      trees = resolved;

      // DKIM selectors that the reports show signing for this domain, largest first.
      const selectors = [
        ...new Map(
          a.dkim
            .filter((k) => k.selector && isAligned(k.domain, domain, false))
            .map((k) => [`${k.selector}._domainkey.${k.domain}`, k] as const)
        ).values(),
      ].slice(0, MAX_DKIM_SELECTORS);
      const [dmarc, ...dkim] = await Promise.all([
        checkDmarc(domain.toLowerCase()),
        ...selectors.map((k) => checkDkim(k.domain, k.selector)),
      ]);
      if (t !== token) return;
      recordChecks = [dmarc, ...[...resolved.values()].map(checkSpf), ...dkim];
      // Local range matching only; the reports already give the SPF result. This only shows
      // whether your record includes an "IP not in your SPF record" source today.
      const result = new Map<string, SpfCheck>();
      for (const r of a.rows) {
        const tree = resolved.get(r.header_from.toLowerCase());
        const key = checkKey(r.header_from, r.source_ip);
        if (!r.has_auth || !tree || result.has(key)) continue;
        result.set(key, await checkIp(tree, r.source_ip));
        if (t !== token) return;
      }
      checks = result;
    } finally {
      if (t === token) resolving = false;
    }
  }

  function refreshDns() {
    clearSpfCache();
    resetSpfTrees();
    if (analysis) resolveTrees(analysis, token);
  }

  $effect(() => {
    void days;
    void domain;
    load();
  });

  let report = $derived(analysis ? analyzeSpf(analysis, checks) : null);
  // The DKIM signatures of each source (From domain + IP): aligned ones first (they are
  // the ones DMARC counts), then by message count.
  let dkimBySource = $derived.by(() => {
    const map = new Map<string, SpfAnalysis["dkimBySource"]>();
    for (const k of analysis?.dkimBySource ?? []) {
      const key = checkKey(k.header_from, k.source_ip);
      map.set(key, [...(map.get(key) ?? []), k]);
    }
    const aligned = (k: SpfAnalysis["dkimBySource"][number]) => Number(!!k.domain && isAligned(k.domain, k.header_from, false));
    for (const list of map.values()) list.sort((a, b) => aligned(b) - aligned(a) || b.messages - a.messages);
    return map;
  });
  let totals = $derived(analysis?.totals);

  function pct(part: number, total: number): string {
    if (!total) return "N/A";
    return ((part / total) * 100).toFixed(1) + "%";
  }

  function fmt(n: number): string {
    return n.toLocaleString();
  }

  // One short line per issue card: what the issue means and what to do.
  function advice(r: Reason): string {
    // Diagnoses are largest first: name the biggest Return-Path domain of this issue only.
    const top = report?.diagnoses.find((d) => d.reason === r && d.spfDomain)?.spfDomain;
    switch (r) {
      case "aligned":
        return `SPF passes for ${top ? top : "a domain"} that aligns with the From domain. Nothing to do.`;
      case "return-path":
        return `SPF passes for the sender's own domain${top ? ` (${top})` : ""}. DKIM aligns, so DMARC passes. To align SPF too, use a Return-Path under your domain.`;
      case "ip":
        return "The Return-Path is your domain, but your SPF record does not include the IP. Add the services that you use.";
      case "both":
        return "This usually occurs with forwarded mail. SPF does not pass after forwarding, so DMARC must use DKIM.";
      case "unauthorized":
        return "DKIM does not align either, so DMARC fails. This usually occurs with spoofing. Your DMARC policy controls this mail.";
      case "no-data":
        return "These reports have no SPF details: the dashboard keeps them only for reports received after the upgrade. New reports fill this in.";
      default:
        return "The report does not give enough SPF details to find the cause.";
    }
  }

  // The SPF aligned card first, then the issues with mail, largest first.
  let issues = $derived(
    report
      ? REASONS.filter((r) => report!.byReason[r] > 0).sort(
          (a, b) => Number(b === "aligned") - Number(a === "aligned") || report!.byReason[b] - report!.byReason[a]
        )
      : []
  );

  // Each card's icon follows DMARC, like the DNS record checks: ✓ passes by SPF, ! SPF does
  // not align but DKIM carries DMARC, ✗ DMARC fails for some of the mail, ? no SPF details.
  type Severity = { status: "ok" | "warning" | "error" | "none"; text: string };

  function severity(r: Reason): Severity {
    if (r === "aligned") return { status: "ok", text: "DMARC passes by SPF." };
    if (r === "no-data" || r === "unknown") return { status: "none", text: "Not enough SPF details to judge." };
    // SPF does not align here, so mail without aligned DKIM fails DMARC.
    const failing = report!.diagnoses
      .filter((d) => d.reason === r)
      .reduce((sum, d) => sum + Math.min(d.messages, d.row.total - d.row.dkim_aligned), 0);
    return failing > 0
      ? { status: "error", text: `DMARC fails for ${fmt(failing)} message${failing === 1 ? "" : "s"}: DKIM does not align either.` }
      : { status: "warning", text: "SPF does not align, but DKIM does, so DMARC passes." };
  }

  const SEVERITY_ICON = { ok: "✓", warning: "!", error: "✗", none: "?" };

  type Step = { label: string; value: string; detail: string; status: "ok" | "bad" | "partial" | "info"; cause?: boolean };

  // The evaluation of the largest source of the selected card (else the largest issue, else
  // the aligned mail), step by step, so the failing step is visible. Mail without SPF
  // details has no steps.
  let example = $derived.by(() => {
    if (!report) return null;
    const hasSteps = (r: Reason) => r !== "no-data" && r !== "unknown";
    const reason =
      reasonFilter ?? issues.find((r) => r !== "aligned" && hasSteps(r)) ?? (issues.includes("aligned") ? "aligned" : undefined);
    if (!reason || !hasSteps(reason)) return null;
    const d = report.diagnoses.find((x) => x.reason === reason && x.spfDomain);
    if (!d) return null;
    const from = maskDomain(d.row.header_from);
    const rp = maskDomain(d.spfDomain);
    const spfPass = d.spfResult === "pass";
    const spfCounts = reason === "aligned";
    const dkim = d.row.dkim_aligned;
    const total = d.row.total;
    const dkimStatus = dkim === total ? "ok" : dkim === 0 ? "bad" : "partial";
    const dmarc: Step = spfCounts
      ? { label: "DMARC", value: dkimStatus === "ok" ? "Pass (by SPF and DKIM)" : "Pass (by SPF)", detail: "SPF aligned", status: "ok" }
      : {
          label: "DMARC",
          value: dkimStatus === "ok" ? "Pass (by DKIM)" : dkimStatus === "bad" ? "Fail" : "Pass for some",
          detail: dkimStatus === "ok" ? "Only DKIM aligned" : "SPF and DKIM do not align",
          status: dkimStatus,
        };
    const steps: Step[] = [
      { label: "Return-Path", value: rp, detail: "SPF checks this domain", status: "info" },
      {
        label: "SPF",
        value: `${d.spfResult} for ${rp}`,
        detail: spfPass ? "The IP is in this domain's SPF record" : "The IP is not in this domain's SPF record",
        status: spfPass ? "ok" : "bad",
        cause: reason === "ip" || reason === "both",
      },
      {
        label: "SPF alignment",
        value: d.spfAligned ? `${rp} = ${from}` : `${rp} ≠ ${from}`,
        detail: spfCounts ? "Related domains: SPF counts" : !d.spfAligned ? "Different domains: SPF does not count" : "Same domain, but SPF failed",
        status: spfCounts ? "ok" : "bad",
        cause: reason === "return-path" || reason === "unauthorized" || reason === "both",
      },
      {
        label: "DKIM alignment",
        value: dkimStatus === "ok" ? `Aligned with ${from}` : dkimStatus === "bad" ? "Not aligned" : `${fmt(dkim)} of ${fmt(total)} aligned`,
        detail: spfCounts
          ? dkimStatus === "ok" ? "DKIM aligns too" : "SPF is enough for DMARC"
          : dkimStatus === "ok" ? "DKIM can carry DMARC" : "DKIM cannot carry DMARC",
        status: spfCounts && dkimStatus !== "ok" ? "info" : dkimStatus,
        cause: reason === "unauthorized",
      },
      dmarc,
    ];
    return { reason, d, steps };
  });

  // Segment widths: each share, but at least MIN_SEGMENT of the bar, so small issues stay
  // visible and sit near their cards. The larger segments give up the room in proportion.
  // The cards show the exact numbers.
  const MIN_SEGMENT = 0.15;

  let segWidths = $derived.by(() => {
    if (!report || issues.length === 0) return [];
    const counts = issues.map((r) => report!.byReason[r]);
    const total = counts.reduce((a, b) => a + b, 0);
    const min = Math.min(MIN_SEGMENT, 1 / issues.length);
    const fixed = new Set<number>();
    for (;;) {
      const freeShare = 1 - fixed.size * min;
      const freeTotal = counts.reduce((sum, c, i) => (fixed.has(i) ? sum : sum + c), 0);
      const widths = counts.map((c, i) => (fixed.has(i) ? min : (c / (freeTotal || total)) * freeShare));
      const tooSmall = widths.findIndex((w, i) => !fixed.has(i) && w < min);
      if (tooSmall === -1) return widths;
      fixed.add(tooSmall);
    }
  });

  // The bar above the cards: one segment per card, with a line from each segment to its
  // card. Positions are measured, because segment widths follow the message counts and
  // card widths do not.
  let mapEl = $state<HTMLDivElement>();
  let segEls: HTMLElement[] = $state([]);
  let cardEls: HTMLElement[] = $state([]);
  let links = $state<{ r: Reason; x1: number; x2: number }[]>([]);
  // Below this width the cards wrap into rows and the lines are not drawn.
  const LINK_MIN_WIDTH = 700;
  let wide = $state(true);

  function measure() {
    if (!mapEl) return;
    const box = mapEl.getBoundingClientRect();
    wide = box.width >= LINK_MIN_WIDTH;
    links = issues.flatMap((r, i) => {
      const seg = segEls[i]?.getBoundingClientRect();
      const card = cardEls[i]?.getBoundingClientRect();
      if (!seg || !card) return [];
      // Start where the segment is closest to the card's centre and land where the card is
      // closest to that point: a segment above its card gets a straight vertical line.
      const clamp = (x: number, lo: number, hi: number) => Math.min(Math.max(x, lo), Math.max(lo, hi));
      const x1 = clamp(card.left + card.width / 2, seg.left + 2, seg.right - 2);
      const x2 = clamp(x1, card.left + 14, card.right - 14);
      return [{ r, x1: x1 - box.left, x2: x2 - box.left }];
    });
  }

  // Down, across, down, with rounded corners (radius 4); straight down when aligned.
  function linkPath(x1: number, x2: number): string {
    if (Math.abs(x1 - x2) < 1) return `M${x1} 0 V28`;
    const dir = x2 > x1 ? 1 : -1;
    const r = Math.min(4, Math.abs(x2 - x1) / 2);
    return `M${x1} 0 V${12 - r} Q${x1} 12 ${x1 + dir * r} 12 H${x2 - dir * r} Q${x2} 12 ${x2} ${12 + r} V28`;
  }

  $effect(() => {
    void issues;
    if (!mapEl) return;
    const observer = new ResizeObserver(() => measure());
    observer.observe(mapEl);
    tick().then(measure);
    return () => observer.disconnect();
  });

  // Clicking an issue card shows only its source IPs.
  let reasonFilter = $state<Reason | null>(null);

  function toggleFilter(r: Reason) {
    reasonFilter = reasonFilter === r ? null : r;
    showAllSources = false;
  }

  function reasonClass(r: Reason): string {
    return `swatch swatch-${r}`;
  }

  let filteredSources = $derived(report ? report.diagnoses.filter((d) => !reasonFilter || d.reason === reasonFilter) : []);
  let visibleSources = $derived(filteredSources.slice(0, showAllSources ? SOURCE_ROWS : 15));
</script>

<div class="spf-page">
  {#if error}
    <div class="error-box" role="alert">{error}</div>
  {/if}

  {#if !domain}
  <section class="panel">
    <h3>Analyzer</h3>
    <p class="note">Select a domain to see its SPF alignment and to check its DMARC, SPF and DKIM records.</p>
    {#if domainAuth.length === 0}
      <p class="empty">No reports for this period</p>
    {:else}
      <table class="data">
        <thead>
          <tr>
            <th scope="col">Domain</th>
            <th scope="col" class="num">Messages</th>
            <th scope="col" class="num">SPF aligned</th>
            <th scope="col" class="num">DKIM aligned</th>
          </tr>
        </thead>
        <tbody>
          {#each domainAuth as d}
            <tr>
              <td><a class="link" href="#/analyzer/{encodeURIComponent(d.domain)}">{maskDomain(d.domain)}</a></td>
              <td class="num">{fmt(d.total)}</td>
              <td class="num">{pct(d.spf_pass, d.total)}</td>
              <td class="num">{pct(d.dkim_pass, d.total)}</td>
            </tr>
          {/each}
        </tbody>
      </table>
    {/if}
  </section>
  {:else}

  <section class="panel">
    <h3>SPF alignment for {maskDomain(domain)}</h3>
    <p class="note">
      DMARC uses SPF only when SPF passes for the From domain or a related domain. This page shows the SPF result of each source and, when SPF does not align, why.
    </p>
    {#if !analysis || !report || !totals}
      <p class="empty">Loading…</p>
    {:else if totals.total === 0}
      <p class="empty">No reports for this period</p>
    {:else}
      {#if issues.length > 0}
        <p class="note">{fmt(totals.total)} messages. DKIM aligns for {pct(totals.dkim_aligned, totals.total)} of them. Click a card to show only its source IPs and its DMARC check. Click it again to show all.</p>
        <div class="issue-map" class:filtering={reasonFilter !== null} bind:this={mapEl}>
          <div class="issue-bar">
            {#each issues as r, i}
              <button
                class="seg seg-{r}"
                class:selected={reasonFilter === r}
                style="flex-grow:{segWidths[i]}"
                title="{REASON_LABEL[r]}: {fmt(report.byReason[r])} ({pct(report.byReason[r], totals.total)})"
                aria-label="{REASON_LABEL[r]}: {fmt(report.byReason[r])} messages"
                bind:this={segEls[i]}
                onclick={() => toggleFilter(r)}
              ></button>
            {/each}
          </div>
          {#if wide}
            <svg class="links" aria-hidden="true">
              {#each links as l}
                <path d={linkPath(l.x1, l.x2)} class="link" class:selected={reasonFilter === l.r} style="stroke: var(--reason-{l.r})" />
              {/each}
            </svg>
          {/if}
        <div class="issues" style={wide ? `grid-template-columns: repeat(${issues.length}, minmax(0, 1fr))` : undefined}>
          {#each issues as r, i}
            {@const sev = severity(r)}
            <button class="issue issue-{r}" class:selected={reasonFilter === r} aria-pressed={reasonFilter === r} bind:this={cardEls[i]} onclick={() => toggleFilter(r)}>
              <span class="issue-count"><span class="check-icon check-{sev.status}" title={sev.text} aria-label={sev.text}>{SEVERITY_ICON[sev.status]}</span>{fmt(report.byReason[r])}<span class="issue-share">· {pct(report.byReason[r], totals.total)}</span></span>
              <span class="issue-label">{REASON_LABEL[r]}</span>
              <span class="issue-advice">{advice(r)}</span>
            </button>
          {/each}
        </div>
        </div>
        {#if example}
          {@const d = example.d}
          <div class="steps-box">
            <p class="steps-title">
              How DMARC checks mail from <span class="mono">{d.row.source_ip}</span>
              <span class="muted">— the largest source of “{REASON_LABEL[example.reason]}”</span>
            </p>
            <ol class="steps">
              {#each example.steps as step, i}
                <li class="step step-{step.status}" class:cause={step.cause} style="--issue-color: var(--reason-{example.reason})">
                  <span class="step-label">{i + 1}. {step.label}</span>
                  <span class="step-value">{step.value}</span>
                  <span class="step-detail">{step.status === "ok" ? "✓" : step.status === "bad" ? "✗" : ""} {step.detail}</span>
                </li>
              {/each}
            </ol>
          </div>
        {/if}
        {#if analysis.truncated}
          <p class="note">The page shows only the {fmt(analysis.rows.length)} largest groups of source IPs.</p>
        {/if}
      {/if}
    {/if}
  </section>

  {#if report && report.diagnoses.length > 0}
    <section class="panel">
      <div class="panel-head">
        <h3>Source IPs</h3>
        {#if reasonFilter}
          <button class="btn-small" onclick={() => (reasonFilter = null)}>Show all</button>
        {/if}
      </div>
      {#if reasonFilter}
        <p class="note">Only: {REASON_LABEL[reasonFilter]}. Click the card again or "Show all" to see all source IPs.</p>
      {/if}
      <div class="table-scroll">
        <table class="data">
          <thead>
            <tr>
              <th scope="col">Source IP</th>
              <th scope="col">From domain</th>
              <th scope="col">Return-Path domain</th>
              <th scope="col">Result</th>
              <th scope="col" class="num">Messages</th>
              <th scope="col">DKIM</th>
            </tr>
          </thead>
          <tbody>
            {#each visibleSources as d}
              <tr>
                <td>
                  <span class="mono">{d.row.source_ip}</span>
                  {#if ipInfo[d.row.source_ip]?.org}
                    <span class="sub">{ipInfo[d.row.source_ip].org}{ipInfo[d.row.source_ip].countryCode ? ` · ${ipInfo[d.row.source_ip].countryCode}` : ""}</span>
                  {/if}
                </td>
                <td class="mono">{maskDomain(d.row.header_from)}</td>
                <td>
                  {#if d.spfDomain}
                    <span class="mono">{maskDomain(d.spfDomain)}</span>
                    <!-- The badge names what failed: the domain (mismatch) or the SPF result. -->
                    {#if !d.spfAligned}
                      <span class="badge badge-gray badge-problem" title="SPF {d.spfResult} for {maskDomain(d.spfDomain)}, but it is not related to {maskDomain(d.row.header_from)}">different domain</span>
                    {:else if d.reason !== "aligned"}
                      <span class="badge badge-gray badge-problem" title="SPF result for this domain">SPF {d.spfResult}</span>
                    {/if}
                  {:else}
                    <span class="muted small">Not in the report</span>
                  {/if}
                </td>
                <td>
                  <span class={reasonClass(d.reason)} aria-hidden="true"></span>{REASON_LABEL[d.reason]}
                  {#if d.current?.result === "pass"}
                    <span class="sub" title={d.current.via.join(" → ")}>Your SPF record includes this IP now. New reports show if this fixes it.</span>
                  {/if}
                </td>
                <td class="num">{fmt(d.messages)}</td>
                <td>
                  <!-- Like the Return-Path: a badge only for what fails (another domain, or a failed result). -->
                  {#each (dkimBySource.get(checkKey(d.row.header_from, d.row.source_ip)) ?? []).slice(0, DKIM_PER_SOURCE) as k}
                    <span class="dkim-line">
                      {#if !k.domain}
                        <span class="muted">No signing domain</span>
                      {:else}
                        <span class="mono">{maskDomain(k.domain)}</span>
                        <span class="muted">· {k.selector || "—"}</span>
                      {/if}
                      {#if !k.domain}
                        <!-- Nothing to compare: the report gives no d= domain. -->
                      {:else if !isAligned(k.domain, d.row.header_from, false)}
                        <span class="badge badge-gray badge-problem" title="d={k.domain || "(none)"} is not related to {maskDomain(d.row.header_from)}">different domain</span>
                      {:else if k.result !== "pass"}
                        <span class="badge badge-gray badge-problem">DKIM {k.result || "none"}</span>
                      {/if}
                    </span>
                  {/each}
                  {#if (dkimBySource.get(checkKey(d.row.header_from, d.row.source_ip))?.length ?? 0) > DKIM_PER_SOURCE}
                    <span class="sub">+{(dkimBySource.get(checkKey(d.row.header_from, d.row.source_ip))?.length ?? 0) - DKIM_PER_SOURCE} more</span>
                  {/if}
                  <span class="sub">{pct(d.row.dkim_aligned, d.row.total)} aligned</span>
                </td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
      {#if filteredSources.length > 15}
        <button class="btn-small more" onclick={() => (showAllSources = !showAllSources)}>
          {showAllSources ? "Show 15 source IPs" : `Show ${Math.min(SOURCE_ROWS, filteredSources.length)} source IPs`}
        </button>
      {/if}
    </section>
  {/if}


  {#if analysis}
    <section class="panel">
      <div class="panel-head">
        <h3>DNS record checks</h3>
        <button class="btn-small" onclick={refreshDns} disabled={resolving}>{resolving ? "Checking DNS…" : "Check DNS again"}</button>
      </div>
      <p class="note">The format of your DMARC record, your SPF records (including the limit of {SPF_LOOKUP_LIMIT} DNS lookups) and the DKIM keys of the selectors in your reports. Your browser gets the records from Cloudflare DNS over HTTPS and sends only domain names. The receivers possibly saw older records.</p>
      {#if recordChecks.length === 0}
        <p class="empty">{resolving ? "Checking DNS…" : "No records to check"}</p>
      {:else}
        {#each recordChecks as c}
          <div class="record">
            <div class="record-head">
              <span class="check-icon check-{c.status}" aria-label={c.status === "ok" ? "No problems" : c.status === "warning" ? "Warnings" : "Errors"}>{c.status === "ok" ? "✓" : c.status === "warning" ? "!" : "✗"}</span>
              <span class="badge badge-gray">{c.kind}</span>
              <span class="mono strong">{maskDomain(c.name)}</span>
            </div>
            {#if c.record}
              <code class="record-text">{c.record}</code>
            {/if}
            {#each c.findings as f}
              <p class="finding finding-{f.level}">{f.text}</p>
            {/each}
          </div>
        {/each}
      {/if}
    </section>
  {/if}


  {/if}
</div>

<style>
  .spf-page {
    --reason-return-path: #2a78d6;
    --reason-ip: #eb6834;
    --reason-aligned: #16a34a;
    --reason-both: #6250d6;
    --reason-unauthorized: #eda100;
    --reason-unknown: #a3a3a3;
    --reason-no-data: #a3a3a3;
  }
  @media (prefers-color-scheme: dark) {
    .spf-page {
      --reason-return-path: #3987e5;
      --reason-ip: #d95926;
      --reason-aligned: #22a35a;
      --reason-both: #9085e9;
      --reason-unauthorized: #c98500;
      --reason-unknown: #6b6b6b;
      --reason-no-data: #6b6b6b;
    }
  }

  .issue-map { margin-top: var(--gap-sm); }
  .issue-bar { display: flex; gap: 2px; height: 12px; }
  .seg {
    all: unset;
    flex-basis: 0;
    min-width: 6px;
    height: 100%;
    cursor: pointer;
    transition: opacity 0.15s;
  }
  .seg:first-child { border-radius: 4px 0 0 4px; }
  .seg:last-child { border-radius: 0 4px 4px 0; }
  .seg:only-child { border-radius: 4px; }
  .seg:focus-visible { outline: 2px solid #3b82f6; outline-offset: 2px; }
  .links { display: block; width: 100%; height: 28px; overflow: visible; }
  .link { fill: none; stroke-width: 1.5; opacity: 0.7; transition: opacity 0.15s; }
  .issue-map:not(:has(.links)) .issues { margin-top: var(--gap-md); }
  .issues {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    gap: var(--gap-md);
    margin-bottom: var(--gap-md);
  }
  .issue-map.filtering .seg:not(.selected) { opacity: 0.3; }
  .issue-map.filtering .link:not(.selected) { opacity: 0.15; }
  .issue {
    all: unset;
    box-sizing: border-box;
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
    padding: 0.75rem 0.9rem;
    border: 1px solid var(--border);
    border-left: 4px solid var(--issue-color);
    border-radius: 6px;
    background: var(--row-alt);
    cursor: pointer;
  }
  .issue:hover { border-color: var(--issue-color); }
  .issue { transition: opacity 0.15s; }
  .issue-map.filtering .issue:not(.selected) { opacity: 0.4; }
  .issue-map.filtering .issue:not(.selected):hover { opacity: 0.75; }
  .issue.selected { border-color: var(--issue-color); box-shadow: 0 0 0 1px var(--issue-color); }
  .issue:focus-visible { outline: 2px solid #3b82f6; outline-offset: 2px; }
  .issue-return-path { --issue-color: var(--reason-return-path); }
  .issue-ip { --issue-color: var(--reason-ip); }
  .seg-aligned { background: var(--reason-aligned); }
  .seg-return-path { background: var(--reason-return-path); }
  .seg-ip { background: var(--reason-ip); }
  .seg-both { background: var(--reason-both); }
  .seg-unauthorized { background: var(--reason-unauthorized); }
  .seg-unknown { background: var(--reason-unknown); }
  .seg-no-data { background: var(--reason-no-data); }
  .issue-aligned { --issue-color: var(--reason-aligned); }
  .issue-both { --issue-color: var(--reason-both); }
  .issue-unauthorized { --issue-color: var(--reason-unauthorized); }
  .issue-unknown { --issue-color: var(--reason-unknown); }
  .issue-no-data { --issue-color: var(--reason-no-data); }
  .steps-box { margin: var(--gap-xs) 0 var(--gap-md); }
  .steps-title { font-size: var(--text-sm); font-weight: 600; margin: 0 0 var(--gap-sm); }
  .steps-title .muted { font-weight: 400; }
  .steps {
    list-style: none;
    margin: 0;
    padding: 0;
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
    gap: var(--gap-sm);
  }
  .step {
    display: flex;
    flex-direction: column;
    gap: 0.2rem;
    padding: 0.55rem 0.7rem;
    border: 1px solid var(--border);
    border-radius: 6px;
    font-size: var(--text-xs);
    position: relative;
  }
  .step:not(:last-child)::after {
    content: "→";
    position: absolute;
    right: -0.45rem;
    top: 50%;
    transform: translate(50%, -50%);
    color: var(--muted);
    font-size: 0.8rem;
  }
  .step.cause { border: 2px solid var(--issue-color); }
  .step-label { font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.03em; color: var(--muted); }
  .step-value { font-family: var(--mono); font-size: var(--text-xs); word-break: break-all; }
  .step-detail { color: var(--muted); }
  .step-ok .step-detail { color: #16a34a; }
  .step-bad .step-detail { color: #dc2626; }
  .step-partial .step-detail { color: #ca8a04; }
  .issue-count { font-size: 1.5rem; font-weight: 600; font-variant-numeric: tabular-nums; }
  .issue-share { font-size: var(--text-sm); font-weight: 400; color: var(--muted); margin-left: 0.4rem; }
  .issue-label { font-weight: 600; font-size: var(--text-sm); }
  .issue-advice { font-size: var(--text-xs); color: var(--muted); line-height: 1.35; }
  .issue-note { font-size: 0.72rem; color: var(--muted); font-style: italic; }
  .swatch {
    display: inline-block;
    width: 10px;
    height: 10px;
    border-radius: 2px;
    margin-right: 0.4rem;
    vertical-align: baseline;
  }
  .swatch-return-path { background: var(--reason-return-path); }
  .swatch-ip { background: var(--reason-ip); }
  .swatch-aligned { background: var(--reason-aligned); }
  .swatch-both { background: var(--reason-both); }
  .swatch-unauthorized { background: var(--reason-unauthorized); }
  .swatch-unknown { background: var(--reason-unknown); }
  .swatch-no-data { background: var(--reason-no-data); }
  .link { color: #3b82f6; text-underline-offset: 2px; }

  .strong { font-weight: 600; }
  .small { font-size: var(--text-xs); }
  .sub { word-break: break-all; }

  .record { padding: var(--gap-md) 0; border-top: 1px solid var(--border); }
  .record:first-of-type { border-top: none; }
  .record-head { display: flex; align-items: center; gap: var(--gap-sm); margin-bottom: var(--gap-xs); }
  .record-text {
    display: block;
    font-size: var(--text-xs);
    background: var(--row-alt);
    padding: var(--gap-sm) var(--gap-md);
    border-radius: 4px;
    font-family: var(--mono);
    word-break: break-all;
  }
  .finding { margin: var(--gap-xs) 0 0; font-size: var(--text-xs); }
  .finding-error { color: #dc2626; }
  .finding-warning { color: #ca8a04; }
  .finding-info { color: var(--muted); }
  .check-none { background: var(--reason-unknown); }
  .issue-count .check-icon { margin-right: 0.45rem; vertical-align: 0.2em; }

  .more { margin-top: var(--gap-md); }
  .dkim-line { display: block; white-space: nowrap; }
  .dkim-line + .dkim-line { margin-top: 0.15rem; }
  .badge { margin-left: var(--gap-xs); }
</style>
