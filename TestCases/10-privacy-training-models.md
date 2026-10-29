# 10 · Privacy, training data, models

| ID | Scenario | Steps | Expected | Type | Status | Result |
|---|---|---|---|---|---|---|
| PRV-01 | No sockets while dictating | `--e2e` (lsof step) | No open network sockets | E2E | ✅ | |
| PRV-02 | One network call site | Runner static scan | Network or download code only in `MLXCleanupClient.swift` | AUTO | ✅ | |
| PRV-03 | No audio written to disk | Runner static scan + `sudo fs_usage -w -f filesys LocalFlow` while dictating | No `AVAudioFile(forWriting:)` in the app path; no audio files created | AUTO+MANUAL | ✅ | |
| PRV-04 | Download needs consent | Select an un-downloaded model | Consent dialog first; Cancel = no network | MANUAL | ✅ | |
| PRV-05 | Deny list | Dictate into 1Password or Bitwarden | No `history` or `samples` row | MANUAL | ✅ | |
| PRV-06 | Delete All History | Settings ▸ Delete All | `history` and `samples` empty (`sqlite3 … "select count(*) from samples"`) | MANUAL | ✅ | |
| PRV-07 | Retention pruning | Set 30 days; insert an old row in a copy DB; relaunch | Old row removed | MANUAL | ✅ | |
| PRV-08 | Offline row in the menu | Open the menu | Offline / privacy row present and accurate | MANUAL | ✅ | |
| PRV-09 | PRIVACY.md matches behavior | Review it against PRV-01…08 | No contradictions | MANUAL | ✅ | |
| PRV-10 | Network off end to end | Wi-Fi off; dictate with Apple and Qwen3 (downloaded) | Works normally | MANUAL | ✅ | |
| TRN-01 | Sample per insert | Dictate 3×; Settings ▸ Training | Count +3; fields filled (engine, style, rules, output, latency) | MANUAL | ✅ | |
| TRN-02 | Edit captured | Dictate; edit within 10 s | `final_text` set, `edited=1` | MANUAL | ✅ | |
| TRN-03 | Capture off | `training.capture` off; dictate | No new sample | MANUAL | ✅ | |
| TRN-04 | Labels | Good / Bad / Exclude; click again | Label set, then cleared | MANUAL | ✅ | |
| TRN-05 | Export training JSONL | Runner: scratch DB `--seed-demo-samples` → `--export-training` | `train.jsonl` + `valid.jsonl`; every line valid JSON with system/user/assistant | AUTO | ✅ | |
| TRN-06 | Export rejects | Runner: `--export-rejects` | Valid JSONL; ≥ 1 line from the demo seed | AUTO | ✅ | |
| TRN-07 | Clipboard-only inserts not captured | Dictate without Accessibility | No sample | MANUAL | ✅ | |
| MDL-01 | Idle unload | `mlx.idle.minutes` = 5; wait 6 min; `--control memory` | Memory drops to idle (< 80 MB); next dictation reloads; key-up falls back if not ready | MANUAL | ✅ | |
| MDL-02 | Model gate | Runner: `--gate` with identical result files | Exit 0, `switch` | AUTO | ✅ | |
| MDL-03 | Improve My Model… disabled below the minimum | Fewer than `personal.minSamples` new samples | Menu item disabled with an explanation | MANUAL | ✅ | |
| MDL-04 | Improve My Model… end to end | ≥ 200 samples; run it | Trains, benches, switches only if ≥ base; keeps the last 2 for rollback | MANUAL | ✅ | |
| MDL-05 | Gate refuses a worse model | Use an overfit adapter (TEST_REPORT method) | Keeps the base model | MANUAL | ✅ | |
| MDL-06 | Pinned revision + hashes | Inspect the model folder after download | `.localflow-installed` marker with revision + hashes | MANUAL | ⏳ B3 | |
| MDL-07 | Corrupted model detected | Truncate one weights file; launch; select the model | Not treated as installed; offers re-download; no crash | MANUAL | ⏳ B3 | |
| MDL-08 | Remove model order | Remove the model while it's loaded | Marker deleted → model unloaded → files deleted; a dictation during removal falls back | MANUAL | ⏳ B3 | |
| MDL-09 | Code probe: pinned install | Runner probe | SHA-256 + marker logic in Sources | AUTO | ⏳ B3 | |
