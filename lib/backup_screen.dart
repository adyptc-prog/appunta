import 'package:flutter/material.dart';

import 'backup_service.dart';
import 'l10n.dart';

// ─── Ecran backup & restaurare ────────────────────────────────────────────────
class BackupScreen extends StatefulWidget {
  // Apelat înainte de restaurare (oprește scrierile din fundal) și după
  // (reîncarcă toate datele din aplicație). onRestored primește true dacă
  // restaurarea a reușit.
  final Future<void> Function()? onBeforeRestore;
  final Future<void> Function(bool success)? onRestored;

  const BackupScreen({super.key, this.onBeforeRestore, this.onRestored});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  static const _indigo = Color(0xFF1E1B4B);

  BackupStatus _status = const BackupStatus();
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    _run(_loadStatus);
  }

  Future<void> _loadStatus() async {
    _status = await BackupService.getStatus();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on BackupCancelled {
      // selector închis — nimic de raportat
    } catch (e) {
      _setMessage(e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setMessage(String text, {bool error = false}) {
    _message = text;
    _messageIsError = error;
  }

  static String _formatDate(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  Future<void> _pickFolder(String destination) => _run(() async {
        _status = await BackupService.pickFolder(destination);
        _setMessage(tr('Folderul de backup a fost setat.', 'The backup folder has been set.'));
      });

  Future<void> _create() => _run(() async {
        final b = await BackupService.createBackup();
        await _loadStatus();
        _setMessage(tr('Backup creat: ${b.name}', 'Backup created: ${b.name}'));
      });

  // Confirmare + alegerea partenerilor de sincronizare; întoarce null la anulare.
  Future<bool?> _confirmRestore(String source) {
    var keepPartners = true;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          title: Text(tr('Restaurezi backup-ul?', 'Restore the backup?')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('Toate datele actuale din aplicație vor fi înlocuite cu cele '
                  'din $source.',
              'All current data in the app will be replaced with the data '
              'from $source.')),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: keepPartners,
                onChanged: (v) => setDs(() => keepPartners = v ?? true),
                title: Text(tr('Păstrează partenerii de sincronizare actuali', 'Keep the current sync partners')),
                subtitle: Text(
                  tr('Debifează doar dacă restaurezi pe același telefon de pe care '
                  'a fost făcut backup-ul.',
                  'Untick only if you are restoring on the same phone '
                  'the backup was made on.'),
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Anulează', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, keepPartners),
              child: Text(tr('Restaurează', 'Restore')),
            ),
          ],
        ),
      ),
    );
  }

  // Parola de backup nouă (de două ori, ca să nu fie greșită la tastare).
  Future<void> _setPassword() async {
    final pw1 = TextEditingController();
    final pw2 = TextEditingController();
    String? error;
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          title: Text(_status.hasPassword
              ? tr('Schimbă parola de backup', 'Change the backup password')
              : tr('Setează parola de backup', 'Set the backup password')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr('Backup-urile sunt criptate cu această parolă. Fără ea nu pot '
                'fi restaurate pe alt telefon — păstreaz-o într-un loc sigur.',
                'Backups are encrypted with this password. Without it they cannot '
                'be restored on another phone — keep it in a safe place.'),
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pw1,
                obscureText: true,
                decoration: InputDecoration(
                    labelText: tr('Parolă', 'Password'), border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: pw2,
                obscureText: true,
                decoration: InputDecoration(
                    labelText: tr('Repetă parola', 'Repeat the password'),
                    errorText: error,
                    border: const OutlineInputBorder()),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Anulează', 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                if (pw1.text.length < BackupService.minPasswordLength) {
                  setDs(() => error =
                      tr('Minim ${BackupService.minPasswordLength} caractere.', 'At least ${BackupService.minPasswordLength} characters.'));
                } else if (pw1.text != pw2.text) {
                  setDs(() => error = tr('Parolele nu coincid.', 'The passwords do not match.'));
                } else {
                  Navigator.pop(ctx, pw1.text);
                }
              },
              child: Text(tr('Salvează', 'Save')),
            ),
          ],
        ),
      ),
    );
    if (password == null || !mounted) return;
    await _run(() async {
      _status = await BackupService.setPassword(password);
      _setMessage(tr('Parola de backup a fost salvată.', 'The backup password has been saved.'));
    });
  }

  // Parola unui backup criptat (alt telefon, sau parolă schimbată între timp).
  Future<String?> _askBackupPassword({required bool wrong}) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Parola backup-ului', 'Backup password')),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(
            labelText: tr('Parolă', 'Password'),
            errorText: wrong ? tr('Parolă greșită. Încearcă din nou.', 'Wrong password. Try again.') : null,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Anulează', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: Text(tr('Deschide', 'Open')),
          ),
        ],
      ),
    );
  }

  // [restore] primește parola introdusă (null la prima încercare — se
  // folosește parola salvată pe telefon).
  Future<void> _restore(String source,
      Future<void> Function(bool keepPartners, String? password) restore) async {
    final keepPartners = await _confirmRestore(source);
    if (keepPartners == null || !mounted) return;
    await _run(() async {
      await widget.onBeforeRestore?.call();
      var ok = false;
      try {
        String? password;
        while (true) {
          try {
            await restore(keepPartners, password);
            break;
          } on BackupPasswordNeeded catch (e) {
            if (!mounted) throw const BackupCancelled();
            // Fără indicator de lucru cât timp așteptăm parola.
            setState(() => _busy = false);
            password = await _askBackupPassword(wrong: e.wrong);
            if (password == null) throw const BackupCancelled();
            if (mounted) setState(() => _busy = true);
          }
        }
        ok = true;
      } finally {
        await widget.onRestored?.call(ok);
      }
      await _loadStatus();
      _setMessage(tr('Backup restaurat. Datele au fost reîncărcate.', 'Backup restored. The data has been reloaded.'));
    });
  }

  Future<void> _restoreFromFolder() async {
    List<BackupEntry>? backups;
    await _run(() async => backups = await BackupService.listBackups());
    if (!mounted || backups == null) return; // eroarea e deja afișată
    if (backups!.isEmpty) {
      setState(() => _setMessage(tr('Nu există backup-uri în folderul ales.', 'There are no backups in the chosen folder.')));
      return;
    }
    final chosen = await showDialog<BackupEntry>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('Alege backup-ul', 'Choose the backup')),
        children: [
          for (final b in backups!)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, b),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(b.auto ? Icons.schedule : Icons.save_outlined),
                title: Text(_formatDate(b.modifiedAt)),
                subtitle: Text(
                    tr('${b.auto ? 'Automat' : 'Manual'} · ${(b.size / 1024).toStringAsFixed(1)} KB', '${b.auto ? 'Automatic' : 'Manual'} · ${(b.size / 1024).toStringAsFixed(1)} KB')),
              ),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    await _restore(
      tr('backup-ul din ${_formatDate(chosen.modifiedAt)}', 'the backup from ${_formatDate(chosen.modifiedAt)}'),
      (keep, password) => BackupService.restoreBackup(chosen.id,
          keepSyncPartners: keep, password: password),
    );
  }

  Future<void> _restoreFromFile() => _restore(
        tr('fișierul pe care îl vei alege', 'the file you choose'),
        (keep, password) => password == null
            ? BackupService.pickAndRestoreBackup(keepSyncPartners: keep)
            : BackupService.retryPickedRestore(
                keepSyncPartners: keep, password: password),
      );

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final folderOk = s.hasFolder && s.folderAccessible;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Backup & restaurare', 'Backup & restore')),
        backgroundColor: _indigo,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(tr('Destinație backup', 'Backup destination'),
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(
                  value: 'usb', icon: Icon(Icons.usb), label: Text(tr('Stick USB', 'USB stick'))),
              ButtonSegment(
                  value: 'phone',
                  icon: Icon(Icons.phone_android),
                  label: Text(tr('Memoria telefonului', 'Phone storage'))),
            ],
            emptySelectionAllowed: true,
            selected: {if (s.destination != null) s.destination!},
            onSelectionChanged: _busy
                ? null
                : (sel) => sel.isEmpty
                    ? _pickFolder(s.destination ?? 'phone')
                    : _pickFolder(sel.first),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: Icon(
                folderOk ? Icons.folder : Icons.folder_off_outlined,
                color: folderOk ? _indigo : Colors.orange.shade800,
              ),
              title: Text(!s.hasFolder
                  ? tr('Niciun folder ales', 'No folder chosen')
                  : folderOk
                      ? s.folderName!
                      : tr('Folderul nu este accesibil', 'The folder is not accessible')),
              subtitle: Text(!s.hasFolder
                  ? tr('Alege destinația de mai sus.', 'Choose the destination above.')
                  : folderOk
                      ? tr('Backup automat zilnic, în jurul orei 00:00.', 'Automatic daily backup, around 00:00.')
                      : tr('Conectează stick-ul sau alege din nou folderul.', 'Connect the stick or choose the folder again.')),
              trailing: s.hasFolder
                  ? IconButton(
                      tooltip: tr('Schimbă folderul', 'Change folder'),
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: _busy
                          ? null
                          : () => _pickFolder(s.destination ?? 'phone'),
                    )
                  : null,
            ),
          ),
          if (s.hasFolder)
            Card(
              child: ListTile(
                leading: Icon(
                  s.lastAutoError != null
                      ? Icons.error_outline
                      : Icons.schedule,
                  color: s.lastAutoError != null ? Colors.red.shade700 : null,
                ),
                title: Text(s.lastAutoAt != null
                    ? tr('Ultimul backup automat: ${_formatDate(s.lastAutoAt!)}', 'Last automatic backup: ${_formatDate(s.lastAutoAt!)}')
                    : tr('Niciun backup automat încă', 'No automatic backup yet')),
                subtitle: s.lastAutoError != null
                    ? Text(tr('Ultima încercare a eșuat: ${s.lastAutoError}', 'The last attempt failed: ${s.lastAutoError}'),
                        style: TextStyle(color: Colors.red.shade700))
                    : s.lastManualAt != null
                        ? Text(tr('Ultimul backup manual: ${_formatDate(s.lastManualAt!)}', 'Last manual backup: ${_formatDate(s.lastManualAt!)}'))
                        : null,
              ),
            ),
          Card(
            color: s.hasPassword ? null : Colors.orange.shade50,
            child: ListTile(
              leading: Icon(
                s.hasPassword ? Icons.lock_outline : Icons.lock_open,
                color: s.hasPassword ? _indigo : Colors.orange.shade800,
              ),
              title: Text(s.hasPassword
                  ? tr('Backup-urile sunt criptate cu parolă', 'Backups are encrypted with a password')
                  : tr('Parola de backup nu e setată', 'The backup password is not set')),
              subtitle: Text(s.hasPassword
                  ? tr('Parola se cere la restaurarea pe alt telefon.', 'The password is required when restoring on another phone.')
                  : tr('Fără parolă nu se face niciun backup (nici automat).', 'Without a password no backup is made (not even automatic ones).')),
              trailing: TextButton(
                onPressed: _busy ? null : _setPassword,
                child: Text(s.hasPassword ? tr('Schimbă', 'Change') : tr('Setează', 'Set')),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.backup),
            label: Text(tr('Creează backup acum', 'Create backup now')),
            onPressed: _busy || !folderOk || !s.hasPassword ? null : _create,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.restore),
            label: Text(tr('Restaurează din folderul de backup', 'Restore from the backup folder')),
            onPressed: _busy || !folderOk ? null : _restoreFromFolder,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.file_open_outlined),
            label: Text(tr('Restaurează din alt fișier', 'Restore from another file')),
            onPressed: _busy ? null : _restoreFromFile,
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_message != null) ...[
            const SizedBox(height: 16),
            Card(
              color: _messageIsError ? Colors.red.shade50 : Colors.green.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: _messageIsError
                          ? Colors.red.shade800
                          : Colors.green.shade800),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Card(
            color: const Color(0xFFEEF2FF),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                tr('Backup-ul conține toate tabelele, setările și codul de '
                'instalare împreună cu licența — după restaurare pe un telefon '
                'nou, licența funcționează în continuare.\n\n'
                'Fișierele sunt criptate (AES-256): fără parolă, datele '
                'clienților nu pot fi citite de pe stick sau din telefon.\n\n'
                'Se păstrează ultimele 14 backup-uri automate; cele manuale '
                'nu se șterg niciodată automat.',
                'The backup contains all tables, settings and the installation '
                'code together with the license — after restoring on a new '
                'phone, the license keeps working.\n\n'
                'The files are encrypted (AES-256): without the password, client '
                'data cannot be read from the stick or the phone.\n\n'
                'The last 14 automatic backups are kept; manual ones '
                'are never deleted automatically.'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
