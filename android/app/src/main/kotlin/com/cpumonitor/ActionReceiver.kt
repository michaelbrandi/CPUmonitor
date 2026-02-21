package com.cpumonitor

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager

class ActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_STOP             = "com.cpumonitor.STOP"
        const val ACTION_TOGGLE_AUTOSTART = "com.cpumonitor.TOGGLE_AUTOSTART"

        fun autostartEnabled(context: Context): Boolean {
            val state = context.packageManager.getComponentEnabledSetting(
                ComponentName(context, BootReceiver::class.java)
            )
            return state != PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_STOP -> {
                context.stopService(Intent(context, CpuMonitorService::class.java))
            }
            ACTION_TOGGLE_AUTOSTART -> {
                val pm = context.packageManager
                val receiver = ComponentName(context, BootReceiver::class.java)
                val nowEnabled = autostartEnabled(context)
                pm.setComponentEnabledSetting(
                    receiver,
                    if (nowEnabled) PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                    else            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                    PackageManager.DONT_KILL_APP
                )
                // Poke the service so it refreshes the notification label
                context.startService(Intent(context, CpuMonitorService::class.java))
            }
        }
    }
}
