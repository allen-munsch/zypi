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
ARG FC_VERSION=1.7.0
RUN curl -L https://github.com/firecracker-microvm/firecracker/releases/download/v${FC_VERSION}/firecracker-v${FC_VERSION}-x86_64.tgz | tar -xz \
    && mv release-v${FC_VERSION}-x86_64/firecracker-v${FC_VERSION}-x86_64 /usr/local/bin/firecracker \
    && mv release-v${FC_VERSION}-x86_64/jailer-v${FC_VERSION}-x86_64 /usr/local/bin/jailer \
    && chmod +x /usr/local/bin/firecracker /usr/local/bin/jailer \
    && rm -rf release-v${FC_VERSION}-x86_64

# --- Download Firecracker quickstart kernel (has virtio built-in, no initrd needed) ---
RUN mkdir -p /opt/zypi/kernel && \
    curl -fsSL -o /opt/zypi/kernel/vmlinux \
      "https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/kernels/vmlinux.bin" && \
    chmod +x /opt/zypi/kernel/vmlinux

# --- Download and patch Ubuntu RootFS from Firecracker CI ---
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
    \
    # Download RootFS Binary (SquashFS)
    wget -O /app/ubuntu.squashfs "https://s3.amazonaws.com/spec.ccfc.min/$latest_ubuntu_key" && \
    \
    # Patch the RootFS with SSH key
    unsquashfs /app/ubuntu.squashfs && \
    ssh-keygen -f id_rsa -N "" && \
    mkdir -p squashfs-root/root/.ssh && \
    cp -v id_rsa.pub squashfs-root/root/.ssh/authorized_keys && \
    mv -v id_rsa /opt/zypi/rootfs/ubuntu-$ubuntu_version.id_rsa && \
    mv -v id_rsa.pub /opt/zypi/rootfs/ubuntu-$ubuntu_version.id_rsa.pub && \
    \
    # Create EXT4 Filesystem Image
    chown -R root:root squashfs-root && \
    truncate -s 1G /opt/zypi/rootfs/ubuntu-$ubuntu_version.ext4 && \
    mkfs.ext4 -d squashfs-root -F /opt/zypi/rootfs/ubuntu-$ubuntu_version.ext4 && \
    \
    # Clean up
    rm -rf squashfs-root /app/ubuntu.squashfs id_rsa.pub

# --- Elixir Project Setup ---
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY lib ./lib
COPY config ./config
RUN mix compile

CMD ["elixir", "--sname", "zypi_node", "--cookie", "zypi_secret", "-S", "mix", "run", "--no-halt"]