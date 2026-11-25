import 'package:flutter_test/flutter_test.dart';
import 'package:management_app/main.dart';

void main() {
  test('ora programării = sfârșitul salvat minus durata', () {
    final item = Item(
      syncId: 's',
      number: 1,
      name: 'Ana',
      description: '',
      createdAt: DateTime(2026, 11, 24),
      expiresAt: DateTime(2026, 11, 30, 17, 10),
      durationMin: 30,
    );
    expect(item.startOr(60), DateTime(2026, 11, 30, 16, 40));
    // Fără durată proprie (programări vechi): durata implicită a tabelului.
    final legacy = Item(
      syncId: 'l',
      number: 2,
      name: 'Ioana',
      description: '',
      createdAt: DateTime(2026, 11, 24),
      expiresAt: DateTime(2026, 11, 30, 12, 0),
    );
    expect(legacy.startOr(45), DateTime(2026, 11, 30, 11, 15));
  });

  test('durata implicită prea mică (3 min, rămasă dintr-o versiune veche) devine 30', () {
    expect(sanitizeDefaultDuration(3), 30);
    expect(sanitizeDefaultDuration(null), 30);
    expect(sanitizeDefaultDuration(45), 45);
  });
}
