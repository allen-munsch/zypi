#!/bin/bash
set -e
API_PORT=4000
SERVICE_NAME="zypi-node"
WAIT_TIME=10
TEST_IMAGE="hello-zypi:latest"
TEST_REGISTRY=$(mktemp -d "${TMPDIR:-/tmp}/zypi-test.XXXXXX")
export ZYPI_REGISTRY_PATH="${TEST_REGISTRY}"
EXPECTED_LOGS=(
  "Zypi.Store.Containers initialized"
  "Zypi.Store.Images initialized"
  "Zypi.Store.Nodes initialized"
  "Zypi.Cluster.Gossip initialized"
  "Zypi.Cluster.Membership initialized"
  "Zypi.Image.Registry initialized"
  "Zypi.Container.Manager initialized"
)

cleanup() {
  echo "--- Cleanup ---"
  docker compose down --remove-orphans 2>/dev/null || true
  [ -d "${TEST_REGISTRY}" ] && rm -r "${TEST_REGISTRY}"
}
trap cleanup EXIT

api() {
  local method="$1" endpoint="$2" data="$3"
  if [ -n "$data" ]; then
    docker compose exec -T ${SERVICE_NAME} curl -sf -X "$method" -H "Content-Type: application/json" -d "$data" "http://localhost:${API_PORT}${endpoint}"
  else
    docker compose exec -T ${SERVICE_NAME} curl -sf -X "$method" "http://localhost:${API_PORT}${endpoint}"
  fi
}

wait_status() {
  local id="$1" timeout="$2"; shift 2
  local wanted=("$@")
  for _ in $(seq 1 "$timeout"); do
    got=$(api GET "/containers/${id}" | jq -r '.status // "error"')
    for want in "${wanted[@]}"; do
      [ "$got" = "$want" ] && return 0
    done
    sleep 1
  done
  echo "Timeout: got ${got}, want one of: ${wanted[*]}"
  return 1
}

wait_pool() {
  local image="$1" min="$2" timeout="$3"
  echo "Waiting for pool ${image} >= ${min}..."
  for _ in $(seq 1 "$timeout"); do
    size=$(api GET "/status" | jq -r ".pools.\"${image}\" // 0")
    [ "$size" -ge "$min" ] && { echo "Pool ready: ${size}"; return 0; }
    sleep 1
  done
  echo "Timeout: pool size ${size}"
  return 1
}

echo "==> Cleanup stale state"
docker compose down --remove-orphans 2>/dev/null || true
rm -rf ./.zypi/data/devices/* 2>/dev/null || true

echo "==> Build test image"
docker build -t "${TEST_IMAGE}" -f hello-zypi/Dockerfile hello-zypi/

echo "==> Convert to delta format"
./tools/push-delta.sh "${TEST_IMAGE}"

echo "==> Start services (mounting registry at ${TEST_REGISTRY})"
export TEST_REGISTRY_MOUNT="${TEST_REGISTRY}:${TEST_REGISTRY}:ro"
docker compose up -d --build
sleep ${WAIT_TIME}

echo "==> Check logs"
LOGS=$(docker compose logs ${SERVICE_NAME})
for log in "${EXPECTED_LOGS[@]}"; do
  echo "$LOGS" | grep -q "$log" && echo "✔ $log" || { echo "✗ $log"; exit 1; }
done

echo "==> Health check"
api GET "/health" | jq -e . || { echo "API down"; exit 1; }

echo "==> Push image to registry API"
CONFIG=$(cat "${TEST_REGISTRY}/images/hello-zypi/latest/config.overlaybd.json")
MANIFEST=$(cat "${TEST_REGISTRY}/images/hello-zypi/latest/manifest.json")
LAYERS=$(echo "$MANIFEST" | jq -c '.layers')
SIZE=$(echo "$MANIFEST" | jq -r '.size_bytes')
api POST "/images/${TEST_IMAGE}/push" "{\"config\":${CONFIG},\"layers\":${LAYERS},\"size_bytes\":${SIZE}}" | jq .

echo "==> Wait for pool"
wait_pool "${TEST_IMAGE}" 2 30 || exit 1

echo "==> Container lifecycle"
ID="test_$(date +%s)"

echo "Create..."
START=$(date +%s%N)
RESP=$(docker compose exec -T ${SERVICE_NAME} curl -s -X POST -H "Content-Type: application/json" -d "{\"id\":\"${ID}\",\"image\":\"${TEST_IMAGE}\"}" "http://localhost:${API_PORT}/containers")
echo "$RESP" | jq .
echo "Create: $(( ($(date +%s%N) - START) / 1000000 ))ms"
wait_status "$ID" 5 "created" || exit 1

echo "Start..."
START=$(date +%s%N)
api POST "/containers/${ID}/start" | jq .
echo "Start: $(( ($(date +%s%N) - START) / 1000000 ))ms"
wait_status "$ID" 5 "running" "exited" || exit 1

echo "Get logs..."
api GET "/containers/${ID}/logs" | jq .

echo "Stop..."
api POST "/containers/${ID}/stop" | jq .
wait_status "$ID" 5 "stopped" "exited" || exit 1

echo "Destroy..."
api DELETE "/containers/${ID}" | jq .
sleep 1
api GET "/containers/${ID}" 2>/dev/null && { echo "Still exists"; exit 1; }

echo "✅ All tests passed"