package com.conjure.now_playing

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Opens the app when the head unit finishes booting (if enabled in settings). */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        val isBoot = action == Intent.ACTION_BOOT_COMPLETED ||
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == "com.htc.intent.action.QUICKBOOT_POWERON"
        if (!isBoot) return
        val prefs = context.getSharedPreferences("np_prefs", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("openOnBoot", false)) return
        try {
            val i = Intent(context, MainActivity::class.java)
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(i)
        } catch (_: Exception) {
        }
    }
}
