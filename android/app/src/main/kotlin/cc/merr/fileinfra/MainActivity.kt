package cc.merr.fileinfra

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "cc.merr.fileinfra/native"
    private val STORAGE_PERMISSION_CODE = 1001

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "log" -> {
                    val msg = call.argument<String>("msg") ?: ""
                    Log.d("fileinfra", msg)
                    result.success(null)
                }
                "getNativeLibraryDir" -> {
                    result.success(applicationInfo.nativeLibraryDir)
                }
                "isStorageGranted" -> {
                    val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        Environment.isExternalStorageManager()
                    } else {
                        ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
                    }
                    Log.d("fileinfra", "Storage granted: $granted (API ${Build.VERSION.SDK_INT})")
                    result.success(granted)
                }
                "requestStorage" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        try {
                            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                            intent.data = Uri.parse("package:${packageName}")
                            startActivity(intent)
                        } catch (e: Exception) {
                            startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                        }
                    } else {
                        ActivityCompat.requestPermissions(this, arrayOf(
                            Manifest.permission.READ_EXTERNAL_STORAGE,
                            Manifest.permission.WRITE_EXTERNAL_STORAGE
                        ), STORAGE_PERMISSION_CODE)
                    }
                    result.success(true)
                }
                "startForegroundService" -> {
                    val port = call.argument<Int>("port") ?: 0
                    val path = call.argument<String>("path") ?: ""
                    val args = call.argument<List<String>>("args")?.toTypedArray() ?: emptyArray()
                    val lang = call.argument<String>("lang") ?: "en"
                    val intent = Intent(this, DufsForegroundService::class.java)
                    intent.putExtra("port", port)
                    intent.putExtra("path", path)
                    intent.putExtra("args", args)
                    intent.putExtra("lang", lang)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    Log.d("fileinfra", "Foreground service start requested: port=$port")
                    result.success(true)
                }
                "stopForegroundService" -> {
                    val intent = Intent(this, DufsForegroundService::class.java)
                    stopService(intent)
                    Log.d("fileinfra", "Foreground service stop requested")
                    result.success(true)
                }
                "isServiceRunning" -> {
                    result.success(DufsForegroundService.isRunning)
                }
                "getServiceInfo" -> {
                    val info = hashMapOf<String, Any>(
                        "isRunning" to DufsForegroundService.isRunning,
                        "port" to DufsForegroundService.currentPort,
                        "path" to DufsForegroundService.currentPath,
                        "error" to (DufsForegroundService.lastError ?: "")
                    )
                    result.success(info)
                }
                else -> result.notImplemented()
            }
        }
    }
}
