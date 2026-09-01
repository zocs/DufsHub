# FileInfra Roadmap

## Current Status (2026-09-01)

### v0.5.x Released
- [x] **v0.5.1** (2026-08-22): full code review batch, Android quick-settings tile, notification enhancements
- [x] **v0.5.2** (2026-08-23): dufs core v0.46.0-fix3, large-folder zip truncation fix
- [x] **v0.5.3** (2026-08-30): dufs core v0.46.0-fix4 (old WebView support), Android open-file rewrite, startup pre-check for unreadable dirs, 403 log retention, universal/per-ABI 4 APK split, release notes dual-track
- [x] **v0.5.4** (2026-08-30): multiple network addresses with per-address default + QR popup, custom theme color picker (hand-rolled HSV)
- [x] **v0.5.5** (2026-08-30): notification shows full access address (follows default address switch, survives tile restarts), SV color panel blank/marker fix
- [x] **v0.5.6** (2026-08-30): shared clipboard (port = dufs + 2000, default 7000), no-JS fallback page upload/mkdir/delete (dufs v0.46.0-fix5), browser-safe clipboard port
- [x] **v0.5.7** (2026-08-31): Tools page (clipboard + QR generator two-tab, multi-row, style/color options, SVG download), offline `/qr?text=...` route, notification clipboard buttons (toggleable), `/api/clipboard` endpoint, Ubuntu 18.04 compat builds (`*-compat-linux-x86_64.*`)

### Post-v0.5.7 fixes on main (unreleased)
- [x] **Ubuntu 18.04 compat blockers** (`c987d7d`): `ServerConfig.save()` no longer blocks first-run wizard when secure storage has no keyring (mirrors `load()`); FilePicker now try/catch + localized SnackBar when no XDG portal is available
- [x] **Android 10 EMUI scoped-storage startup** (`35d66e6` + `3baf6a2`): readability probe is NON-BLOCKING on Android (warning banner instead of refusing to start); warning only surfaces after the server actually starts

### Completed since last roadmap update
- [x] CI cache & checksums.txt generation
- [x] Per-ABI APK builds (--split-per-abi)
- [x] dufs web asset syntax gate (ES2017, Chromium 55+, preventing blank-page regression)
- [x] QS tile API compatibility guards (API 29/26 vs minSdk 24)
- [x] Multi-address default toggle + per-address QR popup
- [x] Custom theme color picker (HSV, no deps)
- [x] Dark mode auto-follow system
- [x] F-Droid preparation (recipe, pre-check, fastlane metadata, zh-CN)
- [x] CI run-name note mechanism (`-f note="..."` on manual triggers, shows purpose in Actions list)
- [x] Shared clipboard + notification clipboard buttons + `/api/clipboard`

### Up next (next release)
- [ ] v0.5.8: fold the two post-v0.5.7 fix batches into a release (code review findings + Linux/Android blockers); decide release date with user
- [ ] Old tablet blank-page real-device retest (Chromium < 80 WebView + `?noscript`)
- [ ] Android 10 EMUI startup retest on device (pick internal public dir like Documents; warning should show but service starts)
- [ ] Ubuntu 18.04 compat retest on device (wizard skip + picker SnackBar + service start)

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
| Android 10 scoped storage limits direct-path dir listing | Medium | Workaround: probe non-blocking + warning banner; user should pick internal public dir |
| AppImage dufs external access | Medium | Resolved via FFI + `/tmp` extraction; needs more distro testing |
| macOS unsigned, needs manual xattr | Low | Cannot auto-sign |
| `withValues(alpha:)` requires Flutter 3.27+ | Low | Current version OK |
| NSIS `OutFile` order fragile | Low | Commented, don't touch without CI smoke |
| Linux tray left-click no signal | Low | Design decision, documented in handoff #10 |
| fastlane zh-CN changelogs incomplete (20-32, 46, 47 missing) | Low | Historical debt; backfill per release cadence |
