# Zypi

Zypi is a simple container runtime written in Elixir with two execution backends: traditional Linux containers and microVMs.

## Quick Start

```bash
# Clone and choose your runtime
git clone https://github.com/allen-munsch/zypi.git
cd zypi

# OR for microVMs (uses Firecracker)
git checkout kata-firecracker
```

# Usage

```
docker compse build
docker compose up

source tools/zypi-cli.sh
./build_push_start.sh

# 3.5 seconds later
# The demo ( hello-zypi ) project has been built, pushed, created, started, booted, and is running

source ./tools/zypi-cli.sh

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
