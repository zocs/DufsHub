🤖 **Automated build & release by GitHub Actions** | **此版本由 GitHub Actions 自动化构建并发布**

> All native binaries (dufs) are compiled from source — F-Droid compatible.

| Platform | Files | Status |
|----------|-------|--------|
| Android arm64 | `.apk` | ✅ |
| Windows x64 | `.zip` (portable) + `.exe` (installer) | ✅ |
| Linux x64 | `.AppImage` + `.deb` + `.tar.gz` | ✅ |
| Linux ARM64 | `.AppImage` + `.deb` + `.tar.gz` | ✅ |
| macOS ARM64 | `.zip` (app bundle) | ⚠️ 仅编译测试，**未签名、未实机测试** |
| iOS arm64 | `.zip` (app bundle, no codesign) | ⚠️ 仅编译测试，**未签名、未实机测试** |

> 🍎 macOS 未签名：解压后执行 `xattr -cr DufsHub.app` 去除隔离属性。
