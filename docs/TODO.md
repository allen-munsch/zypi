# Zypi — Future Considerations & TODO

## Egress Firewall: iron-proxy Integration

**Source**: https://github.com/ironsh/iron-proxy
**Status**: TODO — design phase

iron-proxy is a MITM egress proxy with built-in DNS that enforces default-deny
at the network boundary for untrusted workloads. It complements Zypi's VM-level
isolation with network-level isolation.

### Current Zypi Networking

```
Sandbox VM (10.0.0.x) → tap bridge (zypi0) → iptables MASQUERADE → internet
                                                      ↑
                                             ALL traffic allowed
```

Every sandbox has unrestricted outbound internet access (after the DNS fix).
A compromised sandbox can exfiltrate data, phone home, or probe internal networks.

### Proposed: iron-proxy Integration

```
Sandbox VM (10.0.0.x) → tap bridge (zypi0) → iron-proxy (10.0.0.1:8080) → internet
                                                      ↑
                                            Default-deny + allowlist
                                            Secret injection at boundary
                                            Per-request audit trail
```

### Integration Points

1. **Network routing**: Replace the iptables MASQUERADE rule with a redirect
   to iron-proxy running on the host. Zypi already sets up the bridge — just
   change the egress path.

2. **Per-sandbox policies**: Each agent session gets an egress allowlist:
   ```json
   {
     "agent_id": "agent-01",
     "allow_domains": ["pypi.org", "files.pythonhosted.org", "api.openai.com"],
     "deny_cidrs": ["169.254.169.254/32", "10.0.0.0/8"],
     "proxy_token": "token-agent-01-xyz"
   }
   ```

3. **Secret injection**: Agent workloads use proxy tokens instead of real
   API keys. iron-proxy swaps them at the boundary. A compromised sandbox
   can only exfiltrate a token that's worthless outside the proxy.

4. **Audit trail**: Every outbound request logged as structured JSON.
   Integrates with MosaicDB fabric memory — sandbox network activity
   becomes searchable in the agent memory graph.

### Implementation Approach

Option A — Host-level proxy (simpler):
- Run iron-proxy as a sidecar in the Zypi Docker Compose stack
- Route all sandbox traffic through it via iptables
- Single policy for all sandboxes (good enough for v1)

Option B — Per-sandbox proxy (more secure):
- iron-proxy supports multiple listeners with different configs
- Each sandbox routes through its own proxy listener
- Per-agent allowlists, per-agent tokens

### Dependencies

- iron-proxy binary or Docker image in the Zypi stack
- CA certificate generation for TLS interception
- Agent configuration model for egress policies
- Health check integration (proxy must be running before sandboxes)

---

## Session Persistence Across Restarts

**Status**: TODO

Sessions are currently in-memory (GenServer state). Zypi restart = all sessions
lost, orphaned VMs, leaked IPs. Options:
- Persist session state to disk (DETS, SQLite)
- Clean up orphaned VMs on startup (already partially done via cleanup.ex)
- Recover running VMs by scanning /var/lib/zypi/vms/

---

## Image Registry Pull

**Status**: TODO

Currently images must be imported via `POST /images/:ref/import` (tar upload).
No direct registry pull. `skopeo` is already installed in the Docker image.
Options:
- `POST /images/:ref/pull` → skopeo copy → overlaybd-apply → ext4
- Integration with containerd overlaybd-snapshotter for lazy pulling

---

## Handle-Based Result Protocol

**Status**: TODO

FABRIC.md describes Zypi returning compact handles for large outputs.
Currently stdout/stderr returned inline — can blow up MCP message sizes.
Options:
- POST /exec returns `stdout_handle: "$zypi_exec_a1b2c3"`
- GET /handles/:id expands handle to full output
- Auto-store in MosaicDB handle registry

---

## FlowEngine Rustler NIF

**Status**: TODO

FlowEngine's DAG executor could run inside Zypi via a Rustler NIF.
Would eliminate the HTTP round-trip for zypi.exec nodes.
Options:
- `native/zypi_flow/` Rust crate with Rustler
- `Zypi.FlowEngine.execute_workflow/1` NIF
- SandboxNode type → internal exec (no HTTP)

---

## Vsock Transport for Agent

**Status**: TODO

Agent supports vsock (port 52) with token auth, but host side only uses TCP.
Vsock is faster and more secure than TCP-over-tap.
Options:
- Host-side vsock dialing in Agent module
- vsock-first with TCP fallback
- Requires Firecracker vsock device configuration
