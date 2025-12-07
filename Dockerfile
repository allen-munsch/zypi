# --- Build Arguments ---
ARG ELIXIR_VERSION=1.19.3
ARG OTP_VERSION=28
ARG FC_VERSION=1.13.1

# --- Stage 1: Build overlaybd ---
FROM ubuntu:22.04 AS overlaybd-builder
WORKDIR /build

RUN apt update && apt install -y \
    libcurl4-openssl-dev \
    libssl-dev \
    libaio-dev \
    libnl-3-dev \
    libnl-genl-3-dev \
    libgflags-dev \
    libzstd-dev \
    libext2fs-dev \
    libgtest-dev \
    libtool \
    zlib1g-dev \
    e2fsprogs \
    sudo \
    pkg-config \
    autoconf \
    automake \
    g++ \
    cmake \
    make \
    wget \
    git \
    curl \
    && apt clean

RUN git clone https://github.com/containerd/overlaybd.git && \
    cd overlaybd && \
    git submodule update --init && \
    rm -rf build && \
    mkdir build && \
    cd build && \
    cmake -DBUILD_TESTING=OFF .. && \
    make -j$(nproc) && \
    make install

# --- Stage 2: Runtime with Elixir + Firecracker ---
FROM elixir:${ELIXIR_VERSION}-otp-${OTP_VERSION}-slim
ARG FC_VERSION
WORKDIR /app

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    dmsetup \
    e2fsprogs \
    file \
    iproute2 \
    iptables \
    jq \
    kmod \
    libcurl4-openssl-dev \
    libaio-dev \
    libnl-3-200 \
    libzstd-dev \
    procps \
    skopeo \
    socat \
    squashfs-tools \
    ssh \
    tar \
    util-linux \
    wget \
    zlib1g \
    && rm -rf /var/lib/apt/lists/*

# Copy overlaybd from builder
COPY --from=overlaybd-builder /opt/overlaybd /opt/overlaybd
COPY --from=overlaybd-builder /etc/overlaybd /etc/overlaybd
COPY --from=overlaybd-builder /usr/local/bin/overlaybd* /usr/local/bin/
COPY --from=overlaybd-builder /usr/local/lib/liboverlaybd* /usr/local/lib/

# Install Firecracker and Jailer
RUN curl -L https://github.com/firecracker-microvm/firecracker/releases/download/v${FC_VERSION}/firecracker-v${FC_VERSION}-x86_64.tgz | tar -xz && \
    mv release-v${FC_VERSION}-x86_64/firecracker-v${FC_VERSION}-x86_64 /usr/local/bin/firecracker && \
    mv release-v${FC_VERSION}-x86_64/jailer-v${FC_VERSION}-x86_64 /usr/local/bin/jailer && \
    chmod +x /usr/local/bin/firecracker /usr/local/bin/jailer && \
    rm -rf release-v${FC_VERSION}-x86_64

# --- Download Firecracker quickstart kernel (has virtio built-in, no initrd needed) ---
# NOTE: the quickstart vmlinux is old
# root@11333525b9c9:/app# strings /opt/zypi/kernel/vmlinux | grep -E "Linux version"
# Linux version 4.14.174 (@57edebb99db7) (gcc version 7.5.0 (Ubuntu 7.5.0-3ubuntu1~18.04)) #2 SMP Wed Jul 14 11:47:24 UTC 2021
# ----------------------
#
#
# See: tools/build_vmlinux.sh
COPY kernel/vmlinux /opt/zypi/kernel/vmlinux
RUN if [ ! -f /opt/zypi/kernel/vmlinux ]; then \
      echo "WARNING: Local vmlinux not found — downloading fallback"; \
      curl -fsSL -o /opt/zypi/kernel/vmlinux "https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/kernels/vmlinux.bin"; \
    fi && \
    chmod +x /opt/zypi/kernel/vmlinux

# Build Ubuntu rootfs with SSH
RUN mkdir -p /opt/zypi/rootfs && \
    ARCH="$(uname -m)" && \
    release_url="https://github.com/firecracker-microvm/firecracker/releases" && \
    latest_version=$(basename $(curl -fsSLI -o /dev/null -w %{url_effective} ${release_url}/latest)) && \
    CI_VERSION=${latest_version%.*} && \
    echo "Using Firecracker CI Version: $CI_VERSION for Architecture: $ARCH" && \
    latest_ubuntu_key=$(curl "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/$CI_VERSION/$ARCH/ubuntu-&list-type=2" | grep -oP "(?<=<Key>)(firecracker-ci/$CI_VERSION/$ARCH/ubuntu-[0-9]+\.[0-9]+\.squashfs)(?=</Key>)" | sort -V | tail -1) && \
    ubuntu_version=$(basename $latest_ubuntu_key .squashfs | grep -oE '[0-9]+\.[0-9]+') && \
    echo "Ubuntu version: $ubuntu_version" && \
    wget -O /app/ubuntu.squashfs "https://s3.amazonaws.com/spec.ccfc.min/$latest_ubuntu_key" && \
    unsquashfs /app/ubuntu.squashfs && \
    cp /etc/resolv.conf squashfs-root/etc/resolv.conf && \
    mount --bind /proc squashfs-root/proc && \
    mount --bind /sys squashfs-root/sys && \
    mount --bind /dev squashfs-root/dev && \
    mount --bind /dev/pts squashfs-root/dev/pts && \
    chroot squashfs-root /bin/bash -c ' \
      set -e && \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server bridge-utils netcat-openbsd && \
      ssh-keygen -A && \
      cat > /etc/inittab <<EOF \
ttyS0::respawn:/sbin/agetty -L 115200 ttyS0 linux \
EOF \
      mkdir -p /run/sshd && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/*' && \
    umount squashfs-root/dev/pts || true && \
    umount squashfs-root/dev || true && \
    umount squashfs-root/sys || true && \
    umount squashfs-root/proc || true && \
    rm squashfs-root/etc/resolv.conf && \
    ssh-keygen -f id_rsa -N "" && \
    mkdir -p squashfs-root/root/.ssh && \
    cp -v id_rsa.pub squashfs-root/root/.ssh/authorized_keys && \
    chmod 700 squashfs-root/root/.ssh && \
    chmod 600 squashfs-root/root/.ssh/authorized_keys && \
    mv -v id_rsa /opt/zypi/rootfs/ubuntu-$ubuntu_version.id_rsa && \
    mv -v id_rsa.pub /opt/zypi/rootfs/ubuntu-$ubuntu_version.id_rsa.pub && \
    echo 'AuthorizedKeysFile .ssh/authorized_keys' >> squashfs-root/etc/ssh/sshd_config && \
    echo 'PasswordAuthentication no' >> squashfs-root/etc/ssh/sshd_config && \
    echo 'PermitRootLogin prohibit-password' >> squashfs-root/etc/ssh/sshd_config && \
    echo 'PubkeyAuthentication yes' >> squashfs-root/etc/ssh/sshd_config && \
    touch squashfs-root/etc/zypi-base && \
    mkdir -p squashfs-root/etc/zypi && \
    chown -R root:root squashfs-root && \
    truncate -s 2G /opt/zypi/rootfs/ubuntu-$ubuntu_version.ext4 && \
    mkfs.ext4 -d squashfs-root -F /opt/zypi/rootfs/ubuntu-$ubuntu_version.ext4 && \
    echo "Verifying openssh installation..." && \
    debugfs -R "stat /usr/sbin/sshd" /opt/zypi/rootfs/ubuntu-$ubuntu_version.ext4 && \
    rm -rf squashfs-root /app/ubuntu.squashfs

# Elixir setup
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY lib ./lib
COPY config ./config
RUN mix compile

CMD ["elixir", "--sname", "zypi_node", "--cookie", "zypi_secret", "-S", "mix", "run", "--no-halt"]