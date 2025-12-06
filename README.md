# On host - clean everything
docker compose down
sudo dmsetup remove_all
sudo losetup -D
rm -rf ./.zypi/data/*

# Restart fresh
docker compose up -d
sleep 5

# Now push and test
export ZYPI_REGISTRY_PATH=/tmp/my-registry
./tools/push-delta.sh hello-zypi:latest
source tools/zypi-cli.sh
zypi push hello-zypi:latest ${ZYPI_REGISTRY_PATH}/images/hello-zypi/latest

# Wait for pool
sleep 3
zypi create test1 hello-zypi:latest
zypi start test1
zypi inspect test1
zypi shell test1
