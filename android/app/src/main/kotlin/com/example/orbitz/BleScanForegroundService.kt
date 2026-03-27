package com.example.orbitz

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
import androidx.work.WorkManager
import androidx.work.OneTimeWorkRequest
import androidx.work.NetworkType
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import java.util.concurrent.TimeUnit

// Extension function for logging byte arrays
fun ByteArray.toHexString() = joinToString("") { "%02x".format(it) }

/**
 * BleScanForegroundService - BLE扫描前台服务
 *
 * 功能：
 * - 作为前台服务运行，显示持续通知
 * - 执行周期性BLE扫描
 * - 处理扫描结果并验证Rolling ID
 * - 支持高频率和低功耗两种扫描模式
 * - 监听蓝牙状态变化
 * - 支持WorkManager自动重启机制
 *
 * 优化点：
 * - 简化启动流程
 * - 集中权限检查
 * - 添加启动时间监控
 * - 改进错误处理
 * - 优化通知管理
 * - 集成WorkManager保障
 */
class BleScanForegroundService : Service(), MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        var isServiceActive: Boolean = false
            private set
        private const val CHANNEL_ID = "ble_scan_channel"
        private const val NOTIFICATION_ID = 1002
        private const val TAG = "BleScanService"

        // 与广播端保持一致的常量
        private const val ROLLING_ID_INTERVAL_MINUTES = 15L
        private const val HMAC_ALGORITHM = "HmacSha256"
        const val CLOCK_DRIFT_WINDOW_MINUTES = 20L

        // WorkManager相关常量
        private const val WORKMANAGER_TAG = "ble_scan_worker"

        @SuppressLint("StaticFieldLeak")
        var eventSink: EventChannel.EventSink? = null

        @SuppressLint("StaticFieldLeak")
        var flutterMethodChannel: MethodChannel? = null
    }

    // 服务启动时间监控
    private var serviceStartTime: Long = 0

    // 蓝牙相关组件
    private var bluetoothLeScanner: BluetoothLeScanner? = null
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var currentScanCallback: ScanCallback? = null

    // 扫描模式参数
    private val highFrequencyScanDurationMillis = 5 * 1000L
    private val highFrequencyScanIntervalMillis = 10 * 1000L
    private val lowPowerScanDurationMillis = 10 * 1000L
    private val lowPowerScanIntervalMillis = 60 * 1000L

    private var currentScanMode: String = "low_power"

    // 任务调度
    private val handler = Handler(Looper.getMainLooper())
    private var scanCycleRunnable: Runnable? = null
    private var scanDurationRunnable: Runnable? = null

    // 从Flutter端获取的密钥和已知用户列表
    private lateinit var secretKey: String
    private lateinit var knownUserUUIDs: List<String>

    // 蓝牙状态监听器
    private val bluetoothStateReceiver = object : BroadcastReceiver() {
        @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
        @RequiresApi(Build.VERSION_CODES.O)
        override fun onReceive(context: Context?, intent: Intent?) {
            val action = intent?.action
            if (BluetoothAdapter.ACTION_STATE_CHANGED == action) {
                val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                when (state) {
                    BluetoothAdapter.STATE_OFF -> {
                        Log.w(TAG, "Bluetooth turned off. Stopping BLE scan.")
                        stopPeriodicScan()
                        eventSink?.error("BLUETOOTH_OFF", "Bluetooth has been turned off.", null)
                        updateNotification("Bluetooth is off, scan stopped.")
                    }
                    BluetoothAdapter.STATE_ON -> {
                        Log.i(TAG, "Bluetooth turned on. Resuming BLE scan.")
                        if (isServiceActive && checkBlePermissions()) {
                            initializeBluetoothComponents()
                            if (::secretKey.isInitialized && ::knownUserUUIDs.isInitialized) {
                                startPeriodicScan(currentScanMode)
                            }
                            updateNotification("Bluetooth is on, scan resumed.")
                        }
                    }
                }
            }
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
    @RequiresApi(Build.VERSION_CODES.O)
    override fun onCreate() {
        super.onCreate()
        serviceStartTime = System.currentTimeMillis()

        Log.d(TAG, "BLE Scan Service onCreate() called")

        // 检查是否有WorkManager启动请求
        checkWorkManagerStartRequest()

        // 立即检查前台服务权限
        if (!checkForegroundServicePermissions()) {
            Log.e(TAG, "Missing foreground service permissions")
            stopSelf()
            return
        }

        isServiceActive = true
        Log.d(TAG, "BLE Scan Service created.")

        // 创建通知渠道并启动前台服务
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("BLE Scan Service is running."))

        val elapsedTime = System.currentTimeMillis() - serviceStartTime
        Log.d(TAG, "Service started in ${elapsedTime}ms")

        // 注册蓝牙状态监听器
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        registerReceiver(bluetoothStateReceiver, filter)
    }

    /**
     * 检查WorkManager启动请求
     */
    @RequiresApi(Build.VERSION_CODES.O)
    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
    private fun checkWorkManagerStartRequest() {
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val shouldStart = prefs.getBoolean("workmanager_start_service", false)

            if (shouldStart) {
                Log.d(TAG, "WorkManager requested scan service start")

                // 清除启动标志
                prefs.edit().putBoolean("workmanager_start_service", false).apply()

                // 获取WorkManager传递的参数
                val secretKey = prefs.getString("workmanager_secret_key", null)
                val userUuidsJson = prefs.getString("workmanager_user_uuids", null)

                if (secretKey != null && userUuidsJson != null) {
                    Log.d(TAG, "WorkManager provided scan service parameters")

                    // 解析用户UUID列表
                    val userUuids = try {
                        val jsonArray = org.json.JSONArray(userUuidsJson)
                        (0 until jsonArray.length()).map { jsonArray.getString(it) }
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to parse user UUIDs from WorkManager: ${e.message}")
                        emptyList<String>()
                    }

                    if (userUuids.isNotEmpty()) {
                        // 启动服务
                        this.secretKey = secretKey
                        this.knownUserUUIDs = userUuids

                        // 延迟启动以确保服务完全初始化
                        handler.postDelayed({
                            if (checkBlePermissions()) {
                                initializeBluetoothComponents()
                                startPeriodicScan(currentScanMode)
                                Log.d(TAG, "Scan service started via WorkManager")
                            }
                        }, 1000)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error checking WorkManager start request: ${e.message}")
        }
    }

    /**
     * 注册WorkManager任务以确保扫描服务持续运行
     */
    private fun registerWorkManagerTask() {
        try {
            val constraints = androidx.work.Constraints.Builder()
                .setRequiredNetworkType(NetworkType.NOT_REQUIRED)
                .setRequiresBatteryNotLow(false)
                .setRequiresCharging(false)
                .setRequiresDeviceIdle(false)
                .setRequiresStorageNotLow(false)
                .build()

            val workRequest = OneTimeWorkRequest.Builder(BleScanWorker::class.java)
                .setConstraints(constraints)
                .addTag(WORKMANAGER_TAG)
                .setInitialDelay(15, TimeUnit.MINUTES) // 15分钟后执行
                .build()

            WorkManager.getInstance(this).enqueue(workRequest)
            Log.d(TAG, "WorkManager scan task registered")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register WorkManager scan task: ${e.message}")
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    @androidx.annotation.RequiresPermission(android.Manifest.permission.BLUETOOTH_SCAN)
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "BLE Scan Service received start command.")

        intent?.let {
            when (it.action) {
                "ACTION_START_SCAN_SERVICE" -> handleStartScanService(it)
                "ACTION_SET_SCAN_MODE" -> handleSetScanMode(it)
                else -> {
                    Log.w(TAG, "Received unknown action: ${it.action}. Ignoring.")
                    handleServiceRestart()
                }
            }
        } ?: run {
            Log.d(TAG, "Service started with null intent (system restart)")
            handleServiceRestart()
        }

        return START_STICKY
    }

    /**
     * 处理启动扫描服务
     */
    @RequiresApi(Build.VERSION_CODES.O)
    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
    private fun handleStartScanService(intent: Intent) {
        val secretKey = intent.getStringExtra("secretKey")
        val knownUserUUIDs = intent.getStringArrayListExtra("knownUserUUIDs")

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

                // 注册WorkManager任务
                registerWorkManagerTask()
            } else {
                Log.e(TAG, "Permission denied. Cannot start scan.")
                updateNotification("Permission denied, scan stopped.")
            }
        } else {
            Log.e(TAG, "Missing parameters in Intent")
            updateNotification("Missing parameters, service stopped.")
        }
    }

    /**
     * 处理设置扫描模式
     */
    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
    @RequiresApi(Build.VERSION_CODES.O)
    private fun handleSetScanMode(intent: Intent) {
        val mode = intent.getStringExtra("mode") ?: "low_power"
        Log.d(TAG, "Received scan mode update: $mode")
        if (checkBlePermissions()) {
            setScanModeInternal(mode)
        } else {
            Log.e(TAG, "Missing BLE permissions to set scan mode.")
            eventSink?.error("PERMISSION_DENIED", "Missing BLUETOOTH_SCAN permission.", null)
        }
    }

    /**
     * 处理服务重启
     */
    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
    @RequiresApi(Build.VERSION_CODES.O)
    private fun handleServiceRestart() {
        if (::secretKey.isInitialized && ::knownUserUUIDs.isInitialized) {
            Log.d(TAG, "Service restarted by system, resuming scan with mode: $currentScanMode")
            if (checkBlePermissions()) {
                startPeriodicScan(currentScanMode)
            } else {
                Log.e(TAG, "Service restarted by system, but missing BLE permissions.")
                eventSink?.error("PERMISSION_DENIED", "Service restarted without necessary permissions.", null)
            }
        } else {
            Log.e(TAG, "Service restarted by system, but missing required data.")
            updateNotification("Service restarted but missing data.")
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    override fun onDestroy() {
        super.onDestroy()
        isServiceActive = false
        stopPeriodicScan()
        unregisterReceiver(bluetoothStateReceiver)
        Log.d(TAG, "BLE Scan Service stopped.")
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    /**
     * 检查前台服务权限
     */
    private fun checkForegroundServicePermissions(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) { // API 34+
            val hasForegroundServiceLocation = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.FOREGROUND_SERVICE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED

            val hasLocationPermission = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED ||
                    ContextCompat.checkSelfPermission(
                        this,
                        Manifest.permission.ACCESS_COARSE_LOCATION
                    ) == PackageManager.PERMISSION_GRANTED

            Log.d(TAG, "Foreground service location permission: $hasForegroundServiceLocation")
            Log.d(TAG, "Location permission: $hasLocationPermission")

            return hasForegroundServiceLocation && hasLocationPermission
        }
        return true
    }

    /**
     * 初始化蓝牙组件
     */
    private fun initializeBluetoothComponents(): Boolean {
        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        bluetoothAdapter = bluetoothManager.adapter

        if (bluetoothAdapter == null) {
            Log.e(TAG, "Bluetooth not supported on this device. Stopping scan service.")
            eventSink?.error("BLUETOOTH_NOT_SUPPORTED", "Bluetooth is not supported on this device.", null)
            stopSelf()
            return false
        }

        if (!bluetoothAdapter!!.isEnabled) {
            Log.w(TAG, "Bluetooth is not enabled. Cannot start BLE scan.")
            eventSink?.error("BLUETOOTH_DISABLED", "Bluetooth is not enabled.", null)
            return false
        }

        bluetoothLeScanner = bluetoothAdapter!!.bluetoothLeScanner
        if (bluetoothLeScanner == null) {
            Log.e(TAG, "Bluetooth LE Scanner not available. Stopping scan service.")
            eventSink?.error("BLUETOOTH_LE_NOT_AVAILABLE", "Bluetooth LE Scanner not available.", null)
            stopSelf()
            return false
        }

        return true
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
    @RequiresApi(Build.VERSION_CODES.O)
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startScanService" -> {
                val args = call.arguments as Map<String, Any>
                val userUUIDs = args["userUUIDs"] as List<String>?
                val secretKey = args["secretKey"] as String?
                val mode = args["mode"] as String?

                if (secretKey.isNullOrEmpty()) {
                    result.error("KEY_ERROR", "Secret key is missing.", null)
                    stopSelf()
                    return
                }

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

                if (checkBlePermissions()) {
                    Log.d(TAG, "Permissions granted. Proceeding to start scan.")
                    initializeBluetoothComponents()
                    startPeriodicScan(currentScanMode)

                    // 注册WorkManager任务
                    registerWorkManagerTask()
                    result.success(true)
                } else {
                    Log.e(TAG, "Permission denied. Cannot start scan.")
                    result.error("PERMISSION_DENIED", "BLUETOOTH_SCAN permission not granted.", null)
                }
            }
            "stopScanService" -> {
                stopPeriodicScan()
                result.success(true)
            }
            "setScanMode" -> {
                val mode = call.argument<String>("mode") ?: "low_power"
                if (checkBlePermissions()) {
                    setScanModeInternal(mode)
                    result.success(true)
                } else {
                    result.error("PERMISSION_DENIED", "BLUETOOTH_SCAN permission not granted.", null)
                }
            }
            "isServiceRunning" -> {
                result.success(isServiceActive)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        Log.d(TAG, "EventChannel onListen called, setting eventSink.")
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        Log.d(TAG, "EventChannel onCancel called, clearing eventSink.")
        eventSink = null
    }

    /**
     * 设置扫描模式并重启扫描
     */
    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
    @RequiresApi(Build.VERSION_CODES.O)
    private fun setScanModeInternal(mode: String) {
        if (currentScanMode != mode) {
            currentScanMode = mode
            Log.d(TAG, "Internal scan mode updated to: $currentScanMode")
            if (checkBlePermissions()) {
                stopPeriodicScan()
                startPeriodicScan(currentScanMode)
            } else {
                Log.e(TAG, "Missing BLE permissions to restart scan with new mode.")
                eventSink?.error("PERMISSION_DENIED", "Missing BLUETOOTH_SCAN permission.", null)
            }
        }
    }

    /**
     * 启动周期性扫描
     */
    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
    @RequiresApi(Build.VERSION_CODES.O)
    private fun startPeriodicScan(mode: String) {
        Log.d(TAG, "Entering startPeriodicScan with mode: $mode")

        if (!initializeBluetoothComponents()) {
            Log.e(TAG, "Bluetooth components not ready, cannot start periodic scan.")
            return
        }

        if (!checkBlePermissions()) {
            Log.e(TAG, "Missing BLE permissions, cannot start periodic scan.")
            eventSink?.error("PERMISSION_DENIED", "Missing BLUETOOTH_SCAN permission.", null)
            return
        }

        if (!::secretKey.isInitialized) {
            Log.e(TAG, "Secret key not initialized. Cannot start scan.")
            eventSink?.error("KEY_NOT_INITIALIZED", "Secret key not received from Flutter.", null)
            return
        }

        if (!::knownUserUUIDs.isInitialized) {
            Log.e(TAG, "KnownUserUUIDs not initialized. Cannot start scan.")
            eventSink?.error("KEY_NOT_INITIALIZED", "KnownUserUUIDs not received from Flutter.", null)
            return
        }

        stopPeriodicScan()

        val scanDuration = if (mode == "high_frequency") highFrequencyScanDurationMillis else lowPowerScanDurationMillis
        val scanInterval = if (mode == "high_frequency") highFrequencyScanIntervalMillis else lowPowerScanIntervalMillis

        Log.d(TAG, "Starting periodic scan: Mode=$mode, Duration=${scanDuration}ms, Interval=${scanInterval}ms")

        startActualBleScan(scanDuration)

        scanCycleRunnable = Runnable {
            if (isServiceActive && checkBlePermissions() && bluetoothAdapter?.isEnabled == true) {
                Log.d(TAG, "Scan cycle completed, scheduling next periodic scan.")
                startPeriodicScan(currentScanMode)
            } else {
                Log.w(TAG, "Service not active, permissions missing, or Bluetooth off. Stopping periodic scan cycle.")
                stopPeriodicScan()
            }
        }
        handler.postDelayed(scanCycleRunnable!!, scanInterval)
    }

    /**
     * 停止所有扫描和定时器
     */
    @SuppressLint("MissingPermission")
    private fun stopPeriodicScan() {
        handler.removeCallbacks(scanCycleRunnable ?: Runnable {})
        handler.removeCallbacks(scanDurationRunnable ?: Runnable {})

        if (bluetoothLeScanner != null && currentScanCallback != null) {
            if (checkBlePermissions()) {
                bluetoothLeScanner?.stopScan(currentScanCallback)
                Log.d(TAG, "BLE scan stopped.")
            } else {
                Log.w(TAG, "BLUETOOTH_SCAN permission not granted, cannot stop BLE scan gracefully.")
            }
        } else {
            Log.d(TAG, "No active BLE scan to stop or scanner/callback is null.")
        }
        currentScanCallback = null
        Log.d(TAG, "Stopped all scan handlers.")
    }

    /**
     * 启动实际的BLE扫描
     */
    @RequiresApi(Build.VERSION_CODES.M)
    @SuppressLint("MissingPermission")
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

        val scanFilter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(BleBroadcastService.APP_SERVICE_UUID))
            .build()

        val scanFilters = listOf(scanFilter)

        Log.d(TAG, "Scan settings created with filter for UUID: ${BleBroadcastService.APP_SERVICE_UUID}")

        currentScanCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                super.onScanResult(callbackType, result)
                Log.d(TAG, "=== SCAN RESULT RECEIVED ===")
                processScanResult(result)
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>?) {
                super.onBatchScanResults(results)
                Log.d(TAG, "Batch scan results received: ${results?.size ?: 0} devices")
                results?.forEach { scanResult ->
                    processScanResult(scanResult)
                }
            }

            override fun onScanFailed(errorCode: Int) {
                super.onScanFailed(errorCode)
                val errorMessage = when (errorCode) {
                    SCAN_FAILED_ALREADY_STARTED -> "Scan already started"
                    SCAN_FAILED_APPLICATION_REGISTRATION_FAILED -> "Application registration failed"
                    SCAN_FAILED_FEATURE_UNSUPPORTED -> "Feature unsupported"
                    SCAN_FAILED_INTERNAL_ERROR -> "Internal error"
                    else -> "Unknown error: $errorCode"
                }
                Log.e(TAG, "Scan failed: $errorMessage")
                eventSink?.error("SCAN_FAILED", errorMessage, null)
            }
        }

        bluetoothLeScanner?.startScan(scanFilters, scanSettings, currentScanCallback)

        scanDurationRunnable = Runnable {
            if (currentScanCallback != null) {
                Log.d(TAG, "Scan duration completed, stopping scan")
                bluetoothLeScanner?.stopScan(currentScanCallback)
                currentScanCallback = null
            }
        }
        handler.postDelayed(scanDurationRunnable!!, durationMillis)
    }

    /**
     * 处理扫描结果
     */
    private fun processScanResult(scanResult: ScanResult) {
        val scanRecord = scanResult.scanRecord
        val deviceAddress = scanResult.device.address
        val rssi = scanResult.rssi

        Log.d(TAG, "Processing scan result - Device: $deviceAddress, RSSI: $rssi")

        val serviceUuids = scanRecord?.serviceUuids
        val hasOurService = serviceUuids?.any { it.uuid == BleBroadcastService.APP_SERVICE_UUID } == true

        if (hasOurService) {
            val rollingIdPayload = scanRecord?.getServiceData(
                ParcelUuid(BleBroadcastService.APP_SERVICE_UUID)
            )

            if (rollingIdPayload != null && rollingIdPayload.size >= 2) {
                Log.d(TAG, "Found service data, payload size: ${rollingIdPayload.size}")

                val decryptedUUID = validateRollingId(rollingIdPayload, secretKey, knownUserUUIDs)

                if (decryptedUUID != null) {
                    Log.d(TAG, "Device discovered and validated: UUID: $decryptedUUID, RSSI: $rssi")

                    val jsonResult = JSONObject().apply {
                        put("uuid", decryptedUUID)
                        put("rssi", rssi)
                        put("secretKey", secretKey)
                    }.toString()

                    eventSink?.success(jsonResult)
                } else {
                    Log.d(TAG, "Rolling ID validation failed for device: $deviceAddress")
                }
            } else {
                Log.d(TAG, "No valid service data found for device: $deviceAddress")
            }
        } else {
            Log.d(TAG, "Device does not have our service UUID: $deviceAddress")
        }
    }

    /**
     * 验证Rolling ID
     */
    private fun validateRollingId(rollingIdPayload: ByteArray, secretKey: String, knownUserUUIDs: List<String>): String? {
        if (rollingIdPayload.size != 2) {
            Log.w(TAG, "Invalid rolling ID payload size: ${rollingIdPayload.size}, expected 2 bytes")
            return null
        }

        Log.d(TAG, "=== ROLLING ID VALIDATION START ===")
        Log.d(TAG, "Received rolling ID payload: ${rollingIdPayload.toHexString()}")

        val now = System.currentTimeMillis()
        val driftWindowMillis = CLOCK_DRIFT_WINDOW_MINUTES * 60 * 1000L
        val intervalLengthMillis = ROLLING_ID_INTERVAL_MINUTES * 60 * 1000L

        val currentInterval = now / intervalLengthMillis
        val startInterval = (now - driftWindowMillis) / intervalLengthMillis
        val endInterval = (now + driftWindowMillis) / intervalLengthMillis

        Log.d(TAG, "Checking intervals from $startInterval to $endInterval")

        val secretKeyBytes = secretKey.toByteArray(StandardCharsets.UTF_8)
        val hmacSha256 = Mac.getInstance(HMAC_ALGORITHM)
        val secretKeySpec = SecretKeySpec(secretKeyBytes, HMAC_ALGORITHM)

        try {
            hmacSha256.init(secretKeySpec)

            for (uuid in knownUserUUIDs) {
                for (i in startInterval..endInterval) {
                    val message = "$uuid:$i".toByteArray(StandardCharsets.UTF_8)
                    val generatedHash = hmacSha256.doFinal(message)

                    if (generatedHash.size >= 2) {
                        val generatedPayload = generatedHash.copyOfRange(0, 2)
                        if (rollingIdPayload.contentEquals(generatedPayload)) {
                            Log.d(TAG, "Rolling ID validated successfully for UUID: $uuid at interval: $i")
                            return uuid
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "HMAC validation failed: ${e.message}")
        }

        Log.d(TAG, "=== ROLLING ID VALIDATION FAILED ===")
        return null
    }

    /**
     * 构建通知（使用更高优先级）
     */
    @RequiresApi(Build.VERSION_CODES.O)
    private fun buildNotification(content: String): Notification {
        val notificationIntent = Intent(this, Class.forName("com.example.orbitz.MainActivity"))
        val pendingIntentFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pendingIntent = PendingIntent.getActivity(this, 0, notificationIntent, pendingIntentFlags)

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("BLE Scan Service Active")
            .setContentText(content)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_HIGH) // 提高优先级
            .setOngoing(true) // 设置为持续通知
            .setAutoCancel(false) // 禁止自动取消
            .build()
    }

    /**
     * 创建通知渠道（使用更高重要性）
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "BLE Scan Channel",
                NotificationManager.IMPORTANCE_HIGH // 提高重要性
            ).apply {
                description = "BLE scanning service notifications"
                enableLights(true)
                enableVibration(false)
                setShowBadge(true)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    /**
     * 更新通知内容
     */
    private fun updateNotification(content: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notification = buildNotification(content)
            val manager = getSystemService(NotificationManager::class.java)
            manager.notify(NOTIFICATION_ID, notification)
        }
    }

    /**
     * 检查BLE权限
     */
    private fun checkBlePermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
                    ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }
}