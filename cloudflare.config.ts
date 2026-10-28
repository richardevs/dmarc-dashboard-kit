import { existsSync, readFileSync } from "node:fs";
import { bindings, defineConfig, triggers } from "cf/config";

// Local dev (`cf dev`, `pnpm run migrate:local`, both on .wrangler/state) uses this placeholder; a deploy without
// DMARC_D1_ID then fails instead of silently creating a new database.
const LOCAL_D1_ID = "00000000-0000-4000-8000-000000000000";

// Each deployment is described by profiles/<name>.json and selected with `--mode <name>`
// (deploy.sh passes it). Without a profile (local dev) no account or route is set.
function loadProfile(mode: string | undefined) {
	const file = `profiles/${mode ?? "default"}.json`;
	return existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : {};
}

export default defineConfig(({ mode }) => {
	const profile = loadProfile(mode);
	return {
		accountId: profile.accountId || undefined,
		worker: {
			name: "dmarc-dashboard-kit",
			compatibilityDate: "2026-10-01",
			entrypoint: "src/index.ts",
			workersDev: false,
			previewUrls: false,
			// A route (not a custom domain) on a proxied DNS record that deploy.sh creates, so the
			// zone's Universal SSL wildcard serves it. A custom domain would get its own certificate,
			// publishing the hostname in Certificate Transparency logs.
			triggers: profile.dashboard?.host
				? [triggers.fetch({ pattern: `${profile.dashboard.host}/*`, zone: profile.zone })]
				: [],
			// Persisted, queryable logs in the Cloudflare dashboard (3-day retention). Invocation logs are
			// off because fetch() also serves the dashboard, so they would capture every HTTP request.
			observability: {
				logs: { enabled: true, invocationLogs: false },
				traces: { enabled: false },
			},
			env: {
				// deploy.sh looks the database up by name on every run and passes its id here.
				DB: bindings.d1({ name: "dmarc-reports", id: process.env.DMARC_D1_ID ?? LOCAL_D1_ID }),
				// Static assets, also read by src/geo.ts for the IP geolocation databases.
				ASSETS: bindings.assets(),
			},
		},
	};
});
