import 'package:lab5/main.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Проценты, дробный срок, согласие и неверные числа', () async {
    final c = CalculatorCubit();
    await c.calculate('10000', '2', '10', false);
    expect(c.state.error, isNotNull);
    await c.calculate('10000', '2', '10', true);
    expect(c.state.result!['total'], 12000);
    c.edit();
    expect(c.state.result, isNull);
    await c.calculate('10000', '0,5', '10', true);
    expect(c.state.result!['interest'], 500);
    await c.calculate('10000', '1', '0', true);
    expect(c.state.result!['total'], 10000);
    for (final p in ['-1', '0', 'NaN', 'Infinity', 'abc']) {
      await c.calculate(p, '1', '10', true);
      expect(c.state.error, isNotNull);
    }
    await c.calculate('1e308', '100', '100', true);
    expect(c.state.error, isNotNull);
    await c.close();
  });
  test('Ошибка записи не выдаётся за успешное сохранение', () async {
    final c = CalculatorCubit(save: (_) async => throw StateError('disk'));
    await c.calculate('10000', '2', '10', true);
    expect(c.state.result, isNull);
    expect(c.state.error, isNotNull);
    await c.close();
  });

  test('SQLite и SharedPreferences сохраняют данные и историю', () async {
    sqfliteFfiInit();
    SharedPreferences.setMockInitialValues({});
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, v) => db.execute(
          'CREATE TABLE calculations(id INTEGER PRIMARY KEY AUTOINCREMENT,capital REAL,years REAL,rate REAL,interest REAL,total REAL,created TEXT)',
        ),
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    final store = CalculationStore(db, prefs);
    final c = CalculatorCubit(save: store.save);
    await c.calculate('10000', '2', '10', true);
    expect(store.draft!['capital'], 10000);
    expect((await store.read()).single['total'], 12000);
    final history = HistoryCubit(
      CalculationStore(db, await SharedPreferences.getInstance()),
    );
    await history.load();
    expect(history.state.rows.length, 1);
    await c.close();
    await history.close();
    await db.close();
  });
}
