package com.example.management_app

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.LocalDateTime

/** Programul de lucru pe zile: fiecare zi lucrătoare are intervalul ei orar. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class WorkHoursTest {

    private lateinit var context: Context

    private fun prefs() = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
    }

    @Test
    fun `programul pe zile se citeste din formatul scris de aplicatie`() {
        prefs().edit().putString("flutter.work_hours_b1", "1:540-1080,3:600-840").commit()
        assertEquals(
            mapOf(1 to DayHours(540, 1080), 3 to DayHours(600, 840)),
            BookingSettings.loadSettings(context, "b1").workHours,
        )
    }

    @Test
    fun `intrarile invalide sunt sarite`() {
        assertEquals(
            mapOf(2 to DayHours(60, 120)),
            BookingSettings.parseWorkHours("0:60-120,8:60-120,1:120-60,x,2:60-120,3:60-1500"),
        )
    }

    @Test
    fun `nicio zi bifata inseamna nicio zi lucratoare`() {
        prefs().edit()
            .putString("flutter.work_hours_b1", "")
            .putLong("flutter.work_start_b1", 0L)
            .putLong("flutter.work_end_b1", 600L)
            .commit()
        assertEquals(emptyMap<Int, DayHours>(), BookingSettings.loadSettings(context, "b1").workHours)
    }

    @Test
    fun `setarile vechi devin acelasi program in zilele deschise`() {
        prefs().edit()
            .putLong("flutter.work_start_b1", 8L * 60)
            .putLong("flutter.work_end_b1", 16L * 60)
            .putString("flutter.closed_days_b1", "6,7")
            .commit()
        assertEquals(
            (1..5).associateWith { DayHours(8 * 60, 16 * 60) },
            BookingSettings.loadSettings(context, "b1").workHours,
        )
    }

    @Test
    fun `orele libere respecta programul fiecarei zile`() {
        // 2030-01-14 = luni; marți închis; miercuri program scurt.
        val settings = BoardBookingSettings(
            enabled = true, durationMin = 60,
            workHours = mapOf(1 to DayHours(9 * 60, 11 * 60), 3 to DayHours(14 * 60, 15 * 60)),
        )
        val slots = FreeSlotCalculator.compute(
            emptyList(), settings, LocalDateTime.of(2030, 1, 14, 8, 0), horizonDays = 2, maxResults = 10,
        )
        assertEquals(
            listOf(
                LocalDateTime.of(2030, 1, 14, 9, 0),
                LocalDateTime.of(2030, 1, 14, 10, 0),
                LocalDateTime.of(2030, 1, 16, 14, 0),
            ),
            slots.map { it.start },
        )
    }
}
