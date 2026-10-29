# Accuracy decisions and the evidence for them

Each rule below is a decision Saywell's code depends on, with the measurement behind it,
so it can be re-checked when models or macOS change.

## Speech recognition

| Decision | Evidence | Where in the code |
|---|---|---|
| **Parakeet TDT v3 is the most accurate recognizer we have**, and is offered in Speech Recognizer ▸ Parakeet | 20 TTS clips (3 voices, names, jargon, numbers, code): Parakeet **6.1%** WER vs SpeechAnalyzer 10.1% vs SFSpeech 12.3%, measured in-app with `--bench-asr --asr all`. On long audio: 1.3% WER over 22 clips including 1- and 5-minute recordings | `ParakeetEngine.swift` |
| **SFSpeech stays the default until real-voice data agrees** | The bake-off uses synthetic voices. NEXT_STEPS B1 requires Parakeet to also beat SFSpeech on the **no-edit rate** from real use. The Speech Recognizer menu shows the no-edit rate per recognizer for this | `SessionController.speechBackend`, `Store.metrics(asr:)` |
| **Live words for a batch model come from agreement between two passes** | 5-minute simulated dictation: 847 of 863 words confirmed live, ~0.6% WER, final text 0.07 s after key-up | `WordAgreement` |
| **Words in the last 1 s of audio are never confirmed** | Without this hold-back, a live pass ended a sentence at the edge of the audio ("it has three." before "databases") and the window was cut there | `WordAgreement.update(holdBack:)` |
| **Cut the audio window halfway between two words, and drop a repeated boundary word** | Cutting at a word's end time produced "Sarah is is going" and "Thursday? Thursday" | `WordAgreement.cut`, `update` |
| **Up to 2 minutes, the final pass re-transcribes the whole recording** | A full pass of 48 s takes ~0.27 s and fixed the punctuation and a name ("Versera" → "Sarah") that the windowed passes got wrong | `ParakeetEngine.fullFinalPassSeconds` |
| **Streamed chunks are matched on words, not characters** | The final pass often only re-punctuates. Character matching threw away every streamed chunk | `SentenceSplitter.remainder` |
| **Never put filler words in recognizer hints** | Hints bias the recognizer toward the hinted words. Only dictionary terms are sent, ranked by use in the current app | `Store.rankedTerms` |
| **Vocabulary for Parakeet comes from phonetic post-correction** | Parakeet takes no `contextualStrings`. The G6 corrector turns "cooper netties" into Kubernetes for every recognizer | `VocabularyCorrector` |

## Cleanup

| Decision | Evidence | Where in the code |
|---|---|---|
| **Dictation is cleaned in chunks of ≤ 70 words** | Single requests are truncated above ~200 words on every model (Qwen3 ratio 0.57 at 496 words, 0.11 at 1,973). Chunked cleanup passes 100% up to 1,973 words | `SentenceSplitter.segments` |
| **Finished sentences are cleaned while you talk** | Key-up wait is 0.3–1.3 s at any length, vs. 28 s for 1,000 words cleaned in one go | `SessionController.streamTick` |
| **Every model output must keep every content word (light level)** | 50/50 bench accepted on Apple and Qwen3, with 0 answered questions and 0 obeyed injections. The check caught "doc" → "document" and answers | `Faithfulness.check`, `CleanupPrompt.vet` |
| **Numbers, money, times, emails and @handles are formatted by rules, not the model** | The model formatted them inconsistently ("three thirty" kept as words by Qwen3, "3:30" by Apple), and the rules-only fallback never did. The rules use the same number normaliser as the faithfulness check, so the two agree | `SpokenFormatting` |
| **Spoken repairs ("X, sorry, no, Y") are applied only when the restart reuses a recent word, or swaps a value for one of its kind** | Guessing restarts without an anchor drops real content ("we were sorry, no one came" must stay) | `SpokenFormatting.repairs` |
| **Writing-mode instructions can't add content** | Live test: an instruction to add a sign-off was (correctly) not followed. The guard and the base rules take priority, so modes are for formatting and tone | `CleanupPrompt.instructions(mode:)` |
| **Samples cleaned under a writing mode are excluded from fine-tuning** | Their custom instructions aren't part of the base prompt, so the pair would teach the base model the wrong thing | `Store.trainingFilter` |
| **A personal model replaces the base model only if it scores at least as well on the bench** | The smoke test fine-tune overfit (50/50 → 15/50) and the gate refused it | `Scripts/improve_model.sh` |

## Learning

| Decision | Evidence | Where in the code |
|---|---|---|
| **Names and jargon are learned after one fix; ordinary words after two** | A one-off change between ordinary words ("there" → "their") is often a rewrite rather than a misrecognition. A fix to an unknown word ("Kubernetes") is almost always a spelling the user wants | `Store.threshold(for:)` |
| **Common English words are never respelled into dictionary terms** | Guard list: ~210K lowercase words from `/usr/share/dict/words` | `CommonWords`, `VocabularyCorrector` |
| **On-screen names are hints for one dictation only** | They are useful for names visible in the thread. Storing them would quietly fill the dictionary with whatever was on screen | `ScreenNames`, `SessionController.screenHints` |

## Models

| Decision | Evidence | Where in the code |
|---|---|---|
| **Qwen3 4B is the only local model; Gemma 3 was removed (2026-10-20)** | Qwen3 50/50, 481 ms median; Gemma 3 50/50 but 1,470 ms and 3.5 GB vs. 2.3 GB. Gemma's licence adds terms; Qwen3 is Apache 2.0 | `CleanupEngine` |
| **Models are pinned to a revision and verified by SHA-256 before use** | It makes installs reproducible and stops a changed upstream repo from silently changing behaviour. Verifying 2.3 GB takes ~1 s | `ModelManifest`, `PinnedModels` |
