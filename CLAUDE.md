# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A self-hosted DMARC report analysis kit built on Cloudflare's free/cheap tier. A single Cloudflare Worker receives DMARC aggregate reports via email, stores parsed data in D1 (SQLite), and exposes an API consumed by a Svelte dashboard.

## Architecture

```
Email Sender → Cloudflare Email Routing → Worker email() → D1 (SQLite)
                                          Worker fetch()  → Dashboard (Svelte static assets)
                                          Cloudflare Access (auth)
```

Single worker serves everything: `email()` for ingestion, `fetch()` for API (`/api/*`), and static assets (Svelte dashboard built to `dashboard/dist/`). Cloudflare Access protects the dashboard host, which the worker serves through a route (not a custom domain, so the zone's Universal SSL certificate covers it) — no separate hosting needed. Deployment uses the `cf` CLI (OAuth login, no API token); wrangler is only its bundler.

## Commands

```bash
# pnpm workspace: root = worker, dashboard/ = Svelte app
pnpm install                  # install worker + dashboard dependencies
pnpm add -w <pkg>             # add a worker dependency (root is a workspace package, so -w is required)
pnpm update -r                # update worker + dashboard (plain `pnpm update` only updates the root; also `pnpm run update:all`)
pnpm run dev                  # local dev (cf dev)
bash deploy.sh [--profile <name>]  # deploy profiles/<name>.json (default: default)
pnpm run migrate:local        # run D1 migrations locally
npx tsc --noEmit              # type-check worker
pnpm run scan:secrets         # betterleaks over the git history (pre-commit hook scans staged changes)

# Dashboard
pnpm --filter dashboard run dev     # Vite dev server
pnpm --filter dashboard run build   # build to dashboard/dist/ (served by worker)
pnpm --filter dashboard run check   # svelte-check + tsc
```

## Key Files

- `src/index.ts` — worker entry point (email + fetch handlers)
- `src/email-handler.ts` — email parsing: postal-mime → gzip (DecompressionStream) / zip (unzipit) → fast-xml-parser → D1
- `src/db.ts` — D1 insert (with batch chunking) and all query functions
- `src/api.ts` — HTTP routing for `/api/*`, JSON responses (no CORS — same origin)
- `src/geo.ts` — IP country/network lookup from the DB-IP Lite databases (downloaded by deploy.sh into the static assets, read via the ASSETS binding)
- `src/types.ts` — Env, DmarcRecordRow, DMARC enums
- `migrations/0001_init.sql` — D1 schema (reports + record_rows tables)
- `migrations/0002_record_rows_unique.sql` — unique index on record_rows(report_id, source_ip, header_from)
- `deploy.sh` — deploy and manage via `cf`. Deploy: login, Access, D1, migrations, dashboard build (+ DB-IP download), worker deploy, email routing, DNS. Actions: `--setup` (the only way to write a profile), `--list`, `--verify`, `--cleanup`, `--migrate-from`, `--login`, `--import-env`
- `profiles/<name>.json` — per-deployment settings, written only by `deploy.sh --setup` (and checksummed: deploy refuses hand-edited profiles); gitignored except `example.json`; selected as `--mode <name>`
- `cloudflare.config.ts` — Worker config; reads the profile, D1 id comes from `DMARC_D1_ID` (set by deploy.sh)
- `wrangler.config.ts` — build settings (assets directory)
- `dashboard/` — Svelte 5 + Vite + Chart.js SPA
- `CHANGELOG.md` — Keep a Changelog format; add every user-facing change under `[Unreleased]`

## D1 Schema

Two tables: `reports` (metadata, unique by report_id) and `record_rows` (per-IP results with denormalized date_range_begin). `0001_init.sql` defines the tables and indexes; `0002_record_rows_unique.sql` adds a unique index on `(report_id, source_ip, header_from)` to prevent duplicate rows.

## Multi-Domain Support

All API endpoints accept `?domain=` filter. Each DMARC report stores its domain. `/api/domains` returns the distinct list.

## Reference

`../dmarc-email-worker` is Cloudflare's official DMARC worker (R2 + Analytics Engine). The XML parsing pipeline and type definitions were adapted from it for D1 storage.

## Release Notes

GitHub release notes are written in Simplified Technical English (ASD-STE100):
- Short sentences: at most 20 words for instructions, 25 for descriptions. One instruction per sentence.
- Active voice, simple present tense, imperative for instructions ("Run …", not "You should run …").
- Plain, approved words; no idioms, contractions, or phrasal verbs ("remove", not "get rid of").
- Use the same word for the same thing everywhere.

Group the notes as: **Upgrading from x.y** (only changes that need action from existing users), **New**, **Changes**, **Fixes**. Mark something as breaking only when an existing setup stops working or needs action. Base the notes on `CHANGELOG.md`, which collects every user-facing change under `[Unreleased]` as work happens. A fix to something that was never released (a bug in an unreleased feature) is not a fix: fold it into that feature's entry instead of listing it under Fixed.

## Code Audit Guidelines

When auditing this codebase, check the following:

### Cloudflare Worker (TypeScript)
- Every exported function in `src/` must be reachable from either the `email()` or `fetch()` entry points in `index.ts` — flag anything that isn't
- `email()` handler: verify MIME parsing handles missing/malformed attachments gracefully without crashing the worker
- `fetch()` handler: every route defined in `api.ts` must be exercised by the dashboard — flag unused routes
  - Exception: `/api/health` is an infrastructure-only endpoint (monitoring, deploy verification) — not expected to be called by the dashboard
- D1 queries in `db.ts`: every query function must be called from `api.ts` or `email-handler.ts` — flag unused ones
- No `console.log` left in production paths — use structured logging or remove entirely
- All D1 queries must use parameterized statements — no string interpolation in SQL
- Worker must never expose raw D1 errors to the client — wrap in generic error responses
- Check `cloudflare.config.ts` for any unused bindings or environment variables

### Svelte 5 Frontend
- Use runes exclusively (`$state`, `$derived`, `$props`) — flag any legacy reactive syntax (`$:`, `export let`)
- Every component in `dashboard/src/components/` must be imported and used in `App.svelte` or another active component — flag unused components
- Every function in `dashboard/src/lib/api.ts` must be called from a component — flag unused exports
- No hardcoded API URLs — all endpoints must reference a single base URL constant
- Chart.js instances must be destroyed on component unmount to prevent memory leaks

### General
- No commented-out code blocks
- No TODO/FIXME comments left in production code
- Profile values must never appear in client-side bundle — verify Vite's `VITE_` prefix convention is respected
- `deploy.sh`: every step must be idempotent — re-running should not create duplicate DNS records, D1 databases, or Access policies; DNS records it creates carry the `managed-by:dmarc-dashboard-kit` comment
- `deploy.sh` must run on macOS's bash 3.2: no `${var,,}`, `mapfile`, or associative arrays; no apostrophe inside `${x:-…}` within double quotes; no jq programs with quotes/parentheses nested inside `"$(…)"` (assign to a variable first)
- `deploy.sh`: every Cloudflare call goes through the `cf()` wrapper (quiet output, errors shown, read-only calls retried on 5xx); deletes pass `--force` (cf otherwise prompts and silently aborts without a terminal); confirmations use `confirm` (exact Y/N), optional follow-ups use `offer`
