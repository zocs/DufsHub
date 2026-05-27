import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../constants.dart';
import '../l10n/app_localizations.dart';
import '../models/server_config.dart';
import '../services/dufs_service.dart';
import 'settings_page.dart';
import 'log_page.dart';

class HomePage extends StatefulWidget {
  final ServerConfig config;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final ValueChanged<String> onColorChanged;
  final ValueChanged<String> onLanguageChanged;
  final VoidCallback? onCloseRequested;

  const HomePage({
    super.key,
    required this.config,
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.onColorChanged,
    required this.onLanguageChanged,
    this.onCloseRequested,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WindowListener, WidgetsBindingObserver {
  late ServerConfig _config;
  bool _showAdvanced = false;
  bool _enableAuth = false;
  bool _obscurePassword = true;
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  late final TextEditingController _portController;
  int _navIndex = 0;
  bool _isDragOver = false;
  bool _isServerTransitioning = false;
  bool _isStoppingServer = false;
  static const _ch = MethodChannel(kMethodChannel);

  AppLocalizations get l10n => AppLocalizations(_config.language);

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
    _config = widget.config;
    _portController = TextEditingController(text: _config.port.toString());
    if (_config.auth != null && _config.auth!.contains(':')) {
      final parts = _config.auth!.split(':');
      _enableAuth = true;
      _usernameController.text = parts[0];
      _passwordController.text = parts.sublist(1).join(':');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    _usernameController.dispose();
    _passwordController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Remember if server was running when app goes to background
      _serverWasRunning = context.read<DufsService>().isRunning;
    } else if (state == AppLifecycleState.resumed) {
      _checkServerOnResume();
    }
  }

  /// App 恢复前台时检测并恢复服务状态
  /// 策略：查询 Native Service 状态，如果在跑则同步 UI；否则清理后重启
  Future<void> _checkServerOnResume() async {
    if (!Platform.isAndroid) return;
    final service = context.read<DufsService>();

    // 1. Check if Native Service is still running (the source of truth on Android)
    final info = await _ch.invokeMethod<Map>('getServiceInfo');
    if (info != null && info['isRunning'] == true) {
      debugPrint('Native service running on resume, restoring UI state');
      if (!service.isRunning) {
        await service.restoreFromService();
      }
      return;
    }

    // 2. Native Service not running — if we think we're running, clean up
    if (service.isRunning) {
      debugPrint(
        'Service reports not running but Dart thinks it is, cleaning up',
      );
      await service.stopServer();
      return;
    }

    // 3. Check for orphan dufs on the port
    final inUse = await service.isPortInUse(_config.port);
    if (inUse) {
      debugPrint('Port ${_config.port} in use on resume, killing orphan dufs');
      await service.killOrphanOnPort(_config.port);
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // 4. If server was running before activity was destroyed, restart it
    if (_serverWasRunning) {
      debugPrint('Restarting dufs after activity resume');
      _serverWasRunning = false;
      await _saveConfig();
      if (_enableAuth && _config.auth == null) return;
      await service.startServer(_config);
    }
  }

  /// 追踪服务是否在运行（用于 activity 恢复后自动重启）
  bool _serverWasRunning = false;

  Future<void> _saveConfig() async {
    _config.auth = _buildAuth();
    await _config.save();
  }

  String? _buildAuth() {
    if (!_enableAuth) return null;
    final user = _usernameController.text.trim();
    final pass = _passwordController.text.trim();
    if (user.isEmpty || pass.isEmpty) return null;
    return '$user:$pass';
  }

  Future<void> _handleClose() async {
    final service = context.read<DufsService>();
    final action = _config.closeAction;
    debugPrint('HomePage._handleClose: action=$action');
    if (action == 'exit') {
      await _exitApp(service);
      return;
    }
    if (action == 'tray') {
      windowManager.hide();
      return;
    }
    // action == 'ask': show dialog (context is inside MaterialApp, has MaterialLocalizations)
    final result = await _showCloseDialog();
    debugPrint('Close dialog result: $result');
    if (result == null) return;
    final actionResult = result['action'] as String;
    final dontAsk = result['dontAsk'] as bool;
    if (actionResult == 'tray') {
      windowManager.hide();
    } else {
      await _exitApp(service);
    }
    if (dontAsk) {
      _config.closeAction = actionResult;
      await _config.save();
    }
  }

  Future<Map<String, dynamic>?> _showCloseDialog() async {
    bool dontAsk = false;
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(l10n.t('home.closeTitle')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.minimize),
                title: Text(l10n.t('home.closeTray')),
                onTap: () =>
                    Navigator.pop(ctx, {'action': 'tray', 'dontAsk': dontAsk}),
              ),
              ListTile(
                leading: const Icon(Icons.exit_to_app),
                title: Text(l10n.t('home.closeExit')),
                onTap: () =>
                    Navigator.pop(ctx, {'action': 'exit', 'dontAsk': dontAsk}),
              ),
              const Divider(),
              CheckboxListTile(
                title: Text(l10n.t('home.closeDontAsk')),
                value: dontAsk,
                onChanged: (v) => setDialogState(() => dontAsk = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exitApp(DufsService service) async {
    if (service.isRunning) {
      await _runServerTransition(() async {
        await service.stopServer();
      }, stopping: true);
    }
    trayManager.destroy().catchError((_) {});
    if (!mounted) return;
    if (Theme.of(context).platform == TargetPlatform.android) {
      SystemNavigator.pop();
    } else {
      await windowManager.destroy();
    }
  }

  Future<void> _pickDirectory() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      setState(() {
        _config.path = result;
        _config.shareSingleFile = false;
      });
      await _saveConfig();
    }
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      lockParentWindow: true,
    );
    final pickedPath = result?.files.single.path;
    if (pickedPath != null && pickedPath.isNotEmpty) {
      setState(() {
        _config.path = pickedPath;
        _config.shareSingleFile = true;
      });
      await _saveConfig();
    }
  }

  // ==================== Title Bar ====================

  Widget _buildTitleBar() {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: 40,
        color: Colors.transparent,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(
              Icons.swap_horiz,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Text(
              'DufsHub',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const Spacer(),
            _TitleBarButton(
              icon: Icons.remove,
              onPressed: () => windowManager.minimize(),
            ),
            _TitleBarButton(
              icon: Icons.crop_square,
              onPressed: () async {
                if (await windowManager.isMaximized()) {
                  windowManager.unmaximize();
                } else {
                  windowManager.maximize();
                }
              },
            ),
            _TitleBarButton(
              icon: Icons.close,
              isClose: true,
              onPressed: () => _handleClose(),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== Preset Dirs (Android) ====================

  Widget _buildPresetDirs() {
    if (Theme.of(context).platform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }
    const presets = {
      'Download': '/storage/emulated/0/Download',
      'Documents': '/storage/emulated/0/Documents',
      'DCIM': '/storage/emulated/0/DCIM',
      'Movies': '/storage/emulated/0/Movies',
      'Music': '/storage/emulated/0/Music',
    };
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: presets.entries.map((e) {
        final sel = _config.path == e.value;
        return ActionChip(
          avatar: Icon(
            Icons.folder_outlined,
            size: 18,
            color: sel ? Theme.of(context).colorScheme.onPrimary : null,
          ),
          label: Text(
            e.key,
            style: TextStyle(
              color: sel ? Theme.of(context).colorScheme.onPrimary : null,
            ),
          ),
          backgroundColor: sel ? Theme.of(context).colorScheme.primary : null,
          onPressed: () async {
            setState(() {
              _config.path = e.value;
              _config.shareSingleFile = false;
            });
            await _saveConfig();
          },
        );
      }).toList(),
    );
  }

  // ==================== Dir Picker ====================

  Widget _buildDirPicker() {
    final isSingleFile = _config.shareSingleFile;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  isSingleFile ? Icons.insert_drive_file : Icons.folder_open,
                  size: 32,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isSingleFile
                            ? l10n.t('home.selectFile')
                            : l10n.t('home.selectDir'),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _config.path.isEmpty
                            ? (isSingleFile
                                  ? l10n.t('home.selectFile')
                                  : l10n.t('home.selectDir'))
                            : _config.path,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _config.path.isEmpty
                              ? Theme.of(context).colorScheme.outline
                              : null,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _pickDirectory,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(112, 44),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  icon: const Icon(Icons.folder_open),
                  label: Text(l10n.t('home.chooseFolder')),
                ),
                FilledButton.tonalIcon(
                  onPressed: _pickFile,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(112, 44),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  icon: const Icon(Icons.insert_drive_file_outlined),
                  label: Text(l10n.t('home.chooseFile')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ==================== Permission Presets ====================

  Widget _buildPermPresets(DufsService service) {
    final running = service.isRunning;
    return Row(
      children: [
        Expanded(
          child: FilterChip(
            avatar: const Icon(Icons.visibility, size: 18),
            label: Text(l10n.t('home.readonly')),
            selected: _config.readonly,
            showCheckmark: false,
            onSelected: running
                ? null
                : (_) async {
                    setState(() => _config.applyReadonly());
                    await _saveConfig();
                    _maybeRestart(service);
                  },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilterChip(
            avatar: const Icon(Icons.cloud_upload, size: 18),
            label: Text(l10n.t('home.upload')),
            selected:
                !_config.readonly &&
                _config.allowUpload &&
                !_config.allowDelete,
            showCheckmark: false,
            onSelected: running
                ? null
                : (_) async {
                    setState(() => _config.applyUpload());
                    await _saveConfig();
                    _maybeRestart(service);
                  },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilterChip(
            avatar: const Icon(Icons.lock_open, size: 18),
            label: Text(l10n.t('home.full')),
            selected:
                !_config.readonly && _config.allowUpload && _config.allowDelete,
            showCheckmark: false,
            onSelected: running
                ? null
                : (_) async {
                    setState(() => _config.applyFull());
                    await _saveConfig();
                    _maybeRestart(service);
                  },
          ),
        ),
      ],
    );
  }

  // ==================== Custom Permissions ====================

  Widget _buildCustomPerms(DufsService service) {
    final running = service.isRunning;
    final singleFile = _config.shareSingleFile;
    final items = [
      {
        'label': l10n.t('home.allowUpload'),
        'value': _config.allowUpload,
        'icon': Icons.cloud_upload,
        'disabled': singleFile,
        'onChanged': (v) async {
          setState(() {
            _config.allowUpload = v;
            if (v) {
              _config.readonly = false;
              _config.allowSearch = true;
            }
          });
          await _saveConfig();
          _maybeRestart(service);
        },
      },
      {
        'label': l10n.t('home.allowDelete'),
        'value': _config.allowDelete,
        'icon': Icons.delete_outline,
        'disabled': singleFile,
        'onChanged': (v) async {
          setState(() {
            _config.allowDelete = v;
            if (v) {
              _config.readonly = false;
              _config.allowSearch = true;
            }
          });
          await _saveConfig();
          _maybeRestart(service);
        },
      },
      {
        'label': l10n.t('home.allowSearch'),
        'value': _config.allowSearch,
        'icon': Icons.search,
        'disabled': singleFile,
        'onChanged': (v) async {
          setState(() => _config.allowSearch = v);
          await _saveConfig();
          _maybeRestart(service);
        },
      },
      {
        'label': l10n.t('home.allowArchive'),
        'value': _config.allowArchive,
        'icon': Icons.folder_zip,
        'disabled': false,
        'onChanged': (v) async {
          setState(() => _config.allowArchive = v);
          await _saveConfig();
          _maybeRestart(service);
        },
      },
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(
              context,
            ).colorScheme.outline.withValues(alpha: 0.15),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...items.map((item) {
              final disabled = item['disabled'] as bool;
              return SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                secondary: Icon(
                  item['icon'] as IconData,
                  size: 20,
                  color: (running || disabled)
                      ? Theme.of(context).colorScheme.outline
                      : null,
                ),
                title: Text(item['label'] as String),
                value: item['value'] as bool,
                onChanged: (running || disabled)
                    ? null
                    : (v) => (item['onChanged'] as Function(bool))(v),
              );
            }),
          ],
        ),
      ),
    );
  }

  /// Auto-restart if running with no active connections
  Future<void> _maybeRestart(DufsService service) async {
    if (!service.isRunning) return;
    final hasConnections =
        service.totalRequests > 0 && service.lastActivity != null;
    if (hasConnections) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.t('perm.restartTitle')),
          content: Text(l10n.t('perm.restartMsg')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.t('perm.restart')),
            ),
          ],
        ),
      );
      if (confirmed == true) await _restartServer(service);
    } else {
      await _restartServer(service);
    }
  }

  Future<void> _restartServer(DufsService service) async {
    await _runServerTransition(() async {
      await service.stopServer();
      await _saveConfig();
      if (_enableAuth && _config.auth == null) return;
      await service.startServer(_config);
    }, stopping: true);
  }

  Future<void> _runServerTransition(
    Future<void> Function() action, {
    required bool stopping,
  }) async {
    if (_isServerTransitioning) return;
    setState(() {
      _isServerTransitioning = true;
      _isStoppingServer = stopping;
    });
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() {
          _isServerTransitioning = false;
          _isStoppingServer = false;
        });
        final service = context.read<DufsService>();
        final notice = service.portInfo;
        if (notice != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(notice), duration: const Duration(seconds: 4)),
          );
          service.clearPortInfo();
        }
      }
    }
  }

  // ==================== Start/Stop Button ====================

  Widget _buildControlButton(DufsService service) {
    final running = service.isRunning;
    final busy = _isServerTransitioning;
    final label = busy
        ? (_isStoppingServer
              ? l10n.t('home.stoppingServer')
              : l10n.t('home.startingServer'))
        : (running ? l10n.t('home.stopServer') : l10n.t('home.startServer'));
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: FilledButton.icon(
        icon: busy
            ? SizedBox(
                width: 18,
                height: 18,
                child: _BouncingDots(
                  size: 18,
                  color: Theme.of(context).colorScheme.onSecondary,
                ),
              )
            : Icon(running ? Icons.stop : Icons.play_arrow),
        label: Text(label, style: const TextStyle(fontSize: 16)),
        style: FilledButton.styleFrom(
          backgroundColor: busy
              ? Theme.of(context).colorScheme.secondary
              : running
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        onPressed: busy
            ? null
            : () async {
                if (running) {
                  await _runServerTransition(
                    () => service.stopServer(),
                    stopping: true,
                  );
                } else {
                  if (_enableAuth && _config.auth == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.t('home.authRequired'))),
                    );
                    return;
                  }
                  await _runServerTransition(() async {
                    await _saveConfig();
                    await service.startServer(_config);
                  }, stopping: false);
                }
              },
      ),
    );
  }

  Widget _buildServerTransitionIndicator() {
    if (!_isServerTransitioning) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.secondaryContainer.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.t('home.transitionHint'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: const LinearProgressIndicator(minHeight: 5),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== Running Card (QR + Stats) ====================

  Widget _buildRunningCard(DufsService service) {
    if (!service.isRunning || service.serverUrl == null) {
      return const SizedBox.shrink();
    }
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            // Status dot
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  l10n.t('home.running'),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // QR Code
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
              ),
              child: QrImageView(
                data: service.serverUrl!,
                version: QrVersions.auto,
                size: 140,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            // URL (tap to copy)
            InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: service.serverUrl!));
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(l10n.t('home.copyUrl'))));
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      service.serverUrl!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                        decoration: TextDecoration.underline,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.copy,
                    size: 14,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // IP + Hint
            Text(
              '${l10n.t('home.localIp')}: ${service.localIp ?? 'N/A'}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              l10n.t('home.scanHint'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 8),
            // Stats
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _stat(
                    context,
                    Icons.http,
                    '${service.totalRequests}',
                    'Requests',
                  ),
                  Container(
                    width: 1,
                    height: 24,
                    color: Theme.of(
                      context,
                    ).colorScheme.outline.withValues(alpha: 0.2),
                  ),
                  _stat(
                    context,
                    Icons.access_time,
                    service.lastActivity ?? '--',
                    'Last',
                  ),
                  Container(
                    width: 1,
                    height: 24,
                    color: Theme.of(
                      context,
                    ).colorScheme.outline.withValues(alpha: 0.2),
                  ),
                  InkWell(
                    onTap: () => _showLogPage(context),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: _stat(
                        context,
                        Icons.history,
                        '${service.transferLogs.length}',
                        l10n.t('log.title'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== Multi-NIC Address List ====================
  Widget _buildAddressList(DufsService service) {
    if (!service.isRunning) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        child: ExpansionTile(
          title: Row(
            children: [
              Icon(
                Icons.lan,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.t('home.allAddresses'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ],
          ),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          initiallyExpanded: false,
          children: service.allAddresses.asMap().entries.map((entry) {
            final idx = entry.key;
            final ip = entry.value;
            final ifaceName = idx < service.allInterfaceNames.length
                ? service.allInterfaceNames[idx]
                : '';
            // Use the actually-bound port from the service, not the user's
            // configured port — they may differ when conflict auto-bumped.
            final urlPort = service.activePort != 0
                ? service.activePort
                : _config.port;
            final url = 'http://$ip:$urlPort';
            final isDefault = idx == 0;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: url));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('${l10n.t('home.copyUrl')}: $url')),
                  );
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: isDefault
                        ? Theme.of(
                            context,
                          ).colorScheme.primaryContainer.withValues(alpha: 0.3)
                        : Theme.of(context).colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isDefault ? Icons.star : Icons.link,
                        size: 16,
                        color: isDefault
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(width: 4),
                      if (ifaceName.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.outline.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            ifaceName,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          url,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                fontWeight: isDefault ? FontWeight.w600 : null,
                                decoration: TextDecoration.underline,
                              ),
                        ),
                      ),
                      Icon(
                        Icons.copy,
                        size: 14,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _stat(
    BuildContext context,
    IconData icon,
    String value,
    String label,
  ) {
    return Column(
      children: [
        Icon(
          icon,
          size: 18,
          color: Theme.of(
            context,
          ).colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(
              context,
            ).colorScheme.onPrimaryContainer.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  void _showLogPage(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(l10n.t('log.title'))),
          body: LogPage(config: _config),
        ),
      ),
    );
  }

  // ==================== Error Banner ====================

  Widget _buildError(DufsService service) {
    if (service.error == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline,
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              service.error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== Advanced Options ====================

  Widget _buildAdvancedOptions() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          // Port
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              decoration: InputDecoration(
                labelText: l10n.t('home.port'),
                prefixIcon: const Icon(Icons.numbers),
                helperText: l10n.t('home.portHint'),
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              controller: _portController,
              onChanged: (v) async {
                final port = int.tryParse(v);
                if (port != null && port >= 1 && port <= 65535) {
                  _config.port = port;
                  await _saveConfig();
                }
              },
            ),
          ),
          const SizedBox(height: 8),
          // Auth
          SwitchListTile(
            title: Text(l10n.t('home.enableAuth')),
            value: _enableAuth,
            onChanged: (v) {
              setState(() => _enableAuth = v);
              _saveConfig();
            },
          ),
          if (_enableAuth) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _usernameController,
                decoration: InputDecoration(
                  labelText: l10n.t('home.username'),
                  prefixIcon: const Icon(Icons.person),
                ),
                onChanged: (_) => _saveConfig(),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: l10n.t('home.password'),
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                onChanged: (_) => _saveConfig(),
              ),
            ),
          ],
          // CORS
          SwitchListTile(
            title: Text(l10n.t('home.cors')),
            subtitle: Text(
              l10n.t('home.corsHint'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            value: _config.cors,
            onChanged: (v) async {
              setState(() => _config.cors = v);
              await _saveConfig();
            },
          ),
          // Hide system files
          SwitchListTile(
            title: Text(l10n.t('home.hideSystemFiles')),
            subtitle: Text(
              l10n.t('home.hideSystemFilesHint'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            value: _config.hideSystemFiles,
            onChanged: (v) async {
              setState(() => _config.hideSystemFiles = v);
              await _saveConfig();
            },
          ),
          // Render try index
          SwitchListTile(
            title: Text(l10n.t('home.renderTryIndex')),
            subtitle: Text(
              l10n.t('home.renderTryIndexHint'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            value: _config.renderTryIndex,
            onChanged: (v) async {
              setState(() => _config.renderTryIndex = v);
              await _saveConfig();
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ==================== Main Content ====================

  // ==================== Drop Handler ====================
  Widget _buildDropWrapper({required Widget child}) {
    // Only enable on desktop platforms
    final isDesktop =
        Theme.of(context).platform == TargetPlatform.windows ||
        Theme.of(context).platform == TargetPlatform.linux ||
        Theme.of(context).platform == TargetPlatform.macOS;
    if (!isDesktop) return child;

    return DropTarget(
      onDragDone: (detail) async {
        if (detail.files.isNotEmpty) {
          final file = detail.files.first;
          final filePath = file.path;
          bool isFile = false;
          String dirPath;
          try {
            final entityType = await FileSystemEntity.type(filePath);
            if (entityType == FileSystemEntityType.directory) {
              dirPath = filePath;
            } else {
              dirPath = File(filePath).parent.path;
              isFile = true;
            }
          } catch (_) {
            dirPath = File(filePath).parent.path;
            isFile = true;
          }
          setState(() {
            _config.path = isFile ? filePath : dirPath;
            _config.shareSingleFile = isFile;
            _isDragOver = false;
          });
          final displayName = (isFile ? filePath : dirPath)
              .split(Platform.pathSeparator)
              .last;
          await _saveConfig();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${l10n.t(isFile ? 'home.dropFileSet' : 'home.dropSet')}: $displayName',
              ),
            ),
          );
        }
      },
      onDragEntered: (_) => setState(() => _isDragOver = true),
      onDragExited: (_) => setState(() => _isDragOver = false),
      child: child,
    );
  }

  Widget _buildHomeContent() {
    final service = context.watch<DufsService>();
    return _buildDropWrapper(
      child: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Title
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Column(
                    children: [
                      Text(
                        l10n.t('app.name'),
                        style: Theme.of(context).textTheme.headlineLarge
                            ?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                      Text(
                        l10n.t('app.slogan'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
                // Preset dirs (Android)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildPresetDirs(),
                ),
                const SizedBox(height: 4),
                // Dir picker
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildDirPicker(),
                ),
                const SizedBox(height: 8),
                // Permission presets
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    l10n.t('home.permissionPreset'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildPermPresets(service),
                ),
                // Custom permissions (collapsible)
                ExpansionTile(
                  title: Text(
                    l10n.t('home.customPerm'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  initiallyExpanded: false,
                  clipBehavior: Clip.hardEdge,
                  children: [_buildCustomPerms(service)],
                ),
                const SizedBox(height: 4),
                // Error
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildError(service),
                ),
                if (service.error != null) const SizedBox(height: 4),
                // Start/Stop
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildControlButton(service),
                ),
                _buildServerTransitionIndicator(),
                // Restart hint
                if (!service.isRunning && !_isServerTransitioning)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 2,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 14,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          l10n.t('home.restartHint'),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                // Running card (QR) - appears between button and advanced
                RepaintBoundary(child: _buildRunningCard(service)),
                // Multi-NIC address list
                _buildAddressList(service),
                const SizedBox(height: 4),
                // Advanced options (always at bottom)
                ExpansionTile(
                  title: Text(l10n.t('home.advanced')),
                  initiallyExpanded: _showAdvanced,
                  onExpansionChanged: (v) => setState(() => _showAdvanced = v),
                  clipBehavior: Clip.hardEdge,
                  children: [_buildAdvancedOptions()],
                ),
              ],
            ),
          ),
          // Drag & drop overlay
          if (_isDragOver)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.08),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.5),
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  margin: const EdgeInsets.all(8),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.file_download_outlined,
                          size: 48,
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.6),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.t('home.dropHint'),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ==================== Build ====================

  DateTime? _lastBackPress;

  @override
  Widget build(BuildContext context) {
    final pages = [
      _buildHomeContent(),
      SettingsPage(
        config: _config,
        onConfigChanged: _saveConfig,
        themeMode: widget.themeMode,
        onThemeModeChanged: widget.onThemeModeChanged,
        onColorChanged: widget.onColorChanged,
        onLanguageChanged: widget.onLanguageChanged,
      ),
    ];

    final scaffold = Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (Theme.of(context).platform == TargetPlatform.windows ||
                Theme.of(context).platform == TargetPlatform.linux ||
                Theme.of(context).platform == TargetPlatform.macOS)
              _buildTitleBar(),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: KeyedSubtree(
                  key: ValueKey(_navIndex),
                  child: pages[_navIndex],
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _navIndex,
        onDestinationSelected: (i) => setState(() => _navIndex = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: const Icon(Icons.home),
            label: l10n.t('nav.home'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: l10n.t('nav.settings'),
          ),
        ],
      ),
    );

    // Android: back button behavior
    if (Theme.of(context).platform == TargetPlatform.android) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final service = context.read<DufsService>();
          if (service.isRunning) {
            // Server running: ask if user wants to stop and exit
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(l10n.t('home.exitWhileRunning')),
                content: Text(l10n.t('home.exitWhileRunningMsg')),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(
                      MaterialLocalizations.of(ctx).cancelButtonLabel,
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(l10n.t('home.exitAndStop')),
                  ),
                ],
              ),
            );
            if (confirmed == true) {
              await _exitApp(service);
            }
          } else {
            // Server not running: double-press to exit
            final now = DateTime.now();
            if (_lastBackPress == null ||
                now.difference(_lastBackPress!) > const Duration(seconds: 2)) {
              _lastBackPress = now;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(l10n.t('home.exitConfirm')),
                  duration: const Duration(seconds: 2),
                ),
              );
            } else {
              SystemNavigator.pop();
            }
          }
        },
        child: scaffold,
      );
    }
    return scaffold;
  }
}

// Title bar button widget
class _TitleBarButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final bool isClose;
  const _TitleBarButton({
    required this.icon,
    required this.onPressed,
    this.isClose = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          hoverColor: isClose
              ? Colors.red.withValues(alpha: 0.8)
              : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
          child: Icon(
            icon,
            size: 16,
            color: isClose
                ? null
                : Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

// Lightweight loading indicator for in-button use. Three dots animate via
// Transform.translate + Opacity only — no Canvas redraw per frame, so it
// stays smooth on devices where the Material CircularProgressIndicator
// stutters (notably 120Hz Android in debug).
class _BouncingDots extends StatefulWidget {
  final double size;
  final Color color;
  const _BouncingDots({required this.size, required this.color});

  @override
  State<_BouncingDots> createState() => _BouncingDotsState();
}

class _BouncingDotsState extends State<_BouncingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dotSize = widget.size / 4.5;
    final amp = widget.size / 5;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(3, (i) {
              final phase = (_ctrl.value - i * 0.18) % 1.0;
              // Parabolic hop in the first half of each cycle, rest in second.
              final t = (phase * 2.0).clamp(0.0, 1.0);
              final y = -amp * 4 * t * (1 - t);
              final alpha = 0.55 + 0.45 * (1 - (t - 0.5).abs() * 2);
              return Transform.translate(
                offset: Offset(0, y),
                child: Container(
                  width: dotSize,
                  height: dotSize,
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: alpha),
                    shape: BoxShape.circle,
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
