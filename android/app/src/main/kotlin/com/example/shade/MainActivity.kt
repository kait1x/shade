package com.example.shade

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Канал для управления безопасностью (скриншоты, запись экрана)
        flutterEngine.dartExecutor.binaryMessenger.setMethodCallHandler(
            "com.shade.app/security"
        ) { call, result ->
            when (call.method) {
                "enableSecureMode" -> {
                    enableSecureMode()
                    result.success(null)
                }
                "disableSecureMode" -> {
                    disableSecureMode()
                    result.success(null)
                }
                "excludeFromRecents" -> {
                    excludeFromRecents()
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun enableSecureMode() {
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }

    private fun disableSecureMode() {
        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    private fun excludeFromRecents() {
        // Убираем приложение из списка недавних
        val recentsFlag = WindowManager.LayoutParams.FLAG_EXCLUDE_FROM_RECENTS
        window.addFlags(recentsFlag)
    }
}
