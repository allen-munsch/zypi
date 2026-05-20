#!/bin/bash
source tools/zypi-cli.sh

IMAGES=("hello-zypi:sh" "hello-zippy:py" "hello-zypgo:go")
DIRS=("hello-zypi" "hello-zippy" "hello-zypgo")

for i in 0 1 2; do
  dir="${DIRS[$i]}"
  img="${IMAGES[$i]}"
  name="test-${dir}"
  
  echo "==> Building $img from $dir"
  docker build -t "$img" "$dir"
  
  echo "==> Pushing $img"
  zypi push "$img"
  
  echo "==> Creating and starting $name"
  zypi create "$name" "$img"
  zypi start "$name"
  
  echo ""
done

echo "==> All containers:"
zypi list
