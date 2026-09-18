#!/bin/bash
# lib/model.sh: model lifecycle (pull, benchmark, remove) and the
# MODEL_PARAMS bookkeeping in conf/models.conf.

drop_model_params() {
    awk -v t="MODEL_PARAMS[\"$1\"]" 'index($0, t) != 1' "$MODELS_CONFIG_FILE" > "$MODELS_CONFIG_FILE.tmp" \
        && mv "$MODELS_CONFIG_FILE.tmp" "$MODELS_CONFIG_FILE"
}

# Replaces (or appends) one MODEL_PARAMS entry, in the file and in memory.
update_model_params() {
    echo "[System] Updating $MODELS_CONFIG_FILE..."
    drop_model_params "$1"
    echo "MODEL_PARAMS[\"$1\"]=\"$2\"" >> "$MODELS_CONFIG_FILE"
    MODEL_PARAMS["$1"]="$2"
}

# Asks to benchmark $1; records benchmark params or DEFAULT_MODEL_PARAMS.
ensure_model_params() {
    local params=""
    confirm "[Benchmark] Run llama-optimus (isolated container)?" \
        && benchmark "$1" && params="$LAST_BENCHMARK_PARAMS"
    if [ -z "$params" ]; then
        params="$DEFAULT_MODEL_PARAMS"
        echo "[System] Applying unoptimized default params: $params"
    fi
    update_model_params "$1" "$params"
}

pull_model() {
    [ -n "$1" ] || { echo "[Error] Missing model URI. Usage: pi-ramalama --pull <model_uri>"; exit 1; }
    bootstrap_config --no-env
    echo "[Ramalama] Pulling $1..."
    ramalama pull "$1" || { echo "[Error] Pull failed."; exit 1; }
    ensure_model_params "$(strip_scheme "$1")"
}

remove_model() {
    bootstrap_config --no-env
    local models name
    mapfile -t models < <(list_models)
    [ ${#models[@]} -eq 0 ] && { echo "No models available."; exit 1; }
    name="$(pick "Select model to remove: " "${models[@]}")" || exit 1
    ramalama rm "$name" || true
    drop_model_params "$name"
}

# Finds the .gguf for model $1 under $HOME: one find pass, matching any
# .gguf whose path contains the model basename (layout differs by
# ramalama transport and install method). Prints the chosen path.
locate_gguf() {
    local needle="${1##*/}" matches p
    needle="${needle%%:*}"
    mapfile -t matches < <(find "$HOME" -xdev \
        \( -path '*/.cache/*' -o -path '*/.git/*' -o -path '*/node_modules/*' \) -prune -o \
        \( -type f -o -type l \) -iname '*.gguf' -ipath "*${needle}*" -print 2>/dev/null)

    case "${#matches[@]}" in
        0) echo "[Notice] No .gguf match for '$needle' under $HOME" >&2 ;;
        1) echo "[Benchmark] Found on host: ${matches[0]}" >&2
           read -rp "[Benchmark] Use this path? [Y/n]: " p
           [[ "$p" =~ ^([nN][oO]|[nN])$ ]] || { echo "${matches[0]}"; return; } ;;
        *) echo "[Notice] Multiple .gguf files found for '$needle' (e.g. different quantizations):" >&2
           pick "[Benchmark] Select one (empty to enter a path manually): " "${matches[@]}" && return ;;
    esac
    read -rp "[Benchmark] Actual model file path on host (empty to cancel): " p
    echo "$p"
}

# Runs llama-optimus and python/parse_benchmark.py in ONE container run:
# optimus output streams to the terminal (stderr), parsed params to stdout.
benchmark() {
    local name="$1" path
    path="$(locate_gguf "$name")"
    [ -n "$path" ] && [ -e "$path" ] || { echo "[Error] Model path not found on host: ${path:-<empty>}"; return 1; }

    if [[ "$path" == */snapshots/* ]]; then MODEL_DIR_HOST="${path%%/snapshots/*}"; else MODEL_DIR_HOST="$(dirname "$path")"; fi
    export MODEL_DIR_HOST MODEL_PATH_CONTAINER_DIR="/models"
    export MODEL_PATH_CONTAINER="/models${path#"$MODEL_DIR_HOST"}"

    echo "[Benchmark] Starting llama-optimus container..."
    LAST_BENCHMARK_PARAMS="$(compose --profile benchmark run --rm -T -e PYTHONUNBUFFERED=1 \
        -v "$DIR/python:/py:ro,Z" --entrypoint sh llama-optimus -c \
        'python3 optimus.py --model "$1" 2>&1 | tee /dev/stderr | python3 /py/parse_benchmark.py' \
        sh "$MODEL_PATH_CONTAINER")"

    [ -n "$LAST_BENCHMARK_PARAMS" ] || { echo "[Error] Parsing failed, no params extracted. Check the output above."; return 1; }
    echo "[Benchmark] Extracted params: $LAST_BENCHMARK_PARAMS"
    update_model_params "$name" "$LAST_BENCHMARK_PARAMS"
}

# --benchmark [model_uri]: by URI, or interactive pick.
benchmark_cli() {
    bootstrap_config
    local name models
    if [ -n "${1:-}" ]; then
        name="$(strip_scheme "$1")"
    else
        mapfile -t models < <(list_models)
        [ ${#models[@]} -eq 0 ] && { echo "[Error] No models available in RamaLama to benchmark."; exit 1; }
        echo "Models available for benchmarking:"
        name="$(pick "Select the model to analyze: " "${models[@]}")" || { echo "[Error] Invalid selection."; exit 1; }
    fi
    benchmark "$name"
}
