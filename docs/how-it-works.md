# How Clocked works

Longer notes on what the app does and how. The [README](../README.md) is the short version.

## The app

The main window has a sidebar with Today, Stats, Sessions and Groups, and the settings underneath.

Today shows the day's total inside a ring that fills towards your daily goal, one colour per subject, and your subjects with a play button each. Pressing play on another subject during a session switches to it. Right-click a subject to set an exam date and it gets a D-12 style countdown.

Stats has today, this week, this month, your daily average and your streak, a calendar heatmap, a 24-hour timeline in 10-minute blocks for any of the last 14 days, and a chart of the last 7 days by subject. Sessions lists past sessions by day with a focus percentage.

There's also a menu bar popover with the same timer and subjects. Closing the main window keeps the app running there. Focus View (⌃⌘F) is a full-screen timer. Developer View (⌥⌘I) shows the live camera frame with everything that was detected drawn on it, plus every evidence term, the network's inputs and the sound readings. Frames only show while that window is open and are never saved.

After 50 minutes of unbroken focus it suggests a break. The first launch walks you through subjects, permissions, postures and a goal (Help → Welcome to Clocked brings it back).

Shortcuts: ⌘1–⌘9 start a subject, ⌥⌘B break or resume, ⇧⌘E end, ⌥⌘P working on paper, ⌥⌘S and ⌥⌘D mark the current tab as study or distraction.

## Staying on task

The clock only runs while you're focused. Once you're flagged as being on your phone it stays that way until you touch the keyboard or mouse again, so glancing up at the screen with the phone still in your hand doesn't count.

When the phone evidence passes halfway, study time starts being held back. If it turns into a phone flag, that whole stretch becomes phone time. If the suspicion fades, you get the time back. If you set a session goal, distractions make the session longer.

While you stay distracted it keeps escalating, depending on the strictness you picked. Strictness can't be changed once a session has started.

| | Gentle | Firm | Strict |
|---|---|---|---|
| Banner | at most every 90 s | every 30 s | every 20 s |
| iMessage to your iPhone (optional) | every 2 min | every 45 s | every 30 s |
| Full-screen "Phone down" | never | after 45 s | after 15 s |
| Close the tab or hide the app | never | never | after a 10 s warning |
| Confirm before ending early | no | yes | yes |

The iPhone reminders are sent by the Messages app to your own number or Apple ID, so your phone buzzes while you're scrolling it. They go through Apple's servers like any iMessage, contain the reminder and your subject name, and stop after 10 per session. Settings has a Send Test button to check your iPhone actually shows them.

It can also run a Shortcut when a session starts and ends. If you make "Study Start" and "Study End" shortcuts that turn a Focus on and off, and Share Across Devices is on, your iPhone goes into the same Focus.

## Phone detection

Your phone is usually in your lap where the camera can't see it, so Clocked doesn't depend on seeing it. Every second it adds evidence from several cues and lets it drain when they stop. One weak cue on its own never triggers anything.

| Cue | Effect |
|---|---|
| Head lower than your normal screen posture (head, eye, ear and shoulder positions, eyelids, head turn, where your pupils point) | + |
| Barely typing or using the mouse (it counts key presses, never which keys) | + |
| Smiling or laughing, or laughter in the room | + |
| Choppy short-video audio: fast switches between speech, music and laughter with abrupt cuts | ++ |
| Talking or music in the room while your Mac is silent or on headphones | + |
| A ringtone or notification sound, then head down | + |
| A phone visible in your hand | +++ |
| Pen on paper or typing sounds | − |
| Looking back at the screen, or typing | resets quickly |

In simulation, scrolling in your lap with the sound off is caught in 11–12 seconds (13–17 with quick glances at the screen), and with sound or while smiling in about 6. A quick glance at the screen doesn't reset it. Staying on the screen, glancing up repeatedly or typing does. It never flagged writing notes with pen sounds, typing an essay with music on, watching a lecture, or glancing at notes and then typing.

Your screen posture is re-learned every session from the moments you're typing, and the other postures are stored relative to it, so tilting the lid or moving seats doesn't throw it off. If the camera moves, it re-learns within a few seconds.

You can tell it whether you're typing, writing or both (on the Today screen or in the popover). When you're typing, pen sounds are ignored and looking down counts a bit more. When you're writing, pen sounds count as working and looking down counts a bit less.

It learns from you in a few ways:

- Recording your postures (Postures, about a minute) gives it your screen, paper and phone postures.
- "Writing notes" on a banner teaches it your note-taking posture and pauses head-down checks for 25 minutes. "Working on paper" in the menu does the same.
- "Not my phone" teaches it that the posture you were in is screen time for the rest of the session, and pauses detection for 30 seconds.
- Putting the phone away after a nudge teaches it your phone posture.

On top of the rules, a small neural network trains on your Mac from these labels. See [neural-network.md](neural-network.md).

## Apps and tabs

It reads the name of the app in front, and in Safari, Chrome, Brave, Arc, Edge and Vivaldi the current tab's title and address. Apple Intelligence decides on your Mac whether that fits your subject, and without it there are built-in rules. The screen is never captured. Firefox doesn't let other apps read its tabs, so only "Firefox" is seen.

## Music

Steady music, with or without vocals, never counts against you. In testing, none of 11 songs, a podcast, or music with someone talking over it set off the short-video check. Clocked always uses the Mac's built-in mic, so AirPods stay in high-quality mode.

Banners appear at the top of the screen and fade on their own. They show even when a Focus mode is on, and the menu shows why it fired, e.g. "head down · not typing · sound not from the Mac".

## Study groups

Groups let you compare today's time, streaks and subjects with friends and see who's studying right now. They're off until you turn on online features, which asks for confirmation.

You pick a nickname, create a group and share its invite code (`CLK1-…`). There are no accounts. The invite code is the group's encryption key: everything is encrypted on your Mac before it's sent, so the database only holds encrypted data under random IDs. Whoever runs the database can't read names, subjects or times, though like any server it sees when you sync and your IP address. Each member also has a private write token, so nobody can overwrite someone else's stats.

The syncing runs in a separate helper inside the app, `ClockedSync.xpc`. It's the only part with network access, it can't use the camera or mic, it only gets totals that are already encrypted, and it only talks to `https://*.supabase.co`. You choose what's shared: today's time, whether you're studying now (and the subject), week and streak, and per-subject times.

By default groups use Clocked's Supabase database. Its address and publishable key come from `supabase.env` (copy `supabase.env.example`), and `./build.sh` refuses secret keys. To set up a database, run the script from Settings → Privacy → Study Groups Database → Copy Script in the Supabase SQL editor, and turn off sign-ups under Authentication. Anyone can switch to their own Supabase project in the same place. Everyone in a group has to use the same one, so the owner shares a connection code (`CLKDB1-…`, just the address and publishable key).

`Tests/GroupSyncTests.swift` checks all of this against a stand-in server with the same rules as the setup script.

## Privacy

Clocked doesn't contact any server unless you turn on online features, and the sidebar always says Offline or Online. While it's offline the network helper isn't started at all.

The main app (camera, mic, detection, learning) is sandboxed without network permission, so macOS blocks it from going online. You can check: `codesign -d --entitlements - /Applications/Clocked.app` lists no `network.client`.

The camera, mic and tab checks only run during a session (not during breaks), and during a sensor test or posture recording that you start.

What's stored on disk:

- your settings
- optionally, the last 30 sessions (date, subject, times, top 3 distracting sites or apps)
- your postures, about 20 numbers each
- your subjects and daily time per subject for 400 days, plus 10-minute blocks for the last 14 days
- up to 1,500 learning examples of 32 numbers each, and the trained model

No images, audio, page titles, keystrokes or logs. Settings → Privacy → Delete All My Data erases all of it (and removes you from your groups), then quits.

## Building

You need macOS 26 on Apple Silicon and the Xcode Command Line Tools.

```bash
./build.sh                                   # the first run downloads the ~35 MB phone model
open build/Clocked.app
```

`SKIP_MODEL=1 ./build.sh` builds without the model and falls back to Apple's built-in image classifier, which is less accurate.

`./build.sh dmg` also makes `build/Clocked-<version>.dmg`. Without a Developer ID it's signed ad hoc, so people have to allow it once in System Settings → Privacy & Security. With one, `SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=… ./build.sh dmg` signs it with the hardened runtime, notarizes and staples it.

Each ad hoc rebuild may make macOS ask for camera, mic and browser permissions again.

## Tests

`Tests/run.sh` builds and runs five test programs against the app's sources: the neural network (gradient check, learning, cross-validation, determinism), head-down detection, 24 everyday situations through the evidence engine, a simulated student over 8 sessions of self-training, and the study group crypto and database rules.

## Tuning and limits

Record your postures, then use Start Test on the Postures page to watch the live evidence and the reasons behind it. If it's too eager or too relaxed, change Sensitivity in Settings → Detection.

Reading a paper textbook silently, or copying notes from the screen without pen sounds, can look like phone use until you record the Paper posture or turn on Working on paper (⌥⌘P).

More than 5 seconds out of the camera's view counts as away. The focus percentage is focused time divided by the whole session.

The detection is heuristic. It will sometimes miss or get it wrong, and the banner buttons are there to correct it.
