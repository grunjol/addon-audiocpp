#!/usr/bin/env bash
# audio.cpp Home Assistant add-on entrypoint.
#
# Downloads the selected model packages into /share/audiocpp/models (persistent
# across add-on updates), writes a server config and execs audiocpp_server.
set -euo pipefail

readonly OPTIONS_FILE="/data/options.json"
readonly MODELS_DIR="/share/audiocpp/models"
readonly SERVER_CONFIG="/data/server.json"
readonly HF_BASE="https://huggingface.co"
readonly HF_REPO="audio-cpp/audio.cpp-gguf"
readonly PORT="8099"

readonly APP_DIR="/app"
cd "$APP_DIR"

log() { printf '[audiocpp] %s\n' "$*"; }

opt() {
    # Empty option -> empty string (never the literal "null").
    jq -r --arg key "$1" '.[$key] // empty' "$OPTIONS_FILE" 2>/dev/null || true
}

if [[ ! -f "$OPTIONS_FILE" ]]; then
    log "ERROR: $OPTIONS_FILE not found, cannot start"
    exit 1
fi

BACKEND="$(opt backend)";              BACKEND="${BACKEND:-cpu}"
THREADS="$(opt threads)";              THREADS="${THREADS:-3}"
ASR_MODEL="$(opt asr_model)";          ASR_MODEL="${ASR_MODEL:-canary_180m_flash_q8_0}"
TTS_MODEL="$(opt tts_model)";          TTS_MODEL="${TTS_MODEL:-pocket_tts_spanish_q8_0}"
TTS_VOICE="$(opt tts_voice)";          TTS_VOICE="${TTS_VOICE:-}"
TTS_SPEED="$(opt tts_speed)";          TTS_SPEED="${TTS_SPEED:-1.0}"
MAX_LOADED="$(opt max_loaded_models)"; MAX_LOADED="${MAX_LOADED:-2}"
HF_TOKEN="$(opt hf_token)"

export HF_TOKEN
mkdir -p "$MODELS_DIR" /data

# ---------------------------------------------------------------- model table
# Package id -> "family|path inside the audio.cpp-gguf repo".
asr_spec=""
case "$ASR_MODEL" in
    canary_180m_flash_q8_0) asr_spec="canary_asr|Canary-180M-Flash-GGUF/canary-180m-flash-q8_0.gguf" ;;
    qwen3_asr_0_6b_q8_0)    asr_spec="qwen3_asr|Qwen3-ASR-0.6B-GGUF/qwen3-asr-0.6b-q8_0.gguf" ;;
    nemotron_asr_q8_0)      asr_spec="nemotron_asr|Nemotron-3.5-ASR-Streaming-0.6B-GGUF/nemotron-3.5-asr-streaming-0.6b-q8_0.gguf" ;;
    none)                   asr_spec="" ;;
    *) log "WARNING: unknown asr_model '$ASR_MODEL', speech-to-text disabled"; asr_spec="" ;;
esac

tts_spec=""; tts_lang=""
case "$TTS_MODEL" in
    pocket_tts_spanish_q8_0) tts_spec="pocket_tts|PocketTTS-GGUF/spanish/pocket-tts-spanish-q8_0.gguf"; tts_lang="spanish" ;;
    pocket_tts_english_q8_0) tts_spec="pocket_tts|PocketTTS-GGUF/english/pocket-tts-english-q8_0.gguf"; tts_lang="english" ;;
    kokoro_82m_q8_0)          tts_spec="kokoro_tts|Kokoro-82M-GGUF/kokoro-82m-q8_0.gguf"; tts_lang="" ;;
    none)                    tts_spec="" ;;
    *) log "WARNING: unknown tts_model '$TTS_MODEL', text-to-speech disabled"; tts_spec="" ;;
esac

# Families ship their own default voice; keep an explicit one if the user set it.
if [[ -z "$TTS_VOICE" ]]; then
    case "$TTS_MODEL" in
        kokoro_82m_q8_0)          TTS_VOICE="ef_dora" ;;
        pocket_tts_spanish_q8_0)  TTS_VOICE="rafael" ;;
        pocket_tts_english_q8_0)  TTS_VOICE="alba" ;;
    esac
fi

fetch() { # <path in HF repo> <local destination>
    local rel="$1" dest="$2"
    [[ -s "$dest" ]] && return 0
    mkdir -p "$(dirname "$dest")"
    log "downloading $rel"
    if [[ -n "$HF_TOKEN" ]]; then
        curl -fSL --retry 3 --connect-timeout 20 -H "Authorization: Bearer $HF_TOKEN" \
            -o "$dest.part" "$HF_BASE/$HF_REPO/resolve/main/$rel"
    else
        curl -fSL --retry 3 --connect-timeout 20 \
            -o "$dest.part" "$HF_BASE/$HF_REPO/resolve/main/$rel"
    fi
    mv "$dest.part" "$dest"
}

asr_family=""; asr_path=""
if [[ -n "$asr_spec" ]]; then
    asr_family="${asr_spec%%|*}"
    asr_path="$MODELS_DIR/${asr_spec#*|}"
    if fetch "${asr_spec#*|}" "$asr_path"; then
        log "speech-to-text ready: $ASR_MODEL ($asr_family)"
    else
        log "WARNING: could not download $ASR_MODEL, speech-to-text disabled"
        asr_family=""; asr_path=""
    fi
fi

tts_family=""; tts_path=""
if [[ -n "$tts_spec" ]]; then
    tts_family="${tts_spec%%|*}"
    tts_path="$MODELS_DIR/$(dirname "${tts_spec#*|}")"
    # kokoro loads the single GGUF file; pocket_tts loads the package directory
    [[ "$tts_family" == "kokoro_tts" ]] && tts_path="$MODELS_DIR/${tts_spec#*|}"
    if fetch "${tts_spec#*|}" "$MODELS_DIR/${tts_spec#*|}"; then
        log "text-to-speech ready: $TTS_MODEL ($tts_family)"
        # A voice left over from another family must not be passed through.
        if [[ "$tts_family" == "kokoro_tts" && ! "$TTS_VOICE" =~ ^(ef|em)_ ]]; then
            log "voice '$TTS_VOICE' is not a kokoro voice, using ef_dora"
            TTS_VOICE="ef_dora"
        fi
        # Only pocket_tts needs a voice embedding file: kokoro ships its voice packs
        # inside the GGUF and selects them by voice id.
        if [[ "$tts_family" == "pocket_tts" && -n "$TTS_VOICE" ]]; then
            if fetch "PocketTTS-GGUF/$tts_lang/embeddings/$TTS_VOICE.safetensors" \
                     "$tts_path/embeddings/$TTS_VOICE.safetensors"; then
                log "voice ready: $TTS_VOICE"
            else
                log "WARNING: voice '$TTS_VOICE' not available for $tts_lang, using the model default"
                TTS_VOICE=""
            fi
        fi
    else
        log "WARNING: could not download $TTS_MODEL, text-to-speech disabled"
        tts_family=""; tts_path=""
    fi
fi

# ---------------------------------------------------------------- gpu devices
if [[ -d /dev/dri ]]; then
    log "GPU devices: $(ls -1 /dev/dri 2>/dev/null | tr '\n' ' ')"
    if [[ -e /dev/dri/renderD128 ]]; then
        if head -c 0 /dev/dri/renderD128 2>/dev/null; then
            log "renderD128 is readable"
        else
            log "WARNING: renderD128 exists but cannot be opened"
        fi
    fi
else
    log "no /dev/dri inside the container"
fi

# --------------------------------------------------------------- gpu backend
if [[ "$BACKEND" == "vulkan" ]]; then
    if [[ ! -e /dev/dri/renderD128 ]]; then
        log "WARNING: /dev/dri/renderD128 is not available, falling back to CPU"
        BACKEND="cpu"
    elif ! ./audiocpp_cli --list-devices --backend vulkan 2>/dev/null | grep -qE 'Vulkan[0-9]*:0'; then
        log "WARNING: no usable Vulkan device found, falling back to CPU"
        BACKEND="cpu"
    else
        log "Vulkan device detected: $(./audiocpp_cli --list-devices --backend vulkan 2>/dev/null | grep -E 'Vulkan[0-9]*:0' | head -1)"
    fi
fi

# ------------------------------------------------------------- server config
jq -n \
    --arg backend "$BACKEND" \
    --argjson threads "$THREADS" \
    --argjson max_loaded "$MAX_LOADED" \
    --arg asr_family "$asr_family" \
    --arg asr_path "$asr_path" \
    --arg tts_family "$tts_family" \
    --arg tts_path "$tts_path" \
    --arg tts_voice "$TTS_VOICE" \
    --argjson tts_speed "$TTS_SPEED" \
    '{
        host: "0.0.0.0",
        port: 8099,
        backend: $backend,
        threads: $threads,
        lazy_load: true,
        max_loaded_models: $max_loaded,
        models: [
            (if $asr_path == "" then empty else {
                id: "asr", family: $asr_family, path: $asr_path,
                task: "asr", mode: "offline"
            } end),
            (if $tts_path == "" then empty else (
                {id: "tts", family: $tts_family, path: $tts_path, task: "tts", mode: "streaming"}
                + (if $tts_voice == "" then {} else {default_voice_preset: {voice_id: $tts_voice}} end)
                + (if $tts_family == "kokoro_tts"
                   then {default_request_options: (
                       {language: "es"} + (if $tts_speed == 1 then {} else {speed: $tts_speed} end)
                   )}
                   else (if $tts_speed == 1 then {} else {default_request_options: {speed: $tts_speed}} end)
                   end)
            ) end)
        ]
    }' > "$SERVER_CONFIG"

log "server config: $(jq -c '{backend, threads, models: [.models[] | {id, family, mode}]}' "$SERVER_CONFIG")"
log "starting audiocpp_server on 0.0.0.0:$PORT (backend=$BACKEND, threads=$THREADS)"

exec ./audiocpp_server --config "$SERVER_CONFIG" --ui --ui-management
