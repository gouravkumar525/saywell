# 07 · Text insertion

| ID | Scenario | Steps | Expected | Type | Status | Result |
|---|---|---|---|---|---|---|
| INS-01 | AX write in a native app | Dictate into TextEdit | Log `inserted via accessibility`; read-back matches | E2E | ✅ | |
| INS-02 | Paste in browsers / Electron / terminals | Dictate into Chrome, Slack, VS Code, Terminal | Log `inserted via paste`; text correct | MANUAL | ✅ | |
| INS-03 | Clipboard restored | Copy "SENTINEL"; dictate into Slack; `pbpaste` | Prints `SENTINEL` | MANUAL | ✅ | |
| INS-04 | User copy during restore wins | Dictate, and copy something else immediately (< 250 ms) | Clipboard holds the user's copy, not the old item | MANUAL | ✅ | |
| INS-05 | Clipboard managers ignore dictations | Run Maccy or Raycast clipboard history; dictate via paste | Dictation isn't recorded (transient + concealed types) | MANUAL | ✅ | |
| INS-06 | Smart spacing after punctuation | Field: "See you Thursday?"; dictate "hold on I need to check my calendar first" | Result: `See you Thursday? Hold on…` (one space, capital) | E2E | ✅ | |
| INS-07 | Mid-sentence lowercase | Field: "I think that"; dictate "we should go" | `I think that we should go` (lowercase "we") | MANUAL | ✅ | |
| INS-08 | Space before following text | Caret before "world" in "hello world"; dictate "big" | `hello big world` | MANUAL | ✅ | |
| INS-09 | Target lock | Start in TextEdit, switch to Notes before stopping | Not pasted into Notes; "Copied — focus moved"; text on the clipboard | MANUAL | ✅ | |
| INS-10 | Electron AX tree | Dictate in VS Code or Slack | Context log shows a role (not `-`) after `AXManualAccessibility` | MANUAL | ✅ | |
| INS-11 | Per-app insert override | Set `insert.com.apple.TextEdit` = `paste` | TextEdit uses paste | MANUAL | ✅ | |
| INS-12 | Replace selection (dictation, not a command) | Select a word; dictate "replacement words here" | Selection replaced | MANUAL | ✅ | |
| INS-13 | Multi-line insert | Dictate a numbered list | Line breaks preserved in TextEdit, Slack (Shift-Enter behavior noted), Notes | MANUAL | ✅ | |
| INS-14 | Slow-app clipboard timing | Paste into Word or Teams 10× in a row | Never pastes the previous clipboard content; restore 500 ms (750 ms Electron) | MANUAL | ⏳ B8 | |
| INS-15 | Keep dictation on clipboard | Turn on "Keep dictation on clipboard"; dictate | Clipboard holds the dictation afterwards | MANUAL | ⏳ B8 | |
| INS-16 | Code probe: restore delay ≥ 0.5 s | Runner probe on `TextInserter.swift` | All `restoreAfter` values ≥ 0.5 | AUTO | ⏳ B8 | |
