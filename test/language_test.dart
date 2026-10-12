import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:management_app/l10n.dart';
import 'package:management_app/main.dart';
import 'package:management_app/no_show.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    try { await NotificationService.init(); } catch (_) {}
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    AppLang.debugDeviceLanguage = 'ro';
    AppLang.code.value = 'ro';
  });

  group('limba inițială', () {
    test('telefon în română → română', () async {
      AppLang.debugDeviceLanguage = 'ro';
      await AppLang.load();
      expect(AppLang.code.value, 'ro');
      expect(tr('Salvează', 'Save'), 'Salvează');
    });

    test('telefon în altă limbă → engleză', () async {
      for (final lang in ['en', 'de', 'hu']) {
        AppLang.debugDeviceLanguage = lang;
        await AppLang.load();
        expect(AppLang.code.value, 'en', reason: lang);
      }
      expect(tr('Salvează', 'Save'), 'Save');
    });

    test('alegerea din aplicație are prioritate față de limba telefonului',
        () async {
      SharedPreferences.setMockInitialValues({'app_language': 'ro'});
      AppLang.debugDeviceLanguage = 'en';
      await AppLang.load();
      expect(AppLang.code.value, 'ro');

      await AppLang.set('en');
      AppLang.debugDeviceLanguage = 'ro';
      await AppLang.load();
      expect(AppLang.code.value, 'en');
      final prefs = await SharedPreferences.getInstance();
      // Aceeași cheie e citită de botul SMS nativ (AppLang.kt).
      expect(prefs.getString('app_language'), 'en');
    });
  });

  group('interfața', () {
    testWidgets('în engleză, ecranul principal e tradus', (tester) async {
      await AppLang.set('en');
      await tester.pumpWidget(const ManagementApp());
      await tester.pumpAndSettle();

      expect(find.text('Organizator'), findsOneWidget);
      expect(find.text('No.'), findsOneWidget);
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Description'), findsOneWidget);
      // Prima lansare: datele demonstrative apar în limba aplicației.
      expect(find.text('5 entries'), findsOneWidget);
      expect(find.text('Project Alpha'), findsOneWidget);
      expect(find.text('Proiect Alpha'), findsNothing);
      expect(find.text('Report'), findsOneWidget);
      expect(find.text('SMS message'), findsOneWidget);
      expect(find.text('Nume'), findsNothing);
      expect(find.text('Raport'), findsNothing);
      expect(find.byTooltip('App language'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('schimbarea limbii din aplicație se aplică imediat și se salvează',
        (tester) async {
      await tester.pumpWidget(const ManagementApp());
      await tester.pumpAndSettle();
      expect(find.text('Raport'), findsOneWidget);

      await tester.tap(find.byTooltip('Limba aplicației'));
      await tester.pumpAndSettle();
      expect(find.text('Română'), findsOneWidget);
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();

      expect(find.text('Report'), findsOneWidget);
      expect(find.text('Raport'), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_language'), 'en');

      await tester.tap(find.byTooltip('App language'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Română'));
      await tester.pumpAndSettle();
      expect(find.text('Raport'), findsOneWidget);
      expect(prefs.getString('app_language'), 'ro');
    });

    testWidgets('în engleză încape pe un telefon îngust (360 px)',
        (tester) async {
      await AppLang.set('en');
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const ManagementApp());
      await tester.pumpAndSettle();
      expect(find.text('5 entries'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('mesajul SMS de reminder', () {
    Future<String> templateShown(WidgetTester tester, String button) async {
      await tester.pumpWidget(const ManagementApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      return tester.widget<TextField>(find.byType(TextField).last).controller!.text;
    }

    const ro =
        'Alertă: [NUME]. Va expira la [DATA_EXPIRARE]. Te rugăm să iei măsurile necesare.';
    const en =
        'Reminder: [NAME]. It expires on [EXPIRY_DATE]. Please take the necessary steps.';

    testWidgets('mesajul implicit urmează limba aplicației', (tester) async {
      expect(await templateShown(tester, 'Mesaj SMS'), ro);
    });

    testWidgets('mesajul implicit salvat în română devine cel englezesc',
        (tester) async {
      SharedPreferences.setMockInitialValues(
          {'app_language': 'en', 'sms_template': ro});
      await AppLang.load();
      expect(await templateShown(tester, 'SMS message'), en);
    });

    testWidgets('un mesaj editat de utilizator rămâne neatins la schimbarea limbii',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'app_language': 'en',
        'sms_template': 'Vă așteptăm, [NUME]! Ora: [DATA_EXPIRARE].',
      });
      await AppLang.load();
      expect(await templateShown(tester, 'SMS message'),
          'Vă așteptăm, [NUME]! Ora: [DATA_EXPIRARE].');
    });
  });

  group('mesajele către clienți', () {
    test('SMS-ul de neprezentare e în limba aplicației', () async {
      final at = DateTime(2027, 3, 5, 14, 30);
      expect(noShowSmsText(at, 3, 1),
          'Nu te-ai prezentat la programarea din 05.03, ora 14:30. La 3 neprezentări nu mai poți rezerva prin SMS.');

      await AppLang.set('en');
      expect(noShowSmsText(at, 0, 1),
          'You did not show up for your appointment on 05.03 at 14:30.');
      expect(noShowSmsText(at, 3, 1),
          'You did not show up for your appointment on 05.03 at 14:30. At 3 no-shows you can no longer book by SMS.');
      expect(noShowSmsText(at, 3, 3),
          'You did not show up for your appointment on 05.03 at 14:30. You can no longer book by SMS; please call us.');
    });

    test('intervalul alertei e formatat în limba aplicației', () async {
      expect(formatAlertLead(45), '45 min');
      expect(formatAlertLead(60), '1 oră');
      expect(formatAlertLead(1440), '1 zi');
      await AppLang.set('en');
      expect(formatAlertLead(60), '1 hour');
      expect(formatAlertLead(120), '2 hours');
      expect(formatAlertLead(2880), '2 days');
      expect(formatAlertLead(90), '1h 30min');
    });
  });
}
