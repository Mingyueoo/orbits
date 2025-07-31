import 'package:sqflite/sqflite.dart';
import 'package:orbits_new/database/db_helper.dart';
import 'package:orbits_new/database/models/contact_device.dart';

class DeviceDao {
  /// 插入新设备（首次扫描）
  Future<void> insertDevice(ContactDevice device) async {
    final db = await DBHelper.database;
    // 数据库表的名称--table: contact_devices
    await db.insert(
      'contact_devices',
      device.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 获取所有已扫描的设备
  Future<List<ContactDevice>> getAllDevices() async {
    final db = await DBHelper.database;
    final maps = await db.query('contact_devices');
    return maps.map((e) => ContactDevice.fromMap(e)).toList();
  }

  Future<int> getDeviceCount() async {
    final db = await DBHelper.database;
    // final db = await DatabaseProvider.db.database;
    final result = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM contact_devices'),
    );
    return result ?? 0;
  }

  /// 根据 UUID 获取设备（用于判断是否首次扫描）
  Future<ContactDevice?> getDeviceByUUID(String uuid) async {
    final db = await DBHelper.database;
    final maps = await db.query(
      'contact_devices',
      where: 'uuid = ?',
      whereArgs: [uuid],
    );
    if (maps.isNotEmpty) {
      return ContactDevice.fromMap(maps.first);
    }
    return null;
  }

  /// 更新设备的 lastSeen 字段（每次扫描时调用）
  Future<void> updateLastSeen(String uuid, String newLastSeen) async {
    final db = await DBHelper.database;
    await db.update(
      'contact_devices',
      {'last_seen': newLastSeen},
      where: 'uuid = ?',
      whereArgs: [uuid],
    );
  }

  /// 更新 RSSI（可选）
  Future<void> updateRssi(String uuid, int rssi) async {
    final db = await DBHelper.database;
    await db.update(
      'contact_devices',
      {'rssi': rssi},
      where: 'uuid = ?',
      whereArgs: [uuid],
    );
  }

  /// 删除指定设备
  Future<void> deleteDevice(String uuid) async {
    final db = await DBHelper.database;
    await db.delete('contact_devices', where: 'uuid = ?', whereArgs: [uuid]);
  }

  /// 清空所有数据（调试用）
  Future<void> clearAll() async {
    final db = await DBHelper.database;
    await db.delete('contact_devices');
  }

  // 此处代码是自己修改的代码
  Future<int> getTotalContactMinutes() async {
    final db = await DBHelper.database;
    final maps = await db.query('contact_devices');
    int total = 0;
    for (var map in maps) {
      final device = ContactDevice.fromMap(map);
      total += device.contactDurationMinutes; // 使用模型类计算时间差
    }

    return total;
  }
}
