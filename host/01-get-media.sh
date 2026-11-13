#!/usr/bin/env bash
# Download the installation media from the official sources (resumable) and record SHA-256.
#   * Windows Server 2025 Evaluation (Microsoft Evaluation Center, en-US ISO, ~8 GB)
#   * Windows 11 Enterprise LTSC 2024 Evaluation (Microsoft Evaluation Center, en-US ISO, ~5 GB)
#   * virtio-win (Fedora/Red Hat signed drivers + QEMU guest agent, ~0.9 GB)
# Evaluation media are for non-production testing only; read the licence terms shown at
# https://www.microsoft.com/evalcenter before using them.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=host/lab.env
source "$HERE/lab.env"

mkdir -p "$ISO_DIR"
fetch() {
  local out="$1" url="$2"
  echo "-> $(basename "$out")"
  curl -fL --retry 5 --retry-delay 5 -C - -o "$out" "$url"
}
fetch "$SERVER_ISO" "$SERVER_ISO_URL"
fetch "$CLIENT_ISO" "$CLIENT_ISO_URL"
fetch "$VIRTIO_ISO" "$VIRTIO_ISO_URL"
(cd "$ISO_DIR" && sha256sum "$(basename "$SERVER_ISO")" "$(basename "$CLIENT_ISO")" "$(basename "$VIRTIO_ISO")" | tee SHA256SUMS)
echo "Compare with docs/architecture.md (hashes recorded on the reference host)."
