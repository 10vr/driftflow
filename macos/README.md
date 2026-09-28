# Driftflow

A fast, private dictation app for Apple Silicon Macs. Hold a key, speak, and let go: your words appear in whatever app you're typing in. Everything runs on the Mac's Neural Engine, and no audio or text ever leaves it.

## Performance (M5, macOS 26.6)

| | Driftflow |
|---|---|
| First live text on screen | **0.38–0.55 s** after you start speaking |
| Key release → text inserted (short dictation) | **~60 ms** |
| Key release → text inserted (90 s dictation) | **~150 ms**; long dictations are transcribed while you talk |
| Accuracy (300 LibriSpeech clips, 5,603 words) | **2.55% word error rate** |
| Clipping of the first word | None when the mic is warm (0.5 s pre-roll) |

### Model benchmark

Tested on 300 real LibriSpeech recordings (half clean, half noisy), with numbers and spelling normalized so formatting isn't counted as an error. The 95% intervals come from bootstrap resampling.

| Model | WER | 95% CI | Noisy WER | Median per clip | Verdict |
|---|---|---|---|---|---|
| **Parakeet Unified 0.6B** (default) | **2.55%** | 2.09–3.08 | **2.84%** | 51 ms | Most accurate |
| Driftflow full pipeline | **2.55%** | 2.09–3.08 | 2.84% | 49 ms | Post-processing adds 0 errors |
| Parakeet TDT v2 | 2.89% | 2.33–3.50 | 3.13% | 47 ms | Fastest by a hair (option) |
| Parakeet TDT v3 | 2.96% | 2.44–3.52 | 3.49% | 46 ms | Multilingual; weaker English |
| Parakeet Ultra | 2.98% | 2.47–3.55 | 3.46% | 47 ms | |
| Apple SpeechTranscriber | 3.30% | 2.75–3.91 | 4.36% | 98 ms | Used for live preview and fallback |
| Nemotron Streaming 0.6B | 3.86% | 3.22–4.59 | 5.11% | 92 ms | Slowest first text (1.3 s) |

## How it's faster than Handy and FluidVoice

| | Handy | FluidVoice | Driftflow |
|---|---|---|---|
| Transcription | After release | Re-runs the whole clip every 0.6 s, then again at the end | Streams while you talk; long dictations are finalized in segments at pauses |
| First syllable | Can be clipped | Can be clipped | Recording starts on key-down; optional warm mic adds 0.5 s pre-roll |
| Paste | 220 ms of fixed sleeps, clipboard restored on a timer | 500 ms clipboard hold | No sleeps; the clipboard is restored the moment the target app reads the text (lazy pasteboard promise) |
| Model state | Unloaded after 5 min idle | Reloads after dictionary edits | Loaded once and kept warm on the Neural Engine |
| Overlay | Web view | Native, with many fixed timers | Native Liquid Glass, spring-animated, waveform redrawn at the display's refresh rate outside SwiftUI state |

## Build and run

Requirements to build: Apple Silicon and the Xcode Command Line Tools (Swift 6.2). The app runs on macOS 15 and later (see "macOS 15" below).

```bash
./build.sh --install     # builds, copies to /Applications, and launches
```

Running `./build.sh` on its own only builds, into `build.noindex/`. That folder is excluded from Spotlight, so Launchpad never shows a second copy.

The first launch opens a setup window for Microphone and Accessibility access, then downloads the Parakeet model (about 500 MB, one time).

**Keeping Accessibility access across rebuilds.** Builds are signed ad hoc by default, so macOS forgets the Accessibility grant each time you rebuild. To avoid that, create a stable signing identity once: in Keychain Access, choose Certificate Assistant › Create a Certificate…, with Name `Driftflow Dev`, Identity Type Self Signed Root, and Certificate Type Code Signing. `build.sh` uses it automatically.

## App icon

"Drift Meter" is rendered in code by `Resources/Icon/render_icon.swift`; regenerate it with `Resources/Icon/make_icns.sh`. The tile follows the exact mask macOS 26 expects: an 831 pt tile with 186 pt corners, with nothing drawn outside it. Without that, Tahoe boxes the icon in a grey frame.

## Using it

- **Hold Right ⌘, speak, release:** the text is inserted (push-to-talk).
- **Tap Right ⌘** (under 0.3 s): hands-free mode; tap again to finish. **Esc** cancels.
- **Right ⌘ + C, V, a click, etc.:** recognized as a shortcut and cancelled silently. The sound and overlay wait 150 ms, so shortcuts never flash them.
- **Models** (Settings › Models): choose the final-text model (Parakeet Unified, TDT v2, TDT v3 or Apple Speech). Each card shows measured errors and speed, plus Download, Use and Delete. Apple Speech always drives the live preview.
- **Menu bar:** recent dictations (click to copy) and the latency of the last dictation.
- **Settings:**
  - trigger key: Right ⌥, Right ⌘, Fn, ⌥Space or ⌃⌥Space
  - microphones in order of preference: the highest connected one is used, with automatic switching as devices come and go
  - mic warmth
  - final-text model
  - language: 50+, using Apple's model for anything other than English
  - custom vocabulary, replacements (`spoken => written`) and snippets
  - AI Styles and per-app/website rules (see below)
  - filler-word removal
  - voice commands ("new line", "new paragraph", "scratch that": deletes the sentence just said, or, said first, removes the previous dictation from the app if its text is still exactly as typed)
  - open at login (on by default)
  - 5 sound sets: Classic, Soft Bells, Glass, Minimal, Pop
  - smart spacing
  - paste or typed insertion
  - searchable history

## Styles, app rules, snippets and voice editing

- **AI Styles** (Settings › Styles): Literal (default), Clean, Professional or Casual. Apple's on-device model (macOS 26 with Apple Intelligence) rewrites English dictations: it keeps only your self-corrections ("Tuesday, sorry, Wednesday" → Wednesday), drops repeats and fixes grammar. It adds about 0.35 s on average (1.1 s for a 90-word paragraph). Each rewrite is checked against what you said. A result that answers a dictated question, refuses, invents an email greeting or sign-off, or drifts from your words is discarded, and your words are inserted as spoken.
- **Apps and websites:** a rule per app, or per site in Safari/Chrome/Arc/Edge/Brave (read from the page's address through Accessibility). A rule can set:
  - a style;
  - plain text (no leading capital or final full stop, for terminals and search boxes);
  - pressing Return after inserting.
- **Snippets** (Settings › Vocabulary): say a phrase on its own ("my signature") to insert saved text exactly, line breaks included. Placeholders: `{date}`, `{time}`, `{day}`, `{clipboard}`.
- **Edit selection by voice (⌃⌥E):** select text, press the shortcut, say what to change ("make this shorter", "bullet points", "fix the grammar", "translate into Spanish"), then press it again. The selection is replaced.
- **Learn from corrections:** if you fix a misheard name in the text you just dictated ("cooper netties" → Kubernetes), a toast offers to add it to Vocabulary. Driftflow reads only that one field, through Accessibility, for 90 seconds. Ordinary word fixes ("their" → "there") and rewording are ignored.

## Transcribing audio and video files

Menu bar › **Transcribe Audio Files…**, drop files or a folder on the window, or Finder › Open With › Driftflow.
Uses the model chosen for dictation (Apple Speech for languages it doesn't cover), pauses while you dictate,
and keeps transcripts in `~/Library/Application Support/Driftflow/transcripts.json`. Export as plain text,
text with timestamps, SRT or VTT; click a timestamp to play the original from there.

- Formats: WAV, AIFF, CAF, M4A/AAC, ALAC, MP3, FLAC, Opus (CAF), AC-3, MP4, MOV, M4V, 3GP, any channel
  count (5.1 is averaged to mono). Ogg, WebM, MKV and WMA go through ffmpeg when it's installed.
- Decoding is pull-based in 10 s blocks and the model runs on ~30 s chunks cut at the quietest moment,
  so memory stays flat (~72 MB for any length).
- Measured on a 12-minute recording (90 LibriSpeech clips): 164–174× real time, 98.2% accurate
  (same clips one by one: 98.0%, so chunk seams lose nothing), subtitle starts a median 0.08 s from
  the true speech onset (Unified times shifted 0.3 s earlier; Apple's word ranges trimmed to speech).

## Sharing with other Macs

Needs Apple Silicon (M1 or later) and macOS 15 or later. The speech model (~590 MB) downloads on first launch.

### macOS 15

macOS 15 has no SpeechAnalyzer, so there Parakeet writes both the live preview and the final text, and `PauseTracker` finds the pauses that Apple's model reports on macOS 26, so long dictations are transcribed in pieces while you talk. Measured on this M5 with `DRIFTFLOW_NO_APPLE_SPEECH=1 … --legacy`:

- **Accuracy:** 300 clips, 2.52% WER vs 2.55% on the macOS 26 path (no significant difference).
- **Speed:** 2-minute dictation paced in real time: final text 0.06 s after release on both paths; transcripts 99.7% identical.

Differences on macOS 15:
- Dictation needs the Parakeet model downloaded first (on macOS 26, Apple's model covers the wait).
- Languages are Parakeet's: English, plus 24 European languages with Parakeet TDT v3, which is selected automatically for them.
- There's no accent picker.
- The pill and panels use a frosted material instead of Liquid Glass.

The live preview paces itself, waiting at least twice as long as the last update took, so slower chips preview less often instead of falling behind.

- `./release.sh 0.1.0 --quick` → `dist/Driftflow-0.1.0.zip` with a "How to open" note. Signed with the local
  "Driftflow Dev" certificate, so colleagues open it once via System Settings › Privacy & Security › Open Anyway.
  Updates signed with the same certificate keep their Microphone/Accessibility grants.
- `./release.sh 0.1.0` → notarized `dist/Driftflow-0.1.0.dmg` that opens with no warnings. Needs an Apple Developer
  Program membership, a "Developer ID Application" certificate, and a one-time
  `xcrun notarytool store-credentials driftflow-notary …` (see the top of `release.sh`).

Both use the hardened runtime with the microphone entitlement (`Resources/Driftflow.entitlements`), as does `build.sh`.

## Pill, toasts and reliability

- The pill: a ripple meter in the logo colours (centre bar leads, rings follow 50 ms later on springs), live
  text, ✕ / ✓ buttons in hands-free mode, bouncing dots while finishing. It appears on the screen of the window
  you're working in. Optional idle pill (General): a thin sliver that expands on hover; click to start.
- Toasts under the pill: "No audio from <mic>" (pure digital silence after 2 s) with Change Microphone,
  "No speech detected", a warning before hands-free stops at 10 minutes, and "Connecting to <mic>…" while a
  Bluetooth or iPhone mic starts.
- Silero VAD gate: audio with no voice never reaches Parakeet (it answers "Yeah." to a second of room tone).
- Failed dictations: the audio is kept (16 kHz WAV, 0600, `Driftflow/Rescue`) so History can Retry; deleted after
  the retry or 24 hours. Successful dictations never keep audio.
- Other audio is lowered to 30% while you dictate; the original volume is saved first and restored on the next
  launch after a crash.
- Microphone picker with fallback to the system default, and away from the built-in mic when the lid is closed.
- Shortcuts pane: dictation key, optional hands-free toggle, Paste Last Dictation (⌃⌥V), with conflict checks.
- Typed line breaks in chat apps (Slack, Messages, Discord, WhatsApp, Telegram, Teams…) are Shift+Return.
- Vocabulary: Parakeet CTC word spotting (98 MB helper model) guarded by a spelling-similarity check, plus exact
  spelling of your terms; replacements table and a Try-it box.

## Architecture

```
HotKeyMonitor (left/right-aware modifiers or a Carbon hot key)
  → AudioCapture (a single AVAudioEngine, a 0.5 s pre-roll ring, device-change recovery, vDSP level meter)
  → AudioPipe (buffers audio until the session is ready, so nothing is lost while the model spins up)
  → DictationSession
      ├─ Apple SpeechAnalyzer: streaming live preview
      ├─ EarlyPreview: Parakeet on the first 0.4–4 s, so live text appears about 2× sooner
      └─ SegmentedFinalizer: Parakeet over pause-bounded segments of 6 s or more, run in the background
  → release: Parakeet on the remaining tail, joined to the finished segments (Apple's text as fallback)
  → NumberStyle + TextProcessor (prose-style numbers and months, fillers, commands, replacements)
  → TextInserter (lazy-promise paste or Unicode typing), with CaretContext for smart spacing
```

## Test harness

- `Driftflow --duck-test` · `--duck-crash` then `--duck-recover`: volume ducking and crash recovery.
- `Driftflow --rescue-roundtrip <file>`: failed-dictation audio save → load → transcribe → delete.
- `open -a Driftflow --args --mic-test <file>`: records 0.5 s from every microphone through the real capture path.
- `open -n -g -a Driftflow --args --scratch-test <file> <pid>`: types into a throwaway text app (keystrokes sent to that process only), then checks "scratch that" removes it and refuses when the text was edited.
- `open -n -a Driftflow --args --hud-demo <dir>`: captures the pill over black and white backdrops, appearing and with the ✕/✓ buttons (`DRIFTFLOW_GLASS=regular` shows the old adaptive glass).
- `Driftflow --login-status`: whether macOS will open Driftflow at login.
- `Driftflow --mic-priority-test`: which microphone the priority list picks, with this Mac's real devices.
- `Driftflow --smart-test`: snippets, app/website rules, plain text, correction learning and the AI Style answer check (33 cases).
- `Driftflow --style-test TestData/styles.txt [clean|professional|casual]`: 37 dictations (questions, requests, prompt injections, self-corrections) through the real AI Style rewrite, with timings.
- `Driftflow --edit-test`: voice editing's rewrite on typical instructions.
- `Driftflow --logic-test`: every key decision (hold, tap, hands-free, Esc, shortcuts typed while finishing).
- `Driftflow --load-test`: model switching, including the vocabulary sequence that used to deadlock and rapid switches (the last request wins).
- `DRIFTFLOW_ASSET_READER=1 Driftflow --file <file>`: forces the video decoder (e.g. to test 5.1 surround audio).

- `Driftflow --file <audio or video> [--format text|timestamped|srt|vtt] [--apple] [--v2]`: the file pipeline headlessly.
- `open -a Driftflow --args --snapshot <dir>`: the app renders its Transcribe Files window to PNGs.

```bash
# Stream a file at speaking pace and report time to first text and release → final text.
build.noindex/Driftflow.app/Contents/MacOS/Driftflow --transcribe clip.wav --realtime
# Run the full app pipeline over a folder containing manifest.json ([{file, text}]) → results_driftflow.json.
build.noindex/Driftflow.app/Contents/MacOS/Driftflow --batch path/to/clips
# Play the overlay's full sequence for design review.
open build.noindex/Driftflow.app --args --demo
```
