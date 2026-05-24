# Causeway → Strata OSC Bridge

**Date:** 2026-05-24
**Status:** Design approved, pending implementation plan
**Spans two devices/repos:** Causeway on Clear norns (`~/dev/causeway`), Strata on White norns (`~/dev/strata`).

## Goal

Add a new, independent generative voice to Causeway that plays the **Strata** sampler
on a *different* norns (White) over the network via OSC — with a switchable character
(melodic / chordal / arpeggiated). No extra hardware; reuses Causeway's existing
clock/scale/timing machinery and its already-present `osc` usage.

## Why OSC (not hardware MIDI)

Both ends are norns on the same wifi. norns matron already listens for OSC on UDP
**10111** and dispatches to a global `osc.event(path, args, from)`. Causeway already
sends OSC to a visualizer (`osc_emit` → `192.168.1.229:52178`). A second destination
(White norns) needs no new dependencies and no USB-MIDI interface on Clear.

## Architecture

```
CAUSEWAY (Clear 192.168.1.100)                  STRATA (White 192.168.1.99)
──────────────────────────────                  ───────────────────────────
strata_loop()  coroutine                         osc.event(path,args)
  get_strata_note()  (own random walk)             /strata/noteon  {note,vel} -> inst:on
  branch on strata_mode:                           /strata/noteoff {note}     -> inst:off
    melodic | chordal | arp                        /strata/alloff             -> engine.all_off
  strata_note_on/off  ──OSC UDP :10111──►  ────────►
  clock.sync(strata_rate)
```

Two isolated additions, one per script. The engine (`Engine_Strata.sc`) is unchanged.

## OSC protocol

| Path              | Args                | Meaning                          |
|-------------------|---------------------|----------------------------------|
| `/strata/noteon`  | `int note, int vel` | note on (vel 1–127)              |
| `/strata/noteoff` | `int note`          | note off                         |
| `/strata/alloff`  | *(none)*            | panic — release everything       |

Transport: `osc.send({STRATA_HOST, STRATA_PORT}, path, {args})`. Best-effort UDP.

## Causeway side (Clear) — `causeway.lua`

Built to mirror the existing `lead_loop` so it inherits `playing`, `sync_offset`,
`drunk_sleep`, and `clock.sync` behavior.

### Config (editable locals, mirroring `OSC_HOST`)
```lua
local STRATA_HOST = "192.168.1.99"  -- White norns (edit if its IP drifts)
local STRATA_PORT = 10111           -- norns matron OSC-in
```

### State
```lua
local strata_active = {}     -- notes currently sounding (for all-off + count)
local strata_clock           -- the coroutine handle
local strata_pos = 1         -- random-walk position (independent from lead)
local strata_dir = 1
```

### Send helpers (gated by strata_on)
```lua
local function strata_send(path, ...)
  if params:get("strata_on") ~= 2 then return end
  osc.send({STRATA_HOST, STRATA_PORT}, path, {...})
end
local function strata_note_on(note, vel)
  strata_send("/strata/noteon", note, vel); table.insert(strata_active, note)
end
local function strata_note_off(note)
  strata_send("/strata/noteoff", note)
  for i=#strata_active,1,-1 do if strata_active[i]==note then table.remove(strata_active,i); break end end
end
local function strata_all_off()
  for _,n in ipairs(strata_active) do strata_send("/strata/noteoff", n) end
  strata_active = {}; strata_send("/strata/alloff")
end
```

### Independent note generator
```lua
local function get_strata_note()
  local notes = get_scale_notes(params:get("oct_low"), params:get("oct_high"))
  if #notes == 0 then return nil end
  strata_pos = clamp(strata_pos, 1, #notes)
  local note = notes[strata_pos]
  if math.random() < 0.2 then strata_dir = -strata_dir end
  strata_pos = clamp(strata_pos + strata_dir * math.random(1,3), 1, #notes)
  if strata_pos >= #notes then strata_dir = -1 elseif strata_pos <= 1 then strata_dir = 1 end
  return note
end
```

### Loop (branches on `strata_mode`: 1 melodic, 2 chordal, 3 arp)
- Common: `rate = LEAD_RATES[strata_rate]`, `len = NOTE_LENS[strata_note_len]`,
  `off_t = min(len, rate*0.95) * 60/tempo`, octave offset `(strata_oct-4)*12`,
  random velocity in `[strata_vel_min, strata_vel_max]`.
- **melodic:** single note on, schedule note_off after `off_t`, `clock.sync(rate)`.
- **chordal:** `build_chord(base, strata_density)`, all on, all off after `off_t`, `clock.sync(rate)`.
- **arp:** `build_chord(...)`, then for each chord note: note_on, schedule short
  note_off, `clock.sync(rate / #chord)` — rolls the chord across the step.
- Calls `on_note_trigger()` so the Clear visuals respond to the new voice too.

### PARAMS group "strata (osc)"
```lua
params:add_separator("strata (osc)")
params:add_option("strata_on",   "strata voice", {"off","on"}, 1)   -- default off
params:add_option("strata_mode", "mode", {"melodic","chordal","arp"}, 1)
params:add_option("strata_rate", "rate", LEAD_RATE_NAMES, 2)
params:add_option("strata_note_len", "note length", LEN_NAMES, 6)
params:add_number("strata_oct", "octave", 1, 7, 4)
params:add_number("strata_density", "chord size", 1, 4, 3)
params:add_number("strata_vel_min", "vel min", 1, 127, 50)
params:add_number("strata_vel_max", "vel max", 1, 127, 100)
```

### Lifecycle wiring
- Start `strata_clock = clock.run(strata_loop)` alongside the other voice clocks in `init`.
- Include `strata_active` in `active_voice_count`.
- Call `strata_all_off()` wherever the transport stops / in `cleanup` (next to the
  existing `all_notes_off`).

## Strata side (White) — `strata.lua`

Add an OSC receiver in `init()` (after `inst` is created):
```lua
osc.event = function(path, args)
  if path == "/strata/noteon" then inst:on({ midi = args[1], velocity = args[2] })
  elseif path == "/strata/noteoff" then inst:off({ midi = args[1] })
  elseif path == "/strata/alloff" then engine.all_off() end
end
```
Clear it in `cleanup()` with `osc.event = nil`. No engine changes. Velocity arrives
0–127 and is scaled by the existing `inst:on` (`vel/127`).

## Error handling / edge cases

- **Dropped note-off (UDP):** could hang a note. Mitigated by `strata_all_off()` on stop
  and the `/strata/alloff` panic path.
- **Wrong/stale IP:** `STRATA_HOST` is a documented editable local; no crash if wrong,
  just silence on White.
- **strata_on = off:** `strata_send` early-returns, so the loop runs but emits nothing.
- **Empty scale:** `get_strata_note` returns nil → loop just `clock.sync`s, no note.

## Testing

- **Syntax gates:** `luac -p causeway.lua` and `luac -p strata.lua` on the Mac.
- **OSC delivery probe:** from Clear's matron REPL, `osc.send({"192.168.1.99",10111},
  "/strata/noteon",{60,100})` and confirm White's Strata plays (it played a test note
  via REPL already).
- **Integration:** run Causeway (Clear) + Strata (White); enable `strata_on`; confirm
  notes sound on White and cycle through melodic/chordal/arp; stop Causeway → silence.
- **Hardware playtest:** deferred to user (live on both devices).

## Non-goals (v1)

- Clock/tempo sync between the two norns (each free-runs; Causeway drives note timing).
- Velocity curve / humanization beyond the existing min/max randomization.
- Guaranteed delivery / MIDI clock / transport over OSC.
- Bidirectional control (White → Clear).

## Code management

`causeway.lua` was previously only on Clear and diverged from the stale GitHub v1.0;
the current 2453-line device version has been committed to `~/dev/causeway` as the new
baseline (commit `dae1ef0`). Implementation edits happen in that repo, deploy back to
Clear (with a `causeway_backup_YYYYMMDD.lua` device backup), and push to GitHub. The
Strata-side change lands in `~/dev/strata` and deploys to White.
