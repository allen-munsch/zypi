# Zypi × MosaicDB Agent Fabric — Integration Test Plan

## Architecture Under Test

```
┌─────────────────────────────────────────────────────┐
│                  TEST HARNESS                         │
│  Test Runner (ExUnit + Python)                        │
│    ├── Unit tests (Mosaic.Fabric.Sandbox)             │
│    ├── Integration tests (MCP → Zypi HTTP → VM)       │
│    ├── E2E agent workflow tests                       │
│    ├── Chaos tests (Zypi crash, network loss)          │
│    └── Performance benchmarks                          │
└──────────┬──────────────────────────┬────────────────┘
           │ MCP (JSON-RPC)           │ HTTP REST
           ▼                          ▼
┌─────────────────────┐   ┌──────────────────────────┐
│      MOSAICDB        │   │         ZYPI              │
│  MCP Server :4040    │──▶│  HTTP API :4000           │
│  Fabric Sandbox      │   │  /exec, /containers       │
│  Agent Memory        │   │  /pool/stats, /health     │
│  Graph + Handles     │   │  VMPool → Firecracker     │
└─────────────────────┘   └──────────────────────────┘
```

---

## Phase 0: Prerequisites & Environment

### 0.1 Zypi Setup Verification
- [ ] Zypi boots and health endpoint returns 200
- [ ] Firecracker binary found and KVM available
- [ ] Base rootfs exists (`/opt/zypi/rootfs/ubuntu-24.04.ext4`)
- [ ] Kernel exists (`/opt/zypi/kernel/vmlinux`)
- [ ] zypi-agent binary exists and is executable
- [ ] Network bridge `zypi0` configured
- [ ] VMPool warm VMs reachable (TCP to agent port 9999)

### 0.2 MosaicDB Setup Verification
- [ ] MosaicDB compiles clean
- [ ] MCP server starts on :4040
- [ ] Fabric config enabled: `config :mosaic, :fabric, enabled: true`
- [ ] `FABRIC_SANDBOX_URL` points to Zypi `http://localhost:4000`
- [ ] Mosaic can reach Zypi health endpoint

### 0.3 Test Image Preparation
- [ ] `ubuntu:24.04` base image imported into Zypi
- [ ] `python:3.12-slim` imported
- [ ] `alpine:latest` imported
- [ ] Custom agent image with numpy/pandas pre-installed

**Test script:** `test/support/setup_fabric.exs`

---

## Phase 1: Unit Tests — Mosaic Fabric Layer

### 1.1 Sandbox Client (`Mosaic.Fabric.Sandbox`)
**File:** `test/mosaic/fabric/sandbox_test.exs`

| Test | What It Proves |
|------|---------------|
| `available?/0 returns true when Zypi healthy` | Connectivity check works |
| `available?/0 returns false when Zypi down` | Graceful unavailability detection |
| `available?/0 returns false when fabric disabled` | Config gating works |
| `run/2 executes simple command, returns exit 0` | Basic sandbox execution |
| `run/2 captures stdout correctly` | Output capture working |
| `run/2 captures stderr on failure` | Error output capture |
| `run/2 respects timeout` | Timeout enforcement |
| `run/2 injects files into sandbox` | File injection via agent |
| `run/2 returns exit code for failing command` | Non-zero exit codes |
| `run/2 passes environment variables` | Env var propagation |
| `run/2 respects workdir` | Working directory set |
| `session_create/1 returns session info` | Session creation |
| `session_exec/3 runs command in existing session` | Session multi-exec |
| `session_close/1 destroys sandbox` | Session cleanup |
| `session_create fails gracefully when Zypi down` | Error handling |
| `pool_stats/0 returns VM pool info` | Pool observability |

### 1.2 Agent Memory (`Mosaic.Fabric.AgentMemory`)
**File:** `test/mosaic/fabric/agent_memory_test.exs`

| Test | What It Proves |
|------|---------------|
| `write/3 creates memory node in graph` | Memory persistence |
| `write/3 returns compact handle stub` | Handle creation |
| `write/3 links to existing memories` | Graph edge creation |
| `read/3 returns semantically relevant memories` | Vector search for memories |
| `read/3 respects tag filters` | Tag filtering |
| `link/3 creates edge between memories` | Manual linking |
| `context/2 returns agent neighborhood` | Graph context retrieval |
| `context/2 includes centrality stats` | God-node detection |
| `record_execution/4 creates execution + result nodes` | Auto-recording |
| `record_execution/4 creates agent→exec→sandbox edges` | Graph topology |
| `timeline/2 returns chronological events` | Time ordering |
| `ensure_agent_node/1 is idempotent` | Node dedup |

### 1.3 MCP Tool Dispatch (`Mosaic.MCP.Tools`)
**File:** `test/mosaic/mcp/tools_fabric_test.exs`

| Test | What It Proves |
|------|---------------|
| `list_tools/0 includes all 3 fabric tools` | Tool registration |
| `fabric_sandbox_run` returns exec result with handle | End-to-end tool call |
| `fabric_sandbox_run` auto-records in memory | Auto-memory side effect |
| `fabric_sandbox_run` returns error when fabric disabled | Feature gate |
| `fabric_sandbox_session create` returns session JSON | Session creation tool |
| `fabric_sandbox_session exec` runs in session | Session exec tool |
| `fabric_sandbox_session close` cleans up | Session close tool |
| `fabric_agent_observe` returns graph topology | Observation tool |
| `fabric_agent_observe` includes sandbox pool stats | Pool visibility |
| `fabric_agent_observe` returns agent-specific data | Agent filtering |

---

## Phase 2: Integration Tests — MCP Client → Zypi VM

### 2.1 Cold-Start Flow
**Test:** `test/integration/fabric_cold_start_test.exs`

```
GIVEN: Zypi running, no pre-warmed VMs
WHEN:  MCP tool fabric_sandbox_run called with ["echo", "hello"]
THEN:
  - Zypi creates container
  - Zypi starts Firecracker VM (cold boot)
  - Agent health check passes
  - Command executes
  - stdout = "hello\n"
  - exit_code = 0
  - Duration logged
  - VM destroyed after execution
  - Execution recorded in Mosaic graph
  - Handle stub returned for result
```

### 2.2 Warm-VM Flow
```
GIVEN: Zypi VMPool has pre-warmed VMs
WHEN:  fabric_sandbox_run called
THEN:
  - Warm VM acquired (no boot wait)
  - Execution time < 500ms (not counting VM boot)
  - VM returned to pool (recycled)
```

### 2.3 Session Multi-Step Agent Workflow
**Test:** `test/integration/fabric_session_workflow_test.exs`

```
GIVEN: Agent "data-scientist-01"
WHEN:
  1. fabric_sandbox_session {action: "create", image: "python:3.12", agent_id: "..."}
  2. fabric_sandbox_session {action: "exec", cmd: ["pip", "install", "numpy"]}
  3. fabric_sandbox_session {action: "exec", cmd: ["python", "-c", "import numpy; print(numpy.__version__)"]}
  4. fabric_sandbox_session {action: "close"}
THEN:
  - Step 1: session_id returned
  - Step 2: pip output captured, exit 0
  - Step 3: numpy version printed
  - Step 4: sandbox destroyed
  - Each exec auto-recorded in agent memory graph
  - fabric_agent_observe shows 2 executions for this agent
```

### 2.4 File Injection Workflow
```
GIVEN: Agent needs to analyze a CSV
WHEN:  fabric_sandbox_run {
         cmd: ["python", "/data/analyze.py"],
         files: {
           "/data/analyze.py": "import csv\n...",
           "/data/input.csv": "col1,col2\n1,2\n3,4"
         }
       }
THEN:
  - Files written to sandbox before execution
  - Python script reads CSV
  - stdout contains analysis output
  - Files cleaned up after execution
```

### 2.5 Memory Fabric Persistence
```
GIVEN: Agent "agent-01" with prior executions
WHEN:
  1. fabric_agent_observe {agent_id: "agent-01"}
  2. mosaic_memory_recall {session_id: "agent-01", query: "what did I run"}
THEN:
  - Observe shows execution history
  - Recall returns semantic matches to prior executions
  - Handles can be expanded for full results
  - Timeline shows chronological order
```

---

## Phase 3: Chaos & Resilience Tests

### 3.1 Zypi Unavailability
```
GIVEN: MosaicDB fabric enabled, Zypi STOPPED
WHEN:  fabric_sandbox_run called
THEN:
  - Returns clear error: "sandbox not available"
  - Does NOT crash MosaicDB
  - All memory tools still work (graceful degradation)
  - fabric_agent_observe shows "sandbox pool: unavailable"
```

### 3.2 Zypi Crash During Execution
```
GIVEN: Zypi running, command executing in VM
WHEN:  Zypi process killed mid-execution
THEN:
  - MCP call returns timeout error
  - Orphaned VM eventually cleaned up
  - No resource leak (IPs, rootfs copies)
  - Subsequent calls recover cleanly
```

### 3.3 Agent Memory Corruption Recovery
```
GIVEN: Graph database has agent memories
WHEN:  SQLite shard file forcibly truncated
THEN:
  - mosaic_status reports degraded state
  - Remaining shards still queryable
  - New memories can be written
```

### 3.4 Concurrent Agent Storm
```
GIVEN: 10 agents issuing sandbox commands simultaneously
WHEN:  Each runs fabric_sandbox_run with different images
THEN:
  - No deadlocks
  - VMPool expands to meet demand (up to max_warm)
  - All executions complete within timeout
  - IP pool doesn't exhaust
  - Memory graph handles all concurrent writes
```

### 3.5 VM Pool Exhaustion
```
GIVEN: VMPool at max_total capacity
WHEN:  More sandbox requests arrive than available VMs
THEN:
  - Requests queue or return "cold" status
  - No OOM on host
  - Pool stats reflect saturation
```

---

## Phase 4: Performance Benchmarks

### 4.1 Cold Boot Latency
| Metric | Target | Measurement |
|--------|--------|-------------|
| Container create | < 50ms | `Manager.create` elapsed |
| VM boot to agent ready | < 2s | TCP connect to agent port |
| First exec after boot | < 500ms | `Agent.exec` round-trip |
| Total cold exec | < 3s | POST /exec → response |

### 4.2 Warm VM Latency
| Metric | Target |
|--------|--------|
| Warm VM acquire | < 50ms |
| Simple command exec | < 300ms |
| Session exec (subsequent) | < 200ms |

### 4.3 Memory Fabric Latency
| Metric | Target |
|--------|--------|
| `write/3` (store memory) | < 100ms |
| `read/3` (semantic recall, 10K nodes) | < 500ms |
| `record_execution/4` | < 100ms |
| `context/2` (agent neighborhood) | < 200ms |

### 4.4 Throughput
| Metric | Target |
|--------|--------|
| Concurrent sandbox executions | ≥ 10/sec with 10 warm VMs |
| Concurrent memory writes | ≥ 50/sec |
| Graph traversal (depth 5) | < 1s for 100K nodes |

---

## Phase 5: End-to-End Agent Scenario Tests

### 5.1 Data Analysis Agent
```
SCENARIO: Agent analyzes a dataset
  1. mosaic_memo {content: "Need to analyze sales data", label: "task"}
  2. fabric_sandbox_run {cmd: ["python", "analyze.py"], files: {script, data}}
  3. Agent reads results from handle
  4. mosaic_memo {content: "Found: Q4 revenue up 12%", label: "findings"}
  5. mosaic_memory_consolidate {session_id: agent_id}
  6. fabric_agent_observe → verify full audit trail
```

### 5.2 Multi-Agent Collaboration
```
SCENARIO: Two agents share memory
  1. Agent-A: fabric_sandbox_run {cmd: ["curl", "api.example.com/data"]}
  2. Agent-A: mosaic_memo {content: result, label: "api-data"}
  3. Agent-B: mosaic_memory_recall {query: "api data"}
  4. Agent-B retrieves Agent-A's result via handle
  5. Verify cross-agent graph edges exist
```

### 5.3 Long-Running Training Job
```
SCENARIO: Agent runs ML training
  1. fabric_sandbox_session create {image: "pytorch:latest"}
  2. fabric_sandbox_session exec {cmd: ["python", "train.py"], timeout: 600}
  3. Training output streamed (future: SSE)
  4. Training completes, model saved to sandbox
  5. Agent reads model via file.read (future feature)
  6. Session closed
  7. Execution recorded with 600s duration
```

---

## Phase 6: FlowEngine Rustler NIF Integration (Future)

### 6.1 Assessment
FlowEngine (https://github.com/allen-munsch/flowengine) is a Rust-based DAG workflow engine with:
- `flowcore`: Node trait, Workflow, Value, EventBus (iggy-backed)
- `flowruntime`: DAG executor with parallel execution
- `flownodes`: HTTP, transform, time, debug, **Docker** nodes
- `flowserver`: HTTP API (planned)

### 6.2 Integration Points
| FlowEngine Component | Zypi Integration | Value |
|---------------------|------------------|-------|
| `WorkflowExecutor` | Replace `Zypi.Executor` DAG logic | Multi-step agent workflows with dependencies |
| `DockerNodeV2` | Map docker commands to Zypi VMs | Agent can define workflow with sandbox steps |
| `EventBus (iggy)` | Stream VM events to mosaic | Real-time agent observability |
| `Value` type system | Standardize sandbox I/O types | Type-safe data passing between sandbox steps |
| `NodeRegistry` | Register sandbox nodes as flow nodes | Extensible sandbox primitives |

### 6.3 Rustler NIF Strategy
```elixir
# lib/zypi/flow_engine.ex (new)
defmodule Zypi.FlowEngine do
  use Rustler, otp_app: :zypi, crate: "zypi_flow"

  # Execute a DAG workflow where each node is a sandbox execution
  def execute_workflow(json_spec), do: :erlang.nif_error(:nif_not_loaded)

  # Register a custom sandbox node type
  def register_node(name, config), do: :erlang.nif_error(:nif_not_loaded)

  # Get workflow status/events
  def workflow_status(execution_id), do: :erlang.nif_error(:nif_not_loaded)
end
```

### 6.4 Phase 6 Milestones
- [ ] Create `native/zypi_flow/` Rust crate with Rustler
- [ ] Implement `execute_workflow/1` NIF wrapping flowruntime
- [ ] Add `SandboxNode` type that maps to Zypi HTTP exec
- [ ] Connect flowengine EventBus → MosaicDB telemetry
- [ ] Benchmark: workflow DAG vs. sequential exec calls
- [ ] Expose as MCP tool: `fabric_workflow_run`

---

## Test Infrastructure

### Test Helpers Needed

```elixir
# test/support/fabric_case.ex
defmodule Mosaic.FabricCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Mosaic.FabricCase
      @moduletag :fabric
    end
  end

  # Skip tests if fabric not available
  def ensure_fabric! do
    unless Mosaic.Fabric.Sandbox.available?() do
      raise "Fabric not available — ensure Zypi is running and fabric config is set"
    end
  end

  # Wait for Zypi VMPool to have N warm VMs
  def wait_for_warm_vms(count, timeout_ms \\ 30_000)
end
```

### Docker Compose Test Environment

```yaml
# docker-compose.test.yml
services:
  zypi:
    build: ./zypi
    privileged: true
    devices: [/dev/kvm, /dev/net/tun]
    ports: ["4000:4000"]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4000/health"]
      interval: 5s
      timeout: 2s
      retries: 10

  mosaic-test:
    build: ./mosaic
    depends_on:
      zypi:
        condition: service_healthy
    environment:
      FABRIC_ENABLED: "true"
      FABRIC_SANDBOX_URL: "http://zypi:4000"
      MIX_ENV: test
    command: mix test --only fabric
```

### Git Hooks

```bash
# .githooks/pre-push — run fabric tests before pushing
#!/bin/bash
mix test --only fabric:integration || exit 1
```

---

## Success Criteria

- [ ] All Phase 1 unit tests pass (sandbox client + agent memory + MCP tools)
- [ ] All Phase 2 integration tests pass (cold boot, warm VM, session, files)
- [ ] All Phase 3 chaos tests pass (graceful degradation, no leaks)
- [ ] Phase 4 benchmarks meet targets
- [ ] Phase 5 E2E agent scenarios pass (data analysis, multi-agent, training)
- [ ] Zero Zypi changes required (the FABRIC.md contract holds)
- [ ] MosaicDB memory tools remain fully functional without Zypi
- [ ] Test coverage ≥ 85% for fabric code paths

---

## Running the Tests

```bash
# All fabric tests
mix test --only fabric

# Unit tests only (fast, no Zypi needed for most)
mix test --only fabric:unit

# Integration tests (requires Zypi running)
mix test --only fabric:integration

# Chaos tests (destructive — run in CI only)
mix test --only fabric:chaos

# Benchmarks
mix test --only fabric:bench

# Full suite with docker-compose
docker compose -f docker-compose.test.yml up --abort-on-container-exit
```
