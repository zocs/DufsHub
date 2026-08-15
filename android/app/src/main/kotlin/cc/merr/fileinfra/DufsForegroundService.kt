package cc.merr.fileinfra

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket

class DufsForegroundService : Service() {

    private var dufsProcess: Process? = null

    companion object {
        private const val TAG = "fileinfra"
        private const val CHANNEL_ID = "fileinfra_server"
        private const val NOTIFICATION_ID = 1001

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
        var lastError: String? = null
            private set
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    private val startLock = Object()

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val port = intent?.getIntExtra("port", 0) ?: 0
        val path = intent?.getStringExtra("path") ?: ""
        val args = intent?.getStringArrayExtra("args") ?: emptyArray()
        val lang = intent?.getStringExtra("lang") ?: "en"

        if (port == 0 || path.isEmpty()) {
            Log.w(TAG, "Invalid start request: port=$port path=$path")
            stopSelf()
            return START_NOT_STICKY
        }

        synchronized(startLock) {
            if (isRunning && port == currentPort && path == currentPath) {
                Log.d(TAG, "Already running on port=$port, skip")
                return START_STICKY
            }

            killDufs()

            val notification = buildNotification(port, path, lang)
            // Android 14+ (API 34) requires the 3-arg startForeground with an
            // explicit service type; the manifest already declares
            // android:foregroundServiceType="dataSync". Calling the 2-arg
            // overload on API 34+ throws MissingForegroundServiceTypeException
            // and the service crashes on start.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }

            lastError = null
            val success = startDufs(port, path, args)
            if (!success) {
                Log.e(TAG, "Failed to start dufs, stopping service")
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }

            currentPort = port
            currentPath = path
            isRunning = true

            Log.d(TAG, "Service started: port=$port path=$path")
            return START_STICKY
        }
    }

    private fun startDufs(port: Int, path: String, args: Array<String>): Boolean {
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
            dufsProcess = pb.start()

            val ready = waitForServerReady(port)
            if (!ready) {
                // Scrub the --auth credential from dufs's own stderr before it
                // is surfaced to logcat / the UI: clap echoes offending args on
                // a parse error, and the arg-log redaction above doesn't cover
                // dufs's own output.
                val authVal = fullArgs.zipWithNext().firstOrNull { it.first == "--auth" }?.second
                var errOutput = try { errLog.readText().take(500) } catch (_: Exception) { "" }
                if (!authVal.isNullOrEmpty()) errOutput = errOutput.replace(authVal, "***@/:rw")
                val alive = isProcessAlive()
                lastError = if (!alive) {
                    "dufs process exited during startup${if (errOutput.isNotEmpty()) ": $errOutput" else ""}"
                } else {
                    "dufs did not start listening on port $port${if (errOutput.isNotEmpty()) ": $errOutput" else ""}"
                }
                Log.e(TAG, lastError ?: "")
                killDufs()
                false
            } else {
                Log.d(TAG, "dufs verified listening on port=$port")
                true
            }
        } catch (e: Exception) {
            lastError = "Failed to start dufs: ${e.message}"
            Log.e(TAG, lastError ?: "", e)
            dufsProcess = null
            false
        }
    }

    private fun waitForServerReady(port: Int): Boolean {
        // Socket.connect() on the main thread throws NetworkOnMainThreadException
        // (Android API 11+ StrictMode). onStartCommand runs on main, so we offload
        // the whole probe loop to a worker and block here on the result.
        val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
        return try {
            executor.submit<Boolean> {
                repeat(10) {
                    if (!isProcessAlive()) return@submit false
                    if (canConnectToPort(port)) return@submit true
                    Thread.sleep(200)
                }
                canConnectToPort(port)
            }.get(5, java.util.concurrent.TimeUnit.SECONDS)
        } catch (_: Exception) {
            false
        } finally {
            executor.shutdownNow()
        }
    }

    private fun isProcessAlive(): Boolean {
        return try {
            dufsProcess?.exitValue()
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

    private fun killDufs() {
        try {
            dufsProcess?.destroy()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try { dufsProcess?.destroyForcibly() } catch (_: Exception) {}
            }
        } catch (_: Exception) {}
        dufsProcess = null
        isRunning = false
        currentPort = 0
        currentPath = ""
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        Log.d(TAG, "Service destroying, stopping dufs")
        killDufs()
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

    private fun buildNotification(port: Int, path: String, lang: String): Notification {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        // The in-app language is a user setting independent of device locale, so
        // localize the user-visible notification here (passed in via the start
        // intent) rather than via Android string resources, which key off the
        // device locale.
        val (title, text) = when (lang) {
            "zh" -> "FileInfra 文件分享" to "服务运行中（端口 $port）"
            "zhTW" -> "FileInfra 檔案分享" to "服務運行中（連接埠 $port）"
            else -> "FileInfra File Sharing" to "Running (port $port)"
        }

        return builder
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }
}
