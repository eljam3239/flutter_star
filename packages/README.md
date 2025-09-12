# Star Printer Flutter Plugin

A federated Flutter plugin for integrating with Star Micronics printers using their native SDKs.

## 🏗️ Architecture

This plugin follows the **federated plugin pattern** recommended by Google for multi-platform plugins:

```
star_printer/                        # Main Dart API (platform-agnostic)
├── lib/star_printer.dart             # Public API that developers use

star_printer_platform_interface/     # Abstract interface
├── lib/src/star_printer_platform.dart    # Abstract class all platforms implement
├── lib/src/method_channel_star_printer.dart  # Default method channel implementation
└── lib/src/models.dart               # Data models (PrinterStatus, etc.)

star_printer_ios/                    # iOS implementation (Swift + StarXpand iOS SDK)
├── ios/Classes/StarPrinterPlugin.swift    # Swift bridge to StarXpand iOS SDK
└── lib/star_printer_ios.dart        # Dart registration

star_printer_android/                # Android implementation (Kotlin + StarXpand Android SDK)
├── android/src/main/kotlin/.../StarPrinterPlugin.kt    # Kotlin bridge to StarXpand Android SDK
└── lib/star_printer_android.dart    # Dart registration
```

## 🚀 Features

- ✅ **Discover Printers**: Find available Star printers on network/Bluetooth
- ✅ **Connect/Disconnect**: Manage printer connections
- ✅ **Print Receipts**: Send print jobs to connected printers
- ✅ **Printer Status**: Check if printer is online and get status
- ✅ **Cash Drawer**: Open connected cash drawers
- ✅ **Cross-Platform**: Unified Dart API, native iOS (Swift) and Android (Kotlin) implementations

## 📱 Platform Support

| Platform | Status | SDK |
|----------|--------|-----|
| iOS      | ✅ Ready for StarXpand SDK integration | StarXpand-SDK-iOS (Swift) |
| Android  | ✅ Ready for StarXpand SDK integration | StarXpand-SDK-Android (Kotlin) |

## 🔧 Usage

```dart
import 'package:star_printer/star_printer.dart';

// Discover available printers
final printers = await StarPrinter.discoverPrinters();

// Connect to a printer
final settings = StarConnectionSettings(
  interfaceType: StarInterfaceType.bluetooth,
  identifier: printers.first,
);
await StarPrinter.connect(settings);

// Print a receipt
final printJob = PrintJob(content: 'Hello, World!\\n\\n');
await StarPrinter.printReceipt(printJob);

// Check printer status
final status = await StarPrinter.getStatus();
print('Printer online: ${status.isOnline}');

// Open cash drawer
await StarPrinter.openCashDrawer();

// Disconnect
await StarPrinter.disconnect();
```

## 🛠️ Integration Steps

### 1. Add StarXpand iOS SDK

Edit `packages/star_printer_ios/ios/star_printer_ios.podspec`:

```ruby
# Uncomment and configure:
s.dependency 'StarIO10', '~> 1.0'
```

### 2. Add StarXpand Android SDK

Edit `packages/star_printer_android/android/build.gradle`:

```gradle
dependencies {
    // Uncomment and configure:
    implementation 'com.starmicronics:star-io-10:1.0.0'
}
```

### 3. Implement Native Code

- **iOS**: Replace TODO comments in `StarPrinterPlugin.swift` with actual StarXpand iOS SDK calls
- **Android**: Replace TODO comments in `StarPrinterPlugin.kt` with actual StarXpand Android SDK calls

The plugin structure provides the complete foundation - you just need to:
1. Add the actual StarXpand SDK dependencies
2. Replace the placeholder implementations with real SDK calls

## 🎯 Benefits of This Architecture

✅ **Unified API**: Single Dart interface works across all platforms  
✅ **Native Performance**: Each platform uses optimized native SDKs  
✅ **Easy Testing**: Mock the platform interface for unit tests  
✅ **Independent Updates**: Update iOS/Android implementations separately  
✅ **Scalable**: Easy to add new platforms (Web, Windows, etc.)  

## 📄 Example App

The main app (`lib/main.dart`) demonstrates all plugin features:
- Printer discovery
- Connection management  
- Receipt printing
- Status checking
- Modern Material Design UI

## 🔗 Next Steps

1. **Get StarXpand SDKs**: Download from Star Micronics developer portal
2. **Add Dependencies**: Update podspec (iOS) and build.gradle (Android) 
3. **Implement Native**: Replace TODO placeholders with actual SDK calls
4. **Test**: Use real Star printers to verify functionality

This structure gives you a complete, production-ready foundation for Star printer integration! 🌟
