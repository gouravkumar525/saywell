# Saywell Privacy

Saywell keeps speech recognition and AI cleanup on your Mac. This page lists what it
stores and how you can check for yourself that it works offline.

## What never leaves your Mac

| Data | Where it goes | How long it stays |
|---|---|---|
| Microphone audio | Memory only. It goes either to Apple's on-device recognizer (`requiresOnDeviceRecognition`) or to Parakeet, which runs inside Saywell on the Neural Engine. **Never written to disk.** With "Keep Mic Ready" on, the last 0.5 s stays in a memory ring buffer, which is overwritten continuously. | Until the dictation ends |
| Call recordings (Notes, only when you click Record a Call) | Your mic and what the Mac plays are written as 16 kHz WAV files to `~/Library/Application Support/Saywell/Notes/<id>/` while the call records, then transcribed on this Mac with Parakeet and the speaker model. **The audio is deleted as soon as the transcript is written.** The transcript, summary and to-dos stay in the database until you delete the note. No bot joins the call: tell the other people you're recording | Audio: until the transcript is written. Notes: until you delete them |
| Claude Code events (only after you connect it in Settings ▸ Agents) | Claude Code's hook helper sends each event (project folder, tool name, the command or file it's about to touch) to Saywell over a local Unix socket. Kept in memory to show sessions and approval cards; never stored | Memory |
| Text context | Up to 400 characters before the cursor and 20 after, read through Accessibility from the focused field. **No screenshots.** | Memory, for one dictation |
| On-screen names (off by default) | With "Use Names on Screen for Spelling" on, up to 2,000 characters of the focused window's visible text are read through Accessibility, skipping password fields. Only names and jargon are kept, as spelling hints. **No OCR, no screenshots.** The hints are not saved with history or training samples. | Memory, for one dictation |
| Browser address | Read through Accessibility only when a writing mode lists a website, to pick the mode | Memory, for one dictation |
| AI cleanup | Apple Foundation Models (on-device), or the local Qwen3 model run by MLX in the app's own process | — |
| History and training samples | `~/Library/Application Support/Saywell/saywell.sqlite` | Training samples: 30 / 90 / 365 days or forever (Settings ▸ Training). History: until you delete it |
| Logs | `~/Library/Logs/Saywell.log`. Logs contain dictated text, for debugging, so delete them if that's a concern | Until you delete them |

**Never stored:**
- Password fields (secure text fields), which Saywell also refuses to dictate into.
- Apps on the deny list. The defaults are 1Password, Bitwarden, Keychain Access, Passwords,
  LastPass, Enpass and Dashlane. Edit the list in Settings ▸ Privacy.
- Text that only reached the clipboard.

**Delete everything:** go to Settings ▸ Privacy ▸ Delete All History…. This removes history and
training samples and vacuums the database. To also clear the log, run
`rm ~/Library/Logs/Saywell.log`.

## Network use

Saywell uses the network for two things, and only after you've said yes to each:

1. **Model downloads.** This covers Qwen3 (~2.3 GB) for cleanup,
   Parakeet v3 (~460 MB) for speech recognition and the speaker model (~22 MB, pyannote
   Community-1, for telling voices apart in Notes), all from `huggingface.co`.
   - **Approval:** choosing a model that isn't downloaded yet shows a confirmation dialog. At
     launch, Saywell loads models from disk only and never fetches anything.
   - **Pinned and verified:** each model is pinned to one revision, and every file's size
     and SHA-256 are checked before it's used. A model counts as installed only after a
     test run passes; a failed download is deleted.
   - **Logging:** every download is written to the log as
     `network: downloading <model>@<revision> from huggingface.co (user approved)`.
   - **Offline installs:** the shareable package can include the model (see INSTALL.md),
     so no download is needed at all.
2. **Update checks (only in builds published with updates).** Such builds check the
   appcast URL in their `Info.plist` (`SUFeedURL`) through Sparkle. Updates are signed
   (EdDSA) and verified before they install. Self-built and self-signed packages have no
   feed, so they never check.

**Claude Code (Settings ▸ Agents)** talks to Saywell over a Unix domain socket at
`~/Library/Application Support/Saywell/agent.sock`. It isn't a network socket: the file is
readable only by you (0600, in a 0700 folder), and Saywell checks that every connection comes
from your own user. Connecting writes Saywell's hooks into `~/.claude/settings.json` only
after you confirm a preview, and keeps a timestamped backup; Disconnect removes only Saywell's
entries.

**Auto-Record Meetings** (menu, off unless you turn it on) checks every 2 s which apps are
using the microphone, from Core Audio's process list (app identifiers only, no audio), to notice
when Zoom, Teams or Webex starts and ends a meeting.

**System Audio Recording** (asked by macOS the first time you record a call) lets Saywell
hear what your Mac plays, only while a call is being recorded.

**Pause Music While Dictating** (off by default) sends Apple Events to Music or Spotify on
this Mac. macOS asks you for permission the first time. Nothing goes over the network.

Apple's own components (the speech recognizer and Foundation Models) are system frameworks.
macOS may update their on-device assets in the background, the same way it does for Siri
dictation.

## Verify it yourself

1. **Watch the sockets.** While dictating, run:
   ```bash
   lsof -i -a -p $(pgrep -x Saywell)
   ```
   No output means the app has no network connections open. (The Claude Code socket is a
   local Unix socket, so it doesn't appear here; `lsof -U -a -p $(pgrep -x Saywell)` lists it.)
2. **Use a firewall.** In Little Snitch or LuLu, deny all connections for Saywell, then
   dictate. Everything keeps working. The only thing that fails is a model download you
   start yourself.
3. **Turn on Airplane mode.** Turn off Wi-Fi and dictate. Recognition and cleanup are
   unaffected.
4. **Check the code.** Find the networking code with
   `grep -rn "hubDownloader\|URLSession\|SPUStandardUpdaterController" Sources/`:
   - `PinnedModels.download`, which is gated by `allowDownload`.
   - The Hugging Face downloader in `MLXCleanupClient.load`. It is used only for a custom,
     unpinned model you set yourself, and is gated the same way.
   - `Updater`, which is inactive without a feed URL.

## Training data

Fine-tuning ("Improve My Model…") runs locally with `mlx_lm.lora`, and your samples never
leave the Mac. Turn capture off in Settings ▸ Training ▸ "Save dictations for training".
