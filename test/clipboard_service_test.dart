import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_infra/services/clipboard_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// ClipboardService 单测：同一端口上 HTTP 页面 + WebSocket 双向同步。
/// 注意：不要调用 TestWidgetsFlutterBinding.ensureInitialized() —— 它会
/// 拦截所有真实 HTTP 请求（返回 400），本测试需要真实 dart:io 网络。
void main() {

  test('同一端口同时服务 HTTP 页面与 WebSocket 双向同步', () async {
    final svc = ClipboardService();
    await svc.start(0); // basePort=0 → 绑定随机端口，避免冲突
    expect(svc.isRunning, isTrue);
    expect(svc.port, isNotNull);
    final port = svc.port!;

    // 1) HTTP：根路径返回剪贴板页面
    final hc = HttpClient();
    final hreq = await hc.getUrl(Uri.parse('http://127.0.0.1:$port/'));
    final hres = await hreq.close();
    expect(hres.statusCode, HttpStatus.ok);
    final hbody = await hres.transform(utf8.decoder).join();
    expect(hbody, contains('共享剪贴板'));
    expect(hbody, contains('WebSocket'));

    // 2) WS：客户端 A 连接
    final wsA = await WebSocket.connect('ws://127.0.0.1:$port/');
    final aMsgs = <String>[];
    final aGotB = Completer<void>();
    wsA.listen((d) {
      final s = d as String;
      aMsgs.add(s);
      if (s.contains('hello from B')) aGotB.complete();
    });

    // 3) WS：客户端 B 连接
    final wsB = await WebSocket.connect('ws://127.0.0.1:$port/');
    final bMsgs = <String>[];
    final bGotA = Completer<void>();
    wsB.listen((d) {
      final s = d as String;
      bMsgs.add(s);
      if (s.contains('hello from A')) bGotA.complete();
    });

    // 4) A 发送剪贴板 → B 应收到（广播，排除 A 自身）
    wsA.add(jsonEncode({'type': 'set', 'text': 'hello from A'}));
    await bGotA.future.timeout(const Duration(seconds: 2));
    expect(bMsgs.any((m) => m.contains('hello from A')), isTrue);

    // 5) B 发送剪贴板 → A 应收到
    wsB.add(jsonEncode({'type': 'set', 'text': 'hello from B'}));
    await aGotB.future.timeout(const Duration(seconds: 2));
    expect(aMsgs.any((m) => m.contains('hello from B')), isTrue);

    // 6) 服务端槽位已更新为最新（B 的内容）
    final hreq2 = await hc.getUrl(Uri.parse('http://127.0.0.1:$port/'));
    final hres2 = await hreq2.close();
    final hbody2 = await hres2.transform(utf8.decoder).join();
    expect(hbody2, contains('共享剪贴板')); // 页面仍可用

    await wsA.close();
    await wsB.close();
    await svc.stop();
    expect(svc.isRunning, isFalse);
  });

  test('端口被占用时 start 不抛异常，isRunning=false', () async {
    // 占住一个端口
    final blocker = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final usedPort = blocker.port;

    final svc = ClipboardService();
    // basePort = usedPort - 5000 → 剪贴板端口恰好 = usedPort，被占用
    final basePort = usedPort - 5000;
    await svc.start(basePort);
    expect(svc.isRunning, isFalse);

    await blocker.close();
  });
}
