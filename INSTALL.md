# Installing Saywell on another Mac

*Saywell was called LocalFlow before 20 Oct 2026. Installing it replaces LocalFlow.app and keeps your dictionary, history and models.*

Saywell is a menu-bar dictation app. You hold **Fn** (or press **⌃⌥D**) and speak, and it
types clean text into whatever app you're using. Speech recognition and AI cleanup run on
the Mac itself.

## Requirements

| | Minimum | Recommended |
|---|---|---|
| **Chip** | Apple Silicon (M1 or newer). Intel Macs are not supported, because MLX and the build are arm64 only | M2 or newer |
| **macOS** | 14 Sonoma (dictation, rules cleanup, local Qwen3) | **26 Tahoe or newer**, which adds Apple's built-in model as a cleanup engine |
| **Memory** | 8 GB, using Apple's model or rules-only cleanup | **16 GB** for the local Qwen3 4B model, which adds about 2.5 GB while loaded |
| **Disk** | 110 MB for the app | +2.3 GB for Qwen3, +460 MB for the Parakeet recognizer, +22 MB for the Notes speaker model |
| **Apple Intelligence** | Optional | Turn it on (System Settings ▸ Apple Intelligence & Siri) to use Apple's model |
| **Network** | None to dictate | Model downloads from huggingface.co, only when you pick a model (pinned and SHA-256-verified). None if you use the package that includes the model |
| **Language** | English (en-US) | Menu ▸ Language: languages installed for offline dictation (System Settings ▸ Keyboard ▸ Dictation), or 25 European languages with Parakeet |
| **Call recording (Notes)** | macOS 14.2+ and Parakeet | Allow **System Audio Recording** when macOS asks, so the other people on the call are recorded too |

What runs where:

| Cleanup engine | Needs | Speed (M5, warm) |
|---|---|---|
| Rules only (always available) | Nothing | Instant |
| Apple Foundation Model | macOS 26+, an eligible Mac, Apple Intelligence on | ~0.5 s per sentence |
| Qwen3 4B (local, the default local engine) | 16 GB RAM recommended, model on disk | ~0.5 s per sentence |

If the selected engine isn't ready, Saywell falls back to Apple's model, and then to
rules-only cleanup.

## Install

1. Get `Saywell-1.0.dmg` from the person who shared it and double-click it.
2. **Drag Saywell onto Applications** in the window that opens, then eject the disk.
3. Open Saywell from Applications.
   - **First time only:** macOS may say *"Apple could not verify Saywell is free of malware"*.
     This appears for every app that isn't signed with a paid Apple Developer ID and notarized.
     Click **Done**, open **System Settings ▸ Privacy & Security**, scroll down to the message
     about Saywell and click **Open Anyway**, then confirm with your password.
   - Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Saywell.app`
   - For a Mac without internet, ask for the package that includes the model
     (`Saywell-1.0-with-parakeet.dmg`): it has an `Install.command` that also copies the model.
     Right-click it ▸ Open the first time.
4. Sprig asks your name. Then the **Set Up Saywell** window walks you through five steps. Each turns green when it's
   done:
   1. **Microphone & Speech Recognition:** click Allow.
   2. **Accessibility:** click Open Settings and turn Saywell on. If Saywell isn't in
      the list, add `/Applications/Saywell.app` with **+**. Saywell needs this to type
      into apps.
   3. **Input Monitoring:** turn Saywell on so that holding Fn works. Also set System
      Settings ▸ Keyboard ▸ "Press 🌐 key to" → **Do Nothing**.
   4. **Choose a model:** Apple (instant), or Qwen3 local (downloads 2.3 GB unless it was
      bundled).
   5. **Try it:** hold Fn and say *"Hello, this is my first dictation."*
5. If Fn doesn't work right away, quit Saywell from its menu-bar icon and open it again.
   Input Monitoring only applies after a relaunch.

Manual install, without the script:
```bash
ditto /Volumes/Saywell/Saywell.app /Applications/Saywell.app
xattr -dr com.apple.quarantine /Applications/Saywell.app
open /Applications/Saywell.app
```

## Use

| Action | How |
|---|---|
| Dictate (push-to-talk) | Hold **Fn** (or right ⌥ / ⌘ / ⌃: menu ▸ Hold Key to Talk), speak, release |
| Dictate (hands-free) | Tap the hold key **twice**, speak, press it once to finish; or **⌃⌥D** to start and stop |
| Cancel a dictation | **Esc** |
| Paste the last dictation again | **⌃⌘V** |
| Record meetings automatically | Menu ▸ Auto-Record Meetings ▸ **Ask Me in the Notch** (a "Zoom meeting started — Record Notes?" card) or **Always Record**. Works with Zoom, Teams and Webex; recording stops when the meeting ends |
| Record a call | Menu ▸ Record a Call…, or the record button on the bottom pill. Stop it the same way or in the notch. The transcript by speaker (cleaned up by the local model; "Show what was heard" shows the original), summary, key points, decisions, action items with owners and dates, and open questions appear in Settings ▸ Notes (Export… saves Markdown). Notes use Qwen3 when it's downloaded, else Apple's model |
| Claude Code approvals | Settings ▸ Agents ▸ Connect Claude Code… (shows exactly what it writes to `~/.claude/settings.json`). Then Claude Code's permission requests and questions appear in the notch: Allow, Deny, Always, or reply in the terminal |
| Pill position | Menu ▸ Pill Position: Notch, Bottom of Screen, Left Edge or Right Edge (for external displays) |
| Sprig | The character in the notch and menu bar. Menu ▸ Show Sprig turns it off |
| Saywell window | Open Saywell.app (or click its Dock icon, or menu ▸ Open Saywell…): history, stats, notes, and every setting under General. It asks your name the first time |
| Revert the last insert to the raw text | **⌃⌥Z**, or click **Raw** on the pill |
| Edit selected text by voice | Select text, hold Fn, and say "make this more formal", "turn this into bullet points" or "translate to Spanish" |
| Code dictation | In editors and terminals, say "dash dash help" → `--help`, "index dot js" → `index.js`, "camel case user name" → `userName` |
| Pick the model | Menu bar ▸ AI Cleanup ▸ Model |
| Pick the speech recognizer | Menu bar ▸ Speech Recognizer: Apple (default) or **Parakeet v3**, which is about half the errors in our tests (one 460 MB download) |
| Modes per app, website or spoken trigger | Settings ▸ Modes, e.g. a mode with trigger "email mode" and level Full: say "email mode, hi John…" |
| See your stats | Settings ▸ Insights: words, pace, time saved, streak, top apps, no-edit rate by week |
| Remove a downloaded model | AI Cleanup ▸ Remove Downloaded Model |
| Teach it your words | Settings ▸ Dictionary. It also learns automatically when you fix the same word twice |

## Updating

Builds published with `Scripts/release.sh` update themselves (menu ▸ Check for Updates…,
using Sparkle with signed updates). For other builds, run the new package's `Install.command`. Permissions carry over, as long as the new build
is signed with the same certificate (`LocalFlow Dev`).

## Uninstall

Run `Uninstall.command` from the package. It removes the app and resets permissions, and
asks before deleting your history and models.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Saywell can't be opened" / "unidentified developer" | Right-click the app ▸ Open, or run `xattr -dr com.apple.quarantine /Applications/Saywell.app` |
| Holding Fn does nothing | Grant Input Monitoring, set "Press 🌐 key to" to Do Nothing, and relaunch. Use ⌃⌥D in the meantime |
| Text lands on the clipboard instead of in the app | Grant Accessibility. If Saywell is already listed but this still happens, remove it with "–" and add it again |
| "Apple Intelligence is off" / "device not eligible" | Use Qwen3 (AI Cleanup ▸ Model), or turn on Apple Intelligence |
| Local model says "not downloaded" | Pick it in the menu and approve the download, or use the `-with-qwen3` package |
| Everything is slow or swapping on an 8 GB Mac | Switch to Apple's model, or lower AI Cleanup ▸ Unload Local Model When Idle |

Logs are in `~/Library/Logs/Saywell.log`.

## For the person sharing it (building the package)

```bash
Scripts/package.sh                               # dist/Saywell-1.0.dmg + .zip (~35 MB, models download on first use)
Scripts/package.sh --with-model qwen3            # + Qwen3 (~2.3 GB), offline cleanup
Scripts/package.sh --with-model parakeet         # + Parakeet recognizer (~460 MB)
Scripts/package.sh --with-model qwen3,parakeet   # both: fully offline install
```

Building needs a Mac with Xcode 26+ and the Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`).

The package is signed with the self-signed `LocalFlow Dev` certificate, so recipients have
to use right-click ▸ Open (the installer clears the quarantine). To ship without that
warning, you need an Apple Developer account:
```bash
SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=<notarytool profile> Scripts/package.sh
```

### Publishing updates (optional)

1. One time: run `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`.
   It stores a private key in your Keychain and prints the public key.
2. Each release:
   ```bash
   SPARKLE_PUBLIC_KEY=<public key> SPARKLE_FEED_URL=https://<host>/appcast.xml \
   DOWNLOAD_URL_PREFIX=https://<host>/ BUILD_NUMBER=<n> \
   SIGN_ID="Developer ID Application: …" NOTARY_PROFILE=<profile> Scripts/release.sh
   ```
3. Upload `dist/updates/` to the host. `BUILD_NUMBER` must increase with every release.

To bundle a model, use `Scripts/package.sh --with-model qwen3`. The script checks the model
against the pinned manifest (`--verify-model`) before copying it.

## Licences and credits

Every package includes `THIRD_PARTY_NOTICES.md` (also in the app: menu ▸ Acknowledgements…).
It credits NVIDIA's Parakeet (CC BY 4.0), Qwen3 (Apache 2.0) and every bundled library, and
reproduces their licence texts. Regenerate it after changing dependencies or models:
`python3 Scripts/notices.py`. Keep the file in anything you redistribute.
