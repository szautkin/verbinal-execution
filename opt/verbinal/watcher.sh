#!/usr/bin/env bash
# Verbinal compute watcher.
#
# Long-lived ENTRYPOINT for a CANFAR/Skaha *contributed* interactive session.
# There is NO HTTP server: the only channel is the file-drop tree under the
# launching user's /arc home. The client (Verbinal) writes JSON request files
# into inbox/, this watcher executes them and writes JSON result files into
# out/, moving processed requests into done/ for audit/idempotency.
#
# This process MUST NOT exit: if the entrypoint dies, the pod terminates and
# the Skaha session fails. Every error is caught inside the loop and turned
# into a result file or a log line; nothing propagates out of the loop.
#
# Skaha runs this as the launching CANFAR user at an arbitrary uid/gid, so we
# never assume root and only ever write under /arc/home/<user>/ and /scratch.

set -u
set -o pipefail
# NOTE: deliberately NOT `set -e` -- a non-zero from user code or a helper must
# never kill the watcher.

WATCHER_VERSION="1.0.0"
KILL_AFTER="5s"              # grace after TERM before SIGKILL
TIMEOUT_FLOOR=1
MEM_FLOOR_KB=524288          # don't set ulimit -v below 512 MiB (would break python)
STABLE_GRACE_SEC=3           # an unparseable inbox file must be byte-stable this
                             # long before we treat it as malformed (vs. mid-PUT)

# Per-poll stability tracking for inbox files that don't yet parse. Verbinal
# PUTs requests directly to inbox/<id>.json (no rename), so a file may be seen
# mid-upload: we only claim once it parses, or -- if it stays unparseable and
# byte-stable past STABLE_GRACE_SEC -- claim it so it gets an error result
# instead of hanging the client forever.
declare -A SEEN_SIG    # filename -> "size:mtime" last observed unparseable
declare -A SEEN_TS     # filename -> epoch seconds that signature was first seen

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE="$SELF_DIR/parse_request.py"
BUILD="$SELF_DIR/build_result.py"
READ_CONFIG="$SELF_DIR/read_config.py"
STATUS_WRITER="$SELF_DIR/status_writer.py"

# Live activity state, published in status.json (single-writer: the main loop).
STATE="starting"        # starting | idle | processing | exiting
PROCESSED=0             # count of requests completed since start
CUR_ID=""; CUR_LANG=""; CUR_STARTED=""           # current request (when processing)
LAST_ID=""; LAST_STATUS=""; LAST_EXIT=""; LAST_FINISHED=""   # last completed
ERR_MSG=""; ERR_AT=""   # last watcher-internal error (not user-code errors)

# 3.1: resolve the launching user's identity and home exactly once. These are
# published in status.json so the client can assert its CADC-derived path
# matches ours and fail loudly instead of silently reading a different dir.
# NOTE: for an unmapped uid (Skaha's arbitrary-uid case) `id -un` prints the
# numeric uid to stdout AND exits non-zero, so we must NOT chain it with `||`
# (that would concatenate two outputs and embed a newline). Capture once, then
# fall back only on empty.
RESOLVED_USER="$(id -un 2>/dev/null)"
[ -n "$RESOLVED_USER" ] || RESOLVED_USER="$(id -u 2>/dev/null)"
[ -n "$RESOLVED_USER" ] || RESOLVED_USER="unknown"
USER_HOME="${HOME:-/arc/home/$RESOLVED_USER}"

# The one well-known config file (overridable for tests). Settings the watcher
# needs live under its "verbinal-execution" key; see read_config.py.
CONFIG_PATH="${VERBINAL_CONFIG:-$USER_HOME/.verbinal/config.json}"

# Settings come from the environment when launched via /skaha/startup.sh (which
# resolves the config once and exports it). When the watcher is run standalone
# (e.g. tests), it resolves the same config itself. read_config.py always emits
# a complete, clamped, shell-safe set of exports, so eval is safe.
if [ -z "${VERBINAL_EXEC_DIR:-}" ]; then
    eval "$(python3 "$READ_CONFIG" "$CONFIG_PATH" "$USER_HOME" 2>/dev/null)"
fi
BASE="${VERBINAL_EXEC_DIR:-$USER_HOME/.verbinal/exec}"
POLL_INTERVAL_MS="${VERBINAL_POLL_MS:-1000}"
OUTPUT_CAP_BYTES="${VERBINAL_OUTPUT_CAP:-262144}"   # per stream (client window)
TIMEOUT_CEIL="${VERBINAL_TIMEOUT_CEIL:-900}"
MEM_PERCENT="${VERBINAL_MEM_PERCENT:-75}"           # ulimit -v as % of session RAM

# Derive sleep intervals (seconds, may be fractional) from the poll interval.
# Heartbeat refreshes at <= the poll interval and never slower than ~2s, so
# heartbeat_at always stays fresher than the client's 3x-poll staleness bound.
POLL_INTERVAL_SEC="$(awk "BEGIN{printf \"%.3f\", $POLL_INTERVAL_MS/1000}")"
HEARTBEAT_INTERVAL_SEC="$(awk "BEGIN{p=$POLL_INTERVAL_MS/1000; printf \"%.3f\", (p<2?p:2)}")"

INBOX="$BASE/inbox"
OUT="$BASE/out"
DONE="$BASE/done"
STATUS="$BASE/status.json"

STARTED_AT=""   # set after we can call date; used in every status write

log() {
    printf '%s verbinal-watcher: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_ns()  { date +%s%N; }
now_s()   { date +%s; }

# Minimal JSON string escaping for values we embed via printf (backslash and
# double-quote -- the only metacharacters plausible in a home path or username).
json_escape() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }

# 2.2: sanitize an id before any path use. The set includes a literal backslash
# (the '\\' is a backslash inside a single-quoted string, not a quote escape).
# shellcheck disable=SC1003
sanitize() { printf '%s' "$1" | tr '/:?*<>|"\\' '_'; }

# Pick a writable ephemeral base for per-request scratch dirs (3.5).
scratch_base() {
    local d
    for d in "${SCRATCH:-/scratch}" "${TMPDIR:-}" /tmp; do
        [ -n "$d" ] || continue
        if [ -d "$d" ] && [ -w "$d" ]; then printf '%s' "$d"; return 0; fi
    done
    printf '%s' "/tmp"
}

# 4 + 2.5: compose + atomically publish status.json. Single writer (the main
# loop / its request processing), so there is no race. Delegates to a python
# composer so the file is always valid JSON despite untrusted fields (current
# request id, resolved user, error message).
write_status() {
    local -a args
    args=(--out "$STATUS" --version "$WATCHER_VERSION" --pid "$$" \
          --poll "$POLL_INTERVAL_MS" --home "$USER_HOME" --user "$RESOLVED_USER" \
          --started "$STARTED_AT" --heartbeat "$(now_iso)" \
          --state "$STATE" --processed "$PROCESSED")
    [ -n "$CUR_ID" ] && args+=(--current-id "$CUR_ID" \
          --current-language "$CUR_LANG" --current-started "$CUR_STARTED")
    [ -n "$LAST_ID" ] && args+=(--last-id "$LAST_ID" --last-status "$LAST_STATUS" \
          --last-exit "$LAST_EXIT" --last-finished "$LAST_FINISHED")
    [ -n "$ERR_MSG" ] && args+=(--error-msg "$ERR_MSG" --error-at "$ERR_AT")
    python3 "$STATUS_WRITER" "${args[@]}" 2>/dev/null || true
}

# Record a watcher-internal failure (surfaced as last_error in status.json).
note_error() { ERR_MSG="$1"; ERR_AT="$(now_iso)"; log "$1"; }

# 5: detect the session memory limit (KiB) to bound per-request address space.
# Try cgroup v2, then cgroup v1, then total RAM. Empty => leave unlimited.
detect_mem_limit_kb() {
    local v=""
    if [ -r /sys/fs/cgroup/memory.max ]; then
        v="$(cat /sys/fs/cgroup/memory.max 2>/dev/null)"
        [ "$v" = "max" ] && v=""
        [ -n "$v" ] && v=$(( v / 1024 ))
    fi
    if [ -z "$v" ] && [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        v="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)"
        # cgroup v1 reports a huge sentinel when unlimited.
        if [ -n "$v" ] && [ "$v" -lt 9000000000000000000 ] 2>/dev/null; then
            v=$(( v / 1024 ))
        else
            v=""
        fi
    fi
    if [ -z "$v" ] && [ -r /proc/meminfo ]; then
        v="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
    fi
    printf '%s' "${v:-}"
}

# Process one already-claimed request living at $1 (under done/), SAFE_ID $2.
# Always produces out/<SAFE_ID>.json -- the client blocks on it (2.4).
process_request() {
    local req="$1" safe="$2"
    local out_final="$OUT/$safe.json"
    local out_tmp="$out_final.partial"

    # Mark processing immediately (id is the sanitized name until parse reveals
    # the original) so the health surface reflects activity right away.
    STATE="processing"; CUR_ID="$safe"; CUR_LANG=""; CUR_STARTED="$(now_iso)"
    write_status

    local wd
    wd="$(mktemp -d "$(scratch_base)/verbinal.XXXXXX" 2>/dev/null)" || {
        note_error "mktemp failed; cannot process $safe"
        STATE="idle"; CUR_ID=""; CUR_LANG=""; CUR_STARTED=""; write_status
        return 0
    }

    local started_iso t0
    started_iso="$CUR_STARTED"
    t0="$(now_ns)"

    # finish(): record the completed request, return to idle, publish status.
    finish() {  # finish <status> <exit_code>
        LAST_ID="$CUR_ID"; LAST_STATUS="$1"; LAST_EXIT="$2"; LAST_FINISHED="$(now_iso)"
        PROCESSED=$(( PROCESSED + 1 ))
        STATE="idle"; CUR_ID=""; CUR_LANG=""; CUR_STARTED=""
        write_status
    }

    # --- parse + validate (2.3) -------------------------------------------
    if ! python3 "$PARSE" "$req" "$wd" 2>"$wd/parse_err"; then
        local finished_iso t1 dur
        finished_iso="$(now_iso)"
        t1="$(now_ns)"
        dur=$(( (t1 - t0) / 1000000 ))
        # Echo the original id if it parsed; reflect it in the live state too.
        [ -f "$wd/id" ] && CUR_ID="$(cat "$wd/id" 2>/dev/null)"
        local -a idarg
        if [ -f "$wd/id" ]; then idarg=(--id-file "$wd/id"); else idarg=(--id-literal "$safe"); fi
        # malformed / unsupported => status:"error", exit_code:-1 (2.4)
        python3 "$BUILD" --out-partial "$out_tmp" --out-final "$out_final" \
            "${idarg[@]}" --id-literal "$safe" \
            --status error --exit-code -1 --duration-ms "$dur" \
            --started "$started_iso" --finished "$finished_iso" \
            --stdout /dev/null --stderr "$wd/parse_err" --cap "$OUTPUT_CAP_BYTES" \
            || note_error "build_result(parse-error) failed for $safe"
        finish error -1
        rm -rf "$wd" 2>/dev/null || true
        return 0
    fi

    local lang timeout
    lang="$(cat "$wd/lang" 2>/dev/null)"
    timeout="$(cat "$wd/timeout" 2>/dev/null)"
    case "$timeout" in
        ''|*[!0-9]*) timeout=$TIMEOUT_FLOOR ;;
    esac
    [ "$timeout" -lt "$TIMEOUT_FLOOR" ] && timeout=$TIMEOUT_FLOOR
    [ "$timeout" -gt "$TIMEOUT_CEIL" ]  && timeout=$TIMEOUT_CEIL

    # Now that the request parsed, reflect the real id + language in the state.
    [ -f "$wd/id" ] && CUR_ID="$(cat "$wd/id" 2>/dev/null)"
    CUR_LANG="$lang"
    write_status

    # --- execute in a fresh child with clean cwd + ulimits (3.5, 3.6, 5) --
    local mem_kb
    mem_kb="$(detect_mem_limit_kb)"
    (
        cd "$wd" || exit 127
        # CPU ceiling aligned to the wall-clock timeout (secondary guard).
        ulimit -t $(( timeout + 5 )) 2>/dev/null || true
        # Address-space ceiling as a fraction of the session limit so one
        # request can't OOM-kill the pod and drop the whole session.
        if [ -n "$mem_kb" ]; then
            lim=$(( mem_kb * MEM_PERCENT / 100 ))
            if [ "$lim" -ge "$MEM_FLOOR_KB" ]; then
                ulimit -v "$lim" 2>/dev/null || true
            fi
        fi
        # Run the staged file (never code on the command line): avoids quoting,
        # arg-length, and the heredoc-shadows-pipe-stdin 0-byte-output bug.
        # Redirect straight to files -- no pipe involved.
        exec timeout --signal=TERM --kill-after="$KILL_AFTER" "${timeout}s" \
            "$lang" "$wd/code" >"$wd/stdout" 2>"$wd/stderr"
    ) &
    local child=$!
    # Refresh status while the child runs so the heartbeat stays fresh during a
    # long request and the health surface keeps reporting "processing".
    while kill -0 "$child" 2>/dev/null; do
        write_status
        sleep "$HEARTBEAT_INTERVAL_SEC"
    done
    wait "$child"
    local rc=$?

    local status exit_code
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        # 124 = terminated by timeout; 137 = had to SIGKILL after --kill-after.
        status="timeout"; exit_code=124
    elif [ "$rc" -eq 0 ]; then
        status="ok"; exit_code=0
    else
        # Real non-zero exit from user code is an error result, NOT a crash.
        status="error"; exit_code="$rc"
    fi

    local finished_iso t1 dur
    finished_iso="$(now_iso)"
    t1="$(now_ns)"
    dur=$(( (t1 - t0) / 1000000 ))

    python3 "$BUILD" --out-partial "$out_tmp" --out-final "$out_final" \
        --id-file "$wd/id" --id-literal "$safe" \
        --status "$status" --exit-code "$exit_code" --duration-ms "$dur" \
        --started "$started_iso" --finished "$finished_iso" \
        --stdout "$wd/stdout" --stderr "$wd/stderr" --cap "$OUTPUT_CAP_BYTES" \
        || note_error "build_result failed for $safe"
    finish "$status" "$exit_code"
    rm -rf "$wd" 2>/dev/null || true
    return 0
}

# Claim a validated inbox file and process it. The rename is the atomic claim;
# only the winner of the mv owns the request.
claim_and_process() {
    local f="$1" safe="$2"
    local done_path="$DONE/$safe.json"
    unset 'SEEN_SIG[$f]' 'SEEN_TS[$f]' 2>/dev/null || true
    if mv "$f" "$done_path" 2>/dev/null; then
        process_request "$done_path" "$safe"
    fi
}

# Scan inbox/, claim each pending request, process it (3.4). Because Verbinal
# PUTs directly to inbox/<id>.json with no rename, a file may be observed
# mid-upload -- so we never claim a file until it parses as a complete request
# (parse-or-skip). A file that stays unparseable AND byte-stable past the grace
# window is treated as genuinely malformed and claimed so it gets an error
# result rather than hanging the client.
claim_inbox() {
    local f base safe out_final sig now
    shopt -s nullglob
    for f in "$INBOX"/*.json; do
        # *.json.partial does not match *.json, but guard anyway.
        case "$f" in *.partial) continue ;; esac
        [ -e "$f" ] || continue
        base="$(basename "$f")"; base="${base%.json}"
        safe="$(sanitize "$base")"
        out_final="$OUT/$safe.json"
        if [ -e "$out_final" ]; then
            # Already resulted (2.6): never re-run; tidy the stray inbox copy.
            unset 'SEEN_SIG[$f]' 'SEEN_TS[$f]' 2>/dev/null || true
            mv -f "$f" "$DONE/$safe.json" 2>/dev/null || true
            continue
        fi

        if python3 "$PARSE" --check "$f" 2>/dev/null; then
            # Complete request (incl. unsupported language) -> claim now.
            claim_and_process "$f" "$safe"
            continue
        fi

        # Not parseable yet: still uploading, or malformed. Distinguish by
        # byte-stability over the grace window.
        sig="$(stat -c '%s:%Y' "$f" 2>/dev/null || echo '?:?')"
        now="$(now_s)"
        if [ "${SEEN_SIG[$f]:-}" != "$sig" ]; then
            # Changed (or first sighting): likely still arriving. Remember + skip.
            SEEN_SIG[$f]="$sig"
            SEEN_TS[$f]="$now"
            continue
        fi
        if [ $(( now - ${SEEN_TS[$f]:-$now} )) -ge "$STABLE_GRACE_SEC" ]; then
            # Unparseable and unchanged past the grace window -> malformed.
            log "claiming byte-stable unparseable request as malformed: $safe"
            claim_and_process "$f" "$safe"
        fi
        # else: stable but within grace -- wait another poll.
    done
    shopt -u nullglob
}

# Crash recovery (2.6): a request claimed into done/ but never resulted means
# we died mid-execution. Re-run anything in done/ that lacks an out/ result.
recover_done() {
    local f base safe
    shopt -s nullglob
    for f in "$DONE"/*.json; do
        case "$f" in *.partial) continue ;; esac
        base="$(basename "$f")"; base="${base%.json}"
        safe="$(sanitize "$base")"
        [ -e "$OUT/$safe.json" ] && continue
        log "recovering unfinished request on boot: $safe"
        process_request "$f" "$safe"
    done
    shopt -u nullglob
}

main() {
    # 2.1: the watcher is the source of truth for the tree; create it all.
    mkdir -p "$INBOX" "$OUT" "$DONE" 2>/dev/null || true

    STARTED_AT="$(now_iso)"
    STATE="idle"

    # On shutdown, best-effort publish state=exiting before the pod goes away.
    trap 'STATE=exiting; write_status 2>/dev/null; exit 0' TERM INT

    # Initial status: ready + idle, written once the tree exists and the loop is
    # about to run (4). Single writer (this process) -- no separate heartbeat.
    write_status
    log "watcher $WATCHER_VERSION started; home=$USER_HOME exec=$BASE poll=${POLL_INTERVAL_MS}ms pid=$$"

    # Re-run anything left in-flight by a previous instance, then poll forever.
    recover_done

    while true; do
        # Refresh the heartbeat every poll (gap = poll interval < the client's
        # 3x-poll staleness bound). Long requests keep it fresh from within
        # process_request, so the heartbeat never goes stale mid-execution.
        write_status
        # Catch *everything* so a single bad request can never break the loop.
        claim_inbox || note_error "claim_inbox returned non-zero (ignored)"
        sleep "$POLL_INTERVAL_SEC"
    done
}

main "$@"
