#!/bin/bash
# tools/build_initrd_docker.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KERNEL_DIR="$PROJECT_ROOT/kernel"

mkdir -p "$KERNEL_DIR"

echo "Building initrd using Docker (safest method)..."

# Create a Docker container to build the initrd safely
docker run --rm \
  -v "$KERNEL_DIR:/output" \
  alpine:latest sh -c '
  # Install tools
  apk add --no-cache cpio
  
  # Download and extract Alpine
  cd /tmp
  wget -q https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-minirootfs-3.20.0-x86_64.tar.gz
  mkdir rootfs
  tar -xzf alpine-minirootfs-3.20.0-x86_64.tar.gz -C rootfs
  cd rootfs
  
  # Create initrd
  find . | cpio -ov -H newc 2>/dev/null | gzip > /output/alpine-initrd.img
  
  echo "Initrd created successfully"
'

echo "✓ Initrd built: $KERNEL_DIR/alpine-initrd.img"
ls -lh "$KERNEL_DIR/alpine-initrd.img"