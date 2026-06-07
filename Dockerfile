# Verbinal compute watcher image for CANFAR/Skaha contributed sessions.
#
# Lean alternative to the multi-GB skaha/astroml base: a python:3.11-slim base
# carrying the star-ai-images science stack (see requirements.txt). Multi-stage
# so the build toolchain (compilers, -dev headers) lives only in the discarded
# builder; the runtime ships just the slim base + the installed venv.
#
# linux/amd64 only -- arm64 fails at pull on the Skaha pool. Build with:
#   docker buildx build --platform linux/amd64 ...
ARG BASE_IMAGE=python:3.11-slim-bookworm

# ---- builder: install the science stack into a self-contained venv ----------
FROM ${BASE_IMAGE} AS builder
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore
# Build deps for any package without a prebuilt wheel (notably fitsio -> cfitsio).
# Most of the stack ships manylinux wheels and won't touch these.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        gfortran \
        pkg-config \
        libcfitsio-dev \
        wcslib-dev \
        libbz2-dev \
        libffi-dev \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/*
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"
COPY requirements.txt /tmp/requirements.txt
RUN pip install --upgrade pip wheel setuptools && \
    pip install -r /tmp/requirements.txt

# ---- runtime: slim base + the venv, no toolchain ----------------------------
FROM ${BASE_IMAGE} AS runtime
# Shared libraries some extensions link at runtime (small). ca-certificates is
# needed for TLS by requests/astroquery/canfar. bash + coreutils (mktemp, mv,
# timeout, tr, printf, date, stat, whoami) are already present in the slim base.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libcfitsio10 \
        libgfortran5 \
        libgomp1 \
        libquadmath0 \
    && rm -rf /var/lib/apt/lists/*

# The venv becomes the default python3: agent-supplied code gets the full stack.
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# The watcher, its JSON/config helpers, and the liveness server. World-
# readable/executable so they work at whatever uid/gid Skaha assigns; the
# watcher only ever writes under the user's /arc home and /scratch, never /opt.
COPY opt/verbinal/ /opt/verbinal/
RUN chmod 0755 /opt/verbinal/watcher.sh \
               /opt/verbinal/parse_request.py \
               /opt/verbinal/build_result.py \
               /opt/verbinal/read_config.py \
               /opt/verbinal/status_writer.py \
               /opt/verbinal/health_server.py

# /skaha/startup.sh is the contributed-session launch contract.
RUN mkdir -p /skaha
COPY skaha/startup.sh /skaha/startup.sh
RUN chmod 0755 /skaha/startup.sh

# Register the contributed session type with Skaha/Harbor. Without this label,
# POST /v1/session?type=contributed returns HTTP 400.
LABEL ca.nrc.cadc.skaha.type="contributed" \
      ca.nrc.cadc.skaha.description="Verbinal file-drop code execution watcher"

# Contributed sessions are proxied as a web app on port 5000 (startup.sh /
# health_server.py). CMD is ignored by the platform; the launch mechanism is
# the ENTRYPOINT. No meaningful USER: Skaha overrides uid/gid from SSO.
EXPOSE 5000
ENTRYPOINT ["/skaha/startup.sh"]
