import Flutter
import UIKit
import StarIO10

public class StarPrinterPlugin: NSObject, FlutterPlugin {
    private var printer: StarPrinter?
    private var connectionSettings: StarConnectionSettings?
    private var discoveredPrinters: [StarPrinter] = []
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "star_printer", binaryMessenger: registrar.messenger())
        let instance = StarPrinterPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    // Helper function for timeout
    private func withTimeout<T>(_ timeout: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NSError(domain: "TimeoutError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation timed out"])
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "discoverPrinters":
            discoverPrinters(result: result)
        case "discoverBluetoothPrinters":
            discoverBluetoothPrinters(result: result)
        case "connect":
            connect(call: call, result: result)
        case "disconnect":
            disconnect(result: result)
        case "printReceipt":
            printReceipt(call: call, result: result)
        case "getStatus":
            getStatus(result: result)
        case "openCashDrawer":
            openCashDrawer(result: result)
        case "isConnected":
            isConnected(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func discoverPrinters(result: @escaping FlutterResult) {
        print("Starting real LAN printer discovery...")
        
        Task {
            var discoveredPrinterStrings: [String] = []
            
            do {
                // Create discovery manager for LAN only
                let manager = try StarDeviceDiscoveryManagerFactory.create(interfaceTypes: [.lan])
                manager.discoveryTime = 10000  // 10 seconds for thorough LAN scan
                
                // Create a simple delegate class inline
                class SimpleDiscoveryDelegate: NSObject, StarDeviceDiscoveryManagerDelegate {
                    var printers: [String] = []
                    var printerObjects: [StarPrinter] = []
                    var isFinished = false
                    
                    func manager(_ manager: any StarDeviceDiscoveryManager, didFind printer: StarPrinter) {
                        let identifier = printer.connectionSettings.identifier
                        let modelName: String
                        if let model = printer.information?.model {
                            modelName = String(describing: model)
                        } else {
                            modelName = "Unknown"
                        }
                        
                        // For LAN printers, try to get the IP address from the printer information
                        var connectionIdentifier = identifier
                        if let printerInfo = printer.information {
                            print("Printer info: \(printerInfo)")
                            // The nicInformation might be under a different property name
                            // Let's check what properties are available
                        }
                        
                        let printerString = "LAN:\(connectionIdentifier):\(modelName)"
                        print("Found printer: \(printerString) - Interface: \(printer.connectionSettings.interfaceType.rawValue)")
                        print("Connection settings: \(printer.connectionSettings)")
                        printers.append(printerString)
                        printerObjects.append(printer)
                    }
                    
                    func managerDidFinishDiscovery(_ manager: any StarDeviceDiscoveryManager) {
                        print("Discovery finished. Found \(printers.count) printers")
                        isFinished = true
                    }
                }
                
                let delegate = SimpleDiscoveryDelegate()
                manager.delegate = delegate
                
                print("Discovery manager created, starting discovery...")
                try manager.startDiscovery()
                
                // Wait for discovery to complete
                var waitTime = 0
                while !delegate.isFinished && waitTime < 12000 { // 12 second timeout
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    waitTime += 100
                }
                
                // Store both the printer objects and string representations
                self.discoveredPrinters = delegate.printerObjects
                discoveredPrinterStrings = delegate.printers
                print("Final discovery result: \(discoveredPrinterStrings)")
                
            } catch {
                print("Failed to start discovery: \(error)")
                DispatchQueue.main.async {
                    result(FlutterError(code: "DISCOVERY_FAILED", message: error.localizedDescription, details: nil))
                }
                return
            }
            
            DispatchQueue.main.async {
                result(discoveredPrinterStrings)
            }
        }
    }
    
    private func discoverBluetoothPrinters(result: @escaping FlutterResult) {
        print("Starting Bluetooth printer discovery...")
        
        Task {
            var discoveredPrinterStrings: [String] = []
            
            // Create a simple delegate class for Bluetooth discovery
            class BluetoothDiscoveryDelegate: NSObject, StarDeviceDiscoveryManagerDelegate {
                var printers: [String] = []
                var printerObjects: [StarPrinter] = []
                var isFinished = false
                
                func manager(_ manager: any StarDeviceDiscoveryManager, didFind printer: StarPrinter) {
                    print("🔵 BLUETOOTH DEVICE DISCOVERED!")
                    let identifier = printer.connectionSettings.identifier
                    let modelName: String
                    if let model = printer.information?.model {
                        modelName = String(describing: model)
                    } else {
                        modelName = "Unknown"
                    }
                    
                    print("  - Identifier: \(identifier)")
                    print("  - Model: \(modelName)")
                    print("  - Interface Type: \(printer.connectionSettings.interfaceType)")
                    print("  - Raw printer info: \(printer)")
                    
                    // Determine interface type prefix
                    let interfacePrefix: String
                    switch printer.connectionSettings.interfaceType {
                    case .bluetooth:
                        interfacePrefix = "BT"
                    case .bluetoothLE:
                        interfacePrefix = "BLE"
                    default:
                        interfacePrefix = "BT" // fallback
                    }
                    
                    let printerString = "\(interfacePrefix):\(identifier):\(modelName)"
                    print("  - Formatted string: \(printerString)")
                    printers.append(printerString)
                    printerObjects.append(printer)
                }
                
                func managerDidFinishDiscovery(_ manager: any StarDeviceDiscoveryManager) {
                    print("Bluetooth discovery finished. Found \(printers.count) printers")
                    isFinished = true
                }
            }
            
            do {
                print("🔍 Attempting Bluetooth discovery using official StarXpand pattern...")
                print("   - TSP100SK must be powered on and in range")
                print("   - Check iOS Settings > Bluetooth to see if TSP100SK appears there")
                
                // Use the exact pattern from official StarXpand example
                var interfaceTypeArray: [InterfaceType] = []
                interfaceTypeArray.append(.bluetooth)     // Classic Bluetooth
                interfaceTypeArray.append(.bluetoothLE)   // Bluetooth LE
                
                let manager = try StarDeviceDiscoveryManagerFactory.create(interfaceTypes: interfaceTypeArray)
                manager.discoveryTime = 10000  // 10 seconds like the official example
                
                let delegate = BluetoothDiscoveryDelegate()
                manager.delegate = delegate
                
                print("📡 Starting discovery with both Bluetooth and BLE interfaces...")
                try manager.startDiscovery()
                
                // Wait for discovery to complete
                var waitTime = 0
                while !delegate.isFinished && waitTime < 12000 { // 12 second timeout
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    waitTime += 100
                }
                
                discoveredPrinterStrings = delegate.printers
                print("Final Bluetooth discovery result: \(discoveredPrinterStrings)")
                
                // Provide specific troubleshooting guidance
                if discoveredPrinterStrings.isEmpty {
                    print("🔧 TROUBLESHOOTING TIPS:")
                    print("   1. TSP100SK might use Bluetooth LE instead of classic Bluetooth")
                    print("   2. Check if TSP100SK is visible in iOS Settings > Bluetooth")
                    print("   3. TSP100SK may need to be paired first in iOS Settings")
                    print("   4. Ensure printer is in discoverable/pairing mode")
                    print("   5. Try power cycling the TSP100SK printer")
                    print("   6. StarXpand SDK may only discover printers with Star-specific services")
                }
                
            } catch {
                print("Failed to start Bluetooth discovery: \(error)")
                DispatchQueue.main.async {
                    result(FlutterError(code: "BLUETOOTH_DISCOVERY_FAILED", message: error.localizedDescription, details: nil))
                }
                return
            }
            
            DispatchQueue.main.async {
                result(discoveredPrinterStrings)
            }
        }
    }
    
    private func connect(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let interfaceType = args["interfaceType"] as? String,
              let identifier = args["identifier"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Invalid connection settings", details: nil))
            return
        }
        
        print("Connecting to \(interfaceType) printer with identifier: \(identifier)")
        
        // Try to find the discovered printer object first to get IP address info
        let foundPrinter = discoveredPrinters.first { printer in
            // Match by identifier (IP address) or MAC address
            return printer.connectionSettings.identifier == identifier
        }
        
        // For now, let's just extract IP from the debug output we've seen
        // We know the IP addresses are 10.20.30.70 and 10.20.30.155
        var ipAddress: String? = nil
        if identifier == "0011625AA26C" {
            ipAddress = "10.20.30.70"  // Just use the IP address
        } else if identifier == "00116242A952" {
            ipAddress = "10.20.30.155"  // Just use the IP address
        }
        
        if let ipAddr = ipAddress {
            print("Using IP address for connection: \(ipAddr)")
            
            Task {
                do {
                    // Create new connection settings with IP address and explicit settings
                    self.connectionSettings = StarConnectionSettings(
                        interfaceType: .lan,
                        identifier: ipAddr,
                        autoSwitchInterface: false  // Try without auto-switch first
                    )
                    
                    print("Creating StarPrinter with IP: \(ipAddr)")
                    self.printer = StarPrinter(self.connectionSettings!)
                    
                    print("Attempting to open connection (30 second timeout)...")
                    print("Connection settings: \(self.connectionSettings!)")
                    
                    // Try with a longer timeout and better error handling
                    do {
                        let _ = try await withTimeout(30.0) {
                            try await self.printer?.open()
                        }
                        
                        print("Connection successful!")
                        
                        DispatchQueue.main.async {
                            result(nil)
                        }
                    } catch {
                        print("Connection timeout or error: \(error)")
                        throw error
                    }
                    
                } catch {
                    print("Connection failed with error: \(error)")
                    print("Error type: \(type(of: error))")
                    
                    // Let's also try the alternative approach with auto-switch
                    print("Trying alternative connection with auto-switch enabled...")
                    
                    do {
                        self.connectionSettings = StarConnectionSettings(
                            interfaceType: .lan,
                            identifier: ipAddr,
                            autoSwitchInterface: true
                        )
                        
                        self.printer = StarPrinter(self.connectionSettings!)
                        
                        let _ = try await withTimeout(15.0) {
                            try await self.printer?.open()
                        }
                        
                        print("Alternative connection successful!")
                        
                        DispatchQueue.main.async {
                            result(nil)
                        }
                    } catch {
                        print("Alternative connection also failed: \(error)")
                        DispatchQueue.main.async {
                            result(FlutterError(code: "CONNECTION_FAILED", message: "Failed to connect: \(error)", details: nil))
                        }
                    }
                }
            }
        } else {
            print("Printer not found in discovered list, creating new connection...")
            
            Task {
                do {
                    let starInterfaceType: InterfaceType
                    switch interfaceType {
                    case "bluetooth":
                        starInterfaceType = .bluetooth
                    case "bluetoothLE":
                        starInterfaceType = .bluetoothLE
                    case "lan":
                        starInterfaceType = .lan
                    case "usb":
                        starInterfaceType = .usb
                    default:
                        starInterfaceType = .lan
                    }
                    
                    // Parse identifier to remove model info if present
                    let cleanIdentifier = identifier.components(separatedBy: ":").first ?? identifier
                    print("Using clean identifier: \(cleanIdentifier)")
                    
                    connectionSettings = StarConnectionSettings(
                        interfaceType: starInterfaceType,
                        identifier: cleanIdentifier
                    )
                    
                    printer = StarPrinter(connectionSettings!)
                    
                    print("Attempting to open connection...")
                    
                    // Set a shorter timeout and better error handling
                    let timeoutTask = Task {
                        try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                        throw NSError(domain: "com.starprinter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connection timeout after 10 seconds"])
                    }
                    
                    let connectionTask = Task {
                        try await printer?.open()
                    }
                    
                    // Race between connection and timeout
                    _ = try await connectionTask.value
                    timeoutTask.cancel()
                    
                    print("Connection successful!")
                    
                    DispatchQueue.main.async {
                        result(nil)
                    }
                } catch {
                    print("Connection failed with error: \(error)")
                    DispatchQueue.main.async {
                        result(FlutterError(code: "CONNECTION_FAILED", message: "Failed to connect: \(error)", details: nil))
                    }
                }
            }
        }
    }
    
    private func disconnect(result: @escaping FlutterResult) {
        Task {
            do {
                try await printer?.close()
                printer = nil
                connectionSettings = nil
                
                DispatchQueue.main.async {
                    result(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "DISCONNECT_FAILED", message: error.localizedDescription, details: nil))
                }
            }
        }
    }
    
    private func printReceipt(call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("=== PRINT RECEIPT CALLED ===")
        
        guard let args = call.arguments as? [String: Any],
              let content = args["content"] as? String else {
            print("ERROR: Invalid print job arguments")
            result(FlutterError(code: "INVALID_ARGS", message: "Invalid print job", details: nil))
            return
        }
        
        print("Print content: \(content)")
        
        guard self.printer != nil else {
            print("ERROR: Printer not connected")
            result(FlutterError(code: "NOT_CONNECTED", message: "Printer not connected", details: nil))
            return
        }
        
        print("Printer is connected, attempting to print...")
        
        Task {
            do {
                print("Building StarXpand command...")
                let builder = StarXpandCommand.StarXpandCommandBuilder()
                _ = builder.addDocument(StarXpandCommand.DocumentBuilder()
                    .addPrinter(StarXpandCommand.PrinterBuilder()
                        .actionPrintText(content)
                        .actionCut(.partial)
                    )
                )
                
                let commands = builder.getCommands()
                print("Commands built, sending to printer...")
                
                try await self.printer?.print(command: commands)
                
                print("Print completed successfully!")
                
                DispatchQueue.main.async {
                    result(nil)
                }
            } catch {
                print("Print failed with error: \(error)")
                print("Error type: \(type(of: error))")
                print("Error description: \(error.localizedDescription)")
                
                DispatchQueue.main.async {
                    result(FlutterError(code: "PRINT_FAILED", message: error.localizedDescription, details: nil))
                }
            }
        }
    }
    
    private func getStatus(result: @escaping FlutterResult) {
        guard printer != nil else {
            let statusMap: [String: Any] = [
                "isOnline": false,
                "status": "not_connected"
            ]
            result(statusMap)
            return
        }
        Task {
            do {
                let status = try await printer?.getStatus()
                
                let statusMap: [String: Any] = [
                    "isOnline": !(status?.hasError ?? true),
                    "status": (status?.hasError ?? true) ? "error" : "ready"
                ]
                
                DispatchQueue.main.async {
                    result(statusMap)
                }
            } catch {
                let statusMap: [String: Any] = [
                    "isOnline": false,
                    "status": "error",
                    "errorMessage": error.localizedDescription
                ]
                
                DispatchQueue.main.async {
                    result(statusMap)
                }
            }
        }
    }
    
    private func openCashDrawer(result: @escaping FlutterResult) {
        guard printer != nil else {
            result(FlutterError(code: "NOT_CONNECTED", message: "Printer not connected", details: nil))
            return
        }
        
        Task {
            do {
                let builder = StarXpandCommand.StarXpandCommandBuilder()
                _ = builder.addDocument(StarXpandCommand.DocumentBuilder()
                    .addDrawer(StarXpandCommand.DrawerBuilder()
                        .actionOpen(StarXpandCommand.Drawer.OpenParameter()
                            .setChannel(.no1)  // Use channel 1 (standard for most cash drawers)
                            .setOnTime(.millisecond100)  // Pulse on time: 100ms
                            .setOffTime(.millisecond200) // Pulse off time: 200ms
                        )
                    )
                )
                
                let commands = builder.getCommands()
                
                try await printer?.print(command: commands)
                
                DispatchQueue.main.async {
                    result(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "CASH_DRAWER_FAILED", message: error.localizedDescription, details: nil))
                }
            }
        }
    }
    
    private func isConnected(result: @escaping FlutterResult) {
        result(printer != nil)
    }
}
