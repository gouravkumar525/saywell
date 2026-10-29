# 05 · Rules cleanup (TextProcessor)

Rules run before the LLM and are the fallback whenever the model is off, not ready, or
rejected. Almost all of these are automated in `data/rules.tsv` (CLI `--process`).

| ID | Scenario | Steps | Expected | Type | Status | Result |
|---|---|---|---|---|---|---|
| RUL-01…03 | Filler removal without eating real words ("umbrella", "error") | `data/rules.tsv` | Exact outputs | AUTO | ✅ | |
| RUL-04…08 | Spoken corrections: "no, change that to", "scratch that", "I meant" | `data/rules.tsv` | Exact outputs | AUTO | ✅ | |
| RUL-09…13 | Layout: new line, new paragraph, numbered and bullet lists, single "number one" isn't a list | `data/rules.tsv` | Exact outputs | AUTO | ✅ | |
| RUL-14…17 | Punctuation and capitalization; stray commas; empty input | `data/rules.tsv` | Exact outputs | AUTO | ✅ | |
| RUL-18 | STATUS.md reference sentence | `data/rules.tsv` | `Hello team, let's meet on Tuesday` + list | AUTO | ✅ | |
| RUL-19…22 | Guards: "no", "sorry", and "one of them" must survive | `data/rules.tsv` | Words kept | AUTO | ✅ | |
| RUL-30…34 | Spoken numbers, money, percent, decimals, times | `data/rules.tsv` | `$25`, `10%`, `3.5`, `3:30 PM` | AUTO | ⏳ B10 | |
| RUL-35…36 | Email and handles: "at … dot com", "at the rate KV" | `data/rules.tsv` | `gourav@gmail.com`, `@KV` | AUTO | ⏳ B10 | |
| RUL-37…38 | Repairs: "sorry, no", "no wait" restarting on a recent word | `data/rules.tsv` | The repaired word only | AUTO | ⏳ B10 | |
| RUL-39 | Code-style spoken symbols in the rules path | `--clean` with a Terminal app (see LLM-09/10) | `-la`, `userName` | AUTO | ✅ | |
| RUL-40 | Off level gets the B10 rules too | `data/cleanup.tsv` LLM-19 | `$25` with the LLM off | AUTO | ⏳ B10 | |
