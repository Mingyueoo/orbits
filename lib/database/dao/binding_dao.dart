import 'package:sqflite/sqflite.dart';
import 'package:orbits_new/database/db_helper.dart';
import 'package:orbits_new/database/models/contact_binding.dart';

class BindingDao {
  Future<void> insertBinding(ContactBinding binding) async {
    final db = await DBHelper.database;
    await db.insert(
      'contact_bindings',
      binding.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // New method to get a binding by its UUID
  Future<ContactBinding?> getBindingByUuid(String uuid) async {
    final db = await DBHelper.database;
    final maps = await db.query(
      'contact_bindings',
      where: 'uuid = ?',
      whereArgs: [uuid],
      limit: 1, // We only expect one result for a unique UUID
    );

    if (maps.isNotEmpty) {
      return ContactBinding.fromMap(maps.first);
    }
    return null; // Return null if no binding is found
  }

  // New method to update an existing binding
  Future<void> updateBinding(ContactBinding binding) async {
    final db = await DBHelper.database;
    await db.update(
      'contact_bindings',
      binding.toMap(),
      where: 'uuid = ?',
      whereArgs: [binding.uuid],
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ContactBinding>> getAllBindings() async {
    final db = await DBHelper.database;
    final maps = await db.query('contact_bindings');
    return maps.map((m) => ContactBinding.fromMap(m)).toList();
  }

  Future<void> deleteBinding(String uuid) async {
    final db = await DBHelper.database;
    await db.delete('contact_bindings', where: 'uuid = ?', whereArgs: [uuid]);
  }

  // New method to delete all bindings
  Future<void> deleteAllBindings() async {
    final db = await DBHelper.database;
    await db.delete('contact_bindings');
  }
}
