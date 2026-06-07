# Changelog

All notable changes to this project are documented here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/), and the project aims
to follow [Semantic Versioning](https://semver.org/).

## [0.0.1] - 2026-06-02

Initial release.

### Added
- Long-lived file-drop watcher (`opt/verbinal/watcher.sh`) as the contributed-
  session entrypoint: polls `inbox/`, runs python/bash snippets, writes JSON
  results to `out/`, archives requests to `done/`.
- Skaha contributed-session contract: `/skaha/startup.sh` launches a `:5000`
  liveness web surface alongside the watcher, with the
  `ca.nrc.cadc.skaha.type="contributed"` label.
- Request claiming designed for cavern's single-`PUT` model (no rename):
  claim-on-complete-parse with a byte-stability grace window for malformed files.
- Result encodings: `utf8` by default, `base64` for non-UTF-8 output, so result
  files are always valid JSON.
- `status.json` as a live activity record (`state`, `current`, `last_request`,
  `processed_count`, `last_error`, `resolved_home`/`resolved_user`); single
  writer keeps the heartbeat fresh even during long requests.
- `:5000` health endpoint reports live state plus capability discovery
  (`python_version`, `package_count`, `packages`).
- Optional `verbinal-execution` config key (relocate `exec_dir`, tune
  poll/cap/timeout/memory); runs entirely on defaults with no config file.
- Lean image: `python:3.11-slim` base + the star-ai-images science stack
  installed into a venv via a multi-stage build (~1 GB; `jupyter` omitted).
- Test suites: `checklist.sh` (37), `integration.sh` (14), `imports.sh` (19),
  and a GitHub Actions workflow that builds the image and runs all three.

[0.0.1]: https://github.com/verbinal/verbinal-execution/releases/tag/0.0.1
