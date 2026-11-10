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

log() { printf '[audiocpp] %s\n' "$*" >&2; }

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
ASR_LANGUAGE="$(opt asr_language)";    ASR_LANGUAGE="${ASR_LANGUAGE:-es}"
ASR_PUNC="$(opt asr_punc)";            ASR_PUNC="${ASR_PUNC:-false}"
TTS_MODEL="$(opt tts_model)";          TTS_MODEL="${TTS_MODEL:-pocket_tts_spanish_q8_0}"
TTS_HQ_MODEL="$(opt tts_hq_model)";    TTS_HQ_MODEL="${TTS_HQ_MODEL:-none}"
TTS_VOICE="$(opt tts_voice)";          TTS_VOICE="${TTS_VOICE:-}"
TTS_VOICE_REF="$(opt tts_voice_ref)";  TTS_VOICE_REF="${TTS_VOICE_REF:-}"
TTS_VOICE_REF_TEXT="$(opt tts_voice_ref_text)"; TTS_VOICE_REF_TEXT="${TTS_VOICE_REF_TEXT:-}"
TTS_VOICE_PRESETS="$(opt tts_voice_presets)"
TTS_LANGUAGE="$(opt tts_language)";    TTS_LANGUAGE="${TTS_LANGUAGE:-es}"
TTS_SPEED="$(opt tts_speed)";          TTS_SPEED="${TTS_SPEED:-1.0}"
MAX_LOADED="$(opt max_loaded_models)"; MAX_LOADED="${MAX_LOADED:-2}"
HF_TOKEN="$(opt hf_token)"

export HF_TOKEN
mkdir -p "$MODELS_DIR" /data

# ---------------------------------------------------------------- model table
# Package id -> "family|path inside the audio.cpp-gguf repo|package language"
model_spec() {
    case "$1" in
        canary_180m_flash_q8_0)  echo "canary_asr|Canary-180M-Flash-GGUF/canary-180m-flash-q8_0.gguf|" ;;
        qwen3_asr_0_6b_q8_0)     echo "qwen3_asr|Qwen3-ASR-0.6B-GGUF/qwen3-asr-0.6b-q8_0.gguf|" ;;
        nemotron_asr_q8_0)       echo "nemotron_asr|Nemotron-3.5-ASR-Streaming-0.6B-GGUF/nemotron-3.5-asr-streaming-0.6b-q8_0.gguf|" ;;
        pocket_tts_spanish_q8_0) echo "pocket_tts|PocketTTS-GGUF/spanish/pocket-tts-spanish-q8_0.gguf|spanish" ;;
        pocket_tts_english_q8_0) echo "pocket_tts|PocketTTS-GGUF/english/pocket-tts-english-q8_0.gguf|english" ;;
        pocket_tts_spanish_bf16) echo "pocket_tts|PocketTTS-GGUF/spanish/pocket-tts-spanish-bf16.gguf|spanish" ;;
        moss_tts_nano_q8_0)    echo "moss_tts_nano|MOSS-TTS-Nano-100M-GGUF/moss-tts-nano-100m-q8_0.gguf|" ;;
        kokoro_82m_q8_0)         echo "kokoro_tts|Kokoro-82M-GGUF/kokoro-82m-q8_0.gguf|" ;;
        chatterbox_q8_0)         echo "chatterbox|Chatterbox-GGUF/chatterbox-q8_0.gguf|" ;;
        qwen3_tts_0_6b_q8_0)     echo "qwen3_tts|Qwen3-TTS-12Hz-0.6B-Base-GGUF/qwen3-tts-12hz-0.6b-base-q8_0.gguf|" ;;
        none)                    echo "none||" ;;
        *) return 1 ;;
    esac
}

fetch() { # <path in HF repo> <local destination>
    local rel="$1" dest="$2"
    [[ -s "$dest" ]] && return 0
    mkdir -p "$(dirname "$dest")"
    log "downloading $rel"
    if [[ -n "$HF_TOKEN" ]]; then
        curl -fSL --retry 3 --connect-timeout 20 -H "Authorization: Bearer ***" \
            -o "$dest.part" "$HF_BASE/$HF_REPO/resolve/main/$rel"
    else
        curl -fSL --retry 3 --connect-timeout 20 \
            -o "$dest.part" "$HF_BASE/$HF_REPO/resolve/main/$rel"
    fi
    mv "$dest.part" "$dest"
}

# Named voice presets -> {name: {voice_ref: path}}. The HA integration lists these
# from GET /v1/audio/voices, so every entry here becomes selectable in the UI.
voice_presets_json="{}"
if [[ -n "$TTS_VOICE_PRESETS" ]]; then
    while IFS= read -r line; do
        [[ -z "${line// }" || "$line" == \#* ]] && continue
        name="${line%%=*}"
        ref="${line#*=}"
        name="${name// /}"
        ref="${ref# }"
        ref="${ref% }"
        if [[ -z "$name" || -z "$ref" ]]; then
            continue
        fi
        if [[ -s "$ref" ]]; then
            voice_presets_json=$(jq -nc --argjson cur "$voice_presets_json" --arg n "$name" --arg p "$ref" \
                '$cur + {($n): {voice_ref: $p}}')
        else
            log "WARNING: voice preset '$name' points to a missing file: $ref"
        fi
    done <<< "$TTS_VOICE_PRESETS"
fi

# Emits one JSON model entry per call; log lines go to stderr.
asr_entry() {
    local spec family rel path opts
    if ! spec="$(model_spec "$ASR_MODEL")"; then
        log "WARNING: unknown asr_model '$ASR_MODEL', speech-to-text disabled"
        return 0
    fi
    IFS='|' read -r family rel _ <<<"$spec"
    [[ -z "$family" || "$family" == "none" ]] && return 0
    path="$MODELS_DIR/$rel"
    if ! fetch "$rel" "$path"; then
        log "WARNING: could not download $ASR_MODEL, speech-to-text disabled"
        return 0
    fi
    log "speech-to-text ready: $ASR_MODEL ($family)"
    # Canary with punctuation enabled drops some utterances entirely (empty
    # transcript); punc=false is reliable, and language pins the output language.
    if [[ "$family" == "canary_asr" ]]; then
        opts=$(jq -nc --arg lang "$ASR_LANGUAGE" --arg punc "$ASR_PUNC" \
            '{language: $lang, punc: ($punc == "true")}')
    else
        opts=$(jq -nc --arg lang "$ASR_LANGUAGE" '{language: $lang}')
    fi
    log "speech-to-text options: $opts"
    jq -nc --arg family "$family" --arg path "$path" --argjson opts "$opts" \
        '{id: "asr", family: $family, path: $path, task: "asr", mode: "offline"}
         + (if ($opts|length) == 0 then {} else {default_request_options: $opts} end)'
}

# tts_entry <model id> <server model id>
tts_entry() {
    local model="$1" sid="$2" spec family rel lang path mode="streaming"
    local preset="{}" opts="{}" voice="$TTS_VOICE"
    if ! spec="$(model_spec "$model")"; then
        log "WARNING: unknown tts model '$model' ($sid), skipped"
        return 0
    fi
    IFS='|' read -r family rel lang <<<"$spec"
    [[ -z "$family" || "$family" == "none" ]] && return 0

    path="$MODELS_DIR/$(dirname "$rel")"
    local mfile="$MODELS_DIR/$rel"
    # These families load the single GGUF file; pocket_tts loads a package dir.
    # PocketTTS refuses a directory holding more than one GGUF, so each package
    # (q8_0, bf16...) gets its own subdirectory with the file and its embeddings.
    case "$family" in
        kokoro_tts|chatterbox|qwen3_tts|moss_tts_nano) path="$MODELS_DIR/$rel" ;;
        pocket_tts)
            path="$MODELS_DIR/$(dirname "$rel")/$(basename "$rel" .gguf)"
            mfile="$path/$(basename "$rel")"
            ;;
    esac
    if ! fetch "$rel" "$mfile"; then
        log "WARNING: could not download $model ($sid), skipped"
        return 0
    fi
    log "text-to-speech ready: $model ($family, id=$sid)"

    case "$family" in
        kokoro_tts)
            if [[ ! "$voice" =~ ^(ef|em)_ ]]; then
                [[ -n "$voice" ]] && log "voice '$voice' is not a kokoro voice, using ef_dora"
                voice="ef_dora"
            fi
            preset=$(jq -nc --arg v "$voice" '{voice_id: $v}')
            opts=$(jq -nc --arg lang "$TTS_LANGUAGE" --argjson sp "$TTS_SPEED" \
                '{language: $lang} + (if $sp == 1 then {} else {speed: $sp} end)')
            mode="offline"
            ;;
        pocket_tts)
            # A reference clip wins over a preset embedding: it is the only way to
            # use a cloned voice as the model default.
            if [[ -n "$TTS_VOICE_REF" && -s "$TTS_VOICE_REF" ]]; then
                log "voice reference: $TTS_VOICE_REF"
                preset=$(jq -nc --arg r "$TTS_VOICE_REF" '{voice_ref: $r}')
            else
                if [[ -z "$voice" ]]; then
                    if [[ "$lang" == "spanish" ]]; then voice="rafael"; else voice="alba"; fi
                fi
                if fetch "PocketTTS-GGUF/$lang/embeddings/$voice.safetensors" \
                         "$path/embeddings/$voice.safetensors"; then
                    log "voice ready: $voice"
                    preset=$(jq -nc --arg v "$voice" '{voice_id: $v}')
                else
                    log "WARNING: voice '$voice' not available for $lang, using the model default"
                fi
            fi
            opts=$(jq -nc --argjson sp "$TTS_SPEED" 'if $sp == 1 then {} else {speed: $sp} end')
            ;;
        chatterbox|qwen3_tts|moss_tts_nano)
            if [[ -n "$TTS_VOICE_REF" && -s "$TTS_VOICE_REF" ]]; then
                log "voice reference: $TTS_VOICE_REF"
                preset=$(jq -nc --arg r "$TTS_VOICE_REF" '{voice_ref: $r}')
            else
                log "WARNING: $family clones from tts_voice_ref (a wav inside /share); none found, using the family default"
            fi
            # qwen3_tts clones in ICL mode and refuses to synthesise without the
            # transcript of the reference clip.
            # qwen3_tts and moss_tts_nano clone in ICL mode: they need the
            # transcript of the reference clip, not just the audio.
            local wants_text=""
            [[ "$family" == "qwen3_tts" || "$family" == "moss_tts_nano" ]] && wants_text="1"
            if [[ -n "$wants_text" && -n "$TTS_VOICE_REF_TEXT" ]]; then
                if [[ "$family" == "qwen3_tts" ]]; then
                    opts=$(jq -nc --arg lang "$TTS_LANGUAGE" --arg rt "$TTS_VOICE_REF_TEXT" \
                        '{language: $lang, reference_text: $rt}')
                else
                    opts=$(jq -nc --arg rt "$TTS_VOICE_REF_TEXT" '{reference_text: $rt}')
                fi
                log "voice reference text: ${#TTS_VOICE_REF_TEXT} characters"
            else
                if [[ -n "$wants_text" && -n "$TTS_VOICE_REF" ]]; then
                    log "WARNING: $family needs tts_voice_ref_text, synthesis fails until it is set"
                fi
                if [[ "$family" == "qwen3_tts" ]]; then
                    opts=$(jq -nc --arg lang "$TTS_LANGUAGE" '{language: $lang}')
                else
                    opts="{}"
                fi
            fi
            if [[ "$family" == "chatterbox" ]]; then mode="offline"; fi
            ;;
    esac

    jq -nc --arg sid "$sid" --arg family "$family" --arg path "$path" --arg mode "$mode" \
        --argjson preset "$preset" --argjson opts "$opts" --argjson presets "$voice_presets_json" \
        '{id: $sid, family: $family, path: $path, task: "tts", mode: $mode}
         + (if ($preset|length) == 0 then {} else {default_voice_preset: $preset} end)
         + (if ($presets|length) == 0 then {} else {voice_presets: $presets} end)
         + (if ($opts|length) == 0 then {} else {default_request_options: $opts} end)'
}

models_json="$(
    {
        asr_entry
        tts_entry "$TTS_MODEL" "tts"
        if [[ -n "$TTS_HQ_MODEL" && "$TTS_HQ_MODEL" != "none" && "$TTS_HQ_MODEL" != "$TTS_MODEL" ]]; then
            tts_entry "$TTS_HQ_MODEL" "tts-hq"
        fi
    } | jq -s '.'
)"

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
    --argjson models "$models_json" \
    '{
        host: "0.0.0.0",
        port: 8099,
        backend: $backend,
        threads: $threads,
        lazy_load: true,
        max_loaded_models: $max_loaded,
        models: $models
    }' > "$SERVER_CONFIG"

log "server config: $(jq -c '{backend, threads, max_loaded_models, models: [.models[] | {id, family, mode}]}' "$SERVER_CONFIG")"
log "starting audiocpp_server on 0.0.0.0:$PORT (backend=$BACKEND, threads=$THREADS)"

exec ./audiocpp_server --config "$SERVER_CONFIG" --ui --ui-management
