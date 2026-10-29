#!/bin/bash
# G7: fine-tune a personal cleanup model on your own dictations, then switch
# to it only if it scores at least as well as the current model.
#
#   improve_model.sh --app <Saywell binary> [--base <hf repo or dir>] [--out <models dir>]
#                    [--work <scratch dir>] [--venv ~/lf-mlx] [--iters 600] [--db <sqlite>]
#                    [--cases <bench cases.tsv>] [--keep 2]
#
# Prints progress, then exactly one line "RESULT switch <path>", "RESULT keep <why>",
# or "RESULT error <why>" for the app to act on.
set -uo pipefail

APP=""; BASE="mlx-community/Qwen3-4B-Instruct-2507-4bit"
OUT="$HOME/Library/Application Support/Saywell/models"
WORK="${TMPDIR:-/tmp}/saywell-train"; VENV="$HOME/lf-mlx"; ITERS=600; DB=""; KEEP=2
CASES="$(cd "$(dirname "$0")" && pwd)/cases.tsv"
[ -f "$CASES" ] || CASES="$(cd "$(dirname "$0")/.." && pwd)/Bench/cases.tsv"
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift ;; --base) BASE="$2"; shift ;; --out) OUT="$2"; shift ;;
    --work) WORK="$2"; shift ;; --venv) VENV="$2"; shift ;; --iters) ITERS="$2"; shift ;;
    --db) DB="$2"; shift ;; --cases) CASES="$2"; shift ;; --keep) KEEP="$2"; shift ;;
    *) echo "RESULT error unknown option $1"; exit 2 ;;
  esac
  shift
done
[ -x "$APP" ] || { echo "RESULT error Saywell binary not found ($APP)"; exit 2; }
if [ ! -x "$VENV/bin/mlx_lm.lora" ]; then
  echo "RESULT error mlx-lm not installed. Run: python3 -m venv $VENV && $VENV/bin/pip install -U mlx-lm"
  exit 2
fi
DBARG=(); [ -n "$DB" ] && DBARG=(--db "$DB")

STAMP=$(date +%Y%m%d-%H%M)
NEW="$OUT/saywell-personal-$STAMP"
rm -rf "$WORK"; mkdir -p "$WORK/data" "$OUT"

echo "== 1/5 export training data"
"$APP" "${DBARG[@]}" --export-training "$WORK/data/train.jsonl" --valid-split 0.1 || { echo "RESULT error export failed"; exit 1; }
TRAIN=$(wc -l < "$WORK/data/train.jsonl" | tr -d ' ')
VALID=$(wc -l < "$WORK/data/valid.jsonl" | tr -d ' ')
[ "$TRAIN" -ge 4 ] || { echo "RESULT keep only $TRAIN training lines"; exit 0; }
BATCH=4; [ "$TRAIN" -lt 4 ] && BATCH=$TRAIN
# mlx_lm.lora needs at least one batch of validation lines; top up small sets from train.
if [ "$VALID" -lt "$BATCH" ]; then
  head -n $((BATCH - VALID)) "$WORK/data/train.jsonl" >> "$WORK/data/valid.jsonl"
fi

echo "== 2/5 LoRA fine-tune ($TRAIN lines, $ITERS iters)"
"$VENV/bin/mlx_lm.lora" --model "$BASE" --train --data "$WORK/data" --mask-prompt \
  --iters "$ITERS" --batch-size "$BATCH" --num-layers 16 --learning-rate 1e-4 \
  --adapter-path "$WORK/adapters" --steps-per-report 10 --steps-per-eval 50 \
  || { echo "RESULT error training failed"; exit 1; }

echo "== 3/5 fuse into $NEW"
"$VENV/bin/mlx_lm.fuse" --model "$BASE" --adapter-path "$WORK/adapters" --save-path "$NEW" \
  || { echo "RESULT error fuse failed"; exit 1; }

echo "== 4/5 bench current vs new"
"$APP" --bench "$CASES" "$WORK/base.jsonl" --engine qwen3 --model "$BASE" >/dev/null || { echo "RESULT error base bench failed"; exit 1; }
"$APP" --bench "$CASES" "$WORK/new.jsonl" --engine qwen3 --model "$NEW" >/dev/null || { echo "RESULT error new bench failed"; exit 1; }

echo "== 5/5 gate"
if "$APP" --gate "$WORK/base.jsonl" "$WORK/new.jsonl"; then
  # Keep only the newest $KEEP personal models for rollback.
  ls -1d "$OUT"/saywell-personal-* 2>/dev/null | sort \
    | awk -v k="$KEEP" '{a[NR]=$0} END {for (i = 1; i <= NR - k; i++) print a[i]}' \
    | while read -r old; do rm -rf "$old"; done
  echo "RESULT switch $NEW"
else
  rm -rf "$NEW"
  echo "RESULT keep new model scored lower on the bench"
fi
