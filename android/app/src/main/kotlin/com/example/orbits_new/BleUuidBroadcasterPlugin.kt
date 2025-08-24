package com.example.orbits_new

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.Log

class BleUuidBroadcasterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    //用于 Android 应用程序上下文
    //用于 MethodChannel 实例
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    //当plugin附加到 Flutter 引擎时调用此方法,在这里设置通信通道
    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        //创建一个新的 MethodChannel，具有唯一的名称（"ble_uuid_broadcaster"）和二进制消息传递器。
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "ble_uuid_broadcaster")
        //将此插件实例设置为此通道上的方法调用的处理程序
        channel.setMethodCallHandler(this)
        Log.d("BleUuidBroadcasterPlugin", "Plugin attached to engine. Channels initialized.")
    }
    //当插件从 Flutter 引擎分离时调用此方法。
    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        //在这里清理资源非常重要,清除方法调用处理程序以防止内存泄漏。
        channel.setMethodCallHandler(null)
        Log.d("BleUuidBroadcasterPlugin", "Plugin detached from engine. Channels cleared.")
    }

    @SuppressLint("ServiceCast")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // 每当从 Flutter 端调用方法时，都会调用此方法。
        when (call.method) {
            // 使用 'when' 表达式根据方法名称处理不同的方法调用。
            "startBroadcast" -> {
                Log.d("BleUuidBroadcasterPlugin", "Received startBroadcast call from Flutter.")
                // 提取Flutter传递的参数
                val args = call.arguments as Map<String, Any>?
                val userUUID = args?.get("userUUID") as String?
                val secretKey = args?.get("secretKey") as String?

                Log.d("BleUuidBroadcasterPlugin", "Extracted userUUID: $userUUID")
                Log.d("BleUuidBroadcasterPlugin", "Extracted secretKey length: ${secretKey?.length}")

                // 验证参数
                if (userUUID.isNullOrEmpty() || secretKey.isNullOrEmpty()) {
                    Log.e("BleUuidBroadcasterPlugin", "Missing required parameters: userUUID or secretKey")
                    result.error("MISSING_PARAMETERS", "userUUID and secretKey are required", null)
                    return
                }

                // 创建Intent并传递参数
                val intent = Intent(context, BleBroadcastService::class.java)
                intent.action = "ACTION_START_BROADCAST"
                intent.putExtra("userUUID", userUUID)
                intent.putExtra("secretKey", secretKey)

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }

                result.success("Broadcast started")
            }
            "stopBroadcast" -> {
                Log.d("BleUuidBroadcasterPlugin", "Received stopBroadcast call from Flutter.")
                //创建一个 Intent 以停止 BleBroadcastService。
                val intent = Intent(context, BleBroadcastService::class.java)
                context.stopService(intent)
                result.success("Broadcast stopped")
            }

            "setAdvertisingMode" -> { // 新增的方法处理：设置广告模式
                val mode = call.argument<String>("mode") // 获取从 Flutter 传递的模式字符串
                val intent = Intent(context, BleBroadcastService::class.java).apply {
                    action = "ACTION_SET_ADVERTISING_MODE" // 定义一个自定义动作，用于服务识别
                    putExtra("mode", mode) // 将模式字符串作为 extra 传递
                }
                Log.d("BleUuidBroadcasterPlugin", "Received setAdvertisingMode call from Flutter.")

                // 启动服务。如果服务已运行，这将调用其 onStartCommand 方法。
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                result.success("广告模式设置为 $mode")
            }

            "isServiceRunning" -> {
                // 优化后的方法：检查 BleBroadcastService 是否正在运行。
                // 推荐使用服务内部的静态标志来判断，而不是 ActivityManager.getRunningServices()。
                // 这个方法在 Android 5.0 (API 21) 及更高版本上受到严格限制，无法可靠地检测其他应用的或非活跃的前台服务。
                // 假设 BleBroadcastService 内部维护了一个静态标志 `isServiceActive`。
                Log.d("BleUuidBroadcasterPlugin", "Received isServiceRunning call from Flutter.")

                result.success(BleBroadcastService.isServiceActive)
            }
            // 如果方法名无法识别，则向 Flutter 返回 "notImplemented" 结果。
            else -> result.notImplemented()
        }
    }
}