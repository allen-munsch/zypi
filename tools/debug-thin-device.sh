#!/bin/bash
# debug-thin-device.sh

DEVICE="/dev/mapper/zypi-snap-test1"

echo "=== Debugging Thin Device ==="
echo "Device: $DEVICE"

# Check dmsetup info
echo -e "\n=== dmsetup info ==="
sudo dmsetup info $DEVICE
sudo dmsetup status $DEVICE
sudo dmsetup table $DEVICE

# Check kernel device info
echo -e "\n=== Kernel device info ==="
sudo ls -la /sys/block/dm-*/slaves 2>/dev/null | grep -A5 -B5 "$(basename $DEVICE)"

# Try to read first few bytes to see if it has a filesystem
echo -e "\n=== Checking device content ==="
sudo dd if=$DEVICE bs=512 count=1 2>/dev/null | file -

# Check if it's in use
echo -e "\n=== Checking if device is in use ==="
sudo lsof $DEVICE 2>/dev/null || echo "Not in use by processes"
sudo fuser -v $DEVICE 2>/dev/null || echo "No processes using device"

# Try to mount with different options
echo -e "\n=== Testing mounts ==="
TEST_MOUNT="/tmp/test-thin-mount"
sudo mkdir -p $TEST_MOUNT

for fs in ext4 xfs btrfs nilfs2 f2fs; do
    echo -n "Trying $fs... "
    if sudo mount -t $fs $DEVICE $TEST_MOUNT 2>/dev/null; then
        echo "SUCCESS"
        echo "Contents:"
        sudo ls -la $TEST_MOUNT/
        sudo umount $TEST_MOUNT
        break
    else
        echo "FAILED"
    fi
done

# Try without filesystem type
echo -n "Trying auto-detect... "
if sudo mount $DEVICE $TEST_MOUNT 2>/dev/null; then
    echo "SUCCESS"
    echo "Filesystem: $(df -T $TEST_MOUNT | tail -1 | awk '{print $2}')"
    echo "Contents:"
    sudo ls -la $TEST_MOUNT/
    sudo umount $TEST_MOUNT
else
    echo "FAILED"
fi

sudo rmdir $TEST_MOUNT

# Check thin pool status
echo -e "\n=== Thin pool status ==="
POOL_DEVICE=$(sudo dmsetup table $DEVICE | awk '{print $4}' | cut -d: -f1)
if [ -n "$POOL_DEVICE" ]; then
    echo "Pool device: $POOL_DEVICE"
    sudo thin_check $POOL_DEVICE 2>&1 || echo "thin_check failed or not installed"
fi

echo -e "\n=== Device mapper tree ==="
sudo dmsetup ls --tree
