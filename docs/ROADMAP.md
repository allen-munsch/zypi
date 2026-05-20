# Zypi Roadmap — OCI Runtime + Agent Fabric

## Two Complementary Paths

```
                         ZYPI
                          │
          ┌───────────────┴───────────────┐
          ▼                               ▼
   ┌──────────────┐              ┌──────────────────┐
   │  OCI RUNTIME  │              │  AGENT FABRIC     │
   │  (Kata-style) │              │  (MosaicDB MCP)   │
   └──────┬───────┘              └────────┬─────────┘
          │                               │
          ▼                               ▼
   Docker + K8s                    AI Agents (Claude,
   containerd + CRI                Cursor, pi, LangChain,
   RuntimeClass                    custom Python/JS)
```

## Path A: OCI Runtime Spec (Kata / libkrun Compatible)

**Goal:** `docker run --runtime=zypi` and `kubectl apply -f pod.yaml --runtime-class=zypi`

| Phase | Deliverable | Effort |
|-------|------------|--------|
| A1 | `zypi-runtime` binary (OCI runtime spec: create/start/state/kill/delete) | 2-3 weeks |
| A2 | `containerd-shim-zypi-v2` (ttrpc shim v2 API) | 3-4 weeks |
| A3 | K8s RuntimeClass + node labels + scheduling | 1 week |
| A4 | Agent protocol upgrade (ttrpc, multi-container sandbox) | 2-3 weeks |
| A5 | containerd snapshotter integration (overlaybd) | 2 weeks |
| A6 | Initrd boot support, device passthrough, hotplug | 2-3 weeks |

**Current status: 0%** — not started.

## Path B: Agent Fabric (MosaicDB MCP Protocol)

**Goal:** AI agents execute untrusted code in Firecracker VMs with automatic memory graph recording.

| Phase | Deliverable | Status |
|-------|------------|--------|
| B1 | MosaicDB fabric client + MCP tools | ✅ **DONE** |
| B2 | Integration test suite (see docs/TEST_PLAN.md) | 🔴 TODO |
| B3 | Session API hardening (server-side sessions, streaming) | 🔴 TODO |
| B4 | Image pre-warming HTTP endpoint | 🔴 TODO |
| B5 | Agent identity propagation (X-Agent-ID) | 🔴 TODO |
| B6 | Handle-based result protocol | 🔴 TODO |
| B7 | Python SDK for fabric tools | 🔴 TODO |

**Current status: Phase B1 complete.** Phases B2-B7 in test plan.

## Path C: FlowEngine Rustler NIF (Future)

**Goal:** DAG-based agent workflow execution inside Zypi via Rust NIF.

| Phase | Deliverable |
|-------|------------|
| C1 | `native/zypi_flow/` Rust crate with Rustler |
| C2 | `Zypi.FlowEngine.execute_workflow/1` NIF |
| C3 | SandboxNode type → Zypi HTTP exec bridge |
| C4 | FlowEngine EventBus → MosaicDB telemetry |
| C5 | `fabric_workflow_run` MCP tool |

**Current status: Design only.** Requires flowengine crate published to crates.io or vendored.

## Zen Principle

> Zypi is a **standalone OCI microVM runtime**. MosaicDB is a **federated agent memory fabric**. The integration is a **protocol extension** (3 MCP tools), not code coupling. Either works without the other. Together they form a complete agent operating system.
