#!/bin/bash
set -e

echo "=== Zyppi macOS Setup ==="

# Check macOS version
MACOS_VERSION=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MACOS_VERSION" -lt 11 ]; then
    echo "Error: macOS 11 (Big Sur) or later required"
    exit 1
fi

# Create directories
ZYPI_DIR="$HOME/.zypi"
mkdir -p "$ZYPI_DIR"/{kernel,images,vms,containers}

# Download kernel
echo "Downloading Linux kernel..."
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    KERNEL_URL="https://github.com/example/zypi-kernels/releases/download/v1.0/Image.gz-arm64"
    KERNEL_FILE="Image.gz"
else
    KERNEL_URL="https://github.com/example/zypi-kernels/releases/download/v1.0/vmlinux-x86_64"
    KERNEL_FILE="vmlinux"
fi

curl -L -o "$ZYPI_DIR/kernel/$KERNEL_FILE" "$KERNEL_URL"

# Install QEMU as fallback
if ! command -v qemu-system-aarch64 &> /dev/null && ! command -v qemu-system-x86_64 &> /dev/null; then
    echo "Installing QEMU via Homebrew..."
    brew install qemu
fi

# Build Swift helper (if Xcode available)
if command -v swift &> /dev/null; then
    echo "Building Virtualization.framework helper..."
    cd native/macos
    swift build -c release
    cp .build/release/zypi-virt /usr/local/bin/
    cd ../..
else
    echo "Note: Xcode not found. Using QEMU backend only."
fi

echo "=== Setup Complete ==="
echo "Data directory: $ZYPI_DIR"
echo "Run 'mix run' to start Zyppi"
