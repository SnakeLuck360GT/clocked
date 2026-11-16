<img src="docs/icon.png" width="96" alt="Clocked icon">

# Clocked

A study timer for the Mac that only counts the time you're actually studying. Pick up your phone, open YouTube or walk away, and the clock stops.

I made it because I'd "study" for four hours and get about two hours of work done. The rest went to my phone under the desk.

![Clocked](docs/screenshot.png)

## Download

Get the `.dmg` from the [website](https://snakeluck360gt.github.io/clocked/) and drag Clocked into Applications. It needs macOS 26 on Apple Silicon.

The app isn't notarized yet, so the first time you open it go to System Settings → Privacy & Security and click Open Anyway.

## How it works

- The camera and mic look for signs of a phone: your head down with no typing, light from a phone on your face, sound that isn't from your Mac.
- Looking down to think doesn't count. A hand on your face or looking around reads as thinking.
- The app and browser tab you're on are checked against your subject.
- More than 5 seconds out of view counts as away.
- When you're distracted, the clock pauses and a banner appears. The buttons on it correct mistakes, and a small [neural network](docs/neural-network.md) learns from them.

<img src="docs/nudge.png" width="470" alt="Phone use banner">

## iPhone link

Optional. Your iPhone tells Clocked the moment you open Instagram, TikTok or anything else you pick, so it doesn't have to guess. It works over your Wi-Fi with two Shortcuts automations. Setup is a QR code in Clocked and a few taps on your phone.

<img src="docs/phone-setup.png" width="260" alt="iPhone setup page">

## Timers and looks

- Show today's total, this session (like YPT) or the time left.
- Pomodoro mode with breaks that start on their own.
- Light or dark, six accent colours, the timer font, and a full-screen Focus View.

<p>
  <img src="docs/session.png" width="49%" alt="Session timer">
  <img src="docs/pomodoro.png" width="49%" alt="Pomodoro">
</p>

## Privacy

- The camera and mic only run during a session. Nothing is recorded.
- The app has no internet access. Check with `codesign -d --entitlements - /Applications/Clocked.app`.
- Study groups and the iPhone link are optional and each runs in its own small helper that can't use the camera or mic.

<p>
  <img src="docs/stats.png" width="62%" alt="Stats">
  <img src="docs/popover.png" width="26%" alt="Menu bar">
</p>

## Building it

You need macOS 26 on Apple Silicon and the Xcode Command Line Tools.

```bash
./build.sh        # builds build/Clocked.app
./build.sh dmg    # also makes a .dmg
Tests/run.sh      # runs the tests
```

Study groups need a Supabase project in `supabase.env` (see `supabase.env.example`). Everything else works without it.

More detail is in [docs/how-it-works.md](docs/how-it-works.md).
