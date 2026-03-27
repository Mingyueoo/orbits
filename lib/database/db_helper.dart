import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DBHelper {
  // 静态私有变量，直接内部访问
  static Database? _db;
  // getter
  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB("contact_trace.db");
    return _db!;
  }

  static Future<Database> _initDB(String fileName) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, fileName);

    return await openDatabase(
      path,
      version: 2,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  static Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE contact_devices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid TEXT,
        first_seen TEXT,
        last_seen TEXT,
        rssi INTEGER,
        secret_key TEXT,
        contact_duration INTEGER DEFAULT 0      
      )
    ''');

    await db.execute('''
      CREATE TABLE contact_bindings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid TEXT,
        name TEXT,
        relationship TEXT,
        phoneNumber TEXT
      )
    ''');

    // 在 _createDB 方法中添加新表
    await db.execute('''
  CREATE TABLE rssi_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid TEXT,
    rssi INTEGER,
    timestamp TEXT,
    FOREIGN KEY (uuid) REFERENCES contact_devices (uuid)
  )
''');
  }

  // 关键：添加升级逻辑
  static Future _upgradeDB(Database db, int oldVersion, int newVersion) async {
    print(
      "[DBHelper] Upgrading database from version $oldVersion to $newVersion",
    );

    if (oldVersion < 2) {
      // 从版本1升级到版本2：添加rssi_history表
      await db.execute('''
        CREATE TABLE rssi_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          uuid TEXT,
          rssi INTEGER,
          timestamp TEXT,
          FOREIGN KEY (uuid) REFERENCES contact_devices (uuid)
        )
      ''');
      print("[DBHelper] Added rssi_history table");
    }

    // 未来可以添加更多升级逻辑
    // if (oldVersion < 3) {
    //   // 从版本2升级到版本3：添加新列或表
    // }
  }
}
