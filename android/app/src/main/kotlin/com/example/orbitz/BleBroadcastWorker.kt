package com.example.orbitz

import android.content.Context
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters
import android.content.Intent

/**
 * WorkManager Worker for BLE broadcasting
 * 确保在系统限制下BLE广播服务能够持续运行
 */
class BleBroadcastWorker(
    context: Context,
    params: WorkerParameters
) : Worker(context, params) {

    companion object {
        private const val TAG = "BleBroadcastWorker"
    }

    override fun doWork(): Result {
        Log.d(TAG, "BLE Broadcast Worker started")

        try {
            val prefs = applicationContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

            // 检查服务是否应该运行
            val shouldRun = prefs.getBoolean("ble_broadcast_service_should_run", false)
            if (!shouldRun) {
                Log.d(TAG, "Broadcast service should not run, skipping")
                return Result.success()
            }

            // 检查服务是否已经在运行
            val isServiceRunning = BleBroadcastService.isServiceActive
            if (isServiceRunning) {
                Log.d(TAG, "Broadcast service is already running, skipping")
                return Result.success()
            }

            // 获取服务参数
            val userUuid = prefs.getString("stored_broadcast_user_uuid", null)
            val secretKey = prefs.getString("stored_broadcast_secret_key", null)

            if (userUuid == null || secretKey == null) {
                Log.w(TAG, "Missing broadcast service parameters")
                return Result.failure()
            }

            // 启动BLE广播服务
            val intent = Intent(applicationContext, BleBroadcastService::class.java).apply {
                action = "ACTION_START_BROADCAST"
                putExtra("userUUID", userUuid)
                putExtra("secretKey", secretKey)
            }

            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                applicationContext.startForegroundService(intent)
            } else {
                applicationContext.startService(intent)
            }

            Log.d(TAG, "BLE Broadcast Service started via WorkManager")
            return Result.success()

        } catch (e: Exception) {
            Log.e(TAG, "BLE Broadcast Worker failed: ${e.message}")
            return Result.failure()
        }
    }
}