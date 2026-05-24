# Causeway → Strata OSC Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an independent generative voice to Causeway (Clear norns) that plays the Strata sampler on White norns over OSC, with a switchable melodic/chordal/arp character.

**Architecture:** Causeway gains a `strata_loop` coroutine mirroring `lead_loop`; it sends `/strata/noteon|noteoff|alloff` OSC to White's matron (UDP 10111). Strata gains an `osc.event` receiver mapping those to `inst:on/off`/`engine.all_off`. Both scripts otherwise unchanged; the SuperCollider engine is untouched.

**Tech Stack:** norns Lua (`osc`, `clock`, `params`, `midi`, `musicutil`), `luac` for syntax gating. Two repos: `~/dev/strata` → White (192.168.1.99), `~/dev/causeway` → Clear (192.168.1.100). SSH key `~/.ssh/norns`. `luac` at `/opt/homebrew/bin/luac`.

**Verification reality:** Both files reference norns runtime globals, so the local gate is `luac -p` (syntax). Behavior is verified live via the matron REPL (`/tmp/norns_repl.py`, honoring `NORNS_HOST`/`NORNS_PORT` env) and on-device listening. There is no pure unit-testable logic.

---

## File Structure

- `~/dev/strata/strata.lua` — add `osc.event` receiver (init) + clear it (cleanup). ~8 lines.
- `~/dev/causeway/causeway.lua` — add Strata voice: config+state+send helpers, note generator + loop, PARAMS group, lifecycle wiring. ~90 lines across 6 insertion points.

The REPL helper `/tmp/norns_repl.py` already exists and connects to a norns matron websocket; it reads `NORNS_HOST` (default 192.168.1.99) and `NORNS_PORT` (default 5555).

---

### Task 1: Strata OSC receiver (White)

**Files:**
- Modify: `~/dev/strata/strata.lua` (init + cleanup)

- [ ] **Step 1: Add the OSC receiver in init**

In `~/dev/strata/strata.lua`, find this line in `init()`:

```lua
function init()
  inst = Strata:new()
```

Replace it with:

```lua
function init()
  inst = Strata:new()

  -- OSC input: notes pushed from another norns/script over the network
  -- /strata/noteon {note,vel(1-127)}  /strata/noteoff {note}  /strata/alloff
  osc.event = function(path, args)
    if path == "/strata/noteon" then
      inst:on({ midi = args[1], velocity = args[2] })
    elseif path == "/strata/noteoff" then
      inst:off({ midi = args[1] })
    elseif path == "/strata/alloff" then
      engine.all_off()
    end
  end
```

- [ ] **Step 2: Clear the handler in cleanup**

Find:

```lua
function cleanup()
  if inst then engine.all_off() end
end
```

Replace with:

```lua
function cleanup()
  osc.event = nil
  if inst then engine.all_off() end
end
```

- [ ] **Step 3: Syntax-check**

Run: `cd ~/dev/strata && luac -p strata.lua && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
cd ~/dev/strata
git add strata.lua
git commit -m "feat: OSC note input (/strata/noteon|noteoff|alloff)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

- [ ] **Step 5: Deploy to White and reload**

```bash
rsync -a -e "ssh -i ~/.ssh/norns" ~/dev/strata/strata.lua we@192.168.1.99:/home/we/dust/code/strata/strata.lua
python3 /tmp/norns_repl.py 'norns.script.load("/home/we/dust/code/strata/strata.lua")'
sleep 3
python3 /tmp/norns_repl.py 'params:set("instrument", 3)'   # kurzweil_strings, clearly pitched
```
Expected: load output ends with `# script init`, no errors.

- [ ] **Step 6: Verify OSC delivery end-to-end (matron sends to its own OSC-in)**

```bash
python3 /tmp/norns_repl.py 'osc.send({"localhost",10111},"/strata/noteon",{60,100})'
sleep 2
python3 /tmp/norns_repl.py 'osc.send({"localhost",10111},"/strata/noteoff",{60})'
```
Expected: a note sounds on White when noteon is sent and stops on noteoff. (Audible confirmation that the `osc.event` path reaches the engine.) If silent, STOP — the receiver path is wrong; do not proceed to Causeway.

---

### Task 2: Causeway config, state, and send helpers (Clear)

**Files:**
- Modify: `~/dev/causeway/causeway.lua` (after the midi-device locals, ~line 53–61)

- [ ] **Step 1: Add config, state, and send helpers**

In `~/dev/causeway/causeway.lua`, find:

```lua
-- active notes per voice
local pad_active  = {}
local lead_active = {}
local bass_active = {}
local sec_active  = {}
local vst_active  = {}
```

Replace with:

```lua
-- active notes per voice
local pad_active  = {}
local lead_active = {}
local bass_active = {}
local sec_active  = {}
local vst_active  = {}
local strata_active = {}

-- strata (sampler on another norns, over OSC) -------------------------
local STRATA_HOST = "192.168.1.99"  -- White norns (edit if its IP drifts)
local STRATA_PORT = 10111           -- norns matron OSC-in
local strata_clock                  -- coroutine handle
local strata_pos = 1                -- independent random-walk position
local strata_dir = 1

local function strata_send(path, ...)
  if params:get("strata_on") ~= 2 then return end
  osc.send({STRATA_HOST, STRATA_PORT}, path, {...})
end

local function strata_note_on(note, vel)
  strata_send("/strata/noteon", note, vel)
  table.insert(strata_active, note)
end

local function strata_note_off(note)
  strata_send("/strata/noteoff", note)
  for i = #strata_active, 1, -1 do
    if strata_active[i] == note then table.remove(strata_active, i); break end
  end
end
```

- [ ] **Step 2: Syntax-check**

Run: `cd ~/dev/causeway && luac -p causeway.lua && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
cd ~/dev/causeway
git add causeway.lua
git commit -m "feat(strata): OSC config, state, and send helpers

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: Causeway note generator and loop (Clear)

**Files:**
- Modify: `~/dev/causeway/causeway.lua` (insert before `function init()`)

These reference helpers defined earlier in the file (`get_scale_notes`, `clamp`,
`build_chord`, `on_note_trigger`, `sync_offset`, `drunk_sleep`, `LEAD_RATES`,
`NOTE_LENS`, `playing`) and the helpers/state from Task 2.

- [ ] **Step 1: Insert the generator and loop**

Find:

```lua
function init()
  setup_params()
```

Replace with:

```lua
local function get_strata_note()
  local notes = get_scale_notes(params:get("oct_low"), params:get("oct_high"))
  if #notes == 0 then return nil end
  strata_pos = clamp(strata_pos, 1, #notes)
  local note = notes[strata_pos]
  if math.random() < 0.2 then strata_dir = -strata_dir end
  strata_pos = clamp(strata_pos + strata_dir * math.random(1, 3), 1, #notes)
  if strata_pos >= #notes then strata_dir = -1
  elseif strata_pos <= 1 then strata_dir = 1 end
  return note
end

-- strata voice: melodic (1), chordal (2), or arp (3), sent to Strata over OSC
local function strata_loop()
  while true do
    if playing then
      sync_offset()
      drunk_sleep()
      local rate = LEAD_RATES[params:get("strata_rate")]
      local len  = NOTE_LENS[params:get("strata_note_len")]
      local off_t = math.min(len, rate * 0.95) * 60 / clock.get_tempo()
      local mode = params:get("strata_mode")
      local base = get_strata_note()
      if base then
        base = clamp(base + (params:get("strata_oct") - 4) * 12, 0, 127)
        local vel = math.random(params:get("strata_vel_min"),
                      math.max(params:get("strata_vel_min"), params:get("strata_vel_max")))
        if mode == 1 then
          strata_note_on(base, vel)
          on_note_trigger()
          local played = base
          clock.run(function() clock.sleep(off_t); strata_note_off(played) end)
          clock.sync(rate)
        elseif mode == 2 then
          local chord = build_chord(base, params:get("strata_density"))
          for _, n in ipairs(chord) do strata_note_on(n, vel) end
          on_note_trigger()
          local played = chord
          clock.run(function()
            clock.sleep(off_t)
            for _, n in ipairs(played) do strata_note_off(n) end
          end)
          clock.sync(rate)
        else
          local chord = build_chord(base, params:get("strata_density"))
          local sub = rate / math.max(1, #chord)
          local sub_off = math.min(off_t, sub * 0.95 * 60 / clock.get_tempo())
          for _, n in ipairs(chord) do
            strata_note_on(n, vel)
            on_note_trigger()
            local played = n
            clock.run(function() clock.sleep(sub_off); strata_note_off(played) end)
            clock.sync(sub)
          end
        end
      else
        clock.sync(rate)
      end
    else
      clock.sleep(0.1)
    end
  end
end

function init()
  setup_params()
```

- [ ] **Step 2: Syntax-check**

Run: `cd ~/dev/causeway && luac -p causeway.lua && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
cd ~/dev/causeway
git add causeway.lua
git commit -m "feat(strata): independent generative voice (melodic/chordal/arp)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 4: Causeway PARAMS group and lifecycle wiring (Clear)

**Files:**
- Modify: `~/dev/causeway/causeway.lua` (PARAMS group, `active_voice_count`, `all_notes_off`, init clock start)

- [ ] **Step 1: Add the PARAMS group**

Find (end of the vst voice params):

```lua
  params:add_number("vst_density", "density", 1, 3, 1)
```

Replace with:

```lua
  params:add_number("vst_density", "density", 1, 3, 1)

  params:add_separator("strata (osc)")
  params:add_option("strata_on",   "strata voice", {"off","on"}, 1)
  params:add_option("strata_mode", "mode", {"melodic","chordal","arp"}, 1)
  params:add_option("strata_rate", "rate", LEAD_RATE_NAMES, 2)
  params:add_option("strata_note_len", "note length", LEN_NAMES, 6)
  params:add_number("strata_oct", "octave", 1, 7, 4)
  params:add_number("strata_density", "chord size", 1, 4, 3)
  params:add_number("strata_vel_min", "vel min", 1, 127, 50)
  params:add_number("strata_vel_max", "vel max", 1, 127, 100)
```

- [ ] **Step 2: Count the strata voice as active**

Find:

```lua
local function active_voice_count()
  return (#pad_active  > 0 and 1 or 0)
       + (#lead_active > 0 and 1 or 0)
       + (#bass_active > 0 and 1 or 0)
       + (#sec_active  > 0 and 1 or 0)
       + (#vst_active  > 0 and 1 or 0)
end
```

Replace with:

```lua
local function active_voice_count()
  return (#pad_active  > 0 and 1 or 0)
       + (#lead_active > 0 and 1 or 0)
       + (#bass_active > 0 and 1 or 0)
       + (#sec_active  > 0 and 1 or 0)
       + (#vst_active  > 0 and 1 or 0)
       + (#strata_active > 0 and 1 or 0)
end
```

- [ ] **Step 3: Release strata notes in all_notes_off (covers every stop path)**

`all_notes_off()` is called from the seq_state action, `clock.transport.stop`, the K-toggle, and `cleanup` — so adding the release here covers all of them. Find the end of `all_notes_off`:

```lua
  for _, n in ipairs(vst_active) do
    if midi_vst then midi_vst:note_off(n.note, 0, n.ch) end
  end
  vst_active = {}
end
```

Replace with:

```lua
  for _, n in ipairs(vst_active) do
    if midi_vst then midi_vst:note_off(n.note, 0, n.ch) end
  end
  vst_active = {}
  for _, note in ipairs(strata_active) do strata_send("/strata/noteoff", note) end
  strata_active = {}
  strata_send("/strata/alloff")
end
```

- [ ] **Step 4: Start the strata loop in init**

Find:

```lua
  vst_clock  = clock.run(vst_loop)
  fx_clock   = clock.run(fx_loop)
```

Replace with:

```lua
  vst_clock  = clock.run(vst_loop)
  strata_clock = clock.run(strata_loop)
  fx_clock   = clock.run(fx_loop)
```

- [ ] **Step 5: Syntax-check**

Run: `cd ~/dev/causeway && luac -p causeway.lua && echo OK`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
cd ~/dev/causeway
git add causeway.lua
git commit -m "feat(strata): PARAMS group + lifecycle wiring (count, all-off, clock)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 5: Deploy, integration test, and push

**Files:**
- Deploy: `~/dev/causeway/causeway.lua` → Clear; (`~/dev/strata/strata.lua` already deployed in Task 1)

- [ ] **Step 1: Back up the device copy (matches existing backup convention)**

```bash
ssh -i ~/.ssh/norns we@192.168.1.100 'cp /home/we/dust/code/causeway/causeway.lua /home/we/dust/code/causeway/causeway_backup_'$(date +%Y%m%d)'_preosc.lua && echo backed up'
```
Expected: `backed up`

- [ ] **Step 2: Deploy and reload Causeway on Clear**

```bash
rsync -a -e "ssh -i ~/.ssh/norns" ~/dev/causeway/causeway.lua we@192.168.1.100:/home/we/dust/code/causeway/causeway.lua
NORNS_HOST=192.168.1.100 python3 /tmp/norns_repl.py 'norns.script.load("/home/we/dust/code/causeway/causeway.lua")'
```
Expected: load output ends with `# script init`, no Lua errors. If errors appear, STOP and fix.

- [ ] **Step 3: Cross-device OSC smoke test (Clear → White), bypassing the voice**

```bash
# make sure White's Strata is loaded + on a pitched instrument
python3 /tmp/norns_repl.py 'params:set("instrument", 3)'
# send a note FROM Clear's matron TO White
NORNS_HOST=192.168.1.100 python3 /tmp/norns_repl.py 'osc.send({"192.168.1.99",10111},"/strata/noteon",{62,100})'
sleep 2
NORNS_HOST=192.168.1.100 python3 /tmp/norns_repl.py 'osc.send({"192.168.1.99",10111},"/strata/noteoff",{62})'
```
Expected: White audibly plays a note triggered from Clear. Confirms network path before involving the generative voice.

- [ ] **Step 4: Enable the voice and verify each mode (user listens)**

```bash
NORNS_HOST=192.168.1.100 python3 /tmp/norns_repl.py 'params:set("strata_on", 2); params:set("seq_state", 2)'   # voice on, transport playing
```
Then, spaced out so the difference is audible:
```bash
NORNS_HOST=192.168.1.100 python3 /tmp/norns_repl.py 'params:set("strata_mode", 1)'   # melodic
sleep 12
NORNS_HOST=192.168.1.100 python3 /tmp/norns_repl.py 'params:set("strata_mode", 2)'   # chordal
sleep 12
NORNS_HOST=192.168.1.100 python3 /tmp/norns_repl.py 'params:set("strata_mode", 3)'   # arp
```
Expected (user confirms): White plays generative notes from Causeway; melodic = single notes, chordal = stacks, arp = rolled chords. Note timing follows Causeway's clock.

- [ ] **Step 5: Verify panic / stop**

```bash
NORNS_HOST=192.168.1.100 python3 /tmp/norns_repl.py 'params:set("seq_state", 1)'   # stop transport
```
Expected: White goes silent within a beat (all_notes_off → `/strata/alloff`). No hung notes.

- [ ] **Step 6: Push both repos**

```bash
cd ~/dev/strata && git push
cd ~/dev/causeway && git push -u origin HEAD
```
Expected: both push successfully. (`~/dev/causeway` push includes the device-baseline sync commit + the feature commits.)

---

## Self-Review Notes

- **Spec coverage:** OSC protocol (Task 1 receiver + Task 2 send helpers); independent generator (Task 3 `get_strata_note`); melodic/chordal/arp modes (Task 3 loop branches); PARAMS group incl. `strata_on`/`strata_mode`/rate/len/oct/density/vel (Task 4 Step 1); `active_voice_count` (Task 4 Step 2); panic + stop coverage via `all_notes_off` (Task 4 Step 3); loop start (Task 4 Step 4); config/IP locals (Task 2); Strata receiver + cleanup (Task 1); deploy/back-up/push (Task 5). All spec sections mapped.
- **Deviation from spec (intentional, DRY):** the spec sketched a separate `strata_all_off()`; the plan folds that release inline into `all_notes_off` so all four existing stop paths are covered from one place. Behavior identical (`/strata/noteoff` per active note + `/strata/alloff`).
- **Type/name consistency:** OSC paths `/strata/noteon|noteoff|alloff` and arg order `{note, vel}` match between Task 1 (receiver) and Tasks 2–4 (sender). Param ids (`strata_on/mode/rate/note_len/oct/density/vel_min/vel_max`) are identical across Task 3 (reads) and Task 4 (declarations). `strata_active`, `strata_pos`, `strata_dir`, `strata_clock`, `strata_send`, `strata_note_on`, `strata_note_off` consistent across tasks. `LEAD_RATES`/`LEAD_RATE_NAMES`/`NOTE_LENS`/`LEN_NAMES` reused from existing definitions.
- **Out of scope (per spec):** tempo sync between devices, velocity curves, guaranteed delivery, bidirectional control.
```
