package com.example.orbitz

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.work.WorkManager
import androidx.work.OneTimeWorkRequest
import androidx.work.Constraints
import androidx.work.NetworkType
import java.util.concurrent.TimeUnit

/**
 * 开机自启动广播接收器
 * 监听系统开机完成事件，自动启动BLE服务
 */
class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "BootReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_PACKAGE_REPLACED -> {
                Log.d(TAG, "Boot completed, checking if services should auto-start")
                handleBootCompleted(context)
            }
            else -> {
                Log.d(TAG, "Received unexpected action: ${intent.action}")
            }
        }
    }

    /**
     * 处理开机完成事件
     */
    private fun handleBootCompleted(context: Context) {
        try {
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

            // 检查是否启用了开机自启动
            val autoStartEnabled = prefs.getBoolean("auto_start_enabled", false)
            if (!autoStartEnabled) {
                Log.d(TAG, "Auto-start is disabled, skipping")
                return
            }

            // 检查是否有有效的服务参数
            val secretKey = prefs.getString("stored_secret_key", null)
            val userUuidsJson = prefs.getString("stored_user_uuids", null)
            val userUuid = prefs.getString("stored_broadcast_user_uuid", null)
            val broadcastSecretKey = prefs.getString("stored_broadcast_secret_key", null)

            if (secretKey == null || userUuidsJson == null || userUuid == null || broadcastSecretKey == null) {
                Log.w(TAG, "Missing service parameters for auto-start")
                return
            }

            Log.d(TAG, "Auto-start enabled, scheduling WorkManager tasks")

            // 延迟启动，等待系统完全启动
            scheduleDelayedStart(context)

        } catch (e: Exception) {
            Log.e(TAG, "Error handling boot completed: ${e.message}")
        }
    }

    /**
     * 延迟启动服务
     */
    private fun scheduleDelayedStart(context: Context) {
        try {
            // 创建启动BLE扫描服务的WorkManager任务
            val scanWorkRequest = OneTimeWorkRequest.Builder(BleScanWorker::class.java)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.NOT_REQUIRED)
                        .setRequiresBatteryNotLow(false)
                        .setRequiresCharging(false)
                        .setRequiresDeviceIdle(false)
                        .setRequiresStorageNotLow(false)
                        .build()
                )
                .setInitialDelay(30, TimeUnit.SECONDS) // 延迟30秒启动
                .addTag("boot_scan_worker")
                .build()

            // 创建启动BLE广播服务的WorkManager任务
            val broadcastWorkRequest = OneTimeWorkRequest.Builder(BleBroadcastWorker::class.java)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.NOT_REQUIRED)
                        .setRequiresBatteryNotLow(false)
                        .setRequiresCharging(false)
                        .setRequiresDeviceIdle(false)
                        .setRequiresStorageNotLow(false)
                        .build()
                )
                .setInitialDelay(35, TimeUnit.SECONDS) // 延迟35秒启动
                .addTag("boot_broadcast_worker")
                .build()

            // 提交任务
            WorkManager.getInstance(context).enqueue(scanWorkRequest)
            WorkManager.getInstance(context).enqueue(broadcastWorkRequest)

            Log.d(TAG, "WorkManager tasks scheduled for auto-start")

        } catch (e: Exception) {
            Log.e(TAG, "Error scheduling WorkManager tasks: ${e.message}")
        }
    }
}