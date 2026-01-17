ZTEE Tool Selection Framework

*Zypi-Centric Architecture for PCI Data Sovereignty*

Decision Framework for Enterprise AI Agent Infrastructure

1\. Decision Context

You are selecting tools for a Zero-Trust Execution Environment (ZTEE) to
run AI agents that will interact with PCI-scoped data. The two
non-negotiable requirements are:

1.  **Data Sovereignty:** PCI cardholder data and agent-generated code
    must never leave your controlled infrastructure perimeter

2.  **Software Supply Chain Security:** Every component running in the
    execution environment must be verifiable, scannable, and attestable

Zypi—the self-hosted Elixir/Firecracker orchestration layer—is the
foundation. This document focuses on the complementary tools needed to
build a complete, sovereign stack.

2\. Why Zypi is the Right Foundation

Before selecting supporting tools, let's confirm why Zypi (Firecracker +
Elixir/OTP) is the correct choice over alternatives:

2.1 Isolation Technology Comparison

|                        |                                   |               |                                   |
| ---------------------- | --------------------------------- | ------------- | --------------------------------- |
| **Technology**         | **Isolation Model**               | **Boot Time** | **PCI Suitability**               |
| **Firecracker (Zypi)** | Hardware (KVM) - own guest kernel | \~125ms       | EXCELLENT - Full kernel isolation |
| gVisor                 | Syscall interception (Sentry)     | \~50-100ms    | GOOD - Software boundary          |
| Kata Containers        | Hardware (QEMU/KVM)               | \~150-300ms   | EXCELLENT - But heavier           |
| Docker (runC)          | Namespaces + cgroups              | \~10-50ms     | POOR - Shared kernel risk         |

**Verdict:** Firecracker provides the strongest isolation boundary
(hardware-level via KVM) with the fastest boot time among
hardware-isolated options. For PCI compliance where an agent compromise
must not affect other workloads or the host, this is the correct choice.

2.2 Why Not E2B?

E2B uses Firecracker under the hood—the isolation model is identical.
The difference is **operational control**:

  - **E2B:** Managed SaaS. Your code and data traverse their
    infrastructure. You trust their security practices.

  - **Zypi:** Self-hosted. PCI data never leaves your VPC. You control
    the kernel, rootfs, and network egress.

For PCI DSS compliance, the data residency requirement makes Zypi the
only viable option unless E2B offers a dedicated/on-prem deployment
(which would negate their value proposition).

3\. Software Supply Chain Security Stack

The supply chain security requirement breaks down into three
capabilities: **Provenance** (where did this come from?), **Integrity**
(has it been tampered with?), and **Vulnerability Status** (is it safe
to run?).

3.1 Recommended Supply Chain Stack

|                        |                            |                                                                                  |
| ---------------------- | -------------------------- | -------------------------------------------------------------------------------- |
| **Capability**         | **Tool**                   | **Why This Tool**                                                                |
| Private Registry       | **Harbor**                 | CNCF graduated. RBAC, replication, LDAP/AD integration. Self-hosted sovereignty. |
| Vulnerability Scanning | **Trivy**                  | Built into Harbor. OS + language packages. No external dependencies.             |
| SBOM Generation        | **Syft**                   | CycloneDX/SPDX output. Integrates with Sigstore for attestations.                |
| Signing & Attestation  | **Cosign (Sigstore)**      | Keyless signing via OIDC. Transparency log (Rekor). Industry standard.           |
| Policy Enforcement     | **Kyverno or Connaisseur** | Admission controller: reject unsigned/unscanned images at deploy time.           |

3.2 The Supply Chain Flow

For Zypi's rootfs images and any agent tooling containers:

1.  **Build:** CI builds the image from Dockerfile

2.  **Scan:** Trivy scans for CVEs (block if CVSS ≥ 7)

3.  **Generate SBOM:** Syft produces CycloneDX manifest

4.  **Sign:** Cosign signs image + attests SBOM to registry

5.  **Push:** Image + signatures + attestations stored in Harbor

6.  **Deploy:** Zypi pulls from Harbor; admission policy verifies
    signature

4\. Complete ZTEE Tool Stack

Combining the execution layer (Zypi) with supply chain security and
runtime governance:

|                    |                    |                                                         |
| ------------------ | ------------------ | ------------------------------------------------------- |
| **Layer**          | **Tool**           | **Function**                                            |
| **Execution**      | Zypi + Firecracker | Ephemeral microVMs for agent code execution             |
| **Supply Chain**   | Harbor + Trivy     | Private registry with integrated vulnerability scanning |
| **Supply Chain**   | Syft + Cosign      | SBOM generation + cryptographic signing/attestation     |
| **Policy & Audit** | Invariant Gateway  | AI firewall: prompt/output guardrails, trace logging    |
| **Policy & Audit** | Presidio           | PII/PCI detection and redaction before LLM context      |
| **Identity**       | Keycloak + Nginx   | OIDC provider + gateway PEP (token validation)          |
| **Secrets**        | HashiCorp Vault    | Ephemeral credentials injected into microVMs            |
| **Orchestration**  | n8n (optional)     | Human-in-the-loop approval workflows for high-risk ops  |

5\. Key Decision Points

5.1 Decision: Firecracker vs. gVisor

**Recommendation: Firecracker (via Zypi)**

*Rationale:* For PCI workloads, the threat model assumes agents will
execute malicious code (prompt injection, hallucinated commands).
Firecracker's hardware-level isolation provides a 'blast radius of
one'—a kernel exploit in the guest VM cannot escape to affect other
workloads or the host. gVisor's syscall interception model is strong but
remains a software boundary.

*Trade-off:* gVisor has faster cold starts (50-100ms vs 125ms) and
better Kubernetes integration. If you need very high-density,
short-lived executions and can accept software-level isolation, gVisor
is viable.

5.2 Decision: Self-Hosted Sigstore vs. Public Sigstore

**Recommendation: Self-hosted Timestamp Authority, public Rekor
optional**

*Rationale:* For keyless signing, you need a Timestamp Authority (TSA)
to prove the key was valid when signing occurred. Sigstore provides an
open-source TSA you can self-host. The public Rekor transparency log is
optional—it provides global auditability but means your signing activity
is publicly visible.

*PCI Note:* If your security policy prohibits external visibility of
artifact signing, deploy your own Rekor instance. Otherwise, public
Rekor is acceptable since it only logs that a signing event occurred,
not the content.

5.3 Decision: Harbor vs. Other Registries

**Recommendation: Harbor**

*Rationale:* Harbor is the only CNCF-graduated, fully self-hostable
registry with integrated Trivy scanning, RBAC, LDAP/AD integration, and
multi-site replication. Alternatives like Docker Registry lack security
features; JFrog Artifactory is commercial.

*Key Feature:* Harbor can enforce 'no deploy if vulnerability severity ≥
X' at the project level, preventing unscanned or vulnerable images from
being pulled.

6\. Architecture Overview

The following illustrates the data flow and trust boundaries:

**Build-Time Flow (Supply Chain):**

1.  Developer pushes code → CI triggers build

2.  Trivy scans image for CVEs (gate: block if critical)

3.  Syft generates SBOM (CycloneDX)

4.  Cosign signs image + attests SBOM

5.  Push to Harbor (signatures stored alongside image)

**Run-Time Flow (Execution):**

1.  Agent request → Nginx (validates OIDC token)

2.  Invariant Gateway (guardrails: block PCI data, prompt injection)

3.  Presidio scans for PII/PAN (redact before LLM)

4.  Zypi spawns Firecracker microVM (pulls verified rootfs from Harbor)

5.  Agent code executes in isolated VM (ephemeral, destroyed on
    completion)

6.  Output returned via Invariant (DLP scan on egress)

7\. Recommended Next Steps

  - **Proof of Concept:** Deploy Harbor + Trivy + Zypi in a
    non-production environment. Validate that the supply chain flow
    works end-to-end.

  - **Rootfs Hardening:** Build a minimal rootfs (Alpine-based) with
    only the language runtimes your agents need. Scan it, sign it, and
    use it as Zypi's base image.

  - **Network Isolation:** Deploy Zypi nodes in an isolated VPC segment
    with strict egress controls. Agent VMs should only be able to reach
    approved endpoints.

  - **Compliance Mapping:** Document how each component maps to PCI DSS
    requirements (3.5.1 for encryption, 10.x for logging, etc.).

8\. Summary

Zypi (Firecracker + Elixir/OTP) is the correct foundation for
PCI-compliant AI agent execution. Combined with Harbor, Trivy, Syft, and
Cosign for supply chain security, and Invariant + Presidio for runtime
policy enforcement, you have a complete stack that ensures:

  - PCI data never leaves your infrastructure

  - Every component is vulnerability-scanned and cryptographically
    signed

  - Agent execution is hardware-isolated with a 'blast radius of one'

  - Full audit trail from build to execution

*— End of Document —*
