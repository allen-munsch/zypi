#!/bin/bash
set -euo pipefail

AMAZON_LINUX_PATH="${1:-}"

if [[ -n "$AMAZON_LINUX_PATH" ]]; then
    if [[ ! -d "$AMAZON_LINUX_PATH" ]]; then
        echo "Error: Provided path '$AMAZON_LINUX_PATH' does not exist or is not a directory."
        exit 1
    fi
    pushd "$AMAZON_LINUX_PATH"
    CLONED=0
else
    git clone git@github.com:amazonlinux/linux.git amazon-linux/
    pushd amazon-linux
    CLONED=1
fi

VERSION="${VERSION:-6.1}"

git checkout v$VERSION

CONFIG_NAME="microvm-kernel-ci-$(uname -m)-${VERSION}.config"

curl -O "https://raw.githubusercontent.com/firecracker-microvm/firecracker/refs/heads/main/resources/guest_configs/${CONFIG_NAME}"

mv "${CONFIG_NAME}" .config

# See: https://github.com/firecracker-microvm/firecracker/blob/main/docs/kernel-policy.md#booting-with-acpi-x86_64-only
echo CONFIG_ACPI=y >> .config
echo CONFIG_PCI=y >> .config


sudo apt-get update
sudo apt-get install -y build-essential libncurses-dev bison flex libssl-dev libelf-dev

make olddefconfig
make -j"$(nproc)" vmlinux

popd

mkdir -p kernel

# If we cloned, the vmlinux lives under amazon-linux/
# If user supplied a path, use that path
if [[ $CLONED -eq 1 ]]; then
    mv amazon-linux/vmlinux kernel/vmlinux
else
    mv "$AMAZON_LINUX_PATH/vmlinux" kernel/vmlinux
fi
