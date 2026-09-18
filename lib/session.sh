#!/bin/bash
# lib/session.sh: router-mode serving and session lifecycle.
#
# One 'ramalama serve' router (container name "ramalama") per session.
#   start_env:        every locally pulled model, TUI, torn down on exit.
#   start_rpc(_async): DEFAULT_RPC_MODEL (comma list) or every local model,
#                     stays up for later RPC calls; stop_rpc tears it down.
ROUTER_NAME="ramalama"
ROUTER_MODELS=()
ROUTER_PID=""
ROUTER_PORT=""
SESSION_DIR=""
# Fixed container path; a custom RAMALAMA_ENGINE_ARGS mount MUST target it.
ROUTER_PRESET_CONTAINER_PATH="/mnt/preset/models-preset.ini"

# Router model id for a bare model name: "<scheme>-<name with / and : as ->".
# Confirmed live for unprefixed pulls ("huggingface-"); ROUTER_MODELS is
# always scheme-stripped, so the scheme branch is unverified/unused.
router_model_id() {
    local raw="$1" scheme="huggingface"
    [[ "$raw" =~ ^([a-z]+)://(.*)$ ]] && { scheme="${BASH_REMATCH[1]}"; raw="${BASH_REMATCH[2]}"; }
    raw="${raw//\//-}"
    echo "${scheme}-${raw//:/-}"
}

# conf/models-preset.ini: one [section] per model, named after its router
# id so it overrides the auto-discovered entry. LLAMA_ARG_* keys are
# accepted verbatim by --models-preset; KEY=VALUE becomes KEY = VALUE.
# DEFAULT_RAMALAMA_ENV stays on --env (it mixes non-llama.cpp vars).
render_models_preset() {
    local out="$DIR/conf/models-preset.ini" model pair pairs
    {
        echo "version = 1"
        for model in "${ROUTER_MODELS[@]}"; do
            printf '\n[%s]\n' "$(router_model_id "$model")"
            IFS=',' read -ra pairs <<< "${MODEL_PARAMS[$model]:-$DEFAULT_MODEL_PARAMS}"
            for pair in "${pairs[@]}"; do [ -n "$pair" ] && echo "${pair/=/ = }"; done
        done
    } > "$out"
    echo "[Router] Preset written -> $out (${#ROUTER_MODELS[@]} model section(s))"
}

# Starts the router in the background; sets ROUTER_PID and RAMALAMA_SERVE_LOG.
# RAMALAMA_ENGINE_ARGS gates per-model tuning: router-mode --engine-args is
# dropped by ramalama <= 0.24.0 (fix: containers/ramalama#2889, unreleased).
serve_router() {
    local -a cmd=(nice -n 10) env_pairs
    [ -n "${CPU_AFFINITY:-}" ] && cmd+=(taskset -c "$CPU_AFFINITY")
    cmd+=(ramalama serve --network ai-net --name "$ROUTER_NAME"
          --image "$RAMALAMA_IMAGE" --rag-image "$RAMALAMA_RAG_IMAGE"
          --models-max "${RAMALAMA_MODELS_MAX:-${#ROUTER_MODELS[@]}}")

    local pair
    IFS=',' read -ra env_pairs <<< "${DEFAULT_RAMALAMA_ENV:-}"
    for pair in "${env_pairs[@]}"; do [ -n "$pair" ] && cmd+=(--env "$pair"); done

    if [ -n "${RAMALAMA_ENGINE_ARGS:-}" ]; then
        render_models_preset
        cmd+=(--engine-args "$RAMALAMA_ENGINE_ARGS"
              --runtime-args "--models-preset $ROUTER_PRESET_CONTAINER_PATH")
    else
        echo "[Router] RAMALAMA_ENGINE_ARGS is empty: plain auto-discovery, no per-model tuning (needs containers/ramalama#2889)." >&2
    fi

    cmd+=(-p "$ROUTER_PORT")
    # shellcheck disable=SC2206  # word splitting intended
    [ -n "${RAMALAMA_ADDITIONAL_ARGS:-}" ] && cmd+=($RAMALAMA_ADDITIONAL_ARGS)

    RAMALAMA_SERVE_LOG="$(mktemp -t "$(date +%Y%m%d-%H%M%S)-${ROUTER_NAME}-XXXXXX.log")"
    "${cmd[@]}" >"$RAMALAMA_SERVE_LOG" 2>&1 &
    ROUTER_PID=$!
}

# Waits until /v1/models answers, the router process dies, or timeout.
wait_for_router() {
    local timeout="${RAMALAMA_HEALTHCHECK_TIMEOUT:-60}" i reason=""
    echo "[Healthcheck] Waiting for $ROUTER_NAME on port $ROUTER_PORT, timeout ${timeout}s (log: $RAMALAMA_SERVE_LOG)" >&2
    for ((i = 0; i < timeout; i++)); do
        http_ok "$ROUTER_PORT" /v1/models && return 0
        kill -0 "$ROUTER_PID" 2>/dev/null || { reason="'ramalama serve' exited before becoming healthy"; break; }
        sleep 1
    done
    echo "[Error] ${reason:-Timeout (${timeout}s) waiting for ramalama on port $ROUTER_PORT}. Last log lines:" >&2
    tail -n 40 "$RAMALAMA_SERVE_LOG" >&2 2>/dev/null
    echo "[Error] Full log: $RAMALAMA_SERVE_LOG" >&2
    return 1
}

# ROUTER_MODELS for RPC: DEFAULT_RPC_MODEL entries that are pulled, else
# every local model (with a warning, never a silent fallback).
resolve_rpc_models() {
    local pulled raw name entries
    ROUTER_MODELS=()
    mapfile -t pulled < <(list_models)
    IFS=',' read -ra entries <<< "${DEFAULT_RPC_MODEL:-}"
    for raw in "${entries[@]}"; do
        raw="$(trim "$raw")"; [ -z "$raw" ] && continue
        name="$(strip_scheme "$raw")"
        if printf '%s\n' "${pulled[@]}" | grep -qxF "$name"; then
            ROUTER_MODELS+=("$name")
        else
            echo "[Warning] '$name' from DEFAULT_RPC_MODEL is not pulled locally, skipping it. Pull it with: pi-ramalama --pull $raw" >&2
        fi
    done
    if [ "${#ROUTER_MODELS[@]}" -eq 0 ]; then
        echo "[Warning] DEFAULT_RPC_MODEL is unset or none of its entries are pulled: serving every local model." >&2
        echo "          A model can still be selected at runtime (e.g. from the VSCode extension)." >&2
        ROUTER_MODELS=("${pulled[@]}")
    fi
}

# Shadow models.json (router provider added) and project settings.json
# (defaultModel pinned), built in ONE pi-sandbox-image run by
# python/session_json.py, mounted read-only over the real files for this
# session only via compose.session.override.yaml. Real files never touched.
render_session_files() {
    SESSION_DIR="$(mktemp -d -t pi-ramalama-session-XXXXXX)" || return 1
    local real_models="$HOME/.pi/agent/models.json" real_settings="$PI_RAMALAMA_WD/.pi/settings.json" m
    local -a mounts=(-v "$SESSION_DIR:/work:Z" -v "$DIR/python:/py:ro,Z") args=()
    [ -f "$real_models" ]   && mounts+=(-v "$real_models:/base/models.json:ro,Z")
    [ -f "$real_settings" ] && mounts+=(-v "$real_settings:/base/settings.json:ro,Z")
    for m in "${ROUTER_MODELS[@]}"; do args+=("$(router_model_id "$m")" "$m"); done

    $ENGINE run --rm "${mounts[@]}" --entrypoint python3 pi-sandbox-image /py/session_json.py \
        "session-$ROUTER_NAME" "http://$ROUTER_NAME:$ROUTER_PORT/v1" "${args[@]}" \
        || { echo "[Error] Failed to build shadow models.json/settings.json." >&2; return 1; }

    {
        echo "# Auto-generated per-session by pi-ramalama. Ephemeral, do not edit or commit."
        printf 'services:\n  pi-agent:\n    volumes:\n'
        echo "      - $SESSION_DIR/models.json:/root/.pi/agent/models.json:ro,Z"
        [ -f "$SESSION_DIR/settings.json" ] && echo "      - $SESSION_DIR/settings.json:/workspace/.pi/settings.json:ro,Z"
    } > "$DIR/compose.session.override.yaml"
    echo "[Session] Shadow models.json/settings.json mounted (${#ROUTER_MODELS[@]} model(s)) from $SESSION_DIR"
}

# TUI teardown. Trapped only inside start_env, so it can never kill a
# persistent RPC environment from an unrelated command.
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
    compose stop >/dev/null 2>&1 || true
    rm -f "$DIR/compose.session.override.yaml"
    [ -n "$SESSION_DIR" ] && rm -rf "$SESSION_DIR"
    exit 0
}

# Interactive TUI: serves every local model (router loads on demand, so
# registering unused models is free), asks to benchmark models without
# MODEL_PARAMS, then attaches to pi-agent. Args are forwarded to 'pi'.
start_env() {
    trap cleanup EXIT SIGINT SIGTERM SIGHUP
    bootstrap_config

    local models m name
    mapfile -t models < <(list_models)
    [ "${#models[@]}" -eq 0 ] && { echo "[Error] No models found in RamaLama." >&2; exit 1; }

    ROUTER_MODELS=()
    for m in "${models[@]}"; do
        name="$(strip_scheme "$m")"
        if [ -z "${MODEL_PARAMS[$name]:-}" ]; then
            echo "[Notice] No MODEL_PARAMS entry for '$name' in $MODELS_CONFIG_FILE."
            ensure_model_params "$name"
        fi
        ROUTER_MODELS+=("$name")
    done

    ROUTER_PORT="$(find_free_port "$MODEL_PORT")" || exit 1
    echo "[Start] Router -> ${ROUTER_MODELS[*]} (HTTP port: $ROUTER_PORT)"
    serve_router
    wait_for_router || exit 1
    render_session_files || exit 1
    run_post_start_hook
    start_pi_agent
    $ENGINE exec -it pi-agent pi "$@"
}

# Blocking RPC bootstrap: waits for the router to be healthy.
start_rpc() {
    bootstrap_config
    if http_ok "$MODEL_PORT" /v1/models && is_running pi-agent; then
        echo "[RPC] Environment already up."
        return 0
    fi
    resolve_rpc_models
    ROUTER_PORT="$MODEL_PORT"
    echo "[RPC][Start] Router -> ${ROUTER_MODELS[*]:-<none, auto>} (HTTP port: $ROUTER_PORT)"
    serve_router
    disown
    wait_for_router || exit 1
    run_post_start_hook
    start_pi_agent
    echo "[RPC] Environment ready."
}

# Non-blocking RPC bootstrap for 'pi --mode rpc': does not wait for the
# model (pi's RPC server attaches before one is loaded), only for pi-agent.
start_rpc_async() {
    bootstrap_config
    if ! is_running "$ROUTER_NAME"; then
        resolve_rpc_models
        ROUTER_PORT="$MODEL_PORT"
        echo "[RPC][Async] Starting router -> ${ROUTER_MODELS[*]:-<none, auto>} in the background (not waited on)..." >&2
        serve_router
        disown
    fi
    if ! is_running pi-agent; then
        start_pi_agent
        local i
        for ((i = 0; i < 15; i++)); do is_running pi-agent && return 0; sleep 1; done
        echo "[Error] Container 'pi-agent' did not reach running state within 15s." >&2
        exit 1
    fi
}

# Called by the pi wrapper when an RPC session ends: after a grace period,
# stops everything unless another 'pi --mode rpc' is still running.
stop_rpc() {
    resolve_ramalama || true
    sleep "${RPC_STOP_GRACE_SECONDS:-4}"
    if $ENGINE exec pi-agent pgrep -f "pi --mode rpc" >/dev/null 2>&1; then
        echo "[RPC] Another RPC session is active, not stopping." >&2
        return 0
    fi
    echo "[RPC] No active session left, stopping ramalama and pi-agent..." >&2
    ramalama stop --all >/dev/null 2>&1 || true
    compose stop pi-agent >/dev/null 2>&1 || true
}
