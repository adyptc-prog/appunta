import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:management_app/main.dart';

// Canalul nativ al plugin-ului permission_handler.
const _permChannel = MethodChannel('flutter.baseflow.com/permissions/methods');

// Codurile PermissionStatus ale plugin-ului.
const _denied = 0;
const _granted = 1;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    try { await NotificationService.init(); } catch (_) {}
  });

  late Map<int, int> statuses; // permisiune → status curent
  late int? grantOnRequest; // statusul acordat la cerere (null = neschimbat)
  late List<List<int>> requests;
  late int inFlight;
  late int maxInFlight;
  late int settingsOpened;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugSimulateAndroid = true;
    statuses = {};
    grantOnRequest = null;
    requests = [];
    inFlight = 0;
    maxInFlight = 0;
    settingsOpened = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_permChannel, (call) async {
      switch (call.method) {
        case 'checkPermissionStatus':
          return statuses[call.arguments as int] ?? _denied;
        case 'requestPermissions':
          final perms = (call.arguments as List).cast<int>();
          requests.add(perms);
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          // Dialogul de sistem stă deschis până răspunde utilizatorul.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          inFlight--;
          return {
            for (final p in perms)
              p: grantOnRequest ?? statuses[p] ?? _denied,
          };
        case 'openAppSettings':
          settingsOpened++;
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_permChannel, null);
    debugSimulateAndroid = null;
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets('la pornire cererile de permisiuni nu se suprapun', (tester) async {
    await tester.pumpWidget(const ManagementApp());
    await settle(tester);

    // SMS primul, apoi bateria — niciodată două dialoguri deodată.
    expect(requests, [
      [Permission.sms.value],
      [Permission.ignoreBatteryOptimizations.value],
    ]);
    expect(maxInFlight, 1);
  });

  testWidgets('permisiunea SMS e cerută o singură dată (fără cerere nativă dublă)',
      (tester) async {
    await tester.pumpWidget(const ManagementApp());
    await settle(tester);
    expect(requests.where((r) => r.contains(Permission.sms.value)).length, 1);
  });

  test('SmsService raportează corect statusul permisiunii', () async {
    expect(await SmsService.hasPermission(), isFalse);
    statuses[Permission.sms.value] = _granted;
    expect(await SmsService.hasPermission(), isTrue);
  });

  test('requestPermission întoarce rezultatul real', () async {
    expect(await SmsService.requestPermission(), isFalse);
    grantOnRequest = _granted;
    expect(await SmsService.requestPermission(), isTrue);
  });

  test('non-Android: nimic de cerut, considerat permis', () async {
    debugSimulateAndroid = false;
    expect(await SmsService.hasPermission(), isTrue);
    expect(await SmsService.requestPermission(), isTrue);
    expect(requests, isEmpty);
  });

  group('banner SMS blocat', () {
    testWidgets('apare când permisiunea SMS e refuzată', (tester) async {
      await tester.pumpWidget(const ManagementApp());
      await settle(tester);
      expect(find.text('SMS-urile sunt blocate'), findsOneWidget);
    });

    testWidgets('nu apare când permisiunea e acordată', (tester) async {
      statuses[Permission.sms.value] = _granted;
      await tester.pumpWidget(const ManagementApp());
      await settle(tester);
      expect(find.text('SMS-urile sunt blocate'), findsNothing);
    });

    testWidgets('„Rezolvă” explică pașii și deschide setările aplicației',
        (tester) async {
      await tester.pumpWidget(const ManagementApp());
      await settle(tester);
      await tester.tap(find.text('Rezolvă'));
      await settle(tester);
      expect(find.textContaining('Permite setările restricționate'), findsOneWidget);
      await tester.tap(find.text('Deschide setările'));
      await settle(tester);
      expect(settingsOpened, 1);
    });

    testWidgets('dispare la revenirea din setări cu permisiunea acordată',
        (tester) async {
      await tester.pumpWidget(const ManagementApp());
      await settle(tester);
      expect(find.text('SMS-urile sunt blocate'), findsOneWidget);

      statuses[Permission.sms.value] = _granted; // utilizatorul a permis în setări
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(find.text('SMS-urile sunt blocate'), findsNothing);
    });

    testWidgets('„Cere permisiunea” acordată închide dialogul și bannerul',
        (tester) async {
      await tester.pumpWidget(const ManagementApp());
      await settle(tester);
      await tester.tap(find.text('Rezolvă'));
      await settle(tester);
      grantOnRequest = _granted;
      statuses[Permission.sms.value] = _granted;
      await tester.tap(find.text('Cere permisiunea'));
      await settle(tester);
      expect(find.textContaining('Permite setările restricționate'), findsNothing);
      expect(find.text('SMS-urile sunt blocate'), findsNothing);
    });
  });

  group('sincronizare cu SMS blocat', () {
    Future<void> tapSync(WidgetTester tester, {String code = 'k7qm-2xpa'}) async {
      await tester.pumpWidget(const ManagementApp());
      await settle(tester);
      // Sincronizarea e în meniul „Mai multe”.
      await tester.tap(find.byTooltip('Mai multe'));
      await settle(tester);
      await tester.tap(find.text('Sincronizare'));
      await settle(tester);
      await tester.enterText(
          find.widgetWithText(TextField, 'Număr telefon partener *'), '0722000111');
      await tester.enterText(
          find.widgetWithText(TextField, 'Cod de împerechere *'), code);
      await tester.tap(find.text('Sincronizează'));
      await settle(tester);
    }

    testWidgets('fără permisiune: explicație, partenerul nu e salvat',
        (tester) async {
      await tapSync(tester);
      expect(find.textContaining('Permite setările restricționate'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sync_partner_phone_b1'), isNull);
    });

    testWidgets('cu permisiune: partenerul e salvat și sincronizarea pornește',
        (tester) async {
      statuses[Permission.sms.value] = _granted;
      await tapSync(tester);
      expect(find.textContaining('Permite setările restricționate'), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sync_partner_phone_b1'), '0722000111');
      // Codul e salvat normalizat — identic pe ambele telefoane.
      expect(prefs.getString('sync_secret_b1'), 'K7QM2XPA');
      // Sincronizarea inițială trimite SMS-urile la 1,5 s distanță.
      await tester.pump(const Duration(seconds: 15));
    });

    testWidgets('fără cod de împerechere valid partenerul nu e salvat',
        (tester) async {
      statuses[Permission.sms.value] = _granted;
      await tapSync(tester, code: 'abc');
      expect(find.text('Minim 8 litere/cifre.'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sync_partner_phone_b1'), isNull);
      expect(prefs.getString('sync_secret_b1'), isNull);
    });

    testWidgets('„Generează cod” completează un cod valid', (tester) async {
      await tester.pumpWidget(const ManagementApp());
      await settle(tester);
      // Sincronizarea e în meniul „Mai multe”.
      await tester.tap(find.byTooltip('Mai multe'));
      await settle(tester);
      await tester.tap(find.text('Sincronizare'));
      await settle(tester);
      await tester.tap(find.byTooltip('Generează cod'));
      await settle(tester);
      final field = tester.widget<TextField>(
          find.widgetWithText(TextField, 'Cod de împerechere *'));
      expect(SyncService.isValidCode(field.controller!.text), isTrue);
      expect(field.controller!.text, matches(RegExp(r'^[A-Z2-9]{4}-[A-Z2-9]{4}$')));
    });
  });

  group('SMS netrimis (raportul sistemului)', () {
    const smsChannel = MethodChannel('organizator/sms');
    late Map<String, Object?>? failure;
    late int dismissed;

    setUp(() {
      statuses[Permission.sms.value] = _granted;
      failure = null;
      dismissed = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(smsChannel, (call) async {
        switch (call.method) {
          case 'getSmsFailure':
            return failure;
          case 'dismissSmsFailure':
            dismissed++;
            failure = null;
            return null;
          case 'getSyncMessages':
            return '[]';
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(smsChannel, null);
    });

    testWidgets('eșecul apare cu numărul, ora și motivul', (tester) async {
      failure = {
        'failedAt': DateTime(2026, 9, 24, 19, 30).millisecondsSinceEpoch,
        'phone': '+40722000111',
        'reason': 'Fără semnal / serviciu mobil.',
      };
      await tester.pumpWidget(const ManagementApp());
      await settle(tester);
      expect(find.text('Un SMS nu a putut fi trimis'), findsOneWidget);
      expect(find.textContaining('+40722000111'), findsOneWidget);
      expect(find.textContaining('24.09.2026 19:30'), findsOneWidget);
      expect(find.textContaining('Fără semnal'), findsOneWidget);
    });

    testWidgets('fără eșecuri: niciun banner', (tester) async {
      await tester.pumpWidget(const ManagementApp());
      await settle(tester);
      expect(find.text('Un SMS nu a putut fi trimis'), findsNothing);
    });

    testWidgets('„OK” închide bannerul și îl marchează ca văzut', (tester) async {
      failure = {
        'failedAt': DateTime(2026, 9, 24, 19, 30).millisecondsSinceEpoch,
        'phone': '0722',
        'reason': 'x',
      };
      await tester.pumpWidget(const ManagementApp());
      await settle(tester);
      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(dismissed, 1);
      expect(find.text('Un SMS nu a putut fi trimis'), findsNothing);
    });

    testWidgets('un eșec apărut cu aplicația deschisă e afișat în ≤20 s',
        (tester) async {
      await tester.pumpWidget(const ManagementApp());
      await settle(tester);
      expect(find.text('Un SMS nu a putut fi trimis'), findsNothing);
      failure = {
        'failedAt': DateTime(2026, 9, 24, 20, 0).millisecondsSinceEpoch,
        'phone': '0722',
        'reason': 'x',
      };
      await tester.pump(const Duration(seconds: 21));
      await settle(tester);
      expect(find.text('Un SMS nu a putut fi trimis'), findsOneWidget);
    });
  });
}
