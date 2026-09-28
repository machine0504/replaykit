package com.example.replaykit

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class ScreenCapturePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener,
    EventChannel.StreamHandler {

    private lateinit var channel: MethodChannel
    private lateinit var events: EventChannel
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pending: MethodChannel.Result? = null
    private var appContext: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, EVENTS)
        events.setStreamHandler(this)
        Bridge.channel = channel
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        Bridge.channel = null
        Bridge.sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(true)
            "startSession" -> startSession(result)
            "stopSession" -> {
                val ctx = appContext
                if (ctx != null) {
                    ctx.startService(Intent(ctx, CaptureService::class.java).setAction(CaptureService.ACTION_STOP))
                }
                result.success(true)
            }
            "saveToAlbum" -> saveToAlbum(call.argument<ByteArray>("bytes"), result)
            else -> result.notImplemented()
        }
    }

    /// 写进系统相册。API 29 起用 MediaStore RELATIVE_PATH，不需要存储权限。
    private fun saveToAlbum(bytes: ByteArray?, result: MethodChannel.Result) {
        val ctx = appContext
        if (bytes == null || bytes.isEmpty() || ctx == null) {
            result.error("bad_args", "图片数据无效", null)
            return
        }
        try {
            val name = "screenshot_lab_${System.currentTimeMillis()}.png"
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                if (Build.VERSION.SDK_INT >= 29) {
                    put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/截图实验室")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
            }
            val resolver = ctx.contentResolver
            val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            if (uri == null) {
                result.error("save_failed", "无法创建相册条目", null)
                return
            }
            resolver.openOutputStream(uri)?.use { it.write(bytes) }
                ?: run {
                    resolver.delete(uri, null, null)
                    result.error("save_failed", "无法写入相册", null)
                    return
                }
            if (Build.VERSION.SDK_INT >= 29) {
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("save_failed", e.message ?: "写入相册失败", null)
        }
    }

    private fun startSession(result: MethodChannel.Result) {
        val act = activity
        if (act == null) {
            result.error("no_activity", "没有 Activity，无法弹出授权", null)
            return
        }
        if (Build.VERSION.SDK_INT >= 33) {
            act.requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1101)
        }
        pending?.error("busy", "已有进行中的授权", null)
        pending = result
        val mgr = act.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        act.startActivityForResult(mgr.createScreenCaptureIntent(), REQ)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ) return false
        val reply = pending
        pending = null
        val act = activity
        val ctx = appContext
        if (resultCode != Activity.RESULT_OK || data == null || act == null || ctx == null) {
            reply?.success(false)
            return true
        }
        val extras = Bundle().apply {
            putInt(CaptureService.EXTRA_CODE, resultCode)
            putParcelable(CaptureService.EXTRA_DATA, data)
        }
        val intent = Intent(ctx, CaptureService::class.java).putExtras(extras)
        if (Build.VERSION.SDK_INT >= 26) {
            ctx.startForegroundService(intent)
        } else {
            ctx.startService(intent)
        }
        act.moveTaskToBack(true)
        reply?.success(true)
        return true
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        Bridge.sink = events
        val last = Bridge.lastStopped
        if (events != null && last != null) {
            android.os.Handler(android.os.Looper.getMainLooper()).post { events.success(last) }
        }
    }

    override fun onCancel(arguments: Any?) {
        Bridge.sink = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeActivityResultListener(this)
        activity = null
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activity = null
        activityBinding = null
    }

    companion object {
        const val CHANNEL = "native_screenshot_lab/system_capture"
        const val EVENTS = "native_screenshot_lab/system_capture_events"
        private const val REQ = 0x51C0
    }
}

object Bridge {
    var channel: MethodChannel? = null
    var sink: EventChannel.EventSink? = null
    var lastStopped: Map<String, Any?>? = null

    fun emit(payload: Map<String, Any?>) {
        if (payload["type"] == "stopped") {
            lastStopped = payload
        } else if (payload["type"] == "started") {
            lastStopped = null
        }
        val s = sink
        if (s != null) {
            android.os.Handler(android.os.Looper.getMainLooper()).post { s.success(payload) }
        }
    }
}
