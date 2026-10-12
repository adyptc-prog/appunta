package com.example.management_app

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.LocalDateTime

/**
 * Botul răspunde în limba aleasă în aplicație pe telefonul care primește
 * SMS-ul, dar înțelege mereu cuvintele-cheie din ambele limbi.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class BotLanguageTest {

    private lateinit var context: Context
    private val receiver = ClientBookingReceiver()
    private val client = "+40712345678"
    private val sent = mutableListOf<Pair<String, String>>()

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

    @After
    fun tearDown() {
        SmsSender.testSink = null
        AppLang.setForTest(false)
    }

    private fun setAppLanguage(lang: String) {
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).edit()
            .putString(AppLang.PREF_KEY, lang).commit()
    }

    private fun say(text: String): String? {
        sent.clear()
        receiver.handleMessage(context, client, text)
        return sent.lastOrNull()?.second
    }

    @Test
    fun `aplicatia in engleza - fluxul complet raspunde in engleza`() {
        setAppLanguage("en")

        val offer = say("free")
        assertNotNull(offer)
        assertTrue(offer!!, offer.startsWith("Free times, Salon Ana:\n1. "))
        assertTrue(offer, offer.contains("Reply with the option number to book"))

        val confirmation = say("1")
        assertNotNull(confirmation)
        assertTrue(confirmation!!, confirmation.startsWith("Your appointment at Salon Ana, "))
        assertTrue(confirmation, confirmation.contains(", has been booked. See you then!"))

        val cancelled = say("cancel")
        assertNotNull(cancelled)
        assertTrue(cancelled!!, cancelled.startsWith("Your appointment Salon Ana "))
        assertTrue(cancelled, cancelled.endsWith(" has been cancelled."))
    }

    @Test
    fun `aplicatia in engleza intelege si cuvintele romanesti`() {
        setAppLanguage("en")
        assertTrue(say("Liber")!!.startsWith("Free times, Salon Ana:"))
        assertTrue(say("optiunea 1")!!.startsWith("Your appointment at Salon Ana, "))
        assertTrue(say("anulează")!!.endsWith(" has been cancelled."))
    }

    @Test
    fun `aplicatia in romana intelege si cuvintele englezesti`() {
        setAppLanguage("ro")
        assertTrue(say("FREE")!!.startsWith("Ore libere Salon Ana:"))
        assertTrue(say("option 1")!!.startsWith("Programarea ta la Salon Ana pe "))
        assertTrue(say("Cancel my appointment")!!.endsWith(" a fost anulată."))
    }

    @Test
    fun `fara alegere in aplicatie botul foloseste limba telefonului`() {
        // Telefonul simulat e în română (build.gradle.kts).
        assertTrue(say("free")!!.startsWith("Ore libere Salon Ana:"))
    }

    @Test
    fun `ajutorul si mesajele de eroare sunt in limba aplicatiei`() {
        setAppLanguage("en")
        say("free")
        assertEquals(
            "I didn't understand. Reply with just the number of the time you want (e.g. 2), " +
                "NEXT for other times or FREE for a new search.",
            say("hello there"),
        )
        assertEquals(
            "I couldn't find the category \"atlantida\". Text FREE for the list of categories.",
            say("free atlantida"),
        )
        assertEquals("I found no active appointment for this number.", say("cancel"))
    }

    @Test
    fun `lista categoriilor foloseste cuvantul-cheie din limba aplicatiei`() {
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).edit()
            .putString("flutter.management_boards",
                JSONArray()
                    .put(JSONObject().put("id", "b1").put("name", "Tuns"))
                    .put(JSONObject().put("id", "b2").put("name", "Manichiura")).toString())
            .putBoolean("flutter.booking_enabled_b2", true)
            .putLong("flutter.appointment_duration_b2", 30L)
            .putLong("flutter.work_start_b2", 0L)
            .putLong("flutter.work_end_b2", 24L * 60 - 1)
            .putString("flutter.management_items_b2", "[]")
            .commit()

        val ro = say("liber")
        assertNotNull(ro)
        assertTrue(ro!!, ro.startsWith("Pentru ce categorie dorești programare? Scrie:\nLIBER "))

        setAppLanguage("en")
        val en = say("free")
        assertNotNull(en)
        assertTrue(en!!, en.startsWith("Which category do you want an appointment for? Text:\nFREE "))
        // Răspunsul cu cuvântul englezesc + numele categoriei e înțeles.
        assertTrue(say("free manichiura")!!.startsWith("Free times, Manichiura:"))
    }

    @Test
    fun `un SMS personal in engleza ramane fara raspuns`() {
        setAppLanguage("en")
        assertEquals(null, say("are you free tonight for dinner?"))
        assertEquals(null, say("please cancel"))
    }

    @Test
    fun `mesajul de reminder implicit urmeaza limba, cel editat ramane neatins`() {
        val at = LocalDateTime.of(2027, 3, 5, 11, 0)
        assertEquals(BotReminders.DEFAULT_TEMPLATE_RO, BotReminders.effectiveTemplate(null))
        assertEquals(BotReminders.DEFAULT_TEMPLATE_RO, BotReminders.effectiveTemplate(BotReminders.DEFAULT_TEMPLATE_EN))

        AppLang.setForTest(true)
        assertEquals(BotReminders.DEFAULT_TEMPLATE_EN, BotReminders.effectiveTemplate(null))
        assertEquals(BotReminders.DEFAULT_TEMPLATE_EN, BotReminders.effectiveTemplate(BotReminders.DEFAULT_TEMPLATE_RO))
        assertEquals("Textul meu [NUME]", BotReminders.effectiveTemplate("Textul meu [NUME]"))
        assertEquals(
            "Reminder: Ana. It expires on 05.03.2027 11:00. Please take the necessary steps.",
            BotReminders.buildMessage(BotReminders.effectiveTemplate(null), "Ana", at),
        )
        assertEquals(
            "Ana/Ana 05.03.2027 11:00/05.03.2027 11:00",
            BotReminders.buildMessage("[NUME]/[NAME] [DATA_EXPIRARE]/[EXPIRY_DATE]", "Ana", at),
        )
    }

    @Test
    fun `regula de limba - alegerea din aplicatie, altfel limba telefonului`() {
        assertTrue(AppLang.resolveIsEn("en", "ro"))
        assertFalse(AppLang.resolveIsEn("ro", "en"))
        assertFalse(AppLang.resolveIsEn(null, "ro"))
        assertTrue(AppLang.resolveIsEn(null, "en"))
        assertTrue(AppLang.resolveIsEn(null, "de"))
        assertFalse(BackupFormat.isBackedUpKey(AppLang.PREF_KEY))
    }
}
