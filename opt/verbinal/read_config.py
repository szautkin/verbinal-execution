#!/usr/bin/env python3
"""Resolve Verbinal watcher settings from the user's config file.

Usage: read_config.py <config_path> <user_home>

The config file is a single well-known JSON file on the user's /arc space
(default: $HOME/.verbinal/config.json). Everything this image needs lives under
the top-level "verbinal-execution" key, so the same file can also carry config
for other Verbinal components without collision:

    {
      "verbinal-execution": {
        "exec_dir": "/arc/home/<user>/.verbinal/exec",
        "poll_interval_ms": 1000,
        "output_cap_bytes": 262144,
        "timeout_ceiling_seconds": 900,
        "mem_fraction": 0.75
      }
    }

Every field is optional; a missing/unreadable/malformed file simply yields the
defaults below. This script NEVER fails -- it always prints a complete set of
shell `export` lines (shlex-quoted, safe to `eval`) and exits 0, so the watcher
always has a usable configuration.
"""

import json
import os
import shlex
import sys

# Defaults (also the documented behaviour when no config file is present).
DEFAULTS = {
    "poll_interval_ms": 1000,
    "output_cap_bytes": 262144,        # 256 KiB; client hard cap is 1 MiB
    "timeout_ceiling_seconds": 900,
    "mem_percent": 75,                 # cap address space at this % of session RAM
}

# Clamp ranges keep a hostile/typo'd config from producing degenerate settings.
CLAMPS = {
    "poll_interval_ms": (100, 60000),
    "output_cap_bytes": (1024, 1048576),
    "timeout_ceiling_seconds": (1, 3600),
    "mem_percent": (10, 95),
}


def clamp(name, val):
    lo, hi = CLAMPS[name]
    return max(lo, min(hi, val))


def as_int(val, default):
    if isinstance(val, bool) or not isinstance(val, int):
        return default
    return val


def main():
    config_path = sys.argv[1] if len(sys.argv) > 1 else ""
    user_home = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~")

    cfg = {}
    try:
        with open(config_path, "rb") as f:
            obj = json.loads(f.read().decode("utf-8"))
        if isinstance(obj, dict) and isinstance(obj.get("verbinal-execution"), dict):
            cfg = obj["verbinal-execution"]
    except Exception:
        cfg = {}  # missing / malformed -> defaults

    # exec_dir: where the inbox/out/done tree lives.
    exec_dir = cfg.get("exec_dir")
    if not isinstance(exec_dir, str) or exec_dir.strip() == "":
        exec_dir = os.path.join(user_home, ".verbinal", "exec")
    elif not os.path.isabs(exec_dir):
        exec_dir = os.path.join(user_home, exec_dir)

    poll_ms = clamp("poll_interval_ms",
                    as_int(cfg.get("poll_interval_ms"), DEFAULTS["poll_interval_ms"]))
    output_cap = clamp("output_cap_bytes",
                       as_int(cfg.get("output_cap_bytes"), DEFAULTS["output_cap_bytes"]))
    timeout_ceil = clamp("timeout_ceiling_seconds",
                         as_int(cfg.get("timeout_ceiling_seconds"),
                                DEFAULTS["timeout_ceiling_seconds"]))

    # mem_fraction is a float in (0,1]; convert to an integer percent.
    frac = cfg.get("mem_fraction")
    if isinstance(frac, bool) or not isinstance(frac, (int, float)):
        mem_percent = DEFAULTS["mem_percent"]
    else:
        mem_percent = clamp("mem_percent", int(round(frac * 100)))

    out = {
        "VERBINAL_EXEC_DIR": exec_dir,
        "VERBINAL_POLL_MS": str(poll_ms),
        "VERBINAL_OUTPUT_CAP": str(output_cap),
        "VERBINAL_TIMEOUT_CEIL": str(timeout_ceil),
        "VERBINAL_MEM_PERCENT": str(mem_percent),
    }
    for k, v in out.items():
        sys.stdout.write("export %s=%s\n" % (k, shlex.quote(v)))


if __name__ == "__main__":
    main()
