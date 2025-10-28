import Flutter
import UIKit
import StarIO10

public class StarPrinterPlugin: NSObject, FlutterPlugin {
    private var printer: StarPrinter?
    private var connectionSettings: StarConnectionSettings?
    private var discoveredPrinters: [StarPrinter] = []
    
    // Determine printable pixel width for current printer (rough mapping by model)
    private func currentPrintableWidthDots() -> Int {
        guard let model = self.printer?.information?.model else { return 576 }
        let name = String(describing: model).lowercased()
        print("DEBUG: Printer model for width calculation: \(name)")
        // Common mappings (approx): 80mm -> 576 dots, 58mm/2-inch -> 384 dots
        // TSP100SK uses 2" labels at 203 DPI = ~406 dots, but printable area appears much narrower
        // 
        // ADJUST THIS VALUE if labels are still being cut off:
        // - If content is cut off on right: decrease this number (try 220, 200, etc.)
        // - If content appears too narrow with margins: increase this number (try 260, 280, etc.)
        let tsp100skWidth = 256  // Optimized for TSP100SK label printing
        
        if name.contains("mpop") { return 384 }
        if name.contains("mc_label2") || name.contains("mc-label2") { return 384 }
        if name.contains("tsp100iv_sk") || name.contains("tsp100iv-sk") || name.contains("sk") { 
            print("DEBUG: TSP100SK detected, using \(tsp100skWidth) dots width")
            return tsp100skWidth
        }
        if name.contains("mc_print3") || name.contains("mc-print3") { return 576 }
        if name.contains("tsp100iv") || name.contains("tsp100iii") { return 576 }
        return 576
    }
    
    // Approximate printable width in millimeters for ruled lines
    private func currentPrintableWidthMm() -> Double {
        let dots = currentPrintableWidthDots()
        if dots >= 560 { return 72.0 } // 80mm class
        if dots >= 240 && dots <= 250 { return 48.0 } // TSP100SK 2-inch label printer
        if dots >= 380 { return 48.0 } // 58mm/2-inch class
        return 40.0
    }
    
    // Estimate characters per line for TextParameter widths
    private func currentColumnsPerLine() -> Int {
        let dots = currentPrintableWidthDots()
        if dots >= 560 { return 48 }
        if dots >= 380 { return 32 }
        // TSP100SK with 240 dots - at standard font (~12 dots/char), can fit ~20 chars
        if dots >= 240 { return 32 }  // Use 32 to match standard 2-inch printers
        return 24
    }

    // Identify narrow label printers where text-mode columns may not map well
    private func isLabelPrinter() -> Bool {
        guard let model = self.printer?.information?.model else { return false }
        let name = String(describing: model).lowercased()
        let isLabel = name.contains("mc_label2") || name.contains("mc-label2") || 
               name.contains("tsp100iv_sk") || name.contains("tsp100iv-sk") || name.contains("sk")
        print("DEBUG: isLabelPrinter check for '\(name)': \(isLabel)")
        return isLabel
    }
    
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
            
            // Optimized discovery strategy: try combined first for speed, fallback to individual
            let interfaceTypeSets: [[StarIO10.InterfaceType]] = [
                // Try combined discovery FIRST (most efficient - gets everything in one shot)
                [.lan, .bluetooth, .usb],
                // Individual fallbacks only if combined misses something (unlikely)
                [.lan],
                [.bluetooth], 
                [.usb],
                // BLE only as last resort with minimal timeout
                [.bluetoothLE]
            ]
            
            for (index, interfaceTypes) in interfaceTypeSets.enumerated() {
                let isCombined = interfaceTypes.count > 1 && interfaceTypes.contains(.lan) && interfaceTypes.contains(.bluetooth)
                let isBLEOnly = interfaceTypes.count == 1 && interfaceTypes.first == .bluetoothLE
                
                // Early exit optimization: if combined discovery found printers, skip individual fallbacks
                if index > 0 && !isBLEOnly && !allDiscoveredPrinters.isEmpty {
                    print("Skipping individual discovery for \(interfaceTypes) - combined discovery already found \(allDiscoveredPrinters.count) printers")
                    continue
                }
                
                // Skip BLE if we already found printers via faster interfaces
                if isBLEOnly && !allDiscoveredPrinters.isEmpty {
                    print("Skipping BLE discovery - already found \(allDiscoveredPrinters.count) printers via faster interfaces")
                    continue
                }
                
                do {
                    print("Trying discovery with interfaces: \(interfaceTypes)")
                    let manager = try StarDeviceDiscoveryManagerFactory.create(interfaceTypes: interfaceTypes)
                    
                    // Timeout strategy: combined gets more time, BLE gets less, others are moderate
                    if isCombined {
                        manager.discoveryTime = 6000  // 6 seconds for combined (doing all the work)
                        print("Using extended timeout for combined discovery: 6 seconds")
                    } else if isBLEOnly {
                        manager.discoveryTime = 2000  // Only 2 seconds for BLE (very aggressive)
                        print("Using reduced timeout for BLE-only discovery: 2 seconds")
                    } else {
                        manager.discoveryTime = 4000  // 4 seconds for individual interfaces
                    }
                    
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
                    
                    // Wait for discovery with interface-specific timeout
                    var waitTime = 0
                    let maxWaitTime = isCombined ? 7000 : (isBLEOnly ? 3000 : 5000) // 7s combined, 3s BLE, 5s others
                    while !delegate.isFinished && waitTime < maxWaitTime {
                        try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds (optimized polling)
                        waitTime += 50
                    }
                    
                    // Force stop discovery if it's still running
                    if !delegate.isFinished {
                        print("Discovery timeout reached, stopping discovery for \(interfaceTypes)")
                        manager.stopDiscovery()
                        // Reduced cleanup time for faster response
                        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
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
                manager.discoveryTime = 7000  // 7 seconds (optimized from 10)
                
                let delegate = BluetoothDiscoveryDelegate()
                manager.delegate = delegate
                
                print("📡 Starting discovery with both Bluetooth and BLE interfaces...")
                try manager.startDiscovery()
                
                // Wait for discovery to complete with optimized timeout
                var waitTime = 0
                let maxWaitTime = 8000 // 8 second timeout (optimized from 12)
                while !delegate.isFinished && waitTime < maxWaitTime {
                    try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds (optimized polling)
                    waitTime += 50
                }
                
                // Force stop discovery if it's still running
                if !delegate.isFinished {
                    print("Bluetooth discovery timeout reached, stopping discovery")
                    manager.stopDiscovery()
                    // Reduced cleanup time for faster response
                    try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
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
                
                // Wait a shorter time for the printer to be released
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second (optimized from 2)
                print("Waited 1 second for printer to be released...")
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
    let details = layout?["details"] as? [String: Any]
    let barcodeBlock = layout?["barcode"] as? [String: Any]

        // Defaults
        let headerTitle = (header?["title"] as? String) ?? ""
        let headerFontSize = CGFloat((header?["fontSize"] as? Int) ?? 32)
        let headerSpacing = Int((header?["spacingLines"] as? Int) ?? 1)
    let smallImageBase64 = imageBlock?["base64"] as? String
        let smallImageWidth = (imageBlock?["width"] as? Int) ?? 200
        let smallImageSpacing = (imageBlock?["spacingLines"] as? Int) ?? 1
    // Details
    let locationText = (details?["locationText"] as? String) ?? ""
    let dateText = (details?["date"] as? String) ?? ""
    let timeText = (details?["time"] as? String) ?? ""
    let cashier = (details?["cashier"] as? String) ?? ""
    let receiptNum = (details?["receiptNum"] as? String) ?? ""
    let lane = (details?["lane"] as? String) ?? ""
    let footer = (details?["footer"] as? String) ?? ""
    // Label-specific details
    let category = (details?["category"] as? String) ?? ""
    let size = (details?["size"] as? String) ?? ""
    let color = (details?["color"] as? String) ?? ""
    let labelPrice = (details?["price"] as? String) ?? ""
    // Barcode
    let barcodeContent = (barcodeBlock?["content"] as? String) ?? ""
    let barcodeSymbology = (barcodeBlock?["symbology"] as? String) ?? "code128"
    let barcodeHeight = (barcodeBlock?["height"] as? Int) ?? 50
    let barcodePrintHRI = (barcodeBlock?["printHRI"] as? Bool) ?? true
    
    print("DEBUG: Barcode settings from Dart - content=\(barcodeContent), height=\(barcodeHeight), symbology=\(barcodeSymbology)")

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
                    
                    // Try to log all available properties
                    print("  Checking for paper width information...")
                    let mirror = Mirror(reflecting: printerInfo)
                    for child in mirror.children {
                        print("  Property: \(child.label ?? "unknown") = \(child.value)")
                    }
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

                // Build printer actions according to layout (follow Star sample structure)
                let printerBuilder = StarXpandCommand.PrinterBuilder()
                // Use detected printable width per model
                let targetDots = currentPrintableWidthDots()
                let fullWidthMm: Double = currentPrintableWidthMm()

                // 1) Header: print as image (simple UIImage like the sample)
                if !headerTitle.isEmpty {
                    if let headerImageRaw = createTextImage(text: headerTitle, fontSize: headerFontSize, imageWidth: CGFloat(targetDots)),
                       let headerFlat = flattenImage(headerImageRaw, targetWidth: targetDots) {
                        print("Printing header image at width=\(targetDots) (flattened UIImage)")
                        let param = StarXpandCommand.Printer.ImageParameter(image: headerFlat, width: targetDots)
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
                    if let src = sourceImage, let flatSmall = flattenImage(src, targetWidth: clampedWidth) {
                        // Center the small image on a full-width canvas to ensure horizontal centering on all models
                        let canvasWidth = targetDots
                        let centered = centerOnCanvas(image: flatSmall, canvasWidth: canvasWidth) ?? flatSmall
                        print("Printing small image centered on canvas (target=\(clampedWidth), canvas=\(canvasWidth))")
                        let param = StarXpandCommand.Printer.ImageParameter(image: centered, width: canvasWidth)
                        _ = printerBuilder
                            .styleAlignment(.center)
                            .actionPrintImage(param)
                            .styleAlignment(.left)
                        if smallImageSpacing > 0 { _ = printerBuilder.actionFeedLine(smallImageSpacing) }
                    } else {
                        print("Small image skipped: neither base64 decode nor placeholder succeeded")
                    }
                }

                // Store barcode info for later (print at end for labels)
                let hasBarcodeData = !barcodeContent.isEmpty
                let barcodeSymbology_stored = barcodeSymbology
                let barcodeHeight_stored = barcodeHeight
                let barcodePrintHRI_stored = barcodePrintHRI

                // 2.6) Details block below the image/barcode
                let items = (layout?["items"] as? [[String: Any]]) ?? []
                let hasAnyDetails = !locationText.isEmpty || !dateText.isEmpty || !timeText.isEmpty || !cashier.isEmpty || !receiptNum.isEmpty || !lane.isEmpty || !footer.isEmpty
                if hasAnyDetails {
                    // Only use image rendering for graphics-only printers (TSP100IIIW)
                    // Label printers (TSP100SK) support native text commands
                    if graphicsOnly {
                        // For label printers, use actual targetDots width for proper rendering
                        let detailsCanvasDots = targetDots
                        if let detailsImage = createDetailsImage(location: locationText,
                                                                 date: dateText,
                                                                 time: timeText,
                                                                 cashier: cashier,
                                                                 receiptNum: receiptNum,
                                                                 lane: lane,
                                                                 footer: footer,
                                                                 items: items,
                                                                 imageWidth: CGFloat(detailsCanvasDots)) {
                            let param = StarXpandCommand.Printer.ImageParameter(image: detailsImage, width: detailsCanvasDots)
                            _ = printerBuilder.actionPrintImage(param)
                            _ = printerBuilder.actionFeedLine(1)
                        }
                    } else {
                        // Centered location
                        if !locationText.isEmpty {
                            _ = printerBuilder
                                .styleAlignment(.center)
                                .actionPrintText("\(locationText)\n")
                                .styleAlignment(.left)
                            _ = printerBuilder.actionFeedLine(1) // blank line
                        }
                        // Centered Tax Invoice
                        _ = printerBuilder
                            .styleAlignment(.center)
                            .actionPrintText("Tax Invoice\n")
                            .styleAlignment(.left)
                        // Line: left date/time, right cashier
                        let left1 = "\(dateText) \(timeText)"
                        let right1 = cashier.isEmpty ? "" : "Cashier: \(cashier)"
                        let totalCPL = currentColumnsPerLine()
                        let leftWidth = max(8, totalCPL / 2)
                        let rightWidth = max(8, totalCPL - leftWidth)
                        let leftParam = StarXpandCommand.Printer.TextParameter().setWidth(leftWidth)
                        let rightParam = StarXpandCommand.Printer.TextParameter().setWidth(rightWidth, StarXpandCommand.Printer.TextWidthParameter().setAlignment(.right))
                        _ = printerBuilder.actionPrintText(left1, leftParam)
                        _ = printerBuilder.actionPrintText("\(right1)\n", rightParam)
                        // Line: left receipt no, right lane
                        let left2 = receiptNum.isEmpty ? "" : "Receipt No: \(receiptNum)"
                        let right2 = lane.isEmpty ? "" : "Lane: \(lane)"
                        _ = printerBuilder.actionPrintText(left2, leftParam)
                        _ = printerBuilder.actionPrintText("\(right2)\n", rightParam)
                        // Gap then first ruled line
                        _ = printerBuilder.actionFeedLine(1)
                        _ = printerBuilder.actionPrintRuledLine(StarXpandCommand.Printer.RuledLineParameter(width: fullWidthMm))

                        // Item lines inserted here (left description, right price) before second ruled line
                        if !items.isEmpty {
                            let leftItemsWidth = max(8, Int(Double(totalCPL) * 0.625))
                            let rightItemsWidth = max(6, totalCPL - leftItemsWidth)
                            let leftParamItems = StarXpandCommand.Printer.TextParameter().setWidth(leftItemsWidth)
                            let rightParamItems = StarXpandCommand.Printer.TextParameter().setWidth(rightItemsWidth, StarXpandCommand.Printer.TextWidthParameter().setAlignment(.right))
                            for item in items {
                                let qty = (item["quantity"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "1"
                                let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Item"
                                let priceRaw = (item["price"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.00"
                                let repeatRaw = (item["repeat"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "1"
                                let repeatCount = Int(repeatRaw) ?? 1
                                let leftText = "\(qty) x \(name)"
                                let rightText = "$\(priceRaw)"
                                for _ in 0..<max(1, min(repeatCount, 200)) {
                                    _ = printerBuilder.actionPrintText(leftText, leftParamItems)
                                    _ = printerBuilder.actionPrintText("\(rightText)\n", rightParamItems)
                                }
                            }
                        }

                        // Second ruled line after items
                        _ = printerBuilder.actionPrintRuledLine(StarXpandCommand.Printer.RuledLineParameter(width: fullWidthMm))
                        _ = printerBuilder.actionFeedLine(1)
                        // Footer (centered) if present
                        if !footer.isEmpty {
                            _ = printerBuilder
                                .styleAlignment(.center)
                                .actionPrintText("\(footer)\n")
                                .styleAlignment(.left)
                        }
                    }
                }

                // 3) Body content or Label template
                let trimmedBody = content.trimmingCharacters(in: .whitespacesAndNewlines)
                let labelPrinter = isLabelPrinter()
                
                // Check if this is a label template (has label-specific fields)
                let hasLabelFields = !category.isEmpty || !size.isEmpty || !color.isEmpty || !labelPrice.isEmpty
                
                print("DEBUG: Rendering body content - graphicsOnly=\(graphicsOnly), labelPrinter=\(labelPrinter), hasLabelFields=\(hasLabelFields), contentLength=\(trimmedBody.count)")
                
                if labelPrinter && hasLabelFields {
                    // Label template rendering
                    print("DEBUG: Rendering label template")
                    
                    // Category (centered, below header)
                    if !category.isEmpty {
                        _ = printerBuilder
                            .styleAlignment(.center)
                            .actionPrintText("\(category)\n")
                            .styleAlignment(.left)
                    }
                    
                    // Size (left, normal size)
                    if !size.isEmpty {
                        _ = printerBuilder.actionPrintText("\(size)\n")
                    }
                    
                    // Color (left) and Price (right, magnified) on same line
                    // Use simple left-aligned text for color and right-aligned magnified price
                    if !color.isEmpty {
                        _ = printerBuilder.actionPrintText("\(color)\n")
                    }
                    
                    if !labelPrice.isEmpty {
                        _ = printerBuilder
                            .styleMagnification(StarXpandCommand.MagnificationParameter(width: 2, height: 2))
                            .styleAlignment(.right)
                            .actionPrintText("$\(labelPrice)\n")
                            .styleMagnification(StarXpandCommand.MagnificationParameter(width: 1, height: 1))
                            .styleAlignment(.left)
                    }
                    
                    _ = printerBuilder.actionFeedLine(1)
                    
                    // Now print barcode at the bottom for labels
                    if hasBarcodeData {
                        print("DEBUG: Printing barcode at bottom: content=\(barcodeContent), symbology=\(barcodeSymbology_stored), height=\(barcodeHeight_stored)")
                        
                        let symbology: StarXpandCommand.Printer.BarcodeSymbology
                        switch barcodeSymbology_stored.lowercased() {
                        case "code128":
                            symbology = .code128
                        case "code39":
                            symbology = .code39
                        case "code93":
                            symbology = .code93
                        case "jan8", "ean8":
                            symbology = .jan8
                        case "jan13", "ean13":
                            symbology = .jan13
                        case "upca":
                            symbology = .upcA
                        case "upce":
                            symbology = .upcE
                        case "itf":
                            symbology = .itf
                        case "nw7", "codabar":
                            symbology = .nw7
                        default:
                            symbology = .code128
                        }
                        
                        let barcodeParam = StarXpandCommand.Printer.BarcodeParameter(content: barcodeContent, symbology: symbology)
                            .setHeight(Double(barcodeHeight_stored))
                            .setPrintHRI(barcodePrintHRI_stored)
                        
                        _ = printerBuilder
                            .styleAlignment(.center)
                            .actionPrintBarcode(barcodeParam)
                            .styleAlignment(.left)
                        
                        print("DEBUG: Barcode command added at bottom")
                    }
                    
                } else if graphicsOnly {
                    // Only render a body image for graphics-only models (e.g. TSP100IIIW)
                    // Label printers (TSP100SK) and receipt printers support native text commands
                    if !trimmedBody.isEmpty,
                       let textImage = createTextImage(text: content, fontSize: 24, imageWidth: CGFloat(targetDots)),
                       let safeText = ensureVisibleImage(textImage, targetWidth: targetDots) {
                        print("DEBUG: Rendering body as image for graphics-only printer")
                        let param = StarXpandCommand.Printer.ImageParameter(image: safeText, width: targetDots)
                        _ = printerBuilder.actionPrintImage(param)
                        _ = printerBuilder.actionFeedLine(2)
                    } else {
                        // Provide a small feed for bottom margin consistency when skipping body.
                        print("DEBUG: Skipping body content (empty or image creation failed)")
                        _ = printerBuilder.actionFeedLine(1)
                    }
                } else {
                    print("DEBUG: Rendering body as text")
                    // For label printers, center the text content
                    if labelPrinter {
                        _ = printerBuilder
                            .styleAlignment(.center)
                            .actionPrintText(content)
                            .styleAlignment(.left)
                    } else {
                        _ = printerBuilder.actionPrintText(content)
                    }
                    _ = printerBuilder.actionFeedLine(2)
                    
                    // Print barcode for non-label receipts
                    if hasBarcodeData && !labelPrinter {
                        print("DEBUG: Printing barcode for receipt: content=\(barcodeContent)")
                        
                        let symbology: StarXpandCommand.Printer.BarcodeSymbology
                        switch barcodeSymbology_stored.lowercased() {
                        case "code128":
                            symbology = .code128
                        case "code39":
                            symbology = .code39
                        case "code93":
                            symbology = .code93
                        case "jan8", "ean8":
                            symbology = .jan8
                        case "jan13", "ean13":
                            symbology = .jan13
                        case "upca":
                            symbology = .upcA
                        case "upce":
                            symbology = .upcE
                        case "itf":
                            symbology = .itf
                        case "nw7", "codabar":
                            symbology = .nw7
                        default:
                            symbology = .code128
                        }
                        
                        let barcodeParam = StarXpandCommand.Printer.BarcodeParameter(content: barcodeContent, symbology: symbology)
                            .setHeight(Double(barcodeHeight_stored))
                            .setPrintHRI(barcodePrintHRI_stored)
                        
                        _ = printerBuilder
                            .styleAlignment(.center)
                            .actionPrintBarcode(barcodeParam)
                            .styleAlignment(.left)
                    }
                }

                // Build document - for label printers, don't set printable area to avoid margins
                let docBuilder = StarXpandCommand.DocumentBuilder()
                if !labelPrinter {
                    _ = docBuilder.settingPrintableArea(fullWidthMm)
                }
                _ = builder.addDocument(docBuilder.addPrinter(printerBuilder.actionCut(.partial)))
                
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
                manager.discoveryTime = 3000  // 3 seconds for diagnostics (optimized)
                
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
                while !delegate.isFinished && waitTime < 4000 { // 4 second timeout (optimized)
                    try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds (optimized polling)
                    waitTime += 50
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
    
    // Helper: create a barcode image using iOS Core Image
    private func createBarcodeImage(content: String, symbology: String, width: CGFloat, height: CGFloat) -> UIImage? {
        // Map symbology to CIFilter name
        let filterName: String
        switch symbology.lowercased() {
        case "code128":
            filterName = "CICode128BarcodeGenerator"
        case "qr", "qrcode":
            filterName = "CIQRCodeGenerator"
        case "pdf417":
            filterName = "CIPDF417BarcodeGenerator"
        case "aztec":
            filterName = "CIAztecCodeGenerator"
        default:
            filterName = "CICode128BarcodeGenerator"  // Default to CODE128
        }
        
        guard let filter = CIFilter(name: filterName) else {
            print("DEBUG: Failed to create barcode filter: \(filterName)")
            return nil
        }
        
        guard let data = content.data(using: .ascii) else {
            print("DEBUG: Failed to convert barcode content to ASCII")
            return nil
        }
        
        filter.setValue(data, forKey: "inputMessage")
        
        // For CODE128, we can set inputQuietSpace to reduce/eliminate margins
        if filterName == "CICode128BarcodeGenerator" {
            filter.setValue(0.0, forKey: "inputQuietSpace")  // Minimum quiet zone
        }
        
        guard let ciImage = filter.outputImage else {
            print("DEBUG: Failed to generate barcode CIImage")
            return nil
        }
        
        // Scale the barcode to desired size
        let scaleX = width / ciImage.extent.width
        let scaleY = height / ciImage.extent.height
        let transformedImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        // Convert to UIImage
        let context = CIContext()
        guard let cgImage = context.createCGImage(transformedImage, from: transformedImage.extent) else {
            print("DEBUG: Failed to create CGImage from barcode")
            return nil
        }
        
        let barcodeImage = UIImage(cgImage: cgImage)
        print("DEBUG: Generated barcode image - size: \(barcodeImage.size.width)x\(barcodeImage.size.height)")
        return barcodeImage
    }
    
    // Helper: create an image from text with adjustable font/width
    private func createTextImage(text: String, fontSize: CGFloat, imageWidth: CGFloat = 576) -> UIImage? {
        print("DEBUG createTextImage: Original text = '\(text)'")
        // Filter out barcode placeholder lines (lines that are mostly pipe characters)
        let filteredText = text.components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Keep empty lines
                if trimmed.isEmpty { return true }
                
                let pipeCount = trimmed.filter { $0 == "|" }.count
                let totalChars = trimmed.count
                // Skip lines that are more than 50% pipe characters (barcode placeholders)
                let isPipeLine = Double(pipeCount) / Double(totalChars) >= 0.5
                if isPipeLine {
                    print("DEBUG createTextImage: Filtering out pipe line: '\(trimmed)' (pipes: \(pipeCount)/\(totalChars))")
                }
                return !isPipeLine
            }
            .joined(separator: "\n")
        
        print("DEBUG createTextImage: Filtered text = '\(filteredText)' (Original: \(text.count) chars, Filtered: \(filteredText.count) chars)")
        
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
        let textSize = filteredText.boundingRect(
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
        filteredText.draw(in: textRect, withAttributes: textAttributes)

        guard let image = UIGraphicsGetImageFromCurrentImageContext() else {
            UIGraphicsEndImageContext()
            return nil
        }
        UIGraphicsEndImageContext()
        return image
    }

    // Helper: render the details block into an image for graphics-only printers
    private func createDetailsImage(location: String, date: String, time: String, cashier: String, receiptNum: String, lane: String, footer: String, items: [[String: Any]] = [], imageWidth: CGFloat = 576) -> UIImage? {
        let font = UIFont.systemFont(ofSize: 22)
        let smallFont = UIFont.systemFont(ofSize: 20)
        let backgroundColor = UIColor.white
        let textColor = UIColor.black

        let paraCenter = NSMutableParagraphStyle(); paraCenter.alignment = .center
        let paraLeft = NSMutableParagraphStyle(); paraLeft.alignment = .left
        let paraRight = NSMutableParagraphStyle(); paraRight.alignment = .right

        var lines: [(String, UIFont, NSMutableParagraphStyle)] = []
        if !location.isEmpty { lines.append((location, font, paraCenter)) }
        lines.append(("", smallFont, paraLeft)) // blank line
        lines.append(("Tax Invoice", font, paraCenter))
        // date time (left) and cashier (right) on same line -> render via two columns
        let left1 = "\(date) \(time)"
        let right1 = cashier.isEmpty ? "" : "Cashier: \(cashier)"
        let left2 = receiptNum.isEmpty ? "" : "Receipt No: \(receiptNum)"
        let right2 = lane.isEmpty ? "" : "Lane: \(lane)"

        // Measure height
        var height: CGFloat = 0
        let width = imageWidth
        for (text, f, para) in lines {
            let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: textColor, .paragraphStyle: para]
            let rect = (text as NSString).boundingRect(with: CGSize(width: width - 40, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
            height += rect.height + 8
        }
        // Space for two-column lines and ruled lines (with an extra gap before first rule)
        height += 2 * (smallFont.lineHeight + 10)
        height += 10 // extra gap before first rule
        // Height for first rule
        height += 2 + 10
        // Items block (each repeated line ~ smallFont.lineHeight + 4)
        var computedItemLines: [(String,String)] = []
        if !items.isEmpty {
            for item in items {
                let qty = (item["quantity"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "1"
                let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Item"
                let priceRaw = (item["price"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.00"
                let repeatRaw = (item["repeat"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "1"
                let repeatCount = Int(repeatRaw) ?? 1
                let leftText = "\(qty) x \(name)"
                let rightText = "$\(priceRaw)"
                for _ in 0..<max(1, min(repeatCount, 200)) {
                    computedItemLines.append((leftText, rightText))
                }
            }
            height += CGFloat(computedItemLines.count) * (smallFont.lineHeight + 4)
        }
        // Second rule + spacing after it
        height += 2 + 10
        if !footer.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: textColor, .paragraphStyle: paraCenter]
            let rect = (footer as NSString).boundingRect(with: CGSize(width: width - 40, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
            height += rect.height + 8
        }

        let size = CGSize(width: width, height: max(120, height + 20))
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        ctx.setFillColor(backgroundColor.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        var y: CGFloat = 10
        for (text, f, para) in lines {
            let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: textColor, .paragraphStyle: para]
            let rect = (text as NSString).boundingRect(with: CGSize(width: width - 24, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
            let drawRect = CGRect(x: 12, y: y, width: width - 24, height: rect.height)
            (text as NSString).draw(in: drawRect, withAttributes: attrs)
            y += rect.height + 8
        }

        // Two-column line 1
        let colWidth = (width - 24) / 2
        let leftRect1 = CGRect(x: 12, y: y, width: colWidth, height: smallFont.lineHeight + 2)
        let rightRect1 = CGRect(x: 12 + colWidth, y: y, width: colWidth, height: smallFont.lineHeight + 2)
        (left1 as NSString).draw(in: leftRect1, withAttributes: [.font: smallFont, .foregroundColor: textColor, .paragraphStyle: paraLeft])
        (right1 as NSString).draw(in: rightRect1, withAttributes: [.font: smallFont, .foregroundColor: textColor, .paragraphStyle: paraRight])
        y += smallFont.lineHeight + 10

        // Two-column line 2
        let leftRect2 = CGRect(x: 12, y: y, width: colWidth, height: smallFont.lineHeight + 2)
        let rightRect2 = CGRect(x: 12 + colWidth, y: y, width: colWidth, height: smallFont.lineHeight + 2)
        (left2 as NSString).draw(in: leftRect2, withAttributes: [.font: smallFont, .foregroundColor: textColor, .paragraphStyle: paraLeft])
        (right2 as NSString).draw(in: rightRect2, withAttributes: [.font: smallFont, .foregroundColor: textColor, .paragraphStyle: paraRight])
        y += smallFont.lineHeight + 10

        // Extra gap before first rule
        y += 10
        // Ruled line (2px) full width edge-to-edge, blank, ruled line
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: y, width: width, height: 2)) // first rule
        y += 2 + 10
        // Items (if any) as two columns left (qty x name) / right (price)
        if !computedItemLines.isEmpty {
            let colWidth = (width - 24) / 2
            for (ltext, rtext) in computedItemLines {
                let leftRect = CGRect(x: 12, y: y, width: colWidth, height: smallFont.lineHeight + 2)
                let rightRect = CGRect(x: 12 + colWidth, y: y, width: colWidth, height: smallFont.lineHeight + 2)
                (ltext as NSString).draw(in: leftRect, withAttributes: [.font: smallFont, .foregroundColor: textColor, .paragraphStyle: paraLeft])
                (rtext as NSString).draw(in: rightRect, withAttributes: [.font: smallFont, .foregroundColor: textColor, .paragraphStyle: paraRight])
                y += smallFont.lineHeight + 4
            }
        }
        ctx.fill(CGRect(x: 0, y: y, width: width, height: 2)) // second rule
        y += 2 + 10

        if !footer.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: textColor, .paragraphStyle: paraCenter]
            let rect = (footer as NSString).boundingRect(with: CGSize(width: width - 40, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
            let drawRect = CGRect(x: 20, y: y, width: width - 40, height: rect.height)
            (footer as NSString).draw(in: drawRect, withAttributes: attrs)
            y += rect.height + 8
        }

        let img = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return img
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

        // Draw image as-is first
        image.draw(in: CGRect(origin: .zero, size: size))
        // If it contains alpha, create a black silhouette using destinationIn blending
        if let cg = image.cgImage {
            let alphaInfo = cg.alphaInfo
            let hasAlpha = (alphaInfo == .first || alphaInfo == .last || alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast)
            if hasAlpha {
                // Paint black over the area defined by image's alpha
                ctx.saveGState()
                ctx.setBlendMode(.destinationIn)
                image.draw(in: CGRect(origin: .zero, size: size)) // keep alpha as mask
                ctx.restoreGState()
                ctx.saveGState()
                ctx.setBlendMode(.sourceAtop)
                ctx.setFillColor(UIColor.black.cgColor)
                ctx.fill(CGRect(origin: .zero, size: size))
                ctx.restoreGState()
            }
        }

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

    // Convert image to high-contrast black/white using a simple luminance threshold (0..1)
    private func binarizeImage(_ image: UIImage, threshold: CGFloat = 0.7) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bytesPerPixel = 1
        let bytesPerRow = bytesPerPixel * width
        var raw = [UInt8](repeating: 255, count: width * height)
        guard let ctx = CGContext(data: &raw,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        // Draw incoming on white
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Apply threshold (note: grayscale 0..255 where 0 is black)
        let cutoff = UInt8(max(0, min(1, threshold)) * 255)
        for i in 0..<(width*height) {
            raw[i] = raw[i] < cutoff ? 0 : 255
        }
        guard let bwCg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: bwCg, scale: 1.0, orientation: .up)
    }

    // Normalize to 32-bit RGBA premultiplied for consistent UIImage encoding
    private func normalizeToRGBA(_ image: UIImage) -> UIImage? {
        let size = image.size
        let width = Int(size.width)
        let height = Int(size.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var raw = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        guard let ctx = CGContext(data: &raw,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        image.draw(in: CGRect(origin: .zero, size: size))
        guard let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg, scale: 1.0, orientation: .up)
    }

    // Flatten UIImage onto opaque white background at a given width (keeps aspect)
    private func flattenImage(_ image: UIImage, targetWidth: Int) -> UIImage? {
        let width = CGFloat(max(8, min(targetWidth, 576)))
        let aspect = image.size.height / max(image.size.width, 1)
        let height = max(8, width * aspect)
        let size = CGSize(width: width, height: height)
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        image.draw(in: CGRect(origin: .zero, size: size))
        let out = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return out
    }

    // Center an image on a full-width canvas to force horizontal centering for graphics-only printers
    private func centerOnCanvas(image: UIImage, canvasWidth: Int) -> UIImage? {
        let width = CGFloat(max(8, min(canvasWidth, 576)))
        let aspect = image.size.height / max(image.size.width, 1)
        let targetW = min(image.size.width, width)
        let targetH = targetW * aspect
        let size = CGSize(width: width, height: targetH)
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        let x = (width - targetW) / 2
        image.draw(in: CGRect(x: x, y: 0, width: targetW, height: targetH))
        let out = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return out
    }
}
