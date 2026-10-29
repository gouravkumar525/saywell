# 08 · Vocabulary and learning

| ID | Scenario | Steps | Expected | Type | Status | Result |
|---|---|---|---|---|---|---|
| VOC-01 | Phonetic post-correction | Add "Kubernetes"; say "deploy on cooper netties" | Inserted `Kubernetes` | MANUAL | ✅ | |
| VOC-02 | Common words protected | Add "Ken"; say "I can do it tomorrow" | `can` is not changed to `Ken` | MANUAL | ✅ | |
| VOC-03 | Learn after 2 fixes | Dictate a misheard name; fix it within 10 s; repeat once | Pair appears under Dictionary ▸ learned candidates, then promoted | MANUAL | ✅ | |
| VOC-04 | Accept / Reject candidates | Dictionary tab ▸ pending | Accept adds the term; Reject removes the candidate and doesn't re-learn it immediately | MANUAL | ✅ | |
| VOC-05 | Contacts import | Dictionary ▸ Import Contacts | First and last names added; source shown | MANUAL | ✅ | |
| VOC-06 | Ranked hints (> 100 terms) | Add 150 terms; dictate in Slack | Log shows up to 100 hints, most-used and app-relevant first | MANUAL | ✅ | |
| VOC-07 | No learning outside the window | Fix a word 15 s after inserting | No candidate recorded | MANUAL | ✅ | |
| VOC-08 | No false learning | After inserting, type elsewhere in the doc (anchors change) | Watcher stops; no candidate | MANUAL | ✅ | |
| VOC-09 | Dictionary in the prompt and post-correction (bench) | `Bench/cases.tsv` "names" case | vet shows `→ inserted:` with `Kubernetes`, `Camila`, `LocalFlow` | AUTO | ✅ | |
| VOC-10 | Learn after 1 fix (non-common word) | Fix "Raghunathan" once | Promoted immediately | MANUAL | ⏳ B5 | |
| VOC-11 | Near-common word still needs 2 | Fix "Mira" (close to "mirror") once | Not yet promoted; promoted after the second fix | MANUAL | ⏳ B5 | |
| VOC-12 | On-screen names, off by default | Fresh install; a window shows "Anaya Raghunathan"; dictate the name | Not used (setting off) | MANUAL | ⏳ B11 | |
| VOC-13 | On-screen names, on | Turn on "Use names on screen for spelling"; repeat | Spelled correctly; names never written to the DB (check `dictionary` and `samples`) | MANUAL | ⏳ B11 | |
| VOC-14 | Screen names skip secure fields | Visible password field content | Never read | MANUAL | ⏳ B11 | |
