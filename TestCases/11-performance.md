# 11 · Performance and resources

Baselines are from TEST_REPORT.md (M5, 16 GB). Re-baseline on your own hardware.

| ID | Scenario | Steps | Expected | Type | Status | Result |
|---|---|---|---|---|---|---|
| PRF-01 | Short dictation latency | 10 short dictations; read the `llm:` ms and insert times in the log | p90 key-up → insert ≤ 1.3 s | E2E | ✅ | |
| PRF-02 | Long dictation, streaming | 500-word dictation, streaming on | Key-up → insert ≤ 1.3 s | MANUAL | ✅ | |
| PRF-03 | Chunked long text | Suite `long` | 100% chunks OK at 200 / 1,000 / 2,000 words | AUTO | ✅ | |
| PRF-04 | Idle memory | `--control memory` with the model unloaded | < 80 MB (baseline 77 MB) | E2E | ✅ | |
| PRF-05 | Loaded memory | `--bench` prints memory | Peak ≈ 2.3–3 GB with Qwen3; note it in results | AUTO | ✅ | |
| PRF-06 | Idle CPU | Activity Monitor, 5 min idle | ≈ 0% CPU; no timers firing | MANUAL | ✅ | |
| PRF-07 | First-buffer latency | Log `first buffer` | < 80 ms | E2E | ✅ | |
| PRF-08 | Bench latency | Suite `bench` summary | Median ≤ 1,500 ms per engine on short cases | AUTO | ✅ | |
| PRF-09 | 1-hour soak | Dictate every 2 min for an hour | No memory growth > 50 MB at idle; no crash | MANUAL | ✅ | |
| PRF-10 | Battery | 1 hour of normal use on battery | No unusual energy impact in Activity Monitor | MANUAL | ✅ | |
