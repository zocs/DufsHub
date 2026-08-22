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
    private val NOTIFY_PERMISSION_CODE = 1002

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // API 33+ 的通知运行权限要在前台服务常驻通知显示前拿到。
        // 只挂在 requestStorage 通道上不够：存量用户存储权限早已授予，
        // 那条路径不会再走，通知会被静默压制（只能靠系统"渠道创建后
        // 自动弹一次"的兜底，时机不可控）。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFY_PERMISSION_CODE
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        channel.setMethodCallHandler { call, result ->
            // 顶层兜底：handler 抛出的任何异常以 result.error 回到 Dart，
            /// 否则 Dart 只能收到泛化的 channel 错误（如 FGS 后台启动限制
            /// 的 ForegroundServiceStartNotAllowedException）。
            try {
                handleMethodCall(call, result)
            } catch (e: Exception) {
                Log.e("fileinfra", "method ${call.method} failed", e)
                result.error("native_error", "${e.javaClass.simpleName}: ${e.message}", null)
            }
        }
    }

    private fun handleMethodCall(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
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
                    // API 33+ FGS 通知需要 POST_NOTIFICATIONS 运行时授权，
                    // 否则服务常驻通知被系统静默隐藏。
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            NOTIFY_PERMISSION_CODE
                        )
                    }
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
                    if (port !in 1..65535 || path.isEmpty()) {
                        result.error("invalid_args", "port=$port path-empty=${path.isEmpty()}", null)
                        return
                    }
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

    /// Dart 侧不等待授权结果（settings 页/启动流程都会重新查
    /// isStorageGranted），这里只做日志兜底，防止系统回调缺实现被吞。
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        Log.d("fileinfra", "permission result code=$requestCode granted=$granted")
    }
}
