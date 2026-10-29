# 12 · UI, insights, quality of life, engineering

| ID | Scenario | Steps | Expected | Type | Status | Result |
|---|---|---|---|---|---|---|
| UX-01 | Pill below the notch | Notched MacBook; dictate | Text fully visible below the camera housing; 2 lines | MANUAL | ✅ | |
| UX-02 | Non-notch display | External monitor as main display | Pill renders correctly at the top center | MANUAL | ✅ | |
| UX-03 | States | Idle → listening → processing → inserted / error | Each state shows the right text and colour; errors stay for 3.5 s | MANUAL | ✅ | |
| UX-04 | Settings tabs | Open Dictionary, Snippets, History, Training | All load; edits persist after relaunch | MANUAL | ✅ | |
| UX-05 | Menu live state | Open the menu during a model download | Percentage updates on reopen | MANUAL | ✅ | |
| UX-06 | Polished indicator | Full level, heavy edit | Pill shows "Polished ✓ · Raw ⌃⌥Z" | MANUAL | ✅ | |
| UX-07 | Insights tab | Settings ▸ Insights | Words (today, week, all time), WPM, words removed, top apps, streak | MANUAL | ⏳ B15 | |
| UX-08 | Insights are correct | Compare with SQL on `samples` | Numbers match exactly | MANUAL | ⏳ B15 | |
| UX-09 | No-edit rate trend | After ≥ 50 samples | No-edit rate and a trend line shown; G7 "Your model" comparison | MANUAL | ⏳ B15 | |
| UX-10 | Start / stop sounds | Turn on sounds | Subtle sounds on start and stop; off by default | MANUAL | ⏳ B12 | |
| ENG-01 | Test count | Runner probe | ≥ 150 XCTest cases | AUTO | ⏳ B16 | |
| ENG-02 | Accuracy notes | Runner probe | `docs/accuracy.md` exists | AUTO | ⏳ B16 | |
| ENG-03 | Benchmark history | Runner probe | `eval/RESULTS.md` exists with dated rows | AUTO | ⏳ B16 | |
| ENG-04 | Insights code | Runner probe | An Insights view exists in Sources | AUTO | ⏳ B15 | |
| ENG-05 | Media pause code | Runner probe | Media pause / sounds / recording cap code exists | AUTO | ⏳ B12 | |
