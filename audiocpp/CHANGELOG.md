# Changelog

## 0.9.4.9

- New TTS family: **Qwen3-TTS 0.6B Base** (`qwen3_tts_0_6b_q8_0`, 1.99 GB, 10 languages,
  zero-shot cloning + voice design, streaming and offline). It is the multilingual family that
  actually honours `language`: its spec exposes `language` as a request option.
- **Chatterbox cannot speak Spanish through the API.** Its struct carries `language = "en"` but
  `model_specs/chatterbox.json` does not list `language` among the request options, so the value is
  dropped and Spanish text is rendered with English phonetics. The family stays in the schema for
  English, marked in `tts_model`'s description.

## 0.9.4.8

- New option `tts_language` (default `es`). Chatterbox hardcodes `language = "en"` in its session
  defaults, so Spanish text was read with English phonetics ("rabioles joy" instead of "ravioles
  hoy"). The language is now passed as `default_request_options.language` for `chatterbox` (and
  kokoro, which had `es` hardcoded, now follows the option too).

## 0.9.4.7

- New TTS family: **Chatterbox** (`chatterbox_q8_0`, 0.5B, 19 languages, zero-shot cloning,
  2.1 GB). Offline-only, so the model is registered with `mode: offline` instead of `streaming`.
- New option `tts_voice_ref`: absolute path **inside the container** (use `/share/...`) to a wav that
  the family clones from. Families without preset voices (chatterbox) need it; when empty they fall
  back to their built-in default voice.
- Note: `chatterbox_turbo` (699 MB) is smaller but its spec only declares `tasks: ["tts"]`, so it
  cannot clone — the full `chatterbox` package is the one with `tts`/`clone`/`vc`.

## 0.9.4.6

- Speech-to-text reliability: canary returns an **empty transcript** for some perfectly valid audio
  when punctuation is on (measured: 4/6 files, then 3/6 even with `language=es`). With
  `punc=false` it transcribes 6/6. New options `asr_language` (default `es`) and `asr_punc`
  (default `false`) are passed as the model's `default_request_options`.
- Side effect: without punctuation the transcript has no capitals or periods. Irrelevant for voice
  commands and for an LLM consumer.

## 0.9.4.5

- Install `espeak-ng` in the image. Kokoro uses the shared eSpeak frontend for text
  normalization/phonemization of several languages (Spanish included); without the library every
  kokoro request failed with `Could not load eSpeak-ng; install the shared library or provide its
  path`.

## 0.9.4.4

- New text-to-speech option `kokoro_82m_q8_0` (Kokoro 82M, 54 built-in voices; the Spanish ones
  are `ef_dora`, `em_alex`, `em_santa`). Kokoro does not clone voices; `pocket_tts` stays the
  cloning family.
- New `tts_speed` option (0.5-2.0). It is passed as `default_request_options.speed`, which Kokoro
  supports; `pocket_tts` rejects it, so leave it at 1.0 with that family.
- Kokoro models get `default_request_options.language=es` so the shared eSpeak frontend voices
  Spanish correctly.
- A leftover voice from another family (for example `rafael` with kokoro selected) is replaced by
  the family default instead of failing the request.

## 0.9.4.3

- Declare the iGPU as individual device nodes (`/dev/dri/card0`,
  `/dev/dri/renderD128`) instead of the `/dev/dri` directory: with the directory the
  Supervisor bind-mounts the nodes but does not grant access, so opening `renderD128`
  returned EPERM and Vulkan could not start.

## 0.9.4.2

- Fix the text-to-speech default voice: the model entry now uses the server's
  `default_voice_preset` instead of session options, so OpenAI-compatible clients can omit
  `voice` and still get audio (before, a request without `voice` failed with
  "PocketTTS session prepare() requires a session voice").
- Log the GPU device nodes found inside the container and whether `renderD128` can be
  opened, so a Vulkan fallback to CPU is diagnosable from the add-on log.

## 0.9.4.1

- First release. Thin wrapper around the upstream `ghcr.io/0xshug0/audio.cpp:full-vulkan`
  image (audio.cpp v0.9.4, Apache-2.0): no local compilation.
- CPU and Vulkan backends selectable; the add-on declares `devices: [/dev/dri]` and
  installs `libvulkan1` + `mesa-vulkan-drivers` so the Vulkan backend can use the
  host iGPU. If no Vulkan device is usable it falls back to CPU with a log line.
- Models are downloaded on first start into `/share/audiocpp/models` and survive
  add-on updates.
- Speech-to-text: `canary_180m_flash_q8_0` (default, ~250 MB), `qwen3_asr_0_6b_q8_0`
  (~1.1 GB), `nemotron_asr_q8_0` (~930 MB).
- Text-to-speech: `pocket_tts_spanish_q8_0` (default, ~128 MB) and
  `pocket_tts_english_q8_0`, with a selectable voice from the package voice set.
- OpenAI-compatible API on port 8099 (`/v1/audio/speech`,
  `/v1/audio/transcriptions`, `/v1/audio/transcriptions/details`) and the embedded
  WebUI through HA ingress or the published port.
