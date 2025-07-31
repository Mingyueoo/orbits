import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:app_settings/app_settings.dart';

class BluetoothService {
  static Future<bool> isBluetoothEnabled() async {
    // Listen to the adapterState stream and take the first value that indicates Bluetooth is on.
    // This is the most robust way to get the current state and wait for it to be ready.
    await FlutterBluePlus.adapterState
        .where((state) => state == BluetoothAdapterState.on)
        .first;

    // If the above line completes without error, it means Bluetooth is on.
    return true;
  }

  // If you just want to get the *current* state without waiting for it to turn on,
  // you can listen to the stream and get the last known value, or directly check
  // the first value if you're sure Bluetooth is initialized.
  static Future<bool> getCurrentBluetoothState() async {
    final BluetoothAdapterState state =
    await FlutterBluePlus.adapterState.first;
    return state == BluetoothAdapterState.on;
  }

  static Future<void> openBluetoothSettings() async {
    await AppSettings.openAppSettings();
  }
}
