#!/bin/bash
set -e

IMAGE_REF="$1"
REGISTRY_PATH="${ZYPI_REGISTRY_PATH:-/mnt/zypi-registry}"

if [ -z "$IMAGE_REF" ]; then
  echo "Usage: push-delta.sh <image:tag>"
  exit 1
fi

REPO="${IMAGE_REF%%:*}"
TAG="${IMAGE_REF##*:}"
[ "$TAG" = "$IMAGE_REF" ] && TAG="latest"

DEST="${REGISTRY_PATH}/images/${REPO}/${TAG}"
WORK=$(mktemp -d)
trap "rm -rf ${WORK}" EXIT

echo "==> Exporting ${IMAGE_REF}..."
docker save "${IMAGE_REF}" -o "${WORK}/image.tar"
mkdir -p "${WORK}/extracted"
tar -xf "${WORK}/image.tar" -C "${WORK}/extracted"

echo "==> Processing layers..."
mkdir -p "${DEST}/layers"

MANIFEST_FILE=$(find "${WORK}/extracted" -name "manifest.json" -type f)
LAYER_PATHS=$(jq -r '.[0].Layers[]' "$MANIFEST_FILE")

LAYERS=()
TOTAL_SIZE=0

for layer_tar in $LAYER_PATHS; do
  layer_file="${WORK}/extracted/${layer_tar}"
  digest="sha256:$(sha256sum "${layer_file}" | cut -d' ' -f1)"
  
  # Decompress if gzipped
  if file "${layer_file}" | grep -q gzip; then
    gunzip -c "${layer_file}" > "${DEST}/layers/${digest}"
  else
    cp "${layer_file}" "${DEST}/layers/${digest}"
  fi
  
  size=$(stat -c%s "${DEST}/layers/${digest}")
  LAYERS+=("{\"digest\":\"${digest}\",\"size\":${size}}")
  TOTAL_SIZE=$((TOTAL_SIZE + size))
  
  echo "    Layer: ${digest:7:12}... (${size} bytes)"
done

echo "==> Generating config..."
LOWERS=$(printf '%s\n' "${LAYERS[@]}" | jq -s '.')

cat > "${DEST}/config.overlaybd.json" <<EOF
{"repoBlobUrl":"file://${DEST}/layers","lowers":${LOWERS},"resultFile":"/tmp/zypi-${REPO//\//_}-${TAG}"}
EOF

LAYERS_JSON=$(printf '%s,' "${LAYERS[@]}" | sed 's/,$//')
cat > "${DEST}/manifest.json" <<EOF
{"ref":"${IMAGE_REF}","created_at":"$(date -Iseconds)","size_bytes":${TOTAL_SIZE},"layers":[${LAYERS_JSON}],"overlaybd":{"version":1,"accelerated":false}}
EOF

echo "==> Done: ${DEST}"
echo "    Layers: ${#LAYERS[@]}, Size: ${TOTAL_SIZE} bytes"