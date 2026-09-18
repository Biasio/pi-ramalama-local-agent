#!/bin/bash
# lib/common.sh: shared helpers used by every other module.
# Engine/compose detection, container/model queries, prompts, host
# dependency checks, HTTP healthcheck and port allocation (pure bash,
# no curl), ramalama resolution.

if command -v podman &>/dev/null; then
    ENGINE="podman"; COMPOSE_CMD="podman-compose"
else
    ENGINE="docker";  COMPOSE_CMD="docker compose"
fi

# Base compose.yaml plus whichever generated overrides exist.
compose() {
    local f files=(-f "$DIR/compose.yaml")
    for f in compose.mounts.override.yaml compose.session.override.yaml; do
        [ -f "$DIR/$f" ] && files+=(-f "$DIR/$f")
    done
    (cd "$DIR" && $COMPOSE_CMD "${files[@]}" "$@")
}

is_running() { $ENGINE ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

# Locally pulled models, one per line (first column of 'ramalama list').
list_models() { ramalama list | awk 'NR>1 {print $1}'; }

strip_scheme() { sed -E 's|^[a-z]+://||' <<< "$1"; }

# Strips '#' comments and surrounding whitespace (no xargs fork).
trim() {
    local s="${1%%#*}"
    s="${s#"${s%%[![:space:]]*}"}"
    echo "${s%"${s##*[![:space:]]}"}"
}

confirm() { local a; read -rp "$1 [y/N]: " a; [[ "$a" =~ ^([yY][eE][sS]|[yY])$ ]]; }

# pick "<prompt>" item...  -> prints the chosen item, fails on bad input.
pick() {
    local prompt="$1" i sel; shift
    for ((i = 1; i <= $#; i++)); do echo "  $i) ${!i}" >&2; done
    read -rp "$prompt" sel
    [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le $# ] || return 1
    echo "${!sel}"
}

# Makes 'ramalama' resolvable even when the caller (e.g. VSCode spawning
# the pi wrapper) doesn't inherit the interactive shell's PATH.
resolve_ramalama() {
    command -v ramalama >/dev/null 2>&1 && return 0
    local d
    for d in "${RAMALAMA_BIN_DIR:-}" "$HOME/.local/bin" "$HOME/.local/pipx/venvs/ramalama/bin" /usr/local/bin /usr/bin; do
        [ -n "$d" ] && [ -x "$d/ramalama" ] && { export PATH="$d:$PATH"; return 0; }
    done
    echo "[Error] 'ramalama' not found in PATH or common install locations." >&2
    echo "        Set RAMALAMA_BIN_DIR in env.conf to its install directory." >&2
    return 1
}

# Signals (does not install) missing host dependencies.
check_dependencies() {
    local missing=0
    if ! command -v podman &>/dev/null && ! command -v docker &>/dev/null; then
        echo "[Missing] No OCI engine found (podman or docker), e.g.: sudo apt install podman" >&2
        missing=1
    fi
    if ! resolve_ramalama 2>/dev/null; then
        echo "[Missing] 'ramalama' CLI not found. Install it: pipx install ramalama" >&2
        missing=1
    fi
    return $missing
}

bootstrap_config() {
    resolve_ramalama || exit 1
    [ "${1:-}" = "--no-env" ] || ensure_environment
    export MODEL_PORT="${MODEL_PORT:-8080}" PI_RPC_PORT
}

# True if GET http://127.0.0.1:$1$2 answers HTTP 200. Bash /dev/tcp, no curl.
http_ok() {
    (
        exec 3<>"/dev/tcp/127.0.0.1/$1" || exit 1
        printf 'GET %s HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n' "$2" >&3
        read -r -t 5 _ code _ <&3
        [ "$code" = "200" ]
    ) 2>/dev/null
}

port_is_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# find_free_port <base> [range=2000] [attempts=30]
find_free_port() {
    local base="$1" range="${2:-2000}" attempts="${3:-30}" i port
    for ((i = 0; i < attempts; i++)); do
        port=$((base + RANDOM % range))
        [ "$port" -ge 1024 ] && port_is_free "$port" && { echo "$port"; return 0; }
    done
    echo "[Error] No free port within ${range} of ${base} after ${attempts} attempts." >&2
    return 1
}

run_post_start_hook() {
    local hook="${PI_RAMALAMA_HOOKS_DIR:-$DIR/conf/hooks.d}/post-start"
    [ -x "$hook" ] && "$hook"
    return 0
}

# Starts pi-agent, first dropping a stale (exists but stopped) container
# so a leftover from a previous crash doesn't block 'compose up'.
start_pi_agent() {
    if ! is_running pi-agent && $ENGINE ps -a --format '{{.Names}}' 2>/dev/null | grep -qx pi-agent; then
        $ENGINE rm -f pi-agent >/dev/null 2>&1 || true
    fi
    echo "[Compose] Starting pi-agent..." >&2
    compose up -d pi-agent
}
