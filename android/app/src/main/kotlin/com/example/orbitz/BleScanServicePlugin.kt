package com.example.orbitz

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.annotation.NonNull
import androidx.core.content.ContextCompat
import io.flutter.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * BleScanServicePlugin - Flutter与Android原生BLE扫描服务的桥梁
 *
 * 功能：
 * - 启动/停止BLE扫描前台服务
 * - 设置扫描模式
 * - 查询服务运行状态
 * - 处理扫描结果事件流
 *
 * 优化点：
 * - 简化启动流程，移除重复的MethodChannel调用
 * - 添加权限预检查
 * - 统一错误处理
 * - 改进日志记录
 */
class BleScanServicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel

    companion object {
        private const val TAG = "BleScanServicePlugin"
    }

    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext

        // 创建MethodChannel用于Flutter调用原生方法
        methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "ble_scan_service")
        methodChannel.setMethodCallHandler(this)

        // 创建EventChannel用于发送扫描结果流到Flutter
        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "ble_scan_results")
        eventChannel.setStreamHandler(this)

        Log.d(TAG, "Plugin attached to engine. Channels initialized.")
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        // 清理资源，防止内存泄漏
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        BleScanForegroundService.eventSink = null
        Log.d(TAG, "Plugin detached from engine. Channels cleared.")
    }

    @SuppressLint("ServiceCast")
    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: MethodChannel.Result) {
        when (call.method) {
            "startScanService" -> handleStartScanService(call, result)
            "stopScanService" -> handleStopScanService(result)
            "setScanMode" -> handleSetScanMode(call, result)
            "isServiceRunning" -> handleIsServiceRunning(result)
            else -> {
                Log.w(TAG, "Unknown method called from Flutter: ${call.method}")
                result.notImplemented()
            }
        }
    }

    /**
     * 处理启动扫描服务请求
     */
    private fun handleStartScanService(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "Received startScanService call from Flutter.")

        try {
            // 提取参数
            val args = call.arguments as Map<String, Any>?
            val secretKey = args?.get("secretKey") as String?
            val knownUserUUIDs = args?.get("userUUIDs") as List<String>?

            Log.d(TAG, "Extracted secretKey length: ${secretKey?.length}")
            Log.d(TAG, "Extracted knownUserUUIDs count: ${knownUserUUIDs?.size}")

            // 验证参数
            if (secretKey.isNullOrEmpty()) {
                Log.e(TAG, "Missing required parameter: secretKey")
                result.error("MISSING_PARAMETERS", "secretKey is required", null)
                return
            }

            if (knownUserUUIDs == null) {
                Log.e(TAG, "knownUserUUIDs is null")
                result.error("MISSING_PARAMETERS", "knownUserUUIDs cannot be null", null)
                return
            }

            // 预检查权限
            if (!checkRequiredPermissions()) {
                Log.e(TAG, "Missing required permissions")
                result.error("PERMISSION_DENIED", "Missing required permissions for foreground service", null)
                return
            }

            // 设置MethodChannel引用
            BleScanForegroundService.flutterMethodChannel = methodChannel

            // 创建启动服务的Intent
            val intent = Intent(context, BleScanForegroundService::class.java).apply {
                action = "ACTION_START_SCAN_SERVICE"
                putExtra("secretKey", secretKey)
                putStringArrayListExtra("knownUserUUIDs", ArrayList(knownUserUUIDs))
            }

            // 启动前台服务
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }

            Log.d(TAG, "Foreground service start command sent successfully")
            result.success(true)

        } catch (e: Exception) {
            Log.e(TAG, "Error starting scan service: ${e.message}", e)
            result.error("START_SERVICE_ERROR", "Failed to start service: ${e.message}", null)
        }
    }

    /**
     * 处理停止扫描服务请求
     */
    private fun handleStopScanService(result: MethodChannel.Result) {
        Log.d(TAG, "Received stopScanService call from Flutter.")

        try {
            val intent = Intent(context, BleScanForegroundService::class.java)
            context.stopService(intent)
            Log.d(TAG, "Service stop command sent successfully")
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping scan service: ${e.message}", e)
            result.error("STOP_SERVICE_ERROR", "Failed to stop service: ${e.message}", null)
        }
    }

    /**
     * 处理设置扫描模式请求
     */
    private fun handleSetScanMode(call: MethodCall, result: MethodChannel.Result) {
        val mode = call.argument<String>("mode")
        Log.d(TAG, "Received setScanMode call from Flutter: $mode")

        if (mode != null) {
            try {
                val intent = Intent(context, BleScanForegroundService::class.java).apply {
                    action = "ACTION_SET_SCAN_MODE"
                    putExtra("mode", mode)
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }

                Log.d(TAG, "Scan mode update command sent successfully")
                result.success(true)
            } catch (e: Exception) {
                Log.e(TAG, "Error setting scan mode: ${e.message}", e)
                result.error("SET_MODE_ERROR", "Failed to set scan mode: ${e.message}", null)
            }
        } else {
            Log.e(TAG, "Scan mode argument is null.")
            result.error("INVALID_ARGUMENT", "Scan mode cannot be null", null)
        }
    }

    /**
     * 处理查询服务运行状态请求
     */
    private fun handleIsServiceRunning(result: MethodChannel.Result) {
        Log.d(TAG, "Received isServiceRunning call from Flutter.")
        result.success(BleScanForegroundService.isServiceActive)
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

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        BleScanForegroundService.eventSink = events
        Log.d(TAG, "EventChannel onListen called, setting eventSink.")
    }

    override fun onCancel(arguments: Any?) {
        BleScanForegroundService.eventSink = null
        Log.d(TAG, "EventChannel onCancel called, clearing eventSink.")
    }
}