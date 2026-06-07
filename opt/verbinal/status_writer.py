#!/usr/bin/env python3
"""Compose and atomically publish the watcher's status.json.

Built with json.dumps so the file is always valid JSON even when fields carry
untrusted/awkward data (e.g. the current request id, a resolved username for an
unmapped uid, an error message). The watcher calls this on every poll and
periodically while a request runs, so status.json doubles as a live activity
record that the :5000 health server reflects.
"""

import argparse
import json
import os
import sys


def nonempty(v):
    return v if (v is not None and v != "") else None


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--pid", type=int, required=True)
    p.add_argument("--poll", type=int, required=True)
    p.add_argument("--home", default="")
    p.add_argument("--user", default="")
    p.add_argument("--started", default="")
    p.add_argument("--heartbeat", default="")
    p.add_argument("--state", default="idle")        # idle | processing | exiting
    p.add_argument("--processed", type=int, default=0)
    # current request (only while state == processing)
    p.add_argument("--current-id", default="")
    p.add_argument("--current-language", default="")
    p.add_argument("--current-started", default="")
    # most recently completed request
    p.add_argument("--last-id", default="")
    p.add_argument("--last-status", default="")
    p.add_argument("--last-exit", default="")
    p.add_argument("--last-finished", default="")
    # last watcher-internal error (not user-code errors -- those are results)
    p.add_argument("--error-msg", default="")
    p.add_argument("--error-at", default="")
    a = p.parse_args()

    current = None
    if nonempty(a.current_id) is not None:
        current = {
            "id": a.current_id,
            "language": nonempty(a.current_language),
            "started_at": nonempty(a.current_started),
        }

    last = None
    if nonempty(a.last_id) is not None:
        try:
            last_exit = int(a.last_exit)
        except (ValueError, TypeError):
            last_exit = None
        last = {
            "id": a.last_id,
            "status": nonempty(a.last_status),
            "exit_code": last_exit,
            "finished_at": nonempty(a.last_finished),
        }

    last_error = None
    if nonempty(a.error_msg) is not None:
        last_error = {"message": a.error_msg, "at": nonempty(a.error_at)}

    status = {
        "ready": True,
        "watcher_version": a.version,
        "pid": a.pid,
        "languages": ["python", "bash"],
        "poll_interval_ms": a.poll,
        "resolved_home": a.home,
        "resolved_user": a.user,
        "state": a.state,
        "processed_count": a.processed,
        "current": current,
        "last_request": last,
        "last_error": last_error,
        "heartbeat_at": a.heartbeat,
        "started_at": a.started,
    }

    tmp = a.out + ".partial"
    data = json.dumps(status, ensure_ascii=False)
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    if os.path.getsize(tmp) == 0:
        os.unlink(tmp)
        sys.exit(1)
    os.replace(tmp, a.out)


if __name__ == "__main__":
    main()
