package com.maker.guideline

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 唯一需要原生代码的地方：**长按图标 → 速记**。
 *
 * Android 的 App Shortcut 只是一个带自定义 action 的 Intent，Flutter 层收不到它，
 * 所以这里用一条 MethodChannel 把它转成 Dart 能听的事件，两种情况都要覆盖：
 *   · 冷启动（App 没在跑）—— 记下 pending，等 Dart 起来后主动来取；
 *   · 热启动（App 在后台）—— `onNewIntent` 直接推给 Dart。
 */
class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null
    private var pendingCapture = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    // Dart 启动后来问："这次启动是冲着速记来的吗？"
                    "consumePendingCapture" -> {
                        result.success(pendingCapture)
                        pendingCapture = false
                    }
                    else -> result.notImplemented()
                }
            }
        }
        if (isCaptureIntent(intent)) pendingCapture = true
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (isCaptureIntent(intent)) {
            // 热启动时 Dart 侧已经挂好监听，直接推
            channel?.invokeMethod("onCapture", null)
        }
    }

    private fun isCaptureIntent(intent: Intent?): Boolean = intent?.action == ACTION_CAPTURE

    companion object {
        private const val CHANNEL = "guideline/shortcut"
        const val ACTION_CAPTURE = "com.maker.guideline.SHORTCUT_CAPTURE"
    }
}
