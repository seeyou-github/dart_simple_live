package com.xycz.simple_live

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import java.net.URL
import kotlin.concurrent.thread

/**
 * 音频模式的前台服务：常驻通知显示直播间标题 / 主播 / 头像封面，
 * 并提供播放-暂停、关闭两个按钮。真正的解码仍在 Flutter 侧的 media_kit。
 */
class AudioNotificationService : Service() {
    companion object {
        private const val CHANNEL_ID = "simple_live_audio"
        private const val CHANNEL_NAME = "音频模式"
        private const val NOTIFICATION_ID = 1201

        const val ACTION_SHOW = "com.xycz.simple_live.audio.SHOW"
        const val ACTION_TOGGLE = "com.xycz.simple_live.audio.TOGGLE"

        const val EXTRA_TITLE = "title"
        const val EXTRA_ARTIST = "artist"
        const val EXTRA_AVATAR = "avatar"
        const val EXTRA_PLAYING = "playing"

        /** 通知栏按钮回传给 Flutter */
        var toggleCallback: (() -> Unit)? = null

        /** 通知里显示的信息，后续只更新播放状态时沿用 */
        private var playing = true
        private var title = ""
        private var artist = ""
        private var avatar = ""
        private var cover: Bitmap? = null

        /** 打开通知（同时用于刷新标题 / 状态） */
        fun show(context: Context, extras: Map<String, Any?>) {
            val intent = Intent(context, AudioNotificationService::class.java).apply {
                action = ACTION_SHOW
                (extras["title"] as? String)?.let { putExtra(EXTRA_TITLE, it) }
                (extras["artist"] as? String)?.let { putExtra(EXTRA_ARTIST, it) }
                (extras["avatar"] as? String)?.let { putExtra(EXTRA_AVATAR, it) }
                (extras["playing"] as? Boolean)?.let { putExtra(EXTRA_PLAYING, it) }
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Throwable) {
                // Android 12+ 在后台启动前台服务可能被系统拒绝，
                // 此时只是没有通知，声音仍然继续播放
            }
        }

        fun hide(context: Context) {
            context.stopService(Intent(context, AudioNotificationService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_TOGGLE -> {
                // 由通知的 PendingIntent 拉起时系统要求尽快进入前台，
                // 先无条件满足契约，再决定是否保留这个通知
                startForegroundCompat()
                val callback = toggleCallback
                if (callback == null) {
                    // Flutter 侧已不存在，避免留下一个点了没反应的常驻通知
                    stopSelf()
                } else {
                    playing = !playing
                    callback.invoke()
                    notifyUpdate()
                }
            }

            else -> {
                intent?.getStringExtra(EXTRA_TITLE)?.let { title = it }
                intent?.getStringExtra(EXTRA_ARTIST)?.let { artist = it }
                intent?.getBooleanExtra(EXTRA_PLAYING, playing)?.let { playing = it }
                intent?.getStringExtra(EXTRA_AVATAR)?.let { newAvatar ->
                    if (newAvatar != avatar) {
                        avatar = newAvatar
                        cover = null
                        loadCover(newAvatar)
                    }
                }
                startForegroundCompat()
            }
        }
        return START_NOT_STICKY
    }

    private fun loadCover(url: String) {
        if (url.isEmpty()) return
        thread {
            try {
                val stream = URL(url).openStream()
                val bitmap = BitmapFactory.decodeStream(stream)
                stream.close()
                if (bitmap != null) {
                    cover = bitmap
                    notifyUpdate()
                }
            } catch (_: Throwable) {
                // 头像下载失败不影响通知本身
            }
        }
    }

    private fun buildNotification(): Notification {
        createChannel()

        val contentIntent = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        val toggleIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // 必须用 getForegroundService：服务不在前台时用 getService 拉起
            // 会走「后台服务」限制，Android 8+ 可能直接抛异常
            PendingIntent.getForegroundService(
                this,
                1,
                Intent(this, AudioNotificationService::class.java).setAction(ACTION_TOGGLE),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        } else {
            PendingIntent.getService(
                this,
                1,
                Intent(this, AudioNotificationService::class.java).setAction(ACTION_TOGGLE),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title.ifEmpty { "音频模式" })
            .setContentText(artist)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(contentIntent)
            .addAction(
                if (playing) android.R.drawable.ic_media_pause
                else android.R.drawable.ic_media_play,
                if (playing) "暂停" else "播放",
                toggleIntent,
            )

        cover?.let { builder.setLargeIcon(it) }

        return builder.build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                setShowBadge(false)
                description = "在后台仅播放直播声音"
            },
        )
    }

    private fun startForegroundCompat() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun notifyUpdate() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification())
    }
}
