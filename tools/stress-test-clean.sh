source ./tools/zypi-cli.sh

for img in zippy zypgo zypi; do for i in $(seq 1 100); do zypi destroy ${img}${i} & done; done; wait

sudo losetup -D
