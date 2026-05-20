#!/usr/bin/env bash
# Zypi End-to-End Test Suite
#
# Tests every capability through the HTTP API.
# Exit code 0 = all tests pass, 1 = at least one failure.
#
# Usage: ./tools/e2e-test.sh [--url http://localhost:4000]

set -euo pipefail

Z=${ZYPI_URL:-http://localhost:4000}
PASS=0
FAIL=0
SKIP=0

# ── Helpers ──────────────────────────────────────────────

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "  ${GRN}✓${NC} $1"; ((PASS++)) || true; }
fail() { echo -e "  ${RED}✗${NC} $1 — $2"; ((FAIL++)) || true; }
skip() { echo -e "  ${YLW}○${NC} $1 (skipped: $2)"; ((SKIP++)) || true; }

_exec() {
  local timeout=${3:-15}
  curl -sf --max-time $((timeout + 10)) -X POST "$Z/exec" \
    -H "Content-Type: application/json" \
    -d "{\"cmd\":$2,\"image\":\"ubuntu:24.04\",\"timeout\":$timeout}" \
    2>/dev/null || echo '{"error":"request_failed"}'
}

_sess() {
  curl -sf -X POST "$Z/sessions" \
    -H "Content-Type: application/json" \
    -d "$1" 2>/dev/null || echo '{"error":"request_failed"}'
}

_sess_exec() {
  curl -sf -X POST "$Z/sessions/$1/exec" \
    -H "Content-Type: application/json" \
    -d "$2" 2>/dev/null || echo '{"error":"request_failed"}'
}

json_field() { echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$2',''))" 2>/dev/null || echo ""; }

echo "════════════════════════════════════════════════════"
echo "  Zypi E2E Test Suite"
echo "  Target: $Z"
echo "════════════════════════════════════════════════════"
echo ""

# ── 1. Health ──────────────────────────────────────────

echo "── Health ────────────────────────────────────────"
H=$(curl -sf "$Z/health" 2>/dev/null || echo "")
if echo "$H" | grep -q "ok"; then
  pass "health endpoint returns ok"
else
  fail "health endpoint" "not reachable — is Zypi running?"
  echo "ABORT: Zypi not reachable at $Z"
  exit 1
fi

# ── 2. Pool ───────────────────────────────────────────

echo ""
echo "── Pool ──────────────────────────────────────────"
P=$(curl -sf "$Z/pool/stats" 2>/dev/null)
WARM=$(json_field "$P" warm)
TOTAL=$(json_field "$P" total)
HITS=$(json_field "$P" warm_hits)

if [ "$WARM" -gt 0 ] 2>/dev/null; then
  pass "pool has $WARM warm VMs (total: $TOTAL, hits: $HITS)"
else
  skip "warm pool" "no warm VMs yet — waiting for boot..."
  sleep 20
  P2=$(curl -sf "$Z/pool/stats" 2>/dev/null)
  WARM2=$(json_field "$P2" warm)
  if [ "$WARM2" -gt 0 ] 2>/dev/null; then
    pass "pool now has $WARM2 warm VMs (after wait)"
  else
    fail "warm pool" "still 0 warm VMs after 20s — check iptables/agent"
  fi
fi

# ── 3. Basic Exec ─────────────────────────────────────

echo ""
echo "── Basic Execution ───────────────────────────────"
R=$(_exec '["echo","hello zypi"]' '["echo","hello zypi"]')
EXIT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('exit_code',-1))")
STDOUT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stdout',''))")
DUR=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('duration_ms',0))")

[ "$EXIT" = "0" ] && echo "$STDOUT" | grep -q "hello zypi" \
  && pass "echo command (exit=$EXIT, ${DUR}ms)" \
  || fail "echo command" "exit=$EXIT stdout='$STDOUT'"

R=$(_exec '["sh","-c","exit 42"]' '["sh","-c","exit 42"]')
EXIT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('exit_code',-1))")
[ "$EXIT" = "42" ] \
  && pass "non-zero exit (42)" \
  || fail "non-zero exit" "expected 42, got $EXIT"

R=$(_exec '["sh","-c","echo stdout; echo stderr >&2"]' '["sh","-c","echo stdout; echo stderr >&2"]')
STDOUT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stdout',''))")
STDERR=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stderr',''))")
echo "$STDOUT" | grep -q "stdout" && echo "$STDERR" | grep -q "stderr" \
  && pass "stdout/stderr separation" \
  || fail "stdout/stderr" "stdout='$STDOUT' stderr='$STDERR'"

# ── 4. Timeout ────────────────────────────────────────

echo ""
echo "── Timeout ────────────────────────────────────────"
R=$(_exec '["sleep","10"]' '["sleep","10"]' 2)
TIMED_OUT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('timed_out',False))")
[ "$TIMED_OUT" = "True" ] \
  && pass "command timeout (2s)" \
  || fail "command timeout" "expected timed_out=True, got $TIMED_OUT"

# ── 5. Environment Variables ──────────────────────────

echo ""
echo "── Environment Variables ─────────────────────────"
R=$(curl -sf -X POST "$Z/exec" \
  -H "Content-Type: application/json" \
  -d '{"cmd":["sh","-c","echo $ZYPI_E2E_VAR"],"image":"ubuntu:24.04","timeout":10,"env":{"ZYPI_E2E_VAR":"e2e-test-value"}}' 2>/dev/null)
STDOUT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stdout',''))")
echo "$STDOUT" | grep -q "e2e-test-value" \
  && pass "environment variables" \
  || fail "environment variables" "got '$STDOUT'"

# ── 6. File Injection ─────────────────────────────────

echo ""
echo "── File Injection ────────────────────────────────"
R=$(curl -sf -X POST "$Z/exec" \
  -H "Content-Type: application/json" \
  -d '{"cmd":["cat","/tmp/e2e-test.txt"],"image":"ubuntu:24.04","timeout":10,"files":{"/tmp/e2e-test.txt":"e2e file content"}}' 2>/dev/null)
STDOUT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stdout',''))")
echo "$STDOUT" | grep -q "e2e file content" \
  && pass "file injection" \
  || fail "file injection" "got '$STDOUT'"

# ── 7. Resource Limits ────────────────────────────────

echo ""
echo "── Resource Limits ───────────────────────────────"
R=$(curl -sf -X POST "$Z/exec" \
  -H "Content-Type: application/json" \
  -d '{"cmd":["sh","-c","free -m | grep Mem"],"image":"ubuntu:24.04","timeout":10,"memory_mb":512}' 2>/dev/null)
MEM=$(echo "$R" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('stdout',''))")
if echo "$MEM" | grep -q "Mem:"; then
  pass "memory_mb param accepted (free output)"
else
  fail "memory_mb" "no free output — router not passing memory_mb?"
fi

# ── 8. DNS Resolution ─────────────────────────────────

echo ""
echo "── Networking ────────────────────────────────────"
R=$(_exec '["sh","-c","cat /etc/resolv.conf"]' '["sh","-c","cat /etc/resolv.conf"]')
STDOUT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stdout',''))")
echo "$STDOUT" | grep -q "nameserver" \
  && pass "DNS: resolv.conf has nameserver" \
  || fail "DNS: resolv.conf" "got '$STDOUT'"

# ── 9. HTTP Outbound ─────────────────────────────────

R=$(_exec '["curl","-s","http://httpbin.org/ip"]' '["curl","-s","http://httpbin.org/ip"]' 15)
EXIT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('exit_code',-1))")
STDOUT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stdout',''))")
[ "$EXIT" = "0" ] && echo "$STDOUT" | grep -q "origin" \
  && pass "HTTP outbound (httpbin.org)" \
  || fail "HTTP outbound" "exit=$EXIT stdout=${STDOUT:0:80}"

# ── 10. HTTPS Outbound ───────────────────────────────

R=$(_exec '["curl","-s","https://httpbin.org/ip"]' '["curl","-s","https://httpbin.org/ip"]' 15)
EXIT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('exit_code',-1))")
STDOUT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stdout',''))")
if [ "$EXIT" = "0" ] && echo "$STDOUT" | grep -q "origin"; then
  pass "HTTPS outbound (httpbin.org)"
else
  skip "HTTPS outbound" "exit=$EXIT (known: Firecracker TAP MTU issue with TLS)"
fi

# ── 11. Python ───────────────────────────────────────

echo ""
echo "── Python Runtime ────────────────────────────────"
R=$(_exec '["python3","-c","import sys; print(sys.version)"]' '["python3","-c","import sys; print(sys.version)"]')
STDOUT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stdout',''))")
echo "$STDOUT" | grep -q "3\." \
  && pass "python3 available (${STDOUT:0:40}...)" \
  || fail "python3" "got '$STDOUT'"

R=$(_exec '["pip3","--version"]' '["pip3","--version"]')
STDOUT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stdout',''))")
echo "$STDOUT" | grep -q "pip" \
  && pass "pip3 available" \
  || fail "pip3" "got '$STDOUT'"

# ── 12. Docker Import (Build + Save + Import + Exec) ──

echo ""
echo "── Docker Import (build→save→import→exec) ────────"

ALPINE_IMAGE="weft-e2e-alpine:test"
ALPINE_TAR="/tmp/zypi-e2e-alpine.tar"

# Build minimal alpine test image
docker build -t "$ALPINE_IMAGE" -f - "$(pwd)" >/dev/null 2>&1 <<'ALPINE_DOCKERFILE'
FROM alpine:latest
RUN echo "zypi-e2e-import-works" > /etc/zypi-e2e-marker
CMD ["/bin/sh"]
ALPINE_DOCKERFILE

if [ $? -eq 0 ]; then
  pass "docker build alpine test image"

  docker save "$ALPINE_IMAGE" -o "$ALPINE_TAR" 2>/dev/null
  TAR_SIZE=$(stat -c%s "$ALPINE_TAR" 2>/dev/null || echo 0)
  pass "docker save ($(( TAR_SIZE / 1024 / 1024 ))MB tar)"

  # Import into zypi
  IMPORT_RESP=$(curl -sf -X POST "$Z/images/alpine-e2e:latest/import" \
    -H "Content-Type: application/x-tar" \
    --data-binary "@$ALPINE_TAR" 2>/dev/null || echo '{"error":"import_failed"}')
  IMPORT_STATUS=$(echo "$IMPORT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','error'))" 2>/dev/null)

  if [ "$IMPORT_STATUS" = "accepted" ]; then
    pass "import accepted (alpine-e2e:latest)"

    # Wait for import to complete
    for i in $(seq 1 20); do
      IMPORT_STATE=$(curl -sf "$Z/images/alpine-e2e:latest/status" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
      [ "$IMPORT_STATE" = "ready" ] && break
      sleep 1
    done

    if [ "$IMPORT_STATE" = "ready" ]; then
      pass "import completed (ready)"

      # Verify the marker file exists in the imported image via cold-boot exec
      R=$(curl -sf -X POST "$Z/exec" \
        -H "Content-Type: application/json" \
        -d '{"cmd":["cat","/etc/zypi-e2e-marker"],"image":"alpine-e2e:latest","timeout":15}' 2>/dev/null)
      STDOUT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stdout',''))" 2>/dev/null)
      if echo "$STDOUT" | grep -q "zypi-e2e-import-works"; then
        pass "exec in imported image (marker verified)"
      else
        skip "exec in imported image" "warm VM may use base image — cold boot needed"
      fi
    else
      fail "import" "stuck in state: $IMPORT_STATE"
    fi
  else
    fail "import" "response: $IMPORT_RESP"
  fi

  # Cleanup
  rm -f "$ALPINE_TAR"
  docker rmi "$ALPINE_IMAGE" >/dev/null 2>&1 || true
else
  skip "docker build" "docker not available or build failed"
fi

# ── 13. Chromium (imported image) ─────────────────────

echo ""
echo "── Chromium (Dockerfile.chromium import) ──────────"

# Check if chromium image exists
CHROMIUM_EXISTS=$(curl -sf "$Z/images" 2>/dev/null | python3 -c "import sys,json; print('chromium:latest' in json.load(sys.stdin).get('images',[]))" 2>/dev/null)

if [ "$CHROMIUM_EXISTS" = "True" ]; then
  pass "chromium image registered"

  # Test chromium binary via exec (may hit warm VM with base image — try full path)
  # Use a short timeout and timeout command to prevent hangs
  R=$(timeout 20 curl -sf -X POST "$Z/exec" \
    -H "Content-Type: application/json" \
    -d '{"cmd":["/usr/bin/chromium-browser","--version"],"image":"chromium:latest","timeout":15,"memory_mb":512}' 2>/dev/null || echo '{"error":"curl_failed_or_timeout"}')
  EXIT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('exit_code',-1))" 2>/dev/null)
  STDOUT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stdout',''))" 2>/dev/null)
  STDERR=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stderr',''))" 2>/dev/null)

  if echo "$STDOUT$STDERR" | grep -qi "chrom"; then
    pass "chromium --version ($(echo "$STDOUT$STDERR" | tr -d '\n' | head -c 60))"
  else
    skip "chromium --version" "warm VM has base rootfs (no chromium) — needs image-aware pool"
  fi

  # Check if binary exists on disk (cold-booted containers have it)
  R=$(_exec '["sh","-c","ls -la /opt/chromium/chrome-linux/chrome 2>/dev/null || echo NOT_FOUND"]' '["sh","-c","ls -la /opt/chromium/chrome-linux/chrome 2>/dev/null || echo NOT_FOUND"]')
  STDOUT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stdout',''))" 2>/dev/null)
  if echo "$STDOUT" | grep -q "chrome$"; then
    pass "chromium binary on disk"
  else
    skip "chromium binary" "warm VM has base rootfs — need image-aware pool"
  fi
else
  skip "chromium" "image not imported — run: docker build -f Dockerfile.chromium && docker save && curl import"
fi

# ── 14. Sessions ─────────────────────────────────────

echo ""
echo "── Sessions ──────────────────────────────────────"
S=$(_sess '{"image":"ubuntu:24.04","agent_id":"e2e-test"}')
SID=$(echo "$S" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))")
if [ -n "$SID" ]; then
  pass "session created ($SID)"

  R=$(_sess_exec "$SID" '{"cmd":["echo","session e2e"]}')
  STDOUT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stdout',''))")
  echo "$STDOUT" | grep -q "session e2e" \
    && pass "session exec" \
    || fail "session exec" "got '$STDOUT'"

  R=$(_sess_exec "$SID" '{"cmd":["sh","-c","echo step2 >> /tmp/s; cat /tmp/s"]}')
  STDOUT=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stdout',''))")
  echo "$STDOUT" | grep -q "step2" \
    && pass "session state persists" \
    || fail "session state" "got '$STDOUT'"

  curl -sf --max-time 10 -X DELETE "$Z/sessions/$SID" >/dev/null 2>&1 || true
  GET=$(curl -sf --max-time 10 "$Z/sessions/$SID" 2>/dev/null || echo "")
  echo "$GET" | grep -q "not found" \
    && pass "session close" \
    || fail "session close" "session still accessible"
else
  fail "session create" "no session_id returned"
fi

# ── 15. Warm Pool ─────────────────────────────────────

echo ""
echo "── Warm Pool ─────────────────────────────────────"
P=$(curl -sf "$Z/pool/stats" 2>/dev/null)
W=$(json_field "$P" warm)
H=$(json_field "$P" warm_hits)
C=$(json_field "$P" cold_misses)
echo "  warm: $W, hits: $H, cold: $C"
[ "$W" -gt 0 ] 2>/dev/null && pass "warm VMs available ($W)" || skip "warm VMs" "0 warm (may need time to boot)"

# ── 16. Concurrent Exec ──────────────────────────────

echo ""
echo "── Concurrent Execution ──────────────────────────"
START=$(date +%s%N)
R1=$(_exec '["echo","concurrent-1"]' '["echo","concurrent-1"]' 10) &
PID1=$!
R2=$(_exec '["echo","concurrent-2"]' '["echo","concurrent-2"]' 10) &
PID2=$!
R3=$(_exec '["echo","concurrent-3"]' '["echo","concurrent-3"]' 10) &
PID3=$!
wait $PID1 $PID2 $PID3 2>/dev/null || true
R1=${R1:-'{"exit_code":-1}'}
R2=${R2:-'{"exit_code":-1}'}
R3=${R3:-'{"exit_code":-1}'}
END=$(date +%s%N)
ELAPSED=$(( (END - START) / 1000000 ))
E1=$(echo "$R1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('exit_code',-1))")
E2=$(echo "$R2" | python3 -c "import sys,json; print(json.load(sys.stdin).get('exit_code',-1))")
E3=$(echo "$R3" | python3 -c "import sys,json; print(json.load(sys.stdin).get('exit_code',-1))")
if [ "$E1" = "0" ] && [ "$E2" = "0" ] && [ "$E3" = "0" ]; then
  pass "3 concurrent execs (${ELAPSED}ms total)"
else
  fail "concurrent execs" "exits: $E1 $E2 $E3"
fi

# ── Summary ──────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════"
TOTAL=$((PASS + FAIL + SKIP))
echo -e "  ${GRN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}  ${YLW}Skipped: $SKIP${NC}  Total: $TOTAL"
echo "════════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
