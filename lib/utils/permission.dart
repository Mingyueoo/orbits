import 'package:permission_handler/permission_handler.dart';

class PermissionServiceShow {
  static Future<bool> isNearbyPermissionGranted() async {
    final status = await Permission.bluetoothScan.status;
    return status.isGranted;
  }
}
