sudo mkdir -p /mnt/test2
sudo mount -o loop .zypi/data/containers/test2/rootfs.ext4 /mnt/test2
sudo pushd /mnt/test2
sudo chroot . ./bin/sh
#apt update
#apt install openssh-server
