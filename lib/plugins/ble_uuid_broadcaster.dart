import 'package:flutter/services.dart';
// startBroadcast and stopBroadcast can implement both front-end and back-end broadcast functions

class BleUuidBroadcaster {
  static const MethodChannel _channel = MethodChannel('ble_uuid_broadcaster');

  /// Starts the BLE broadcast service.
  static Future<void> startBroadcast() async {
    await _channel.invokeMethod('startBroadcast');
  }

  /// Stops the BLE broadcast service.
  static Future<void> stopBroadcast() async {
    await _channel.invokeMethod('stopBroadcast');
  }

  /// Sets the BLE advertising mode.
  /// [mode] can be 'high_frequency' or 'low_power'.
  static Future<void> setAdvertisingMode(String mode) async {
    await _channel.invokeMethod('setAdvertisingMode', {'mode': mode});
  }

  /// Checks if the BLE broadcast service is running.
  /// This method now relies on a static flag inside the native service.
  static Future<bool> isServiceRunning() async {
    try {
      final bool? isRunning = await _channel.invokeMethod('isServiceRunning');
      return isRunning ?? false; // Defaults to false if null is returned
    } on PlatformException catch (e) {
      print("Error checking service running status: ${e.message}");
      return false; // Returns false on platform exception
    }
  }
}
