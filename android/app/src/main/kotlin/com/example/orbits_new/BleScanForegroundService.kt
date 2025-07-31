package com.example.orbits_new

import android.Manifest
import android.annotation.SuppressLint
import android.app.*
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.*
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.*
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel // used to send data streams from native to Flutter
import io.flutter.plugin.common.MethodCall // representing a method call from Flutter to the native side
import io.flutter.plugin.common.MethodChannel // used for communication between Flutter and native code
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject // Import JSONObject, used to construct JSON objects for sending scan results
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

class BleScanForegroundService : Service(), MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    // Companion object, used to store static members and methods
    companion object {
        var isServiceActive: Boolean = false
            private set // Private set method, can only be modified within the companion object
        private const val CHANNEL_ID = "ble_scan_channel"
        private const val NOTIFICATION_ID = 1002
        private const val TAG = "BleScanService"

        @SuppressLint("StaticFieldLeak") // Suppress warning about static field possibly causing memory leak, common usage for EventSink here
        var eventSink: EventChannel.EventSink? = null // send scan results back to Flutter
        // 新增：用于原生到 Flutter 调用的 MethodChannel，由 BleScanServicePlugin 设置
        @SuppressLint("StaticFieldLeak")
        var flutterMethodChannel: MethodChannel? = null

        // 滚动 ID 的时间间隔（分钟），必须与广播端保持一致
        const val CLOCK_DRIFT_WINDOW_MINUTES = 20L // 检查当前时间前后 +/- 20 分钟内生成的 RPI
    }

    private var bluetoothLeScanner: BluetoothLeScanner? = null
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var currentScanCallback: ScanCallback? = null

    // Scan mode parameter definitions
    private val highFrequencyScanDurationMillis = 5 * 1000L // Duration of each scan in high frequency mode (5 seconds)
    private val highFrequencyScanIntervalMillis = 10 * 1000L // Scan cycle in high frequency mode (10 seconds, scan for 5 seconds, pause for 5 seconds)

    private val lowPowerScanDurationMillis = 10 * 1000L // Duration of each scan in low power mode (10 seconds)
    private val lowPowerScanIntervalMillis = 60 * 1000L // Scan cycle in low power mode (60 seconds, scan for 10 seconds, pause for 50 seconds)

    private var currentScanMode: String = "low_power"

    private val handler = Handler(Looper.getMainLooper()) // Handler for scheduling tasks
    private var scanCycleRunnable: Runnable? = null // Runnable for periodic scan task
    private var scanDurationRunnable: Runnable? = null // Runnable for controlling single scan duration

    // Bluetooth state listener: listens for Bluetooth on/off events
    private val bluetoothStateReceiver = object : BroadcastReceiver() {
        @RequiresApi(Build.VERSION_CODES.O) // This method requires Android O (API 26) or higher
        override fun onReceive(context: Context?, intent: Intent?) {
            val action = intent?.action // Get the broadcast action
            if (BluetoothAdapter.ACTION_STATE_CHANGED == action) { // If it's a Bluetooth state changed broadcast
                val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR) // Get the current Bluetooth state
                when (state) {
                    BluetoothAdapter.STATE_OFF -> { // Bluetooth off
                        Log.w(TAG, "Bluetooth turned off. Stopping BLE scan.")
                        stopPeriodicScan() // Stop all scan activities when Bluetooth is off
                        eventSink?.error("BLUETOOTH_OFF", "Bluetooth has been turned off.", null) // Notify Flutter that Bluetooth is off
                        updateNotification("Bluetooth is off, scan stopped.") // Update foreground service notification
                    }
                    BluetoothAdapter.STATE_ON -> { // Bluetooth on
                        Log.i(TAG, "Bluetooth turned on. Resuming BLE scan.")
                        // After Bluetooth is turned on, if the service is active and permissions are granted, try to restart scanning
                        if (isServiceActive && checkBlePermissions()) {
                            initializeBluetoothComponents() // Re-initialize Bluetooth components
                            startPeriodicScan(currentScanMode) // Start periodic scan with current mode
                            updateNotification("Bluetooth is on, scan resumed.") // Update foreground service notification
                        }
                    }
                }
            }
        }
    }

    @RequiresApi(Build.VERSION_CODES.O) // This method requires Android O (API 26) or higher
    override fun onCreate() {
        super.onCreate()
        isServiceActive = true // Set static flag to true when service is created
        Log.d(TAG, "BLE Scan Service created.")

        createNotificationChannel() // Create notification channel (Android O+ required)
        startForeground(NOTIFICATION_ID, buildNotification("BLE Scan Service is running.")) // Start service as foreground service

        // Register Bluetooth state listener to respond to Bluetooth on/off
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        registerReceiver(bluetoothStateReceiver, filter)

        initializeBluetoothComponents() // Initialize Bluetooth components (adapter, scanner)
    }

    // Independent method to initialize Bluetooth components, returns true for successful initialization, false for failure
    private fun initializeBluetoothComponents(): Boolean {
        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager // Get BluetoothManager
        bluetoothAdapter = bluetoothManager.adapter // Get BluetoothAdapter

        if (bluetoothAdapter == null) { // Check if device supports Bluetooth
            Log.e(TAG, "Bluetooth not supported on this device. Stopping scan service.")
            eventSink?.error("BLUETOOTH_NOT_SUPPORTED", "Bluetooth is not supported on this device.", null) // Notify Flutter
            stopSelf() // Stop service
            return false
        }
        if (!bluetoothAdapter!!.isEnabled) { // Check if Bluetooth is enabled
            Log.w(TAG, "Bluetooth is not enabled. Cannot start BLE scan.")
            eventSink?.error("BLUETOOTH_DISABLED", "Bluetooth is not enabled.", null) // Notify Flutter
            // Do not stop service immediately, as user might enable Bluetooth later, handled by bluetoothStateReceiver
            return false
        }

        bluetoothLeScanner = bluetoothAdapter!!.bluetoothLeScanner // Get BluetoothLeScanner
        if (bluetoothLeScanner == null) { // Check if device supports BLE scanning
            Log.e(TAG, "Bluetooth LE Scanner not available. Stopping scan service.")
            eventSink?.error("BLUETOOTH_LE_NOT_AVAILABLE", "Bluetooth LE Scanner not available.", null) // Notify Flutter
            stopSelf() // Stop service
            return false
        }
        return true // Successfully initialized
    }

    @RequiresApi(Build.VERSION_CODES.O) // This method requires Android O (API 26) or higher
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "BLE Scan Service received start command.")
        intent?.let { // Handle incoming Intent
            when (it.action) {
                "ACTION_START_SCAN_SERVICE" -> { // Action to start scan service
                    if (checkBlePermissions()) { // Check permissions
                        startPeriodicScan(currentScanMode) // Start periodic scan
                        Log.d(TAG, "Initial periodic scan started with mode: $currentScanMode")
                    } else {
                        Log.e(TAG, "Missing BLE permissions to start scan service.")
                        eventSink?.error("PERMISSION_DENIED", "Missing BLUETOOTH_SCAN permission.", null) // Notify Flutter about insufficient permissions
                        stopSelf() // Stop service
                    }
                }
                "ACTION_SET_SCAN_MODE" -> { // Action to set scan mode
                    val mode = it.getStringExtra("mode") ?: "low_power" // Get mode string
                    Log.d(TAG, "Received scan mode update: $mode")
                    if (checkBlePermissions()) { // Check permissions
                        setScanModeInternal(mode) // Internal set mode
                    } else {
                        Log.e(TAG, "Missing BLE permissions to set scan mode.")
                        eventSink?.error("PERMISSION_DENIED", "Missing BLUETOOTH_SCAN permission.", null) // Notify Flutter about insufficient permissions
                    }
                }
                else -> { // Handle unknown actions
                    Log.w(TAG, "Received unknown action: ${it.action}. Ignoring.")
                    // If service is restarted by system, and permissions are granted, resume scan
                    if (checkBlePermissions()) {
                        startPeriodicScan(currentScanMode)
                    } else {
                        Log.e(TAG, "Service restarted by system, but missing BLE permissions.")
                        eventSink?.error("PERMISSION_DENIED", "Service restarted without necessary permissions.", null)
                    }
                }
            }
        } ?: run { // If Intent is null (e.g., system restarts service)
            if (checkBlePermissions()) { // Check permissions
                startPeriodicScan(currentScanMode) // Start periodic scan
                Log.d(TAG, "Service restarted by system, resuming scan with mode: $currentScanMode")
            } else {
                Log.e(TAG, "Service restarted by system, but missing BLE permissions.")
                eventSink?.error("PERMISSION_DENIED", "Service restarted without necessary permissions.", null)
            }
        }
        return START_STICKY // Attempt to restart service after it's killed
    }

    @RequiresApi(Build.VERSION_CODES.O) // This method requires Android O (API 26) or higher
    override fun onDestroy() {
        super.onDestroy()
        isServiceActive = false // Set static flag to false when service is destroyed
        stopPeriodicScan() // Stop all scan activities
        unregisterReceiver(bluetoothStateReceiver) // Unregister Bluetooth state listener to prevent memory leaks
        Log.d(TAG, "BLE Scan Service stopped.")
    }

    override fun onBind(intent: Intent?): IBinder? {
        // This service is not for binding, return null.
        // MethodChannel and EventChannel binding is handled in BleScanServicePlugin.
        return null
    }

    // Method implementing MethodChannel.MethodCallHandler interface
    @RequiresApi(Build.VERSION_CODES.O) // This method requires Android O (API 26) or higher
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startScanService" -> { // Flutter requests to start scan service
                if (checkBlePermissions()) { // Check permissions
                    startPeriodicScan(currentScanMode)
                    result.success(true)
                } else {
                    result.error("PERMISSION_DENIED", "BLUETOOTH_SCAN permission not granted.", null) // Return error to Flutter
                }
            }
            "stopScanService" -> { // Flutter requests to stop scan service
                stopPeriodicScan()
                result.success(true)
            }
            "setScanMode" -> { // Flutter requests to set scan mode
                val mode = call.argument<String>("mode") ?: "low_power"
                if (checkBlePermissions()) { // Check permissions
                    setScanModeInternal(mode)
                    result.success(true)
                } else {
                    result.error("PERMISSION_DENIED", "BLUETOOTH_SCAN permission not granted.", null) // Return error to Flutter
                }
            }
            "isServiceRunning" -> { // Flutter requests to query if service is running
                result.success(isServiceActive) // Return status of static flag
            }
            else -> result.notImplemented() // Unknown method
        }
    }

    // Method implementing EventChannel.StreamHandler interface
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        Log.d(TAG, "EventChannel onListen called, setting eventSink.")
        eventSink = events // Store EventSink to send scan results to Flutter
    }

    override fun onCancel(arguments: Any?) {
        Log.d(TAG, "EventChannel onCancel called, clearing eventSink.")
        eventSink = null // Clear EventSink to prevent memory leaks
    }

    // Internal method: set scan mode and restart scan
    @RequiresApi(Build.VERSION_CODES.O) // This method requires Android O (API 26) or higher
    private fun setScanModeInternal(mode: String) {
        if (currentScanMode != mode) { // If mode changes
            currentScanMode = mode // Update current mode
            Log.d(TAG, "Internal scan mode updated to: $currentScanMode")
            if (checkBlePermissions()) { // Check permissions again
                stopPeriodicScan() // Stop current scan cycle
                startPeriodicScan(currentScanMode) // Start new cycle with new mode
            } else {
                Log.e(TAG, "Missing BLE permissions to restart scan with new mode.")
                eventSink?.error("PERMISSION_DENIED", "Missing BLUETOOTH_SCAN permission.", null)
            }
        }
    }

    // Internal method: start periodic scan (includes one scan and one pause)
    @RequiresApi(Build.VERSION_CODES.O) // This method requires Android O (API 26) or higher
    private fun startPeriodicScan(mode: String) {
        // Before starting scan, perform final Bluetooth component and permission checks
        if (!initializeBluetoothComponents()) {
            Log.e(TAG, "Bluetooth components not ready, cannot start periodic scan.")
            return
        }
        if (!checkBlePermissions()) {
            Log.e(TAG, "Missing BLE permissions, cannot start periodic scan.")
            eventSink?.error("PERMISSION_DENIED", "Missing BLUETOOTH_SCAN permission.", null)
            return
        }

        stopPeriodicScan() // Ensure old cycle is stopped before starting a new one

        val scanDuration = if (mode == "high_frequency") highFrequencyScanDurationMillis else lowPowerScanDurationMillis
        val scanInterval = if (mode == "high_frequency") highFrequencyScanIntervalMillis else lowPowerScanIntervalMillis

        Log.d(TAG, "Starting periodic scan: Mode=$mode, Duration=${scanDuration}ms, Interval=${scanInterval}ms")

        startActualBleScan(scanDuration) // Start actual BLE scan

        // Set scan cycle timer to restart scan after scanInterval
        scanCycleRunnable = Runnable {
            // Only continue to the next cycle if service is still active, permissions are granted, and Bluetooth is enabled
            if (isServiceActive && checkBlePermissions() && bluetoothAdapter?.isEnabled == true) {
                startPeriodicScan(currentScanMode)
            } else {
                Log.w(TAG, "Service not active, permissions missing, or Bluetooth off. Stopping periodic scan cycle.")
                stopPeriodicScan() // If conditions are not met, stop periodic scan
            }
        }
        handler.postDelayed(scanCycleRunnable!!, scanInterval) // Schedule next periodic scan
    }

    // Internal method: stop all scans and timers
    @SuppressLint("MissingPermission") // Suppress warning, as we will perform permission checks externally
    private fun stopPeriodicScan() {
        // Precisely remove specific Runnables from Handler to avoid affecting other tasks
        handler.removeCallbacks(scanCycleRunnable ?: Runnable {})
        handler.removeCallbacks(scanDurationRunnable ?: Runnable {})

        // Only stop BLE scan if scanner and callback exist and permissions are available
        if (bluetoothLeScanner != null && currentScanCallback != null) {
            if (checkBlePermissions()) { // Check permissions every time before stopping scan
                bluetoothLeScanner?.stopScan(currentScanCallback)
                Log.d(TAG, "BLE scan stopped.")
            } else {
                Log.w(TAG, "BLUETOOTH_SCAN permission not granted, cannot stop BLE scan gracefully.")
            }
        } else {
            Log.d(TAG, "No active BLE scan to stop or scanner/callback is null.")
        }
        currentScanCallback = null // Clear current scan callback reference
        Log.d(TAG, "Stopped all scan handlers.")
    }

    // Internal method: start actual BLE scan
    @RequiresApi(Build.VERSION_CODES.M) // This method requires Android M (API 23) or higher
    @SuppressLint("MissingPermission") // Suppress warning, as we will perform permission checks externally
    private fun startActualBleScan(durationMillis: Long) {
        // Before starting actual scan, perform final permission and Bluetooth state checks
        if (!checkBlePermissions() || bluetoothLeScanner == null || bluetoothAdapter?.isEnabled != true) {
            Log.e(TAG, "Cannot start actual BLE scan: missing permissions, scanner not available, or Bluetooth is off.")
            eventSink?.error("SCAN_INIT_FAILED", "Failed to initialize BLE scan due to permissions or Bluetooth state.", null)
            stopPeriodicScan() // If unable to start, stop periodic scan
            return
        }

        // Ensure no ongoing scan, stop old scan before starting a new one
        bluetoothLeScanner?.stopScan(currentScanCallback)

        val scanSettings = ScanSettings.Builder()
            .setScanMode(if (currentScanMode == "high_frequency") ScanSettings.SCAN_MODE_LOW_LATENCY else ScanSettings.SCAN_MODE_LOW_POWER) // Set scan mode based on current mode
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES) // Report all matching advertisement packets
            .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE) // Aggressive matching mode
            .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT) // Report all advertisements
            .setReportDelay(0L) // Report results immediately (no batch reporting)
            .build()

        // ScanFilter for filtering specific devices. Currently an empty list, meaning scan all devices.
        val scanFilter = listOf(ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(BleBroadcastService.APP_SERVICE_UUID))
            .build())
        val filters = listOf(scanFilter) // Add filter to the list
//        val scanFilters = listOf<ScanFilter>() // Temporarily no filters, scan all devices

        currentScanCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {

                super.onScanResult(callbackType, result)
                result?.let { scanResult ->
                    val scanRecord = scanResult.scanRecord
                    // Check if scanRecord contains Service Data for our APP_SERVICE_UUID
                    val serviceDataBytes = scanRecord?.getServiceData(ParcelUuid(BleBroadcastService.APP_SERVICE_UUID))

                    if (serviceDataBytes != null && serviceDataBytes.isNotEmpty()) {
                        try {
                            // "Decrypt" Service Data (rolling ID) back to original user UUID
                            val originalUserUUID = serviceDataBytes.bytesToUUID()
                            val rssi = scanResult.rssi

                            Log.d(TAG, "Device discovered: UUID: $originalUserUUID, RSSI: $rssi")

                            // Send results to Flutter
                            val jsonResult = JSONObject().apply {
                                put("uuid", originalUserUUID.toString())
                                put("rssi", rssi)
                            }.toString()

                            // Ensure eventSink is not null and service is active
                            eventSink?.success(jsonResult)
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to parse Service Data: ${e.message}")
                            eventSink?.error("DATA_PARSE_ERROR", "Unable to parse Bluetooth data", e.message)
                        }
                    } else {
                        Log.d(TAG, "Device discovered, but no App Service Data or empty.")
                    }
                }
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>?) {
                super.onBatchScanResults(results)

                // For reportDelay = 0, this method is usually not called
                // If you set reportDelay, you need to handle batch results here
                results?.forEach { result ->
                    val scanRecord = result.scanRecord
                    val serviceDataBytes = scanRecord?.getServiceData(ParcelUuid(BleBroadcastService.APP_SERVICE_UUID))
                    if (serviceDataBytes != null && serviceDataBytes.isNotEmpty()) {
                        try {
                            val originalUserUUID = serviceDataBytes.bytesToUUID()
                            val rssi = result.rssi
                            Log.d(TAG, "Batch device discovered: UUID: $originalUserUUID, RSSI: $rssi")
                            val jsonResult = JSONObject().apply {
                                put("uuid", originalUserUUID.toString())
                                put("rssi", rssi)
                            }.toString()
                            eventSink?.success(jsonResult)
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to parse batch Service Data: ${e.message}")
                        }
                    }
                }
            }

            override fun onScanFailed(errorCode: Int) {
                super.onScanFailed(errorCode)
                Log.e(TAG, "BLE Scan Failed: $errorCode")
                val errorMessage = when (errorCode) {
                    ScanCallback.SCAN_FAILED_ALREADY_STARTED -> "Scan already started."
                    ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED -> "Application registration failed."
                    ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED -> "Feature unsupported."
                    ScanCallback.SCAN_FAILED_INTERNAL_ERROR -> "Internal error."
                    // Fix: ScanCallback.SCAN_FAILED_OUT_OF_RESOURCES is no longer a public constant in the latest SDK, use its integer value 5 directly
                    5 -> "Out of resources."
                    else -> "Unknown scan failure."
                }
                eventSink?.error("SCAN_FAILED", "BLE scan failed: $errorMessage (Code: $errorCode)", null) // Notify Flutter about scan failure
                stopPeriodicScan() // Stop periodic scan on scan failure
                updateNotification("BLE scan failed, please check Bluetooth.") // Update foreground service notification
            }
        }

        bluetoothLeScanner?.startScan(scanFilter, scanSettings, currentScanCallback) // Start BLE scan
        Log.d(TAG, "Actual BLE scan started for ${durationMillis / 1000} seconds.")
        updateNotification("BLE Scan Service is running (${currentScanMode} mode).") // Update foreground service notification, show current mode

        // Set a timer to stop the current scan, to achieve scan duration
        scanDurationRunnable = Runnable {
            if (checkBlePermissions()) { // Check permissions again before stopping
                bluetoothLeScanner?.stopScan(currentScanCallback)
                Log.d(TAG, "Actual BLE scan stopped (duration reached).")
            } else {
                Log.w(TAG, "Missing BLE permissions, cannot stop BLE scan gracefully after duration.")
            }
        }
        handler.postDelayed(scanDurationRunnable!!, durationMillis) // Schedule stop scan task
    }

    @RequiresApi(Build.VERSION_CODES.O) // This method requires Android O (API 26) or higher
    private fun buildNotification(content: String): Notification {
        // Create an intent that, when the user clicks the notification, can return to your main Activity
        // Class.forName("com.example.orbits_application.MainActivity") dynamically gets the main Activity class
        val notificationIntent = Intent(this, Class.forName("com.example.orbits_new.MainActivity"))
        val pendingIntentFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT // Set PendingIntent flags
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pendingIntent = PendingIntent.getActivity(this, 0, notificationIntent, pendingIntentFlags) // Create PendingIntent

        return NotificationCompat.Builder(this, CHANNEL_ID) // Use NotificationCompat for compatibility builder
            .setContentTitle("BLE Scan Service Active") // Notification title
            .setContentText(content) // Notification content
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth) // Small icon (can be replaced with your app icon)
            .setContentIntent(pendingIntent) // Set intent after clicking notification
            .setPriority(NotificationCompat.PRIORITY_LOW) // Set notification priority, matching channel importance
            .build() // Build notification
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) { // Only create channel on Android O (API 26) and higher
            val channel = NotificationChannel(
                CHANNEL_ID, // Channel ID
                "BLE Scan Channel", // Channel name
                NotificationManager.IMPORTANCE_LOW // Channel importance level (low, silent notification)
            )
            val manager = getSystemService(NotificationManager::class.java) // Get NotificationManager
            manager.createNotificationChannel(channel) // Create notification channel
        }
    }

    // Update foreground service notification content
    private fun updateNotification(content: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) { // Only update notification on Android O (API 26) and higher
            val notification = buildNotification(content) // Build new notification
            val manager = getSystemService(NotificationManager::class.java) // Get NotificationManager
            manager.notify(NOTIFICATION_ID, notification) // Update notification
        }
    }

    // Helper method to check BLE permissions
    private fun checkBlePermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) { // Android 12 (API 31) and higher
            // Requires BLUETOOTH_SCAN and BLUETOOTH_CONNECT permissions
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
                    ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        } else { // Android 11 (API 30) and lower
            // Requires ACCESS_FINE_LOCATION permission
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }

    /**
     * "Decrypts" a byte array back to the original UUID.
     * This corresponds to the simple reverse operation in the `generateRollingId` function on the broadcast side.
     *
     * @param bytes The received Service Data byte array (i.e., the "encrypted" UUID bytes).
     * @return The restored original UUID.
     */
    private fun ByteArray.bytesToUUID(): UUID {
        // Decryption: reverse the byte array again to restore the original UUID bytes
        // This is because the broadcast side used reversedArray() for "encryption"
        val originalUuidBytes = this.reversedArray()

        val bb = ByteBuffer.wrap(originalUuidBytes)
        val high = bb.long
        val low = bb.long
        return UUID(high, low)
    }
}


