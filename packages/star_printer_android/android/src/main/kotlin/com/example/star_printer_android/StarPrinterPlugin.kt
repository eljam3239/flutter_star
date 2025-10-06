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

        // Read structured layout from Dart
        val settings = args["settings"] as? Map<*, *>
        val layout = settings?.get("layout") as? Map<*, *>
        val header = layout?.get("header") as? Map<*, *>
        val imageBlock = layout?.get("image") as? Map<*, *>
        val details = layout?.get("details") as? Map<*, *>
  val items = layout?.get("items") as? List<*>

        val headerTitle = (header?.get("title") as? String)?.trim().orEmpty()
        val headerFontSize = (header?.get("fontSize") as? Number)?.toInt() ?: 32
        val headerSpacing = (header?.get("spacingLines") as? Number)?.toInt() ?: 1

        val smallImageBase64 = imageBlock?.get("base64") as? String
        val smallImageWidth = (imageBlock?.get("width") as? Number)?.toInt() ?: 200
        val smallImageSpacing = (imageBlock?.get("spacingLines") as? Number)?.toInt() ?: 1

        val locationText = (details?.get("locationText") as? String)?.trim().orEmpty()
        val dateText = (details?.get("date") as? String)?.trim().orEmpty()
        val timeText = (details?.get("time") as? String)?.trim().orEmpty()
        val cashier = (details?.get("cashier") as? String)?.trim().orEmpty()
        val receiptNum = (details?.get("receiptNum") as? String)?.trim().orEmpty()
        val lane = (details?.get("lane") as? String)?.trim().orEmpty()
        val footer = (details?.get("footer") as? String)?.trim().orEmpty()

        val graphicsOnly = isGraphicsOnlyPrinter()

        val printerBuilder = PrinterBuilder()
        val fullWidthMm = 72.0 // typical printable width for 80mm receipts

        // 1) Header as image for consistent layout
        if (headerTitle.isNotEmpty()) {
          val headerBitmap = createHeaderBitmap(headerTitle, headerFontSize, 576)
          if (headerBitmap != null) {
            printerBuilder
              .styleAlignment(Alignment.Center)
              .actionPrintImage(ImageParameter(headerBitmap, 576))
              .styleAlignment(Alignment.Left)
            if (headerSpacing > 0) printerBuilder.actionFeedLine(headerSpacing)
          }
        }

        // 2) Small image centered
        if (!smallImageBase64.isNullOrEmpty()) {
          val clamped = smallImageWidth.coerceIn(8, 576)
          val decoded = decodeBase64ToBitmap(smallImageBase64)
          val src = decoded ?: createPlaceholderBitmap(clamped, clamped)
          if (src != null) {
            val flat = flattenBitmap(src, clamped)
            val centered = centerOnCanvas(flat, 576)
            if (centered != null) {
              printerBuilder
                .styleAlignment(Alignment.Center)
                .actionPrintImage(ImageParameter(centered, 576))
                .styleAlignment(Alignment.Left)
              if (smallImageSpacing > 0) printerBuilder.actionFeedLine(smallImageSpacing)
            }
          }
        }

  // 2.5) Details block (we will later inject items between ruled lines)
        val hasAnyDetails = listOf(locationText, dateText, timeText, cashier, receiptNum, lane, footer).any { it.isNotEmpty() }
        if (hasAnyDetails) {
          if (graphicsOnly) {
            val detailsBmp = createDetailsBitmap(locationText, dateText, timeText, cashier, receiptNum, lane, footer, items, 576)
            if (detailsBmp != null) {
              printerBuilder.actionPrintImage(ImageParameter(detailsBmp, 576)).actionFeedLine(1)
            }
          } else {
            // Centered location
            if (locationText.isNotEmpty()) {
              printerBuilder.styleAlignment(Alignment.Center).actionPrintText("$locationText\n").styleAlignment(Alignment.Left)
              printerBuilder.actionFeedLine(1) // blank line
            }
            // Centered Tax Invoice
            printerBuilder.styleAlignment(Alignment.Center).actionPrintText("Tax Invoice\n").styleAlignment(Alignment.Left)
            // Left date/time, right cashier
            val leftParam = TextParameter().setWidth(24)
            val rightParam = TextParameter().setWidth(24, TextWidthParameter().setAlignment(TextAlignment.Right))
            val left1 = listOf(dateText, timeText).filter { it.isNotEmpty() }.joinToString(" ")
            val right1 = if (cashier.isNotEmpty()) "Cashier: $cashier" else ""
            printerBuilder.actionPrintText(left1, leftParam)
            printerBuilder.actionPrintText("$right1\n", rightParam)
            // Left receipt no, right lane
            val left2 = if (receiptNum.isNotEmpty()) "Receipt No: $receiptNum" else ""
            val right2 = if (lane.isNotEmpty()) "Lane: $lane" else ""
            printerBuilder.actionPrintText(left2, leftParam)
            printerBuilder.actionPrintText("$right2\n", rightParam)
            // Gap then first ruled line
            printerBuilder.actionFeedLine(1)
            printerBuilder.actionPrintRuledLine(RuledLineParameter(fullWidthMm))

            // Inject item lines (text path only here). Each item: "Q x Name" left, price right.
            val itemList = items?.mapNotNull { it as? Map<*, *> } ?: emptyList()
            if (itemList.isNotEmpty()) {
              val leftParam = TextParameter().setWidth(30) // more left width for description
              val rightParam = TextParameter().setWidth(18, TextWidthParameter().setAlignment(TextAlignment.Right))
              for (item in itemList) {
                val qty = (item["quantity"] as? String)?.trim().orEmpty()
                val name = (item["name"] as? String)?.trim().orEmpty()
                val price = (item["price"] as? String)?.trim().orEmpty()
                val repeatStr = (item["repeat"] as? String)?.trim().orEmpty()
                val repeatN = repeatStr.toIntOrNull() ?: 1
                val leftText = listOf(qty.ifEmpty { "1" }, "x", name.ifEmpty { "Item" }).joinToString(" ")
                val rightText = if (price.isNotEmpty()) "$$price" else "$0.00"
                repeat(repeatN.coerceAtLeast(1).coerceAtMost(200)) {
                  printerBuilder.actionPrintText(leftText, leftParam)
                  printerBuilder.actionPrintText("$rightText\n", rightParam)
                }
              }
            }

            // Second ruled line after items
            printerBuilder.actionPrintRuledLine(RuledLineParameter(fullWidthMm))
            printerBuilder.actionFeedLine(1)
            // Footer centered
            if (footer.isNotEmpty()) {
              printerBuilder.styleAlignment(Alignment.Center).actionPrintText("$footer\n").styleAlignment(Alignment.Left)
            }
          }
        }

        // 3) Body/content
        val trimmedBody = content.trim()
        if (graphicsOnly) {
          // Skip generating an empty body bitmap to prevent a blank rectangle artifact
          // on graphics-only printers (e.g., TSP100III). Only render if there is real content.
          if (trimmedBody.isNotEmpty()) {
            val bodyBitmap = createTextBitmap(content)
            printerBuilder.actionPrintImage(ImageParameter(bodyBitmap, 576)).actionFeedLine(2)
          } else {
            // Light feed to keep a small margin before cut for visual consistency.
            printerBuilder.actionFeedLine(1)
          }
        } else {
          printerBuilder.actionPrintText(content).actionFeedLine(2)
        }

        builder.addDocument(DocumentBuilder().addPrinter(printerBuilder.actionCut(CutType.Partial)))
        
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

  // Render centered header text to a bitmap of given width
  private fun createHeaderBitmap(text: String, fontSize: Int, width: Int): Bitmap? {
    val w = width.coerceAtMost(576)
    val padding = 20
    val textPaint = TextPaint().apply {
      isAntiAlias = true
      color = Color.BLACK
      textSize = fontSize.toFloat()
    }
    val contentWidth = w - (padding * 2)
    val layout: StaticLayout = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      StaticLayout.Builder
        .obtain(text, 0, text.length, textPaint, contentWidth)
        .setAlignment(Layout.Alignment.ALIGN_CENTER)
        .setIncludePad(false)
        .build()
    } else {
      @Suppress("DEPRECATION")
      StaticLayout(text, textPaint, contentWidth, Layout.Alignment.ALIGN_CENTER, 1.0f, 0.0f, false)
    }
    val height = (layout.height + padding * 2).coerceAtLeast(100)
    val bitmap = Bitmap.createBitmap(w, height, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    canvas.drawColor(Color.WHITE)
    canvas.save()
    canvas.translate(padding.toFloat(), padding.toFloat())
    layout.draw(canvas)
    canvas.restore()
    return bitmap
  }

  // Create a structured details block bitmap matching iOS layout
  private fun createDetailsBitmap(
    locationText: String,
    dateText: String,
    timeText: String,
    cashier: String,
    receiptNum: String,
    lane: String,
    footer: String,
    items: List<*>?,
    canvasWidth: Int
  ): Bitmap? {
    val width = canvasWidth.coerceIn(8, 576)
    val padding = 20

    val titlePaint = TextPaint().apply {
      isAntiAlias = true
      color = Color.BLACK
      textSize = 28f
    }
    val bodyPaint = TextPaint().apply {
      isAntiAlias = true
      color = Color.BLACK
      textSize = 22f
    }

    val contentWidth = width - padding * 2

    fun buildLayout(text: String, paint: TextPaint, align: Layout.Alignment): StaticLayout {
      return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
        StaticLayout.Builder
          .obtain(text, 0, text.length, paint, contentWidth)
          .setAlignment(align)
          .setIncludePad(false)
          .build()
      } else {
        @Suppress("DEPRECATION")
        StaticLayout(text, paint, contentWidth, align, 1.0f, 0.0f, false)
      }
    }

    // Build layouts (no lines yet)
    val layouts = mutableListOf<StaticLayout>()
    var totalHeight = 0

    if (locationText.isNotEmpty()) {
      val loc = buildLayout(locationText, titlePaint, Layout.Alignment.ALIGN_CENTER)
      layouts.add(loc)
      totalHeight += loc.height
      // blank line spacer
      val spacer = buildLayout(" ", bodyPaint, Layout.Alignment.ALIGN_NORMAL)
      layouts.add(spacer)
      totalHeight += spacer.height
    }

    val tax = buildLayout("Tax Invoice", titlePaint, Layout.Alignment.ALIGN_CENTER)
    layouts.add(tax)
    totalHeight += tax.height

    // Two column helper: left and right each 24 char width equivalent
    fun twoCol(left: String, right: String): StaticLayout {
      val leftText = left
      val rightText = right
      // crude two-column by spacing; final print uses image so mono spacing is acceptable
      val spaces = 40
      val combined = if (rightText.isNotEmpty()) {
        (leftText + " ".repeat(spaces)).take(spaces) + rightText
      } else leftText
      return buildLayout(combined, bodyPaint, Layout.Alignment.ALIGN_NORMAL)
    }

    val left1 = listOf(dateText, timeText).filter { it.isNotEmpty() }.joinToString(" ")
    val right1 = if (cashier.isNotEmpty()) "Cashier: $cashier" else ""
    val row1 = twoCol(left1, right1)
    layouts.add(row1)
    totalHeight += row1.height

    val left2 = if (receiptNum.isNotEmpty()) "Receipt No: $receiptNum" else ""
    val right2 = if (lane.isNotEmpty()) "Lane: $lane" else ""
    val row2 = twoCol(left2, right2)
    layouts.add(row2)
    totalHeight += row2.height

    // Prepare items (if any) for graphics-only rendering
    val parsedItems = mutableListOf<Pair<String,String>>()
    items?.mapNotNull { it as? Map<*, *> }?.forEach { item ->
      val qty = (item["quantity"] as? String)?.trim().orEmpty().ifEmpty { "1" }
      val name = (item["name"] as? String)?.trim().orEmpty().ifEmpty { "Item" }
      val priceRaw = (item["price"] as? String)?.trim().orEmpty().ifEmpty { "0.00" }
      val repeatStr = (item["repeat"] as? String)?.trim().orEmpty()
      val repeatN = repeatStr.toIntOrNull() ?: 1
      val leftText = "$qty x $name"
      val rightText = "$$priceRaw"
      repeat(repeatN.coerceAtLeast(1).coerceAtMost(200)) {
        parsedItems.add(Pair(leftText, rightText))
      }
    }

    // Reserve space: gap + first line + items + second line + gap after second line
    val gapBeforeLinesPx = (bodyPaint.textSize).toInt()
    val lineThicknessPx = 4
    val interItemLineSpacing = 8
    val gapAfterSecondLinePx = (bodyPaint.textSize * 0.6f).toInt().coerceAtLeast(8)
    var itemsBlockHeight = 0
    if (parsedItems.isNotEmpty()) {
      val lineHeight = (bodyPaint.textSize + 4).toInt()
      itemsBlockHeight = parsedItems.size * (lineHeight + interItemLineSpacing)
    }
    totalHeight += gapBeforeLinesPx + lineThicknessPx + itemsBlockHeight + lineThicknessPx + gapAfterSecondLinePx

    val footerLayout = if (footer.isNotEmpty()) buildLayout(footer, bodyPaint, Layout.Alignment.ALIGN_CENTER) else null
    if (footerLayout != null) {
      totalHeight += footerLayout.height
    }

    // Draw to bitmap
    val height = totalHeight + padding * 2
    val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bmp)
    canvas.drawColor(Color.WHITE)
    var y = padding

    // Draw text layouts first
    for (layout in layouts) {
      canvas.save()
      canvas.translate(padding.toFloat(), y.toFloat())
      layout.draw(canvas)
      canvas.restore()
      y += layout.height
    }

    // Draw gap then first ruled line
    y += gapBeforeLinesPx
    val leftX = padding
    val rightX = width - padding
    val linePaint = android.graphics.Paint().apply {
      color = Color.BLACK
      style = android.graphics.Paint.Style.FILL
      isAntiAlias = false
    }
    canvas.drawRect(leftX.toFloat(), y.toFloat(), rightX.toFloat(), (y + lineThicknessPx).toFloat(), linePaint)
    y += lineThicknessPx + 10

    // Draw items if present (left/right columns)
    if (parsedItems.isNotEmpty()) {
      val availableWidth = (width - padding * 2)
      val leftColWidth = (availableWidth * 0.65).toInt()
      val rightColWidth = availableWidth - leftColWidth
      val leftXText = padding
      val rightXText = padding + leftColWidth
      val textPaintLeft = TextPaint(bodyPaint)
      val textPaintRight = TextPaint(bodyPaint)
      textPaintRight.textAlign = android.graphics.Paint.Align.RIGHT
      parsedItems.forEach { (l, r) ->
        // Left text clipped to column
        val leftLayout = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
          StaticLayout.Builder.obtain(l, 0, l.length, textPaintLeft, leftColWidth)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setIncludePad(false)
            .build()
        } else {
          @Suppress("DEPRECATION")
          StaticLayout(l, textPaintLeft, leftColWidth, Layout.Alignment.ALIGN_NORMAL, 1.0f, 0f, false)
        }
        canvas.save()
        canvas.translate(leftXText.toFloat(), y.toFloat())
        leftLayout.draw(canvas)
        canvas.restore()
        // Right text (single line) aligned right
        val priceY = y + bodyPaint.textSize
        canvas.drawText(r, (rightXText + rightColWidth).toFloat(), priceY - 6, textPaintRight)
        val lineH = leftLayout.height.coerceAtLeast(bodyPaint.textSize.toInt()) + interItemLineSpacing
        y += lineH
      }
    }

    // Second ruled line
    canvas.drawRect(leftX.toFloat(), y.toFloat(), rightX.toFloat(), (y + lineThicknessPx).toFloat(), linePaint)
    y += lineThicknessPx + gapAfterSecondLinePx

    // Footer centered if present
    if (footerLayout != null) {
      canvas.save()
      canvas.translate(padding.toFloat(), y.toFloat())
      footerLayout.draw(canvas)
      canvas.restore()
      y += footerLayout.height
    }

    return bmp
  }

  // Create a placeholder bitmap (solid black square)
  private fun createPlaceholderBitmap(width: Int, height: Int): Bitmap {
    val w = width.coerceIn(8, 576)
    val h = height.coerceAtLeast(8)
    val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bmp)
    canvas.drawColor(Color.BLACK)
    return bmp
  }

  // Flatten bitmap onto white background at target width (keep aspect)
  private fun flattenBitmap(src: Bitmap, targetWidth: Int): Bitmap {
    val tw = targetWidth.coerceIn(8, 576)
    val aspect = src.height.toFloat() / src.width.toFloat().coerceAtLeast(1f)
    val th = (tw * aspect).toInt().coerceAtLeast(8)
    val out = Bitmap.createBitmap(tw, th, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(out)
    canvas.drawColor(Color.WHITE)
    val dst = android.graphics.Rect(0, 0, tw, th)
    canvas.drawBitmap(src, null, dst, null)
    return out
  }

  // Center a bitmap on a full-width canvas to force horizontal centering
  private fun centerOnCanvas(src: Bitmap, canvasWidth: Int): Bitmap {
    val cw = canvasWidth.coerceIn(8, 576)
    val aspect = src.height.toFloat() / src.width.toFloat().coerceAtLeast(1f)
    val targetW = src.width.coerceAtMost(cw)
    val targetH = (targetW * aspect).toInt().coerceAtLeast(8)
    val out = Bitmap.createBitmap(cw, targetH, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(out)
    canvas.drawColor(Color.WHITE)
    val left = (cw - targetW) / 2
    val dst = android.graphics.Rect(left, 0, left + targetW, targetH)
    canvas.drawBitmap(src, null, dst, null)
    return out
  }

  // Decode Base64 (with optional data URI) to Bitmap
  private fun decodeBase64ToBitmap(b64: String?): Bitmap? {
    if (b64.isNullOrEmpty()) return null
    return try {
      val trimmed = b64.trim()
      val payload = if (trimmed.startsWith("data:image")) trimmed.substringAfter(",") else trimmed
      val clean = payload.replace("\n", "").replace("\r", "").replace(" ", "")
      val bytes = android.util.Base64.decode(clean, android.util.Base64.DEFAULT)
      android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
    } catch (e: Exception) {
      null
    }
  }
}
