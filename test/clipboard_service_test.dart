import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_infra/services/clipboard_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// ClipboardService 单测：HTTP 页面 + WebSocket 双向同步 + 端口跟随 + 占用降级。
void main() {
  test('同一端口同时服务 HTTP 页面与 WebSocket 双向同步', () async {
    // 启动一个 dummy 服务作为"dufs"，剪贴板应绑到 dufsPort + portOffset
    final dummy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final dufsPort = dummy.port;
    final cbPort = dufsPort + ClipboardService.portOffset;

    final svc = ClipboardService();
    await svc.start(dufsPort);
    expect(svc.isRunning, isTrue);
    expect(svc.port, cbPort);

    // 1) HTTP：根路径返回剪贴板页面
    final hc = HttpClient();
    final hreq = await hc.getUrl(Uri.parse('http://127.0.0.1:$cbPort/'));
    final hres = await hreq.close();
    expect(hres.statusCode, HttpStatus.ok);
    final hbody = await hres.transform(utf8.decoder).join();
    expect(hbody, contains('共享剪贴板'));
    expect(hbody, contains('WebSocket'));

    // 2) WS：客户端 A
    final wsA = await WebSocket.connect('ws://127.0.0.1:$cbPort/');
    final aGotB = Completer<void>();
    final aMsgs = <String>[];
    wsA.listen((d) {
      final s = d as String;
      aMsgs.add(s);
      if (s.contains('hello from B')) aGotB.complete();
    });

    // 3) WS：客户端 B
    final wsB = await WebSocket.connect('ws://127.0.0.1:$cbPort/');
    final bGotA = Completer<void>();
    final bMsgs = <String>[];
    wsB.listen((d) {
      final s = d as String;
      bMsgs.add(s);
      if (s.contains('hello from A')) bGotA.complete();
    });

    // 4) A 发送 → B 应收到
    wsA.add(jsonEncode({'type': 'set', 'text': 'hello from A'}));
    await bGotA.future.timeout(const Duration(seconds: 2));
    expect(bMsgs.any((m) => m.contains('hello from A')), isTrue);

    // 5) B 发送 → A 应收到
    wsB.add(jsonEncode({'type': 'set', 'text': 'hello from B'}));
    await aGotB.future.timeout(const Duration(seconds: 2));
    expect(aMsgs.any((m) => m.contains('hello from B')), isTrue);

    // 6) HTTP 页面仍可用
    final hreq2 = await hc.getUrl(Uri.parse('http://127.0.0.1:$cbPort/'));
    final hres2 = await hreq2.close();
    final hbody2 = await hres2.transform(utf8.decoder).join();
    expect(hbody2, contains('共享剪贴板'));

    await wsA.close();
    await wsB.close();
    await svc.stop();
    await dummy.close(force: true);
    expect(svc.isRunning, isFalse);
  });

  test('剪贴板端口被占用时自动+1 最多 9 步', () async {
    final dummy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final dufsPort = dummy.port;

    // 占用 dufsPort + portOffset（剪贴板首选端口）
    final blocker = await HttpServer.bind(InternetAddress.loopbackIPv4, dufsPort + ClipboardService.portOffset);

    final svc = ClipboardService();
    await svc.start(dufsPort);
    // 首选端口被占，应退到 +1
    expect(svc.isRunning, isTrue);
    expect(svc.port, dufsPort + ClipboardService.portOffset + 1);

    await svc.stop();
    await blocker.close(force: true);
    await dummy.close(force: true);
  });

  test('浏览器不安全端口（6000=X11）自动跳过', () async {
    final dummy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final dufsPort = 4000; // 剪贴板首选 = 6000（X11，浏览器禁用）
    await dummy.close(force: true);

    final svc = ClipboardService();
    await svc.start(dufsPort);
    expect(svc.isRunning, isTrue);
    expect(svc.port, 6001); // 跳过 6000 → 6001

    await svc.stop();
  });

  test('端口范围全部被占时降级跳过', () async {
    final dummy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final dufsPort = dummy.port;

    // 占满 dufsPort+1000 ~ dufsPort+1009（= 全部 10 个候选端口）
    final blockers = <HttpServer>[];
    for (var i = 0; i <= ClipboardService.maxBump; i++) {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, dufsPort + ClipboardService.portOffset + i);
      blockers.add(s);
    }

    final svc = ClipboardService();
    await svc.start(dufsPort);
    expect(svc.isRunning, isFalse);
    expect(svc.port, isNull);

    for (final s in blockers) {
      await s.close(force: true);
    }
    await dummy.close(force: true);
  });
}