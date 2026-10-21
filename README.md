<img src="docs/icon.png" width="96" alt="Clocked icon">

# Clocked

A study timer for the Mac that only counts the time you're actually studying. Pick up your phone, open YouTube or walk away, and the clock stops.

I made it because I'd "study" for four hours and get about two hours of work done. The rest went to my phone under the desk.

![Clocked](docs/screenshot.png)

## Download

Get the `.dmg` from the [website](https://snakeluck360gt.github.io/clocked/) and drag Clocked into Applications. It needs macOS 26 on Apple Silicon.

The app isn't notarized yet, so the first time you open it go to System Settings → Privacy & Security and click Open Anyway.

## How it works

- It watches for what phone use looks like: head down, no typing, sound that isn't coming from your Mac. Scrolling with the sound off gets caught in about 12 seconds.
- It checks the app and browser tab you're on and asks Apple Intelligence (on your Mac) if it fits your subject.
- More than 5 seconds out of the camera's view counts as away.
- When you're caught, the clock pauses and a banner pops up. On stricter settings it goes full screen, texts your iPhone, or closes the tab.
- If it's wrong, the banner buttons correct it, and a small [neural network](docs/neural-network.md) learns from that.

<img src="docs/nudge.png" width="470" alt="Phone use banner">

## Privacy

- The camera and mic only run during a session. Nothing is recorded.
- The app has no internet access at all. macOS blocks it, and you can check with `codesign -d --entitlements - /Applications/Clocked.app`.
- Optional study groups run in a separate helper and everything they send is end-to-end encrypted.

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
