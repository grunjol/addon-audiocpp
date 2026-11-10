# Changelog

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
