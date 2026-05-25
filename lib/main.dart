import 'dart:io';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'app.dart';
import 'models/server_config.dart';
import 'services/dufs_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Pull the version from the platform package metadata so it always tracks
  // pubspec.yaml without manual sync. (See lib/app.dart::appVersion.)
  try {
    final pkgInfo = await PackageInfo.fromPlatform();
    appVersion = pkgInfo.version;
  } catch (_) {
    // Fallback already covered by `appVersion = '0.0.0'` initializer.
  }

  // Desktop: frameless window + system tray
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(420, 740),
      minimumSize: Size(360, 600),
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setPreventClose(true);
      await windowManager.show();
      await windowManager.focus();
    });
  }

  final config = await ServerConfig.load();

  runApp(
    ChangeNotifierProvider(
      create: (_) => DufsService(),
      child: DufsHubApp(config: config),
    ),
  );
}

class DufsHubApp extends StatefulWidget {
  final ServerConfig config;
  const DufsHubApp({super.key, required this.config});

  @override
  State<DufsHubApp> createState() => _DufsHubAppState();
}

class _DufsHubAppState extends State<DufsHubApp> with TrayListener, WindowListener {
  late ThemeMode _themeMode;
  late String _colorScheme;
  late String _language;
  late bool _setupDone;
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _themeMode = _themeModeFromString(widget.config.themeMode);
    _colorScheme = widget.config.colorScheme;
    _language = widget.config.language;
    _setupDone = widget.config.setupDone;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.addListener(this);
    }
  }

  bool _trayInitialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_trayInitialized &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      _trayInitialized = true;
      _initTray();
    }
  }

  Future<void> _initTray() async {
    try {
      // Load asset bytes synchronously from context, before any other awaits
      final assetBundle = DefaultAssetBundle.of(context);
      final icoBytes = await assetBundle.load('assets/icon/tray_icon.ico');
      final pngBytes = await assetBundle.load('assets/icon/app_icon.png');
      if (!mounted) return;
      final dir = await Directory.systemTemp.createTemp('dufshub_tray');
      if (Platform.isWindows) {
        final iconFile = File('${dir.path}/tray_icon.ico');
        await iconFile.writeAsBytes(icoBytes.buffer.asUint8List());
        await trayManager.setIcon(iconFile.path);
      } else {
        final iconFile = File('${dir.path}/tray_icon.png');
        await iconFile.writeAsBytes(pngBytes.buffer.asUint8List());
        await trayManager.setIcon(iconFile.path);
      }
      await trayManager.setToolTip('DufsHub');

      // Small delay before setting context menu (Windows needs icon to be registered first)
      await Future.delayed(const Duration(milliseconds: 200));

      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: 'Show'),
            MenuItem(key: 'quit', label: 'Quit'),
          ],
        ),
      );
      trayManager.addListener(this);
      debugPrint('Tray initialized successfully');
    } catch (e) {
      debugPrint('Tray init failed: $e');
    }
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowClose() async {
    debugPrint('onWindowClose called, action=${widget.config.closeAction}');
    final action = widget.config.closeAction;
    switch (action) {
      case 'exit':
        windowManager.destroy();
        break;
      case 'tray':
        windowManager.hide();
        break;
      default: // 'ask' — handled by HomePage's close button callback
        break;
    }
  }

  @override
  void onTrayIconMouseDown() async {
    // Single click: show and focus window
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() async {
    debugPrint('Tray right-click detected, popping up context menu');
    try {
      await trayManager.popUpContextMenu();
      debugPrint('popUpContextMenu completed');
    } catch (e) {
      debugPrint('popUpContextMenu error: $e');
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    debugPrint('Tray menu clicked: ${menuItem.key}');
    switch (menuItem.key) {
      case 'show':
        await windowManager.show();
        await windowManager.focus();
        break;
      case 'quit':
        await trayManager.destroy();
        await windowManager.destroy();
        break;
    }
  }

  ThemeMode _themeModeFromString(String s) {
    switch (s) {
      case 'dark':
        return ThemeMode.dark;
      case 'light':
        return ThemeMode.light;
      default:
        return ThemeMode.system;
    }
  }

  void _onThemeChanged(ThemeMode mode) {
    setState(() {
      _themeMode = mode;
      widget.config.themeMode = mode.name;
    });
    widget.config.save();
  }

  void _onColorChanged(String scheme) {
    setState(() {
      _colorScheme = scheme;
      widget.config.colorScheme = scheme;
    });
    widget.config.save();
  }

  void _onLanguageChanged(String code) {
    setState(() {
      _language = code;
      widget.config.language = code;
    });
    widget.config.save();
  }

  void _onSetupDone() {
    setState(() {
      _setupDone = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return App(
      config: widget.config,
      themeMode: _themeMode,
      colorScheme: _colorScheme,
      language: _language,
      setupDone: _setupDone,
      onThemeModeChanged: _onThemeChanged,
      onColorChanged: _onColorChanged,
      onLanguageChanged: _onLanguageChanged,
      onSetupDone: _onSetupDone,
      onCloseRequested: () => onWindowClose(),
      navigatorKey: _navigatorKey,
    );
  }
}
