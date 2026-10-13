package com.conjure.now_playing

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.MediaMetadata
import android.media.audiofx.Visualizer
import android.media.session.MediaController
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/** Pulls the best artwork out of a media session's metadata. */
object MediaArt {
    fun bitmap(ctx: Context, md: MediaMetadata?): Bitmap? {
        if (md == null) return null
        var bmp: Bitmap? = md.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: md.getBitmap(MediaMetadata.METADATA_KEY_ART)
            ?: md.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)
        if (bmp == null) {
            val uri = md.getString(MediaMetadata.METADATA_KEY_ALBUM_ART_URI)
                ?: md.getString(MediaMetadata.METADATA_KEY_ART_URI)
                ?: md.getString(MediaMetadata.METADATA_KEY_DISPLAY_ICON_URI)
            if (uri != null && (uri.startsWith("content:") || uri.startsWith("file:"))) {
                try {
                    ctx.contentResolver.openInputStream(Uri.parse(uri))?.use {
                        bmp = BitmapFactory.decodeStream(it)
                    }
                } catch (_: Exception) {}
            }
        }
        val b = bmp ?: return null
        val cap = 600
        return if (b.width > cap || b.height > cap) {
            val r = cap.toFloat() / max(b.width, b.height)
            Bitmap.createScaledBitmap(b, max(1, (b.width * r).toInt()), max(1, (b.height * r).toInt()), true)
        } else b
    }
}

/**
 * The Drive overlay: VYBE drawn over the map app. Three small windows leave
 * the centre of the screen open for the map. Album art and controls sit on
 * one side, title and visualizer on the other, and turn-by-turn text from
 * the navigation notification sits under the centre.
 */
class DriveOverlay(private val ctx: Context) {

    var running = false
        private set
    var controllerProvider: () -> MediaController? = { null }
    var onClose: () -> Unit = {}

    private val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val main = Handler(Looper.getMainLooper())

    private var artWin: View? = null
    private var infoWin: View? = null
    private var dirWin: View? = null

    private var artView: ImageView? = null
    private var playBtn: TextView? = null
    private var titleView: TextView? = null
    private var artistView: TextView? = null
    private var bars: BarsView? = null
    private var dirTitle: TextView? = null
    private var dirText: TextView? = null

    private var suppressed = false
    private var accent = Color.rgb(255, 120, 90)
    private var lastTitle = ""
    private var lastArtist = ""
    private var lastArt: Bitmap? = null
    private var lastPlaying = false
    private var dirT: String? = null
    private var dirB: String? = null

    private var visualizer: Visualizer? = null
    private var swap = false
    private var centerFrac = 0.5f
    private var controls = true

    private fun dp(v: Float): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, ctx.resources.displayMetrics).toInt()

    private fun screen(): Pair<Int, Int> {
        val m = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(m)
        return Pair(m.widthPixels, m.heightPixels)
    }

    private fun params(w: Int, h: Int, x: Int, y: Int): WindowManager.LayoutParams {
        val type = if (Build.VERSION.SDK_INT >= 26)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        val p = WindowManager.LayoutParams(
            w, h, type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        )
        p.gravity = Gravity.TOP or Gravity.START
        p.x = x
        p.y = y
        return p
    }

    /** A dark shadow that is solid at the screen edge and fades toward the map. */
    private fun shadow(outerLeft: Boolean): GradientDrawable {
        val dark = Color.argb(235, 0, 0, 0)
        val clear = Color.argb(0, 0, 0, 0)
        return GradientDrawable(
            if (outerLeft) GradientDrawable.Orientation.LEFT_RIGHT
            else GradientDrawable.Orientation.RIGHT_LEFT,
            intArrayOf(dark, Color.argb(200, 0, 0, 0), clear),
        )
    }

    // ------------------------------------------------------------ lifecycle

    fun start(swap: Boolean, center: Float, controls: Boolean) {
        stop()
        this.swap = swap
        this.centerFrac = center.coerceIn(0.3f, 0.7f)
        this.controls = controls
        try {
            build()
            running = true
            applyVisibility()
            refreshAll()
            syncVisualizer()
        } catch (e: Exception) {
            removeAll()
            running = false
        }
    }

    fun stop() {
        stopVisualizer()
        removeAll()
        running = false
    }

    /** VYBE itself is on screen, so the overlay steps aside. */
    fun setSuppressed(v: Boolean) {
        suppressed = v
        if (!running) return
        applyVisibility()
        syncVisualizer()
    }

    private fun applyVisibility() {
        val vis = if (suppressed) View.GONE else View.VISIBLE
        artWin?.visibility = vis
        infoWin?.visibility = vis
        dirWin?.visibility = if (suppressed || (dirT == null && dirB == null)) View.GONE else View.VISIBLE
    }

    private fun removeAll() {
        for (v in listOf(artWin, infoWin, dirWin)) {
            try { if (v != null) wm.removeViewImmediate(v) } catch (_: Exception) {}
        }
        artWin = null; infoWin = null; dirWin = null
        artView = null; playBtn = null; titleView = null; artistView = null
        bars = null; dirTitle = null; dirText = null
    }

    // ----------------------------------------------------------------- build

    private fun build() {
        val (sw, sh) = screen()
        val centerW = (sw * centerFrac).toInt()
        val sideW = (sw - centerW) / 2
        val leftIsArt = !swap

        // Art side
        val artPanel = FrameLayout(ctx)
        val artOuterLeft = leftIsArt
        artPanel.background = shadow(artOuterLeft)
        val artSize = min((sideW * 0.78f).toInt(), (sh * 0.5f).toInt())
        val artCol = LinearLayout(ctx)
        artCol.orientation = LinearLayout.VERTICAL
        artCol.gravity = Gravity.CENTER_HORIZONTAL
        val iv = ImageView(ctx)
        iv.scaleType = ImageView.ScaleType.CENTER_CROP
        iv.setBackgroundColor(Color.argb(255, 30, 30, 36))
        iv.clipToOutline = true
        iv.outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                outline.setRoundRect(0, 0, view.width, view.height, dp(14f).toFloat())
            }
        }
        iv.elevation = dp(8f).toFloat()
        iv.setOnClickListener { openVybe() }
        artCol.addView(iv, LinearLayout.LayoutParams(artSize, artSize))
        artView = iv

        if (controls) {
            val row = LinearLayout(ctx)
            row.orientation = LinearLayout.HORIZONTAL
            row.gravity = Gravity.CENTER
            val prev = ctl("⏮") { controllerProvider()?.transportControls?.skipToPrevious() }
            val play = ctl("⏯") {
                val c = controllerProvider()
                if (c != null) {
                    if (lastPlaying) c.transportControls.pause() else c.transportControls.play()
                }
            }
            val next = ctl("⏭") { controllerProvider()?.transportControls?.skipToNext() }
            playBtn = play
            val bw = max(dp(44f), min(artSize / 3, dp(72f)))
            for (b in listOf(prev, play, next)) row.addView(b, LinearLayout.LayoutParams(bw, bw))
            val rl = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            rl.topMargin = dp(10f)
            artCol.addView(row, rl)
        }
        val acl = FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        acl.gravity = Gravity.CENTER
        artPanel.addView(artCol, acl)

        // Info side
        val infoPanel = FrameLayout(ctx)
        infoPanel.background = shadow(!artOuterLeft)
        val col = LinearLayout(ctx)
        col.orientation = LinearLayout.VERTICAL
        col.gravity = Gravity.CENTER_VERTICAL
        val pad = dp(18f)
        col.setPadding(pad, pad, pad, pad)
        val t = TextView(ctx)
        t.setTextColor(Color.WHITE)
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, 24f)
        t.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        t.maxLines = 3
        t.ellipsize = android.text.TextUtils.TruncateAt.END
        t.setShadowLayer(8f, 0f, 2f, Color.BLACK)
        col.addView(t)
        titleView = t
        val a = TextView(ctx)
        a.setTextColor(Color.argb(220, 255, 255, 255))
        a.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        a.maxLines = 2
        a.ellipsize = android.text.TextUtils.TruncateAt.END
        a.setShadowLayer(8f, 0f, 2f, Color.BLACK)
        val al = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        al.topMargin = dp(4f)
        col.addView(a, al)
        artistView = a
        val bv = BarsView(ctx)
        val bl = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, min(dp(90f), (sh * 0.16f).toInt()))
        bl.topMargin = dp(16f)
        col.addView(bv, bl)
        bars = bv
        val icl = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        icl.gravity = Gravity.CENTER_VERTICAL
        infoPanel.addView(col, icl)

        val close = TextView(ctx)
        close.text = "✕"
        close.setTextColor(Color.argb(200, 255, 255, 255))
        close.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
        close.gravity = Gravity.CENTER
        close.setOnClickListener { onClose() }
        val cl = FrameLayout.LayoutParams(dp(48f), dp(48f))
        cl.gravity = Gravity.TOP or (if (artOuterLeft) Gravity.END else Gravity.START)
        cl.topMargin = dp(8f)
        infoPanel.addView(close, cl)

        // Directions strip
        val dirPanel = LinearLayout(ctx)
        dirPanel.orientation = LinearLayout.VERTICAL
        dirPanel.gravity = Gravity.CENTER
        val bg = GradientDrawable()
        bg.setColor(Color.argb(210, 12, 12, 16))
        bg.cornerRadius = dp(16f).toFloat()
        dirPanel.background = bg
        dirPanel.setPadding(dp(16f), dp(8f), dp(16f), dp(8f))
        val dt = TextView(ctx)
        dt.setTextColor(Color.WHITE)
        dt.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
        dt.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        dt.maxLines = 2
        dt.gravity = Gravity.CENTER
        dt.ellipsize = android.text.TextUtils.TruncateAt.END
        dirPanel.addView(dt)
        val dx = TextView(ctx)
        dx.setTextColor(Color.argb(210, 255, 255, 255))
        dx.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        dx.maxLines = 1
        dx.gravity = Gravity.CENTER
        dx.ellipsize = android.text.TextUtils.TruncateAt.END
        dirPanel.addView(dx)
        dirTitle = dt
        dirText = dx

        val artX = if (leftIsArt) 0 else sw - sideW
        val infoX = if (leftIsArt) sw - sideW else 0
        wm.addView(artPanel, params(sideW, sh, artX, 0))
        wm.addView(infoPanel, params(sideW, sh, infoX, 0))
        val dirH = max(dp(70f), (sh * 0.14f).toInt())
        val dirW = (centerW * 0.94f).toInt()
        wm.addView(dirPanel, params(dirW, dirH, sideW + (centerW - dirW) / 2, sh - dirH - dp(10f)))
        artWin = artPanel
        infoWin = infoPanel
        dirWin = dirPanel
    }

    private fun ctl(glyph: String, action: () -> Unit): TextView {
        val b = TextView(ctx)
        b.text = glyph
        b.setTextColor(Color.WHITE)
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 26f)
        b.gravity = Gravity.CENTER
        b.setOnClickListener { action() }
        return b
    }

    private fun openVybe() {
        try {
            val i = Intent(ctx, MainActivity::class.java)
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            ctx.startActivity(i)
        } catch (_: Exception) {}
    }

    // ---------------------------------------------------------------- data

    fun update(title: String, artist: String, art: Bitmap?, playing: Boolean) {
        lastTitle = title
        lastArtist = artist
        lastPlaying = playing
        if (art !== lastArt) {
            lastArt = art
            if (art != null) accent = accentOf(art)
        }
        if (running) refreshAll()
    }

    fun setDirections(title: String?, text: String?) {
        dirT = title
        dirB = text
        if (!running) return
        dirTitle?.text = title ?: ""
        dirText?.text = text ?: ""
        dirText?.visibility = if (text.isNullOrBlank()) View.GONE else View.VISIBLE
        applyVisibility()
    }

    private fun refreshAll() {
        titleView?.text = lastTitle
        artistView?.text = lastArtist
        val a = lastArt
        if (a != null) artView?.setImageBitmap(a) else artView?.setImageDrawable(null)
        playBtn?.text = if (lastPlaying) "⏸" else "▶"
        bars?.color = accent
        bars?.invalidate()
        dirTitle?.text = dirT ?: ""
        dirText?.text = dirB ?: ""
        dirText?.visibility = if (dirB.isNullOrBlank()) View.GONE else View.VISIBLE
        applyVisibility()
        syncVisualizer()
    }

    /** The most vivid colour in the art, lightened a little so it reads on dark. */
    private fun accentOf(b: Bitmap): Int {
        return try {
            val s = Bitmap.createScaledBitmap(b, 24, 24, true)
            var best = 0f
            var pick = Color.rgb(255, 120, 90)
            val hsv = FloatArray(3)
            for (y in 0 until s.height) for (x in 0 until s.width) {
                Color.colorToHSV(s.getPixel(x, y), hsv)
                val score = hsv[1] * hsv[2]
                if (score > best && hsv[2] > 0.35f) { best = score; pick = s.getPixel(x, y) }
            }
            Color.colorToHSV(pick, hsv)
            hsv[1] = min(1f, max(0.45f, hsv[1]))
            hsv[2] = max(0.85f, hsv[2])
            Color.HSVToColor(hsv)
        } catch (_: Exception) {
            Color.rgb(255, 120, 90)
        }
    }

    // ------------------------------------------------------------ visualizer

    private val ticker = object : Runnable {
        override fun run() {
            val b = bars ?: return
            if (suppressed || !running) return
            if (visualizer == null) b.simulate(lastPlaying)
            b.invalidate()
            main.postDelayed(this, 40)
        }
    }

    private fun syncVisualizer() {
        main.removeCallbacks(ticker)
        if (!running || suppressed) {
            stopVisualizer()
            return
        }
        if (visualizer == null && lastPlaying) startVisualizer()
        if (!lastPlaying) stopVisualizer()
        main.post(ticker)
    }

    private fun startVisualizer() {
        if (Build.VERSION.SDK_INT >= 23 &&
            ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
        ) return
        try {
            val v = Visualizer(0)
            v.setEnabled(false)
            v.setCaptureSize(Visualizer.getCaptureSizeRange()[1])
            v.setDataCaptureListener(object : Visualizer.OnDataCaptureListener {
                override fun onWaveFormDataCapture(vis: Visualizer?, data: ByteArray?, rate: Int) {}
                override fun onFftDataCapture(vis: Visualizer?, fft: ByteArray?, rate: Int) {
                    if (fft != null) bars?.feed(fft)
                }
            }, Visualizer.getMaxCaptureRate() / 2, false, true)
            v.setEnabled(true)
            visualizer = v
        } catch (_: Exception) {
            visualizer = null
        }
    }

    private fun stopVisualizer() {
        try {
            visualizer?.setEnabled(false)
            visualizer?.release()
        } catch (_: Exception) {}
        visualizer = null
    }

    // ------------------------------------------------------------- bar view

    private class BarsView(c: Context) : View(c) {
        var color = Color.WHITE
        private val n = 20
        private val level = FloatArray(n)
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val rect = RectF()

        /** FFT bytes are re/im pairs. Fold them into log-spaced bands. */
        fun feed(fft: ByteArray) {
            val bins = fft.size / 2
            if (bins < 8) return
            for (i in 0 until n) {
                val lo = max(1, (Math.pow(bins.toDouble() * 0.6, i.toDouble() / n)).toInt())
                val hi = max(lo + 1, (Math.pow(bins.toDouble() * 0.6, (i + 1).toDouble() / n)).toInt())
                var m = 0f
                for (k in lo until min(hi, bins)) {
                    val re = fft[2 * k].toFloat()
                    val im = fft[2 * k + 1].toFloat()
                    m = max(m, sqrt(re * re + im * im))
                }
                val v = (log10(1.0 + m) / log10(1.0 + 180.0)).toFloat().coerceIn(0f, 1f)
                level[i] = if (v > level[i]) v else level[i] * 0.82f + v * 0.18f
            }
        }

        /** Used when the audio tap is not available. Gentle, clearly not real. */
        fun simulate(playing: Boolean) {
            val t = System.currentTimeMillis() / 1000.0
            for (i in 0 until n) {
                val target = if (playing) (0.3 + 0.25 * sin(t * 2.1 + i * 0.7) + 0.15 * sin(t * 3.7 + i * 1.9)).toFloat() else 0.04f
                level[i] += (target - level[i]) * 0.2f
            }
        }

        override fun onDraw(canvas: Canvas) {
            paint.color = color
            val w = width.toFloat()
            val h = height.toFloat()
            val gap = w * 0.012f
            val bw = (w - gap * (n - 1)) / n
            for (i in 0 until n) {
                val bh = max(h * 0.05f, abs(level[i]) * h)
                val x = i * (bw + gap)
                rect.set(x, h - bh, x + bw, h)
                canvas.drawRoundRect(rect, bw / 3f, bw / 3f, paint)
            }
        }
    }
}
