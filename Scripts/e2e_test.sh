#!/bin/bash
# Live end-to-end test: real app, real mic (speech played through the speakers
# with `say`), real insertion into a throwaway test window. Needs an unlocked
# screen, the granted permissions, and the speaker volume up.
#   Scripts/e2e_test.sh [engine] [recognizer]   (apple | qwen3; apple | parakeet)
set -uo pipefail
cd "$(dirname "$0")/.."
APP=build/Saywell.app; BIN=$APP/Contents/MacOS/Saywell; ENGINE="${1:-qwen3}"; ASR="${2:-apple}"
OUT=$(mktemp -d)/e2e; mkdir -p "$OUT"; LOG=~/Library/Logs/Saywell.log
mark() { wc -l < "$LOG" | tr -d ' '; }
since() { tail -n +"$1" "$LOG"; }

pkill -x Saywell; sleep 1
open "$APP" --args --enable-test-control; sleep 4
"$BIN" --control "engine:$ENGINE"; "$BIN" --control level:light; "$BIN" --control "asr:$ASR"; sleep 6
"$BIN" --control "addmode:E2E Email|email mode|Put each sentence on its own line."

run_case() {  # name, seed text in window, spoken text
  local name="$1" seed="$2" speech="$3" start
  start=$(mark)
  LF_TEST_SEED="$seed" "$BIN" --test-window 40 "$OUT/$name.txt" > /dev/null &
  local win=$!; sleep 3
  "$BIN" --control toggle; sleep 1.2
  say -v Samantha "$speech"
  sleep 1.5; "$BIN" --control toggle
  wait $win
  echo "== $name"
  echo "   spoke : $speech"
  echo "   field : $(cat "$OUT/$name.txt")"
  since "$start" | grep -E "first buffer|final:|llm\\[|vocab:|insert|training: sample|stream:|parakeet:|asr:|mode:" | sed 's/^\[[^]]*\] /   log   : /' | cut -c1-200
}

run_case basic "" "um so I think we should uh meet on Tuesday and talk about the the budget"
run_case spacing "See you Thursday?" "hold on I need to check my calendar first"
run_case question "Notes: " "what time is it in Tokyo right now"
run_case long "" "So I wanted to give everyone a quick update on the migration. We moved the billing service last week and it has been stable. The one thing that came up is the nightly export job was running twice. Next week we plan to move the profile service. Sarah will own the database part and I will handle the traffic switch."

run_case numbers "" "the invoice is twenty five dollars sorry no thirty dollars and it is due at five thirty pm"
run_case email "" "please email gourav at gmail dot com about the ten percent discount"
run_case mode "" "email mode hi John the report is ready for review"
"$BIN" --control "removemode:E2E Email"

"$BIN" --control memory; sleep 1
echo "== memory"; grep "memory:" "$LOG" | tail -1 | sed 's/^/   /'
echo "== sockets (expect none)"; lsof -nP -i -a -p "$(pgrep -x Saywell)" 2>/dev/null | tail -n +2 | sed 's/^/   /' || true
echo "outputs in $OUT"
