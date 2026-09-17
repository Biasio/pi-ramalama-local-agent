#!/bin/bash
# lib/session.sh — interactive/RPC session lifecycle.
#
# Router mode is now the ONLY serve path, for one model or many: a single
# 'ramalama serve' container, started with --runtime-args pointing
# --models-preset at conf/models-preset.ini (ramalama itself has no
# native --models-preset flag; this is the confirmed passthrough — see
# render_models_preset() in common.sh). The old per-model instance loop
# and its RAMALAMA_PIDS/NAMES/PORTS/MODEL_URIS/MODEL_NAMES bookkeeping
# arrays are gone: there is now exactly one router process per session,
# so a single ROUTER_PID/ROUTER_NAME/ROUTER_PORT is enough.
#
# Model-set resolution differs by entry point:
#   - start_env (interactive TUI):   select_models() — unchanged, still
#     lets the user pick one or more models from what's pulled locally.
#   - start_rpc / start_rpc_async:   DEFAULT_RPC_MODEL (now accepted as a
#     comma-separated list, not just one model) if set; otherwise a
#     warning is printed and ROUTER_MODELS falls back to every locally
#     available model, so the router still starts with zero explicit
#     selection — model choice can happen later at runtime via whatever
#     hits the router's OpenAI-compatible endpoint (e.g. the VSCode
#     extension), rather than blocking startup on a selection.
#
# ROUTER_NAME is fixed as "ramalama" (not "ramalama-router") to match the
# container name every pre-existing check in this file
# (stop_rpc/start_rpc/start_rpc_async) already looks for.
ROUTER_NAME="ramalama"
ROUTER_MODELS=()
ROUTER_PID=""
ROUTER_PORT=""

# Tears down the router, pi-agent, and this session's ephemeral artifacts.
# Only registered inside start_env, never globally, so it can't kill a
# persistent RPC environment as a side effect of an unrelated command.
cleanup() {
    echo -e "\n[System] Shutting down..."

    if [ -n "$ROUTER_PID" ] && kill -0 "$ROUTER_PID" 2>/dev/null; then
        echo "[Ramalama] Stopping PID $ROUTER_PID..."
        kill "$ROUTER_PID" || true
    fi

    echo "[Ramalama] Stopping container..."
    $ENGINE stop "$ROUTER_NAME" >/dev/null 2>&1 || true
    ramalama stop --all >/dev/null 2>&1 || true

    echo "[Compose] Stopping pi-agent..."
    cd "$DIR" && compose stop >/dev/null 2>&1 || true

    remove_session_artifacts
    exit 0
}

# Resolves a model URI to its bare name (scheme stripped) — the form
# MODEL_PARAMS is keyed by and render_models_preset()'s [section] names
# use. Kept as a standalone helper since pull_model()/benchmark() and the
# preset renderer all need the exact same stripping rule.
strip_model_scheme() {
    echo "$1" | sed -E 's|^[a-z]+://||'
}

# Launches the single router-mode 'ramalama serve' instance: no positional
# MODEL args (per-model config comes entirely from the rendered preset),
# --models-max defaulting to the number of models actually in the preset
# (0 falls through to ramalama's own "unlimited" default when
# ROUTER_MODELS is empty, which is the correct semantic for "serve
# whatever's local, unrestricted").
# Fixed container-side path the injected preset must land at. Any custom
# RAMALAMA_ENGINE_ARGS mount value MUST use this exact destination, since
# --runtime-args below points --models-preset at it unconditionally.
ROUTER_PRESET_CONTAINER_PATH="/mnt/preset/models-preset.ini"

# Launches the single router-mode 'ramalama serve' instance: no positional
# MODEL args (per-model config comes entirely from the rendered preset,
# when enabled), --models-max defaulting to the number of models actually
# in the preset (0 falls through to ramalama's own "unlimited" default
# when ROUTER_MODELS is empty, which is the correct semantic for "serve
# whatever's local, unrestricted").
#
# Per-model MODEL_PARAMS tuning in router mode requires getting the
# rendered preset file into the container via --engine-args, which is
# currently BROKEN in router mode in ramalama <= 0.24.0 (confirmed via
# --dryrun: the --engine-args value is silently dropped from the
# generated podman command) — fix merged upstream as
# containers/ramalama#2889 but not yet in a released version as of this
# writing. RAMALAMA_ENGINE_ARGS gates this entirely: empty (the default)
# skips rendering the preset and adding --engine-args/--runtime-args, so
# the router starts cleanly with plain auto-discovery (untuned) instead
# of failing on "preset file does not exist". Once a ramalama build with
# that fix is installed, setting RAMALAMA_ENGINE_ARGS in user.env.conf to
# a --mount value targeting ROUTER_PRESET_CONTAINER_PATH switches tuning
# back on with no code change needed here.
_serve_router() {
    local port="$1"

    local -a cmd=(nice -n 10)
    [ -n "${CPU_AFFINITY:-}" ] && cmd+=(taskset -c "$CPU_AFFINITY")

    cmd+=(ramalama serve --network ai-net --name "$ROUTER_NAME"
          --image "$RAMALAMA_IMAGE" --rag-image "$RAMALAMA_RAG_IMAGE"
          --models-max "${RAMALAMA_MODELS_MAX:-${#ROUTER_MODELS[@]}}")

    local IFS=','
    local pair
    for pair in $DEFAULT_RAMALAMA_ENV; do
        [ -n "$pair" ] && cmd+=(--env "$pair")
    done
    unset IFS

    if [ -n "${RAMALAMA_ENGINE_ARGS:-}" ]; then
        render_models_preset
        cmd+=(--engine-args "$RAMALAMA_ENGINE_ARGS"
              --runtime-args "--models-preset $ROUTER_PRESET_CONTAINER_PATH")
    else
        echo "[Router] RAMALAMA_ENGINE_ARGS is empty: serving with plain auto-discovery, no per-model tuning." >&2
        echo "[Router] Per-model MODEL_PARAMS need ramalama's router-mode engine-args fix (containers/ramalama#2889), not yet in a released version." >&2
    fi

    cmd+=(-p "$port")
    [ -n "${RAMALAMA_ADDITIONAL_ARGS:-}" ] && cmd+=($RAMALAMA_ADDITIONAL_ARGS)

    RAMALAMA_SERVE_LOG="$(mktemp -t "$(date +"%Y%m%d-%H%M%S")-${ROUTER_NAME}-XXXXXX.log")"
    "${cmd[@]}" >"$RAMALAMA_SERVE_LOG" 2>&1 &
}

# Waits for either the healthcheck to pass or the background 'ramalama
# serve' process (ROUTER_PID, set by the caller right after
# _serve_router) to die.
wait_for_ramalama() {
    local port="$1"
    local timeout="${2:-60}"
    local elapsed=0

    until curl -s -f "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1; do
        if [ -n "${ROUTER_PID:-}" ] && ! kill -0 "$ROUTER_PID" 2>/dev/null; then
            echo "[Error] 'ramalama serve' exited before becoming healthy. Last log lines:" >&2
            tail -n 40 "$RAMALAMA_SERVE_LOG" >&2 2>/dev/null
            echo "[Error] Full log: $RAMALAMA_SERVE_LOG" >&2
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "[Error] Timeout (${timeout}s) waiting for ramalama on port ${port}. Last log lines:" >&2
            tail -n 40 "$RAMALAMA_SERVE_LOG" >&2 2>/dev/null
            echo "[Error] Full log: $RAMALAMA_SERVE_LOG" >&2
            return 1
        fi
    done
    return 0
}

# Resolves ROUTER_MODELS for the RPC entry points (no interactive prompt
# available there): DEFAULT_RPC_MODEL as a comma-separated list if set,
# else every locally available model — with an explicit warning either
# way, never a silent fallback. A model in DEFAULT_RPC_MODEL that isn't
# actually pulled yet is dropped with its own warning rather than hard-
# failing the whole router: the remaining models still serve.
resolve_rpc_models() {
    ROUTER_MODELS=()

    if [ -z "${DEFAULT_RPC_MODEL:-}" ]; then
        echo "[Warning] DEFAULT_RPC_MODEL is not set in $CONFIG_FILE." >&2
        echo "          Starting the router with every locally available model instead." >&2
        echo "          A model can still be selected and loaded at runtime (e.g. from the VSCode extension)." >&2
        mapfile -t ROUTER_MODELS < <(ramalama list | awk 'NR>1 {print $1}')
        return 0
    fi

    mapfile -t PULLED < <(ramalama list | awk 'NR>1 {print $1}')
    local IFS=','
    local raw name
    for raw in $DEFAULT_RPC_MODEL; do
        unset IFS
        raw="$(echo "$raw" | xargs)"
        [ -z "$raw" ] && { local IFS=','; continue; }
        name="$(strip_model_scheme "$raw")"
        if printf '%s\n' "${PULLED[@]}" | grep -qxF "$name"; then
            ROUTER_MODELS+=("$name")
        else
            echo "[Warning] '$name' from DEFAULT_RPC_MODEL is not pulled locally, skipping it." >&2
            echo "          Pull it with: $DIR/pi-ramalama --pull $raw" >&2
        fi
        local IFS=','
    done
    unset IFS

    if [ "${#ROUTER_MODELS[@]}" -eq 0 ]; then
        echo "[Warning] None of DEFAULT_RPC_MODEL's entries are pulled locally." >&2
        echo "          Starting the router with every locally available model instead." >&2
        mapfile -t ROUTER_MODELS < <(ramalama list | awk 'NR>1 {print $1}')
    fi
}

# Non-interactive: loads every locally pulled model through the router,
# expose it to pi-agent via a session-only shadow models.json, attach in
# TUI. Tears everything down together on exit. No prompt — router mode's
# on-demand loading means registering every local model costs nothing at
# startup; nothing actually loads into RAM until a request names it.
start_env() {
    trap cleanup EXIT SIGINT SIGTERM SIGHUP

    bootstrap_config

    local -a SELECTED_MODEL_URIS
    mapfile -t SELECTED_MODEL_URIS < <(ramalama list | awk 'NR>1 {print $1}')
    if [ "${#SELECTED_MODEL_URIS[@]}" -eq 0 ]; then
        echo "[Error] No models found in RamaLama." >&2
        exit 1
    fi

    local PI_EXEC_CMD="pi $*"

    # Per-model bookkeeping check (benchmark-if-missing) still runs before
    # the preset is generated, exactly as before — MODEL_PARAMS has to be
    # populated first so render_models_preset() has something to read.
    local MODEL MODEL_NAME
    ROUTER_MODELS=()
    for MODEL in "${SELECTED_MODEL_URIS[@]}"; do
        MODEL_NAME="$(strip_model_scheme "$MODEL")"

        if [ -z "${MODEL_PARAMS[$MODEL_NAME]:-}" ]; then
            echo "[Notice] No MODEL_PARAMS entry for '$MODEL_NAME' in $CONFIG_FILE."
            read -p "[Benchmark] Run llama-optimus now (isolated container) before starting? [y/N]: " RUN_BENCH_NOW
            local SPECIFIC_PARAMS=""
            if [[ "$RUN_BENCH_NOW" =~ ^([yY][eE][sS]|[yY])$ ]]; then
                benchmark "$MODEL_NAME" && SPECIFIC_PARAMS="$LAST_BENCHMARK_PARAMS"
            fi
            if [ -z "$SPECIFIC_PARAMS" ]; then
                SPECIFIC_PARAMS="${DEFAULT_MODEL_PARAMS}"
                echo "[System] Applying unoptimized default params: $SPECIFIC_PARAMS"
            fi
            update_model_params "$MODEL_NAME" "$SPECIFIC_PARAMS"
        fi

        ROUTER_MODELS+=("$MODEL_NAME")
    done

    ROUTER_PORT="$(find_free_port "$MODEL_PORT")" || exit 1

    echo "[Start] Router -> ${ROUTER_MODELS[*]} (HTTP port: $ROUTER_PORT)"
    _serve_router "$ROUTER_PORT"
    ROUTER_PID="$!"

    echo "[Healthcheck] Waiting for $ROUTER_NAME, timeout ${RAMALAMA_HEALTHCHECK_TIMEOUT:-60}s... (log: $RAMALAMA_SERVE_LOG)"
    wait_for_ramalama "$ROUTER_PORT" "${RAMALAMA_HEALTHCHECK_TIMEOUT:-60}" || exit 1

    render_shadow_models_json || exit 1
    render_session_settings || exit 1
    render_session_override

    if [[ -x "${PI_RAMALAMA_HOOKS_DIR:-conf/hooks.d}/post-start" ]]; then
        "${PI_RAMALAMA_HOOKS_DIR:-conf/hooks.d}/post-start"
    fi

    ensure_pi_agent_removed
    echo "[Compose] Starting pi-agent..."
    export PI_RPC_PORT
    cd "$DIR" && compose up -d pi-agent

    $ENGINE exec -it pi-agent $PI_EXEC_CMD
}

# Non-interactive counterpart to start_env, for the 'pi --mode rpc' host
# wrapper. Now router mode too — DEFAULT_RPC_MODEL may hold one model or a
# comma-separated several; resolve_rpc_models() also covers the
# unset/none-pulled case by falling back to every local model rather than
# hard-failing, since router mode can legitimately start with the model
# selected later at runtime. The environment stays up after this returns
# so later RPC calls can reuse it.
start_rpc() {
    bootstrap_config

    if curl -s -f "http://127.0.0.1:${MODEL_PORT}/v1/models" >/dev/null 2>&1 \
       && $ENGINE ps --format '{{.Names}}' 2>/dev/null | grep -qx pi-agent; then
        echo "[RPC] Environment already up."
        return 0
    fi

    resolve_rpc_models

    ROUTER_PORT="$MODEL_PORT"
    echo "[RPC][Start] Router -> ${ROUTER_MODELS[*]:-<none, auto>} (HTTP port: $ROUTER_PORT)"
    _serve_router "$ROUTER_PORT"
    ROUTER_PID=$!
    disown

    echo "[RPC] Log: $RAMALAMA_SERVE_LOG"
    wait_for_ramalama "$ROUTER_PORT" "${RAMALAMA_HEALTHCHECK_TIMEOUT:-60}" || exit 1

    if [[ -x "${PI_RAMALAMA_HOOKS_DIR:-conf/hooks.d}/post-start" ]]; then
        "${PI_RAMALAMA_HOOKS_DIR:-conf/hooks.d}/post-start"
    fi

    ensure_pi_agent_removed
    export PI_RPC_PORT
    cd "$DIR" && compose up -d pi-agent
    echo "[RPC] Environment ready."
}

# Fast, non-blocking bootstrap used by the 'pi --mode rpc' wrapper directly
# (all output redirected to stderr by the caller). Unlike start_rpc(), this
# does NOT wait for ramalama's healthcheck: Pi's RPC server attaches fine
# before a model is loaded and only needs one once a prompt is actually
# sent — this holds just as well for router mode, since the router itself
# comes up fast and loads individual models lazily on first request up to
# --models-max. Only the pi-agent container itself is waited on (seconds,
# not model-load time).
start_rpc_async() {
    bootstrap_config

    if ! $ENGINE ps --format '{{.Names}}' 2>/dev/null | grep -qx "$ROUTER_NAME"; then
        resolve_rpc_models
        ROUTER_PORT="$MODEL_PORT"
        echo "[RPC][Async] Starting router -> ${ROUTER_MODELS[*]:-<none, auto>} in the background (not waited on)..." >&2
        _serve_router "$ROUTER_PORT"
        disown
    fi

    # pi-agent itself must be reachable before Pi's RPC server can attach —
    # this is just container startup, so it's fine to wait on it.
    if ! $ENGINE ps --format '{{.Names}}' 2>/dev/null | grep -qx pi-agent; then
        ensure_pi_agent_removed
        export PI_RPC_PORT
        cd "$DIR" && compose up -d pi-agent

        local ELAPSED=0
        local TIMEOUT=15
        until $ENGINE ps --format '{{.Names}}' 2>/dev/null | grep -qx pi-agent; do
            sleep 1
            ELAPSED=$((ELAPSED + 1))
            if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
                echo "[Error] Container 'pi-agent' did not reach running state within ${TIMEOUT}s." >&2
                exit 1
            fi
        done
    fi
}

# Called by the 'pi --mode rpc' wrapper when its RPC session ends (VSCode
# closed, window reloaded, etc.). Waits RPC_STOP_GRACE_SECONDS, then stops
# the router and pi-agent only if no other 'pi --mode rpc' process is
# running inside the container — avoids tearing down on a quick reconnect.
stop_rpc() {
    resolve_ramalama || true

    sleep "${RPC_STOP_GRACE_SECONDS:-4}"

    if $ENGINE exec pi-agent pgrep -f "pi --mode rpc" >/dev/null 2>&1; then
        echo "[RPC] Another RPC session is active, not stopping." >&2
        return 0
    fi

    echo "[RPC] No active session left, stopping ramalama..." >&2
    ramalama stop --all >/dev/null 2>&1 || true
    echo "[RPC] Stopping pi-agent..." >&2
    cd "$DIR" && compose stop pi-agent >/dev/null 2>&1 || true
}
