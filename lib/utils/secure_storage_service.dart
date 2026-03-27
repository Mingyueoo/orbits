import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart'; // 用于生成唯一的 userUUID
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 安全存储服务，用于保存和获取敏感信息，例如用户的密钥。
class SecureStorageService {
  final _storage = const FlutterSecureStorage();

  // 定义存储 userUUID 和 secretKey 的键
  static const _userUuidKey = 'user_uuid';
  static const _secretKey = 'secret_key';
  static const _keyVersion = 'key_version';

  /// 获取或生成一个唯一的应用 UUID。
  /// 这个 UUID 是设备的永久标识符，用于二维码绑定。
  Future<String> getOrCreateUserUUID() async {
    // 尝试从安全存储中读取 UUID
    String? uuid = await _storage.read(key: _userUuidKey);

    // 如果 UUID 不存在，则生成一个新的
    if (uuid == null) {
      // 使用 uuid 包生成一个 v4 UUID
      uuid = const Uuid().v4();
      // 将新生成的 UUID 写入安全存储
      await _storage.write(key: _userUuidKey, value: uuid);
      print("[SecureStorageService] A new UUID has been generated and stored.");
    } else {
      print("[SecureStorageService] Existing UUID has been loaded.");
    }

    return uuid;
  }

  Future<String> getOrCreateSecretKey() async {
    String? secretKey = await _storage.read(key: _secretKey);
    String? keyVersion = await _storage.read(key: _keyVersion);

    // 生成当前版本的应用特征
    final currentAppFingerprint = await _generateAppFingerprint();

    // 如果密钥不存在或应用特征发生变化，重新生成密钥
    if (secretKey == null || keyVersion != currentAppFingerprint) {
      print("[SecureStorageService] Generating new app-based secret key.");

      // 生成基于应用信息的密钥（所有设备相同）
      secretKey = await _generateAppBasedKey();

      await _storage.write(key: _secretKey, value: secretKey);
      await _storage.write(key: _keyVersion, value: currentAppFingerprint);

      print(
        "[SecureStorageService] New app-based secret key generated and stored.",
      );
    } else {
      print("[SecureStorageService] Existing app-based secret key loaded.");
    }

    return secretKey;
  }

  // 第 67-75 行：_generateAppFingerprint() 方法
  Future<String> _generateAppFingerprint() async {
    final packageInfo = await PackageInfo.fromPlatform();

    // 应用指纹包含版本信息，用于检测更新
    final fingerprint =
        '${packageInfo.version}_${packageInfo.buildNumber}_${packageInfo.packageName}';
    final hash = sha256.convert(utf8.encode(fingerprint));

    return hash.toString().substring(0, 16); // 取前16位作为版本标识
  }

  // 第 77-95 行：_generateAppBasedKey() 方法
  Future<String> _generateAppBasedKey() async {
    final packageInfo = await PackageInfo.fromPlatform();

    // 只使用包名，确保所有版本使用相同密钥
    final seed = [
      packageInfo.packageName, // 只使用包名
      'OrbitsApp2024', // 应用标识
    ].join('_');

    // 使用SHA-256生成密钥
    final hash = sha256.convert(utf8.encode(seed));

    // 返回32字节的密钥（64个十六进制字符）
    return hash.toString();
  }
}
