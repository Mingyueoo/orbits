import 'package:workmanager/workmanager.dart';
import 'package:flutter/services.dart';
import 'package:orbits_new/plugins/ble_uuid_broadcaster.dart';
import 'package:orbits_new/plugins/ble_scan_service.dart';

/// WorkManager 任务唯一名称
const String bleScanTask = "bleScanTask";

/// 后台任务入口（必须加 @pragma 保证 isolate 可执行）
@pragma('vm:entry-point')
void callbackDispatcher() {
  // 在后台isolate中，我们不直接使用Flutter插件，而是通过原生服务
  // 避免MethodChannel初始化问题

  Workmanager().executeTask((task, inputData) async {
    try {
      switch (task) {
        case bleScanTask:
          print("[WorkManager] === BLE 周期任务开始 ===");

          // 1️⃣ 参数检查
          if (inputData == null ||
              !inputData.containsKey('secretKey') ||
              !inputData.containsKey('userUuid') ||
              !inputData.containsKey('knownUserUUIDs')) {
            print("[WorkManager][Error] 缺少必要参数，任务终止。");
            return Future.value(false);
          }

          final String secretKey = inputData['secretKey']!;
          final String userUuid = inputData['userUuid']!;
          final List<String> knownUserUUIDs = List<String>.from(
            inputData['knownUserUUIDs']!,
          );

          print("[WorkManager] 参数验证通过:");
          print("[WorkManager] - secretKey: ${secretKey.length} 字符");
          print("[WorkManager] - userUuid: $userUuid");
          print("[WorkManager] - knownUserUUIDs: ${knownUserUUIDs.length} 个");

          // 2️⃣ 在后台任务中，我们只记录日志，不直接操作BLE
          // BLE服务应该通过前台服务持续运行，WorkManager只是作为备用检查
          print("[WorkManager] 后台任务完成 - BLE服务应该通过前台服务持续运行");
          print("[WorkManager] === BLE 周期任务完成 ===");
          return Future.value(true);

        default:
          print("[WorkManager][Error] 未知任务: $task");
          return Future.value(false);
      }
    } catch (e) {
      // 捕获所有潜在异常
      print("[WorkManager][Error] 任务执行过程中发生未捕获的异常: $e");
      return Future.value(false); // 任务失败
    }
  });
}

/// 初始化 WorkManager（应用启动时调用一次）
Future<void> initWorkManager() async {
  await Workmanager().initialize(callbackDispatcher, isInDebugMode: true);
  print("[WorkManager] 初始化完成。");
}

/// 注册 BLE 周期任务（后台低频扫描）
Future<void> registerBleScanTask({
  required String secretKey,
  required String userUuid,
  required List<String> knownUserUUIDs,
}) async {
  await Workmanager().registerPeriodicTask(
    "ble-scan-task-id",
    bleScanTask,
    frequency: const Duration(minutes: 15), // Android 最小 15 分钟
    constraints: Constraints(
      networkType: NetworkType.notRequired,
      requiresBatteryNotLow: false,
      requiresCharging: false,
    ),
    inputData: {
      'secretKey': secretKey,
      'userUuid': userUuid,
      'knownUserUUIDs': knownUserUUIDs,
    },
  );
  print("[WorkManager] BLE 周期任务已注册。");
}

/// 取消 BLE 周期任务
Future<void> cancelBleScanTask() async {
  await Workmanager().cancelByUniqueName("ble-scan-task-id");
  print("[WorkManager] BLE 周期任务已取消。");
}
