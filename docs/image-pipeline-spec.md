# Image Pipeline Standardization — Design Spec

> **Status**: PROPOSED
> **Priority**: MEDIUM (not blocking any agent)
> **Author**: zypi agent
> **Date**: 2026-05-12

---

## 1. Problem

Zypi's current image pipeline is hand-rolled and opaque to external tooling:

```
skopeo copy → tar xzf layers → unsquashfs → chroot apt-get → mke2fs → overlaybd mount
```

This works on the happy path but:

| Pain point | Why it hurts |
|------------|-------------|
| **No OCI ref support** | Can't `zypi exec --image docker://ubuntu:24.04`. Images must be pre-imported via tar uploads to `/images/{ref}/import`. |
| **Fragile pull chain** | skopeo + unsquashfs + overlaybd each have failure modes. The pipeline is 6 tools deep with no retry/error recovery. |
| **Incompatible tooling** | `docker pull` doesn't know about zypi images. `nerdctl` can't inspect them. `cosign` can't sign them. |
| **Custom rootfs build** | Dockerfile builds rootfs via chroot + apt-get. Can't use pre-built OCI images. |
| **No image registry integration** | Images live as local ext4 files. No push/pull to standard registries. |

---

## 2. What We're Proposing

Accept standard OCI/Docker image references as input. Under the hood, use containerd's snapshotter (specifically overlaybd, which zypi already uses) to pull and cache layers. Then use zypi's existing tar→ext4 pipeline to create the rootfs. The result: zypi keeps its transparent, inspectable image format while being compatible with the entire OCI ecosystem.

```
NOW:
  skopeo → tar layers → unsquashfs → chroot → mke2fs → ext4 → Firecracker

PROPOSED:
  containerd snapshotter (overlaybd) → tar layers → cp --reflink → ext4 → Firecracker
                                        └─ zypi's metal pipeline, unchanged
```

**The key insight**: nerdctl/containerd already support overlaybd as a lazy-pull snapshotter. Zypi's overlaybd usage is forward-compatible with this ecosystem. We just need to accept OCI refs and let containerd do the pulling.

---

## 3. Architecture

```
┌──────────────────────────────────────────────────────────┐
│                   zypi exec --image                       │
│            docker://ubuntu:24.04 --cmd "..."              │
└──────────────────────┬───────────────────────────────────┘
                       │
┌──────────────────────▼───────────────────────────────────┐
│              Image Resolver (new)                         │
│  docker://ubuntu:24.04 → registry-1.docker.io/library/.. │
│  oci:///path/to/oci-layout → local dir                    │
│  ext4:///opt/zypi/rootfs/ubuntu-24.04.ext4 → local file  │
└──────────────────────┬───────────────────────────────────┘
                       │ OCI ref + auth
┌──────────────────────▼───────────────────────────────────┐
│           containerd snapshotter (new dep)                │
│  overlaybd-snapshotter or nydus-snapshotter               │
│  Lazy-pull layers → /var/lib/containerd/snapshots/        │
└──────────────────────┬───────────────────────────────────┘
                       │ tar layers (lazily resolved)
┌──────────────────────▼───────────────────────────────────┐
│         zypi Image Importer (existing, unchanged)         │
│  tar xzf layer → mount_point                              │
│  cp --reflink base_ext4 → new ext4                        │
│  Apply each layer via GNU tar                             │
│  Store at /opt/zypi/rootfs/{ref}.ext4                     │
└──────────────────────┬───────────────────────────────────┘
                       │ ext4 rootfs
┌──────────────────────▼───────────────────────────────────┐
│         Firecracker VM (existing, unchanged)              │
│  warm pool, SSH agent, iron-proxy, session model          │
└──────────────────────────────────────────────────────────┘
```

---

## 4. Image Format Support Matrix

| Format | Reference syntax | Status | Notes |
|--------|-----------------|--------|-------|
| OCI/Docker registry | `docker://ubuntu:24.04` | **NEW** | containerd pulls, zypi converts to ext4 |
| OCI layout (local) | `oci:///path/to/oci-layout` | **NEW** | Direct filesystem import, no network |
| ext4 raw | `ext4:///opt/zypi/rootfs/ubuntu.ext4` | Existing | Current format, unchanged |
| qcow2 | `qcow2:///path/to/image.qcow2` | **NEW** | Convert via qemu-img to ext4, supports snapshots |
| initrd (cpio) | `initrd:///path/to/initrd.img` | **NEW** | For Kata compatibility, RAM-based |
| Dockerfile | `dockerfile:///path/to/Dockerfile` | Future | Build via buildkit, import OCI, convert to ext4 |

---

## 5. Benefits

| Benefit | Detail |
|---------|--------|
| **Standard tooling** | `docker push/pull`, `cosign sign`, `trivy scan` all work with zypi images |
| **Lazy pulling** | overlaybd stargz/nydus: start VM before image fully downloads |
| **No lock-in** | Images work with Docker, nerdctl, Podman, OR zypi — user chooses |
| **Smaller Dockerfile** | Remove skopeo, unsquashfs, overlaybd-apply. Drop ~40 lines. |
| **Registry caching** | containerd's content store caches layers across images |
| **Cross-platform kernels** | OCI images don't care about kernel — zypi provides vmlinux separately |
| **Zypi uniqueness** | Still the only Firecracker runtime with transparent ext4 rootfs + warm pool |

---

## 6. What We Lose

| Loss | Mitigation |
|------|-----------|
| **Zero-dependency purity** | containerd adds a daemon dependency (~30MB binary). Acceptable tradeoff for OCI compat. |
| **Rootfs build customization** | Current Dockerfile runs `apt-get install chromium` inside chroot. OCI images are pre-built. Solution: multi-stage builds OR post-import customization hooks. |
| **overlaybd self-management** | Currently zypi manages overlaybd directly. Moving to containerd snapshotter means overlaybd runs as a containerd plugin. Still the same binary, just managed differently. |

---

## 7. Implementation Plan

### Phase 1: containerd sidecar (P0 — unblocks interop)
- Add containerd as optional runtime dependency (not required for ext4-only mode)
- Configure overlaybd-snapshotter as containerd plugin
- Build `ImageResolver` module: parse `docker://`, `oci://`, `ext4://` refs
- Use containerd's gRPC API to pull OCI images
- Convert pulled layers to tar streams → feed to existing `ImageImporter`
- **Goal**: `zypi exec --image docker://ubuntu:24.04 --cmd "echo hello"` works

### Phase 2: lazy pull (P1 — performance)
- Enable overlaybd stargz/nydus lazy pulling
- VM starts when first block is available, streams rest
- Warm pool pre-pulls popular images
- **Goal**: Cold start under 3s for any OCI image

### Phase 3: qcow2 + initrd (P2 — ecosystem breadth)
- Add qcow2→ext4 conversion via `qemu-img convert`
- Add initrd→ext4 conversion (extract cpio, mke2fs)
- Support `qcow2://` and `initrd://` refs
- **Goal**: Zypi runs Kata container images and QEMU disk images

### Phase 4: libkrun backend (P3 — macOS support)
- Add libkrun as alternative hypervisor (via Elixir NIF or port)
- Same zypi API, different VMM
- Cross-platform: Linux (Firecracker/KVM) + macOS (libkrun/HVF)
- **Goal**: `zypi exec` works on macOS without QEMU

---

## 8. Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| containerd adds operational complexity | Medium | Make it optional. ext4-only mode works without containerd. |
| overlaybd snapshotter instability | Low | Already proven in nerdctl production use. Zypi already uses overlaybd. |
| Image conversion latency (OCI→ext4) | Medium | Layer cache. Warm pool pre-converts popular images. |
| Breaking existing ext4-only workflow | None | Backward compatible. `ext4://` refs unchanged. |

---

## 9. Decision Required

- **containerd**: Required dependency or optional plugin?
- **Image format**: ext4 primary with OCI input, or OCI-primary with ext4 as internal detail?
- **Lazy pull**: overlaybd or nydus? (Both supported by containerd)
- **macOS**: libkrun now or later?

---

## 10. References

- [containerd](https://github.com/containerd/containerd)
- [overlaybd](https://github.com/containerd/accelerated-container-image) — zypi already uses this
- [nerdctl overlaybd docs](https://github.com/containerd/nerdctl/blob/main/docs/overlaybd.md)
- [libkrun](https://github.com/containers/libkrun)
- [Kata Containers + Firecracker](https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-use-kata-containers-with-firecracker.md)
- [zypi.neocities.org](https://zypi.neocities.org/) — project homepage
