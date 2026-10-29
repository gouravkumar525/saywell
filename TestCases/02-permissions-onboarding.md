# 02 · Permissions and onboarding

| ID | Scenario | Steps | Expected | Type | Status | Result |
|---|---|---|---|---|---|---|
| PRM-01 | Mic + speech prompts on first launch | `tccutil reset All com.gourav.localflow`; launch; click Allow | Launch log shows `mic=3 speech=3` | MANUAL | ✅ | |
| PRM-02 | No Accessibility permission | Remove LocalFlow from Accessibility; dictate in TextEdit | Text left on the clipboard; pill says "On clipboard — press ⌘V"; nothing typed | MANUAL | ✅ | |
| PRM-03 | No Input Monitoring permission | Remove from Input Monitoring; hold Fn | Fn does nothing; ⌃⌥D and clicking the pill still work; menu shows a hint | MANUAL | ✅ | |
| PRM-04 | Permission granted while the app runs | Grant Accessibility with the app open | Within ~2 s the log shows `hotkey: Fn tap installed`; Fn works without relaunching | MANUAL | ✅ | |
| PRM-05 | Status CLI | `LocalFlow --status` | Prints mic, speech, accessibility, recognizer, on-device, notch (for the calling process) | AUTO | ✅ | |
| PRM-06 | Contacts permission only when importing | Click Contacts import in the Dictionary tab | Contacts prompt appears only then; declining leaves the dictionary unchanged | MANUAL | ✅ | |
| ONB-01 | Onboarding on first launch | Delete the `onboarding.done` setting (or use a fresh account); launch | Onboarding window opens | MANUAL | ✅ | |
| ONB-02 | Steps turn green live | Grant each permission from its onboarding step | Each step turns green without restarting the app | MANUAL | ✅ | |
| ONB-03 | Model choice step | Pick Apple, then Qwen3 | Apple is instant; Qwen3 asks for download consent and shows progress | MANUAL | ✅ | |
| ONB-04 | "Try it" box | Hold Fn in the onboarding text box and speak | Text appears in the onboarding box, not in another LocalFlow-signed process (fix #7) | MANUAL | ✅ | |
| ONB-05 | Two-minute target | A new user starts with a stopwatch | First successful Slack dictation in < 2 min | MANUAL | ✅ | |
| ONB-06 | Reopen onboarding | Use the menu item that reopens setup | Onboarding opens and reflects the current permission state | MANUAL | ✅ | |
| ONB-07 | Fn key system setting hint | Onboarding Input Monitoring step | Tells the user to set "Press 🌐 key to" = Do Nothing | MANUAL | ✅ | |
