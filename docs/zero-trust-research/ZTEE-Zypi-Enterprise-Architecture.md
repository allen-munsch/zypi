Zero-Trust Execution Environment for Enterprise Agentic AI

*Zypi-Based Sovereign Virtualization Architecture*

Version 2.0 | Enterprise Reference Architecture

1\. Executive Summary

This document presents a refined architectural blueprint for deploying a
**Zero-Trust Execution Environment (ZTEE)** for enterprise Agentic AI
systems. The architecture replaces managed SaaS sandbox providers (such
as E2B) with **Zypi**—a self-hosted orchestration layer built on
Elixir/OTP and AWS Firecracker microVMs.

The transition from managed sandboxes to Zypi represents a fundamental
shift from 'renting' execution capacity to 'owning' the virtualization
substrate. This provides three critical enterprise advantages:

1.  **Data Sovereignty:** Agent-generated code and sensitive data never
    leave the organization's controlled perimeter, enabling GDPR, HIPAA,
    and PCI DSS compliance.

2.  **Hardware-Level Isolation:** Firecracker microVMs provide KVM-based
    virtualization where each agent session runs its own guest kernel,
    creating a 'blast radius of one' that contains any compromise.

3.  **Operational Control:** Elixir's OTP framework provides
    fault-tolerant supervision, enabling automatic recovery from crashes
    and eliminating zombie processes that plague custom orchestration
    scripts.

2\. The Agentic Threat Landscape

Agentic AI systems invert traditional security assumptions. The
'developer' is a probabilistic model, and the 'code' is generated
on-the-fly in response to potentially untrusted inputs. This creates
attack vectors that traditional container isolation cannot adequately
address.

2.1 The Shared Kernel Vulnerability

Standard Docker containers isolate processes using Linux namespaces and
cgroups, but they **share the host operating system's kernel**. If an AI
agent executes malicious code that exploits a kernel vulnerability
(e.g., Dirty Pipe, io\_uring exploits), the attacker can escape the
container and compromise the entire host node. In multi-tenant
environments, this exposes all concurrent agent sessions.

2.2 The Probabilistic Dilemma

LLMs are non-deterministic. A policy stating 'agents cannot access PANs'
is unenforceable when users can craft prompts like 'Ignore previous
instructions and decode the following string.' This necessitates a
security layer that operates independently of the model's training—a
deterministic guardrail at the gateway level that Zypi enables through
its integration hooks.

3\. Zypi Architecture: The Elixir-Firecracker Synergy

Zypi pairs Elixir's OTP (Open Telecom Platform) with Firecracker's
microVM model to create an isomorphic structure where each agentic
'thought' that requires code execution spawns a dedicated, lightweight
actor (Elixir process) supervising a dedicated, lightweight computer
(Firecracker microVM).

3.1 The Actor Model Mapping

Elixir runs on the BEAM virtual machine, which implements the Actor
Model of concurrency. There is a direct architectural isomorphism
between:

  - **Elixir Process:** Lightweight, isolated thread of execution
    communicating via message passing

  - **Firecracker microVM:** Isolated virtual machine communicating via
    vsock/network packets

In Zypi, a DynamicSupervisor spawns a GenServer process for every
execution request. This Elixir process manages the entire lifecycle of a
single Firecracker VM: allocating the TAP interface, configuring JSON
boot parameters, spawning the firecracker binary, monitoring for exit
signals, and cleaning up resources upon termination.

3.2 Firecracker Internals

Firecracker differs from QEMU in its minimalism—no BIOS, PCI bus, or USB
support. It supports only virtio-net and virtio-block devices.
Configuration occurs via an HTTP API over a Unix Domain Socket (UDS),
with Zypi acting as the HTTP client:

  - **PUT /boot-source:** Specifies kernel path and boot arguments

  - **PUT /drives/rootfs:** Attaches the agent's filesystem

  - **PUT /network-interfaces/eth0:** Attaches the TAP device

  - **PUT /actions/InstanceStart:** Boots the VM

3.3 Latency Optimization

Firecracker microVMs boot in as little as 125ms. When coupled with
Zypi's 'warm pool' strategies, the effective time-to-execution
approaches near-instantaneous speeds (\<10ms from pool lease). This is
achieved through a Zypi.Pool module that maintains a FIFO queue of
pre-booted GenServers paused in the Guest init loop, ready for immediate
assignment.

4\. ZTEE Architectural Pillars with Zypi

The refined architecture creates a 'defense-in-depth' model where each
layer assumes the others might fail. Zypi serves as the foundational
execution layer, integrating with complementary security components.

4.1 Policy & Audit Layer (The AI Firewall)

**Components:** Invariant Gateway, Microsoft Presidio, SIEM Integration

Invariant Gateway intercepts every prompt and every tool call before
they reach Zypi. This layer provides:

  - **Input Guardrails:** Blocks prompt injection attempts and filters
    requests against RBAC policies

  - **Output Guardrails (DLP):** Scans tool outputs via Presidio before
    they reach the LLM context, redacting PII/PCI data

  - **Immutable Audit Log:** Provides forensically-sound logging of
    every agent thought and action for compliance

***Zypi Integration:*** Middleware in the Zypi Elixir app asynchronously
sends trace data to Invariant. Every POST /execute request (containing
raw code) and its response (stdout/stderr) is logged as a 'Tool Use'
span.

4.2 Human-in-the-Loop Orchestration

**Components:** n8n Workflow Engine, Slack/Teams Integration

Risk-based routing codifies human business logic. Invariant routes
low-risk calls (read-only operations) directly to Zypi for instant
execution, while high-risk calls (execute Python, access PII) are
forwarded to n8n workflows that pause execution until human approval is
received via Slack or Teams.

4.3 Execution & Isolation Layer (Zypi)

**Components:** Zypi Orchestrator, Firecracker MicroVMs, Optional
Asterinas Kernel

This is the 'blast-radius-of-one' execution layer that replaces E2B and
container-based sandboxes:

  - **Hardware-Level Isolation:** Each agent session runs in a separate
    microVM with its own guest kernel via KVM

  - **Memory-Safe Kernel Option:** For paranoid-level defense, run
    microVMs with Asterinas (Rust-based kernel) to eliminate 70% of CVEs
    caused by memory-safety vulnerabilities

  - **Ephemeral Execution:** VMs are destroyed after task completion,
    wiping any potential persistence mechanisms

4.4 Identity & Access Management

**Components:** Nginx (Identity Gateway), Keycloak/Okta (IdP), HashiCorp
Vault

Nginx validates OIDC tokens before any request reaches Zypi. A critical
design choice is **Token Exchange**: Nginx validates the user's JWT,
strips it, and injects a Zypi-Authorization system header. This ensures
users cannot bypass Nginx to hit Zypi directly.

5\. Component Reference Matrix

The following table maps each architectural layer to its implementing
components and Zypi integration points:

|                |                      |                    |                                     |
| -------------- | -------------------- | ------------------ | ----------------------------------- |
| **Layer**      | **Component**        | **Technology**     | **Zypi Integration**                |
| Policy & Audit | AI Firewall          | Invariant Gateway  | Async trace export via middleware   |
| Policy & Audit | PII Redaction        | Microsoft Presidio | Pre-execution scan via Zypi hook    |
| Orchestration  | Approval Workflow    | n8n + Slack        | Webhook callback on approval        |
| Execution      | VM Orchestrator      | Zypi (Elixir/OTP)  | Core component                      |
| Execution      | MicroVM Runtime      | Firecracker + KVM  | Spawned per GenServer               |
| Identity       | Gateway PEP          | Nginx + OIDC       | Token exchange header injection     |
| Identity       | Identity Provider    | Keycloak/Okta      | External IdP, no direct integration |
| Secrets        | Credential Injection | HashiCorp Vault    | Ephemeral creds to Guest VM         |

6\. Deployment Strategy: The Untrusted Zone

To fully realize the security benefits of Zypi, the Execution Layer must
be physically and logically decoupled from the Control Plane and Data
Plane. We implement **infrastructure isolation**, not just software
isolation.

6.1 DMZ Topology

Deploy Zypi execution nodes in a dedicated, isolated VPC or Kubernetes
cluster labeled 'Untrusted'. This cluster has no network route to the
corporate internal network.

1.  **Isolated VPC/Cluster:** No lateral movement, no implicit trust, no
    flat networks

2.  **Strict Network Whitelisting:** Firewall accepts ingress only from
    Invariant Gateway and n8n IP addresses

3.  **Controlled Egress:** Outbound access only to tool-specific URLs
    and package registries (optionally proxied)

4.  **Ephemeral Infrastructure:** Auto-scaling group recycles worker
    nodes every 24 hours, wiping potential footholds

6.2 Confidential Computing Option

For ultimate hardening, deploy Zypi nodes on Confidential VMs using AMD
SEV-SNP or Intel TDX. This ensures microVM memory is cryptographically
encrypted at the hardware level. Even if a malicious agent escapes the
microVM and compromises the host OS, they cannot read memory of other
concurrent agents or the hypervisor.

6.3 Zypi Container Requirements

The Zypi container must run with specific privileges to access
virtualization hardware:

  - **--privileged:** Required to access /dev/kvm and manipulate network
    interfaces

  - **Volume Mounts:** /var/run/zypi for UDS sockets, /var/log/zypi for
    audit logs, /var/lib/zypi for kernel/rootfs images

  - **Seccomp Filters:** Applied to Firecracker process itself for
    syscall restriction even if Guest escapes

7\. Risk-Based Routing Matrix

The following matrix defines how Invariant Gateway routes requests to
Zypi based on assessed risk level:

|            |                                       |                                   |                              |
| ---------- | ------------------------------------- | --------------------------------- | ---------------------------- |
| **Risk**   | **Definition**                        | **Examples**                      | **Zypi Action**              |
| **LOW**    | Read-only, public data, idempotent    | search\_docs, get\_weather        | Direct execute via warm pool |
| **MEDIUM** | Internal data, non-destructive writes | draft\_email, query\_internal\_db | Log to SIEM, then execute    |
| **HIGH**   | Destructive writes, PII, code exec    | execute\_python, delete\_user     | Route to n8n, await approval |

8\. Migration Strategy: E2B to Zypi

Transitioning from E2B to Zypi requires a phased approach to minimize
disruption. The recommended strategy uses the **Client Adapter Pattern**
to maintain backward compatibility.

8.1 The Shim SDK Approach

Implement a ZypiSandbox class that matches the E2B interface but directs
traffic to the Zypi API. This allows developers to swap 'from
zypi\_adapter import ZypiSandbox as Sandbox' and maintain existing agent
behavior without code changes.

8.2 Migration Phases

1.  **Phase 1 - Parallel Run:** Deploy Zypi alongside E2B. Route 10% of
    traffic to Zypi via feature flag.

2.  **Phase 2 - Validation:** Compare execution results, latency, and
    error rates between E2B and Zypi.

3.  **Phase 3 - Gradual Cutover:** Increase Zypi traffic to 50%, then
    90%, monitoring for regressions.

4.  **Phase 4 - Deprecation:** Disable E2B integration after 30 days of
    stable Zypi operation.

9\. Operational Playbook

9.1 Key Rotation Strategy

Use a 'restart' strategy: Update the .env file with new keys and run
'docker-compose up -d'. Because Zypi components are stateless, they
restart with new configuration in seconds. For zero-downtime rotation,
implement Blue/Green deployment with dual containers and Nginx weight
shifting.

9.2 Disaster Recovery

In the event of primary provider outage:

  - Update OPENAI\_API\_BASE in Zypi configuration to point to secondary
    region

  - Restart: docker-compose restart zypi\_gateway

  - For automated failover, configure Glide routing layer behind
    Invariant

9.3 Log Aggregation & Auditing

A single X-Request-ID generated by Nginx must propagate through
Keycloak, Invariant, and Zypi logs. This enables end-to-end tracing from
initial TCP connection to specific microVM execution. Logs must be
retained for one year per PCI requirements, with the PostgreSQL volume
for Invariant Explorer backed up to immutable storage (e.g., AWS S3
Object Lock).

10\. Conclusion

The Zypi-based ZTEE architecture represents a maturation of enterprise
agentic infrastructure. By replacing managed sandbox providers with
self-hosted Elixir/Firecracker orchestration, organizations gain:

  - **Data Sovereignty:** Complete control over where agent code
    executes and sensitive data resides

  - **Hardware Isolation:** Security posture comparable to bare-metal
    while maintaining millisecond boot times

  - **Operational Resilience:** Elixir's supervision trees eliminate
    zombie processes and enable automatic recovery

  - **Cost Predictability:** Decoupling execution cost from volume by
    running on commodity infrastructure

This architecture not only secures the current generation of agents but
scales to support the high-concurrency, high-frequency agentic swarms of
the future. The integration with Invariant Gateway, Presidio, and n8n
creates a defense-in-depth model where no single layer failure results
in complete compromise.

*— End of Document —*
