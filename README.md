# Zypi

Zypi is a simple container runtime written in Elixir for firecracker microVMs

It's experimental.

# Demo

[demo video](docs/zypi-overlaybd-2025-12-07_15.14.49.mp4)


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
```

Helper cli:

```
source ./tools/zypi-cli.sh
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