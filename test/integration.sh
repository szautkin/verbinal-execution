#!/usr/bin/env bash
# Integration checks for the pieces the unit checklist doesn't cover:
#   - /skaha/startup.sh orchestration (health server + watcher together)
#   - the :5000 liveness web surface (platform contract)
#   - config-file relocation of the exec dir via the "verbinal-execution" key
#
# Run inside the built image:
#   docker run --rm -p 5000:5000 -v "$PWD":/src:ro --entrypoint bash \
#       <image> /src/test/integration.sh
# (a published image's ENTRYPOINT is already /skaha/startup.sh; here we invoke
# it explicitly so we can drive and assert against it).

set -u

WORK="$(mktemp -d)"
export HOME="$WORK/home"
export SCRATCH="$WORK/scratch"
mkdir -p "$HOME" "$SCRATCH"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# Relocate the exec dir somewhere non-default via the config file.
RELOC="$WORK/relocated/exec"
mkdir -p "$HOME/.verbinal"
cat > "$HOME/.verbinal/config.json" <<JSON
{ "verbinal-execution": { "exec_dir": "$RELOC", "poll_interval_ms": 500, "timeout_ceiling_seconds": 120 } }
JSON

EXEC="$RELOC"
INBOX="$EXEC/inbox"; OUT="$EXEC/out"

drop() {  # drop <safe_filename> <json>
    printf '%s' "$2" > "$INBOX/$1.json.partial"
    mv "$INBOX/$1.json.partial" "$INBOX/$1.json"
}
wait_out() { local i=0; while [ ! -e "$OUT/$1.json" ]; do i=$((i+1)); [ "$i" -gt 200 ] && return 1; sleep 0.1; done; }
field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$1" "$2"; }

echo "workdir: $WORK"
echo "launching /skaha/startup.sh ..."
bash /skaha/startup.sh test-session-id &
SPID=$!
trap 'kill "$SPID" 2>/dev/null; pkill -P "$SPID" 2>/dev/null; rm -rf "$WORK"' EXIT

# --- exec dir was relocated per config ----------------------------------
i=0; while [ ! -e "$EXEC/status.json" ]; do i=$((i+1)); [ "$i" -gt 100 ] && break; sleep 0.1; done
[ -d "$INBOX" ] && [ -e "$EXEC/status.json" ] && ok "config relocated exec dir to \$exec_dir" || bad "config relocation"
[ "$(field "$EXEC/status.json" poll_interval_ms)" = "500" ] && ok "config poll_interval_ms honoured (500)" || bad "config poll_interval_ms"

# --- :5000 liveness surface answers -------------------------------------
hc=""
for _ in $(seq 1 50); do
    hc="$(python3 -c 'import urllib.request,sys;\
sys.stdout.write(urllib.request.urlopen("http://127.0.0.1:5000/",timeout=2).read().decode())' 2>/dev/null)" && break
    sleep 0.2
done
if [ -n "$hc" ]; then
    ok "health server answers on :5000"
    python3 -c 'import json,sys;d=json.loads(sys.argv[1]);sys.exit(0 if d.get("service")=="verbinal-compute" else 1)' "$hc" \
        && ok "health body identifies verbinal-compute" || bad "health body shape"
    python3 -c 'import json,sys;d=json.loads(sys.argv[1]);sys.exit(0 if d.get("ready") is True else 1)' "$hc" \
        && ok "health reports ready:true (heartbeat fresh)" || bad "health ready:true"
else
    bad "health server answers on :5000"
fi

# --- round-trip still works through the relocated dir -------------------
drop r1 '{"id":"r1","language":"python","code":"print(6*7)","timeout_seconds":30}'
if wait_out r1; then
    [ "$(field "$OUT/r1.json" status)" = "ok" ] && ok "round-trip via relocated exec dir" || bad "relocated round-trip status"
else bad "relocated round-trip produced result"; fi

# --- :5000 reflects live execution state --------------------------------
hget() { python3 -c 'import urllib.request,sys;sys.stdout.write(urllib.request.urlopen("http://127.0.0.1:5000/",timeout=2).read().decode())' 2>/dev/null; }
# hfield <dotted.key> : read JSON from stdin, print the nested value (or None).
hfield() { python3 -c '
import json,sys
try: d=json.loads(sys.stdin.read())
except Exception: print("None"); sys.exit()
v=d
for k in sys.argv[1].split("."):
    v=v.get(k) if isinstance(v,dict) else None
print(v)' "$1" 2>/dev/null; }
drop slow1 '{"id":"slow1","language":"python","code":"import time;time.sleep(4);print(\"ok\")","timeout_seconds":30}'
# Poll the health endpoint until it reports processing slow1 (or give up).
saw_proc=""; saw_cur=""
for _ in $(seq 1 60); do
    h="$(hget)"; [ -z "$h" ] && { sleep 0.2; continue; }
    st="$(printf '%s' "$h" | hfield state)"
    cid="$(printf '%s' "$h" | hfield current.id)"
    [ "$st" = "processing" ] && saw_proc=1
    [ "$cid" = "slow1" ] && saw_cur=1
    [ -n "$saw_proc" ] && [ -n "$saw_cur" ] && break
    sleep 0.2
done
[ -n "$saw_proc" ] && ok "health reports state=processing during a request" || bad "health processing state"
[ -n "$saw_cur" ] && ok "health current.id names the running request (slow1)" || bad "health current.id"
if wait_out slow1; then
    sleep 1
    h="$(hget)"
    [ "$(printf '%s' "$h" | hfield state)" = "idle" ] && ok "health returns to state=idle after completion" || bad "health idle after"
    [ "$(printf '%s' "$h" | hfield last_request.id)" = "slow1" ] && ok "health last_request.id reflects slow1" || bad "health last_request"
else bad "slow request produced result"; fi

# --- :5000 reports installed packages (capability discovery) ------------
h="$(hget)"
pyv="$(printf '%s' "$h" | hfield python_version)"
case "$pyv" in 3.*) ok "health reports python_version ($pyv)" ;; *) bad "health python_version ($pyv)" ;; esac
# package_count is an int and matches the length of the packages array.
if printf '%s' "$h" | python3 -c 'import json,sys;d=json.loads(sys.stdin.read());p=d.get("packages");c=d.get("package_count");sys.exit(0 if isinstance(p,list) and c==len(p) and c>=1 else 1)' 2>/dev/null; then
    ok "health packages is a list, package_count matches ($(printf '%s' "$h" | hfield package_count))"
else
    bad "health packages/package_count shape"
fi
# Each entry has name+version.
if printf '%s' "$h" | python3 -c 'import json,sys;d=json.loads(sys.stdin.read());p=d["packages"];sys.exit(0 if all(("name" in e and "version" in e) for e in p) else 1)' 2>/dev/null; then
    ok "health package entries have name+version" || true
else bad "health package entry shape"; fi

# --- startup is still alive ---------------------------------------------
kill -0 "$SPID" 2>/dev/null && ok "startup.sh still supervising after traffic" || bad "startup.sh alive"

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ]
