#!/usr/bin/env python3
"""Build a Verbinal result file and publish it atomically.

All untrusted data (the client id, captured stdout/stderr) flows in via file
paths, never the command line. JSON is produced with json.dumps so arbitrary
bytes in stdout/stderr can never yield malformed JSON (3.6).

Atomic publish (2.5): write <out-partial>, fsync, verify non-empty, then
os.replace() to <out-final> (atomic rename on POSIX / cavern).
"""

import argparse
import base64
import json
import os
import sys


def read_capped(path, cap):
    """Return (value, truncated, encoding).

    Tail-truncate to `cap` bytes, keeping the end (where tracebacks live). If
    the captured bytes are valid UTF-8, return them as a string with encoding
    "utf8" (json.dumps escapes control chars). Otherwise base64-encode the raw
    bytes and return encoding "base64" -- so non-UTF-8 binary output can never
    produce an unparseable result file (which would hang the client forever)."""
    if not path or path == "/dev/null":
        return "", False, "utf8"
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return "", False, "utf8"

    truncated = len(data) > cap
    dropped = len(data) - cap if truncated else 0
    tail = data[-cap:] if truncated else data

    # Decide encoding from the FULL bytes so a multibyte char split by tail
    # truncation doesn't misclassify otherwise-UTF-8 output as binary.
    try:
        data.decode("utf-8")
        is_utf8 = True
    except UnicodeDecodeError:
        is_utf8 = False

    if is_utf8:
        if truncated:
            # The tail may begin mid-codepoint; drop leading continuation bytes.
            i = 0
            while i < len(tail) and 0x80 <= tail[i] <= 0xBF:
                i += 1
            text = "...[truncated %d bytes]...\n" % dropped
            text += tail[i:].decode("utf-8", errors="replace")
        else:
            text = data.decode("utf-8")
        return text, truncated, "utf8"

    # Binary: base64 the (possibly truncated) tail; truncated flag conveys loss.
    return base64.b64encode(tail).decode("ascii"), truncated, "base64"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out-partial", required=True)
    p.add_argument("--out-final", required=True)
    p.add_argument("--id-file")
    p.add_argument("--id-literal", default="")
    p.add_argument("--status", required=True)
    p.add_argument("--exit-code", type=int, required=True)
    p.add_argument("--duration-ms", type=int, required=True)
    p.add_argument("--started", required=True)
    p.add_argument("--finished", required=True)
    p.add_argument("--stdout", required=True)
    p.add_argument("--stderr", required=True)
    p.add_argument("--cap", type=int, default=262144)
    a = p.parse_args()

    # Prefer the staged original id; fall back to the literal (e.g. SAFE_ID
    # when JSON was malformed and no id could be recovered).
    rid = a.id_literal or ""
    if a.id_file and os.path.exists(a.id_file):
        try:
            with open(a.id_file, "r", encoding="utf-8", errors="replace") as f:
                rid = f.read()
        except OSError:
            pass

    out, t_out, enc_out = read_capped(a.stdout, a.cap)
    err, t_err, enc_err = read_capped(a.stderr, a.cap)

    result = {
        "id": rid,
        "status": a.status,
        "exit_code": a.exit_code,
        "stdout": out,
        "stderr": err,
        "stdout_encoding": enc_out,
        "stderr_encoding": enc_err,
        "duration_ms": a.duration_ms,
        "truncated": bool(t_out or t_err),
        "started_at": a.started,
        "finished_at": a.finished,
    }

    data = json.dumps(result, ensure_ascii=False)
    with open(a.out_partial, "w", encoding="utf-8") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())

    # Never publish a 0-byte temp (2.5).
    if os.path.getsize(a.out_partial) == 0:
        sys.stderr.write("refusing to publish 0-byte result\n")
        try:
            os.unlink(a.out_partial)
        except OSError:
            pass
        sys.exit(1)

    os.replace(a.out_partial, a.out_final)


if __name__ == "__main__":
    main()
