# How Clocked works

## Sessions

- Pick a subject and press play. The clock only counts while you're focused.
- Set a session goal (50 minutes by default). Time lost to distractions is added on.
- Shortcuts: ⌘1–⌘9 start a subject, ⌥⌘B break, ⇧⌘E end, ⌃⌘F full-screen timer.

## What it checks

- Camera: head and eye position compared with your normal screen posture, and phones in view.
- Microphone: the type of sound, such as speech, music, typing or writing. Nothing is recorded.
- Keyboard and mouse: whether you're using them, not what you type.
- The app and browser tab in front. Apple Intelligence checks it against your subject.

## Phone detection

- Each cue adds to an evidence score every second. One cue on its own isn't enough.
- At half the threshold, study time is held back. At the threshold, that time becomes phone time and the clock stops.
- Typing or looking back at the screen clears it.
- Scrolling with the sound off takes about 12 seconds to catch. With sound, about 6.

## Strictness

| | Gentle | Firm | Strict |
|---|---|---|---|
| Banner | every 90 s | every 30 s | every 20 s |
| iMessage to your iPhone (optional) | every 2 min | every 45 s | every 30 s |
| Full-screen "Phone down" | never | after 45 s | after 15 s |
| Close the tab or hide the app | never | never | after 10 s |

Strictness can't be changed during a session.

## Correcting it

- Writing Notes on the banner pauses head-down checks for 25 minutes.
- Not My Phone counts that posture as screen time for the rest of the session.
- Recording your postures in Postures makes detection more accurate.
- A small neural network learns from these. See [neural-network.md](neural-network.md).

## Study groups

- Off until you turn them on.
- Friends join with an invite code, which is also the encryption key.
- Syncing runs in a separate helper. It's the only part with network access and it can't use the camera or mic.

## Privacy

- The camera, mic and tab checks only run during a session.
- The app has no network permission. Check with `codesign -d --entitlements - /Applications/Clocked.app`.
- Saved on your Mac: settings, daily totals, postures, the last 30 sessions and the learning examples.
- Settings → Privacy → Delete All My Data removes everything.

## Known limits

- Reading a paper book without writing can look like phone use. Turn on Working on paper (⌥⌘P).
- Firefox doesn't share its tabs, so only the app name is checked.
