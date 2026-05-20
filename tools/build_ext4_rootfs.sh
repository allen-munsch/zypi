# On your host machine
mkdir -p /tmp/rootfs-build
cd /tmp/rootfs-build

# Download and extract Alpine
wget https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-minirootfs-3.20.0-x86_64.tar.gz
mkdir alpine-rootfs
tar -xzf alpine-minirootfs-3.20.0-x86_64.tar.gz -C alpine-rootfs

# Create ext4 image (requires sudo on host)
sudo dd if=/dev/zero of=alpine.ext4 bs=1M count=512
sudo mkfs.ext4 alpine.ext4
sudo mkdir -p /mnt/alpine
sudo mount -o loop alpine.ext4 /mnt/alpine
sudo cp -a alpine-rootfs/. /mnt/alpine/
sudo umount /mnt/alpine

# Move to your project directory
echo mv alpine.ext4 /path/to/your/project/rootfs/
