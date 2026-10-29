# LocalFlow Test Cases

This folder holds acceptance tests for everything LocalFlow does today (✅) and for the
features we still plan to build (⏳: the BetterWispr gap items B1–B16 in NEXT_STEPS.md).
Run the whole suite after every full build. The pending cases are already written, so
when a feature lands its tests are waiting for it.

These sit on top of the XCTest unit tests (`Scripts/test.sh`). The unit tests check
functions; these check the built app and its CLI the way a user experiences them.

## Layout

| Path | What |
|---|---|
| `01-build-install.md` … `12-ux-insights.md` | Test case catalog by area: ID, scenario, steps, expected, type, status, and a blank Result column |
| `data/rules.tsv` | Automated rules-cleanup cases (`--process`) |
| `data/cleanup.tsv` | Automated LLM-cleanup cases (`--clean`), run against each engine |
| `data/bench_extra.tsv` | Extra adversarial cases in the `Bench/cases.tsv` format (`--bench` + `--vet`) |
| `data/audio/` | Optional: put `name.aiff` or `name.wav` plus `name.txt` (reference text) here for `--simulate` capture tests |
| `data/asr/` | Optional: an ASR clip set (`--make-asr-set data/asr`, or your own recordings plus `.txt` files) for `--bench-asr` |
| `run_tests.py` | The runner. Python 3 standard library only |
| `run_tests.sh` | Wrapper: `./TestCases/run_tests.sh [options]` |
| `results/` | One Markdown report per run: auto results plus the manual checklist to fill in |

## Legend

**Type**
- **AUTO**: `run_tests.py` runs it with no human involved.
- **E2E**: needs the real app, the mic, and an unlocked screen. Run it with `--e2e`, which
  uses `Scripts/e2e_test.sh`, or follow the steps by hand.
- **MANUAL**: a person follows the steps and fills in the Result column.

**Status**
- ✅ = implemented; the test must pass.
- ⏳ Bx = not built yet (the item number in NEXT_STEPS.md); the test is expected to fail for now.

**Runner outcomes**

| Outcome | Meaning | What to do |
|---|---|---|
| PASS | Implemented and passing | Nothing |
| FAIL | Implemented but failing | A regression. Fix it before shipping |
| XFAIL | Pending and failing | Expected. The feature isn't built yet |
| XPASS | Pending but passing | The feature has landed. Change the case's status to `impl` in the TSV (or ✅ in the .md) |
| INFO | Informational output, not graded | Read it |
| SKIP | Missing prerequisite (no audio files, app not built, …) | Supply it, or ignore |

## How to run

```bash
cd ~/Documents/localWishpFlow

# Everything automated, against Apple FM + Qwen3 (builds first):
./TestCases/run_tests.sh --build

# Faster: skip the build and the unit tests, one engine:
./TestCases/run_tests.sh --skip-unit --engines qwen3

# Include the slow long-text benchmark and the live E2E (mic + speakers + unlocked screen):
./TestCases/run_tests.sh --long --e2e

# Only some suites:
./TestCases/run_tests.sh --only rules,cleanup,probes
```

Suites: `unit, signing, rules, cleanup, bench, long, training, gate, privacy, simulate,
asr, probes, status, e2e`.

Each run writes `TestCases/results/run-<date>-<time>.md`. That file holds every AUTO
result **plus a checklist of all E2E and MANUAL cases**. Work through the checklist and
commit the file, so there's a dated record of what was verified.

## Adding or updating cases

- **Rules or LLM case:** add a line to the TSV. Columns are explained in each file's
  header.
  - `must` and `must_not` hold `;;`-separated checks.
  - A plain check is a case-insensitive substring.
  - `re:` starts a regex (case-insensitive, multiline).
  - `=` starts an exact match.
- **Pending feature:** set `status` to `pending:B10` (for example). Change it to `impl`
  once the runner reports XPASS and you've confirmed the feature by hand.
- **Manual case:** add a row to the right `.md` table. Use the next free ID in that area,
  and keep `|` out of the cell text.

`results/example-probes-only.md` is a sample report from a probes-only dry run, made while
the folder was being set up. It isn't a real test result. Your first real run sits next
to it as `run-<date>-<time>.md`.
