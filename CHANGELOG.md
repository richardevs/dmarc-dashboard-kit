# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- **Sender IP details come from the DB-IP Lite databases** (CC BY 4.0, free for commercial use, attribution shown) looked up locally by the worker, instead of ip-api.com (non-commercial free tier, plain HTTP). No external API call, token, or rate limit; the dashboard's rate-limit countdown is gone.
- **Breaking:** deployment uses the `cf` CLI instead of wrangler + `curl`. `deploy.sh` logs in with `cf auth login` using only the OAuth scopes it needs (`--login`, or automatically when not logged in); API tokens are no longer used. wrangler remains as `cf`'s bundler.
- **Breaking:** configuration moved from `.env` to JSON profiles in `profiles/<name>.json`, selected with `deploy.sh --profile <name>`. Several deployments (e.g. personal and company accounts) can live side by side. An existing `.env` is converted automatically on the first run and, after confirmation, moved to `.env.legacy`; a leftover `wrangler.toml` is reported for you to compare and remove.
- **Breaking:** the dashboard is served on its own hostname, `dmarc-<random>.<zone>` by default (generated once and saved to the profile), through a Worker route on a proxied DNS record so the zone's Universal SSL wildcard covers it and no per-host certificate is published to CT logs. `workers.dev` and preview URLs are disabled.
- **Breaking:** `deploy.sh` takes `[--profile <name>] [action]`: the profile is selected only with `--profile` (default `default`), one action per run. Deploying first shows the plan for the profile and continues only on `Y`. Unknown or misplaced parameters print the help (with a "did you mean" hint) and exit with status 2; every run ends with a pointer to `--help`.
- `wrangler.toml` is replaced by `cloudflare.config.ts` (Worker settings, reads the profile) and `wrangler.config.ts` (build settings). The D1 database id is looked up by name on every deploy instead of being stored.
- Cloudflare Access uses one reusable, account-level policy attached to the app by id. The app-scoped (legacy) policy from earlier versions is converted in place.
- Cloudflare Access is configured before the Worker is deployed, so the dashboard host is never reachable without it.
- D1 migrations are applied with `cf d1 migrations apply` and recorded in `d1_migrations`, so each migration runs once.
- **Breaking:** `--cleanup` works from the profile instead of `--zone-id`: it lists every resource the script created on the account (current and earlier versions, on any zone) and deletes only the ones you tick. Deleting a D1 database requires confirming the reports were migrated or are no longer needed. Confirmations accept only `Y`; `--yes` was removed.
- Upgraded to pnpm 12, wrangler 4.153, `@cloudflare/workers-types` 5, fast-xml-parser 5.11, postal-mime 4, unzipit 2, and TypeScript 6 (TypeScript 7 is not yet supported by svelte-check); dashboard dependencies updated to their latest minor versions.
- The repository is a pnpm workspace (root = worker, `dashboard/`): one lockfile, `pnpm install` installs both, `pnpm update -r` updates both (also available as `pnpm run update:all`).
- Compatibility date moved from 2024-12-30 to 2026-10-01 (navigation requests are served from static assets without invoking the worker; `email()` receives full `To`/`Cc` headers; Node.js compatibility is on by default, with no change to the bundle).
- gzip reports are decompressed with the runtime's `DecompressionStream`; `pako` and the deprecated `@types/pako` were removed (bundle 420 KiB → 348 KiB).

### Added
- `access.sessionDuration` in the profile (picked in `--setup`, default 24 hours) sets the Access application's session duration; `--list` shows it and `--verify` checks it.
- Profiles are changed only through `--setup`: each saved profile carries a `_note` and a `_checksum`, and deploy, cleanup and migrate refuse a profile edited by hand until it is saved with `--setup` again (`--list` and `--verify` only warn).
- Changing `dashboard.host` retires the previous host first: its DNS record (if created by the script) is removed before Access moves, so a leftover route can never serve the dashboard without Access; a record the script did not create keeps Access on the old host until it is removed.
- Report allowlist: when `dmarc.authorizedDomains` is set, the worker keeps only reports whose `policy_published.domain` is the zone, a listed domain, or a subdomain of them, and drops others (the address is public in `rua=`, so anyone can send to it). An empty list keeps reports for any domain, as before.
- Optional receiving subdomain (`dmarc.subdomain`): reports go to `<localPart>@<subdomain>.<zone>` with `_report._dmarc` records under the subdomain, and Email Routing is enabled on the subdomain automatically. The zone root's MX and existing SPF records are left as they are (Cloudflare adds a `cf2024-1._domainkey` DKIM key at the root); deploy refuses when the subdomain already receives mail elsewhere, or when the root receives mail elsewhere but has no SPF record, because Cloudflare would then add a root SPF record authorizing only itself. Email Routing is never enabled on the zone root itself, because that replaces the root's MX records.
- `deploy.sh [--profile <name>] --setup` builds a profile step by step (profile, cf login, account and zone pickers; when the zone root already receives mail it suggests receiving at `rua@dmarc.<zone>`); it runs automatically when the profile does not exist.
- Pre-commit hook that scans staged changes for secrets with betterleaks (enabled by `pnpm install`), and `pnpm run scan:secrets` for the full history.
- `--list` shows a profile's settings, the resources the script manages, and whether the login has every required scope. `--verify` compares the live Cloudflare setup with the profile (including an Access and certificate check of the dashboard) and reports leftovers from older versions.
- `deploy.sh --profile <target> --migrate-from=<source>` copies stored reports between profiles' databases, across accounts, skipping reports already present.
- DNS records created by the script carry the comment `managed-by:dmarc-dashboard-kit`. Records removed from `dmarc.authorizedDomains` are deleted on the next deploy, and cleanup only deletes tagged records (plus untagged ones from earlier versions).

### Fixed
- `pnpm run migrate:local` now migrates the database the local dev server uses (`.wrangler/state`).
- A report attachment delivered as a partial byte view could include bytes outside the attachment.
- Select the DMARC report attachment by media type and filename (RFC 9990).
- Dashboard fetches ignore stale responses and no longer send duplicate IP-info requests.
- `.env` values containing spaces (e.g. `REPORT_AUTHORIZED_DOMAINS=a.com, b.org`) were mis-parsed.
- Email routing rules are listed per zone, so other zones' rules on the same account are never matched.

## [1.0.1] - 2026-06-03

### Fixed
- Detect report compression (gzip/zip) by magic bytes instead of trusting the declared type.
- Hardened `deploy.sh` and worker logging.

## [1.0.0] - 2026-03-25

Initial release: self-hosted DMARC report analyzer on Cloudflare (Email Routing → Worker → D1, Svelte dashboard behind Cloudflare Access).

### Added
- One-command `deploy.sh` for D1, migrations, dashboard build, worker deploy, email routing, `_report._dmarc` records, and Cloudflare Access.
- Cloudflare Access rules for emails, email domains, and IP ranges.
- Sender IP enrichment with country and organization.
- All Senders tab, day drill-down on the time series chart, and a commit hash badge.
- Dashboard accessibility improvements (WCAG 2.1 AA).

### Fixed
- Ingestion failure when optional XML fields are missing.
- Timezone-aware date grouping and report ID precision.
- Idempotent `_report._dmarc` and Access policy updates.

[Unreleased]: https://github.com/richardevs/dmarc-dashboard-kit/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/richardevs/dmarc-dashboard-kit/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/richardevs/dmarc-dashboard-kit/releases/tag/v1.0.0
