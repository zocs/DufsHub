import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 剪贴板旁路服务：同一端口同时提供 HTTP 页面 + WebSocket 实时同步。
///
/// 默认端口 = dufs 端口 + 1000（差值固定），dufs 因自动+1 变化时剪贴板也
/// 跟随+1；若自身端口被占用，独立再+1 最多 [maxBump] 步。
/// 零第三方依赖，纯 dart:io 实现。
class ClipboardService {
  /// 剪贴板端口与 dufs 端口之间的固定差值。
  static const int portOffset = 1000;

  /// 端口被占用时最多尝试 +1 的次数。
  static const int maxBump = 9;

  HttpServer? _server;
  final Set<WebSocket> _clients = {};
  String? _text;
  int _updatedAt = 0;
  bool _running = false;

  bool get isRunning => _running;

  /// 实际绑定的剪贴板端口。
  int? get port => _server?.port;

  /// 展示用 URL（host 由 UI 从主服务地址复用）。
  String? get url => _server != null ? 'http://<host>:${_server!.port}' : null;

  /// 启动服务，剪贴板端口 = [dufsPort] + 1000。
  /// 若端口被占用，自动+1 最多 [maxBump] 步；全部被占则 log warning 跳过。
  /// 失败时只 log warning，不抛异常（剪贴板是增量功能，不阻塞主服务）。
  Future<void> start(int dufsPort) async {
    int base = dufsPort + portOffset;
    if (base > 65535) base = 65535;
    final maxPort = _min(base + maxBump, 65535);

    for (var port = base; port <= maxPort; port++) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
        _running = true;
        debugPrint('ClipboardService: bound on port $port (dufs $dufsPort)');
        _server!.listen(_handleRequest, onError: (e) {
          debugPrint('ClipboardService: server error: $e');
        });
        return;
      } on SocketException catch (_) {
        // port busy, try next
      }
    }
    debugPrint('ClipboardService: all ports $base..$maxPort busy, skipping');
  }

  static int _min(int a, int b) => a < b ? a : b;

  /// 停止服务，关闭所有连接。
  Future<void> stop() async {
    _running = false;
    for (final c in _clients) {
      try {
        await c.close();
      } catch (_) {}
    }
    _clients.clear();
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    _text = null;
    _updatedAt = 0;
    debugPrint('ClipboardService: stopped');
  }

  /// 设置剪贴板内容并广播给所有其他客户端（排除发送者自身）。
  void setText(String text, {WebSocket? source}) {
    _text = text;
    _updatedAt = DateTime.now().millisecondsSinceEpoch;
    final msg = _buildClipboardMsg();
    for (final c in _clients) {
      if (c.readyState == WebSocket.open && c != source) {
        c.add(msg);
      }
    }
  }

  // ── 请求分发 ──

  void _handleRequest(HttpRequest req) {
    if (WebSocketTransformer.isUpgradeRequest(req)) {
      _upgradeToWs(req);
    } else {
      _serveHtml(req);
    }
  }

  // ── WebSocket ──

  Future<void> _upgradeToWs(HttpRequest req) async {
    WebSocket? ws;
    try {
      ws = await WebSocketTransformer.upgrade(req);
    } catch (e) {
      debugPrint('ClipboardService: WS upgrade failed: $e');
      return;
    }
    _clients.add(ws);
    debugPrint('ClipboardService: WS client connected (total=${_clients.length})');

    // 连接后立即推送当前内容
    if (_text != null) {
      ws.add(_buildClipboardMsg());
    }

    ws.listen(
      (data) {
        final msg = _parseClientMsg(data as String);
        if (msg != null) {
          setText(msg, source: ws);
        }
      },
      onDone: () {
        _clients.remove(ws);
        debugPrint('ClipboardService: WS client disconnected (remaining=${_clients.length})');
      },
      onError: (e) {
        _clients.remove(ws);
        debugPrint('ClipboardService: WS client error: $e');
      },
    );
  }

  // ── HTTP 页面 ──

  void _serveHtml(HttpRequest req) {
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType(
        'text', 'html', charset: 'utf-8',
      )
      ..write(_htmlPage())
      ..close();
  }

  // ── WS 消息协议 ──

  /// 服务端 → 客户端：JSON，字段固定。
  String _buildClipboardMsg() {
    return jsonEncode({
      'type': 'clipboard',
      'text': _text ?? '',
      'ts': _updatedAt,
    });
  }

  /// 解析客户端 → 服务端消息。
  /// 客户端发送 JSON：{"type":"set","text":"..."}
  static String? _parseClientMsg(String raw) {
    try {
      final map = jsonDecode(raw) as Map;
      if (map['type'] == 'set' && map['text'] is String) {
        return map['text'] as String;
      }
    } catch (_) {}
    return null;
  }

  // ── 内联 HTML 页面 ──

  String _htmlPage() {
    return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FileInfra 共享剪贴板</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,sans-serif;background:#f5f5f5;padding:20px;max-width:600px;margin:0 auto}
h1{font-size:20px;margin-bottom:8px;display:flex;align-items:center;gap:8px}
.status{font-size:13px;color:#666;margin-bottom:16px;padding:8px 12px;background:#fff;border-radius:8px;border:1px solid #ddd}
.status.connected{color:#2e7d32;background:#e8f5e9;border-color:#a5d6a7}
.status.disconnected{color:#c62828;background:#ffebee;border-color:#ef9a9a}
.tip{font-size:12px;color:#999;margin-bottom:12px}
textarea{width:100%;min-height:120px;padding:12px;font-size:15px;border:1px solid #ddd;border-radius:8px;resize:vertical;font-family:inherit}
textarea:focus{outline:none;border-color:#1976d2}
.actions{display:flex;gap:8px;margin-top:8px;flex-wrap:wrap}
.btn{padding:8px 20px;font-size:14px;border:none;border-radius:6px;cursor:pointer;font-weight:500}
.btn-primary{background:#1976d2;color:#fff}
.btn-primary:hover{background:#1565c0}
.btn-secondary{background:#e0e0e0;color:#333}
.btn-secondary:hover{background:#bdbdbd}
.clipboard-display{background:#fff;border:1px solid #ddd;border-radius:8px;padding:12px;margin-bottom:16px;min-height:60px;font-size:15px;line-height:1.5;word-break:break-all}
.clipboard-display:empty::before{content:"暂无内容";color:#bbb}
.clipboard-display .time{font-size:11px;color:#999;margin-top:8px;display:block}
</style>
</head>
<body>
<h1>📋 共享剪贴板</h1>
<div id="status" class="status disconnected">⏳ 连接中…</div>
<div class="tip">⚠️ 剪贴板内容对内网可见，请勿粘贴敏感信息</div>

<div id="display" class="clipboard-display"><span class="time" id="time"></span></div>

<textarea id="input" placeholder="粘贴文本到这里…"></textarea>
<div class="actions">
  <button class="btn btn-primary" onclick="send()">📤 发送到共享剪贴板</button>
  <button class="btn btn-secondary" onclick="copyFromDisplay()">📋 复制到本机</button>
</div>

<script>
var ws = null;
var statusEl = document.getElementById('status');
var displayEl = document.getElementById('display');
var timeEl = document.getElementById('time');
var inputEl = document.getElementById('input');
var reconnectTimer = null;

function connect() {
  var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(proto + '//' + location.host + '/');
  ws.onopen = function() {
    statusEl.textContent = '✅ 已连接';
    statusEl.className = 'status connected';
  };
  ws.onmessage = function(e) {
    try {
      var msg = JSON.parse(e.data);
      if (msg.type === 'clipboard') {
        displayEl.textContent = msg.text;
        if (msg.ts) {
          var d = new Date(msg.ts);
          timeEl.textContent = '同步于 ' + d.toLocaleString();
        }
        displayEl.appendChild(timeEl);
      }
    } catch(err) {}
  };
  ws.onclose = function() {
    statusEl.textContent = '❌ 已断开，正在重连…';
    statusEl.className = 'status disconnected';
    ws = null;
    reconnectTimer = setTimeout(connect, 3000);
  };
  ws.onerror = function() {};
}

function send() {
  var text = inputEl.value.trim();
  if (!text) return;
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({type: 'set', text: text}));
    inputEl.value = '';
  }
}

function copyFromDisplay() {
  var text = displayEl.textContent;
  if (!text) return;
  navigator.clipboard.writeText(text).catch(function() {});
}

connect();
</script>
</body>
</html>
''';
  }
}