# verbinal-compute

[![ci](https://github.com/szautkin/verbinal-execution/actions/workflows/ci.yml/badge.svg)](https://github.com/szautkin/verbinal-execution/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![code style: ruff](https://img.shields.io/badge/code%20style-ruff-261230.svg)](https://github.com/astral-sh/ruff)

A CANFAR/Skaha **contributed** interactive session image whose baked-in
entrypoint is a long-lived watcher. The watcher polls a directory under the
launching user's `/arc` home, executes short Python/bash snippets that an
external client (Verbinal) drops there as JSON request files, and writes JSON
result files back. **No shell, no inbound network — the only work channel is
files under `/arc`.**

It runs as a *contributed* session so it lands on the fast interactive pool
(Running in seconds) rather than the headless batch queue. Long/batch work is
out of scope — use headless jobs for that.

## How it runs on Skaha

A contributed session is, by the platform's contract, **a web app on port 5000
launched from `/skaha/startup.sh`**, declared with the
`ca.nrc.cadc.skaha.type="contributed"` label. This image satisfies that contract
*and* does the real work over files:

```
/skaha/startup.sh            ENTRYPOINT (contributed-session launch contract)
├── health_server.py  :5000  liveness web surface so the portal keeps the pod up
└── watcher.sh               the real work loop (file-drop executor)
```

`startup.sh` resolves config once, exports it, launches both processes, and
`wait -n`s on them; if either exits it tears down so the pod restarts. The
execution mechanism is the **ENTRYPOINT** because Skaha ignores `cmd/args/env`
for contributed sessions — they are silently dropped.

Skaha provides the runtime (don't configure it): the session runs as the
launching CANFAR user (uid/gid from SSO; any `USER` directive is overridden),
auto-mounts the user's home at `/arc/home/<username>/`, provides `/scratch` for
ephemeral temp, and renews a session TTL.

## The file-drop contract

Default layout (relocatable via config, below):

```
$HOME/.verbinal/exec/
├── status.json     # heartbeat/readiness, written by the watcher
├── inbox/          # client writes request files here
├── out/            # watcher writes result files here
└── done/           # watcher moves processed requests here (audit/idempotency)
```

The watcher `mkdir -p`s the whole tree at startup — it is the source of truth
and does not assume the client created it.

**Request** (`inbox/<SAFE_ID>.json`):

```json
{ "id": "req-1", "language": "python", "code": "print(1+1)", "timeout_seconds": 120 }
```

- `id` — client-chosen, opaque, `[A-Za-z0-9._-]`, ≤128 chars. Sanitized before
  any path use (`/:?*<>|"\` → `_`). The result echoes the **original** id.
- `language` — `"python"` (→ `python3`) or `"bash"`; anything else → error.
- `code` — UTF-8 string, run from a staged file (never the command line).
- `timeout_seconds` — int, clamped to `[1, timeout_ceiling]` (default ceiling 900).
- Unknown fields are ignored (forward-compat).

**Result** (`out/<SAFE_ID>.json`):

```json
{ "id":"req-1", "status":"ok", "exit_code":0,
  "stdout":"2\n", "stderr":"", "stdout_encoding":"utf8", "stderr_encoding":"utf8",
  "duration_ms":41, "truncated":false,
  "started_at":"2026-06-02T14:03:11Z", "finished_at":"2026-06-02T14:03:11Z" }
```

- `status` — `ok` (exit 0) / `error` (non-zero, or malformed/unsupported) /
  `timeout` (killed).
- `exit_code` — real exit code; `124` on timeout; `-1` on malformed/unsupported.
- `stdout`/`stderr` — each capped at 256 KiB (`output_cap_bytes`) and
  **tail**-truncated (the end, where tracebacks live), with `truncated:true`.
- `stdout_encoding`/`stderr_encoding` — `"utf8"` (default) when the stream is
  valid UTF-8 (json.dumps escapes control chars; truncation prepends a
  `...[truncated N bytes]...` marker), or `"base64"` when the stream contains
  non-UTF-8 bytes — the field is then the base64 of the (tail-truncated) raw
  bytes. This guarantees the result file is always valid JSON, so binary output
  can never produce an unparseable result that hangs the client. (Absent ⇒
  `utf8`, so it's backward-compatible.)
- A result is produced for **every** claimed request, including failures and
  timeouts — the client blocks on it.

**Writes.** The watcher publishes results atomically: write
`<name>.json.partial`, flush + fsync, verify non-empty, then `os.replace` to
`<name>.json`.

**Claiming (no rename on the client side).** Verbinal's cavern/ARC layer has no
move/rename op — it does a single HTTP `PUT` straight to
`inbox/<SAFE_ID>.json`, so a file can be observed mid-upload. The watcher
therefore **never claims a file until it parses as a complete request**
(structural check: valid JSON object with `id`/`language`/`code`/`timeout_seconds`
of the right types). A file that doesn't parse yet is skipped and retried next
poll. To avoid hanging the client on a genuinely malformed request, a file that
stays unparseable **and byte-stable** (same size+mtime) past a short grace
window (`STABLE_GRACE_SEC`, 3 s) is then claimed and given an `error` result.
An unsupported language is a *complete* request, so it's claimed immediately and
errored. The claim itself is the atomic `mv inbox → done`.

**Crash recovery / idempotency:** names are deterministic from the id. If
`out/<SAFE_ID>.json` exists the request is done (never re-run). On boot the
watcher re-scans `inbox/` for unresulted requests and also re-runs anything left
in `done/` without a result (a crash mid-execution).

## Configuration

One well-known JSON file — default `$HOME/.verbinal/config.json` — carries
settings under a top-level **`verbinal-execution`** key (so the same file can
hold config for other Verbinal components). The file is optional; every field
is optional and falls back to the documented default. Malformed/missing config
silently yields defaults.

> **No config file is required.** Verbinal v1 does not write
> `$HOME/.verbinal/config.json`; the watcher runs entirely on the defaults below
> — in particular `exec_dir = $HOME/.verbinal/exec`, ceiling `900`, cap
> `262144`. The file exists only to relocate/tune later without rebuilding.

```json
{
  "verbinal-execution": {
    "exec_dir": "/arc/home/<user>/.verbinal/exec",
    "poll_interval_ms": 1000,
    "output_cap_bytes": 262144,
    "timeout_ceiling_seconds": 900,
    "mem_fraction": 0.75
  }
}
```

| Key | Default | Clamp | Meaning |
|-----|---------|-------|---------|
| `exec_dir` | `$HOME/.verbinal/exec` | — | Where the `inbox/out/done` tree lives. Relative paths resolve against `$HOME`; use this to put the channel on `/arc/projects/...` instead of home. |
| `poll_interval_ms` | `1000` | 100–60000 | Inbox poll cadence. Heartbeat refreshes at ≤ this interval (and ≤ 2 s), staying fresher than the client's 3×-poll staleness bound. |
| `output_cap_bytes` | `262144` | 1024–1048576 | Per-stream stdout/stderr cap before tail-truncation. |
| `timeout_ceiling_seconds` | `900` | 1–3600 | Upper clamp on a request's `timeout_seconds`. |
| `mem_fraction` | `0.75` | 0.10–0.95 | Per-request address-space (`ulimit -v`) ceiling as a fraction of the session memory limit, so one request can't OOM-kill the pod. |

## Health / readiness

`status.json` (composed and published atomically by the watcher) is both a
heartbeat and a **live activity record**:

```json
{ "ready":true, "watcher_version":"1.0.0", "pid":1,
  "languages":["python","bash"], "poll_interval_ms":1000,
  "resolved_home":"/arc/home/<user>", "resolved_user":"<user>",
  "state":"processing", "processed_count":7,
  "current":{ "id":"req-9", "language":"python3", "started_at":"...Z" },
  "last_request":{ "id":"req-8", "status":"ok", "exit_code":0, "finished_at":"...Z" },
  "last_error":null,
  "heartbeat_at":"...Z", "started_at":"...Z" }
```

- `state` — `idle` (polling), `processing` (a request is running — see
  `current`), or `exiting` (SIGTERM). `current`/`last_request`/`last_error` are
  `null` when not applicable.
- `resolved_home`/`resolved_user` — what the watcher resolved from `$HOME` /
  `id`. Verbinal builds its path from its CADC username, so it can assert these
  match and **fail loudly** instead of silently reading a different directory.
- The watcher is the **single writer**: it refreshes `heartbeat_at` on every
  poll *and* from within a running request, so the heartbeat never goes stale —
  even during a 900 s request — yet a genuinely hung watcher correctly stops
  heartbeating (it doesn't get masked by an independent heartbeat thread).

`GET http://<pod>:5000/` returns JSON reflecting that state — `state`,
`processed_count`, `current`, `last_request`, `last_error` — plus
**capability discovery** (`python_version` and the installed `packages` agent
code can import) and the full `watcher_status`:

```json
{ "service":"verbinal-compute", "ready":true, "state":"processing",
  "processed_count":7, "current":{...}, "last_request":{...}, "last_error":null,
  "python_version":"3.11.x", "package_count":142,
  "packages":[ {"name":"astropy","version":"6.1.0"}, {"name":"numpy","version":"1.26.4"}, ... ],
  "heartbeat_at":"...Z", "started_at":"...Z", "watcher_status":{...} }
```

`packages` is the authoritative list from the *same* interpreter agent code
runs (`importlib.metadata` over the venv), computed **once at startup** and
cached, so listing it adds no per-request cost.

HTTP 200 when the heartbeat is fresh (`ready:true`) or the watcher hasn't
written status yet (still starting); 503 once status exists but the heartbeat
has gone stale. This is the platform liveness/observability surface only — it
performs **no** execution.

## Security & isolation

This image runs arbitrary agent-supplied code **as the CANFAR user** — intended.
Blast radius equals what that user could do at a terminal; the watcher grants no
extra privilege. There is no inbound network and no listening port for the work
channel — the only channel is `/arc`. Per-request: enforced wall-clock timeout
(`timeout --signal=TERM --kill-after=5s`), `ulimit -t` (CPU) and `ulimit -v`
(address space, a fraction of session RAM), and output caps. `id` is treated as
untrusted: sanitized for paths, never `eval`'d, never interpolated into a shell
string — code is always staged to a file and the file is run.

## Bundled Python packages (what agent code can import)

Rather than the multi-GB `skaha/astroml` base, this image uses a lean
`python:3.11-slim` base carrying the **star-ai-images science stack** (see
`requirements.txt`), installed into a venv that becomes the default `python3`.
Result: a **~1 GB image** (venv ≈ 870 MB) with the full stack — `numpy`,
`scipy`, `pandas`, `matplotlib`, `astropy`, `astroquery`, `photutils`,
`specutils`, `reproject`, `regions`, `fitsio`, `h5py`, `scikit-learn`,
`scikit-image`, `ipython`, `tqdm`, `pyyaml`, `requests`, and `canfar` — plus
their dependencies (~135 packages total). The notebook server (`jupyter`) from
the star-ai list is intentionally omitted (useless headless, large).

**The live, authoritative list is the `:5000` health endpoint's `packages`
field** (see below) — that's the ground truth from the same interpreter agent
code runs. Add/remove packages by editing `requirements.txt` and rebuilding.

## Build & publish

linux/amd64 only (arm64 fails at pull). Published image:

```
images.canfar.net/private-test/verbinal-execution:0.0.1
```

Build a clean single-arch image and push (provenance/SBOM attestations off so
the registry gets a plain amd64 image):

```bash
docker build --platform linux/amd64 --provenance=false --sbom=false \
  -t images.canfar.net/private-test/verbinal-execution:0.0.1 .
docker push images.canfar.net/private-test/verbinal-execution:0.0.1
```

- **Base image** is the build arg `BASE_IMAGE`, defaulting to
  `python:3.11-slim-bookworm` (a multi-stage build compiles into a venv in a
  throwaway builder, so the toolchain never ships). Override to pin a different
  base if needed.
- The `ca.nrc.cadc.skaha.type="contributed"` label is required — without it,
  `POST /v1/session?type=contributed` returns HTTP 400. The image must be
  registered in Harbor with the contributed session type.
- The client reads/writes over `https://ws-uv.canfar.net/arc/files/home/<user>/
  .verbinal/exec/{out,inbox}/<SAFE_ID>.json`; the image only ever sees these as
  plain files under the exec dir.

## Layout

```
verbinal-execution/             # repo root
├── Dockerfile                  # multi-stage: builder venv -> slim runtime
├── requirements.txt            # the bundled science stack
├── Makefile                    # build / test / push helpers
├── skaha/startup.sh            # contributed-session entrypoint (health + watcher)
├── opt/verbinal/
│   ├── watcher.sh              # the never-exiting file-drop executor
│   ├── parse_request.py        # validate/stage a request (JSON in)
│   ├── build_result.py         # build + atomically publish a result (JSON out)
│   ├── read_config.py          # resolve the verbinal-execution config
│   ├── status_writer.py        # compose + atomically publish status.json
│   └── health_server.py        # :5000 liveness + live-state + packages surface
├── test/
│   ├── checklist.sh            # §7 go/no-go unit checks (drives watcher.sh)
│   ├── integration.sh          # startup.sh + :5000 state + config relocation
│   └── imports.sh              # the bundled science stack actually imports
└── .github/workflows/ci.yml    # build image + run all three suites
```

## How the Verbinal team can check the image

**1. Inspect what's available without launching code — hit `:5000`.** From
inside the session (or via the Skaha-proxied URL), any GET returns the live
state plus the full package list. No `curl` in the slim base; use Python:

```python
import json, urllib.request
d = json.loads(urllib.request.urlopen("http://127.0.0.1:5000/").read())
print(d["ready"], d["state"], d["python_version"], d["package_count"])
print({p["name"]: p["version"] for p in d["packages"]})   # e.g. astropy 7.2.0, numpy 2.4.6, canfar 1.3.5 ...
```

`ready:true` + a fresh `heartbeat_at` means the watcher is up; `state` is
`idle`/`processing`/`exiting`; `current`/`last_request`/`processed_count` show
live activity; `packages` is exactly what snippets can import.

**2. End-to-end round-trip over the file channel** (what Verbinal actually
does): write a request and read the result.

```python
# write inbox/t1.json  (single PUT in production; here a local write)
req = {"id":"t1","language":"python","code":"print(1+1)","timeout_seconds":30}
# ... PUT to .../.verbinal/exec/inbox/t1.json ...
# then poll .../.verbinal/exec/out/t1.json -> {"status":"ok","stdout":"2\n",...}
```

**3. Verify identity matches** before relying on the channel: compare
Verbinal's CADC-derived path against `resolved_home`/`resolved_user` in
`status.json` (or the health body's `watcher_status`); mismatch ⇒ fail loudly.

## Testing locally (maintainers)

Build and run all three suites inside the image (they need GNU coreutils, which
the base provides). `-u 4321:4321` mirrors Skaha assigning an arbitrary,
non-root uid:

```bash
make build && make test
# equivalently:
docker buildx build --platform linux/amd64 -t verbinal-execution:dev .
for t in checklist integration imports; do
  docker run --rm -u 4321:4321 -v "$PWD":/src:ro --entrypoint bash \
    verbinal-execution:dev /src/test/$t.sh
done
```

The first build pulls the science stack (~100 s); after that, buildx layer
caching makes iteration fast — editing `opt/verbinal/` only rebuilds the small
final layers, not the venv. (`BASE_IMAGE` must be a Python image, since the
builder stage creates a venv; the default is `python:3.11-slim-bookworm`.)

CI (`.github/workflows/ci.yml`) runs exactly these three suites on every push
and PR. Current status: **checklist 37/37, integration 14/14, imports 19/19** on
the default lean image (linux/amd64, run as uid 4321).

## Final validation on CANFAR (go / no-go)

Launch as the real user via Skaha (`type=contributed`) and confirm: session
stays Running ≥10 min; `status.json` + tree appear within seconds with
`ready:true` and advancing `heartbeat_at`; `:5000` returns the package list;
round-trips for python/bash return correct streams; non-zero exit and timeouts
do **not** kill the session; >256 KiB output truncates to valid JSON; binary
output comes back base64; unsupported language and malformed JSON return `error`
and the loop continues; a relaunch on the same `/arc` home re-runs unresulted
requests but not already-resulted ones.

## License

[MIT](LICENSE). See also [`CONTRIBUTING.md`](CONTRIBUTING.md),
[`SECURITY.md`](SECURITY.md), and [`CHANGELOG.md`](CHANGELOG.md).
