docker save hello-zypi:latest -o hello.tar
mkdir hello-rootfs
# The tarball contains multiple layer tars under 'blobs/sha256/...'
# Extract each layer on top of the rootfs in order
mkdir tmp_layers
tar -xf hello.tar -C tmp_layers

# Find all the layer tarballs from manifest.json order
cat tmp_layers/manifest.json
for layer in $(jq -r '.[0].Layers[]' tmp_layers/manifest.json); do
    tar -xf tmp_layers/$layer -C hello-rootfs
done
