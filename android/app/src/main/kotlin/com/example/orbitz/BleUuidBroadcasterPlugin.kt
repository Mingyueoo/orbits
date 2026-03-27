package com.example.orbitz

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.annotation.NonNull
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.Log

/**
 * BleUuidBroadcasterPlugin - Flutter与Android原生BLE广播服务的桥梁
 *
 * 功能：
 * - 启动/停止BLE广播前台服务
 * - 设置广播模式
 * - 查询服务运行状态
 *
 * 优化点：
 * - 添加权限预检查
 * - 统一错误处理
 * - 改进日志记录
 * - 简化启动流程
 */
class BleUuidBroadcasterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var context: Context
    private lateinit var channel: MethodChannel

    companion object {
        private const val TAG = "BleUuidBroadcasterPlugin"
    }

    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "ble_uuid_broadcaster")
        channel.setMethodCallHandler(this)
        Log.d(TAG, "Plugin attached to engine. Channels initialized.")
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        Log.d(TAG, "Plugin detached from engine. Channels cleared.")
    }

    @SuppressLint("ServiceCast")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startBroadcast" -> handleStartBroadcast(call, result)
            "stopBroadcast" -> handleStopBroadcast(result)
            "setAdvertisingMode" -> handleSetAdvertisingMode(call, result)
            "isServiceRunning" -> handleIsServiceRunning(result)
            else -> result.notImplemented()
        }
    }

    /**
     * 处理启动广播服务请求
     */
    private fun handleStartBroadcast(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "Received startBroadcast call from Flutter.")

        try {
            // 提取参数
            val args = call.arguments as Map<String, Any>?
            val userUUID = args?.get("userUUID") as String?
            val secretKey = args?.get("secretKey") as String?

            Log.d(TAG, "Extracted userUUID: $userUUID")
            Log.d(TAG, "Extracted secretKey length: ${secretKey?.length}")

            // 验证参数
            if (userUUID.isNullOrEmpty() || secretKey.isNullOrEmpty()) {
                Log.e(TAG, "Missing required parameters: userUUID or secretKey")
                result.error("MISSING_PARAMETERS", "userUUID and secretKey are required", null)
                return
            }

            // 预检查权限
            if (!checkRequiredPermissions()) {
                Log.e(TAG, "Missing required permissions")
                result.error("PERMISSION_DENIED", "Missing required permissions for foreground service", null)
                return
            }

            // 创建Intent并传递参数
            val intent = Intent(context, BleBroadcastService::class.java).apply {
                action = "ACTION_START_BROADCAST"
                putExtra("userUUID", userUUID)
                putExtra("secretKey", secretKey)
            }

            // 启动前台服务
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }

            Log.d(TAG, "Foreground service start command sent successfully")
            result.success("Broadcast started")

        } catch (e: Exception) {
            Log.e(TAG, "Error starting broadcast service: ${e.message}", e)
            result.error("START_SERVICE_ERROR", "Failed to start service: ${e.message}", null)
        }
    }

    /**
     * 处理停止广播服务请求
     */
    private fun handleStopBroadcast(result: MethodChannel.Result) {
        Log.d(TAG, "Received stopBroadcast call from Flutter.")

        try {
            val intent = Intent(context, BleBroadcastService::class.java)
            context.stopService(intent)
            Log.d(TAG, "Service stop command sent successfully")
            result.success("Broadcast stopped")
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping broadcast service: ${e.message}", e)
            result.error("STOP_SERVICE_ERROR", "Failed to stop service: ${e.message}", null)
        }
    }

    /**
     * 处理设置广播模式请求
     */
    private fun handleSetAdvertisingMode(call: MethodCall, result: MethodChannel.Result) {
        val mode = call.argument<String>("mode")
        Log.d(TAG, "Received setAdvertisingMode call from Flutter: $mode")

        if (mode != null) {
            try {
                val intent = Intent(context, BleBroadcastService::class.java).apply {
                    action = "ACTION_SET_ADVERTISING_MODE"
                    putExtra("mode", mode)
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }

                Log.d(TAG, "Advertising mode update command sent successfully")
                result.success("Advertising mode set to $mode")
            } catch (e: Exception) {
                Log.e(TAG, "Error setting advertising mode: ${e.message}", e)
                result.error("SET_MODE_ERROR", "Failed to set advertising mode: ${e.message}", null)
            }
        } else {
            Log.e(TAG, "Advertising mode argument is null")
            result.error("INVALID_ARGUMENT", "Advertising mode cannot be null", null)
        }
    }

    /**
     * 处理查询服务运行状态请求
     */
    private fun handleIsServiceRunning(result: MethodChannel.Result) {
        Log.d(TAG, "Received isServiceRunning call from Flutter.")
        result.success(BleBroadcastService.isServiceActive)
    }

    /**
     * 检查启动前台服务所需的权限
     */
    private fun checkRequiredPermissions(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) { // API 34+
            val hasForegroundServiceLocation = ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.FOREGROUND_SERVICE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED

            val hasLocationPermission = ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED ||
                    ContextCompat.checkSelfPermission(
                        context,
                        android.Manifest.permission.ACCESS_COARSE_LOCATION
                    ) == PackageManager.PERMISSION_GRANTED

            Log.d(TAG, "Foreground service location permission: $hasForegroundServiceLocation")
            Log.d(TAG, "Location permission: $hasLocationPermission")

            return hasForegroundServiceLocation && hasLocationPermission
        }
        return true // 对于较低版本的Android，不需要这个权限
    }
}