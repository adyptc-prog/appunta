package com.example.management_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.provider.Telephony
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Bot de rezervări prin SMS pentru clienți.
 *
 *   „liber”                    → lista categoriilor (tabelelor) cu rezervări
 *                                 active, numerotate; cu una singură, direct
 *                                 pasul următor
 *   „liber <categorie>”        → lista serviciilor categoriei, numerotate
 *                                 (cu un singur serviciu sau niciunul, direct
 *                                 orele libere) — la fel ca alegerea
 *                                 categoriei după număr
 *   un număr după servicii     → până la 6 ore libere, numerotate, calculate
 *                                 cu durata serviciului ales
 *   „next”                     → următoarea pagină de ore libere
 *   un număr (ex. „2”)         → alegere dintr-o listă de categorii, de
 *                                 servicii, de ore sau de anulare (cea mai
 *                                 recentă interacțiune câștigă)
 *   „anuleaza” / „anulare”     → caută programările viitoare de pe
 *                                 acest număr (create de bot SAU adăugate
 *                                 manual din aplicație) și le anulează —
 *                                 direct dacă e una singură, altfel cere
 *                                 alegerea dintr-o listă
 *
 * Rulează independent de Flutter (ca SmsAlarmReceiver) — citește direct din
 * SharedPreferences prin BookingSettings/FreeSlotCalculator,
 * ca să răspundă instant chiar dacă aplicația e complet închisă. Rezervarea
 * confirmată/anulată e scrisă în coada de sincronizare existentă ca mesaj
 * „ORG:A:”/„ORG:D:” — Flutter o preia automat la următoarea deschidere, cu
 * logica de sincronizare deja existentă (numerotare, alarme, sloturi libere
 * etc.), fără cod separat pentru asta.
 *
 * Declanșatoarele sunt stricte (mesajul trebuie să înceapă exact cu cuvântul
 * cheie) ca să nu se confunde cu un SMS personal obișnuit care conține
 * întâmplător acel cuvânt undeva în text.
 */
class ClientBookingReceiver : BroadcastReceiver() {

    companion object {
        private const val PREFS_NAME        = "ClientBookingPrefs"
        private const val OFFERS_KEY        = "offers"
        private const val SERVICE_OFFERS_KEY = "serviceOffers"
        private const val CATEGORY_OFFERS_KEY = "categoryOffers"
        private const val OFFER_TTL_MIN     = 20L
        private const val CANCEL_OFFERS_KEY = "cancelOffers"
        private const val RATE_KEY          = "rateLimits"
        private const val CANCEL_OFFER_TTL_MIN = 10L
        private const val BLOCK_NOTICE_KEY  = "noShowBlockNotices"
        private const val DAY_MS = 24L * 60L * 60L * 1000L
        private const val PAGE_SIZE       = 6
        private const val HORIZON_DAYS    = 14
        private const val MAX_TOTAL_SLOTS = 200

        // Toate SMS-urile de la clienți se procesează strict în ordinea sosirii
        // (FIFO) pe un singur fir de execuție — evită curse între două cereri
        // aproape simultane (ofertă suprascrisă, rezervare pierdută).
        private val EXECUTOR: ExecutorService = Executors.newSingleThreadExecutor()

        private val ISO_SHORT: DateTimeFormatter        = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm")
        private val DISPLAY_TIME_FMT: DateTimeFormatter  = DateTimeFormatter.ofPattern("HH:mm")
        private val DISPLAY_DATE_FMT: DateTimeFormatter  = DateTimeFormatter.ofPattern("dd.MM")

        // Categoria poate avea mai multe cuvinte (ex. „liber gene false”).
        // Cuvintele-cheie sunt acceptate mereu în ambele limbi (liber/free,
        // anuleaza/cancel); răspunsul pleacă în limba aleasă în aplicație.
        private val LIBER_RE   = Regex("^(?:liber|free)(\\s+(.+))?$")
        private val NUMBER_RE  = Regex("^(\\d{1,2})$")
        // "anuleaza" / "anulare", eventual urmat de orice alt text (ex. "anuleaza
        // aceasta programare") — normalize() scoate deja diacriticele, deci
        // "anulează" ajunge tot aici.
        private val CANCEL_RE  = Regex("^(anuleaza|anulare|cancel)(\\s+.*)?$")
        // Cât timp clientul are o listă activă, acceptăm și forme ca „3.”,
        // „3)”, „nr 3”, „opțiunea 3”, „ora 3” (diacriticele sunt deja scoase).
        private val LOOSE_NUMBER_RE =
            Regex("^(?:(?:optiunea|optiune|varianta|numarul|numar|nr|ora|option|number|no)\\.?\\s*)?(\\d{1,2})\\s*[.)!]*$")
        // Un text scurt, nerecunoscut, primit în timpul unei liste active
        // primește o singură dată un mesaj de ajutor; unul lung e probabil
        // un SMS personal și rămâne fără răspuns.
        private const val HELP_MAX_LEN = 60
        private val WHITESPACE_RE = Regex("\\s+")
        private val TIME_FMT: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm")
    }

    override fun onReceive(context: Context, intent: Intent) {
        Diag.i("onReceive action=${intent.action}")
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val pdus = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return

        val bySender = mutableMapOf<String, StringBuilder>()
        for (sms in pdus) {
            val sender = sms.originatingAddress ?: continue
            val body   = sms.messageBody        ?: continue
            bySender.getOrPut(sender) { StringBuilder() }.append(body)
        }
        Diag.i("onReceive senders=${bySender.keys.map { Diag.mask(it) }}")
        if (bySender.isEmpty()) return

        val pending = goAsync()
        val appContext = context.applicationContext
        EXECUTOR.execute {
            try {
                for ((sender, sb) in bySender) {
                    try {
                        handleMessage(appContext, sender, sb.toString())
                    } catch (e: Exception) {
                        Diag.e("handleMessage threw for sender=${Diag.mask(sender)}", e)
                    }
                }
            } finally {
                pending.finish()
            }
        }
    }

    private fun digitsOnly(raw: String?): String = raw.orEmpty().filter { it.isDigit() }

    private fun normalize(s: String): String {
        val nfd = java.text.Normalizer.normalize(s, java.text.Normalizer.Form.NFD)
        return nfd.replace(Regex("\\p{Mn}+"), "").lowercase().trim()
    }

    // internal: apelat direct de testele Robolectric (fără SMS-uri reale).
    internal fun handleMessage(context: Context, sender: String, rawBody: String) {
        Diag.i("handleMessage sender=${Diag.mask(sender)} len=${rawBody.length}")
        // Răspunsurile pleacă în limba aleasă în aplicație pe acest telefon.
        AppLang.sync(context)
        // Mesaje de sincronizare — ale acestei aplicații (ORG:) sau ale
        // aplicației „Ospita” (PEN:), dacă e pe același telefon.
        if (rawBody.startsWith("ORG:") || rawBody.startsWith("PEN:")) {
            Diag.i("handleMessage: ignored, looks like sync message")
            return
        }

        val senderDigits = digitsOnly(sender)
        if (senderDigits.isEmpty()) {
            Diag.w("handleMessage: senderDigits empty, aborting")
            return
        }
        // După expirarea trial-ului, fără licență, botul nu mai răspunde
        // (fiecare răspuns e un SMS trimis de aplicație).
        if (!Entitlement.isActive(context)) {
            Diag.i("handleMessage: no license and trial expired, bot disabled")
            return
        }
        if (!BotLimits.isReplyableSender(sender)) {
            Diag.i("handleMessage: sender is not a phone number, ignoring")
            return
        }
        if (isSyncPartner(context, senderDigits)) {
            Diag.i("handleMessage: sender=${Diag.mask(senderDigits)} matched sync_partner_phone, ignoring")
            return
        }

        val body = normalize(rawBody)
        if (body.isEmpty()) return

        val liberMatch  = LIBER_RE.find(body)
        val cancelMatch = CANCEL_RE.find(body)
        val categoryOffer = getCategoryOffer(context, senderDigits)
        val serviceOffer = getServiceOffer(context, senderDigits)
        val bookingOffer = getOffer(context, senderDigits)
        val cancelOffer  = getCancelOffer(context, senderDigits)
        val hasActiveList = categoryOffer != null || serviceOffer != null || bookingOffer != null || cancelOffer != null
        val numberMatch = NUMBER_RE.find(body)
            ?: if (hasActiveList) LOOSE_NUMBER_RE.find(body) else null
        Diag.i("handleMessage: liberMatch=${liberMatch != null} cancelMatch=${cancelMatch != null} numberMatch=${numberMatch != null} activeList=$hasActiveList")

        val isCommand = liberMatch != null || body == "next" || cancelMatch != null || numberMatch != null
        // Lista activă la care se referă ajutorul — cea mai recentă câștigă,
        // ca la alegerea numerică.
        val helpFor = if (!isCommand && body.length <= HELP_MAX_LEN) {
            listOfNotNull(
                categoryOffer?.takeUnless { it.optBoolean("helped") }?.let { "category" to it.optLong("ts", 0L) },
                serviceOffer?.takeUnless { it.optBoolean("helped") }?.let { "service" to it.optLong("ts", 0L) },
                bookingOffer?.takeUnless { it.optBoolean("helped") }?.let { "booking" to it.optLong("ts", 0L) },
                cancelOffer?.takeUnless { it.optBoolean("helped") }?.let { "cancel" to it.optLong("ts", 0L) },
            ).maxByOrNull { it.second }?.first
        } else null
        if (!isCommand && helpFor == null) {
            Diag.i("handleMessage: no pattern matched, ignoring silently (by design)")
            return
        }
        // Fiecare răspuns e un SMS plătit — limităm cât poate cere un număr
        // și cât răspunde botul pe zi.
        val limit = registerCommand(context, senderDigits)
        if (limit != BotLimits.Decision.ALLOW) {
            Diag.w("handleMessage: rate limited ($limit)")
            if (limit == BotLimits.Decision.NUMBER_LIMIT) notifyLimit(context, sender, senderDigits)
            return
        }
        // Un număr se referă la lista activă cea mai recentă (categorie, serviciu, oră sau anulare).
        val numberTarget = listOfNotNull(
            categoryOffer?.let { "category" to it.optLong("ts", 0L) },
            serviceOffer?.let { "service" to it.optLong("ts", 0L) },
            bookingOffer?.let { "booking" to it.optLong("ts", 0L) },
            cancelOffer?.let  { "cancel"  to it.optLong("ts", 0L) },
        ).maxByOrNull { it.second }?.first
        // Clientul blocat pentru neprezentări mai poate doar anula.
        val cancelRelated = cancelMatch != null || helpFor == "cancel" ||
            (numberMatch != null && numberTarget == "cancel")
        if (!cancelRelated && blockedForNoShows(context, sender, senderDigits)) return

        when {
            helpFor == "category" -> {
                markHelped(context, CATEGORY_OFFERS_KEY, senderDigits)
                sendSms(
                    context, sender,
                    tr(
                        "Nu am înțeles. Răspunde doar cu numărul categoriei dorite (ex. 1).",
                        "I didn't understand. Reply with just the number of the category you want (e.g. 1).",
                    )
                )
            }
            helpFor == "service" -> {
                markHelped(context, SERVICE_OFFERS_KEY, senderDigits)
                sendSms(
                    context, sender,
                    tr(
                        "Nu am înțeles. Răspunde doar cu numărul serviciului dorit (ex. 1) " +
                            "sau LIBER pentru o căutare nouă.",
                        "I didn't understand. Reply with just the number of the service you want (e.g. 1) " +
                            "or FREE for a new search.",
                    )
                )
            }
            helpFor == "booking" -> {
                markHelped(context, OFFERS_KEY, senderDigits)
                sendSms(
                    context, sender,
                    tr(
                        "Nu am înțeles. Răspunde doar cu numărul orei dorite (ex. 2), " +
                            "NEXT pentru alte ore sau LIBER pentru o căutare nouă.",
                        "I didn't understand. Reply with just the number of the time you want (e.g. 2), " +
                            "NEXT for other times or FREE for a new search.",
                    )
                )
            }
            helpFor == "cancel" -> {
                markHelped(context, CANCEL_OFFERS_KEY, senderDigits)
                sendSms(
                    context, sender,
                    tr(
                        "Nu am înțeles. Răspunde doar cu numărul programării pe care vrei " +
                            "să o anulezi (ex. 1).",
                        "I didn't understand. Reply with just the number of the appointment you want " +
                            "to cancel (e.g. 1).",
                    )
                )
            }
            liberMatch != null -> {
                val token = liberMatch.groupValues.getOrNull(2)?.takeIf { it.isNotBlank() }
                startOffer(context, sender, senderDigits, token)
            }
            body == "next" -> continueOffer(context, sender, senderDigits)
            cancelMatch != null -> startCancelFlow(context, sender, senderDigits)
            numberMatch != null -> {
                // Un răspuns numeric poate însemna, în funcție de ce a
                // întrebat ultimul mesaj trimis clientului: ce opțiune de
                // rezervare alege, sau ce programare alege să anuleze. Când
                // ambele sunt active, câștigă cea mai recentă interacțiune.
                val choice = numberMatch.groupValues[1].toInt()
                when (numberTarget) {
                    "cancel" -> confirmCancel(context, sender, senderDigits, choice)
                    "category" -> confirmCategory(context, sender, senderDigits, choice)
                    "service" -> confirmService(context, sender, senderDigits, choice)
                    else     -> confirmOffer(context, sender, senderDigits, choice)
                }
            }
        }
    }

    // Peste limita pe oră: o singură explicație, cu ora de la care poate
    // scrie din nou (BotLimits decide dacă se trimite).
    private fun notifyLimit(context: Context, sender: String, senderDigits: String) {
        val prefs = bookingPrefs(context)
        val state = try {
            JSONObject(prefs.getString(RATE_KEY, "{}") ?: "{}")
        } catch (_: Exception) {
            JSONObject()
        }
        val untilMs = BotLimits.limitNotice(state, senderDigits, System.currentTimeMillis()) ?: return
        prefs.edit().putString(RATE_KEY, state.toString()).apply()
        val until = java.time.Instant.ofEpochMilli(untilMs)
            .atZone(java.time.ZoneId.systemDefault()).toLocalTime()
        sendSms(
            context, sender,
            tr(
                "Ai trimis multe mesaje într-un timp scurt. Poți reveni după ora ${until.format(TIME_FMT)}.",
                "You sent many messages in a short time. You can try again after ${until.format(TIME_FMT)}.",
            )
        )
    }

    // Ajutorul se trimite o singură dată pe listă.
    private fun markHelped(context: Context, key: String, senderDigits: String) {
        val prefs = bookingPrefs(context)
        val all = try {
            JSONObject(prefs.getString(key, "{}") ?: "{}")
        } catch (_: Exception) {
            JSONObject()
        }
        val o = all.optJSONObject(senderDigits) ?: return
        o.put("helped", true)
        all.put(senderDigits, o)
        prefs.edit().putString(key, all.toString()).apply()
    }

    private fun registerCommand(context: Context, senderDigits: String): BotLimits.Decision {
        val prefs = bookingPrefs(context)
        val state = try {
            JSONObject(prefs.getString(RATE_KEY, "{}") ?: "{}")
        } catch (_: Exception) {
            JSONObject()
        }
        val today = java.time.LocalDate.now().toString()
        val decision = BotLimits.register(state, senderDigits, System.currentTimeMillis(), today)
        prefs.edit().putString(RATE_KEY, state.toString()).apply()
        return decision
    }

    // Plafonul de rezervări active pe număr — altfel cineva putea ocupa toate
    // orele libere cu „liber” + „1” repetat.
    private fun bookingLimitReached(context: Context, sender: String, senderDigits: String): Boolean {
        if (BotLimits.canBookMore(findActiveBookings(context, senderDigits).size)) return false
        sendSms(
            context, sender,
            tr(
                "Ai deja ${BotLimits.MAX_ACTIVE_BOOKINGS_PER_NUMBER} rezervări active. " +
                    "Pentru una nouă, anulează mai întâi una scriind ANULEAZA.",
                "You already have ${BotLimits.MAX_ACTIVE_BOOKINGS_PER_NUMBER} active appointments. " +
                    "For a new one, first cancel one by texting CANCEL.",
            )
        )
        return true
    }

    // ── Excludere parteneri de sincronizare (device-to-device) ──────────────────
    private fun isSyncPartner(context: Context, senderDigits: String): Boolean {
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val boards = BookingSettings.loadBoards(context)
        val keys = if (boards.isEmpty()) {
            listOf("flutter.sync_partner_phone")
        } else {
            boards.map { "flutter.sync_partner_phone_${it.id}" }
        }
        for (key in keys) {
            val partnerDigits = digitsOnly(prefs.getString(key, null))
            if (partnerDigits.isEmpty()) continue
            val minLen = minOf(senderDigits.length, partnerDigits.length)
            if (minLen < 7) continue
            if (senderDigits.takeLast(minLen) == partnerDigits.takeLast(minLen)) {
                Diag.i("isSyncPartner: MATCH key=$key sender=${Diag.mask(senderDigits)}")
                return true
            }
        }
        return false
    }

    // ── Potrivire categorie (tabel) după nume ────────────────────────────────────
    // Exact pe orice tabel; aproximativ („unghie” → „Unghii”) doar pe cele cu
    // rezervări active și doar pentru texte de cel puțin 3 litere — cu 10
    // tabele, o literă ar nimeri aproape orice nume.
    private fun matchBoard(boards: List<BoardInfo>, enabled: List<BoardInfo>, token: String): BoardInfo? {
        val t = normalize(token).replace(WHITESPACE_RE, " ")
        boards.firstOrNull { normalize(it.name) == t }?.let { return it }
        if (t.length < 3) return null
        enabled.firstOrNull { normalize(it.name).contains(t) || t.contains(normalize(it.name)) }?.let { return it }
        return null
    }

    // ── Stocare ofertă activă per client ─────────────────────────────────────────
    private fun bookingPrefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun loadOffers(context: Context): JSONObject = try {
        JSONObject(bookingPrefs(context).getString(OFFERS_KEY, "{}") ?: "{}")
    } catch (_: Exception) {
        JSONObject()
    }

    private fun saveOffers(context: Context, offers: JSONObject) {
        bookingPrefs(context).edit().putString(OFFERS_KEY, offers.toString()).apply()
    }

    private fun getOffer(context: Context, senderDigits: String): JSONObject? {
        val o = loadOffers(context).optJSONObject(senderDigits) ?: return null
        val ts = o.optLong("ts", 0L)
        if (System.currentTimeMillis() - ts > OFFER_TTL_MIN * 60_000L) return null
        return o
    }

    private fun setOffer(context: Context, senderDigits: String, boardId: String, offset: Int, service: ChosenService) {
        val offers = loadOffers(context)
        val o = JSONObject()
        o.put("board", boardId)
        o.put("offset", offset)
        if (service.name != null) o.put("svc", service.name)
        o.put("dur", service.durationMin)
        o.put("ts", System.currentTimeMillis())
        offers.put(senderDigits, o)
        saveOffers(context, offers)
    }

    private fun clearOffer(context: Context, senderDigits: String) {
        val offers = loadOffers(context)
        offers.remove(senderDigits)
        saveOffers(context, offers)
    }

    // ── Stocare listă de servicii activă per client ──────────────────────────────
    private fun loadServiceOffers(context: Context): JSONObject = try {
        JSONObject(bookingPrefs(context).getString(SERVICE_OFFERS_KEY, "{}") ?: "{}")
    } catch (_: Exception) {
        JSONObject()
    }

    private fun getServiceOffer(context: Context, senderDigits: String): JSONObject? {
        val o = loadServiceOffers(context).optJSONObject(senderDigits) ?: return null
        if (System.currentTimeMillis() - o.optLong("ts", 0L) > OFFER_TTL_MIN * 60_000L) return null
        return o
    }

    // Se memorează și lista trimisă — alegerea „2” înseamnă al doilea serviciu
    // din mesajul primit, chiar dacă salonul a schimbat între timp ordinea.
    private fun setServiceOffer(context: Context, senderDigits: String, boardId: String, services: List<ServiceInfo>) {
        val offers = loadServiceOffers(context)
        val arr = JSONArray()
        services.forEach { arr.put(JSONObject().put("n", it.name).put("m", it.durationMin)) }
        offers.put(
            senderDigits,
            JSONObject().put("board", boardId).put("services", arr).put("ts", System.currentTimeMillis()),
        )
        bookingPrefs(context).edit().putString(SERVICE_OFFERS_KEY, offers.toString()).apply()
    }

    private fun clearServiceOffer(context: Context, senderDigits: String) {
        val offers = loadServiceOffers(context)
        if (offers.remove(senderDigits) == null) return
        bookingPrefs(context).edit().putString(SERVICE_OFFERS_KEY, offers.toString()).apply()
    }

    // ── Stocare listă de categorii activă per client ─────────────────────────────
    // Ca la servicii, se memorează lista trimisă: „2” înseamnă a doua categorie
    // din mesajul primit, chiar dacă între timp s-a activat sau dezactivat alta.
    private fun loadCategoryOffers(context: Context): JSONObject = try {
        JSONObject(bookingPrefs(context).getString(CATEGORY_OFFERS_KEY, "{}") ?: "{}")
    } catch (_: Exception) {
        JSONObject()
    }

    private fun getCategoryOffer(context: Context, senderDigits: String): JSONObject? {
        val o = loadCategoryOffers(context).optJSONObject(senderDigits) ?: return null
        if (System.currentTimeMillis() - o.optLong("ts", 0L) > OFFER_TTL_MIN * 60_000L) return null
        return o
    }

    private fun setCategoryOffer(context: Context, senderDigits: String, boards: List<BoardInfo>) {
        val offers = loadCategoryOffers(context)
        val arr = JSONArray()
        boards.forEach { arr.put(it.id) }
        offers.put(senderDigits, JSONObject().put("boards", arr).put("ts", System.currentTimeMillis()))
        bookingPrefs(context).edit().putString(CATEGORY_OFFERS_KEY, offers.toString()).apply()
    }

    private fun clearCategoryOffer(context: Context, senderDigits: String) {
        val offers = loadCategoryOffers(context)
        if (offers.remove(senderDigits) == null) return
        bookingPrefs(context).edit().putString(CATEGORY_OFFERS_KEY, offers.toString()).apply()
    }

    // ── Stocare cerere de anulare activă per client ──────────────────────────────
    // Separată de oferta de rezervare ("offers") ca să nu se confunde un răspuns
    // numeric destinat uneia cu celălalt flux — vezi dezambiguizarea din handleMessage.
    private fun loadCancelOffers(context: Context): JSONObject = try {
        JSONObject(bookingPrefs(context).getString(CANCEL_OFFERS_KEY, "{}") ?: "{}")
    } catch (_: Exception) {
        JSONObject()
    }

    private fun saveCancelOffers(context: Context, offers: JSONObject) {
        bookingPrefs(context).edit().putString(CANCEL_OFFERS_KEY, offers.toString()).apply()
    }

    private fun getCancelOffer(context: Context, senderDigits: String): JSONObject? {
        val o = loadCancelOffers(context).optJSONObject(senderDigits) ?: return null
        val ts = o.optLong("ts", 0L)
        if (System.currentTimeMillis() - ts > CANCEL_OFFER_TTL_MIN * 60_000L) return null
        return o
    }

    private fun setCancelOffer(context: Context, senderDigits: String, candidates: JSONArray) {
        val offers = loadCancelOffers(context)
        val o = JSONObject()
        o.put("candidates", candidates)
        o.put("ts", System.currentTimeMillis())
        offers.put(senderDigits, o)
        saveCancelOffers(context, offers)
    }

    private fun clearCancelOffer(context: Context, senderDigits: String) {
        val offers = loadCancelOffers(context)
        offers.remove(senderDigits)
        saveCancelOffers(context, offers)
    }

    // ── Flux „liber” / „liber <categorie>” ──────────────────────────────────────
    // Serviciul ales: numele (null = fără serviciu, durata implicită a
    // tabelului) și durata cu care se caută orele libere.
    private class ChosenService(val name: String?, val durationMin: Int)

    private fun startOffer(context: Context, sender: String, senderDigits: String, token: String?) {
        val boards = BookingSettings.loadBoards(context)
        Diag.i("startOffer: boards=${boards.map { it.id }} hasToken=${token != null}")
        if (boards.isEmpty()) {
            Diag.w("startOffer: no boards found, aborting")
            return
        }
        val enabled = boards.filter { BookingSettings.loadSettings(context, it.id).enabled }

        val board = if (token == null) {
            when (enabled.size) {
                0 -> {
                    sendSms(
                        context, sender,
                        tr("Rezervările prin SMS nu sunt active momentan.", "SMS bookings are not active at the moment."),
                    )
                    return
                }
                1 -> enabled[0]
                else -> {
                    // Categoriile cu rezervări active sunt publice (le alege
                    // clientul cu numărul din fața lor).
                    clearServiceOffer(context, senderDigits)
                    clearOffer(context, senderDigits)
                    setCategoryOffer(context, senderDigits, enabled)
                    val lines = enabled.mapIndexed { i, b -> "${i + 1}. ${b.name}" }
                    sendSms(
                        context, sender,
                        tr(
                            "Pentru ce categorie dorești programare?",
                            "Which category do you want an appointment for?",
                        ) + "\n${lines.joinToString("\n")}\n" +
                            tr("Răspunde cu numărul categoriei dorite.", "Reply with the number of the category you want.")
                    )
                    return
                }
            }
        } else {
            matchBoard(boards, enabled, token) ?: run {
                // Nu repetăm aici numele tabelelor — lista e la „LIBER”.
                sendSms(
                    context, sender,
                    tr(
                        "Nu am găsit categoria \"$token\". Scrie LIBER pentru lista categoriilor.",
                        "I couldn't find the category \"$token\". Text FREE for the list of categories.",
                    )
                )
                return
            }
        }
        offerBoard(context, sender, senderDigits, board)
    }

    // Clientul a ales categoria din listă — urmează serviciile ei (sau orele).
    private fun confirmCategory(context: Context, sender: String, senderDigits: String, choice: Int) {
        val offer = getCategoryOffer(context, senderDigits)
        if (offer == null) {
            sendSms(context, sender, noActiveSearch())
            return
        }
        val ids = offer.optJSONArray("boards") ?: JSONArray()
        if (choice < 1 || choice > ids.length()) {
            sendSms(
                context, sender,
                tr(
                    "Opțiune invalidă. Răspunde cu numărul unei categorii din ultimul mesaj primit, " +
                        "sau scrie LIBER pentru o căutare nouă.",
                    "Invalid option. Reply with the number of a category from the last message you received, " +
                        "or text FREE for a new search.",
                )
            )
            return
        }
        val boardId = ids.optString(choice - 1, "")
        val board = BookingSettings.loadBoards(context).firstOrNull { it.id == boardId }
        if (board == null) {
            // Tabelul a fost șters între timp.
            clearCategoryOffer(context, senderDigits)
            sendSms(context, sender, noActiveSearch())
            return
        }
        offerBoard(context, sender, senderDigits, board)
    }

    // Categoria e stabilită (după nume sau după număr): verifică rezervările
    // active, apoi trimite serviciile sau direct orele libere.
    private fun offerBoard(context: Context, sender: String, senderDigits: String, board: BoardInfo) {
        clearCategoryOffer(context, senderDigits)
        val settings = BookingSettings.loadSettings(context, board.id)
        Diag.i("startOffer: board=${board.id} settings.enabled=${settings.enabled}")
        if (!settings.enabled) {
            sendSms(
                context, sender,
                tr(
                    "Rezervările prin SMS nu sunt active pentru ${board.name}.",
                    "SMS bookings are not active for ${board.name}.",
                ),
            )
            return
        }

        if (bookingLimitReached(context, sender, senderDigits)) return

        val services = ServicesStore.load(context, board.id)
        when (services.size) {
            // Fără servicii: durata implicită; cu unul singur, nu mai întrebăm.
            0 -> startHours(context, sender, senderDigits, board, settings, ChosenService(null, settings.durationMin))
            1 -> startHours(context, sender, senderDigits, board, settings, ChosenService(services[0].name, services[0].durationMin))
            else -> {
                clearOffer(context, senderDigits)
                setServiceOffer(context, senderDigits, board.id, services)
                val lines = services.mapIndexed { i, s -> "${i + 1}. ${s.name} (${formatDuration(s.durationMin)})" }
                sendSms(
                    context, sender,
                    tr("Servicii ${board.name}:", "Services, ${board.name}:") +
                        "\n${lines.joinToString("\n")}\n" +
                        tr("Răspunde cu numărul serviciului dorit.", "Reply with the number of the service you want.")
                )
            }
        }
    }

    // Clientul a ales serviciul din listă — urmează orele libere pentru el.
    private fun confirmService(context: Context, sender: String, senderDigits: String, choice: Int) {
        val offer = getServiceOffer(context, senderDigits)
        if (offer == null) {
            sendSms(context, sender, noActiveSearch())
            return
        }
        val services = ServicesStore.decode(offer.optJSONArray("services"))
        if (choice < 1 || choice > services.size) {
            sendSms(
                context, sender,
                tr(
                    "Opțiune invalidă. Răspunde cu numărul unui serviciu din ultimul mesaj primit, " +
                        "sau scrie LIBER pentru o căutare nouă.",
                    "Invalid option. Reply with the number of a service from the last message you received, " +
                        "or text FREE for a new search.",
                )
            )
            return
        }
        val board = BookingSettings.loadBoards(context).firstOrNull { it.id == offer.optString("board", "") }
        val settings = board?.let { BookingSettings.loadSettings(context, it.id) }
        if (board == null || settings == null || !settings.enabled) {
            clearServiceOffer(context, senderDigits)
            return
        }
        if (bookingLimitReached(context, sender, senderDigits)) {
            clearServiceOffer(context, senderDigits)
            return
        }
        val chosen = services[choice - 1]
        startHours(context, sender, senderDigits, board, settings, ChosenService(chosen.name, chosen.durationMin))
    }

    private fun startHours(
        context: Context, sender: String, senderDigits: String,
        board: BoardInfo, settings: BoardBookingSettings, service: ChosenService,
    ) {
        clearServiceOffer(context, senderDigits)
        sendPage(context, sender, senderDigits, board, settings, service, offset = 0, isFirstPage = true)
    }

    // Serviciul memorat în oferta de ore; ofertele scrise înainte de servicii
    // nu au „dur” — se folosește durata implicită a tabelului.
    private fun offerService(offer: JSONObject, settings: BoardBookingSettings): ChosenService {
        val dur = offer.optInt("dur", 0).takeIf { it > 0 } ?: settings.durationMin
        return ChosenService(offer.optString("svc", "").takeIf { it.isNotEmpty() }, dur)
    }

    private fun continueOffer(context: Context, sender: String, senderDigits: String) {
        val offer = getOffer(context, senderDigits)
        if (offer == null) {
            sendSms(context, sender, noActiveSearch())
            return
        }
        val boardId = offer.optString("board", "")
        val board = BookingSettings.loadBoards(context).firstOrNull { it.id == boardId }
        if (board == null) {
            clearOffer(context, senderDigits)
            return
        }
        val settings = BookingSettings.loadSettings(context, board.id)
        if (!settings.enabled) {
            clearOffer(context, senderDigits)
            return
        }
        val nextOffset = offer.optInt("offset", 0) + PAGE_SIZE
        sendPage(
            context, sender, senderDigits, board, settings, offerService(offer, settings),
            offset = nextOffset, isFirstPage = false,
        )
    }

    // „Unghii – Gel” sau doar „Unghii” (fără serviciu).
    private fun title(board: BoardInfo, service: ChosenService): String =
        if (service.name == null) board.name else "${board.name} – ${service.name}"

    private fun sendPage(
        context: Context,
        sender: String,
        senderDigits: String,
        board: BoardInfo,
        settings: BoardBookingSettings,
        service: ChosenService,
        offset: Int,
        isFirstPage: Boolean,
    ) {
        val page = computePage(context, board, settings, service, offset)

        if (page.slots.isEmpty()) {
            val msg = if (isFirstPage) {
                tr(
                    "Nu sunt ore libere în perioada verificată pentru ${title(board, service)}.",
                    "There are no free times in the period checked for ${title(board, service)}.",
                )
            } else {
                tr(
                    "Nu mai sunt alte ore libere pentru ${title(board, service)}. Scrie LIBER pentru a relua căutarea.",
                    "There are no more free times for ${title(board, service)}. Text FREE to search again.",
                )
            }
            sendSms(context, sender, msg)
            clearOffer(context, senderDigits)
            return
        }

        setOffer(context, senderDigits, board.id, offset, service)

        val today = LocalDateTime.now().toLocalDate()
        val lines = page.slots.mapIndexed { i, slot ->
            val dateSuffix = if (slot.start.toLocalDate() != today) " (${slot.start.format(DISPLAY_DATE_FMT)})" else ""
            "${i + 1}. ${slot.start.format(DISPLAY_TIME_FMT)}-${slot.end.format(DISPLAY_TIME_FMT)}$dateSuffix"
        }
        val footer = tr("Răspunde cu numărul opțiunii pentru rezervare", "Reply with the option number to book") +
            (if (page.hasMore) tr(", sau NEXT pentru alte ore.", ", or NEXT for other times.") else ".")
        val header = tr("Ore libere ${title(board, service)}:", "Free times, ${title(board, service)}:")
        sendSms(context, sender, "$header\n${lines.joinToString("\n")}\n$footer")
    }

    private fun noActiveSearch(): String = tr(
        "Nu am nicio căutare activă. Scrie LIBER pentru a vedea orele libere.",
        "I have no active search. Text FREE to see the free times.",
    )

    private class Page(val slots: List<FreeSlot>, val hasMore: Boolean)

    // Cerem un slot „în plus” față de pagina curentă (peekTarget), doar ca să
    // detectăm dacă mai există ore libere după cele afișate — fără asta,
    // FreeSlotCalculator s-ar opri exact la finalul paginii și nu am putea ști
    // niciodată dacă „NEXT” chiar mai aduce ceva.
    // Programările existente ocupă fiecare durata serviciului ei (cele fără
    // serviciu — durata implicită); orele oferite au durata serviciului ales.
    private fun computePage(
        context: Context, board: BoardInfo, settings: BoardBookingSettings,
        service: ChosenService, offset: Int,
    ): Page {
        val busy = BookingSettings.loadBusyIntervals(context, board.id, settings.durationMin)
        val peekTarget = minOf(offset + PAGE_SIZE + 1, MAX_TOTAL_SLOTS)
        val all = FreeSlotCalculator.compute(
            busy, settings.copy(durationMin = service.durationMin), LocalDateTime.now(), HORIZON_DAYS,
            maxResults = peekTarget,
        )
        val slots = if (offset < all.size) all.subList(offset, minOf(offset + PAGE_SIZE, all.size)) else emptyList()
        val hasMore = all.size > offset + slots.size
        return Page(slots, hasMore)
    }

    // Identic cu formatServiceDuration din Dart.
    private fun formatDuration(minutes: Int): String {
        if (minutes < 60) return "$minutes min"
        val h = minutes / 60
        val m = minutes % 60
        if (m == 0) return "$h ${if (h == 1) tr("oră", "hour") else tr("ore", "hours")}"
        return "${h}h ${m}min"
    }

    // ── Confirmare opțiune ───────────────────────────────────────────────────────
    private fun confirmOffer(context: Context, sender: String, senderDigits: String, choice: Int) {
        val offer = getOffer(context, senderDigits)
        if (offer == null) {
            sendSms(
                context, sender,
                tr(
                    "Nu am nicio ofertă activă pentru tine. Scrie LIBER pentru a vedea orele libere.",
                    "I have no active offer for you. Text FREE to see the free times.",
                ),
            )
            return
        }
        val boardId = offer.optString("board", "")
        val offset  = offer.optInt("offset", 0)
        val board = BookingSettings.loadBoards(context).firstOrNull { it.id == boardId }
        if (board == null) {
            clearOffer(context, senderDigits)
            return
        }
        val settings = BookingSettings.loadSettings(context, board.id)
        if (bookingLimitReached(context, sender, senderDigits)) {
            clearOffer(context, senderDigits)
            return
        }
        val service = offerService(offer, settings)

        // Recalculăm oferta curentă din nou (nu memorăm sloturile în sine), ca să
        // reflectăm orice schimbare de la ultimul mesaj — inclusiv o eventuală
        // rezervare făcută între timp de alt client, pe același interval.
        val page = computePage(context, board, settings, service, offset)

        if (choice < 1 || choice > page.slots.size) {
            sendSms(
                context, sender,
                tr(
                    "Opțiune invalidă sau expirată. Răspunde cu un număr din ultimul mesaj primit, " +
                        "sau scrie LIBER pentru o căutare nouă.",
                    "Invalid or expired option. Reply with a number from the last message you received, " +
                        "or text FREE for a new search.",
                )
            )
            return
        }

        val slot = page.slots[choice - 1]
        clearOffer(context, senderDigits)
        enqueueBooking(context, board.id, sender, slot.start, slot.end, service)

        val dateSuffix = if (slot.start.toLocalDate() != LocalDateTime.now().toLocalDate())
            " (${slot.start.format(DISPLAY_DATE_FMT)})" else ""
        sendSms(
            context, sender,
            tr(
                "Programarea ta la ${title(board, service)} pe ${slot.start.format(DISPLAY_TIME_FMT)}-" +
                    "${slot.end.format(DISPLAY_TIME_FMT)}$dateSuffix a fost înregistrată. Te așteptăm!",
                "Your appointment at ${title(board, service)}, ${slot.start.format(DISPLAY_TIME_FMT)}-" +
                    "${slot.end.format(DISPLAY_TIME_FMT)}$dateSuffix, has been booked. See you then!",
            ) + noShowWarning(context, sender)
        )
    }

    // ── Neprezentări ─────────────────────────────────────────────────────────────
    // Clientul care a atins pragul de neprezentări nu mai poate rezerva prin
    // SMS (poate doar anula). Explicația pleacă cel mult o dată pe zi; restul
    // cererilor rămân fără răspuns, ca la limita de mesaje.
    private fun blockedForNoShows(context: Context, sender: String, senderDigits: String): Boolean {
        val count = NoShowStore.countFor(context, sender)
        if (!NoShowStore.isBlocked(count, NoShowStore.threshold(context))) return false
        Diag.i("handleMessage: sender blocked for no-shows (count=$count)")
        clearOffer(context, senderDigits)
        val prefs = bookingPrefs(context)
        val notices = try {
            JSONObject(prefs.getString(BLOCK_NOTICE_KEY, "{}") ?: "{}")
        } catch (_: Exception) {
            JSONObject()
        }
        val now = System.currentTimeMillis()
        if (now - notices.optLong(senderDigits, 0L) < DAY_MS) return true
        notices.put(senderDigits, now)
        prefs.edit().putString(BLOCK_NOTICE_KEY, notices.toString()).apply()
        sendSms(
            context, sender,
            tr(
                "Nu mai poți face programări prin SMS din cauza neprezentărilor repetate. " +
                    "Te rugăm să suni la salon.",
                "You can no longer book by SMS because of repeated no-shows. " +
                    "Please call us.",
            )
        )
        return true
    }

    // La o singură neprezentare de prag, clientul e avertizat la confirmare.
    private fun noShowWarning(context: Context, sender: String): String {
        val threshold = NoShowStore.threshold(context)
        val count = NoShowStore.countFor(context, sender)
        if (threshold <= 0 || count <= 0 || count != threshold - 1) return ""
        return tr(
            "\nAtenție: ai $count ${if (count == 1) "neprezentare" else "neprezentări"}. " +
                "La $threshold nu mai poți rezerva prin SMS.",
            "\nNote: you have $count ${if (count == 1) "no-show" else "no-shows"}. " +
                "At $threshold you can no longer book by SMS.",
        )
    }

    // ── Flux „anuleaza” / „anulare” ─────────────────────────────────────────────
    private class CancelCandidate(
        val boardId: String,
        val syncId: String,
        val label: String,
        val start: LocalDateTime,
    )

    // Potrivire telefon-client identică (pe sufix de cifre) cu cea folosită la
    // excluderea partenerului de sincronizare — tolerează formate diferite
    // (+40712345678 / 0712345678 / cu spații).
    private fun phoneMatches(phones: List<String>, senderDigits: String): Boolean {
        for (raw in phones) {
            val itemDigits = digitsOnly(raw)
            if (itemDigits.isEmpty()) continue
            val minLen = minOf(senderDigits.length, itemDigits.length)
            if (minLen < 7) continue
            if (senderDigits.takeLast(minLen) == itemDigits.takeLast(minLen)) return true
        }
        return false
    }

    // Caută, pe toate tabelele, programările viitoare al căror telefon se
    // potrivește cu expeditorul — indiferent dacă au fost create de bot sau
    // adăugate manual din aplicație (orice înregistrare cu telefon completat).
    private fun findActiveBookings(context: Context, senderDigits: String): List<CancelCandidate> {
        val boards = BookingSettings.loadBoards(context)
        val now = LocalDateTime.now()
        val result = mutableListOf<CancelCandidate>()
        for (board in boards) {
            val settings = BookingSettings.loadSettings(context, board.id)
            val items = BookingSettings.loadBookedItems(context, board.id)
            for (item in items) {
                val end = item.expiresAt ?: continue
                if (end.isBefore(now)) continue
                if (!phoneMatches(item.phones, senderDigits)) continue
                val start = end.minusMinutes((item.durationMin ?: settings.durationMin).toLong())
                val dateSuffix = if (start.toLocalDate() != now.toLocalDate())
                    " (${start.format(DISPLAY_DATE_FMT)})" else ""
                val what = if (item.service == null) board.name else "${board.name} – ${item.service}"
                val label = "$what ${start.format(DISPLAY_TIME_FMT)}-${end.format(DISPLAY_TIME_FMT)}$dateSuffix"
                result.add(CancelCandidate(board.id, item.syncId, label, start))
            }
        }
        return result.sortedBy { it.start }
    }

    private fun startCancelFlow(context: Context, sender: String, senderDigits: String) {
        val candidates = findActiveBookings(context, senderDigits)
        when {
            candidates.isEmpty() ->
                sendSms(
                    context, sender,
                    tr(
                        "Nu am găsit nicio programare activă pe acest număr.",
                        "I found no active appointment for this number.",
                    ),
                )
            candidates.size == 1 -> {
                clearCancelOffer(context, senderDigits)
                cancelBooking(context, sender, candidates[0])
            }
            else -> {
                val arr = JSONArray()
                candidates.forEach { c ->
                    val o = JSONObject()
                    o.put("board", c.boardId)
                    o.put("sync", c.syncId)
                    o.put("label", c.label)
                    arr.put(o)
                }
                setCancelOffer(context, senderDigits, arr)
                val lines = candidates.mapIndexed { i, c -> "${i + 1}. ${c.label}" }
                sendSms(
                    context, sender,
                    tr("Ai mai multe programări active:", "You have several active appointments:") +
                        "\n${lines.joinToString("\n")}\n" +
                        tr(
                            "Răspunde cu numărul celei pe care vrei să o anulezi.",
                            "Reply with the number of the one you want to cancel.",
                        )
                )
            }
        }
    }

    private fun confirmCancel(context: Context, sender: String, senderDigits: String, choice: Int) {
        val offer = getCancelOffer(context, senderDigits)
        if (offer == null) {
            sendSms(
                context, sender,
                tr(
                    "Nu am nicio cerere de anulare activă. Scrie ANULEAZA pentru a o relua.",
                    "I have no active cancellation request. Text CANCEL to start again.",
                ),
            )
            return
        }
        val candidates = offer.optJSONArray("candidates") ?: JSONArray()
        if (choice < 1 || choice > candidates.length()) {
            sendSms(
                context, sender,
                tr(
                    "Opțiune invalidă sau expirată. Răspunde cu un număr din ultimul mesaj primit, " +
                        "sau scrie ANULEAZA pentru o căutare nouă.",
                    "Invalid or expired option. Reply with a number from the last message you received, " +
                        "or text CANCEL for a new search.",
                )
            )
            return
        }
        val chosen = candidates.getJSONObject(choice - 1)
        clearCancelOffer(context, senderDigits)
        cancelBooking(
            context, sender,
            CancelCandidate(
                boardId = chosen.optString("board"),
                syncId  = chosen.optString("sync"),
                label   = chosen.optString("label"),
                start   = LocalDateTime.now(), // nefolosit după alegere
            )
        )
    }

    // Scrie ștergerea în coada de sincronizare existentă („ORG:D:”) — Flutter o
    // aplică deja complet (șterge înregistrarea, recalculează sloturile libere,
    // reprogramează notificările), fără cod Dart suplimentar.
    private fun cancelBooking(context: Context, sender: String, candidate: CancelCandidate) {
        enqueueSyncMessage(context, candidate.boardId, "ORG:D:${candidate.syncId}")
        BotReminders.cancel(context, candidate.syncId)
        sendSms(
            context, sender,
            tr(
                "Programarea ta ${candidate.label} a fost anulată.",
                "Your appointment ${candidate.label} has been cancelled.",
            ),
        )
    }

    private fun generateSyncId(): String {
        val chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        val r = SecureRandom()
        return (1..16).map { chars[r.nextInt(chars.length)] }.joinToString("")
    }

    // ── Scrie programarea confirmată în coada de sincronizare existentă ─────────
    // Reutilizează exact protocolul de sincronizare între tabele (mesaj „ORG:A:”)
    // — Flutter va prelua această „programare” la fel ca pe oricare alta primită
    // de la un dispozitiv pereche, cu logica deja existentă de merge/numerotare.
    // createdAt = începutul programării (nu există alt câmp care să reprezinte
    // „ora programării” în formatul compact de sincronizare).
    private fun enqueueBooking(
        context: Context, boardId: String, sender: String,
        start: LocalDateTime, end: LocalDateTime, service: ChosenService,
    ): String {
        val syncId = generateSyncId()
        val item = JSONObject()
        item.put("s", syncId)
        item.put("n", sender)
        item.put("c", start.format(ISO_SHORT))
        item.put("e", end.format(ISO_SHORT))
        item.put("p1", sender)
        // Serviciul și durata — programarea ocupă exact intervalul oferit, chiar
        // dacă salonul schimbă ulterior durata implicită.
        if (service.name != null) item.put("v", service.name)
        item.put("m", service.durationMin)
        // Alerta (reminderul SMS către client) cu intervalul ales în aplicație;
        // fără ea, rezervarea n-ar avea reminder deloc.
        // Ca în aplicație, intervalul se socotește față de data de expirare (e).
        val warning = end.minusMinutes(BookingSettings.loadAlertLeadMin(context, boardId).toLong())
        val hasWarning = warning.isAfter(LocalDateTime.now())
        if (hasWarning) item.put("w", warning.format(ISO_SHORT))
        // Rezervare făcută de client prin bot: telefonul e al clientului, nu
        // un destinatar de alerte — fără SMS „EXPIRAT” la final.
        item.put("b", true)

        enqueueSyncMessage(context, boardId, "ORG:A:$item")
        // Reminderul pleacă și dacă aplicația nu e deschisă până atunci.
        if (hasWarning) BotReminders.schedule(context, syncId, sender, sender, warning, end)
        return syncId
    }

    // Scrie un mesaj în coada de sincronizare existentă (folosită atât pentru
    // rezervări noi „ORG:A:”, cât și pentru anulări „ORG:D:”).
    private fun enqueueSyncMessage(context: Context, boardId: String, msg: String) =
        SmsSyncReceiver.enqueue(context, boardId, msg)

    private fun sendSms(context: Context, phone: String, message: String) {
        SmsSender.send(context, phone, message)
    }
}
