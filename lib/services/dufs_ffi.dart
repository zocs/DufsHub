// dufs_ffi.dart — Dart FFI bindings for libdufs.so / dufs.dll / libdufs.dylib

import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

// C function signatures
typedef DufsStartNative =
    Int32 Function(Int32 argc, Pointer<Pointer<Utf8>> argv);
typedef DufsStopNative = Void Function();
typedef DufsIsRunningNative = Int32 Function();

// Dart function signatures
typedef DufsStart = int Function(int argc, Pointer<Pointer<Utf8>> argv);
typedef DufsStop = void Function();
typedef DufsIsRunning = int Function();

class DufsFfi {
  DynamicLibrary? _lib;
  DufsStart? _start;
  DufsStop? _stop;
  DufsIsRunning? _isRunning;

  /// Load the shared library from the given path.
  void load(String libPath) {
    _lib = DynamicLibrary.open(libPath);
    _start = _lib!.lookupFunction<DufsStartNative, DufsStart>('dufs_start');
    _stop = _lib!.lookupFunction<DufsStopNative, DufsStop>('dufs_stop');
    _isRunning = _lib!.lookupFunction<DufsIsRunningNative, DufsIsRunning>(
      'dufs_is_running',
    );
  }

  /// Start the dufs server with an argv array.
  /// Returns 0 on success, -1 on error.
  int start(List<String> args) {
    if (_start == null) throw StateError('DufsFfi not loaded');
    final argc = args.length;
    final argv = calloc<Pointer<Utf8>>(argc);
    final owned = <Pointer<Utf8>>[];
    try {
      for (var i = 0; i < argc; i++) {
        final ptr = args[i].toNativeUtf8();
        owned.add(ptr);
        argv[i] = ptr;
      }
      return _start!(argc, argv);
    } finally {
      for (final ptr in owned) {
        malloc.free(ptr);
      }
      calloc.free(argv);
    }
  }

  /// Stop the dufs server.
  void stop() {
    if (_stop == null) throw StateError('DufsFfi not loaded');
    _stop!();
  }

  /// Check if the server is running.
  bool isRunning() {
    if (_isRunning == null) return false;
    return _isRunning!() == 1;
  }

  bool get isLoaded => _lib != null;
}

/// Resolve the path to the dufs shared library for the current platform.
Future<String> resolveDufsLibPath() async {
  if (Platform.isLinux) {
    // In AppImage, extract to a unique temp path to avoid FUSE isolation and stale reuse
    final exeDir = Directory.fromUri(
      Uri.file(Platform.resolvedExecutable),
    ).parent.path;
    final libPath = '$exeDir/libdufs.so';
    if (exeDir.contains('.mount_')) {
      final sourceFile = File(libPath);
      final stat = await sourceFile.stat();
      final tmpLib = p.join(
        Directory.systemTemp.path,
        'dufshub-libdufs-${stat.modified.millisecondsSinceEpoch}-$pid.so',
      );
      final tmpFile = File(tmpLib);
      if (!await tmpFile.exists()) {
        await sourceFile.copy(tmpLib);
      }
      return tmpLib;
    }
    return libPath;
  } else if (Platform.isMacOS) {
    final exeDir = Directory.fromUri(
      Uri.file(Platform.resolvedExecutable),
    ).parent.path;
    return '$exeDir/libdufs.dylib';
  } else if (Platform.isWindows) {
    // Windows: extract from asset to app data dir
    final exeDir = Directory.fromUri(
      Uri.file(Platform.resolvedExecutable),
    ).parent.path;
    return '$exeDir/dufs.dll';
  }
  throw UnsupportedError(
    'Platform not supported for FFI: ${Platform.operatingSystem}',
  );
}
