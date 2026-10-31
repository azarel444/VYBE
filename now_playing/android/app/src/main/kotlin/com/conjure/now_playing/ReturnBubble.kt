package com.conjure.now_playing

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.provider.Settings
import android.util.DisplayMetrics
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.TextView

/**
 * A labeled edge-mounted "Return to VYBE" tab drawn over the map app while the Drive
 * window is hidden. Drag it to move it (the spot is remembered). Tap it to
 * bring the Drive window back to the front.
 *
 * It is a visible overlay window, which is what lets Android allow the tap
 * to start VYBE's screen again from the background.
 */
class ReturnBubble(private val ctx: Context) {

    private val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private var view: TextView? = null
    private var lp: WindowManager.LayoutParams? = null

    val showing: Boolean get() = view != null

    private fun dp(v: Float): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, ctx.resources.displayMetrics).toInt()

    private fun screen(): Pair<Int, Int> {
        val m = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getMetrics(m)
        return Pair(m.widthPixels, m.heightPixels)
    }

    fun show() {
        if (view != null) return
        if (Build.VERSION.SDK_INT >= 23 && !Settings.canDrawOverlays(ctx)) return
        try {
            val prefs = ctx.getSharedPreferences(PlayerFilter.PREFS, Context.MODE_PRIVATE)
            val tabWidth = dp(172f)
            val tabHeight = dp(46f)
            val (sw, sh) = screen()
            val onLeft = prefs.getBoolean("bubbleOnLeft",
                prefs.getInt("bubbleX", sw - tabWidth) < sw / 2)
            val edgeInset = dp(8f)
            val y = prefs.getInt("bubbleY", sh / 2 - tabHeight / 2).coerceIn(0, maxOf(0, sh - tabHeight))

            val v = TextView(ctx)
            v.text = "‹  Return to VYBE"
            v.setTextColor(Color.WHITE)
            v.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            v.gravity = Gravity.CENTER
            v.alpha = 0.94f
            v.setPadding(dp(10f), 0, dp(10f), 0)
            val bg = GradientDrawable()
            bg.shape = GradientDrawable.RECTANGLE
            bg.cornerRadius = dp(12f).toFloat()
            bg.setColor(Color.argb(220, 12, 14, 24))
            bg.setStroke(dp(2f), Color.argb(230, 5, 217, 255))
            v.background = bg

            val type = if (Build.VERSION.SDK_INT >= 26)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
            val p = WindowManager.LayoutParams(
                tabWidth, tabHeight, type,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT,
            )
            p.gravity = Gravity.TOP or (if (onLeft) Gravity.START else Gravity.END)
            p.x = edgeInset
            p.y = y

            val slop = dp(10f)
            var downX = 0f
            var downY = 0f
            var startX = 0
            var startY = 0
            var moved = false
            v.setOnTouchListener { _, e ->
                when (e.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        downX = e.rawX
                        downY = e.rawY
                        startX = if ((p.gravity and Gravity.HORIZONTAL_GRAVITY_MASK) == Gravity.END)
                            sw - tabWidth - edgeInset else edgeInset
                        startY = p.y
                        moved = false
                        true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        val dx = e.rawX - downX
                        val dy = e.rawY - downY
                        if (!moved && (Math.abs(dx) > slop || Math.abs(dy) > slop)) moved = true
                        if (moved) {
                            val (w2, h2) = screen()
                            val desiredX = startX + dx.toInt()
                            val left = desiredX + tabWidth / 2 < w2 / 2
                            p.gravity = Gravity.TOP or (if (left) Gravity.START else Gravity.END)
                            p.x = edgeInset
                            p.y = (startY + dy.toInt()).coerceIn(0, maxOf(0, h2 - tabHeight))
                            try { wm.updateViewLayout(v, p) } catch (_: Exception) {}
                        }
                        true
                    }
                    MotionEvent.ACTION_UP -> {
                        if (moved) {
                            val left = (p.gravity and Gravity.HORIZONTAL_GRAVITY_MASK) != Gravity.END
                            prefs.edit().putBoolean("bubbleOnLeft", left)
                                .putInt("bubbleX", if (left) edgeInset else screen().first - tabWidth - edgeInset)
                                .putInt("bubbleY", p.y).apply()
                        } else {
                            openVybe()
                        }
                        true
                    }
                    else -> true
                }
            }

            wm.addView(v, p)
            view = v
            lp = p
        } catch (_: Exception) {
            view = null
            lp = null
        }
    }

    fun hide() {
        val v = view ?: return
        try { wm.removeViewImmediate(v) } catch (_: Exception) {}
        view = null
        lp = null
    }

    private fun openVybe() {
        try {
            val i = Intent(ctx, DriveActivity::class.java)
            // Restore the existing Drive task instead of reordering its
            // activity across Maps' task boundary. Reordering can cause Maps
            // to treat the return as a new foreground transition and enter PiP.
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            ctx.startActivity(i)
        } catch (_: Exception) {
        }
    }
}
