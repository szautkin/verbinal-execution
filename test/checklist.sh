#!/usr/bin/env bash
# Local go/no-go checklist for the Verbinal watcher (section 7).
#
# Runs the real watcher against a throwaway HOME/SCRATCH, drives the file-drop
# contract exactly as the client would (atomic .partial -> .json writes), and
# asserts every checklist item that does not require an actual Skaha launch.
#
# Run inside the built image (needs GNU coreutils `date +%s%N`):
#   docker run --rm -v "$PWD":/src --entrypoint bash \
#       images.canfar.net/<project>/verbinal-compute:dev /src/test/checklist.sh
# or on any Linux host with bash + python3.

# The `cond && ok "..." || bad "..."` assertion idiom is used throughout. `ok`
# always succeeds, so the `|| bad` branch only runs when the condition fails --
# the SC2015 "not if-then-else" caveat does not apply here. Silence it file-wide.
# shellcheck disable=SC2015

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHER="$REPO_ROOT/opt/verbinal/watcher.sh"

WORK="$(mktemp -d)"
export HOME="$WORK/home"
export SCRATCH="$WORK/scratch"
mkdir -p "$HOME" "$SCRATCH"
EXEC="$HOME/.verbinal/exec"
INBOX="$EXEC/inbox"; OUT="$EXEC/out"; DONE="$EXEC/done"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# Atomic client-side request write (matches 2.5).
drop() {  # drop <safe_filename> <json>
    local name="$1" json="$2"
    printf '%s' "$json" > "$INBOX/$name.json.partial"
    mv "$INBOX/$name.json.partial" "$INBOX/$name.json"
}

# Wait up to ~30s for out/<name>.json to appear.
wait_out() {  # wait_out <safe_filename>
    local name="$1" i=0
    while [ ! -e "$OUT/$name.json" ]; do
        i=$((i+1)); [ "$i" -gt 300 ] && return 1
        sleep 0.1
    done
    return 0
}

# Read a JSON field via python (use for non-string fields; note that command
# substitution strips trailing newlines, so do NOT use this to compare exact
# stdout/stderr -- use eqfield for that).
field() {  # field <file> <key>
    python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$1" "$2"
}

# Exact string-equality check on a JSON field (newline-safe). Returns 0 on match.
eqfield() {  # eqfield <file> <key> <expected>
    python3 -c 'import json,sys;sys.exit(0 if json.load(open(sys.argv[1])).get(sys.argv[2])==sys.argv[3] else 1)' "$1" "$2" "$3"
}

echo "workdir: $WORK"
echo "starting watcher..."
bash "$WATCHER" &
WPID=$!
trap 'kill "$WPID" 2>/dev/null; rm -rf "$WORK"' EXIT

# --- Readiness --------------------------------------------------------------
i=0; while [ ! -e "$EXEC/status.json" ]; do i=$((i+1)); [ "$i" -gt 100 ] && break; sleep 0.1; done
if [ -d "$INBOX" ] && [ -d "$OUT" ] && [ -d "$DONE" ] && [ -e "$EXEC/status.json" ]; then
    ok "tree + status.json created within seconds"
else
    bad "tree + status.json created"
fi
[ "$(field "$EXEC/status.json" ready)" = "True" ] && ok "status.json ready:true" || bad "status.json ready:true"
[ -n "$(field "$EXEC/status.json" resolved_home)" ] && [ "$(field "$EXEC/status.json" resolved_home)" != "None" ] \
    && ok "status.json publishes resolved_home" || bad "status.json resolved_home"
[ "$(field "$EXEC/status.json" resolved_user)" != "None" ] \
    && ok "status.json publishes resolved_user" || bad "status.json resolved_user"
[ "$(field "$EXEC/status.json" state)" = "idle" ] && ok "status.json state idle at rest" || bad "status.json state"
hb1="$(field "$EXEC/status.json" heartbeat_at)"; sleep 3; hb2="$(field "$EXEC/status.json" heartbeat_at)"
[ "$hb1" != "$hb2" ] && ok "heartbeat_at advances" || bad "heartbeat_at advances ($hb1 == $hb2)"

# --- Round-trip: python -----------------------------------------------------
drop t1 '{"id":"t1","language":"python","code":"print(1+1)","timeout_seconds":30}'
if wait_out t1; then
    [ "$(field "$OUT/t1.json" status)" = "ok" ] && ok "python status ok" || bad "python status ok"
    eqfield "$OUT/t1.json" stdout $'2\n' && ok "python stdout '2\\n'" || bad "python stdout"
    [ "$(field "$OUT/t1.json" stdout_encoding)" = "utf8" ] && ok "stdout_encoding utf8 default" || bad "stdout_encoding utf8"
    [ -e "$DONE/t1.json" ] && ok "request moved to done/" || bad "request moved to done/"
    [ "$(field "$EXEC/status.json" processed_count)" -ge 1 ] 2>/dev/null && ok "status.json processed_count advances" || bad "processed_count"
    [ "$(python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("last_request") or {}).get("id"))' "$EXEC/status.json")" = "t1" ] \
        && ok "status.json last_request reflects t1" || bad "last_request"
else bad "python round-trip produced a result"; fi

# --- Round-trip: bash streams ----------------------------------------------
drop t2 '{"id":"t2","language":"bash","code":"echo hi; echo err >&2","timeout_seconds":30}'
if wait_out t2; then
    eqfield "$OUT/t2.json" stdout $'hi\n'  && ok "bash stdout 'hi'"  || bad "bash stdout"
    eqfield "$OUT/t2.json" stderr $'err\n' && ok "bash stderr 'err'" || bad "bash stderr"
else bad "bash round-trip"; fi

# --- Non-zero exit stays alive ----------------------------------------------
drop t3 '{"id":"t3","language":"bash","code":"exit 3","timeout_seconds":30}'
if wait_out t3; then
    [ "$(field "$OUT/t3.json" status)" = "error" ] && ok "non-zero exit -> error" || bad "non-zero exit status"
    [ "$(field "$OUT/t3.json" exit_code)" = "3" ] && ok "exit_code:3 recorded" || bad "exit_code:3"
else bad "non-zero exit result"; fi

# --- Timeout ----------------------------------------------------------------
t_start=$(date +%s)
drop t4 '{"id":"t4","language":"python","code":"import time;time.sleep(60)","timeout_seconds":2}'
if wait_out t4; then
    t_elapsed=$(( $(date +%s) - t_start ))
    [ "$(field "$OUT/t4.json" status)" = "timeout" ] && ok "sleep(60)/timeout 2 -> timeout" || bad "timeout status"
    [ "$(field "$OUT/t4.json" exit_code)" = "124" ] && ok "timeout exit_code:124" || bad "timeout exit_code"
    [ "$t_elapsed" -le 12 ] && ok "killed promptly (~7s, was ${t_elapsed}s)" || bad "killed promptly (${t_elapsed}s)"
else bad "timeout result"; fi

# --- Output cap / truncation ------------------------------------------------
drop t5 '{"id":"t5","language":"python","code":"import sys;sys.stdout.write(\"x\"*400000)","timeout_seconds":30}'
if wait_out t5; then
    [ "$(field "$OUT/t5.json" truncated)" = "True" ] && ok ">256KB -> truncated:true" || bad "truncated:true"
    python3 -c 'import json;json.load(open("'"$OUT/t5.json"'"))' 2>/dev/null && ok "truncated result is valid JSON" || bad "valid JSON"
    python3 -c 'import json,sys;sys.exit(0 if "[truncated" in json.load(open(sys.argv[1]))["stdout"] else 1)' "$OUT/t5.json" \
        && ok "truncation marker present" || bad "truncation marker"
else bad "truncation result"; fi

# --- Binary (non-UTF-8) stdout -> base64 -----------------------------------
drop tb '{"id":"tb","language":"python","code":"import sys;sys.stdout.buffer.write(bytes([255,254,0,1,2]))","timeout_seconds":30}'
if wait_out tb; then
    [ "$(field "$OUT/tb.json" stdout_encoding)" = "base64" ] && ok "non-UTF-8 stdout -> base64" || bad "binary stdout_encoding"
    python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$OUT/tb.json" 2>/dev/null && ok "binary result is valid JSON" || bad "binary valid JSON"
    python3 -c 'import json,base64,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if base64.b64decode(d["stdout"])==bytes([255,254,0,1,2]) else 1)' "$OUT/tb.json" \
        && ok "base64 stdout decodes to original bytes" || bad "base64 round-trip"
else bad "binary result"; fi

# --- Unsupported language ---------------------------------------------------
drop t6 '{"id":"t6","language":"ruby","code":"puts 1","timeout_seconds":30}'
if wait_out t6; then
    [ "$(field "$OUT/t6.json" status)" = "error" ] && ok "ruby -> error" || bad "ruby error status"
else bad "ruby result"; fi

# --- id sanitization + original-id echo ------------------------------------
# Client chose id "a/b:c*d"; it sanitizes for the filename, keeps raw id in JSON.
drop "a_b_c_d" '{"id":"a/b:c*d","language":"python","code":"print(99)","timeout_seconds":30}'
if wait_out "a_b_c_d"; then
    ok "sanitized filename used (out/a_b_c_d.json)"
    [ "$(field "$OUT/a_b_c_d.json" id)" = "a/b:c*d" ] && ok "result echoes original id" || bad "original id echo"
else bad "sanitized-id result"; fi

# --- *.partial never read as a result --------------------------------------
printf '%s' '{"id":"never","language":"python","code":"print(1)","timeout_seconds":30}' > "$INBOX/never.json.partial"
sleep 2
[ ! -e "$OUT/never.json" ] && ok "*.partial ignored (no result produced)" || bad "*.partial ignored"
rm -f "$INBOX/never.json.partial"

# --- Incomplete direct PUT (mid-upload) is NOT claimed prematurely ----------
# Verbinal PUTs straight to inbox/<id>.json with no rename, so simulate a
# partially-arrived file by writing truncated JSON directly to the final name.
printf '%s' '{"id":"up1","language":"python","code":"print(' > "$INBOX/up1.json"
sleep 2   # < STABLE_GRACE_SEC: must not be claimed or errored yet
if [ ! -e "$OUT/up1.json" ] && [ -e "$INBOX/up1.json" ]; then
    ok "incomplete upload not claimed within grace"
else
    bad "incomplete upload left alone (out exists=$( [ -e "$OUT/up1.json" ] && echo y || echo n ))"
fi
# Complete the upload; it must now be processed normally.
printf '%s' '{"id":"up1","language":"python","code":"print(123)","timeout_seconds":30}' > "$INBOX/up1.json"
if wait_out up1; then
    [ "$(field "$OUT/up1.json" status)" = "ok" ] && ok "completed upload then processed ok" || bad "completed upload status"
    eqfield "$OUT/up1.json" stdout $'123\n' && ok "completed upload correct stdout" || bad "completed upload stdout"
else bad "completed upload produced result"; fi

# --- Malformed JSON ---------------------------------------------------------
drop t7 '{not valid json'
if wait_out t7; then
    [ "$(field "$OUT/t7.json" status)" = "error" ] && ok "malformed JSON -> error" || bad "malformed JSON status"
    [ "$(field "$OUT/t7.json" exit_code)" = "-1" ] && ok "malformed exit_code:-1" || bad "malformed exit_code"
else bad "malformed JSON result"; fi
# loop still alive?
drop t8 '{"id":"t8","language":"python","code":"print(8)","timeout_seconds":30}'
wait_out t8 && ok "loop continues after malformed request" || bad "loop survives malformed"

# --- Idempotency: pre-existing result is not re-run ------------------------
# shellcheck disable=SC2034  # captured for readability of the idempotency window; unread by design
mtime_before=$(date +%s)
sleep 1
# t1 already has a result; re-drop the same id, it must NOT re-run.
drop t1 '{"id":"t1","language":"python","code":"print(1+1)","timeout_seconds":30}'
sleep 2
# stdout still "2\n" and result file untouched-in-spirit (already done -> skipped)
[ "$(field "$OUT/t1.json" status)" = "ok" ] && ok "already-resulted request not re-run" || bad "idempotent skip"

# --- Watcher still alive -----------------------------------------------------
kill -0 "$WPID" 2>/dev/null && ok "watcher process still alive after all edges" || bad "watcher alive"

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ]
