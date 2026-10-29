# 01 · Build, signing, packaging, distribution

| ID | Scenario | Steps | Expected | Type | Status | Result |
|---|---|---|---|---|---|---|
| BLD-01 | Clean release build | `./Scripts/make_app.sh` | Prints `Built build/LocalFlow.app`; exit 0; `mlx-swift_Cmlx.bundle` inside `Contents/Resources` | AUTO | ✅ | |
| BLD-02 | Unit tests | `Scripts/test.sh` | `TEST SUCCEEDED`, 0 failures (66+ tests) | AUTO | ✅ | |
| BLD-03 | Stable signing identity | `codesign -dv build/LocalFlow.app` | Authority is `LocalFlow Dev` or a Developer ID, never ad-hoc | AUTO | ✅ | |
| BLD-04 | Permissions survive a rebuild | Grant all permissions, rebuild, relaunch | Launch log still shows `ax=true listen=true`; no re-grant needed | MANUAL | ✅ | |
| BLD-05 | Package DMG + zip | `Scripts/package.sh --no-build` | `dist/LocalFlow-<v>.dmg`, `.zip`, `.sha256` created; `shasum -a 256 -c` passes | MANUAL | ✅ | |
| BLD-06 | Install on a second Mac | Copy the DMG, run `Install.command` | App lands in /Applications; quarantine handled; app launches and shows onboarding | MANUAL | ✅ | |
| BLD-07 | Offline install with bundled model | `Scripts/package.sh --with-model qwen3`; install with the network off; pick Qwen3 | Model loads without any download | MANUAL | ✅ | |
| BLD-08 | Uninstall | Run `Uninstall.command` | App removed; data handled as INSTALL.md describes | MANUAL | ✅ | |
| BLD-09 | MLX Metal shaders present | Launch, run one dictation with Qwen3 | No `Failed to load the default metallib` in the log | MANUAL | ✅ | |
| BLD-10 | Developer ID + notarization | `SIGN_ID="Developer ID Application: …" NOTARY_PROFILE=… Scripts/package.sh`; `spctl -a -vv LocalFlow.app` | `accepted`, `source=Notarized Developer ID`; no Gatekeeper warning on a fresh Mac | MANUAL | ⏳ B13 | |
| BLD-11 | Hardened runtime + mic entitlement | `codesign -d --entitlements - LocalFlow.app` | Includes `com.apple.security.device.audio-input`; dictation works under the hardened runtime | MANUAL | ⏳ B13 | |
| BLD-12 | Sparkle auto-update | Publish a higher version to the appcast; menu ▸ Check for Updates… | Finds the update, verifies the EdDSA signature, installs, relaunches; settings kept | MANUAL | ⏳ B13 | |
| BLD-13 | Sparkle rejects a tampered update | Serve an update with a bad signature | Update refused; app unchanged | MANUAL | ⏳ B13 | |
| BLD-14 | Code probe: Sparkle linked | Runner probe | `Sparkle` dependency in Package.swift | AUTO | ⏳ B13 | |
