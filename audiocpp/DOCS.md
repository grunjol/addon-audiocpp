# audio.cpp

Local audio inference engine ([audio.cpp](https://github.com/0xShug0/audio.cpp)) packaged
as a Home Assistant add-on. It runs on the official
`ghcr.io/0xshug0/audio.cpp:full-vulkan` image (audio.cpp v0.9.4, Apache-2.0): nothing is
compiled here, the add-on only adds the configuration, the entrypoint and the Vulkan
userspace libraries.

## What runs inside

A single process, `audiocpp_server`, which exposes:

- An **OpenAI-compatible API**: `POST /v1/audio/speech`, `POST /v1/audio/transcriptions`,
  `POST /v1/audio/transcriptions/details`, `POST /v1/audio/alignments`, plus `/health` and
  `/v1/models`.
- The embedded **WebUI** (sidebar panel through ingress, or `http://<host>:8099`).
- A **CPU** or **Vulkan** (Intel/AMD iGPU) backend, selectable through an option.

It covers three use cases at once: voice engines for Assist, transcription through the
API for automations, and manual work in the WebUI (try voices, transcribe a file, switch
models).

## Options

| Option | Default | Description |
|---|---|---|
| `backend` | `cpu` | `cpu` or `vulkan`. With `vulkan` the add-on uses `/dev/dri`; if no usable device is found it falls back to CPU and says so in the log |
| `threads` | `3` | Inference threads. The host has 4 in total: keep one free for Home Assistant |
| `asr_model` | `canary_180m_flash_q8_0` | Speech-to-text model (or `none`) |
| `tts_model` | `pocket_tts_spanish_q8_0` | Text-to-speech model (or `none`) |
| `tts_voice` | `rafael` | Voice preset of the TTS package (`alba`, `estelle`, …). Empty = model default |
| `max_loaded_models` | `2` | Models allowed to stay in memory at the same time |
| `hf_token` | empty | Only needed for gated or private model repositories |

Models are downloaded on first start into `/share/audiocpp/models` and **survive add-on
updates**. Deleting a `.gguf` from there forces a fresh download.

| Model | Size | RAM (approx.) | Notes |
|---|---|---|---|
| `canary_180m_flash_q8_0` | 250 MB | 0.4 GB | fastest, Spanish included |
| `qwen3_asr_0_6b_q8_0` | 1.1 GB | 1.9 GB | better transcripts, close to real time |
| `nemotron_asr_q8_0` | 930 MB | ~1.5 GB | streaming, 100+ languages |
| `pocket_tts_spanish_q8_0` | 128 MB | 1.2 GB | 100M TTS, 1.4x real time on this host |
| `pocket_tts_english_q8_0` | 128 MB | 1.2 GB | same model, English |

## Using it

### From Home Assistant (Assist)

Install the **[Drakknar/ha-audiocpp](https://github.com/Drakknar/ha-audiocpp)** integration
(HACS → custom repository → Integration), point it at `http://<add-on-ip>:8099` and add a
`tts` and/or `stt` engine per model. Then select the engines in
**Settings → Voice assistants**. Wyoming is not required for this path.

### From automations or scripts

```yaml
action: tts.speak
target:
  entity_id: tts.audiocpp_pocket_tts
data:
  media_player_entity_id: media_player.office_speaker
  message: "The garage door is still open."
```

Transcription over the API (multipart):

```bash
curl -s -X POST http://<add-on-ip>:8099/v1/audio/transcriptions \
  -F "file=@note.wav" -F "model=asr" -F "language=es"
```

### From the WebUI

The **audio.cpp** sidebar panel (ingress) runs TTS/ASR interactively, browses the model
catalog and shows inference metrics.

## GPU (Vulkan)

The add-on declares `devices: [/dev/dri]` and ships `libvulkan1` + `mesa-vulkan-drivers`.
On this host the iGPU is an **Intel UHD 620** (Gen9, 24 EU, no CUDA).

Realistic expectation: **ASR and dense matmuls 1.5-3x** versus CPU, **TTS with many small
operations 0.8-2x** (it may not improve at all). On Vulkan prefer **F16 over Q8** (Q8 gets
dequantized per operation) and do not worry about VRAM — it is shared system memory. The
15 W package power budget is shared between CPU and iGPU, so the total gain is lower than
the sum of both.

To compare on the same machine, run the same audio with `backend: cpu` and
`backend: vulkan` and read the `rtf` the server reports.

## Resources

- Ports: `8099/tcp` (API + WebUI). Not required when the ingress panel is used.
- Volume: `/share` (models).
- RAM: ~1.5-3 GB depending on the loaded models.
- Watchdog: `tcp://[HOST]:[PORT:8099]` (the Supervisor restarts the add-on when it stops
  answering).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `WARNING: no usable Vulkan device found` | `/dev/dri` is not reachable or the Mesa ICD is missing; the add-on keeps running on CPU |
| First transcription is slow | the model is loaded on first request (`lazy_load`) |
| Unknown voice | the preset does not exist for that language; the log says so and the model default is used |
| Running out of RAM | lower `max_loaded_models` to 1 or `threads` to 2 |
