package com.example.management_app

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * Reminderul SMS provizoriu al unei rezervări făcute prin bot.
 *
 * Rezervarea stă în coada de sincronizare până se deschide aplicația, iar
 * abia atunci Dart îi programează alarmele (sub numărul ei din tabel). Cu
 * aplicația închisă, o programare din aceeași zi ar rămâne fără reminder —
 * de aceea botul programează imediat unul provizoriu, aici.
 *
 * Când Dart preia rezervarea (confirmă mesajul „ORG:A:” din coadă), își
 * programează propria alarmă, iar cea provizorie se anulează — clientul nu
 * primește două SMS-uri. Anularea de către client („ORG:D:”) o anulează și ea.
 *
 * ID-urile stau într-un interval separat de cele din Dart
 * (tabel*10.000.000 + număr*100 + ..., sub 100.000.000).
 */
object BotReminders {

    private const val PREFS_NAME = "BotReminderPrefs"
    private const val ENTRIES_KEY = "entries"
    private const val COUNTER_KEY = "counter"
    const val ID_BASE = 900_000_000
    private const val ID_SPAN = 1_000_000
    private const val DAY_MS = 24L * 60L * 60L * 1000L

    // Identice cu _kDefaultSmsTemplateRo / _kDefaultSmsTemplateEn din Dart.
    const val DEFAULT_TEMPLATE_RO =
        "Alertă: [NUME]. Va expira la [DATA_EXPIRARE]. Te rugăm să iei măsurile necesare."
    const val DEFAULT_TEMPLATE_EN =
        "Reminder: [NAME]. It expires on [EXPIRY_DATE]. Please take the necessary steps."

    /**
     * Mesajul implicit urmează limba aplicației. Unul salvat identic cu un
     * mesaj implicit e tratat tot ca implicit; unul editat de utilizator
     * rămâne neatins la schimbarea limbii (ca _effectiveSmsTemplate din Dart).
     */
    fun effectiveTemplate(saved: String?): String =
        if (saved.isNullOrBlank() || saved == DEFAULT_TEMPLATE_RO || saved == DEFAULT_TEMPLATE_EN) {
            tr(DEFAULT_TEMPLATE_RO, DEFAULT_TEMPLATE_EN)
        } else {
            saved
        }

    private val DISPLAY_FMT: DateTimeFormatter = DateTimeFormatter.ofPattern("dd.MM.yyyy HH:mm")

    private val LOCK = Any()

    fun isBotReminderId(id: Int): Boolean = id >= ID_BASE && id < ID_BASE + ID_SPAN

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    // { "<syncId>": { "id": n, "at": ms, "phone": "...", "message": "..." } }
    private fun readEntries(p: SharedPreferences): JSONObject = try {
        JSONObject(p.getString(ENTRIES_KEY, "{}") ?: "{}")
    } catch (_: Exception) {
        JSONObject()
    }

    /** Textul reminderului, cu template-ul ales în aplicație (ca SmsService din Dart). */
    // Variabilele au nume în ambele limbi; un mesaj scris cu cele românești
    // funcționează și cu aplicația în engleză, și invers.
    fun buildMessage(template: String, name: String, expiresAt: LocalDateTime): String =
        template.replace("[NUME]", name).replace("[NAME]", name)
            .replace("[DATA_EXPIRARE]", expiresAt.format(DISPLAY_FMT))
            .replace("[EXPIRY_DATE]", expiresAt.format(DISPLAY_FMT))

    fun schedule(
        context: Context, syncId: String, phone: String, name: String,
        warningAt: LocalDateTime, expiresAt: LocalDateTime,
    ) {
        val atMs = warningAt.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        if (atMs <= System.currentTimeMillis()) return
        AppLang.sync(context)
        val template = effectiveTemplate(
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getString("flutter.sms_template", null)
        )
        val id = synchronized(LOCK) {
            val p = prefs(context)
            val entries = readEntries(p)
            prune(entries)
            val next = (p.getInt(COUNTER_KEY, 0) + 1) % ID_SPAN
            val id = ID_BASE + next
            entries.put(syncId, JSONObject()
                .put("id", id).put("at", atMs).put("phone", phone)
                .put("message", buildMessage(template, name, expiresAt)))
            p.edit().putInt(COUNTER_KEY, next).putString(ENTRIES_KEY, entries.toString()).commit()
            id
        }
        AlarmScheduler.scheduleSmsAlarm(context, id, atMs)
        Diag.i("BotReminders: scheduled id=$id for sync=$syncId")
    }

    fun cancel(context: Context, syncId: String) {
        val id = synchronized(LOCK) {
            val p = prefs(context)
            val entries = readEntries(p)
            val e = entries.optJSONObject(syncId) ?: return
            entries.remove(syncId)
            p.edit().putString(ENTRIES_KEY, entries.toString()).commit()
            e.optInt("id", -1)
        }
        if (isBotReminderId(id)) AlarmScheduler.cancelSmsAlarm(context, id)
        Diag.i("BotReminders: cancelled id=$id for sync=$syncId")
    }

    /** Telefonul și mesajul alarmei [id], pentru SmsAlarmReceiver; null dacă a fost anulată. */
    fun payload(context: Context, id: Int): JSONObject? = synchronized(LOCK) {
        val entries = readEntries(prefs(context))
        entries.keys().asSequence()
            .mapNotNull { entries.optJSONObject(it) }
            .firstOrNull { it.optInt("id", -1) == id }
    }

    /**
     * Mesajele din coadă tocmai preluate de aplicație: pentru rezervările
     * („ORG:A:”) și anulările („ORG:D:”) lor, reminderul provizoriu nu mai
     * e necesar — Dart a programat deja alarma definitivă (sau niciuna).
     */
    fun onProcessed(context: Context, messages: List<String>) {
        for (msg in messages) {
            val syncId = when {
                msg.startsWith("ORG:A:") -> try {
                    JSONObject(msg.removePrefix("ORG:A:")).optString("s")
                } catch (_: Exception) {
                    ""
                }
                msg.startsWith("ORG:D:") -> msg.removePrefix("ORG:D:").trim()
                else -> ""
            }
            if (syncId.isNotEmpty()) cancel(context, syncId)
        }
    }

    /** După repornirea telefonului: AlarmManager a uitat alarmele — le rearmăm. */
    fun rescheduleAll(context: Context) {
        val now = System.currentTimeMillis()
        val pending = synchronized(LOCK) {
            val p = prefs(context)
            val entries = readEntries(p)
            prune(entries)
            p.edit().putString(ENTRIES_KEY, entries.toString()).commit()
            entries.keys().asSequence().mapNotNull { entries.optJSONObject(it) }.toList()
        }
        for (e in pending) {
            val at = e.optLong("at", 0L)
            val id = e.optInt("id", -1)
            if (at > now && isBotReminderId(id)) AlarmScheduler.scheduleSmsAlarm(context, id, at)
        }
    }

    // Reminderele trecute de o zi (aplicația n-a mai fost deschisă) nu mai
    // folosesc la nimic — starea nu crește la infinit.
    private fun prune(entries: JSONObject) {
        val cutoff = System.currentTimeMillis() - DAY_MS
        for (key in entries.keys().asSequence().toList()) {
            if ((entries.optJSONObject(key)?.optLong("at", 0L) ?: 0L) < cutoff) entries.remove(key)
        }
    }
}
