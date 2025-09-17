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
import android.content.Context
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import android.app.Activity

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
          // Try LAN and Bluetooth first (most common and stable)
          listOf(InterfaceType.Lan, InterfaceType.Bluetooth),
          // Try with Bluetooth LE as well
          listOf(InterfaceType.Lan, InterfaceType.Bluetooth, InterfaceType.BluetoothLE),
          // Try USB separately if other methods work
          listOf(InterfaceType.Usb),
          // Fallback to LAN only
          listOf(InterfaceType.Lan)
        )
        
        var discoverySucceeded = false
        
        for (interfaceTypes in interfaceTypeSets) {
          try {
            discoveryManager?.stopDiscovery()
            discoveryManager = StarDeviceDiscoveryManagerFactory.create(interfaceTypes, context)
            
            discoveryManager?.discoveryTime = 10000 // 10 seconds
            
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
            // Log the error but continue trying other interface combinations
            println("StarPrinter: Discovery failed for interfaces $interfaceTypes: ${e.message}")
            continue
          }
        }
        
        if (!discoverySucceeded) {
          CoroutineScope(Dispatchers.Main).launch {
            result.error("DISCOVERY_FAILED", "All discovery interface combinations failed", null)
          }
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
        builder.addDocument(DocumentBuilder().addPrinter(
          PrinterBuilder()
            .actionPrintText(content)
            .actionCut(CutType.Partial)
        ))
        
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
}
