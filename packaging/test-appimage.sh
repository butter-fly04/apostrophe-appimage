#!/usr/bin/env bash
# Smoke-test an AppImage in a clean Fedora 44 container.
#
# Usage: packaging/test-appimage.sh dist/Apostrophe-*.AppImage
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${TEST_IMAGE:-quay.io/fedora/fedora:44}"
APPIMAGE="${1:-}"
[ -n "$APPIMAGE" ] && [ -f "$APPIMAGE" ] || {
  echo "usage: $0 <path-to-AppImage>" >&2
  exit 2
}

APPIMAGE="$(readlink -f "$APPIMAGE")"

echo "==> Clean-container self-test (no GTK/WebKit/packages installed)"
podman run --rm \
  --network=host \
  --security-opt label=disable \
  -v "$APPIMAGE:/test.AppImage:ro,Z" \
  -e APPIMAGE_EXTRACT_AND_RUN=1 \
  "$IMAGE" \
  /bin/sh -c '
    set -e
    /test.AppImage --apostrophe-self-test
  '

echo "==> Self-test passed"
