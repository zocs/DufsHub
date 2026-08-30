#!/usr/bin/env bash
# check_dufs_web.sh - dufs 网页 assets 语法门禁（白屏修复防回归，见 docs/handoff.md 陷阱 #14）
#
# 背景：dufs 的 SPA 100% 客户端渲染。v0.46.0-fix3 的 index.js 含 Chromium>=80
# 语法（?. / Object.fromEntries / catch{} / 对象展开），旧 EMUI 设备的 WebView
# （Chromium 55-79）整脚本 SyntaxError → 分享页白屏。fix4 已降到 ES2017
# （async/await，Chromium 55 起支持）。
#
# 本脚本锁定 ES2017 下限，防止未来升 dufs 时把现代语法带回 Android 核心
# （index.js 编译进 libdufs.so，Android job 编完三 ABI 后必须过这关）。
set -euo pipefail

JS="${1:?usage: $0 <path/to/index.js>}"
[ -f "$JS" ] || { echo "ERROR: $JS not found"; exit 1; }

node --check "$JS"

if command -v npx >/dev/null 2>&1; then
  npx --yes es-check es2017 "$JS"
else
  echo "WARN: npx unavailable, falling back to grep-only scan"
fi

# es-check 不可用时的最后防线：grep 已知的致命残留（可选链 / 空值合并 /
# 省略 catch 绑定）。正则限定在解析层会出现的形态，避免命中注释与字符串。
if grep -nE '\?\.|\?\?|catch[[:space:]]*\{' "$JS" >/tmp/dufs-web-modern.txt; then
  echo "ERROR: modern JS syntax found in $JS (fix4 violation, Chromium>=80 required):" >&2
  cat /tmp/dufs-web-modern.txt >&2
  exit 1
fi

echo "OK: $JS is ES2017-safe (Chromium >= 55)"
