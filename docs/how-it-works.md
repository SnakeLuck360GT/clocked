# How Clocked works

A study timer for macOS that only counts time you actually study, and learns how *you* get distracted. Pick a subject and press play. The clock pauses whenever you pick up your phone, drift to an off-task site, or leave your desk, and it keeps pushing until you're back.

It's built to be private: sensors run only during a session, everything stays on your Mac, and macOS itself stops the app from going online.

## The app

- **Today:** today's total in large type, plus your subjects (colour, today's time, play/stop). Tapping another subject while a session runs switches to it.
- **Stats:** today / week / month / daily average / streak, a monthly calendar heatmap, a 24-hour timeline in 10-minute blocks for any of the last 14 days, and a last-7-days chart by subject.
- **Sessions:** past sessions grouped by day, with focus %.
- **Settings** (in the sidebar, or ⌘,): everything in one place. **Postures / Learning:** record your postures, test the sensors, and see the on-device neural network's status, accuracy and examples. See [docs/neural-network.md](neural-network.md).
- **Exam countdowns:** right-click a subject → Set Exam Date… for a "D-12" badge.
- **Break suggestions** after 50 minutes of unbroken focus (configurable).
- **First run:** a short welcome walks through subjects, permissions, postures and goals (Help → Welcome to Clocked reopens it).
- **Focus View (⌃⌘F):** a full-screen timer with nothing else on screen.
- **Developer View (View → Developer View, ⌥⌘I):** the live camera frame with everything detected drawn on it (face box and angles, eyes and pupils, lips, body skeleton, hands, phone boxes with confidence), every evidence term this second, the network's inputs, per-input push and learned weights, the posture votes, and the sound readings. Frames are only shown while the window is open, and never saved.
- **Menu bar:** a popover with the same timer and subjects. Closing the main window keeps the app running there.
- **Session menu:** ⌘1–⌘9 start a subject, ⌥⌘B break/resume, ⇧⌘E end, ⌥⌘P working on paper, ⌥⌘S / ⌥⌘D mark the current tab as study / distraction.

## Staying on task

The study clock only runs while you're focused. Once you're flagged as on your phone, it stays that way until you use the keyboard or mouse again; looking up at the screen with the phone still in hand doesn't clear it. From the moment phone evidence passes 50%, study time is **held back**: if it turns into a phone flag, that whole stretch counts as phone time; if the suspicion fades, the time is given back. With a goal set (e.g. 50 minutes), every distraction makes the session longer. While you stay distracted, the app escalates according to **Strictness**:

| | Gentle | Firm | Strict |
|---|---|---|---|
| Banner | at most every 90 s | every 30 s | every 20 s |
| iPhone reminder (opt-in) | every 2 min | every 45 s | every 30 s |
| Full-screen "Phone down" curtain | — | after 45 s | after 15 s |
| Close distracting tab / hide app | — | — | after a 10 s warning |
| Confirm before ending early | — | yes | yes |

Strictness is locked once a session starts.

- **iPhone reminders (opt-in):** the Messages app sends an iMessage to your own number or Apple ID email, so your phone buzzes while you scroll. iMessage goes through Apple's servers (end-to-end encrypted). The message is the reminder text and your subject name, at most 10 per session. Use **Send Test** to check that your iPhone shows a notification for messages sent to yourself.
- **Focus mode (opt-in):** runs a Shortcut when a session starts and ends. Create "Study Start" (Set Focus → On) and "Study End" (Set Focus → Off). With Share Across Devices on, your iPhone enters the same Focus, which can silence or hide distracting apps.

## What it notices

### 📱 Phone use, even when your phone is out of view
Your phone is usually hidden in your lap, so it doesn't rely on seeing it. Every second it builds up (or drains) evidence from several cues. One weak cue alone never triggers a nudge.

| Cue | Effect |
|---|---|
| Head down vs. *your* normal posture (head/eye/ear/shoulder positions, eyelids, head turn, where your pupils point) | + |
| Barely typing or mousing (key-press **count** only, never which keys) | + |
| Smiling or laughing (mouth shape vs. your resting face), or laughter in the room | + |
| TikTok-style choppy audio (fast switches between speech, music and laughter, with abrupt cuts) | ++ |
| Talking or music in the room while your Mac is silent or on headphones (so it's coming from your phone) | + |
| A ringtone or notification sound, then head down | + |
| A phone visible in your hand (bonus, rarely needed) | +++ |
| Pen-on-paper or typing sounds | − |
| Looking up at the screen, or typing | resets quickly |

Simulated timings: muted scrolling in your lap ≈ 11–12 s (13–17 s with brief glances at the screen); with sound from your phone, or while smiling ≈ 6 s. A brief glance at the screen doesn't reset it; staying on the screen, glancing up repeatedly, or typing does. It never flags in these simulated cases: writing notes with pen sounds, typing an essay with music on, watching a lecture, or glancing at notes and then typing.

**Laptop tilt doesn't matter.** Your "looking at the screen" posture is re-learned every session from moments you're typing. Every other posture is stored *relative* to it, so tilting the lid or changing seats doesn't throw it off. If the camera moves (shoulders jump in the frame while you type), it re-learns within seconds.

**Typing / Writing / Both.** Tell it how you're studying (Today screen or menu-bar popover; you can switch mid-session):
- **Typing:** writing sounds are ignored, since a misheard tap on a phone screen shouldn't excuse looking down, and looking down counts a bit more.
- **Writing:** pen sounds count as working, and looking down counts a bit less.
- **Both:** pen and typing sounds both count.

**It learns you.**
- **Postures tab → Record** takes about 1 min: Screen, Paper, Phone.
- Tapping **Writing notes** in a nudge teaches it your note-taking posture and pauses head-down checks for 25 min.
- **Not My Phone** teaches it that the posture you were in (for example, looking at the bottom of the screen) is screen time, for the rest of the session. Detection pauses for only 30 seconds.
- Putting the phone away after a nudge teaches it your phone posture.
- **Working on paper** in the menu pauses head-down checks for 25 min.

### 🌐 Off-task apps and tabs
It reads the name of the app in front. For Safari, Chrome, Brave, Arc, Edge and Vivaldi, it also reads the active tab's title and address. Apple Intelligence (on-device) judges whether that fits your topic; without it, built-in rules are used. The screen is never captured.

### 🎵 Music is fine
Steady music, with or without vocals, never counts. In testing, none of 11 real songs, a podcast, or music with someone talking over it triggered the TikTok-audio check. The app always uses the Mac's built-in mic, so AirPods stay in high-quality mode.

Nudges are a small banner at the top of the screen that fades on its own. They still show when a Focus mode is on, and the menu shows **why** (e.g. "head down · not typing · sound not from the Mac").

## Study groups (optional)

Compare today's study time, streaks and subjects with friends, and see who's studying right now (**Groups** in the sidebar).

- **No Apple account or email needed.** You pick a nickname. Create a group, then share its invite code (`CLK1-…`) with friends.
- **Clocked's database, or your own.** By default groups sync through Clocked's study-groups database on [Supabase](https://supabase.com). Its address and publishable key come from `supabase.env` (copy `supabase.env.example`) and are built in by `./build.sh`, which refuses secret keys. To set it up, run the script from Settings → Privacy → Study Groups Database → Copy Script once in the Supabase SQL Editor, and turn off sign-ups under Authentication. Anyone can switch to their own Supabase project in Settings → Privacy. Everyone in a group has to use the same database, so the owner shares a **connection code** (`CLKDB1-…`, just the address and publishable key) that friends paste in the same place. Online features stay off until each user turns them on.
- **End-to-end encrypted.** The invite code *is* the group's key. Everything is encrypted on your Mac before it's sent, so the database only stores scrambled data under random IDs. Nobody running it, including Clocked's makers, can read names, subjects or times or join your group. It does see when you sync and your IP address, like any website. Each member also has a private write token, so nobody can overwrite anyone else's stats.
- **Detection still never goes online.** Networking happens in a separate helper bundled inside the app (`ClockedSync.xpc`). It's the only part with internet access, and it has no camera, microphone or anything else. It only receives already-encrypted totals, and only talks to `https://*.supabase.co`.
- **You choose what's shared:** today's time, studying now (and subject), week and streak, per-subject times.

`Tests/GroupSyncTests.swift` checks all of this against a stand-in server that enforces the same rules as the setup script.

## Privacy guarantees

- **Offline by default.** Clocked never contacts any server unless you switch on online features in Groups (asked again with a confirmation, and off again with one click). The sidebar always shows **Offline** or **Online**. While it's off, the network helper isn't even started.
- **Delete everything in one click.** Settings → Privacy → Delete All My Data erases stats, sessions, subjects, postures, learning examples and settings (and removes you from your groups), then quits.
- **Detection never goes online, enforced by macOS.** The main app (camera, microphone, detection, learning) is sandboxed with no network permission. Check it with `codesign -d --entitlements - "build/Clocked.app"`: there's no `network.client`. Optional study groups use the separate `ClockedSync.xpc` helper, which only has outgoing network access and only receives encrypted totals. Optional iPhone reminders are sent by the Messages app.
- **On only while studying.** Camera, mic and tab checks run during a session (not during breaks), and during a sensor test or posture recording you start yourself.
- **Almost nothing on disk.** Clear the session list in Sessions, study totals in Stats, and learned postures with "Reset Postures". On disk there is only:
  - your settings;
  - an optional history of the last 30 sessions (date, topic, times, top 3 distracting sites/apps);
  - your taught postures, about 20 numbers each;
  - your subjects, and study time per day per subject for 400 days (plus 10-minute blocks for the last 14 days), roughly 50 KB after a year.

  Under 100 KB in total after a year. No images, audio, page titles, keystrokes or logs.

## Build & run

Needs macOS 26 on Apple Silicon and the Xcode Command Line Tools (full Xcode isn't required).

```bash
./build.sh                                   # first run downloads the ~35 MB phone model, once
open "build/Clocked.app"
cp -R "build/Clocked.app" /Applications/   # optional
```

`SKIP_MODEL=1 ./build.sh` builds without the model (falls back to Apple's built-in image classifier, less accurate).

**Release DMG:** `./build.sh dmg` also makes `build/Clocked-<version>.dmg` (drag-to-Applications). Without an Apple Developer ID it's signed ad hoc, so people who download it have to open it once via System Settings → Privacy & Security → Open Anyway. With one, `SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=… ./build.sh dmg` signs with the hardened runtime, notarizes and staples, so it opens normally.

**Smarter tab checks:** turn on Apple Intelligence in System Settings → Apple Intelligence & Siri. It runs entirely on-device.

## Tests

`Tests/run.sh` compiles and runs three test programs against the app's sources:

- **Neural network:** gradient check, non-linear learning, determinism.
- **Detection scenarios:** 24 everyday situations through the evidence engine.
- **Self-training simulation:** a simulated student over 8 sessions, including noisy-label and worst-case variants.

## Tuning

1. Record your postures in the **Postures** tab.
2. Press **Start Test** there to watch the live evidence score and the reasons behind it.
3. Adjust **Sensitivity** in Settings → Detection if it's too eager or too relaxed.

Known limitation: reading a paper textbook silently, or copying notes from the screen without pen sounds, can look like phone use until you record the Paper posture or turn on **Working on paper** (⌥⌘P).

Time out of the camera's view for more than 5 seconds counts as Away, not focus. The focus percentage is focused time divided by the whole session.

## Notes

- Each rebuild is signed ad-hoc, so macOS may ask for camera, mic and browser permissions again after a rebuild.
- Firefox can't report its tabs to other apps. When you use it, only the app name ("Firefox") is seen.
- The phone and audio detection are heuristics. Expect the occasional miss or false alarm, and use the banner buttons to correct it.
