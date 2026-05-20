# Iron-Proxy Egress Firewall Integration

Zypi sandboxes now route outbound traffic through [iron-proxy](https://github.com/ironsh/iron-proxy) —
a MITM egress proxy that enforces **default-deny** at the network boundary.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   Zypi Container                         │
│                                                          │
│  ┌──────────────────┐       ┌──────────────────┐        │
│  │  Firecracker VM  │       │  Firecracker VM  │        │
│  │  10.0.0.8        │       │  10.0.0.9        │        │
│  │  http_proxy=     │       │  http_proxy=     │        │
│  │  10.0.0.1:8080   │       │  10.0.0.1:8080   │        │
│  └────────┬─────────┘       └────────┬─────────┘        │
│           │ ztap                    │ ztap              │
│           └──────────┬──────────────┘                   │
│                      ▼                                   │
│              ┌───────────────┐                           │
│              │  zypi0 bridge │                           │
│              │  10.0.0.1/24  │                           │
│              └───────┬───────┘                           │
│                      │                                   │
│              ┌───────▼───────┐                           │
│              │  iron-proxy   │                           │
│              │  :8080 (HTTP) │                           │
│              │  :8443 (HTTPS)│                           │
│              │  :5353 (DNS)  │                           │
│              └───────┬───────┘                           │
│                      │                                   │
│              ┌───────▼───────┐                           │
│              │  Allowlist?   │                           │
│              │  YES → proxy  │                           │
│              │  NO  → 403    │                           │
│              └───────┬───────┘                           │
└──────────────────────┼──────────────────────────────────┘
                       │
                  ┌────▼────┐
                  │ Internet │
                  └─────────┘
```

## How It Works

1. **At VM boot**: init script sets `http_proxy=http://10.0.0.1:8080` and `https_proxy` for all HTTP clients (curl, wget, pip, npm, Python requests, etc.).

2. **On outbound request**: traffic routes through iron-proxy's allowlist transform.

3. **Allowlist check**: domain must match an entry in `config/iron-proxy/config.yaml`. Match → proxied. No match → 403.

4. **Audit trail**: every request logged as structured JSON with host, method, action (allow/reject), status code, duration, and transform pipeline results.

## Configuration

File: `config/iron-proxy/config.yaml`

```yaml
transforms:
  - name: allowlist
    config:
      domains:
        - "pypi.org"
        - "api.openai.com"
        - "github.com"
        # ... add domains as needed
      cidrs:
        - "10.0.0.0/24"
```

See `config/iron-proxy/config.yaml` for the full annotated config with secret injection setup.

## Verifying

```bash
# Test allowed domain
curl -X POST http://localhost:4000/exec \
  -H "Content-Type: application/json" \
  -d '{"cmd":["sh","-c","http_proxy=http://10.0.0.1:8080 curl -s http://httpbin.org/ip"],"image":"ubuntu:24.04","timeout":15}'
# → {"exit_code":0,"stdout":"{\"origin\":\"...\"}"}

# Test blocked domain
curl -X POST http://localhost:4000/exec \
  -H "Content-Type: application/json" \
  -d '{"cmd":["sh","-c","http_proxy=http://10.0.0.1:8080 curl -s http://example.com"],"image":"ubuntu:24.04","timeout":15}'
# → {"exit_code":0,"stdout":""}  ← blocked, empty stdout

# Check proxy audit log
docker exec zypi-node curl -s http://10.0.0.1:9091/metrics  # Prometheus metrics
```

## Production Hardening

- [ ] **Enforce proxy for all traffic**: `iptables -t nat -A PREROUTING -i zypi0 -p tcp --dport 80 -j REDIRECT --to-port 8080`
- [ ] **TLS MITM mode**: generate CA certs, switch `tls.mode` to `mitm`, enable secret injection
- [ ] **Per-agent allowlists**: extend iron-proxy config with agent-specific domain rules
- [ ] **Prometheus metrics**: scrape iron-proxy's `/metrics` endpoint (port 9091)

## Files

| File | Purpose |
|------|---------|
| `config/iron-proxy/config.yaml` | Allowlist, DNS, TLS, transforms |
| `docker-compose.yaml` | iron-proxy sidecar service (optional, for separate container deployment) |
| `lib/zypi/image/init_generator.ex` | Sets `http_proxy`/`https_proxy` env vars in all sandboxes |
| `tools/test-iron-proxy.sh` | Smoke test for allowed/blocked domains |
