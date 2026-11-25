// Verificarea unui număr de telefon introdus de utilizator, înainte să fie
// salvat (și folosit pentru SMS). Acceptă formatul local (0712 345 678) și
// internațional (+40712345678), cu spații, cratime, puncte sau paranteze.

final _separators = RegExp(r'[\s\-.()/]');

/// Numărul fără separatori: „0712 345-678” → „0712345678”.
String normalizePhoneInput(String input) =>
    input.trim().replaceAll(_separators, '');

/// true pentru un număr plauzibil: doar cifre (opțional „+” la început),
/// între 8 și 15 cifre. Textul gol NU e valid — câmpurile opționale îl
/// verifică separat.
bool isPlausiblePhone(String input) {
  final value = normalizePhoneInput(input);
  final digits = value.startsWith('+') ? value.substring(1) : value;
  if (digits.isEmpty || !RegExp(r'^\d+$').hasMatch(digits)) return false;
  return digits.length >= 8 && digits.length <= 15;
}
