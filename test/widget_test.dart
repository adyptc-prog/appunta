import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:management_app/main.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    try { await NotificationService.init(); } catch (_) {}
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('afișează spinner la pornire apoi tabelul', (tester) async {
    await tester.pumpWidget(const ManagementApp());

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.text('Appunta'), findsOneWidget);
    expect(find.text('Nr.'), findsOneWidget);
    expect(find.text('Nume'), findsOneWidget);
    expect(find.text('Descriere'), findsOneWidget);
  });

  testWidgets('datele demo apar la prima lansare', (tester) async {
    await tester.pumpWidget(const ManagementApp());
    await tester.pumpAndSettle();

    expect(find.text('Proiect Alpha'), findsOneWidget);
    expect(find.text('Raport lunar'), findsOneWidget);
    expect(find.text('5 înregistrări'), findsOneWidget);
  });

  testWidgets('butonul Adaugă deschide dialogul', (tester) async {
    await tester.pumpWidget(const ManagementApp());
    await tester.pumpAndSettle();

    // Butonul din AppBar are icon Icons.add
    await tester.tap(find.byIcon(Icons.add_circle_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Adaugă înregistrare'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Nume *'), findsOneWidget);
  });

  testWidgets('adăugarea unui item îl include în tabel', (tester) async {
    await tester.pumpWidget(const ManagementApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add_circle_rounded));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Nume *'), 'Test Item');
    // 'Adaugă' apare în AppBar și în dialog; .last = butonul din dialog
    await tester.tap(find.text('Adaugă').last);
    await tester.pumpAndSettle();

    expect(find.text('Test Item'), findsOneWidget);
    expect(find.text('6 înregistrări'), findsOneWidget);
  });

  testWidgets('căutarea filtrează rândurile', (tester) async {
    await tester.pumpWidget(const ManagementApp());
    await tester.pumpAndSettle();

    // Search-ul este ascuns implicit — activăm cu butonul search
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Alpha');
    await tester.pumpAndSettle();

    expect(find.text('Proiect Alpha'), findsOneWidget);
    expect(find.text('Raport lunar'), findsNothing);
    expect(find.textContaining('1 din 5'), findsOneWidget);
  });

  testWidgets('ștergerea unui item îl elimină din tabel', (tester) async {
    await tester.pumpWidget(const ManagementApp());
    await tester.pumpAndSettle();

    // Butonul de delete poate fi în afara viewport-ului orizontal;
    // scrollăm tabelul la dreapta ca să-l facem vizibil
    await tester.ensureVisible(find.byIcon(Icons.delete_outlined).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_outlined).first);
    await tester.pumpAndSettle();

    // Confirmă ștergerea
    await tester.tap(find.text('Șterge').last);
    await tester.pumpAndSettle();

    expect(find.text('4 înregistrări'), findsOneWidget);
  });

  testWidgets('tabelele pot fi comutate și sunt independente',
      (tester) async {
    await tester.pumpWidget(const ManagementApp());
    await tester.pumpAndSettle();

    // Tabelul activ implicit e „Tabel 1”, cu datele demo.
    expect(find.text('Tabel 1'), findsOneWidget);
    expect(find.text('5 înregistrări'), findsOneWidget);

    // Deschidem selectorul de tabele din AppBar.
    await tester.tap(find.text('Tabel 1'));
    await tester.pumpAndSettle();

    expect(find.text('Tabele'), findsOneWidget);
    expect(find.text('Tabel 2'), findsOneWidget);
    expect(find.text('Tabel 3'), findsOneWidget);

    // Comutăm pe „Tabel 2” — trebuie să fie complet gol, independent de Tabel 1.
    await tester.tap(find.text('Tabel 2'));
    await tester.pumpAndSettle();

    expect(find.text('Tabel 2'), findsOneWidget);
    expect(find.text('Proiect Alpha'), findsNothing);
    expect(find.text('0 înregistrări'), findsOneWidget);
  });

  testWidgets('al 10-lea tabel e în selector și poate fi folosit',
      (tester) async {
    await tester.pumpWidget(const ManagementApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Tabel 1'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Tabel 10'), 100,
        scrollable: find.descendant(
            of: find.byType(SimpleDialog),
            matching: find.byType(Scrollable)));
    await tester.tap(find.text('Tabel 10'));
    await tester.pumpAndSettle();

    expect(find.text('Tabel 10'), findsOneWidget);
    expect(find.text('0 înregistrări'), findsOneWidget);
  });

  testWidgets('redenumirea unui tabel actualizează selectorul', (tester) async {
    await tester.pumpWidget(const ManagementApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Tabel 1'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Redenumește').first);
    await tester.pumpAndSettle();

    expect(find.text('Redenumește tabelul'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Nume tabel'), 'Familie');
    await tester.tap(find.text('Salvează'));
    await tester.pumpAndSettle();

    expect(find.text('Familie'), findsOneWidget);
    expect(find.text('Tabel 1'), findsNothing);
  });

  group('versiunea aplicației', () {
    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'Appunta',
        packageName: 'app.sayitapp.organizator',
        version: '1.5.0',
        buildNumber: '9',
        buildSignature: '',
      );
    });

    testWidgets('apare sub tabel', (tester) async {
      await tester.pumpWidget(const ManagementApp());
      await tester.pumpAndSettle();
      expect(find.text('v1.5.0'), findsOneWidget);
    });

    testWidgets('încape pe un telefon îngust (360 px)', (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const ManagementApp());
      await tester.pumpAndSettle();
      expect(find.text('v1.5.0'), findsOneWidget);
      expect(tester.takeException(), isNull); // fără RenderFlex overflow
    });
  });

  testWidgets('aplicația de salon nu mai are modul Pensiune', (tester) async {
    await tester.pumpWidget(const ManagementApp());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.hotel), findsNothing);

    await tester.tap(find.byIcon(Icons.add_circle_rounded));
    await tester.pumpAndSettle();
    expect(find.textContaining('Check-in'), findsNothing);
    expect(find.text('Data expirare: nesetată'), findsOneWidget);
  });
}

