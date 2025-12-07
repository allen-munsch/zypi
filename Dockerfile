# --- Build Arguments ---
ARG ELIXIR_VERSION=1.19.3
ARG OTP_VERSION=28

# --- Stage 1: Base Image and Dependencies ---
FROM elixir:${ELIXIR_VERSION}-otp-${OTP_VERSION}-slim

WORKDIR /app

# Install necessary build and runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    procps \
    curl \
    wget \
    jq \
    dmsetup \
    util-linux \
    skopeo \
    ca-certificates \
    iproute2 \
    iptables \
    socat \
    tar \
    file \
    ssh \
    squashfs-tools \
    e2fsprogs \
    && rm -rf /var/lib/apt/lists/*

# --- Install Firecracker and Jailer ---
ARG FC_VERSION=1.13.1
RUN curl -L https://github.com/firecracker-microvm/firecracker/releases/download/v${FC_VERSION}/firecracker-v${FC_VERSION}-x86_64.tgz | tar -xz \
    && mv release-v${FC_VERSION}-x86_64/firecracker-v${FC_VERSION}-x86_64 /usr/local/bin/firecracker \
    && mv release-v${FC_VERSION}-x86_64/jailer-v${FC_VERSION}-x86_64 /usr/local/bin/jailer \
    && chmod +x /usr/local/bin/firecracker /usr/local/bin/jailer \
    && rm -rf release-v${FC_VERSION}-x86_64

# --- Download Firecracker quickstart kernel (has virtio built-in, no initrd needed) ---
# WARNING: this vmlinux is old
# root@11333525b9c9:/app# strings /opt/zypi/kernel/vmlinux | grep -E "Linux version"
# Linux version 4.14.174 (@57edebb99db7) (gcc version 7.5.0 (Ubuntu 7.5.0-3ubuntu1~18.04)) #2 SMP Wed Jul 14 11:47:24 UTC 2021
# ----------------------
#
#
# See: tools/build_vmlinux.sh
# Try to copy vmlinux if it exists (Docker ignores empty directory copy)
COPY kernel/vmlinux /opt/zypi/kernel/vmlinux
RUN if [ ! -f /opt/zypi/kernel/vmlinux ]; then \
      echo "WARNING: Local vmlinux not found — downloading fallback"; \
      curl -fsSL -o /opt/zypi/kernel/vmlinux \
        "https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/kernels/vmlinux.bin"; \
    fi && chmod +x /opt/zypi/kernel/vmlinux

# --- Download and patch Ubuntu RootFS from Firecracker CI ---
# This creates a BASE rootfs with openssh pre-installed that DevicePool
# will use as foundation for all container images

RUN mkdir -p /opt/zypi/rootfs && \
    ARCH="$(uname -m)" && \
    release_url="https://github.com/firecracker-microvm/firecracker/releases" && \
    latest_version=$(basename $(curl -fsSLI -o /dev/null -w %{url_effective} ${release_url}/latest)) && \
    CI_VERSION=${latest_version%.*} && \
    echo "Using Firecracker CI Version: $CI_VERSION for Architecture: $ARCH" && \
    \
    # Download RootFS Path
    latest_ubuntu_key=$(curl "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/$CI_VERSION/$ARCH/ubuntu-&list-type=2" \
        | grep -oP "(?<=<Key>)(firecracker-ci/$CI_VERSION/$ARCH/ubuntu-[0-9]+\.[0-9]+\.squashfs)(?=</Key>)" \
        | sort -V | tail -1) && \
    ubuntu_version=$(basename $latest_ubuntu_key .squashfs | grep -oE '[0-9]+\.[0-9]+') && \
    echo "Ubuntu version: $ubuntu_version" && \
    \
    # Download RootFS Binary (SquashFS)
    wget -O /app/ubuntu.squashfs "https://s3.amazonaws.com/spec.ccfc.min/$latest_ubuntu_key" && \
    \
    # Extract SquashFS
    unsquashfs /app/ubuntu.squashfs && \
    \
    # === CRITICAL: Install openssh-server inside rootfs via chroot ===
    # This runs DURING Docker build when we have internet access
    cp /etc/resolv.conf squashfs-root/etc/resolv.conf && \
    mount --bind /proc squashfs-root/proc && \
    mount --bind /sys squashfs-root/sys && \
    mount --bind /dev squashfs-root/dev && \
    mount --bind /dev/pts squashfs-root/dev/pts && \
    \
    # Install openssh-server and netcat, generate host keys and create inittab
    chroot squashfs-root /bin/bash -c '\
set -e && \
apt-get update && \
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    openssh-server bridge-utils netcat-openbsd && \
ssh-keygen -A && \
\
# Write getty to serial console (ttyS0) \
cat > /etc/inittab <<"EOF" \
ttyS0::respawn:/sbin/agetty -L 115200 ttyS0 linux \
EOF \
\
mkdir -p /run/sshd && \
apt-get clean && \
rm -rf /var/lib/apt/lists/*' && \
    \
    # Unmount chroot filesystems
    umount squashfs-root/dev/pts || true && \
    umount squashfs-root/dev || true && \
    umount squashfs-root/sys || true && \
    umount squashfs-root/proc || true && \
    rm squashfs-root/etc/resolv.conf && \
    \
    # === END openssh installation ===
    \
    # Generate SSH keypair for authentication
    ssh-keygen -f id_rsa -N "" && \
    mkdir -p squashfs-root/root/.ssh && \
    cp -v id_rsa.pub squashfs-root/root/.ssh/authorized_keys && \
    chmod 700 squashfs-root/root/.ssh && \
    chmod 600 squashfs-root/root/.ssh/authorized_keys && \
    mv -v id_rsa /opt/zypi/rootfs/ubuntu-$ubuntu_version.id_rsa && \
    mv -v id_rsa.pub /opt/zypi/rootfs/ubuntu-$ubuntu_version.id_rsa.pub && \
    \
    # Configure sshd for key-only root login
    echo 'AuthorizedKeysFile .ssh/authorized_keys' >> squashfs-root/etc/ssh/sshd_config && \
    echo 'PasswordAuthentication no' >> squashfs-root/etc/ssh/sshd_config && \
    echo 'PermitRootLogin prohibit-password' >> squashfs-root/etc/ssh/sshd_config && \
    echo 'PubkeyAuthentication yes' >> squashfs-root/etc/ssh/sshd_config && \
    # echo 'Subsystem sftp /usr/lib/openssh/sftp-server' >> squashfs-root/etc/ssh/sshd_config && \
    # echo 'UsePAM no' >> squashfs-root/etc/ssh/sshd_config && \
    \
    # Create marker file so DevicePool knows this is a zypi base
    touch squashfs-root/etc/zypi-base && \
    mkdir -p squashfs-root/etc/zypi && \
    \
    # Create EXT4 Filesystem Image (2G to accommodate openssh + apps)
    chown -R root:root squashfs-root && \
    truncate -s 2G /opt/zypi/rootfs/ubuntu-$ubuntu_version.ext4 && \
    mkfs.ext4 -d squashfs-root -F /opt/zypi/rootfs/ubuntu-$ubuntu_version.ext4 && \
    \
    # Verify openssh is installed
    echo "Verifying openssh installation..." && \
    debugfs -R "stat /usr/sbin/sshd" /opt/zypi/rootfs/ubuntu-$ubuntu_version.ext4 && \
    \
    # Clean up
    rm -rf squashfs-root /app/ubuntu.squashfs

# --- Elixir Project Setup ---
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY lib ./lib
COPY config ./config
RUN mix compile

CMD ["elixir", "--sname", "zypi_node", "--cookie", "zypi_secret", "-S", "mix", "run", "--no-halt"]