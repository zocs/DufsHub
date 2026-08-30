package cc.merr.fileinfra

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.widget.Toast

/// 快捷设置磁贴：点击 = 用上次保存的启动参数 启/停 分享服务。
/// 未在 App 里配置过（无缓存参数）时提示先进 App 设置。
class DufsQsTile : TileService() {

    override fun onStartListening() {
        updateTile()
    }

    override fun onClick() {
        val ctx = applicationContext
        if (DufsForegroundService.isRunning) {
            DufsForegroundService.requestStop(ctx)
        } else {
            val launch = DufsForegroundService.readLastLaunch(ctx)
            if (launch == null) {
                Toast.makeText(ctx, "Open FileInfra to configure sharing", Toast.LENGTH_SHORT).show()
                return
            }
            startServerFromTile(ctx, launch)
        }
        // 状态刷新走 requestListeningState → onStartListening；这里不直接
        // updateTile()，因为服务启/停是异步的，过早刷新会闪错误状态。
    }

    private fun startServerFromTile(ctx: Context, launch: Intent) {
        try {
            // startForegroundService 是 API 26+（minSdk 24）：API 24/25 用
            // startService，服务内自行 startForeground。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(launch)
            } else {
                @Suppress("DEPRECATION")
                ctx.startService(launch)
            }
        } catch (e: Exception) {
            // API 31+ 对后台 FGS 启动有限制；磁贴点击的豁免口径各家
            // ROM 实现不一。兜底走透明 trampoline activity（前台上下文）。
            val trampoline = Intent(ctx, TileTrampolineActivity::class.java).putExtras(launch)
            val pi = PendingIntent.getActivity(
                ctx, 2, trampoline,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    startActivityAndCollapse(pi)
                } else {
                    @Suppress("DEPRECATION")
                    startActivityAndCollapse(trampoline)
                }
            } catch (e2: Exception) {
                android.util.Log.w("fileinfra", "tile trampoline failed: ${e2.message}")
            }
        }
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        tile.state = if (DufsForegroundService.isRunning) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        // tile.subtitle 是 API 29+（minSdk 24）：低版本不设副标题。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = if (DufsForegroundService.isRunning && DufsForegroundService.currentPort > 0) {
                "Port ${DufsForegroundService.currentPort}"
            } else {
                null
            }
        }
        tile.updateTile()
    }

    companion object {
        /// 服务侧状态变化后调用，让系统回调 onStartListening 刷新磁贴。
        /// 磁贴未被添加时是 no-op。
        fun requestUpdate(context: Context) {
            try {
                TileService.requestListeningState(
                    context,
                    ComponentName(context, DufsQsTile::class.java)
                )
            } catch (_: Exception) {
            }
        }
    }
}
