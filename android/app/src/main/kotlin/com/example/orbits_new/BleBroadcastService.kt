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
import android.bluetooth.le.BluetoothLeAdvertiser
import android.os.Build
import androidx.annotation.RequiresApi
import java.nio.ByteBuffer

class BleBroadcastService : Service() {

    // Add companion object to store static members
    companion object {
        var isServiceActive: Boolean = false // Static flag, indicating whether the service is running
            private set // Private set method, can only be modified within the companion object

        // Define your unique App Service UUID here
        // This UUID identifies your application
        val APP_SERVICE_UUID: UUID = UUID.fromString("0000180F-0000-1000-8000-00805F9B34FB")
        // Example: Battery Service UUID. **Replace with your own unique UUID.**
        // Generate a new UUID: UUID.randomUUID().toString() -> "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
        // Example: val APP_SERVICE_UUID: UUID = UUID.fromString("YOUR-APP-SPECIFIC-UUID-HERE")
    }

    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private val CHANNEL_ID = "ble_broadcast_channel"
    private val NOTIFICATION_ID = 1001
    private val TAG = "BleBroadcastService"

    // UUID change interval (15 minutes)
    private val uuidChangeIntervalMillis = 15 * 60 * 1000L

    // Current advertising mode, defaults to low power mode
    private var currentAdvertiseMode: Int = AdvertiseSettings.ADVERTISE_MODE_LOW_POWER

    private val handler = Handler(Looper.getMainLooper())

    // The persistent user UUID for this device
    private lateinit var userUUID: UUID

    // Runnable for periodically changing UUID and starting advertising
    private val broadcastRunnable = object : Runnable {
        @RequiresPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
        override fun run() {
            // Generate a new rolling ID based on the persistent userUUID
            val rollingIdPayload = generateRollingId(userUUID)
            // Start advertising with the App Service UUID and the rolling ID payload
            startAdvertising(APP_SERVICE_UUID, rollingIdPayload, currentAdvertiseMode)
            handler.postDelayed(this, uuidChangeIntervalMillis)
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    override fun onCreate() {
        super.onCreate()
        // Set static flag to true when service is created
        isServiceActive = true
        // Initialize userUUID here
        userUUID = getPersistentUserUUID(this)

        // 1. Get BluetoothManager
        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager

        // 2. Get BluetoothAdapter from BluetoothManager
        val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter

        // 3. Check if Bluetooth adapter is available, then get its LE advertiser
        if (bluetoothAdapter == null) {
            Log.e(TAG, "Bluetooth not supported on this device.")
            // Optionally, stop the service or handle this case appropriately
            stopSelf() // Example: Stop the service if Bluetooth isn't available
            return
        }

        // Ensure Bluetooth is enabled, otherwise the advertiser might be null
        if (!bluetoothAdapter.isEnabled) {
            Log.w(TAG, "Bluetooth is not enabled. Cannot start BLE advertisement.")
            // You might want to prompt the user to enable Bluetooth here,
            // or stop the service if it's critical.
            stopSelf()
            return
        }

        // Get LE advertiser
        advertiser = bluetoothAdapter.bluetoothLeAdvertiser

        if (advertiser == null) {
            Log.e(TAG, "Bluetooth LE Advertiser not available. Is Bluetooth enabled?")
            stopSelf() // Stop if the advertiser isn't available
            return
        }

        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("BLE Broadcast is active."))
        Log.d(TAG, "BLE service started.")

        // When the service is first started, immediately start advertising (initial mode depends on onStartCommand or default value)
        // Advertising is not started immediately here, but waits for onStartCommand to handle the initial intent
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // When the service is first started, or started via the setAdvertisingMode intent
        if (intent != null) {
            when (intent.action) {
                "ACTION_SET_ADVERTISING_MODE" -> { // Handle mode switch command
                    val modeString = intent.getStringExtra("mode")
                    currentAdvertiseMode = when (modeString) {
                        "high_frequency" -> AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY
                        "low_power" -> AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
                        else -> AdvertiseSettings.ADVERTISE_MODE_LOW_POWER // Default to low power
                    }
                    Log.d(TAG, "Advertising mode updated to: $modeString")
                }
                // Other actions for starting the service can be added here
            }
        }

        // Always ensure advertising is running with the correct payload and mode
        // This will stop any existing advertising and start a new one with the current settings
        val rollingIdPayload = generateRollingId(userUUID)
        startAdvertising(APP_SERVICE_UUID, rollingIdPayload, currentAdvertiseMode)
        Log.d(TAG, "Initial advertising or mode updated advertising started, mode: $currentAdvertiseMode")

        // Only post delayed if it's not already scheduled
        handler.removeCallbacks(broadcastRunnable) // Ensure only one runnable is pending
        handler.postDelayed(broadcastRunnable, uuidChangeIntervalMillis)

        return START_STICKY // Attempt to restart service after it's killed
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
    override fun onDestroy() {
        super.onDestroy()
        // Set static flag to false when service is destroyed
        isServiceActive = false
        stopAdvertising()
        handler.removeCallbacks(broadcastRunnable)
        Log.d(TAG, "BLE service stopped.")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Retrieves or generates a persistent UUID for this device.
     * This UUID should remain constant for the lifetime of the app on the device.
     */
    private fun getPersistentUserUUID(context: Context): UUID {
        val prefs = context.getSharedPreferences("app_prefs", Context.MODE_PRIVATE)
        var storedUuid = prefs.getString("user_uuid", null)

        if (storedUuid == null) {
            // Generate a new UUID if one doesn't exist
            val newUuid = UUID.randomUUID()
            prefs.edit().putString("user_uuid", newUuid.toString()).apply()
            storedUuid = newUuid.toString()
            Log.d(TAG, "Generated new persistent user UUID: $storedUuid")
        } else {
            Log.d(TAG, "Retrieved persistent user UUID: $storedUuid")
        }
        return UUID.fromString(storedUuid)
    }

    /**
     * Generates a "rolling ID" payload from the persistent user UUID.
     * This is a placeholder for a true cryptographic rolling ID scheme.
     * In a real application, you would implement a secure method here
     * (e.g., hash, HMAC, or a deterministic rotating ID derived from a secret key).
     *
     * For this example, we'll simply reverse the byte array of the UUID
     * to demonstrate a "transformed" version.
     */
    private fun generateRollingId(userUuid: UUID): ByteArray {
        // Convert UUID to byte array
        val bb = ByteBuffer.wrap(ByteArray(16))
        bb.putLong(userUuid.mostSignificantBits)
        bb.putLong(userUuid.leastSignificantBits)
        val uuidBytes = bb.array()

        // Simple transformation: reverse the byte array
        val transformedBytes = uuidBytes.reversedArray()

        Log.d(TAG, "Original User UUID: $userUuid")
        Log.d(TAG, "Generated Rolling ID Payload (transformed): ${transformedBytes.toHexString()}")

        return transformedBytes
    }

    // Extension function for logging byte arrays
    fun ByteArray.toHexString() = joinToString("") { "%02x".format(it) }

    @RequiresPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
    private fun startAdvertising(
        appServiceUuid: UUID,
        rollingIdPayload: ByteArray,
        advertiseMode: Int
    ) {
        stopAdvertising() // Ensure old advertisement is stopped before starting a new one

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(advertiseMode) // Dynamically set advertising mode
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(false)
            .build()

        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(appServiceUuid))// Add the App's Service UUID
            // Add the rolling ID payload as Service Data associated with your APP_SERVICE_UUID
            .addServiceData(ParcelUuid(appServiceUuid), rollingIdPayload)
            .setIncludeDeviceName(false)
            .build()

        advertiseCallback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                Log.d(
                    TAG,
                    "Advertising started with App Service UUID: $appServiceUuid and Rolling ID Payload."
                )
            }

            override fun onStartFailure(errorCode: Int) {
                Log.e(TAG, "Advertising failed: $errorCode")
            }
        }

        advertiser?.startAdvertising(settings, data, advertiseCallback)
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
    private fun stopAdvertising() {
        if (advertiser != null && advertiseCallback != null) {
            advertiser?.stopAdvertising(advertiseCallback)
            advertiseCallback = null
            Log.d(TAG, "Advertising stopped.")
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

