package com.example.orbits_new

import android.annotation.SuppressLint // Import annotation, used to suppress specific Lint warnings
import android.app.ActivityManager // Import ActivityManager, used to manage application processes and tasks
import android.content.Context // Import Context class, providing application environment information
import android.content.Intent // Import Intent class, used for inter-component communication
import android.os.Build // Import Build class, used to check Android version
import androidx.annotation.NonNull // Import NonNull annotation, indicating that parameters, fields, or method return values cannot be null.
import io.flutter.Log // Import Flutter's Log utility, used for logging to the Flutter console
import io.flutter.embedding.engine.plugins.FlutterPlugin // Import FlutterPlugin interface, for plugin lifecycle management
import io.flutter.plugin.common.EventChannel // Import EventChannel, used to send data streams from native to Flutter
import io.flutter.plugin.common.MethodCall // Import MethodCall, representing a method call from Flutter to the native side.
import io.flutter.plugin.common.MethodChannel // Import MethodChannel, for communication between Flutter and native code.


//BleScanServicePlugin is a bridge between the Flutter application and the native Android BLE scan service.
//It allows Flutter to start, stop the BLE scan service, set scan modes, and receive scan results.


class BleScanServicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var context: Context // Used for Android application context
    private lateinit var methodChannel: MethodChannel // Used for MethodChannel instance
    private lateinit var eventChannel: EventChannel // Used for EventChannel instance

    // This method is called when the plugin is attached to the Flutter engine. Set up communication channels here.
    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext // Get application context

        // Create MethodChannel, used for Flutter to call native methods
        methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "ble_scan_service")
        // Set this plugin instance as the handler for method calls on this channel
        methodChannel.setMethodCallHandler(this)

        // Create EventChannel, used for native to send scan result streams to Flutter
        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "ble_scan_results")
        // Set this plugin instance as the stream handler for this event channel
        eventChannel.setStreamHandler(this)

        Log.d("BleScanServicePlugin", "Plugin attached to engine. Channels initialized.") // Add log
    }

    // This method is called when the plugin is detached from the Flutter engine.
    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        // It is crucial to clean up resources here.
        // Clear MethodChannel's method call handler to prevent memory leaks.
        methodChannel.setMethodCallHandler(null)
        // Clear EventChannel's stream handler.
        eventChannel.setStreamHandler(null)
        // Clear the static reference to EventSink in BleScanForegroundService to prevent memory leaks.
        BleScanForegroundService.eventSink = null
        Log.d("BleScanServicePlugin", "Plugin detached from engine. Channels cleared.") // Add log
    }

    // Method implementation for MethodChannel.MethodCallHandler interface.
    // This method is called whenever a method is invoked from the Flutter side.
    @SuppressLint("ServiceCast") // Suppress ServiceCast warning for getSystemService
    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: MethodChannel.Result) {
        // Use a 'when' expression to handle different method calls based on the method name.
        when (call.method) {
            "startScanService" -> {
                Log.d("BleScanServicePlugin", "Received startScanService call from Flutter.") // Add log
                // Create an Intent to start BleScanForegroundService.
                val intent = Intent(context, BleScanForegroundService::class.java)
                intent.action = "ACTION_START_SCAN_SERVICE" // Set custom action
                // Check if the Android version is Android O (API 26) or higher.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    // If O or higher, start the service as a foreground service.
                    context.startForegroundService(intent)
                } else {
                    // For older Android versions, start the service normally.
                    context.startService(intent)
                }
                // Return a success result to Flutter.
                result.success(true)
            }
            "stopScanService" -> {
                Log.d("BleScanServicePlugin", "Received stopScanService call from Flutter.") // Add log
                // Create an Intent to stop BleScanForegroundService.
                val intent = Intent(context, BleScanForegroundService::class.java)
                context.stopService(intent)
                // Return a success result to Flutter.
                result.success(true)
            }
            "setScanMode" -> {
                // Get the mode string passed from Flutter.
                val mode = call.argument<String>("mode")
                Log.d("BleScanServicePlugin", "Received setScanMode call from Flutter: $mode") // Add log
                if (mode != null) {
                    // Create an Intent to set the scan mode of BleScanForegroundService.
                    val intent = Intent(context, BleScanForegroundService::class.java).apply {
                        action = "ACTION_SET_SCAN_MODE" // Define a custom action for service identification
                        putExtra("mode", mode) // Pass the mode string as an extra
                    }
                    // Start the service. If the service is already running, this will call its onStartCommand method.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(intent)
                    } else {
                        context.startService(intent)
                    }
                    result.success(true)
                } else {
                    Log.e("BleScanServicePlugin", "Scan mode argument is null.") // Add error log
                    result.error("INVALID_ARGUMENT", "Scan mode cannot be null", null)
                }
            }
            "isServiceRunning" -> { // Optimization: Method name consistent with Dart side
                Log.d("BleScanServicePlugin", "Received isServiceRunning call from Flutter.") // Add log
                // Query if BleScanForegroundService is running.
                // Assuming BleScanForegroundService internally maintains a static flag `isServiceActive`.
                result.success(BleScanForegroundService.isServiceActive)
            }
            else -> {
                Log.w("BleScanServicePlugin", "Unknown method called from Flutter: ${call.method}") // Add warning log
                result.notImplemented() // If the method name is not recognized, return a "notImplemented" result to Flutter.
            }
        }
    }

    // Method implementation for EventChannel.StreamHandler interface.
    // This method is called when Flutter listens to an event stream.
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        // Store the EventSink in BleScanForegroundService's companion object, so the service can send data directly.
        BleScanForegroundService.eventSink = events
        Log.d("BleScanServicePlugin", "EventChannel onListen called, setting eventSink.") // Add log
    }

    // This method is called when Flutter cancels listening to an event stream.
    override fun onCancel(arguments: Any?) {
        // Clear the static reference to EventSink in BleScanForegroundService to prevent memory leaks.
        BleScanForegroundService.eventSink = null
        Log.d("BleScanServicePlugin", "EventChannel onCancel called, clearing eventSink.") // Add log
    }
}


