#!/bin/bash
# iron-proxy egress firewall smoke test
# Run from inside a Zypi sandbox (or mock the proxy calls)
#
# Usage: docker compose up -d && ./tools/test-iron-proxy.sh

IRON_PROXY="http://10.0.0.2:8080"
BASE="http://localhost:4000"

echo "=== iron-proxy Egress Firewall Smoke Test ==="
echo ""

# Test 1: Health checks
echo "--- Test 1: iron-proxy health ---"
curl -s "$IRON_PROXY/health" 2>/dev/null && echo "" || echo "iron-proxy not reachable (expected if running in sandbox)"
echo ""

echo "--- Test 2: Zypi health ---"
curl -s "$BASE/health" | python3 -m json.tool 2>/dev/null || echo "Zypi not reachable"
echo ""

# Test 2: Exec with allowed domain (httpbin.org is in allowlist)
echo "--- Test 3: Allowed domain (httpbin.org) ---"
curl -s -X POST "$BASE/exec" \
  -H "Content-Type: application/json" \
  -d '{
    "cmd": ["curl", "-s", "http://httpbin.org/ip"],
    "image": "ubuntu:24.04",
    "timeout": 15
  }' | python3 -m json.tool 2>/dev/null
echo ""

# Test 3: Exec with blocked domain (example.com is NOT in allowlist)
echo "--- Test 4: Blocked domain (example.com — should fail) ---"
curl -s -X POST "$BASE/exec" \
  -H "Content-Type: application/json" \
  -d '{
    "cmd": ["curl", "-s", "http://example.com"],
    "image": "ubuntu:24.04",
    "timeout": 15
  }' | python3 -m json.tool 2>/dev/null
echo ""

# Test 4: HTTPS via proxy
echo "--- Test 5: HTTPS via proxy (httpbin.org) ---"
curl -s -X POST "$BASE/exec" \
  -H "Content-Type: application/json" \
  -d '{
    "cmd": ["curl", "-s", "https://httpbin.org/ip"],
    "image": "ubuntu:24.04",
    "timeout": 15
  }' | python3 -m json.tool 2>/dev/null
echo ""

# Test 5: pip install (pypi.org is allowlisted)
echo "--- Test 6: pip install requests (pypi.org) ---"
curl -s -X POST "$BASE/exec" \
  -H "Content-Type: application/json" \
  -d '{
    "cmd": ["pip", "install", "requests"],
    "image": "ubuntu:24.04",
    "timeout": 30
  }' | python3 -m json.tool 2>/dev/null
echo ""

echo "=== Done ==="
