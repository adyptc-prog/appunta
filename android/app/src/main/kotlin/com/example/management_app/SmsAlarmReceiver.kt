package com.example.management_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.json.JSONObject

class SmsAlarmReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val alarmId = intent.getIntExtra("sms_alarm_id", -1)
        if (alarmId < 0) return

        // goAsync() extinde limita de timp la 60s și eliberează main thread-ul
        val pending = goAsync()

        Thread {
            try {
                // Citim datele din SharedPreferences Flutter
                // Reminderele provizorii ale botului au datele separat.
                val json = if (BotReminders.isBotReminderId(alarmId)) {
                    BotReminders.payload(context, alarmId) ?: return@Thread
                } else {
                    val prefs = context.getSharedPreferences(
                        "FlutterSharedPreferences", Context.MODE_PRIVATE
                    )
                    JSONObject(prefs.getString("flutter.sms_alarm_$alarmId", null) ?: return@Thread)
                }
                // optString întoarce textul "null" pentru o valoare JSON null —
                // fără verificare, SMS-ul pleca spre numărul „null”.
                val phone   = if (json.isNull("phone")) "" else json.optString("phone").trim()
                val message = if (json.isNull("message")) "" else json.optString("message")

                if (phone.isBlank() || message.isBlank()) return@Thread

                // Reminderele SMS cer licență sau trial activ — verificat la
                // trimitere, deci și pentru alarmele programate înainte.
                if (!Entitlement.isActive(context)) {
                    Diag.i("SmsAlarmReceiver: no license and trial expired, SMS not sent")
                    return@Thread
                }

                // Împărțit în segmente: un text cu diacritice peste 70 de
                // caractere nu pleacă altfel (sendTextMessage eșua silențios).
                SmsSender.send(context, phone, message)

                // Nu ștergem cheia din SharedPreferences din receiver:
                // evităm accesul concurent cu Flutter care poate provoca crash
                // Cheia va fi curățată de Dart la próxima reprogramare / ștergere
            } catch (_: Exception) {
                // Erorile sunt silențioase pentru a nu crash-ui procesul
            } finally {
                pending.finish()
            }
        }.start()
    }
}
