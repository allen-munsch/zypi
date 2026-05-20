#!/bin/bash
# cleanup-containers.sh

echo "=== Cleaning up existing containers ==="

# List all containers
echo "Current containers:"
sudo crun list || echo "No crun containers"

# Clean up test1 if it exists
if sudo crun state test1 2>/dev/null; then
    echo "Stopping and deleting test1..."
    sudo crun kill test1 SIGKILL 2>/dev/null || true
    sudo crun delete -f test1 2>/dev/null || true
fi

# Clean up cgroup directory
echo "Cleaning up cgroup directory..."
sudo rmdir /sys/fs/cgroup/test1 2>/dev/null || true

# Clean up bundle directory
echo "Cleaning up bundle directory..."
sudo umount /var/lib/zypi/bundles/test1/rootfs 2>/dev/null || true
sudo rm -rf /var/lib/zypi/bundles/test1 2>/dev/null || true

echo "=== Cleanup complete ==="
