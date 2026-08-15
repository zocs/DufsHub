import 'package:flutter_test/flutter_test.dart';
import 'package:file_infra/models/transfer_log.dart';

void main() {
  group('TransferLog.parse', () {
    test('parses a well-formed dufs log line with size', () {
      final log = TransferLog.parse(
        '2026-03-26T12:00:00+08:00 INFO - 192.168.1.100 "GET /file.zip" 200 1024',
      );
      expect(log, isNotNull);
      expect(log!.method, 'GET');
      expect(log.path, '/file.zip');
      expect(log.status, 200);
      expect(log.size, 1024);
      expect(log.ip, '192.168.1.100');
      expect(log.isDownload, isTrue);
      expect(log.isSuccess, isTrue);
    });

    test('treats a "-" size field as unknown (null)', () {
      final log = TransferLog.parse(
        '2026-03-26T12:00:00+08:00 INFO - 10.0.0.2 "POST /upload" 201 -',
      );
      expect(log, isNotNull);
      expect(log!.size, isNull);
      expect(log.method, 'POST');
      expect(log.isUpload, isTrue);
    });

    test('parses a line with no trailing size', () {
      final log = TransferLog.parse(
        '2026-03-26T12:00:00Z INFO - 127.0.0.1 "DELETE /old.txt" 204',
      );
      expect(log, isNotNull);
      expect(log!.status, 204);
      expect(log.size, isNull);
      expect(log.isDelete, isTrue);
    });

    test('uppercases the method', () {
      final log = TransferLog.parse(
        '2026-03-26T12:00:00Z INFO - 127.0.0.1 "get /a" 200',
      );
      expect(log?.method, 'GET');
    });

    test('preserves spaces in the request path', () {
      final log = TransferLog.parse(
        '2026-03-26T12:00:00Z INFO - 127.0.0.1 "GET /my file.txt" 200',
      );
      expect(log?.path, '/my file.txt');
    });

    test('non-2xx status is not success', () {
      final log = TransferLog.parse(
        '2026-03-26T12:00:00Z INFO - 127.0.0.1 "GET /missing" 404',
      );
      expect(log?.isSuccess, isFalse);
    });

    test('returns null for malformed / non-matching lines', () {
      expect(TransferLog.parse(''), isNull);
      expect(TransferLog.parse('not a log line'), isNull);
      expect(TransferLog.parse('starting server on port 5000'), isNull);
      // Bad timestamp -> DateTime.tryParse fails -> null
      expect(
        TransferLog.parse('notadate INFO - 1.2.3.4 "GET /a" 200'),
        isNull,
      );
    });
  });
}
