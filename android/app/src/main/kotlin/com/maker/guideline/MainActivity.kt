package com.maker.guideline

import android.content.Intent
import android.os.ParcelFileDescriptor
import android.system.Os
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 唯一需要原生代码的地方（两条通道）：
 *
 * 1. **长按图标 → 速记**：Android 的 App Shortcut 只是一个带自定义 action 的 Intent，
 *    Flutter 层收不到它，所以用一条 MethodChannel 把它转成 Dart 能听的事件：
 *    · 冷启动（App 没在跑）—— 记下 pending，等 Dart 起来后主动来取；
 *    · 热启动（App 在后台）—— `onNewIntent` 直接推给 Dart。
 *
 * 2. **真正的 fsync**：Dart 标准库没暴露 `fsync`，而 `flushSync()` 只把用户态缓冲
 *    交给内核，掉电时数据可能还在 page cache 里。这里对文件描述符调 `Os.fsync`，
 *    由 `lib/platform/file_durability_platform.dart` 在启动时挂钩子。
 */
class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null
    private var durability: MethodChannel? = null
    private var pendingCapture = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        channel = MethodChannel(messenger, CHANNEL).also { ch ->
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
        durability = MethodChannel(messenger, DURABILITY_CHANNEL).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "fsync" -> {
                        val path = call.argument<String>("path")
                        result.success(if (path == null) false else fsync(path))
                    }
                    else -> result.notImplemented()
                }
            }
        }
        if (isCaptureIntent(intent)) pendingCapture = true
    }

    /**
     * 对一个文件调 `fsync`。**失败一律返回 false，绝不抛给 Dart** ——
     * 加固落盘不该让一次正常保存变成失败（内容已经写进内核缓冲，
     * 只是在"掉电"这个边界上退回到原来的可靠性）。
     *
     * 目录也能 fsync（`open(dir, O_RDONLY)` 在某些实现上可行），所以先试目录、
     * 失败再当普通文件处理 —— rename 之后刷一下父目录，目录项才算真的落盘。
     */
    private fun fsync(path: String): Boolean {
        return try {
            ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
                Os.fsync(fd.fileDescriptor)
            }
            true
        } catch (e: Exception) {
            false
        }
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
        private const val DURABILITY_CHANNEL = "guideline/file_durability"
        const val ACTION_CAPTURE = "com.maker.guideline.SHORTCUT_CAPTURE"
    }
}
