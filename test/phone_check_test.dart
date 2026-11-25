import 'package:flutter_test/flutter_test.dart';
import 'package:management_app/phone_check.dart';

void main() {
  test('numere valide: local, internațional, cu separatori', () {
    expect(isPlausiblePhone('0712345678'), isTrue);
    expect(isPlausiblePhone('+40712345678'), isTrue);
    expect(isPlausiblePhone('0712 345 678'), isTrue);
    expect(isPlausiblePhone('(0712) 345-678'), isTrue);
  });

  test('respinge text, numere prea scurte și „null”', () {
    expect(isPlausiblePhone('abc'), isFalse);
    expect(isPlausiblePhone('12'), isFalse);
    expect(isPlausiblePhone('null'), isFalse);
    expect(isPlausiblePhone(''), isFalse);
    expect(isPlausiblePhone('0712abc678'), isFalse);
    expect(isPlausiblePhone('+4071234567890123'), isFalse);
  });

  test('normalizează separatorii', () {
    expect(normalizePhoneInput(' 0712 345-678 '), '0712345678');
  });
}
