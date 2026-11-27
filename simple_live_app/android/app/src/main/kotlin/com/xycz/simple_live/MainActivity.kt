package com.xycz.simple_live

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "simple_live/audio_notification"
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel = methodChannel
        // 通知栏的播放 / 暂停按钮回传给 Flutter 处理
        AudioNotificationService.toggleCallback = {
            methodChannel.invokeMethod("togglePlay", null)
        }
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    val args = call.arguments as? Map<*, *>
                    @Suppress("UNCHECKED_CAST")
                    AudioNotificationService.show(
                        this,
                        (args as? Map<String, Any?>) ?: emptyMap(),
                    )
                    result.success(null)
                }

                "setPlaying" -> {
                    val playing = call.argument<Boolean>("playing") ?: true
                    AudioNotificationService.show(this, mapOf("playing" to playing))
                    result.success(null)
                }

                "hide" -> {
                    AudioNotificationService.hide(this)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        AudioNotificationService.toggleCallback = null
        channel?.setMethodCallHandler(null)
        channel = null
        super.onDestroy()
    }
}
