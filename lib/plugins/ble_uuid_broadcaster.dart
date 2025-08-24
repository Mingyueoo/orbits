import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:orbits_new/utils/secure_storage_service.dart';

/// 统一的 BLE UUID 广播类，前台 / 后台统一使用 startBroadcastWithKeys
class BleUuidBroadcaster {
  final MethodChannel _channel = const MethodChannel('ble_uuid_broadcaster');

  // 添加回调函数类型定义
  Function()? _onServiceRestarted;

  /// 设置服务重启回调
  void setServiceRestartedCallback(Function() callback) {
    _onServiceRestarted = callback;
  }

  /// 初始化方法通道监听器
  void _setupMethodCallHandler() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'serviceRestarted':
          print(
            "[BleUuidBroadcaster] Received service restart notification from native",
          );
          _onServiceRestarted?.call();
          break;
        default:
          print("[BleUuidBroadcaster] Unknown method call: ${call.method}");
      }
    });
  }

  /// 构造函数，设置方法调用处理器
  /// 使用延迟初始化，避免在WorkManager后台isolate中初始化失败
  BleUuidBroadcaster() {
    // 延迟设置MethodCallHandler，避免在后台isolate中初始化失败
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _setupMethodCallHandler();
      });
    } catch (e) {
      // 在后台isolate中，WidgetsBinding可能不可用，忽略错误
      print(
        "[BleUuidBroadcaster] Skipping MethodCallHandler setup in background isolate: $e",
      );
    }
  }

  /// 启动 BLE 广播服务（核心方法）。
  /// [secretKey] 与 [userUuid] 由调用方提供（适合后台任务）。
  // Future<void> startBroadcastWithKeys({
  Future<void> startBroadcast({
    required String secretKey,
    required String userUuid,
  }) async {
    try {
      print("[BleUuidBroadcaster] Calling native startBroadcast with:");
      print("[BleUuidBroadcaster] - userUuid: $userUuid");
      print("[BleUuidBroadcaster] - secretKey length: ${secretKey.length}");
      final result = await _channel.invokeMethod('startBroadcast', {
        'userUUID': userUuid,
        'secretKey': secretKey,
      });
      print("[BleUuidBroadcaster] Native method call result: $result");
      print("[BleUuidBroadcaster] Broadcast started with provided keys.");
    } on PlatformException catch (e) {
      print(
        "[BleUuidBroadcaster] Error starting broadcast with keys: ${e.message}",
      );
      print("[BleUuidBroadcaster] Error details: ${e.details}");
      print("[BleUuidBroadcaster] Error code: ${e.code}");
    } catch (e) {
      print("[BleUuidBroadcaster] Unexpected error: $e");
    }
  }

  /// 停止 BLE 广播服务
  Future<void> stopBroadcast() async {
    try {
      await _channel.invokeMethod('stopBroadcast');
      print("[BleUuidBroadcaster] Broadcast stopped.");
    } on PlatformException catch (e) {
      print("[BleUuidBroadcaster] Error stopping broadcast: ${e.message}");
    }
  }

  /// 设置广播模式 ('high_frequency' 或 'low_power')
  Future<void> setAdvertisingMode(String mode) async {
    try {
      await _channel.invokeMethod('setAdvertisingMode', {'mode': mode});
      print("[BleUuidBroadcaster] Advertising mode set to $mode.");
    } on PlatformException catch (e) {
      print(
        "[BleUuidBroadcaster] Error setting advertising mode: ${e.message}",
      );
    }
  }

  /// 检查 BLE 广播服务是否运行中
  Future<bool> isServiceRunning() async {
    try {
      final bool? isRunning = await _channel.invokeMethod('isServiceRunning');
      return isRunning ?? false;
    } on PlatformException catch (e) {
      print(
        "[BleUuidBroadcaster] Error checking service running status: ${e.message}",
      );
      return false;
    }
  }
}
