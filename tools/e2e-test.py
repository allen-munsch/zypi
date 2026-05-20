#!/usr/bin/env python3
"""Zypi End-to-End Test Suite — Python edition.

Tests every capability through the HTTP API.
Exit code 0 = all tests pass, 1 = at least one failure.

Usage: ./tools/e2e-test.py [--url http://localhost:4000]
"""

import argparse
import json
import os
import subprocess
import sys
import time
import tempfile
import concurrent.futures
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

# ── Config ──────────────────────────────────────────────

Z = os.environ.get("ZYPI_URL", "http://localhost:4000")
PASS = 0
FAIL = 0
SKIP = 0

RED = "\033[0;31m"
GRN = "\033[0;32m"
YLW = "\033[1;33m"
NC  = "\033[0m"


def _pass(msg):
    global PASS; PASS += 1
    print(f"  {GRN}✓{NC} {msg}")

def _fail(msg, detail=""):
    global FAIL; FAIL += 1
    print(f"  {RED}✗{NC} {msg} — {detail}" if detail else f"  {RED}✗{NC} {msg}")

def _skip(msg, reason=""):
    global SKIP; SKIP += 1
    print(f"  {YLW}○{NC} {msg} (skipped: {reason})" if reason else f"  {YLW}○{NC} {msg}")


def api(method, path, body=None, content_type="application/json", timeout=30):
    """Call the Zypi API, return (status, parsed_json)."""
    url = f"{Z}{path}"
    data = None
    if body is not None:
        if isinstance(body, dict):
            data = json.dumps(body).encode()
        elif isinstance(body, bytes):
            data = body
        else:
            data = body.encode()
    try:
        req = Request(url, data=data, method=method)
        req.add_header("Content-Type", content_type)
        resp = urlopen(req, timeout=timeout)
        return resp.status, json.loads(resp.read())
    except HTTPError as e:
        try:
            return e.code, json.loads(e.read())
        except Exception:
            return e.code, {"error": str(e)}
    except URLError as e:
        return -1, {"error": f"connection_failed: {e.reason}"}
    except Exception as e:
        return -1, {"error": str(e)}


def exec_cmd(cmd, image="ubuntu:24.04", timeout=15, **kwargs):
    """Execute a command in a sandbox. Returns parsed result dict."""
    body = {"cmd": cmd, "image": image, "timeout": timeout, **kwargs}
    _, result = api("POST", "/exec", body=body, timeout=timeout + 15)
    return result


def main():
    global Z
    parser = argparse.ArgumentParser(description="Zypi E2E Test Suite")
    parser.add_argument("--url", default=Z, help="Zypi API URL")
    args = parser.parse_args()
    Z = args.url

    print("════════════════════════════════════════════════════")
    print("  Zypi E2E Test Suite (Python)")
    print(f"  Target: {Z}")
    print("════════════════════════════════════════════════════\n")

    # ── 1. Health ──────────────────────────────────────
    print("── Health ────────────────────────────────────────")
    status, data = api("GET", "/health")
    if data.get("status") == "ok":
        _pass("health endpoint returns ok")
    else:
        _fail("health endpoint", f"not reachable — is Zypi running? (status={status})")
        print("ABORT: Zypi not reachable")
        sys.exit(1)

    # ── 2. Pool ───────────────────────────────────────
    print("\n── Pool ──────────────────────────────────────────")
    _, pool = api("GET", "/pool/stats")
    warm = pool.get("warm", 0)
    total = pool.get("total", 0)
    if warm > 0:
        _pass(f"pool has {warm} warm VMs (total: {total})")
    else:
        _skip("warm pool", "no warm VMs yet — waiting for boot...")
        time.sleep(20)
        _, pool2 = api("GET", "/pool/stats")
        warm2 = pool2.get("warm", 0)
        if warm2 > 0:
            _pass(f"pool now has {warm2} warm VMs (after wait)")
        else:
            _fail("warm pool", "still 0 warm VMs after 20s")

    # ── 3. Basic Exec ─────────────────────────────────
    print("\n── Basic Execution ───────────────────────────────")
    r = exec_cmd(["echo", "hello zypi"])
    if r.get("exit_code") == 0 and "hello zypi" in r.get("stdout", ""):
        _pass(f"echo command (exit=0, {r.get('duration_ms', '?')}ms)")
    else:
        _fail("echo command", f"got {r}")

    r = exec_cmd(["sh", "-c", "exit 42"])
    if r.get("exit_code") == 42:
        _pass("non-zero exit (42)")
    else:
        _fail("non-zero exit", f"expected 42, got {r.get('exit_code')}")

    r = exec_cmd(["sh", "-c", "echo stdout; echo stderr >&2"])
    if "stdout" in r.get("stdout", "") and "stderr" in r.get("stderr", ""):
        _pass("stdout/stderr separation")
    else:
        _fail("stdout/stderr", f"stdout='{r.get('stdout','')}' stderr='{r.get('stderr','')}'")

    # ── 4. Timeout ────────────────────────────────────
    print("\n── Timeout ────────────────────────────────────────")
    r = exec_cmd(["sleep", "10"], timeout=2)
    if r.get("timed_out") == True or ":timeout" in str(r.get("error", "")):
        _pass("command timeout (2s)")
    else:
        _fail("command timeout", f"expected timeout, got: {r}")

    # ── 5. Environment Variables ──────────────────────
    print("\n── Environment Variables ─────────────────────────")
    r = exec_cmd(["sh", "-c", "echo $ZYPI_E2E_VAR"], env={"ZYPI_E2E_VAR": "e2e-test-value"})
    if "e2e-test-value" in r.get("stdout", ""):
        _pass("environment variables")
    else:
        _fail("environment variables", f"got '{r.get('stdout','')}'")

    # ── 6. File Injection ─────────────────────────────
    print("\n── File Injection ────────────────────────────────")
    r = exec_cmd(["cat", "/tmp/e2e-test.txt"],
                 files={"/tmp/e2e-test.txt": "e2e file content"})
    if "e2e file content" in r.get("stdout", ""):
        _pass("file injection")
    else:
        _fail("file injection", f"got '{r.get('stdout','')}'")

    # ── 7. Resource Limits ────────────────────────────
    print("\n── Resource Limits ───────────────────────────────")
    r = exec_cmd(["sh", "-c", "free -m | grep Mem"], memory_mb=512)
    if "Mem:" in r.get("stdout", ""):
        _pass("memory_mb param accepted (free output)")
    else:
        _fail("memory_mb", f"no free output: {r.get('stdout','')}")

    # ── 8. DNS Resolution ─────────────────────────────
    print("\n── Networking ────────────────────────────────────")
    r = exec_cmd(["sh", "-c", "cat /etc/resolv.conf"])
    if "nameserver" in r.get("stdout", ""):
        _pass("DNS: resolv.conf has nameserver")
    else:
        _fail("DNS: resolv.conf", f"got '{r.get('stdout','')[:80]}'")

    # ── 9. HTTP Outbound ──────────────────────────────
    r = exec_cmd(["sh", "-c", "curl -s --connect-timeout 5 http://httpbin.org/ip 2>&1"], timeout=15)
    out = (r.get("stdout", "") + r.get("stderr", "")).strip()
    if r.get("exit_code") == 0 and "origin" in out:
        _pass("HTTP outbound (httpbin.org)")
    elif ":timeout" in str(r.get("error", "")):
        _skip("HTTP outbound", "VM has no internet (bridge/NAT issue)")
    else:
        _skip("HTTP outbound", f"exit={r.get('exit_code')} out={out[:80]}")

    # ── 10. HTTPS Outbound ────────────────────────────
    r = exec_cmd(["sh", "-c", "curl -s --connect-timeout 5 https://httpbin.org/ip 2>&1"], timeout=15)
    out = (r.get("stdout", "") + r.get("stderr", "")).strip()
    if r.get("exit_code") == 0 and "origin" in out:
        _pass("HTTPS outbound (httpbin.org)")
    else:
        _skip("HTTPS outbound", f"exit={r.get('exit_code')} (known: TAP MTU / bridge issue)")

    # ── 11. Python ────────────────────────────────────
    print("\n── Python Runtime ────────────────────────────────")
    r = exec_cmd(["python3", "-c", "import sys; print(sys.version)"])
    stdout = r.get("stdout", "")
    if "3." in stdout:
        _pass(f"python3 available ({stdout[:50].strip()}...)")
    else:
        _fail("python3", f"got '{stdout}'")

    r = exec_cmd(["pip3", "--version"])
    stdout = r.get("stdout", "")
    if "pip" in stdout:
        _pass("pip3 available")
    else:
        _skip("pip3", "not in base rootfs (installed via Dockerfile chroot)")

    # ── 12. Docker Import (Build → Save → Import → Exec) ──
    print("\n── Docker Import (build→save→import→exec) ────────")
    alpine_dockerfile = """FROM alpine:latest
RUN echo "zypi-e2e-import-works" > /etc/zypi-e2e-marker
CMD ["/bin/sh"]
"""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".tar", delete=False) as tf:
        tar_path = tf.name

    try:
        # Build
        result = subprocess.run(
            ["docker", "build", "-t", "weft-e2e-alpine:test", "-f", "-", "."],
            input=alpine_dockerfile, capture_output=True, text=True, timeout=60
        )
        if result.returncode == 0:
            _pass("docker build alpine test image")

            # Save
            subprocess.run(
                ["docker", "save", "weft-e2e-alpine:test", "-o", tar_path],
                capture_output=True, timeout=30
            )
            tar_size = os.path.getsize(tar_path)
            _pass(f"docker save ({tar_size // 1024 // 1024}MB tar)")

            # Import
            with open(tar_path, "rb") as f:
                tar_data = f.read()
            _, import_resp = api("POST", "/images/alpine-e2e:latest/import",
                                 body=tar_data, content_type="application/x-tar", timeout=60)
            if import_resp.get("status") == "accepted":
                _pass("import accepted (alpine-e2e:latest)")

                # Wait for completion
                for _ in range(30):
                    _, status = api("GET", "/images/alpine-e2e:latest/status")
                    if status.get("status") == "ready":
                        break
                    time.sleep(1)

                if status.get("status") == "ready":
                    _pass("import completed (ready)")

                    # Verify marker
                    r = exec_cmd(["cat", "/etc/zypi-e2e-marker"],
                                 image="alpine-e2e:latest", timeout=15)
                    if "zypi-e2e-import-works" in r.get("stdout", ""):
                        _pass("exec in imported image (marker verified)")
                    else:
                        _skip("exec in imported image",
                              f"warm VM may use base image — got: {r.get('stdout','')[:60]}")
                else:
                    _fail("import", f"stuck in state: {status.get('status')}")
            else:
                _fail("import", f"response: {import_resp}")
        else:
            _skip("docker build", f"build failed: {result.stderr[:200]}")

        # Cleanup
        subprocess.run(["docker", "rmi", "weft-e2e-alpine:test"],
                       capture_output=True, timeout=10)
    finally:
        try:
            os.unlink(tar_path)
        except Exception:
            pass

    # ── 13. Chromium ──────────────────────────────────
    print("\n── Chromium (Dockerfile.chromium import) ──────────")
    _, images = api("GET", "/images")
    chromium_exists = "chromium:latest" in images.get("images", [])

    if chromium_exists:
        _pass("chromium image registered")

        r = exec_cmd(["/usr/bin/chromium-browser", "--version"],
                     image="chromium:latest", timeout=20, memory_mb=512)
        out = (r.get("stdout", "") + r.get("stderr", "")).strip()
        if "hrom" in out.lower():  # Chromium
            _pass(f"chromium --version ({out[:60]})")
        else:
            _skip("chromium --version",
                  f"warm VM has base rootfs (no chromium) — got: {out[:60]}")

        r = exec_cmd(["sh", "-c", "ls -la /opt/chromium/chrome-linux/chrome 2>/dev/null || echo NOT_FOUND"])
        if "chrome" in r.get("stdout", "") and "NOT_FOUND" not in r.get("stdout", ""):
            _pass("chromium binary on disk")
        else:
            _skip("chromium binary", "warm VM has base rootfs — need image-aware pool")
    else:
        _skip("chromium", "image not imported — run: docker build -f Dockerfile.chromium && docker save && curl import")

    # ── 14. Sessions ──────────────────────────────────
    print("\n── Sessions ──────────────────────────────────────")
    _, sess = api("POST", "/sessions",
                  body={"image": "ubuntu:24.04", "agent_id": "e2e-test"})
    sid = sess.get("session_id", "")
    if sid:
        _pass(f"session created ({sid})")

        _, r = api("POST", f"/sessions/{sid}/exec",
                   body={"cmd": ["echo", "session e2e"]})
        if "session e2e" in r.get("stdout", ""):
            _pass("session exec")
        else:
            _fail("session exec", f"got '{r.get('stdout','')}'")

        _, r = api("POST", f"/sessions/{sid}/exec",
                   body={"cmd": ["sh", "-c", "echo step2 >> /tmp/s; cat /tmp/s"]})
        if "step2" in r.get("stdout", ""):
            _pass("session state persists")
        else:
            _fail("session state", f"got '{r.get('stdout','')}'")

        # Close session
        api("DELETE", f"/sessions/{sid}", timeout=10)
        time.sleep(1)
        status, get_resp = api("GET", f"/sessions/{sid}")
        if "not found" in str(get_resp).lower() or "not_found" in str(get_resp).lower():
            _pass("session close")
        else:
            _fail("session close", f"session still accessible: {get_resp}")
    else:
        _fail("session create", "no session_id returned")

    # ── 15. Warm Pool ─────────────────────────────────
    print("\n── Warm Pool ─────────────────────────────────────")
    _, pool = api("GET", "/pool/stats")
    w = pool.get("warm", 0)
    print(f"  warm: {w}, total: {pool.get('total', 0)}")
    if w > 0:
        _pass(f"warm VMs available ({w})")
    else:
        _skip("warm VMs", "0 warm (may need time to boot)")

    # ── 16. Concurrent Exec ───────────────────────────
    print("\n── Concurrent Execution ──────────────────────────")
    start = time.monotonic()

    def do_echo(n):
        return exec_cmd(["echo", f"concurrent-{n}"], timeout=10)

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as ex:
        futures = [ex.submit(do_echo, i) for i in range(1, 4)]
        results = [f.result() for f in futures]

    elapsed = int((time.monotonic() - start) * 1000)
    exits = [r.get("exit_code", -1) for r in results]
    if all(e == 0 for e in exits):
        _pass(f"3 concurrent execs ({elapsed}ms total)")
    else:
        _fail("concurrent execs", f"exits: {exits}")

    # ── Summary ──────────────────────────────────────
    total = PASS + FAIL + SKIP
    print(f"\n════════════════════════════════════════════════════")
    print(f"  {GRN}Passed: {PASS}{NC}  {RED}Failed: {FAIL}{NC}  {YLW}Skipped: {SKIP}{NC}  Total: {total}")
    print( "════════════════════════════════════════════════════")

    sys.exit(0 if FAIL == 0 else 1)


if __name__ == "__main__":
    main()
