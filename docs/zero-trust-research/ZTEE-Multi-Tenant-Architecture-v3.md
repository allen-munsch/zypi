Zero-Trust Execution Environment

**Multi-Tenant Enterprise Architecture**

*Zypi + YAS-MCP + Developer YOLO Mode*

Unified Reference Architecture for Agentic AI Infrastructure

1\. Executive Summary

This document presents a comprehensive multi-tenant architecture for
enterprise AI agent execution. The architecture serves **five distinct
audience segments** with varying trust levels, data sensitivity
requirements, and autonomy needs.

**Key Capabilities:**

1.  **Multi-Audience Segmentation:** Public API consumers, external
    developers, PCI merchants, internal users, and the inner sanctum

2.  **YAS-MCP Public API:** OpenAPI specs exposed as MCP tools for
    external consumption

3.  **Developer YOLO Mode:** Safe autonomous execution for Claude Code,
    Cursor, Aider, Gemini CLI, and other AI coding tools

4.  **Tiered Provenance:** Full attestation for PCI apps; relaxed for
    general development

5.  **Multi-LLM Routing:** Snowflake Cortex, Vertex AI, Bedrock, Ollama
    with per-tier policies

2\. Audience Segmentation

The architecture defines five trust tiers, each with distinct access
patterns, data boundaries, and governance requirements:

|                     |                 |                        |                         |
| ------------------- | --------------- | ---------------------- | ----------------------- |
| **Audience**        | **Trust Level** | **Access Pattern**     | **Data Boundary**       |
| **Public API**      | UNTRUSTED       | YAS-MCP endpoints only | Public data only        |
| **External Devs**   | LOW             | Sandboxed YOLO mode    | Own workspace only      |
| **Merchants (PCI)** | MEDIUM          | Governed agent access  | Own PCI data (redacted) |
| **Internal Users**  | HIGH            | Full platform + YOLO   | Internal systems (RBAC) |
| **Inner Sanctum**   | PRIVILEGED      | Audited, MFA, approval | Raw PCI/CHD access      |

2.1 Audience Definitions

Public API (YAS-MCP)

External consumers accessing your OpenAPI specs as MCP tools. YAS-MCP
transforms OpenAPI 3.x specifications into MCP-compatible tool servers,
enabling AI agents (ChatGPT, Claude, Cursor, etc.) to discover and
invoke your public APIs.

  - **Access:** Rate-limited, API key authenticated

  - **Data:** Public endpoints only; no internal or PCI data

  - **Execution:** Stateless; no code execution rights

External Developers

Third-party developers building on your platform. They need sandbox
environments to run AI coding tools autonomously without risking your
infrastructure.

  - **Access:** OAuth2 authenticated; scoped to their workspace

  - **Data:** Own development artifacts only

  - **Execution:** YOLO mode in isolated Zypi sandbox; cannot escape
    workspace

Customers/Merchants (PCI Scope)

Business users operating within PCI DSS scope. Agents can query their
transaction data but cardholder data (PAN, CVV) is redacted before LLM
context.

  - **Access:** OIDC authenticated; role-based access

  - **Data:** Own merchant data; PCI fields redacted by Presidio

  - **Execution:** Governed agents only; no arbitrary code execution

Internal Users (Business, Sales, Developers)

Employees across business, sales, and engineering functions. Internal
developers want full YOLO mode for autonomous coding; business users
want governed agents for data queries.

  - **Access:** SSO/OIDC; AD group membership

  - **Data:** Internal systems per RBAC; aggregated PCI data (no raw
    CHD)

  - **Execution:** YOLO mode for devs (sandboxed); governed agents for
    business

Inner Sanctum (Hard PCI Scope)

Privileged access to raw cardholder data. This tier is for PCI DSS
compliance operations, fraud investigation, and authorized financial
operations.

  - **Access:** MFA required; just-in-time approval; session recording

  - **Data:** Raw PAN, CHD with full audit trail

  - **Execution:** Human-in-the-loop required; no autonomous agents

3\. YAS-MCP: Public API as MCP Tools

YAS-MCP transforms your OpenAPI specifications into MCP (Model Context
Protocol) tool servers, enabling external AI agents to discover and
invoke your public APIs as structured tools.

3.1 How It Works

  - **OpenAPI Ingestion:** YAS-MCP parses your OpenAPI 3.x specs
    (YAML/JSON)

  - **Tool Generation:** Each endpoint becomes an MCP tool with typed
    parameters from the spec

  - **Transport:** Serves tools via stdio (local) or HTTP/SSE (remote)

  - **Invocation:** AI agents call tools; YAS-MCP translates to REST
    calls against your API

3.2 Security Model

|                |                                                                  |
| -------------- | ---------------------------------------------------------------- |
| **Control**    | **Implementation**                                               |
| Authentication | API keys passed via MCP auth headers; validated at Gateway       |
| Rate Limiting  | Per-key limits enforced at Nginx (e.g., 100 req/min)             |
| Tool Filtering | Only expose public-tagged endpoints; internal endpoints excluded |
| Dangerous Ops  | PUT/POST/DELETE require confirmation workflow in MCP protocol    |
| Audit          | All tool invocations logged with X-Request-ID correlation        |

4\. Developer YOLO Mode

Internal and external developers want to run AI coding tools—Claude
Code, Cursor, Aider, Gemini CLI, Continue, Windsurf, and others—in
**near-autonomous 'YOLO' mode** without constant permission prompts. The
architecture provides this capability safely via Zypi-based sandboxing.

4.1 The YOLO Problem

Modern AI coding tools operate at various autonomy levels:

  - **Level 1 (Autocomplete):** GitHub Copilot, Tabnine—suggests lines,
    requires human steering

  - **Level 2 (Interactive):** ChatGPT, Claude web—generates functions,
    human executes

  - **Level 3 (Supervised):** Cursor, Cline—reads/writes files, asks
    permission per action

  - **Level 4 (Autonomous):** Claude Code, Aider—executes multi-step
    plans with minimal oversight

Level 4 tools are most productive but also most dangerous. Without
sandboxing, a prompt-injected agent could exfiltrate SSH keys, backdoor
system files, or download malware.

4.2 Zypi Sandbox Solution

Zypi provides hardware-isolated sandboxes where developers can enable
YOLO mode safely:

|                      |                                         |                                              |
| -------------------- | --------------------------------------- | -------------------------------------------- |
| **Isolation Layer**  | **What It Protects**                    | **Implementation**                           |
| Filesystem Isolation | Agent can only access mounted workspace | Firecracker rootfs + volume mounts           |
| Network Isolation    | Agent can only reach approved hosts     | Firecracker network namespace + egress proxy |
| Kernel Isolation     | Guest kernel exploits can't escape      | KVM hardware virtualization                  |
| Credential Isolation | Git keys, API tokens outside sandbox    | Vault injects ephemeral creds on demand      |

4.3 Supported Tools

The Zypi sandbox is tool-agnostic. Any AI coding tool that runs in a
terminal or IDE can operate inside the sandbox:

|                 |                 |                                                      |
| --------------- | --------------- | ---------------------------------------------------- |
| **Tool**        | **Type**        | **YOLO Mode Integration**                            |
| **Claude Code** | CLI Agent       | Run /sandbox + --dangerously-skip-permissions safely |
| Cursor          | IDE + Agent     | DevContainer connects to Zypi sandbox                |
| Aider           | CLI Agent       | Git-native context; runs inside sandbox terminal     |
| Gemini CLI      | CLI Agent       | Google's Gemini via terminal; sandboxed execution    |
| Continue        | IDE Extension   | VS Code extension; workspace mounted in sandbox      |
| Windsurf/Cline  | IDE Agent       | Level 3/4 agents; permission-free inside sandbox     |
| Perplexity      | Research + Code | Search-augmented coding; network egress controlled   |

4.4 YOLO Mode Activation Flow

1.  Developer authenticates via SSO/OAuth

2.  Gateway provisions Zypi sandbox (Firecracker microVM)

3.  Workspace mounted as volume; credentials injected from Vault

4.  Developer connects via browser terminal or IDE DevContainer

5.  AI tool runs with full permissions inside sandbox

6.  All actions logged; egress filtered through proxy

7.  On completion: workspace synced, VM destroyed

5\. Tiered Provenance Model

Different workloads require different supply chain rigor based on data
sensitivity:

|            |                                        |                                    |
| ---------- | -------------------------------------- | ---------------------------------- |
| **Aspect** | **Tier 1: PCI-Scoped**                 | **Tier 2: General Product**        |
| Registry   | Harbor / GitLab Registry (self-hosted) | GHCR / DockerHub Enterprise        |
| SBOM       | MANDATORY - Syft + Cosign signed       | OPTIONAL - GitHub Dependency Graph |
| Vuln Gate  | BLOCK if CVSS \>= 7.0                  | WARN if CVSS \>= 9.0               |
| Admission  | Reject unsigned images                 | Standard deployment                |

6\. Multi-LLM Backend Routing

The Gateway routes LLM requests based on audience tier and data
sensitivity:

|                      |                |                   |                       |
| -------------------- | -------------- | ----------------- | --------------------- |
| **Provider**         | **PCI Tier 1** | **Inner Sanctum** | **Tier 2 / Dev YOLO** |
| **Snowflake Cortex** | ALLOWED        | ALLOWED           | ALLOWED               |
| **Ollama (Local)**   | ALLOWED        | ALLOWED           | ALLOWED               |
| Vertex AI            | BLOCKED        | BLOCKED           | ALLOWED               |
| AWS Bedrock          | BLOCKED        | BLOCKED           | ALLOWED               |
| Custom Endpoints     | ALLOWLIST      | BLOCKED           | ALLOWED               |

**Snowflake Cortex** is the preferred PCI-tier backend because data and
prompts never leave Snowflake's governance boundary. The Cortex Analyst
API returns SQL queries (not raw data), which execute under Snowflake's
RBAC.

7\. Complete Architecture Stack

|                  |                   |                           |                                 |
| ---------------- | ----------------- | ------------------------- | ------------------------------- |
| **Layer**        | **Component**     | **PCI / Inner Sanctum**   | **Tier 2 / Dev YOLO**           |
| **Public API**   | MCP Server        | N/A                       | YAS-MCP (public endpoints only) |
| **Execution**    | VM Orchestration  | Zypi + Firecracker        | Zypi + Firecracker (YOLO mode)  |
| **Supply Chain** | Registry          | Harbor / GitLab Registry  | GHCR / DockerHub Ent            |
| **LLM Routing**  | Gateway           | Bifrost/Invariant         | Bifrost/Invariant               |
| **LLM Routing**  | Allowed Providers | Cortex, Ollama only       | All (Cortex, Vertex, Bedrock)   |
| **Policy**       | PII/PCI Detection | Presidio (block PAN)      | Presidio (redact)               |
| **Identity**     | Auth Provider     | Keycloak (MFA + approval) | Okta/SSO                        |

8\. Deployment Topology

The architecture deploys across multiple security zones:

  - **DMZ:** YAS-MCP public endpoint, rate-limited Nginx

  - **Application Zone:** Gateway, Invariant, Bifrost, Presidio

  - **Sandbox Zone:** Zypi worker nodes (isolated VPC, no lateral
    movement)

  - **Data Zone:** Snowflake, internal databases

  - **Inner Sanctum:** Air-gapped PCI environment; MFA + approval +
    session recording

9\. Implementation Roadmap

1.  **Phase 1 - Foundation:** Deploy Zypi + Firecracker; validate
    hardware isolation

2.  **Phase 2 - Public API:** Stand up YAS-MCP with OpenAPI specs; rate
    limiting

3.  **Phase 3 - Dev YOLO:** Enable sandboxed autonomous mode for
    internal devs

4.  **Phase 4 - Multi-LLM:** Deploy Bifrost/Invariant with routing for
    Cortex, Vertex, Bedrock

5.  **Phase 5 - Merchant Access:** Enable governed agent access for PCI
    merchants

6.  **Phase 6 - Inner Sanctum:** Deploy air-gapped PCI environment with
    full audit

10\. Summary

This architecture delivers a unified platform serving five audience
segments with appropriate trust boundaries:

  - **Public API via YAS-MCP** exposes your OpenAPI specs as MCP tools
    for external AI agents

  - **Developer YOLO Mode** enables autonomous AI coding tools in
    hardware-isolated Zypi sandboxes

  - **Tiered Provenance** enforces full attestation for PCI apps while
    allowing relaxed governance for general development

  - **Multi-LLM Routing** directs traffic to appropriate backends
    (Cortex for PCI, any for Tier 2)

  - **Inner Sanctum** provides audited, human-in-the-loop access for raw
    PCI data

*— End of Document —*
