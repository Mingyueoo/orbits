import 'dart:async';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:orbits_new/database/models/contact_device.dart';
import 'package:orbits_new/database/dao/device_dao.dart';
import 'dart:convert'; // JSON encoding/decoding library

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
  final int contactThresholdMinutes = 1; // for testing, 1 minutes.
  final DeviceDao deviceDao = DeviceDao(); // Device data access object instance

  StreamSubscription?
  _scanResultsSubscription; // Subscription for listening to native scan results stream

  // Scan mode is still maintained on the Dart side and passed to native
  ScanMode _currentScanMode =
      ScanMode.lowPower; // Current scan mode, defaults to low power

  // Constructor, used to initialize EventChannel listener
  BluetoothScanService() {
    _listenToNativeScanResults(); // Start listening to native scan results upon instantiation
  }

  /// Initializes the service, requesting necessary permissions.
  /// Bluetooth enabled check is now performed by main.dart before starting the service, or handled internally by the native service.
  Future<void> init() async {
    await _requestPermissions();
    // _checkBluetooth() logic can now be handled by the native service, or in the Flutter UI layer before calling startScanningService.
    // For simplicity, only permission requests are kept here.
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
  Future<void> startScanningService() async {
    print(
      "[BluetoothScanService] Dart: Start native scan service command sent.",
    ); // Add log
    try {
      await _methodChannel.invokeMethod(
        'startScanService',
      ); // Invoke native method to start service
      // After starting the service, immediately pass the current mode to the native service to ensure it starts with the correct mode
      await setScanMode(
        _currentScanMode == ScanMode.highFrequency
            ? 'high_frequency'
            : 'low_power',
      );
    } on PlatformException catch (e) {
      print(
        "[BluetoothScanService] Dart: Failed to start native scan service: ${e.message}",
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
    _scanResultsSubscription = _eventChannel.receiveBroadcastStream().listen(
      (dynamic scanResultJson) async {
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
        // Only process devices with RSSI strength greater than -70 (configurable threshold)
        if (rssi > -70) {
          print(
            "[BluetoothScanService] Dart: [Valid rssi] $rssi} ",
          ); // Print valid contact log
          // Record first seen time, add if not present
          _firstSeenMap.putIfAbsent(userUuid, () => now);
          final firstSeen = _firstSeenMap[userUuid]!; // Get first seen time
          final duration = now.difference(
            firstSeen,
          ); // Calculate contact duration

          // Contact duration > 15 minutes, and this UUID has not yet been recorded as a valid contact in the current session
          // if (duration.inMinutes >= contactThresholdMinutes) {
          if (!_contactDurationMap.containsKey(userUuid)) {
            _contactDurationMap[user
                duration.inMinutes; // Record contact duration

            print(
              "[BluetoothScanService] Dart: [Valid Contact] $userUuid - ${duration.inMinutes} mins",
            ); // Print valid contact log

            // Query database to check if UUID already exists
            final existing = await deviceDao.getDeviceByUUID(userUuid);
            if (existing == null) {
              // First contact: insert new record
              final device = ContactDevice(
                uuid: userUuid,
                firstSeen: firstSeen.toIso8601String(),
                // Convert to ISO 8601 string for storage
                lastSeen: now.toIso8601String(),
                rssi: rssi,
              );
              await deviceDao.insertDevice(
                device,
              ); // Insert new device into database
              print(
                "[BluetoothScanService] Dart: [Database] Inserted new device: $userUuid",
              ); // Print database operation log
            } else {
              // Record exists: only update lastSeen and rssi
              await deviceDao.updateLastSeen(
                userUuid,
                now.toIso8601String(),
              ); // Update last seen time
              await deviceDao.updateRssi(userUuid, rssi); // Update RSSI
              print(
                "[BluetoothScanService] Dart: [Database] Updated existing device: $userUuid",
              ); // Print database operation log
            }
          }
          // }
        }
      },
      onError: (e) {
        print(
          "[BluetoothScanService] Dart: Scan results stream error: $e",
        ); // Print scan results stream error
        // On error, may need to notify UI or attempt to restart service
      },
      onDone: () {
        print(
          "[BluetoothScanService] Dart: Scan results stream completed.",
        ); // Print stream completed log
      },
    );
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
