# Contributing

Thanks for your interest in `verbinal-execution`. This is a small, security-
sensitive image (it runs arbitrary agent-supplied code as the CANFAR user), so
changes are reviewed with that in mind.

## Layout

```
Dockerfile            # multi-stage: builder venv -> slim runtime
requirements.txt      # the bundled science stack agent code can import
skaha/startup.sh      # contributed-session entrypoint (health server + watcher)
opt/verbinal/         # watcher.sh + python helpers + health server
test/                 # checklist.sh, integration.sh, imports.sh
```

See `README.md` for the architecture and the file-drop contract.

## Build & test

Everything is verified by building the image and running the suites inside it
(they need GNU coreutils, which the base provides). Running as a non-root uid
mirrors how Skaha assigns an arbitrary uid:

```bash
docker buildx build --platform linux/amd64 -t verbinal-execution:dev .
for t in checklist integration imports; do
  docker run --rm -u 4321:4321 -v "$PWD":/src:ro --entrypoint bash \
    verbinal-execution:dev /src/test/$t.sh
done
```

Or use the `Makefile`: `make build && make test`.

CI (`.github/workflows/ci.yml`) runs exactly this on every push/PR. Please make
sure all three suites pass before opening a PR, and add a check to the relevant
suite for any behavior you change.

## Conventions

- **Never break the watcher loop.** All errors must be caught and turned into a
  result file or a log line; the entrypoint process must never exit (that drops
  the Skaha session).
- **Treat the request `id` and code as untrusted.** Sanitize ids for paths,
  never `eval`, never interpolate into a shell string — always stage code to a
  file and run the file. Build all JSON via `json.dumps` (the python helpers),
  never hand-rolled string concatenation.
- **Atomic writes:** results and `status.json` are written to a `.partial` file,
  fsync'd, verified non-empty, then `os.replace`d into place.
- Match the surrounding style (shell and python). Keep comments at the same
  density and explain *why*, not *what*.

## Adding or removing Python packages

Edit `requirements.txt` and rebuild. The live, authoritative list is exposed by
the `:5000` health endpoint's `packages` field, and `test/imports.sh` verifies
the stack actually imports in the runtime image — update it if you add a package
that needs a runtime shared library.
