# FileInfra Roadmap

## Current Status (2026-08-30)

### v0.5.x Released
- [x] **v0.5.1** (2026-08-22): full code review batch, Android quick-settings tile, notification enhancements
- [x] **v0.5.2** (2026-08-23): dufs core v0.46.0-fix3, large-folder zip truncation fix
- [x] **v0.5.3** (2026-08-30): dufs core v0.46.0-fix4 (old WebView support), Android open-file rewrite, startup pre-check for unreadable dirs, 403 log retention, universal/per-ABI 4 APK split, release notes dual-track

### Completed since last roadmap update
- [x] CI cache & checksums.txt generation
- [x] Per-ABI APK builds (--split-per-abi)
- [x] dufs web asset syntax gate (ES2017, Chromium 55+, preventing blank-page regression)
- [x] QS tile API compatibility guards (API 29/26 vs minSdk 24)
- [x] Multi-address default toggle + per-address QR popup
- [x] Custom theme color picker (HSV, no deps)
- [x] Dark mode auto-follow system
- [x] F-Droid preparation (recipe, pre-check, fastlane metadata, zh-CN)

### Up next (next release)
- [ ] Unify orphan cleanup paths (`_killOrphanDufs` / `killOrphanOnPort`)
- [ ] F-Droid submission (deferred)
- [ ] Old tablet blank-page real-device retest

### Medium-term
- [ ] HTTPS support (self-signed or Let's Encrypt)
- [ ] Upload progress bar (large file UX)
- [ ] Batch operations (multi-download as zip, multi-delete)
- [ ] Share link expiry (auto-invalidate)
- [ ] Access log (who accessed what)
- [ ] Per-directory auth (password per folder)
- [ ] File preview (image/text/video)

### Long-term / Low-priority
- [ ] WebDAV support
- [ ] Language expansion (Japanese, Korean, etc.)
- [ ] Share statistics panel (total traffic, connections)
- [ ] Android desktop widget (quick start/stop)
- [ ] Android shortcuts (share specific dir directly)
- [ ] Windows right-click menu ("Share with FileInfra")
- [ ] macOS DMG package
- [ ] Android AAB (Play Store)
- [ ] iPad adaptation

## Known Issues

| Issue | Severity | Status |
|-------|----------|--------|
| AppImage dufs external access | Medium | Resolved via FFI + `/tmp` extraction; needs more distro testing |
| macOS unsigned, needs manual xattr | Low | Cannot auto-sign |
| `withValues(alpha:)` requires Flutter 3.27+ | Low | Current version OK |
| NSIS `OutFile` order fragile | Low | Commented, don't touch without CI smoke |
| Linux tray left-click no signal | Low | Design decision, documented in handoff #10 |