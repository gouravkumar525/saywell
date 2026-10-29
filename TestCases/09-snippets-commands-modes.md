# 09 · Snippets, command mode, undo, modes

| ID | Scenario | Steps | Expected | Type | Status | Result |
|---|---|---|---|---|---|---|
| SNP-01 | Inline snippet | Add "my calendar link" → `https://cal.com/gourav/30min`; say "here is my calendar link" | URL inserted verbatim inside the sentence | MANUAL | ✅ | |
| SNP-02 | Longest trigger wins | Snippets "my email" and "my work email"; say "send it to my work email" | Work email expansion used | MANUAL | ✅ | |
| SNP-03 | LLM can't alter an expansion | Expansion `LoCaL-123 Main St.`; Full level | Expansion exact, casing kept | MANUAL | ✅ | |
| SNP-04 | Token dropped → safe fallback | Unit test `testSnippetRestoreFailsWhenTokenDropped` | Rules text with the expansion restored | AUTO | ✅ | |
| SNP-05 | Case-insensitive trigger | Say "My Calendar Link" | Expanded | MANUAL | ✅ | |
| CMD-01 | Make formal | Select "hey whats up can u send the file"; say "make this more formal" | Selection replaced with a formal version | MANUAL | ✅ | |
| CMD-02 | Bullets | Select a paragraph; "turn this into bullet points" | Bulleted list replaces it | MANUAL | ✅ | |
| CMD-03 | Fix grammar | Select text with errors; "fix the grammar" | Corrected; meaning kept | MANUAL | ✅ | |
| CMD-04 | Translate | Select an English sentence; "translate to Spanish" | Spanish replaces it | MANUAL | ✅ | |
| CMD-05 | Not a command | Select text; say "we should fix the login page" | Treated as dictation (replaces the selection with that sentence) | MANUAL | ✅ | |
| CMD-06 | Long utterance isn't a command | Select text; say a > 15-word sentence that starts with "make" | Treated as dictation | MANUAL | ✅ | |
| CMD-07 | Undo to raw (hotkey) | Dictate a messy sentence at Full; press ⌃⌥Z | Polished text replaced by the rules version; log `undo-to-raw`; sample `label=bad` | E2E | ✅ | |
| CMD-08 | Undo via the pill | Click "Raw" in the pill right after an insert | Same as CMD-07 | MANUAL | ✅ | |
| CMD-09 | Undo after a command | After CMD-01, press ⌃⌥Z | Original selection text restored | MANUAL | ✅ | |
| CMD-10 | Undo with nothing to undo | ⌃⌥Z at launch | No change; no crash | MANUAL | ✅ | |
| MOD-01 | Website mode | Mode `mail.google.com/mail` = formal; dictate in Gmail (Chrome and Safari) | Formal output; other sites unaffected | MANUAL | ⏳ B9 | |
| MOD-02 | Subdomain and path matching | Mode `github.com`; dictate on `gist.github.com` and `github.com/org/repo` | Both match; `notgithub.com` doesn't | MANUAL | ⏳ B9 | |
| MOD-03 | Trigger word | Mode trigger "email mode"; say "email mode thanks for the update" | Trigger stripped; mode applied | MANUAL | ⏳ B9 | |
| MOD-04 | Precedence | App mode = casual, website mode = formal, trigger = code | Trigger > website > app > default | MANUAL | ⏳ B9 | |
| MOD-05 | URL read only when needed | No website modes defined; dictate in Chrome | No AX URL read (log) | MANUAL | ⏳ B9 | |
| MOD-06 | Code probe: modes | Runner probe | A website-mode type exists in LocalFlowCore | AUTO | ⏳ B9 | |
