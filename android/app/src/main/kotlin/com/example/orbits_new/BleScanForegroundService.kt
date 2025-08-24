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
import androidx.annotation.RequiresPermission
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

// Extension function for logging byte arrays
fun ByteArray.toHexString() = joinToString("") { "%02x".format(it) }


class BleScanForegroundService : Service(), MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    // Companion object, used to store static members and methods
    companion object {
        var isServiceActive: Boolean = false
            private set // Private set method, can only be modified within the companion object
        private const val CHANNEL_ID = "ble_scan_channel"
        private const val NOTIFICATION_ID = 1002
        private const val TAG = "BleScanService"

        // 与广播端保持一致的常量
        private const val ROLLING_ID_INTERVAL_MINUTES = 15L
        private const val HMAC_ALGORITHM = "HmacSha256"

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

    // 从 Flutter 端获取的密钥和已知用户列表
    private lateinit var secretKey: String
    private lateinit var knownUserUUIDs: List<String>

    // Bluetooth state listener: listens for Bluetooth on/off events
    private val bluetoothStateReceiver = object : BroadcastReceiver() {
        @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
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
                            // 只有在接收到来自Flutter的密钥和UUID列表后才开始扫描
                            if (::secretKey.isInitialized && ::knownUserUUIDs.isInitialized) {
                                startPeriodicScan(currentScanMode) // Start periodic scan with current mode
                            }
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

        // Bluetooth初始化现在被推迟到从Flutter接收到密钥和UUID列表之后
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

//    @RequiresApi(Build.VERSION_CODES.O) // This method requires Android O (API 26) or higher

    @RequiresApi(Build.VERSION_CODES.O)
    @androidx.annotation.RequiresPermission(android.Manifest.permission.BLUETOOTH_SCAN)
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "BLE Scan Service received start command.")
        // Intent-based commands are now handled via MethodChannel for a more unified approach
        // 处理从Intent传递的参数
        intent?.let  {
            when (it.action) {
                "ACTION_START_SCAN_SERVICE" -> {
                    val secretKey = it.getStringExtra("secretKey")
                    val knownUserUUIDs = it.getStringArrayListExtra("knownUserUUIDs")

                    Log.d(TAG, "Received parameters from Intent - secretKey length: ${secretKey?.length}")
                    Log.d(TAG, "Received parameters from Intent - knownUserUUIDs count: ${knownUserUUIDs?.size}")

                    if (!secretKey.isNullOrEmpty() && knownUserUUIDs != null) {
                        this.secretKey = secretKey
                        this.knownUserUUIDs = knownUserUUIDs

                        // 设置MethodChannel处理器
                        flutterMethodChannel?.setMethodCallHandler(this)

                        // 开始扫描
                        if (checkBlePermissions()) {
                            Log.d(TAG, "Permissions granted. Starting scan with received parameters.")
                            initializeBluetoothComponents()
                            startPeriodicScan(currentScanMode)
                        } else {
                            Log.e(TAG, "Permission denied. Cannot start scan.")
                        }
                    } else {
                        Log.e(TAG, "Missing parameters in Intent")
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
    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
    @RequiresApi(Build.VERSION_CODES.O) // This method requires Android O (API 26) or higher
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startScanService" -> { // Flutter requests to start scan service
                val args = call.arguments as Map<String, Any>
                val userUUIDs = args["userUUIDs"] as List<String>?
                val secretKey = args["secretKey"] as String?

                // 新增：如果mode参数也存在，则更新扫描模式
                val mode = args["mode"] as String?

                if (secretKey.isNullOrEmpty()) {
                    result.error("KEY_ERROR", "Secret key is missing.", null)
                    stopSelf()
                    return
                }

                // knownUserUUIDs可以为空（用户第一次使用应用时）
                if (userUUIDs == null) {
                    result.error("KEY_ERROR", "UserUUIDs cannot be null.", null)
                    stopSelf()
                    return
                }

                this.secretKey = secretKey
                this.knownUserUUIDs = userUUIDs
                if (mode != null) {
                    this.currentScanMode = mode
                }

                if (checkBlePermissions()) { // Check permissions
                    Log.d(TAG, "Permissions granted. Proceeding to start scan.")
                    initializeBluetoothComponents() // 初始化蓝牙组件
                    startPeriodicScan(currentScanMode)
                    result.success(true)
                } else {
                    Log.e(TAG, "Permission denied. Cannot start scan.")
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
    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
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
    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
    @RequiresApi(Build.VERSION_CODES.O) // This method requires Android O (API 26) or higher
    private fun startPeriodicScan(mode: String) {
        // 【修改点 1】：在方法入口处添加日志，确认它被调用了
        Log.d(TAG, "Entering startPeriodicScan with mode: $mode")
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

        // 【新增】：检查密钥是否已初始化，这是关键
        if (!::secretKey.isInitialized) {
            Log.e(TAG, "Secret key not initialized. Cannot start scan.")
            eventSink?.error("KEY_NOT_INITIALIZED", "Secret key not received from Flutter.", null)
            return
        }

        // knownUserUUIDs可以为空（用户第一次使用应用时），但必须已初始化
        if (!::knownUserUUIDs.isInitialized) {
            Log.e(TAG, "KnownUserUUIDs not initialized. Cannot start scan.")
            eventSink?.error("KEY_NOT_INITIALIZED", "KnownUserUUIDs not received from Flutter.", null)
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
                // 【修改点 2】：添加日志，确认下一个扫描周期被调度
                Log.d(TAG, "Scan cycle completed, scheduling next periodic scan.")
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
    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
    private fun startActualBleScan(durationMillis: Long) {
        Log.d(TAG, "Starting actual BLE scan for ${durationMillis / 1000} seconds")

        if (bluetoothLeScanner == null) {
            Log.e(TAG, "BluetoothLeScanner is null, cannot start scan")
            return
        }

        val scanSettings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
            .setReportDelay(0L)
            .build()

        // 添加扫描过滤器，只扫描包含我们服务UUID的设备
        val scanFilter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(BleBroadcastService.APP_SERVICE_UUID))
            .build()

        val scanFilters = listOf(scanFilter)

        Log.d(TAG, "Scan settings created with filter for UUID: ${BleBroadcastService.APP_SERVICE_UUID}")
        Log.d(TAG, "Starting scan with filter...")

        currentScanCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                super.onScanResult(callbackType, result)
                Log.d(TAG, "=== SCAN RESULT RECEIVED ===")
                Log.d(TAG, "Callback type: $callbackType")

                result?.let { scanResult ->
                    val scanRecord = scanResult.scanRecord
                    val deviceAddress = scanResult.device.address
                    val rssi = scanResult.rssi

                    Log.d(TAG, "Raw scan result - Device: $deviceAddress, RSSI: $rssi")

                    // 由于使用了扫描过滤器，这里应该总是包含我们的服务UUID
                    val serviceUuids = scanRecord?.serviceUuids
                    Log.d(TAG, "Service UUIDs found: ${serviceUuids?.size ?: 0}")

                    val hasOurService = serviceUuids?.any { it.uuid == BleBroadcastService.APP_SERVICE_UUID } == true
                    Log.d(TAG, "Has our service UUID: $hasOurService")

                    if (hasOurService) {
                        Log.d(TAG, "Found our service UUID for device: $deviceAddress")

                        // 检查是否有Manufacturer Data
                        val manufacturerData = scanRecord?.manufacturerSpecificData

                        if (manufacturerData != null && manufacturerData.size() > 0) {
                            // 查找我们的Company ID (0x3412)
                            val ourData = manufacturerData.get(0x3412)
                            if (ourData != null && ourData.size >= 4) {
                                Log.d(TAG, "Found manufacturer data, payload size: ${ourData.size}")

                                // 提取rolling ID（后2字节）
                                val rollingIdPayload = ourData.copyOfRange(2, 4)
                                Log.d(TAG, "Extracted rolling ID payload, size: ${rollingIdPayload.size}")

                                val decryptedUUID = validateRollingId(rollingIdPayload, secretKey, knownUserUUIDs)

                                if (decryptedUUID != null) {
                                    Log.d(TAG, "Device discovered and validated: UUID: $decryptedUUID, RSSI: $rssi")

                                    val jsonResult = JSONObject().apply {
                                        put("uuid", decryptedUUID)
                                        put("rssi", rssi)
                                        put("secretKey", secretKey)
                                    }.toString()

                                    eventSink?.success(jsonResult)
                                    Log.d(TAG, "Sent scan result to Flutter: $jsonResult")
                                } else {
                                    Log.d(TAG, "Device discovered, but rolling ID validation failed.")
                                    Log.d(TAG, "Skipping unvalidated device - only known devices are recorded")
                                    // 不再发送未验证的设备到Flutter
                                }
                            } else {
                                Log.d(TAG, "Device discovered with our service UUID, but no valid manufacturer data.")
                                Log.d(TAG, "This should not happen with proper broadcast configuration.")
                            }
                        } else {
                            Log.d(TAG, "Device discovered with our service UUID, but no manufacturer data.")
                            Log.d(TAG, "This should not happen with proper broadcast configuration.")
                        }
                    } else {
                        Log.d(TAG, "Unexpected: Device passed filter but doesn't have our service UUID. Device: $deviceAddress")
                    }
                }
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>?) {
                super.onBatchScanResults(results)
                Log.d(TAG, "Batch scan results received: ${results?.size ?: 0} devices")
            }

            override fun onScanFailed(errorCode: Int) {
                super.onScanFailed(errorCode)
                val errorMessage = when (errorCode) {
                    SCAN_FAILED_ALREADY_STARTED -> "Scan already started"
                    SCAN_FAILED_APPLICATION_REGISTRATION_FAILED -> "Application registration failed"
                    SCAN_FAILED_FEATURE_UNSUPPORTED -> "Feature unsupported"
                    SCAN_FAILED_INTERNAL_ERROR -> "Internal error"
//                    SCAN_FAILED_INVALID_SCAN -> "Invalid scan"
                    else -> "Unknown error: $errorCode"
                }
                Log.e(TAG, "Scan failed: $errorMessage")
                eventSink?.error("SCAN_FAILED", errorMessage, null)
            }
        }

        // 启动扫描，使用过滤器
        bluetoothLeScanner?.startScan(scanFilters, scanSettings, currentScanCallback)

        // 设置扫描持续时间
        scanDurationRunnable = Runnable {
            if (currentScanCallback != null) {
                Log.d(TAG, "Scan duration completed, stopping scan")
                bluetoothLeScanner?.stopScan(currentScanCallback)
                currentScanCallback = null
            }
        }
        handler.postDelayed(scanDurationRunnable!!, durationMillis)
    }
//    private fun startActualBleScan(durationMillis: Long) {
//        // 【修改点 3】：在方法入口处添加日志，确认它被调用了
//        Log.d(TAG, "Starting actual BLE scan for ${durationMillis / 1000} seconds")
//        Log.d(TAG, "Entering startActualBleScan. Duration: ${durationMillis}ms")
//        // Before starting actual scan, perform final permission and Bluetooth state checks
//        if (!checkBlePermissions() || bluetoothLeScanner == null || bluetoothAdapter?.isEnabled != true) {
//            Log.e(TAG, "Cannot start actual BLE scan: missing permissions, scanner not available, or Bluetooth is off.")
//            eventSink?.error("SCAN_INIT_FAILED", "Failed to initialize BLE scan due to permissions or Bluetooth state.", null)
//            stopPeriodicScan() // If unable to start, stop periodic scan
//            return
//        }
//
//        if (!::secretKey.isInitialized || !::knownUserUUIDs.isInitialized) {
//            Log.e(TAG, "Secret key or known UUIDs not initialized. Cannot start scan.")
//            eventSink?.error("KEY_NOT_INITIALIZED", "Secret key or known UUIDs not received from Flutter.", null)
//            stopPeriodicScan()
//            return
//        }
//
//        // 停止上一次扫描，确保新扫描能正常开始
//        if (currentScanCallback != null) {
//            bluetoothLeScanner?.stopScan(currentScanCallback)
//        }
//
//        val scanSettings = ScanSettings.Builder()
//            .setScanMode(if (currentScanMode == "high_frequency") ScanSettings.SCAN_MODE_LOW_LATENCY else ScanSettings.SCAN_MODE_LOW_POWER) // Set scan mode based on current mode
//            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES) // Report all matching advertisement packets
//            .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE) // Aggressive matching mode
//            .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT) // Report all advertisements
//            .setReportDelay(0L) // Report results immediately (no batch reporting)
//            .build()
//
//        // ScanFilter for filtering specific devices. Currently an empty list, meaning scan all devices.
//        // 临时注释掉ScanFilter，扫描所有设备
////        val scanFilter = listOf(ScanFilter.Builder()
////            .setServiceUuid(ParcelUuid(BleBroadcastService.APP_SERVICE_UUID))
////            .build())
//
//        // 使用空的scanFilter列表
//        val scanFilter = emptyList<ScanFilter>()
//
//        bluetoothLeScanner?.startScan(scanFilter, scanSettings, currentScanCallback)
//
//        currentScanCallback = object : ScanCallback() {
//
//            override fun onScanResult(callbackType: Int, result: ScanResult) {
//                super.onScanResult(callbackType, result)
//                result?.let { scanResult ->
//                    val scanRecord = scanResult.scanRecord
//                    val deviceAddress = scanResult.device.address
//                    val rssi = scanResult.rssi
//
//                    Log.d(TAG, "Raw scan result - Device: $deviceAddress, RSSI: $rssi")
//
//                    // 检查是否包含我们的服务UUID
//                    val serviceUuids = scanRecord?.serviceUuids
//                    val hasOurService = serviceUuids?.any { it.uuid == BleBroadcastService.APP_SERVICE_UUID } == true
//
//                    if (hasOurService) {
//                        Log.d(TAG, "Found our service UUID for device: $deviceAddress")
//
//                        // 检查是否有服务数据（滚动ID）
//                        val rollingIdPayload = scanRecord?.getServiceData(ParcelUuid(BleBroadcastService.APP_SERVICE_UUID))
//
//                        if (rollingIdPayload != null && rollingIdPayload.isNotEmpty()) {
//                            Log.d(TAG, "Found service data, payload size: ${rollingIdPayload.size}")
//
//                            // 尝试验证滚动ID
//                            val decryptedUUID = validateRollingId(rollingIdPayload, secretKey, knownUserUUIDs)
//
//                            if (decryptedUUID != null) {
//                                Log.d(TAG, "Device discovered and validated: UUID: $decryptedUUID, RSSI: $rssi")
//
//                                val jsonResult = JSONObject().apply {
//                                    put("uuid", decryptedUUID)
//                                    put("rssi", rssi)
//                                    put("secretKey", secretKey)
//                                }.toString()
//
//                                eventSink?.success(jsonResult)
//                                Log.d(TAG, "Sent scan result to Flutter: $jsonResult")
//                            } else {
//                                Log.d(TAG, "Device discovered, but rolling ID validation failed.")
//                            }
//                        } else {
//                            Log.d(TAG, "Device discovered with our service UUID, but no service data. Using device address as identifier.")
//
//                            // 临时方案：使用设备地址作为标识
//                            // 检查这个设备地址是否在已知UUID列表中
//                            val knownDevice = knownUserUUIDs.find { uuid ->
//                                // 这里可以添加一个映射逻辑，将设备地址映射到UUID
//                                // 暂时使用设备地址作为UUID
//                                uuid == deviceAddress
//                            }
//
//                            val jsonResult = JSONObject().apply {
//                                put("uuid", deviceAddress) // 使用设备地址作为临时UUID
//                                put("rssi", rssi)
//                                put("secretKey", "temp_key") // 临时密钥
//                            }.toString()
//
//                            eventSink?.success(jsonResult)
//                            Log.d(TAG, "Sent scan result for device with only service UUID: $jsonResult")
//                        }
//                    } else {
//                        Log.d(TAG, "Device discovered, but no our service UUID. Device: $deviceAddress")
//                    }
//                }
//            }
////            override fun onScanResult(callbackType: Int, result: ScanResult) {
////
////                super.onScanResult(callbackType, result)
////                result?.let { scanResult ->
////                    val scanRecord = scanResult.scanRecord
////                    val deviceAddress = scanResult.device.address
////                    val rssi = scanResult.rssi
////                    // 添加调试日志
////                    Log.d(TAG, "Raw scan result - Device: $deviceAddress, RSSI: $rssi")
////
////                    // Check if scanRecord contains Service Data for our APP_SERVICE_UUID
////                    val rollingIdPayload = scanRecord?.getServiceData(ParcelUuid(BleBroadcastService.APP_SERVICE_UUID))
////
////                    if (rollingIdPayload != null && rollingIdPayload.isNotEmpty()) {
////                        Log.d(TAG, "Found service data for our UUID, payload size: ${rollingIdPayload.size}")
////
////                        // 使用新的验证逻辑来“解密”滚动 ID
////                        val decryptedUUID = validateRollingId(rollingIdPayload, secretKey, knownUserUUIDs)
////
////                        if (decryptedUUID != null) {
//////                            val rssi = scanResult.rssi
////                            Log.d(TAG, "Device discovered and validated: UUID: $decryptedUUID, RSSI: $rssi")
////
////                            // Send results to Flutter
////                            val jsonResult = JSONObject().apply {
////                                put("uuid", decryptedUUID)
////                                put("rssi", rssi)
////                                put("secretKey", secretKey) // 添加secretKey
////                            }.toString()
////                            // Ensure eventSink is not null and service is active
////                            eventSink?.success(jsonResult)
////                            Log.d(TAG, "Sent scan result to Flutter: $jsonResult")
////                        } else {
////                            Log.d(TAG, "Device discovered, but rolling ID validation failed.")
////                        }
////                    } else {
////                        Log.d(TAG, "Device discovered, but no App Service Data or empty. Device: $deviceAddress")
////                    }
////                }
////            }
//
//            override fun onBatchScanResults(results: MutableList<ScanResult>?) {
//                super.onBatchScanResults(results)
//
//                // For reportDelay = 0, this method is usually not called
//                // If you set reportDelay, you need to handle batch results here
//                results?.forEach { result ->
//                    val scanRecord = result.scanRecord
//                    val rollingIdPayload = scanRecord?.getServiceData(ParcelUuid(BleBroadcastService.APP_SERVICE_UUID))
//
//                    if (rollingIdPayload != null && rollingIdPayload.isNotEmpty()) {
//                        val decryptedUUID = validateRollingId(rollingIdPayload, secretKey, knownUserUUIDs)
//
//                        if (decryptedUUID != null) {
//                            val rssi = result.rssi
//                            Log.d(TAG, "Batch device discovered and validated: UUID: $decryptedUUID, RSSI: $rssi")
//                            val jsonResult = JSONObject().apply {
//                                put("uuid", decryptedUUID)
//                                put("rssi", rssi)
//                            }.toString()
//                            eventSink?.success(jsonResult)
//                        }
//                    }
//                }
//            }
//
//            override fun onScanFailed(errorCode: Int) {
//                super.onScanFailed(errorCode)
//                Log.e(TAG, "BLE Scan Failed: $errorCode")
//                val errorMessage = when (errorCode) {
//                    ScanCallback.SCAN_FAILED_ALREADY_STARTED -> "Scan already started."
//                    ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED -> "Application registration failed."
//                    ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED -> "Feature unsupported."
//                    ScanCallback.SCAN_FAILED_INTERNAL_ERROR -> "Internal error."
//                    // Fix: ScanCallback.SCAN_FAILED_OUT_OF_RESOURCES is no longer a public constant in the latest SDK, use its integer value 5 directly
//                    5 -> "Out of resources."
//                    else -> "Unknown scan failure."
//                }
//                eventSink?.error("SCAN_FAILED", "BLE scan failed: $errorMessage (Code: $errorCode)", null) // Notify Flutter about scan failure
//                stopPeriodicScan() // Stop periodic scan on scan failure
//                updateNotification("BLE scan failed, please check Bluetooth.") // Update foreground service notification
//            }
//        }
//
//        bluetoothLeScanner?.startScan(scanFilter, scanSettings, currentScanCallback) // Start BLE scan
//        Log.d(TAG, "Actual BLE scan started for ${durationMillis / 1000} seconds.")
//        updateNotification("BLE Scan Service is running (${currentScanMode} mode).") // Update foreground service notification, show current mode
//
//        // Set a timer to stop the current scan, to achieve scan duration
//        scanDurationRunnable = Runnable {
//            if (checkBlePermissions()) { // Check permissions again before stopping
//                bluetoothLeScanner?.stopScan(currentScanCallback)
//                Log.d(TAG, "Actual BLE scan stopped (duration reached).")
//            } else {
//                Log.w(TAG, "Missing BLE permissions, cannot stop BLE scan gracefully after duration.")
//            }
//        }
//        handler.postDelayed(scanDurationRunnable!!, durationMillis) // Schedule stop scan task
//    }

    /**
     * Verifies a rolling ID against a list of known UUIDs and a secret key.
     * This method accounts for potential clock drift by checking a time window.
     *
     * @param rollingIdPayload The received rolling ID (Service Data) from the BLE advertisement.
     * @param secretKey The pre-shared secret key for HMAC verification.
     * @param knownUserUUIDs A list of all user UUIDs to check against.
     * @return The original UUID string if a match is found, otherwise null.
     */
    private fun validateRollingId(rollingIdPayload: ByteArray, secretKey: String, knownUserUUIDs: List<String>): String? {
        // 确保输入是2字节（最小化格式）
        if (rollingIdPayload.size != 2) {
            Log.w(TAG, "Invalid rolling ID payload size: ${rollingIdPayload.size}, expected 2 bytes")
            return null
        }

        Log.d(TAG, "=== ROLLING ID VALIDATION START ===")
        Log.d(TAG, "Received rolling ID payload: ${rollingIdPayload.toHexString()}")
        Log.d(TAG, "Secret key length: ${secretKey.length}")
        Log.d(TAG, "Known UUIDs count: ${knownUserUUIDs.size}")
        Log.d(TAG, "Known UUIDs: $knownUserUUIDs")

        val now = System.currentTimeMillis()
        val driftWindowMillis = CLOCK_DRIFT_WINDOW_MINUTES * 60 * 1000L
        val intervalLengthMillis = ROLLING_ID_INTERVAL_MINUTES * 60 * 1000L

        // Calculate the current interval index and the check window
        val currentInterval = now / intervalLengthMillis
        val startInterval = (now - driftWindowMillis) / intervalLengthMillis
        val endInterval = (now + driftWindowMillis) / intervalLengthMillis

        Log.d(TAG, "Current time: $now")
        Log.d(TAG, "Current interval: $currentInterval")
        Log.d(TAG, "Checking intervals from $startInterval to $endInterval")

        val secretKeyBytes = secretKey.toByteArray(StandardCharsets.UTF_8)
        val hmacSha256 = Mac.getInstance(HMAC_ALGORITHM)
        val secretKeySpec = SecretKeySpec(secretKeyBytes, HMAC_ALGORITHM)

        try {
            hmacSha256.init(secretKeySpec)

            // Iterate through each known UUID
            for (uuid in knownUserUUIDs) {
                Log.d(TAG, "Checking UUID: $uuid")
                // Iterate through the time window to account for clock drift
                for (i in startInterval..endInterval) {
                    val message = "$uuid:$i".toByteArray(StandardCharsets.UTF_8)
                    val generatedHash = hmacSha256.doFinal(message)

                    // Check if the received payload matches the generated hash
                    // 只比较前2字节（最小化格式）
                    if (generatedHash.size >= 2) {
                        val generatedPayload = generatedHash.copyOfRange(0, 2)
                        Log.d(TAG, "Generated payload for interval $i: ${generatedPayload.toHexString()}")
                        if (rollingIdPayload.contentEquals(generatedPayload)) {
                            Log.d(TAG, "Rolling ID validated successfully for UUID: $uuid at interval: $i")
                            return uuid // Return the validated UUID
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "HMAC validation failed: ${e.message}")
        }

        Log.d(TAG, "=== ROLLING ID VALIDATION FAILED ===")
        // If no match is found after all checks, return null
        return null
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
}
