#!/usr/bin/env python3
"""Writes THIRD_PARTY_NOTICES.md: credits and full licence texts for the models
Saywell can download or bundle, and every Swift package compiled into the app
(read from Package.resolved and .build/checkouts). Re-run after changing
dependencies or models:  python3 Scripts/notices.py"""
import glob, json, os

root = os.path.join(os.path.dirname(__file__), "..")
checkouts = os.path.join(root, ".build", "checkouts")
resolved = json.load(open(os.path.join(root, "Package.resolved")))
# Build-time only (macros); not in the shipped binary, listed for completeness.
BUILD_ONLY = {"swift-syntax"}

MODELS = """## Models

### Parakeet TDT 0.6B v3 (speech recognition)
- Original model: NVIDIA, [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- Core ML conversion used by Saywell: FluidInference, [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml), revision `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`
- Licence: **Creative Commons Attribution 4.0 International (CC BY 4.0)**, https://creativecommons.org/licenses/by/4.0/
- Changes: converted to Core ML by FluidInference; Saywell uses the files unmodified.
- Downloaded on first use after you approve it, or bundled in packages built with `--with-model parakeet`.

### Qwen3-4B-Instruct-2507 (text cleanup)
- Original model: Alibaba Cloud Qwen team, [Qwen/Qwen3-4B-Instruct-2507](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507)
- 4-bit MLX conversion used by Saywell: [mlx-community/Qwen3-4B-Instruct-2507-4bit](https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit), revision `50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b`
- Licence: **Apache License 2.0**, https://www.apache.org/licenses/LICENSE-2.0 (the full text is also reproduced below under swift-transformers)
- Changes: quantised to 4 bits by mlx-community; a personal model made with "Improve My Model…" is a LoRA fine-tune of it and stays on your Mac.
- Downloaded on first use after you approve it, or bundled in packages built with `--with-model qwen3`.

## Code adapted from other projects

### Coucou (github.com/louis-cfm/coucou)
- Used for: the hold-key logic (`HoldKeyLogic`: double tap for hands-free, Esc), the
  time-saved formula in Insights, the voice-dot band math (`AudioBands`), the Notetaker's
  approach (system audio tap, echo removal, speaker merging), the Claude Code hook protocol
  (`AgentProtocol`), and the animation technique behind Sprig (pose numbers, keyframe
  tweens, state tables). Sprig's look and Saywell's code are original; Coucou's
  name, its Mochi character and its sounds are not used.
- Licence: **MIT**

```
MIT License

Copyright (c) 2026 Louis Raillé

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Speaker diarization (pyannote Community-1, Core ML) — Notes
- Original models: pyannote, [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1)
- Core ML conversion used by Saywell: FluidInference, [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml), revision `df2625ac79a7ac6b65ad868fee6d80f320da4232` (Segmentation, FBank, Embedding, PldaRho, plda-parameters.json)
- Licence: **Creative Commons Attribution 4.0 International (CC BY 4.0)**, https://creativecommons.org/licenses/by/4.0/ (see the repository's NOTICE.md for scope)
- Changes: converted to Core ML by FluidInference; Saywell uses the files unmodified.
- Downloaded after you approve it, the first time you record a call.

### Apple models
Apple's on-device speech recognizer and Foundation Model are part of macOS. Saywell
calls them through system frameworks and does not include or redistribute them.
"""

def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().strip()

out = ["# Third-party notices", "",
       "Saywell includes or downloads the following third-party software and models.",
       "Each is used under the licence shown; full licence texts follow.", "", MODELS,
       "## Software compiled into Saywell", "",
       "| Package | Version | Licence file |", "|---|---|---|"]
sections = []
for pin in sorted(resolved["pins"], key=lambda p: p["identity"]):
    ident = pin["identity"]
    version = pin["state"].get("version") or pin["state"].get("revision", "")[:10]
    folder = next((d for d in os.listdir(checkouts) if d.lower() == ident.lower()), None)
    if not folder:
        continue
    base = os.path.join(checkouts, folder)
    files = sorted(f for f in os.listdir(base) if f.upper().startswith(("LICENSE", "NOTICE", "COPYING")))
    vendored = []
    if ident == "mlx-swift":
        vendored = sorted(glob.glob(os.path.join(base, "Source/Cmlx/*/LICENSE*")))
    if ident == "fluidaudio":
        vendored = sorted(glob.glob(os.path.join(base, "ThirdPartyLicenses", "**", "*"), recursive=True))
        vendored = [v for v in vendored if os.path.isfile(v)]
    note = " (build tool only)" if ident in BUILD_ONLY else ""
    out.append(f"| [{folder}]({pin['location']}){note} | {version} | {', '.join(files)} |")
    body = [f"### {folder} {version}{note}", pin["location"], ""]
    for f in files:
        body += ["```", read(os.path.join(base, f)), "```", ""]
    for v in vendored:
        rel = os.path.relpath(v, base)
        body += [f"Bundled inside {folder}: `{rel}`", "", "```", read(v), "```", ""]
    sections.append("\n".join(body))

# FluidAudio's binary dependency (shipped inside its library).
out.append("| [text-processing-rs (NemoTextProcessing)](https://github.com/FluidInference/text-processing-rs) | 0.3.1 | Apache-2.0 (see FluidAudio's ThirdPartyLicenses) |")
out += ["", "## Licence texts", ""] + sections
dest = os.path.join(root, "THIRD_PARTY_NOTICES.md")
open(dest, "w").write("\n".join(out) + "\n")
print("wrote", os.path.normpath(dest), f"({len(sections)} packages)")
