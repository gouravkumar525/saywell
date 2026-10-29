#!/usr/bin/env python3
"""LocalFlow acceptance test runner (Python 3 standard library only).

Runs every AUTO case in TestCases/, grades pending (⏳) cases as XFAIL/XPASS, and
writes TestCases/results/run-<timestamp>.md with the auto results plus a checklist
of all E2E and MANUAL cases from the .md catalogs.

    ./TestCases/run_tests.sh [--build] [--skip-unit] [--engines apple,qwen3]
                             [--long] [--e2e] [--only rules,cleanup,...]
"""
import argparse, datetime, difflib, glob, json, os, re, shutil, subprocess, sys, tempfile

TC = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TC)
DATA = os.path.join(TC, "data")
DEFAULT_BIN = os.path.join(ROOT, "build/LocalFlow.app/Contents/MacOS/LocalFlow")
ALL_SUITES = ["build", "unit", "signing", "rules", "cleanup", "bench", "long", "training", "gate",
              "privacy", "simulate", "asr", "probes", "status", "e2e"]

results = []   # dicts: id, suite, outcome, detail


# ---------------------------------------------------------------- helpers

def record(cid, suite, ok, detail="", pending=False, outcome=None):
    if outcome is None:
        outcome = ("XPASS" if ok else "XFAIL") if pending else ("PASS" if ok else "FAIL")
    detail = " ".join(str(detail).split())
    results.append({"id": cid, "suite": suite, "outcome": outcome, "detail": detail})
    print(f"  {outcome:5}  {cid:<14} {detail[:150]}")


def run(cmd, timeout=300, env=None):
    try:
        p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout,
                           env={**os.environ, **(env or {})})
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
        return 124, out, "timeout"
    except FileNotFoundError as e:
        return 127, "", str(e)


def read_tsv(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if not line.strip() or line.startswith("#"):
                continue
            rows.append(line.rstrip("\n").split("\t"))
    return rows


def unesc(s):
    return "" if s == "-" else s.replace("\\n", "\n").replace("\\t", "\t")


def checks(spec):
    return [c.strip() for c in unesc(spec).split(";;") if c.strip()] if spec not in ("-", "") else []


def matches(text, check):
    if check.startswith("re:"):
        return re.search(check[3:], text, re.IGNORECASE | re.MULTILINE) is not None
    if check.startswith("="):
        return text == unesc(check[1:])
    return check.lower() in text.lower()


def grade(text, must, must_not):
    missing = [c for c in checks(must) if not matches(text, c)]
    present = [c for c in checks(must_not) if matches(text, c)]
    if must.startswith("=") and must[1:] == "":   # exact empty
        missing = [] if text == "" else ["(empty)"]
    return not missing and not present, missing, present


def pending_of(status):
    return status.startswith("pending")


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def src_files(sub=""):
    return glob.glob(os.path.join(ROOT, "Sources", sub, "**", "*.swift"), recursive=True)


def need_bin(binpath, suite):
    if not os.path.exists(binpath):
        record(suite.upper() + "-bin", suite, False, f"app binary not found: {binpath} (build first)", outcome="SKIP")
        return False
    return True


# ---------------------------------------------------------------- suites

def suite_build(a):
    print("\n== build (BLD-01)")
    rc, out, err = run(["./Scripts/make_app.sh"], timeout=1800)
    ok = rc == 0 and "Built" in out
    metallib = os.path.isdir(os.path.join(ROOT, "build/LocalFlow.app/Contents/Resources/mlx-swift_Cmlx.bundle"))
    record("BLD-01", "build", ok and metallib, f"rc={rc} metallib-bundle={'yes' if metallib else 'no'} {(out + err)[-200:]}")


def suite_unit(a):
    print("\n== unit tests (BLD-02)")
    rc, out, err = run(["./Scripts/test.sh"], timeout=1800)
    text = out + err
    m = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", text)
    ok = "TEST SUCCEEDED" in text or (m and m[-1][1] == "0")
    record("BLD-02", "unit", bool(ok), (f"{m[-1][0]} tests, {m[-1][1]} failures" if m else text[-200:]))


def suite_signing(a):
    print("\n== signing (BLD-03)")
    app = os.path.join(ROOT, "build/LocalFlow.app")
    if not os.path.isdir(app):
        return record("BLD-03", "signing", False, "no build/LocalFlow.app", outcome="SKIP")
    rc, out, err = run(["codesign", "-dv", app])
    info = out + err
    auth = re.findall(r"Authority=(.*)", info)
    adhoc = "Signature=adhoc" in info
    ok = (not adhoc) and any("LocalFlow Dev" in x or "Developer ID" in x for x in auth)
    record("BLD-03", "signing", ok, f"authority={auth[:1]} adhoc={adhoc}")


def suite_rules(a):
    print("\n== rules (data/rules.tsv)")
    if not need_bin(a.bin, "rules"):
        return
    for r in read_tsv(os.path.join(DATA, "rules.tsv")):
        cid, status, inp, must, must_not = (r + ["-"] * 5)[:5]
        rc, out, err = run([a.bin, "--process", unesc(inp)], timeout=30)
        text = out[:-1] if out.endswith("\n") else out
        ok, missing, present = grade(text, must, must_not)
        detail = f"got {text!r}" + (f" missing={missing}" if missing else "") + (f" unwanted={present}" if present else "")
        record(cid, "rules", ok and rc == 0, detail, pending=pending_of(status))


def clean_final(out):
    if "FINAL: " not in out:
        return None, False
    final = out.split("FINAL: ", 1)[1].rstrip("\n")
    m = re.search(r"\s+\[fell back to rules: [^\]]*\]$", final)
    fell = bool(m)
    if m:
        final = final[:m.start()]
    return final, fell


def suite_cleanup(a):
    print("\n== cleanup (data/cleanup.tsv) engines=" + ",".join(a.engines))
    if not need_bin(a.bin, "cleanup"):
        return
    rows = read_tsv(os.path.join(DATA, "cleanup.tsv"))
    for engine in a.engines:
        for r in rows:
            cid, status, app, level, inp, must, must_not = (r + ["-"] * 7)[:7]
            cmd = [a.bin, "--clean", unesc(inp), "--level", level, "--engine", engine]
            if app != "-":
                cmd += ["--app", app]
            rc, out, err = run(cmd, timeout=600)
            final, fell = clean_final(out)
            if final is None:
                record(f"{cid}[{engine}]", "cleanup", False, f"no FINAL line rc={rc} {(out + err)[-160:]}",
                       pending=pending_of(status))
                continue
            ok, missing, present = grade(final, must, must_not)
            detail = f"{'(rules fallback) ' if fell else ''}got {final!r}" + \
                     (f" missing={missing}" if missing else "") + (f" unwanted={present}" if present else "")
            record(f"{cid}[{engine}]", "cleanup", ok, detail, pending=pending_of(status))


def vet_summary(text):
    return re.findall(r"^\s+(\S+): accepted (\d+)/(\d+), median (\d+)ms, max (\d+)ms", text, re.MULTILINE)


def suite_bench(a, workdir):
    print("\n== bench (Bench/cases.tsv + data/bench_extra.tsv)")
    if not need_bin(a.bin, "bench"):
        return
    sets = [("LLM-30", os.path.join(ROOT, "Bench/cases.tsv"), 1.0),
            ("LLM-31", os.path.join(DATA, "bench_extra.tsv"), 0.9)]
    for cid, path, threshold in sets:
        if not os.path.exists(path):
            record(cid, "bench", False, f"missing {path}", outcome="SKIP")
            continue
        for engine in a.engines:
            out_path = os.path.join(workdir, f"{cid}-{engine}.jsonl")
            rc, out, err = run([a.bin, "--bench", path, out_path, "--engine", engine], timeout=3600)
            mem = re.findall(r"memory: now (.*)", out)
            if rc != 0 or not os.path.exists(out_path):
                record(f"{cid}[{engine}]", "bench", False, f"bench failed rc={rc} {(out + err)[-160:]}")
                continue
            rc, vout, verr = run([a.bin, "--vet", out_path], timeout=300)
            summ = vet_summary(vout)
            if not summ:
                record(f"{cid}[{engine}]", "bench", False, f"no vet summary {vout[-160:]}")
                continue
            name, acc, tot, med, mx = summ[0]
            rate = int(acc) / max(int(tot), 1)
            rejects = [l.strip() for l in vout.splitlines() if "REJECT" in l][:3]
            record(f"{cid}[{engine}]", "bench", rate >= threshold,
                   f"accepted {acc}/{tot} (need ≥{threshold:.0%}) median {med}ms max {mx}ms; memory {mem[-1] if mem else '?'}"
                   + (f"; first rejects: {rejects}" if rejects else ""))
            if cid == "LLM-30":
                record(f"PRF-08[{engine}]", "bench", int(med) <= 1500, f"median {med}ms (need ≤1500)")
                if mem:
                    record(f"PRF-05[{engine}]", "bench", True, f"memory {mem[-1]}", outcome="INFO")


def suite_long(a):
    print("\n== long text (LLM-42 / PRF-03)")
    if not need_bin(a.bin, "long"):
        return
    for engine in a.engines:
        rc, out, err = run([a.bin, "--bench-long", "--engine", engine, "--words", "200,1000,2000"], timeout=3600)
        rows = re.findall(r"^(\d+) \| [^|]*\| [^|]*\| (\d+) \| [^|]*\| (\d+)/(\d+) \| (\d+) \|", out, re.MULTILINE)
        if not rows:
            record(f"LLM-42[{engine}]", "long", False, f"no result rows rc={rc} {(out + err)[-160:]}")
            continue
        all_ok = all(ok == n for _, _, ok, n, _ in rows)
        worst_last = max(int(last) for *_, last in rows)
        record(f"LLM-42[{engine}]", "long", all_ok,
               "; ".join(f"{w}w {ok}/{n} chunks last {last}ms" for w, _, ok, n, last in rows))
        record(f"PRF-03[{engine}]", "long", all_ok and worst_last <= 1300 * 2,
               f"worst last-chunk {worst_last}ms (target ≤1300; graded ≤2600 to allow first-load noise)")


def suite_training(a, workdir):
    print("\n== training export (TRN-05 / TRN-06)")
    if not need_bin(a.bin, "training"):
        return
    db = os.path.join(workdir, "scratch.sqlite")
    rc, out, err = run([a.bin, "--db", db, "--seed-demo-samples"], timeout=120)
    if rc != 0:
        return record("TRN-05", "training", False, f"seed failed rc={rc} {(out + err)[-160:]}")
    train = os.path.join(workdir, "lf-data", "train.jsonl")
    os.makedirs(os.path.dirname(train), exist_ok=True)
    rc, out, err = run([a.bin, "--db", db, "--export-training", train, "--valid-split", "0.2"], timeout=120)
    valid = os.path.join(os.path.dirname(train), "valid.jsonl")
    problems, lines = [], 0
    for p in (train, valid):
        for i, line in enumerate(read(p).splitlines()):
            lines += 1
            try:
                roles = [m["role"] for m in json.loads(line)["messages"]]
                if roles != ["system", "user", "assistant"]:
                    problems.append(f"{os.path.basename(p)}:{i + 1} roles={roles}")
            except Exception as e:  # noqa
                problems.append(f"{os.path.basename(p)}:{i + 1} {e}")
    record("TRN-05", "training", rc == 0 and lines > 0 and os.path.exists(valid) and not problems,
           f"{lines} lines; problems={problems[:3]}; {out.strip()[-160:]}")
    rej = os.path.join(workdir, "lf-data", "rejects.jsonl")
    rc, out, err = run([a.bin, "--db", db, "--export-rejects", rej], timeout=120)
    bad = 0
    rl = read(rej).splitlines()
    for line in rl:
        try:
            json.loads(line)
        except Exception:  # noqa
            bad += 1
    record("TRN-06", "training", rc == 0 and len(rl) > 0 and bad == 0, f"{len(rl)} lines, {bad} invalid")


def suite_gate(a, workdir):
    print("\n== model gate (MDL-02)")
    if not need_bin(a.bin, "gate"):
        return
    base = sorted(glob.glob(os.path.join(workdir, "LLM-30-*.jsonl")))
    if not base:
        return record("MDL-02", "gate", False, "needs the bench suite output (run with bench)", outcome="SKIP")
    rc, out, err = run([a.bin, "--gate", base[0], base[0]], timeout=60)
    record("MDL-02", "gate", rc == 0 and "switch" in out, out.strip()[-160:])


def suite_privacy(a):
    print("\n== privacy static scan (PRV-02 / PRV-03)")
    net = re.compile(r"URLSession|NWConnection|URLRequest|CFStream|socket\(|#hubDownloader|HubApi|HubClient")
    allowed = {"MLXCleanupClient.swift"}
    hits = []
    for f in src_files():
        for i, line in enumerate(read(f).splitlines()):
            if net.search(line) and not line.strip().startswith("//"):
                hits.append(f"{os.path.basename(f)}:{i + 1}")
    outside = [h for h in hits if h.split(":")[0] not in allowed]
    record("PRV-02", "privacy", not outside, f"network call sites: {hits or 'none'}; outside allow-list: {outside or 'none'}")
    app_path = [f for f in src_files("LocalFlow") if os.path.basename(f) not in ("CLI.swift", "EvalCLI.swift")]
    writers = [os.path.basename(f) for f in app_path if re.search(r"AVAudioFile\(\s*forWriting", read(f))]
    writers += [os.path.basename(f) for f in src_files("LocalFlowCore") if re.search(r"AVAudioFile\(\s*forWriting", read(f))]
    record("PRV-03", "privacy", not writers, f"audio writers in the app path: {writers or 'none'}")


def suite_simulate(a):
    print("\n== long capture via --simulate (ASR-02)")
    files = [f for f in glob.glob(os.path.join(DATA, "audio", "*"))
             if f.lower().endswith((".aiff", ".wav", ".m4a", ".caf"))]
    if not files:
        return record("ASR-02", "simulate", False, "no audio in TestCases/data/audio (add name.aiff + name.txt)", outcome="SKIP")
    if not need_bin(a.bin, "simulate"):
        return
    for f in files:
        ref = read(os.path.splitext(f)[0] + ".txt")
        rc, out, err = run([a.bin, "--simulate", f, "--speed", "1"], timeout=3600)
        hyp = (re.findall(r"^TRANSCRIPT: (.*)$", out, re.MULTILINE) or [""])[-1]
        norm = lambda s: re.sub(r"[^a-z0-9' ]", " ", s.lower()).split()
        r, h = norm(ref), norm(hyp)
        sm = difflib.SequenceMatcher(None, r, h, autojunk=False)
        matched = sum(b.size for b in sm.get_matching_blocks())
        recall = matched / max(len(r), 1)
        lag = re.findall(r"final arrived ([\d.]+)s", out)
        ok = recall >= 0.98 and (not lag or float(lag[-1]) <= 1.0)
        record(f"ASR-02[{os.path.basename(f)}]", "simulate", ok if ref else False,
               f"recall {recall:.1%} ({matched}/{len(r)} words), final lag {lag[-1] if lag else '?'}s" if ref else "no reference .txt",
               outcome=None if ref else "SKIP")


def suite_asr(a):
    print("\n== ASR clip bench (ASR-08 / ASR-12)")
    clips = [f for f in glob.glob(os.path.join(DATA, "asr", "*"))
             if f.lower().endswith((".aiff", ".wav", ".m4a", ".caf"))]
    if not clips:
        return record("ASR-08", "asr", False, "no clips in TestCases/data/asr (try: LocalFlow --make-asr-set TestCases/data/asr)", outcome="SKIP")
    if not need_bin(a.bin, "asr"):
        return
    rc, out, err = run([a.bin, "--bench-asr", os.path.join(DATA, "asr"), "--asr", "all"], timeout=3600)
    summ = re.findall(r"^\s+(\S+): WER ([\d.]+)%, dropped words ([\d.]+)%, mean (\d+) ms/clip", out, re.MULTILINE)
    if not summ:
        return record("ASR-08", "asr", False, f"no summary rc={rc} {(out + err)[-160:]}")
    wer = {n: float(w) for n, w, _, _ in summ}
    sf = next((v for k, v in wer.items() if "sf" in k.lower()), None)
    record("ASR-08", "asr", sf is not None and sf <= 12.3 * 1.25, f"WER by backend: {wer} (SFSpeech baseline 12.3%)")
    pk = next((v for k, v in wer.items() if "parakeet" in k.lower()), None)
    record("ASR-12", "asr", pk is not None and pk <= 6.5 and (sf is None or pk <= sf),
           f"parakeet WER {pk if pk is not None else 'not in app'}", pending=True)


def suite_probes(a):
    print("\n== feature probes for pending items (code presence; XPASS = go run the manual cases)")
    pkg = read(os.path.join(ROOT, "Package.swift"))
    allsrc = "\n".join(read(f) for f in src_files())
    core = "\n".join(read(f) for f in src_files("LocalFlowCore"))
    inserter = read(os.path.join(ROOT, "Sources/LocalFlow/TextInserter.swift"))
    settings = read(os.path.join(ROOT, "Sources/LocalFlow/SettingsWindow.swift"))
    ntests = sum(len(re.findall(r"func test\w*\(", read(f))) for f in glob.glob(os.path.join(ROOT, "Tests", "**", "*.swift"), recursive=True))
    delays = [float(x) for line in inserter.splitlines() if re.search(r"restoreAfter:\s*[^T]", line)
              for x in re.findall(r"\d+\.\d+", line.split("restoreAfter:", 1)[1])]
    probes = [
        ("ASR-17", "B1/B2", "FluidAudio" in pkg and re.search(r"[Aa]greement", allsrc) is not None, "FluidAudio dependency + word-agreement engine"),
        ("MDL-09", "B3", re.search(r"SHA256|sha256", allsrc) is not None and "localflow-installed" in allsrc, "SHA-256 + .localflow-installed marker"),
        ("INS-16", "B8", bool(delays) and min(delays) >= 0.5, f"clipboard restore delays {delays}"),
        ("MOD-06", "B9", re.search(r"websites?\s*:", core) is not None, "website/trigger mode type in LocalFlowCore"),
        ("ENG-05", "B12", re.search(r"MediaRemote|[Mm]ediaPause|maxRecording|recordingCap", allsrc) is not None, "media pause / recording cap"),
        ("BLD-14", "B13", "Sparkle" in pkg, "Sparkle dependency"),
        ("ENG-04", "B15", "Insights" in settings or re.search(r"class \w*Insights", allsrc) is not None, "Insights view"),
        ("ENG-01", "B16", ntests >= 150, f"{ntests} XCTest functions (need ≥150)"),
        ("ENG-02", "B16", os.path.exists(os.path.join(ROOT, "docs/accuracy.md")), "docs/accuracy.md"),
        ("ENG-03", "B16", os.path.exists(os.path.join(ROOT, "eval/RESULTS.md")), "eval/RESULTS.md"),
    ]
    for cid, item, ok, desc in probes:
        record(cid, "probes", ok, f"{item}: {desc}", pending=True)


def suite_status(a):
    print("\n== permission status (PRM-05, informational)")
    if not need_bin(a.bin, "status"):
        return
    rc, out, err = run([a.bin, "--status"], timeout=30)
    record("PRM-05", "status", rc == 0, out.strip().replace("\n", "; ") or err, outcome="INFO" if rc == 0 else "FAIL")


def suite_e2e(a):
    print("\n== live E2E via Scripts/e2e_test.sh (needs mic, speakers, unlocked screen)")
    if not need_bin(a.bin, "e2e"):
        return
    engine = a.engines[-1]
    rc, out, err = run(["./Scripts/e2e_test.sh", engine], timeout=900)
    with open(os.path.join(TC, "results", "last-e2e.txt"), "w") as f:
        f.write(out + err)
    blocks = {}
    for m in re.finditer(r"^== (\w+)\n(.*?)(?=^== |\Z)", out, re.MULTILINE | re.DOTALL):
        blocks[m.group(1)] = m.group(2)
    field = lambda name: (re.findall(r"field : (.*)", blocks.get(name, "")) or [""])[0]
    exp = {
        "basic": ("HK-01", "tuesday ;; budget", "re:\\bum\\b ;; re:\\buh\\b ;; the the"),
        "spacing": ("INS-06", "re:Thursday\\? Hold", "-"),
        "question": ("LLM-39", "tokyo", "re:Notes:.*Notes: ;; re:\\b\\d{1,2}:\\d{2}\\b"),
        "long": ("ASR-01", "sarah ;; profile service", "-"),
    }
    for name, (cid, must, must_not) in exp.items():
        if name not in blocks:
            record(cid, "e2e", False, f"case '{name}' missing from e2e output (rc={rc})")
            continue
        ok, missing, present = grade(field(name), must, must_not)
        record(cid, "e2e", ok, f"field={field(name)!r} missing={missing} unwanted={present}")
    record("PRF-04", "e2e", True, f"memory {blocks.get('memory', '').strip()[:120]} "
           "(the model is loaded right after E2E; check idle <80 MB by hand after unload, see MDL-01)", outcome="INFO")
    sockets = blocks.get("sockets", "")
    lines = [l for l in sockets.splitlines() if l.strip() and "expect none" not in l]
    record("PRV-01", "e2e", not lines, f"sockets: {lines or 'none'}")
    fb = re.findall(r"first buffer (\d+)\s*ms", out)
    record("PRF-07", "e2e", bool(fb) and max(map(int, fb)) < 80, f"first buffer ms: {fb or 'not logged'}")


# ---------------------------------------------------------------- report

def manual_checklist():
    rows = []
    for md in sorted(glob.glob(os.path.join(TC, "[0-9][0-9]-*.md"))):
        for line in read(md).splitlines():
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) >= 6 and re.match(r"^[A-Z]{2,4}-\d+", cells[0]) and cells[4] in ("E2E", "MANUAL", "AUTO+MANUAL"):
                rows.append((os.path.basename(md), cells[0], cells[1], cells[4], cells[5]))
    return rows


def write_report(a, started):
    os.makedirs(os.path.join(TC, "results"), exist_ok=True)
    stamp = started.strftime("%Y%m%d-%H%M")
    path = os.path.join(TC, "results", f"run-{stamp}.md")
    counts = {}
    for r in results:
        counts[r["outcome"]] = counts.get(r["outcome"], 0) + 1
    rc, sha, _ = run(["git", "rev-parse", "--short", "HEAD"], timeout=10)
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"# LocalFlow test run {started:%Y-%m-%d %H:%M}\n\n")
        f.write(f"- Engines: {', '.join(a.engines)}\n- Suites: {', '.join(a.suites)}\n")
        f.write(f"- Commit: {sha.strip() if rc == 0 else 'n/a'}\n- Binary: `{a.bin}`\n")
        f.write("- Totals: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) + "\n\n")
        f.write("## Automated results\n\n| Outcome | ID | Suite | Detail |\n|---|---|---|---|\n")
        order = {"FAIL": 0, "XPASS": 1, "PASS": 2, "XFAIL": 3, "INFO": 4, "SKIP": 5}
        for r in sorted(results, key=lambda r: (order.get(r["outcome"], 9), r["id"])):
            d = r["detail"].replace("|", "/")[:300]
            f.write(f"| {r['outcome']} | {r['id']} | {r['suite']} | {d} |\n")
        f.write("\n## Manual / E2E checklist\n\nMark each one ✅ pass, ❌ fail (with a note), or ➖ n/a. "
                "⏳ rows are expected to fail until their feature is built.\n\n"
                "| File | ID | Scenario | Type | Status | Result | Notes |\n|---|---|---|---|---|---|---|\n")
        for md, cid, scen, typ, status in manual_checklist():
            f.write(f"| {md} | {cid} | {scen} | {typ} | {status} | | |\n")
    return path, counts


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bin", default=DEFAULT_BIN)
    ap.add_argument("--engines", default="apple,qwen3", help="comma-separated: apple,qwen3,gemma3")
    ap.add_argument("--only", default="", help="comma-separated suites: " + ",".join(ALL_SUITES))
    ap.add_argument("--build", action="store_true", help="run Scripts/make_app.sh first")
    ap.add_argument("--skip-unit", action="store_true")
    ap.add_argument("--long", action="store_true", help="include the slow --bench-long suite")
    ap.add_argument("--e2e", action="store_true", help="include the live E2E (mic + speakers + unlocked screen)")
    ap.add_argument("--keep", action="store_true", help="keep the scratch directory")
    a = ap.parse_args()
    a.engines = [e.strip() for e in a.engines.split(",") if e.strip()]
    if a.only:
        a.suites = [s.strip() for s in a.only.split(",") if s.strip()]
    else:
        a.suites = [s for s in ALL_SUITES if s not in ("build", "long", "e2e")]
        if a.build: a.suites.insert(0, "build")
        if a.skip_unit: a.suites.remove("unit")
        if a.long: a.suites.append("long")
        if a.e2e: a.suites.append("e2e")
    started = datetime.datetime.now()
    workdir = tempfile.mkdtemp(prefix="localflow-tests-")
    print(f"LocalFlow tests — suites: {', '.join(a.suites)} — engines: {', '.join(a.engines)}\nscratch: {workdir}")
    table = {
        "build": lambda: suite_build(a), "unit": lambda: suite_unit(a), "signing": lambda: suite_signing(a),
        "rules": lambda: suite_rules(a), "cleanup": lambda: suite_cleanup(a), "bench": lambda: suite_bench(a, workdir),
        "long": lambda: suite_long(a), "training": lambda: suite_training(a, workdir), "gate": lambda: suite_gate(a, workdir),
        "privacy": lambda: suite_privacy(a), "simulate": lambda: suite_simulate(a), "asr": lambda: suite_asr(a),
        "probes": lambda: suite_probes(a), "status": lambda: suite_status(a), "e2e": lambda: suite_e2e(a),
    }
    for s in a.suites:
        if s not in table:
            print(f"unknown suite {s}"); continue
        try:
            table[s]()
        except Exception as e:  # keep going; record the crash
            record(f"{s.upper()}-crash", s, False, f"runner error: {e!r}")
    path, counts = write_report(a, started)
    if not a.keep:
        shutil.rmtree(workdir, ignore_errors=True)
    print("\n== summary: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    print(f"report: {path}")
    if counts.get("XPASS"):
        print("XPASS: a pending feature now passes — confirm it and flip its status to impl / ✅.")
    sys.exit(1 if counts.get("FAIL") else 0)


if __name__ == "__main__":
    main()
