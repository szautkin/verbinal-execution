# Changelog

All notable changes to this project are documented here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/), and the project aims
to follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Linting and formatting: Ruff (config in `pyproject.toml`), ShellCheck for the
  shell scripts, Hadolint for the Dockerfile (`.hadolint.yaml`), and actionlint
  for the workflows.
- CI `lint` job running all of the above on every push/PR, alongside the
  existing Docker build-and-test job.
- `.pre-commit-config.yaml` mirroring the CI lint job, plus `.editorconfig`.
- Open-source project scaffolding: `CODE_OF_CONDUCT.md`, issue and pull-request
  templates, and a Dependabot config for GitHub Actions / Docker / pip.

### Changed
- Applied Ruff lint/format fixes to the `opt/verbinal/` helpers (f-strings,
  `datetime.UTC`, import sorting, `contextlib.suppress`) with no behavior change.

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

[Unreleased]: https://github.com/szautkin/verbinal-execution/compare/0.0.1...HEAD
[0.0.1]: https://github.com/szautkin/verbinal-execution/releases/tag/0.0.1
