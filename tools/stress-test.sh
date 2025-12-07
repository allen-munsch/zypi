#!/bin/bash
# stress-test.sh - 300 container parallel deployment

VERSIONS=100
PARALLEL=20

echo "==> Building images (Python, Go, Shell × ${VERSIONS})..."
for i in $(seq 1 $VERSIONS); do
  (
    if ! docker image inspect hello-zippy:v$i >/dev/null 2>&1; then
      cd hello-zippy && docker build -t hello-zippy:v$i --build-arg VERSION=$i . >/dev/null 2>&1 && echo "Built zippy:v$i"
    else
      echo "Skipped zippy:v$i (exists)"
    fi
  ) &
  
  (
    if ! docker image inspect hello-zypgo:v$i >/dev/null 2>&1; then
      cd hello-zypgo && docker build -t hello-zypgo:v$i --build-arg VERSION=$i . >/dev/null 2>&1 && echo "Built zypgo:v$i"
    else
      echo "Skipped zypgo:v$i (exists)"
    fi
  ) &
  
  (
    if ! docker image inspect hello-zypi:v$i >/dev/null 2>&1; then
      cd hello-zypi && docker build -t hello-zypi:v$i --build-arg VERSION=$i . >/dev/null 2>&1 && echo "Built zypi:v$i"
    else
      echo "Skipped zypi:v$i (exists)"
    fi
  ) &
  
  [ $(jobs -r | wc -l) -ge $PARALLEL ] && wait -n
done
wait

source ./tools/zypi-cli.sh

echo "==> Pushing 300 images..."
for img in zippy zypgo zypi; do
  for i in $(seq 1 $VERSIONS); do
    zypi push hello-$img:v$i >/dev/null 2>&1 && echo "Pushed $img:v$i" &
    [ $(jobs -r | wc -l) -ge $PARALLEL ] && wait -n
  done
done
wait

echo "==> Waiting for images to process..."
for img in zippy zypgo zypi; do
  for i in $(seq 1 $VERSIONS); do
    (
      while true; do
        if docker compose exec -T zypi-node curl -sf "http://localhost:4000/images" 2>/dev/null | jq -e ".images[] | select(. == \"hello-$img:v$i\")" >/dev/null 2>&1; then
          echo "Ready: $img:v$i"
          break
        fi
        sleep 0.5
      done
    ) &
    [ $(jobs -r | wc -l) -ge $PARALLEL ] && wait -n
  done
done
wait

echo "==> Creating 300 containers..."
for img in zippy zypgo zypi; do
  for i in $(seq 1 $VERSIONS); do
    zypi create ${img}${i} hello-$img:v$i >/dev/null 2>&1 && echo "Created ${img}${i}" &
    [ $(jobs -r | wc -l) -ge $PARALLEL ] && wait -n
  done
done
wait

echo "==> Starting 300 containers..."
START=$(date +%s)
for img in zippy zypgo zypi; do
  for i in $(seq 1 $VERSIONS); do
    zypi start ${img}${i} >/dev/null 2>&1 && echo "Started ${img}${i}" &
    [ $(jobs -r | wc -l) -ge $PARALLEL ] && wait -n
  done
done
wait
ELAPSED=$(($(date +%s) - START))

echo ""
echo "==> Results:"
echo "300 containers in ${ELAPSED}s ($(( ELAPSED * 1000 / 300 ))ms avg)"
zypi list | jq 'group_by(.status) | map({status: .[0].status, count: length})'
