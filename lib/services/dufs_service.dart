import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../constants.dart';
import '../l10n/app_localizations.dart';
import '../models/server_config.dart';
import '../models/transfer_log.dart';
import 'dufs_ffi.dart';

/// Whether to use FFI (in-process) instead of spawning dufs as child process.
/// Desktop platforms (Linux/macOS/Windows) use FFI to avoid AppImage sandbox,
/// antivirus interception, and orphan process issues.
bool get _useFfi => Platform.isLinux || Platform.isMacOS || Platform.isWindows;

class DufsService extends ChangeNotifier {
  static const _ch = MethodChannel(kMethodChannel);
  /// --log-file 轮转上限：超限即在读取后截断（内容已入 UI），防长会话
  /// 无界增长（F3 的 Dart 侧缓解；dufs 以追加模式写，截断后继续从 0 写）。
  static const _kMaxLogBytes = 16 * 1024 * 1024;

  final DufsFfi _dufsFfi = DufsFfi();
  Process? _process;
  /// iOS 子进程退出码；startServer 的 300ms 等待后非空即视为启动失败。
  int? _processExitCode;
  bool _isRunning = false;
  /// 重入守卫：_isRunning 要到启动链尾段才置位，resume 恢复与用户点击
  /// 可并发触发两次启动（UI 的 _isServerTransitioning 只护住按钮）。
  bool _isStarting = false;
  /// 当前 UI 语言，用于服务层错误/提示文案。
  String _lang = 'zh';
  String? _serverUrl;
  String? _localIp;
  String? _error;
  int _totalRequests = 0;
  String? _lastActivity;
  DateTime? _lastActivityAt;
  List<String> _allAddresses = [];

  /// 网卡名称列表，与 allAddresses 一一对应
  List<String> _allInterfaceNames = [];

  /// 实际绑定的端口（可能因冲突自动 +1，与 ServerConfig.port 解耦）
  int _activePort = 0;

  /// 传输日志（最新的在前）
  final List<TransferLog> _transferLogs = [];

  bool get isRunning => _isRunning;
  String? get serverUrl => _serverUrl;
  String? get localIp => _localIp;
  String? get error => _error;
  String? get portInfo => _portInfo;
  /// Port the running server is actually bound to. Differs from the
  /// user-configured `ServerConfig.port` when `_resolvePort` had to bump
  /// the port to find a free one. UI should prefer this for URLs while
  /// keeping ServerConfig.port as the user's stored preference.
  int get activePort => _activePort;
  int get totalRequests => _totalRequests;
  String? get lastActivity => _lastActivity;
  /// Time since the last parsed request, or null if none yet. Lets the UI
  /// tell "transfer likely in progress" from "idle after a past request".
  Duration? get timeSinceLastActivity => _lastActivityAt == null
      ? null
      : DateTime.now().difference(_lastActivityAt!);
  List<String> get allAddresses => _allAddresses;
  List<String> get allInterfaceNames => _allInterfaceNames;
  List<TransferLog> get transferLogs => List.unmodifiable(_transferLogs);

  /// Transient one-shot notice ("原端口 5000 被占用，已切到 5001"). UI consumes
  /// via [portInfo] then calls [clearPortInfo] to dismiss.
  String? _portInfo;
  void clearPortInfo() {
    _portInfo = null;
  }

  void _log(String msg) {
    debugPrint(msg);
    // ignore: body_might_complete_normally_catch_error
    if (Platform.isAndroid) {
      _ch.invokeMethod('log', {'msg': msg}).catchError((_) {});
    }
  }

  AppLocalizations get _l10n => AppLocalizations(_lang);

  String _t(String key, Map<String, String> params) {
    var s = _l10n.t(key);
    params.forEach((k, v) => s = s.replaceAll('{$k}', v));
    return s;
  }

  Future<String?> _getWifiIP() async {
    try {
      return await NetworkInfo().getWifiIP();
    } catch (_) {
      return null;
    }
  }

  /// 获取所有可用网络接口的 IPv4 地址及网卡名称
  Future<Map<String, List<String>>> _getAllAddresses() async {
    final addresses = <String>[];
    final names = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.address != '127.0.0.1' &&
              !addresses.contains(addr.address)) {
            addresses.add(addr.address);
            names.add(iface.name);
          }
        }
      }
    } catch (_) {}
    return {'addresses': addresses, 'names': names};
  }

  Future<bool> _isPortAvailable(int port) async {
    try {
      final socket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 检查端口是否被占用（公共方法，用于恢复状态检测）
  Future<bool> isPortInUse(int port) async => !(await _isPortAvailable(port));

  /// Resolve the actually-bindable port given a requested one.
  ///
  /// Strategy:
  ///   1. Try the requested port. If free, use it.
  ///   2. If busy, try to identify and stop a leftover dufs process
  ///      that is holding it (same user only). Re-probe.
  ///   3. If still busy, scan +1, +2, ... up to +9. Return the first free.
  ///   4. None free in range → throw.
  ///
  /// Sets [_portInfo] with a user-facing message when an automatic decision
  /// was made (orphan killed, port bumped). UI is expected to surface and
  /// then [clearPortInfo].
  Future<int> _resolvePort(int requestedPort) async {
    const maxBump = 9;
    if (await _isPortAvailable(requestedPort)) return requestedPort;

    _log('Port $requestedPort in use, attempting orphan cleanup...');
    await _killOrphanDufs(requestedPort);
    await Future.delayed(const Duration(milliseconds: 400));
    if (await _isPortAvailable(requestedPort)) {
      _portInfo = _t('srv.orphanKilled', {'port': '$requestedPort'});
      return requestedPort;
    }

    for (var bump = 1; bump <= maxBump; bump++) {
      final candidate = requestedPort + bump;
      if (await _isPortAvailable(candidate)) {
        _portInfo = _t('srv.portBumped', {
          'from': '$requestedPort',
          'to': '$candidate',
        });
        return candidate;
      }
    }
    throw Exception(
      _t('srv.portsExhausted', {
        'range': '$requestedPort..${requestedPort + maxBump}',
      }),
    );
  }

  /// 强制清理占用端口的 dufs 孤儿进程。
  ///
  /// Android 限制：没有 root 拿不到端口→PID 映射（lsof/ss 不可用），只能
  /// 按 cmdline 匹配杀所有 libdufs.so 进程——多个 FileInfra 实例并存的
  /// 场景会误杀，接受此权衡（桌面走 FFI 进程内无孤儿，iOS 无从下手）。
  Future<void> killOrphanOnPort(int port) async {
    try {
      await Process.run('pkill', [
        '-f',
        'libdufs.so',
      ]).catchError((_) => ProcessResult(0, 1, '', ''));
      _log('Cleaned up orphan dufs (pkill libdufs.so), port hint=$port');
    } catch (e) {
      _log('Failed to clean orphan on port $port: $e');
    }
  }

  /// 清理可能残留的 dufs 孤儿进程（占用了目标端口的）。
  /// 仅 Android 有意义：桌面走 FFI（进程内，无孤儿进程），iOS 无法这样杀子进程。
  /// (The old Windows/macOS/Linux branches were dead: `_useFfi` covers all three
  /// desktop platforms and returns above, so only the Android path ever ran.)
  Future<void> _killOrphanDufs(int port) async {
    if (_useFfi) return; // desktop: dufs runs in-process, no orphan to kill
    if (!Platform.isAndroid) return; // iOS: can't kill the child this way
    try {
      await Process.run('pkill', [
        '-f',
        'libdufs.so',
      ]).catchError((_) => ProcessResult(0, 1, '', ''));
      _log('Cleaned up orphan dufs on port $port');
    } catch (e) {
      _log('Failed to kill orphan dufs: $e');
    }
  }

  Future<void> _prepareLogFile() async {
    final tmpDir = await getTemporaryDirectory();
    _logFilePath = '${tmpDir.path}/fileinfra_dufs.log';
    try {
      await File(_logFilePath!).writeAsString('');
    } catch (_) {}
    _logFilePosition = 0;
    _logFileRemainder = '';
  }

  Future<void> startServer(ServerConfig config) async {
    if (_isRunning || _isStarting) return;
    _isStarting = true;
    try {
      await _startServerLocked(config);
    } finally {
      _isStarting = false;
    }
  }

  Future<void> _startServerLocked(ServerConfig config) async {
    _lang = config.language;
    await _prepareLogFile();
    if (config.path.isEmpty) {
      _error = _l10n.t('srv.noDir');
      notifyListeners();
      return;
    }
    // 单文件模式检查文件是否存在，目录模式检查目录是否存在
    if (config.shareSingleFile) {
      if (!await File(config.path).exists()) {
        _error = _l10n.t('srv.fileGone');
        notifyListeners();
        return;
      }
      final parentDir = p.dirname(config.path);
      if (!await Directory(parentDir).exists()) {
        _error = _l10n.t('srv.parentGone');
        notifyListeners();
        return;
      }
    } else {
      if (!await Directory(config.path).exists()) {
        _error = _l10n.t('srv.dirGone');
        notifyListeners();
        return;
      }
    }
    // exists() 通过不代表 dufs 读得了：能 stat 不能 opendir 的目录（Android 10
    // 分区存储、内存卡、Android/data 下）会让 dufs 对每个请求回 403 Forbidden
    // （server.rs handle_list_dir ← fs::read_dir 报错），而 UI 照样把二维码和
    // URL 递出去。启动前先按 dufs 的读法探一次，失败就直接拒绝启动。
    final readableError = await _probeReadable(config);
    if (readableError != null) {
      _error = readableError;
      notifyListeners();
      return;
    }
    // Validate permission consistency
    final permError = config.validatePermissions(config.language);
    if (permError != null) {
      _error = permError;
      notifyListeners();
      return;
    }
    // Resolve port: kill orphan dufs, fall back to next free port if needed.
    // _resolvePort returns the actually-bindable port WITHOUT mutating
    // config.port, so the user's preference survives across runs.
    _portInfo = null;
    final int actualPort;
    try {
      actualPort = await _resolvePort(config.port);
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
      return;
    }
    _activePort = actualPort;
    if (_portInfo != null) {
      _log(_portInfo!);
      notifyListeners();
    }
    try {
      _error = null;
      notifyListeners();
      if (Platform.isAndroid) {
        final granted =
            await _ch.invokeMethod<bool>('isStorageGranted') ?? false;
        _log('MANAGE_EXTERNAL_STORAGE granted: $granted');
        if (!granted) {
          _error = _l10n.t('srv.storagePermNeeded');
          notifyListeners();
          await _ch.invokeMethod('requestStorage');
          return;
        }
      }
      if (Platform.isAndroid) {
        // Android: start dufs via Native Service (process lives in Service, not Dart)
        final args = _buildArgs(config, actualPort);
        await _ch.invokeMethod('startForegroundService', {
          'port': actualPort,
          'path': config.path,
          'args': args,
          'lang': config.language,
        });
        // Poll service status. Kotlin side runs a TCP-connect probe that can
        // take up to ~5s on slow devices; a fixed 500ms wait races with that
        // and falsely reports failure. Poll every 200ms up to 6s.
        Map? info;
        var serviceFailed = false;
        for (var i = 0; i < 30; i++) {
          await Future.delayed(const Duration(milliseconds: 200));
          info = await _ch.invokeMethod<Map>('getServiceInfo');
          if (info?['isRunning'] == true) break;
          final svcError = (info?['error'] as String?) ?? '';
          if (svcError.isNotEmpty) {
            // Kotlin reported a definitive failure — fail fast.
            serviceFailed = true;
            break;
          }
        }
        if (serviceFailed || info == null || info['isRunning'] != true) {
          final svcError = (info?['error'] as String?) ?? '';
          _error = '${_l10n.t('srv.startFailed')}'
              '${svcError.isNotEmpty ? ': $svcError' : ''}';
          _isRunning = false;
          _activePort = 0;
          notifyListeners();
          return;
        }
      } else if (Platform.isIOS) {
        // iOS: start dufs as child process (not signed for FFI)
        await _startDufsProcess(config, actualPort);
      } else {
        // Desktop (Linux/macOS/Windows): use FFI
        await _startDufsFfi(config, actualPort);
      }

      _isRunning = true;
      _localIp = await _getWifiIP();
      final allNet = await _getAllAddresses();
      _allAddresses = allNet['addresses'] ?? [];
      _allInterfaceNames = allNet['names'] ?? [];
      // 确保默认 WiFi IP 在列表首位
      if (_localIp != null && _allAddresses.contains(_localIp)) {
        final idx = _allAddresses.indexOf(_localIp!);
        _allAddresses.removeAt(idx);
        _allInterfaceNames.removeAt(idx);
        _allAddresses.insert(0, _localIp!);
        _allInterfaceNames.insert(0, 'WiFi');
      } else if (_localIp != null && !_allAddresses.contains(_localIp)) {
        _allAddresses.insert(0, _localIp!);
        _allInterfaceNames.insert(0, 'WiFi');
      }
      if (_allAddresses.isEmpty) {
        _allAddresses.add('127.0.0.1');
        _allInterfaceNames.add('Local');
      }
      _serverUrl = 'http://${_allAddresses.first}:$actualPort';
      _log('server: $_serverUrl, all: $_allAddresses');
      // Start polling log file for transfer records
      _startLogFilePolling();
      notifyListeners();
    } catch (e) {
      // FFI 已起来的情况下不能只清状态：stopServer 会因 !_isRunning 拒停，
      // 服务器会占着端口滞留到进程退出。
      if (_useFfi && _dufsFfi.isLoaded && _dufsFfi.isRunning()) {
        try {
          _dufsFfi.stop();
        } catch (_) {}
      }
      _error = 'Start failed: $e';
      _isRunning = false;
      _activePort = 0;
      notifyListeners();
      _log('failed: $e');
    }
  }

  // ==================== Build dufs CLI args ====================
  List<String> _buildArgs(ServerConfig c, int port) {
    final args = <String>['-b', '0.0.0.0', '-p', '$port'];
    if (!c.readonly) {
      if (c.allowUpload) args.add('--allow-upload');
      if (c.allowDelete) args.add('--allow-delete');
      if (c.allowSearch) args.add('--allow-search');
      if (c.allowArchive) args.add('--allow-archive');
      if (c.allowSymlink) args.add('--allow-symlink');
    }
    if (c.auth != null && c.auth!.isNotEmpty) {
      args.addAll(['--auth', '${c.auth!}@/:rw']);
    }
    if (c.cors) args.add('--enable-cors');
    if (c.hideSystemFiles) {
      args.addAll([
        '--hidden',
        '.git,.DS_Store,Thumbs.db,.env,.idea,.vscode,__pycache__,.svn,.hg',
      ]);
    }
    if (c.renderTryIndex) args.add('--render-try-index');
    // Write HTTP logs to a temp file so we can read them on all platforms
    if (_logFilePath != null) args.addAll(['--log-file', _logFilePath!]);
    // dufs supports serving a single file directly.
    args.add(c.path);
    return args;
  }

  /// Path to the dufs log file (set before start, cleared on stop)
  String? _logFilePath;

  /// Timer to poll the log file for new entries (Android/workaround)
  Timer? _logFileTimer;

  /// Last position read in the log file
  int _logFilePosition = 0;

  /// Partial line buffered between incremental reads
  String _logFileRemainder = '';

  /// Redact the value following any `--auth` flag so credentials (user:pass)
  /// do not leak into logcat / debugPrint. Kotlin-side already redacted in
  /// v0.3.4; this is the missing Dart half (C1).
  List<String> _redactedArgs(List<String> args) {
    final out = <String>[];
    for (var i = 0; i < args.length; i++) {
      out.add(args[i]);
      if (args[i] == '--auth' && i + 1 < args.length) {
        out.add('***@/:rw');
        i++;
      }
    }
    return out;
  }

  // ==================== Start dufs via FFI (desktop) ====================
  Future<void> _startDufsFfi(ServerConfig config, int port) async {
    if (!_dufsFfi.isLoaded) {
      final libPath = await resolveDufsLibPath();
      _log('Loading dufs FFI library: $libPath');
      _dufsFfi.load(libPath);
    }
    final args = _buildArgs(config, port);
    final argv = ['dufs', ...args];
    _log('dufs ffi start: ${_redactedArgs(args).join(' ')}');
    final ret = _dufsFfi.start(argv);
    if (ret != 0) {
      _log('dufs FFI start returned $ret (failure)');
      throw Exception('dufs FFI start returned $ret');
    }
    _log('dufs FFI start returned 0 (success)');
    // 验证端口真的绑上了：_isPortAvailable 的探测与本启动之间存在 TOCTOU，
    // 端口可能被抢；dufs_start 返回 0 只代表参数解析/任务派发成功。
    if (!await _waitPortReady(port) || !_dufsFfi.isRunning()) {
      try {
        _dufsFfi.stop();
      } catch (_) {}
      throw Exception(_t('srv.notListening', {'port': '$port'}));
    }
  }

  /// 轮询本机端口直到可连接。返回 false 即超时（默认 3s）。
  Future<bool> _waitPortReady(int port,
      {Duration timeout = const Duration(seconds: 3)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final s = await Socket.connect(InternetAddress.loopbackIPv4, port,
            timeout: const Duration(milliseconds: 300));
        s.destroy();
        return true;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  // ==================== Start dufs process (iOS) ====================
  Future<void> _startDufsProcess(ServerConfig config, int port) async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final binPath = p.join(exeDir, 'dufs');
    if (!await File(binPath).exists()) {
      throw Exception(_t('srv.dufsMissing', {'path': binPath}));
    }
    final args = _buildArgs(config, port);
    final workDir = config.shareSingleFile
        ? p.dirname(config.path)
        : config.path;
    _log('dufs: $binPath ${_redactedArgs(args).join(' ')}');
    final proc = await Process.start(binPath, args, workingDirectory: workDir);
    _process = proc;
    _processExitCode = null;
    // 监听子进程退出：秒死（参数错/端口被抢）要在 UI 标记失败，运行中死掉
    // 要收回"运行中"状态——否则界面对着一个死 URL 显示在线。
    proc.exitCode.then((code) => _onProcessDied(proc, code));
    proc.stdout.listen((d) {
      final line = String.fromCharCodes(d).trim();
      _log('out: $line');
      _trackActivity(line);
    });
    proc.stderr.listen((d) {
      final line = String.fromCharCodes(d).trim();
      _log('err: $line');
      _trackActivity(line);
    });
    await Future.delayed(const Duration(milliseconds: 300));
    if (_processExitCode != null) {
      throw Exception(
        _t('srv.exitedDuringStart', {'code': '$_processExitCode'}),
      );
    }
  }

  void _onProcessDied(Process proc, int code) {
    if (_process != proc) return;
    _process = null;
    _processExitCode = code;
    if (!_isRunning) return;
    _error = _t('srv.exitedUnexpectedly', {'code': '$code'});
    _isRunning = false;
    _activePort = 0;
    _serverUrl = null;
    _totalRequests = 0;
    _lastActivity = null;
    _lastActivityAt = null;
    _allAddresses = [];
    _allInterfaceNames = [];
    _transferLogs.clear();
    _logFileTimer?.cancel();
    _logFileTimer = null;
    _log('dufs process died unexpectedly (code $code)');
    notifyListeners();
  }

  /// 解析 dufs 输出行，更新请求计数和日志列表。
  ///
  /// Returns true if state changed but does NOT notify — callers batch a single
  /// [notifyListeners] after ingesting a whole chunk. A busy transfer logs
  /// hundreds of lines per 2s poll; notifying per line rebuilt the entire home
  /// page (QR matrix included) hundreds of times per frame — the main source of
  /// desktop UI jank under load.
  bool _ingestLine(String line) {
    final entry = TransferLog.parse(line);
    if (entry == null) return false;
    _totalRequests++;
    final now = DateTime.now();
    _lastActivityAt = now;
    _lastActivity = now.toIso8601String().substring(11, 19);
    if (showInLog(entry)) {
      _transferLogs.insert(0, entry);
      if (_transferLogs.length > 200) {
        _transferLogs.removeRange(200, _transferLogs.length);
      }
    }
    return true;
  }

  /// Ingest one line and notify immediately. Used by the iOS stdout/stderr
  /// stream path, where lines arrive one at a time anyway.
  void _trackActivity(String line) {
    if (_ingestLine(line)) notifyListeners();
  }

  Future<String?> _probeReadable(ServerConfig c) =>
      probeReadableError(c, _l10n, log: _log);

  /// 可读性探测：以 dufs 实际使用的方式（opendir / open）试读一次。
  /// 返回 null 表示可读，否则返回可直接展示的本地化错误。
  ///
  /// 只取第一条目录项：`Stream.isEmpty` 收到首个事件即取消订阅，不会为
  /// 十万文件的目录做完整 readdir（那会卡住启动）。
  @visibleForTesting
  static Future<String?> probeReadableError(
    ServerConfig c,
    AppLocalizations l10n, {
    void Function(String)? log,
  }) async {
    final say = log ?? _noopLog;
    try {
      if (c.shareSingleFile) {
        final raf = await File(c.path).open();
        await raf.close();
      } else {
        await Directory(c.path).list(followLinks: false).isEmpty;
      }
      return null;
    } on FileSystemException catch (e) {
      final key =
          c.shareSingleFile ? 'srv.fileNotReadable' : 'srv.dirNotReadable';
      final reason = e.osError?.message ?? e.message;
      say('readability probe failed for ${c.path}: $reason');
      // 分区存储那段建议只对 Android 有意义：桌面走到这里通常是权限位、
      // SELinux 或断开的网络盘，照抄 Android 文案会把人带偏。
      final hint = !c.shareSingleFile && Platform.isAndroid
          ? ' ${l10n.t('srv.dirNotReadableAndroid')}'
          : '';
      return '${l10n.t(key)}（$reason）$hint';
    } catch (e) {
      // 探测本身失败（超时等）≠ 目录不可读：放行，让 dufs 自己决定。
      // 真出现 403 时现在能在传输记录里看到（showInLog 保留失败请求）。
      say('readability probe inconclusive for ${c.path}: $e');
      return null;
    }
  }

  static void _noopLog(String _) {}

  /// 该请求是否值得进「传输记录」。
  @visibleForTesting
  static bool showInLog(TransferLog entry) {
    final path = entry.path;
    // 失败请求必须留痕：用户报「浏览器只显示 Forbidden」时，证据就是这条
    // `GET / 403`，而旧过滤规则恰好把 path=='/' 全丢了。
    if (entry.status >= 400) {
      if (path.contains('/dufs-assets/')) return false;
      if (path.endsWith('.ico') ||
          path.endsWith('.css') ||
          path.endsWith('.js')) {
        return false;
      }
      return true;
    }
    if (path == '/' || path.isEmpty) return false;
    if (path.endsWith('/')) return false;
    if (path.endsWith('.css') ||
        path.endsWith('.js') ||
        path.endsWith('.ico')) {
      return false;
    }
    if (path.contains('/dufs-assets/')) return false;
    if (entry.method == 'MKCOL' ||
        entry.method == 'OPTIONS' ||
        entry.method == 'PROPFIND') {
      return false;
    }
    if (entry.isDownload && !path.contains('.')) return false;
    return entry.isDownload || entry.isUpload || entry.isDelete;
  }

  void clearLogs() {
    _transferLogs.clear();
    notifyListeners();
  }

  void _startLogFilePolling() {
    _logFileTimer?.cancel();
    _logFileTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _readLogFile(),
    );
  }

  Future<void> _readLogFile() async {
    if (_logFilePath == null) return;
    try {
      final file = File(_logFilePath!);
      if (!await file.exists()) return;
      final raf = await file.open();
      try {
        final length = await raf.length();
        if (length < _logFilePosition) {
          _logFilePosition = 0;
          _logFileRemainder = '';
        }
        if (length == _logFilePosition) return;

        await raf.setPosition(_logFilePosition);
        final bytes = await raf.read(length - _logFilePosition);
        _logFilePosition = length;

        final chunk = utf8.decode(bytes, allowMalformed: true);
        final merged = _logFileRemainder + chunk;
        final endsWithNewline = merged.endsWith('\n');
        final lines = merged.split('\n');
        _logFileRemainder = endsWithNewline ? '' : lines.removeLast();

        var changed = false;
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isNotEmpty && _ingestLine(trimmed)) changed = true;
        }
        if (changed) notifyListeners();
        // F3 缓解：内容已消化，超过上限即截断（dufs 追加写会从 0 续写），
        // 防单个长分享会话把临时目录写爆。
        if (length > _kMaxLogBytes) {
          _overCap = true;
        }
      } finally {
        await raf.close();
      }
      if (_overCap) {
        _overCap = false;
        _logFilePosition = 0;
        _logFileRemainder = '';
        final w = await file.open(mode: FileMode.writeOnly);
        try {
          await w.truncate(0);
        } finally {
          await w.close();
        }
      }
    } catch (_) {}
  }

  /// _readLogFile 内部跨 try/finally 的截断信号。
  bool _overCap = false;

  Future<void> stopServer() async {
    if (!_isRunning) return;
    if (_useFfi && _dufsFfi.isLoaded) {
      // FFI mode: stop the in-process server
      _dufsFfi.stop();
      // Wait for the server to release the port (accept() may be blocking)
      var released = false;
      for (int i = 0; i < 20; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        if (!_dufsFfi.isRunning()) {
          released = true;
          break;
        }
      }
      // 已释放就不用再等；Windows 上端口常滞留 TIME_WAIT，额外等一段
      if (!released || Platform.isWindows) {
        await Future.delayed(const Duration(milliseconds: 800));
      }
    } else if (_process != null) {
      // Process mode (iOS): kill child process
      _process!.kill();
      try {
        await _process!.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {}
      _process = null;
      _processExitCode = null;
    }
    if (Platform.isAndroid) {
      _ch.invokeMethod('stopForegroundService').catchError((_) {});
    }
    _isRunning = false;
    _serverUrl = null;
    _activePort = 0;
    _totalRequests = 0;
    _lastActivity = null;
    _lastActivityAt = null;
    _allAddresses = [];
    _allInterfaceNames = [];
    _transferLogs.clear();
    _logFileTimer?.cancel();
    _logFileTimer = null;
    _logFilePath = null;
    _logFilePosition = 0;
    _logFileRemainder = '';
    notifyListeners();
  }

  /// 恢复到 Native Service 管理的 dufs 进程状态（Activity 重建后查询 Service）
  Future<void> restoreFromService() async {
    if (!Platform.isAndroid) return;
    try {
      final info = await _ch.invokeMethod<Map>('getServiceInfo');
      if (info != null && info['isRunning'] == true) {
        final port = info['port'] as int? ?? 0;
        _activePort = port;
        await _prepareLogFile();
        _totalRequests = 0;
        _lastActivity = null;
        _lastActivityAt = null;
        _transferLogs.clear();
        _localIp = await _getWifiIP();
        final allNet = await _getAllAddresses();
        _allAddresses = allNet['addresses'] ?? [];
        _allInterfaceNames = allNet['names'] ?? [];
        if (_localIp != null && _allAddresses.contains(_localIp)) {
          final idx = _allAddresses.indexOf(_localIp!);
          _allAddresses.removeAt(idx);
          _allInterfaceNames.removeAt(idx);
          _allAddresses.insert(0, _localIp!);
          _allInterfaceNames.insert(0, 'WiFi');
        } else if (_localIp != null && !_allAddresses.contains(_localIp)) {
          _allAddresses.insert(0, _localIp!);
          _allInterfaceNames.insert(0, 'WiFi');
        }
        if (_allAddresses.isEmpty) {
          _allAddresses.add('127.0.0.1');
          _allInterfaceNames.add('Local');
        }
        _serverUrl = 'http://${_allAddresses.first}:$port';
        _isRunning = true;
        _startLogFilePolling();
        _log('restored from native service: $_serverUrl');
        notifyListeners();
      }
    } catch (e) {
      _log('Failed to restore from service: $e');
    }
  }

  @override
  void dispose() {
    // Cancel the log-file poll timer before anything else: otherwise it can
    // fire after dispose and call notifyListeners() on a disposed
    // ChangeNotifier ("A ChangeNotifier was used after being disposed").
    // stopServer() cancels it too, but dispose() can run without a prior stop.
    _logFileTimer?.cancel();
    _logFileTimer = null;
    if (_useFfi && _dufsFfi.isLoaded) {
      try {
        _dufsFfi.stop();
      } catch (_) {}
    }
    try {
      _process?.kill();
    } catch (_) {}
    _process = null;
    _isRunning = false;
    super.dispose();
  }
}
