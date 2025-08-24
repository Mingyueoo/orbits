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

    return await openDatabase(path, version: 1, onCreate: _createDB);
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

    // await db.execute('''
    //   CREATE TABLE emergency_contacts (
    //     id INTEGER PRIMARY KEY AUTOINCREMENT,
    //     name TEXT,
    //     phone TEXT,
    //     note TEXT
    //   )
    // ''');

    // await db.execute('''
    //   CREATE TABLE scan_history (
    //     id INTEGER PRIMARY KEY AUTOINCREMENT,
    //     uuid TEXT,
    //     rssi INTEGER,
    //     timestamp TEXT,
    //     valid_contact INTEGER
    //   )
    // ''');
  }
}
