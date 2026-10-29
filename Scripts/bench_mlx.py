#!/usr/bin/env python3
"""Run an MLX model over LocalFlow's exact cleanup prompts (NEXT_STEPS Phase B).

    LocalFlow --dump-prompts Bench/cases.tsv > prompts.jsonl
    ~/lf-mlx/bin/python Scripts/bench_mlx.py MODEL prompts.jsonl results.jsonl [engine-name]
    LocalFlow --vet results.jsonl apple.jsonl ...

Greedy decoding, like the app. The first case doubles as warm-up and is run twice;
only the second timing is kept, so numbers reflect a model that's already loaded.
"""
import json
import sys
import time

import mlx.core as mx
from mlx_lm import generate, load
from mlx_lm.sample_utils import make_sampler


def main() -> None:
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    model_id, prompts_path, out_path = sys.argv[1:4]
    engine = sys.argv[4] if len(sys.argv) > 4 else model_id.split("/")[-1]

    started = time.perf_counter()
    model, tokenizer = load(model_id)
    load_s = time.perf_counter() - started
    sampler = make_sampler(temp=0.0)

    cases = [json.loads(line) for line in open(prompts_path) if line.strip()]
    results = []
    for i, case in enumerate(cases):
        messages = [{"role": "system", "content": case["system"]},
                    {"role": "user", "content": case["user"]}]
        prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
        # Output can't legitimately be much longer than the input.
        max_tokens = max(48, len(case["rules"].split()) * 3 + 24)
        for attempt in range(2 if i == 0 else 1):
            t0 = time.perf_counter()
            output = generate(model, tokenizer, prompt=prompt, max_tokens=max_tokens, sampler=sampler)
            ms = int((time.perf_counter() - t0) * 1000)
        output = output.strip()
        print(f"{case['id']}: {ms}ms  {output!r}", file=sys.stderr)
        results.append({"id": case["id"], "engine": engine, "rules": case["rules"],
                        "level": case["level"], "output": output, "ms": ms})

    with open(out_path, "w") as f:
        for r in results:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"{engine}: load {load_s:.1f}s, peak memory {mx.get_peak_memory() / 2**30:.2f} GB, "
          f"{len(results)} results → {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
