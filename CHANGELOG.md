# Changelog

All notable changes to this project are documented here.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.2.0] - 2026-11-27

### Added
- Onboarding guide: non-blocking 3-step inline guide, dismissed after first block or by "skip"
- Return hooks: monthly block counter, "unmanaged running programs" suggestion panel
- AI assist (local heuristics, no external API):
  - Smart recommendations ranked by background-traffic signals with reasons
  - Natural-language parsing ("block chrome" / "把 XX 断网") matched against discovered programs
- Funnel telemetry events: `first_open`, `first_block`, `return_7d`
- `ops/dashboard.html` - local analytics dashboard reading Worker `/stats`
- Content kit: B站 video script, 知乎 article, SEO landing page (`docs/index.html`)
- `PRIVACY.md` - full privacy policy
- Real UI screenshot replacing placeholder

### Changed
- README: value proposition, trust section, privacy wording

## [1.1.0] - 2026-11-27

### Added
- Program picker: list running + installed programs, no need to type paths
- Drag-and-drop .exe onto the page
- Optional anonymous telemetry (opt-in, default off, no first-run popup)
- Settings panel with telemetry toggle and endpoint field
- Cloudflare Worker + KV analytics backend (`worker/`)
- GitHub Release with ready-to-run zip package

## [1.0.0] - 2026-11-26

### Added
- Initial release: per-app network blocking via Windows Firewall (`NG-` prefix rules)
- Web UI on `127.0.0.1`, CLI, batch directory scan, config export/import, one-click reset
