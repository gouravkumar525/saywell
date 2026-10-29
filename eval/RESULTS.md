# Benchmark history

Add a row each time a model, the prompt, a recognizer or the rules change, so you can tell
whether the change helped. All runs below are on an M5 with 16 GB.

How to reproduce:
```bash
B=build/Saywell.app/Contents/MacOS/Saywell
$B --bench Bench/cases.tsv out-qwen3.jsonl --engine qwen3     # cleanup, 50 cases
$B --vet out-apple.jsonl out-qwen3.jsonl                       # accept/reject + summary
$B --make-asr-set ~/asr && $B --bench-asr ~/asr --asr all      # recognizers, 20 TTS clips
$B --simulate long.aiff --asr parakeet                         # live path, real-time feed
$B --bench-long --engine qwen3                                 # 50 → 2,000 words
Scripts/e2e_test.sh qwen3 parakeet                             # live mic → app → field
```

## Cleanup (50-case `Bench/cases.tsv`, light level)

| Date | Engine | Prompt v | Rules | Accepted | Median / max ms | Notes |
|---|---|---|---|---|---|---|
| 2026-10-18 | Apple FM | 1 | — | 12/12 (12-case set) | 534 | First bench |
| 2026-10-18 | Qwen3 4B | 1 | — | 12/12 | 530 | Most faithful, chosen |
| 2026-10-18 | Gemma 3 4B | 1 | — | 12/12 | 963 | |
| 2026-10-19 | Apple FM | 2 | G1 guard | 50/50 | 516 / 1085 | 0 answered questions, 0 obeyed injections |
| 2026-10-19 | Qwen3 4B | 2 | G1 guard | 50/50 | 489 / 1321 | |
| 2026-10-19 | Gemma 3 4B | 2 | G1 guard | 50/50 | 1470 / 2261 | Slow through the VLM loader |
| 2026-10-20 | Apple FM | 2 | + B10 formatting | 50/50 | 518 / 1194 | No regression from the new rules |
| 2026-10-20 | Qwen3 4B | 2 | + B10 formatting | 50/50 | 481 / 1288 | |

## Speech recognition (20 TTS clips: 3 voices, names, jargon, numbers, code)

| Date | Recognizer | Where measured | WER | Dropped words | ms / clip |
|---|---|---|---|---|---|
| 2026-10-19 | SFSpeech (on-device) | app | 12.3% | 1.8% | 108 |
| 2026-10-19 | SpeechAnalyzer (macOS 26) | app | 10.5% | 3.1% | 81 |
| 2026-10-19 | Parakeet TDT v3 | `Tools/parakeet-bench` | 6.1% | 1.3% | 52 |
| 2026-10-20 | SFSpeech | app | 12.3% | 1.8% | 106 |
| 2026-10-20 | SpeechAnalyzer | app | 10.1% | 2.6% | 83 |
| 2026-10-20 | **Parakeet TDT v3** | **app (B1)** | **6.1%** | **1.3%** | **40** |
| 2026-10-20 | Parakeet, 22 clips including the 1-min and 5-min recordings | app | 1.3% | 0.2% | 84 (5 min of audio in 756 ms) |

## Live path (real-time feed through the recognizer, `--simulate`)

| Date | Recognizer | Audio | WER | Words confirmed live | Final text after audio ends |
|---|---|---|---|---|---|
| 2026-10-19 | SFSpeech | 3 min 51 s | 5.6% | partials only | 0.2 s |
| 2026-10-20 | Parakeet + agreement (first version) | 48 s | ~5% | 177 / 178 | 0.08 s; duplicate words at cuts ("is is"), "three. databases" |
| 2026-10-20 | Parakeet + hold-back, gap cuts, full final pass | 48 s | 0% | 175 / 178 | 0.27 s |
| 2026-10-20 | Parakeet, same, 3× speed | 4 min 48 s | ~0.6% | 847 / 863 | 0.07 s (window pass, > 2 min) |

## Live end-to-end (speech from speakers → mic → app → test window, Qwen3 cleanup)

| Date | Recognizer | Cases inserted | Key-up → inserted | Errors seen |
|---|---|---|---|---|
| 2026-10-20 | SFSpeech | 4/4 | 0.06–0.98 s | — |
| 2026-10-20 | SFSpeech | 7/7 | 0.09–0.87 s | Dropped "at" in an email ("Grava gmail.com"); "email mode" heard as "Email Monai" |
| 2026-10-20 | Parakeet | 7/7 | 0.58–0.76 s | "meet" → "eat"; "hi" → "high" (speaker playback) |

## Memory

| Date | Configuration | Footprint |
|---|---|---|
| 2026-10-19 | App with the Apple engine | ~10 MB (Apple's model service: ~0.9 GB peak, macOS-owned) |
| 2026-10-19 | App + Qwen3 4B | 2.31 GB, 2.84–3.33 GB peak |
| 2026-10-19 | App + Gemma 3 4B | 3.50 GB, ~4.3 GB peak |
| 2026-10-20 | App + Parakeet (recognizer only) | 44 MB peak (SFSpeech: 13 MB); Core ML weights on the Neural Engine |
| 2026-10-20 | App + Qwen3 + Parakeet, live E2E | 2.37 GB, 2.97 GB peak |
