import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n.dart';

// ─── Servicii (per tabel) ─────────────────────────────────────────────────────
// Fiecare tabel e o categorie (ex. „Unghii”) cu propriile servicii, fiecare cu
// durata lui. Botul SMS le oferă clientului și calculează orele libere după
// durata serviciului ales (ServicesStore.kt citește aceeași cheie).

String servicesKeyFor(String boardId) => 'services_$boardId';

// Fiecare serviciu ajunge în SMS-ul botului — lista și numele rămân scurte.
const kMaxServices = 15;
const kMaxServiceNameLength = 30;
const kMinServiceDuration = 5;
const kMaxServiceDuration = 12 * 60;

// Mesajul de sincronizare al listei de servicii a unui tabel (înlocuiește
// lista partenerului): ORG:V:{"d":<durata implicită>,"s":[{"n":..,"m":..}]}.
const kServicesSyncPrefix = 'ORG:V:';

class SalonService {
  final String name;
  final int durationMin;

  const SalonService({required this.name, required this.durationMin});

  Map<String, dynamic> toJson() => {'n': name, 'm': durationMin};

  static SalonService? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = (j['n'] as String?)?.trim() ?? '';
    final m = j['m'];
    if (name.isEmpty || m is! int || !isValidServiceDuration(m)) return null;
    return SalonService(name: name, durationMin: m);
  }

  @override
  bool operator ==(Object other) =>
      other is SalonService &&
      other.name == name &&
      other.durationMin == durationMin;

  @override
  int get hashCode => Object.hash(name, durationMin);
}

bool isValidServiceDuration(int m) =>
    m >= kMinServiceDuration && m <= kMaxServiceDuration;

List<SalonService> decodeServices(Object? raw) {
  if (raw is! List) return [];
  return raw
      .map(SalonService.fromJson)
      .whereType<SalonService>()
      .take(kMaxServices)
      .toList();
}

List<SalonService> loadServices(SharedPreferences prefs, String boardId) {
  final raw = prefs.getString(servicesKeyFor(boardId));
  if (raw == null) return [];
  try {
    return decodeServices(jsonDecode(raw));
  } catch (_) {
    return [];
  }
}

Future<void> saveServices(
    SharedPreferences prefs, String boardId, List<SalonService> services) =>
    prefs.setString(servicesKeyFor(boardId),
        jsonEncode(services.map((s) => s.toJson()).toList()));

String servicesSyncMessage(int defaultMin, List<SalonService> services) =>
    '$kServicesSyncPrefix${jsonEncode({
      'd': defaultMin,
      's': services.map((s) => s.toJson()).toList(),
    })}';

typedef ServicesSync = ({int defaultMin, List<SalonService> services});

ServicesSync? parseServicesSyncMessage(String msg) {
  if (!msg.startsWith(kServicesSyncPrefix)) return null;
  try {
    final j = jsonDecode(msg.substring(kServicesSyncPrefix.length));
    if (j is! Map) return null;
    final d = j['d'];
    if (d is! int || !isValidServiceDuration(d)) return null;
    return (defaultMin: d, services: decodeServices(j['s']));
  } catch (_) {
    return null;
  }
}

/// „90” → „1h 30min”, „60” → „1 oră”, „45” → „45 min”.
String formatServiceDuration(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (m == 0) return tr('$h ${h == 1 ? "oră" : "ore"}', '$h ${h == 1 ? "hour" : "hours"}');
  return '${h}h ${m}min';
}

String _normName(String s) => s.trim().toLowerCase();

// ─── Ecranul „Servicii” ───────────────────────────────────────────────────────

/// Ce s-a ales în ecran: lista (dacă s-a schimbat) și afișarea orelor libere.
class ServicesResult {
  final int defaultMin;
  final List<SalonService> services;
  final bool changed;
  // null = neschimbat; altfel durata cu care se afișează orele libere
  // (0 = ascunde rândurile libere).
  final int? freeSlotsDuration;

  const ServicesResult({
    required this.defaultMin,
    required this.services,
    required this.changed,
    this.freeSlotsDuration,
  });
}

class ServicesScreen extends StatefulWidget {
  final String boardName;
  final int defaultMin;
  final List<SalonService> services;
  final bool freeSlotsActive;

  const ServicesScreen({
    super.key,
    required this.boardName,
    required this.defaultMin,
    required this.services,
    required this.freeSlotsActive,
  });

  @override
  State<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends State<ServicesScreen> {
  late int _defaultMin = widget.defaultMin;
  late final List<SalonService> _services = List.of(widget.services);

  bool get _changed =>
      _defaultMin != widget.defaultMin ||
      _services.length != widget.services.length ||
      [for (var i = 0; i < _services.length; i++) i]
          .any((i) => _services[i] != widget.services[i]);

  void _finish({int? freeSlotsDuration}) {
    Navigator.of(context).pop(ServicesResult(
      defaultMin: _defaultMin,
      services: List.unmodifiable(_services),
      changed: _changed,
      freeSlotsDuration: freeSlotsDuration,
    ));
  }

  Future<void> _editService([int? index]) async {
    final existing = index == null ? null : _services[index];
    final result = await showDialog<SalonService>(
      context: context,
      builder: (_) => _ServiceDialog(
        existing: existing,
        takenNames: {
          for (var i = 0; i < _services.length; i++)
            if (i != index) _normName(_services[i].name),
        },
      ),
    );
    if (result == null) return;
    setState(() {
      if (index == null) {
        _services.add(result);
      } else {
        _services[index] = result;
      }
    });
  }

  Future<void> _deleteService(int index) async {
    final s = _services[index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Ștergi serviciul?', 'Delete the service?')),
        content: Text(tr('„${s.name}” nu va mai fi oferit clienților prin SMS. '
            'Programările existente nu se modifică.',
        '“${s.name}” will no longer be offered to clients by SMS. '
        'Existing appointments are not changed.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Anulează', 'Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Șterge', 'Delete'))),
        ],
      ),
    );
    if (ok == true) setState(() => _services.removeAt(index));
  }

  Future<void> _editDefault() async {
    final v = await showDialog<int>(
      context: context,
      builder: (_) => _DurationDialog(
        title: tr('Durată implicită', 'Default duration'),
        initial: _defaultMin,
      ),
    );
    if (v != null) setState(() => _defaultMin = v);
  }

  // Durata cu care se afișează rândurile libere în tabel.
  Future<void> _showFreeSlots() async {
    if (_services.isEmpty) {
      _finish(freeSlotsDuration: _defaultMin);
      return;
    }
    final d = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('Ore libere pentru', 'Free times for')),
        children: [
          for (final s in _services)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, s.durationMin),
              child: Text('${s.name} (${formatServiceDuration(s.durationMin)})'),
            ),
        ],
      ),
    );
    if (d != null) _finish(freeSlotsDuration: d);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<ServicesResult>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr('Servicii – ${widget.boardName}', 'Services – ${widget.boardName}')),
          leading: BackButton(onPressed: _finish),
        ),
        floatingActionButton: _services.length >= kMaxServices
            ? null
            : FloatingActionButton.extended(
                onPressed: () => _editService(),
                icon: const Icon(Icons.add),
                label: Text(tr('Adaugă serviciu', 'Add service')),
              ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
          children: [
            Text(
              tr('Clientul scrie „liber ${widget.boardName.toLowerCase()}” și '
              'primește lista de mai jos. După ce alege serviciul, primește '
              'orele libere calculate cu durata lui.',
              'The client texts “free ${widget.boardName.toLowerCase()}” and '
              'receives the list below. After choosing the service, they receive '
              'the free times calculated with its duration.'),
              style: const TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: Text(tr('Durată implicită', 'Default duration')),
                subtitle: Text(
                    tr('Pentru programările fără serviciu și când tabelul nu '
                    'are servicii.',
                    'For appointments without a service and when the table has '
                    'no services.')),
                trailing: Text(formatServiceDuration(_defaultMin),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                onTap: _editDefault,
              ),
            ),
            const SizedBox(height: 12),
            if (_services.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  tr('Niciun serviciu. Adaugă serviciile acestui tabel '
                  '(ex. Semipermanentă – 1 oră).',
                  'No services. Add the services of this table '
                  '(e.g. Gel polish – 1 hour).'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black54),
                ),
              )
            else
              ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                onReorder: (from, to) => setState(() {
                  if (to > from) to--;
                  _services.insert(to, _services.removeAt(from));
                }),
                children: [
                  for (var i = 0; i < _services.length; i++)
                    Card(
                      key: ValueKey('svc_${_services[i].name}'),
                      child: ListTile(
                        leading: ReorderableDragStartListener(
                          index: i,
                          child: CircleAvatar(
                            radius: 14,
                            child: Text('${i + 1}',
                                style: const TextStyle(fontSize: 12)),
                          ),
                        ),
                        title: Text(_services[i].name),
                        subtitle: Text(
                            formatServiceDuration(_services[i].durationMin)),
                        onTap: () => _editService(i),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: tr('Șterge', 'Delete'),
                          onPressed: () => _deleteService(i),
                        ),
                      ),
                    ),
                ],
              ),
            if (_services.length > 1)
              Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  tr('Ține apăsat pe număr și trage pentru a schimba ordinea.', 'Press and hold the number and drag to change the order.'),
                  style: TextStyle(fontSize: 11, color: Colors.black45),
                ),
              ),
            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 8),
            if (widget.freeSlotsActive)
              OutlinedButton.icon(
                onPressed: () => _finish(freeSlotsDuration: 0),
                icon: const Icon(Icons.unfold_less_rounded),
                label: Text(tr('Ascunde orele libere din tabel', 'Hide free times in the table')),
              )
            else
              OutlinedButton.icon(
                onPressed: _showFreeSlots,
                icon: const Icon(Icons.unfold_more_rounded),
                label: Text(tr('Arată orele libere în tabel', 'Show free times in the table')),
              ),
          ],
        ),
      ),
    );
  }
}

const _durationPresets = [15, 30, 45, 60, 90, 120];

// Câmpurile de durată (ore + minute) cu prescurtări — comune dialogurilor.
class _DurationPicker extends StatelessWidget {
  final TextEditingController hours;
  final TextEditingController minutes;
  final VoidCallback onChanged;

  const _DurationPicker(
      {required this.hours, required this.minutes, required this.onChanged});

  int? get value => _readDuration(hours, minutes);

  @override
  Widget build(BuildContext context) {
    final current = value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final p in _durationPresets)
              ChoiceChip(
                label: Text(formatServiceDuration(p)),
                selected: current == p,
                onSelected: (_) {
                  hours.text = '${p ~/ 60}';
                  minutes.text = '${p % 60}';
                  onChanged();
                },
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: hours,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: tr('Ore', 'Hours'), border: OutlineInputBorder()),
                onChanged: (_) => onChanged(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: minutes,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: tr('Minute', 'Minutes'), border: OutlineInputBorder()),
                onChanged: (_) => onChanged(),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

int? _readDuration(TextEditingController h, TextEditingController m) {
  final hv = int.tryParse(h.text.trim().isEmpty ? '0' : h.text.trim());
  final mv = int.tryParse(m.text.trim().isEmpty ? '0' : m.text.trim());
  if (hv == null || mv == null || hv < 0 || mv < 0) return null;
  final total = hv * 60 + mv;
  return isValidServiceDuration(total) ? total : null;
}

String get _durationError =>
    tr('Durata trebuie să fie între $kMinServiceDuration minute și '
    '${kMaxServiceDuration ~/ 60} ore.',
    'The duration must be between $kMinServiceDuration minutes and '
    '${kMaxServiceDuration ~/ 60} hours.');

class _ServiceDialog extends StatefulWidget {
  final SalonService? existing;
  final Set<String> takenNames;

  const _ServiceDialog({required this.existing, required this.takenNames});

  @override
  State<_ServiceDialog> createState() => _ServiceDialogState();
}

class _ServiceDialogState extends State<_ServiceDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _hours = TextEditingController(
      text: '${(widget.existing?.durationMin ?? 60) ~/ 60}');
  late final _minutes = TextEditingController(
      text: '${(widget.existing?.durationMin ?? 60) % 60}');
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _hours.dispose();
    _minutes.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final duration = _readDuration(_hours, _minutes);
    String? error;
    if (name.isEmpty) {
      error = tr('Scrie numele serviciului.', 'Enter the service name.');
    } else if (widget.takenNames.contains(_normName(name))) {
      error = tr('Există deja un serviciu cu acest nume.', 'A service with this name already exists.');
    } else if (duration == null) {
      error = _durationError;
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, SalonService(name: name, durationMin: duration!));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? tr('Serviciu nou', 'New service') : tr('Editează serviciul', 'Edit service')),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autofocus: widget.existing == null,
                maxLength: kMaxServiceNameLength,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                    labelText: tr('Nume serviciu (ex. Semipermanentă)', 'Service name (e.g. Gel polish)'),
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 4),
              Text(tr('Durată', 'Duration'), style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              _DurationPicker(
                  hours: _hours,
                  minutes: _minutes,
                  onChanged: () => setState(() => _error = null)),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_error!,
                      style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Anulează', 'Cancel'))),
        FilledButton(onPressed: _save, child: Text(tr('Salvează', 'Save'))),
      ],
    );
  }
}

class _DurationDialog extends StatefulWidget {
  final String title;
  final int initial;

  const _DurationDialog({required this.title, required this.initial});

  @override
  State<_DurationDialog> createState() => _DurationDialogState();
}

class _DurationDialogState extends State<_DurationDialog> {
  late final _hours = TextEditingController(text: '${widget.initial ~/ 60}');
  late final _minutes = TextEditingController(text: '${widget.initial % 60}');
  String? _error;

  @override
  void dispose() {
    _hours.dispose();
    _minutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DurationPicker(
                hours: _hours,
                minutes: _minutes,
                onChanged: () => setState(() => _error = null)),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_error!,
                    style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Anulează', 'Cancel'))),
        FilledButton(
          onPressed: () {
            final d = _readDuration(_hours, _minutes);
            if (d == null) {
              setState(() => _error = _durationError);
              return;
            }
            Navigator.pop(context, d);
          },
          child: Text(tr('Salvează', 'Save')),
        ),
      ],
    );
  }
}
