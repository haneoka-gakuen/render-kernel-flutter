package dev.renderkernel.flutter

import android.app.Activity
import android.app.Application
import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.Window
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.WeakHashMap

/** Optional window policy; no renderer or game state participates in it. */
class FrameRatePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    Application.ActivityLifecycleCallbacks, DisplayManager.DisplayListener {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var displayManager: DisplayManager? = null
    private var resumed = false
    private val windowOwner = Any()
    private val requests = mutableMapOf<String, Float>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "render_kernel_flutter/display_frame_rate")
            .also { it.setMethodCallHandler(this) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val owner = call.argument<String>("owner")
        if (owner.isNullOrEmpty()) {
            result.error("invalid-owner", "A frame-rate owner is required", null)
            return
        }
        when (call.method) {
            "request" -> {
                val target = call.argument<Number>("targetHz")?.toFloat()
                if (target == null || !target.isFinite() || target <= 0f) {
                    result.error("invalid-rate", "A positive finite targetHz is required", null)
                    return
                }
                requests[owner] = target
                apply()
                result.success(null)
            }
            "release" -> {
                requests.remove(owner)
                apply()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        detachActivity()
        activity = binding.activity
        resumed = binding.activity.hasWindowFocus()
        binding.activity.application.registerActivityLifecycleCallbacks(this)
        displayManager = binding.activity.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        displayManager?.registerDisplayListener(this, Handler(Looper.getMainLooper()))
        apply()
    }

    @Suppress("DEPRECATION")
    private fun apply() {
        val current = activity ?: return
        WindowRequests.update(
            current.window,
            windowOwner,
            if (resumed) requests.values.maxOrNull() else null,
            current.window.decorView.display ?: current.windowManager.defaultDisplay,
        )
    }

    private fun detachActivity() {
        activity?.let {
            WindowRequests.update(it.window, windowOwner, null)
            it.application.unregisterActivityLifecycleCallbacks(this)
        }
        displayManager?.unregisterDisplayListener(this)
        displayManager = null
        activity = null
        resumed = false
    }

    override fun onDetachedFromActivity() = detachActivity()
    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detachActivity()
        requests.clear()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onActivityResumed(activity: Activity) {
        if (this.activity === activity) {
            resumed = true
            apply()
        }
    }

    override fun onActivityPaused(activity: Activity) {
        if (this.activity === activity) {
            resumed = false
            apply()
        }
    }

    override fun onActivityDestroyed(activity: Activity) {
        if (this.activity === activity) detachActivity()
    }

    override fun onActivityCreated(activity: Activity, state: Bundle?) {}
    override fun onActivityStarted(activity: Activity) {}
    override fun onActivityStopped(activity: Activity) {}
    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) {}
    override fun onDisplayAdded(displayId: Int) {}
    override fun onDisplayRemoved(displayId: Int) { apply() }
    override fun onDisplayChanged(displayId: Int) { apply() }
}

/** Shares one preference across all Flutter engines attached to a window. */
private object WindowRequests {
    // Values contain no Window or Activity, so this map does not retain either.
    private val windows = WeakHashMap<Window, Requests>()

    private class Requests(val originalMode: Int, val originalRate: Float) {
        val owners = mutableMapOf<Any, Float>()
    }

    fun update(window: Window, owner: Any, target: Float?, display: Display? = window.decorView.display) {
        var state = windows[window]
        if (state == null) {
            if (target == null) return
            val attributes = window.attributes
            state = Requests(attributes.preferredDisplayModeId, attributes.preferredRefreshRate)
            windows[window] = state
        }
        if (target == null) state.owners.remove(owner) else state.owners[owner] = target
        val attributes = window.attributes
        val selected = state.owners.values.maxOrNull()?.let { select(display, it) }
        val mode = selected?.modeId ?: state.originalMode
        val rate = selected?.refreshRate ?: state.originalRate
        if (attributes.preferredDisplayModeId != mode || attributes.preferredRefreshRate != rate) {
            attributes.preferredDisplayModeId = mode
            attributes.preferredRefreshRate = rate
            window.attributes = attributes
        }
        if (state.owners.isEmpty()) windows.remove(window)
    }

    private fun select(display: Display?, target: Float): Display.Mode? {
        val current = display?.mode ?: return null
        return display.supportedModes.asSequence()
            .filter {
                it.physicalWidth == current.physicalWidth &&
                    it.physicalHeight == current.physicalHeight &&
                    it.refreshRate > 0f && it.refreshRate <= target + 0.01f
            }
            .maxByOrNull { it.refreshRate }
    }
}
