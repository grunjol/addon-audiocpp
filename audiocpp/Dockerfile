ARG BUILD_FROM=ghcr.io/0xshug0/audio.cpp:full-vulkan
FROM ${BUILD_FROM}

# The upstream image is a plain Ubuntu runtime: unprivileged user, no HA
# helpers. We keep its /app layout untouched (binaries + per-ISA ggml libs)
# and only add the Vulkan userspace pieces and our entrypoint.
USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# libvulkan1 + mesa-vulkan-drivers: the Vulkan backend links libvulkan.so.1
# from the system and needs the Intel ANV ICD to see /dev/dri.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        espeak-ng \
        jq \
        libvulkan1 \
        mesa-vulkan-drivers \
    && rm -rf /var/lib/apt/lists/*

COPY run.sh /run.sh
RUN chmod 755 /run.sh

ENTRYPOINT []
CMD ["/run.sh"]
