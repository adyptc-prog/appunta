package com.example.management_app

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ClientBookingReceiverTest {

    private lateinit var context: Context
    private val receiver = ClientBookingReceiver()
    private val client = "+40712345678"

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).edit()
            .putString("flutter.management_boards",
                JSONArray().put(JSONObject().put("id", "b1").put("name", "Salon Ana")).toString())
            .putBoolean("flutter.booking_enabled_b1", true)
            .putLong("flutter.appointment_duration_b1", 30L)
            .putLong("flutter.work_start_b1", 0L)
            .putLong("flutter.work_end_b1", 24L * 60 - 1)
            .putString("flutter.management_items_b1", "[]")
            .commit()
        SmsSender.testSink = { phone, message -> sent.add(phone to message) }
    }

    private val sent = mutableListOf<Pair<String, String>>()

    @After
    fun tearDown() {
        SmsSender.testSink = null
    }

    private fun clearSent() = sent.clear()

    // Textul ultimului SMS trimis de bot, sau null dacă n-a trimis nimic.
    private fun lastSent(): String? = sent.lastOrNull()?.second

    private fun queueFutureBooking(syncId: String, daysAhead: Long) {
        val fmt = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm")
        val end = LocalDateTime.now().plusDays(daysAhead).withHour(12).withMinute(0)
        val payload = JSONObject().put("s", syncId).put("n", client)
            .put("c", end.minusMinutes(30).format(fmt)).put("e", end.format(fmt)).put("p1", client)
        SmsSyncReceiver.enqueue(context, "b1", "ORG:A:$payload")
    }

    @Test
    fun `raspunde la LIBER de la un numar de telefon`() {
        receiver.handleMessage(context, client, "liber")
        val sent = lastSent()
        assertNotNull(sent)
        assertTrue(sent!!.startsWith("Ore libere Salon Ana"))
    }

    @Test
    fun `nu raspunde expeditorilor alfanumerici sau numerelor scurte`() {
        receiver.handleMessage(context, "BancaX", "liber")
        receiver.handleMessage(context, "1234", "liber")
        assertNull(lastSent())
    }

    @Test
    fun `peste limita pe ora vine o singura explicatie, apoi botul tace`() {
        repeat(BotLimits.MAX_COMMANDS_PER_NUMBER_PER_HOUR) {
            clearSent()
            receiver.handleMessage(context, client, "liber")
            assertNotNull(lastSent())
        }
        clearSent()
        receiver.handleMessage(context, client, "liber")
        assertTrue(lastSent()!!.startsWith("Ai trimis multe mesaje"))
        assertTrue(Regex("după ora \\d{2}:\\d{2}").containsMatchIn(lastSent()!!))
        clearSent()
        receiver.handleMessage(context, client, "liber")
        receiver.handleMessage(context, client, "3")
        assertNull(lastSent())
    }

    @Test
    fun `al doilea LIBER porneste o lista noua, iar alegerea merge pe ea`() {
        receiver.handleMessage(context, client, "liber")
        receiver.handleMessage(context, client, "liber")
        clearSent()
        receiver.handleMessage(context, client, "3")
        assertTrue(lastSent()!!.startsWith("Programarea ta la Salon Ana"))
    }

    @Test
    fun `cu lista activa sunt acceptate si forme ca 3 punct sau optiunea 3`() {
        for (text in listOf("2.", "opțiunea 2", "Nr. 2", "2)")) {
            context.getSharedPreferences("ClientBookingPrefs", Context.MODE_PRIVATE).edit().clear().commit()
            SmsSyncReceiver.acknowledge(context,
                (0 until JSONArray(SmsSyncReceiver.snapshot(context)).length()).map {
                    JSONArray(SmsSyncReceiver.snapshot(context)).getJSONObject(it).getString("id")
                })
            receiver.handleMessage(context, client, "liber")
            clearSent()
            receiver.handleMessage(context, client, text)
            assertTrue("„$text”: ${lastSent()}", lastSent()!!.startsWith("Programarea ta la Salon Ana"))
        }
    }

    @Test
    fun `fara lista activa formele libere sunt ignorate`() {
        receiver.handleMessage(context, client, "opțiunea 2")
        receiver.handleMessage(context, client, "2.")
        assertNull(lastSent())
    }

    @Test
    fun `text nerecunoscut cu lista activa primeste ajutor o singura data`() {
        receiver.handleMessage(context, client, "liber")
        clearSent()
        receiver.handleMessage(context, client, "vreau mâine dimineață")
        assertTrue(lastSent()!!.startsWith("Nu am înțeles. Răspunde doar cu numărul orei"))
        clearSent()
        receiver.handleMessage(context, client, "alo?")
        assertNull(lastSent())
        // O listă nouă poate primi din nou ajutor.
        receiver.handleMessage(context, client, "liber")
        clearSent()
        receiver.handleMessage(context, client, "alo?")
        assertNotNull(lastSent())
    }

    @Test
    fun `mesajele lungi nu primesc ajutor nici cu lista activa`() {
        receiver.handleMessage(context, client, "liber")
        clearSent()
        receiver.handleMessage(context, client,
            "Salut, ne vedem diseară la cină? Adu te rog și cartea pe care ți-am împrumutat-o.")
        assertNull(lastSent())
    }

    @Test
    fun `textele obisnuite nu consuma din limita`() {
        repeat(30) { receiver.handleMessage(context, client, "salut, ce faci?") }
        receiver.handleMessage(context, client, "liber")
        assertNotNull(lastSent())
    }

    @Test
    fun `cu 2 rezervari active nu se mai ofera ore`() {
        queueFutureBooking("r1", 1)
        queueFutureBooking("r2", 2)

        receiver.handleMessage(context, client, "liber")
        assertTrue(lastSent()!!.startsWith("Ai deja 2 rezervări active"))
    }

    @Test
    fun `a doua rezervare activa e permisa, a treia nu`() {
        queueFutureBooking("r1", 1)
        receiver.handleMessage(context, client, "liber")
        assertTrue(lastSent()!!.startsWith("Ore libere"))
        receiver.handleMessage(context, client, "1")
        assertTrue(lastSent()!!.startsWith("Programarea ta"))

        receiver.handleMessage(context, client, "liber")
        assertTrue(lastSent()!!.startsWith("Ai deja 2 rezervări active"))
    }

    @Test
    fun `tabelul necunoscut nu dezvaluie numele tabelelor`() {
        receiver.handleMessage(context, client, "liber xyz")
        val sent = lastSent()!!
        assertTrue(sent.startsWith("Nu am găsit categoria"))
        assertFalse(sent.contains("Salon Ana"))
    }

    @Test
    fun `numaratoarea zilnica e salvata`() {
        receiver.handleMessage(context, client, "liber")
        val state = JSONObject(
            context.getSharedPreferences("ClientBookingPrefs", Context.MODE_PRIVATE)
                .getString("rateLimits", "{}")!!
        )
        assertEquals(1, state.getInt("dayCount"))
    }

    @Test
    fun `rezervarea facuta de bot e marcata (fara SMS EXPIRAT)`() {
        receiver.handleMessage(context, client, "liber")
        receiver.handleMessage(context, client, "1")
        val arr = JSONArray(SmsSyncReceiver.snapshot(context))
        val msg = arr.getJSONObject(0).getString("msg")
        assertTrue(msg.startsWith("ORG:A:"))
        assertEquals(true, JSONObject(msg.removePrefix("ORG:A:")).getBoolean("b"))
    }

    @Test
    fun `rezervarea facuta de bot primeste alerta cu intervalul ales in aplicatie`() {
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).edit()
            .putLong("flutter.alert_lead_minutes_b1", 15L).commit()
        receiver.handleMessage(context, client, "liber")
        receiver.handleMessage(context, client, "2") // începe peste ≥ 30 min
        val msg = JSONArray(SmsSyncReceiver.snapshot(context)).getJSONObject(0).getString("msg")
        val j = JSONObject(msg.removePrefix("ORG:A:"))
        val fmt = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm")
        // Alerta se socotește față de ora programării (începutul, „c”).
        val start = LocalDateTime.parse(j.getString("c"), fmt)
        assertEquals(start.minusMinutes(15).format(fmt), j.getString("w"))
    }

    @Test
    fun `fara interval salvat alerta e cu o ora inainte, iar una trecuta lipseste`() {
        assertEquals(60, BookingSettings.loadAlertLeadMin(context, "b1"))
        // Alerta cu 60 min înainte de începutul programării: pentru primul slot
        // liber momentul a trecut deja — nu se trimite o alertă inutilă.
        receiver.handleMessage(context, client, "liber")
        receiver.handleMessage(context, client, "1")
        val msg = JSONArray(SmsSyncReceiver.snapshot(context)).getJSONObject(0).getString("msg")
        val j = JSONObject(msg.removePrefix("ORG:A:"))
        val start = LocalDateTime.parse(j.getString("c"), DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm"))
        if (start.minusMinutes(60).isAfter(LocalDateTime.now())) assertTrue(j.has("w"))
        else assertFalse(j.has("w"))
    }

    private fun setNoShows(count: Int, threshold: Int? = null) {
        val dates = JSONArray()
        repeat(count) { dates.put(LocalDateTime.now().minusDays(it + 1L).toString()) }
        val e = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).edit()
            .putString("flutter.no_show_summary", JSONObject().put("712345678", dates).toString())
        if (threshold != null) e.putLong("flutter.no_show_block_threshold", threshold.toLong())
        e.commit()
    }

    @Test
    fun `clientul cu 3 neprezentari e refuzat o data, apoi botul tace`() {
        setNoShows(3)
        receiver.handleMessage(context, client, "liber")
        assertTrue(lastSent()!!.startsWith("Nu mai poți face programări prin SMS"))
        clearSent()
        receiver.handleMessage(context, client, "liber")
        receiver.handleMessage(context, client, "1")
        assertNull(lastSent())
    }

    @Test
    fun `neconfirmatele de peste 24 de ore blocheaza si cu aplicatia inchisa`() {
        setNoShows(2)
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).edit()
            .putString("flutter.no_show_pending", JSONObject().put("712345678",
                JSONArray().put(LocalDateTime.now().minusHours(30).toString())).toString())
            .commit()
        receiver.handleMessage(context, client, "liber")
        assertTrue(lastSent()!!.startsWith("Nu mai poți face programări prin SMS"))
    }

    @Test
    fun `clientul blocat isi poate anula programarea`() {
        queueFutureBooking("r1", 1)
        setNoShows(3)
        receiver.handleMessage(context, client, "anuleaza")
        assertTrue(lastSent()!!.contains("a fost anulată"))
    }

    @Test
    fun `cu o neprezentare sub prag clientul e avertizat la confirmare`() {
        setNoShows(2)
        receiver.handleMessage(context, client, "liber")
        receiver.handleMessage(context, client, "1")
        assertTrue(lastSent()!!.contains("Atenție: ai 2 neprezentări. La 3 nu mai poți rezerva prin SMS."))
    }

    @Test
    fun `pragul ales in aplicatie e respectat, iar 0 dezactiveaza blocarea`() {
        setNoShows(2, threshold = 2)
        receiver.handleMessage(context, client, "liber")
        assertTrue(lastSent()!!.startsWith("Nu mai poți face programări prin SMS"))

        context.getSharedPreferences("ClientBookingPrefs", Context.MODE_PRIVATE).edit().clear().commit()
        setNoShows(5, threshold = 0)
        clearSent()
        receiver.handleMessage(context, client, "liber")
        assertTrue(lastSent()!!.startsWith("Ore libere Salon Ana"))
    }

    @Test
    fun `mesajele de sincronizare ale ambelor aplicatii sunt ignorate`() {
        receiver.handleMessage(context, client, "ORG:D:abc")
        receiver.handleMessage(context, client, "PEN:D:abc")
        assertNull(lastSent())
    }
}

