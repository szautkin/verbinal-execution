#!/usr/bin/env python3
"""Parse/validate a Verbinal request file.

Two modes:

  parse_request.py --check <request_file>
      Structural completeness check ONLY -- used to decide whether an inbox
      file is fully uploaded and safe to claim. Verbinal's cavern/ARC layer has
      no rename op: it does a single HTTP PUT straight to inbox/<id>.json, so a
      file may be observed mid-upload. Exit 0 iff the file is complete JSON with
      all required fields of the right primitive type. Exit non-zero otherwise
      (still uploading, or genuinely malformed -- the watcher distinguishes
      those by file stability). NOTE: a complete request with an *unsupported*
      language passes --check (it is complete; it gets claimed and then errored).

  parse_request.py <request_file> <workdir>
      Full validation + staging. On success (exit 0) writes into <workdir>:
        id, lang ("python3"/"bash"), timeout (clamped), code.
      On failure prints a reason to stderr and exits:
        10 malformed/unreadable/empty JSON   11 invalid fields   12 bad language
      `id` is staged best-effort even on later failure, so error results can
      still echo the original id.
"""

import json
import os
import sys

LANG_MAP = {"python": "python3", "bash": "bash"}


def die(code, msg):
    sys.stderr.write(msg + "\n")
    sys.exit(code)


def load_obj(req_path):
    """Return (obj, error_code, error_msg). obj is None on failure."""
    try:
        with open(req_path, "rb") as f:
            raw = f.read()
    except OSError as e:
        return None, 10, "cannot read request: %s" % e
    if not raw.strip():
        return None, 10, "empty request file"
    try:
        obj = json.loads(raw.decode("utf-8"))
    except Exception as e:
        return None, 10, "malformed JSON: %s" % e
    if not isinstance(obj, dict):
        return None, 10, "request is not a JSON object"
    return obj, 0, ""


def structural_ok(obj):
    """True iff all required fields are present with the right primitive type.
    Does NOT check language support -- an unsupported language is still a
    structurally complete request (it gets claimed, then errored)."""
    rid = obj.get("id")
    if not isinstance(rid, str) or rid == "":
        return False
    if not isinstance(obj.get("language"), str):
        return False
    if not isinstance(obj.get("code"), str):
        return False
    to = obj.get("timeout_seconds")
    if isinstance(to, bool) or not isinstance(to, int):
        return False
    return True


def check_mode(req_path):
    obj, code, msg = load_obj(req_path)
    if obj is None or not structural_ok(obj):
        sys.exit(1)
    sys.exit(0)


def stage_mode(req_path, wd):
    obj, code, msg = load_obj(req_path)
    if obj is None:
        die(code, msg)

    # Stage the id first (best effort) so error results can echo it.
    rid = obj.get("id")
    if isinstance(rid, str) and rid != "":
        try:
            with open(os.path.join(wd, "id"), "w", encoding="utf-8") as f:
                f.write(rid)
        except OSError:
            pass

    if not isinstance(rid, str) or rid == "":
        die(11, "missing or invalid 'id' (must be a non-empty string)")
    if len(rid) > 128:
        die(11, "'id' exceeds 128 characters")

    lang = obj.get("language")
    if not isinstance(lang, str) or lang not in LANG_MAP:
        die(12, "unsupported language: %r (expected 'python' or 'bash')" % (lang,))

    code_str = obj.get("code")
    if not isinstance(code_str, str):
        die(11, "missing or invalid 'code' (must be a string)")

    # bool is a subclass of int -- reject it explicitly.
    to = obj.get("timeout_seconds")
    if isinstance(to, bool) or not isinstance(to, int):
        die(11, "missing or invalid 'timeout_seconds' (must be an integer)")
    if to < 1:
        to = 1
    if to > 900:
        to = 900

    # Unknown fields are ignored for forward-compatibility.
    try:
        with open(os.path.join(wd, "lang"), "w", encoding="utf-8") as f:
            f.write(LANG_MAP[lang])
        with open(os.path.join(wd, "timeout"), "w", encoding="utf-8") as f:
            f.write(str(to))
        with open(os.path.join(wd, "code"), "w", encoding="utf-8") as f:
            f.write(code_str)
    except OSError as e:
        die(11, "cannot stage request: %s" % e)

    sys.exit(0)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--check":
        check_mode(sys.argv[2])
    elif len(sys.argv) == 3:
        stage_mode(sys.argv[1], sys.argv[2])
    else:
        die(11, "usage: parse_request.py [--check] <request_file> [<workdir>]")


if __name__ == "__main__":
    main()
