# FileInfra Roadmap

## Current Status (2026-04-27)

### Recently completed
- [x] dufs FFI desktop embedding
- [x] Android foreground service lifecycle
- [x] Hidden system files + `index.html` rendering
- [x] Android API < 30 dufs startup crash fix
- [x] Explicit single-file picker entry
- [x] Incremental transfer log reading

### Next up
- [ ] Flutter/CI cache to reduce release build time
- [ ] Generate `checksums.txt` for release assets
- [ ] Unify orphan cleanup paths (`_killOrphanDufs` / `killOrphanOnPort`)
- [ ] Clean tray temporary icon files
- [ ] Tighten `_trackActivity` request matching
- [ ] Stop Android foreground service reliably on all app exit paths

---

## v0.4.0 — 功能扩展（未来）

### 高优先级
- [ ] HTTPS 支持（自签证书或 Let's Encrypt）
- [ ] 上传进度条（大文件上传体验）
- [ ] 文件预览（图片/文本/视频）
- [ ] 批量操作（批量下载为 zip、批量删除）

### 中优先级
- [ ] 分享链接有效期（自动过期）
- [ ] 访问日志（谁访问了什么文件）
- [ ] 文件夹密码（per-directory auth）
- [ ] 暗色模式自动跟随系统（Android 10+）

### 低优先级
- [ ] WebDAV 支持
- [ ] 多语言扩展（日语、韩语）
- [ ] 自定义主题（用户自选颜色）
- [ ] 分享统计面板（总流量、连接数）

---

## v0.5.0 — 平台增强（远期）

- [ ] Android 桌面小部件（快速启动/停止）
- [ ] Android 快捷方式（直接分享指定目录）
- [ ] Windows 右键菜单集成（"用 FileInfra 分享此文件夹"）
- [ ] macOS DMG 安装包
- [ ] Android AAB 格式（Play Store 准备）
- [ ] iPad 适配

---

## 已知问题

| 问题 | 严重性 | 状态 |
|------|--------|------|
| AppImage dufs 外部无法访问 | 中 | 已通过 FFI + `/tmp` 提取缓解，仍需更多发行版验证 |
| macOS 未签名，需手动 xattr | 低 | 无法自动签名 |
| `withValues(alpha:)` 需 Flutter 3.27+ | 低 | 当前版本无问题 |
| `_killOrphanDufs` 与 `killOrphanOnPort` 代码重复 | 低 | 功能正常 |
