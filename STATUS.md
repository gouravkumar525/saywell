# LocalFlow — Project Status & Pick-Up Notes

*Last updated: 2026-10-20*

Full design and session change log: [ARCHITECTURE.md](ARCHITECTURE.md).

A Wispr Flow–style AI voice dictation app for macOS. Speak from any app, and cleaned-up
text is typed into whatever app has focus. Lives in a "Dynamic Island"-style pill on the
MacBook notch. English only, fully on-device (no API keys, no network).

## How it works (architecture)

Fully on-device. Pipeline per dictation (`SessionController`):
capture context → stream mic to ASR → rules cleanup → snippets → Foundation Model polish
(falls back to rules) → insert (AX write → paste) → watch for user edits → learn.

| Component | File | Role |
|---|---|---|
| HotkeyManager | `Sources/LocalFlow/HotkeyManager.swift` | **Hold Fn** = push-to-talk (CGEventTap listen-only on flagsChanged/keyDown; Fn+key or <0.3s tap cancels). **⌃⌥D** = toggle (Carbon). Tap retries every 3s until Accessibility is granted. |
| SessionController | `Sources/LocalFlow/SessionController.swift` | State machine + pipeline above; generation counter drops stale callbacks; optional auto-stop after N s silence (toggle mode). |
| DictationEngine | `Sources/LocalFlow/DictationEngine.swift` | AVAudioEngine → `SFSpeechRecognizer` (on-device, streaming), restarts through silences. Dictionary terms → `contextualStrings`. Energy VAD (`secondsSinceVoice`). |
| ContextProvider | `Sources/LocalFlow/ContextProvider.swift` | Frontmost bundle ID, focused AX element, role, secure-field check, selection range, ~400 chars before the caret (`AXStringForRange`). Sets `AXManualAccessibility` for Electron apps. |
| AppStyle | `Sources/LocalFlowCore/AppStyle.swift` | Bundle ID → formal (Mail/Outlook/Word) / casual (Slack/Messages/Discord) / code (Xcode/VS Code/terminals/JetBrains) / neutral. Override: setting `style.<bundleID>`. |
| CleanupClient | `Sources/LocalFlow/CleanupClient.swift` | Apple Foundation Models (`LanguageModelSession`, greedy, streamed to the pill). Session prewarmed at dictation start; 4s timeout; guardrail/errors → nil. |
| CleanupPrompt | `Sources/LocalFlowCore/CleanupPrompt.swift` | Instructions per level (off/light/full) × style; prompt with dictionary + preceding text; `accept()` rejects preambles/refusals/answers via word-count ratio. `SnippetExpander` swaps expansions for ⟦n⟧ tokens so the LLM can't touch them. |
| TextProcessor | `Sources/LocalFlowCore/TextProcessor.swift` | Rule cleanup (fillers, "change that to", lists, punctuation). Runs before the LLM and is the fallback. |
| TextInserter | `Sources/LocalFlow/TextInserter.swift` | 1) set `kAXSelectedTextAttribute` and verify by reading back (native apps), 2) pasteboard + ⌘V, restore after 250ms (skipped if user copied meanwhile), 3) clipboard only. Browsers/Electron/terminals forced to paste. Override: setting `insert.<bundleID>` = `paste`/`accessibility`. |
| EditWatcher | `Sources/LocalFlow/EditWatcher.swift` | Polls the field for 10s after insert, diffs (`EditDiff`, word LCS) → correction candidates; seen 2× → dictionary. |
| Store | `Sources/LocalFlowCore/Store.swift` | SQLite (system libsqlite3, no deps) at `~/Library/Application Support/LocalFlow/localflow.sqlite`: settings, dictionary, candidates, snippets, history. |
| Settings window | `Sources/LocalFlow/SettingsWindow.swift` | Dictionary (+ learned candidates), Snippets, History. Menu bar: AI Cleanup level, Hold Fn, Auto-stop. |
| CLI modes | `Sources/LocalFlow/CLI.swift`, `main.swift` | `--process`, `--clean "text" [--app <bundleID>] [--level light|full]`, `--transcribe`, `--listen N`, `--inject`, `--status`. |

Not done from the reference design (deliberately, to stay on-device/dep-free): cloud
WebSocket ASR, Silero VAD (energy VAD instead), GRDB (raw SQLite3), Keychain (no secrets),
300ms pre-roll (would need the mic always on).

## Build & run

```bash
./Scripts/make_app.sh          # swift build -c release + bundle + ad-hoc codesign
open build/LocalFlow.app       # menu bar mic icon + notch strip appear
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # 29 tests (CLT has no XCTest)
```

Use: focus any text field → **⌃⌥D** (or click the notch pill) → speak → **⌃⌥D** again →
cleaned text is pasted into the focused app.

## What is VALIDATED ✅

- 16/16 unit tests pass (fillers, corrections, lists, punctuation).
- Full cleanup pipeline: `"um, hello team, uh, let's meet on Monday, no, change that to
  Tuesday, new line number one review the doc number two ship it"` →
  `"Hello team, let's meet on Tuesday\n1. Review the doc\n2. Ship it"`.
- File transcription E2E (`--transcribe` on `say`-generated audio): RAW `"Hello team,
  let's meet on Monday. No change that to Tuesday."` → CLEAN `"Hello team, let's meet on
  Tuesday."` — on-device recognizer works, correction applied across sentence boundary.
- Live mic streaming (`--listen`): real-time partials of real human speech confirmed.
- Injection E2E: `--inject` pasted text into a TextEdit doc, read back exact match;
  clipboard restored.
- Notch panel renders at correct geometry (window-server verified: 209×38pt, top-center
  over the notch, layer 25).
- Recognizer self-termination after ~10s silence: now auto-restarts and banks transcript
  (fix landed; validated at engine level, needs one live in-app confirmation).

## Training data capture (2026-10-18) ✅ built, offline-verified

- Every inserted dictation → `samples` table (raw, rules sent to model, context, model
  output even if rejected, inserted, final text after edits, latency, label). Settings ▸
  Training tab labels Good/Bad/Exclude, toggles capture, sets retention.
- `--export-training ~/lf-data/train.jsonl [--valid-split 0.1]` → mlx_lm.lora chat JSONL
  (+ `valid.jsonl`); `--export-rejects` for DPO. Verified on a seeded scratch DB
  (`--db … --seed-demo-samples`): 3 eligible → 2 train / 1 valid, rejects 1, tokens intact.
- 40/40 tests pass (11 new `TrainingTests`).
- Live paste confirmed in the log before the rebuild (`inserted via paste [llm]`, 23:22).
- Not yet seen live: a sample written during real use and its `final_text` after an edit.
  Details: ARCHITECTURE.md §12, NEXT_STEPS.md "Training data".

## Phase B — local model chosen (2026-10-18) ✅

- `~/lf-mlx` venv with mlx-lm 0.32.2; Qwen3-4B-Instruct-2507-4bit and Gemma 3 4B downloaded
  (~5.3 GB in `~/.cache/huggingface`). Not wired into the app yet (that's Phase C/D).
- Bench with the app's exact prompts: all three engines 12/12 accepted, ~0.5 s median.
  Qwen3 was the most faithful → chosen. Results and commands in NEXT_STEPS.md B3.
- New tooling: `Bench/cases.tsv`, `Scripts/bench_mlx.py`, CLI `--dump-prompts`,
  `--bench-apple`, `--vet`.

## Local models in the app (2026-10-19) ✅

- AI Cleanup ▸ Model: **Apple / Qwen3 4B / Gemma 3 4B**, switchable live; falls back to
  Apple while a local model loads. Bench through the app: Qwen3 12/12, 530 ms median;
  Gemma 12/12, 963 ms; Apple 12/12, 534 ms. ARCHITECTURE.md §13.
- Build is now `xcodebuild` (Scripts/make_app.sh), signed with the "LocalFlow Dev" cert, so
  **permissions should survive rebuilds from now on** (needs one final grant for the new
  signature). Tests: `Scripts/test.sh` (41 pass).

## What is BLOCKED — waiting on user (the only remaining step) ⚠️

The in-app end-to-end (hotkey → speak → paste appears) needs **permission grants for the
.app itself** (grants given earlier applied to the terminal, not the app; ad-hoc re-signing
also resets them after every rebuild):

1. **Speech Recognition + Microphone**: click *Allow* on the prompts when the app starts.
2. **Accessibility** (enables the ⌘V paste): System Settings → Privacy & Security →
   Accessibility → enable **LocalFlow** (add `build/LocalFlow.app` with **+** if missing).
   Without it, text is left on the clipboard and the pill says so.
3. Then test: focus TextEdit, ⌃⌥D, say *"um, hello team, let's meet on Monday, no, change
   that to Tuesday"*, ⌃⌥D. Check `~/Library/Logs/LocalFlow.log` — it records audio peak
   levels, first partial, task restarts, final raw/clean, and inject result, so any failure
   is pinpointable.

## Phase F + G (2026-10-19) ✅ implemented

Everything in NEXT_STEPS (F1, F2 pipeline, G1–G11) is built. Measurements are in
**TEST_REPORT.md**, design is in ARCHITECTURE.md §14, and installing on another Mac is in
**INSTALL.md** / `Scripts/package.sh`. Privacy is described in **PRIVACY.md**.

Tests and tools:
- `Scripts/test.sh` runs 66 unit tests.
- `Scripts/e2e_test.sh [engine]` runs the live mic → app → test-window test.
- CLI: `--bench-long`, `--simulate`, `--bench-asr`, `--gate`.

## Known quirks / debugging notes

- `say` audio played through speakers is **echo-cancelled out of the mic** — you can't
  self-test the mic path with `say`; a human must speak.
- Every rebuild (ad-hoc signature) **resets TCC permissions** → re-grant mic/speech/AX.
  A stable self-signed cert would fix this (no signing identities on this Mac yet).
- Screen Recording permission not granted to the terminal → `screencapture` fails;
  panel verified via `CGWindowListCopyWindowInfo` instead (scratchpad `winlist.swift`).
- Correction heuristic: strips shared prefix/suffix words, then anchors on the
  correction's first word ("the design team"→"the platform team"), else replaces the last
  word ("Monday"→"Tuesday at noon" keeps "Send it"). Whole-clause redo = "scratch that".
- User's TextEdit had a personal draft open (`caption_test.txt`) — test docs were created
  and closed separately; never touch existing docs.

## Next steps (in order)

0. Re-grant permissions after the 2026-10-18 training rebuild (mic, speech, Input
   Monitoring, Accessibility), dictate into TextEdit, edit a word within 10 s, then check
   Settings ▸ Training shows the sample with "edited to:".

1. User grants permissions (mic, speech, Accessibility) → live E2E in TextEdit, Slack, Mail.
   Check log lines `context:`, `llm:`, `inserted via`.
2. Verify Fn hold-to-talk (set System Settings → Keyboard → "Press 🌐 key to" = Do Nothing).
3. Verify EditWatcher learning: correct a word twice → appears in Dictionary tab.
4. LLM quirks seen in `--clean` tests: light mode occasionally rewords ("doc"→"document");
   full mode dropped "ignore previous instructions" as a false start (didn't obey it).
5. Ideas: voice commands on selected text ("make this formal"), SpeechAnalyzer (macOS 26)
   instead of SFSpeechRecognizer, self-signed cert for stable TCC, per-app style UI.

## BetterWispr gap items B1–B16 (2026-10-20) ✅ implemented

See **TEST_REPORT.md §9**, **eval/RESULTS.md** and **docs/accuracy.md**.
- New Core files: `SpokenFormatting`, `WritingMode`, `UsageInsights`, `ScreenNames`,
  `ModelManifest` (+ the generated `ModelManifests`), `WordAgreement`.
- New app files: `ParakeetEngine` (+ `SpeechEngine` protocol), `PinnedModels`, `MediaControl`,
  `Updater`.
- Dependencies: FluidAudio 0.17.7 (Parakeet) and Sparkle 2.6.4 (updates, inactive without a feed).
- Tests: 156 (`Scripts/test.sh`). Compile check: `Scripts/build_check.sh`. E2E:
  `Scripts/e2e_test.sh <engine> <apple|parakeet>`.
- Open:
  - Make Parakeet the default once the real-voice no-edit rate agrees.
  - B13 needs a Developer ID and an update host.
  - A real fine-tune needs 200+ samples.

## Distribution prep (2026-10-20) ✅
- Gemma 3 removed (engine, MLXVLM dependency, manifest). A saved `gemma3` setting falls back to Apple.
- `THIRD_PARTY_NOTICES.md` (generated by `Scripts/notices.py`) credits Parakeet (CC BY 4.0), Qwen3 (Apache 2.0) and all 14 packages plus their vendored code. It ships in the app (menu ▸ Acknowledgements…) and in every package.
- `Scripts/package.sh --with-model qwen3|parakeet|qwen3,parakeet` bundles pinned, verified models. `dist/LocalFlow-1.0-with-parakeet.dmg` is 487 MB.

## Renamed to Saywell (2026-10-20)
- The app is **Saywell.app**, with bundle ID `com.gourav.saywell` and the icon in `Resources/Icon` (rebuild it with `swift Scripts/make_icon.swift`).
- Data lives in `~/Library/Application Support/Saywell` (`saywell.sqlite`, `models/`) and the log in `~/Library/Logs/Saywell.log`. The old LocalFlow folder is moved automatically, by `Store.migrateFromLocalFlow` and by Install.command.
- Unchanged code names: the Swift package, targets and scheme are still `LocalFlow` / `LocalFlowCore`, and the signing certificate is still `LocalFlow Dev`. Neither is visible to users.
- The new bundle ID means macOS permissions must be granted again once.

## Coucou features (2026-10-29) — C1–C6
Adapted from github.com/louis-cfm/coucou (MIT, credited in THIRD_PARTY_NOTICES.md); Sprig is our own character.
- **C1 Keys:** menu ▸ Hold Key to Talk (Fn / right ⌥ / right ⌘ / right ⌃ / Off), double tap = hands-free, Esc cancels,
  ⌃⌘V pastes the last dictation. `HoldKeyLogic` (pure, tested). The 🌐 key sends keyDown 179 and delivers its release
  late; both handled (`finishWait` grace after holds < 1 s). Verified live by the user.
- **C2 Stats + languages:** `usage` table (word counts only, every dictation; backfilled from samples), Insights ▸ Time
  saved (45 wpm typing). Menu ▸ Language: Apple locales installed for offline use + Parakeet's 25; non-English skips the
  English-only rules and tells the model to keep the language. French verified live with Parakeet.
- **C3 Sprig:** `sprig_character.md` ported to Swift (`Sprig.swift` engine, tested with a fake clock; `SprigView.swift`
  renderer). States: idle, listening (hand at ear, arcs + ♪ follow the voice), writing (notepad + pencil), thinking,
  working, approval, question, error, done, sleeping, dizzy. In the notch (70 pt), the bottom pill and the menu bar.
- **C4 Pill:** menu ▸ Pill Position (notch default; bottom / left / right, click-through except the capsule, hover
  toolbar: dictate, record call, settings). Real 9-band voice dots (vDSP FFT in `MicCapture`, `AudioBands`).
- **C5 Notes:** Record a Call (menu, pill, Settings ▸ Notes). Mic + Core Audio process tap (System Audio Recording
  permission) → 16 kHz WAVs → live Parakeet lines → full pass with word times, echo removal, FluidAudio offline
  diarizer (pinned, 22 MB, CC-BY-4.0, FluidAudio kept in offline mode) → transcript by speaker → summary/key
  points/to-dos by Qwen3 or Apple FM → audio deleted. `--make-call` + `--note-test` verify the pipeline: 3 speakers
  right, echo removed, summary in ~6 s for a 39 s call. **Needs the user:** allow System Audio Recording on the first
  real call.
- **C6 Claude Code:** `saywell-hook` helper (Contents/Helpers, copied to Application Support/Saywell/bin) → Unix
  socket `agent.sock` (0600, peer uid checked) → notch card: Allow / Deny / Always / Terminal, AskUserQuestion
  options; hang-up and 115 s timeout fall back to the terminal. Settings ▸ Agents: preview, then write
  `~/.claude/settings.json` (backup kept); Disconnect removes only our entries. Verified with simulated hook events.
  **Needs the user:** click Connect (it also routes this Claude Code session's prompts to the notch).
- Re-pinning models: `python3 Scripts/pin_models.py mlx-community/Qwen3-4B-Instruct-2507-4bit
  'FluidInference/parakeet-tdt-0.6b-v3-coreml@<rev>=<dir>' 'FluidInference/speaker-diarization-coreml@df2625ac79a7ac6b65ad868fee6d80f320da4232=<dir>'`
- **C5b (2026-10-29):** Auto-Record Meetings (menu: Off / Ask Me in the Notch / Always): `MicUsers` reads Core Audio's
  process list every 2 s; `MeetingDetector` (tested) starts after Zoom/Teams/Webex hold the mic 4 s and ends 12 s after
  they let go; recordings started for a meeting stop with it. Notes now: each line cleaned (rules + light model pass +
  faithfulness vet, original kept in `raw`), summary JSON with decisions / action items (owner, due) / open questions,
  Qwen3 loaded on demand for notes (Apple FM fallback). Qwen3 run on the scripted call: fillers and repeats removed,
  1 decision, 3 action items with correct owners. Zoom is installed: the user can verify detection by joining a meeting.
- **C7 Hub window (2026-10-29):** `HubWindow.swift`. Opening Saywell.app (or the Dock icon, or menu ▸ Open Saywell…)
  shows a dark main window modelled on Coucou's: first launch asks your name ("Hi, I'm Sprig"), then Dictation
  (Hello <name> banner with three live Sprigs and Record a call, searchable history with copy/delete, stats card,
  Notetaker card), Notetaker (notes with transcript, summary, decisions, action items), Statistics, Dictionary,
  Snippets, Styles, General (every menu setting, applied through the menu's own actions), Agents, Privacy, Training,
  Shortcuts. In the Dock while the window is open, menu-bar only when closed. Screenshots checked.
