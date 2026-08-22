package cc.merr.fileinfra

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle

/// 磁贴的后台 FGS 启动兜底：以前台 Activity 身份转发启动 Intent 后立即
/// 退出，用户看到的是一次透明闪过。
class TileTrampolineActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val launch = Intent(this, DufsForegroundService::class.java)
            .setAction(DufsForegroundService.ACTION_START)
        intent.extras?.let { launch.putExtras(it) }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(launch)
            } else {
                startService(launch)
            }
        } catch (e: Exception) {
            android.util.Log.w("fileinfra", "trampoline start failed: ${e.message}")
        }
        finish()
    }
}
