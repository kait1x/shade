package com.example.shade

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val keyWorker = java.util.concurrent.Executors.newSingleThreadExecutor()

    private val CHANNEL = "com.shade.app/security"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Ensure screenshots and screen recording are allowed across all screens
        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun onResume() {
        super.onResume()
        // Ensure screenshots and screen recording remain allowed
        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "deriveDatabaseKey" -> {
                    val password = call.argument<ByteArray>("password")
                    val salt = call.argument<ByteArray>("salt")
                    if (password == null || password.size != 32 || salt == null || salt.size > 128) {
                        result.error("INVALID_KDF_INPUT", "Invalid database key input", null)
                    } else {
                        keyWorker.execute {
                            try {
                                val started = System.nanoTime()
                                val key = DatabaseKeyDerivation.derive(password, salt, 2100000)
                                val encoded = android.util.Base64.encodeToString(key, android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP)
                                java.util.Arrays.fill(key, 0.toByte())
                                android.util.Log.i("ShadeKeyDerivation", "Database key prepared in " + ((System.nanoTime() - started) / 1000000) + " ms")
                                runOnUiThread { result.success(encoded) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("KDF_FAILED", "Database key preparation failed", null) }
                            } finally {
                                java.util.Arrays.fill(password, 0.toByte())
                            }
                        }
                    }
                }
                "enableSecureMode" -> {
                    // Screenshot and screen recording restrictions removed across all screens
                    disableSecureMode()
                    result.success(null)
                }
                "disableSecureMode" -> {
                    disableSecureMode()
                    result.success(null)
                }
                "setSecureMode" -> {
                    // Screenshot and screen recording restrictions removed across all screens
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
        // Screenshot restriction removed: do not set FLAG_SECURE
        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    private fun disableSecureMode() {
        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    private fun excludeFromRecents() {
        val recentsFlag = 0x00080000
        window.addFlags(recentsFlag)
    }
}
