package com.example.replaykit

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.DisplayMetrics
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import java.io.File
import java.io.FileOutputStream
import kotlin.math.abs
import kotlin.math.roundToInt

class CaptureService : Service() {
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private val handler = Handler(Looper.getMainLooper())
    private val paths = mutableListOf<String>()
    private var lastThumb: IntArray? = null
    private var grabbing = false
    private var finishing = false
    private val tick = object : Runnable {
        override fun run() {
            grabOnce()
            if (projection != null) {
                handler.postDelayed(this, INTERVAL_MS)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            finishAndStop()
            return START_NOT_STICKY
        }
        val code = intent?.getIntExtra(EXTRA_CODE, 0) ?: 0
        val data = if (Build.VERSION.SDK_INT >= 33) {
            intent?.getParcelableExtra(EXTRA_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent?.getParcelableExtra(EXTRA_DATA)
        }
        if (code == 0 || data == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        startFg()
        finishing = false
        val mgr = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val proj = mgr.getMediaProjection(code, data)
        if (proj == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        proj.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                finishAndStop()
            }
        }, handler)
        projection = proj
        dir().apply {
            deleteRecursively()
            mkdirs()
        }
        paths.clear()
        lastThumb = null
        setupDisplay(proj)
        handler.postDelayed(tick, 800)
        Bridge.emit(mapOf("type" to "started"))
        return START_STICKY
    }

    private fun startFg() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "长截图", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val stop = PendingIntent.getBroadcast(
            this,
            1,
            Intent(ACTION_BROADCAST_STOP).setClass(this, StopCaptureReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notif: Notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentTitle("长截图进行中")
            .setContentText("请切换到其它 App 慢慢下滑，完成后点停止")
            .addAction(0, "停止并拼接", stop)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    private fun setupDisplay(proj: MediaProjection) {
        val metrics = DisplayMetrics()
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(metrics)
        val scale = TARGET_WIDTH.toFloat() / metrics.widthPixels
        val w = TARGET_WIDTH
        val h = (metrics.heightPixels * scale).roundToInt().coerceAtLeast(2) and 1.inv()
        val dpi = (metrics.densityDpi * scale).roundToInt().coerceAtLeast(160)
        val ir = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        reader = ir
        display = proj.createVirtualDisplay(
            "lab-long-shot",
            w,
            h,
            dpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            ir.surface,
            null,
            handler
        )
    }

    private fun grabOnce() {
        if (grabbing || paths.size >= MAX_FRAMES) return
        val img: Image = reader?.acquireLatestImage() ?: return
        grabbing = true
        try {
            val bmp = imageToBitmap(img) ?: return
            if (isDuplicate(bmp)) {
                bmp.recycle()
                return
            }
            val file = File(dir(), "${paths.size.toString().padStart(3, '0')}.jpg")
            FileOutputStream(file).use { out ->
                bmp.compress(Bitmap.CompressFormat.JPEG, 78, out)
            }
            bmp.recycle()
            paths.add(file.absolutePath)
            Bridge.emit(mapOf("type" to "frame", "count" to paths.size))
        } catch (_: Exception) {
        } finally {
            img.close()
            grabbing = false
        }
    }

    private fun imageToBitmap(image: Image): Bitmap? {
        val plane = image.planes.firstOrNull() ?: return null
        val buffer = plane.buffer
        val pixelStride = plane.pixelStride
        val rowStride = plane.rowStride
        val w = image.width
        val h = image.height
        val rowPadding = rowStride - pixelStride * w
        val full = Bitmap.createBitmap(
            w + rowPadding / pixelStride,
            h,
            Bitmap.Config.ARGB_8888
        )
        full.copyPixelsFromBuffer(buffer)
        return if (rowPadding == 0) full else Bitmap.createBitmap(full, 0, 0, w, h).also {
            if (it !== full) full.recycle()
        }
    }

    private fun isDuplicate(bmp: Bitmap): Boolean {
        val small = Bitmap.createScaledBitmap(bmp, 16, 16, true)
        val pixels = IntArray(256)
        small.getPixels(pixels, 0, 16, 0, 0, 16, 16)
        small.recycle()
        val prev = lastThumb
        lastThumb = pixels
        if (prev == null) return false
        var diff = 0
        for (i in pixels.indices) {
            val a = pixels[i]
            val b = prev[i]
            diff += abs(((a shr 16) and 0xff) - ((b shr 16) and 0xff))
            diff += abs(((a shr 8) and 0xff) - ((b shr 8) and 0xff))
            diff += abs((a and 0xff) - (b and 0xff))
        }
        return diff < 16 * 16 * 18
    }

    private fun dir(): File = File(cacheDir, "sys_frames")

    private fun finishAndStop() {
        if (finishing) return
        finishing = true
        handler.removeCallbacks(tick)
        try {
            display?.release()
        } catch (_: Exception) {
        }
        display = null
        try {
            reader?.close()
        } catch (_: Exception) {
        }
        reader = null
        try {
            projection?.stop()
        } catch (_: Exception) {
        }
        projection = null
        val snapshot = ArrayList(paths)
        bringAppToFront()
        handler.postDelayed({
            Bridge.emit(mapOf("type" to "stopped", "paths" to snapshot))
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }, 350)
    }

    private fun bringAppToFront() {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
        startActivity(launch)
    }

    companion object {
        const val ACTION_STOP = "com.example.replaykit.SERVICE_STOP"
        const val ACTION_BROADCAST_STOP = "com.example.replaykit.STOP"
        const val EXTRA_CODE = "code"
        const val EXTRA_DATA = "data"
        private const val CHANNEL = "lab_long_shot"
        private const val NOTIF_ID = 0x51C1
        private const val INTERVAL_MS = 480L
        private const val TARGET_WIDTH = 720
        private const val MAX_FRAMES = 36
    }
}
