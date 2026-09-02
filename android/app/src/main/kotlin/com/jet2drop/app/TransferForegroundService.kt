package com.jet2drop.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

class TransferForegroundService : Service() {
    companion object {
        const val ACTION_START = "com.jet2drop.app.TRANSFER_START"
        const val ACTION_UPDATE = "com.jet2drop.app.TRANSFER_UPDATE"
        const val ACTION_STOP = "com.jet2drop.app.TRANSFER_STOP"
        const val EXTRA_CURRENT = "current"
        const val EXTRA_TOTAL = "total"
        const val EXTRA_TASKS = "tasks"
        private const val CHANNEL_ID = "jet2drop_transfers"
        private const val NOTIFICATION_ID = 41005
    }

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "文件传输",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { description = "在后台继续 Jet2Drop 文件传输" },
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        val current = intent?.getIntExtra(EXTRA_CURRENT, 0) ?: 0
        val total = intent?.getIntExtra(EXTRA_TOTAL, 0) ?: 0
        val tasks = intent?.getIntExtra(EXTRA_TASKS, 1) ?: 1
        startForeground(NOTIFICATION_ID, notification(current, total, tasks))
        return START_NOT_STICKY
    }

    private fun notification(current: Int, total: Int, tasks: Int): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(if (tasks > 1) "正在传输 $tasks 个任务" else "正在传输文件")
            .setContentText("Jet2Drop 将在后台继续传输")
            .setContentIntent(openApp)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(total.coerceAtLeast(0), current.coerceIn(0, total.coerceAtLeast(0)), total <= 0)
            .build()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
