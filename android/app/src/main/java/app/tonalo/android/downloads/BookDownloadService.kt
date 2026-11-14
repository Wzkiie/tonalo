package app.tonalo.android.downloads

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import app.tonalo.android.MainActivity
import app.tonalo.android.R
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Keeps the process alive while audiobooks download and shows the progress (the transfers themselves run in
 * [BookDownloads]). Stops itself when nothing is left to download. A foreground service of type `dataSync`.
 */
class BookDownloadService : Service() {
    private val scope = MainScope()
    private var job: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL) {
            BookDownloads.cancelUnfinished()
            end()
            return START_NOT_STICKY
        }
        show(BookDownloads.activity.value)
        if (job == null) {
            job = scope.launch {
                BookDownloads.activity.collect { activity ->
                    if (activity == null) end() else notifications().notify(ID, build(activity))
                }
            }
        }
        return START_NOT_STICKY
    }

    /** Android 15 gives a dataSync service a time limit; downloads stop where they are and can be started again. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        BookDownloads.suspendAll()
        end()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun end() {
        job?.cancel()
        job = null
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun notifications() = getSystemService(NotificationManager::class.java)

    private fun show(activity: BookDownloads.Activity?) {
        ensureChannel()
        val type = if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
        ServiceCompat.startForeground(this, ID, build(activity), type)
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        if (notifications().getNotificationChannel(CHANNEL) != null) return
        notifications().createNotificationChannel(
            NotificationChannel(CHANNEL, getString(R.string.bp_download_channel), NotificationManager.IMPORTANCE_LOW)
        )
    }

    private fun build(activity: BookDownloads.Activity?): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val cancel = PendingIntent.getService(
            this, 1, Intent(this, BookDownloadService::class.java).setAction(ACTION_CANCEL),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(getString(R.string.bp_downloading))
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .addAction(0, getString(R.string.bp_cancel), cancel)
        if (activity != null) {
            builder.setContentText(getString(R.string.bp_downloading_n, minOf(activity.done + 1, activity.total), activity.total))
            builder.setProgress(100, (activity.progress * 100).toInt(), false)
        } else {
            builder.setProgress(100, 0, true)
        }
        return builder.build()
    }

    companion object {
        private const val ID = 3
        private const val CHANNEL = "book_downloads"
        private const val ACTION_CANCEL = "app.tonalo.android.books.cancelDownloads"

        /** Starts the notification and keeps the process; harmless when already running or when Android doesn't allow it now. */
        internal fun start(context: Context) {
            try {
                ContextCompat.startForegroundService(context, Intent(context, BookDownloadService::class.java))
            } catch (e: Exception) {
                // Started from the background (e.g. the car): the downloads still run, only without the notification
            }
        }
    }
}
