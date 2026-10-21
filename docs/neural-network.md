# The neural network

The phone detection started as hand-written rules: head down, not typing, sound not coming from the Mac, and so on. They work for most people, but everyone sits and scrolls a bit differently, so I added a small neural network that learns from your own sessions. It runs and trains entirely on your Mac.

![The Learning page](learning.png)

## What it is

- A tiny network: 32 inputs → 16 → 8 → 1 output, 673 weights in total.
- Once a second it gets 32 numbers describing you: head and eye position compared to how you normally sit, typing and mouse activity, what kind of sound is in the room, whether a phone is visible. Never images, audio or text.
- The output is how likely it is that you're on your phone right now.
- I wrote it by hand in Swift (about 340 lines, in `Sources/Clocked/PhoneNet.swift`) because Core ML training needs Xcode, and this project builds without it.

## Where it learns from

It labels its own examples from things you do anyway:

- Recording your postures (screen, paper, phone).
- Pressing "Not my phone" or "Writing notes" on a banner.
- Going back to typing after a phone banner, which means the banner was right.
- Typing while facing the screen, which means you're not on your phone.
- Teach Phone Detection on the Learning page: about 4 minutes where it tells you out loud what to do (type, read, write, use your phone a few ways) and learns from each step.

It retrains from scratch every 40 new examples and at the end of each session, which takes a second or two.

## How much it's trusted

The rules always do most of the work. The network only gets a say once it's proven itself:

- It's tested on sessions it wasn't trained on, so it can't just memorise.
- Below 70% accuracy (estimated cautiously) it has no say at all. It gets full say at 90%.
- It can push towards "phone" or away from it, which is how it fixes false alarms on the way you specifically read or write.
- It can never trigger a banner on its own, and it can't argue with typing or writing sounds.

## What I learned

On my first day of real data, the network mostly learned "not typing = phone", because most of its phone examples came from moments the rules had already flagged. It couldn't tell reading apart from scrolling. Tweaking the training didn't help, and every version scored 66–71% on unseen sessions. What fixed it was better examples, which is why Teach Phone Detection exists. Scoring it across whole sessions instead of one random split also made the accuracy numbers much more honest.

## Privacy

- Training and predictions only happen on your Mac, and the app can't go online anyway.
- It keeps at most 1,500 examples (32 numbers each, about 200 KB) plus the model (about 20 KB).
- Reset Learning on the Learning page deletes both.

## Tests

`Tests/run.sh` checks the maths against numerical gradients, makes sure it can learn a shape a straight line can't, checks that results are repeatable, and simulates a student over 8 sessions, including mislabelled data, to check the network doesn't make detection worse.
