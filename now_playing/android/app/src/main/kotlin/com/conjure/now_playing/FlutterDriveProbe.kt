package com.conjure.now_playing

import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.provider.Settings
import android.util.DisplayMetrics
import android.view.Gravity
import android.view.WindowManager
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Opt-in architecture probe, NOT the production Drive UI.
 *
 * Hosts a real FlutterView in a non-focusable WindowManager overlay while Maps
 * remains the resumed activity. This tests the rendering/lifecycle prerequisite
 * for replacing the activity-backed Drive window without changing the normal
 * Return button or removing the existing native preview.
 *
 * Keep the view narrow: unlike transparent pixels in a Flutter surface, the
 * unoccupied right side of the display must accept Maps touches directly.
 */
class FlutterDriveProbe(
    private val ctx: Context,
    private val onClose: () -> Unit,
) {
    private val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private var engine: FlutterEngine? = null
    private var flutterView: FlutterView? = null

    val showing: Boolean get() = flutterView != null

    fun show(): Boolean {
        if (showing) return true
        if (Build.VERSION.SDK_INT >= 23 && !Settings.canDrawOverlays(ctx)) return false

        var createdEngine: FlutterEngine? = null
        var createdView: FlutterView? = null
        var attached = false
        try {
            val e = FlutterEngine(ctx)
            createdEngine = e
            e.navigationChannel.setInitialRoute("/drive-overlay-probe")
            MethodChannel(e.dartExecutor.binaryMessenger, "vybe/drive_overlay_probe")
                .setMethodCallHandler { call, result ->
                    if (call.method == "close") {
                        result.success(null)
                        onClose()
                    } else {
                        result.notImplemented()
                    }
                }
            // Texture rendering supports transparent WindowManager surfaces.
            // Use the supported FlutterTextureView constructor rather than
            // deprecated RenderMode/TransparencyMode constructor overloads.
            val v = FlutterView(ctx, FlutterTextureView(ctx))
            createdView = v
            v.attachToFlutterEngine(e)
            attached = true

            val metrics = DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getMetrics(metrics)
            val width = (metrics.widthPixels * 0.42f).toInt().coerceAtLeast(1)
            val type = if (Build.VERSION.SDK_INT >= 26)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
            val params = WindowManager.LayoutParams(
                width,
                WindowManager.LayoutParams.MATCH_PARENT,
                type,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT,
            )
            params.gravity = Gravity.TOP or Gravity.START
            wm.addView(v, params)
            flutterView = v
            engine = e
            e.lifecycleChannel.appIsResumed()
            e.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault(),
            )
            return true
        } catch (error: Exception) {
            android.util.Log.e("VYBE/FlutterProbe", "Unable to show Flutter overlay", error)
            if (createdView != null) {
                try { wm.removeViewImmediate(createdView) } catch (_: Exception) {}
                if (attached) {
                    try { createdView.detachFromFlutterEngine() } catch (_: Exception) {}
                }
            }
            try { createdEngine?.destroy() } catch (_: Exception) {}
            flutterView = null
            engine = null
            return false
        }
    }

    fun hide() {
        val v = flutterView
        val e = engine
        flutterView = null
        engine = null
        if (v != null) {
            try { wm.removeViewImmediate(v) } catch (_: Exception) {}
            try { v.detachFromFlutterEngine() } catch (_: Exception) {}
        }
        if (e != null) {
            try { e.lifecycleChannel.appIsPaused() } catch (_: Exception) {}
            try { e.destroy() } catch (_: Exception) {}
        }
    }
}
