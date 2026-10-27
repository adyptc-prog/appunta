package com.example.management_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.provider.Telephony
import org.json.JSONArray
import org.json.JSONObject

/**
 * Ascultă SMS-urile primite și stochează în coadă pe cele cu prefix ORG:
 * (mesaje de sincronizare trimise de celălalt dispozitiv Appunta).
 * Fiecare tabel poate avea propriul partener de sincronizare, deci fiecare
 * mesaj e etichetat cu tabelul al cărui partener configurat corespunde
 * expeditorului. Mesajele trebuie să fie semnate cu codul de împerechere al
 * tabelului (vezi SyncAuth) — cele nesemnate sunt ignorate.
 *
 * Flutter citește coada la pornire și la revenire în foreground via
 * MethodChannel "organizator/sms" → getSyncMessages / ackSyncMessages.
 */
class SmsSyncReceiver : BroadcastReceiver() {

    companion object {
        const val SYNC_PREFIX = "ORG:"
        const val PREFS_NAME  = "SyncQueue"
        const val QUEUE_KEY   = "queue"

        // Licența se împarte între cele două telefoane sincronizate: „L” poartă
        // fișierul de licență semnat, „R” e cererea unui telefon fără licență
        // (trimisă când își configurează partenerul după ce celălalt a făcut-o
        // deja — altfel licența trimisă atunci ar fi fost ignorată).
        const val LICENSE_PREFIX         = "ORG:L:"
        const val LICENSE_REQUEST_PREFIX = "ORG:R:"

        // Protejează scrierile concurente în coadă — atât acest receiver, cât și
        // ClientBookingReceiver (rezervări de la clienți) pot scrie simultan.
        val QUEUE_LOCK = Any()

        const val ORIGIN_LOCAL   = "local"
        const val ORIGIN_PARTNER = "partner"

        // Scrie un mesaj în coada de sincronizare — folosit de orice cod nativ
        // care trebuie să adauge/actualizeze/șteargă o înregistrare (bot de
        // rezervări, expirare automată de validare etc.), fără să dubleze
        // logica de acces la SharedPreferences în fiecare loc.
        // Fiecare intrare are un „id” unic, ca Flutter să confirme (și să
        // scoată din coadă) exact intrările procesate — nu și pe cele sosite
        // între timp.
        //
        // „origin” spune de unde vine schimbarea: ORIGIN_LOCAL (botul de
        // rezervări, anularea automată la 24h — trebuie trimisă și
        // partenerului) sau ORIGIN_PARTNER (a venit chiar de la partener — nu
        // se retrimite, altfel mesajele s-ar plimba la nesfârșit).
        fun enqueue(context: Context, boardId: String, msg: String, origin: String = ORIGIN_LOCAL) {
            synchronized(QUEUE_LOCK) {
                val prefs = queuePrefs(context)
                val arr = readQueue(prefs)
                arr.put(
                    JSONObject().put("id", newEntryId()).put("board", boardId)
                        .put("msg", msg).put("origin", origin)
                )
                prefs.edit().putString(QUEUE_KEY, arr.toString()).commit()
            }
        }

        /**
         * Coada, ca JSON, pentru Flutter. Intrările vechi (fără id, sau scrise
         * ca text simplu de versiuni anterioare) primesc acum un id, salvat,
         * ca să poată fi confirmate la fel ca restul.
         */
        fun snapshot(context: Context): String = synchronized(QUEUE_LOCK) {
            val prefs = queuePrefs(context)
            val arr = readQueue(prefs)
            var changed = false
            val normalized = JSONArray()
            for (i in 0 until arr.length()) {
                val raw = arr.opt(i)
                val entry = when (raw) {
                    is JSONObject -> raw
                    is String -> JSONObject().put("board", "").put("msg", raw).also { changed = true }
                    else -> { changed = true; continue }
                }
                if (entry.optString("id").isEmpty()) {
                    entry.put("id", newEntryId())
                    changed = true
                }
                normalized.put(entry)
            }
            if (changed) prefs.edit().putString(QUEUE_KEY, normalized.toString()).commit()
            normalized.toString()
        }

        /** Scoate din coadă doar intrările procesate de Flutter. */
        fun acknowledge(context: Context, ids: Collection<String>) {
            if (ids.isEmpty()) return
            val done = ids.toSet()
            val processed = mutableListOf<String>()
            synchronized(QUEUE_LOCK) {
                val prefs = queuePrefs(context)
                val arr = readQueue(prefs)
                val remaining = JSONArray()
                for (i in 0 until arr.length()) {
                    val entry = arr.optJSONObject(i)
                    if (entry != null && entry.optString("id") in done) {
                        processed.add(entry.optString("msg"))
                        continue
                    }
                    remaining.put(arr.opt(i))
                }
                prefs.edit().putString(QUEUE_KEY, remaining.toString()).commit()
            }
            // Rezervările prin bot preluate au acum alarma definitivă din Dart.
            BotReminders.onProcessed(context, processed)
        }

        fun secretKey(boardId: String) = "flutter.sync_secret_$boardId"

        /**
         * Trimite [message] (ex. „ORG:A:{...}”) partenerului tabelului
         * [boardId], semnat cu codul de împerechere. Fără partener sau fără
         * cod valid nu trimite nimic (partenerul l-ar respinge oricum).
         */
        fun sendSigned(context: Context, boardId: String, message: String): Boolean {
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val phone = prefs.getString("flutter.sync_partner_phone_$boardId", null)?.trim().orEmpty()
            val code = prefs.getString(secretKey(boardId), null)
            if (phone.isEmpty() || !SyncAuth.isValidCode(code)) return false
            SmsSender.send(context, phone, SyncAuth.sign(code!!, message))
            return true
        }

        private fun queuePrefs(context: Context): SharedPreferences =
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        // JSON corupt = coadă goală, nu excepție (altfel nimic nu mai intră).
        private fun readQueue(prefs: SharedPreferences): JSONArray = try {
            JSONArray(prefs.getString(QUEUE_KEY, "[]") ?: "[]")
        } catch (_: Exception) {
            JSONArray()
        }

        private fun newEntryId(): String = java.util.UUID.randomUUID().toString()
    }

    // Păstrăm doar cifrele, ca să comparăm numere indiferent de format
    // (+40712345678, 0712345678, cu spații etc.)
    private fun digitsOnly(raw: String?): String = raw.orEmpty().filter { it.isDigit() }

    private fun matches(sender: String, partnerDigits: String): Boolean {
        if (partnerDigits.isEmpty()) return false
        val senderDigits = digitsOnly(sender)
        val minLen = minOf(senderDigits.length, partnerDigits.length)
        if (minLen < 7) return false
        return senderDigits.takeLast(minLen) == partnerDigits.takeLast(minLen)
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        val pdus = Telephony.Sms.Intents.getMessagesFromIntent(intent)
            ?: return

        // Grupăm PDU-urile pe expeditor și concatenăm corpul
        // (SMS multipart: toate segmentele sosesc în același broadcast)
        val bySender = mutableMapOf<String, StringBuilder>()
        for (sms in pdus) {
            val sender = sms.originatingAddress ?: continue
            val body   = sms.messageBody        ?: continue
            bySender.getOrPut(sender) { StringBuilder() }.append(body)
        }

        for ((sender, sb) in bySender) handleSms(context, sender, sb.toString())
    }

    // internal: apelat direct de teste.
    internal fun handleSms(context: Context, sender: String, rawBody: String) {
        if (!rawBody.startsWith(SYNC_PREFIX)) return

        // Doar de la partenerul configurat al unui tabel ȘI semnat cu codul de
        // împerechere al acelui tabel — altfel oricine ne știe numărul (sau
        // falsifică numărul partenerului) ar putea injecta/modifica/șterge
        // înregistrări. Același partener poate fi pe mai multe tabele; tabelul
        // e cel al cărui cod validează semnătura.
        val flutterPrefs = context.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE
        )
        var boardId: String? = null
        var body: String? = null
        for (candidate in partnerBoards(flutterPrefs, sender)) {
            val inner = SyncAuth.verify(flutterPrefs.getString(secretKey(candidate), null), rawBody)
            if (inner != null) {
                boardId = candidate
                body = inner
                break
            }
        }
        if (boardId == null || body == null) {
            Diag.w("sync message rejected: unknown sender or invalid signature")
            return
        }

        if (body.startsWith(LICENSE_PREFIX)) {
            try {
                val decision = LicenseStore.adoptFromPartner(
                    context, body.removePrefix(LICENSE_PREFIX)
                )
                Diag.i("license from partner: $decision")
            } catch (e: Exception) {
                Diag.e("license from partner FAILED", e)
            }
            return
        }
        if (body.startsWith(LICENSE_REQUEST_PREFIX)) {
            // Doar telefonul care a importat licența, și doar partenerului ei.
            val (decision, license) = LicenseStore.shareTo(context, sender)
            Diag.i("license request from partner: $decision")
            if (license != null) sendSigned(context, boardId, LICENSE_PREFIX + license)
            return
        }

        if (body.startsWith(ServicesStore.SYNC_PREFIX)) {
            // Botul trebuie să ofere imediat serviciile noi, nu abia după
            // ce aplicația e deschisă și coada procesată.
            val ok = ServicesStore.applySync(context, boardId, body.removePrefix(ServicesStore.SYNC_PREFIX))
            Diag.i("services from partner: applied=$ok")
            if (!ok) return
        }

        enqueue(context, boardId, body, ORIGIN_PARTNER)
    }

    // Tabelele al căror partener configurat corespunde expeditorului.
    private fun partnerBoards(flutterPrefs: SharedPreferences, sender: String): List<String> {
        val boardsJson = flutterPrefs.getString("flutter.management_boards", null) ?: return emptyList()
        val boards = try { JSONArray(boardsJson) } catch (_: Exception) { return emptyList() }
        val result = mutableListOf<String>()
        for (i in 0 until boards.length()) {
            val id = boards.optJSONObject(i)?.optString("id", "") ?: continue
            if (id.isEmpty()) continue
            val partnerDigits = digitsOnly(flutterPrefs.getString("flutter.sync_partner_phone_$id", null))
            if (matches(sender, partnerDigits)) result.add(id)
        }
        return result
    }
}
