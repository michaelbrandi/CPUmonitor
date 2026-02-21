package com.cpumonitor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.drawable.Icon
import android.os.IBinder
import java.util.Timer
import java.util.TimerTask
import kotlin.math.min
import kotlin.math.roundToInt

class CpuMonitorService : Service() {

    private val CPU_THRESHOLD     = 90.0
    private val DURATION_MS       = 60_000L
    private val CHECK_INTERVAL_MS = 5_000L

    private val STATUS_CHANNEL  = "cpu_status"
    private val STATUS_NOTIF_ID = 1

    private val highCpuStart   = mutableMapOf<Int, Long>()   // PID → when it crossed threshold
    private val alertedProcs   = mutableMapOf<Int, String>()  // PID → name, once 60s elapsed

    // Icons created once; Icon wrappers cached so we never re-marshal bitmap data on every tick
    private val bitmaps  by lazy { generateBitmaps() }
    private val iconObjs by lazy { bitmaps.map { Icon.createWithBitmap(it) } }

    // Track last-posted state so we only call notify() when something actually changed
    private var lastIconIndex  = -1
    private var lastAutostart  = false

    private val nm by lazy { getSystemService(NotificationManager::class.java) }
    private var timer: Timer? = null

    // MARK: Lifecycle

    override fun onCreate() {
        super.onCreate()
        createChannels()
        lastAutostart = ActionReceiver.autostartEnabled(this)
        startForeground(STATUS_NOTIF_ID, buildStatusNotification(0))
        lastIconIndex = 0

        timer = Timer("CpuMonitor", true)
        timer?.scheduleAtFixedRate(object : TimerTask() {
            override fun run() { checkCpu() }
        }, CHECK_INTERVAL_MS, CHECK_INTERVAL_MS)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Called when ActionReceiver pokes us after toggling autostart — refresh notification
        val autostart = ActionReceiver.autostartEnabled(this)
        if (autostart != lastAutostart) {
            lastAutostart = autostart
            nm.notify(STATUS_NOTIF_ID, buildStatusNotification(lastIconIndex))
        }
        return START_STICKY
    }

    override fun onDestroy() {
        timer?.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // MARK: CPU check

    private fun checkCpu() {
        val processes = CpuSampler.sample(this)
        val now = System.currentTimeMillis()
        val currentHighPids = mutableSetOf<Int>()

        var notifDirty = false

        for (proc in processes) {
            if (proc.cpuPercent < CPU_THRESHOLD) continue
            currentHighPids.add(proc.pid)

            if (proc.pid !in highCpuStart) {
                highCpuStart[proc.pid] = now
            } else {
                val elapsed = now - (highCpuStart[proc.pid] ?: now)
                if (elapsed >= DURATION_MS && proc.pid !in alertedProcs) {
                    alertedProcs[proc.pid] = proc.name
                    notifDirty = true   // alert text changed — force notification update
                }
            }
        }

        // Processes that dropped below threshold — auto-dismiss, same as macOS/Linux
        val gone = highCpuStart.keys - currentHighPids
        for (pid in gone) {
            highCpuStart.remove(pid)
            if (alertedProcs.remove(pid) != null) notifDirty = true
        }

        val iconIndex = if (highCpuStart.isEmpty()) {
            0
        } else {
            val maxElapsed = highCpuStart.values.maxOf { now - it }
            val progress = (maxElapsed.toDouble() / DURATION_MS).coerceIn(0.0, 1.0)
            (progress * 12).roundToInt()
        }

        if (iconIndex != lastIconIndex) {
            lastIconIndex = iconIndex
            notifDirty = true
        }

        if (notifDirty) {
            nm.notify(STATUS_NOTIF_ID, buildStatusNotification(iconIndex))
        }
    }

    // MARK: Notifications

    private fun buildStatusNotification(iconStep: Int): Notification {
        val label = when {
            alertedProcs.isNotEmpty() ->
                "High CPU: ${alertedProcs.values.joinToString(", ")}"
            iconStep == 0 -> "CPU normal"
            else          -> "High CPU detected"
        }
        val icon = iconObjs[iconStep]

        val autostartLabel = if (ActionReceiver.autostartEnabled(this))
            "Run on login: ON" else "Run on login: OFF"

        val toggleIntent = PendingIntent.getBroadcast(
            this, 0,
            Intent(ActionReceiver.ACTION_TOGGLE_AUTOSTART).setClass(this, ActionReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val stopIntent = PendingIntent.getBroadcast(
            this, 1,
            Intent(ActionReceiver.ACTION_STOP).setClass(this, ActionReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )

        return Notification.Builder(this, STATUS_CHANNEL)
            .setSmallIcon(icon)
            .setLargeIcon(icon)
            .setContentTitle("CPU Monitor")
            .setContentText(label)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, autostartLabel, toggleIntent).build())
            .addAction(Notification.Action.Builder(null, "Stop", stopIntent).build())
            .build()
    }

    // MARK: Icon generation — green → yellow → red, 13 steps

    private fun generateBitmaps(): List<Bitmap> {
        val size  = 64
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        return (0..12).map { step ->
            val t = step / 12f
            val r = min(t * 2f, 1f)
            val g = min((1f - t) * 2f, 1f)

            val bmp    = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)

            paint.style = Paint.Style.FILL
            paint.color = Color.rgb((r * 255).toInt(), (g * 255).toInt(), 0)
            canvas.drawCircle(size / 2f, size / 2f, size / 2f - 2, paint)

            paint.style      = Paint.Style.STROKE
            paint.strokeWidth = 2f
            paint.color      = Color.rgb((r * 127).toInt(), (g * 127).toInt(), 0)
            canvas.drawCircle(size / 2f, size / 2f, size / 2f - 2, paint)

            bmp
        }
    }

    // MARK: Notification channels

    private fun createChannels() {
        nm.createNotificationChannel(
            NotificationChannel(STATUS_CHANNEL, "Monitor Status", NotificationManager.IMPORTANCE_LOW)
                .apply { description = "Ongoing CPU status indicator" }
        )
    }
}
