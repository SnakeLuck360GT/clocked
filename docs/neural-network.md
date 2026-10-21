# How Clocked's neural network works

Clocked started with hand-written rules for spotting phone use: head down, not typing, sound coming from somewhere other than the Mac, and so on. Those rules work for most people most of the time, but they can't know *you*. Everyone sits, reads and scrolls a bit differently, and the camera angle changes from desk to desk.

So Clocked now also has a small neural network that trains itself on your Mac from your own sessions. It doesn't replace the rules. It adds evidence on top of them, and only once it has proven it predicts well.

This document covers what the network sees, how it's built and trained, where its training labels come from, how it's kept from doing harm, and how it was tested.

---

## 1. At a glance

| | |
|---|---|
| **Task** | For each second of a session, estimate the probability that you're on your phone |
| **Model** | Fully connected network: 32 inputs → 16 tanh → 8 tanh → 1 sigmoid, **673 parameters** |
| **Training** | On-device, from scratch each time, in a second or two. Adam optimiser, class-weighted cross-entropy, early stopping |
| **Labels** | Your posture recordings and corrections, plus automatic labels (typing at the screen, accepted nudges) |
| **When it retrains** | After every 40 new labels, after a posture recording, and at the end of each session |
| **Say in detection** | 0% until it scores at least 70% on data it hasn't seen (cautious estimate), rising to 100% at 90% |
| **Storage** | At most 1,500 examples of 32 numbers each (about 200 KB), plus the model (about 20 KB). Never images or audio |
| **Code** | `Sources/Clocked/PhoneNet.swift` (the network) and `Sources/Clocked/Learning.swift` (features, labels, retraining) |
| **Tests** | `Tests/run.sh` runs `NeuralNetTests`, `DetectionScenarios` and `LearningSimulation` |

---

## 2. Why build it from scratch

Apple's Core ML can train models on-device, but only if a model was first prepared with Python tooling and Xcode. Neither suits this project, which builds with the Swift compiler alone. A network this small is also easy to write by hand: about 340 lines including the optimiser. Writing it by hand has two other advantages:

- **Nothing is hidden.** Every step, from initialising the weights to the optimiser update, is ordinary Swift you can read.
- **It's tiny and fast.** 673 parameters train in a second or two, so retraining after every session costs nothing.

---

## 3. What the network sees

Once per second the app turns everything it knows into **32 numbers**, most of them between 0 and 1. Two rules shape them:

- **Everything is relative to you.** Posture is measured as the *difference* from how you sit while typing. That baseline is re-learned each session, so a tilted laptop lid or a different chair doesn't throw the numbers off.
- **No raw data.** The numbers describe geometry, timing and sound *type*. They are never pixels, audio or text.

| # | Feature | Source |
|---|---|---|
| 0–3 | Change in eye height vs. ears, nose height vs. shoulders, face height in frame, head pitch | Vision body pose + face detection, compared with your typing posture |
| 4–5 | Face visible, person in view | Vision |
| 6–7 | Change in eye openness (eyelids drop when you look down), head turn | Face landmarks |
| 8 | Typing baseline ready | — |
| 9–11 | Mouth curve, width and openness vs. your resting face (smiling) | Face landmarks |
| 12–13 | Phone-detector confidence, phone held in hand | YOLOv3-Tiny + hand pose |
| 14–16 | Key presses in the last 10 s (count only), time since mouse, time since any input | macOS event counters |
| 17–20 | Share of speech/music/laughter, sound switches, loudness cuts, short-form-video pattern | SoundAnalysis |
| 21–25 | Writing sounds, typing sounds, laughter, notification sound, Mac playing aloud | SoundAnalysis + Core Audio |
| 26–27 | Camera on, microphone on | — |
| 28 | Gaze: how low the pupils sit inside the eyes vs. your normal (looking down with eyes only) | Face landmarks (pupils) |
| 29–31 | Share of the last 10 s with head down, glances back at the screen in the last 30 s, time since the last key press | The app's own recent history |

Features 26–27 let the network tell "no signal" apart from "sensor off". Features 29–31 give it a short memory. Scrolling is a steady head-down stretch with few glances up; reading notes or copying from the screen involves frequent glances back.

---

## 4. Architecture

```
 32 features ──► standardise (per-feature mean / std learned in training)
                    │
                    ▼
             Dense 32→16, tanh        (528 parameters)
                    │
                    ▼
             Dense 16→8, tanh         (136 parameters)
                    │
                    ▼
             Dense 8→1, sigmoid       (9 parameters)
                    │
                    ▼
           p(on phone) ∈ (0, 1)
```

- **Standardisation:** each feature is scaled to mean 0 and spread 1 using statistics from the training data, so no single feature dominates just because of its units.
- **Two small hidden layers with tanh:** enough to learn interactions (for example, "head down *and* no writing sound *and* eyes nearly closed") that a straight-line rule can't express, while staying hard to overfit with only a few hundred examples.
- **Xavier/Glorot uniform initialisation:** suits tanh layers and keeps early training stable.

---

## 5. Training

Each retrain starts from fresh weights and trains on every stored example (`PhoneNet.train`).

1. **Split by episode, not by second.** Neighbouring seconds are nearly identical, so a random split would let the network "see" its test data and look better than it is. Examples are grouped into *episodes* (one recording, one correction, one session's typing samples), and 20% of episodes are held out. "Phone" and "not phone" episodes are held out separately, so both kinds are tested. A class with only one episode so far keeps it for training; that model then can't earn a say (section 7).
2. **Class-weighted binary cross-entropy.** "Not phone" examples usually outnumber "phone" ones. The rarer class is weighted up (clamped to a 0.2×–5× range), so the network can't win by always answering "not phone".
3. **Adam optimiser:** learning rate 0.01, batches of 32, L2 weight decay 1e-4.
4. **Early stopping.** Training runs for at most 80 epochs, stops when held-out loss hasn't improved for 10 epochs, and keeps the best weights seen.
5. **Deterministic.** A seeded random number generator (SplitMix64) makes every run reproducible.
6. **Cross-validated scores.** The model that's kept is trained as above, but the accuracy that decides its say comes from 5-fold cross-validation over whole episodes (`PhoneNet.crossValidate`): five extra networks are each trained without one fifth of the episodes, and every example is scored by the one that never saw it. One 20% split of a dozen episodes held out as few as 3 "not phone" examples; this way every example counts. A test checks that random labels stay untrusted (cautious accuracy below 65%).

**Backpropagation** is written out by hand (`accumulateGradients`):
- For sigmoid + cross-entropy, the output error is simply `weight × (p − y)`.
- Each layer adds `error × input` to its weight gradients.
- The error is passed back through the weights and the tanh derivative `1 − a²`.

The test suite checks these gradients against numerical finite differences (section 9).

---

## 6. Where the labels come from: self-training

The network learns only from situations where the answer is reliably known. It never trains on its own guesses, because that would just reinforce its mistakes.

| Source | Label | When |
|---|---|---|
| **Posture recordings** | Screen and Paper = not phone, Phone = phone | Each 15-second recording in the Postures tab (about 30 examples). Posture is measured against the first seconds of the countdown, while you're watching the screen, so a recording uses the same reference as a live session from the same sitting |
| **Your corrections** | not phone | "Not My Phone" or "Writing Notes" labels the previous 20 seconds. "Not My Phone" also tells the rules that the posture you were in counts as looking at the screen for the rest of the session. Detection pauses for only 30 seconds, and the small drop in sensitivity halves back at each new session |
| **Confirmed nudges** | phone | After a phone nudge, if you go back to typing without saying it was wrong, the seconds before the nudge that look like phone use (no key presses, nothing touched for 4 s) are labelled. A correction of *that same nudge* within 3 minutes removes them again and retrains |
| **Typing at the screen** | not phone | At most one example every 15 seconds while you're typing and facing the screen. At most 600 are kept (40% of capacity), oldest replaced first |
| **Working on paper** | not phone | At most one example every 15 seconds while paper mode is on, your head is down, writing is heard and no phone is visible |
| **Guided teaching** | as asked | **Learning → Teach Phone Detection**, about 4 minutes with spoken prompts: type, read without typing, phone in lap, write on paper, phone another way, sit back and think, watch something on the phone. Each step is its own episode; the first 4 seconds of each are dropped while you move into position. Camera and microphone both run, as in a real session |

**Why guided teaching matters.** On a real user's first day of data (289 examples, 15 episodes), the strongest feature by far was key presses, and 101 of 151 "phone" examples came from confirmed nudges, which are moments the rules had already flagged. The network was mostly learning to copy the rules ("not typing and head down"), with no examples of reading or thinking without typing to tell them apart. Changing the training settings didn't help: every variant scored 66–71% on unseen episodes. More varied, honestly labelled examples are what it needs.

**Storage policy.** The store holds at most 1,500 examples. When it's full, the oldest example of the more common class goes first, so both classes stay represented and old habits fade out.

**When it retrains:**
- every 40 new labels;
- right after a posture recording;
- at the end of each session.

Training runs on a background thread, and the new model replaces the old one only when training finishes.

---

## 7. How much say it gets

A network trained on a few hundred examples can be wrong, so its influence is earned (`Learner.influence`).

1. **Minimum data.** At least 30 examples of each class in the training set, and at least 10 of each scored in cross-validation.
2. **Cautious accuracy.** It uses *balanced accuracy*, the average of the true-positive and true-negative rates. One standard error is subtracted for each class, so a small held-out set that happened to look perfect can't earn it a big say.
3. **Influence:** 0% below a cautious estimate of 70%, rising linearly to 100% at 90%.

**How it feeds into detection.** Each second, the network adds a term to the same evidence score the rules use (`PhoneEvidence`):

```
push = influence × clamp(0.4 × log(p / (1 − p)), −1.2, +1.2)   per second
```

- **Log-odds:** the push is proportional to how confident the network is, not just which side of 50% it's on.
- **Two-way:** it can push *against* a nudge. That's how it fixes false alarms the rules can't, such as your particular way of reading on paper.
- **Capped:** the rules still decide most cases. The network tips the balance in uncertain ones.
- **Never alone:** if no rule sees anything suspicious, the network's upward push is held below the constant drift back to zero, so it can't trigger a nudge on its own.
- **Never against direct evidence:** while writing or typing sounds are heard, the network can't push towards "phone".

The **Learning** tab shows its status, its say, the latest validation scores and the examples by source. You can retrain or reset it at any time.

---

## 8. Privacy and storage

- **Training and prediction run only on this Mac.** The app is sandboxed with no network permission, so nothing could be uploaded even by accident.
- **What it stores:** labelled examples (32 numbers each, binary file `learning.bin`, at most about 200 KB) and the model (`model.json`, about 20 KB). Both are in the app's private container.
- **What it never stores:** images, audio, page titles or keystrokes. The features are geometry and counts.
- **Reset:** **Learning → Reset Learning** deletes both files. A training round already running when you reset is discarded.

---

## 9. Testing

All numbers below come from `Tests/run.sh` on the current code.

### 9.1 The network itself (`Tests/NeuralNetTests.swift`)

| Test | Result |
|---|---|
| Gradient check: hand-written backpropagation vs. central finite differences | Worst relative error **0.0009** (pass threshold 0.02) |
| Learns a non-linear boundary (points inside a ring) that a linear model can't | **98.9%** balanced accuracy on held-out episodes |
| Same data and seed give identical weights | Pass |

### 9.2 The self-training loop (`Tests/LearningSimulation.swift`)

A simulated student produces features through the same `LearningFeatures` code the app uses.
- **Postures:** screen, phone-in-lap and paper postures with realistic spread. The paper posture is deliberately close to the phone posture in head angle; it differs mainly in eye openness, face visibility and head turn.
- **Recordings:** made the way the app makes them: camera only, mic off, measured against countdown frames.
- **Labels:** they arrive as in real use. There are three posture recordings up front. Then each simulated session adds typing samples and two accepted phone nudges, and the first four sessions also add a "Writing Notes" correction.
- **Measurement:** after each session the network is retrained and tested on 1,800 fresh examples it never saw.

**Typical student.** "Cautious" is the held-out balanced accuracy minus one standard error, which is what decides the network's say.

| Session | Labels (phone / not) | Held-out accuracy | Cautious | Say | Accuracy on unseen data |
|---|---|---|---|---|---|
| 1 | 70 / 92 | 97.5% | 75.9% | **0%** (too few held-out phone examples) | 69.3% |
| 2 | 110 / 124 | 87.2% | 77.7% | 38% | 96.2% |
| 3 | 150 / 156 | 95.7% | 88.6% | 93% | 97.7% |
| 8 | 350 / 236 | 98.7% | 95.3% | 100% | 98.3% |

After session 1 the network is poor on unseen data (69%), and the safety gate correctly gives it no say. Its say then grows as the labels pile up.

Effect on time to a phone nudge, rules alone vs. rules + network (after session 8):

| Situation | Rules only | Rules + network |
|---|---|---|
| Phone in lap, muted | 11 s | **5 s** |
| Phone in lap, with sound | 4 s | 2 s |
| Reading paper silently (the rules' known false alarm) | 11 s | **never** |
| Typing / reading the screen / writing with pen audible | never | never |

**Stress tests:**
- **20% of labels wrong.** Cautious accuracy never reaches 70%, so the network's say stays at **0%** across all eight sessions. Detection behaves like rules alone.
- **Paper and phone postures indistinguishable.** The network's say is 0% in five of eight sessions and 37–69% in the others. No scenario's outcome changes. Writing with a pen is protected by the "never against direct evidence" rule; before that rule existed, this case produced a false nudge at 75 s.
- **Looking at the bottom corner of the screen** (the false alarm reported in real use). Before any correction it reads as head-down 11% of the time. After one "Not My Phone" it reads as head-down 0% of the time, while real phone posture is still caught 99% of the time.

### 9.3 The rules (`Tests/DetectionScenarios.swift`)

Twenty-four everyday scenarios run through the evidence engine. Examples: muted lap scrolling gets a nudge at 11 s, scrolling with sound at 6 s, and nothing fires for pen writing, typing, a lecture, or a roommate's TV with the camera off.

---

## 10. Limitations

- **Simulated, not measured.** Every number above comes from a simulated student, built to resemble what the camera and microphone produce. Real features are noisier, and the real accuracy will only be known after you use it for a while. The Learning tab shows the honest held-out numbers as they come in.
- **One second at a time.** The network sees each second on its own. Time is handled by the evidence integrator around it. A model that looks at the last 10–30 seconds together (a small 1-D convolution or GRU) could pick up patterns like "glance up every few seconds while reading".
- **Recording conditions differ from sessions.** The microphone is off during posture recordings, and there's no resting-face reference then. Both are the same across the three recordings, so they can't fake the difference between them, and the simulation includes them. But recordings still look slightly different from live sessions.
- **Few episodes.** Cross-validation scores every example, but with only a dozen episodes the score can still swing. The cautious-accuracy rule and the guard rails in section 7 limit the damage but don't remove it.
- **Pupils at webcam resolution.** The gaze reading depends on Vision locating the pupils in a 640×480 frame, which will be noisy in dim light.
- **It can't see what's on the phone.** Only an iPhone app with Screen Time access could know for sure (see below).

---

## 11. Other improvements in this version

- **Name and logo.** The app is now **Clocked**. The icon is a flat clock dial whose ring forms a "C", with an ember hand pointing into the gap, on a light tile. It's drawn in code (`Tools/make-icon.swift`), with a matching menu-bar glyph.
- **Onboarding.** A five-step welcome: what the app does, your subjects, permissions (explained *before* macOS asks), posture recordings, and goal and strictness. Reopen it from **Help → Welcome to Clocked**.
- **Learning tab.** Model status, its say in detection, validation scores, examples by source, Retrain and Reset.
- **Exam countdowns.** Right-click a subject → **Set Exam Date…** shows a "D-12" badge, red in the final week.
- **Break suggestions.** After 50 minutes of unbroken focus (configurable, or off) it suggests a break, to avoid burnout.
- **Focus by hour.** Stats shows focused vs. distracted minutes for each hour of the selected day, plus your longest unbroken focus.
- **Code structure.** The session controller is split by responsibility (`SessionController+Sensors`, `+Detection`, `+Escalation`, `+Learning`), and the tests live in `Tests/` with a one-command runner.

## 12. Ideas for later, in order of impact

1. **An iPhone companion app.** Apple's Screen Time APIs (Family Controls / Device Activity) can tell your Mac when TikTok or Instagram is actually open on your phone, and can block them during a session. That would turn "probably on your phone" into "definitely on TikTok", and give the network perfect labels to learn from. It needs Xcode and an Apple developer account.
2. **A model that looks at time.** Feed the last 30 seconds of features to a small 1-D convolution so it learns rhythms like scrolling vs. reading.
3. **Explanations.** Show which features pushed the network's estimate each second (for example via input gradients), next to the rules' reasons.
4. **Weekly review.** A short Sunday summary: study time by subject, when you drift most, and progress towards exam dates.
5. ~~Study-group leaderboards (YPT-style).~~ Done: optional, end-to-end encrypted study groups through a separate network-only helper (see the README).
