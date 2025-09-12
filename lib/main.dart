import 'package:flutter/material.dart';
import 'package:star_printer/star_printer.dart';
import 'bluetooth_test_widget.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'Star Printer Demo'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;
  List<String> _discoveredPrinters = [];
  bool _isConnected = false;
  String _printerStatus = 'Unknown';
  String? _selectedPrinter; // Add selected printer tracking

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
  }

  Future<void> _discoverPrinters() async {
    try {
      print('DEBUG: Starting printer discovery...');
      final printers = await StarPrinter.discoverPrinters();
      print('DEBUG: Discovery result: $printers');
      setState(() {
        _discoveredPrinters = printers;
        // Auto-select first printer if none selected or if current selection is no longer available
        if (_selectedPrinter == null || !printers.contains(_selectedPrinter)) {
          _selectedPrinter = printers.isNotEmpty ? printers.first : null;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Found ${printers.length} printers')),
      );
    } catch (e) {
      print('DEBUG: Discovery error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Discovery failed: $e')),
      );
    }
  }

  Future<void> _connectToPrinter() async {
    if (_discoveredPrinters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No printers discovered. Please discover printers first.')),
      );
      return;
    }

    if (_selectedPrinter == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a printer first.')),
      );
      return;
    }

    try {
      // Disconnect from current printer if connected
      if (_isConnected) {
        print('DEBUG: Disconnecting from current printer before new connection...');
        await StarPrinter.disconnect();
        setState(() {
          _isConnected = false;
        });
        // Small delay to ensure clean disconnect
        await Future.delayed(const Duration(milliseconds: 500));
      }
      
      final printerString = _selectedPrinter!; // Use selected printer instead of first
      
      // Parse the printer string to determine interface type
      StarInterfaceType interfaceType;
      String identifier;
      
      if (printerString.startsWith('LAN:')) {
        interfaceType = StarInterfaceType.lan;
        // Extract just the identifier part (MAC address or IP), ignore model info
        final parts = printerString.substring(4).split(':');
        identifier = parts[0]; // Take first part before any model info
      } else if (printerString.startsWith('BT:') || printerString.startsWith('BLE:')) {
        interfaceType = StarInterfaceType.bluetooth;
        final parts = printerString.startsWith('BT:') 
            ? printerString.substring(3).split(':')
            : printerString.substring(4).split(':');
        identifier = parts[0]; // Take first part before any model info
      } else {
        interfaceType = StarInterfaceType.lan;
        identifier = printerString.split(':')[0]; // Take first part
      }
      
      print('DEBUG: Connecting to $interfaceType printer: $identifier (Selected: $printerString)');
      
      final settings = StarConnectionSettings(
        interfaceType: interfaceType,
        identifier: identifier,
      );
      await StarPrinter.connect(settings);
      setState(() {
        _isConnected = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connected to: ${_selectedPrinter!.split(':').last}')), // Show printer model
      );
    } catch (e) {
      print('DEBUG: Connection error: $e');
      setState(() {
        _isConnected = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connection failed: $e')),
      );
    }
  }

  Future<void> _printReceipt() async {
    print('DEBUG: Print receipt button pressed');
    
    try {
      print('DEBUG: Creating print job...');
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
Counter: $_counter
Print Test

''',
      );
      
      print('DEBUG: Sending print job to printer...');
      await StarPrinter.printReceipt(printJob);
      
      print('DEBUG: Print job completed successfully');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Print job sent successfully')),
      );
    } catch (e) {
      print('DEBUG: Print failed with error: $e');
      print('DEBUG: Error type: ${e.runtimeType}');
      print('DEBUG: Error details: ${e.toString()}');
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Print failed: $e')),
      );
    }
  }

  Future<void> _disconnectFromPrinter() async {
    try {
      await StarPrinter.disconnect();
      setState(() {
        _isConnected = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Disconnected from printer')),
      );
    } catch (e) {
      print('DEBUG: Disconnect error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Disconnect failed: $e')),
      );
    }
  }

  Future<void> _getStatus() async {
    try {
      final status = await StarPrinter.getStatus();
      setState(() {
        _printerStatus = 'Online: ${status.isOnline}, Status: ${status.status}';
      });
    } catch (e) {
      setState(() {
        _printerStatus = 'Error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: <Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Counter Demo',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    const Text('You have pushed the button this many times:'),
                    Text(
                      '$_counter',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _incrementCounter,
                      child: const Text('Increment Counter'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Star Printer Controls',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    Text('Discovered Printers: ${_discoveredPrinters.length}'),
                    if (_discoveredPrinters.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text('Select Printer:', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _selectedPrinter,
                            hint: const Text('Select a printer'),
                            isExpanded: true,
                            items: _discoveredPrinters.map((printer) {
                              // Extract model name for display
                              final parts = printer.split(':');
                              final model = parts.length > 2 ? parts[2] : 'Unknown';
                              final mac = parts.length > 1 ? parts[1] : 'Unknown';
                              return DropdownMenuItem<String>(
                                value: printer,
                                child: Text('$model (${mac.substring(0, 8)}...)'),
                              );
                            }).toList(),
                            onChanged: (String? newValue) {
                              setState(() {
                                _selectedPrinter = newValue;
                                _isConnected = false; // Reset connection status when changing printer
                              });
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_selectedPrinter != null)
                        Text('Selected: ${_selectedPrinter!}', 
                             style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
                    ],
                    const SizedBox(height: 16),
                    Text('Connection Status: ${_isConnected ? "Connected" : "Disconnected"}'),
                    const SizedBox(height: 8),
                    Text('Printer Status: $_printerStatus'),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ElevatedButton(
                          onPressed: _discoverPrinters,
                          child: const Text('Discover Printers'),
                        ),
                        ElevatedButton(
                          onPressed: _selectedPrinter != null && !_isConnected
                              ? _connectToPrinter
                              : null,
                          child: const Text('Connect'),
                        ),
                        ElevatedButton(
                          onPressed: _isConnected ? _disconnectFromPrinter : null,
                          child: const Text('Disconnect'),
                        ),
                        ElevatedButton(
                          onPressed: _printReceipt,
                          child: const Text('Print Receipt'),
                        ),
                        ElevatedButton(
                          onPressed: _getStatus,
                          child: const Text('Get Status'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const BluetoothTestWidget(),
          ],
        ),
      ),
    );
  }
}
