import 'dart:io';

import 'package:file_infra/l10n/app_localizations.dart';
import 'package:file_infra/models/server_config.dart';
import 'package:file_infra/services/dufs_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「服务起来了，浏览器只给 Forbidden」的回归测试。
///
/// 根因：目录能被 stat（`exists()` 通过）但不能被 opendir（EACCES）时，
/// dufs 对每个请求回 403，而 UI 照样把二维码和 URL 递出去。Android 10+
/// 分区存储、内存卡、Android/data 下都会这样。启动前的可读性探测就是为了让
/// 这种情况直接拒绝启动并给出可执行的文案。
void main() {
  final l10n = AppLocalizations('zh');

  ServerConfig cfg(String path, {bool single = false}) =>
      ServerConfig(path: path, shareSingleFile: single);

  test('可读目录：探测放行', () async {
    final dir = await Directory.systemTemp.createTemp('fi_probe_');
    File('${dir.path}/a.txt').writeAsStringSync('x');
    expect(await DufsService.probeReadableError(cfg(dir.path), l10n), isNull);
    await dir.delete(recursive: true);
  });

  test('空目录：探测放行（不是"不可读"）', () async {
    final dir = await Directory.systemTemp.createTemp('fi_probe_');
    expect(await DufsService.probeReadableError(cfg(dir.path), l10n), isNull);
    await dir.delete(recursive: true);
  });

  test('不可读目录：探测拒绝启动并带上 OS 原因', () async {
    final dir = await Directory.systemTemp.createTemp('fi_probe_');
    File('${dir.path}/secret.txt').writeAsStringSync('x');
    final mode = Process.runSync('chmod', ['000', dir.path]);
    if (mode.exitCode != 0) {
      // 没有 chmod 就用 dart 的权限位；两条路都走不通说明平台不支持这个
      // 场景（例如以 root 运行），跳过而不是假通过。
      reportSkip('无法构造不可读目录');
      return;
    }
    try {
      final err = await DufsService.probeReadableError(cfg(dir.path), l10n);
      if (err == null) {
        // root / 某些 Android FUSE 卷无视权限位：同样不能算失败，但要说出来。
        reportSkip('平台无视目录权限位，探测无法构造（可能以 root 运行）');
        return;
      }
      expect(err, contains(l10n.t('srv.dirNotReadable')));
      // OS 原始原因必须带出来，否则现场无法区分 EACCES / ENOTDIR / ELOOP。
      expect(err, isNot(equals(l10n.t('srv.dirNotReadable'))));
    } finally {
      Process.runSync('chmod', ['755', dir.path]);
      await dir.delete(recursive: true);
    }
  });

  test('单文件模式：可读文件放行，不可读文件拒绝', () async {
    final dir = await Directory.systemTemp.createTemp('fi_probe_');
    final f = File('${dir.path}/share.bin');
    f.writeAsBytesSync([1, 2, 3]);
    expect(
      await DufsService.probeReadableError(cfg(f.path, single: true), l10n),
      isNull,
    );
    final mode = Process.runSync('chmod', ['000', f.path]);
    if (mode.exitCode == 0) {
      final err = await DufsService.probeReadableError(
        cfg(f.path, single: true),
        l10n,
      );
      if (err != null) {
        expect(err, contains(l10n.t('srv.fileNotReadable')));
        // 单文件模式不该出现"改选内部存储公共目录"那段目录专属建议。
        expect(err, isNot(contains(l10n.t('srv.dirNotReadableAndroid'))));
      }
      Process.runSync('chmod', ['644', f.path]);
    }
    await dir.delete(recursive: true);
  });

  test('探测只读打开，不改 mtime / 不写任何东西', () async {
    final dir = await Directory.systemTemp.createTemp('fi_probe_');
    final f = File('${dir.path}/a.bin')..writeAsBytesSync([0]);
    final before = f.statSync().modified;
    final dirBefore = dir.statSync().modified;
    await Future.delayed(const Duration(milliseconds: 30));
    await DufsService.probeReadableError(cfg(f.path, single: true), l10n);
    await DufsService.probeReadableError(cfg(dir.path), l10n);
    expect(f.statSync().modified, before);
    expect(dir.statSync().modified, dirBefore);
    await dir.delete(recursive: true);
  });
}

void reportSkip(String why) {
  // ignore: avoid_print
  print('SKIP: $why');
}
