/// 传输日志条目
class TransferLog {
  final DateTime time;
  final String method; // GET, POST, DELETE, etc.
  final String path;
  final int status; // HTTP status code
  final int? size; // bytes transferred (null if unknown)
  final String? ip; // client IP (null if unknown)

  const TransferLog({
    required this.time,
    required this.method,
    required this.path,
    required this.status,
    this.size,
    this.ip,
  });

  /// 是否为上传操作
  bool get isUpload => method == 'POST' || method == 'PUT';

  /// 是否为下载操作
  bool get isDownload => method == 'GET';

  /// 是否为删除操作
  bool get isDelete => method == 'DELETE';

  /// 是否成功
  bool get isSuccess => status >= 200 && status < 300;

  /// 解析 dufs 日志行
  /// dufs 日志格式 (logger.rs + http_logger.rs):
  /// "2026-03-26T12:00:00+08:00 INFO - 192.168.1.100 \"GET /path\" 200"
  static final RegExp _lineRe = RegExp(
    r'^(\S+)\s+(\S+)\s+-\s+(\S+)\s+"(\S+)\s+(.+?)"\s+(\d{3})(?:\s+(\d+|-))?',
  );

  static TransferLog? parse(String line) {
    // Format: TIMESTAMP LEVEL - IP "METHOD PATH" STATUS [SIZE]
    final match = _lineRe.firstMatch(line);
    if (match == null) return null;

    final time = DateTime.tryParse(match.group(1)!);
    if (time == null) return null;

    final ip = match.group(3)!;
    final method = match.group(4)!.toUpperCase();
    final path = match.group(5)!;
    final status = int.tryParse(match.group(6)!);
    final size = int.tryParse(match.group(7) ?? '');
    if (status == null) return null;

    return TransferLog(
      time: time,
      method: method,
      path: path,
      status: status,
      size: size,
      ip: ip,
    );
  }
}
