package com.example.management_app

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.provider.DocumentsContract
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Backup / restore al datelor Appunta (vezi BackupFormat) într-un singur
 * folder ales de utilizator prin Storage Access Framework — pe stick-ul USB
 * sau în memoria telefonului. Același folder e folosit și de backup-ul
 * automat zilnic (OrganizatorBackupWorker).
 */
object BackupManager {

    private const val PREFS_NAME = "BackupPrefs"
    private const val KEY_FOLDER_URI = "backup_folder_uri"
    private const val KEY_DESTINATION = "backup_destination" // "usb" | "phone"
    private const val KEY_LAST_AUTO_AT = "last_auto_backup_at"
    private const val KEY_LAST_AUTO_ERROR = "last_auto_backup_error"
    private const val KEY_LAST_MANUAL_AT = "last_manual_backup_at"
    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val SAFETY_FILE = "before_restore.orgbackup"

    const val AUTO_KEEP = 14

    private val ALARM_KEY = Regex("""^flutter\.(notif|sms)_alarm_(-?\d+)$""")

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun flutterPrefs(context: Context): SharedPreferences =
        context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)

    // ── Folder ───────────────────────────────────────────────────────────────────
    fun folderUri(context: Context): Uri? =
        prefs(context).getString(KEY_FOLDER_URI, null)?.let(Uri::parse)

    fun setFolder(context: Context, treeUri: Uri, destination: String) {
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        // O singură destinație: eliberăm permisiunea folderului anterior.
        folderUri(context)?.takeIf { it != treeUri }?.let { old ->
            try { context.contentResolver.releasePersistableUriPermission(old, flags) } catch (_: Exception) {}
        }
        context.contentResolver.takePersistableUriPermission(treeUri, flags)
        prefs(context).edit()
            .putString(KEY_FOLDER_URI, treeUri.toString())
            .putString(KEY_DESTINATION, destination)
            .remove(KEY_LAST_AUTO_ERROR)
            .apply()
    }

    private fun folderDocumentUri(treeUri: Uri): Uri =
        DocumentsContract.buildDocumentUriUsingTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri))

    private fun hasWriteAccess(context: Context, treeUri: Uri): Boolean =
        context.contentResolver.persistedUriPermissions.any {
            it.uri == treeUri && it.isWritePermission
        }

    private fun requireFolder(context: Context): Uri {
        val treeUri = folderUri(context)
            ?: throw IllegalStateException(tr("Nu a fost ales un folder pentru backup.", "No backup folder has been chosen."))
        if (!hasWriteAccess(context, treeUri)) {
            throw IllegalStateException(tr("Aplicația nu mai are acces la folderul de backup. Alege-l din nou.", "The app no longer has access to the backup folder. Choose it again."))
        }
        return treeUri
    }

    private fun folderName(context: Context, treeUri: Uri): String? = try {
        context.contentResolver.query(
            folderDocumentUri(treeUri),
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null,
        )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    } catch (_: Exception) {
        null
    }

    fun status(context: Context): HashMap<String, Any?> {
        val p = prefs(context)
        val treeUri = folderUri(context)
        val accessible = treeUri != null && hasWriteAccess(context, treeUri) &&
            folderName(context, treeUri) != null
        return hashMapOf(
            "folderUri" to treeUri?.toString(),
            "folderName" to if (accessible) folderName(context, treeUri!!) else null,
            "folderAccessible" to accessible,
            "destination" to p.getString(KEY_DESTINATION, null),
            "lastAutoAt" to p.getLong(KEY_LAST_AUTO_AT, 0L).takeIf { it > 0 },
            "lastAutoError" to p.getString(KEY_LAST_AUTO_ERROR, null),
            "lastManualAt" to p.getLong(KEY_LAST_MANUAL_AT, 0L).takeIf { it > 0 },
            "hasPassword" to BackupPassword.isSet(context),
        )
    }

    // ── Creare ───────────────────────────────────────────────────────────────────
    fun snapshot(context: Context, now: Long = System.currentTimeMillis()): String =
        BackupFormat.encode(flutterPrefs(context).all, LicenseStore.identity(context), now)

    fun createBackup(context: Context, auto: Boolean): HashMap<String, Any?> {
        val treeUri = requireFolder(context)
        val password = BackupPassword.get(context)
            ?: throw IllegalStateException(tr("Setează mai întâi parola de backup.", "Set the backup password first."))
        val now = System.currentTimeMillis()
        // Fișierul pleacă pe stick / în Documents — criptat (BackupCrypto).
        val content = BackupCrypto.encrypt(snapshot(context, now), password, now)
            .toByteArray(Charsets.UTF_8)
        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date(now))
        val prefix = if (auto) BackupFormat.AUTO_PREFIX else BackupFormat.MANUAL_PREFIX
        val name = "$prefix$stamp${BackupFormat.EXTENSION}"

        val docUri = DocumentsContract.createDocument(
            context.contentResolver, folderDocumentUri(treeUri), "application/octet-stream", name,
        ) ?: throw IllegalStateException(tr("Nu s-a putut crea fișierul de backup.", "The backup file could not be created."))
        try {
            context.contentResolver.openOutputStream(docUri, "w")?.use { it.write(content) }
                ?: throw IllegalStateException(tr("Nu s-a putut scrie fișierul de backup.", "The backup file could not be written."))
        } catch (e: Exception) {
            // Nu lăsăm în urmă un fișier gol/trunchiat care ar apărea în listă.
            try { DocumentsContract.deleteDocument(context.contentResolver, docUri) } catch (_: Exception) {}
            throw e
        }

        val p = prefs(context).edit()
        if (auto) {
            p.putLong(KEY_LAST_AUTO_AT, now).remove(KEY_LAST_AUTO_ERROR)
        } else {
            p.putLong(KEY_LAST_MANUAL_AT, now)
        }
        p.apply()
        if (auto) pruneAutoBackups(context, treeUri)

        return hashMapOf("id" to DocumentsContract.getDocumentId(docUri), "name" to name,
            "size" to content.size.toLong(), "modifiedAt" to now)
    }

    fun recordAutoError(context: Context, message: String) {
        prefs(context).edit().putString(KEY_LAST_AUTO_ERROR, message).apply()
    }

    private data class Entry(val id: String, val name: String, val modifiedAt: Long, val size: Long)

    private fun entries(context: Context, treeUri: Uri): List<Entry> {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri, DocumentsContract.getTreeDocumentId(treeUri),
        )
        return context.contentResolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                DocumentsContract.Document.COLUMN_SIZE,
            ), null, null, null,
        )?.use { c ->
            val list = mutableListOf<Entry>()
            while (c.moveToNext()) {
                val name = c.getString(1) ?: continue
                if (!name.endsWith(BackupFormat.EXTENSION)) continue
                list.add(Entry(c.getString(0), name, c.getLong(2), c.getLong(3)))
            }
            list
        } ?: emptyList()
    }

    private fun pruneAutoBackups(context: Context, treeUri: Uri) {
        val all = entries(context, treeUri)
        val toDelete = BackupFormat.autoBackupsToDelete(all.map { it.name }, AUTO_KEEP).toSet()
        for (e in all) {
            if (e.name !in toDelete) continue
            try {
                DocumentsContract.deleteDocument(
                    context.contentResolver,
                    DocumentsContract.buildDocumentUriUsingTree(treeUri, e.id),
                )
            } catch (_: Exception) {}
        }
    }

    fun listBackups(context: Context): List<HashMap<String, Any?>> {
        val treeUri = folderUri(context) ?: return emptyList()
        if (!hasWriteAccess(context, treeUri)) return emptyList()
        return entries(context, treeUri)
            .sortedByDescending { it.modifiedAt }
            .map {
                hashMapOf<String, Any?>("id" to it.id, "name" to it.name,
                    "modifiedAt" to it.modifiedAt, "size" to it.size,
                    "auto" to it.name.startsWith(BackupFormat.AUTO_PREFIX))
            }
    }

    // ── Restore ──────────────────────────────────────────────────────────────────
    private fun readText(context: Context, uri: Uri): String =
        context.contentResolver.openInputStream(uri)?.use { it.reader(Charsets.UTF_8).readText() }
            ?: throw IllegalStateException(tr("Nu s-a putut citi fișierul de backup.", "The backup file could not be read."))

    fun restoreFromDocumentId(
        context: Context, documentId: String, keepSyncPartners: Boolean, password: String? = null,
    ) {
        val treeUri = requireFolder(context)
        val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
        restoreContent(context, readText(context, uri), keepSyncPartners, password)
    }

    fun restoreFromUri(context: Context, uri: Uri, keepSyncPartners: Boolean, password: String? = null) =
        restoreContent(context, readText(context, uri), keepSyncPartners, password)

    /** Backup-ul cere parola (PASSWORD_REQUIRED) sau parola dată e greșită (PASSWORD_WRONG). */
    class PasswordException(val code: String, message: String) : Exception(message)

    const val PASSWORD_REQUIRED = "BACKUP_PASSWORD_REQUIRED"
    const val PASSWORD_WRONG = "BACKUP_PASSWORD_WRONG"

    /**
     * Textul backup-ului (v1) — decriptat dacă e nevoie. Încearcă întâi
     * parola dată, apoi pe cea salvată pe acest telefon. Backup-urile vechi,
     * necriptate, merg în continuare.
     */
    private fun plainBackup(context: Context, content: String, password: String?): String {
        if (!BackupCrypto.isEncrypted(content)) return content
        val candidates = listOfNotNull(password, BackupPassword.get(context)).distinct()
        for (candidate in candidates) {
            try {
                return BackupCrypto.decrypt(content, candidate)
            } catch (_: BackupCrypto.WrongPasswordException) {
            }
        }
        if (password != null) throw PasswordException(PASSWORD_WRONG, tr("Parola backup-ului este greșită.", "The backup password is wrong."))
        throw PasswordException(PASSWORD_REQUIRED, tr("Backup-ul este criptat — introdu parola lui.", "The backup is encrypted — enter its password."))
    }

    /**
     * Înlocuiește datele cu cele din backup. Ordinea contează:
     * 1. decriptare (dacă e cazul) și validare completă (aplicație, versiune,
     *    checksum) — înainte de orice scriere;
     * 2. copie de siguranță a stării curente (before_restore.orgbackup, intern);
     * 3. anularea alarmelor stării curente — altfel ar declanșa payload-urile
     *    restaurate la ore greșite (ID-urile se refolosesc);
     * 4. înlocuirea datelor + identitatea de licență;
     * 5. rearmarea alarmelor din datele restaurate (aceeași logică ca la boot).
     */
    fun restoreContent(
        context: Context, content: String, keepSyncPartners: Boolean, password: String? = null,
    ) {
        val backup = BackupFormat.decode(plainBackup(context, content, password))

        File(context.filesDir, SAFETY_FILE).writeText(snapshot(context), Charsets.UTF_8)

        val flutter = flutterPrefs(context)
        val current = flutter.all
        cancelAlarms(context, current.keys)

        val merged = BackupFormat.mergeForRestore(current, backup.prefs, keepSyncPartners)
        val editor = flutter.edit()
        for (key in current.keys) {
            if (key.startsWith("flutter.")) editor.remove(key)
        }
        for ((key, value) in merged) {
            @Suppress("UNCHECKED_CAST")
            when (value) {
                is String -> editor.putString(key, value)
                is Long -> editor.putLong(key, value)
                is Int -> editor.putInt(key, value)
                is Boolean -> editor.putBoolean(key, value)
                is Float -> editor.putFloat(key, value)
                is Set<*> -> editor.putStringSet(key, value as Set<String>)
            }
        }
        if (!editor.commit()) throw IllegalStateException(tr("Nu s-au putut salva datele restaurate.", "The restored data could not be saved."))

        LicenseStore.restoreIdentity(context, backup.identity)

        // Ofertele de rezervare în așteptare se referă la sloturile vechi.
        context.getSharedPreferences("ClientBookingPrefs", Context.MODE_PRIVATE)
            .edit().clear().commit()

        AlarmRescheduler.rescheduleAll(context)

        // Telefon nou (fără parolă): parola cu care tocmai s-a deschis backup-ul
        // devine parola lui, ca backup-ul automat să continue.
        if (password != null && BackupCrypto.isValidPassword(password) && !BackupPassword.isSet(context)) {
            BackupPassword.set(context, password)
        }
    }

    private fun cancelAlarms(context: Context, keys: Set<String>) {
        for (key in keys) {
            val match = ALARM_KEY.matchEntire(key) ?: continue
            val id = match.groupValues[2].toIntOrNull() ?: continue
            when (match.groupValues[1]) {
                "notif" -> AlarmScheduler.cancelNotifAlarm(context, id)
                "sms" -> AlarmScheduler.cancelSmsAlarm(context, id)
            }
        }
    }
}
