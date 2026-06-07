#!/usr/bin/env bash
# Skaha contributed-session entrypoint for Verbinal compute.
#
# The CANFAR contributed-session contract is: a web app on port 5000, launched
# from /skaha/startup.sh. We honour it by running a tiny liveness server on
# :5000 (so the portal keeps the pod Running) alongside the real work process,
# the file-drop watcher. If EITHER dies we exit non-zero so the pod restarts.
#
# Skaha passes a session id as $1; we don't need it. Runs as the launching
# CANFAR user at an arbitrary uid -- never assume root, fall back off /arc.

set -u

VERBINAL_DIR="/opt/verbinal"
export VERBINAL_PORT="${VERBINAL_PORT:-5000}"

USER_HOME="${HOME:-/arc/home/$(whoami 2>/dev/null || id -un 2>/dev/null || id -u)}"
# Mirror the watcher's working-dir idiom: prefer the /arc home, fall back to /tmp.
cd "$USER_HOME" 2>/dev/null || cd /tmp || true

# Resolve config once so both processes agree on the exec dir, and so the health
# server can point at the right status.json. read_config.py always emits a
# complete, shell-safe set of exports (defaults when no config file exists).
CONFIG_PATH="${VERBINAL_CONFIG:-$USER_HOME/.verbinal/config.json}"
eval "$(python3 "$VERBINAL_DIR/read_config.py" "$CONFIG_PATH" "$USER_HOME" 2>/dev/null)"
export VERBINAL_EXEC_DIR VERBINAL_POLL_MS VERBINAL_OUTPUT_CAP \
       VERBINAL_TIMEOUT_CEIL VERBINAL_MEM_PERCENT
export VERBINAL_STATUS="${VERBINAL_EXEC_DIR:-$USER_HOME/.verbinal/exec}/status.json"

echo "verbinal-compute: starting (home=$USER_HOME exec=$VERBINAL_EXEC_DIR port=$VERBINAL_PORT)"

# Liveness web surface on :5000 (platform contract).
python3 "$VERBINAL_DIR/health_server.py" &
HEALTH_PID=$!

# The real work process: the never-exiting file-drop watcher.
bash "$VERBINAL_DIR/watcher.sh" &
WATCHER_PID=$!

# On termination, take both down together.
trap 'kill "$HEALTH_PID" "$WATCHER_PID" 2>/dev/null' EXIT TERM INT

# Hold the container open. If either process exits, fall through and fail so the
# pod is recreated rather than lingering half-dead.
wait -n "$HEALTH_PID" "$WATCHER_PID"
echo "verbinal-compute: a managed process exited; shutting down so the pod restarts" >&2
kill "$HEALTH_PID" "$WATCHER_PID" 2>/dev/null
exit 1
