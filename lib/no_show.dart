// ─── Neprezentări (bile roșii) ───────────────────────────────────────────────
// Logică pură, fără Flutter: cine are câte neprezentări în ultimele 6 luni.
//
// Clientul e identificat după numărul de telefon (primul telefon al
// programării) — ultimele 9 cifre, ca „+40712345678”, „0712345678” și
// „0712 345 678” să fie același client (botul compară tot pe sufix).
// Sursa sunt programările marcate „nu a venit” din toate tabelele, inclusiv
// cele șterse (păstrate 6 luni în buffer) — ștergerea unui rând vechi nu
// iartă clientul. Iertarea e un moment per client: neprezentările de dinainte
// nu mai contează.

import 'dart:convert';

import 'l10n.dart';

/// Cât timp contează o neprezentare.
const kNoShowWindow = Duration(days: 180);

/// Cheile din SharedPreferences.
const kNoShowResetsKey  = 'no_show_resets';  // {cheie: ISO} — iertări
const kNoShowSummaryKey = 'no_show_summary'; // {cheie: [ISO]} — citit și nativ

/// Pragul de blocare a rezervărilor prin SMS (0 = niciodată) — citit și de
/// botul nativ (NoShowStore.kt).
const kNoShowThresholdKey = 'no_show_block_threshold';
const kDefaultNoShowThreshold = 3;
const kNoShowThresholdOptions = [0, 2, 3, 4, 5];

bool isBlockedBy(int count, int threshold) => threshold > 0 && count >= threshold;

/// După cât timp o programare neconfirmată devine neprezentare.
const kAutoNoShowAfter = Duration(hours: 24);

/// Programările neconfirmate, pe client: {cheie: [ISO final]} — citit nativ.
const kNoShowPendingKey = 'no_show_pending';

/// SMS către client la neprezentare: opțiunea (per telefon) și programările
/// deja anunțate (o singură dată pe programare).
const kNoShowSmsKey     = 'no_show_sms';
const kNoShowSmsSentKey = 'no_show_sms_sent';

String noShowSmsText(DateTime at, int threshold, int count) {
  String two(int n) => n.toString().padLeft(2, '0');
  final when = tr('${two(at.day)}.${two(at.month)}, ora ${two(at.hour)}:${two(at.minute)}', '${two(at.day)}.${two(at.month)} at ${two(at.hour)}:${two(at.minute)}');
  final base = tr('Nu te-ai prezentat la programarea din $when.', 'You did not show up for your appointment on $when.');
  if (threshold <= 0) return base;
  if (count >= threshold) {
    return tr('$base Nu mai poți face programări prin SMS; te rugăm să suni la salon.', '$base You can no longer book by SMS; please call us.');
  }
  return tr('$base La $threshold neprezentări nu mai poți rezerva prin SMS.', '$base At $threshold no-shows you can no longer book by SMS.');
}

/// Ultimele 9 cifre ale telefonului; '' dacă are prea puține ca să fie sigur.
String clientKey(String? phone) {
  final digits = (phone ?? '').replaceAll(RegExp(r'\D'), '');
  if (digits.length < 7) return '';
  return digits.length <= 9 ? digits : digits.substring(digits.length - 9);
}

// Un număr de telefon scris în text: „0712345678”, „Ana +40 712 345 678”.
final _phoneInText = RegExp(r'\+?\d[\d .\-]{7,}\d');

/// Primul număr de telefon (9–15 cifre) găsit în [text], sau null.
String? findPhoneInText(String text) {
  for (final m in _phoneInText.allMatches(text)) {
    final digits = m.group(0)!.replaceAll(RegExp(r'\D'), '');
    if (digits.length >= 9 && digits.length <= 15) return m.group(0)!.trim();
  }
  return null;
}

/// Telefonul clientului unei programări: Telefon 1 dacă e completat, altfel
/// un număr scris în nume (rezervările manuale și cele prin bot îl pun
/// acolo) sau în descriere.
String? noShowClientPhone(String? phone, String name, String description) {
  if (clientKey(phone).isNotEmpty) return phone;
  return findPhoneInText(name) ?? findPhoneInText(description);
}

/// O programare, redusă la ce contează pentru neprezentări.
typedef NoShowSource = ({
  String syncId,
  String? phone,
  String name,
  DateTime? at,
  bool noShow,
});

class NoShowRecord {
  final String key;
  final String phone; // telefonul așa cum a fost scris ultima dată
  final String name;  // numele de la cea mai recentă neprezentare
  final List<DateTime> dates; // crescător

  const NoShowRecord({
    required this.key,
    required this.phone,
    required this.name,
    required this.dates,
  });

  int get count => dates.length;
  DateTime get last => dates.last;
}

/// Neprezentările active, pe client.
Map<String, NoShowRecord> computeNoShows(
  Iterable<NoShowSource> sources,
  Map<String, DateTime> resets, {
  DateTime? now,
}) {
  final cutoff = (now ?? DateTime.now()).subtract(kNoShowWindow);
  final seen = <String>{};
  final byKey = <String, List<NoShowSource>>{};
  for (final s in sources) {
    if (!s.noShow || s.at == null) continue;
    if (!seen.add(s.syncId)) continue; // aceeași programare în două locuri
    final key = clientKey(s.phone);
    if (key.isEmpty) continue;
    if (!s.at!.isAfter(cutoff)) continue;
    final reset = resets[key];
    if (reset != null && !s.at!.isAfter(reset)) continue;
    byKey.putIfAbsent(key, () => []).add(s);
  }
  return {
    for (final e in byKey.entries)
      e.key: () {
        final list = e.value..sort((a, b) => a.at!.compareTo(b.at!));
        return NoShowRecord(
          key: e.key,
          phone: list.last.phone ?? '',
          name: list.last.name,
          dates: [for (final s in list) s.at!],
        );
      }(),
  };
}

Map<String, DateTime> decodeResets(String? json) {
  if (json == null || json.isEmpty) return {};
  try {
    final m = Map<String, dynamic>.from(jsonDecode(json) as Map);
    return {
      for (final e in m.entries)
        if (DateTime.tryParse('${e.value}') != null)
          e.key: DateTime.parse('${e.value}'),
    };
  } catch (_) {
    return {};
  }
}

/// Mesajul de sincronizare pentru iertare: `ORG:F:cheie|ISO-scurt`.
String forgiveMessage(String key, DateTime at) =>
    'ORG:F:$key|${at.toIso8601String().substring(0, 16)}';

/// (cheie, moment) din „ORG:F:…”, sau null dacă mesajul nu e valid.
(String, DateTime)? parseForgiveMessage(String msg) {
  if (!msg.startsWith('ORG:F:')) return null;
  final parts = msg.substring(6).split('|');
  if (parts.length != 2 || clientKey(parts[0]) != parts[0]) return null;
  final at = DateTime.tryParse(parts[1]);
  return at == null ? null : (parts[0], at);
}
