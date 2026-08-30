# Release Checklist — FileInfra

每次发版按此顺序检查，全部打勾后再 tag push。

## 1. 版本号同步

版本号: `X.Y.Z` (build: `+Z`)

- [ ] `pubspec.yaml` → `version: X.Y.Z+Z`
- [ ] `lib/app.dart`/`lib/main.dart` → `appVersion` 自动从 `PackageInfo.fromPlatform()` 读取，**无需手改**（main.dart 启动时赋值）`
- [ ] `installer/fileinfra.nsi` → `!define APP_VERSION "X.Y.Z"`
- [ ] `.fdroid.yml` → `versionName: X.Y.Z`, `versionCode: Z`
- [ ] `.fdroid.yml` → `CurrentVersion: X.Y.Z`, `CurrentVersionCode: Z`
- [ ] `.fdroid.yml` → `build` 步骤中 `--build-name=X.Y.Z --build-number=Z`
- [ ] `fastlane/metadata/android/en-US/changelogs/Z.txt` 存在且内容正确

## 2. CI / 构建

- [ ] 本地 `flutter build apk --debug` 通过
- [ ] CI workflow 无语法错误（push tag 前可先 `act` 或 dry-run）
- [ ] dufs 二进制/库文件已更新（如有 Rust 变更）

## 3. 文档

- [ ] `CHANGELOG.md` 已添加 X.Y.Z 版本条目
- [ ] `README.md` / `README_zh.md` 截图/功能描述是否需要更新
- [ ] `ROADMAP.md` 当前状态与实际 release 节奏一致

## 4. Git

- [ ] 所有改动已 commit
- [ ] 旧 tag vX.Y.Z 已删除（如果是重建）: `git push origin --delete vX.Y.Z`
- [ ] squash 成一个干净 commit
- [ ] tag push: `git tag vX.Y.Z && git push origin main --tags`

## 5. Release

- [ ] CI 构建全部通过
- [ ] GitHub Release 已创建（自动由 CI 触发）
- [ ] Release assets 完整（APK、Windows zip/nsis、Linux AppImage/deb、macOS zip）
- [ ] F-Droid `.fdroid.yml` commit hash 更新到 tag 对应的 commit

## 6. 发布后

- [ ] 更新 `.fdroid.yml` 的 `commit` 字段为新 tag 的 commit hash
- [ ] 提交 F-Droid MR（如需更新 fdroiddata fork）
- [ ] 测试安装：Android 升级安装、Windows 覆盖安装
