package com.example.management_app

import java.time.Duration
import java.time.LocalDateTime

data class FreeSlot(val start: LocalDateTime, val end: LocalDateTime)

/**
 * Calculează sloturile libere ale unui tabel, ținând cont de programul de lucru,
 * zilele închise și intervalele deja ocupate. Folosită atât pentru afișarea
 * rândurilor libere din aplicație (pe Android, prin MethodChannel) cât și pentru botul
 * SMS de rezervări — o singură implementare pe platforma unde contează.
 *
 * Sloturile se aliniază la începutul programului de lucru (sau la finalul
 * programării anterioare) — echivalent cu formula veche din Dart
 * (gap/durată - 1 pentru goluri dintre programări), extinsă să acopere și
 * marginile zilei (înainte de prima programare / după ultima).
 */
object FreeSlotCalculator {

    fun compute(
        busy: List<BusyInterval>,
        settings: BoardBookingSettings,
        from: LocalDateTime,
        horizonDays: Int,
        maxResults: Int,
    ): List<FreeSlot> {
        if (settings.durationMin <= 0 || maxResults <= 0) return emptyList()
        val duration = settings.durationMin.toLong()
        val result = mutableListOf<FreeSlot>()
        val sortedBusy = busy.sortedBy { it.startMin }

        var day = from.toLocalDate()
        val lastDay = day.plusDays(horizonDays.toLong())

        while (!day.isAfter(lastDay) && result.size < maxResults) {
            val hours = settings.workHours[day.dayOfWeek.value]
            if (hours != null) {
                val dayStart = day.atStartOfDay().plusMinutes(hours.startMin.toLong())
                val dayEnd = day.atStartOfDay().plusMinutes(hours.endMin.toLong())
                var cursor = if (dayStart.isBefore(from)) roundUpToSlot(from, dayStart, duration) else dayStart

                val dayBusy = sortedBusy.filter { it.endMin.isAfter(dayStart) && it.startMin.isBefore(dayEnd) }
                for (b in dayBusy) {
                    if (result.size >= maxResults) break
                    val busyStart = if (b.startMin.isBefore(cursor)) cursor else b.startMin
                    while (result.size < maxResults && !cursor.plusMinutes(duration).isAfter(busyStart)) {
                        result.add(FreeSlot(cursor, cursor.plusMinutes(duration)))
                        cursor = cursor.plusMinutes(duration)
                    }
                    if (b.endMin.isAfter(cursor)) cursor = b.endMin
                }
                while (result.size < maxResults && !cursor.plusMinutes(duration).isAfter(dayEnd)) {
                    result.add(FreeSlot(cursor, cursor.plusMinutes(duration)))
                    cursor = cursor.plusMinutes(duration)
                }
            }
            day = day.plusDays(1)
        }

        return result
    }

    private fun roundUpToSlot(from: LocalDateTime, dayStart: LocalDateTime, durationMin: Long): LocalDateTime {
        if (!from.isAfter(dayStart)) return dayStart
        val minutesFromStart = Duration.between(dayStart, from).toMinutes()
        val slots = (minutesFromStart + durationMin - 1) / durationMin
        return dayStart.plusMinutes(slots * durationMin)
    }
}
