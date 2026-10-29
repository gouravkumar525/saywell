# 04 · Speech capture and recognition

| ID | Scenario | Steps | Expected | Type | Status | Result |
|---|---|---|---|---|---|---|
| ASR-01 | Live partials | ⌃⌥D and speak | Words appear in the pill within ~1 s; last 140 characters shown | E2E | ✅ | |
| ASR-02 | Long dictation capture | Put a 3–5 min recording in `data/audio/` (with a `.txt` reference); run suite `simulate` | Word recall ≥ 98%; final text ≤ 1 s after the audio ends (TEST_REPORT: 861/861) | AUTO | ✅ | |
| ASR-03 | Silence restart banks text | Speak, stay silent 15 s, speak again, stop | Both parts inserted; log shows a recognizer restart, nothing lost | MANUAL | ✅ | |
| ASR-04 | First word, pre-roll off | 20× start speaking the instant you trigger: "So we should ship it" | First word missing ≤ 1/20 | MANUAL | ✅ | |
| ASR-05 | First word, pre-roll on | Turn on the `mic.preroll` setting; repeat ASR-04 | 0/20 missing; orange mic dot visible while idle (documented tradeoff) | MANUAL | ✅ | |
| ASR-06 | First-buffer latency | Trigger dictation; read the log | `first buffer` < 80 ms | E2E | ✅ | |
| ASR-07 | Dictionary biasing | Add "Kubernetes"; say "deploy it on Kubernetes" | Recognized or post-corrected to "Kubernetes" | MANUAL | ✅ | |
| ASR-08 | ASR clip set bench | Clips + `.txt` in `data/asr/`; suite `asr` | WER table per backend (sfspeech, analyzer); SFSpeech WER ≤ 12.3% baseline | AUTO | ✅ | |
| ASR-09 | Noisy room | Dictate with background music or a fan | Usable output; no made-up text during silences | MANUAL | ✅ | |
| ASR-10 | AirPods / external mic | Switch the input device; dictate | Works with the new device; no crash on device change mid-session | MANUAL | ✅ | |
| ASR-11 | Parakeet selectable in the app | Choose Parakeet in the recognizer menu; dictate | Works end to end; model download consent; offline afterwards | MANUAL | ⏳ B1 | |
| ASR-12 | Parakeet accuracy | Suite `asr` with Parakeet included | WER ≤ 6.5% on the clip set and ≤ SFSpeech; key-up latency ≤ 1.3 s | AUTO | ⏳ B1 | |
| ASR-13 | Parakeet live words | Dictate with Parakeet | Confirmed words white, provisional grey; final text keeps the confirmed prefix | MANUAL | ⏳ B2 | |
| ASR-14 | Parakeet + vocabulary | Dictionary term not in English (e.g. "Raghunathan") | Spelled correctly through G6 post-correction | MANUAL | ⏳ B1 | |
| ASR-15 | Warm-up clip | Relaunch; time the first dictation vs the second | First is within 20% of the second | MANUAL | ⏳ B12 | |
| ASR-16 | Pause media | Play Music; dictate; stop | Music pauses during the recording and resumes after; if nothing was playing, nothing starts | MANUAL | ⏳ B12 | |
| ASR-17 | Code probe: word agreement / Parakeet | Runner probe | FluidAudio in Package.swift; an agreement engine in Sources | AUTO | ⏳ B1/B2 | |
