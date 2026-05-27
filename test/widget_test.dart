import 'package:flutter_test/flutter_test.dart';
import 'package:dufs_hub/models/server_config.dart';

void main() {
  test('ServerConfig serialization', () {
    final config = ServerConfig.defaultConfig();
    final json = config.toJson();
    final restored = ServerConfig.fromJson(json);
    expect(restored.port, equals(5000));
    expect(restored.path, isEmpty);
  });
}
