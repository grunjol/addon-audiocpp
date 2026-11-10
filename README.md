# addon-audiocpp

Home Assistant add-on that runs [audio.cpp](https://github.com/0xShug0/audio.cpp) as a
local audio inference server: text-to-speech, speech-to-text, VAD and more, on CPU or on
the host iGPU through Vulkan.

This is a **thin add-on**: audio.cpp is never built here. The image layers the official
upstream image (`ghcr.io/0xshug0/audio.cpp:full-vulkan`, audio.cpp v0.9.4, Apache-2.0)
plus the Vulkan userspace packages and an entrypoint that turns the add-on options into a
server configuration. Images are built and published by GitHub Actions on a GitHub
Release to `ghcr.io/grunjol/addon-audiocpp`.

## Install

1. **Settings → Add-ons → Add-on store → ⋮ → Repositories**.
2. Add `https://github.com/grunjol/addon-audiocpp`.
3. Install **audio.cpp** and start it. The selected models are downloaded on first start
   into `/share/audiocpp/models`.

Full option documentation lives in the add-on **Documentation** tab
([`audiocpp/DOCS.md`](audiocpp/DOCS.md)).

## Release

1. Bump `version` in `audiocpp/config.yaml` and note the change in
   `audiocpp/CHANGELOG.md`.
2. Commit and push to `main`.
3. Publish a **GitHub Release** whose tag equals the version (for example `0.9.4.1`).
   That triggers `.github/workflows/main.yml`, which builds `amd64` and `aarch64` and
   publishes `ghcr.io/grunjol/addon-audiocpp:<version>` and `:latest` behind a
   multi-architecture manifest.
4. Optional: register the add-on in the `grunjol/hassio-repository` catalog
   (`audiocpp/` directory with its `config.yaml` and `CHANGELOG.md`).

## Layout

```text
repository.json              # add-on store catalog for the Supervisor
audiocpp/
├── config.yaml              # options, schema, devices, ingress
├── Dockerfile               # FROM upstream + libvulkan1/mesa + entrypoint
├── run.sh                   # options → model download → server.json → exec
├── DOCS.md / CHANGELOG.md
└── translations/en.yaml
.github/workflows/main.yml   # multi-architecture build + manifest
```

## Licenses

This add-on (this repository) is Apache-2.0. audio.cpp is Apache-2.0 (ShugoAI LLC).
Every GGUF model keeps its original license (`docs/model_licenses.md` in the audio.cpp
repository) and several families are not cleared for commercial use — check before using
it outside a private installation.
