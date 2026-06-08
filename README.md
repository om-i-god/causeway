# causeway

slow generative music for norns — pad + lead + bass + secondary voice + VST + a sampler on a second norns

---

causeway is a generative MIDI/OSC sequencer for [norns](https://monome.org/norns/) built around slow, drifting melodic movement across up to six simultaneous voices. it is designed for live performance with a rack of hardware synths and/or a DAW on a connected computer. the internal PolySub engine generates a lush ambient pad while up to four external MIDI voices play lead, bass, secondary harmony, and a fifth VST/software synth voice over the network — and a sixth voice is sent as OSC to a second norns running the [Strata](https://github.com/om-i-god/strata) sampler.

the music moves like water finding its way downhill — unhurried, with gravity and memory. lead and bass lines drift through the scale with directional momentum, occasionally leaping or snapping back to root. the secondary voices can shadow the lead, echo it with a delay, or run a counter-melody in the opposite direction. drunk timing and optional syncopation give the whole thing a slightly-behind-the-beat organic feel.

the norns stops being a single instrument and becomes the conductor of whatever's wired to it: the onboard pad, a rack of hardware, a DAW track, a sampler on a second norns, and a screen full of reactive visuals — all from one calm stream.

---

## voices

| voice | output | role |
|---|---|---|
| **pad** | PolySub (norns audio out) | slow chord clusters, the harmonic foundation |
| **lead** | MIDI out | melodic drift — stepwise with momentum and occasional leaps |
| **bass** | MIDI out | pentatonic walking line with root gravity |
| **sec lead** | MIDI out | responds to lead — harmony, echo, or counter-melody |
| **VST** | MIDI out (network) | fifth voice for DAW/software synths |
| **strata** | OSC (network) | sixth voice — a sampler running on a second norns |

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

### strata
a sixth voice with its own generator (an independent random-walk position), sent as raw OSC to a second norns running the Strata sampler. it has three modes of its own:
- **melodic** — single notes
- **chordal** — a stacked chord
- **arp** — the chord rolled out as sub-divided steps

OSC messages are `/strata/noteon`, `/strata/noteoff`, and `/strata/alloff`. the destination host and port are set in the **NETWORK** params group (see below), so a DHCP-drifted IP never requires editing the script.

---

## controls

causeway uses a **modifier key pattern** — hold a key while turning an encoder to access parameters directly from the main screen without opening the params menu.

| input | action |
|---|---|
| **K1 held + E1** | cycle visual theme |
| **K2 held + E2** | root note |
| **K2 held + E3** | scale |
| **K3 held + E2** | wow depth |
| **K3 held + E3** | flutter depth |
| **K2 + K3 together** | play / stop |

the screen always shows the current root and scale name at the top left, a play indicator (`*`) at the bottom right when running, and two small bars (W / F) showing wow and flutter depth. holding K3 brightens the bars and shows numeric percentages. while K1 is held, the current theme name and index are shown top-left.

---

## wow / flutter

inspired by tape machine pitch instability (Generation Loss MkII). applied to the PolySub pad voices only — does not affect MIDI output.

- **wow** — slow Brownian pitch wander (mean-reverting random walk)
- **flutter** — faster sample-and-hold pitch variation (new target every 3 frames)

pitch modulation is applied by calling `engine.start()` on already-playing voices, which updates pitch through PolySub's built-in lag without retriggering the amplitude envelope.

---

## visual themes

the norns screen is a visualizer, not a control surface. there are **twenty** themes, **cycled live by holding K1 and turning E1** (the name and index show top-left while K1 is held). they redraw on their own metro independent of the musical clock and pause while the params menu is open.

every theme reads two shared signals: an envelope-followed `audio_level` from the pad (scales brightness, speed, motion across all themes) and a per-note trigger that dispatches to the current theme's burst hook. the result is that the screen is always moving because the music is moving — twenty exist for variety over a long, left-running session.

| theme | description |
|---|---|
| **pulse** | concentric rings expanding from center; a new ring spawns on each note trigger |
| **drift** | slow horizontal light bands crossing the screen |
| **field** | vertical noise columns (FFT-style); height scales with audio level |
| **hex** | hexagonal grid; random nodes light up and decay on note triggers |
| **stars** | warp-speed starfield with streak trails |
| **wave** | three interfering sine waves with a note-triggered shock |
| **rain** | streaking drops with wind drift and splashes |
| **spiral** | galaxy arms drawn as connected line segments |
| **liss** | harmonic oscilloscope (lissajous) curves, phase-morphing |
| **tunnel** | zooming concentric rectangles, warping on note |
| **bounce** | physics balls with trails; audio boosts velocity |
| **grid** | ripple waves on a dot grid, radiating from centre |
| **flow** | curl-noise vector-field particles |
| **morph** | a polygon morphing between shapes |
| **shatter** | crack lines that spawn on notes and slowly heal |
| **code** | matrix-style falling character columns |
| **orbit** | planets orbiting a star; audio perturbs the orbits |
| **terrain** | wireframe heightfield scrolling toward the viewer; a note raises a peak from the horizon |
| **lattice** | rotating wireframe icosahedron; scale breathes with audio, a note kicks the spin |
| **kaleido** | six-fold mirrored mandala of drifting particles; a note fires bright shards from the center |

all themes respond to the audio output level from the pad engine — brightness and movement scale with loudness.

---

## DAYDREAM — generative-video sidecar

an optional second OSC stream (the **DAYDREAM** params group, off by default) emits to a separate host/port, aimed at driving an external generative-video / diffusion "scope". it sends continuous control values derived from the music (a noise scale from wow, an attention-bias term that falls as audio rises, a context scale from the active-voice count), play/pause and cache-reset events, and — keyed off the current root note — a *text prompt* drawn from a built-in table of atmospheric scene descriptions. changing root or scale pushes a new prompt and a transition. it's a one-way feed; causeway doesn't read anything back. its host/port are set in the **NETWORK** params group.

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

### LEAD / BASS / SEC LEAD / VST / STRATA
each voice has:
| param | description |
|---|---|
| device | MIDI vport to send on (MIDI voices) |
| channel | MIDI channel (MIDI voices) |
| octave | central octave for note generation |
| rate | note trigger rate |
| note length | held duration |
| vel min / max | velocity range (random per note) |
| density | number of simultaneous notes (lead/sec/vst/strata) |

sec lead and VST also have:
| param | description |
|---|---|
| mode | harmony / echo / counter |
| harmony steps | scale steps offset from lead (harmony mode) |
| echo delay | delay in beats before re-triggering lead note (echo mode) |

strata instead has its own **mode** (melodic / chordal / arp) and no harmony-steps / echo-delay.

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

### DAYDREAM
| param | description |
|---|---|
| send OSC | on/off — enable the generative-video sidecar stream |

### VISUALS
| param | description |
|---|---|
| theme | starting theme (all 20; cycle live with K1+E1) |
| speed | visual animation speed |
| brightness | overall visual brightness |
| particles | particle count for particle-based themes |

### NETWORK
| param | description |
|---|---|
| strata host | IP of the second norns running Strata (default `192.168.1.133`) |
| strata port | Strata's matron OSC-in port (default `10111`) |
| scope host | IP of the DAYDREAM generative-video scope (default `192.168.1.229`) |
| scope port | DAYDREAM scope OSC port (default `52178`) |

host/port values persist in the pset, so once set on the device they survive reloads — no source edit needed when a DHCP lease drifts.

---

## MIDI routing

causeway sends on up to five MIDI outputs plus one OSC voice. each MIDI voice's device and channel are configured independently from params. devices are populated from the norns vport system at load time — any connected USB MIDI device or virtual MIDI port will appear.

**Ableton Link** sync is supported. causeway will respond to transport start/stop from a Link-connected DAW, delaying playback start to the next 4-bar boundary.

### connecting to a DAW over the network (rtpMIDI)

to send the VST voice to a computer running Ableton (or similar):

1. ensure `rtpmidid` is running on norns (`sudo systemctl status rtpmidid`)
2. on Windows, add norns manually in Tobias Erichsen's rtpMIDI app:
   - address: norns's IP (find it at SYSTEM > WIFI on norns), port `5004`
3. once connected, a virtual MIDI port will appear in the DAW — route the VST track's MIDI input to it
4. in causeway params, set the VST voice device to the `virtual` vport and channel to match the DAW track

### connecting to Strata on a second norns (OSC)

1. note the second norns's IP (SYSTEM > WIFI) and run the Strata script on it
2. in causeway's **NETWORK** params, set `strata host` to that IP (port `10111` is norns's matron OSC-in)
3. enable the **strata voice** in params

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
- (optional) a second norns running Strata for the sixth voice

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
