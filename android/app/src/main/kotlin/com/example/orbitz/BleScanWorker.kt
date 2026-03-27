package com.example.orbitz

import android.content.Context
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters
import android.content.Intent
import org.json.JSONArray

/**
 * WorkManager Worker for BLE scanning
 * 确保在系统限制下BLE服务能够持续运行
 */
class BleScanWorker(
    context: Context,
    params: WorkerParameters
) : Worker(context, params) {

    companion object {
        private const val TAG = "BleScanWorker"
    }

    override fun doWork(): Result {
        Log.d(TAG, "BLE Scan Worker started")

        try {
            val prefs = applicationContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

            // 检查服务是否应该运行
            val shouldRun = prefs.getBoolean("ble_service_should_run", false)
            if (!shouldRun) {
                Log.d(TAG, "Service should not run, skipping")
                return Result.success()
            }

            // 检查服务是否已经在运行
            val isServiceRunning = BleScanForegroundService.isServiceActive
            if (isServiceRunning) {
                Log.d(TAG, "Service is already running, skipping")
                return Result.success()
            }

            // 获取服务参数
            val secretKey = prefs.getString("stored_secret_key", null)
            val userUuidsJson = prefs.getString("stored_user_uuids", null)

            if (secretKey == null || userUuidsJson == null) {
                Log.w(TAG, "Missing service parameters")
                return Result.failure()
            }

            // 解析用户UUID列表
            val userUuids = try {
                val jsonArray = JSONArray(userUuidsJson)
                (0 until jsonArray.length()).map { jsonArray.getString(it) }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to parse user UUIDs: ${e.message}")
                return Result.failure()
            }

            // 启动BLE扫描服务
            val intent = Intent(applicationContext, BleScanForegroundService::class.java).apply {
                action = "ACTION_START_SCAN_SERVICE"
                putExtra("secretKey", secretKey)
                putStringArrayListExtra("knownUserUUIDs", ArrayList(userUuids))
            }

            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                applicationContext.startForegroundService(intent)
            } else {
                applicationContext.startService(intent)
            }

            Log.d(TAG, "BLE Scan Service started via WorkManager")
            return Result.success()

        } catch (e: Exception) {
            Log.e(TAG, "BLE Scan Worker failed: ${e.message}")
            return Result.failure()
        }
    }
}