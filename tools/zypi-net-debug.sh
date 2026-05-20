#!/bin/bash
# Zypi Debug Script - Run from HOST machine
# All debugging commands are executed INSIDE the zypi-node container.

set -e

TARGET="${1:-test1}"
API_URL="http://localhost:4000"
NODE="zypi-node"    # name of the container running the API + bridge + taps

exec_in_node() {
    docker compose exec -T "$NODE" bash -c "$1"
}

echo "========================================"
echo "  ZYPI DEBUG SCRIPT (host -> zypi-node)"
echo "  Target VM container: $TARGET"
echo "========================================"
echo ""

# === STEP 1: Install tools ===
echo "[1/10] Installing tools in $NODE ..."
exec_in_node "
    apt-get update -qq &&
    apt-get install -y -qq --no-install-recommends \
        netcat-openbsd iputils-arping iputils-ping bridge-utils net-tools \
        tcpdump procps curl jq >/dev/null 2>&1 || true
"
echo "✓ Tools installed"
echo ""

# === STEP 2: API health ===
echo "[2/10] Checking Zypi API..."
if exec_in_node "curl -sf $API_URL/health" >/dev/null 2>&1; then
    exec_in_node "curl -s $API_URL/health | jq ."
else
    echo "✗ API NOT responding"
    exit 1
fi
echo ""

# === STEP 3: List VM containers ===
echo "[3/10] Listing VM containers..."
exec_in_node "curl -s $API_URL/containers | jq -r '.containers[] | \"\(.id): \(.status) @ \(.ip)\"'"
echo ""

# === STEP 4: Inspect target container ===
echo "[4/10] Checking $TARGET ..."
INFO=$(exec_in_node "curl -s $API_URL/containers/$TARGET")

if echo "$INFO" | jq -e '.error' >/dev/null 2>&1; then
    echo "✗ VM '$TARGET' not found"
    exec_in_node "curl -s $API_URL/containers | jq -r '.containers[].id'"
    exit 1
fi


exec_in_node "curl --unix-socket /var/lib/zypi/vms/${TARGET}/api.sock http://localhost/"
exec_in_node "curl --unix-socket /var/lib/zypi/vms/${TARGET}/api.sock http://localhost/vm/config | jq ."

STATUS=$(echo "$INFO" | jq -r '.status')
IP=$(echo "$INFO" | jq -r '.ip')
IMAGE=$(echo "$INFO" | jq -r '.image')
ROOTFS=$(echo "$INFO" | jq -r '.rootfs')

echo "  Status: $STATUS"
echo "  IP:     $IP"
echo "  Image:  $IMAGE"
echo "  Rootfs: $ROOTFS"
echo ""

# === STEP 5: Bridge ===
echo "[5/10] Checking zypi0 bridge..."
exec_in_node "
    ip link show zypi0 >/dev/null 2>&1 &&
    ip addr show zypi0 | grep -E 'inet|state'
" || {
    echo "✗ zypi0 missing in zypi-node"
    exit 1
}
echo ""

# === STEP 6: TAP interfaces ===
echo "[6/10] Checking TAP devices..."
exec_in_node "
    ip link | grep ztap || echo 'No TAP interfaces found'
"
echo ""

# === STEP 7: Routing ===
echo "[7/10] Checking routing inside zypi-node..."
exec_in_node "ip route | grep 10.0.0 || echo 'No 10.0.0.* routes'"
echo ""

# === STEP 8: Connectivity tests ===
echo "[8/10] Testing connectivity to $IP (inside zypi-node)..."

echo "  a) ping:"
exec_in_node "
    ping -c 2 -W 2 $IP >/dev/null 2>&1 ||
    echo 'Ping failed'
"
echo ""

echo "  b) ARP:"
exec_in_node "arp -n | grep $IP || echo 'No ARP entry'"
echo ""

echo "  c) arping:"
exec_in_node "arping -c 2 -I zypi0 $IP || true"
echo ""

echo "  d) SSH port test:"
exec_in_node "
    nc -z -w 2 $IP 22 &&
    echo 'SSH port open' ||
    echo 'SSH port closed'
"
echo ""

# === STEP 9: SSH key ===
echo "[9/10] Checking SSH keys..."
exec_in_node "
    KEY=\$(ls /opt/zypi/rootfs/*.id_rsa 2>/dev/null | head -1 || true);
    echo \"Key: \$KEY\";
    [ -f \"\$KEY.pub\" ] && echo 'Public key OK' || echo 'Missing .pub file'
"
echo ""

# === STEP 10: SSH connect ===
echo "[10/10] SSH connect test..."
exec_in_node "
    KEY=\$(ls /opt/zypi/rootfs/*.id_rsa 2>/dev/null | head -1 || true);
    if [ -n \"\$KEY\" ]; then
        if nc -z -w 2 $IP 22; then
            ssh -v -i \"\$KEY\" \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=5 \
                -o BatchMode=yes \
                root@$IP 'echo SSH OK; hostname; whoami' 2>&1 | tail -20;
        else
            echo 'SSH port closed — skipping'
        fi
    else
        echo 'No SSH key found — skipping'
    fi
"
echo ""

# === Logs ===
echo "==== LAST 50 LINES OF VM LOGS ===="
exec_in_node "curl -s $API_URL/containers/$TARGET/logs | jq -r '.logs' | tail -50"
echo ""

echo "========================================"
echo "  DEBUG COMPLETE"
echo "  VM: $TARGET"
echo "  IP: $IP"
echo ""
echo "  SSH into zypi-node first"
echo "     docker compose exec zypi-node bash"
echo "  Then from inside zypi-node, try to SSH to VM"
echo "      ssh -i /opt/zypi/rootfs/ubuntu-24.04.id_rsa root@$IP"
echo "========================================"

