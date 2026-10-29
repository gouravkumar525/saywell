# LocalFlow test run 2026-10-20 20:51

- Engines: apple, qwen3
- Suites: probes
- Commit: n/a
- Binary: `/sessions/rcw-01wqeftgddfhtqtvba1bgg8a/mnt/localWishpFlow/build/LocalFlow.app/Contents/MacOS/LocalFlow`
- Totals: XFAIL 10

## Automated results

| Outcome | ID | Suite | Detail |
|---|---|---|---|
| XFAIL | ASR-17 | probes | B1/B2: FluidAudio dependency + word-agreement engine |
| XFAIL | BLD-14 | probes | B13: Sparkle dependency |
| XFAIL | ENG-01 | probes | B16: 66 XCTest functions (need ≥150) |
| XFAIL | ENG-02 | probes | B16: docs/accuracy.md |
| XFAIL | ENG-03 | probes | B16: eval/RESULTS.md |
| XFAIL | ENG-04 | probes | B15: Insights view |
| XFAIL | ENG-05 | probes | B12: media pause / recording cap |
| XFAIL | INS-16 | probes | B8: clipboard restore delays [0.4, 0.25, 0.4] |
| XFAIL | MDL-09 | probes | B3: SHA-256 + .localflow-installed marker |
| XFAIL | MOD-06 | probes | B9: website/trigger mode type in LocalFlowCore |

## Manual / E2E checklist

Mark each one ✅ pass, ❌ fail (with a note), or ➖ n/a. ⏳ rows are expected to fail until their feature is built.

| File | ID | Scenario | Type | Status | Result | Notes |
|---|---|---|---|---|---|---|
| 01-build-install.md | BLD-04 | Permissions survive a rebuild | MANUAL | ✅ | | |
| 01-build-install.md | BLD-05 | Package DMG + zip | MANUAL | ✅ | | |
| 01-build-install.md | BLD-06 | Install on a second Mac | MANUAL | ✅ | | |
| 01-build-install.md | BLD-07 | Offline install with bundled model | MANUAL | ✅ | | |
| 01-build-install.md | BLD-08 | Uninstall | MANUAL | ✅ | | |
| 01-build-install.md | BLD-09 | MLX Metal shaders present | MANUAL | ✅ | | |
| 01-build-install.md | BLD-10 | Developer ID + notarization | MANUAL | ⏳ B13 | | |
| 01-build-install.md | BLD-11 | Hardened runtime + mic entitlement | MANUAL | ⏳ B13 | | |
| 01-build-install.md | BLD-12 | Sparkle auto-update | MANUAL | ⏳ B13 | | |
| 01-build-install.md | BLD-13 | Sparkle rejects a tampered update | MANUAL | ⏳ B13 | | |
| 02-permissions-onboarding.md | PRM-01 | Mic + speech prompts on first launch | MANUAL | ✅ | | |
| 02-permissions-onboarding.md | PRM-02 | No Accessibility permission | MANUAL | ✅ | | |
| 02-permissions-onboarding.md | PRM-03 | No Input Monitoring permission | MANUAL | ✅ | | |
| 02-permissions-onboarding.md | PRM-04 | Permission granted while the app runs | MANUAL | ✅ | | |
| 02-permissions-onboarding.md | PRM-06 | Contacts permission only when importing | MANUAL | ✅ | | |
| 02-permissions-onboarding.md | ONB-01 | Onboarding on first launch | MANUAL | ✅ | | |
| 02-permissions-onboarding.md | ONB-02 | Steps turn green live | MANUAL | ✅ | | |
| 02-permissions-onboarding.md | ONB-03 | Model choice step | MANUAL | ✅ | | |
| 02-permissions-onboarding.md | ONB-04 | "Try it" box | MANUAL | ✅ | | |
| 02-permissions-onboarding.md | ONB-05 | Two-minute target | MANUAL | ✅ | | |
| 02-permissions-onboarding.md | ONB-06 | Reopen onboarding | MANUAL | ✅ | | |
| 02-permissions-onboarding.md | ONB-07 | Fn key system setting hint | MANUAL | ✅ | | |
| 03-hotkeys-session.md | HK-01 | ⌃⌥D toggle | E2E | ✅ | | |
| 03-hotkeys-session.md | HK-02 | Hold Fn push-to-talk | MANUAL | ✅ | | |
| 03-hotkeys-session.md | HK-03 | Fn tap cancels | MANUAL | ✅ | | |
| 03-hotkeys-session.md | HK-04 | Fn shortcuts still work | MANUAL | ✅ | | |
| 03-hotkeys-session.md | HK-05 | Disable Fn | MANUAL | ✅ | | |
| 03-hotkeys-session.md | HK-06 | Click the pill | MANUAL | ✅ | | |
| 03-hotkeys-session.md | HK-07 | Auto-stop | MANUAL | ✅ | | |
| 03-hotkeys-session.md | HK-08 | No stale callbacks | MANUAL | ✅ | | |
| 03-hotkeys-session.md | HK-09 | Password field refused | MANUAL | ✅ | | |
| 03-hotkeys-session.md | HK-10 | ⌃⌥Z registered | MANUAL | ✅ | | |
| 03-hotkeys-session.md | HK-11 | Hotkey not swallowed when idle | MANUAL | ✅ | | |
| 03-hotkeys-session.md | HK-12 | Recording cap | MANUAL | ⏳ B12 | | |
| 04-speech-capture.md | ASR-01 | Live partials | E2E | ✅ | | |
| 04-speech-capture.md | ASR-03 | Silence restart banks text | MANUAL | ✅ | | |
| 04-speech-capture.md | ASR-04 | First word, pre-roll off | MANUAL | ✅ | | |
| 04-speech-capture.md | ASR-05 | First word, pre-roll on | MANUAL | ✅ | | |
| 04-speech-capture.md | ASR-06 | First-buffer latency | E2E | ✅ | | |
| 04-speech-capture.md | ASR-07 | Dictionary biasing | MANUAL | ✅ | | |
| 04-speech-capture.md | ASR-09 | Noisy room | MANUAL | ✅ | | |
| 04-speech-capture.md | ASR-10 | AirPods / external mic | MANUAL | ✅ | | |
| 04-speech-capture.md | ASR-11 | Parakeet selectable in the app | MANUAL | ⏳ B1 | | |
| 04-speech-capture.md | ASR-13 | Parakeet live words | MANUAL | ⏳ B2 | | |
| 04-speech-capture.md | ASR-14 | Parakeet + vocabulary | MANUAL | ⏳ B1 | | |
| 04-speech-capture.md | ASR-15 | Warm-up clip | MANUAL | ⏳ B12 | | |
| 04-speech-capture.md | ASR-16 | Pause media | MANUAL | ⏳ B12 | | |
| 06-llm-cleanup.md | LLM-33 | Engine switching | MANUAL | ✅ | | |
| 06-llm-cleanup.md | LLM-34 | Model not ready → fallback | MANUAL | ✅ | | |
| 06-llm-cleanup.md | LLM-35 | 4 s timeout | MANUAL | ✅ | | |
| 06-llm-cleanup.md | LLM-36 | Levels | MANUAL | ✅ | | |
| 06-llm-cleanup.md | LLM-37 | Per-app style | E2E | ✅ | | |
| 06-llm-cleanup.md | LLM-38 | Style override | MANUAL | ✅ | | |
| 06-llm-cleanup.md | LLM-39 | Echo of context stripped | E2E | ✅ | | |
| 06-llm-cleanup.md | LLM-40 | Streaming cleanup | MANUAL | ✅ | | |
| 06-llm-cleanup.md | LLM-41 | Re-punctuation at the end keeps the chunks | MANUAL | ✅ | | |
| 06-llm-cleanup.md | LLM-43 | Gemma 3 loads (VLM loader) | MANUAL | ✅ | | |
| 06-llm-cleanup.md | LLM-44 | Prompt version recorded | MANUAL | ✅ | | |
| 06-llm-cleanup.md | LLM-45 | Mode instructions change the output | MANUAL | ⏳ B9 | | |
| 07-insertion.md | INS-01 | AX write in a native app | E2E | ✅ | | |
| 07-insertion.md | INS-02 | Paste in browsers / Electron / terminals | MANUAL | ✅ | | |
| 07-insertion.md | INS-03 | Clipboard restored | MANUAL | ✅ | | |
| 07-insertion.md | INS-04 | User copy during restore wins | MANUAL | ✅ | | |
| 07-insertion.md | INS-05 | Clipboard managers ignore dictations | MANUAL | ✅ | | |
| 07-insertion.md | INS-06 | Smart spacing after punctuation | E2E | ✅ | | |
| 07-insertion.md | INS-07 | Mid-sentence lowercase | MANUAL | ✅ | | |
| 07-insertion.md | INS-08 | Space before following text | MANUAL | ✅ | | |
| 07-insertion.md | INS-09 | Target lock | MANUAL | ✅ | | |
| 07-insertion.md | INS-10 | Electron AX tree | MANUAL | ✅ | | |
| 07-insertion.md | INS-11 | Per-app insert override | MANUAL | ✅ | | |
| 07-insertion.md | INS-12 | Replace selection (dictation, not a command) | MANUAL | ✅ | | |
| 07-insertion.md | INS-13 | Multi-line insert | MANUAL | ✅ | | |
| 07-insertion.md | INS-14 | Slow-app clipboard timing | MANUAL | ⏳ B8 | | |
| 07-insertion.md | INS-15 | Keep dictation on clipboard | MANUAL | ⏳ B8 | | |
| 08-vocabulary-learning.md | VOC-01 | Phonetic post-correction | MANUAL | ✅ | | |
| 08-vocabulary-learning.md | VOC-02 | Common words protected | MANUAL | ✅ | | |
| 08-vocabulary-learning.md | VOC-03 | Learn after 2 fixes | MANUAL | ✅ | | |
| 08-vocabulary-learning.md | VOC-04 | Accept / Reject candidates | MANUAL | ✅ | | |
| 08-vocabulary-learning.md | VOC-05 | Contacts import | MANUAL | ✅ | | |
| 08-vocabulary-learning.md | VOC-06 | Ranked hints (> 100 terms) | MANUAL | ✅ | | |
| 08-vocabulary-learning.md | VOC-07 | No learning outside the window | MANUAL | ✅ | | |
| 08-vocabulary-learning.md | VOC-08 | No false learning | MANUAL | ✅ | | |
| 08-vocabulary-learning.md | VOC-10 | Learn after 1 fix (non-common word) | MANUAL | ⏳ B5 | | |
| 08-vocabulary-learning.md | VOC-11 | Near-common word still needs 2 | MANUAL | ⏳ B5 | | |
| 08-vocabulary-learning.md | VOC-12 | On-screen names, off by default | MANUAL | ⏳ B11 | | |
| 08-vocabulary-learning.md | VOC-13 | On-screen names, on | MANUAL | ⏳ B11 | | |
| 08-vocabulary-learning.md | VOC-14 | Screen names skip secure fields | MANUAL | ⏳ B11 | | |
| 09-snippets-commands-modes.md | SNP-01 | Inline snippet | MANUAL | ✅ | | |
| 09-snippets-commands-modes.md | SNP-02 | Longest trigger wins | MANUAL | ✅ | | |
| 09-snippets-commands-modes.md | SNP-03 | LLM can't alter an expansion | MANUAL | ✅ | | |
| 09-snippets-commands-modes.md | SNP-05 | Case-insensitive trigger | MANUAL | ✅ | | |
| 09-snippets-commands-modes.md | CMD-01 | Make formal | MANUAL | ✅ | | |
| 09-snippets-commands-modes.md | CMD-02 | Bullets | MANUAL | ✅ | | |
| 09-snippets-commands-modes.md | CMD-03 | Fix grammar | MANUAL | ✅ | | |
| 09-snippets-commands-modes.md | CMD-04 | Translate | MANUAL | ✅ | | |
| 09-snippets-commands-modes.md | CMD-05 | Not a command | MANUAL | ✅ | | |
| 09-snippets-commands-modes.md | CMD-06 | Long utterance isn't a command | MANUAL | ✅ | | |
| 09-snippets-commands-modes.md | CMD-07 | Undo to raw (hotkey) | E2E | ✅ | | |
| 09-snippets-commands-modes.md | CMD-08 | Undo via the pill | MANUAL | ✅ | | |
| 09-snippets-commands-modes.md | CMD-09 | Undo after a command | MANUAL | ✅ | | |
| 09-snippets-commands-modes.md | CMD-10 | Undo with nothing to undo | MANUAL | ✅ | | |
| 09-snippets-commands-modes.md | MOD-01 | Website mode | MANUAL | ⏳ B9 | | |
| 09-snippets-commands-modes.md | MOD-02 | Subdomain and path matching | MANUAL | ⏳ B9 | | |
| 09-snippets-commands-modes.md | MOD-03 | Trigger word | MANUAL | ⏳ B9 | | |
| 09-snippets-commands-modes.md | MOD-04 | Precedence | MANUAL | ⏳ B9 | | |
| 09-snippets-commands-modes.md | MOD-05 | URL read only when needed | MANUAL | ⏳ B9 | | |
| 10-privacy-training-models.md | PRV-01 | No sockets while dictating | E2E | ✅ | | |
| 10-privacy-training-models.md | PRV-03 | No audio written to disk | AUTO+MANUAL | ✅ | | |
| 10-privacy-training-models.md | PRV-04 | Download needs consent | MANUAL | ✅ | | |
| 10-privacy-training-models.md | PRV-05 | Deny list | MANUAL | ✅ | | |
| 10-privacy-training-models.md | PRV-06 | Delete All History | MANUAL | ✅ | | |
| 10-privacy-training-models.md | PRV-07 | Retention pruning | MANUAL | ✅ | | |
| 10-privacy-training-models.md | PRV-08 | Offline row in the menu | MANUAL | ✅ | | |
| 10-privacy-training-models.md | PRV-09 | PRIVACY.md matches behavior | MANUAL | ✅ | | |
| 10-privacy-training-models.md | PRV-10 | Network off end to end | MANUAL | ✅ | | |
| 10-privacy-training-models.md | TRN-01 | Sample per insert | MANUAL | ✅ | | |
| 10-privacy-training-models.md | TRN-02 | Edit captured | MANUAL | ✅ | | |
| 10-privacy-training-models.md | TRN-03 | Capture off | MANUAL | ✅ | | |
| 10-privacy-training-models.md | TRN-04 | Labels | MANUAL | ✅ | | |
| 10-privacy-training-models.md | TRN-07 | Clipboard-only inserts not captured | MANUAL | ✅ | | |
| 10-privacy-training-models.md | MDL-01 | Idle unload | MANUAL | ✅ | | |
| 10-privacy-training-models.md | MDL-03 | Improve My Model… disabled below the minimum | MANUAL | ✅ | | |
| 10-privacy-training-models.md | MDL-04 | Improve My Model… end to end | MANUAL | ✅ | | |
| 10-privacy-training-models.md | MDL-05 | Gate refuses a worse model | MANUAL | ✅ | | |
| 10-privacy-training-models.md | MDL-06 | Pinned revision + hashes | MANUAL | ⏳ B3 | | |
| 10-privacy-training-models.md | MDL-07 | Corrupted model detected | MANUAL | ⏳ B3 | | |
| 10-privacy-training-models.md | MDL-08 | Remove model order | MANUAL | ⏳ B3 | | |
| 11-performance.md | PRF-01 | Short dictation latency | E2E | ✅ | | |
| 11-performance.md | PRF-02 | Long dictation, streaming | MANUAL | ✅ | | |
| 11-performance.md | PRF-04 | Idle memory | E2E | ✅ | | |
| 11-performance.md | PRF-06 | Idle CPU | MANUAL | ✅ | | |
| 11-performance.md | PRF-07 | First-buffer latency | E2E | ✅ | | |
| 11-performance.md | PRF-09 | 1-hour soak | MANUAL | ✅ | | |
| 11-performance.md | PRF-10 | Battery | MANUAL | ✅ | | |
| 12-ux-insights.md | UX-01 | Pill below the notch | MANUAL | ✅ | | |
| 12-ux-insights.md | UX-02 | Non-notch display | MANUAL | ✅ | | |
| 12-ux-insights.md | UX-03 | States | MANUAL | ✅ | | |
| 12-ux-insights.md | UX-04 | Settings tabs | MANUAL | ✅ | | |
| 12-ux-insights.md | UX-05 | Menu live state | MANUAL | ✅ | | |
| 12-ux-insights.md | UX-06 | Polished indicator | MANUAL | ✅ | | |
| 12-ux-insights.md | UX-07 | Insights tab | MANUAL | ⏳ B15 | | |
| 12-ux-insights.md | UX-08 | Insights are correct | MANUAL | ⏳ B15 | | |
| 12-ux-insights.md | UX-09 | No-edit rate trend | MANUAL | ⏳ B15 | | |
| 12-ux-insights.md | UX-10 | Start / stop sounds | MANUAL | ⏳ B12 | | |
