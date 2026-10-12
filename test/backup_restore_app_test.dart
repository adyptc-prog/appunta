import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:management_app/backup_service.dart';
import 'package:management_app/main.dart';

// Restaurarea scrie datele nativ (BackupManager.kt), pe lângă cache-ul Dart
// al SharedPreferences. Testul verifică pe aplicația întreagă că, după
// restaurare, tabelul afișează datele restaurate — nu cele vechi din cache.
const _backupChannel = MethodChannel('organizator/backup');

String _items(List<String> names) => jsonEncode([
      for (var i = 0; i < names.length; i++)
        {
          'syncId': 's$i',
          'number': i + 1,
          'name': names[i],
          'description': '',
          'createdAt': '2026-09-01T10:00:00.000',
          'expiresAt': null,
          'warningAt': null,
          'validated': false,
        }
    ]);

Map<String, Object> _state(List<String> names) => {
      'management_boards': jsonEncode([
        {'id': 'b1', 'name': 'Salon'},
        {'id': 'b2', 'name': 'Tabel 2'},
        {'id': 'b3', 'name': 'Tabel 3'},
      ]),
      'management_active_board': 'b1',
      'management_items_b1': _items(names),
      'management_next_number_b1': names.length + 1,
    };

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    try { await NotificationService.init(); } catch (_) {}
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(_state(['Ana Popescu', 'Maria Ionescu']));
    BackupService.debugIsAndroid = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_backupChannel, (call) async {
      switch (call.method) {
        case 'getStatus':
          return {'folderUri': null};
        case 'pickAndRestoreBackup':
          // „Partea nativă” înlocuiește datele direct în store, pe lângă
          // cache-ul instanței Dart — ca pe Android. (setMockInitialValues
          // ar reseta și instanța, ascunzând lipsa unui reload.)
          final store = SharedPreferencesStorePlatform.instance;
          await store.clear();
          for (final e in _state(['Ion Restaurat', 'Elena Restaurată', 'Dan Restaurat']).entries) {
            await store.setValue(e.value is int ? 'Int' : 'String', 'flutter.${e.key}', e.value);
          }
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_backupChannel, null);
    BackupService.debugIsAndroid = null;
  });

  testWidgets('după restaurare tabelul afișează datele din backup',
      (tester) async {
    await tester.pumpWidget(const ManagementApp());
    await tester.pumpAndSettle();
    expect(find.text('Ana Popescu'), findsOneWidget);
    expect(find.text('2 înregistrări'), findsOneWidget);

    await tester.tap(find.byTooltip('Backup & restaurare'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restaurează din alt fișier'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Restaurează'));
    await tester.pumpAndSettle();
    expect(find.text('Backup restaurat. Datele au fost reîncărcate.'),
        findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('Ana Popescu'), findsNothing);
    expect(find.text('Ion Restaurat'), findsOneWidget);
    expect(find.text('3 înregistrări'), findsOneWidget);

    // Adăugarea după restaurare continuă numerotarea din backup și nu
    // readuce datele vechi din cache.
    await tester.tap(find.byIcon(Icons.add_circle_rounded));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Nume *'), 'Nou');
    await tester.tap(find.text('Adaugă').last);
    await tester.pumpAndSettle();
    expect(find.text('4 înregistrări'), findsOneWidget);
    expect(find.text('Ana Popescu'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('management_items_b1')!;
    expect(saved, contains('Ion Restaurat'));
    expect(saved, isNot(contains('Ana Popescu')));
  });
}
