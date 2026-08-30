import 'package:file_infra/models/transfer_log.dart';
import 'package:file_infra/services/dufs_service.dart';
import 'package:flutter_test/flutter_test.dart';

TransferLog _e(String method, String path, int status) => TransferLog(
      time: DateTime(2026, 8, 30),
      method: method,
      path: path,
      status: status,
    );

void main() {
  group('DufsService.showInLog', () {
    test('成功请求：根目录与静态资源不进记录', () {
      expect(DufsService.showInLog(_e('GET', '/', 200)), isFalse);
      expect(DufsService.showInLog(_e('GET', '/app.css', 200)), isFalse);
      expect(DufsService.showInLog(_e('GET', '/dufs-assets/x.js', 200)), isFalse);
      expect(DufsService.showInLog(_e('GET', '/sub/', 200)), isFalse);
      expect(DufsService.showInLog(_e('PROPFIND', '/a.txt', 207)), isFalse);
    });

    test('成功请求：真实文件传输进记录', () {
      expect(DufsService.showInLog(_e('GET', '/a.txt', 200)), isTrue);
      expect(DufsService.showInLog(_e('PUT', '/up.bin', 201)), isTrue);
      expect(DufsService.showInLog(_e('DELETE', '/a.txt', 204)), isTrue);
    });

    // 回归：用户报「浏览器只显示 Forbidden」时唯一证据是 `GET / 403`，
    // 旧过滤规则把 path=='/' 全丢了，UI 上什么都看不到。
    test('失败请求留痕，包括根目录 403', () {
      expect(DufsService.showInLog(_e('GET', '/', 403)), isTrue);
      expect(DufsService.showInLog(_e('GET', '/', 401)), isTrue);
      expect(DufsService.showInLog(_e('GET', '/a.txt', 404)), isTrue);
      expect(DufsService.showInLog(_e('PUT', '/a.txt', 403)), isTrue);
    });

    test('失败请求也过滤掉静态资源噪声', () {
      expect(
        DufsService.showInLog(_e('GET', '/favicon.ico', 404)),
        isFalse,
      );
      expect(
        DufsService.showInLog(_e('GET', '/dufs-assets/app.css', 404)),
        isFalse,
      );
    });
  });
}
