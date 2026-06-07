#!/usr/bin/env python3
"""Minimal liveness web surface for the Skaha contributed-session contract.

Skaha treats a contributed session as a web app it proxies on port 5000, so
*something* must answer on that port or the portal marks the session failed.
The real work channel is the file-drop tree under /arc -- this server does no
execution; it only reports health so the platform keeps the pod Running.

Any GET returns 200 with a small JSON body. If the watcher's status.json is
readable (path via $VERBINAL_STATUS), its contents are reflected for convenience
and a 503 is returned when the heartbeat has gone stale, so the endpoint
doubles as a readiness probe. Binds 0.0.0.0:$VERBINAL_PORT (default 5000).
"""

import datetime
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("VERBINAL_PORT", "5000"))
STATUS_PATH = os.environ.get("VERBINAL_STATUS", "")
STALE_AFTER_SEC = 30  # heartbeat older than this -> report not-ready


def list_installed_packages():
    """Enumerate installed distributions (name+version) for this python -- the
    same interpreter agent code runs, so this is the authoritative list of what
    snippets can import. Computed once at startup; the set is fixed for the
    container's life."""
    try:
        import importlib.metadata as md
    except ImportError:
        return []
    seen = {}
    try:
        for dist in md.distributions():
            try:
                name = (dist.metadata["Name"] or "").strip()
            except Exception:
                name = ""
            if not name:
                continue
            seen[name.lower()] = {"name": name, "version": dist.version}
    except Exception:
        return []
    return [seen[k] for k in sorted(seen)]


# Static for the container's lifetime -> compute once, serve from cache.
INSTALLED_PACKAGES = list_installed_packages()
PACKAGE_COUNT = len(INSTALLED_PACKAGES)
PYTHON_VERSION = sys.version.split()[0]


def read_status():
    if not STATUS_PATH:
        return None
    try:
        with open(STATUS_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def heartbeat_fresh(status):
    hb = (status or {}).get("heartbeat_at")
    if not isinstance(hb, str):
        return False
    try:
        ts = datetime.datetime.strptime(hb, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
    except ValueError:
        return False
    age = (datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds()
    return age <= STALE_AFTER_SEC


class Handler(BaseHTTPRequestHandler):
    def _respond(self):
        status = read_status() or {}
        have = bool(status)
        ready = have and heartbeat_fresh(status)
        # Lift the live activity fields to the top level for convenience; keep
        # the full watcher status nested for anything not surfaced here.
        body = json.dumps({
            "service": "verbinal-compute",
            "ready": ready,
            "state": status.get("state") if have else "down",
            "processed_count": status.get("processed_count"),
            "current": status.get("current"),
            "last_request": status.get("last_request"),
            "last_error": status.get("last_error"),
            "heartbeat_at": status.get("heartbeat_at"),
            "started_at": status.get("started_at"),
            # Capability discovery: what agent code can import (static, cached).
            "python_version": PYTHON_VERSION,
            "package_count": PACKAGE_COUNT,
            "packages": INSTALLED_PACKAGES,
            "watcher_status": status or None,
        }).encode("utf-8")
        # 200 keeps the session alive; 503 signals not-yet-ready to probes.
        self.send_response(200 if ready or not have else 503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._respond()

    def do_HEAD(self):
        self._respond()

    def log_message(self, *args):
        pass  # silence per-request logging


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
