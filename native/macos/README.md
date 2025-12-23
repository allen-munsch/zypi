# zypi-virt - macOS Virtualization.framework Helper

This Swift application wraps Apple's Virtualization.framework to provide
VM management for Zyppi on macOS.

## Requirements

- macOS 11.0 (Big Sur) or later
- Xcode 12+ for building
- Signed with appropriate entitlements for virtualization

## Building

```bash
cd native/macos
swift build -c release
cp .build/release/zypi-virt /usr/local/bin/
```

## Usage

```bash
# Start a VM
zypi-virt start --config /path/to/config.json

# Stop a VM  
zypi-virt stop --id <vm-id>

# List running VMs
zypi-virt list
```

## Config Format

```json
{
  "id": "container_123",
  "rootfs": "/path/to/rootfs.img",
  "kernel": "/path/to/Image.gz",
  "memory_mb": 256,
  "cpus": 1,
  "ip": "192.168.64.2",
  "socket_path": "/tmp/vm_123/control.sock"
}
```

## Entitlements

The binary needs these entitlements:
- com.apple.security.virtualization
- com.apple.vm.networking

## Implementation Notes

See zypi-virt/Sources/main.swift for the full implementation.
Key components:
- VZVirtualMachine for VM lifecycle
- VZVirtioNetworkDeviceConfiguration for networking
- VZVirtioBlockDeviceConfiguration for rootfs
- Unix socket for control interface
