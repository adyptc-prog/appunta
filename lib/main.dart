import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backup_screen.dart';
import 'backup_service.dart';
import 'l10n.dart';
import 'license_screen.dart';
import 'license_service.dart';
import 'no_show.dart';
import 'services.dart';

// ─── Constante ───────────────────────────────────────────────────────────────
const _kBoardsKey      = 'management_boards';
const _kActiveBoardKey = 'management_active_board';
const _kSmsTemplateKey = 'sms_template';

// Chei folosite înainte de suportul pentru mai multe tabele — păstrate doar
// pentru migrarea automată a datelor existente în „Tabel 1”.
const _kLegacyItemsKey         = 'management_items';
const _kLegacyNextNumberKey    = 'management_next_number';
const _kLegacyDeletedBufferKey = 'management_deleted_buffer';
const _kLegacySyncPartnerKey   = 'sync_partner_phone';

String _itemsKeyFor(String boardId)         => 'management_items_$boardId';
String _nextNumberKeyFor(String boardId)    => 'management_next_number_$boardId';
String _deletedBufferKeyFor(String boardId) => 'management_deleted_buffer_$boardId';
String _syncPartnerKeyFor(String boardId)   => 'sync_partner_phone_$boardId';
// Codul de împerechere al tabelului — semnează mesajele de sincronizare
// (SyncAuth.kt); trebuie introdus identic pe ambele telefoane.
String _syncSecretKeyFor(String boardId)    => 'sync_secret_$boardId';

// ── Chei pentru setările de rezervări prin SMS (per tabel) ────────────────────
String _bookingEnabledKeyFor(String boardId)      => 'booking_enabled_$boardId';
String _appointmentDurationKeyFor(String boardId) => 'appointment_duration_$boardId';
String _workStartKeyFor(String boardId)           => 'work_start_$boardId';
String _workEndKeyFor(String boardId)             => 'work_end_$boardId';
String _closedDaysKeyFor(String boardId)          => 'closed_days_$boardId';

// ── Cu cât timp înainte de expirare vine alerta (per tabel, în minute) ────────
// Ultima valoare aleasă în „Setează alertă” — folosită automat pentru
// programările noi (adăugate manual sau prin botul SMS). Citită și nativ de
// ClientBookingReceiver, ca rezervările prin bot să aibă alerta din start.
String _alertLeadKeyFor(String boardId) => 'alert_lead_minutes_$boardId';
const kDefaultAlertLeadMin = 60;

int _loadAlertLead(SharedPreferences prefs, String boardId) {
  final v = prefs.getInt(_alertLeadKeyFor(boardId));
  return v != null && v > 0 ? v : kDefaultAlertLeadMin;
}

/// Ora alertei pentru o programare care expiră la [expiresAt]: cu [leadMin]
/// minute înainte. Null dacă acel moment a trecut deja (alerta n-ar mai
/// pleca niciodată).
DateTime? autoWarningFor(DateTime? expiresAt, int leadMin, {DateTime? now}) {
  if (expiresAt == null || leadMin <= 0) return null;
  final w = expiresAt.subtract(Duration(minutes: leadMin));
  return w.isAfter(now ?? DateTime.now()) ? w : null;
}

/// „90” → „1h 30min”, „1440” → „1 zi”.
String formatAlertLead(int minutes) {
  if (minutes < 60) return '$minutes min';
  if (minutes % 1440 == 0) {
    final d = minutes ~/ 1440;
    return tr('$d ${d == 1 ? "zi" : "zile"}', '$d ${d == 1 ? "day" : "days"}');
  }
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (m == 0) return tr('$h ${h == 1 ? "oră" : "ore"}', '$h ${h == 1 ? "hour" : "hours"}');
  return '${h}h ${m}min';
}

// Identice cu DEFAULT_TEMPLATE_RO / DEFAULT_TEMPLATE_EN din BotReminders.kt.
const _kDefaultSmsTemplateRo =
    'Alertă: [NUME]. Va expira la [DATA_EXPIRARE]. Te rugăm să iei măsurile necesare.';
const _kDefaultSmsTemplateEn =
    'Reminder: [NAME]. It expires on [EXPIRY_DATE]. Please take the necessary steps.';

// Mesajul implicit urmează limba aplicației. Un mesaj salvat identic cu unul
// din cele implicite e tratat tot ca implicit; unul editat de utilizator
// rămâne neatins la schimbarea limbii.
String get _defaultSmsTemplate =>
    tr(_kDefaultSmsTemplateRo, _kDefaultSmsTemplateEn);

String _effectiveSmsTemplate(String? saved) =>
    (saved == null ||
            saved.trim().isEmpty ||
            saved == _kDefaultSmsTemplateRo ||
            saved == _kDefaultSmsTemplateEn)
        ? _defaultSmsTemplate
        : saved;

enum _AlertMode { lead, exact, none }

// ── Prezența la programare ────────────────────────────────────────────────────
const kCame   = 'came';
const kNoShow = 'noShow';
// Momentul de la care aplicația cere confirmarea prezenței — programările
// încheiate înainte de această funcție nu devin „de confirmat”.
const _kAttendanceSinceKey = 'attendance_since';

/// Programare încheiată (după ora de final), încă neconfirmată de salon.
bool needsAttendance(Item item, DateTime? since, {DateTime? now}) =>
    item.attendance == null &&
    item.expiresAt != null &&
    item.expiresAt!.isBefore(now ?? DateTime.now()) &&
    since != null &&
    item.expiresAt!.isAfter(since);

// ─── Helper: ID unic stabil pentru sincronizare ───────────────────────────────
String _generateSyncId() {
  final r = Random.secure();
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List.generate(16, (_) => chars[r.nextInt(chars.length)]).join();
}

// Format ISO scurt (fără secunde) pentru SMS compact
String _isoShort(DateTime dt) =>
    '${dt.year}-'
    '${dt.month.toString().padLeft(2, '0')}-'
    '${dt.day.toString().padLeft(2, '0')}T'
    '${dt.hour.toString().padLeft(2, '0')}:'
    '${dt.minute.toString().padLeft(2, '0')}';

// ─── Serviciu notificări push ─────────────────────────────────────────────────
// Notificările sunt programate via AlarmManager nativ (același mecanism ca SMS),
// prin NotifAlarmReceiver.kt — fiabil pe orice versiune Android, fără dependență
// de flutter_local_notifications scheduling.
class NotificationService {
  static const _ch = MethodChannel('organizator/sms');

  static final _plugin = FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    // Inițializăm plugin-ul doar pentru requestPermissions — fără scheduling
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );
    await _plugin.initialize(settings);
  }

  static Future<void> requestPermissions() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
      await android?.requestExactAlarmsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (_) {}

    if (_isAndroid) {
      try {
        final status = await Permission.ignoreBatteryOptimizations.status;
        if (!status.isGranted) {
          await Permission.ignoreBatteryOptimizations.request();
        }
      } catch (_) {}
    }
  }

  // ID-urile alarmelor includ indexul tabelului (0..9) ca să nu se
  // suprapună între tabele diferite — pentru tabelul 0 (primul, migrat din
  // versiunea cu un singur tabel) formula rămâne identică cu cea veche.
  static Future<void> scheduleFor(Item item, {required int boardIndex}) async {
    if (!_isAndroid) return;
    await cancelFor(item.number, boardIndex: boardIndex);
    final now  = DateTime.now();
    final base = boardIndex * 1000000;

    if (item.warningAt != null &&
        item.warningAt!.isAfter(now) &&
        item.expiresAt != null) {
      await _schedule(
        id: base + item.number * 10 + 1,
        when: item.warningAt!,
        title: tr('⚠️ Alertă: ${item.name}', '⚠️ Alert: ${item.name}'),
        body: tr('Va expira la ${_fmt(item.expiresAt!)}', 'It expires on ${_fmt(item.expiresAt!)}'),
      );
    }
    if (item.expiresAt != null && item.expiresAt!.isAfter(now)) {
      await _schedule(
        id: base + item.number * 10 + 2,
        when: item.expiresAt!,
        title: tr('Programare încheiată: ${item.name}', 'Appointment ended: ${item.name}'),
        body: tr('A venit? Confirmă prezența în aplicație.', 'Did they arrive? Confirm attendance in the app.'),
      );
    }
  }

  static Future<void> cancelFor(int number, {required int boardIndex}) async {
    if (!_isAndroid) return;
    final base = boardIndex * 1000000;
    try {
      await _ch.invokeMethod<void>('cancelNotif', {'id': base + number * 10 + 1});
      await _ch.invokeMethod<void>('cancelNotif', {'id': base + number * 10 + 2});
    } catch (_) {}
  }

  static Future<void> _schedule({
    required int id,
    required DateTime when,
    required String title,
    required String body,
  }) async {
    try {
      await _ch.invokeMethod<void>('scheduleNotif', {
        'id': id,
        'triggerAtMs': when.millisecondsSinceEpoch,
        'title': title,
        'body': body,
      });
    } catch (_) {}
  }

  static String _fmt(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}.'
      '${dt.month.toString().padLeft(2, '0')}.'
      '${dt.year} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';
}

// Testele rulează pe desktop — permite simularea Android-ului pentru
// permisiuni și sincronizare (canalele native sunt simulate în teste).
@visibleForTesting
bool? debugSimulateAndroid;
bool get _isAndroid => debugSimulateAndroid ?? Platform.isAndroid;

// ─── Serviciu SMS (alarme programate via Kotlin AlarmManager) ─────────────────
class SmsService {
  static const _ch = MethodChannel('organizator/sms');

  static bool get isAndroid => _isAndroid;

  // Permission.sms cere împreună SEND_SMS și RECEIVE_SMS (trimitere +
  // sincronizare / rezervări prin SMS).
  static Future<bool> requestPermission() async {
    if (!isAndroid) return true;
    try {
      return (await Permission.sms.request()).isGranted;
    } catch (_) {
      return false;
    }
  }

  // Fără permisiune, toate SMS-urile (remindere, rezervări, sincronizare,
  // licență) eșuează silențios în partea nativă — interfața trebuie să știe.
  static Future<bool> hasPermission() async {
    if (!isAndroid) return true;
    try {
      return (await Permission.sms.status).isGranted;
    } catch (_) {
      return false;
    }
  }

  // Ultimul SMS care nu a putut fi trimis (raportul sistemului), neînchis
  // încă de utilizator — sau null.
  static Future<({DateTime failedAt, String phone, String reason})?>
      pendingFailure() async {
    if (!isAndroid) return null;
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('getSmsFailure');
      if (r == null) return null;
      return (
        failedAt: DateTime.fromMillisecondsSinceEpoch((r['failedAt'] as int?) ?? 0),
        phone: (r['phone'] as String?) ?? '',
        reason: (r['reason'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  // Xiaomi: fără „Pornire automată”, aplicația glisată din Recente nu mai e
  // pornită de sistem pentru SMS-urile primite (botul și sincronizarea tac).
  // true = refuzată; false = permisă, necunoscută sau alt producător.
  static Future<bool> autostartBlocked() async {
    if (!isAndroid) return false;
    try {
      return await _ch.invokeMethod<String>('getAutostartState') == 'denied';
    } catch (_) {
      return false;
    }
  }

  static Future<void> openAutostartSettings() async {
    if (!isAndroid) return;
    try { await _ch.invokeMethod<bool>('openAutostartSettings'); } catch (_) {}
  }

  static Future<void> dismissFailure() async {
    if (!isAndroid) return;
    try { await _ch.invokeMethod<void>('dismissSmsFailure'); } catch (_) {}
  }

  // Trimite un SMS imediat (nu programat) — folosit pentru notificarea
  // clientului la evenimente manuale din aplicație (ex. validarea plății).
  static Future<void> sendNow(String phone, String message) async {
    if (!isAndroid) return;
    try {
      await _ch.invokeMethod<void>('sendSms', {'phone': phone, 'message': message});
    } catch (_) {}
  }

  // ID-urile includ indexul tabelului (0..9) ca să nu se suprapună între
  // tabele diferite — pentru tabelul 0 formula rămâne identică cu cea veche.
  static List<int> _warnIds(int n, int boardIndex) {
    final base = boardIndex * 10000000;
    return [base + n * 100 + 10, base + n * 100 + 11, base + n * 100 + 12];
  }

  static List<int> _expIds(int n, int boardIndex) {
    final base = boardIndex * 10000000;
    return [base + n * 100 + 20, base + n * 100 + 21, base + n * 100 + 22];
  }

  static Future<void> scheduleFor(Item item,
      {String? template, required int boardIndex}) async {
    final tpl = _effectiveSmsTemplate(template);
    if (!isAndroid) return;
    // Așteptăm anularea: altfel ștergerea payload-ului vechi (sms_alarm_<id>)
    // și anularea nativă pot ajunge DUPĂ programarea nouă, sub același id.
    await cancelFor(item.number, boardIndex: boardIndex);
    final phones = item.phones;
    if (phones.isEmpty) return;

    final now       = DateTime.now();
    final expiryStr = item.expiresAt != null ? _fmt(item.expiresAt!) : tr('nesetată', 'not set');
    String buildMsg(String tmpl) => tmpl
        .replaceAll('[NUME]', item.name)
        .replaceAll('[NAME]', item.name)
        .replaceAll('[DATA_EXPIRARE]', expiryStr)
        .replaceAll('[EXPIRY_DATE]', expiryStr);

    if (item.warningAt != null && item.warningAt!.isAfter(now)) {
      final ids = _warnIds(item.number, boardIndex);
      for (var i = 0; i < phones.length && i < ids.length; i++) {
        await _schedule(
            id: ids[i], when: item.warningAt!, phone: phones[i],
            message: buildMsg(tpl));
      }
    }
    if (!item.viaBot && item.expiresAt != null && item.expiresAt!.isAfter(now)) {
      final ids = _expIds(item.number, boardIndex);
      for (var i = 0; i < phones.length && i < ids.length; i++) {
        await _schedule(
            id: ids[i], when: item.expiresAt!, phone: phones[i],
            message: tr('EXPIRAT: ${buildMsg(tpl)}', 'EXPIRED: ${buildMsg(tpl)}'));
      }
    }
  }

  static Future<void> cancelFor(int number, {required int boardIndex}) async {
    if (!isAndroid) return;
    final base = boardIndex * 10000000;
    final ids = [
      ..._warnIds(number, boardIndex), ..._expIds(number, boardIndex),
      base + number * 10 + 3, base + number * 10 + 4,
    ];
    final prefs = await SharedPreferences.getInstance();
    for (final id in ids) {
      try {
        await _ch.invokeMethod<void>('cancel', {'id': id});
      } catch (_) {}
      await prefs.remove('sms_alarm_$id');
    }
  }

  static Future<void> _schedule({
    required int id,
    required DateTime when,
    required String phone,
    required String message,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'sms_alarm_$id', jsonEncode({'phone': phone, 'message': message}));
      await _ch.invokeMethod('schedule', {
        'id': id,
        'triggerAtMs': when.millisecondsSinceEpoch,
      });
    } catch (_) {}
  }

  static String _fmt(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}.'
      '${dt.month.toString().padLeft(2, '0')}.'
      '${dt.year} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';

  // Calculul sloturilor libere rulează nativ (Kotlin) pe Android — aceeași
  // sursă de adevăr folosită și de botul de rezervări prin SMS, ca ecranul
  // „Spatiere” să nu poată diverge de ce vede botul. Nu e disponibil pe alte
  // platforme (nu există acces SMS acolo, deci nici bot de rezervat).
  static Future<List<_FreeSlot>> _computeFreeSlots(
    String boardId, {
    required int durationMin,
    int horizonDays = 14,
    int maxResults = 200,
  }) async {
    if (!_isAndroid) return [];
    try {
      final raw = await _ch.invokeMethod<String>('computeFreeSlots', {
            'boardId': boardId,
            'durationMin': durationMin,
            'horizonDays': horizonDays,
            'maxResults': maxResults,
          }) ??
          '[]';
      final decoded = jsonDecode(raw) as List<dynamic>;
      debugPrint('OrgDiag: _computeFreeSlots boardId=$boardId rawLen=${raw.length} count=${decoded.length}');
      return decoded.map((e) {
        final m = e as Map<String, dynamic>;
        return _FreeSlot(
          DateTime.fromMillisecondsSinceEpoch(m['s'] as int),
          DateTime.fromMillisecondsSinceEpoch(m['e'] as int),
        );
      }).toList();
    } catch (e, st) {
      debugPrint('OrgDiag: _computeFreeSlots FAILED boardId=$boardId error=$e\n$st');
      return [];
    }
  }
}

// ─── Serviciu sincronizare bidirecțională prin SMS ────────────────────────────
//
// Protocol:
//   ORG:A:{json}  — item adăugat
//   ORG:U:{json}  — item actualizat
//   ORG:D:{syncId} — item șters
//   ORG:I:{json}  — item din sincronizare inițială (bulk)
//   ORG:Z:        — sfârșitul sincronizării inițiale
//   ORG:V:{json}  — lista de servicii a tabelului (services.dart); aplicată
//                   și nativ, la primire, ca botul s-o folosească imediat
//
// Câmpuri JSON compact: s=syncId, n=name, d=description, c=createdAt,
//   e=expiresAt, w=warningAt, p1/p2/p3=phoneNumbers,
//   b=rezervare prin bot (viaBot), a=prezență ('c' a venit / 'n' nu a venit),
//   v=serviciu, m=durata programării în minute
class SyncService {
  static const _ch = MethodChannel('organizator/sms');
  static String? _partnerPhone;
  static String? _pairingCode;
  static String  _boardId = '';

  static const minCodeLength = 8;

  static bool get isSupported => _isAndroid;
  // Activă doar cu număr ȘI cod de împerechere — fără cod, partenerul ar
  // respinge toate mesajele (sunt semnate).
  static bool get isActive =>
      _partnerPhone != null &&
      _partnerPhone!.isNotEmpty &&
      isValidCode(_pairingCode);
  static String? get partnerPhone => _partnerPhone;
  static String? get pairingCode =>
      _pairingCode == null ? null : formatCode(_pairingCode!);

  // Identic cu SyncAuth.normalizeCode din Kotlin.
  static String normalizeCode(String? code) =>
      (code ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  static bool isValidCode(String? code) =>
      normalizeCode(code).length >= minCodeLength;

  // „K7QM2XPA” → „K7QM-2XPA”, ușor de citit și de tastat pe celălalt telefon.
  static String formatCode(String code) {
    final n = normalizeCode(code);
    final groups = <String>[];
    for (var i = 0; i < n.length; i += 4) {
      groups.add(n.substring(i, min(i + 4, n.length)));
    }
    return groups.join('-');
  }

  // Fără caractere ușor de confundat (0/O, 1/I/L).
  static String generateCode() {
    const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return formatCode(
        List.generate(minCodeLength, (_) => alphabet[r.nextInt(alphabet.length)])
            .join());
  }

  // Fiecare tabel are propriul partener de sincronizare — se încarcă la
  // activarea tabelului respectiv.
  static Future<void> load(String boardId) async {
    _boardId = boardId;
    _partnerPhone = null;
    _pairingCode = null;
    if (!isSupported) return;
    final prefs = await SharedPreferences.getInstance();
    _partnerPhone = prefs.getString(_syncPartnerKeyFor(boardId));
    _pairingCode = prefs.getString(_syncSecretKeyFor(boardId));
  }

  static Future<void> setPartner(String phone, String code) async {
    _partnerPhone = phone.trim();
    _pairingCode = normalizeCode(code);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_syncPartnerKeyFor(_boardId), _partnerPhone!);
    await prefs.setString(_syncSecretKeyFor(_boardId), _pairingCode!);
  }

  static Future<void> clearPartner() async {
    _partnerPhone = null;
    _pairingCode = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_syncPartnerKeyFor(_boardId));
    await prefs.remove(_syncSecretKeyFor(_boardId));
  }

  // Semnarea și trimiterea se fac nativ (SmsSyncReceiver.sendSigned).
  static Future<bool> _sendForBoard(String boardId, String msg) async {
    if (!isSupported) return false;
    try {
      return await _ch.invokeMethod<bool>(
              'sendSync', {'boardId': boardId, 'message': msg}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _send(String msg) async {
    if (!isActive || !isSupported) return;
    await _sendForBoard(_boardId, msg);
  }

  // Trimite toate înregistrările la sincronizarea inițială
  static Future<void> sendInitialSync(List<Item> items) async {
    for (final item in items) {
      await _send('ORG:I:${jsonEncode(item.toSyncJson())}');
      // Pauză între SMS-uri pentru a evita limitele operatorului
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    await _send('ORG:Z:');
  }

  // Lista de servicii a tabelului (înlocuiește lista partenerului).
  static Future<void> sendServices(int defaultMin, List<SalonService> services) =>
      _send(servicesSyncMessage(defaultMin, services));

  static Future<void> sendAdd(Item item) =>
      _send('ORG:A:${jsonEncode(item.toSyncJson())}');

  static Future<void> sendUpdate(Item item) =>
      _send('ORG:U:${jsonEncode(item.toSyncJson())}');

  static Future<void> sendDelete(String syncId) =>
      _send('ORG:D:$syncId');

  // Licența cumpărată merge pe ambele telefoane sincronizate. La împerechere,
  // telefonul cu licență o trimite („L”), iar cel fără licență o cere („R”) —
  // partenerul poate să-l fi configurat deja pe acesta înainte, caz în care
  // licența trimisă atunci a fost ignorată. Mesajele sunt tratate nativ, în
  // SmsSyncReceiver, doar dacă vin de la partenerul configurat.
  static Future<void> sendLicenseHandshake() async {
    if (!isActive) return;
    // Telefonul cu licență o trimite (dacă are voie); cel fără o cere.
    final status = await LicenseService.shareWithBoard(_boardId);
    if (status == 'no_license') await _send('ORG:R:');
  }

  // Tabelele cu partener și cod de împerechere, câte unul per număr de
  // telefon (același partener pe mai multe tabele primește un singur SMS).
  static Future<List<String>> pairedBoards() async {
    final prefs = await SharedPreferences.getInstance();
    final boards = await _loadOrMigrateBoards(prefs);
    final byPhone = <String, String>{};
    for (final b in boards) {
      final phone = prefs.getString(_syncPartnerKeyFor(b.id))?.trim() ?? '';
      final digits = phone.replaceAll(RegExp(r'\D'), '');
      if (digits.isEmpty || !isValidCode(prefs.getString(_syncSecretKeyFor(b.id)))) {
        continue;
      }
      byPhone.putIfAbsent(digits, () => b.id);
    }
    return byPhone.values.toList();
  }

  // Trimite licența partenerilor (nativ refuză un al treilea telefon).
  static Future<LicenseShareOutcome> sendLicenseToAllPartners() async {
    if (!isSupported) return (sent: 0, refused: null);
    var sent = 0;
    String? refused;
    for (final boardId in await pairedBoards()) {
      final status = await LicenseService.shareWithBoard(boardId);
      if (status == 'sent') sent++;
      if (status == 'not_owner' || status == 'other_partner') refused = status;
    }
    return (sent: sent, refused: refused);
  }

  // Fiecare mesaj din coadă e etichetat de partea nativă cu tabelul al cărui
  // partener configurat corespunde expeditorului SMS-ului (boardId poate fi
  // gol dacă a fost primit înainte ca migrarea pe mai multe tabele să ruleze
  // — în acel caz se consideră primul tabel). Fiecare intrare are un id,
  // folosit la confirmare (ackMessages).
  static Future<List<SyncQueueEntry>> getPendingMessages() async {
    if (!isSupported) return [];
    try {
      final raw = await _ch.invokeMethod<String>('getSyncMessages') ?? '[]';
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .map<SyncQueueEntry?>((e) {
            if (e is! Map) return null;
            final id = e['id'] as String?;
            final msg = e['msg'] as String?;
            if (id == null || id.isEmpty) return null;
            return (
              id: id,
              boardId: (e['board'] as String?) ?? '',
              msg: msg ?? '',
              // Intrările scrise de versiuni vechi nu au „origin” — le
              // tratăm ca venite de la partener (nu le retrimitem).
              fromPartner: e['origin'] != 'local',
            );
          })
          .whereType<SyncQueueEntry>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  // Trimite partenerului unui anumit tabel (nu neapărat cel activ) — pentru
  // schimbările făcute nativ, cu aplicația închisă, pe orice tabel.
  static Future<void> sendToBoardPartner(String boardId, String msg) =>
      _sendForBoard(boardId, msg);

  // Scoate din coadă doar intrările procesate — nu și pe cele sosite între
  // timp (golirea completă a cozii le pierdea).
  static Future<void> ackMessages(List<String> ids) async {
    if (!isSupported || ids.isEmpty) return;
    try {
      await _ch.invokeMethod<void>('ackSyncMessages', {'ids': ids});
    } catch (_) {}
  }
}

// ─── Model ────────────────────────────────────────────────────────────────────
class Item {
  final String syncId;
  final int number;
  final String name;
  final String description;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final DateTime? warningAt;
  final String? phoneNumber;
  final String? phoneNumber2;
  final String? phoneNumber3;
  // Rezervare făcută de client prin botul SMS. Telefonul ei e al clientului
  // (pentru anulare/confirmări), nu un destinatar de alerte: la expirare nu
  // primește SMS-ul „EXPIRAT”.
  final bool viaBot;
  // Prezența la programare, confirmată de salon după ora de final:
  // null = neconfirmată, 'came' = a venit, 'noShow' = nu a venit.
  final String? attendance;
  // „Nu a venit” pus automat (neconfirmată în 24h), nu de salon.
  final bool attendanceAuto;
  // Serviciul programării (din ecranul „Servicii”) și durata lui, în minute.
  // Programarea ocupă [expiresAt − durationMin, expiresAt]; fără durată
  // (programări vechi) se folosește durata implicită a tabelului.
  final String? service;
  final int? durationMin;

  const Item({
    required this.syncId,
    required this.number,
    required this.name,
    required this.description,
    required this.createdAt,
    this.expiresAt,
    this.warningAt,
    this.phoneNumber,
    this.phoneNumber2,
    this.phoneNumber3,
    this.viaBot = false,
    this.attendance,
    this.attendanceAuto = false,
    this.service,
    this.durationMin,
  });

  /// Durata programării — a ei sau, dacă nu o are, [defaultMin] (tabelul).
  int durationOr(int defaultMin) =>
      durationMin != null && durationMin! > 0 ? durationMin! : defaultMin;

  // Telefonul după care e recunoscut clientul (neprezentări).
  String? get clientPhone =>
      noShowClientPhone(phoneNumber, name, description);

  List<String> get phones => [
        if (phoneNumber  != null && phoneNumber!.isNotEmpty)  phoneNumber!,
        if (phoneNumber2 != null && phoneNumber2!.isNotEmpty) phoneNumber2!,
        if (phoneNumber3 != null && phoneNumber3!.isNotEmpty) phoneNumber3!,
      ];

  Item copyWith({
    String? syncId,
    int? number,
    String? name,
    String? description,
    DateTime? createdAt,
    DateTime? expiresAt,
    bool clearExpiry = false,
    DateTime? warningAt,
    bool clearWarning = false,
    String? phoneNumber,
    bool clearPhone = false,
    String? phoneNumber2,
    bool clearPhone2 = false,
    String? phoneNumber3,
    bool clearPhone3 = false,
    String? attendance,
    bool clearAttendance = false,
    bool? attendanceAuto,
    String? service,
    int? durationMin,
    bool clearService = false,
  }) {
    return Item(
      syncId:       syncId       ?? this.syncId,
      number:       number       ?? this.number,
      name:         name         ?? this.name,
      description:  description  ?? this.description,
      createdAt:    createdAt    ?? this.createdAt,
      expiresAt:    clearExpiry   ? null : (expiresAt   ?? this.expiresAt),
      warningAt:    clearWarning  ? null : (warningAt   ?? this.warningAt),
      phoneNumber:  clearPhone    ? null : (phoneNumber  ?? this.phoneNumber),
      phoneNumber2: clearPhone2   ? null : (phoneNumber2 ?? this.phoneNumber2),
      phoneNumber3: clearPhone3   ? null : (phoneNumber3 ?? this.phoneNumber3),
      viaBot:       viaBot,
      attendance:   clearAttendance ? null : (attendance ?? this.attendance),
      attendanceAuto: clearAttendance
          ? false
          : (attendanceAuto ?? (attendance != null ? false : this.attendanceAuto)),
      service:      clearService ? null : (service ?? this.service),
      durationMin:  clearService ? null : (durationMin ?? this.durationMin),
    );
  }

  // Persistență locală (JSON complet)
  Map<String, dynamic> toJson() => {
        'syncId':       syncId,
        'number':       number,
        'name':         name,
        'description':  description,
        'createdAt':    createdAt.toIso8601String(),
        'expiresAt':    expiresAt?.toIso8601String(),
        'warningAt':    warningAt?.toIso8601String(),
        'phoneNumber':  phoneNumber,
        'phoneNumber2': phoneNumber2,
        'phoneNumber3': phoneNumber3,
        'viaBot':       viaBot,
        'attendance':   attendance,
        if (attendanceAuto) 'attendanceAuto': true,
        if (service != null) 'service': service,
        if (durationMin != null) 'durationMin': durationMin,
      };

  factory Item.fromJson(Map<String, dynamic> json) => Item(
        // Migrare: dacă syncId lipsește (date vechi), generăm unul nou
        syncId:       (json['syncId'] as String?) ?? _generateSyncId(),
        number:       json['number']      as int,
        name:         json['name']        as String,
        description:  json['description'] as String,
        createdAt:    DateTime.parse(json['createdAt'] as String),
        expiresAt:    json['expiresAt']  != null
            ? DateTime.parse(json['expiresAt']  as String) : null,
        warningAt:    json['warningAt']  != null
            ? DateTime.parse(json['warningAt']  as String) : null,
        phoneNumber:  json['phoneNumber']  as String?,
        phoneNumber2: json['phoneNumber2'] as String?,
        phoneNumber3: json['phoneNumber3'] as String?,
        viaBot:       json['viaBot'] as bool? ?? false,
        attendance:   json['attendance'] as String?,
        attendanceAuto: json['attendanceAuto'] == true,
        service:      json['service'] as String?,
        durationMin:  json['durationMin'] as int?,
      );

  // Format compact pentru SMS (câmpuri opționale omise dacă sunt goale/null)
  Map<String, dynamic> toSyncJson() => {
        's': syncId,
        'n': name,
        if (description.isNotEmpty) 'd': description,
        'c': _isoShort(createdAt),
        if (expiresAt != null) 'e': _isoShort(expiresAt!),
        if (warningAt != null) 'w': _isoShort(warningAt!),
        if (phoneNumber  != null && phoneNumber!.isNotEmpty)  'p1': phoneNumber,
        if (phoneNumber2 != null && phoneNumber2!.isNotEmpty) 'p2': phoneNumber2,
        if (phoneNumber3 != null && phoneNumber3!.isNotEmpty) 'p3': phoneNumber3,
        if (viaBot) 'b': true,
        if (attendance == kCame) 'a': 'c',
        if (attendance == kNoShow) 'a': 'n',
        if (service != null) 'v': service,
        if (durationMin != null) 'm': durationMin,
      };

  factory Item.fromSyncJson(Map<String, dynamic> j) => Item(
        syncId:       j['s'] as String,
        number:       0, // numărul local se asignează la merge
        name:         j['n'] as String,
        description:  (j['d'] as String?) ?? '',
        createdAt:    DateTime.parse(j['c'] as String),
        expiresAt:    j['e'] != null ? DateTime.parse(j['e'] as String) : null,
        warningAt:    j['w'] != null ? DateTime.parse(j['w'] as String) : null,
        phoneNumber:  j['p1'] as String?,
        phoneNumber2: j['p2'] as String?,
        phoneNumber3: j['p3'] as String?,
        viaBot:       j['b'] == true,
        attendance:   switch (j['a']) { 'c' => kCame, 'n' => kNoShow, _ => null },
        service:      j['v'] as String?,
        durationMin:  j['m'] as int?,
      );
}

// ─── Buffer înregistrări șterse (6 luni) ─────────────────────────────────────
class DeletedItem {
  final Item item;
  final DateTime deletedAt;

  const DeletedItem({required this.item, required this.deletedAt});

  bool get isExpiredFromBuffer => deletedAt.isBefore(
        DateTime.now().subtract(const Duration(days: 180)));

  Map<String, dynamic> toJson() => {
        'item': item.toJson(),
        'deletedAt': deletedAt.toIso8601String(),
      };

  factory DeletedItem.fromJson(Map<String, dynamic> json) => DeletedItem(
        item: Item.fromJson(json['item'] as Map<String, dynamic>),
        deletedAt: DateTime.parse(json['deletedAt'] as String),
      );
}

// fromPartner: mesajul a venit de la partenerul de sincronizare (nu se
// retrimite). Altfel e o schimbare locală făcută nativ (botul de rezervări,
// anularea automată) pe care partenerul trebuie s-o primească.
typedef SyncQueueEntry = ({String id, String boardId, String msg, bool fromPartner});

typedef ReportEntry = ({Item item, DateTime? deletedAt});

enum SortColumn { number, name, description, createdAt, expiresAt }

// ─── Tabel (board) ─────────────────────────────────────────────────────────────
class Board {
  final String id;
  final String name;

  const Board({required this.id, required this.name});

  Board copyWith({String? name}) => Board(id: id, name: name ?? this.name);

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory Board.fromJson(Map<String, dynamic> json) => Board(
        id:   json['id']   as String,
        name: json['name'] as String,
      );
}

// ─── Setări rezervări prin SMS (per tabel) ────────────────────────────────────
class BookingSettingsData {
  final bool enabled;
  final int  durationMin;
  // Program de lucru (minute de la miezul nopții).
  final int  workStartMin;
  final int  workEndMin;
  final Set<int> closedDays; // DateTime.weekday: 1=luni .. 7=duminică

  const BookingSettingsData({
    required this.enabled,
    required this.durationMin,
    required this.workStartMin,
    required this.workEndMin,
    required this.closedDays,
  });

  static const defaults = BookingSettingsData(
    enabled: false,
    durationMin: 30,
    workStartMin: 9 * 60,
    workEndMin: 18 * 60,
    closedDays: {},
  );

  BookingSettingsData copyWith({
    bool? enabled,
    int? durationMin,
    int? workStartMin,
    int? workEndMin,
    Set<int>? closedDays,
  }) =>
      BookingSettingsData(
        enabled:      enabled      ?? this.enabled,
        durationMin:  durationMin  ?? this.durationMin,
        workStartMin: workStartMin ?? this.workStartMin,
        workEndMin:   workEndMin   ?? this.workEndMin,
        closedDays:   closedDays   ?? this.closedDays,
      );
}

Future<BookingSettingsData> _loadBookingSettings(
    SharedPreferences prefs, String boardId) async {
  final closedStr = prefs.getString(_closedDaysKeyFor(boardId)) ?? '';
  final closed = closedStr
      .split(',')
      .map((s) => int.tryParse(s.trim()))
      .whereType<int>()
      .toSet();
  return BookingSettingsData(
    enabled: prefs.getBool(_bookingEnabledKeyFor(boardId)) ??
        BookingSettingsData.defaults.enabled,
    durationMin: prefs.getInt(_appointmentDurationKeyFor(boardId)) ??
        BookingSettingsData.defaults.durationMin,
    workStartMin: prefs.getInt(_workStartKeyFor(boardId)) ??
        BookingSettingsData.defaults.workStartMin,
    workEndMin: prefs.getInt(_workEndKeyFor(boardId)) ??
        BookingSettingsData.defaults.workEndMin,
    closedDays: closed,
  );
}

Future<void> _saveBookingSettings(String boardId, BookingSettingsData s) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_bookingEnabledKeyFor(boardId), s.enabled);
  await prefs.setInt(_appointmentDurationKeyFor(boardId), s.durationMin);
  await prefs.setInt(_workStartKeyFor(boardId), s.workStartMin);
  await prefs.setInt(_workEndKeyFor(boardId), s.workEndMin);
  await prefs.setString(_closedDaysKeyFor(boardId), s.closedDays.join(','));
}

// Numărul de tabele (categorii de servicii). ID-urile alarmelor includ indexul
// tabelului (index × 10.000.000 pentru SMS) — cu 10 tabele rămân sub
// 100.000.000, departe de plaja reminderelor botului (BotReminders.kt).
const kBoardCount = 10;

/// Completează lista de tabele până la [kBoardCount] (b1..b10), fără să
/// atingă tabelele existente (nume, ordine, date). Null dacă nu lipsește nimic.
List<Board>? completeBoards(List<Board> boards) {
  final ids = boards.map((b) => b.id).toSet();
  final added = [
    for (var i = 1; i <= kBoardCount; i++)
      if (!ids.contains('b$i')) Board(id: 'b$i', name: tr('Tabel $i', 'Table $i')),
  ];
  if (added.isEmpty || boards.length >= kBoardCount) return null;
  return [...boards, ...added.take(kBoardCount - boards.length)];
}

// Încarcă lista de tabele; la prima rulare după actualizare, migrează datele
// vechi (un singur tabel implicit) în „Tabel 1”. Instalările cu mai puține
// tabele (versiunile cu 3) primesc restul, goale, până la [kBoardCount].
Future<List<Board>> _loadOrMigrateBoards(SharedPreferences prefs) async {
  final boardsJson = prefs.getString(_kBoardsKey);
  if (boardsJson != null) {
    final boards = (jsonDecode(boardsJson) as List<dynamic>)
        .map((e) => Board.fromJson(e as Map<String, dynamic>))
        .toList();
    final completed = completeBoards(boards);
    if (completed == null) return boards;
    await prefs.setString(
        _kBoardsKey, jsonEncode(completed.map((b) => b.toJson()).toList()));
    return completed;
  }

  final b1 = Board(id: 'b1', name: tr('Tabel 1', 'Table 1'));
  final boards = completeBoards([b1])!;

  final legacyItems = prefs.getString(_kLegacyItemsKey);
  if (legacyItems != null) {
    await prefs.setString(_itemsKeyFor(b1.id), legacyItems);
    await prefs.remove(_kLegacyItemsKey);
  }
  final legacyNext = prefs.getInt(_kLegacyNextNumberKey);
  if (legacyNext != null) {
    await prefs.setInt(_nextNumberKeyFor(b1.id), legacyNext);
    await prefs.remove(_kLegacyNextNumberKey);
  }
  final legacyDeleted = prefs.getString(_kLegacyDeletedBufferKey);
  if (legacyDeleted != null) {
    await prefs.setString(_deletedBufferKeyFor(b1.id), legacyDeleted);
    await prefs.remove(_kLegacyDeletedBufferKey);
  }
  final legacyPartner = prefs.getString(_kLegacySyncPartnerKey);
  if (legacyPartner != null) {
    await prefs.setString(_syncPartnerKeyFor(b1.id), legacyPartner);
    await prefs.remove(_kLegacySyncPartnerKey);
  }

  await prefs.setString(
      _kBoardsKey, jsonEncode(boards.map((b) => b.toJson()).toList()));
  await prefs.setString(_kActiveBoardKey, b1.id);
  return boards;
}

// ─── Punct de intrare ─────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.init();
  await AppLang.load();
  runApp(const ManagementApp());
}

class ManagementApp extends StatelessWidget {
  const ManagementApp({super.key});

  @override
  Widget build(BuildContext context) {
    // La schimbarea limbii, aplicația se reconstruiește de la ecranul
    // principal (cheia se schimbă), ca toate textele să apară în limba nouă.
    return ValueListenableBuilder<String>(
      valueListenable: AppLang.code,
      builder: (context, lang, _) => _buildApp(lang),
    );
  }

  Widget _buildApp(String lang) {
    return MaterialApp(
      key: ValueKey(lang),
      locale: Locale(lang),
      supportedLocales: const [Locale('ro'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      title: 'Organizator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF312E81),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E1B4B),
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
        ),
      ),
      home: const ManagementPage(),
    );
  }
}

// ─── Rând liber generat de funcția „Spatiere" (doar vizual, nu se salvează) ──
class _FreeSlot {
  final DateTime start;
  final DateTime end;
  const _FreeSlot(this.start, this.end);
}

class ManagementPage extends StatefulWidget {
  const ManagementPage({super.key});
  @override
  State<ManagementPage> createState() => _ManagementPageState();
}

class _ManagementPageState extends State<ManagementPage>
    with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  bool _searchVisible = false;

  final List<({SortColumn column, bool ascending})> _sortCriteria = [
    (column: SortColumn.number, ascending: true),
  ];
  List<({SortColumn column, bool ascending})>? _sortCriteriaBeforeSpacing;
  bool     _spatiereActiva  = false;
  Duration? _spatiereInterval;
  List<_FreeSlot> _cachedFreeSlots = [];
  BookingSettingsData _bookingSettings = BookingSettingsData.defaults;
  // Serviciile tabelului activ (ecranul „Servicii”, botul SMS).
  List<SalonService> _services = const [];
  String _searchQuery  = '';
  bool   _loading      = true;
  int    _nextNumber   = 1;

  List<Board> _boards        = [];
  String      _activeBoardId = '';

  final List<Item>        _items         = [];
  final List<DeletedItem> _deletedBuffer = [];
  Timer? _colorTimer;
  Timer? _syncQueueTimer;
  String _smsTemplate = _defaultSmsTemplate;
  int _alertLeadMin = kDefaultAlertLeadMin;
  DateTime? _attendanceSince;
  // Neprezentările active (6 luni), pe client — din toate tabelele.
  Map<String, NoShowRecord> _noShows = {};
  int _noShowBlockThreshold = kDefaultNoShowThreshold;

  // Înainte ca _loadData să termine încărcarea inițială, _boards e încă gol
  // (Scaffold-ul cu spinner se construiește imediat) — nu explodăm în acel caz.
  Board get _activeBoard => _boards.firstWhere(
      (b) => b.id == _activeBoardId,
      orElse: () => const Board(id: '', name: 'Organizator'));
  int get _activeBoardIndex => _boards.indexWhere((b) => b.id == _activeBoardId);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadData();
    WidgetsBinding.instance.addPostFrameCallback((_) => _requestPermissions());
    _loadAppVersion();
    _startColorTimer();
    _startSyncQueueTimer();
  }

  // Android afișează o singură cerere de permisiuni odată — o a doua, lansată
  // în paralel, e întoarsă imediat ca refuzată, fără dialog. De aceea
  // cererile se fac strict una după alta.
  Future<void> _requestPermissions() async {
    await SmsService.requestPermission();
    await NotificationService.requestPermissions();
    await _checkSmsPermission();
    await _checkSmsFailure();
    await _checkAutostart();
  }

  // ── Pornire automată (Xiaomi) ────────────────────────────────────────────────
  bool _autostartBlocked = false;

  Future<void> _checkAutostart() async {
    final blocked = await SmsService.autostartBlocked();
    if (mounted && blocked != _autostartBlocked) {
      setState(() => _autostartBlocked = blocked);
    }
  }

  // Versiunea instalată, afișată sub tabel — utilizatorul o compară cu cea de
  // pe site ca să știe dacă are o actualizare disponibilă.
  String _appVersion = '';

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _appVersion = info.version);
    } catch (_) {}
  }

  // ── Permisiunea SMS ──────────────────────────────────────────────────────────
  bool _smsBlocked = false;

  Future<void> _checkSmsPermission() async {
    final ok = await SmsService.hasPermission();
    if (mounted && _smsBlocked == ok) setState(() => _smsBlocked = !ok);
  }

  // Eșecurile de trimitere raportate de sistem (fără credit, fără semnal,
  // SIM implicit nesetat...) — afișate până le închide utilizatorul.
  ({DateTime failedAt, String phone, String reason})? _smsFailure;

  Future<void> _checkSmsFailure() async {
    final f = await SmsService.pendingFailure();
    if (!mounted || f?.failedAt == _smsFailure?.failedAt) return;
    setState(() => _smsFailure = f);
  }

  Future<void> _dismissSmsFailure() async {
    await SmsService.dismissFailure();
    if (mounted) setState(() => _smsFailure = null);
  }

  // Înainte de o acțiune care trimite SMS acum (sincronizare, licență): fără
  // permisiune ar „reuși” în interfață, dar nimic nu ar pleca.
  Future<bool> _ensureSmsPermission() async {
    if (await SmsService.hasPermission()) return true;
    final granted = await SmsService.requestPermission();
    await _checkSmsPermission();
    if (granted) return true;
    if (mounted) await _showSmsBlockedDialog();
    return false;
  }

  // null = SMS blocat (utilizatorul a văzut deja explicația).
  Future<LicenseShareOutcome?> _shareLicenseWithPartners() async {
    // Fără parteneri nu e nimic de trimis — nici motiv să cerem permisiunea.
    if ((await SyncService.pairedBoards()).isEmpty) return (sent: 0, refused: null);
    if (!await _ensureSmsPermission()) return null;
    return SyncService.sendLicenseToAllPartners();
  }

  // Pe telefoanele cu Android 13+, o aplicație instalată din fișier APK nu
  // poate primi permisiunea SMS până când utilizatorul nu permite „setările
  // restricționate” din pagina aplicației — cererea e refuzată automat, fără
  // dialog. Explicăm pașii și ducem utilizatorul direct acolo.
  Future<void> _showSmsBlockedDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(Icons.sms_failed_outlined, color: Colors.red),
          SizedBox(width: 8),
          Expanded(child: Text(tr('SMS-urile sunt blocate', 'SMS is blocked'))),
        ]),
        content: SingleChildScrollView(
          child: Text(
            tr('Fără permisiunea SMS nu pleacă reminderele, confirmările de '
            'rezervare, sincronizarea și licența către telefonul partener.\n\n'
            'Dacă telefonul spune că setarea e restricționată „pentru '
            'siguranța ta”:\n'
            '1. Apasă „Deschide setările”.\n'
            '2. Apasă ⋮ (dreapta-sus) → „Permite setările restricționate” '
            'și confirmă.\n'
            '3. Permisiuni → SMS → Permite.\n'
            '4. Revino în aplicație.',
            'Without the SMS permission, reminders, booking '
            'confirmations, sync and the license for the partner phone cannot be sent.\n\n'
            'If the phone says the setting is restricted “for your '
            'security”:\n'
            '1. Tap “Open settings”.\n'
            '2. Tap ⋮ (top right) → “Allow restricted settings” '
            'and confirm.\n'
            '3. Permissions → SMS → Allow.\n'
            '4. Come back to the app.'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Închide', 'Close')),
          ),
          TextButton(
            onPressed: () async {
              final ok = await SmsService.requestPermission();
              await _checkSmsPermission();
              if (ok && ctx.mounted) Navigator.pop(ctx);
            },
            child: Text(tr('Cere permisiunea', 'Request permission')),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await openAppSettings();
            },
            child: Text(tr('Deschide setările', 'Open settings')),
          ),
        ],
      ),
    );
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    _boards = await _loadOrMigrateBoards(prefs);
    _activeBoardId = prefs.getString(_kActiveBoardKey) ?? _boards.first.id;
    if (!_boards.any((b) => b.id == _activeBoardId)) {
      _activeBoardId = _boards.first.id;
    }

    await SyncService.load(_activeBoardId);
    await LicenseService.load();
    await _loadItems();
    await _processSyncQueue();
    await _checkLicenseFromPartner();
    await _warnLicenseExpiry();
  }

  // ── Comutare / redenumire tabele ─────────────────────────────────────────────
  Future<void> _switchBoard(String boardId) async {
    if (boardId == _activeBoardId) return;
    setState(() {
      _activeBoardId = boardId;
      _loading = true;
      // Sloturile libere calculate erau pentru tabelul anterior — le golim ca
      // să nu afișăm date greșite până se recalculează pentru noul tabel.
      _spatiereActiva = false;
      _cachedFreeSlots = [];
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kActiveBoardKey, boardId);
    await SyncService.load(boardId);
    await _loadItems();
    await _processSyncQueue();
  }

  Future<void> _renameBoard(String boardId, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    setState(() {
      _boards = _boards
          .map((b) => b.id == boardId ? b.copyWith(name: trimmed) : b)
          .toList();
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kBoardsKey, jsonEncode(_boards.map((b) => b.toJson()).toList()));
  }

  Future<void> _showBoardMenu() async {
    final action = await showDialog<({String action, String boardId})>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('Tabele', 'Tables')),
        children: _boards.map((b) {
          final isActive = b.id == _activeBoardId;
          // ListTile + trailing IconButton (nu SimpleDialogOption) — ca să
          // avem două zone de tap independente și fiabile: selectarea
          // tabelului și butonul de redenumire.
          return ListTile(
            onTap: () => Navigator.pop(ctx, (action: 'select', boardId: b.id)),
            leading: Icon(
              isActive
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: isActive ? const Color(0xFF1E1B4B) : Colors.grey,
            ),
            title: Text(
              b.name,
              style: TextStyle(
                  fontWeight: isActive ? FontWeight.bold : FontWeight.normal),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              tooltip: tr('Redenumește', 'Rename'),
              onPressed: () =>
                  Navigator.pop(ctx, (action: 'rename', boardId: b.id)),
            ),
          );
        }).toList(),
      ),
    );

    if (action == null) return;
    if (action.action == 'select') {
      await _switchBoard(action.boardId);
    } else if (action.action == 'rename') {
      await _showRenameBoardDialog(action.boardId);
    }
  }

  Future<void> _showRenameBoardDialog(String boardId) async {
    final board = _boards.firstWhere((b) => b.id == boardId);
    final ctrl = TextEditingController(text: board.name);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Redenumește tabelul', 'Rename table')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
              labelText: tr('Nume tabel', 'Table name'), border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Anulează', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Salvează', 'Save')),
          ),
        ],
      ),
    );
    if (saved == true) {
      await _renameBoard(boardId, ctrl.text);
    }
  }

  void _startColorTimer() {
    _colorTimer?.cancel();
    _colorTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  // Rezervările confirmate prin SMS (vezi ClientBookingReceiver, partea nativă)
  // ajung într-o coadă de sincronizare pe care Flutter o citește normal doar
  // la reluarea aplicației din fundal (didChangeAppLifecycleState). Dacă
  // aplicația stă deschisă în prim-plan tot timpul (cazul obișnuit pentru un
  // ecran de recepție), acel eveniment nu se mai declanșează și rezervarea nu
  // apărea niciodată automat în tabel — de-aici acest timer, care verifică
  // periodic coada indiferent dacă aplicația a fost sau nu în fundal.
  void _startSyncQueueTimer() {
    _syncQueueTimer?.cancel();
    _syncQueueTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _processSyncQueue();
      _checkLicenseFromPartner();
      _checkSmsFailure();
      _applyAutoNoShows();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _startColorTimer();
        _startSyncQueueTimer();
        _processSyncQueue();
        _refreshLicense();
        _checkSmsPermission();
        _checkSmsFailure();
        _checkAutostart();
        if (mounted) setState(() {});
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _colorTimer?.cancel();
        _colorTimer = null;
        _syncQueueTimer?.cancel();
        _syncQueueTimer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _colorTimer?.cancel();
    _syncQueueTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  // ── Persistență ─────────────────────────────────────────────────────────────
  Future<void> _loadItems() async {
    _items.clear();
    _deletedBuffer.clear();
    List<Item>? loaded;
    int nextNumber = 1;
    try {
      final prefs   = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_itemsKeyFor(_activeBoardId));
      nextNumber    = prefs.getInt(_nextNumberKeyFor(_activeBoardId)) ?? 1;
      _smsTemplate  = _effectiveSmsTemplate(prefs.getString(_kSmsTemplateKey));
      _bookingSettings = await _loadBookingSettings(prefs, _activeBoardId);
      _services = loadServices(prefs, _activeBoardId);
      _alertLeadMin = _loadAlertLead(prefs, _activeBoardId);
      final since = prefs.getString(_kAttendanceSinceKey);
      if (since == null) {
        _attendanceSince = DateTime.now();
        await prefs.setString(
            _kAttendanceSinceKey, _attendanceSince!.toIso8601String());
      } else {
        _attendanceSince = DateTime.tryParse(since);
      }
      final deletedStr = prefs.getString(_deletedBufferKeyFor(_activeBoardId));
      if (deletedStr != null) {
        final deletedList = (jsonDecode(deletedStr) as List<dynamic>)
            .map((e) => DeletedItem.fromJson(e as Map<String, dynamic>))
            .where((d) => !d.isExpiredFromBuffer)
            .toList();
        _deletedBuffer.addAll(deletedList);
      }
      if (jsonStr != null) {
        loaded = (jsonDecode(jsonStr) as List<dynamic>)
            .map((e) => Item.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {}

    if (!mounted) return;

    if (loaded != null) {
      setState(() {
        _items.addAll(loaded!);
        _nextNumber = nextNumber;
        _loading    = false;
      });
    } else if (_activeBoardId == 'b1') {
      // Date demonstrative — doar la prima instalare, doar pentru primul tabel.
      setState(() {
        _items.addAll([
          Item(syncId: _generateSyncId(), number: 1, name: tr('Proiect Alpha', 'Project Alpha'),    description: tr('Proiect principal de dezvoltare', 'Main development project'),    createdAt: DateTime(2026, 1, 10,  9,  0), expiresAt: DateTime(2026, 7,  1, 18,  0)),
          Item(syncId: _generateSyncId(), number: 2, name: tr('Raport lunar', 'Monthly report'),     description: tr('Raport de activitate lunară', 'Monthly activity report'),        createdAt: DateTime(2026, 2,  1,  8, 30), expiresAt: DateTime(2026, 6, 30, 23, 59)),
          Item(syncId: _generateSyncId(), number: 3, name: tr('Întâlnire echipă', 'Team meeting'), description: tr('Ședință săptămânală de status', 'Weekly status meeting'),     createdAt: DateTime(2026, 3, 15, 10,  0), expiresAt: DateTime(2026, 12,31, 17,  0)),
          Item(syncId: _generateSyncId(), number: 4, name: tr('Audit intern', 'Internal audit'),     description: tr('Verificare proceduri interne', 'Internal procedures review'),       createdAt: DateTime(2026, 4,  5, 11,  0), expiresAt: DateTime(2026, 8, 15, 16,  0)),
          Item(syncId: _generateSyncId(), number: 5, name: tr('Buget anual', 'Annual budget'),      description: tr('Planificare buget pentru 2027', 'Budget planning for 2027'),      createdAt: DateTime(2026, 5, 20, 14,  0), expiresAt: DateTime(2026,11, 30, 23, 59)),
        ]);
        _nextNumber = 6;
        _loading    = false;
      });
      await _saveItems();
    } else {
      // Tabel nou, fără date salvate — pornește complet gol.
      setState(() {
        _nextNumber = 1;
        _loading    = false;
      });
    }
    await _refreshNoShows();
    unawaited(_applyAutoNoShows());
  }

  Future<void> _saveItems() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_itemsKeyFor(_activeBoardId),
        jsonEncode(_items.map((e) => e.toJson()).toList()));
    await prefs.setInt(_nextNumberKeyFor(_activeBoardId), _nextNumber);
    unawaited(_recomputeFreeSlots());
    unawaited(_refreshNoShows());
  }

  Future<void> _saveBuffer() async {
    _deletedBuffer.removeWhere((d) => d.isExpiredFromBuffer);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _deletedBufferKeyFor(_activeBoardId),
      jsonEncode(_deletedBuffer.map((d) => d.toJson()).toList()),
    );
    unawaited(_refreshNoShows());
  }

  // ── Neprezentări ─────────────────────────────────────────────────────────────
  // Recalculează bilele roșii din toate tabelele (și din programările șterse)
  // și scrie rezumatul citit de botul SMS (blocarea, la pragul ales).
  Future<void> _refreshNoShows() async {
    final prefs = await SharedPreferences.getInstance();
    NoShowSource src(Item i) => (
          syncId: i.syncId,
          phone: i.clientPhone,
          name: i.name,
          at: i.expiresAt,
          noShow: i.attendance == kNoShow,
        );
    final sources = <NoShowSource>[];
    // Programările încă neconfirmate — botul le socotește neprezentări după
    // 24 de ore, ca blocarea să meargă și cu aplicația închisă.
    final pending = <String, List<String>>{};
    void addPending(Iterable<Item> items) {
      for (final i in items) {
        if (i.attendance != null || i.expiresAt == null) continue;
        if (_attendanceSince == null || !i.expiresAt!.isAfter(_attendanceSince!)) continue;
        final key = clientKey(i.clientPhone);
        if (key.isEmpty) continue;
        pending.putIfAbsent(key, () => []).add(i.expiresAt!.toIso8601String());
      }
    }
    for (final b in _boards) {
      try {
        if (b.id == _activeBoardId) {
          sources
            ..addAll(_items.map(src))
            ..addAll(_deletedBuffer.map((d) => src(d.item)));
          addPending(_items);
          continue;
        }
        final itemsStr = prefs.getString(_itemsKeyFor(b.id));
        if (itemsStr != null) {
          final items = (jsonDecode(itemsStr) as List<dynamic>)
              .map((e) => Item.fromJson(e as Map<String, dynamic>))
              .toList();
          sources.addAll(items.map(src));
          addPending(items);
        }
        final deletedStr = prefs.getString(_deletedBufferKeyFor(b.id));
        if (deletedStr != null) {
          sources.addAll((jsonDecode(deletedStr) as List<dynamic>)
              .map((e) => src(DeletedItem.fromJson(e as Map<String, dynamic>).item)));
        }
      } catch (_) {
        // Date corupte într-un tabel — nu blocăm restul.
      }
    }
    _noShowBlockThreshold =
        prefs.getInt(kNoShowThresholdKey) ?? kDefaultNoShowThreshold;
    final result = computeNoShows(
        sources, decodeResets(prefs.getString(kNoShowResetsKey)));
    await prefs.setString(kNoShowSummaryKey, jsonEncode({
      for (final r in result.values)
        r.key: [for (final d in r.dates) d.toIso8601String()],
    }));
    await prefs.setString(kNoShowPendingKey, jsonEncode(pending));
    if (mounted) setState(() => _noShows = result);
  }

  int _noShowCountFor(String? phone) => _noShows[clientKey(phone)]?.count ?? 0;

  // Iertarea: neprezentările de până acum nu mai contează. Trimisă și
  // partenerului de pe fiecare tabel, ca bilele să fie aceleași pe ambele.
  Future<void> _forgiveClient(NoShowRecord record) async {
    await _applyForgive(record.key, DateTime.now());
    final msg = forgiveMessage(record.key, DateTime.now());
    for (final b in _boards) {
      await SyncService.sendToBoardPartner(b.id, msg);
    }
  }

  Future<void> _applyForgive(String key, DateTime at) async {
    final prefs = await SharedPreferences.getInstance();
    final resets = decodeResets(prefs.getString(kNoShowResetsKey));
    if (resets[key] != null && !at.isAfter(resets[key]!)) return;
    resets[key] = at;
    await prefs.setString(kNoShowResetsKey, jsonEncode({
      for (final e in resets.entries) e.key: e.value.toIso8601String(),
    }));
    await _refreshNoShows();
  }

  Future<void> _showNoShowClients() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) {
          final records = _noShows.values.toList()
            ..sort((a, b) => b.count != a.count
                ? b.count.compareTo(a.count)
                : b.last.compareTo(a.last));
          return AlertDialog(
            title: Text(tr('Clienți cu neprezentări', 'Clients with no-shows')),
            content: SizedBox(
              width: 440,
              child: records.isEmpty
                  ? Text(tr('Niciun client cu neprezentări în ultimele 6 luni.', 'No client with no-shows in the last 6 months.'))
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        Text(
                          tr('Neprezentările din ultimele 6 luni. O bilă dispare '
                          'singură după 6 luni.'
                          '${_noShowBlockThreshold > 0 ? ' La $_noShowBlockThreshold bile, clientul nu mai poate rezerva prin SMS.' : ''}',
                          'No-shows in the last 6 months. A dot disappears '
                          'by itself after 6 months.'
                          '${_noShowBlockThreshold > 0 ? ' At $_noShowBlockThreshold dots, the client can no longer book by SMS.' : ''}'),
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600),
                        ),
                        const SizedBox(height: 8),
                        for (final r in records)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    r.name == r.phone || r.phone.isEmpty
                                        ? r.name
                                        : '${r.name} · ${r.phone}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                _noShowBalls(r.count),
                              ],
                            ),
                            subtitle: Text(
                              tr('Ultima: ${_formatDateTime(r.last)}'
                              '${isBlockedBy(r.count, _noShowBlockThreshold) ? ' · blocat la rezervări prin SMS' : ''}',
                              'Last: ${_formatDateTime(r.last)}'
                              '${isBlockedBy(r.count, _noShowBlockThreshold) ? ' · blocked from SMS bookings' : ''}'),
                              style: isBlockedBy(r.count, _noShowBlockThreshold)
                                  ? TextStyle(color: Colors.red.shade700)
                                  : null,
                            ),
                            trailing: TextButton(
                              onPressed: () async {
                                final ok = await showDialog<bool>(
                                  context: ctx,
                                  builder: (c) => AlertDialog(
                                    title: Text(tr('Iartă clientul?', 'Forgive the client?')),
                                    content: Text(
                                        tr('Cele ${r.count} neprezentări ale lui '
                                        '${r.name} nu vor mai conta.',
                                        'The ${r.count} no-shows of '
                                        '${r.name} will no longer count.')),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(c, false),
                                        child: Text(tr('Anulează', 'Cancel')),
                                      ),
                                      FilledButton(
                                        onPressed: () => Navigator.pop(c, true),
                                        child: Text(tr('Iartă', 'Forgive')),
                                      ),
                                    ],
                                  ),
                                );
                                if (ok != true) return;
                                await _forgiveClient(r);
                                setDs(() {});
                              },
                              child: Text(tr('Iartă', 'Forgive')),
                            ),
                          ),
                      ],
                    ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('Închide', 'Close')),
              ),
            ],
          );
        },
      ),
    );
  }

  // Bile roșii pentru neprezentări (maxim 5 desenate, apoi „+N”).
  Widget _noShowBalls(int count) {
    if (count <= 0) return const SizedBox.shrink();
    return Tooltip(
      message: '$count ${count == 1 ? "neprezentare" : "neprezentări"}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count && i < 5; i++)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Icon(Icons.circle, size: 10, color: Colors.red.shade600),
            ),
          if (count > 5)
            Text('+${count - 5}',
                style: TextStyle(fontSize: 11, color: Colors.red.shade700)),
        ],
      ),
    );
  }

  // ── Procesare coadă sincronizare ─────────────────────────────────────────────
  // Fiecare tabel are propriul partener SMS, deci mesajele din coadă pot
  // aparține unui tabel diferit de cel activ (etichetate de SmsSyncReceiver
  // cu tabelul al cărui partener configurat corespunde expeditorului).
  // Rulează din mai multe locuri (timer, revenire în aplicație, schimbare de
  // tabel) — o a doua procesare simultană ar aplica aceleași mesaje de două
  // ori peste aceeași listă în memorie.
  bool _syncQueueBusy = false;

  Future<void> _processSyncQueue() async {
    if (_loading || _syncQueueBusy) return;
    _syncQueueBusy = true;
    // Marcarea automată a neprezentărilor scrie aceleași date — o așteptăm.
    while (_autoNoShowBusy) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    try {
      final entries = await SyncService.getPendingMessages();
      if (entries.isEmpty) return;

      final byBoard = <String, List<String>>{};
      for (final e in entries) {
        if (e.msg.isEmpty) continue;
        // Lista de servicii a unui tabel — înlocuiește lista locală.
        final services = parseServicesSyncMessage(e.msg);
        if (services != null) {
          await _applyServicesSync(
              e.boardId.isEmpty ? 'b1' : e.boardId, services);
          continue;
        }
        // Iertarea unui client — comună tuturor tabelelor.
        final forgive = parseForgiveMessage(e.msg);
        if (forgive != null) {
          await _applyForgive(forgive.$1, forgive.$2);
          continue;
        }
        final boardId = e.boardId.isEmpty ? 'b1' : e.boardId;
        byBoard.putIfAbsent(boardId, () => []).add(e.msg);
      }

      for (final entry in byBoard.entries) {
        final boardIndex = _boards.indexWhere((b) => b.id == entry.key);
        if (boardIndex == -1) continue; // tabel necunoscut — ignorat
        await _mergeSyncMessages(entry.key, boardIndex, entry.value);
      }

      // Rezervările/anulările făcute de bot (și anularea automată la 24h)
      // ajung doar în coada acestui telefon — le trimitem și partenerului,
      // altfel tabelul de pe celălalt telefon nu le vede niciodată.
      for (final e in entries) {
        if (e.fromPartner || e.msg.isEmpty) continue;
        final boardId = e.boardId.isEmpty ? 'b1' : e.boardId;
        if (!_boards.any((b) => b.id == boardId)) continue;
        await SyncService.sendToBoardPartner(boardId, e.msg);
      }

      await SyncService.ackMessages([for (final e in entries) e.id]);
    } finally {
      _syncQueueBusy = false;
    }
  }

  // Serviciile primite de la partener (SmsSyncReceiver le-a scris deja nativ,
  // pentru bot — aici se actualizează și cache-ul Dart și ecranul).
  Future<void> _applyServicesSync(String boardId, ServicesSync sync) async {
    if (!_boards.any((b) => b.id == boardId)) return;
    final prefs = await SharedPreferences.getInstance();
    await saveServices(prefs, boardId, sync.services);
    final settings = await _loadBookingSettings(prefs, boardId);
    final updated = settings.copyWith(durationMin: sync.defaultMin);
    await _saveBookingSettings(boardId, updated);
    if (boardId == _activeBoardId && mounted) {
      setState(() {
        _services = sync.services;
        _bookingSettings = updated;
      });
      unawaited(_recomputeFreeSlots());
    }
  }

  // Aplică mesajele de sincronizare peste tabelul indicat. Dacă e tabelul
  // activ, operează direct pe starea din memorie (_items); altfel încarcă,
  // modifică și salvează datele acelui tabel fără să afecteze ecranul curent.
  Future<void> _mergeSyncMessages(
    String boardId,
    int boardIndex,
    List<String> messages,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final isActiveBoard = boardId == _activeBoardId;

    List<Item> items;
    List<DeletedItem> deletedBuffer;
    int nextNumber;

    if (isActiveBoard) {
      items = _items;
      deletedBuffer = _deletedBuffer;
      nextNumber = _nextNumber;
    } else {
      items = [];
      deletedBuffer = [];
      final jsonStr = prefs.getString(_itemsKeyFor(boardId));
      if (jsonStr != null) {
        items = (jsonDecode(jsonStr) as List<dynamic>)
            .map((e) => Item.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      nextNumber = prefs.getInt(_nextNumberKeyFor(boardId)) ?? (items.length + 1);
      final deletedStr = prefs.getString(_deletedBufferKeyFor(boardId));
      if (deletedStr != null) {
        deletedBuffer = (jsonDecode(deletedStr) as List<dynamic>)
            .map((e) => DeletedItem.fromJson(e as Map<String, dynamic>))
            .where((d) => !d.isExpiredFromBuffer)
            .toList();
      }
    }

    final alertLeadMin = _loadAlertLead(prefs, boardId);
    bool changed = false;
    final removed = <Item>[];
    final becameNoShow = <Item>[];
    void trackNoShow(Item? old, Item incoming) {
      if (incoming.attendance == kNoShow && old?.attendance != kNoShow) {
        becameNoShow.add(incoming);
      }
    }
    for (final msg in messages) {
      try {
        if (msg.startsWith('ORG:A:') || msg.startsWith('ORG:I:')) {
          final prefix = msg.startsWith('ORG:A:') ? 'ORG:A:' : 'ORG:I:';
          final j = jsonDecode(msg.substring(prefix.length)) as Map<String, dynamic>;
          var incoming = Item.fromSyncJson(j);
          // Rezervare prin bot fără alertă (scrisă de o versiune care nu o
          // calcula nativ) — primește intervalul implicit al tabelului.
          if (incoming.viaBot && incoming.warningAt == null) {
            final w = autoWarningFor(incoming.expiresAt, alertLeadMin);
            if (w != null) incoming = incoming.copyWith(warningAt: w);
          }
          final idx = items.indexWhere((e) => e.syncId == incoming.syncId);
          trackNoShow(idx == -1 ? null : items[idx], incoming);
          if (idx == -1) {
            items.add(incoming.copyWith(number: nextNumber++));
          } else {
            items[idx] = incoming.copyWith(number: items[idx].number);
          }
          changed = true;
        } else if (msg.startsWith('ORG:U:')) {
          final j = jsonDecode(msg.substring(6)) as Map<String, dynamic>;
          final incoming = Item.fromSyncJson(j);
          final idx = items.indexWhere((e) => e.syncId == incoming.syncId);
          trackNoShow(idx == -1 ? null : items[idx], incoming);
          if (idx != -1) {
            items[idx] = incoming.copyWith(number: items[idx].number);
          } else {
            // Item necunoscut primit ca update → adăugat
            items.add(incoming.copyWith(number: nextNumber++));
          }
          changed = true;
        } else if (msg.startsWith('ORG:D:')) {
          final syncId = msg.substring(6).trim();
          final idx = items.indexWhere((e) => e.syncId == syncId);
          if (idx != -1) {
            deletedBuffer.add(
                DeletedItem(item: items[idx], deletedAt: DateTime.now()));
            removed.add(items.removeAt(idx));
            changed = true;
          }
        }
        // ORG:Z: (end of initial sync) — ignorat, nu necesită acțiune
      } catch (_) {
        // SMS corupt sau format necunoscut — ignorat
      }
    }

    if (!changed) return;

    // Înregistrările șterse își pierd toate alarmele. Renumerotarea de mai jos
    // le acoperă doar când numărul lor e preluat de altă înregistrare — cea
    // cu numărul cel mai mare (de ex. anularea prin SMS a ultimei rezervări)
    // rămânea cu reminderele SMS/notificările active.
    for (final item in removed) {
      await NotificationService.cancelFor(item.number, boardIndex: boardIndex);
      await SmsService.cancelFor(item.number, boardIndex: boardIndex);
    }

    // Anulăm alarmele vechi (SMS + notificări) pentru orice item care își
    // schimbă numărul la renumerotare — altfel rămân alarme "orfane"
    // programate sub numărul vechi, iar noul număr nu are nicio alarmă.
    for (var i = 0; i < items.length; i++) {
      if (items[i].number != i + 1) {
        await NotificationService.cancelFor(items[i].number,
            boardIndex: boardIndex);
        await SmsService.cancelFor(items[i].number, boardIndex: boardIndex);
      }
    }
    // Renumerotare secvențială după orice modificare prin sync
    for (var i = 0; i < items.length; i++) {
      if (items[i].number != i + 1) {
        items[i] = items[i].copyWith(number: i + 1);
      }
    }
    nextNumber = items.length + 1;
    deletedBuffer.removeWhere((d) => d.isExpiredFromBuffer);

    await prefs.setString(
        _itemsKeyFor(boardId), jsonEncode(items.map((e) => e.toJson()).toList()));
    await prefs.setInt(_nextNumberKeyFor(boardId), nextNumber);
    await prefs.setString(_deletedBufferKeyFor(boardId),
        jsonEncode(deletedBuffer.map((d) => d.toJson()).toList()));

    // Reprogramează notificările locale pentru toate înregistrările tabelului
    for (final item in items) {
      await NotificationService.scheduleFor(item, boardIndex: boardIndex);
      await SmsService.scheduleFor(item,
          template: _smsTemplate, boardIndex: boardIndex);
    }

    if (isActiveBoard) {
      _nextNumber = nextNumber;
      if (mounted) setState(() {});
      unawaited(_recomputeFreeSlots());
    }
    await _refreshNoShows();
    if (becameNoShow.isNotEmpty) await _notifyNoShows(becameNoShow);
  }

  Future<void> _openBackupScreen() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => BackupScreen(
        onBeforeRestore: _pauseSyncForRestore,
        onRestored: _reloadAfterRestore,
      ),
    ));
    if (mounted) setState(() {});
  }

  // Coada de sincronizare scrie în SharedPreferences din fundal — oprită pe
  // durata restaurării, ca să nu suprascrie datele abia restaurate cu cele
  // vechi din cache-ul Dart.
  Future<void> _pauseSyncForRestore() async {
    _syncQueueTimer?.cancel();
    _syncQueueTimer = null;
  }

  // Restaurarea înlocuiește datele nativ — cache-ul SharedPreferences din Dart
  // și toată starea din memorie se reîncarcă de la zero (și la eșec: o
  // restaurare întreruptă poate să fi scris parțial).
  Future<void> _reloadAfterRestore(bool success) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (mounted) {
      setState(() {
        _loading = true;
        _spatiereActiva = false;
        _cachedFreeSlots = [];
      });
    }
    await _loadData();
    _startSyncQueueTimer();
  }

  Future<void> _openLicenseScreen() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => LicenseScreen(
        onShareWithPartners: _shareLicenseWithPartners,
      ),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _refreshLicense() async {
    await LicenseService.checkNewLicense();
    if (mounted) setState(() {});
  }

  // Licența poate sosi prin SMS de la telefonul partener oricând — inclusiv
  // cu aplicația închisă; o anunțăm la următoarea verificare.
  Future<void> _checkLicenseFromPartner() async {
    if (!await LicenseService.consumePartnerNotice()) return;
    await LicenseService.checkNewLicense();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Licența a fost primită de la telefonul partener.', 'The license was received from the partner phone.')),
        backgroundColor: Colors.green.shade700,
      ),
    );
  }

  Future<void> _warnLicenseExpiry() async {
    if (!await LicenseService.shouldWarnExpiryToday() || !mounted) return;
    final days = LicenseService.newLicenseDaysUntilExpiry ?? 0;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(days <= 1
            ? tr('Licența expiră mâine! Reînnoiește-o pentru a evita întreruperile.', 'The license expires tomorrow! Renew it to avoid interruptions.')
            : tr('Licența expiră în $days zile. Reînnoiește-o pentru a evita întreruperile.', 'The license expires in $days days. Renew it to avoid interruptions.')),
        backgroundColor: Colors.orange.shade800,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: tr('Detalii', 'Details'),
          textColor: Colors.white,
          onPressed: _openLicenseScreen,
        ),
      ),
    );
  }

  void _showLicenseRequiredDialog() async {
    final businessId = await LicenseService.getBusinessId();
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(Icons.lock_outline, color: Colors.orange),
          SizedBox(width: 8),
          Text(tr('Licență necesară', 'License required')),
        ]),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('Perioada de trial gratuită de 1 lună a expirat.', 'The free 1-month trial has expired.'),
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                tr('Botul de rezervări prin SMS și reminderele SMS sunt oprite '
                'până la activarea licenței. Datele, sincronizarea și '
                'backup-ul funcționează în continuare.',
                'The SMS booking bot and SMS reminders are off '
                'until the license is activated. Your data, sync and '
                'backup keep working.'),
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              Text(
                tr('Cumpără o licență pe voltacademy.app/organizator.html folosind codul de instalare de mai jos, apoi importă fișierul descărcat:', 'Buy a license at voltacademy.app/organizator.html using the installation code below, then import the downloaded file:'),
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFEEF2FF),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFC7D2FE)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        businessId,
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Color(0xFF3730A3)),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      tooltip: tr('Copiază codul', 'Copy code'),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: businessId));
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text(tr('Cod copiat.', 'Code copied.'))),
                          );
                        }
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: const Icon(Icons.folder_open),
                label: Text(tr('Selectează fișierul de licență', 'Select the license file')),
                onPressed: () async {
                  final r = await LicenseService.pickLicenseFile();
                  if (!ctx.mounted) return;
                  // Selectorul închis fără alegere — nimic de raportat.
                  if (!r.success && r.message.isEmpty) return;
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(
                      content: Text(r.success
                          ? tr('Licență activată cu succes!', 'License activated successfully!')
                          : r.message),
                      backgroundColor: r.success ? Colors.green.shade700 : Colors.red.shade700,
                    ),
                  );
                  if (r.success) {
                    Navigator.pop(ctx);
                    if (mounted) setState(() {});
                    unawaited(_shareLicenseWithPartners());
                  }
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Închide', 'Close')),
          ),
        ],
      ),
    );
  }

  // ── Filtrare și sortare ──────────────────────────────────────────────────────
  List<Item> get _filteredAndSorted {
    var result = _items.where((item) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return item.number.toString().contains(q) ||
          item.name.toLowerCase().contains(q) ||
          item.description.toLowerCase().contains(q) ||
          (item.service?.toLowerCase().contains(q) ?? false) ||
          _formatDateTime(item.createdAt).contains(q) ||
          (item.expiresAt != null && _formatDateTime(item.expiresAt!).contains(q));
    }).toList();

    result.sort((a, b) {
      for (final c in _sortCriteria) {
        final cmp = _compareItems(a, b, c.column);
        if (cmp != 0) return c.ascending ? cmp : -cmp;
      }
      return 0;
    });
    return result;
  }

  bool _isExpired(Item item) =>
      item.expiresAt != null && item.expiresAt!.isBefore(DateTime.now());

  bool _isWarning(Item item) =>
      !_isExpired(item) &&
      item.warningAt != null &&
      item.warningAt!.isBefore(DateTime.now());

  bool _needsAttendance(Item item) => needsAttendance(item, _attendanceSince);

  // Programare încheiată după pornirea funcției — are buton de prezență în
  // locul celui de alertă (alerta nu mai are rost după final).
  bool _tracksAttendance(Item item) =>
      _isExpired(item) &&
      _attendanceSince != null &&
      (item.attendance != null || item.expiresAt!.isAfter(_attendanceSince!));

  Color _rowBg(Item item, bool isEven) {
    if (item.attendance == kCame) return const Color(0xFFE7F6EC);
    if (_needsAttendance(item)) return const Color(0xFFFFEDD5);
    if (_isExpired(item)) return const Color(0xFFFFDADA);
    if (_isWarning(item)) return const Color(0xFFFEF3C7);
    return isEven ? Colors.white : const Color(0xFFF8FAFC);
  }

  // Lățimea coloanei de acțiuni (Editează/Alertă/Șterge). Trebuie folosită
  // peste tot unde tabelul își calculează lățimea totală (SizedBox exterior,
  // antet, rânduri libere „Spatiere”), altfel conținutul depășește
  // containerul și butoanele din dreapta ies din zona vizibilă.
  double get _actionColWidth => 148;

  String _formatDateTime(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}.'
      '${dt.month.toString().padLeft(2, '0')}.'
      '${dt.year} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';

  // Coloana „Descriere” arată și serviciul, ca salonul să-l vadă din tabel.
  String _descriptionWithService(Item item) {
    final svc = item.service;
    if (svc == null) return item.description;
    return item.description.isEmpty ? svc : '$svc · ${item.description}';
  }

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';

  int _compareItems(Item a, Item b, SortColumn col) {
    switch (col) {
      case SortColumn.number:      return a.number.compareTo(b.number);
      case SortColumn.name:        return a.name.compareTo(b.name);
      case SortColumn.description: return a.description.compareTo(b.description);
      case SortColumn.createdAt:   return a.createdAt.compareTo(b.createdAt);
      case SortColumn.expiresAt:
        if (a.expiresAt == null && b.expiresAt == null) return 0;
        if (a.expiresAt == null) return 1;
        if (b.expiresAt == null) return -1;
        return a.expiresAt!.compareTo(b.expiresAt!);
    }
  }

  void _onSort(SortColumn column) {
    setState(() {
      final idx = _sortCriteria.indexWhere((c) => c.column == column);
      if (idx == -1) {
        _sortCriteria.add((column: column, ascending: true));
      } else if (_sortCriteria[idx].ascending) {
        _sortCriteria[idx] = (column: column, ascending: false);
      } else {
        _sortCriteria.removeAt(idx);
      }
    });
  }

  // ── Servicii (lista tabelului + rânduri libere între programări) ─────────────
  Future<void> _openServices() async {
    final board = _boards.firstWhere((b) => b.id == _activeBoardId,
        orElse: () => _boards.first);
    final result = await Navigator.of(context).push<ServicesResult>(
      MaterialPageRoute(
        builder: (_) => ServicesScreen(
          boardName: board.name,
          defaultMin: _bookingSettings.durationMin,
          services: _services,
          freeSlotsActive: _spatiereActiva,
        ),
      ),
    );
    if (result == null || !mounted) return;

    if (result.changed) {
      final prefs = await SharedPreferences.getInstance();
      await saveServices(prefs, _activeBoardId, result.services);
      final updated =
          _bookingSettings.copyWith(durationMin: result.defaultMin);
      await _saveBookingSettings(_activeBoardId, updated);
      setState(() {
        _services = result.services;
        _bookingSettings = updated;
      });
      // Un singur SMS la ieșirea din ecran, nu câte unul la fiecare editare.
      await SyncService.sendServices(result.defaultMin, result.services);
    }

    final freeDuration = result.freeSlotsDuration;
    if (freeDuration == 0) {
      _hideFreeSlots();
    } else if (freeDuration != null) {
      setState(() {
        _spatiereInterval = Duration(minutes: freeDuration);
        if (!_spatiereActiva) {
          _sortCriteriaBeforeSpacing = List.of(_sortCriteria);
          _sortCriteria
            ..clear()
            ..add((column: SortColumn.expiresAt, ascending: true));
        }
        _spatiereActiva = true;
      });
    }
    await _recomputeFreeSlots();
  }

  void _hideFreeSlots() {
    if (!_spatiereActiva) return;
    setState(() {
      _spatiereActiva = false;
      _cachedFreeSlots = [];
      if (_sortCriteriaBeforeSpacing != null) {
        _sortCriteria
          ..clear()
          ..addAll(_sortCriteriaBeforeSpacing!);
        _sortCriteriaBeforeSpacing = null;
      }
    });
  }

  // Intercalează sloturile libere deja calculate (_cachedFreeSlots, sortate
  // crescător după oră de start) cu programările (sortate după expiresAt), în
  // ordine cronologică — inclusiv sloturile de dinaintea primei programări sau
  // de după ultima (limitate de programul de lucru configurat).
  List<Object> _withFreeSlots(List<Item> sortedByExpiry) {
    if (!_spatiereActiva || _cachedFreeSlots.isEmpty) return sortedByExpiry;

    final result = <Object>[];
    var slotIdx = 0;
    for (final item in sortedByExpiry) {
      if (item.expiresAt != null) {
        while (slotIdx < _cachedFreeSlots.length &&
            _cachedFreeSlots[slotIdx].start.isBefore(item.expiresAt!)) {
          result.add(_cachedFreeSlots[slotIdx]);
          slotIdx++;
        }
      }
      result.add(item);
    }
    while (slotIdx < _cachedFreeSlots.length) {
      result.add(_cachedFreeSlots[slotIdx]);
      slotIdx++;
    }
    return result;
  }

  // Recalculează sloturile libere pentru tabelul activ. Pe Android delegă
  // integral către codul nativ (aceeași sursă de adevăr ca botul de rezervări
  // prin SMS); pe celelalte platforme (unde nu există bot SMS, deci nimic cu
  // care să diverge) folosește implementarea locală de mai jos.
  Future<void> _recomputeFreeSlots() async {
    if (!_spatiereActiva) {
      if (_cachedFreeSlots.isNotEmpty) setState(() => _cachedFreeSlots = []);
      return;
    }
    final slots = _isAndroid
        ? await SmsService._computeFreeSlots(_activeBoardId,
            durationMin: (_spatiereInterval?.inMinutes ??
                _bookingSettings.durationMin))
        : _computeFreeSlotsLocal();
    debugPrint('OrgDiag: _recomputeFreeSlots activeBoardId=$_activeBoardId '
        'interval=$_spatiereInterval durationMin=${_bookingSettings.durationMin} '
        'resultCount=${slots.length}');
    if (!mounted) return;
    setState(() => _cachedFreeSlots = slots);
  }

  // Implementare de rezervă (non-Android) — aceeași logică ca FreeSlotCalculator
  // din Kotlin: sloturile se aliniază la începutul programului de lucru sau la
  // finalul programării anterioare, respectând zilele închise.
  List<_FreeSlot> _computeFreeSlotsLocal() {
    final interval = _spatiereInterval;
    if (interval == null || interval <= Duration.zero) return [];
    final durationMin = interval.inMinutes;

    final busy = _items
        .where((i) => i.expiresAt != null)
        .map((i) => (
              start: i.expiresAt!.subtract(Duration(
                  minutes: i.durationOr(_bookingSettings.durationMin))),
              end: i.expiresAt!,
            ))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    final result = <_FreeSlot>[];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    const horizonDays = 14;
    const maxResults = 200;

    for (var d = 0; d <= horizonDays && result.length < maxResults; d++) {
      final date = today.add(Duration(days: d));
      if (_bookingSettings.closedDays.contains(date.weekday)) continue;

      final dayStart = date.add(Duration(minutes: _bookingSettings.workStartMin));
      final dayEnd   = date.add(Duration(minutes: _bookingSettings.workEndMin));
      var cursor = dayStart.isBefore(now)
          ? _roundUpToSlot(now, dayStart, durationMin)
          : dayStart;

      final dayBusy =
          busy.where((b) => b.end.isAfter(dayStart) && b.start.isBefore(dayEnd));
      for (final b in dayBusy) {
        if (result.length >= maxResults) break;
        final busyStart = b.start.isBefore(cursor) ? cursor : b.start;
        while (result.length < maxResults &&
            !cursor.add(interval).isAfter(busyStart)) {
          result.add(_FreeSlot(cursor, cursor.add(interval)));
          cursor = cursor.add(interval);
        }
        if (b.end.isAfter(cursor)) cursor = b.end;
      }
      while (result.length < maxResults && !cursor.add(interval).isAfter(dayEnd)) {
        result.add(_FreeSlot(cursor, cursor.add(interval)));
        cursor = cursor.add(interval);
      }
    }
    return result;
  }

  DateTime _roundUpToSlot(DateTime from, DateTime dayStart, int durationMin) {
    if (!from.isAfter(dayStart)) return dayStart;
    final minutesFromStart = from.difference(dayStart).inMinutes;
    final slots = (minutesFromStart + durationMin - 1) ~/ durationMin;
    return dayStart.add(Duration(minutes: slots * durationMin));
  }

  Widget _buildSortIcon(SortColumn column) {
    final idx = _sortCriteria.indexWhere((c) => c.column == column);
    if (idx == -1) {
      return const Icon(Icons.unfold_more, size: 16, color: Colors.white54);
    }
    final isAsc   = _sortCriteria[idx].ascending;
    final showNum = _sortCriteria.length > 1;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isAsc ? Icons.arrow_upward : Icons.arrow_downward,
          size: 14, color: Colors.white,
        ),
        if (showNum)
          Padding(
            padding: const EdgeInsets.only(left: 1),
            child: Text(
              '${idx + 1}',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHeaderCell(String label, SortColumn column, {double? width}) {
    return InkWell(
      onTap: () => _onSort(column),
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13)),
            ),
            const SizedBox(width: 4),
            _buildSortIcon(column),
          ],
        ),
      ),
    );
  }

  // ── Dialog adăugare / editare ────────────────────────────────────────────────
  // La mutarea unei programări, alerta se mută odată cu ea, cu același
  // interval înainte de expirare — altfel ar pleca la ora veche.
  DateTime? _shiftedWarning(Item item, DateTime? newExpiry) {
    final oldWarning = item.warningAt;
    final oldExpiry  = item.expiresAt;
    if (oldWarning == null || oldExpiry == null || newExpiry == null ||
        newExpiry == oldExpiry) {
      return oldWarning;
    }
    return autoWarningFor(
        newExpiry, oldExpiry.difference(oldWarning).inMinutes);
  }

  Future<void> _showItemDialog({Item? existing}) async {
    final isEdit  = existing != null;
    // Verificare limită versiune gratuită (doar la adăugare, nu la editare)
    if (!isEdit && !LicenseService.canAdd) {
      _showLicenseRequiredDialog();
      return;
    }
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final descCtrl = TextEditingController(text: existing?.description ?? '');
    DateTime? selectedExpiry = existing?.expiresAt;
    // Serviciul programării — dintre cele ale tabelului; unul șters între
    // timp din listă rămâne selectat la editare.
    SalonService? selectedService = existing?.service == null
        ? null
        : SalonService(
            name: existing!.service!,
            durationMin: existing.durationOr(_bookingSettings.durationMin));
    final serviceOptions = [
      ..._services,
      if (selectedService != null && !_services.contains(selectedService))
        selectedService,
    ];

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          title: Text(isEdit ? tr('Editează înregistrarea', 'Edit entry') : tr('Adaugă înregistrare', 'Add entry')),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                        labelText: tr('Nume *', 'Name *'), border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: descCtrl,
                    decoration: InputDecoration(
                        labelText: tr('Descriere', 'Description'), border: OutlineInputBorder()),
                    maxLines: 3,
                  ),
                  if (serviceOptions.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<SalonService?>(
                      initialValue: selectedService,
                      isExpanded: true,
                      decoration: InputDecoration(
                          labelText: tr('Serviciu', 'Service'), border: OutlineInputBorder()),
                      items: [
                        DropdownMenuItem<SalonService?>(
                          value: null,
                          child: Text(tr('Fără serviciu (durată implicită '
                              '${formatServiceDuration(_bookingSettings.durationMin)})',
                          'No service (default duration '
                          '${formatServiceDuration(_bookingSettings.durationMin)})')),
                        ),
                        for (final svc in serviceOptions)
                          DropdownMenuItem<SalonService?>(
                            value: svc,
                            child: Text('${svc.name} '
                                '(${formatServiceDuration(svc.durationMin)})'),
                          ),
                      ],
                      onChanged: (v) => setDs(() => selectedService = v),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _buildDatePickerRow(
                    label: selectedExpiry == null
                        ? tr('Data expirare: nesetată', 'Expiry date: not set')
                        : tr('Expirare: ${_formatDateTime(selectedExpiry!)}', 'Expiry: ${_formatDateTime(selectedExpiry!)}'),
                    hasValue: selectedExpiry != null,
                    onClear: () => setDs(() => selectedExpiry = null),
                    onPick: () async {
                      final date = await showDatePicker(
                        context: ctx,
                        initialDate: selectedExpiry ?? DateTime.now(),
                        firstDate: DateTime(2020), lastDate: DateTime(2100),
                      );
                      if (date == null) return;
                      if (!ctx.mounted) return;
                      final time = await showTimePicker(
                        context: ctx,
                        initialTime: selectedExpiry != null
                            ? TimeOfDay(
                                hour: selectedExpiry!.hour,
                                minute: selectedExpiry!.minute)
                            : TimeOfDay.now(),
                      );
                      if (time == null) return;
                      setDs(() => selectedExpiry = DateTime(
                          date.year, date.month, date.day,
                          time.hour, time.minute));
                    },
                  ),
                  if (selectedExpiry != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        tr('Ocupă intervalul '
                        '${_formatTime(selectedExpiry!.subtract(Duration(minutes: selectedService?.durationMin ?? _bookingSettings.durationMin)))}'
                        '–${_formatTime(selectedExpiry!)}',
                        'Takes the slot '
                        '${_formatTime(selectedExpiry!.subtract(Duration(minutes: selectedService?.durationMin ?? _bookingSettings.durationMin)))}'
                        '–${_formatTime(selectedExpiry!)}'),
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade700),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Anulează', 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                final desc = descCtrl.text.trim();
                if (name.isEmpty) return;
                setState(() {
                  if (isEdit) {
                    final idx =
                        _items.indexWhere((e) => e.number == existing.number);
                    if (idx != -1) {
                      _items[idx] = existing.copyWith(
                        name: name,
                        description: desc,
                        expiresAt: selectedExpiry,
                        clearExpiry: selectedExpiry == null,
                        warningAt: _shiftedWarning(existing, selectedExpiry),
                        clearWarning:
                            _shiftedWarning(existing, selectedExpiry) == null,
                        // Mutată la altă oră: prezența se confirmă din nou.
                        clearAttendance: selectedExpiry != existing.expiresAt,
                        service: selectedService?.name,
                        durationMin: selectedService?.durationMin,
                        clearService: selectedService == null,
                      );
                    }
                  } else {
                    _items.add(Item(
                      syncId:      _generateSyncId(),
                      number:      _nextNumber++,
                      name:        name,
                      description: desc,
                      createdAt:   DateTime.now(),
                      expiresAt:   selectedExpiry,
                      warningAt:
                          autoWarningFor(selectedExpiry, _alertLeadMin),
                      service:     selectedService?.name,
                      durationMin: selectedService?.durationMin,
                    ));
                  }
                });
                Navigator.pop(ctx, true);
              },
              child: Text(isEdit ? tr('Salvează', 'Save') : tr('Adaugă', 'Add')),
            ),
          ],
        ),
      ),
    );

    if (saved == true) {
      Item? changedItem;
      if (isEdit) {
        changedItem = _items.firstWhere(
            (e) => e.number == existing.number, orElse: () => existing);
        await NotificationService.scheduleFor(changedItem,
            boardIndex: _activeBoardIndex);
        await SmsService.scheduleFor(changedItem,
            template: _smsTemplate, boardIndex: _activeBoardIndex);
        await SyncService.sendUpdate(changedItem);
      } else if (_items.isNotEmpty) {
        changedItem = _items.reduce((a, b) => a.number > b.number ? a : b);
        await NotificationService.scheduleFor(changedItem,
            boardIndex: _activeBoardIndex);
        await SmsService.scheduleFor(changedItem,
            template: _smsTemplate, boardIndex: _activeBoardIndex);
        await SyncService.sendAdd(changedItem);
      }
      await _saveItems();
    }
  }

  // ── Dialog alertă + SMS ──────────────────────────────────────────────────────
  static int _parseLead(TextEditingController hours,
          TextEditingController minutes) =>
      (int.tryParse(hours.text.trim()) ?? 0) * 60 +
      (int.tryParse(minutes.text.trim()) ?? 0);

  Future<void> _showWarningDialog(Item item) async {
    final expiresAt = item.expiresAt;
    const presets = [15, 30, 60, 120, 1440];
    // Modul alertei: cu un interval înainte de expirare (implicit), la o
    // oră exactă aleasă din calendar, sau deloc.
    var mode = _AlertMode.lead;
    var leadMin = _alertLeadMin;
    DateTime? exactWarning = item.warningAt;
    if (expiresAt == null) {
      mode = item.warningAt != null ? _AlertMode.exact : _AlertMode.none;
    } else if (item.warningAt != null) {
      final diff = expiresAt.difference(item.warningAt!).inMinutes;
      if (diff > 0) {
        leadMin = diff;
      } else {
        mode = _AlertMode.exact;
      }
    }
    bool custom = !presets.contains(leadMin);
    final hoursCtrl   = TextEditingController(text: '${leadMin ~/ 60}');
    final minutesCtrl = TextEditingController(text: '${leadMin % 60}');

    DateTime? effectiveWarning() => switch (mode) {
          _AlertMode.lead  => expiresAt?.subtract(Duration(minutes: leadMin)),
          _AlertMode.exact => exactWarning,
          _AlertMode.none  => null,
        };

    final phone1Ctrl = TextEditingController(text: item.phoneNumber  ?? '');
    final phone2Ctrl = TextEditingController(text: item.phoneNumber2 ?? '');
    final phone3Ctrl = TextEditingController(text: item.phoneNumber3 ?? '');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          title: Text(tr('Setează alertă & SMS', 'Set alert & SMS')),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15)),
                  if (item.expiresAt != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        tr('Expiră la: ${_formatDateTime(item.expiresAt!)}', 'Expires at: ${_formatDateTime(item.expiresAt!)}'),
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text(tr('Alertă', 'Alert'),
                      style: TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (expiresAt != null) ...[
                        for (final p in presets)
                          ChoiceChip(
                            label: Text(tr('${formatAlertLead(p)} înainte', '${formatAlertLead(p)} before')),
                            selected: mode == _AlertMode.lead &&
                                !custom && leadMin == p,
                            onSelected: (_) => setDs(() {
                              mode = _AlertMode.lead;
                              custom = false;
                              leadMin = p;
                              hoursCtrl.text = '${p ~/ 60}';
                              minutesCtrl.text = '${p % 60}';
                            }),
                          ),
                        ChoiceChip(
                          label: Text(tr('Personalizat', 'Custom')),
                          selected: mode == _AlertMode.lead && custom,
                          onSelected: (_) => setDs(() {
                            mode = _AlertMode.lead;
                            custom = true;
                          }),
                        ),
                      ],
                      ChoiceChip(
                        label: Text(tr('Oră exactă', 'Exact time')),
                        selected: mode == _AlertMode.exact,
                        onSelected: (_) => setDs(() {
                          mode = _AlertMode.exact;
                          exactWarning ??= effectiveWarning();
                        }),
                      ),
                      ChoiceChip(
                        label: Text(tr('Fără alertă', 'No alert')),
                        selected: mode == _AlertMode.none,
                        onSelected: (_) =>
                            setDs(() => mode = _AlertMode.none),
                      ),
                    ],
                  ),
                  if (mode == _AlertMode.lead && custom) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: hoursCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: tr('Ore înainte', 'Hours before'),
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (_) => setDs(() {
                              leadMin = _parseLead(hoursCtrl, minutesCtrl);
                            }),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: minutesCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: tr('Minute înainte', 'Minutes before'),
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (_) => setDs(() {
                              leadMin = _parseLead(hoursCtrl, minutesCtrl);
                            }),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (mode == _AlertMode.exact) ...[
                    const SizedBox(height: 8),
                    _buildDatePickerRow(
                      label: exactWarning == null
                          ? tr('Alertă: nesetată', 'Alert: not set')
                          : tr('Alertă la: ${_formatDateTime(exactWarning!)}', 'Alert at: ${_formatDateTime(exactWarning!)}'),
                      hasValue: exactWarning != null,
                      icon: Icons.alarm,
                      onClear: () => setDs(() => exactWarning = null),
                      onPick: () async {
                        final date = await showDatePicker(
                          context: ctx,
                          initialDate: exactWarning ?? DateTime.now(),
                          firstDate: DateTime(2020), lastDate: DateTime(2100),
                        );
                        if (date == null) return;
                        if (!ctx.mounted) return;
                        final time = await showTimePicker(
                          context: ctx,
                          initialTime: exactWarning != null
                              ? TimeOfDay(
                                  hour: exactWarning!.hour,
                                  minute: exactWarning!.minute)
                              : TimeOfDay.now(),
                        );
                        if (time == null) return;
                        setDs(() => exactWarning = DateTime(
                            date.year, date.month, date.day,
                            time.hour, time.minute));
                      },
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Builder(builder: (_) {
                      final w = effectiveWarning();
                      final String text;
                      Color color = Colors.grey.shade700;
                      if (mode == _AlertMode.lead && leadMin <= 0) {
                        text = tr('⚠️  Introdu un interval mai mare de 0.', '⚠️  Enter an interval greater than 0.');
                        color = Colors.orange.shade700;
                      } else if (w == null) {
                        text = mode == _AlertMode.none
                            ? tr('Nu se trimite nicio alertă.', 'No alert is sent.')
                            : tr('Alertă: nesetată', 'Alert: not set');
                      } else if (!w.isAfter(DateTime.now())) {
                        text = tr('⚠️  Momentul alertei (${_formatDateTime(w)}) '
                            'a trecut deja — nu se mai trimite.',
                        '⚠️  The alert time (${_formatDateTime(w)}) '
                        'has already passed — it will not be sent.');
                        color = Colors.orange.shade700;
                      } else if (expiresAt != null && w.isAfter(expiresAt)) {
                        text = tr('⚠️  Alerta este setată după data de expirare.', '⚠️  The alert is set after the expiry date.');
                        color = Colors.orange.shade700;
                      } else {
                        text = tr('Alerta pleacă la: ${_formatDateTime(w)}', 'The alert is sent at: ${_formatDateTime(w)}');
                      }
                      return Text(text,
                          style: TextStyle(fontSize: 12, color: color));
                    }),
                  ),
                  if (mode == _AlertMode.lead && expiresAt != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        tr('Intervalul ales se folosește automat la toate '
                        'programările noi din acest tabel.',
                        'The chosen interval is used automatically for all '
                        'new appointments in this table.'),
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade500),
                      ),
                    ),
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 8),
                  _phoneField(phone1Ctrl, tr('Telefon 1 (opțional)', 'Phone 1 (optional)'), setDs),
                  if (_noShowCountFor(phone1Ctrl.text) > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        children: [
                          _noShowBalls(_noShowCountFor(phone1Ctrl.text)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              tr('Clientul are ${_noShowCountFor(phone1Ctrl.text)} '
                              'neprezentări în ultimele 6 luni.',
                              'The client has ${_noShowCountFor(phone1Ctrl.text)} '
                              'no-shows in the last 6 months.'),
                              style: TextStyle(
                                  fontSize: 12, color: Colors.red.shade700),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 10),
                  _phoneField(phone2Ctrl, tr('Telefon 2 (opțional)', 'Phone 2 (optional)'), setDs),
                  const SizedBox(height: 10),
                  _phoneField(phone3Ctrl, tr('Telefon 3 (opțional)', 'Phone 3 (optional)'), setDs),
                  const SizedBox(height: 6),
                  Text(
                    tr('SMS trimis automat la toate numerele completate.', 'An SMS is sent automatically to all the numbers filled in.'),
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Anulează', 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                if (mode == _AlertMode.lead && leadMin <= 0) return;
                final warning = effectiveWarning();
                final p1  = phone1Ctrl.text.trim();
                final p2  = phone2Ctrl.text.trim();
                final p3  = phone3Ctrl.text.trim();
                final idx = _items.indexWhere((e) => e.number == item.number);
                if (idx != -1) {
                  setState(() {
                    _items[idx] = item.copyWith(
                      warningAt:    warning,
                      clearWarning: warning == null,
                      phoneNumber:  p1.isNotEmpty ? p1 : null, clearPhone:  p1.isEmpty,
                      phoneNumber2: p2.isNotEmpty ? p2 : null, clearPhone2: p2.isEmpty,
                      phoneNumber3: p3.isNotEmpty ? p3 : null, clearPhone3: p3.isEmpty,
                    );
                  });
                }
                Navigator.pop(ctx, true);
              },
              child: Text(tr('Salvează', 'Save')),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      // Intervalul ales devine implicit pentru programările noi ale tabelului.
      if (mode == _AlertMode.lead && expiresAt != null &&
          leadMin != _alertLeadMin) {
        _alertLeadMin = leadMin;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_alertLeadKeyFor(_activeBoardId), leadMin);
      }
      final updated = _items.firstWhere(
          (e) => e.number == item.number, orElse: () => item);
      await NotificationService.scheduleFor(updated,
          boardIndex: _activeBoardIndex);
      await SmsService.scheduleFor(updated,
          template: _smsTemplate, boardIndex: _activeBoardIndex);
      await SyncService.sendUpdate(updated);
      await _saveItems();
    }
  }

  // ── Ștergere ─────────────────────────────────────────────────────────────────
  Future<void> _confirmDelete(Item item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Șterge înregistrare', 'Delete entry')),
        content: Text(tr('Ești sigur că vrei să ștergi "${item.name}"?', 'Are you sure you want to delete "${item.name}"?')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Anulează', 'Cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Șterge', 'Delete')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final syncId = item.syncId; // salvăm înainte de ștergere
      await NotificationService.cancelFor(item.number,
          boardIndex: _activeBoardIndex);
      await SmsService.cancelFor(item.number, boardIndex: _activeBoardIndex);
      _deletedBuffer.add(DeletedItem(item: item, deletedAt: DateTime.now()));

      // Reținem înregistrările care își schimbă numărul la renumerotare,
      // ca să le anulăm și reprogramăm alarmele sub noul număr.
      final renumbered = <Item>[];
      setState(() {
        _items.removeWhere((e) => e.number == item.number);
        for (var i = 0; i < _items.length; i++) {
          if (_items[i].number != i + 1) {
            renumbered.add(_items[i]);
            _items[i] = _items[i].copyWith(number: i + 1);
          }
        }
        _nextNumber = _items.length + 1;
      });

      // Alarmele erau programate sub numărul vechi — le anulăm și le
      // reprogramăm sub noul număr, altfel rămân orfane sau lipsesc.
      for (final oldItem in renumbered) {
        await NotificationService.cancelFor(oldItem.number,
            boardIndex: _activeBoardIndex);
        await SmsService.cancelFor(oldItem.number, boardIndex: _activeBoardIndex);
      }
      for (final oldItem in renumbered) {
        final newItem =
            _items.firstWhere((e) => e.syncId == oldItem.syncId);
        await NotificationService.scheduleFor(newItem,
            boardIndex: _activeBoardIndex);
        await SmsService.scheduleFor(newItem,
            template: _smsTemplate, boardIndex: _activeBoardIndex);
      }

      await SyncService.sendDelete(syncId);
      await _saveItems();
      await _saveBuffer();
    }
  }

  // ── Dialog rezervări prin SMS ────────────────────────────────────────────────
  Future<void> _showBookingSettingsDialog() async {
    bool enabled = _bookingSettings.enabled;
    TimeOfDay workStart = TimeOfDay(
        hour: _bookingSettings.workStartMin ~/ 60,
        minute: _bookingSettings.workStartMin % 60);
    TimeOfDay workEnd = TimeOfDay(
        hour: _bookingSettings.workEndMin ~/ 60,
        minute: _bookingSettings.workEndMin % 60);
    final closedDays = Set<int>.of(_bookingSettings.closedDays);

    final dayLabels = {
      1: tr('L', 'Mo'), 2: tr('Ma', 'Tu'), 3: tr('Mi', 'We'), 4: tr('J', 'Th'),
      5: tr('V', 'Fr'), 6: tr('S', 'Sa'), 7: tr('D', 'Su'),
    };
    var blockThreshold = _noShowBlockThreshold;
    var noShowSms = (await SharedPreferences.getInstance())
            .getBool(kNoShowSmsKey) ??
        false;
    if (!mounted) return;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          title: Text(tr('Rezervări prin SMS', 'SMS bookings')),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Clienții trimit SMS cu "liber" urmat de numele '
                    'tabelului (categoria, ex. "liber unghii"), aleg '
                    'serviciul din lista primită (butonul Servicii), apoi '
                    'ora liberă — răspunzând de fiecare dată cu numărul '
                    'opțiunii. Doar "liber" trimite lista categoriilor '
                    'active.',
                    'Clients text "free" followed by the table '
                    'name (the category, e.g. "free nails"), choose '
                    'the service from the list they receive (the Services button), then '
                    'a free time — replying each time with the option '
                    'number. Just "free" sends the list of active '
                    'categories.'),
                    style: TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                  const SizedBox(height: 6),
                  // Trebuie să rămână la fel ca BotLimits.kt.
                  Text(
                    tr('Protecție anti-abuz: botul răspunde doar numerelor de '
                    'telefon, cel mult 15 mesaje pe oră de la același număr '
                    'și 100 de răspunsuri pe zi; un client poate avea cel '
                    'mult 2 rezervări active.',
                    'Abuse protection: the bot replies only to phone '
                    'numbers, at most 15 messages per hour from the same number '
                    'and 100 replies per day; a client can have at '
                    'most 2 active bookings.'),
                    style: TextStyle(fontSize: 11, color: Colors.black45),
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr('Activ pentru acest tabel', 'Active for this table')),
                    value: enabled,
                    onChanged: (v) => setDs(() => enabled = v),
                  ),
                  const SizedBox(height: 4),
                  Text(tr('Blochează rezervările prin SMS după', 'Block SMS bookings after'),
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final n in kNoShowThresholdOptions)
                        ChoiceChip(
                          label: Text(n == 0 ? tr('Niciodată', 'Never') : tr('$n neprezentări', '$n no-shows')),
                          selected: blockThreshold == n,
                          onSelected: (_) => setDs(() => blockThreshold = n),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    blockThreshold == 0
                        ? tr('Clienții cu neprezentări pot rezerva în continuare.', 'Clients with no-shows can still book.')
                        : tr('Pentru toți clienții salonului, pe toate tabelele. '
                            'Clientul blocat poate fi programat manual și '
                            'iertat din lista „Clienți cu neprezentări”.',
                        'For all clients, on all tables. '
                        'A blocked client can be booked manually and '
                        'forgiven from the “Clients with no-shows” list.'),
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr('Anunță clientul prin SMS la neprezentare', 'Text the client on a no-show')),
                    subtitle: Text(
                      tr('Cu sincronizare pe două telefoane, activează doar pe unul.', 'With sync on two phones, turn it on on only one.'),
                      style: TextStyle(fontSize: 11),
                    ),
                    value: noShowSms,
                    onChanged: (v) => setDs(() => noShowSms = v),
                  ),
                  const SizedBox(height: 8),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(tr('Deschidere', 'Opening')),
                          subtitle: Text(workStart.format(context)),
                          onTap: () async {
                            final t = await showTimePicker(
                                context: ctx, initialTime: workStart);
                            if (t != null) setDs(() => workStart = t);
                          },
                        ),
                      ),
                      Expanded(
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(tr('Închidere', 'Closing')),
                          subtitle: Text(workEnd.format(context)),
                          onTap: () async {
                            final t = await showTimePicker(
                                context: ctx, initialTime: workEnd);
                            if (t != null) setDs(() => workEnd = t);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(tr('Zile în care NU lucrezi (fără programări)', 'Days you do NOT work (no appointments)'),
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    children: dayLabels.entries.map((e) {
                      final selected = closedDays.contains(e.key);
                      return FilterChip(
                        label: Text(e.value),
                        selected: selected,
                        selectedColor: Colors.red.shade100,
                        checkmarkColor: Colors.red.shade700,
                        onSelected: (sel) => setDs(() {
                          if (sel) {
                            closedDays.add(e.key);
                          } else {
                            closedDays.remove(e.key);
                          }
                        }),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 6),
                  Builder(builder: (_) {
                    final open = dayLabels.entries
                        .where((e) => !closedDays.contains(e.key))
                        .map((e) => e.value)
                        .toList();
                    return Text(
                      open.isEmpty
                          ? tr('⚠️  Toate zilele sunt bifate — nu se poate face '
                              'nicio programare.',
                          '⚠️  All days are ticked — no appointment '
                          'can be made.')
                          : tr('Se pot face programări: ${open.join(', ')}', 'Appointments possible: ${open.join(', ')}'),
                      style: TextStyle(
                          fontSize: 12,
                          color: open.isEmpty
                              ? Colors.orange.shade700
                              : Colors.grey.shade700),
                    );
                  }),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Anulează', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Salvează', 'Save')),
            ),
          ],
        ),
      ),
    );

    if (saved != true) return;

    final startMin = workStart.hour * 60 + workStart.minute;
    final endMin = workEnd.hour * 60 + workEnd.minute;
    if (endMin <= startMin) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(tr('Ora de închidere trebuie să fie după cea de deschidere.', 'The closing time must be after the opening time.')),
        ));
      }
      return;
    }

    final updated = _bookingSettings.copyWith(
      enabled: enabled,
      workStartMin: startMin,
      workEndMin: endMin,
      closedDays: closedDays,
    );
    setState(() {
      _bookingSettings = updated;
      _noShowBlockThreshold = blockThreshold;
    });
    await _saveBookingSettings(_activeBoardId, updated);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kNoShowThresholdKey, blockThreshold);
    await prefs.setBool(kNoShowSmsKey, noShowSms);
    await _recomputeFreeSlots();
  }

  // ── Dialog sincronizare dispozitiv ───────────────────────────────────────────
  Future<void> _showSyncDialog() async {
    final phoneCtrl =
        TextEditingController(text: SyncService.partnerPhone ?? '');
    final codeCtrl = TextEditingController();
    String? codeError;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          title: Row(
            children: [
              Icon(
                SyncService.isActive ? Icons.sync : Icons.sync_disabled,
                color: SyncService.isActive
                    ? Colors.green.shade600
                    : Colors.grey,
                size: 22,
              ),
              const SizedBox(width: 8),
              Text(tr('Sincronizare · ${_activeBoard.name}', 'Sync · ${_activeBoard.name}')),
            ],
          ),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (SyncService.isActive) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.green.shade200),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.check_circle_outline,
                              color: Colors.green.shade700, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              tr('Sincronizare activă cu:\n${SyncService.partnerPhone}', 'Sync active with:\n${SyncService.partnerPhone}'),
                              style: TextStyle(
                                  color: Colors.green.shade800,
                                  fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      tr('Modificările se trimit automat prin SMS la fiecare schimbare.', 'Changes are sent automatically by SMS every time something changes.'),
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      tr('Cod de împerechere: ${SyncService.pairingCode ?? ''}', 'Pairing code: ${SyncService.pairingCode ?? ''}'),
                      style: const TextStyle(
                          fontSize: 12, fontFamily: 'monospace'),
                    ),
                  ] else ...[
                    TextField(
                      controller: phoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        labelText: tr('Număr telefon partener *', 'Partner phone number *'),
                        hintText: '+40712345678',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: codeCtrl,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        labelText: tr('Cod de împerechere *', 'Pairing code *'),
                        hintText: tr('ex. K7QM-2XPA', 'e.g. K7QM-2XPA'),
                        helperText:
                            tr('Același cod pe ambele telefoane. Generează-l pe '
                            'unul și tastează-l pe celălalt.',
                            'The same code on both phones. Generate it on '
                            'one and type it on the other.'),
                        helperMaxLines: 2,
                        errorText: codeError,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.key_outlined),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.casino_outlined),
                          tooltip: tr('Generează cod', 'Generate code'),
                          onPressed: () => setDs(() {
                            codeCtrl.text = SyncService.generateCode();
                            codeError = null;
                          }),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.blue.shade100),
                      ),
                      child: Text(
                        tr('La prima sincronizare, toate înregistrările de pe acest '
                        'dispozitiv vor fi trimise prin SMS. Ulterior, fiecare '
                        'modificare va fi sincronizată automat.\n\n'
                        'Configurează sincronizarea și pe celălalt dispozitiv, '
                        'cu același cod — mesajele cu alt cod sunt ignorate.',
                        'On the first sync, all entries on this '
                        'device are sent by SMS. After that, every '
                        'change is synced automatically.\n\n'
                        'Set up sync on the other device as well, '
                        'with the same code — messages with another code are ignored.'),
                        style: TextStyle(
                            fontSize: 11, color: Colors.blue.shade700),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (SyncService.isActive)
              TextButton.icon(
                icon: const Icon(Icons.sync_disabled, color: Colors.red, size: 18),
                label: Text(tr('Desincronizează', 'Stop syncing'),
                    style: TextStyle(color: Colors.red)),
                onPressed: () async {
                  await SyncService.clearPartner();
                  setDs(() {});
                  if (ctx.mounted) Navigator.pop(ctx);
                  setState(() {});
                },
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Închide', 'Close')),
            ),
            if (!SyncService.isActive)
              FilledButton.icon(
                icon: const Icon(Icons.sync, size: 18),
                label: Text(tr('Sincronizează', 'Sync')),
                onPressed: () async {
                  final phone = phoneCtrl.text.trim();
                  if (phone.isEmpty) return;
                  if (!SyncService.isValidCode(codeCtrl.text)) {
                    setDs(() => codeError =
                        tr('Minim ${SyncService.minCodeLength} litere/cifre.', 'At least ${SyncService.minCodeLength} letters/digits.'));
                    return;
                  }
                  if (!await _ensureSmsPermission()) return;
                  await SyncService.setPartner(phone, codeCtrl.text);
                  setDs(() {});
                  if (ctx.mounted) Navigator.pop(ctx);
                  setState(() {});
                  _performInitialSync();
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _performInitialSync() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            tr('Trimitere sincronizare inițială (${_items.length} înregistrări)...', 'Sending initial sync (${_items.length} ${_items.length == 1 ? 'entry' : 'entries'})...')),
        duration: Duration(seconds: _items.length * 2 + 3),
      ),
    );
    await SyncService.sendLicenseHandshake();
    // Doar o listă completată — una goală ar șterge serviciile partenerului.
    if (_services.isNotEmpty) {
      await SyncService.sendServices(_bookingSettings.durationMin, _services);
    }
    await SyncService.sendInitialSync(_items);
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Sincronizare inițială trimisă!', 'Initial sync sent!')),
        duration: Duration(seconds: 3),
      ),
    );
  }

  // ── Prezența la programare ───────────────────────────────────────────────────
  Future<void> _setAttendance(Item item, String? value) async {
    final idx = _items.indexWhere((e) => e.syncId == item.syncId);
    if (idx == -1) return;
    final updated = value == null
        ? _items[idx].copyWith(clearAttendance: true)
        : _items[idx].copyWith(attendance: value);
    final before = _items[idx];
    setState(() => _items[idx] = updated);
    await _saveItems();
    await SyncService.sendUpdate(updated);
    if (before.attendance != kNoShow && updated.attendance == kNoShow) {
      await _refreshNoShows();
      await _notifyNoShows([updated]);
    }
  }

  // ── Neprezentare automată ────────────────────────────────────────────────────
  // Programările neconfirmate la 24 de ore după final devin neprezentări, pe
  // toate tabelele. Fiecare telefon le marchează singur (nu se sincronizează —
  // celălalt ajunge la același rezultat), deci nu circulă SMS-uri în plus.
  bool _autoNoShowBusy = false;

  Future<void> _applyAutoNoShows() async {
    if (_loading || _autoNoShowBusy || _syncQueueBusy || _attendanceSince == null) {
      return;
    }
    _autoNoShowBusy = true;
    try {
      final now = DateTime.now();
      bool due(Item i) =>
          needsAttendance(i, _attendanceSince, now: now) &&
          !i.expiresAt!.add(kAutoNoShowAfter).isAfter(now);
      Item mark(Item i) => i.copyWith(attendance: kNoShow, attendanceAuto: true);
      final marked = <Item>[];

      final idxs = [for (var i = 0; i < _items.length; i++) if (due(_items[i])) i];
      if (idxs.isNotEmpty) {
        setState(() {
          for (final i in idxs) {
            _items[i] = mark(_items[i]);
            marked.add(_items[i]);
          }
        });
        await _saveItems();
      }

      final prefs = await SharedPreferences.getInstance();
      for (final b in _boards) {
        if (b.id == _activeBoardId) continue;
        final str = prefs.getString(_itemsKeyFor(b.id));
        if (str == null) continue;
        try {
          final items = (jsonDecode(str) as List<dynamic>)
              .map((e) => Item.fromJson(e as Map<String, dynamic>))
              .toList();
          var changed = false;
          for (var i = 0; i < items.length; i++) {
            if (!due(items[i])) continue;
            items[i] = mark(items[i]);
            marked.add(items[i]);
            changed = true;
          }
          if (changed) {
            await prefs.setString(_itemsKeyFor(b.id),
                jsonEncode(items.map((e) => e.toJson()).toList()));
          }
        } catch (_) {}
      }

      if (marked.isNotEmpty) {
        await _refreshNoShows();
        await _notifyNoShows(marked);
      }
    } finally {
      _autoNoShowBusy = false;
    }
  }

  // ── SMS către client la neprezentare (opțional) ──────────────────────────────
  // Îl trimite doar telefonul pe care e activă opțiunea, indiferent unde s-a
  // marcat neprezentarea (aici, pe partener sau automat) — o singură dată pe
  // programare.
  Future<void> _notifyNoShows(List<Item> items) async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(kNoShowSmsKey) ?? false)) return;
    if (!LicenseService.isLicensed && !LicenseService.isTrialActive) return;
    final sent = (prefs.getStringList(kNoShowSmsSentKey) ?? []).toList();
    for (final item in items) {
      final phone = item.clientPhone;
      if (phone == null || item.expiresAt == null) continue;
      if (sent.contains(item.syncId)) continue;
      sent.add(item.syncId);
      await SmsService.sendNow(
          phone,
          noShowSmsText(item.expiresAt!, _noShowBlockThreshold,
              _noShowCountFor(phone)));
    }
    // Păstrăm doar ultimele 300 de programări notificate.
    final trimmed = sent.length > 300 ? sent.sublist(sent.length - 300) : sent;
    await prefs.setStringList(kNoShowSmsSentKey, trimmed);
  }

  Future<void> _showAttendanceDialog(Item item) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('A venit ${item.name}?', 'Did ${item.name} arrive?')),
        content: Text(
          item.expiresAt != null
              ? tr('Programarea s-a încheiat la ${_formatDateTime(item.expiresAt!)}.', 'The appointment ended at ${_formatDateTime(item.expiresAt!)}.')
              : tr('Confirmă prezența clientului.', 'Confirm that the client showed up.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Anulează', 'Cancel')),
          ),
          OutlinedButton.icon(
            icon: Icon(Icons.close, color: Colors.red.shade700),
            label: Text(tr('Nu a venit', 'Did not arrive'),
                style: TextStyle(color: Colors.red.shade700)),
            onPressed: () => Navigator.pop(ctx, kNoShow),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.check),
            label: Text(tr('A venit', 'Arrived')),
            style: FilledButton.styleFrom(
                backgroundColor: Colors.green.shade700),
            onPressed: () => Navigator.pop(ctx, kCame),
          ),
        ],
      ),
    );
    if (choice != null && choice != item.attendance) {
      await _setAttendance(item, choice);
    }
  }

  // Lista programărilor încheiate și neconfirmate, cu ✓ / ✗ pe fiecare rând.
  Future<void> _showPendingAttendance() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) {
          final pending = _items.where(_needsAttendance).toList()
            ..sort((a, b) => a.expiresAt!.compareTo(b.expiresAt!));
          return AlertDialog(
            title: Text(tr('Confirmă prezența', 'Confirm attendance')),
            content: SizedBox(
              width: 420,
              child: pending.isEmpty
                  ? Text(tr('Toate programările sunt confirmate.', 'All appointments are confirmed.'))
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final item in pending)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(item.name),
                            subtitle: Text(_formatDateTime(item.expiresAt!)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: tr('Nu a venit', 'Did not arrive'),
                                  icon: Icon(Icons.close,
                                      color: Colors.red.shade700),
                                  onPressed: () async {
                                    await _setAttendance(item, kNoShow);
                                    setDs(() {});
                                  },
                                ),
                                IconButton(
                                  tooltip: tr('A venit', 'Arrived'),
                                  icon: Icon(Icons.check,
                                      color: Colors.green.shade700),
                                  onPressed: () async {
                                    await _setAttendance(item, kCame);
                                    setDs(() {});
                                  },
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('Închide', 'Close')),
              ),
            ],
          );
        },
      ),
    );
  }

  String _attendanceLabel(Item item) => switch (item.attendance) {
        kCame   => tr('A venit', 'Arrived'),
        kNoShow => item.attendanceAuto
            ? tr('Nu a venit (neconfirmată în 24 de ore)', 'Did not arrive (not confirmed within 24 hours)')
            : tr('Nu a venit', 'Did not arrive'),
        _       => _needsAttendance(item) ? tr('De confirmat', 'To confirm') : '—',
      };

  // ── Dialog detalii ───────────────────────────────────────────────────────────
  void _showItemDetail(Item item) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item.name),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _detailRow(tr('Nr.', 'No.'), item.number.toString()),
              const SizedBox(height: 10),
              _detailRow(tr('Descriere', 'Description'),
                  item.description.isEmpty ? '—' : item.description),
              const SizedBox(height: 10),
              if (item.service != null) ...[
                _detailRow(tr('Serviciu', 'Service'),
                    '${item.service} (${formatServiceDuration(item.durationOr(_bookingSettings.durationMin))})'),
                const SizedBox(height: 10),
              ],
              _detailRow(tr('Creat la', 'Created'), _formatDateTime(item.createdAt)),
              const SizedBox(height: 10),
              _detailRow(
                tr('Expiră la', 'Expires at'),
                item.expiresAt != null
                    ? _formatDateTime(item.expiresAt!)
                    : tr('Nesetată', 'Not set'),
                valueColor: _isExpired(item) ? Colors.red.shade700 : null,
              ),
              if (item.warningAt != null) ...[
                const SizedBox(height: 10),
                _detailRow(tr('Alertă la', 'Alert at'), _formatDateTime(item.warningAt!),
                    valueColor: Colors.orange.shade700),
              ],
              if (item.phones.isNotEmpty) ...[
                const SizedBox(height: 10),
                _detailRow(tr('SMS la', 'SMS to'), item.phones.join('\n'),
                    valueColor: Colors.blue.shade700),
              ],
              if (_noShowCountFor(item.clientPhone) > 0) ...[
                const SizedBox(height: 10),
                _detailRow(
                    tr('Neprezentări', 'No-shows'),
                    tr('${_noShowCountFor(item.clientPhone)} în ultimele 6 luni', '${_noShowCountFor(item.clientPhone)} in the last 6 months'),
                    valueColor: Colors.red.shade700),
              ],
              if (_isExpired(item)) ...[
                const SizedBox(height: 10),
                _detailRow(tr('Prezență', 'Attendance'), _attendanceLabel(item),
                    valueColor: switch (item.attendance) {
                      kCame   => Colors.green.shade700,
                      kNoShow => Colors.red.shade700,
                      _       => Colors.orange.shade800,
                    }),
              ],
            ],
          ),
        ),
        actions: [
          if (_isExpired(item))
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _showAttendanceDialog(item);
              },
              child: Text(tr('Prezență', 'Attendance')),
            ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _showItemDialog(existing: item);
            },
            child: Text(tr('Editează', 'Edit')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Închide', 'Close')),
          ),
        ],
      ),
    );
  }

  // ── Widget helpers ───────────────────────────────────────────────────────────
  Widget _detailRow(String label, String value, {Color? valueColor}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(fontSize: 14, color: valueColor ?? Colors.black87)),
      ],
    );
  }

  Widget _buildDatePickerRow({
    required String label,
    required bool hasValue,
    required VoidCallback onClear,
    required Future<void> Function() onPick,
    IconData icon = Icons.calendar_today,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: TextStyle(
                  color: hasValue ? Colors.black87 : Colors.grey)),
        ),
        if (hasValue)
          IconButton(
              icon: const Icon(Icons.clear, size: 18),
              tooltip: tr('Șterge data', 'Clear date'),
              onPressed: onClear),
        TextButton.icon(
          icon: Icon(icon),
          label: Text(tr('Alege', 'Choose')),
          onPressed: onPick,
        ),
      ],
    );
  }

  Widget _dataCell(String text,
      {double? width, bool expired = false, bool muted = false}) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          color: expired
              ? Colors.red.shade700
              : muted
                  ? Colors.grey.shade400
                  : Colors.black87,
          fontWeight: expired ? FontWeight.w500 : FontWeight.normal,
          fontStyle: muted ? FontStyle.italic : FontStyle.normal,
        ),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
    );
  }

  Widget _nameCell(Item item, bool expired) {
    final count = _noShowCountFor(item.clientPhone);
    if (count == 0) return _dataCell(item.name, width: 160, expired: expired);
    return Container(
      width: 160,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          Flexible(
            child: Text(
              item.name,
              style: TextStyle(
                fontSize: 13,
                color: expired ? Colors.red.shade700 : Colors.black87,
                fontWeight: expired ? FontWeight.w500 : FontWeight.normal,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: 4),
          _noShowBalls(count),
        ],
      ),
    );
  }

  Widget _freeSlotRow(_FreeSlot slot, bool isEven) {
    final bg = isEven ? const Color(0xFFF0FDF4) : const Color(0xFFECFDF5);
    final fg = Colors.green.shade700;
    return Container(
      color: bg,
      child: Row(
        children: [
          SizedBox(
            width: 70 + 160 + 200,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Text(
                tr('Liber', 'Free'),
                style: TextStyle(
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ),
          ),
          _dataCell(_formatDateTime(slot.start), width: 155, muted: true),
          _dataCell(_formatDateTime(slot.end),   width: 155, muted: true),
          SizedBox(width: _actionColWidth),
        ],
      ),
    );
  }

  Widget _actionBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? color,
  }) {
    return IconButton(
      icon: Icon(icon, size: 18, color: color),
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final rows = _filteredAndSorted;
    final rowsForDisplay = _spatiereActiva
        ? (List.of(rows)..sort((a, b) => _compareItems(a, b, SortColumn.expiresAt)))
        : rows;
    final displayRows = _withFreeSlots(rowsForDisplay);

    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: _showBoardMenu,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Organizator',
                  style: TextStyle(fontSize: 12, color: Colors.white70)),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_activeBoard.name,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  const Icon(Icons.arrow_drop_down, color: Colors.white70),
                ],
              ),
            ],
          ),
        ),
        actions: [
          // Indicator licență (Android)
          if (Platform.isAndroid)
            IconButton(
              icon: Icon(
                LicenseService.isExpiringSoon
                    ? Icons.warning_amber_rounded
                    : LicenseService.isLicensed
                    ? Icons.verified_user
                    : LicenseService.isTrialActive
                        ? Icons.lock_open_outlined
                        : Icons.lock_outline,
                color: LicenseService.isExpiringSoon
                    ? Colors.orangeAccent.shade100
                    : LicenseService.isLicensed
                    ? Colors.greenAccent.shade100
                    : LicenseService.isTrialActive
                        ? Colors.orangeAccent.shade100
                        : Colors.white54,
              ),
              tooltip: LicenseService.isExpiringSoon
                  ? tr('Licența expiră în ${LicenseService.newLicenseDaysUntilExpiry} zile', 'The license expires in ${LicenseService.newLicenseDaysUntilExpiry} days')
                  : LicenseService.isLicensed
                  ? tr('Licență activă', 'License active')
                  : LicenseService.isTrialActive
                      ? tr('Trial activ · ${LicenseService.trialDaysLeft} zile rămase', 'Trial active · ${LicenseService.trialDaysLeft} days left')
                      : tr('Trial expirat · activează licența', 'Trial expired · activate the license'),
              onPressed: _openLicenseScreen,
            ),
          // Buton sincronizare — vizibil doar pe Android
          if (SyncService.isSupported)
            IconButton(
              icon: Icon(
                SyncService.isActive ? Icons.sync : Icons.sync_disabled,
                color: SyncService.isActive
                    ? Colors.greenAccent.shade100
                    : Colors.white54,
              ),
              tooltip: SyncService.isActive
                  ? tr('Sincronizare activă · ${SyncService.partnerPhone}', 'Sync active · ${SyncService.partnerPhone}')
                  : tr('Configurează sincronizare', 'Set up sync'),
              onPressed: _showSyncDialog,
            ),
          // Clienți cu neprezentări — doar când există
          if (_noShows.isNotEmpty)
            IconButton(
              icon: Icon(Icons.person_off_outlined,
                  color: Colors.redAccent.shade100),
              tooltip: tr('Clienți cu neprezentări', 'Clients with no-shows'),
              onPressed: _showNoShowClients,
            ),
          // Buton backup & restaurare — vizibil doar pe Android
          if (BackupService.isSupported)
            IconButton(
              icon: const Icon(Icons.settings_backup_restore,
                  color: Colors.white70),
              tooltip: tr('Backup & restaurare', 'Backup & restore'),
              onPressed: _openBackupScreen,
            ),
          // Buton rezervări prin SMS — vizibil doar pe Android
          if (Platform.isAndroid)
            IconButton(
              icon: Icon(
                Icons.event_available,
                color: _bookingSettings.enabled
                    ? Colors.greenAccent.shade100
                    : Colors.white54,
              ),
              tooltip: _bookingSettings.enabled
                  ? tr('Rezervări prin SMS active', 'SMS bookings active')
                  : tr('Configurează rezervări prin SMS', 'Set up SMS bookings'),
              onPressed: _showBookingSettingsDialog,
            ),
          IconButton(
            icon: Icon(
              _searchVisible ? Icons.search_off : Icons.search,
              color: Colors.white,
            ),
            tooltip: _searchVisible ? tr('Ascunde căutare', 'Hide search') : tr('Caută', 'Search'),
            onPressed: () {
              setState(() {
                _searchVisible = !_searchVisible;
                if (!_searchVisible) {
                  _searchController.clear();
                  _searchQuery = '';
                }
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.language, color: Colors.white70),
            tooltip: tr('Limba aplicației', 'App language'),
            onPressed: _showLanguageDialog,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  if (_smsBlocked)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Material(
                        color: Colors.red.shade50,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: BorderSide(color: Colors.red.shade200),
                        ),
                        child: ListTile(
                          leading: Icon(Icons.sms_failed_outlined,
                              color: Colors.red.shade700),
                          title: Text(tr('SMS-urile sunt blocate', 'SMS is blocked'),
                              style: TextStyle(
                                  color: Colors.red.shade800,
                                  fontWeight: FontWeight.w600)),
                          subtitle: Text(
                              tr('Remindere, rezervări și sincronizarea nu funcționează.', 'Reminders, bookings and sync are not working.')),
                          trailing: TextButton(
                            onPressed: _showSmsBlockedDialog,
                            child: Text(tr('Rezolvă', 'Fix')),
                          ),
                          onTap: _showSmsBlockedDialog,
                        ),
                      ),
                    ),
                  if (_autostartBlocked)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Material(
                        color: Colors.orange.shade50,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: BorderSide(color: Colors.orange.shade300),
                        ),
                        child: ListTile(
                          leading: Icon(Icons.power_settings_new,
                              color: Colors.orange.shade900),
                          title: Text(tr('Activează „Pornire automată”', 'Turn on “Autostart”'),
                              style: TextStyle(
                                  color: Colors.orange.shade900,
                                  fontWeight: FontWeight.w600)),
                          subtitle: Text(
                              tr('Fără ea, cu aplicația închisă, botul nu răspunde '
                              'la SMS-uri și sincronizarea nu primește nimic.',
                              'Without it, with the app closed, the bot does not reply '
                              'to SMS and sync receives nothing.')),
                          trailing: TextButton(
                            onPressed: SmsService.openAutostartSettings,
                            child: Text(tr('Activează', 'Activate')),
                          ),
                          onTap: SmsService.openAutostartSettings,
                        ),
                      ),
                    ),
                  if (_items.any(_needsAttendance))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Material(
                        color: const Color(0xFFFFEDD5),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: BorderSide(color: Colors.orange.shade300),
                        ),
                        child: ListTile(
                          leading: Icon(Icons.how_to_reg_outlined,
                              color: Colors.orange.shade900),
                          title: Text(
                              tr('${_items.where(_needsAttendance).length} '
                              'programări de confirmat',
                              '${_items.where(_needsAttendance).length} '
                              '${_items.where(_needsAttendance).length == 1 ? 'appointment' : 'appointments'} to confirm'),
                              style: TextStyle(
                                  color: Colors.orange.shade900,
                                  fontWeight: FontWeight.w600)),
                          subtitle: Text(
                              tr('Marchează dacă clienții au venit. Neconfirmate '
                              'în 24 de ore, contează ca neprezentări.',
                              'Mark whether the clients showed up. Not confirmed '
                              'within 24 hours, they count as no-shows.')),
                          trailing: TextButton(
                            onPressed: _showPendingAttendance,
                            child: Text(tr('Confirmă', 'Confirm')),
                          ),
                          onTap: _showPendingAttendance,
                        ),
                      ),
                    ),
                  if (_smsFailure != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Material(
                        color: Colors.orange.shade50,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: BorderSide(color: Colors.orange.shade300),
                        ),
                        child: ListTile(
                          leading: Icon(Icons.sms_failed_outlined,
                              color: Colors.orange.shade900),
                          title: Text(tr('Un SMS nu a putut fi trimis', 'An SMS could not be sent'),
                              style: TextStyle(
                                  color: Colors.orange.shade900,
                                  fontWeight: FontWeight.w600)),
                          subtitle: Text(
                              tr('Către ${_smsFailure!.phone} · '
                              '${SmsService._fmt(_smsFailure!.failedAt)}\n'
                              '${_smsFailure!.reason}',
                              'To ${_smsFailure!.phone} · '
                              '${SmsService._fmt(_smsFailure!.failedAt)}\n'
                              '${_smsFailure!.reason}')),
                          isThreeLine: true,
                          trailing: TextButton(
                            onPressed: _dismissSmsFailure,
                            child: const Text('OK'),
                          ),
                        ),
                      ),
                    ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeInOut,
                    child: _searchVisible
                        ? Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: TextField(
                              controller: _searchController,
                              autofocus: true,
                              decoration: InputDecoration(
                                hintText: tr('Caută în tabel...', 'Search the table...'),
                                prefixIcon: const Icon(Icons.search),
                                suffixIcon: _searchQuery.isNotEmpty
                                    ? IconButton(
                                        icon: const Icon(Icons.clear),
                                        onPressed: () {
                                          _searchController.clear();
                                          setState(() => _searchQuery = '');
                                        },
                                      )
                                    : null,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(
                                      color: Color(0xFFCBD5E1)),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(
                                      color: Color(0xFFCBD5E1)),
                                ),
                                filled: true,
                                fillColor: Colors.white,
                              ),
                              onChanged: (v) =>
                                  setState(() => _searchQuery = v),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border:
                            Border.all(color: const Color(0xFFCBD5E1)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.07),
                            blurRadius: 12,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SizedBox(
                                width: 70 + 160 + 200 + 155 + 155 + _actionColWidth,
                                child: Column(
                                  children: [
                                    Container(
                                      color: const Color(0xFF1E1B4B),
                                      child: Row(
                                        children: [
                                          _buildHeaderCell(tr('Nr.', 'No.'),       SortColumn.number,      width: 70),
                                          _buildHeaderCell(tr('Nume', 'Name'),      SortColumn.name,        width: 160),
                                          _buildHeaderCell(tr('Descriere', 'Description'), SortColumn.description, width: 200),
                                          _buildHeaderCell(tr('Creat la', 'Created'),  SortColumn.createdAt,   width: 155),
                                          _buildHeaderCell(tr('Expiră la', 'Expires at'), SortColumn.expiresAt,   width: 155),
                                          SizedBox(width: _actionColWidth),
                                        ],
                                      ),
                                    ),
                                    Expanded(
                                      child: rows.isEmpty
                                          ? Center(
                                              child: Text(
                                                _searchQuery.isEmpty
                                                    ? tr('Nu există înregistrări.', 'There are no entries.')
                                                    : tr('Niciun rezultat pentru "$_searchQuery".', 'No results for "$_searchQuery".'),
                                                style: TextStyle(
                                                    color: Colors.grey.shade600),
                                              ),
                                            )
                                          : ListView.builder(
                                              itemCount: displayRows.length,
                                              itemBuilder: (ctx, index) {
                                                final entry  = displayRows[index];
                                                final isEven = index % 2 == 0;
                                                if (entry is _FreeSlot) {
                                                  return _freeSlotRow(entry, isEven);
                                                }
                                                final item   = entry as Item;
                                                // Programarea la care clientul a venit nu mai e „roșie”.
                                                final expired = _isExpired(item) && item.attendance != kCame;
                                                return InkWell(
                                                  onTap: () =>
                                                      _showItemDetail(item),
                                                  child: Container(
                                                    color: _rowBg(item, isEven),
                                                    child: Row(
                                                      children: [
                                                        _dataCell(item.number.toString(), width: 70,  expired: expired),
                                                        _nameCell(item, expired),
                                                        _dataCell(_descriptionWithService(item), width: 200, expired: expired),
                                                        _dataCell(_formatDateTime(item.createdAt), width: 155, expired: expired),
                                                        _dataCell(
                                                          item.expiresAt != null
                                                              ? _formatDateTime(item.expiresAt!)
                                                              : tr('Nesetată', 'Not set'),
                                                          width: 155,
                                                          expired: expired,
                                                          muted: !expired && item.expiresAt == null,
                                                        ),
                                                        SizedBox(
                                                          width: _actionColWidth,
                                                          child: Row(
                                                            mainAxisAlignment:
                                                                MainAxisAlignment.center,
                                                            children: [
                                                              _actionBtn(
                                                                icon: Icons.edit_outlined,
                                                                tooltip: tr('Editează', 'Edit'),
                                                                onPressed: () =>
                                                                    _showItemDialog(existing: item),
                                                              ),
                                                              if (_tracksAttendance(item))
                                                                _actionBtn(
                                                                  icon: switch (item.attendance) {
                                                                    kCame   => Icons.check_circle,
                                                                    kNoShow => Icons.cancel,
                                                                    _       => Icons.how_to_reg_outlined,
                                                                  },
                                                                  tooltip: tr('Confirmă prezența', 'Confirm attendance'),
                                                                  color: switch (item.attendance) {
                                                                    kCame   => Colors.green.shade700,
                                                                    kNoShow => Colors.red.shade700,
                                                                    _       => Colors.orange.shade800,
                                                                  },
                                                                  onPressed: () =>
                                                                      _showAttendanceDialog(item),
                                                                )
                                                              else
                                                              _actionBtn(
                                                                icon: Icons.alarm_outlined,
                                                                tooltip: tr('Setează alertă & SMS', 'Set alert & SMS'),
                                                                color: item.warningAt != null
                                                                    ? Colors.orange.shade700
                                                                    : item.phoneNumber != null
                                                                        ? Colors.blue.shade600
                                                                        : null,
                                                                onPressed: () =>
                                                                    _showWarningDialog(item),
                                                              ),
                                                              _actionBtn(
                                                                icon: Icons.delete_outlined,
                                                                tooltip: tr('Șterge', 'Delete'),
                                                                color: Colors.red.shade400,
                                                                onPressed: () =>
                                                                    _confirmDelete(item),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            color: const Color(0xFFE2E8F0),
                            child: Row(
                              children: [
                                Text(
                                  rows.length == _items.length
                                      ? tr('${_items.length} înregistrări', '${_items.length} ${_items.length == 1 ? 'entry' : 'entries'}')
                                      : tr('${rows.length} din ${_items.length} înregistrări', '${rows.length} of ${_items.length} ${_items.length == 1 ? 'entry' : 'entries'}'),
                                  style: TextStyle(
                                      color: Colors.grey.shade600,
                                      fontSize: 12),
                                ),
                                if (Platform.isAndroid && !LicenseService.isLicensed) ...[
                                  const SizedBox(width: 8),
                                  Icon(
                                    LicenseService.isTrialActive
                                        ? Icons.lock_open_outlined
                                        : Icons.lock_outline,
                                    size: 12,
                                    color: LicenseService.isTrialActive
                                        ? Colors.orange.shade600
                                        : Colors.red.shade600,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    LicenseService.isTrialActive
                                        ? tr('Trial · ${LicenseService.trialDaysLeft} zile', 'Trial · ${LicenseService.trialDaysLeft} days')
                                        : tr('Trial expirat', 'Trial expired'),
                                    style: TextStyle(
                                        color: LicenseService.isTrialActive
                                            ? Colors.orange.shade700
                                            : Colors.red.shade700,
                                        fontSize: 11),
                                  ),
                                ],
                                if (SyncService.isActive) ...[
                                  const SizedBox(width: 8),
                                  Icon(Icons.sync,
                                      size: 12,
                                      color: Colors.green.shade600),
                                  const SizedBox(width: 3),
                                  Text(
                                    tr('Sincronizat', 'Synced'),
                                    style: TextStyle(
                                        color: Colors.green.shade600,
                                        fontSize: 11),
                                  ),
                                ],
                                // Ocupă spațiul rămas, aliniată la dreapta; pe ecrane
                                // înguste se trunchiază în loc să depășească rândul.
                                if (_appVersion.isNotEmpty)
                                  Expanded(
                                    child: Text(
                                      'v$_appVersion',
                                      textAlign: TextAlign.right,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: Colors.grey.shade500,
                                          fontSize: 11),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Row(
            children: [
              _bottomBtn(
                icon: Icons.add_circle_rounded,
                label: tr('Adaugă', 'Add'),
                onTap: () => _showItemDialog(),
                primary: true,
              ),
              const SizedBox(width: 10),
              _bottomBtn(
                icon: Icons.bar_chart_rounded,
                label: tr('Raport', 'Report'),
                onTap: _showReportDialog,
              ),
              const SizedBox(width: 10),
              _bottomBtn(
                icon: Icons.edit_note_rounded,
                label: tr('Mesaj SMS', 'SMS message'),
                onTap: _showSmsTemplateDialog,
              ),
              const SizedBox(width: 10),
              _bottomBtn(
                icon: Icons.design_services_outlined,
                label: tr('Servicii', 'Services'),
                onTap: _openServices,
                primary: _spatiereActiva,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool primary = false,
  }) {
    const bg      = Color(0xFF1E1B4B);
    const bgLight = Color(0xFFF1F5F9);
    return Expanded(
      child: Material(
        color: primary ? bg : bgLight,
        borderRadius: BorderRadius.circular(14),
        elevation: primary ? 3 : 0,
        shadowColor: primary
            ? const Color(0xFF1E1B4B).withValues(alpha: 0.35)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 22, color: primary ? Colors.white : bg),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: primary ? Colors.white : bg,
                    letterSpacing: 0.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Dialog raport ────────────────────────────────────────────────────────────
  Future<void> _showReportDialog() async {
    DateTime? from;
    DateTime? to;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          title: Text(tr('Generează raport', 'Generate report')),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('Selectează perioada de expirare:', 'Select the expiry period:'),
                      style: TextStyle(fontSize: 13, color: Colors.grey)),
                  const SizedBox(height: 12),
                  _buildDatePickerRow(
                    label: from == null
                        ? tr('De la: nesetat', 'From: not set')
                        : tr('De la: ${_formatDateTime(from!)}', 'From: ${_formatDateTime(from!)}'),
                    hasValue: from != null,
                    icon: Icons.calendar_today,
                    onClear: () => setDs(() => from = null),
                    onPick: () async {
                      final d = await showDatePicker(
                          context: ctx,
                          initialDate: from ?? DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100));
                      if (d == null) return;
                      setDs(() => from = DateTime(d.year, d.month, d.day));
                    },
                  ),
                  const SizedBox(height: 8),
                  _buildDatePickerRow(
                    label: to == null
                        ? tr('Până la: nesetat', 'Until: not set')
                        : tr('Până la: ${_formatDateTime(to!)}', 'Until: ${_formatDateTime(to!)}'),
                    hasValue: to != null,
                    icon: Icons.calendar_today,
                    onClear: () => setDs(() => to = null),
                    onPick: () async {
                      final d = await showDatePicker(
                          context: ctx,
                          initialDate: to ?? DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100));
                      if (d == null) return;
                      setDs(() => to =
                          DateTime(d.year, d.month, d.day, 23, 59, 59));
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Anulează', 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _showReportResult(from, to);
              },
              child: Text(tr('Generează', 'Generate')),
            ),
          ],
        ),
      ),
    );
  }

  void _showReportResult(DateTime? from, DateTime? to) {
    bool matchPeriod(DateTime? expiresAt) {
      // Fără filtru de perioadă → toate înregistrările, inclusiv cele
      // fără dată de expirare setată.
      if (from == null && to == null) return true;
      if (expiresAt == null) return false;
      if (from != null && expiresAt.isBefore(from)) return false;
      if (to   != null && expiresAt.isAfter(to))   return false;
      return true;
    }

    final activeItems = _items
        .where((i) => matchPeriod(i.expiresAt))
        .map<ReportEntry>((i) => (item: i, deletedAt: null))
        .toList();

    final deletedItems = _deletedBuffer
        .where((d) => matchPeriod(d.item.expiresAt))
        .map<ReportEntry>((d) => (item: d.item, deletedAt: d.deletedAt))
        .toList();

    String buildExportText(
        List<ReportEntry> all, String period, int actCnt, int delCnt) {
      final buf = StringBuffer();
      buf.writeln('═══════════════════════════════════════');
      buf.writeln(tr('         RAPORT ORGANIZATOR', '         ORGANIZATOR REPORT'));
      buf.writeln('═══════════════════════════════════════');
      buf.writeln(tr('Perioadă : $period', 'Period   : $period'));
      buf.writeln(tr('Total    : ${all.length} înregistrări', 'Total    : ${all.length} ${all.length == 1 ? 'entry' : 'entries'}'));
      buf.writeln('  Active : $actCnt');
      buf.writeln(tr('  Șterse : $delCnt', '  Deleted: $delCnt'));
      buf.writeln('───────────────────────────────────────');
      for (final e in all) {
        buf.writeln('');
        final del = e.deletedAt != null ? tr(' [ȘTERS]', ' [DELETED]') : '';
        buf.writeln('• ${e.item.name}$del');
        buf.writeln(tr('  Expiră  : ${e.item.expiresAt != null ? _formatDateTime(e.item.expiresAt!) : "nesetată"}', '  Expires : ${e.item.expiresAt != null ? _formatDateTime(e.item.expiresAt!) : "not set"}'));
        if (e.deletedAt != null) {
          buf.writeln(tr('  Șters la: ${_formatDateTime(e.deletedAt!)}', '  Deleted : ${_formatDateTime(e.deletedAt!)}'));
        }
        if (e.item.service != null) {
          buf.writeln(tr('  Serviciu: ${e.item.service}', '  Service: ${e.item.service}'));
        }
        if (e.item.description.isNotEmpty) {
          buf.writeln(tr('  Descriere: ${e.item.description}', '  Description: ${e.item.description}'));
        }
      }
      buf.writeln('');
      buf.writeln('═══════════════════════════════════════');
      buf.writeln(tr('Generat la: ${_formatDateTime(DateTime.now())}', 'Generated: ${_formatDateTime(DateTime.now())}'));
      return buf.toString();
    }

    final all = <ReportEntry>[...activeItems, ...deletedItems]
      ..sort((a, b) {
        final ea = a.item.expiresAt;
        final eb = b.item.expiresAt;
        if (ea == null && eb == null) return 0;
        if (ea == null) return 1;
        if (eb == null) return -1;
        return ea.compareTo(eb);
      });

    final period = (from != null || to != null)
        ? '${from != null ? _formatDateTime(from) : "—"}  →  ${to != null ? _formatDateTime(to) : "—"}'
        : tr('Toate înregistrările', 'All entries');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Raport programări', 'Appointments report')),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('Perioadă: $period', 'Period: $period'),
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 2),
              RichText(
                text: TextSpan(
                  style: const TextStyle(fontSize: 12, color: Colors.black87),
                  children: [
                    TextSpan(
                        text: '${all.length} total  ',
                        style:
                            const TextStyle(fontWeight: FontWeight.w600)),
                    TextSpan(
                        text: '(${activeItems.length} active',
                        style: const TextStyle(color: Colors.green)),
                    const TextSpan(text: '  +  '),
                    TextSpan(
                        text:
                            tr('${deletedItems.length} șterse din buffer)', '${deletedItems.length} deleted, from the buffer)'),
                        style:
                            TextStyle(color: Colors.red.shade700)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (all.isEmpty)
                Text(tr('Nu există înregistrări în această perioadă.', 'There are no entries in this period.'))
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 400),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: all.length,
                    separatorBuilder: (a, b) =>
                        const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final entry     = all[i];
                      final item      = entry.item;
                      final isDeleted = entry.deletedAt != null;
                      final exp       = _isExpired(item);

                      return Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            Container(
                              width: 8, height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isDeleted
                                    ? Colors.grey
                                    : exp
                                        ? Colors.red
                                        : Colors.green,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          item.name,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                            color: isDeleted
                                                ? Colors.grey
                                                : Colors.black87,
                                            decoration: isDeleted
                                                ? TextDecoration.lineThrough
                                                : null,
                                          ),
                                        ),
                                      ),
                                      if (isDeleted)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: Colors.grey.shade200,
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            tr('ȘTERS', 'DELETED'),
                                            style: TextStyle(
                                                fontSize: 10,
                                                color: Colors.grey.shade600,
                                                fontWeight:
                                                    FontWeight.w600),
                                          ),
                                        ),
                                    ],
                                  ),
                                  Text(
                                    item.expiresAt != null
                                        ? tr('Expiră: ${_formatDateTime(item.expiresAt!)}', 'Expires: ${_formatDateTime(item.expiresAt!)}')
                                        : tr('Fără dată de expirare', 'No expiry date'),
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: isDeleted
                                            ? Colors.grey
                                            : exp
                                                ? Colors.red.shade700
                                                : Colors.grey.shade600),
                                  ),
                                  if (isDeleted)
                                    Text(
                                      tr('Șters la: ${_formatDateTime(entry.deletedAt!)}', 'Deleted: ${_formatDateTime(entry.deletedAt!)}'),
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey.shade500),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.share_outlined, size: 18),
            label: const Text('Share'),
            onPressed: () {
              final text = buildExportText(
                  all, period, activeItems.length, deletedItems.length);
              Share.share(text, subject: tr('Raport Organizator', 'Organizator report'));
            },
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Închide', 'Close')),
          ),
        ],
      ),
    );
  }

  // Template-ul e comun tuturor tabelelor — reminderele deja programate pe
  // fiecare tabel (nu doar pe cel activ) se refac cu textul nou.
  Future<void> _rescheduleSmsAllBoards(String template) async {
    final prefs = await SharedPreferences.getInstance();
    for (var boardIndex = 0; boardIndex < _boards.length; boardIndex++) {
      final boardId = _boards[boardIndex].id;
      final List<Item> items;
      if (boardId == _activeBoardId) {
        items = _items;
      } else {
        final jsonStr = prefs.getString(_itemsKeyFor(boardId));
        if (jsonStr == null) continue;
        try {
          items = (jsonDecode(jsonStr) as List<dynamic>)
              .map((e) => Item.fromJson(e as Map<String, dynamic>))
              .toList();
        } catch (_) {
          continue;
        }
      }
      for (final item in items) {
        if (item.phones.isEmpty) continue;
        await SmsService.scheduleFor(item,
            template: template, boardIndex: boardIndex);
      }
    }
  }

  // ── Dialog limba aplicației ──────────────────────────────────────────────────
  // Limba aleasă se aplică interfeței, notificărilor, botului SMS și
  // mesajelor trimise clienților de pe acest telefon.
  Future<void> _showLanguageDialog() async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('Limba aplicației', 'App language')),
        children: [
          for (final (code, name) in const [('ro', 'Română'), ('en', 'English')])
            ListTile(
              leading: Icon(
                AppLang.code.value == code
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              title: Text(name),
              onTap: () => Navigator.pop(ctx, code),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              tr('Botul SMS și mesajele către clienți folosesc limba aleasă aici. '
                      'Botul înțelege mereu comenzile în ambele limbi.',
                  'The SMS bot and the messages to clients use the language chosen here. '
                      'The bot always understands commands in both languages.'),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ),
        ],
      ),
    );
    if (chosen == null || chosen == AppLang.code.value) return;
    await AppLang.set(chosen);
  }

  // ── Dialog editare template SMS ───────────────────────────────────────────────
  Future<void> _showSmsTemplateDialog() async {
    final ctrl = TextEditingController(text: _smsTemplate);

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Editează mesaj SMS', 'Edit SMS message')),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('Variabile disponibile:', 'Available variables:'),
                  style: TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13),
                ),
                const SizedBox(height: 4),
                _templateChip(tr('[NUME]', '[NAME]'), tr('Numele înregistrării', 'The name of the entry')),
                _templateChip(tr('[DATA_EXPIRARE]', '[EXPIRY_DATE]'), tr('Data și ora expirării', 'The expiry date and time')),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  maxLines: 5,
                  decoration: InputDecoration(
                    labelText: tr('Template mesaj', 'Message template'),
                    border: OutlineInputBorder(),
                    helperText:
                        tr('La trimitere, variabilele sunt înlocuite automat.', 'When the message is sent, the variables are replaced automatically.'),
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  icon: const Icon(Icons.restart_alt, size: 16),
                  label: Text(tr('Resetează la implicit', 'Reset to default')),
                  onPressed: () => ctrl.text = _defaultSmsTemplate,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Anulează', 'Cancel')),
          ),
          FilledButton(
            onPressed: () async {
              final tmpl = ctrl.text.trim();
              if (tmpl.isEmpty) return;
              setState(() => _smsTemplate = tmpl);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString(_kSmsTemplateKey, tmpl);
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              await _rescheduleSmsAllBoards(tmpl);
            },
            child: Text(tr('Salvează', 'Save')),
          ),
        ],
      ),
    );
  }

  Widget _phoneField(
      TextEditingController ctrl, String label, StateSetter setDs) {
    return TextField(
      controller: ctrl,
      keyboardType: TextInputType.phone,
      onChanged: (_) => setDs(() {}),
      decoration: InputDecoration(
        labelText: label,
        hintText: '+40712345678',
        border: const OutlineInputBorder(),
        prefixIcon: const Icon(Icons.phone_outlined, size: 18),
        isDense: true,
      ),
    );
  }

  Widget _templateChip(String tag, String desc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFEEF2FF),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xFFC7D2FE)),
            ),
            child: Text(tag,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Color(0xFF3730A3))),
          ),
          const SizedBox(width: 8),
          // Flexible: pe ecrane înguste descrierea se rupe pe rând nou în loc
          // să depășească dialogul.
          Flexible(
            child: Text(desc,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ],
      ),
    );
  }
}
