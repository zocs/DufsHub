import 'package:file_infra/l10n/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 三语键集必须完全对齐。所有服务层/页面文案都走 `l10n.t(key)`，而 `t()`
/// 在缺键时把 key 原样返回——漏翻译不会让 analyze/test 报错，只会在用户界面
/// 上凭空冒出一句 `srv.dirNotReadable`。
void main() {
  final langs = AppLocalizations.supportedLanguages;

  test('supportedLanguages 与翻译表一致', () {
    for (final lang in langs) {
      expect(AppLocalizations.keysFor(lang), isNotEmpty,
          reason: '$lang 没有翻译表（键名拼错或表未注册）');
    }
  });

  test('三语键集完全相同', () {
    final reference = AppLocalizations.keysFor(langs.first);
    for (final lang in langs.skip(1)) {
      final keys = AppLocalizations.keysFor(lang);
      expect(
        reference.difference(keys),
        isEmpty,
        reason: '$lang 缺少 ${reference.difference(keys).length} 个键',
      );
      expect(
        keys.difference(reference),
        isEmpty,
        reason: '$lang 有 ${langs.first} 里没有的孤立键',
      );
    }
  });

  test('占位符 {xxx} 在三语间保持一致', () {
    final re = RegExp(r'\{(\w+)\}');
    for (final key in AppLocalizations.keysFor('zh')) {
      final expected = re
          .allMatches(AppLocalizations('zh').t(key))
          .map((m) => m.group(1)!)
          .toSet();
      for (final lang in langs) {
        final got = re
            .allMatches(AppLocalizations(lang).t(key))
            .map((m) => m.group(1)!)
            .toSet();
        expect(got, expected, reason: '$key 在 $lang 的占位符不匹配');
      }
    }
  });

  test('没有空翻译', () {
    for (final lang in langs) {
      for (final key in AppLocalizations.keysFor(lang)) {
        expect(AppLocalizations(lang).t(key).trim(), isNotEmpty,
            reason: '$lang/$key 是空串');
      }
    }
  });
}
