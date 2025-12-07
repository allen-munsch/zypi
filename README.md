# Zypi

Zypi is a simple container runtime written in Elixir for firecracker microVMs

It's experimental.

```
03:15:37 jm@pop-os zypi ±|optimize-observe ✗|→ zypi shell test-hello-zippy
Connecting via SSH to root@10.0.0.3...
Press Ctrl-D or type 'exit' to disconnect.

╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║   ███████╗██╗   ██╗██████╗ ██╗                                ║
║   ╚══███╔╝╚██╗ ██╔╝██╔══██╗██║                                ║
║     ███╔╝  ╚████╔╝ ██████╔╝██║                                ║
║    ███╔╝    ╚██╔╝  ██╔═══╝ ██║                                ║
║   ███████╗   ██║   ██║     ██║                                ║
║   ╚══════╝   ╚═╝   ╚═╝     ╚═╝                                ║
║                                                               ║
║   ⚡ Firecracker microVM · Sub-second boot · CoW snapshots    ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝

```

## Quick Start

```bash
# Clone and choose your runtime
git clone https://github.com/allen-munsch/zypi.git
cd zypi

# OR for an older cgroups version
# git checkout crun-cgroups
```

# Demo

[demo video](docs/zypi-overlaybd-2025-12-07_15.14.49)

# Usage

```
sudo modprobe target_core_user
sudo modprobe tcm_loop

# NOTE 
# you'll need to compile a newer vmlinux if you want shell support
# See: tools/build_vmlinux.sh

docker compse build
docker compose up

source tools/zypi-cli.sh


./build_push_start.sh

# There are 2 examples that run, base alpine, and a base alpine python
# 3.5 seconds later
# The demo ( hello-zypi ) project has been built, pushed, created, started, booted, and is running

zypi-node  | 09:33:42.524 [debug] Manager received line: [    0.832465] input: AT Raw Set 2 keyboard as /devices/platform/i8042/serio0/input/input0
zypi-node  | 
zypi-node  | 09:33:42.527 [debug] Manager received line: [    0.834195] EXT4-fs (vda): mounted filesystem with ordered data mode. Opts: (null)
zypi-node  | 
zypi-node  | 09:33:42.528 [debug] Manager received line: [    0.835329] VFS: Mounted root (ext4 filesystem) on device 254:0.
zypi-node  | 
zypi-node  | 09:33:42.528 [debug] Manager received line: [    0.836414] devtmpfs: mounted
zypi-node  | 
zypi-node  | 09:33:42.530 [debug] Manager received line: [    0.837736] Freeing unused kernel memory: 1324K
zypi-node  | 
zypi-node  | 09:33:42.540 [debug] Manager received line: [    0.848103] Write protecting the kernel read-only data: 12288k
zypi-node  | 
zypi-node  | 09:33:42.542 [debug] Manager received line: [    0.850060] Freeing unused kernel memory: 2016K
zypi-node  | 
zypi-node  | 09:33:42.543 [debug] Manager received line: [    0.851241] Freeing unused kernel memory: 568K
zypi-node  | 
zypi-node  | 09:33:42.547 [debug] Manager received line: Hello from Zypi!
zypi-node  | 
zypi-node  | 09:33:42.547 [debug] Manager received line: Container ID: 10.0.0.16
zypi-node  | 
zypi-node  | 09:33:42.548 [debug] Manager received line: Time: Sat Dec  6 09:33:42 UTC 2025
zypi-node  | 
zypi-node  | 09:33:42.656 [debug] Manager received line: [    0.832354] input: AT Raw Set 2 keyboard as /devices/platform/i8042/serio0/input/input0
zypi-node  | 
zypi-node  | 09:33:42.658 [debug] Manager received line: [    0.834844] EXT4-fs (vda): recovery complete
zypi-node  | 
zypi-node  | 09:33:42.660 [debug] Manager received line: [    0.835582] EXT4-fs (vda): mounted filesystem with ordered data mode. Opts: (null)
zypi-node  | 
zypi-node  | 09:33:42.660 [debug] Manager received line: [    0.836760] VFS: Mounted root (ext4 filesystem) on device 254:0.
zypi-node  | 
zypi-node  | 09:33:42.660 [debug] Manager received line: [    0.837200] devtmpfs: mounted
zypi-node  | 
zypi-node  | 09:33:42.661 [debug] Manager received line: [    0.838007] Freeing unused kernel memory: 1324K
zypi-node  | 
zypi-node  | 09:33:42.671 [debug] Manager received line: [    0.848042] Write protecting the kernel read-only data: 12288k
zypi-node  | 
zypi-node  | 09:33:42.673 [debug] Manager received line: [    0.849382] Freeing unused kernel memory: 2016K
zypi-node  | 
zypi-node  | 09:33:42.674 [debug] Manager received line: [    0.850452] Freeing unused kernel memory: 568K
zypi-node  | 
zypi-node  | 09:33:42.678 [debug] Manager received line: Hello from Zypi!
zypi-node  | 
zypi-node  | 09:33:42.678 [debug] Manager received line: Container ID: 10.0.0.15
zypi-node  | 
zypi-node  | 09:33:42.679 [debug] Manager received line: Time: Sat Dec  6 09:33:42 UTC 2025
zypi-node  | 
zypi-node  | 09:33:52.548 [debug] Manager received line: Still running...
zypi-node  | 
zypi-node  | 09:33:52.680 [debug] Manager received line: Still running...
zypi-node  | 
zypi-node  | 09:34:02.549 [debug] Manager received line: Still running...
zypi-node  | 
```

Helper cli:

```
05:06:40 jm@pop-os zypi ±|main ✗|→ source ./tools/zypi-cli.sh
Zypi CLI loaded. Type 'zypi' for help.

05:06:40 jm@pop-os zypi ±|main ✗|→ zypi

Zypi CLI - Firecracker Container Runtime

Image commands:
  push <image:tag>     Push Docker image to Zypi [fix]
  images               List available images

Container commands:
  create <id> <image>  Create container
  start <id>           Start container (launches VM)
  stop <id>            Stop container
  destroy <id>         Destroy container
  run <id> <image>     Create and start

Inspection:
  list                 List containers
  status <id>          Container status
  inspect <id>         Container details
  logs <id>            Container logs [todo]
  attach <id>          Attach to output stream [todo]

05:06:37 jm@pop-os zypi ±|main ✗|→ zypi images
{
  "images": [
    "hello-zippy:v22",
    "hello-zippy:v4",
    "hello-zippy:v2",
    "hello-zippy:v3",
    "hello-zippy:v21"
  ]
}

05:06:40 jm@pop-os zypi ±|main ✗|→ zypi list
{
  "containers": [
    {
      "id": "test21",
      "status": "created",
      "ip": "10.0.0.6",
      "started_at": null,
      "image": "hello-zippy:v21",
      "created_at": "2025-12-06T11:05:30.575573Z",
      "rootfs": "/var/lib/zypi/containers/test21/rootfs.ext4"
    },
    {
      "id": "test3",
      "status": "running",
      "ip": "10.0.0.4",
      "started_at": "2025-12-06T11:05:26.123145Z",
      "image": "hello-zippy:v3",
      "created_at": "2025-12-06T11:05:25.907863Z",
      "rootfs": "/var/lib/zypi/containers/test3/rootfs.ext4"
    },
    {
      "id": "test22",
      "status": "running",
      "ip": "10.0.0.7",
      "started_at": "2025-12-06T11:05:33.036854Z",
      "image": "hello-zippy:v22",
      "created_at": "2025-12-06T11:05:32.845566Z",
      "rootfs": "/var/lib/zypi/containers/test22/rootfs.ext4"
    },
    {
      "id": "test4",
      "status": "running",
      "ip": "10.0.0.5",
      "started_at": "2025-12-06T11:05:28.461920Z",
      "image": "hello-zippy:v4",
      "created_at": "2025-12-06T11:05:28.256263Z",
      "rootfs": "/var/lib/zypi/containers/test4/rootfs.ext4"
    },
    {
      "id": "test2",
      "status": "running",
      "ip": "10.0.0.3",
      "started_at": "2025-12-06T11:05:20.876954Z",
      "image": "hello-zippy:v2",
      "created_at": "2025-12-06T11:05:20.668811Z",
      "rootfs": "/var/lib/zypi/containers/test2/rootfs.ext4"
    }
  ]
}


```



## Runtime Options

### `crun-cgroups` branch
- Uses **crun** with Linux cgroups
- Fast, lightweight containers
- Traditional container isolation
- Trusted workloads

### `kata-firecracker` branch - Firecracker
- Uses **Firecracker** microVMs
- Hardware-level isolation
- More secure, slightly slower
