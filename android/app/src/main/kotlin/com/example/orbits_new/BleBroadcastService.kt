package com.example.orbits_new

import android.Manifest
import android.app.*
import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.*
import android.content.Context
import android.content.Intent
import android.os.*
import android.util.Log
import androidx.annotation.RequiresPermission
import java.util.*
import android.bluetooth.BluetoothManager
import android.os.Build
import androidx.annotation.RequiresApi
import java.nio.charset.StandardCharsets
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.*
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.FlutterEngineCache

class BleBroadcastService : Service() {

    // Add companion object to store static members
    companion object {
        var isServiceActive: Boolean = false // Static flag, indicating whether the service is running
            private set // Private set method, can only be modified within the companion object
        private var isAdvertising = false
            private set

        // Define your unique App Service UUID here
        // This UUID identifies your application
        val APP_SERVICE_UUID: UUID = UUID.fromString("d61a71b4-3c1f-4b79-80b4-158e70f5d927")
        // Example: Battery Service UUID. **Replace with your own unique UUID.**
        // Generate a new UUID: UUID.randomUUID().toString() -> "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
        // Example: val APP_SERVICE_UUID: UUID = UUID.fromString("YOUR-APP-SPECIFIC-UUID-HERE")

        private const val ROLLING_ID_INTERVAL_MINUTES = 15L
        private const val HMAC_ALGORITHM = "HmacSha256"
        private const val TAG = "BleBroadcastService"

        // Define MethodChannel name
        private const val CHANNEL_NAME = "ble_uuid_broadcaster"
    }

    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private val CHANNEL_ID = "ble_broadcast_channel"
    private val NOTIFICATION_ID = 1001

    // UUID change interval (15 minutes)
    private val uuidChangeIntervalMillis = ROLLING_ID_INTERVAL_MINUTES * 60 * 1000L

    // Current advertising mode, defaults to low power mode
    private var currentAdvertiseMode: Int = AdvertiseSettings.ADVERTISE_MODE_LOW_POWER

    private val handler = Handler(Looper.getMainLooper())

    // The persistent user UUID for this device, now retrieved from secure storage
    private lateinit var userUUID: String

    // The persistent secret key for this device, now retrieved from secure storage
    private lateinit var secretKey: String

    // Flutter MethodChannel instance
//    private lateinit var methodChannel: MethodChannel

    // MARK: - Modifying methodChannel to be nullable to prevent UninitializedPropertyAccessException
    private var methodChannel: MethodChannel? = null

    // Runnable for periodically changing UUID and starting advertising
    private val broadcastRunnable = object : Runnable {
        @RequiresPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
        override fun run() {
            // MARK: 【修改】新增检查，确保 lateinit 属性已初始化
            if (::userUUID.isInitialized && ::secretKey.isInitialized) {
                Log.d(TAG, "Broadcast runnable executing - userUUID: $userUUID")
                // Generate a new rolling ID based on the persistent userUUID and secretKey
                val rollingIdPayload = generateRollingId(userUUID, secretKey)
                Log.d(TAG, "Generated rolling ID payload, size: ${rollingIdPayload.size}")
                // Start advertising with the App Service UUID and the rolling ID payload
                startAdvertising(APP_SERVICE_UUID, rollingIdPayload, currentAdvertiseMode)
                handler.postDelayed(this, uuidChangeIntervalMillis)
            } else {
                Log.e(TAG, "broadcastRunnable called but userUUID or secretKey is not initialized.")
                Log.e(TAG, "userUUID initialized: ${::userUUID.isInitialized}")
                Log.e(TAG, "secretKey initialized: ${::secretKey.isInitialized}")
                // Stop the service if a critical component is missing
                // 如果密钥未初始化，停止服务
                if (!isServiceActive) {
                    stopSelf()
                }}
        }
    }

    //    @RequiresApi(Build.VERSION_CODES.O)
    @RequiresApi(Build.VERSION_CODES.Q)
    override fun onCreate() {
        super.onCreate()
        isServiceActive = true
        Log.d(TAG, "BLE service created.")

        // Create notification channel and start foreground service
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("BLE Broadcast is active."))

        // Set up MethodChannel to listen for commands from Flutter
        Log.d(TAG, "Setting up MethodChannel...")
        setupMethodChannel()
        Log.d(TAG, "MethodChannel setup completed")
        Log.d(TAG, "BLE service onCreate completed, MethodChannel setup done")
        // 延迟检查是否需要重新启动广播
        handler.postDelayed({
            if (isServiceActive && ::userUUID.isInitialized && ::secretKey.isInitialized) {
                Log.d(TAG, "Service restarted, reinitializing broadcast")
                initializeBluetooth()
            }else {
                Log.d(TAG, "Service restarted but keys not initialized, notifying Flutter")
                // 通知Flutter服务已重启但需要重新初始化
                notifyFlutterServiceRestarted()
            }
        }, 1000)


    }
    // 添加通知Flutter服务重启的方法
    private fun notifyFlutterServiceRestarted() {
        try {
            val flutterEngine = FlutterEngineCache.getInstance().get("my_flutter_engine")
            if (flutterEngine != null) {
                // 使用MethodChannel发送事件，这是更简单的方法
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
        // Retrieve the cached FlutterEngine
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
                    // Extract keys from the arguments map
                    val args = call.arguments as Map<String, String>
                    val newUserUUID = args["userUUID"]
                    val newSecretKey = args["secretKey"]
                    Log.d(TAG, "Extracted userUUID: $newUserUUID, secretKey length: ${newSecretKey?.length}")

                    // 修复：先检查参数是否为空，而不是检查未初始化的属性
                    if (newUserUUID.isNullOrEmpty() || newSecretKey.isNullOrEmpty()) {
                        Log.e(TAG, "UUID or secret key is missing")
                        result.error("KEY_ERROR", "UUID or secret key is missing.", null)
                        stopSelf()
                        return@setMethodCallHandler
                    }

                    // 现在安全地赋值给 lateinit 属性
                    userUUID = newUserUUID
                    secretKey = newSecretKey

                    Log.d(TAG, "Received keys from Flutter. Initializing Bluetooth.")
                    initializeBluetooth()
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
                    // Re-schedule the broadcast runnable immediately to apply the new mode
                    // MARK: 【修改】新增检查，确保 Runnable 已经开始运行
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

    private fun initializeBluetooth() {
        // 1. Get BluetoothManager
        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter

        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            Log.e(TAG, "Bluetooth not supported or not enabled.")
            stopSelf()
            return
        }

        advertiser = bluetoothAdapter.bluetoothLeAdvertiser

        if (advertiser == null) {
            Log.e(TAG, "Bluetooth LE Advertiser not available.")
            stopSelf()
            return
        }

        // Start advertising once Bluetooth is ready
        handler.removeCallbacks(broadcastRunnable)
        handler.post(broadcastRunnable)
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // MethodChannel handles commands now. This method is mainly for service lifecycle management.
        // 处理从Intent传递的参数
        intent?.let {
            when (it.action) {
                "ACTION_START_BROADCAST" -> {
                    val userUUID = it.getStringExtra("userUUID")
                    val secretKey = it.getStringExtra("secretKey")

                    Log.d(TAG, "Received parameters from Intent - userUUID: $userUUID")
                    Log.d(TAG, "Received parameters from Intent - secretKey length: ${secretKey?.length}")

                    if (!userUUID.isNullOrEmpty() && !secretKey.isNullOrEmpty()) {
                        this.userUUID = userUUID
                        this.secretKey = secretKey

                        Log.d(TAG, "Parameters received, initializing Bluetooth broadcast")
                        initializeBluetooth()
                    } else {
                        Log.e(TAG, "Missing parameters in Intent")
                    }
                }
                "ACTION_SET_ADVERTISING_MODE" -> {
                    val mode = it.getStringExtra("mode") ?: "low_power"
                    Log.d(TAG, "Received advertising mode update: $mode")
                    // 处理模式设置
                    currentAdvertiseMode = when (mode) {
                        "high_frequency" -> AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY
                        "low_power" -> AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
                        else -> AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
                    }
                    Log.d(TAG, "Advertising mode updated to: $mode")
                }

                else -> {}
            }
        }
        return START_STICKY
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
    override fun onDestroy() {
        super.onDestroy()
        isServiceActive = false
        stopAdvertising()
        handler.removeCallbacks(broadcastRunnable)
        methodChannel?.setMethodCallHandler(null) // Unset handler to avoid memory leaks
        Log.d(TAG, "BLE service stopped.")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Generates a "rolling ID" payload using a cryptographically secure HMAC-SHA256 algorithm.
     * The rolling ID is derived from the user's UUID, a secret key, and the current time interval.
     */
    private fun generateRollingId(userUuid: String, secretKey: String): ByteArray {
        // Get the current time interval in minutes
        val now = System.currentTimeMillis()
        val currentInterval = now / uuidChangeIntervalMillis

        // Create the message to be hashed: userUuid + time interval
        val message = "$userUuid:$currentInterval"
        Log.d(TAG, "=== BROADCAST ROLLING ID GENERATION ===")
        Log.d(TAG, "Generated Rolling ID for interval $currentInterval: $message")
        Log.d(TAG, "User UUID: $userUuid")
        Log.d(TAG, "Secret key length: ${secretKey.length}")

        // Use the secret key for HMAC-SHA256
        val secretKeyBytes = secretKey.toByteArray(StandardCharsets.UTF_8)
        val hmacSha256 = Mac.getInstance(HMAC_ALGORITHM)
        val secretKeySpec = SecretKeySpec(secretKeyBytes, HMAC_ALGORITHM)

        try {
            hmacSha256.init(secretKeySpec)
            val hash = hmacSha256.doFinal(message.toByteArray(StandardCharsets.UTF_8))

            // 只取前8字节，减少数据大小
            val result = hash.copyOfRange(0, 8)
            Log.d(TAG, "Generated 8-byte hash: ${result.toHexString()}")
            Log.d(TAG, "Using first 2 bytes for advertising: ${result.copyOfRange(0, 2).toHexString()}")
            return result
        } catch (e: Exception) {
            Log.e(TAG, "HMAC generation failed: ${e.message}")
            return ByteArray(8) { 0 }
        }
    }

    // Extension function for logging byte arrays
    fun ByteArray.toHexString() = joinToString("") { "%02x".format(it) }

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
            .setAdvertiseMode(advertiseMode) // Dynamically set advertising mode
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(false)
            .setTimeout(0) // 0 means no timeout
            .build()

        // 方案5：只使用Service UUID + Manufacturer Data
        // 使用Manufacturer Data来携带rolling ID，避免Service Data的重复
        val shortRollingId = rollingIdPayload.copyOfRange(0, 2) // 只取前2字节

        // 创建Manufacturer Data（2字节company ID + 2字节rolling ID）
        val manufacturerData = ByteArray(4)
        manufacturerData[0] = 0x12 // Company ID low byte (示例值)
        manufacturerData[1] = 0x34 // Company ID high byte (示例值)
        manufacturerData[2] = shortRollingId[0] // Rolling ID byte 1
        manufacturerData[3] = shortRollingId[1] // Rolling ID byte 2

        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(appServiceUuid)) // Service UUID用于过滤
            .addManufacturerData(0x3412, manufacturerData) // 4字节Manufacturer Data
            .build()
        Log.d(TAG, "Advertise settings and data created, starting advertising...")
        Log.d(TAG, "Starting advertising with UUID: $appServiceUuid, manufacturer data size: ${manufacturerData.size}")

        advertiseCallback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                super.onStartSuccess(settingsInEffect)
                isAdvertising = true
                Log.d(TAG, "BLE advertising started successfully")
                Log.d(TAG, "Advertising started with App Service UUID: $appServiceUuid and Rolling ID Payload."
                )
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
                // 处理 "Too many advertisers" 错误
                if (errorCode == ADVERTISE_FAILED_TOO_MANY_ADVERTISERS) {
                    Log.w(TAG, "Too many advertisers, stopping old advertisements and retrying...")
                    stopAdvertising()

                    // 延迟重试
                    handler.postDelayed({
                        if (isServiceActive && ::userUUID.isInitialized && ::secretKey.isInitialized) {
                            Log.d(TAG, "Retrying advertising after too many advertisers error")
                            startAdvertising(APP_SERVICE_UUID, generateRollingId(userUUID, secretKey), currentAdvertiseMode)
                        }
                    }, 2000) // 2秒后重试
                }
            }
        }

        advertiser?.startAdvertising(settings, data, advertiseCallback)
    }

//    @RequiresPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
//    private fun stopAdvertising() {
//        if (advertiser != null && advertiseCallback != null) {
//            advertiser?.stopAdvertising(advertiseCallback)
//            advertiseCallback = null
//            Log.d(TAG, "Advertising stopped.")
//        }
//    }

    // 添加停止广播的方法
    @RequiresPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
    private fun stopAdvertising() {
        try {
            advertiser?.stopAdvertising(advertiseCallback)
            Log.d(TAG, "Stopped advertising")
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping advertising: ${e.message}")
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun buildNotification(content: String): Notification {

        val builder = Notification.Builder(this, CHANNEL_ID)

        return builder
            .setContentTitle("BLE Broadcast Active")
            .setContentText(content)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "BLE Broadcast Channel",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }
}
