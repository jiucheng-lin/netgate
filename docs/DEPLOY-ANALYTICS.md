# Deploying the analytics backend (Cloudflare Worker + KV)

This sets up the optional, opt-in telemetry endpoint described in [TELEMETRY.md](TELEMETRY.md). Estimated time: 10-15 minutes. Free tier is enough.

## 1. Prerequisites

- A Cloudflare account (free): https://dash.cloudflare.com/sign-up
- Node.js 18+ with npm (you already have Node 22)

## 2. Install Wrangler

```bash
npm install -g wrangler
wrangler login
```

A browser window opens; approve the login.

## 3. Create the KV namespace

From the `worker/` directory:

```bash
cd worker
wrangler kv namespace create NETGATE_KV
wrangler kv namespace create NETGATE_KV --preview
```

Each command prints an `id`. Copy them.

## 4. Configure

```bash
cp wrangler.toml.example wrangler.toml
```

Edit `wrangler.toml`, replace `REPLACE_WITH_YOUR_KV_ID` and `REPLACE_WITH_YOUR_PREVIEW_KV_ID` with the ids from step 3.

Set the stats token (pick a long random string; you will need it to read reports):

```bash
wrangler secret put STATS_TOKEN
```

Paste your chosen token when prompted.

## 5. Deploy

```bash
wrangler deploy
```

The output shows your endpoint URL, e.g.:

```
https://netgate-telemetry.<your-subdomain>.workers.dev
```

Verify:

```bash
curl https://netgate-telemetry.<your-subdomain>.workers.dev/health
# {"ok":true,"service":"netgate-telemetry","v":1}
```

## 6. Wire it into NetGate

Two ways:

**A. Per-user (each user opts in themselves):** in the NetGate web UI, open Settings, paste the `/ingest` URL into the telemetry field, and switch it on. Nothing is collected until they do.

**B. Build-time default:** set `TELEMETRY_ENDPOINT` in `web/index.html` to your `/ingest` URL before distributing. Users are still asked for consent on first run; the URL is just pre-filled.

## 7. Read your stats

```bash
curl "https://netgate-telemetry.<your-subdomain>.workers.dev/stats?token=YOUR_TOKEN"
```

Or use the helper script (from the repo root):

```powershell
.\ops\fetch-telemetry.ps1 -Endpoint "https://netgate-telemetry.<your-subdomain>.workers.dev" -Token "YOUR_TOKEN"
```

## What is stored

In KV, only counters:
- `event:<name>` - total count per event
- `fail:<name>` - failure count per event
- `day:<YYYY-MM-DD>:<name>` - daily counts (last 7 days readable)
- `uid:<date>:<id-prefix>` - best-effort unique-id marker for daily unique users

No paths, filenames, IPs, usernames, or machine names are stored. The Worker discards anything outside the allowed field set.

## Cost

Cloudflare free tier includes 100,000 Worker requests/day and 1 GB-day of KV storage. For a small utility this is effectively unlimited.

## Privacy checklist before enabling

- [ ] Privacy statement published in the repo
- [ ] Telemetry is off by default and only enabled explicitly in Settings (no first-run popup)
- [ ] User can turn it off and clear local data at any time
- [ ] `/stats` protected by token
- [ ] Endpoint URL pinned in code/config (no third-party relay)
