import 'dart:async';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:orbits_new/database/models/contact_device.dart';
import 'package:orbits_new/database/dao/device_dao.dart';
import 'dart:convert'; // JSON encoding/decoding library

// 这个文件热启动是没有问题的！
// Defines scan mode enum, these modes will be passed to the native service
enum ScanMode { highFrequency, lowPower }

class BluetoothScanService {
  // Defines channels for communication with native code
  static const MethodChannel _methodChannel = MethodChannel(
    'ble_scan_service',
  ); // Used to invoke native methods
  static const EventChannel _eventChannel = EventChannel(
    'ble_scan_results',
  ); // Used to receive native event streams

  // Database and contact duration logic remain on the Dart side
  final Map<String, DateTime> _firstSeenMap =
      {}; // Stores UUID and first seen time of discovered devices
  final Map<String, int> _contactDurationMap =
      {}; // Stores device UUID and contact duration
  // final int contactThresholdMinutes = 15; // Defines contact duration threshold (15 minutes)
  // final int contactThresholdMinutes = 1; // for testing, 1 minutes.
  final DeviceDao deviceDao = DeviceDao(); // Device data access object instance

  StreamSubscription?
  _scanResultsSubscription; // Subscription for listening to native scan results stream

  // Scan mode is still maintained on the Dart side and passed to native
  ScanMode _currentScanMode =
      ScanMode.lowPower; // Current scan mode, defaults to low power

  // Constructor, now only handles database setup
  BluetoothScanService();

  /// Initializes the service, requesting necessary permissions.
  /// Bluetooth enabled check is now performed by main.dart before starting the service, or handled internally by the native service.
  Future<void> init() async {
    await _requestPermissions();
    print(
      "[BluetoothScanService] Dart: Service initialization complete, permissions requested.",
    ); // Add log
  }

  /// Requests necessary Bluetooth and location permissions
  Future<void> _requestPermissions() async {
    await [
      Permission.bluetooth,
      // Bluetooth permission
      Permission.locationWhenInUse,
      // Location permission while in use (required for BLE scanning)
      Permission.bluetoothScan,
      // Android 12+ Bluetooth scan permission
      Permission.bluetoothConnect,
      // Android 12+ Bluetooth connect permission
      Permission.bluetoothAdvertise,
      // Android 12+ Bluetooth advertise permission (though it's a scan service, often also required)
      // If continuous background scanning is needed, ACCESS_BACKGROUND_LOCATION (locationAlways) might also be required, but use with caution and inform the user
      // Permission.locationAlways,
    ].request(); // Request all listed permissions
    print(
      "[BluetoothScanService] Dart: Bluetooth and location permission requests completed.",
    ); // Add log
  }

  /// Sets the scan mode.
  /// [mode] can be 'high_frequency' or 'low_power'.
  /// This method passes the mode to the native service.
  Future<void> setScanMode(String mode) async {
    ScanMode newMode;
    switch (mode) {
      case 'high_frequency':
        newMode = ScanMode.highFrequency;
        break;
      case 'low_power':
        newMode = ScanMode.lowPower;
        break;
      default:
        newMode = ScanMode.lowPower; // Default to low power
        break;
    }

    if (_currentScanMode != newMode) {
      _currentScanMode = newMode; // Update current mode
      print(
        "[BluetoothScanService] Dart: Scan mode updated to: $_currentScanMode",
      ); // Add log
      try {
        // Invoke native method to set scan mode
        await _methodChannel.invokeMethod('setScanMode', {'mode': mode});
      } on PlatformException catch (e) {
        print(
          "[BluetoothScanService] Dart: Failed to set scan mode: ${e.message}",
        ); // Print error message
      }
    }
  }

  /// Starts the native scan service (sends start command to native)
  /// Now requires the secretKey and a list of knownUserUUIDs to be passed.
  Future<void> startScanningService({
    required String secretKey,
    required List<String> knownUserUUIDs,
  }) async {
    print(
      "[BluetoothScanService] Dart: Start native scan service command sent with HMAC data.",
    ); // Add log
    print("[BluetoothScanService] Dart: SecretKey length: ${secretKey.length}");
    print(
      "[BluetoothScanService] Dart: KnownUserUUIDs count: ${knownUserUUIDs.length}",
    );
    print("[BluetoothScanService] Dart: KnownUserUUIDs: $knownUserUUIDs");
    try {
      // Invoke native method to start service, passing the necessary data
      final result = await _methodChannel.invokeMethod('startScanService', {
        'secretKey': secretKey,
        'userUUIDs': knownUserUUIDs,
        'mode': _currentScanMode == ScanMode.highFrequency
            ? 'high_frequency'
            : 'low_power',
      });
      print("[BluetoothScanService] Dart: Native method call result: $result");
      // Start listening to native scan results only after the service has been successfully started
      _listenToNativeScanResults();
    } on PlatformException catch (e) {
      print(
        "[BluetoothScanService] Dart: Failed to start native scan service: ${e.message}",
      );
      print("[BluetoothScanService] Dart: Error details: ${e.details}");
      print("[BluetoothScanService] Dart: Error code: ${e.code}");
    } catch (e) {
      print(
        "[BluetoothScanService] Dart: Unexpected error starting scan service: $e",
      ); // Print error message
    }
  }

  /// Stops the native scan service (sends stop command to native)
  Future<void> stopScanningService() async {
    print(
      "[BluetoothScanService] Dart: Stop native scan service command sent.",
    ); // Add log
    try {
      await _methodChannel.invokeMethod(
        'stopScanService',
      ); // Invoke native method to stop service
      _scanResultsSubscription
          ?.cancel(); // Cancel subscription to native scan results
      _firstSeenMap.clear(); // Clear map when stopping
      _contactDurationMap.clear(); // Clear map when stopping
      print(
        "[BluetoothScanService] Dart: Scan results subscription cancelled, maps cleared.",
      ); // Add log
    } on PlatformException catch (e) {
      print(
        "[BluetoothScanService] Dart: Failed to stop native scan service: ${e.message}",
      ); // Print error message
    }
  }

  /// Checks if the native scan service is running
  Future<bool> isServiceRunning() async {
    try {
      // Invoke native method to query service status (method name consistent with native plugin)
      final bool? isRunning = await _methodChannel.invokeMethod(
        'isServiceRunning',
      );
      print("[BluetoothScanService] Dart: isServiceRunning is $isRunning}");
      return isRunning ?? false; // Default to false if native returns null
    } on PlatformException catch (e) {
      print(
        "[BluetoothScanService] Dart: Failed to check service running status: ${e.message}",
      ); // Print error message
      return false; // Return false on platform exception
    }
  }

  /// Listens to the scan results stream from the native service
  void _listenToNativeScanResults() {
    print("[BluetoothScanService] Setting up scan results listener...");
    // Only set up the subscription if it's not already active
    // 强制取消现有订阅并重新设置
    _scanResultsSubscription?.cancel();
    _scanResultsSubscription = null;
    // if (_scanResultsSubscription == null ||
    //     _scanResultsSubscription!.isPaused) {

    _scanResultsSubscription = _eventChannel.receiveBroadcastStream().listen(
      (dynamic scanResultJson) async {
        print("[BluetoothScanService] Received scan result: $scanResultJson");
        // Assuming native side sends JSON string
        final Map<String, dynamic> scanResultMap = jsonDecode(
          scanResultJson,
        ); // Parse JSON string

        // Parse required data from native results (must match native-side data structure)
        final String userUuid =
            scanResultMap['uuid']
                as String; // Device unique identifier (usually MAC address)
        final int rssi = scanResultMap['rssi'] as int; // Signal strength
        // More fields like device name, manufacturer data can be added to scanResultMap as needed

        final now = DateTime.now(); // Get current time
        print(
          "[BluetoothScanService] Dart: Debug - UserUUID: $userUuid, [Valid rssi] $rssi, CurrentTime: $now",
        );

        // 只处理已知的真实UUID，跳过unknown设备
        if (userUuid.startsWith('unknown_device_')) {
          print(
            "[BluetoothScanService] Dart: Skipping unknown device: $userUuid",
          );
          return;
        }

        final String secretKey = scanResultMap['secretKey'] as String;

        if (rssi > -70) {
          print(
            "[BluetoothScanService] Dart: [Valid rssi] $rssi for device $userUuid",
          );

          final existing = await deviceDao.getDeviceByUUID(userUuid);
          if (existing == null) {
            // First contact: insert new record
            final device = ContactDevice(
              uuid: userUuid,
              firstSeen: now.toIso8601String(),
              // Convert to ISO 8601 string for storage
              lastSeen: now.toIso8601String(),
              rssi: rssi,
              secretKey: secretKey,
              contactDuration: 1, // 首次接触，累计时长为1分钟
            );
            await deviceDao.insertDevice(device);
            print(
              "[BluetoothScanService] New device inserted: $userUuid, contactDuration: 1",
            );
          } else {
            final lastSeen = DateTime.tryParse(existing.lastSeen);

            if (lastSeen != null) {
              // 计算从上一次扫描到这一次扫描的间隔时间（分钟）
              final durationToAdd = now.difference(lastSeen).inMinutes;
              // 确保时间间隔是正数且小于某个阈值（例如10分钟），避免错误数据累加
              if (durationToAdd > 0 && durationToAdd <= 10) {
                final newTotalDuration =
                    existing.contactDuration + durationToAdd;
                // 更新 lastSeen 和 contactDuration
                await deviceDao.updateLastSeenAndDuration(
                  userUuid,
                  now.toIso8601String(),
                  newTotalDuration,
                );
                print(
                  "[BluetoothScanService] Device updated: $userUuid, newTotalDuration: $newTotalDuration",
                );
                // 更新 rssi
                await deviceDao.updateRssi(userUuid, rssi);
              } else if (durationToAdd > 10) {
                // 如果间隔时间过长，说明设备已断开连接，重新计算
                // 此时可以将 firstSeen 更新为 now，并重置 duration
                // 但考虑到你的需求，更简单的方式是只更新 lastSeen，不增加时长
                await deviceDao.updateLastSeenAndDuration(
                  userUuid,
                  now.toIso8601String(),
                  existing.contactDuration,
                );
              }
            } else {
              // 处理 lastSeen 解析失败的情况，只更新 lastSeen
              await deviceDao.updateLastSeenAndDuration(
                userUuid,
                now.toIso8601String(),
                existing.contactDuration,
              );
            }
          }
          // }
          // }
        }
      },
      onError: (e) {
        print("[BluetoothScanService] Dart: Scan results stream error: $e");
      },
      onDone: () {
        print("[BluetoothScanService] Dart: Scan results stream completed.");
      },
    );
    print("[BluetoothScanService] Scan results listener setup completed");
  }

  /// 刷新已知用户UUID列表
  Future<void> refreshKnownUserUUIDs() async {
    try {
      final List<String> knownUserUUIDs = await deviceDao.getAllUserUUIDs();
      await updateKnownUserUUIDs(knownUserUUIDs);
      print("[BluetoothScanService] Refreshed known UUIDs: $knownUserUUIDs");
      // 重新设置监听器以确保正常工作
      _listenToNativeScanResults();
    } catch (e) {
      print("[BluetoothScanService] Error refreshing known UUIDs: $e");
    }
  }

  /// 更新已知用户UUID列表
  Future<void> updateKnownUserUUIDs(List<String> newUUIDs) async {
    try {
      final result = await _methodChannel.invokeMethod('updateKnownUserUUIDs', {
        'userUUIDs': newUUIDs,
      });
      print("[BluetoothScanService] Updated known UUIDs: $newUUIDs");
    } catch (e) {
      print("[BluetoothScanService] Error updating known UUIDs: $e");
    }
  }

  /// Releases resources
  void dispose() {
    _scanResultsSubscription?.cancel(); // Cancel scan results subscription
    // No need to call stopScanningService, as dispose is usually called when the App Widget is destroyed,
    // and at this point the native service should have already handled the stop logic, or its lifecycle is managed by WorkManager.
    print(
      "[BluetoothScanService] Dart: Resources released.",
    ); // Print resource release log
  }
}
