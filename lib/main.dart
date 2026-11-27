import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

const studentName = 'Шмаков Владислав Ярославович';
String money(double n) => n.abs() >= 1e12
    ? n.toStringAsExponential(3)
    : n.toStringAsFixed(2).replaceAll('.', ',');
double? number(String text) {
  final n = double.tryParse(text.trim().replaceAll(',', '.'));
  return n != null && n.isFinite ? n : null;
}

ThemeData appTheme() => ThemeData(
  useMaterial3: true,
  fontFamily: 'LabRoboto',
  colorSchemeSeed: Colors.teal,
  scaffoldBackgroundColor: const Color(0xfff4f7f8),
);

class CalcState {
  const CalcState({this.result, this.error, this.busy = false});
  final Map<String, Object?>? result;
  final String? error;
  final bool busy;
}

class CalculatorCubit extends Cubit<CalcState> {
  CalculatorCubit({this.save}) : super(const CalcState());
  final Future<void> Function(Map<String, Object?>)? save;
  Future<void> calculate(
    String capital,
    String years,
    String rate,
    bool consent,
  ) async {
    if (state.busy) return;
    final p = number(capital), t = number(years), r = number(rate);
    if (p == null || t == null || r == null || p <= 0 || t <= 0 || r < 0) {
      emit(
        const CalcState(
          error: 'Введите положительные капитал и срок, ставку не ниже нуля.',
        ),
      );
      return;
    }
    if (!consent) {
      emit(const CalcState(error: 'Подтвердите согласие на обработку данных.'));
      return;
    }
    // Все расчёты выполняются в Cubit, без перехода на другой экран.
    final interest = p * (r / 100) * t, total = p + p * (r / 100) * t;
    if (!interest.isFinite || !total.isFinite) {
      emit(const CalcState(error: 'Слишком большие значения.'));
      return;
    }
    final result = {
      'capital': p,
      'years': t,
      'rate': r,
      'interest': interest,
      'total': total,
      'created': DateTime.now().toIso8601String(),
    };
    emit(const CalcState(busy: true));
    try {
      await save?.call(result);
      if (!isClosed) emit(CalcState(result: result));
    } catch (_) {
      if (!isClosed) {
        emit(
          const CalcState(
            error: 'Не удалось сохранить расчёт. Проверьте доступ к хранилищу.',
          ),
        );
      }
    }
  }

  void edit() => emit(const CalcState());
}

class CalculationStore {
  CalculationStore(this.db, this.prefs);
  final Database db;
  final SharedPreferences prefs;
  Map<String, dynamic>? get draft {
    try {
      final s = prefs.getString('last_input');
      return s == null ? null : jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(Map<String, Object?> row) async {
    await db.insert('calculations', row);
    if (!await prefs.setString('last_input', jsonEncode(row))) {
      throw StateError('preferences');
    }
  }

  Future<List<Map<String, Object?>>> read() =>
      db.query('calculations', orderBy: 'id DESC');
}

class HistoryState {
  const HistoryState({this.rows = const [], this.loading = false, this.error});
  final List<Map<String, Object?>> rows;
  final bool loading;
  final String? error;
}

class HistoryCubit extends Cubit<HistoryState> {
  HistoryCubit(this.store) : super(const HistoryState());
  final CalculationStore store;
  Future<void> load() async {
    emit(const HistoryState(loading: true));
    try {
      final rows = await store.read();
      if (!isClosed) emit(HistoryState(rows: rows));
    } catch (_) {
      if (!isClosed) {
        emit(const HistoryState(error: 'Не удалось загрузить историю.'));
      }
    }
  }
}

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('История расчётов')),
    body: BlocBuilder<HistoryCubit, HistoryState>(
      builder: (context, state) {
        if (state.loading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (state.error != null) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(state.error!),
                TextButton(
                  onPressed: context.read<HistoryCubit>().load,
                  child: const Text('Повторить'),
                ),
              ],
            ),
          );
        }
        if (state.rows.isEmpty) {
          return const Center(child: Text('Пока нет сохранённых расчётов'));
        }
        return ListView.separated(
          padding: const EdgeInsets.all(20),
          itemCount: state.rows.length,
          separatorBuilder: (_, index) => const Divider(),
          itemBuilder: (_, i) {
            final row = state.rows[i];
            return ListTile(
              title: Text('Итог: ${money((row['total'] as num).toDouble())} ₽'),
              subtitle: Text(
                'Капитал: ${row['capital']} ₽ · ${row['years']} лет · ${row['rate']} %\nДоход: ${row['interest']} ₽\n${row['created']}',
              ),
            );
          },
        );
      },
    ),
  );
}

class CalculatorPage extends StatefulWidget {
  const CalculatorPage({super.key, this.store});
  final CalculationStore? store;
  @override
  State<CalculatorPage> createState() => _CalculatorPageState();
}

class _CalculatorPageState extends State<CalculatorPage> {
  final form = GlobalKey<FormState>();
  final p = TextEditingController(),
      t = TextEditingController(),
      r = TextEditingController();
  bool consent = false;
  @override
  void initState() {
    super.initState();
    final draft = widget.store?.draft;
    if (draft != null) {
      p.text = '${draft['capital']}';
      t.text = '${draft['years']}';
      r.text = '${draft['rate']}';
    }
  }

  @override
  void dispose() {
    p.dispose();
    t.dispose();
    r.dispose();
    super.dispose();
  }

  Widget field(
    String label,
    TextEditingController control, {
    bool zero = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: TextFormField(
      controller: control,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      validator: (value) {
        final n = number(value ?? '');
        return n == null || (zero ? n < 0 : n <= 0)
            ? 'Введите ${zero ? 'неотрицательное' : 'положительное'} число'
            : null;
      },
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      toolbarHeight: 80,
      title: const Text(studentName, maxLines: 2),
      leading: widget.store == null
          ? null
          : IconButton(
              tooltip: 'История расчётов',
              icon: const Icon(Icons.history),
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => BlocProvider(
                    create: (_) => HistoryCubit(widget.store!)..load(),
                    child: const HistoryPage(),
                  ),
                ),
              ),
            ),
    ),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: BlocBuilder<CalculatorCubit, CalcState>(
              builder: (context, state) {
                final result = state.result;
                if (result != null) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Результат расчёта',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        '${money(result['total'] as double)} ₽',
                        style: const TextStyle(
                          fontSize: 36,
                          color: Colors.teal,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text('Доход: ${money(result['interest'] as double)} ₽'),
                      const SizedBox(height: 12),
                      Text(
                        'Капитал: ${result['capital']} ₽\nСрок: ${result['years']} лет\nСтавка: ${result['rate']} %',
                        style: const TextStyle(height: 1.8),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'I = P × r × t / 100\nS = P + I',
                        style: TextStyle(fontSize: 20, height: 1.6),
                      ),
                      const SizedBox(height: 24),
                      OutlinedButton(
                        onPressed: context.read<CalculatorCubit>().edit,
                        child: const Text('Изменить данные'),
                      ),
                    ],
                  );
                }
                return Form(
                  key: form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        widget.store == null
                            ? 'Лабораторная 4 · Вариант 3'
                            : 'Лабораторная 5 · Вариант 3',
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Простые проценты',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Ставка — годовая. Срок — в годах. Расчёт без капитализации.',
                      ),
                      const SizedBox(height: 28),
                      field('Исходный капитал, ₽', p),
                      field('Срок, лет', t),
                      field('Годовая ставка, %', r, zero: true),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: consent,
                        onChanged: state.busy
                            ? null
                            : (v) => setState(() => consent = v ?? false),
                        title: const Text('Согласен на обработку данных'),
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                      if (state.error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            state.error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: state.busy
                            ? null
                            : () {
                                if (form.currentState!.validate()) {
                                  context.read<CalculatorCubit>().calculate(
                                    p.text,
                                    t.text,
                                    r.text,
                                    consent,
                                  );
                                }
                              },
                        child: Text(state.busy ? 'Сохранение…' : 'Рассчитать'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (kIsWeb) databaseFactory = databaseFactoryFfiWeb;
    final prefs = await SharedPreferences.getInstance();
    final db = await openDatabase(
      'interest_history.db',
      version: 1,
      onCreate: (db, v) => db.execute(
        'CREATE TABLE calculations (id INTEGER PRIMARY KEY AUTOINCREMENT, capital REAL NOT NULL, years REAL NOT NULL, rate REAL NOT NULL, interest REAL NOT NULL, total REAL NOT NULL, created TEXT NOT NULL)',
      ),
    );
    final store = CalculationStore(db, prefs);
    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appTheme(),
        home: BlocProvider(
          create: (_) => CalculatorCubit(save: store.save),
          child: CalculatorPage(store: store),
        ),
      ),
    );
  } catch (_) {
    runApp(
      MaterialApp(
        theme: appTheme(),
        home: const Scaffold(
          body: Center(
            child: Text(
              'Не удалось открыть хранилище. Перезапустите приложение.',
            ),
          ),
        ),
      ),
    );
  }
}
