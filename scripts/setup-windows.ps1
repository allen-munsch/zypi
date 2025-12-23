# Zyppi Windows Setup Script
# Run as Administrator

$ErrorActionPreference = "Stop"

Write-Host "=== Zyppi Windows Setup ===" -ForegroundColor Cyan

# Check Windows version
$winver = [System.Environment]::OSVersion.Version
if ($winver.Build -lt 19041) {
    Write-Host "Error: Windows 10 version 2004 or later required" -ForegroundColor Red
    exit 1
}

# Create directories
$ZYPI_DIR = "C:\ProgramData\Zypi"
New-Item -ItemType Directory -Force -Path "$ZYPI_DIR\kernel"
New-Item -ItemType Directory -Force -Path "$ZYPI_DIR\images"
New-Item -ItemType Directory -Force -Path "$ZYPI_DIR\vms"
New-Item -ItemType Directory -Force -Path "$ZYPI_DIR\containers"

# Check for WSL2
Write-Host "Checking WSL2..." -ForegroundColor Yellow
$wslStatus = wsl --status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "WSL2 not found. Installing..." -ForegroundColor Yellow
    wsl --install
    Write-Host "Please restart your computer and run this script again." -ForegroundColor Yellow
    exit 0
}

# Install Firecracker in WSL
Write-Host "Setting up Firecracker in WSL..." -ForegroundColor Yellow
wsl -d Ubuntu -- bash -c @"
set -e
sudo apt-get update
sudo apt-get install -y curl

# Download Firecracker
FC_VERSION=1.5.0
curl -L -o firecracker.tgz https://github.com/firecracker-microvm/firecracker/releases/download/v\${FC_VERSION}/firecracker-v\${FC_VERSION}-x86_64.tgz
tar xzf firecracker.tgz
sudo mv release-v\${FC_VERSION}-x86_64/firecracker-v\${FC_VERSION}-x86_64 /usr/local/bin/firecracker
sudo chmod +x /usr/local/bin/firecracker
rm -rf firecracker.tgz release-v\${FC_VERSION}-x86_64

# Create Zypi directories
sudo mkdir -p /var/lib/zypi/{kernel,images,vms,containers}
sudo mkdir -p /opt/zypi/{bin,rootfs}

# Download kernel
sudo curl -L -o /opt/zypi/kernel/vmlinux https://github.com/example/zypi-kernels/releases/download/v1.0/vmlinux-x86_64

echo "WSL setup complete"
" @

# Check/Enable Hyper-V as fallback
$hyperv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V
if ($hyperv.State -ne "Enabled") {
    Write-Host "Hyper-V not enabled. Enable it for an additional runtime option." -ForegroundColor Yellow
    Write-Host "Run: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All" -ForegroundColor Yellow
}

# Install QEMU
if (-not (Get-Command qemu-system-x86_64 -ErrorAction SilentlyContinue)) {
    Write-Host "Installing QEMU via Chocolatey..." -ForegroundColor Yellow
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Host "Installing Chocolatey..." -ForegroundColor Yellow
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
    }
    choco install qemu -y
}

Write-Host ""
Write-Host "=== Setup Complete ===" -ForegroundColor Green
Write-Host "Data directory: $ZYPI_DIR"
Write-Host "WSL distro: Ubuntu"
Write-Host ""
Write-Host "Available runtimes:"
Write-Host "  1. WSL2 + Firecracker (recommended)"
if ($hyperv.State -eq "Enabled") {
    Write-Host "  2. Hyper-V"
}
Write-Host "  3. QEMU (fallback)"
