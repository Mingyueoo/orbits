package com.example.orbits_new

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Build
//导入 NonNull 注解，表示参数、字段或方法返回值不能为空。
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
// 导入 MethodCall，表示从 Flutter 到原生端的方法调用。
import io.flutter.plugin.common.MethodChannel
// 导入 MethodChannel，用于 Flutter 和原生代码之间的通信。
/*
a bridge between your Flutter application and the native Android BLE broadcasting functionality.
It allows Flutter to initiate and stop the BLE advertising service.
 */

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
    }
    //当插件从 Flutter 引擎分离时调用此方法。
    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        //在这里清理资源非常重要,清除方法调用处理程序以防止内存泄漏。
        channel.setMethodCallHandler(null)
    }

    @SuppressLint("ServiceCast")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // 每当从 Flutter 端调用方法时，都会调用此方法。
        when (call.method) {
            // 使用 'when' 表达式根据方法名称处理不同的方法调用。
            "startBroadcast" -> {
                //创建一个 Intent 以启动 BleBroadcastService。
                val intent = Intent(context, BleBroadcastService::class.java)
                // 检查 Android 版本是否为 Android O (API 26) 或更高。
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {

                    //如果是 O 或更高版本，则将服务作为前台服务启动（后台任务所需）。
                    context.startForegroundService(intent)
                } else {
                    // 对于较旧的 Android 版本，正常启动服务。
                    context.startService(intent)
                }
                // 向 Flutter 返回成功结果。
                result.success("Broadcast started")
            }
            "stopBroadcast" -> {
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
                result.success(BleBroadcastService.isServiceActive)
            }
            // 如果方法名无法识别，则向 Flutter 返回 "notImplemented" 结果。
            else -> result.notImplemented()
        }
    }
}