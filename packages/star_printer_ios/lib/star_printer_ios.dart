import 'package:star_printer_platform_interface/star_printer_platform_interface.dart';
import 'package:flutter/services.dart';

/// iOS implementation of [StarPrinterPlatform].
class StarPrinterIOS extends StarPrinterPlatform {
  /// The method channel used to interact with the native platform.
  static const MethodChannel _channel = MethodChannel('star_printer');

  /// Registers this class as the platform implementation for iOS.
  static void registerWith() {
    StarPrinterPlatform.instance = StarPrinterIOS();
  }

  @override
  Future<List<String>> discoverPrinters() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('discoverPrinters');
      return result?.cast<String>() ?? [];
    } catch (e) {
      throw Exception('Failed to discover printers: $e');
    }
  }

  @override
  Future<List<String>> discoverBluetoothPrinters() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('discoverBluetoothPrinters');
      return result?.cast<String>() ?? [];
    } catch (e) {
      throw Exception('Failed to discover Bluetooth printers: $e');
    }
  }

  @override
  Future<void> connect(StarConnectionSettings settings) async {
    try {
      await _channel.invokeMethod('connect', settings.toMap());
    } catch (e) {
      throw Exception('Failed to connect: $e');
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
    } catch (e) {
      throw Exception('Failed to disconnect: $e');
    }
  }

  @override
  Future<void> printReceipt(PrintJob printJob) async {
    try {
      await _channel.invokeMethod('printReceipt', printJob.toMap());
    } catch (e) {
      throw Exception('Failed to print: $e');
    }
  }

  @override
  Future<PrinterStatus> getStatus() async {
    try {
      final result = await _channel.invokeMethod<Map<String, dynamic>>('getStatus');
      return PrinterStatus.fromMap(result ?? {});
    } catch (e) {
      throw Exception('Failed to get status: $e');
    }
  }

  @override
  Future<void> openCashDrawer() async {
    try {
      await _channel.invokeMethod('openCashDrawer');
    } catch (e) {
      throw Exception('Failed to open cash drawer: $e');
    }
  }

  @override
  Future<bool> isConnected() async {
    try {
      final result = await _channel.invokeMethod<bool>('isConnected');
      return result ?? false;
    } catch (e) {
      throw Exception('Failed to check connection: $e');
    }
  }
}
