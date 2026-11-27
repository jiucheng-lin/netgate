# Telemetry Design (DRAFT - not enabled)

Status: **implemented, opt-in, disabled by default.**

This document describes the optional, privacy-preserving usage analytics in NetGate. Nothing is collected or sent until the user explicitly enables it.

## Why this is sensitive

NetGate is a tool that modifies Windows Firewall rules. Collecting data in a tool like this is inherently sensitive and can destroy trust if done carelessly. Any telemetry MUST meet all of the following:

1. **Opt-in only** - off by default, user explicitly enables it
2. **Auditable** - the full source is public; anyone can verify what is sent
3. **No paths** - never transmit executable paths, filenames, usernames, machine names, or IP addresses as data
4. **Reversible** - one switch turns it off and clears local state
5. **Honest** - a plain-language explanation in the UI of exactly what is collected

## What would be collected

Only coarse event counters. Example event payload:

```json
{
  "v": "1.0.0",
  "id": "a1b2c3d4e5f6...",     // random anonymous UUID, generated locally
  "e": "block",               // event name
  "t": 1760000000,            // unix timestamp (seconds)
  "os": "10.0.19045",         // OS major.minor.build only
  "r": 1                      // 1 = success, 0 = failure
}
```

Event names: `app_start`, `block`, `unblock`, `enable`, `disable`, `scan`, `export`, `import`, `reset`, `error`.

**Never collected**: exe paths, directory names, usernames, computer names, IP addresses, network interfaces, rule contents, configuration files.

## How it would work

1. On first use, the app asks once: "Help improve NetGate by sending anonymous usage counts? [No / Yes]"
2. If No (default): nothing is stored, nothing is sent.
3. If Yes: a random UUID is generated and stored locally in `%LOCALAPPDATA%\NetGate\telemetry.json`.
4. Each action appends one small event to a local queue file.
5. Events are POSTed to a configured endpoint in batches. On success the queue is cleared. On failure the queue is kept for retry.
6. The user can disable at any time; disabling deletes the local ID and queue.

## Backend options (need your decision)

| Option | What you need | Pros | Cons |
|---|---|---|---|
| **A. GitHub metrics only** (current) | nothing | zero privacy risk, zero setup | no feature-level data |
| **B. Cloudflare Worker + KV** | a free Cloudflare account | free tier, no server to maintain, can aggregate counts | need to deploy worker + domain/URL |
| **C. Self-hosted HTTP endpoint** | a server/VPS you control | full control of data | you maintain it |
| **D. Third-party analytics** (e.g. Plausible/PostHog) | an account + API key | dashboards ready-made | external dependency, trust considerations |

My recommendation: **B** if you want real usage numbers without maintenance. I can write the Worker code; you just deploy it and give me the URL.

## Implementation status

- [x] Client module (`ops/telemetry.ps1`) - implemented and wired into the server
- [x] Server-side event hooks (block/unblock/enable/disable/scan/export/import/reset)
- [x] Consent UI in `web/index.html` - first-run prompt, defaults to No
- [x] Settings panel - toggle, endpoint field, opt-out clears local data
- [x] Backend (`worker/worker.js`) - Cloudflare Worker + KV, ingest/stats/health
- [ ] Endpoint URL - deploy the Worker and paste its `/ingest` URL in Settings
- [ ] Stats token - set with `wrangler secret put STATS_TOKEN`
- [ ] Endpoint pinned as build-time default (optional; users can enter it manually)

Nothing is collected until a user opts in AND a valid endpoint is configured.
