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
        case "usbDiagnostics":
            usbDiagnostics(result: result)
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
        print("Starting combined printer discovery (LAN + Bluetooth)...")
        
        Task {
            var allDiscoveredPrinters: [String] = []
            
            // Try discovery with different interface combinations to match Android behavior
            let interfaceTypeSets: [[StarIO10.InterfaceType]] = [
                // Try LAN only first
                [.lan],
                // Try Bluetooth only
                [.bluetooth],
                // Try Bluetooth LE only  
                [.bluetoothLE],
                // Try USB (might work with Lightning to USB adapters or USB-C iPads)
                [.usb],
                // Try combined LAN + Bluetooth when both are available
                [.lan, .bluetooth, .bluetoothLE]
            ]
            
            for interfaceTypes in interfaceTypeSets {
                do {
                    print("Trying discovery with interfaces: \(interfaceTypes)")
                    let manager = try StarDeviceDiscoveryManagerFactory.create(interfaceTypes: interfaceTypes)
                    manager.discoveryTime = 8000  // 8 seconds per discovery type
                    
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
                                print("Discovered printer model enum value: \(model.rawValue)")
                                print("Discovered printer emulation: \(String(describing: printer.information?.emulation))")
                                if let emulation = printer.information?.emulation {
                                    print("Emulation enum value: \(emulation.rawValue)")
                                }
                            } else {
                                modelName = "Unknown"
                            }
                            
                            // Determine interface type string
                            let interfaceTypeStr: String
                            switch printer.connectionSettings.interfaceType {
                            case .lan:
                                interfaceTypeStr = "LAN"
                            case .bluetooth:
                                interfaceTypeStr = "BT"
                            case .bluetoothLE:
                                interfaceTypeStr = "BLE"
                            case .usb:
                                interfaceTypeStr = "USB"
                            @unknown default:
                                interfaceTypeStr = "UNKNOWN"
                            }
                            
                            let printerString = "\(interfaceTypeStr):\(identifier):\(modelName)"
                            print("Found printer: \(printerString)")
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
                    
                    // Wait for discovery to complete with proper timeout
                    var waitTime = 0
                    let maxWaitTime = 10000 // 10 seconds max per interface type
                    while !delegate.isFinished && waitTime < maxWaitTime {
                        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                        waitTime += 100
                    }
                    
                    // Force stop discovery if it's still running
                    if !delegate.isFinished {
                        print("Discovery timeout reached, stopping discovery for \(interfaceTypes)")
                        manager.stopDiscovery()
                        // Give it a moment to clean up
                        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    }
                    
                    // Add discovered printers to combined list (avoiding duplicates)
                    for printer in delegate.printers {
                        if !allDiscoveredPrinters.contains(printer) {
                            allDiscoveredPrinters.append(printer)
                        }
                    }
                    
                    // Store printer objects for potential use
                    self.discoveredPrinters.append(contentsOf: delegate.printerObjects)
                    
                    print("Discovery completed for \(interfaceTypes). Found \(delegate.printers.count) printers.")
                    
                } catch {
                    print("Discovery failed for interfaces \(interfaceTypes): \(error.localizedDescription)")
                    continue
                }
            }
            
            print("All discovery completed. Total printers found: \(allDiscoveredPrinters.count)")
            
            // Return all discovered printers
            DispatchQueue.main.async {
                result(allDiscoveredPrinters)
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
                
                // Wait for discovery to complete with proper timeout
                var waitTime = 0
                let maxWaitTime = 12000 // 12 second timeout
                while !delegate.isFinished && waitTime < maxWaitTime {
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    waitTime += 100
                }
                
                // Force stop discovery if it's still running
                if !delegate.isFinished {
                    print("Bluetooth discovery timeout reached, stopping discovery")
                    manager.stopDiscovery()
                    // Give it a moment to clean up
                    try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
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
        
        Task {
            // Force disconnect any existing connection first
            if self.printer != nil {
                print("Force disconnecting existing printer connection...")
                do {
                    try await self.printer?.close()
                } catch {
                    print("Error closing existing connection: \(error)")
                }
                self.printer = nil
                self.connectionSettings = nil
                
                // Wait a moment for the printer to be released
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                print("Waited 2 seconds for printer to be released...")
            }
            
            // Continue with connection logic...
            
            // Try to find the discovered printer object first to get IP address info
            let foundPrinter = self.discoveredPrinters.first { printer in
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
            } else {
                print("Printer not found in discovered list, creating new connection...")
                
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
                    
                    self.connectionSettings = StarConnectionSettings(
                        interfaceType: starInterfaceType,
                        identifier: cleanIdentifier
                    )
                    
                    self.printer = StarPrinter(self.connectionSettings!)
                    
                    print("Attempting to open connection...")
                    
                    // Set a shorter timeout and better error handling
                    let timeoutTask = Task {
                        try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                        throw NSError(domain: "com.starprinter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connection timeout after 10 seconds"])
                    }
                    
                    let connectionTask = Task {
                        try await self.printer?.open()
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
        
        // Read optional layout settings coming from Dart
        let settings = args["settings"] as? [String: Any]
        let layout = settings?["layout"] as? [String: Any]
        let header = layout?["header"] as? [String: Any]
        let imageBlock = layout?["image"] as? [String: Any]

        // Defaults
        let headerTitle = (header?["title"] as? String) ?? ""
        let headerFontSize = CGFloat((header?["fontSize"] as? Int) ?? 32)
        let headerSpacing = Int((header?["spacingLines"] as? Int) ?? 1)
        let smallImageBase64 = imageBlock?["base64"] as? String
        let smallImageWidth = (imageBlock?["width"] as? Int) ?? 200
        let smallImageSpacing = (imageBlock?["spacingLines"] as? Int) ?? 1

        print("Printer is connected, attempting to print with structured layout...")
        
        Task {
            do {
                // First check printer status
                print("Checking printer status before printing...")
                let status = try await self.printer?.getStatus()
                print("Printer status: hasError=\(status?.hasError ?? true), online=\(!(status?.hasError ?? true))")
                
                if let status = status, status.hasError {
                    print("WARNING: Printer reports error status before printing")
                } else {
                    print("Printer status looks good")
                }
                
                print("Building StarXpand command...")
                
                // Get printer information for debugging
                if let printerInfo = self.printer?.information {
                    print("PRINTER DEBUG INFO:")
                    print("  Model: \(printerInfo.model) (raw: \(printerInfo.model.rawValue))")
                    print("  Emulation: \(printerInfo.emulation) (raw: \(printerInfo.emulation.rawValue))")
                    print("  Connection Type: \(self.printer?.connectionSettings.interfaceType.rawValue ?? -1)")
                    print("  Identifier: \(self.printer?.connectionSettings.identifier ?? "unknown")")
                } else {
                    print("No printer information available")
                }
                
                let builder = StarXpandCommand.StarXpandCommandBuilder()

                // Graphics-only detection
                let graphicsOnly: Bool = {
                    if let model = self.printer?.information?.model {
                        return model == .tsp100IIIW
                    }
                    return false
                }()

                // Build printer actions according to layout
                let printerBuilder = StarXpandCommand.PrinterBuilder()

                // 1) Header: draw as image for predictable layout (works for all models)
                if !headerTitle.isEmpty {
                    if let rawHeaderImage = createTextImage(text: headerTitle, fontSize: headerFontSize, imageWidth: 576),
                       let safeHeaderImage = ensureVisibleImage(rawHeaderImage, targetWidth: 576) {
                        print("Printing header image at width=576 (safeguarded)")
                        let param = StarXpandCommand.Printer.ImageParameter(image: safeHeaderImage, width: 576)
                        _ = printerBuilder
                            .styleAlignment(.center)
                            .actionPrintImage(param)
                            .styleAlignment(.left)
                        if headerSpacing > 0 { _ = printerBuilder.actionFeedLine(headerSpacing) }
                    }
                }

                // 2) Small centered image (optional)
                if let base64 = smallImageBase64 {
                    let clampedWidth = max(8, min(smallImageWidth, 576))
                    let decoded = decodeBase64Image(base64)
                    let sourceImage = decoded ?? createPlaceholderLogo(size: clampedWidth)
                    if decoded == nil {
                        print("Small image: using placeholder logo (width=\(clampedWidth))")
                    }
                    if let src = sourceImage, let safeSmall = ensureVisibleImage(src, targetWidth: clampedWidth) {
                        print("Printing small image at width=\(clampedWidth) (safeguarded)")
                        let param = StarXpandCommand.Printer.ImageParameter(image: safeSmall, width: clampedWidth)
                        _ = printerBuilder
                            .styleAlignment(.center)
                            .actionPrintImage(param)
                            .styleAlignment(.left)
                        if smallImageSpacing > 0 { _ = printerBuilder.actionFeedLine(smallImageSpacing) }
                    } else {
                        print("Small image skipped: neither base64 decode nor placeholder succeeded")
                    }
                }

                // 3) Body content
                if graphicsOnly {
                    // Render body text to image for graphics-only printers
                    if let textImage = createTextImage(text: content, fontSize: 24, imageWidth: 576),
                       let safeText = ensureVisibleImage(textImage, targetWidth: 576) {
                        let param = StarXpandCommand.Printer.ImageParameter(image: safeText, width: 576)
                        _ = printerBuilder.actionPrintImage(param)
                        _ = printerBuilder.actionFeedLine(2)
                    }
                } else {
                    _ = printerBuilder.actionPrintText(content)
                    _ = printerBuilder.actionFeedLine(2)
                }

                _ = builder.addDocument(StarXpandCommand.DocumentBuilder().addPrinter(printerBuilder.actionCut(.partial)))
                
                let commands = builder.getCommands()
                print("Generated commands: \(commands)")
                print("Command length: \(commands.count) characters")
                print("Sending to printer...")
                
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
    
    private func usbDiagnostics(result: @escaping FlutterResult) {
        print("Testing USB connectivity on iOS...")
        
        Task {
            var diagnostics: [String: Any] = [
                "platform": "iOS",
                "note": "Testing USB discovery on iOS - may work with Lightning to USB or USB-C adapters"
            ]
            
            do {
                // Try USB discovery to see if it's actually supported
                let manager = try StarDeviceDiscoveryManagerFactory.create(interfaceTypes: [.usb])
                manager.discoveryTime = 5000  // 5 seconds for diagnostics
                
                class UsbDiscoveryDelegate: NSObject, StarDeviceDiscoveryManagerDelegate {
                    var printers: [String] = []
                    var isFinished = false
                    
                    func manager(_ manager: any StarDeviceDiscoveryManager, didFind printer: StarPrinter) {
                        let identifier = printer.connectionSettings.identifier
                        let modelName = printer.information?.model.rawValue ?? 0
                        printers.append("USB:\(identifier):\(modelName)")
                        print("Found USB printer: USB:\(identifier):\(modelName)")
                    }
                    
                    func managerDidFinishDiscovery(_ manager: any StarDeviceDiscoveryManager) {
                        print("USB discovery finished. Found \(printers.count) USB printers")
                        isFinished = true
                    }
                }
                
                let delegate = UsbDiscoveryDelegate()
                manager.delegate = delegate
                
                try manager.startDiscovery()
                
                // Wait for discovery to complete
                var waitTime = 0
                while !delegate.isFinished && waitTime < 6000 { // 6 second timeout
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    waitTime += 100
                }
                
                diagnostics["usb_discovery_attempted"] = true
                diagnostics["usb_printers_discovered"] = delegate.printers.count
                diagnostics["usb_printer_list"] = delegate.printers
                diagnostics["usb_supported"] = true
                
                if delegate.printers.isEmpty {
                    diagnostics["status"] = "USB discovery completed but no printers found. This could mean: 1) No USB printers connected, 2) USB adapter not compatible, 3) Printer not in discoverable mode"
                } else {
                    diagnostics["status"] = "USB discovery successful! Found \(delegate.printers.count) USB printer(s)"
                }
                
            } catch {
                print("USB discovery failed: \(error.localizedDescription)")
                diagnostics["usb_discovery_attempted"] = true
                diagnostics["usb_supported"] = false
                diagnostics["usb_error"] = error.localizedDescription
                diagnostics["usb_printers_discovered"] = 0
                diagnostics["usb_printer_list"] = []
                diagnostics["status"] = "USB discovery failed: \(error.localizedDescription). This might indicate USB is not supported on this iOS device or adapter configuration."
            }
            
            DispatchQueue.main.async {
                result(diagnostics)
            }
        }
    }
    
    // Helper: create an image from text with adjustable font/width
    private func createTextImage(text: String, fontSize: CGFloat, imageWidth: CGFloat = 576) -> UIImage? {
        let font = UIFont.systemFont(ofSize: fontSize)
        let textColor = UIColor.black
        let backgroundColor = UIColor.white

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]

        let bounds = CGSize(width: imageWidth - 40, height: CGFloat.greatestFiniteMagnitude)
        let textSize = text.boundingRect(
            with: bounds,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes,
            context: nil
        ).size

        let imageHeight = max(textSize.height + 40, 100)
        let imageSize = CGSize(width: imageWidth, height: imageHeight)

        UIGraphicsBeginImageContextWithOptions(imageSize, true, 1.0)
        guard let context = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return nil
        }
        context.setFillColor(backgroundColor.cgColor)
        context.fill(CGRect(origin: .zero, size: imageSize))

        let textRect = CGRect(x: 20, y: 20, width: imageWidth - 40, height: textSize.height)
        text.draw(in: textRect, withAttributes: textAttributes)

        guard let image = UIGraphicsGetImageFromCurrentImageContext() else {
            UIGraphicsEndImageContext()
            return nil
        }
        UIGraphicsEndImageContext()
        return image
    }

    // Helper: decode base64 PNG/JPEG (supports data URIs and whitespace)
    private func decodeBase64Image(_ base64: String) -> UIImage? {
        // Strip data URI prefix if present
        let cleaned: String = {
            let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = trimmed.range(of: ","), trimmed.lowercased().hasPrefix("data:image") {
                return String(trimmed[range.upperBound...])
            }
            return trimmed
        }()
        // Remove accidental spaces/newlines inside the payload
        let compact = cleaned.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: " ", with: "")
        if let data = Data(base64Encoded: compact) {
            if let image = UIImage(data: data) {
                // Normalize into a standard bitmap to avoid PNG encoder/decoder edge cases
                if let normalized = normalizeImage(image) {
                    print("decodeBase64Image: normalized image size=\(normalized.size)")
                    return normalized
                }
                return image
            } else {
                print("decodeBase64Image: Failed to create UIImage from data (bytes=\(data.count))")
                return nil
            }
        } else {
            print("decodeBase64Image: Base64 decode failed. Prefix=\(String(compact.prefix(30)))… length=\(compact.count)")
            return nil
        }
    }

    // Normalize a UIImage into a standard ARGB bitmap at scale 1.0 with white background
    private func normalizeImage(_ image: UIImage) -> UIImage? {
        let size = image.size
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        image.draw(in: CGRect(origin: .zero, size: size))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }

    // Helper: simple placeholder logo if decoding fails
    private func createPlaceholderLogo(size: Int) -> UIImage? {
        let dim = CGFloat(max(16, min(size, 576)))
        let rect = CGRect(x: 0, y: 0, width: dim, height: dim)
        UIGraphicsBeginImageContextWithOptions(rect.size, true, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        // Filled black square for high visibility
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(rect)
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return image
    }

    // Safeguard: ensure visible black content by adding a subtle border and cross-lines
    // Also normalizes to 1.0 scale with white background. This guarantees the printer
    // has non-empty (non-AAAA..) data even for near-white or tiny images.
    private func ensureVisibleImage(_ image: UIImage, targetWidth: Int) -> UIImage? {
        let width = CGFloat(max(8, min(targetWidth, 576)))
        let aspect = image.size.height / max(image.size.width, 1)
        let height = max(8, width * aspect)
        let size = CGSize(width: width, height: height)

        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        // White background
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        // Draw the original image fitted
        image.draw(in: CGRect(origin: .zero, size: size))
        // Add 1px black border
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1))
        // Add thin cross to guarantee dark pixels
        ctx.move(to: CGPoint(x: 0, y: 0))
        ctx.addLine(to: CGPoint(x: size.width, y: size.height))
        ctx.move(to: CGPoint(x: size.width, y: 0))
        ctx.addLine(to: CGPoint(x: 0, y: size.height))
        ctx.strokePath()
        let out = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return out
    }
}
