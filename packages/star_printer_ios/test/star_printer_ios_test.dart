import 'package:flutter_test/flutter_test.dart';
import 'package:star_printer_platform_interface/star_printer_platform_interface.dart';
import 'package:star_printer_ios/star_printer_ios.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StarPrinterIOS', () {
    late StarPrinterIOS starPrinterIOS;

    setUp(() {
      starPrinterIOS = StarPrinterIOS();
      StarPrinterPlatform.instance = starPrinterIOS;
    });

    test('can be registered', () {
      StarPrinterIOS.registerWith();
      expect(StarPrinterPlatform.instance, isA<StarPrinterIOS>());
    });

    test('discoverPrinters returns a list', () async {
      final result = await starPrinterIOS.discoverPrinters();
      expect(result, isA<List<String>>());
    });

    test('isConnected returns false initially', () async {
      final result = await starPrinterIOS.isConnected();
      expect(result, false);
    });

    test('getStatus returns printer status', () async {
      final result = await starPrinterIOS.getStatus();
      expect(result, isA<PrinterStatus>());
      expect(result.isOnline, false); // Should be false when not connected
    });
  });
}
