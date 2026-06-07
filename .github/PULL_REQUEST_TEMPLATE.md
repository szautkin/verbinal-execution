<!-- Thanks for contributing to verbinal-execution! -->

## What & why

<!-- What does this change do, and why is it needed? -->

## How it was tested

<!-- e.g. `make build && make test`, or which suite/check you added. -->

## Checklist

- [ ] `make build && make test` passes (all three suites: checklist, integration, imports).
- [ ] `ruff check` and `ruff format --check` are clean (or `pre-commit run --all-files`).
- [ ] The watcher loop still cannot exit on error (all failures become a result file or log line).
- [ ] Request `id` and code are still treated as untrusted (no `eval`, no shell interpolation; code is staged to a file).
- [ ] Added/updated a check in the relevant `test/*.sh` suite for any behavior change.
- [ ] Updated `README.md` / `CHANGELOG.md` if user-facing behavior or the file-drop contract changed.
