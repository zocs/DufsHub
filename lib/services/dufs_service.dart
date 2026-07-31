import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../constants.dart';
import '../models/server_config.dart';
import '../models/transfer_log.dart';
import 'dufs_ffi.dart';

/// Whether to use FFI (in-process) instead of spawning dufs as child process.
/// Desktop platforms (Linux/macOS/Windows) use FFI to avoid AppImage sandbox,
/// antivirus interception, and orphan process issues.
bool get _useFfi => Platform.isLinux || Platform.isMacOS || Platform.isWindows;

class DufsService extends ChangeNotifier {
  static const _ch = MethodChannel(kMethodChannel);

  final DufsFfi _dufsFfi = DufsFfi();
  Process? _process;
  bool _isRunning = false;
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
      _portInfo = '检测到残留 dufs 进程，已结束并使用端口 $requestedPort';
      return requestedPort;
    }

    for (var bump = 1; bump <= maxBump; bump++) {
      final candidate = requestedPort + bump;
      if (await _isPortAvailable(candidate)) {
        _portInfo = '原端口 $requestedPort 被其他程序占用，已切换到 $candidate';
        return candidate;
      }
    }
    throw Exception(
      '端口 $requestedPort..${requestedPort + maxBump} 全部被占用，请手动指定一个空闲端口',
    );
  }

  /// 强制清理占用端口的 dufs 孤儿进程
  Future<void> killOrphanOnPort(int port) async {
    try {
      if (Platform.isAndroid) {
        await Process.run('pkill', [
          '-f',
          'libdufs.so',
        ]).catchError((_) => ProcessResult(0, 1, '', ''));
      } else if (Platform.isLinux || Platform.isMacOS) {
        final r = await Process.run('lsof', [
          '-ti',
          ':$port',
        ]).catchError((_) => ProcessResult(0, 1, '', ''));
        final pids = r.stdout.toString().trim().split('\n');
        for (final pid in pids) {
          if (pid.isEmpty) continue;
          final cmd = await Process.run('ps', [
            '-p',
            pid,
            '-o',
            'comm=',
          ]).catchError((_) => ProcessResult(0, 1, '', ''));
          if (cmd.stdout.toString().toLowerCase().contains('dufs')) {
            _log('Killing orphan dufs PID=$pid on port $port');
            await Process.run('kill', [
              pid,
            ]).catchError((_) => ProcessResult(0, 1, '', ''));
          }
        }
      }
      _log('Cleaned up orphan on port $port');
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
    _logFilePath = '${tmpDir.path}/dufshub_dufs.log';
    try {
      await File(_logFilePath!).writeAsString('');
    } catch (_) {}
    _logFilePosition = 0;
    _logFileRemainder = '';
  }

  Future<void> startServer(ServerConfig config) async {
    if (_isRunning) return;
    await _prepareLogFile();
    if (config.path.isEmpty) {
      _error = 'No directory';
      notifyListeners();
      return;
    }
    // 单文件模式检查文件是否存在，目录模式检查目录是否存在
    if (config.shareSingleFile) {
      if (!await File(config.path).exists()) {
        _error = 'File not found';
        notifyListeners();
        return;
      }
      final parentDir = p.dirname(config.path);
      if (!await Directory(parentDir).exists()) {
        _error = 'Parent directory not found';
        notifyListeners();
        return;
      }
    } else {
      if (!await Directory(config.path).exists()) {
        _error = 'Directory not found';
        notifyListeners();
        return;
      }
    }
    // Validate permission consistency
    final permError = config.validatePermissions();
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
          _error = '需要开启"所有文件访问权限"才能正常列出文件。请在系统设置中开启后重试。';
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
          _error = '服务启动失败${svcError.isNotEmpty ? ': $svcError' : ''}';
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
    // Give the server a moment to bind
    await Future.delayed(const Duration(milliseconds: 500));
  }

  // ==================== Start dufs process (iOS) ====================
  Future<void> _startDufsProcess(ServerConfig config, int port) async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final binPath = p.join(exeDir, 'dufs');
    if (!await File(binPath).exists()) {
      throw Exception('dufs 服务组件缺失，请重新安装应用。路径: $binPath');
    }
    final args = _buildArgs(config, port);
    final workDir = config.shareSingleFile
        ? p.dirname(config.path)
        : config.path;
    _log('dufs: $binPath ${_redactedArgs(args).join(' ')}');
    _process = await Process.start(binPath, args, workingDirectory: workDir);
    _process!.stdout.listen((d) {
      final line = String.fromCharCodes(d).trim();
      _log('out: $line');
      _trackActivity(line);
    });
    _process!.stderr.listen((d) {
      final line = String.fromCharCodes(d).trim();
      _log('err: $line');
      _trackActivity(line);
    });
    await Future.delayed(const Duration(milliseconds: 300));
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
    if (_isFileTransfer(entry)) {
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

  bool _isFileTransfer(TransferLog entry) {
    final path = entry.path;
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
      } finally {
        await raf.close();
      }
    } catch (_) {}
  }

  Future<void> stopServer() async {
    if (!_isRunning) return;
    if (_useFfi && _dufsFfi.isLoaded) {
      // FFI mode: stop the in-process server
      _dufsFfi.stop();
      // Wait for the server to release the port (accept() may be blocking)
      for (int i = 0; i < 20; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        if (!_dufsFfi.isRunning()) break;
      }
      // Extra delay for OS to fully release the port (TIME_WAIT on Windows)
      await Future.delayed(const Duration(milliseconds: 800));
    } else if (_process != null) {
      // Process mode (iOS): kill child process
      _process!.kill();
      try {
        await _process!.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {}
      _process = null;
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
