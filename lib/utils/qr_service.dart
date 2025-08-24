import 'dart:convert';
import 'package:permission_handler/permission_handler.dart';
import 'package:orbits_new/database/dao/device_dao.dart';
import 'package:orbits_new/database/models/contact_device.dart';
import 'package:orbits_new/utils/secure_storage_service.dart';

class QrService {
  // 单例
  QrService._();
  static final QrService instance = QrService._();

  final SecureStorageService _secureStorageService = SecureStorageService();
  final DeviceDao _deviceDao = DeviceDao();

  /// 生成我的二维码数据
  Future<String> generateMyQrData() async {
    final userUuid = await _secureStorageService.getOrCreateUserUUID();
    final secretKey = await _secureStorageService.getOrCreateSecretKey();
    return jsonEncode({'userUuid': userUuid, 'secretKey': secretKey});
  }

  /// 请求相机权限
  Future<bool> requestCameraPermission() async {
    final status = await Permission.camera.request();
    return status.isGranted;
  }

  /// 解析扫描结果并写入数据库
  /// 成功返回 ContactDevice，失败抛异常
  Future<ContactDevice> processScannedQrData(String qrData) async {
    try {
      final Map<String, dynamic> data = jsonDecode(qrData);
      final otherUserUuid = data['userUuid'] as String?;
      final otherSecretKey = data['secretKey'] as String?;

      if (otherUserUuid == null || otherSecretKey == null) {
        throw FormatException("UUID 或 SecretKey 缺失");
      }

      final newContactDevice = ContactDevice(
        uuid: otherUserUuid,
        secretKey: otherSecretKey,
        lastSeen: DateTime.now().toIso8601String(),
        firstSeen: DateTime.now().toIso8601String(),
        rssi: -50,
      );

      await _deviceDao.insertDevice(newContactDevice);
      return newContactDevice;
    } catch (e) {
      throw FormatException("二维码数据无效: $e");
    }
  }
}
