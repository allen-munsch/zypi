# Install overlaybd tools (Ubuntu/Debian)
apt-get install -y overlaybd-tcmu

# Or build from source
git clone https://github.com/containerd/accelerated-container-image.git
cd accelerated-container-image
make && make install

# Also need skopeo for OCI export
apt-get install -y skopeo jq
