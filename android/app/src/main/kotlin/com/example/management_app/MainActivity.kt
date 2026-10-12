package com.example.management_app

import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {

    companion object {
        const val SMS_CHANNEL     = "organizator/sms"
        const val LICENSE_CHANNEL = "organizator/license"
        const val BACKUP_CHANNEL  = "organizator/backup"
        private const val PICK_LICENSE_REQUEST_CODE = 8021
        private const val PICK_BACKUP_FOLDER_REQUEST_CODE = 8022
        private const val PICK_RESTORE_BACKUP_REQUEST_CODE = 8023
    }

    // Fluxul nou de licențiere (businessId + expirare, format identic cu Fidelio)
    private var pendingLicensePickResult: MethodChannel.Result? = null

    // Backup: selectoarele de folder / fișier așteaptă rezultatul activității
    private var pendingBackupFolderResult: MethodChannel.Result? = null
    private var pendingBackupDestination: String = "phone"
    private var pendingRestoreResult: MethodChannel.Result? = null
    private var pendingRestoreKeepPartners: Boolean = true
    @Volatile
    private var lastPickedRestoreUri: android.net.Uri? = null

    // ── Lifecycle ────────────────────────────────────────────────────────────────
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            PICK_BACKUP_FOLDER_REQUEST_CODE -> { handleBackupFolderResult(resultCode, data); return }
            PICK_RESTORE_BACKUP_REQUEST_CODE -> { handleRestoreResult(resultCode, data); return }
        }
        if (requestCode != PICK_LICENSE_REQUEST_CODE) return

        val result = pendingLicensePickResult ?: return
        pendingLicensePickResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.error("LICENSE_PICK_CANCELLED", tr("Nu a fost selectat niciun fișier de licență.", "No license file was selected."), null)
            return
        }

        try {
            val content = contentResolver.openInputStream(uri)?.use {
                it.reader(Charsets.UTF_8).readText()
            } ?: throw IllegalStateException(tr("Fișierul de licență nu a putut fi citit.", "Could not read license file."))
            result.success(LicenseStore.importLicense(this, content).toMap(uri.toString()))
        } catch (error: Exception) {
            result.error("LICENSE_PICK_FAILED", error.message ?: error.toString(), null)
        }
    }

    // ── Flutter Engine ───────────────────────────────────────────────────────────
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AppLang.sync(applicationContext)
        OrganizatorBackupWorker.schedule(applicationContext)

        // ── Canal Backup ──────────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BACKUP_CHANNEL)
            .setMethodCallHandler { call, result ->
                AppLang.sync(applicationContext)
                when (call.method) {
                    "getStatus" -> runInBackground(result, "BACKUP_STATUS_FAILED") {
                        BackupManager.status(this)
                    }
                    "pickFolder" -> pickBackupFolder(call.argument<String>("destination") ?: "phone", result)
                    "createBackup" -> runInBackground(result, "BACKUP_CREATE_FAILED") {
                        BackupManager.createBackup(this, auto = false)
                    }
                    "listBackups" -> runInBackground(result, "BACKUP_LIST_FAILED") {
                        BackupManager.listBackups(this)
                    }
                    "restoreBackup" -> {
                        val id = call.argument<String>("id")
                            ?: run { result.error("ARG", "missing id", null); return@setMethodCallHandler }
                        val keep = call.argument<Boolean>("keepSyncPartners") ?: true
                        val password = call.argument<String>("password")
                        runInBackground(result, "BACKUP_RESTORE_FAILED") {
                            BackupManager.restoreFromDocumentId(this, id, keep, password); null
                        }
                    }
                    "pickAndRestoreBackup" -> pickAndRestoreBackup(
                        call.argument<Boolean>("keepSyncPartners") ?: true, result
                    )
                    // Fișierul ales anterior era criptat: reîncercăm cu parola,
                    // fără să-l mai cerem din nou utilizatorului.
                    "retryPickedRestore" -> {
                        val uri = lastPickedRestoreUri
                            ?: run { result.error("ARG", "no picked backup", null); return@setMethodCallHandler }
                        val keep = call.argument<Boolean>("keepSyncPartners") ?: true
                        val password = call.argument<String>("password")
                        runInBackground(result, "BACKUP_RESTORE_FAILED") {
                            BackupManager.restoreFromUri(this, uri, keep, password)
                            lastPickedRestoreUri = null
                            null
                        }
                    }
                    "setPassword" -> {
                        val password = call.argument<String>("password")
                            ?: run { result.error("ARG", "missing password", null); return@setMethodCallHandler }
                        runInBackground(result, "BACKUP_PASSWORD_INVALID") {
                            BackupPassword.set(this, password)
                            BackupManager.status(this)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Canal SMS (alarme + sincronizare) ─────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SMS_CHANNEL)
            .setMethodCallHandler { call, result ->
                AppLang.sync(applicationContext)
                when (call.method) {

                    "schedule" -> {
                        val id = call.argument<Int>("id")
                            ?: run { result.error("ARG", "missing id", null); return@setMethodCallHandler }
                        val triggerAtMs = call.argument<Long>("triggerAtMs")
                            ?: run { result.error("ARG", "missing triggerAtMs", null); return@setMethodCallHandler }
                        scheduleSmsAlarm(id, triggerAtMs)
                        result.success(null)
                    }

                    "cancel" -> {
                        val id = call.argument<Int>("id")
                            ?: run { result.error("ARG", "missing id", null); return@setMethodCallHandler }
                        cancelSmsAlarm(id)
                        result.success(null)
                    }

                    "scheduleNotif" -> {
                        val id          = call.argument<Int>("id")
                            ?: run { result.error("ARG", "missing id", null); return@setMethodCallHandler }
                        val triggerAtMs = call.argument<Long>("triggerAtMs")
                            ?: run { result.error("ARG", "missing triggerAtMs", null); return@setMethodCallHandler }
                        val title       = call.argument<String>("title") ?: "Organizator"
                        val body        = call.argument<String>("body")  ?: ""
                        scheduleNotifAlarm(id, triggerAtMs, title, body)
                        result.success(null)
                    }

                    "cancelNotif" -> {
                        val id = call.argument<Int>("id")
                            ?: run { result.error("ARG", "missing id", null); return@setMethodCallHandler }
                        cancelNotifAlarm(id)
                        result.success(null)
                    }

                    "sendSms" -> {
                        val phone = call.argument<String>("phone")
                            ?: run { result.error("ARG", "missing phone", null); return@setMethodCallHandler }
                        val message = call.argument<String>("message")
                            ?: run { result.error("ARG", "missing message", null); return@setMethodCallHandler }
                        sendSmsNow(phone, message)
                        result.success(null)
                    }

                    // Mesaj de sincronizare către partenerul unui tabel, semnat
                    // cu codul de împerechere (SyncAuth). false = fără partener
                    // sau fără cod — nu s-a trimis nimic.
                    "sendSync" -> {
                        val boardId = call.argument<String>("boardId")
                            ?: run { result.error("ARG", "missing boardId", null); return@setMethodCallHandler }
                        val message = call.argument<String>("message")
                            ?: run { result.error("ARG", "missing message", null); return@setMethodCallHandler }
                        result.success(SmsSyncReceiver.sendSigned(this, boardId, message))
                    }

                    "computeFreeSlots" -> {
                        val boardId = call.argument<String>("boardId")
                            ?: run { result.error("ARG", "missing boardId", null); return@setMethodCallHandler }
                        val horizonDays = call.argument<Int>("horizonDays") ?: 14
                        val maxResults  = call.argument<Int>("maxResults") ?: 200
                        val durationMin = call.argument<Int>("durationMin")
                        result.success(computeFreeSlotsJson(boardId, durationMin, horizonDays, maxResults))
                    }

                    "getAutostartState" -> result.success(BackgroundStart.autostartState(this))

                    "openAutostartSettings" -> result.success(BackgroundStart.openAutostartSettings(this))

                    "getSmsFailure" -> result.success(SmsStatus.pendingFailure(this))

                    "dismissSmsFailure" -> {
                        SmsStatus.dismiss(this)
                        result.success(null)
                    }

                    "getSyncMessages" -> result.success(SmsSyncReceiver.snapshot(this))

                    "ackSyncMessages" -> {
                        val ids = call.argument<List<String>>("ids") ?: emptyList()
                        SmsSyncReceiver.acknowledge(this, ids)
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }

        // ── Canal Licență ─────────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LICENSE_CHANNEL)
            .setMethodCallHandler { call, result ->
                AppLang.sync(applicationContext)
                when (call.method) {

                    // ── Flux nou: licență cu businessId + expirare, cumpărată de pe site ──
                    "getBusinessId" -> result.success(LicenseStore.getOrCreateBusinessId(this))
                    "checkLicense" -> {
                        val map = LicenseStore.check(this).toMap(null)
                        // Trial-ul, calculat cu același ceas protejat ca licența.
                        val start = Entitlement.trialStartMs(this)
                        val now = LicenseStore.effectiveNow(this)
                        map["trialActive"] = Entitlement.isTrialActive(start, now)
                        map["trialDaysLeft"] = Entitlement.trialDaysLeft(start, now)
                        result.success(map)
                    }
                    "pickLicenseFile" -> pickLicenseFile(result)
                    // Trimite licența partenerului unui tabel, dacă are voie:
                    // "sent" | "no_license" | "not_owner" | "other_partner" |
                    // "no_partner" (fără partener sau cod de împerechere).
                    "shareLicenseWithBoard" -> {
                        val boardId = call.argument<String>("boardId")
                            ?: run { result.error("ARG", "missing boardId", null); return@setMethodCallHandler }
                        result.success(shareLicenseWithBoard(boardId))
                    }
                    "getLicenseShareInfo" -> result.success(LicenseStore.shareInfo(this))
                    "consumePartnerNotice" -> result.success(LicenseStore.consumePartnerNotice(this))

                    else -> result.notImplemented()
                }
            }
    }

    private fun shareLicenseWithBoard(boardId: String): String {
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val phone = prefs.getString("flutter.sync_partner_phone_$boardId", null)?.trim().orEmpty()
        if (phone.isEmpty() || !SyncAuth.isValidCode(prefs.getString(SmsSyncReceiver.secretKey(boardId), null))) {
            return "no_partner"
        }
        val (decision, license) = LicenseStore.shareTo(this, phone)
        if (license == null) {
            return when (decision) {
                ShareDecision.NOT_OWNER -> "not_owner"
                ShareDecision.OTHER_PARTNER -> "other_partner"
                else -> "no_license"
            }
        }
        SmsSyncReceiver.sendSigned(this, boardId, SmsSyncReceiver.LICENSE_PREFIX + license)
        return "sent"
    }

    // ── Flux nou de licențiere (identic ca format cu Fidelio) ────────────────────
    // Verificarea, stocarea și preluarea de la partener sunt în LicenseStore.
    private fun pickLicenseFile(result: MethodChannel.Result) {
        if (pendingLicensePickResult != null) {
            result.error("LICENSE_PICK_BUSY", tr("Un selector de licență este deja deschis.", "A license picker is already open."), null)
            return
        }

        pendingLicensePickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/*", "application/octet-stream"))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivityForResult(intent, PICK_LICENSE_REQUEST_CODE)
    }

    // ── Backup ───────────────────────────────────────────────────────────────────
    // Operațiile pe fișiere (stick USB) nu blochează interfața.
    private fun runInBackground(result: MethodChannel.Result, errorCode: String, work: () -> Any?) {
        Thread {
            try {
                val value = work()
                runOnUiThread { result.success(value) }
            } catch (e: BackupManager.PasswordException) {
                runOnUiThread { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                runOnUiThread { result.error(errorCode, e.message ?: e.toString(), null) }
            }
        }.start()
    }

    private fun pickBackupFolder(destination: String, result: MethodChannel.Result) {
        if (pendingBackupFolderResult != null) {
            result.error("BACKUP_PICK_BUSY", tr("Un selector de folder este deja deschis.", "A backup folder picker is already open."), null)
            return
        }
        pendingBackupFolderResult = result
        pendingBackupDestination = destination
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            // Memoria telefonului: pornim din Documents, unde backup-ul
            // supraviețuiește dezinstalării aplicației.
            if (destination == "phone" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(
                    DocumentsContract.EXTRA_INITIAL_URI,
                    DocumentsContract.buildDocumentUri(
                        "com.android.externalstorage.documents", "primary:Documents"
                    )
                )
            }
        }
        startActivityForResult(intent, PICK_BACKUP_FOLDER_REQUEST_CODE)
    }

    private fun handleBackupFolderResult(resultCode: Int, data: Intent?) {
        val result = pendingBackupFolderResult ?: return
        pendingBackupFolderResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.error("BACKUP_PICK_CANCELLED", tr("Nu a fost selectat niciun folder de backup.", "No backup folder was selected."), null)
            return
        }
        runInBackground(result, "BACKUP_PICK_FAILED") {
            BackupManager.setFolder(this, uri, pendingBackupDestination)
            BackupManager.status(this)
        }
    }

    private fun pickAndRestoreBackup(keepSyncPartners: Boolean, result: MethodChannel.Result) {
        if (pendingRestoreResult != null) {
            result.error("RESTORE_PICK_BUSY", tr("Un selector de backup este deja deschis.", "A backup picker is already open."), null)
            return
        }
        pendingRestoreResult = result
        pendingRestoreKeepPartners = keepSyncPartners
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivityForResult(intent, PICK_RESTORE_BACKUP_REQUEST_CODE)
    }

    private fun handleRestoreResult(resultCode: Int, data: Intent?) {
        val result = pendingRestoreResult ?: return
        pendingRestoreResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.error("RESTORE_PICK_CANCELLED", tr("Nu a fost selectat niciun fișier de backup.", "No backup file was selected."), null)
            return
        }
        val keep = pendingRestoreKeepPartners
        lastPickedRestoreUri = uri
        runInBackground(result, "BACKUP_RESTORE_FAILED") {
            BackupManager.restoreFromUri(this, uri, keep)
            lastPickedRestoreUri = null
            null
        }
    }

    // ── Notificări push native (AlarmManager → NotifAlarmReceiver) ──────────────
    private fun scheduleNotifAlarm(id: Int, triggerAtMs: Long, title: String, body: String) {
        val data = org.json.JSONObject()
        data.put("title", title)
        data.put("body", body)
        getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit()
            .putString("flutter.notif_alarm_$id", data.toString())
            .apply()

        AlarmScheduler.scheduleNotifAlarm(this, id, triggerAtMs)
    }

    private fun cancelNotifAlarm(id: Int) = AlarmScheduler.cancelNotifAlarm(this, id)

    // ── Calcul sloturi libere (rândurile libere din tabel, alese din ecranul
    // „Servicii” — aceeași sursă de adevăr ca botul din ClientBookingReceiver).
    // [durationMin] = durata serviciului ales; null = durata implicită. ──────
    private fun computeFreeSlotsJson(boardId: String, durationMin: Int?, horizonDays: Int, maxResults: Int): String {
        return try {
            val saved = BookingSettings.loadSettings(this, boardId)
            val settings = if (durationMin != null && durationMin > 0) saved.copy(durationMin = durationMin) else saved
            val busy = BookingSettings.loadBusyIntervals(this, boardId, saved.durationMin)
            val slots = FreeSlotCalculator.compute(
                busy, settings, java.time.LocalDateTime.now(), horizonDays, maxResults
            )
            val arr = JSONArray()
            val zone = java.time.ZoneId.systemDefault()
            for (s in slots) {
                val o = JSONObject()
                o.put("s", s.start.atZone(zone).toInstant().toEpochMilli())
                o.put("e", s.end.atZone(zone).toInstant().toEpochMilli())
                arr.put(o)
            }
            arr.toString()
        } catch (e: Exception) {
            Diag.e("computeFreeSlotsJson failed for boardId=$boardId", e)
            "[]"
        }
    }

    // ── SMS imediat (multipart dacă depășește 160 caractere) ─────────────────────
    private fun sendSmsNow(phone: String, message: String) {
        SmsSender.send(this, phone, message)
    }

    // ── AlarmManager pentru SMS programate ───────────────────────────────────────
    private fun scheduleSmsAlarm(id: Int, triggerAtMs: Long) =
        AlarmScheduler.scheduleSmsAlarm(this, id, triggerAtMs)

    private fun cancelSmsAlarm(id: Int) = AlarmScheduler.cancelSmsAlarm(this, id)
}
