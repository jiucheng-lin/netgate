# Privacy Policy

Last updated: 2026-11-27

NetGate is a local Windows utility for controlling individual applications' network access. This policy explains what data the tool handles.

## Summary

**By default, NetGate collects nothing and sends nothing.** All data stays on your machine. There is no first-run popup and no telemetry unless you explicitly enable it in Settings.

## Data stored locally

| Data | Where | Purpose |
|---|---|---|
| Firewall rules | Windows Firewall (under your control) | Block/allow the programs you choose |
| Rule list | Windows Firewall rule Description field | Display managed programs in the UI |
| Program discovery cache | In-memory only, per session | Program picker; not written to disk |
| Telemetry settings (only if enabled) | `%LOCALAPPDATA%\NetGate\telemetry.json` | Your opt-in preference and anonymous ID |
| Telemetry queue (only if enabled) | `%LOCALAPPDATA%\NetGate\telemetry-queue.jsonl` | Events waiting to be sent |

Your configuration export (JSON) is created only when you click "Export", and saved only where you choose.

## What telemetry sends (only if you enable it)

If and only if you go to Settings, enter an endpoint URL and switch telemetry on, NetGate sends small anonymous events:

```json
{
  "v": "1.0.0",
  "id": "random-anonymous-uuid",
  "e": "block",
  "t": 1760000000,
  "os": "10.0.19045",
  "r": 1
}
```

- `e` = event name (block, unblock, scan, export, import, reset, etc.)
- `r` = 1 success / 0 failure
- `os` = major.minor.build only
- `id` = a random UUID generated on your machine, not tied to any identity

**NetGate never collects or transmits**: executable paths, filenames, window titles, usernames, computer names, IP addresses, network configuration, rule contents, or configuration files.

## How to disable telemetry

Open Settings → switch "Send anonymous usage stats" off. This clears your local anonymous ID and all queued events. You can also run:

```powershell
.\ops\telemetry.ps1 -Action optout
```

## Network behavior

- The local web service binds only to `127.0.0.1` (loopback). It is not reachable from your LAN or the internet.
- The only outbound connection NetGate can make is to the telemetry endpoint **you** configure, and only after you opt in.
- No analytics SDK, no third-party trackers, no auto-update checks.

## Firewall changes

NetGate creates Windows Firewall rules prefixed `NG-`. It never modifies rules it did not create. "Clear all rules" removes only `NG-` rules. Uninstalling is a matter of deleting the folder and clearing the rules.

## Third parties

The optional analytics backend is a Cloudflare Worker you deploy and control yourself. If you do not deploy one, no data leaves your machine.

## Changes

This policy may change as NetGate evolves. Updates will be committed to this file in the public repository with a new "Last updated" date.

## Contact

Report privacy concerns via GitHub Issues at https://github.com/jiucheng-lin/netgate/issues
