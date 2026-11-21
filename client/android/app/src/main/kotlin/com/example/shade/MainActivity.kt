package com.example.shade

import android.os.Bundle
import android.view.WindowManager
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val keyWorker = java.util.concurrent.Executors.newSingleThreadExecutor()

    private val CHANNEL = "com.shade.app/security"
    private val PICK_RECOVERY_REQUEST = 4711
    private var pendingPick: MethodChannel.Result? = null
    private val SAVE_RECOVERY_REQUEST = 4712
    private var pendingSave: Pair<MethodChannel.Result, ByteArray>? = null

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
                "saveRecoveryPackage" -> {
                    val bytes = call.argument<String>("json")?.toByteArray(Charsets.UTF_8)
                    if (bytes == null || bytes.isEmpty() || bytes.size > 1024 * 1024) {
                        result.error("INVALID_RECOVERY_FILE", "Неверный размер файла восстановления", null)
                    } else if (pendingPick != null || pendingSave != null) {
                        result.error("FILE_DIALOG_IN_PROGRESS", "Диалог файлов уже открыт", null)
                    } else {
                        pendingSave = Pair(result, bytes)
                        try {
                            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "application/json"
                                putExtra(Intent.EXTRA_TITLE, "shade-recovery.json")
                            }
                            startActivityForResult(intent, SAVE_RECOVERY_REQUEST)
                        } catch (e: Exception) {
                            pendingSave = null
                            result.error("SAVE_UNAVAILABLE", "Нет приложения для сохранения файла", null)
                        }
                    }
                }
                "pickRecoveryPackage" -> {
                    // Системный выбор JSON-пакета восстановления без сторонних
                    // плагинов: ACTION_OPEN_DOCUMENT, байты читаются здесь.
                    if (pendingPick != null || pendingSave != null) {
                        result.error("PICK_IN_PROGRESS", "Выбор файла уже открыт", null)
                    } else {
                        pendingPick = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/json"
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, false)
                        }
                        try {
                            startActivityForResult(intent, PICK_RECOVERY_REQUEST)
                        } catch (e: Exception) {
                            pendingPick = null
                            result.error("PICK_UNAVAILABLE", "Нет приложения для выбора файла", null)
                        }
                    }
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

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == SAVE_RECOVERY_REQUEST) {
            val (result, bytes) = pendingSave ?: return
            pendingSave = null
            val uri = data?.data
            if (resultCode != RESULT_OK || uri == null) {
                result.success(false)
                return
            }
            try {
                contentResolver.openOutputStream(uri, "wt")?.use { it.write(bytes) }
                    ?: throw java.io.IOException("No writable output stream")
                result.success(true)
            } catch (e: Exception) {
                result.error("SAVE_FAILED", "Не удалось записать файл", null)
            }
            return
        }
        if (requestCode != PICK_RECOVERY_REQUEST) return
        val result = pendingPick
        pendingPick = null
        if (result == null) return
        if (resultCode != RESULT_OK || data?.data == null) {
            result.success(null) // отмена выбора — не ошибка
            return
        }
        val uri = data.data!!
        try {
            contentResolver.openInputStream(uri)?.use { stream ->
                // Лимит пакета 1 МБ; читаем на байт больше, чтобы клиент честно
                // отклонил превышение, а не обрезал молча.
                val buffer = java.io.ByteArrayOutputStream()
                val chunk = ByteArray(64 * 1024)
                var total = 0
                while (total <= 1024 * 1024) {
                    val read = stream.read(chunk)
                    if (read <= 0) break
                    buffer.write(chunk, 0, read)
                    total += read
                }
                val bytes = buffer.toByteArray()
                val name = uri.lastPathSegment ?: "recovery-package.json"
                result.success(mapOf("name" to name, "bytes" to bytes))
            } ?: result.error("PICK_READ_FAILED", "Не удалось прочитать файл", null)
        } catch (e: Exception) {
            result.error("PICK_READ_FAILED", "Не удалось прочитать файл", null)
        }
    }
}
