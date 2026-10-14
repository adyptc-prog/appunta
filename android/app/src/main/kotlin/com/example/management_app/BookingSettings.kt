package com.example.management_app

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

data class BoardInfo(val id: String, val name: String)

// Programul unei zile lucrătoare (minute de la miezul nopții).
data class DayHours(val startMin: Int, val endMin: Int)

data class BoardBookingSettings(
    val enabled: Boolean,
    val durationMin: Int,
    // Programul de lucru pe zile (1=luni .. 7=duminică, la fel ca
    // DateTime.weekday din Dart); zilele care lipsesc sunt nelucrătoare.
    val workHours: Map<Int, DayHours>,
)

data class BusyInterval(val startMin: LocalDateTime, val endMin: LocalDateTime)

data class BookedItem(
    val boardId: String,
    val syncId: String,
    val name: String,
    val description: String,
    val phones: List<String>,
    val expiresAt: LocalDateTime?,
    // Durata serviciului programării; null = durata implicită a tabelului.
    val durationMin: Int? = null,
    val service: String? = null,
)

/**
 * Citește tabelele, setările de rezervare și programările existente direct din
 * SharedPreferences-ul Flutter — folosit atât de MainActivity (rândurile libere din ecranul „Servicii”
 * pe Android) cât și de ClientBookingReceiver (botul SMS), ca să existe o singură
 * sursă de adevăr pentru calculul locurilor libere pe această platformă.
 */
object BookingSettings {
    private const val PREFS_NAME = "FlutterSharedPreferences"

    private val ISO_SHORT: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm")

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    // Citește un întreg indiferent dacă plugin-ul Flutter shared_preferences l-a
    // scris ca Int sau ca Long — versiuni diferite ale plugin-ului (mai ales cele
    // bazate pe noul backend Pigeon) scriu valorile int din Dart cu putLong(),
    // iar SharedPreferences.getInt() aruncă ClassCastException dacă tipul stocat
    // nu se potrivește exact. Number acoperă ambele cazuri fără să ghicim tipul.
    private fun getIntCompat(p: android.content.SharedPreferences, key: String, default: Int): Int =
        (p.all[key] as? Number)?.toInt() ?: default

    fun loadBoards(context: Context): List<BoardInfo> {
        val json = prefs(context).getString("flutter.management_boards", null) ?: return emptyList()
        return try {
            val arr = JSONArray(json)
            (0 until arr.length()).mapNotNull { i ->
                val o = arr.getJSONObject(i)
                val id = o.optString("id", "")
                if (id.isEmpty()) null else BoardInfo(id, o.optString("name", ""))
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun loadSettings(context: Context, boardId: String): BoardBookingSettings {
        val p = prefs(context)
        val hoursStr = p.getString("flutter.work_hours_$boardId", null)
        val result = BoardBookingSettings(
            enabled = p.getBoolean("flutter.booking_enabled_$boardId", false),
            durationMin = getIntCompat(p, "flutter.appointment_duration_$boardId", 30),
            workHours = if (hoursStr != null) parseWorkHours(hoursStr) else legacyWorkHours(p, boardId),
        )
        Diag.i("loadSettings: boardId=$boardId -> $result")
        return result
    }

    private val WORK_HOURS_ENTRY = Regex("""^(\d+):(\d+)-(\d+)$""")

    // „1:540-1080,3:600-840” (zi:deschidere-închidere) — scris de
    // encodeWorkHours din Dart; intrările invalide sunt sărite.
    fun parseWorkHours(raw: String): Map<Int, DayHours> {
        val result = mutableMapOf<Int, DayHours>()
        for (part in raw.split(",")) {
            val m = WORK_HOURS_ENTRY.matchEntire(part.trim()) ?: continue
            val day = m.groupValues[1].toIntOrNull() ?: continue
            val start = m.groupValues[2].toIntOrNull() ?: continue
            val end = m.groupValues[3].toIntOrNull() ?: continue
            if (day !in 1..7 || end <= start || end > 24 * 60) continue
            result[day] = DayHours(start, end)
        }
        return result
    }

    // Programul salvat în formatul vechi (înainte de programul pe zile):
    // aceleași ore în toate zilele, mai puțin cele închise.
    private fun legacyWorkHours(p: android.content.SharedPreferences, boardId: String): Map<Int, DayHours> {
        val closedStr = p.getString("flutter.closed_days_$boardId", "") ?: ""
        val closed = closedStr.split(",").mapNotNull { it.trim().toIntOrNull() }.toSet()
        val start = getIntCompat(p, "flutter.work_start_$boardId", 9 * 60)
        val end = getIntCompat(p, "flutter.work_end_$boardId", 18 * 60)
        if (end <= start) return emptyMap()
        return (1..7).filter { it !in closed }.associateWith { DayHours(start, end) }
    }

    // Cu câte minute înainte de expirare vine alerta — ultima valoare aleasă
    // în aplicație („Setează alertă”), aceeași regulă ca _loadAlertLead din Dart.
    const val DEFAULT_ALERT_LEAD_MIN = 60

    fun loadAlertLeadMin(context: Context, boardId: String): Int {
        val v = getIntCompat(prefs(context), "flutter.alert_lead_minutes_$boardId", 0)
        return if (v > 0) v else DEFAULT_ALERT_LEAD_MIN
    }

    private fun parseFlexibleIso(raw: String): LocalDateTime? = try {
        LocalDateTime.parse(raw)
    } catch (_: Exception) {
        try {
            LocalDateTime.parse(raw, ISO_SHORT)
        } catch (_: Exception) {
            null
        }
    }

    // Durata pozitivă salvată pe programare (câmpul „durationMin” / „m”), sau null.
    private fun durationOf(o: JSONObject, key: String): Int? =
        (o.opt(key) as? Number)?.toInt()?.takeIf { it > 0 }

    // Intervalul ocupat al unei programări = [expiresAt - durată, expiresAt),
    // unde durata e a serviciului programării (Item.durationMin din Dart) sau,
    // pentru programările fără serviciu, [durationMin] — durata implicită.
    fun loadBusyIntervals(context: Context, boardId: String, durationMin: Int): List<BusyInterval> {
        val p = prefs(context)
        val result = mutableListOf<BusyInterval>()

        val itemsJson = p.getString("flutter.management_items_$boardId", null)
        Diag.i("loadBusyIntervals: key=flutter.management_items_$boardId present=${itemsJson != null} len=${itemsJson?.length}")
        if (itemsJson != null) {
            try {
                val arr = JSONArray(itemsJson)
                var skippedNoExpiry = 0
                var skippedBadDate = 0
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    if (o.isNull("expiresAt")) { skippedNoExpiry++; continue }
                    val expiresStr = o.optString("expiresAt", "")
                    if (expiresStr.isEmpty()) { skippedNoExpiry++; continue }
                    val end = parseFlexibleIso(expiresStr)
                    if (end == null) { skippedBadDate++; Diag.w("loadBusyIntervals: unparsable expiresAt=\"$expiresStr\""); continue }
                    val d = durationOf(o, "durationMin") ?: durationMin
                    result.add(BusyInterval(end.minusMinutes(d.toLong()), end))
                }
                Diag.i("loadBusyIntervals: totalItems=${arr.length()} busyParsed=${result.size} skippedNoExpiry=$skippedNoExpiry skippedBadDate=$skippedBadDate")
            } catch (e: Exception) {
                Diag.e("loadBusyIntervals: JSON parse failed for boardId=$boardId", e)
            }
        }

        // Rezervări deja confirmate de clienți, dar încă neprocesate de aplicație
        // (stau în coada de sincronizare) — trebuie tratate ca ocupate, altfel doi
        // clienți ar putea primi aceeași oră liberă înainte ca aplicația să fie
        // deschisă și coada procesată.
        for ((prefix, payload) in queuedEntries(context, boardId)) {
            if (prefix !in ITEM_PREFIXES) continue
            val j = parsePayload(payload) ?: continue
            val end = parseFlexibleIso(j.optString("e", "")) ?: continue
            val d = durationOf(j, "m") ?: durationMin
            result.add(BusyInterval(end.minusMinutes(d.toLong()), end))
        }

        return result
    }

    // Citește lista completă de înregistrări ale unui tabel (syncId, telefoane,
    // dată expirare) — folosit de fluxul de anulare prin SMS ca să găsească
    // programarea unui client după numărul de telefon, indiferent dacă a fost
    // creată de bot sau adăugată manual din aplicație.
    //
    // Include și rezervările din coada de sincronizare încă neprocesate de
    // Flutter (coada se golește doar când aplicația e deschisă/în prim-plan —
    // vezi loadBusyIntervals) — altfel un client care trimite „anuleaza” la
    // câteva minute după ce a rezervat prin SMS, fără să fi fost deschisă
    // între timp aplicația, primește „nu am găsit nicio programare activă”,
    // deși rezervarea chiar există (doar că încă n-a ajuns în lista aplicată).
    fun loadBookedItems(context: Context, boardId: String): List<BookedItem> {
        // Cheie = syncId, ca o rezervare cu update în coadă (ORG:U:) să
        // înlocuiască versiunea persistată, nu să apară de două ori.
        val result = LinkedHashMap<String, BookedItem>()

        val itemsJson = prefs(context).getString("flutter.management_items_$boardId", null)
        if (itemsJson != null) {
            try {
                val arr = JSONArray(itemsJson)
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    val syncId = o.optString("syncId", "")
                    if (syncId.isEmpty()) continue
                    val phones = listOfNotNull(
                        o.optString("phoneNumber", "").takeIf { it.isNotEmpty() },
                        o.optString("phoneNumber2", "").takeIf { it.isNotEmpty() },
                        o.optString("phoneNumber3", "").takeIf { it.isNotEmpty() },
                    )
                    if (phones.isEmpty()) continue
                    val expiresStr = o.optString("expiresAt", "")
                    val expiresAt = if (o.isNull("expiresAt") || expiresStr.isEmpty()) null else parseFlexibleIso(expiresStr)
                    result[syncId] = BookedItem(
                        boardId = boardId,
                        syncId = syncId,
                        name = o.optString("name", ""),
                        description = o.optString("description", ""),
                        phones = phones,
                        expiresAt = expiresAt,
                        durationMin = durationOf(o, "durationMin"),
                        service = o.optString("service", "").takeIf { it.isNotEmpty() },
                    )
                }
            } catch (e: Exception) {
                Diag.e("loadBookedItems: JSON parse failed for boardId=$boardId", e)
            }
        }

        for ((prefix, payload) in queuedEntries(context, boardId)) {
            if (prefix == "ORG:D:") {
                // Ștergere încă neprocesată — nu o oferim la anulare.
                result.remove(payload.trim())
                continue
            }
            if (prefix !in ITEM_PREFIXES) continue
            val j = parsePayload(payload) ?: continue
            val syncId = j.optString("s", "")
            if (syncId.isEmpty()) continue
            val phones = listOfNotNull(
                j.optString("p1", "").takeIf { it.isNotEmpty() },
                j.optString("p2", "").takeIf { it.isNotEmpty() },
                j.optString("p3", "").takeIf { it.isNotEmpty() },
            )
            if (phones.isEmpty()) continue
            val expiresStr = j.optString("e", "")
            result[syncId] = BookedItem(
                boardId = boardId,
                syncId = syncId,
                name = j.optString("n", ""),
                description = j.optString("d", ""),
                phones = phones,
                expiresAt = if (expiresStr.isEmpty()) null else parseFlexibleIso(expiresStr),
                durationMin = durationOf(j, "m"),
                service = j.optString("v", "").takeIf { it.isNotEmpty() },
            )
        }

        return result.values.toList()
    }

    // Intrările din coada de sincronizare pentru un tabel, încă neprocesate de
    // Flutter, ca (prefix, payload). Fiecare intrare e citită separat — una
    // coruptă e sărită, fără să le ascundă pe cele de după ea (altfel o oră
    // deja rezervată ar fi oferită din nou).
    private fun queuedEntries(context: Context, boardId: String): List<Pair<String, String>> {
        val queueJson = context
            .getSharedPreferences(SmsSyncReceiver.PREFS_NAME, Context.MODE_PRIVATE)
            .getString(SmsSyncReceiver.QUEUE_KEY, "[]") ?: "[]"
        val arr = try { JSONArray(queueJson) } catch (_: Exception) { return emptyList() }
        val result = mutableListOf<Pair<String, String>>()
        for (i in 0 until arr.length()) {
            val entry = arr.optJSONObject(i) ?: continue
            if (entry.optString("board", "") != boardId) continue
            val msg = entry.optString("msg", "")
            if (msg.length < 6 || !msg.startsWith("ORG:")) continue
            result.add(msg.substring(0, 6) to msg.substring(6))
        }
        return result
    }

    // Payload-ul JSON al unei intrări „ORG:A/I/U:”, sau null dacă e corupt.
    private fun parsePayload(payload: String): JSONObject? = try {
        JSONObject(payload)
    } catch (_: Exception) {
        Diag.w("queued sync entry skipped: invalid JSON")
        null
    }

    private val ITEM_PREFIXES = setOf("ORG:A:", "ORG:I:", "ORG:U:")
}
