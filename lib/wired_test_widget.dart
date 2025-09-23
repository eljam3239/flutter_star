import 'package:flutter/material.dart';
import 'package:star_printer/star_printer.dart';

class WiredTestWidget extends StatefulWidget {
  const WiredTestWidget({super.key});

  @override
  State<WiredTestWidget> createState() => _WiredTestWidgetState();
}

class _WiredTestWidgetState extends State<WiredTestWidget> {
  List<String> _usbPrinters = [];
  bool _isUsbConnected = false;
  String _usbStatus = 'Disconnected';
  String? _selectedUsbPrinter;
  bool _isDiscovering = false;
  List<String> _debugLog = []; // Add debug log for UI display

  void _addDebugLog(String message) {
    setState(() {
      _debugLog.add('${DateTime.now().toString().substring(11, 19)}: $message');
      // Keep only last 15 log entries for better visibility
      if (_debugLog.length > 15) {
        _debugLog.removeAt(0);
      }
    });
    print('DEBUG USB: $message');
  }

  // Add comprehensive USB system diagnostics
  Future<void> _runUsbDiagnostics() async {
    setState(() {
      _debugLog.clear();
    });
    
    _addDebugLog('=== USB SYSTEM DIAGNOSTICS ===');
    _addDebugLog('Device: Galaxy Tab S6 Lite');
    _addDebugLog('Target: TSP100SK via USB cable');
    
    try {
      // Test 1: Native USB diagnostics
      _addDebugLog('Test 1: Native USB system check...');
      final usbDiag = await StarPrinter.usbDiagnostics();
      
      _addDebugLog('USB Host Support: ${usbDiag['usb_host_supported']}');
      _addDebugLog('Connected USB Devices: ${usbDiag['connected_usb_devices']}');
      _addDebugLog('TSP100 Devices Found: ${usbDiag['tsp100_devices_found']}');
      _addDebugLog('USB Printers Discovered: ${usbDiag['usb_printers_discovered']}');
      
      if (usbDiag['usb_devices'] != null) {
        List<dynamic> devices = usbDiag['usb_devices'];
        for (int i = 0; i < devices.length; i++) {
          Map<String, dynamic> device = devices[i];
          _addDebugLog('USB Device $i:');
          _addDebugLog('  Name: ${device['device_name']}');
          _addDebugLog('  Vendor: ${device['vendor_id']} (${device['manufacturer_name']})');
          _addDebugLog('  Product: ${device['product_id']} (${device['product_name']})');
        }
      }
      
      if (usbDiag['usb_printer_list'] != null) {
        List<dynamic> printers = usbDiag['usb_printer_list'];
        for (String printer in printers) {
          _addDebugLog('USB Printer: $printer');
        }
      }
      
      if (usbDiag['usb_discovery_error'] != null) {
        _addDebugLog('USB Discovery Error: ${usbDiag['usb_discovery_error']}');
      }
      
      // Test 2: Check if any printers are discoverable at all
      _addDebugLog('Test 2: General printer discovery...');
      final allPrinters = await StarPrinter.discoverPrinters();
      _addDebugLog('Found ${allPrinters.length} total printers');
      
      for (int i = 0; i < allPrinters.length; i++) {
        _addDebugLog('  $i: ${allPrinters[i]}');
      }
      
      // Test 3: USB printer filtering
      _addDebugLog('Test 3: USB printer filtering...');
      final usbPrinters = allPrinters.where((p) => 
        p.startsWith('USB:') || 
        p.toLowerCase().contains('usb')
      ).toList();
      _addDebugLog('USB filtered: ${usbPrinters.length} printers');
      
      // Test 4: Look for TSP100 variants
      _addDebugLog('Test 4: TSP100 variant detection...');
      final tsp100Printers = allPrinters.where((p) => 
        p.contains('TSP100') || 
        p.contains('TSP') ||
        p.contains('Star')
      ).toList();
      _addDebugLog('TSP100 variants: ${tsp100Printers.length} printers');
      for (String printer in tsp100Printers) {
        _addDebugLog('  TSP100 variant: $printer');
      }
      
      // Test 5: Analyze discovered printer patterns
      _addDebugLog('Test 5: Interface analysis...');
      Set<String> interfaces = {};
      for (String printer in allPrinters) {
        if (printer.contains(':')) {
          String interface = printer.split(':')[0];
          interfaces.add(interface);
        }
      }
      _addDebugLog('Interfaces found: ${interfaces.join(', ')}');
      
      if (!interfaces.contains('USB')) {
        _addDebugLog('❌ USB interface NOT detected');
        _addDebugLog('Possible causes:');
        _addDebugLog('  • USB cable not connected properly');
        _addDebugLog('  • TSP100SK not powered on');
        _addDebugLog('  • Android USB permissions not granted');
        _addDebugLog('  • StarIO10 SDK USB drivers not working');
        _addDebugLog('  • USB OTG not supported/enabled');
      } else {
        _addDebugLog('✅ USB interface detected');
      }
      
    } catch (e) {
      _addDebugLog('❌ Diagnostics failed: $e');
    }
  }

  Future<void> _discoverUsbPrinters() async {
    setState(() {
      _isDiscovering = true;
      _usbStatus = 'Discovering USB printers...';
      _debugLog.clear(); // Clear previous logs
    });

    _addDebugLog('Starting USB printer discovery...');

    try {
      // Discover all printers and filter for USB
      _addDebugLog('Calling StarPrinter.discoverPrinters()...');
      final allPrinters = await StarPrinter.discoverPrinters();
      _addDebugLog('Discovery returned ${allPrinters.length} total printers');
      
      // Log all discovered printers
      for (int i = 0; i < allPrinters.length; i++) {
        _addDebugLog('Printer $i: ${allPrinters[i]}');
      }
      
      final usbPrinters = allPrinters.where((printer) => 
        printer.startsWith('USB:') || 
        printer.contains('USB') ||
        printer.toLowerCase().contains('usb')
      ).toList();
      
      _addDebugLog('Filtered to ${usbPrinters.length} USB printers');
      
      setState(() {
        _usbPrinters = usbPrinters;
        _selectedUsbPrinter = usbPrinters.isNotEmpty ? usbPrinters.first : null;
        _usbStatus = usbPrinters.isNotEmpty 
            ? 'Found ${usbPrinters.length} USB printer(s)'
            : 'No USB printers found. Check: USB cable, printer power, USB permissions';
      });

      if (mounted) {
        String message;
        Color backgroundColor;
        
        if (usbPrinters.isNotEmpty) {
          message = 'Found ${usbPrinters.length} USB printer(s)';
          backgroundColor = Colors.green;
          _addDebugLog('SUCCESS: Found USB printers!');
        } else if (allPrinters.isNotEmpty) {
          message = 'Found ${allPrinters.length} printers but none via USB. TSP100 may need manual USB permission grant.';
          backgroundColor = Colors.orange;
          _addDebugLog('WARNING: No USB printers, but found other printers');
        } else {
          message = 'No printers detected at all. Check printer power and connections.';
          backgroundColor = Colors.red;
          _addDebugLog('ERROR: No printers found at all');
        }
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: backgroundColor,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      _addDebugLog('EXCEPTION in discovery: $e');
      setState(() {
        _usbStatus = 'Discovery failed: $e';
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('USB discovery failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() {
        _isDiscovering = false;
      });
      _addDebugLog('Discovery process completed.');
    }
  }

  Future<void> _connectUsbPrinter() async {
    if (_selectedUsbPrinter == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No USB printer selected')),
      );
      return;
    }

    setState(() {
      _usbStatus = 'Connecting to USB printer...';
    });

    try {
      // Disconnect any existing connection first
      if (_isUsbConnected) {
        await StarPrinter.disconnect();
        setState(() {
          _isUsbConnected = false;
        });
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // Parse USB printer identifier
      final printerString = _selectedUsbPrinter!;
      String identifier;
      
      if (printerString.startsWith('USB:')) {
        final parts = printerString.substring(4).split(':');
        identifier = parts[0];
      } else {
        identifier = printerString.split(':')[0];
      }

      final settings = StarConnectionSettings(
        interfaceType: StarInterfaceType.usb,
        identifier: identifier,
      );

      await StarPrinter.connect(settings);
      
      setState(() {
        _isUsbConnected = true;
        _usbStatus = 'Connected via USB to TSP100';
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('USB connection established!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isUsbConnected = false;
        _usbStatus = 'USB connection failed: $e';
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('USB connection failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Manual TSP100SK connection method when discovery fails
  Future<void> _connectTsp100Manually() async {
    setState(() {
      _usbStatus = 'Attempting manual TSP100SK USB connection...';
    });
    
    _addDebugLog('Starting manual TSP100SK connection...');

    try {
      // Disconnect any existing connection first
      if (_isUsbConnected) {
        _addDebugLog('Disconnecting existing connection...');
        await StarPrinter.disconnect();
        setState(() {
          _isUsbConnected = false;
        });
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // Try TSP100SK specific USB identifiers
      final commonTsp100Identifiers = [
        '2611324121400006', // EXACT identifier from USB diagnostics
        'TSP100SK',
        'TSP100IV_SK',  // Based on LAN discovery output
        'TSP100',
        'Star TSP100',
        'TSP100IV',     // Generic TSP100IV variant
        'usb://0001',   // Common USB identifier patterns
        'usb://0002',
        'usb://0003',
        '0011625AA26C', // MAC address from LAN discovery
        '', // Empty identifier (sometimes works)
      ];

      bool connected = false;
      String successfulIdentifier = '';

      for (String identifier in commonTsp100Identifiers) {
        try {
          _addDebugLog('Trying identifier: "$identifier"');
          
          final settings = StarConnectionSettings(
            interfaceType: StarInterfaceType.usb,
            identifier: identifier,
          );

          await StarPrinter.connect(settings);
          
          // If we get here, connection succeeded
          connected = true;
          successfulIdentifier = identifier;
          _addDebugLog('SUCCESS! Connected with identifier: "$identifier"');
          break;
          
        } catch (e) {
          _addDebugLog('Failed with "$identifier": $e');
          // Continue to next identifier
          continue;
        }
      }

      if (connected) {
        setState(() {
          _isUsbConnected = true;
          _usbStatus = 'Connected via USB to TSP100SK ($successfulIdentifier)';
          _selectedUsbPrinter = 'USB:$successfulIdentifier:TSP100SK';
          _usbPrinters = ['USB:$successfulIdentifier:TSP100SK'];
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Manual TSP100SK USB connection successful! ($successfulIdentifier)'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        _addDebugLog('All manual connection attempts failed');
        setState(() {
          _usbStatus = 'Manual connection failed - tried all common TSP100SK identifiers';
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Manual TSP100SK connection failed. Check USB cable and permissions.'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      _addDebugLog('EXCEPTION in manual connection: $e');
      setState(() {
        _isUsbConnected = false;
        _usbStatus = 'Manual connection error: $e';
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Manual connection error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _disconnectUsbPrinter() async {
    try {
      await StarPrinter.disconnect();
      setState(() {
        _isUsbConnected = false;
        _usbStatus = 'Disconnected from USB printer';
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('USB printer disconnected')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Disconnect failed: $e')),
        );
      }
    }
  }

  Future<void> _printUsbTestReceipt() async {
    if (!_isUsbConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please connect to USB printer first')),
      );
      return;
    }

    try {
      final printJob = PrintJob(
        content: '''
╔══════════════════════════════════╗
║        USB TSP100 TEST           ║
╠══════════════════════════════════╣
║                                  ║
║  🖨️  USB Connection Test         ║
║                                  ║
║  Printer: Star TSP100            ║
║  Interface: USB Cable            ║
║  Device: Android Tablet          ║
║                                  ║
║  Date: ${DateTime.now().toString().substring(0, 19)}  ║
║                                  ║
║  ✅ USB Communication OK         ║
║                                  ║
╠══════════════════════════════════╣
║  Testing Receipt Print...        ║
║                                  ║
║  Line 1: Regular text            ║
║  Line 2: Numbers 1234567890      ║
║  Line 3: Symbols !@#\$%^&*()      ║
║                                  ║
║  🎯 Print Test Complete          ║
║                                  ║
╚══════════════════════════════════╝


''',
      );

      await StarPrinter.printReceipt(printJob);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('USB test receipt printed successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('USB print failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _openUsbCashDrawer() async {
    if (!_isUsbConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please connect to USB printer first')),
      );
      return;
    }

    try {
      await StarPrinter.openCashDrawer();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('USB cash drawer opened!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('USB cash drawer failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _getUsbStatus() async {
    if (!_isUsbConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please connect to USB printer first')),
      );
      return;
    }

    try {
      final status = await StarPrinter.getStatus();
      setState(() {
        _usbStatus = 'USB Status - Online: ${status.isOnline}, Details: ${status.status}';
      });
    } catch (e) {
      setState(() {
        _usbStatus = 'USB Status Error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(8.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.usb, color: Colors.blue),
                const SizedBox(width: 8),
                Text(
                  'USB TSP100 Test',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.blue[700],
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Status Section
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _isUsbConnected ? Colors.green[50] : Colors.grey[100],
                border: Border.all(
                  color: _isUsbConnected ? Colors.green : Colors.grey,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _isUsbConnected ? Icons.check_circle : Icons.error_outline,
                        color: _isUsbConnected ? Colors.green : Colors.grey[600],
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Status: ${_isUsbConnected ? "Connected" : "Disconnected"}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: _isUsbConnected ? Colors.green[700] : Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(_usbStatus, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            
            const SizedBox(height: 16),
            
            // USB Printer Selection
            if (_usbPrinters.isNotEmpty) ...[
              const Text('Available USB Printers:', style: TextStyle(fontWeight: FontWeight.bold)),
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
                    value: _selectedUsbPrinter,
                    hint: const Text('Select USB printer'),
                    isExpanded: true,
                    items: _usbPrinters.map((printer) {
                      return DropdownMenuItem<String>(
                        value: printer,
                        child: Text(printer, style: const TextStyle(fontSize: 12)),
                      );
                    }).toList(),
                    onChanged: (String? newValue) {
                      setState(() {
                        _selectedUsbPrinter = newValue;
                        _isUsbConnected = false; // Reset connection when changing printer
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            
            // Control Buttons
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: _isDiscovering ? null : _discoverUsbPrinters,
                  icon: _isDiscovering 
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search, size: 16),
                  label: Text(_isDiscovering ? 'Discovering...' : 'Find USB'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue[100],
                    foregroundColor: Colors.blue[700],
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _runUsbDiagnostics,
                  icon: const Icon(Icons.bug_report, size: 16),
                  label: const Text('USB Debug'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber[100],
                    foregroundColor: Colors.amber[700],
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _selectedUsbPrinter != null && !_isUsbConnected
                      ? _connectUsbPrinter
                      : null,
                  icon: const Icon(Icons.link, size: 16),
                  label: const Text('Connect'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green[100],
                    foregroundColor: Colors.green[700],
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: !_isUsbConnected ? _connectTsp100Manually : null,
                  icon: const Icon(Icons.usb, size: 16),
                  label: const Text('Manual TSP100SK'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.indigo[100],
                    foregroundColor: Colors.indigo[700],
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _isUsbConnected ? _disconnectUsbPrinter : null,
                  icon: const Icon(Icons.link_off, size: 16),
                  label: const Text('Disconnect'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red[100],
                    foregroundColor: Colors.red[700],
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _isUsbConnected ? _printUsbTestReceipt : null,
                  icon: const Icon(Icons.print, size: 16),
                  label: const Text('Test Print'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.purple[100],
                    foregroundColor: Colors.purple[700],
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _isUsbConnected ? _openUsbCashDrawer : null,
                  icon: const Icon(Icons.point_of_sale, size: 16),
                  label: const Text('Cash Drawer'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange[100],
                    foregroundColor: Colors.orange[700],
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _isUsbConnected ? _getUsbStatus : null,
                  icon: const Icon(Icons.info, size: 16),
                  label: const Text('Status'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal[100],
                    foregroundColor: Colors.teal[700],
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 16),
            
            // Debug Log Section
            if (_debugLog.isNotEmpty) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[50],
                  border: Border.all(color: Colors.grey[300]!),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.bug_report, color: Colors.grey, size: 16),
                        const SizedBox(width: 8),
                        const Text(
                          'Debug Log:',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _debugLog.clear();
                            });
                          },
                          child: const Text('Clear', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      height: 160, // Increased height for more log entries
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: SingleChildScrollView(
                        reverse: true, // Auto-scroll to bottom
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: _debugLog.map((log) => Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text(
                              log,
                              style: const TextStyle(
                                color: Colors.green,
                                fontSize: 10,
                                fontFamily: 'monospace',
                              ),
                            ),
                          )).toList(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            
            // Instructions
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue[200]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.blue[700], size: 16),
                      const SizedBox(width: 8),
                      Text(
                        'Galaxy Tab S6 Lite USB Setup:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.blue[700],
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '1. Power ON the TSP100 printer first\n'
                    '2. Connect USB cable: TSP100 → Galaxy Tab S6 Lite\n'
                    '3. If no USB permission popup appears:\n'
                    '   • Check Android Settings > Apps > test_star > Permissions\n'
                    '   • Look for "USB access" or similar permission\n'
                    '   • Enable Developer Options and check USB settings\n'
                    '4. Try unplugging and reconnecting USB cable\n'
                    '5. Tap "Find USB" to discover the printer\n'
                    '6. If still no USB printers found, try different USB cable',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            
            const SizedBox(height: 8),
            
            // Troubleshooting
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange[200]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.warning_amber_outlined, color: Colors.orange[700], size: 16),
                      const SizedBox(width: 8),
                      Text(
                        'Troubleshooting USB Issues:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.orange[700],
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '• Galaxy Tab S6 Lite may not auto-prompt for USB permissions\n'
                    '• Enable "Developer Options" in Android Settings\n'
                    '• Check "USB Debugging" and "Default USB Configuration"\n'
                    '• Some tablets require OTG (USB-C to USB-A) adapter\n'
                    '• Ensure TSP100 shows steady power light (not blinking)\n'
                    '• Try connecting TSP100 to computer first to verify USB works',
                    style: TextStyle(fontSize: 11, color: Colors.orange[800]),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
