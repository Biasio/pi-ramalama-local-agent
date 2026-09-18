# pi-dev/Dockerfile: image for the pi-agent service (compose.yaml).
# Node.js sandbox with pi-coding-agent installed globally, plus the
# toolchain it needs to act on a codebase. Tagged pi-sandbox-image; runs
# as a long-lived container (entrypoint "sleep infinity") that
# pi-ramalama execs into. Also runs python/session_json.py for sessions.
FROM node:24-bookworm-slim

ARG PI_CODING_AGENT_VERSION=latest

# build-essential already pulls gcc, g++ and make.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgl1 libglu1-mesa libosmesa6 \
        git curl python3 python3-pip ripgrep jq fd-find sqlite3 \
        build-essential cmake ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd

# Separate layer so bumping pi's version doesn't redo apt; the npm cache
# is deleted in the same layer that creates it.
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent@${PI_CODING_AGENT_VERSION} \
    && rm -rf /root/.npm

# Must come after every build-time npm/pip install.
ENV NPM_CONFIG_PREFIX=/opt/npm-global-runtime
ENV PATH="/opt/npm-global-runtime/bin:/root/.local/bin:${PATH}"

WORKDIR /workspace
