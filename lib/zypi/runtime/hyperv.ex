defmodule Zypi.Runtime.HyperV do
  @moduledoc """
  Hyper-V runtime for Windows Pro/Enterprise/Education.
  
  Uses PowerShell to manage Hyper-V VMs directly.
  Faster than WSL2 for dedicated VM workloads.
  
  Requirements:
  - Windows 10/11 Pro, Enterprise, or Education
  - Hyper-V enabled
  - Administrator privileges
  """

  @behaviour Zypi.Runtime.Behaviour
  require Logger

  @data_dir Application.compile_env(:zypi, :data_dir, "C:\\ProgramData\\Zypi")
  @vm_dir Path.join(@data_dir, "vms")

  @impl true
  def available? do
    cond do
      :os.type() != {:win32, :nt} ->
        false
      not hyperv_enabled?() ->
        Logger.debug("HyperV: Hyper-V not enabled")
        false
      true ->
        true
    end
  end

  @impl true
  def name, do: "Hyper-V"

  defp hyperv_enabled? do
    case powershell("(Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State") do
      {:ok, output} -> String.contains?(output, "Enabled")
      _ -> false
    end
  end

  @impl true
  def start(container) do
    Logger.info("HyperV: Starting VM for #{container.id}")

    vm_path = Path.join(@vm_dir, container.id)
    File.mkdir_p!(vm_path)

    mem_mb = get_in(container.resources, [:memory_mb]) || 256
    cpus = get_in(container.resources, [:cpu]) || 1

    # Convert ext4 rootfs to VHDX
    vhdx_path = Path.join(vm_path, "rootfs.vhdx")
    convert_to_vhdx(container.rootfs, vhdx_path)

    vm_name = "zypi-#{container.id}"

    # Create and configure VM
    script = """
    $ErrorActionPreference = "Stop"
    
    # Create VM
    New-VM -Name \"#{vm_name}\" -MemoryStartupBytes #{mem_mb}MB -Generation 2 -Path \"#{vm_path}\" 
    
    # Configure CPU
    Set-VMProcessor -VMName \"#{vm_name}\" -Count #{cpus}
    
    # Disable Secure Boot for Linux
    Set-VMFirmware -VMName \"#{vm_name}\" -EnableSecureBoot Off
    
    # Add disk
    Add-VMHardDiskDrive -VMName \"#{vm_name}\" -Path \"#{vhdx_path}\" 
    
    # Configure network
    $switch = Get-VMSwitch -Name "ZypiSwitch" -ErrorAction SilentlyContinue
    if (-not $switch) {
        New-VMSwitch -Name "ZypiSwitch" -SwitchType Internal
        New-NetIPAddress -IPAddress 10.0.0.1 -PrefixLength 24 -InterfaceAlias "vEthernet (ZypiSwitch)"
        New-NetNat -Name "ZypiNAT" -InternalIPInterfaceAddressPrefix 10.0.0.0/24
    }
    Connect-VMNetworkAdapter -VMName \"#{vm_name}\" -SwitchName "ZypiSwitch"
    
    # Start VM
    Start-VM -Name \"#{vm_name}\" 
    
    # Wait for VM to get IP
    $timeout = 60
    $ip = $null
    while ($timeout -gt 0 -and -not $ip) {
        Start-Sleep -Seconds 1
        $ip = (Get-VMNetworkAdapter -VMName \"#{vm_name}\").IPAddresses | Where-Object { $_ -match "^10\\.0\\.0." }
        $timeout--
    }
    
    Write-Output $ip
    """

    case powershell(script) do
      {:ok, output} ->
        ip = output |> String.trim() |> parse_ip()
        
        {:ok, %{
          vm_name: vm_name,
          vhdx_path: vhdx_path,
          pid: nil,
          container_ip: ip || container.ip
        }}
        
      {:error, reason} ->
        Logger.error("HyperV: Failed to start VM: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def stop(%{id: id, pid: vm_state}) when is_map(vm_state) do
    Logger.info("HyperV: Stopping VM #{id}")

    vm_name = vm_state[:vm_name] || "zypi-#{id}"
    
    powershell("""
    Stop-VM -Name \"#{vm_name}\" -Force -ErrorAction SilentlyContinue
    Remove-VM -Name \"#{vm_name}\" -Force -ErrorAction SilentlyContinue
    """)

    cleanup(id)
    :ok
  end

  def stop(%{id: id}), do: cleanup(id)

  @impl true
  def exec(container_id, cmd, opts) do
    Zypi.Container.Agent.exec(container_id, cmd, opts)
  end

  @impl true
  def health(container_id) do
    Zypi.Container.Agent.health(container_id)
  end

  @impl true
  def cleanup(container_id) do
    vm_path = Path.join(@vm_dir, container_id)
    
    # Remove VM if exists
    powershell("""
    $vm = Get-VM -Name "zypi-#{container_id}" -ErrorAction SilentlyContinue
    if ($vm) {
        Stop-VM -Name "zypi-#{container_id}" -Force -ErrorAction SilentlyContinue
        Remove-VM -Name "zypi-#{container_id}" -Force
    }
    """)
    
    File.rm_rf(vm_path)
    :ok
  end

  @impl true
  def setup_network(_container_id, _ip) do
    # Hyper-V network switch setup
    powershell("""
    $switch = Get-VMSwitch -Name "ZypiSwitch" -ErrorAction SilentlyContinue
    if (-not $switch) {
        New-VMSwitch -Name "ZypiSwitch" -SwitchType Internal
        $adapter = Get-NetAdapter | Where-Object { $_.Name -like "*ZypiSwitch*" }
        New-NetIPAddress -IPAddress 10.0.0.1 -PrefixLength 24 -InterfaceIndex $adapter.ifIndex
        New-NetNat -Name "ZypiNAT" -InternalIPInterfaceAddressPrefix 10.0.0.0/24 -ErrorAction SilentlyContinue
    }
    """)
    
    {:ok, %{mode: :hyperv_switch}}
  end

  @impl true
  def teardown_network(_container_id, _state) do
    :ok
  end

  # Private functions

  defp powershell(script) do
    # Write script to temp file to avoid escaping issues
    temp_file = Path.join(System.tmp_dir!(), "zypi_ps_#{:rand.uniform(100000)}.ps1")
    File.write!(temp_file, script)
    
    result = System.cmd("powershell", [
      "-ExecutionPolicy", "Bypass",
      "-File", temp_file
    ], stderr_to_stdout: true)
    
    File.rm(temp_file)
    
    case result do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {code, output}}
    end
  end

  defp convert_to_vhdx(ext4_path, vhdx_path) do
    # Use qemu-img to convert ext4 to vhdx
    System.cmd("qemu-img", ["convert", "-f", "raw", "-O", "vhdx", ext4_path, vhdx_path])
  end

  defp parse_ip(ip_str) when is_binary(ip_str) do
    case String.split(ip_str, ".") do
      [a, b, c, d] ->
        {String.to_integer(a), String.to_integer(b), 
         String.to_integer(c), String.to_integer(d)}
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp kernel_path do
    Application.get_env(:zypi, :kernel_path)
  end
end
