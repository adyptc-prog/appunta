package com.example.management_app

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.Duration
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

/** Botul cu categorii (tabele) și servicii: liber → categorie → serviciu → oră. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ClientBookingServicesTest {

    private lateinit var context: Context
    private val receiver = ClientBookingReceiver()
    private val client = "+40712345678"
    private val sent = mutableListOf<String>()
    private val fmt = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm")

    private fun services(vararg s: Pair<String, Int>) =
        JSONArray().also { arr -> s.forEach { arr.put(JSONObject().put("n", it.first).put("m", it.second)) } }.toString()

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        val boards = JSONArray()
            .put(JSONObject().put("id", "b1").put("name", "Unghii"))
            .put(JSONObject().put("id", "b2").put("name", "Păr"))
            .put(JSONObject().put("id", "b3").put("name", "Gene false"))
            .put(JSONObject().put("id", "b4").put("name", "Masaj"))
        val e = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).edit()
            .putString("flutter.management_boards", boards.toString())
        for (id in listOf("b1", "b2", "b3", "b4")) {
            e.putBoolean("flutter.booking_enabled_$id", id != "b4")
                .putLong("flutter.appointment_duration_$id", 30L)
                .putLong("flutter.work_start_$id", 0L)
                .putLong("flutter.work_end_$id", 24L * 60 - 1)
                .putString("flutter.management_items_$id", "[]")
        }
        e.putString("flutter.services_b1", services("Semipermanentă" to 60, "Gel" to 90, "Ojă" to 30))
            .putString("flutter.services_b2", services("Tuns" to 45))
            .commit()
        SmsSender.testSink = { _, message -> sent.add(message) }
    }

    @After
    fun tearDown() {
        SmsSender.testSink = null
    }

    private fun last(): String? = sent.lastOrNull()

    private fun queued(): List<JSONObject> {
        val arr = JSONArray(SmsSyncReceiver.snapshot(context))
        return (0 until arr.length()).map { JSONObject(arr.getJSONObject(it).getString("msg").removePrefix("ORG:A:")) }
    }

    // Prima oră oferită, din SMS-ul „Ore libere …”: „1. 10:00-11:30 …”.
    private fun firstSlotMinutes(text: String): Long {
        val m = Regex("""1\. (\d{2}):(\d{2})-(\d{2}):(\d{2})""").find(text)!!
        val (h1, m1, h2, m2) = m.destructured
        val start = h1.toLong() * 60 + m1.toLong()
        var end = h2.toLong() * 60 + m2.toLong()
        if (end < start) end += 24 * 60
        return end - start
    }

    @Test
    fun `LIBER fara categorie trimite lista numerotata a categoriilor active`() {
        receiver.handleMessage(context, client, "liber")
        // Categoria fără rezervări active (Masaj) nu apare.
        assertEquals(
            "Pentru ce categorie dorești programare?\n1. Unghii\n2. Păr\n3. Gene false\n" +
                "Răspunde cu numărul categoriei dorite.",
            last(),
        )
    }

    @Test
    fun `fluxul complet cu categoria aleasa dupa numar`() {
        receiver.handleMessage(context, client, "liber")
        receiver.handleMessage(context, client, "1")
        assertTrue(last()!!, last()!!.startsWith("Servicii Unghii:\n1. Semipermanentă"))

        receiver.handleMessage(context, client, "2")
        assertTrue(last()!!, last()!!.startsWith("Ore libere Unghii – Gel:"))

        receiver.handleMessage(context, client, "1")
        assertTrue(last()!!, last()!!.startsWith("Programarea ta la Unghii – Gel pe "))
        assertEquals("Gel", queued().single().getString("v"))
    }

    @Test
    fun `categoria cu un singur serviciu aleasa dupa numar merge direct la ore`() {
        receiver.handleMessage(context, client, "liber")
        receiver.handleMessage(context, client, "optiunea 2")
        assertTrue(last()!!, last()!!.startsWith("Ore libere Păr – Tuns:"))
    }

    @Test
    fun `numar de categorie invalid si text neinteles`() {
        receiver.handleMessage(context, client, "liber")
        receiver.handleMessage(context, client, "7")
        assertTrue(last()!!, last()!!.startsWith("Opțiune invalidă. Răspunde cu numărul unei categorii"))

        receiver.handleMessage(context, client, "unghii")
        assertEquals("Nu am înțeles. Răspunde doar cu numărul categoriei dorite (ex. 1).", last())

        // Lista rămâne activă: alegerea corectă merge în continuare.
        receiver.handleMessage(context, client, "3")
        assertTrue(last()!!, last()!!.startsWith("Ore libere Gene false:"))
    }

    @Test
    fun `numerele se raporteaza la lista trimisa, nu la tabelele activate ulterior`() {
        receiver.handleMessage(context, client, "liber")
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).edit()
            .putBoolean("flutter.booking_enabled_b1", false)
            .commit()
        // „2” rămâne Păr, deși acum Unghii nu mai e activă.
        receiver.handleMessage(context, client, "2")
        assertTrue(last()!!, last()!!.startsWith("Ore libere Păr – Tuns:"))
    }

    @Test
    fun `cu o singura categorie activa LIBER merge direct mai departe`() {
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).edit()
            .putBoolean("flutter.booking_enabled_b1", false)
            .putBoolean("flutter.booking_enabled_b3", false)
            .commit()
        receiver.handleMessage(context, client, "liber")
        // Păr are un singur serviciu — direct orele.
        assertTrue(last()!!, last()!!.startsWith("Ore libere Păr – Tuns"))
    }

    @Test
    fun `fluxul complet categorie, serviciu, ora`() {
        receiver.handleMessage(context, client, "Liber unghii")
        assertEquals(
            "Servicii Unghii:\n1. Semipermanentă (1 oră)\n2. Gel (1h 30min)\n3. Ojă (30 min)\n" +
                "Răspunde cu numărul serviciului dorit.",
            last(),
        )

        receiver.handleMessage(context, client, "2")
        assertTrue(last()!!, last()!!.startsWith("Ore libere Unghii – Gel:"))
        assertEquals(90L, firstSlotMinutes(last()!!))

        receiver.handleMessage(context, client, "1")
        assertTrue(last()!!, last()!!.startsWith("Programarea ta la Unghii – Gel pe "))
        val booking = queued().single()
        assertEquals("Gel", booking.getString("v"))
        assertEquals(90, booking.getInt("m"))
        val start = LocalDateTime.parse(booking.getString("c"), fmt)
        val end = LocalDateTime.parse(booking.getString("e"), fmt)
        assertEquals(90L, Duration.between(start, end).toMinutes())
    }

    @Test
    fun `NEXT pastreaza serviciul ales`() {
        receiver.handleMessage(context, client, "liber unghii")
        receiver.handleMessage(context, client, "3")
        receiver.handleMessage(context, client, "next")
        assertTrue(last()!!, last()!!.startsWith("Ore libere Unghii – Ojă:"))
        assertEquals(30L, firstSlotMinutes(last()!!))
    }

    @Test
    fun `orele noi nu se suprapun cu o programare mai lunga`() {
        receiver.handleMessage(context, client, "liber unghii")
        receiver.handleMessage(context, client, "2") // Gel, 90 min
        receiver.handleMessage(context, client, "1")
        val gel = queued().single()
        val gelStart = LocalDateTime.parse(gel.getString("c"), fmt)
        val gelEnd = LocalDateTime.parse(gel.getString("e"), fmt)

        // Alt client vrea Ojă (30 min): nicio oră oferită nu intră în Gel.
        val other = "+40799888777"
        receiver.handleMessage(context, other, "liber unghii")
        receiver.handleMessage(context, other, "3")
        val offered = Regex("""\d+\. (\d{2}):(\d{2})-""").findAll(last()!!).map {
            val (h, m) = it.destructured
            h.toInt() * 60 + m.toInt()
        }.toList()
        assertTrue(offered.isNotEmpty())
        val gelFrom = gelStart.hour * 60 + gelStart.minute
        val gelTo = gelEnd.hour * 60 + gelEnd.minute
        if (gelFrom < gelTo) {
            for (start in offered) {
                assertTrue("$start în $gelFrom..$gelTo", start + 30 <= gelFrom || start >= gelTo)
            }
        }
    }

    @Test
    fun `un singur serviciu nu mai e intrebat`() {
        receiver.handleMessage(context, client, "liber par")
        assertTrue(last()!!.startsWith("Ore libere Păr – Tuns:"))
        assertEquals(45L, firstSlotMinutes(last()!!))
        receiver.handleMessage(context, client, "1")
        assertEquals("Tuns", queued().single().getString("v"))
    }

    @Test
    fun `fara servicii se foloseste durata implicita`() {
        receiver.handleMessage(context, client, "liber gene false")
        assertTrue(last()!!, last()!!.startsWith("Ore libere Gene false:"))
        assertEquals(30L, firstSlotMinutes(last()!!))
        receiver.handleMessage(context, client, "1")
        val b = queued().single()
        assertFalse(b.has("v"))
        assertEquals(30, b.getInt("m"))
    }

    @Test
    fun `numar invalid la servicii`() {
        receiver.handleMessage(context, client, "liber unghii")
        receiver.handleMessage(context, client, "7")
        assertTrue(last()!!.startsWith("Opțiune invalidă"))
        assertTrue(queued().isEmpty())
    }

    @Test
    fun `text nerecunoscut la lista de servicii primeste ajutor`() {
        receiver.handleMessage(context, client, "liber unghii")
        receiver.handleMessage(context, client, "cu gel vreau")
        assertTrue(last()!!.startsWith("Nu am înțeles. Răspunde doar cu numărul serviciului"))
    }

    @Test
    fun `categoria inactiva sau necunoscuta`() {
        receiver.handleMessage(context, client, "liber masaj")
        assertEquals("Rezervările prin SMS nu sunt active pentru Masaj.", last())
        receiver.handleMessage(context, client, "liber xyz")
        assertTrue(last()!!.startsWith("Nu am găsit categoria"))
        // O literă nu nimerește o categorie la întâmplare.
        receiver.handleMessage(context, client, "liber a")
        assertTrue(last()!!.startsWith("Nu am găsit categoria"))
    }

    @Test
    fun `numele aproximativ al categoriei e recunoscut`() {
        receiver.handleMessage(context, client, "liber unghi")
        assertTrue(last()!!.startsWith("Servicii Unghii"))
    }

    @Test
    fun `lista de anulare arata serviciul`() {
        receiver.handleMessage(context, client, "liber unghii")
        receiver.handleMessage(context, client, "2")
        receiver.handleMessage(context, client, "1")
        receiver.handleMessage(context, client, "liber par")
        receiver.handleMessage(context, client, "1")
        receiver.handleMessage(context, client, "anuleaza")
        val text = last()!!
        assertTrue(text, text.contains("Unghii – Gel"))
        assertTrue(text, text.contains("Păr – Tuns"))
    }

    @Test
    fun `noul LIBER inlocuieste lista de servicii`() {
        receiver.handleMessage(context, client, "liber unghii")
        receiver.handleMessage(context, client, "liber par")
        receiver.handleMessage(context, client, "1")
        // „1” se referă la orele pentru Tuns, nu la Semipermanentă.
        assertTrue(last()!!.startsWith("Programarea ta la Păr – Tuns"))
        assertNull(queued().single().optString("v").takeIf { it != "Tuns" })
    }
}
