package com.example.management_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONObject

class NotifAlarmReceiver : BroadcastReceiver() {

    companion object {
        const val CHANNEL_ID = "organizator_alerts"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val alarmId = intent.getIntExtra("notif_alarm_id", -1)
        if (alarmId < 0) return
        AppLang.sync(context)

        try {
            val prefs   = context.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE
            )
            val dataStr = prefs.getString("flutter.notif_alarm_$alarmId", null) ?: return

            val json  = JSONObject(dataStr)
            val title = json.optString("title", "Appunta")
            val body  = json.optString("body", "")

            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    tr("Alerte Appunta", "Appunta alerts"),
                    NotificationManager.IMPORTANCE_HIGH
                ).apply { enableVibration(true) }
                nm.createNotificationChannel(channel)
            }

            val iconRes = context.resources.getIdentifier(
                "ic_launcher", "mipmap", context.packageName
            )
            val icon = if (iconRes != 0) iconRes else android.R.drawable.ic_dialog_info

            val notif: Notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
                    .setSmallIcon(icon)
                    .setContentTitle(title)
                    .setContentText(body)
                    .setAutoCancel(true)
                    .build()
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
                    .setSmallIcon(icon)
                    .setContentTitle(title)
                    .setContentText(body)
                    .setPriority(Notification.PRIORITY_HIGH)
                    .setAutoCancel(true)
                    .build()
            }

            nm.notify(alarmId, notif)
        } catch (_: Exception) {}
    }
}
