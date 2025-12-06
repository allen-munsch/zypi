# Zypi

Zypi is a simple container runtime written in Elixir with two execution backends: traditional Linux containers and microVMs.

## Quick Start

```bash
# Clone and choose your runtime
git clone https://github.com/allen-munsch/zypi.git
cd zypi

# OR for a cgroups version
# git checkout crun-cgroups
```

# Usage

```
docker compse build
docker compose up

source tools/zypi-cli.sh
./build_push_start.sh

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
source ./tools/zypi-cli.sh
Zypi CLI loaded. Type 'zypi' for help.

zypi

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
