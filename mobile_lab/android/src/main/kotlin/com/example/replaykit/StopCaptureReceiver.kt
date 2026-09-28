package com.example.replaykit

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class StopCaptureReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        context.startService(
            Intent(context, CaptureService::class.java).setAction(CaptureService.ACTION_STOP)
        )
    }
}
