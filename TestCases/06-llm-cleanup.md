# 06 · LLM cleanup, faithfulness, streaming

Engines: `apple` (Foundation Models), `qwen3` (Qwen3-4B-Instruct-2507, MLX), `gemma3`
(Gemma 3 4B, MLX). AUTO cases run against every engine passed with `--engines`.

| ID | Scenario | Steps | Expected | Type | Status | Result |
|---|---|---|---|---|---|---|
| LLM-01…21 | Cleanup quality and safety per style and level (fillers, questions, injections, requests, lists, no synonyms, code/terminal, casual, full rewrite, short replies, translate/math/system traps, Off level, email) | `data/cleanup.tsv` via `--clean` | Every `must` present, no `must_not` present | AUTO | ✅ | |
| LLM-30 | Core bench | `Bench/cases.tsv` → `--bench` → `--vet` per engine | 50/50 accepted (TEST_REPORT baseline) | AUTO | ✅ | |
| LLM-31 | Adversarial bench | `data/bench_extra.tsv` → `--bench` → `--vet` | ≥ 90% accepted; rejects fall back safely | AUTO | ✅ | |
| LLM-32 | Faithfulness: no dropped content words | Included in LLM-30 (vet runs the content-word check) | 0 dropped content words in `light` | AUTO | ✅ | |
| LLM-33 | Engine switching | Menu ▸ AI Cleanup ▸ Engine: Apple → Qwen3 → Gemma 3; dictate each time | History source shows `llm:<engine>`; the menu status row updates | MANUAL | ✅ | |
| LLM-34 | Model not ready → fallback | Select Qwen3 while it's unloaded or downloading; dictate | Inserts Apple or rules text; log gives the reason; no hang | MANUAL | ✅ | |
| LLM-35 | 4 s timeout | Force a slow model (big input with streaming off) | Rules text inserted after ≤ 4 s; `timeout` logged | MANUAL | ✅ | |
| LLM-36 | Levels | Same sentence at Off / Light / Full | Off = rules only; Light = no rewording; Full = concise, no information lost | MANUAL | ✅ | |
| LLM-37 | Per-app style | Same sentence into Mail, Slack, Terminal, Notes | Formal / casual / code (prose punctuation kept) / neutral | E2E | ✅ | |
| LLM-38 | Style override | Set `style.com.apple.Notes` = `formal` | Notes output is formal | MANUAL | ✅ | |
| LLM-39 | Echo of context stripped | Field contains "Notes: "; dictate a question | Inserted text doesn't repeat "Notes:" (fix #5) | E2E | ✅ | |
| LLM-40 | Streaming cleanup | `stream.enabled` on; dictate ~300 words | Pill shows sentences polished while you talk; key-up → insert ≈ 1 s | MANUAL | ✅ | |
| LLM-41 | Re-punctuation at the end keeps the chunks | Long dictation whose final recognizer pass changes punctuation | Wait ≈ 0.3 s, not ~2 s (fix #6); log shows the prefix kept | MANUAL | ✅ | |
| LLM-42 | Long-text chunking | Suite `long` (`--bench-long --words 200,1000,2000`) | Chunks OK = 100% at every size; last-chunk ms ≤ 1,300 | AUTO | ✅ | |
| LLM-43 | Gemma 3 loads (VLM loader) | Select Gemma 3 | Loads and cleans; no layout error | MANUAL | ✅ | |
| LLM-44 | Prompt version recorded | Dictate; inspect the newest `samples` row | `prompt_version` = current `CleanupPrompt.promptVersion` | MANUAL | ✅ | |
| LLM-45 | Mode instructions change the output | Gmail mode with "sign off with Thanks, Gourav" | Output follows it; `promptVersion` bumped; `mode` stored on the sample | MANUAL | ⏳ B9 | |
