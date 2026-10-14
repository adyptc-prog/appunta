package com.example.management_app

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.LocalDateTime

/** Fiecare programare ocupă durata serviciului ei, nu durata comună a tabelului. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ServiceDurationTest {

    private lateinit var context: Context

    private fun at(h: Int, m: Int = 0) = LocalDateTime.of(2030, 1, 14, h, m)

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        val items = JSONArray()
            // Gel, 90 min: 09:00–10:30.
            .put(
                JSONObject().put("syncId", "gel").put("expiresAt", "2030-01-14T10:30:00.000")
                    .put("phoneNumber", "0711111111").put("service", "Gel").put("durationMin", 90)
            )
            // Programare veche, fără durată: durata implicită (30) → 11:30–12:00.
            .put(
                JSONObject().put("syncId", "vechi").put("expiresAt", "2030-01-14T12:00:00.000")
                    .put("phoneNumber", "0722222222")
            )
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).edit()
            .putString("flutter.management_items_b1", items.toString())
            .commit()
        // Rezervare din coadă, încă neprocesată: 60 min, 13:00–14:00.
        val queued = JSONObject().put("s", "coada").put("n", "x").put("c", "2030-01-14T13:00")
            .put("e", "2030-01-14T14:00").put("p1", "0733333333").put("v", "Semi").put("m", 60)
        context.getSharedPreferences(SmsSyncReceiver.PREFS_NAME, Context.MODE_PRIVATE).edit()
            .putString(
                SmsSyncReceiver.QUEUE_KEY,
                JSONArray().put(JSONObject().put("id", "1").put("board", "b1").put("msg", "ORG:A:$queued")).toString(),
            )
            .commit()
    }

    @Test
    fun `intervalele ocupate folosesc durata fiecarei programari`() {
        val busy = BookingSettings.loadBusyIntervals(context, "b1", 30).sortedBy { it.startMin }
        assertEquals(
            listOf(at(9) to at(10, 30), at(11, 30) to at(12), at(13) to at(14)),
            busy.map { it.startMin to it.endMin },
        )
    }

    @Test
    fun `programarile citite pentru anulare au serviciul si durata`() {
        val items = BookingSettings.loadBookedItems(context, "b1").associateBy { it.syncId }
        assertEquals(90, items["gel"]!!.durationMin)
        assertEquals("Gel", items["gel"]!!.service)
        assertEquals(null, items["vechi"]!!.durationMin)
        assertEquals(60, items["coada"]!!.durationMin)
        assertEquals("Semi", items["coada"]!!.service)
    }

    @Test
    fun `orele libere nu se suprapun cu programarile de durate diferite`() {
        val settings = BoardBookingSettings(
            enabled = true, durationMin = 60, workHours = mapOf(1 to DayHours(9 * 60, 15 * 60)),
        )
        val busy = BookingSettings.loadBusyIntervals(context, "b1", 30)
        val slots = FreeSlotCalculator.compute(busy, settings, at(8), horizonDays = 0, maxResults = 10)
        // 10:30–11:30 (până la programarea veche), apoi 12:00–13:00, apoi 14:00–15:00.
        assertEquals(
            listOf(at(10, 30) to at(11, 30), at(12) to at(13), at(14) to at(15)),
            slots.map { it.start to it.end },
        )
    }
}
