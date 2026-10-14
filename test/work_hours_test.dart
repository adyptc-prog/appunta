import 'package:flutter_test/flutter_test.dart';

import 'package:management_app/main.dart';

void main() {
  test('programul pe zile se citește înapoi identic', () {
    const hours = {
      3: DayHours(600, 840),
      1: DayHours(540, 1080),
    };
    expect(encodeWorkHours(hours), '1:540-1080,3:600-840');
    expect(parseWorkHours(encodeWorkHours(hours)), hours);
  });

  test('nicio zi lucrătoare → text gol → nicio zi', () {
    expect(encodeWorkHours({}), '');
    expect(parseWorkHours(''), isEmpty);
  });

  test('intrările invalide sunt sărite', () {
    expect(
      parseWorkHours('0:60-120,8:60-120,1:120-60,x,2:60-120,3:60-1500'),
      {2: const DayHours(60, 120)},
    );
  });

  test('ora afișată în grafic', () {
    expect(formatMinutesOfDay(540), '09:00');
    expect(formatMinutesOfDay(17 * 60 + 5), '17:05');
  });
}
