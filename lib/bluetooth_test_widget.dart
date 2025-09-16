import 'package:flutter/material.dart';
import 'package:star_printer/star_printer.dart';

class BluetoothTestWidget extends StatefulWidget {
  const BluetoothTestWidget({super.key});

  @override
  State<BluetoothTestWidget> createState() => _BluetoothTestWidgetState();
}

class _BluetoothTestWidgetState extends State<BluetoothTestWidget> {
  List<String> _discoveredBluetoothPrinters = [];
  bool _isBluetoothConnected = false;
  String _bluetoothPrinterStatus = 'Unknown';
  String? _selectedBluetoothPrinter;
  bool _isDiscovering = false;

  Future<void> _discoverBluetoothPrinters() async {
    setState(() {
      _isDiscovering = true;
    });

    try {
      print('DEBUG: Starting Bluetooth printer discovery...');
      final printers = await StarPrinter.discoverBluetoothPrinters();
      print('DEBUG: Bluetooth discovery result: $printers');
      setState(() {
        _discoveredBluetoothPrinters = printers;
        // Auto-select first printer if none selected or if current selection is no longer available
        if (_selectedBluetoothPrinter == null || !printers.contains(_selectedBluetoothPrinter)) {
          _selectedBluetoothPrinter = printers.isNotEmpty ? printers.first : null;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Found ${printers.length} Bluetooth printers')),
      );
    } catch (e) {
      print('DEBUG: Bluetooth discovery error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Bluetooth discovery failed: $e')),
      );
    } finally {
      setState(() {
        _isDiscovering = false;
      });
    }
  }

  Future<void> _connectToBluetoothPrinter() async {
    if (_discoveredBluetoothPrinters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No Bluetooth printers discovered. Please discover printers first.')),
      );
      return;
    }

    if (_selectedBluetoothPrinter == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a Bluetooth printer first.')),
      );
      return;
    }

    try {
      // Disconnect from current printer if connected
      if (_isBluetoothConnected) {
        print('DEBUG: Disconnecting from current Bluetooth printer before new connection...');
        await StarPrinter.disconnect();
        setState(() {
          _isBluetoothConnected = false;
        });
        // Small delay to ensure clean disconnect
        await Future.delayed(const Duration(milliseconds: 500));
      }
      
      final printerString = _selectedBluetoothPrinter!;
      
      // Parse the printer string to determine interface type
      StarInterfaceType interfaceType;
      String identifier;
      
      if (printerString.startsWith('BT:')) {
        interfaceType = StarInterfaceType.bluetooth;
        // Extract just the identifier part (MAC address), ignore model info
        final parts = printerString.substring(3).split(':');
        identifier = parts[0]; // Take first part before any model info
      } else if (printerString.startsWith('BLE:')) {
        interfaceType = StarInterfaceType.bluetoothLE;
        final parts = printerString.substring(4).split(':');
        identifier = parts[0]; // Take first part before any model info
      } else {
        interfaceType = StarInterfaceType.bluetooth;
        identifier = printerString.split(':')[0]; // Take first part
      }
      
      print('DEBUG: Connecting to $interfaceType printer: $identifier (Selected: $printerString)');
      
      final settings = StarConnectionSettings(
        interfaceType: interfaceType,
        identifier: identifier,
      );
      await StarPrinter.connect(settings);
      setState(() {
        _isBluetoothConnected = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connected to Bluetooth: ${_selectedBluetoothPrinter!.split(':').last}')),
      );
    } catch (e) {
      print('DEBUG: Bluetooth connection error: $e');
      setState(() {
        _isBluetoothConnected = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Bluetooth connection failed: $e')),
      );
    }
  }

  Future<void> _disconnectFromBluetoothPrinter() async {
    try {
      await StarPrinter.disconnect();
      setState(() {
        _isBluetoothConnected = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Disconnected from Bluetooth printer')),
      );
    } catch (e) {
      print('DEBUG: Bluetooth disconnect error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Bluetooth disconnect failed: $e')),
      );
    }
  }

  Future<void> _printBluetoothReceipt() async {
    print('DEBUG: Bluetooth print receipt button pressed');
    
    try {
      print('DEBUG: Creating Bluetooth print job...');
      final printJob = PrintJob(
        content: '''
           .--._.--.
          ( O     O )
          /   . .   \\
         .\`._______.\'.\`
        /(           )\\
      _/  \\  \\   /  /  \\_
   .~   \`  \\  \\ /  /  \'   ~.
  {    -.   \\  V  /   .-    }
_ _\`.    \\  |  |  |  /    .\'\_ _
>_       _} |  |  | {_       _<
 /. - ~ ,_-\'  .^.  \`-_, ~ - .\\
         \'-\'|/   \\|\`-\`

Hello Star Printer!

Print Test

''',
      );
      
      print('DEBUG: Sending Bluetooth print job to printer...');
      await StarPrinter.printReceipt(printJob);
      
      
      print('DEBUG: Bluetooth print job completed successfully');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bluetooth print job sent successfully')),
      );
    } catch (e) {
      print('DEBUG: Bluetooth print failed with error: $e');
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Bluetooth print failed: $e')),
      );
    }
  }

  Future<void> _getBluetoothStatus() async {
    try {
      final status = await StarPrinter.getStatus();
      setState(() {
        _bluetoothPrinterStatus = 'Online: ${status.isOnline}, Status: ${status.status}';
      });
    } catch (e) {
      setState(() {
        _bluetoothPrinterStatus = 'Error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bluetooth, color: Colors.blue),
                const SizedBox(width: 8),
                Text(
                  'Bluetooth Printer Controls',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text('Discovered Bluetooth Printers: ${_discoveredBluetoothPrinters.length}'),
                if (_isDiscovering) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
            if (_discoveredBluetoothPrinters.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('Select Bluetooth Printer:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.blue),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedBluetoothPrinter,
                    hint: const Text('Select a Bluetooth printer'),
                    isExpanded: true,
                    items: _discoveredBluetoothPrinters.map((printer) {
                      // Extract model name for display
                      final parts = printer.split(':');
                      final model = parts.length > 2 ? parts[2] : 'Unknown';
                      final mac = parts.length > 1 ? parts[1] : 'Unknown';
                      final interfaceType = parts[0];
                      return DropdownMenuItem<String>(
                        value: printer,
                        child: Text('$model ($interfaceType - ${mac.substring(0, 8)}...)'),
                      );
                    }).toList(),
                    onChanged: (String? newValue) {
                      setState(() {
                        _selectedBluetoothPrinter = newValue;
                        _isBluetoothConnected = false; // Reset connection status when changing printer
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (_selectedBluetoothPrinter != null)
                Text('Selected: ${_selectedBluetoothPrinter!}', 
                     style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
            ],
            const SizedBox(height: 16),
            Text('Bluetooth Connection Status: ${_isBluetoothConnected ? "Connected" : "Disconnected"}'),
            const SizedBox(height: 8),
            Text('Bluetooth Printer Status: $_bluetoothPrinterStatus'),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: _isDiscovering ? null : _discoverBluetoothPrinters,
                  icon: const Icon(Icons.bluetooth_searching),
                  label: Text(_isDiscovering ? 'Discovering...' : 'Discover Bluetooth'),
                ),
                ElevatedButton.icon(
                  onPressed: _selectedBluetoothPrinter != null && !_isBluetoothConnected
                      ? _connectToBluetoothPrinter
                      : null,
                  icon: const Icon(Icons.bluetooth_connected),
                  label: const Text('Connect'),
                ),
                ElevatedButton.icon(
                  onPressed: _isBluetoothConnected ? _disconnectFromBluetoothPrinter : null,
                  icon: const Icon(Icons.bluetooth_disabled),
                  label: const Text('Disconnect'),
                ),
                ElevatedButton.icon(
                  onPressed: _printBluetoothReceipt,
                  icon: const Icon(Icons.print),
                  label: const Text('Print Test'),
                ),
                ElevatedButton.icon(
                  onPressed: _getBluetoothStatus,
                  icon: const Icon(Icons.info),
                  label: const Text('Get Status'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
