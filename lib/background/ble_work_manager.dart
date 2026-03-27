import 'dart:async';
import 'dart:convert';
import 'package:workmanager/workmanager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// WorkManager 后台任务管理器
/// 用于在系统限制下保持BLE服务运行
class BleWorkManager {
  static const String _scanTaskName = "ble_scan_worker";
  static const String _broadcastTaskName = "ble_broadcast_worker";
  static const String _scanTaskTag = "ble_scan_tag";
  static const String _broadcastTaskTag = "ble_broadcast_tag";

  // 任务执行间隔（15分钟）
  static const Duration _workInterval = Duration(minutes: 15);

  /// 初始化WorkManager
  static Future<void> initialize() async {
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: false, // 生产环境设为false
    );
    print("[BleWorkManager] WorkManager initialized");
  }

  /// 注册周期性后台任务
  static Future<void> registerPeriodicTask() async {
    // 先取消现有任务
    await cancelAllTasks();

    // 注册扫描服务任务
    await Workmanager().registerPeriodicTask(
      _scanTaskName,
      _scanTaskName,
      frequency: _workInterval,
      initialDelay: Duration(seconds: 30), // 30秒后开始第一次执行
      constraints: Constraints(
        networkType: NetworkType.notRequired,
        requiresBatteryNotLow: false,
        requiresCharging: false,
        requiresDeviceIdle: false,
        requiresStorageNotLow: false,
      ),
    );

    // 注册广播服务任务
    await Workmanager().registerPeriodicTask(
      _broadcastTaskName,
      _broadcastTaskName,
      frequency: _workInterval,
      initialDelay: Duration(seconds: 45), // 45秒后开始第一次执行，错开时间
      constraints: Constraints(
        networkType: NetworkType.notRequired,
        requiresBatteryNotLow: false,
        requiresCharging: false,
        requiresDeviceIdle: false,
        requiresStorageNotLow: false,
      ),
    );

    print(
      "[BleWorkManager] Periodic tasks registered with interval: $_workInterval",
    );
  }

  /// 取消所有任务
  static Future<void> cancelAllTasks() async {
    await Workmanager().cancelAll();
    print("[BleWorkManager] All tasks cancelled");
  }

  /// 注册一次性任务（用于立即启动服务）
  // static Future<void> registerOneTimeTask() async {
  //   await Workmanager().registerOneOffTask(
  //     _scanTaskName,
  //     _scanTaskTag,
  //     initialDelay: Duration(seconds: 5),
  //     constraints: Constraints(
  //       networkType: NetworkType.notRequired,
  //       requiresBatteryNotLow: false,
  //       requiresCharging: false,
  //       requiresDeviceIdle: false,
  //       requiresStorageNotLow: false,
  //     ),
  //   );
  //
  //   await Workmanager().registerOneOffTask(
  //     _broadcastTaskName,
  //     _broadcastTaskTag,
  //     initialDelay: Duration(seconds: 10),
  //     constraints: Constraints(
  //       networkType: NetworkType.notRequired,
  //       requiresBatteryNotLow: false,
  //       requiresCharging: false,
  //       requiresDeviceIdle: false,
  //       requiresStorageNotLow: false,
  //     ),
  //   );
  //
  //   print("[BleWorkManager] One-time tasks registered");
  // }

  /// 检查任务是否正在运行
  // static Future<bool> isTaskRunning() async {
  //   final prefs = await SharedPreferences.getInstance();
  //   return prefs.getBool('ble_work_task_running') ?? false;
  // }
}

/// WorkManager回调函数
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    print("[BleWorkManager] Task $task started");

    try {
      // 记录任务开始
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('ble_work_task_running', true);

      // 根据任务类型执行不同的操作
      if (task == "ble_scan_worker") {
        await _handleScanServiceTask();
      } else if (task == "ble_broadcast_worker") {
        await _handleBroadcastServiceTask();
      }

      // 记录任务完成
      await prefs.setBool('ble_work_task_running', false);

      print("[BleWorkManager] Task $task completed successfully");
      return Future.value(true);
    } catch (e) {
      print("[BleWorkManager] Task $task failed: $e");
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('ble_work_task_running', false);
      return Future.value(false);
    }
  });
}

/// 处理扫描服务任务
Future<void> _handleScanServiceTask() async {
  try {
    // 检查是否需要启动BLE扫描服务
    final shouldStartService = await _shouldStartBleScanService();

    if (shouldStartService) {
      print("[BleWorkManager] Starting BLE scan service via WorkManager");
      await _startBleScanServiceViaWorkManager();
    } else {
      print(
        "[BleWorkManager] Skipping BLE scan service start - conditions not met",
      );
    }
  } catch (e) {
    print("[BleWorkManager] Error handling scan service task: $e");
  }
}

/// 处理广播服务任务
Future<void> _handleBroadcastServiceTask() async {
  try {
    // 检查是否需要启动BLE广播服务
    final shouldStartService = await _shouldStartBleBroadcastService();

    if (shouldStartService) {
      print("[BleWorkManager] Starting BLE broadcast service via WorkManager");
      await _startBleBroadcastServiceViaWorkManager();
    } else {
      print(
        "[BleWorkManager] Skipping BLE broadcast service start - conditions not met",
      );
    }
  } catch (e) {
    print("[BleWorkManager] Error handling broadcast service task: $e");
  }
}

/// 检查是否应该启动BLE扫描服务
Future<bool> _shouldStartBleScanService() async {
  try {
    final prefs = await SharedPreferences.getInstance();

    // 检查服务是否应该运行
    final shouldRun = prefs.getBool('ble_service_should_run') ?? false;
    if (!shouldRun) {
      print(
        "[BleWorkManager] Scan service should not run according to settings",
      );
      return false;
    }

    // 检查是否有必要的密钥数据
    final hasSecretKey = prefs.getBool('has_secret_key') ?? false;
    final hasUserUuids = prefs.getBool('has_user_uuids') ?? false;

    if (!hasSecretKey || !hasUserUuids) {
      print("[BleWorkManager] Missing required data for BLE scan service");
      return false;
    }

    return true;
  } catch (e) {
    print("[BleWorkManager] Error checking scan service conditions: $e");
    return false;
  }
}

/// 检查是否应该启动BLE广播服务
Future<bool> _shouldStartBleBroadcastService() async {
  try {
    final prefs = await SharedPreferences.getInstance();

    // 检查服务是否应该运行
    final shouldRun =
        prefs.getBool('ble_broadcast_service_should_run') ?? false;
    if (!shouldRun) {
      print(
        "[BleWorkManager] Broadcast service should not run according to settings",
      );
      return false;
    }

    // 检查是否有必要的密钥数据
    final hasBroadcastUserUuid =
        prefs.getBool('has_broadcast_user_uuid') ?? false;
    final hasBroadcastSecretKey =
        prefs.getBool('has_broadcast_secret_key') ?? false;

    if (!hasBroadcastUserUuid || !hasBroadcastSecretKey) {
      print("[BleWorkManager] Missing required data for BLE broadcast service");
      return false;
    }

    return true;
  } catch (e) {
    print("[BleWorkManager] Error checking broadcast service conditions: $e");
    return false;
  }
}

/// 通过WorkManager启动BLE扫描服务
Future<void> _startBleScanServiceViaWorkManager() async {
  try {
    final prefs = await SharedPreferences.getInstance();

    // 获取存储的服务参数
    final secretKey = prefs.getString('stored_secret_key');
    final userUuidsJson = prefs.getString('stored_user_uuids');

    if (secretKey == null || userUuidsJson == null) {
      print("[BleWorkManager] Missing stored scan service parameters");
      return;
    }

    final userUuids = List<String>.from(jsonDecode(userUuidsJson));

    print("[BleWorkManager] Attempting to start native BLE scan service");
    print("[BleWorkManager] SecretKey length: ${secretKey.length}");
    print("[BleWorkManager] UserUUIDs count: ${userUuids.length}");

    // 设置服务参数到SharedPreferences，供原生服务读取
    await prefs.setString('workmanager_secret_key', secretKey);
    await prefs.setString('workmanager_user_uuids', userUuidsJson);
    await prefs.setBool('workmanager_start_service', true);

    print("[BleWorkManager] Scan service parameters set for native service");
  } catch (e) {
    print("[BleWorkManager] Error starting BLE scan service: $e");
  }
}

/// 通过WorkManager启动BLE广播服务
Future<void> _startBleBroadcastServiceViaWorkManager() async {
  try {
    final prefs = await SharedPreferences.getInstance();

    // 获取存储的服务参数
    final userUuid = prefs.getString('stored_broadcast_user_uuid');
    final secretKey = prefs.getString('stored_broadcast_secret_key');

    if (userUuid == null || secretKey == null) {
      print("[BleWorkManager] Missing stored broadcast service parameters");
      return;
    }

    print("[BleWorkManager] Attempting to start native BLE broadcast service");
    print("[BleWorkManager] UserUUID: $userUuid");
    print("[BleWorkManager] SecretKey length: ${secretKey.length}");

    // 设置服务参数到SharedPreferences，供原生服务读取
    await prefs.setString('workmanager_broadcast_user_uuid', userUuid);
    await prefs.setString('workmanager_broadcast_secret_key', secretKey);
    await prefs.setBool('workmanager_start_broadcast_service', true);

    print(
      "[BleWorkManager] Broadcast service parameters set for native service",
    );
  } catch (e) {
    print("[BleWorkManager] Error starting BLE broadcast service: $e");
  }
}
