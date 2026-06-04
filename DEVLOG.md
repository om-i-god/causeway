# causeway — devlog

A running design log, written from the project's current state rather than as a
dated release history. The repo's git history is short and uneven — an initial
v1.0 commit on 2026-03-27, then a long gap before the on-device version (a much
larger build) was synced back into the repo on 2026-05-24, followed by the
Strata OSC work that same week. So dates below are noted only where the git log
actually supports them; everything else is described from what the code does
now.

## The idea

causeway is a generative music machine for [norns](https://monome.org/norns/)
whose whole point is to play *everywhere at once*. One slow, drifting harmonic
stream is generated on the norns and fanned out simultaneously to the onboard
PolySub engine, up to three external MIDI synths, a fourth MIDI port aimed at a
DAW over the network, and — most recently — a fifth voice sent as OSC to a
second norns running the Strata sampler. The norns stops being a single
instrument and becomes the conductor of whatever's wired to it.

The music itself is meant to move "like water finding its way downhill"
(the script's own header words it that way): unhurried, gravitational, with
memory. Nothing is sequenced note-for-note. Lines drift through a scale with
directional momentum, occasionally leap, occasionally snap back to root, and
the timing is deliberately loosened so it never sounds quantized. The name fits
— a long, low, deliberate path across water.

## The voices

Each voice runs as its own independent `clock.run` loop, syncing to the norns
clock via `clock.sync` at its own bar-rate. They share a key, a scale, and an
octave window, but they each make their own decisions.

- **pad** — the only voice that makes sound on the norns itself. It plays slow
  chord clusters through PolySub. `get_pad_notes` picks a root from the middle
  third of the available scale notes and stacks notes upward by twos with a
  little jitter; density (1–3) controls how many it stacks.
- **lead** — `get_lead_note` is the melodic core. Most steps it walks one scale
  degree in its current direction; ~12% of the time it leaps two or three
  degrees; the rest of the time it reverses direction. It flips direction near
  the top and bottom of its range, and it refuses to repeat the same note
  twice. The single lead pitch is then built into a chord by `build_chord`
  before being sent.
- **bass** — `get_bass_note` is a weighted walking line: a 9% chance of a rest
  ("silence is part of the groove," per the comment), a 28% chance of *root
  gravity* that snaps to the nearest root note in range, and otherwise a
  momentum walk through the scale with a 13% chance of dropping an octave for
  depth. It also dodges consecutive duplicates. Bass has a density-as-percent
  control — a probability that any given step fires at all.
- **sec lead** — a reactive voice with three modes. *harmony* offsets the
  lead's last note by a fixed number of scale steps; *echo* replays the lead's
  last note after a delay in beats; *counter* runs its own drift walking the
  opposite direction. It voices at 80% of the lead's velocity to sit underneath.
- **VST** — structurally identical to sec lead (same three modes, same logic),
  but on its own MIDI port and channel, intended for a software synth in a DAW.

`lead_last` is the shared hinge here: it's the most recently played lead note,
and both sec lead and VST read it to shadow or echo the melody. That's how the
voices stay related without being locked together.

## Timing — drunk and syncopated

Two layers loosen the grid, applied before the lead, bass, and Strata steps:

- **drunk** adds up to ~200ms of random delay before a note
  (`drunk_sleep` scales a `clock.sleep` by the drunk amount), so onsets scatter
  slightly behind the beat.
- **syncopation** (soft / medium / hard) probabilistically shifts a note onto
  the off-beat — a half-beat shift most of the time, with hard mode occasionally
  pushing a full beat. The probabilities climb 25% / 50% / 75% across the modes.

Neither touches the pad, which stays on its slow grid as the harmonic anchor.

## Playing everywhere at once

The defining structural choice is that there is no single output. Each MIDI
voice carries its own device (a norns vport) and channel, configured
independently in params, and each maintains its own active-notes table so
note-offs always land. The pad speaks `engine.start` / `engine.stop` with raw
frequency; the four MIDI voices speak `midi:note_on/off` on their channels;
`all_notes_off` sweeps every destination — engine, all four MIDI ports, and
Strata — whenever playback stops or the script cleans up, so nothing hangs.

Network output is part of the design rather than bolted on. The VST voice is
meant to reach a DAW through rtpMIDI (a virtual vport on the norns side). And
the **Strata voice** sends raw OSC messages (`/strata/noteon`, `/strata/noteoff`,
`/strata/alloff`) directly to a second norns's matron OSC port — its host IP is
a hardcoded constant near the top of the file, with a comment noting it must be
edited when that device's DHCP lease drifts. The Strata voice has its own
generator (`get_strata_note`, an independent random-walk position) and three
modes of its own: melodic (single notes), chordal (a `build_chord` stack), and
arp (the chord rolled out as sub-divided steps via nested `clock.sync`). Per the
git log this bridge was the most recent body of work, landing on the
`strata-osc-voice` branch and merged on 2026-05-26.

## Wow / flutter

A tape-style pitch-instability layer runs in `fx_loop` at ~60fps, and it applies
*only to the PolySub pad* — the MIDI voices are untouched. **wow** is a slow,
mean-reverting Brownian wander; **flutter** is faster sample-and-hold variation
(a new random target every few frames). The two combine into a semitone offset
that's re-applied to every currently-sounding pad voice by calling
`engine.start` again on it — updating pitch through PolySub's built-in lag
without retriggering the amplitude envelope. Flutter also lightly amplitude-
modulates the pad. It's the one effect with its own front-panel UI: two small
W/F bars at the bottom of the screen, brightening with numeric percentages while
K3 is held.

## The screen — twenty audioreactive themes

The norns screen here is a visualizer, not a control surface. There are
twenty themes — pulse, drift, field, hex, stars, wave, rain, spiral, liss,
tunnel, bounce, grid, flow, morph, shatter, code, orbit, terrain, lattice, and
kaleido — and they're cycled
live by **holding K1 and turning E1**, with the theme name and index shown
top-left while K1 is held. They redraw on their own metro at 1/20s, independent
of the musical clock, and they pause when the norns params menu is open.

Every theme reads from the same two shared signals. The first is `audio_level`,
an asymmetric envelope-followed reading of the pad's output (`amp_out_l` poll,
fast attack / slow release) that scales brightness, speed, warp, and motion
across all of them. The second is `on_note_trigger`, fired by every voice on
every note: it dispatches to the current theme's trigger hook, so a note can
spawn a ring burst (pulse), a crack (shatter), a galaxy-arm flash (spiral), a
new lissajous ratio, a tunnel lurch, and so on. The result is that the screen is
always moving because the music is moving. Twenty exists for variety over a
long session — causeway is built to be left running, and one visualizer would
wear thin.

The three newest themes (2026-06-03) lean on 3D-ish geometry: **terrain** is a
wireframe heightfield scrolling toward the viewer, ridge amplitude scaling with
level and a note raising a peak that rolls up from the horizon; **lattice** is a
rotating wireframe icosahedron (12 vertices / 30 edges) whose scale breathes with
the audio and whose spin gets a decaying kick on each note; **kaleido** is a
six-fold mirrored mandala of drifting particles that bloom outward with level and
fire bright shards from the center on note triggers. They're namespaced as global
tables rather than file-local functions — the main chunk had already hit Lua's
200-local-per-chunk limit, so new top-level locals wouldn't compile.

## DAYDREAM — the OSC sidecar

There's a second, optional OSC stream (the "DAYDREAM" params group, off by
default) that emits to a separate host/port from `fx_loop` at ~15Hz. It's
clearly aimed at driving an external generative-video / diffusion "scope": it
sends continuous control values derived from the music (a noise scale from wow,
an attention-bias term that falls as audio rises, a context scale from the
active-voice count) plus play/pause and cache-reset events, and — keyed off the
current root note — a *text prompt* from a built-in table of twelve atmospheric
scene descriptions ("iron bridge in fog, rust and rain"; "winter morning, bare
trees, frost"). Changing root or scale pushes a new prompt and a transition. It's
a one-way feed; causeway doesn't read anything back.

## Controls

The performance gestures all live on held-key + encoder, so you never have to
open the menu mid-flight:

- **K1 + E1** — cycle visual theme
- **K2 + E2 / E3** — root note / scale
- **K3 + E2 / E3** — wow depth / flutter depth
- **K2 + K3 together** — play / stop toggle

The main screen otherwise shows root and scale name (top-left), a `*` play
indicator (bottom-right), and the W/F bars. Everything else — per-voice devices,
channels, octaves, rates, note lengths, velocities, densities, modes, the Strata
voice, drunk and syncopation, the DAYDREAM toggle — is set in params before you
start.

## Sync

causeway honors Ableton Link transport. `clock.link.set_start_stop_sync(true)`
plus `clock.transport.start/stop` hooks mean a Link-connected DAW can start and
stop it; on start it waits for the next 4-bar boundary before letting the voices
play, so it falls into the bar grid rather than jumping in mid-measure. On stop
it kills all notes everywhere.

## Design intent

causeway is a hub, not a soloist. The generative model is deliberately modest —
scale, weighted drift, root gravity, a shared `lead_last` the harmony voices
hang off of — because the interesting part isn't the cleverness of any one line.
It's that a single calm stream can light up the onboard pad, a rack of hardware,
a DAW track, a sampler on a second norns, and a screen full of reactive
visuals all at once, each contributing its own voice to a piece nobody is
playing by hand. You set it up, point its outputs where you want them, and let
the water find its way down.
