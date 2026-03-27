import 'package:sqflite/sqflite.dart';
import 'package:orbits_new/database/db_helper.dart';
import 'package:orbits_new/database/models/contact_device.dart';
import 'dart:async';
import 'package:rxdart/rxdart.dart';

class DeviceDao {
  bool _isInitialized = false;

  // BehaviorSubject is a StreamController 的特殊类型，可以记住最新的值并立即发送给新的订阅者
  final _updateSubject = BehaviorSubject<void>.seeded(null);

  Future<void> initialize() async {
    if (!_isInitialized) {
      print("[DeviceDao] Initializing...");
      _isInitialized = true;
      print("[DeviceDao] Setting _isInitialized = true");
      _updateSubject.add(null);
      print("[DeviceDao] initialize: _updateSubject.add(null) completed");
      print("[DeviceDao] Initialized with current data");
    } else {
      print("[DeviceDao] Already initialized, skipping");
    }
  }

  void forceRefresh() {
    print("[DeviceDao] forceRefresh called");
    _updateSubject.add(null);
    print("[DeviceDao] forceRefresh: _updateSubject.add(null) completed");
  }

  // 确保所有的数据库操作都通过这个方法进行，以统一触发 Stream 更新
  Future<T> _performDbOperation<T>(
    Future<T> Function(Database) operation,
  ) async {
    try {
      print("[DeviceDao] Starting database operation");
      final db = await DBHelper.database;
      final result = await operation(db);
      print("[DeviceDao] Database operation completed successfully");
      print(
        "[DeviceDao] Triggering stream update via _updateSubject.add(null)",
      );
      _updateSubject.add(null);
      print("[DeviceDao] Stream update triggered");
      return result;
    } catch (e) {
      print("Database operation failed: $e");
      rethrow;
    }
  }

  /// 获取设备数量的 Stream
  Stream<int> getDeviceCountStream() {
    print("[DeviceDao] getDeviceCountStream called");
    initialize();
    return _updateSubject.switchMap((_) async* {
      print("[DeviceDao] getDeviceCountStream: _updateSubject triggered");
      final db = await DBHelper.database;
      final count = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM contact_devices'),
      );
      print("[DeviceDao] getDeviceCountStream: yielding count = ${count ?? 0}");
      yield count ?? 0;
    });
  }

  // 获取总接触分钟数的 Stream，这里计算的是所有设备的时间
  Stream<int> getTotalContactMinutesStream() {
    print("[DeviceDao] getTotalContactMinutesStream called");
    initialize();
    return _updateSubject.switchMap((_) async* {
      print(
        "[DeviceDao] getTotalContactMinutesStream: _updateSubject triggered",
      );
      final db = await DBHelper.database;
      final result = await db.rawQuery(
        'SELECT SUM(contact_duration) as total FROM contact_devices',
      );
      int total = result.first['total'] as int? ?? 0;
      print(
        "[DeviceDao] getTotalContactMinutesStream: yielding total = $total",
      );
      yield total;
    });
  }

  // 更新设备的 lastSeen 和 contactDuration 字段
  Future<void> updateLastSeenAndDuration(
    String uuid,
    String newLastSeen,
    int newDuration,
  ) async {
    await _performDbOperation((db) async {
      final rowsAffected = await db.update(
        'contact_devices',
        {'last_seen': newLastSeen, 'contact_duration': newDuration},
        where: 'uuid = ?',
        whereArgs: [uuid],
      );
      return rowsAffected;
    });
  }

  void dispose() {
    _updateSubject.close();
  }

  /// 插入设备（如果已存在则抛出异常）==qr code used to solve repeated inserting
  Future<void> insertDevice(ContactDevice device) async {
    await _performDbOperation((db) async {
      // 先检查设备是否已存在
      final existing = await db.query(
        'contact_devices',
        where: 'uuid = ?',
        whereArgs: [device.uuid],
      );

      if (existing.isNotEmpty) {
        throw Exception("The device already exists: ${device.uuid}");
      }

      // 如果不存在，则插入新设备
      return db.insert('contact_devices', device.toMap());
    });
  }

  /// 插入或更新设备（如果已存在则更新，不存在则插入）==用来更新contact time and rssi
  Future<void> insertOrUpdateDevice(ContactDevice device) async {
    await _performDbOperation(
      (db) => db.insert(
        'contact_devices',
        device.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      ),
    );
  }

  /// 获取所有设备的UUID列表
  Future<List<String>> getAllUserUUIDs() async {
    final db = await DBHelper.database;
    final result = await db.query('contact_devices', columns: ['uuid']);
    return result.map((e) => e['uuid'] as String).toList();
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

  /// 更新 RSSI
  Future<void> updateRssi(String uuid, int rssi) async {
    await _performDbOperation(
      (db) => db.update(
        'contact_devices',
        {'rssi': rssi},
        where: 'uuid = ?',
        whereArgs: [uuid],
      ),
    );
  }

  /// 删除指定设备根据uuid
  Future<void> deleteDevice(String uuid) async {
    await _performDbOperation(
      (db) =>
          db.delete('contact_devices', where: 'uuid = ?', whereArgs: [uuid]),
    );
  }

  /// 获取所有已扫描的设备
  Future<List<ContactDevice>> getAllDevices() async {
    final db = await DBHelper.database;
    final maps = await db.query('contact_devices');
    return maps.map((e) => ContactDevice.fromMap(e)).toList();
  }

  /// 清空所有数据（调试用）
  Future<void> clearAll() async {
    await _performDbOperation((db) => db.delete('contact_devices'));
  }
}
