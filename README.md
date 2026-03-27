# causeway

slow generative music for norns — pad + lead + bass + secondary voice + VST

---

causeway is a generative MIDI sequencer for [norns](https://monome.org/norns/) built around slow, drifting melodic movement across up to five simultaneous voices. it is designed for live performance with a rack of hardware synths and/or a DAW on a connected computer. the internal PolySub engine generates a lush ambient pad while up to four external MIDI voices play lead, bass, secondary harmony, and a fifth VST/software synth voice over the network.

the music moves like water finding its way downhill — unhurried, with gravity and memory. lead and bass lines drift through the scale with directional momentum, occasionally leaping or snapping back to root. the secondary voices can shadow the lead, echo it with a delay, or run a counter-melody in the opposite direction. drunk timing and optional syncopation give the whole thing a slightly-behind-the-beat organic feel.

---

## voices

| voice | output | role |
|---|---|---|
| **pad** | PolySub (norns audio out) | slow chord clusters, the harmonic foundation |
| **lead** | MIDI out | melodic drift — stepwise with momentum and occasional leaps |
| **bass** | MIDI out | pentatonic walking line with root gravity |
| **sec lead** | MIDI out | responds to lead — harmony, echo, or counter-melody |
| **VST** | MIDI out (network) | fifth voice for DAW/software synths |

### lead
moves through the scale one step at a time, occasionally making a larger leap (2–3 scale degrees). direction reverses near the top and bottom of the range. repeating the same note twice is avoided.

### bass
a probabilistic walking line with three behaviors:
- **9% rest** — silence is part of the groove
- **28% root gravity** — snaps to the nearest root note in range, keeping things grounded
- **63% scale walking** — drifts through the pentatonic degrees with directional momentum
- **13% chance** of octave displacement per step — drops the note down an octave for depth

### sec lead modes
- **harmony** — plays a fixed number of scale steps above/below the lead note simultaneously
- **echo** — plays the same note as lead delayed by a set number of beats
- **counter** — an independent drift walking in the opposite direction to lead

### VST
same architecture as sec lead (harmony / echo / counter modes), routed to a separate MIDI output intended for a computer running a DAW.

---

## controls

causeway uses a **modifier key pattern** — hold a key while turning an encoder to access parameters directly from the main screen without opening the params menu.

| input | action |
|---|---|
| **K2 held + E2** | root note |
| **K2 held + E3** | scale |
| **K3 held + E2** | wow depth |
| **K3 held + E3** | flutter depth |

the screen always shows the current root and scale name at the top left, a play indicator (`*`) at the bottom right when running, and two small bars (W / F) showing wow and flutter depth. holding K3 brightens the bars and shows numeric percentages.

---

## wow / flutter

inspired by tape machine pitch instability (Generation Loss MkII). applied to the PolySub pad voices only — does not affect MIDI output.

- **wow** — slow Brownian pitch wander (mean-reverting random walk)
- **flutter** — faster sample-and-hold pitch variation (new target every 3 frames)

pitch modulation is applied by calling `engine.start()` on already-playing voices, which updates pitch through PolySub's built-in lag without retriggering the amplitude envelope.

---

## visual themes

four visual themes, selectable from params:

| theme | description |
|---|---|
| **pulse** | concentric rings expanding from center; a new ring spawns on each note trigger |
| **drift** | slow horizontal light bands crossing the screen |
| **field** | vertical noise columns (FFT-style); height scales with audio level |
| **hex** | hexagonal grid; random nodes light up and decay on note triggers |

all themes respond to the audio output level from the pad engine — brightness and movement scale with loudness.

---

## params

### KEY + SCALE
| param | description |
|---|---|
| root | root note (C – B) |
| scale | scale type (all musicutil scales available; default: pentatonic minor) |
| octave low / high | playable range for lead, pad, sec voices |

### PAD
| param | description |
|---|---|
| pad engine | on/off |
| amp | output level (0–100%) |
| rate | note trigger rate (2–16 bars) |
| note length | held duration (1/32 note – 8 bars) |
| density | number of simultaneous notes (1–3) |
| release ms | PolySub amplitude release time |
| cutoff hz | PolySub filter cutoff |
| detune | PolySub stereo oscillator spread |

### LEAD / BASS / SEC LEAD / VST
each voice has:
| param | description |
|---|---|
| device | MIDI vport to send on |
| channel | MIDI channel |
| octave | central octave for note generation |
| rate | note trigger rate |
| note length | held duration |
| vel min / max | velocity range (random per note) |
| density | number of simultaneous notes (lead/sec/vst) |

sec lead and VST also have:
| param | description |
|---|---|
| mode | harmony / echo / counter |
| harmony steps | scale steps offset from lead (harmony mode) |
| echo delay | delay in beats before re-triggering lead note (echo mode) |

### TIMING
| param | description |
|---|---|
| state | stopped / playing |
| drunk | onset randomisation — adds up to 200ms of random delay before each lead/bass note (0 = grid-locked) |
| syncopation | off / soft / medium / hard — randomly offsets note onset by half or full beats |

### WOW / FLUTTER
| param | description |
|---|---|
| wow depth | amount of slow Brownian pitch wander (0–100%) |
| flutter depth | amount of fast sample-and-hold pitch variation (0–100%) |

### VISUALS
| param | description |
|---|---|
| theme | pulse / drift / field / hex |
| speed | visual animation speed |
| brightness | overall visual brightness |

---

## MIDI routing

causeway sends on up to five MIDI outputs. each voice's device and channel are configured independently from params. devices are populated from the norns vport system at load time — any connected USB MIDI device or virtual MIDI port will appear.

**Ableton Link** sync is supported. causeway will respond to transport start/stop from a Link-connected DAW, delaying playback start to the next 4-bar boundary.

### connecting to a DAW over the network (rtpMIDI)

to send the VST voice to a computer running Ableton (or similar):

1. ensure `rtpmidid` is running on norns (`sudo systemctl status rtpmidid`)
2. on Windows, add norns manually in Tobias Erichsen's rtpMIDI app:
   - address: norns's IP (find it at SYSTEM > WIFI on norns), port `5004`
3. once connected, a virtual MIDI port will appear in the DAW — route the VST track's MIDI input to it
4. in causeway params, set the VST voice device to the `virtual` vport and channel to match the DAW track

---

## engine

causeway uses the **PolySub** engine for the pad voice. default preset values are tuned for a slow ambient pad:

```
ampAtk=4.0  ampRel=5.0  cut=2.5  cutAtk=2.0  cutEnvAmt=0.4
detune=2.0  hzLag=0.01  shape=0.2  timbre=0.45  sub=0.35  fgain=0.3  width=0.9
```

`hzLag` is set to 10ms so wow/flutter pitch steps land cleanly without audible stepping.

---

## requirements

- [norns](https://monome.org/norns/) (any version)
- PolySub engine (included with norns)
- one or more USB MIDI synths, or a DAW connected via rtpMIDI

---

## installation

copy `causeway.lua` to `~/dust/code/causeway/causeway.lua` on norns, then select it from the norns script menu.

via maiden REPL:
```
os.execute("mkdir -p ~/dust/code/causeway")
```
then transfer the file over SSH or via the maiden file browser.

---

## license

MIT
