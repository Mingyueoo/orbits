package com.example.orbitz

import android.Manifest
import android.app.*
import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.*
import android.util.Log
import androidx.annotation.RequiresPermission
import androidx.core.content.ContextCompat
import androidx.work.WorkManager
import androidx.work.OneTimeWorkRequest
import androidx.work.NetworkType
import java.util.*
import java.util.concurrent.TimeUnit
import android.bluetooth.BluetoothManager
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import java.nio.charset.StandardCharsets
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.*
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * BleBroadcastService - BLE广播前台服务
 *
 * 功能：
 * - 作为前台服务运行，显示持续通知
 * - 执行周期性BLE广播
 * - 生成和广播Rolling ID
 * - 支持高频率和低功耗两种广播模式
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
class BleBroadcastService : Service() {

    companion object {
        var isServiceActive: Boolean = false
            private set
        private var isAdvertising = false
            private set

        // 应用服务UUID
        val APP_SERVICE_UUID: UUID = UUID.fromString("0000D61A-0000-1000-8000-00805F9B34FB")

        private const val ROLLING_ID_INTERVAL_MINUTES = 15L
        private const val HMAC_ALGORITHM = "HmacSha256"
        private const val TAG = "BleBroadcastService"
        private const val CHANNEL_NAME = "ble_uuid_broadcaster"

        // WorkManager相关常量
        private const val WORKMANAGER_TAG = "ble_broadcast_worker"
    }

    // 服务启动时间监控
    private var serviceStartTime: Long = 0

    // 蓝牙相关组件
    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null

    // 通知相关
    private val CHANNEL_ID = "ble_broadcast_channel"
    private val NOTIFICATION_ID = 1001

    // UUID变化间隔（15分钟）
    private val uuidChangeIntervalMillis = ROLLING_ID_INTERVAL_MINUTES * 60 * 1000L

    // 当前广播模式，默认为低功耗模式
    private var currentAdvertiseMode: Int = AdvertiseSettings.ADVERTISE_MODE_LOW_POWER

    // 任务调度
    private val handler = Handler(Looper.getMainLooper())

    // 持久化的用户UUID和密钥
    private lateinit var userUUID: String
    private lateinit var secretKey: String

    // Flutter MethodChannel实例
    private var methodChannel: MethodChannel? = null

    // 周期性广播任务
    private val broadcastRunnable = object : Runnable {
        @RequiresPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
        override fun run() {
            if (::userUUID.isInitialized && ::secretKey.isInitialized) {
                Log.d(TAG, "Broadcast runnable executing - userUUID: $userUUID")
                // 生成新的rolling ID
                val rollingIdPayload = generateRollingId(userUUID, secretKey)
                Log.d(TAG, "Generated rolling ID payload, size: ${rollingIdPayload.size}")
                // 开始广播
                startAdvertising(APP_SERVICE_UUID, rollingIdPayload, currentAdvertiseMode)
                handler.postDelayed(this, uuidChangeIntervalMillis)
            } else {
                Log.e(TAG, "broadcastRunnable called but userUUID or secretKey is not initialized.")
                Log.e(TAG, "userUUID initialized: ${::userUUID.isInitialized}")
                Log.e(TAG, "secretKey initialized: ${::secretKey.isInitialized}")
                if (!isServiceActive) {
                    stopSelf()
                }
            }
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    override fun onCreate() {
        super.onCreate()
        serviceStartTime = System.currentTimeMillis()

        Log.d(TAG, "BLE Broadcast Service onCreate() called")

        // 检查是否有WorkManager启动请求
        checkWorkManagerStartRequest()

        // 立即检查前台服务权限
        if (!checkForegroundServicePermissions()) {
            Log.e(TAG, "Missing foreground service permissions")
            stopSelf()
            return
        }

        isServiceActive = true
        Log.d(TAG, "BLE service created.")

        // 创建通知渠道并启动前台服务
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("BLE Broadcast is active."))

        val elapsedTime = System.currentTimeMillis() - serviceStartTime
        Log.d(TAG, "Service started in ${elapsedTime}ms")

        // 设置MethodChannel
        Log.d(TAG, "Setting up MethodChannel...")
        setupMethodChannel()
        Log.d(TAG, "MethodChannel setup completed")
    }

    /**
     * 检查WorkManager启动请求
     */
    private fun checkWorkManagerStartRequest() {
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val shouldStart = prefs.getBoolean("workmanager_start_broadcast_service", false)

            if (shouldStart) {
                Log.d(TAG, "WorkManager requested broadcast service start")

                // 清除启动标志
                prefs.edit().putBoolean("workmanager_start_broadcast_service", false).apply()

                // 获取WorkManager传递的参数
                val userUuid = prefs.getString("workmanager_broadcast_user_uuid", null)
                val secretKey = prefs.getString("workmanager_broadcast_secret_key", null)

                if (userUuid != null && secretKey != null) {
                    Log.d(TAG, "WorkManager provided broadcast service parameters")

                    this.userUUID = userUuid
                    this.secretKey = secretKey

                    // 延迟启动以确保服务完全初始化
                    handler.postDelayed({
                        initializeBluetooth()
                        Log.d(TAG, "Broadcast service started via WorkManager")
                    }, 1000)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error checking WorkManager start request: ${e.message}")
        }
    }

    /**
     * 注册WorkManager任务以确保广播服务持续运行
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

            val workRequest = OneTimeWorkRequest.Builder(BleBroadcastWorker::class.java)
                .setConstraints(constraints)
                .addTag(WORKMANAGER_TAG)
                .setInitialDelay(15, TimeUnit.MINUTES) // 15分钟后执行
                .build()

            WorkManager.getInstance(this).enqueue(workRequest)
            Log.d(TAG, "WorkManager broadcast task registered")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register WorkManager broadcast task: ${e.message}")
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "BLE Broadcast Service received start command.")

        intent?.let {
            when (it.action) {
                "ACTION_START_BROADCAST" -> handleStartBroadcast(it)
                "ACTION_SET_ADVERTISING_MODE" -> handleSetAdvertisingMode(it)
                else -> {
                    Log.w(TAG, "Received unknown action: ${it.action}. Ignoring.")
                }
            }
        } ?: run {
            Log.d(TAG, "Service started with null intent (system restart)")
            handleServiceRestart()
        }

        return START_STICKY
    }

    /**
     * 处理启动广播
     */
    private fun handleStartBroadcast(intent: Intent) {
        val userUUID = intent.getStringExtra("userUUID")
        val secretKey = intent.getStringExtra("secretKey")

        Log.d(TAG, "Received parameters from Intent - userUUID: $userUUID")
        Log.d(TAG, "Received parameters from Intent - secretKey length: ${secretKey?.length}")

        if (!userUUID.isNullOrEmpty() && !secretKey.isNullOrEmpty()) {
            this.userUUID = userUUID
            this.secretKey = secretKey

            Log.d(TAG, "Parameters received, initializing Bluetooth broadcast")
            initializeBluetooth()

            // 注册WorkManager任务
            registerWorkManagerTask()
        } else {
            Log.e(TAG, "Missing parameters in Intent")
            updateNotification("Missing parameters, service stopped.")
        }
    }

    /**
     * 处理设置广播模式
     */
    private fun handleSetAdvertisingMode(intent: Intent) {
        val mode = intent.getStringExtra("mode") ?: "low_power"
        Log.d(TAG, "Received advertising mode update: $mode")

        currentAdvertiseMode = when (mode) {
            "high_frequency" -> AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY
            "low_power" -> AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
            else -> AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
        }

        Log.d(TAG, "Advertising mode updated to: $mode")

        // 如果广播正在运行，重新启动以应用新模式
        if (isAdvertising && ::userUUID.isInitialized && ::secretKey.isInitialized) {
            Log.d(TAG, "Restarting advertising with new mode")
            initializeBluetooth()
        }
    }

    /**
     * 处理服务重启
     */
    private fun handleServiceRestart() {
        if (::userUUID.isInitialized && ::secretKey.isInitialized) {
            Log.d(TAG, "Service restarted by system, reinitializing broadcast")
            initializeBluetooth()
        } else {
            Log.d(TAG, "Service restarted but keys not initialized, notifying Flutter")
            notifyFlutterServiceRestarted()
        }
    }

    /**
     * 通知Flutter服务重启
     */
    private fun notifyFlutterServiceRestarted() {
        try {
            val flutterEngine = FlutterEngineCache.getInstance().get("my_flutter_engine")
            if (flutterEngine != null) {
                methodChannel?.invokeMethod("serviceRestarted", "service_restarted")
                Log.d(TAG, "Notified Flutter that service restarted via MethodChannel")
            } else {
                Log.w(TAG, "FlutterEngine not found, cannot notify Flutter")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error notifying Flutter: ${e.message}")
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun setupMethodChannel() {
        Log.d(TAG, "Entering setupMethodChannel")
        val flutterEngine = FlutterEngineCache.getInstance().get("my_flutter_engine")
        if (flutterEngine == null) {
            Log.e(TAG, "FlutterEngine not found in cache. Cannot set up MethodChannel.")
            stopSelf()
            return
        }

        Log.d(TAG, "FlutterEngine found, creating MethodChannel")
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        methodChannel?.setMethodCallHandler { call, result ->
            Log.d(TAG, "MethodChannel received call: ${call.method}")
            when (call.method) {
                "startBroadcast" -> {
                    Log.d(TAG, "Received startBroadcast call from Flutter")
                    val args = call.arguments as Map<String, String>
                    val newUserUUID = args["userUUID"]
                    val newSecretKey = args["secretKey"]
                    Log.d(TAG, "Extracted userUUID: $newUserUUID, secretKey length: ${newSecretKey?.length}")

                    if (newUserUUID.isNullOrEmpty() || newSecretKey.isNullOrEmpty()) {
                        Log.e(TAG, "UUID or secret key is missing")
                        result.error("KEY_ERROR", "UUID or secret key is missing.", null)
                        stopSelf()
                        return@setMethodCallHandler
                    }

                    userUUID = newUserUUID
                    secretKey = newSecretKey

                    Log.d(TAG, "Received keys from Flutter. Initializing Bluetooth.")
                    initializeBluetooth()

                    // 注册WorkManager任务
                    registerWorkManagerTask()
                    result.success(true)
                }
                "stopBroadcast" -> {
                    stopSelf()
                    result.success(true)
                }
                "setAdvertisingMode" -> {
                    val modeString = call.argument<String>("mode")
                    currentAdvertiseMode = when (modeString) {
                        "high_frequency" -> AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY
                        "low_power" -> AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
                        else -> AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
                    }
                    Log.d(TAG, "Advertising mode updated to: $modeString")

                    if (handler.hasCallbacks(broadcastRunnable)) {
                        handler.removeCallbacks(broadcastRunnable)
                        handler.post(broadcastRunnable)
                    } else {
                        Log.w(TAG, "Broadcast runnable not running, cannot update mode")
                    }
                    result.success(true)
                }
                "isServiceRunning" -> {
                    Log.d(TAG, "Received isServiceRunning call, returning: $isServiceActive")
                    result.success(isServiceActive)
                }
                else -> {
                    Log.w(TAG, "Unknown method call: ${call.method}")
                    result.notImplemented()
                }
            }
        }
        Log.d(TAG, "MethodChannel setup completed successfully")
    }

    /**
     * 初始化蓝牙组件
     */
    private fun initializeBluetooth() {
        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter

        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            Log.e(TAG, "Bluetooth not supported or not enabled.")
            updateNotification("Bluetooth not available, service stopped.")
            stopSelf()
            return
        }

        advertiser = bluetoothAdapter.bluetoothLeAdvertiser

        if (advertiser == null) {
            Log.e(TAG, "Bluetooth LE Advertiser not available.")
            updateNotification("BLE Advertiser not available, service stopped.")
            stopSelf()
            return
        }

        // 开始广播
        handler.removeCallbacks(broadcastRunnable)
        handler.post(broadcastRunnable)
        updateNotification("BLE Broadcast is active.")
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
    override fun onDestroy() {
        super.onDestroy()
        isServiceActive = false
        stopAdvertising()
        handler.removeCallbacks(broadcastRunnable)
        methodChannel?.setMethodCallHandler(null)
        Log.d(TAG, "BLE service stopped.")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * 生成Rolling ID
     */
    private fun generateRollingId(userUuid: String, secretKey: String): ByteArray {
        val now = System.currentTimeMillis()
        val currentInterval = now / uuidChangeIntervalMillis

        val message = "$userUuid:$currentInterval"
        Log.d(TAG, "=== BROADCAST ROLLING ID GENERATION ===")
        Log.d(TAG, "Generated Rolling ID for interval $currentInterval: $message")
        Log.d(TAG, "User UUID: $userUuid")
        Log.d(TAG, "Secret key length: ${secretKey.length}")

        val secretKeyBytes = secretKey.toByteArray(StandardCharsets.UTF_8)
        val hmacSha256 = Mac.getInstance(HMAC_ALGORITHM)
        val secretKeySpec = SecretKeySpec(secretKeyBytes, HMAC_ALGORITHM)

        try {
            hmacSha256.init(secretKeySpec)
            val hash = hmacSha256.doFinal(message.toByteArray(StandardCharsets.UTF_8))

            // 只取前2字节，减少数据大小
            val result = hash.copyOfRange(0, 2)
            Log.d(TAG, "Generated 2-byte hash: ${result.toHexString()}")
            return result
        } catch (e: Exception) {
            Log.e(TAG, "HMAC generation failed: ${e.message}")
            return ByteArray(2) { 0 }
        }
    }

    // Extension function for logging byte arrays
    fun ByteArray.toHexString() = joinToString("") { "%02x".format(it) }

    /**
     * 开始广播
     */
    @RequiresPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
    private fun startAdvertising(
        appServiceUuid: UUID,
        rollingIdPayload: ByteArray,
        advertiseMode: Int
    ) {
        if (isAdvertising) {
            Log.d(TAG, "Already advertising, stopping first")
            stopAdvertising()
        }

        Log.d(TAG, "Starting advertising with UUID: $appServiceUuid, payload size: ${rollingIdPayload.size}, mode: $advertiseMode")

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(advertiseMode)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(false)
            .setTimeout(0)
            .build()

        // 确保只使用2字节数据
        val shortRollingId = if (rollingIdPayload.size >= 2) {
            rollingIdPayload.copyOfRange(0, 2)
        } else {
            rollingIdPayload
        }

        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(appServiceUuid))
            .addServiceData(ParcelUuid(appServiceUuid), shortRollingId)
            .build()

        Log.d(TAG, "Advertise settings and data created, starting advertising...")

        advertiseCallback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                super.onStartSuccess(settingsInEffect)
                isAdvertising = true
                Log.d(TAG, "BLE advertising started successfully")
                Log.d(TAG, "Advertising started with App Service UUID: $appServiceUuid and Rolling ID Payload.")
                updateNotification("BLE Broadcast is active - Advertising")
            }

            @RequiresPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
            override fun onStartFailure(errorCode: Int) {
                super.onStartFailure(errorCode)
                isAdvertising = false
                val errorMessage = when (errorCode) {
                    ADVERTISE_FAILED_ALREADY_STARTED -> "Advertising already started"
                    ADVERTISE_FAILED_DATA_TOO_LARGE -> "Data too large"
                    ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "Too many advertisers"
                    ADVERTISE_FAILED_INTERNAL_ERROR -> "Internal error"
                    ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "Feature unsupported"
                    else -> "Unknown error: $errorCode"
                }
                Log.e(TAG, "Advertising failed: $errorMessage")
                updateNotification("BLE Broadcast failed: $errorMessage")

                // 处理 "Too many advertisers" 错误
                if (errorCode == ADVERTISE_FAILED_TOO_MANY_ADVERTISERS) {
                    Log.w(TAG, "Too many advertisers, stopping old advertisements and retrying...")
                    stopAdvertising()

                    handler.postDelayed({
                        if (isServiceActive && ::userUUID.isInitialized && ::secretKey.isInitialized) {
                            Log.d(TAG, "Retrying advertising after too many advertisers error")
                            startAdvertising(APP_SERVICE_UUID, generateRollingId(userUUID, secretKey), currentAdvertiseMode)
                        }
                    }, 2000)
                }
            }
        }

        advertiser?.startAdvertising(settings, data, advertiseCallback)
    }

    /**
     * 停止广播
     */
    @RequiresPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
    private fun stopAdvertising() {
        try {
            advertiser?.stopAdvertising(advertiseCallback)
            isAdvertising = false
            Log.d(TAG, "Stopped advertising")
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping advertising: ${e.message}")
        }
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
            .setContentTitle("BLE Broadcast Active")
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
                "BLE Broadcast Channel",
                NotificationManager.IMPORTANCE_HIGH // 提高重要性
            ).apply {
                description = "BLE broadcast service notifications"
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
}