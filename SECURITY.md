# Security

## Threat model

This image **executes arbitrary agent-supplied code as the launching CANFAR
user** — that is its purpose. The blast radius is exactly what that user could
do at a terminal: their own `/arc` space and whatever their CADC identity can
reach. The watcher grants **no** extra privilege and adds no attack surface
beyond that:

- **No inbound network / no listening work channel.** The only work channel is
  files under `/arc`. The single open port (`:5000`) is a read-only
  liveness/observability surface that performs no execution.
- **The request `id` is untrusted.** It is sanitized before any path use, never
  `eval`'d, and never interpolated into a shell string. Code is always staged to
  a file and the file is run.
- **Per-request limits.** Wall-clock timeout (`timeout --kill-after`), `ulimit`
  on CPU time and address space (a fraction of session RAM, so one request can't
  OOM-kill the pod), and output caps.
- **Never assumes root.** All writes are under the user's `/arc` home and
  `/scratch`; the image works at whatever uid/gid Skaha assigns.

## Reporting a vulnerability

Please report suspected vulnerabilities privately to the maintainers rather than
opening a public issue. Include a description, affected version/tag, and a
reproduction if possible.
