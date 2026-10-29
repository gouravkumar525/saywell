# 03 · Hotkeys and session control

| ID | Scenario | Steps | Expected | Type | Status | Result |
|---|---|---|---|---|---|---|
| HK-01 | ⌃⌥D toggle | Focus TextEdit; ⌃⌥D; speak; ⌃⌥D | Cleaned text inserted; log shows `trigger=toggle` | E2E | ✅ | |
| HK-02 | Hold Fn push-to-talk | Hold Fn ≥ 0.3 s while speaking; release | Text inserted on release; `trigger=push` | MANUAL | ✅ | |
| HK-03 | Fn tap cancels | Tap Fn < 0.3 s | No insert; log `session cancelled` | MANUAL | ✅ | |
| HK-04 | Fn shortcuts still work | Hold Fn and press an arrow key or F-key | Dictation cancels; the Fn shortcut does its normal action | MANUAL | ✅ | |
| HK-05 | Disable Fn | Menu ▸ Hold Fn to Talk off; hold Fn | Nothing happens; ⌃⌥D still works; setting persists after relaunch | MANUAL | ✅ | |
| HK-06 | Click the pill | Click the notch pill, speak, click again | Same as HK-01 | MANUAL | ✅ | |
| HK-07 | Auto-stop | Menu ▸ Auto-Stop 5 s; ⌃⌥D; speak; stay silent | Stops ≈ 5 s after the last speech and inserts; `auto-stop after 5s` logged | MANUAL | ✅ | |
| HK-08 | No stale callbacks | Start a long dictation, stop, then immediately start and stop a short one | Only each session's own text is inserted, in order; nothing duplicated | MANUAL | ✅ | |
| HK-09 | Password field refused | Focus a password field (Safari login); ⌃⌥D | Pill: "Won't dictate into a password field"; no audio, no sample | MANUAL | ✅ | |
| HK-10 | ⌃⌥Z registered | Press ⌃⌥Z after a dictation | Undo-to-raw runs (see CMD-07) | MANUAL | ✅ | |
| HK-11 | Hotkey not swallowed when idle | With no dictation running, type ⌃⌥Z or ⌃⌥D in an app that uses them | Document behavior: LocalFlow owns these globally (Carbon); confirm there's no conflict in your daily apps | MANUAL | ✅ | |
| HK-12 | Recording cap | Dictate for 10 min | Countdown in the pill for the last 30 s; stops and inserts at 10:00 | MANUAL | ⏳ B12 | |
