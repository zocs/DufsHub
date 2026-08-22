import 'dart:io';

import 'package:file_infra/pages/log_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory outside;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fi_resolve_root');
    outside = Directory.systemTemp.createTempSync('fi_resolve_out');
    File('${root.path}/a.txt').writeAsStringSync('a');
    File('${root.path}/pic 1.png').writeAsStringSync('p');
    File('${outside.path}/secret.txt').writeAsStringSync('s');
  });

  tearDown(() {
    root.deleteSync(recursive: true);
    outside.deleteSync(recursive: true);
  });

  group('LogPage.resolveTarget 正常解析', () {
    test('根下普通文件', () {
      final t = LogPage.resolveTarget('/a.txt', root.path);
      expect(t, isNotNull);
      expect(File(t!).readAsStringSync(), 'a');
    });

    test('去 query 后命中', () {
      final t = LogPage.resolveTarget('/a.txt?download=true', root.path);
      expect(t, isNotNull);
    });

    test('URL 解码命中（空格）', () {
      final t = LogPage.resolveTarget('/pic%201.png', root.path);
      expect(t, isNotNull);
    });

    test('相对形式（无前导斜杠）', () {
      final t = LogPage.resolveTarget('a.txt', root.path);
      expect(t, isNotNull);
    });

    test('不存在的文件返回 null', () {
      expect(LogPage.resolveTarget('/nope.txt', root.path), isNull);
    });

    test('空 root 返回 null', () {
      expect(LogPage.resolveTarget('/a.txt', ''), isNull);
    });

    test('单文件分享：root 是文件时直接返回 root', () {
      final single = '${root.path}/a.txt';
      expect(LogPage.resolveTarget('/anything', single), single);
    });
  });

  group('LogPage.resolveTarget 防逃逸', () {
    test('裸 ../ 逃逸被拒', () {
      expect(LogPage.resolveTarget('/../x', root.path), isNull);
      expect(
        LogPage.resolveTarget(
          '/../${p.basename(outside.path)}/secret.txt',
          Directory.systemTemp.path,
        ),
        isNull,
      );
    });

    test('多层嵌套 ../ 逃逸被拒', () {
      expect(LogPage.resolveTarget('/a/../../b/c.txt', root.path), isNull);
    });

    test('percent 编码的 ../ 被拒（解码发生在候选生成后）', () {
      expect(LogPage.resolveTarget('/%2e%2e/x', root.path), isNull);
      expect(LogPage.resolveTarget('/%2E%2E%2Fx', root.path), isNull);
    });

    test('反斜杠形式的 .. 被拒', () {
      expect(LogPage.resolveTarget(r'/..\x', root.path), isNull);
    });

    test('路径中段含 .. 文件名不误伤（..x 是合法名）', () {
      File('${root.path}/..tricky.txt').writeAsStringSync('ok');
      final t = LogPage.resolveTarget('/..tricky.txt', root.path);
      expect(t, isNotNull);
    });
  });
}
