import 'package:star_printer/star_printer.dart';

/// Example usage of the Star Printer plugin
void main() async {
  // Discover available printers
  print('Discovering printers...');
  final printers = await StarPrinter.discoverPrinters();
  print('Found ${printers.length} printers: $printers');

  if (printers.isNotEmpty) {
    // Connect to the first discovered printer
    final settings = StarConnectionSettings(
      interfaceType: StarInterfaceType.bluetooth,
      identifier: printers.first,
    );
    
    print('Connecting to printer: ${printers.first}');
    await StarPrinter.connect(settings);
    
    // Check if connected
    final isConnected = await StarPrinter.isConnected();
    print('Connected: $isConnected');
    
    if (isConnected) {
      // Get printer status
      final status = await StarPrinter.getStatus();
      print('Printer Status - Online: ${status.isOnline}, Status: ${status.status}');
      
      // Print a test receipt
      final printJob = PrintJob(
        content: '''
STAR PRINTER TEST
================

Date: ${DateTime.now().toString()}
Test Print Successful!

Thank you for using
Star Printers

================

''',
      );
      
      print('Printing receipt...');
      await StarPrinter.printReceipt(printJob);
      print('Print job sent successfully!');
      
      // Open cash drawer (if connected)
      print('Opening cash drawer...');
      await StarPrinter.openCashDrawer();
      
      // Disconnect
      print('Disconnecting...');
      await StarPrinter.disconnect();
    }
  } else {
    print('No printers found. Make sure your Star printer is powered on and discoverable.');
  }
}

/// Example of different connection types
void connectionExamples() async {
  // Bluetooth connection
  final bluetoothSettings = StarConnectionSettings(
    interfaceType: StarInterfaceType.bluetooth,
    identifier: 'BT:01:23:45:67:89:AB',
  );
  
  // LAN connection
  final lanSettings = StarConnectionSettings(
    interfaceType: StarInterfaceType.lan,
    identifier: '192.168.1.100',
  );
  
  // USB connection
  final usbSettings = StarConnectionSettings(
    interfaceType: StarInterfaceType.usb,
    identifier: 'USB:04b8:0202',
  );
  
  // Connect using any of the settings
  await StarPrinter.connect(bluetoothSettings);
}

/// Example of advanced print job with settings
void advancedPrintExample() async {
  final printJob = PrintJob(
    content: 'Advanced print content',
    settings: {
      'paperWidth': 58, // 58mm paper
      'fontSize': 'normal',
      'alignment': 'center',
      'bold': true,
    },
  );
  
  await StarPrinter.printReceipt(printJob);
}
