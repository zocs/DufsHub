package cc.merr.fileinfra

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket

class DufsForegroundService : Service() {

    @Volatile
    private var dufsProcess: Process? = null

    companion object {
        private const val TAG = "fileinfra"
        private const val CHANNEL_ID = "fileinfra_server"
        private const val NOTIFICATION_ID = 1001
        private const val PREFS = "fileinfra_native"

        /// 通知栏多语标签（三语 × 文件/剪切板/停止/发送/拉取）
        private data class NotifLabels(
            val file: String, val clip: String, val stop: String,
            val send: String, val pull: String
        )

        const val ACTION_START = "cc.merr.fileinfra.action.START"
        const val ACTION_STOP = "cc.merr.fileinfra.action.STOP"
        const val ACTION_SEND_CLIPBOARD = "cc.merr.fileinfra.action.SEND_CLIPBOARD"
        const val ACTION_PULL_CLIPBOARD = "cc.merr.fileinfra.action.PULL_CLIPBOARD"

        @Volatile
        var isRunning = false
            private set
        @Volatile
        var currentPort = 0
            private set
        @Volatile
        var currentPath = ""
            private set
        @Volatile
        var currentAddress = ""
            private set
        @Volatile
        var currentClipboardAddress = ""
            private set
        @Volatile
        var lastError: String? = null
            private set

        /// 启动代数：每次 start/stop/timeout 递增。启动 worker 持有自己
        /// 的代数提交结果，发现已被更新的操作超越就丢弃（并杀掉自己
        /// 的子进程）——避免慢启动的失败清理误杀后来者的子进程。
        @Volatile
        var startGeneration = 0
            private set

        /// 让快捷磁贴直接用 App 上次成功下发的一组启动参数重启服务
        ///（App 未运行时 Dart 侧不可达）。args 含 --auth 明文，落点是
        /// app-private SharedPreferences（仅本 uid 可读）；运行中子进程的
        /// /proc/<pid>/cmdline 本就含同样的值，不降低现有暴露面。
        fun readLastLaunch(context: Context): Intent? {
            return try {
                val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                val port = prefs.getInt("port", 0)
                val path = prefs.getString("path", null) ?: return null
                if (port == 0 || path.isEmpty()) return null
                val args = ArrayList<String>()
                val arr = org.json.JSONArray(prefs.getString("args", "[]"))
                for (i in 0 until arr.length()) args.add(arr.getString(i))
                Intent(context, DufsForegroundService::class.java)
                    .setAction(ACTION_START)
                    .putExtra("port", port)
                    .putExtra("path", path)
                    .putExtra("args", args.toTypedArray())
                    .putExtra("lang", prefs.getString("lang", "en") ?: "en")
                    .putExtra("address", prefs.getString("address", "") ?: "")
                    .putExtra("clipboardAddress", prefs.getString("clipboardAddress", "") ?: "")
            } catch (_: Exception) {
                null
            }
        }

        /// 通知/磁贴侧的停止入口。startForegroundService 语义下
        /// onStartCommand 必须调 startForeground（ACTION_STOP 分支已保证），
        /// 退回 startService 仅在两者都失败时放弃。
        fun requestStop(context: Context) {
            val i = Intent(context, DufsForegroundService::class.java).setAction(ACTION_STOP)
            try {
                context.startForegroundService(i)
            } catch (e: Exception) {
                Log.w(TAG, "startForegroundService(STOP) failed: ${e.message}")
                try {
                    context.startService(i)
                } catch (e2: Exception) {
                    Log.w(TAG, "startService(STOP) failed: ${e2.message}")
                }
            }
        }

        /// 用户切换默认地址后由 Dart 侧经 MethodChannel 调用：只更新
        /// 通知栏地址（含持久化，磁贴重启后仍能恢复），不重启服务。
        fun updateAddress(context: Context, address: String, clipboardAddress: String) {
            if (!isRunning) return
            currentAddress = address
            try {
                context.getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                    .putString("address", address)
                    .putString("clipboardAddress", clipboardAddress)
                    .apply()
            } catch (_: Exception) {}
            val lang = context.getSharedPreferences(PREFS, MODE_PRIVATE)
                .getString("lang", "en") ?: "en"
            val notifClipboard = context.getSharedPreferences(PREFS, MODE_PRIVATE)
                .getBoolean("notifClipboard", true)
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.notify(
                NOTIFICATION_ID,
                buildNotification(
                    context, currentPort, address, clipboardAddress, currentPath, lang, notifClipboard
                )
            )
        }

        /// 设置页切换「通知栏剪贴板按钮」开关后由 Dart 侧经 MethodChannel 调用：
        /// 持久化新值并即时重建通知栏（服务未运行时只存 prefs，下次启动生效）。
        fun updateClipboardButtons(context: Context, enabled: Boolean) {
            try {
                context.getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                    .putBoolean("notifClipboard", enabled)
                    .apply()
            } catch (_: Exception) {}
            if (!isRunning) return
            val lang = context.getSharedPreferences(PREFS, MODE_PRIVATE)
                .getString("lang", "en") ?: "en"
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.notify(
                NOTIFICATION_ID,
                buildNotification(
                    context, currentPort, currentAddress, currentClipboardAddress,
                    currentPath, lang, enabled
                )
            )
        }

        /// 通知内容构建（companion 静态方法：updateAddress 与 onStartCommand
        /// 都要用，且后者可能在服务实例创建前调用）。
        /// [address] 为空时降级为仅端口；[clipboardAddress] 非空时用 BigTextStyle
        /// 展开显示两行（折叠只显示第一行主地址）。
        fun buildNotification(
            context: Context, port: Int, address: String, clipboardAddress: String,
            path: String, lang: String, notifClipboard: Boolean = true
        ): Notification {
            val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            val pendingIntent = PendingIntent.getActivity(
                context, 0, intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

            val stopIntent = Intent(context, DufsForegroundService::class.java).setAction(ACTION_STOP)
            val stopPendingIntent = PendingIntent.getService(
                context, 1, stopIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

            val showClipboardButtons = notifClipboard

            val clipboardPort = clipboardAddress.substringAfterLast(":").toIntOrNull()

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }

            // The in-app language is a user setting independent of device locale, so
            // localize the user-visible notification here (passed in via the start
            // intent) rather than via Android string resources, which key off the
            // device locale.
            val display = if (address.isBlank()) {
                when (lang) {
                    "zh" -> "端口 $port"
                    "zhTW" -> "連接埠 $port"
                    else -> "port $port"
                }
            } else address

            val labels = when (lang) {
                "zh" -> NotifLabels("文件分享", "剪切板", "停止分享", "发送", "拉取")
                "zhTW" -> NotifLabels("檔案分享", "剪貼板", "停止分享", "發送", "拉取")
                else -> NotifLabels("File Sharing", "Clipboard", "Stop", "Send", "Pull")
            }
            val fileLabel = labels.file
            val clipLabel = labels.clip
            val stopLabel = labels.stop

            val firstLine = "$fileLabel: $display"

            builder
                .setContentTitle("FileInfra")
                .setContentText(firstLine)
                // Alpha-only drawable: adaptive launcher mipmaps render as a washed
                // gray square in the status bar.
                .setSmallIcon(R.drawable.ic_stat_notify)
                .setContentIntent(pendingIntent)
                .addAction(
                    Notification.Action.Builder(
                        null,
                        stopLabel,
                        stopPendingIntent
                    ).build()
                )
                .setOngoing(true)

            // 剪贴板按钮（发送/拉取）
            if (showClipboardButtons && clipboardPort != null) {
                val sendIntent = Intent(context, DufsForegroundService::class.java)
                    .setAction(ACTION_SEND_CLIPBOARD)
                val sendPendingIntent = PendingIntent.getService(
                    context, 2, sendIntent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
                val pullIntent = Intent(context, DufsForegroundService::class.java)
                    .setAction(ACTION_PULL_CLIPBOARD)
                val pullPendingIntent = PendingIntent.getService(
                    context, 3, pullIntent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
                builder.addAction(
                    Notification.Action.Builder(null, labels.send, sendPendingIntent).build()
                )
                builder.addAction(
                    Notification.Action.Builder(null, labels.pull, pullPendingIntent).build()
                )
            }

            // 剪贴板服务可用时展开为两行，冒号对齐：
            // 折叠：文件分享：http://192.168.1.5:5000
            // 展开：文件分享：http://192.168.1.5:5000
            //       剪 切 板：http://192.168.1.5:6000
            if (clipboardAddress.isNotBlank()) {
                builder.setStyle(
                    Notification.BigTextStyle()
                        .bigText("$firstLine\n$clipLabel: $clipboardAddress")
                )
            }

            return builder.build()
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    private val startLock = Object()

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START
        if (action == ACTION_STOP) {
            handleStop()
            return START_NOT_STICKY
        }
        if (action == ACTION_SEND_CLIPBOARD) {
            handleSendClipboard()
            return START_NOT_STICKY
        }
        if (action == ACTION_PULL_CLIPBOARD) {
            handlePullClipboard()
            return START_NOT_STICKY
        }

        val port = intent?.getIntExtra("port", 0) ?: 0
        val path = intent?.getStringExtra("path") ?: ""
        val args = intent?.getStringArrayExtra("args") ?: emptyArray()
        val lang = intent?.getStringExtra("lang") ?: "en"
        val address = intent?.getStringExtra("address") ?: ""
        val clipboardAddress = intent?.getStringExtra("clipboardAddress") ?: ""
        val notifClipboard = intent?.getBooleanExtra("notifClipboard", true) ?: true

        // Clear the previous run's failure at entry (before the lock): Dart's
        // start-flow poll reads this field within ~200ms of dispatch, and a
        // stale error from run A used to fail run B's poll (TOCTOU).
        lastError = null

        if (port == 0 || path.isEmpty()) {
            Log.w(TAG, "Invalid start request: port=$port path=$path")
            stopWithForegroundContract()
            return START_NOT_STICKY
        }

        // Main thread does only quick work: dedup check, foreground promotion,
        // old-child kill, intent dispatch to a worker. The spawn + port probe
        // (up to ~4s) runs off main — it used to block onStartCommand via
        // Future.get(5s), freezing the UI and queueing every method-channel
        // reply behind it.
        val gen: Int
        synchronized(startLock) {
            if (isRunning && port == currentPort && path == currentPath) {
                Log.d(TAG, "Already running on port=$port, skip")
                return START_REDELIVER_INTENT
            }

            startGeneration++
            gen = startGeneration
            killDufs()
            persistLaunch(port, path, args, lang, address, clipboardAddress, notifClipboard)

            val notification = buildNotification(this, port, address, clipboardAddress, path, lang, notifClipboard)
            // Android 14+ (API 34) requires the 3-arg startForeground with an
            // explicit service type. We use SPECIAL_USE (declared in the
            // manifest with PROPERTY_SPECIAL_USE_FGS_SUBTYPE): dataSync would
            // hit Android 15+'s 6h/24h budget and hard-kill the app via
            // RemoteServiceException on timeout; a sideloaded local file
            // server fits the special-use category.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        }

        Thread {
            val proc = startDufs(port, path, args)
            synchronized(startLock) {
                if (gen != startGeneration) {
                    // A newer start/stop superseded us — kill OUR child too:
                    // the newer gen's killDufs() may have run before this
                    // child was even spawned, leaving it orphaned otherwise.
                    Log.w(TAG, "start gen=$gen superseded, killing stray child")
                    killProcess(proc)
                } else if (proc != null) {
                    currentPort = port
                    currentPath = path
                    currentAddress = address
                    currentClipboardAddress = clipboardAddress
                    isRunning = true
                    Log.d(TAG, "Service started: port=$port path=$path address=$address clipboard=$clipboardAddress")
                } else {
                    Log.e(TAG, "Failed to start dufs, stopping service (gen=$gen)")
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
            DufsQsTile.requestUpdate(this)
        }.start()

        // START_REDELIVER_INTENT: after a system kill the original start
        // intent (port/path/args) is redelivered and the server revives —
        // START_STICKY redelivers a null intent and used to stopSelf().
        return START_REDELIVER_INTENT
    }

    private fun handleStop() {
        // The service may have been (re)started via startForegroundService
        // (Dart stop path is stopService, but the notification stop-action
        // and the QS tile both use startForegroundService). Satisfy the
        // startForeground contract before stopping so the system never
        // raises "did not then call Service.startForeground()".
        startForegroundQuietly()
        synchronized(startLock) {
            startGeneration++
            lastError = null
            killDufs()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
        DufsQsTile.requestUpdate(this)
    }

    /// START_REDELIVER_INTENT re-dispatch and the invalid-argument path can
    /// both arrive without the service having called startForeground in this
    /// process lifetime; call it with a minimal notification then stop.
    private fun stopWithForegroundContract() {
        startForegroundQuietly()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun startForegroundQuietly() {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("FileInfra")
            .setSmallIcon(R.drawable.ic_stat_notify)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /// Safety net for FGS budget timeouts on types that have them (we ship
    /// specialUse, which has none — keep this so a future type change fails
    /// soft instead of crashing with RemoteServiceException).
    override fun onTimeout(fgsType: Int, startId: Int) {
        Log.w(TAG, "FGS timeout (type=$fgsType startId=$startId), stopping gracefully")
        synchronized(startLock) {
            startGeneration++
            lastError = "Foreground service hit its system time limit and was stopped"
            killDufs()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
        DufsQsTile.requestUpdate(this)
    }

    private fun persistLaunch(port: Int, path: String, args: Array<String>, lang: String, address: String, clipboardAddress: String, notifClipboard: Boolean = true) {
        try {
            val arr = org.json.JSONArray()
            args.forEach { arr.put(it) }
            getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                .putInt("port", port)
                .putString("path", path)
                .putString("args", arr.toString())
                .putString("lang", lang)
                .putString("address", address)
                .putString("clipboardAddress", clipboardAddress)
                .putBoolean("notifClipboard", notifClipboard)
                .apply()
        } catch (e: Exception) {
            Log.w(TAG, "persistLaunch failed: ${e.message}")
        }
    }

    /// 发送剪贴板：读系统剪贴板 → POST 到本机剪贴板服务的 /api/clipboard，
    /// 由服务广播给所有已连接的工具页。后台线程执行（网络/剪贴板都不可在主线程）。
    private fun handleSendClipboard() {
        Thread {
            try {
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                val clip = cm.primaryClip ?: return@Thread
                if (clip.itemCount == 0) return@Thread
                val text = clip.getItemAt(0).coerceToText(this)?.toString() ?: return@Thread
                if (text.isEmpty()) return@Thread
                val port = currentClipboardAddress.substringAfterLast(":").toIntOrNull() ?: return@Thread
                val url = java.net.URL("http://127.0.0.1:$port/api/clipboard")
                val conn = url.openConnection() as java.net.HttpURLConnection
                conn.requestMethod = "POST"
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "text/plain; charset=utf-8")
                conn.connectTimeout = 3000
                conn.readTimeout = 3000
                conn.outputStream.use { it.write(text.toByteArray(Charsets.UTF_8)) }
                val code = conn.responseCode
                Log.d(TAG, "send clipboard -> HTTP $code")
                conn.disconnect()
            } catch (e: Exception) {
                Log.w(TAG, "send clipboard failed: ${e.message}")
            }
        }.start()
    }

    /// 拉取剪贴板：GET 本机剪贴板服务的 /api/clipboard，把共享内容写入系统剪贴板。
    private fun handlePullClipboard() {
        Thread {
            try {
                val port = currentClipboardAddress.substringAfterLast(":").toIntOrNull() ?: return@Thread
                val url = java.net.URL("http://127.0.0.1:$port/api/clipboard")
                val conn = url.openConnection() as java.net.HttpURLConnection
                conn.requestMethod = "GET"
                conn.connectTimeout = 3000
                conn.readTimeout = 3000
                if (conn.responseCode != 200) {
                    Log.w(TAG, "pull clipboard HTTP ${conn.responseCode}")
                    conn.disconnect()
                    return@Thread
                }
                val json = conn.inputStream.bufferedReader(Charsets.UTF_8).readText()
                conn.disconnect()
                val obj = org.json.JSONObject(json)
                val text = obj.optString("text", "")
                if (text.isEmpty()) return@Thread
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                cm.setPrimaryClip(android.content.ClipData.newPlainText("FileInfra", text))
                Log.d(TAG, "pull clipboard <- ${text.length} chars")
            } catch (e: Exception) {
                Log.w(TAG, "pull clipboard failed: ${e.message}")
            }
        }.start()
    }

    /// Runs on a worker thread. Only touches its own child handle; global
    /// state (isRunning/currentPort/...) is committed by the caller under
    /// startLock, gated on the start generation.
    /// Returns the child process on success, null on failure (own child
    /// already killed on failure paths).
    private fun startDufs(port: Int, path: String, args: Array<String>): Process? {
        var proc: Process? = null
        return try {
            val nativeLibDir = applicationInfo.nativeLibraryDir
            val dufsBin = "$nativeLibDir/libdufs.so"

            val fullArgs = mutableListOf(dufsBin)
            fullArgs.addAll(args)

            // Redact --auth credential before logging — logcat is world-readable
            // on Android (any same-uid app or adb client can read it).
            val redactedArgs = mutableListOf<String>()
            var skipNext = false
            for (a in fullArgs) {
                when {
                    skipNext -> {
                        redactedArgs.add("***@/:rw")
                        skipNext = false
                    }
                    a == "--auth" -> {
                        redactedArgs.add(a)
                        skipNext = true
                    }
                    else -> redactedArgs.add(a)
                }
            }
            Log.d(TAG, "Starting dufs: ${redactedArgs.joinToString(" ")}")

            val workingDir = File(path).let { target ->
                if (target.isDirectory) target else target.parentFile ?: filesDir
            }

            val pb = ProcessBuilder(fullArgs)
            pb.directory(workingDir)
            val errLog = java.io.File(externalCacheDir ?: cacheDir, "dufs_stderr.log")
            val outLog = java.io.File(externalCacheDir ?: cacheDir, "dufs_stdout.log")
            pb.redirectErrorStream(false)
            pb.redirectError(errLog)
            pb.redirectOutput(outLog)
            proc = pb.start()
            dufsProcess = proc

            val ready = waitForServerReady(proc, port)
            if (!ready) {
                // Scrub the --auth credential from dufs's own stderr before it
                // is surfaced to logcat / the UI / the log FILE (clap echoes
                // offending args on a parse error; the file keeps it until the
                // next start otherwise).
                val authVal = fullArgs.zipWithNext().firstOrNull { it.first == "--auth" }?.second
                var errOutput = try { errLog.readText().take(500) } catch (_: Exception) { "" }
                if (!authVal.isNullOrEmpty()) {
                    errOutput = errOutput.replace(authVal, "***@/:rw")
                    try { errLog.writeText(errOutput) } catch (_: Exception) {}
                }
                val alive = isAlive(proc)
                lastError = if (!alive) {
                    "dufs process exited during startup${if (errOutput.isNotEmpty()) ": $errOutput" else ""}"
                } else {
                    "dufs did not start listening on port $port${if (errOutput.isNotEmpty()) ": $errOutput" else ""}"
                }
                Log.e(TAG, lastError ?: "")
                killProcess(proc)
                if (dufsProcess === proc) dufsProcess = null
                null
            } else {
                Log.d(TAG, "dufs verified listening on port=$port")
                proc
            }
        } catch (e: Exception) {
            lastError = "Failed to start dufs: ${e.message}"
            Log.e(TAG, lastError ?: "", e)
            // Kill via the local handle: nulling the shared field without
            // destroying would orphan a live child no later killDufs() reach.
            killProcess(proc)
            if (proc != null && dufsProcess === proc) dufsProcess = null
            null
        }
    }

    private fun waitForServerReady(proc: Process, port: Int): Boolean {
        // Runs on a worker thread already — probe inline, no executor hop.
        repeat(10) {
            // Connect FIRST, then verify OUR child is alive. A leftover
            // orphan dufs may hold the port: the fresh child fails bind
            // and exits within a few hundred ms, and a plain
            // alive-then-connect check would validate the orphan during
            // that window (hidden server, stale path/args). The settle
            // delay lets a failed-bind child die before we commit.
            if (canConnectToPort(port)) {
                if (!isAlive(proc)) return false
                Thread.sleep(250)
                return isAlive(proc) && canConnectToPort(port)
            }
            if (!isAlive(proc)) return false
            Thread.sleep(200)
        }
        return false
    }

    private fun isAlive(proc: Process?): Boolean {
        if (proc == null) return false
        return try {
            proc.exitValue()
            false
        } catch (e: IllegalThreadStateException) {
            true
        }
    }

    private fun canConnectToPort(port: Int): Boolean {
        return try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress("127.0.0.1", port), 200)
                true
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun killProcess(proc: Process?) {
        if (proc == null) return
        try {
            proc.destroy()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try { proc.destroyForcibly() } catch (_: Exception) {}
            }
        } catch (_: Exception) {}
    }

    private fun killDufs() {
        killProcess(dufsProcess)
        dufsProcess = null
        isRunning = false
        currentPort = 0
        currentPath = ""
        currentAddress = ""
        currentClipboardAddress = ""
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        Log.d(TAG, "Service destroying, stopping dufs")
        synchronized(startLock) {
            startGeneration++
            killDufs()
        }
        DufsQsTile.requestUpdate(this)
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "FileInfra Server",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                // Channel name/description show only in system Settings, which
                // follow device locale (not the in-app language), so keep them
                // neutral English. The notification itself is localized per the
                // in-app language in buildNotification().
                description = "FileInfra file-sharing service"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }
}
