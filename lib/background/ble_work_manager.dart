import 'package:workmanager/workmanager.dart';
import 'package:flutter/services.dart';
import 'package:orbits_new/plugins/ble_uuid_broadcaster.dart';
import 'package:orbits_new/plugins/ble_scan_service.dart';

// Define unique names for WorkManager tasks
const String bleScanTask = "bleScanTask";

// WorkManager tasks run in a separate isolate, requiring their own BluetoothScanService instance
final BluetoothScanService _bluetoothScanServiceForWorkmanager =
    BluetoothScanService();

// Entry point function for Workmanager tasks.
// The @pragma('vm:entry-point') annotation is required, allowing Workmanager to execute this function in a separate isolate.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    switch (task) {
      case bleScanTask:
        print(
          "[Workmanager] Executing BLE service restart task.",
        ); // Log task execution

        try {
          // Attempt to start BLE broadcast foreground service
          // WorkManager tasks directly call static methods of BleUuidBroadcaster to send start commands to the native service.
          await BleUuidBroadcaster.startBroadcast();
          print("[Workmanager] BleBroadcastService start command sent.");
        } on PlatformException catch (e) {
          print(
            "[Workmanager] Failed to send start command for BleBroadcastService: ${e.message}",
          );
        }

        try {
          // Attempt to start BLE scan foreground service
          // WorkManager tasks call methods on the BluetoothScanService instance to send start commands to the native service.
          // First, check if the service is already running to avoid unnecessary start commands.
          final bool isScanServiceRunning =
              await _bluetoothScanServiceForWorkmanager.isServiceRunning();
          if (!isScanServiceRunning) {
            await _bluetoothScanServiceForWorkmanager.startScanningService();
            print("[Workmanager] BleScanForegroundService start command sent.");
          } else {
            print("[Workmanager] BleScanForegroundService already running.");
          }
        } on PlatformException catch (e) {
          print(
            "[Workmanager] Failed to send start command for BleScanForegroundService: ${e.message}",
          );
        }

        print(
          "[Workmanager] BLE service restart task completed.",
        ); // Log task completion
        return Future.value(true); // Task completed successfully
      default:
        print("[Workmanager] Unknown task: $task"); // Log unknown task
        return Future.value(false); // Unknown task, return failure
    }
  });
}

/// Initializes Workmanager
/// Must be called once at application startup.
Future<void> initWorkManager() async {
  await Workmanager().initialize(
    callbackDispatcher, // Specify the entry point function for WorkManager tasks
    isInDebugMode: true, // Enable debug logs in development mode
  );
  print("[Workmanager] WorkManager initialized."); // Add initialization log
}

/// Registers a periodic BLE scan task
/// Call when the user enables the Bluetooth detection service.
Future<void> registerBleScanTask() async {
  await Workmanager().registerPeriodicTask(
    "ble-scan-task-id", // Unique task ID, used for registration and cancellation
    bleScanTask, // Task name, corresponds to the case in callbackDispatcher
    frequency: const Duration(
      minutes: 15,
    ), // Task execution frequency, minimum 15 minutes on Android
    constraints: Constraints(
      // Constraints for task execution
      networkType: NetworkType.notRequired, // No network connection required
      requiresBatteryNotLow: false, // Does not require battery not low
      requiresCharging: false, // Does not require device to be charging
    ),
    // Can add initialDelay: Duration(seconds: 10), if you want the task to execute for the first time after a delay
  );
  print(
    "[Workmanager] Periodic task 'ble-scan-task-id' registered.",
  ); // Add registration log
}

/// Cancels the periodic BLE scan task
/// Call when the user disables the Bluetooth detection service.
Future<void> cancelBleScanTask() async {
  await Workmanager().cancelByUniqueName(
    "ble-scan-task-id",
  ); // Cancel task by unique ID
  print(
    "[Workmanager] Periodic task 'ble-scan-task-id' cancelled.",
  ); // Add cancellation log
}
