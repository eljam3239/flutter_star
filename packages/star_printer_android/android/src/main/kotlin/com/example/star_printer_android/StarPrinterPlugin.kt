package com.example.star_printer_android

import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import com.starmicronics.stario10.*
import com.starmicronics.stario10.starxpandcommand.*
import com.starmicronics.stario10.starxpandcommand.printer.*
import com.starmicronics.stario10.starxpandcommand.drawer.*
import kotlinx.coroutines.*
import kotlinx.coroutines.CompletableDeferred
import android.hardware.usb.UsbManager
import android.content.Context
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint

/** StarPrinterPlugin */
class StarPrinterPlugin: FlutterPlugin, MethodCallHandler, ActivityAware {
  private lateinit var channel: MethodChannel
  private lateinit var context: Context
  private var activity: Activity? = null
  private var printer: StarPrinter? = null
  private var discoveryManager: StarDeviceDiscoveryManager? = null

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "star_printer")
    channel.setMethodCallHandler(this)
    context = flutterPluginBinding.applicationContext
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
      "discoverPrinters" -> discoverPrinters(result)
      "discoverBluetoothPrinters" -> discoverBluetoothPrinters(result)
      "usbDiagnostics" -> runUsbDiagnostics(result)
      "connect" -> connectToPrinter(call, result)
      "disconnect" -> disconnectFromPrinter(result)
      "printReceipt" -> printReceipt(call, result)
      "getStatus" -> getStatus(result)
      "openCashDrawer" -> openCashDrawer(result)
      "isConnected" -> isConnected(result)
      else -> result.notImplemented()
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    discoveryManager?.stopDiscovery()
  }

  private fun discoverPrinters(result: Result) {
    CoroutineScope(Dispatchers.IO).launch {
      try {
        // Check USB OTG support and connected devices first
        val usbManager = context.getSystemService(android.content.Context.USB_SERVICE) as UsbManager
        val hasUsbHost = context.packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_USB_HOST)
        
        println("StarPrinter: USB Host (OTG) support: $hasUsbHost")
        println("StarPrinter: Connected USB devices: ${usbManager.deviceList.size}")
        
        // List all connected USB devices for debugging
        usbManager.deviceList.forEach { (deviceName, device) ->
          println("StarPrinter: USB Device - Name: $deviceName")
          println("StarPrinter: USB Device - VendorId: ${device.vendorId} (0x${device.vendorId.toString(16)})")
          println("StarPrinter: USB Device - ProductId: ${device.productId} (0x${device.productId.toString(16)})")
          println("StarPrinter: USB Device - Manufacturer: ${device.manufacturerName}")
          println("StarPrinter: USB Device - Product: ${device.productName}")
          
          // Check if this matches TSP100 USB IDs (Star Micronics vendor ID: 0x0519 = 1305)
          if (device.vendorId == 1305) {
            println("StarPrinter: *** STAR MICRONICS DEVICE DETECTED! ***")
            println("StarPrinter: This appears to be a Star printer via USB")
          }
        }
        
        // Check Bluetooth permissions and availability
        if (!hasBluetoothPermissions()) {
          CoroutineScope(Dispatchers.Main).launch {
            result.error("BLUETOOTH_PERMISSION_DENIED", "Bluetooth permissions not granted", null)
          }
          return@launch
        }

        if (!isBluetoothAvailable()) {
          CoroutineScope(Dispatchers.Main).launch {
            result.error("BLUETOOTH_UNAVAILABLE", "Bluetooth is not available or enabled", null)
          }
          return@launch
        }

        val printers = mutableListOf<String>()
        
        // Try discovery with different interface combinations to find what works
        val interfaceTypeSets = listOf(
          // Try LAN only first (in case WiFi is available)
          listOf(InterfaceType.Lan),
          // Try Bluetooth only (works even without WiFi)
          listOf(InterfaceType.Bluetooth),
          // Try Bluetooth LE only (works even without WiFi)
          listOf(InterfaceType.BluetoothLE),
          // Try USB separately
          listOf(InterfaceType.Usb),
          // Try combined LAN + Bluetooth (when both are available)
          listOf(InterfaceType.Lan, InterfaceType.Bluetooth, InterfaceType.BluetoothLE)
        )
        
        // Run ALL discovery types and combine results
        val allDiscoveredPrinters = mutableSetOf<String>()
        
        for (interfaceTypes in interfaceTypeSets) {
          try {
            discoveryManager?.stopDiscovery()
            discoveryManager = StarDeviceDiscoveryManagerFactory.create(interfaceTypes, context)
            
            discoveryManager?.discoveryTime = 8000 // 8 seconds per discovery type
            
            val discoveryCompleted = CompletableDeferred<Unit>()
            val discoveryPrinters = mutableListOf<String>()
            
            discoveryManager?.callback = object : StarDeviceDiscoveryManager.Callback {
              override fun onPrinterFound(printer: StarPrinter) {
                val interfaceTypeStr = when (printer.connectionSettings.interfaceType) {
                  InterfaceType.Lan -> "LAN"
                  InterfaceType.Bluetooth -> "BT"
                  InterfaceType.BluetoothLE -> "BLE"
                  InterfaceType.Usb -> "USB"
                  else -> "UNKNOWN"
                }
                val identifier = printer.connectionSettings.identifier
                val model = printer.information?.model ?: "Unknown"
                val printerString = "$interfaceTypeStr:$identifier:$model"
                discoveryPrinters.add(printerString)
              }
              
              override fun onDiscoveryFinished() {
                discoveryCompleted.complete(Unit)
              }
            }
            
            discoveryManager?.startDiscovery()
            discoveryCompleted.await()
            
            // Add all discovered printers to the combined set
            allDiscoveredPrinters.addAll(discoveryPrinters)
            
          } catch (e: Exception) {
            // Log the error but continue trying other interface combinations
            println("StarPrinter: Discovery failed for interfaces $interfaceTypes: ${e.message}")
            continue
          }
        }
        
        // Convert set back to list and return all discovered printers
        printers.addAll(allDiscoveredPrinters.toList())
        
        CoroutineScope(Dispatchers.Main).launch {
          result.success(printers)
        }
        
      } catch (e: Exception) {
        CoroutineScope(Dispatchers.Main).launch {
          result.error("DISCOVERY_FAILED", e.message ?: "Unknown error", null)
        }
      }
    }
  }

  private fun discoverBluetoothPrinters(result: Result) {
    CoroutineScope(Dispatchers.IO).launch {
      try {
        // Check Bluetooth permissions and availability
        if (!hasBluetoothPermissions()) {
          CoroutineScope(Dispatchers.Main).launch {
            result.error("BLUETOOTH_PERMISSION_DENIED", "Bluetooth permissions not granted", null)
          }
          return@launch
        }

        if (!isBluetoothAvailable()) {
          CoroutineScope(Dispatchers.Main).launch {
            result.error("BLUETOOTH_UNAVAILABLE", "Bluetooth is not available or enabled", null)
          }
          return@launch
        }

        val printers = mutableListOf<String>()
        
        // Try different Bluetooth interface combinations
        val bluetoothInterfaceSets = listOf(
          // Try classic Bluetooth first
          listOf(InterfaceType.Bluetooth),
          // Try both classic and LE
          listOf(InterfaceType.Bluetooth, InterfaceType.BluetoothLE),
          // Try LE only as fallback
          listOf(InterfaceType.BluetoothLE)
        )
        
        var discoverySucceeded = false
        
        for (interfaceTypes in bluetoothInterfaceSets) {
          try {
            discoveryManager?.stopDiscovery()
            discoveryManager = StarDeviceDiscoveryManagerFactory.create(interfaceTypes, context)
            
            discoveryManager?.discoveryTime = 10000 // 10 seconds
            
            discoveryManager?.callback = object : StarDeviceDiscoveryManager.Callback {
              override fun onPrinterFound(printer: StarPrinter) {
                val interfaceTypeStr = when (printer.connectionSettings.interfaceType) {
                  InterfaceType.Bluetooth -> "BT"
                  InterfaceType.BluetoothLE -> "BLE"
                  else -> "UNKNOWN"
                }
                val identifier = printer.connectionSettings.identifier
                val model = printer.information?.model ?: "Unknown"
                printers.add("$interfaceTypeStr:$identifier:$model")
              }
              
              override fun onDiscoveryFinished() {
                CoroutineScope(Dispatchers.Main).launch {
                  result.success(printers)
                }
              }
            }
            
            discoveryManager?.startDiscovery()
            discoverySucceeded = true
            break // Success, stop trying other combinations
            
          } catch (e: Exception) {
            println("StarPrinter: Bluetooth discovery failed for interfaces $interfaceTypes: ${e.message}")
            continue
          }
        }
        
        if (!discoverySucceeded) {
          CoroutineScope(Dispatchers.Main).launch {
            result.error("BLUETOOTH_DISCOVERY_FAILED", "All Bluetooth discovery methods failed", null)
          }
        }
        
      } catch (e: Exception) {
        CoroutineScope(Dispatchers.Main).launch {
          result.error("BLUETOOTH_DISCOVERY_FAILED", e.message ?: "Not supported interface.", null)
        }
      }
    }
  }

  private fun connectToPrinter(call: MethodCall, result: Result) {
    val args = call.arguments as? Map<*, *>
    val interfaceType = args?.get("interfaceType") as? String
    val identifier = args?.get("identifier") as? String

    if (interfaceType == null || identifier == null) {
      result.error("INVALID_ARGS", "Invalid connection settings", null)
      return
    }

    CoroutineScope(Dispatchers.IO).launch {
      try {
        // Close any existing connection
        printer?.closeAsync()?.await()
        
        val starInterfaceType = when (interfaceType) {
          "bluetooth" -> InterfaceType.Bluetooth
          "lan" -> InterfaceType.Lan
          "usb" -> InterfaceType.Usb
          else -> InterfaceType.Lan
        }
        
        val settings = StarConnectionSettings(starInterfaceType, identifier)
        val newPrinter = StarPrinter(settings, context)
        
        newPrinter.openAsync().await()
        printer = newPrinter
        
        withContext(Dispatchers.Main) {
          result.success(true)
        }
      } catch (e: Exception) {
        withContext(Dispatchers.Main) {
          result.error("CONNECTION_FAILED", e.message ?: "Unknown error", null)
        }
      }
    }
  }

  private fun disconnectFromPrinter(result: Result) {
    CoroutineScope(Dispatchers.IO).launch {
      try {
        printer?.closeAsync()?.await()
        printer = null
        
        withContext(Dispatchers.Main) {
          result.success(true)
        }
      } catch (e: Exception) {
        withContext(Dispatchers.Main) {
          result.error("DISCONNECT_FAILED", e.message ?: "Unknown error", null)
        }
      }
    }
  }

  private fun printReceipt(call: MethodCall, result: Result) {
    val args = call.arguments as? Map<*, *>
    val content = args?.get("content") as? String

    if (content == null) {
      result.error("INVALID_ARGS", "Content is required", null)
      return
    }

    if (printer == null) {
      result.error("NOT_CONNECTED", "Printer is not connected", null)
      return
    }

    CoroutineScope(Dispatchers.IO).launch {
      try {
        val builder = StarXpandCommandBuilder()

        val graphicsOnly = isGraphicsOnlyPrinter()
        if (graphicsOnly) {
          println("StarPrinter: Graphics-only printer detected – using actionPrintImage")
          val bitmap = createTextBitmap(content)
          builder.addDocument(
            DocumentBuilder().addPrinter(
              PrinterBuilder()
                .actionPrintImage(ImageParameter(bitmap, 576))
                .actionFeedLine(2)
                .actionCut(CutType.Partial)
            )
          )
        } else {
          builder.addDocument(
            DocumentBuilder().addPrinter(
              PrinterBuilder()
                .actionPrintText(content)
                .actionFeedLine(2)
                .actionCut(CutType.Partial)
            )
          )
        }
        
        val commands = builder.getCommands()
        printer?.printAsync(commands)?.await()
        
        withContext(Dispatchers.Main) {
          result.success(true)
        }
      } catch (e: Exception) {
        withContext(Dispatchers.Main) {
          result.error("PRINT_FAILED", e.message ?: "Unknown error", null)
        }
      }
    }
  }

  private fun getStatus(result: Result) {
    if (printer == null) {
      result.error("NOT_CONNECTED", "Printer is not connected", null)
      return
    }

    CoroutineScope(Dispatchers.IO).launch {
      try {
        val status = printer?.getStatusAsync()?.await()
        
        val statusMap = mapOf(
          "isOnline" to (status != null),
          "status" to "OK"
        )
        
        withContext(Dispatchers.Main) {
          result.success(statusMap)
        }
      } catch (e: Exception) {
        withContext(Dispatchers.Main) {
          result.error("STATUS_FAILED", e.message ?: "Unknown error", null)
        }
      }
    }
  }

  private fun openCashDrawer(result: Result) {
    if (printer == null) {
      result.error("NOT_CONNECTED", "Printer is not connected", null)
      return
    }

    CoroutineScope(Dispatchers.IO).launch {
      try {
        val builder = StarXpandCommandBuilder()
        builder.addDocument(DocumentBuilder().addDrawer(
          DrawerBuilder()
            .actionOpen(OpenParameter())
        ))
        
        val commands = builder.getCommands()
        printer?.printAsync(commands)?.await()
        
        withContext(Dispatchers.Main) {
          result.success(true)
        }
      } catch (e: Exception) {
        withContext(Dispatchers.Main) {
          result.error("CASH_DRAWER_FAILED", e.message ?: "Unknown error", null)
        }
      }
    }
  }

  private fun isConnected(result: Result) {
    result.success(printer != null)
  }

  private fun runUsbDiagnostics(result: Result) {
    CoroutineScope(Dispatchers.IO).launch {
      try {
        val diagnostics = mutableMapOf<String, Any>()
        
        // Check USB Host support
        val packageManager = context.packageManager
        val hasUsbHost = packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST)
        diagnostics["usb_host_supported"] = hasUsbHost
        
        // Check USB Manager and connected devices
        val usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
        val deviceList = usbManager.deviceList
        diagnostics["connected_usb_devices"] = deviceList.size
        
        val usbDevices = mutableListOf<Map<String, Any>>()
        for ((deviceName, device) in deviceList) {
          val deviceInfo = mapOf(
            "device_name" to deviceName,
            "vendor_id" to device.vendorId,
            "product_id" to device.productId,
            "device_class" to device.deviceClass,
            "device_subclass" to device.deviceSubclass,
            "product_name" to (device.productName ?: "Unknown"),
            "manufacturer_name" to (device.manufacturerName ?: "Unknown")
          )
          usbDevices.add(deviceInfo)
        }
        diagnostics["usb_devices"] = usbDevices
        
        // Check for TSP100 specific devices (vendor ID 1305, common product IDs)
        val tsp100Devices = deviceList.values.filter { device ->
          device.vendorId == 1305 // Star Micronics vendor ID
        }
        diagnostics["tsp100_devices_found"] = tsp100Devices.size
        
        // Try USB-only discovery
        var usbPrintersFound = 0
        try {
          val printers = mutableListOf<String>()
          discoveryManager?.stopDiscovery()
          discoveryManager = StarDeviceDiscoveryManagerFactory.create(listOf(InterfaceType.Usb), context)
          
          discoveryManager?.discoveryTime = 5000 // 5 seconds for diagnostics
          
          val discoveryCompleted = CompletableDeferred<Unit>()
          
          discoveryManager?.callback = object : StarDeviceDiscoveryManager.Callback {
            override fun onPrinterFound(printer: StarPrinter) {
              val identifier = printer.connectionSettings.identifier
              val model = printer.information?.model ?: "Unknown"
              printers.add("USB:$identifier:$model")
              usbPrintersFound++
            }
            
            override fun onDiscoveryFinished() {
              discoveryCompleted.complete(Unit)
            }
          }
          
          discoveryManager?.startDiscovery()
          discoveryCompleted.await()
          
          diagnostics["usb_printers_discovered"] = usbPrintersFound
          diagnostics["usb_printer_list"] = printers
          
        } catch (e: Exception) {
          diagnostics["usb_discovery_error"] = e.message ?: "Unknown error"
          diagnostics["usb_printers_discovered"] = 0
        }
        
        withContext(Dispatchers.Main) {
          result.success(diagnostics)
        }
        
      } catch (e: Exception) {
        withContext(Dispatchers.Main) {
          result.error("USB_DIAGNOSTICS_FAILED", e.message ?: "Unknown error", null)
        }
      }
    }
  }

  // ActivityAware implementation
  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
  }

  override fun onDetachedFromActivityForConfigChanges() {
    activity = null
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    activity = binding.activity
  }

  override fun onDetachedFromActivity() {
    activity = null
  }

  private fun hasBluetoothPermissions(): Boolean {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      // Android 12+ permissions - BLUETOOTH_CONNECT is required for printer communication
      ContextCompat.checkSelfPermission(context, android.Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
      ContextCompat.checkSelfPermission(context, android.Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
    } else {
      // Legacy permissions
      ContextCompat.checkSelfPermission(context, android.Manifest.permission.BLUETOOTH) == PackageManager.PERMISSION_GRANTED &&
      ContextCompat.checkSelfPermission(context, android.Manifest.permission.BLUETOOTH_ADMIN) == PackageManager.PERMISSION_GRANTED
    }
  }

  private fun isBluetoothAvailable(): Boolean {
    val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    val bluetoothAdapter = bluetoothManager?.adapter
    return bluetoothAdapter != null && bluetoothAdapter.isEnabled
  }

  // Determine if the connected printer is graphics-only (e.g., TSP100iii series)
  private fun isGraphicsOnlyPrinter(): Boolean {
    return try {
      val modelStr = printer?.information?.model?.toString() ?: return false
      // Use a case-insensitive check to avoid tight coupling to enum identifiers
      val ms = modelStr.lowercase()
      ms.contains("tsp100iii") || ms.contains("tsp1003")
    } catch (e: Exception) {
      false
    }
  }

  // Render multiline text into a Bitmap suitable for printing
  private fun createTextBitmap(text: String): Bitmap {
    val width = 576 // 80mm paper standard printable width (pixels)
    val padding = 20

    val textPaint = TextPaint().apply {
      isAntiAlias = true
      color = Color.BLACK
      textSize = 24f
    }

    val contentWidth = width - (padding * 2)

    val layout: StaticLayout = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      StaticLayout.Builder
        .obtain(text, 0, text.length, textPaint, contentWidth)
        .setAlignment(Layout.Alignment.ALIGN_NORMAL)
        .setIncludePad(false)
        .build()
    } else {
      @Suppress("DEPRECATION")
      StaticLayout(
        text,
        textPaint,
        contentWidth,
        Layout.Alignment.ALIGN_NORMAL,
        1.0f,
        0.0f,
        false
      )
    }

    val height = (layout.height + padding * 2).coerceAtLeast(100)
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    canvas.drawColor(Color.WHITE)
    canvas.save()
    canvas.translate(padding.toFloat(), padding.toFloat())
    layout.draw(canvas)
    canvas.restore()
    return bitmap
  }
}
