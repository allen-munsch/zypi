// zypi-virt - Virtualization.framework helper for Zyppi
// Build: swift build -c release

import Foundation
import Virtualization

// VM configuration from JSON
struct VMConfig: Codable {
    let id: String
    let rootfs: String
    let kernel: String
    let memoryMB: Int
    let cpus: Int
    let ip: String
    let socketPath: String
    
    enum CodingKeys: String, CodingKey {
        case id, rootfs, kernel, ip
        case memoryMB = "memory_mb"
        case cpus
        case socketPath = "socket_path"
    }
}

class VMManager {
    var vms: [String: VZVirtualMachine] = [:]
    
    func startVM(config: VMConfig) throws {
        let vmConfig = VZVirtualMachineConfiguration()
        
        // Boot loader
        let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: config.kernel))
        bootLoader.commandLine = "console=hvc0 root=/dev/vda rw"
        vmConfig.bootLoader = bootLoader
        
        // CPU & Memory
        vmConfig.cpuCount = config.cpus
        vmConfig.memorySize = UInt64(config.memoryMB) * 1024 * 1024
        
        // Root disk
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: URL(fileURLWithPath: config.rootfs),
            readOnly: false
        )
        let disk = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
        vmConfig.storageDevices = [disk]
        
        // Network (NAT mode)
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        vmConfig.networkDevices = [network]
        
        // Serial console
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: FileHandle.standardInput,
            fileHandleForWriting: FileHandle.standardOutput
        )
        vmConfig.serialPorts = [serial]
        
        // Entropy
        vmConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        
        try vmConfig.validate()
        
        let vm = VZVirtualMachine(configuration: vmConfig)
        vms[config.id] = vm
        
        vm.start { result in
            switch result {
            case .success:
                print("VM \(config.id) started")
            case .failure(let error):
                print("VM start failed: \(error)")
            }
        }
    }
    
    func stopVM(id: String) {
        guard let vm = vms[id] else { return }
        
        if vm.canRequestStop {
            vm.requestStop { error in
                if let error = error {
                    print("Stop request failed: \(error)")
                }
            }
        }
        vms.removeValue(forKey: id)
    }
}

// Main entry point
let manager = VMManager()

if CommandLine.arguments.count < 2 {
    print("Usage: zypi-virt <start|stop|list> [options]")
    exit(1)
}

let command = CommandLine.arguments[1]

switch command {
case "start":
    guard CommandLine.arguments.count >= 4,
          CommandLine.arguments[2] == "--config" else {
        print("Usage: zypi-virt start --config <path>")
        exit(1)
    }
    
    let configPath = CommandLine.arguments[3]
    let configData = try! Data(contentsOf: URL(fileURLWithPath: configPath))
    let config = try! JSONDecoder().decode(VMConfig.self, from: configData)
    
    try! manager.startVM(config: config)
    
    // Keep running
    RunLoop.main.run()
    
case "stop":
    guard CommandLine.arguments.count >= 4,
          CommandLine.arguments[2] == "--id" else {
        print("Usage: zypi-virt stop --id <vm-id>")
        exit(1)
    }
    manager.stopVM(id: CommandLine.arguments[3])
    
case "list":
    for id in manager.vms.keys {
        print(id)
    }
    
default:
    print("Unknown command: \(command)")
    exit(1)
}
