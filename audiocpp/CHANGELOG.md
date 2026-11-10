# Changelog

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
