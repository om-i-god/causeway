-- causeway
-- slow generative music for multiple synths
-- pad + lead + bass + secondary voice
-- v1.0

engine.name = "PolySub"

local musicutil = require("musicutil")
local osc        = require("osc")

------------------------------------------------------------------------
-- constants
------------------------------------------------------------------------

local PAD_RATES       = {2, 4, 6, 8, 16}
local LEAD_RATES      = {0.5, 1, 2, 4, 6, 8, 16}
local BASS_RATES      = {2, 4, 6, 8, 16}
local SEC_RATES       = {0.5, 1, 2, 4, 6, 8, 16}
local NOTE_LENS       = {0.125, 0.25, 0.5, 1, 2, 4, 8, 16, 32}

local PAD_RATE_NAMES  = {"2 bars","4 bars","6 bars","8 bars","16 bars"}
local LEAD_RATE_NAMES = {"1/2 bar","1 bar","2 bars","4 bars","6 bars","8 bars","16 bars"}
local BASS_RATE_NAMES = {"2 bars","4 bars","6 bars","8 bars","16 bars"}
local SEC_RATE_NAMES  = {"1/2 bar","1 bar","2 bars","4 bars","6 bars","8 bars","16 bars"}
local LEN_NAMES       = {"1/32","1/16","1/8","1/4","1/2","1 bar","2 bars","4 bars","8 bars"}

-- network hosts (strata sampler + DAYDREAM scope) are configured in the
-- NETWORK params group, so DHCP drift no longer requires a source edit.

------------------------------------------------------------------------
-- state
------------------------------------------------------------------------

local playing    = false
local root_note  = 9     -- A
local scale_index = 1

local default_scale = 5
for i, s in ipairs(musicutil.SCALES) do
  if string.lower(s.name) == "pentatonic minor" then
    default_scale = i; break
  end
end

local k1_held = false
local k2_held = false
local k3_held  = false

-- midi devices
local midi_lead = nil
local midi_bass = nil
local midi_sec  = nil
local midi_vst  = nil

-- active notes per voice
local pad_active  = {}
local lead_active = {}
local bass_active = {}
local sec_active  = {}
local vst_active  = {}
local strata_active = {}

-- strata (sampler on another norns, over OSC) -------------------------
-- host/port live in the NETWORK params group (strata_host / strata_port)
local strata_clock                  -- coroutine handle
local strata_pos = 1                -- independent random-walk position
local strata_dir = 1

local function strata_send(path, ...)
  if params:get("strata_on") ~= 2 then return end
  osc.send({params:get("strata_host"), params:get("strata_port")}, path, {...})
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


-- lead melodic drift
local lead_pos  = 1
local lead_dir  = 1
local lead_last = nil

-- bass drift state
local bass_pos  = 1
local bass_dir  = 1
local bass_last = nil

-- sec counter drift (counter mode)
local sec_pos = 1
local sec_dir = -1

-- vst counter drift (counter mode)
local vst_pos = 1
local vst_dir = -1

-- wow/flutter
local playing_voices = {}
local wow_val        = 0
local flutter_val    = 0
local flutter_target = 0
local flutter_hold   = 0
local FLUTTER_HOLD   = 3

-- audio reactivity
local audio_level        = 0
local audio_level_smooth = 0

-- clocks
local pad_clock  = nil
local lead_clock = nil
local bass_clock = nil
local sec_clock  = nil
local vst_clock  = nil
local fx_clock   = nil
local draw_clock = nil

-- osc
local osc_tick         = 0
local last_playing_osc = false
local last_root_osc    = -1
local last_scale_osc   = -1

-- visuals
local time_val    = 0
local theme_index = 1
local theme_names = {"pulse","drift","field","hex","stars","wave","rain","spiral","liss","tunnel","bounce","grid","flow","morph","shatter","code","orbit","terrain","lattice","kaleido"}

-- V: single namespace for all per-theme animation state. Holds the state that
-- used to be ~30 separate top-level locals — collapsing them here keeps the main
-- chunk well under Lua's 200-local-per-chunk limit so new themes can be added.
local V = {}

V.rings      = {}
V.bands      = {}
V.columns    = {}
V.hex_nodes  = {}
local stars      = {}
V.rain_drops = {}
V.bounce_balls  = {}
V.grid_nodes    = {}
V.spiral_points = {}
V.wave_phase    = 0
V.wave_phase2   = 0
V.wave_shock    = 0
V.spiral_angle  = 0
V.liss_phase    = 0
V.liss_ratio_i  = 1
V.tunnel_z      = 0
V.grid_wave_t   = 0
V.nova_rings      = {}
V.splash_particles = {}
V.liss_history    = {}
V.spiral_dust     = {}
V.shatter_flashes = {}
V.code_highlight  = 1
V.code_boost      = 0
V.tunnel_rot      = 0
V.grid_wave2_t    = 0
V.grid_src2_x     = 20
V.grid_src2_y     = 10
V.morph_vphase    = {}

-- 3D-ish themes: each table holds the theme's state + its init/draw/trigger funcs.
local terrain = { rows = {}, N = 10, S = 12 }
local lattice = { verts = {}, edges = {}, rx = 0, ry = 0, kick = 0, flash = 0 }
local kaleido = { parts = {}, shards = {} }

V.LISS_RATIOS = {{1,2},{2,3},{3,4},{3,5},{4,5},{1,3},{2,5}}

------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function get_scale_notes(oct_lo, oct_hi)
  local scale = musicutil.SCALES[scale_index]
  local notes = {}
  for oct = oct_lo, oct_hi do
    for _, interval in ipairs(scale.intervals) do
      local n = oct * 12 + root_note + interval
      if n >= 0 and n <= 127 then table.insert(notes, n) end
    end
  end
  return notes
end

local function offset_note(note, steps)
  if steps == 0 then return note end
  local notes = get_scale_notes(params:get("oct_low"), params:get("oct_high"))
  if #notes == 0 then return note end
  local idx = 1
  for i, n in ipairs(notes) do
    if n == note then idx = i; break end
    if n < note then idx = i end
  end
  return notes[clamp(idx + steps, 1, #notes)]
end

local function build_chord(root, density)
  if density <= 1 then return {root} end
  local pool = get_scale_notes(1, 7)
  if #pool == 0 then return {root} end
  local root_idx = 1
  for i, n in ipairs(pool) do
    if n <= root then root_idx = i end
  end
  local chord = {root}
  local used = {[root] = true}
  for i = 2, density do
    local idx = clamp(root_idx + (i - 1) * 2 + math.random(-1, 1), 1, #pool)
    local n = pool[idx]
    if n and not used[n] then
      used[n] = true
      table.insert(chord, clamp(n, 0, 127))
    end
  end
  return chord
end

------------------------------------------------------------------------
-- note generation
------------------------------------------------------------------------

local function get_pad_notes()
  local notes = get_scale_notes(params:get("oct_low"), params:get("oct_high"))
  if #notes == 0 then return {} end
  local density = params:get("pad_density")
  local root_idx = math.random(math.floor(#notes * 0.3), math.floor(#notes * 0.7))
  local chosen = {}
  for i = 1, density do
    local idx = clamp(root_idx + (i - 1) * 2 + math.random(-1, 1), 1, #notes)
    table.insert(chosen, notes[idx])
  end
  return chosen
end

local function get_lead_note()
  local notes = get_scale_notes(params:get("oct_low"), params:get("oct_high"))
  if #notes == 0 then return nil end
  lead_pos = clamp(lead_pos, 1, #notes)
  local note = notes[lead_pos]
  -- drift: stepwise with momentum, occasional leap
  if math.random() < 0.12 then
    lead_pos = clamp(lead_pos + lead_dir * math.random(2, 3), 1, #notes)
  elseif math.random() < 0.7 then
    lead_pos = lead_pos + lead_dir
  else
    lead_dir = -lead_dir
    lead_pos = lead_pos + lead_dir
  end
  lead_pos = clamp(lead_pos, 1, #notes)
  if lead_pos <= 2          then lead_dir =  1 end
  if lead_pos >= #notes - 1 then lead_dir = -1 end
  -- avoid consecutive duplicate
  if note == lead_last and #notes > 1 then
    lead_pos = clamp(lead_pos + lead_dir, 1, #notes)
    note = notes[lead_pos]
  end
  lead_last = note
  return note
end

local function get_bass_note()
  local bass_oct = params:get("bass_oct")
  -- two-octave window centered on bass_oct so there's room to walk
  local notes = get_scale_notes(bass_oct - 1, bass_oct)
  if #notes == 0 then return root_note + bass_oct * 12 end
  bass_pos = clamp(bass_pos, 1, #notes)

  -- find root positions within the note set
  local root_idxs = {}
  for i, n in ipairs(notes) do
    if (n - root_note) % 12 == 0 then table.insert(root_idxs, i) end
  end

  local r = math.random()

  -- 9% rest — silence is part of the groove
  if r < 0.09 then return nil end

  local result

  -- 28% gravity: snap to nearest root in range (keeps things grounded)
  if r < 0.37 and #root_idxs > 0 then
    local best, best_dist = root_idxs[1], 999
    for _, ri in ipairs(root_idxs) do
      local d = math.abs(bass_pos - ri)
      if d < best_dist then best, best_dist = ri, d end
    end
    bass_pos = best
    result = notes[bass_pos]
  else
    -- step through the scale with momentum
    local step
    if math.random() < 0.68 then
      step = bass_dir
    else
      bass_dir = -bass_dir
      step = bass_dir
    end
    bass_pos = clamp(bass_pos + step, 1, #notes)
    if bass_pos <= 1      then bass_dir =  1 end
    if bass_pos >= #notes then bass_dir = -1 end

    -- 13% chance of octave displacement
    if math.random() < 0.13 then
      local displaced = notes[bass_pos] - 12
      result = displaced >= 0 and displaced or notes[bass_pos]
    else
      result = notes[bass_pos]
    end
  end

  -- avoid consecutive duplicate — step up one scale degree
  if result == bass_last and #notes > 1 then
    local alt = clamp(bass_pos + 1, 1, #notes)
    if notes[alt] == bass_last then alt = clamp(bass_pos - 1, 1, #notes) end
    bass_pos = alt
    result = notes[bass_pos]
  end
  bass_last = result
  return result
end


------------------------------------------------------------------------
-- drunk timing
------------------------------------------------------------------------

local function drunk_sleep()
  local amt = params:get("drunk") / 100.0 * 0.20
  if amt > 0.001 then clock.sleep(math.random() * amt) end
end

local function sync_offset()
  local mode = params:get("syncopation")
  if mode == 1 then return end
  -- probability of an off-beat shift: soft=25%, medium=50%, hard=75%
  local probs = {0, 0.25, 0.5, 0.75}
  if math.random() < probs[mode] then
    -- shift by a half-beat (lands on the "and")
    -- hard mode occasionally shifts a full beat for stronger syncopation
    local shift = (mode == 4 and math.random() < 0.35) and 1.0 or 0.5
    clock.sleep(shift * 60 / clock.get_tempo())
  end
end

------------------------------------------------------------------------
-- note send helpers
------------------------------------------------------------------------

local function pad_note_on(note)
  if params:get("pad_on") == 2 then
    local freq = musicutil.note_num_to_freq(note)
    engine.start(note, freq)
    playing_voices[note] = freq
  end
  table.insert(pad_active, note)
end

local function pad_note_off(note)
  if params:get("pad_on") == 2 then
    engine.stop(note)
    playing_voices[note] = nil
  end
  for i = #pad_active, 1, -1 do
    if pad_active[i] == note then table.remove(pad_active, i); break end
  end
end

local function lead_note_on(note)
  local vel = math.random(params:get("lead_vel_min"),
                math.max(params:get("lead_vel_min"), params:get("lead_vel_max")))
  if midi_lead then midi_lead:note_on(note, vel, params:get("lead_ch")) end
  table.insert(lead_active, {note = note, ch = params:get("lead_ch")})
end

local function lead_note_off(note)
  if midi_lead then midi_lead:note_off(note, 0, params:get("lead_ch")) end
  for i = #lead_active, 1, -1 do
    if lead_active[i].note == note then table.remove(lead_active, i); break end
  end
end

local function bass_note_on(note)
  local vel = math.random(params:get("bass_vel_min"),
                math.max(params:get("bass_vel_min"), params:get("bass_vel_max")))
  if midi_bass then midi_bass:note_on(note, vel, params:get("bass_ch")) end
  table.insert(bass_active, {note = note, ch = params:get("bass_ch")})
end

local function bass_note_off(note)
  if midi_bass then midi_bass:note_off(note, 0, params:get("bass_ch")) end
  for i = #bass_active, 1, -1 do
    if bass_active[i].note == note then table.remove(bass_active, i); break end
  end
end

local function sec_note_on(note)
  local vel = math.random(params:get("lead_vel_min"),
                math.max(params:get("lead_vel_min"), params:get("lead_vel_max")))
  if midi_sec then midi_sec:note_on(note, math.floor(vel * 0.8), params:get("sec_ch")) end
  table.insert(sec_active, {note = note, ch = params:get("sec_ch")})
end

local function sec_note_off(note)
  if midi_sec then midi_sec:note_off(note, 0, params:get("sec_ch")) end
  for i = #sec_active, 1, -1 do
    if sec_active[i].note == note then table.remove(sec_active, i); break end
  end
end


local function vst_note_on(note)
  local vel = math.random(params:get("lead_vel_min"),
                math.max(params:get("lead_vel_min"), params:get("lead_vel_max")))
  if midi_vst then midi_vst:note_on(note, math.floor(vel * 0.8), params:get("vst_ch")) end
  table.insert(vst_active, {note = note, ch = params:get("vst_ch")})
end

local function vst_note_off(note)
  if midi_vst then midi_vst:note_off(note, 0, params:get("vst_ch")) end
  for i = #vst_active, 1, -1 do
    if vst_active[i].note == note then table.remove(vst_active, i); break end
  end
end
local function all_notes_off()
  for _, note in ipairs(pad_active) do
    if params:get("pad_on") == 2 then engine.stop(note) end
  end
  pad_active     = {}
  playing_voices = {}
  lead_last      = nil
  bass_last      = nil
  for _, n in ipairs(lead_active) do
    if midi_lead then midi_lead:note_off(n.note, 0, n.ch) end
  end
  lead_active = {}
  for _, n in ipairs(bass_active) do
    if midi_bass then midi_bass:note_off(n.note, 0, n.ch) end
  end
  bass_active = {}
  for _, n in ipairs(sec_active) do
    if midi_sec then midi_sec:note_off(n.note, 0, n.ch) end
  end
  sec_active = {}
  for _, n in ipairs(vst_active) do
    if midi_vst then midi_vst:note_off(n.note, 0, n.ch) end
  end
  vst_active = {}
  for _, note in ipairs(strata_active) do strata_send("/strata/noteoff", note) end
  strata_active = {}
  strata_send("/strata/alloff")
end

------------------------------------------------------------------------
-- osc helpers
------------------------------------------------------------------------

local OSC_PROMPTS = {
  [0]  = "morning light through pine forest, soft mist, grain",
  [1]  = "iron bridge in fog, rust and rain, long exposure",
  [2]  = "golden hour fields, telephone wires, slow motion",
  [3]  = "deep forest at dusk, roots and dark water",
  [4]  = "summer afternoon haze, suburban stillness, faded film",
  [5]  = "empty car park at night, sodium glow, concrete",
  [6]  = "underwater caustics, kelp forest, diffracted light",
  [7]  = "harvest moon over fields, amber and black, long exposure",
  [8]  = "standing stones at twilight, lichen, silence",
  [9]  = "late evening hills, amber light fading, tape grain",
  [10] = "rain on windows, neon blur, dark street puddles",
  [11] = "winter morning, bare trees, frost, cold blue light",
}

local function osc_emit(path, args)
  if params:get("osc_on") ~= 2 then return end
  osc.send({params:get("osc_host"), params:get("osc_port")}, path, args)
end

local function active_voice_count()
  return (#pad_active  > 0 and 1 or 0)
       + (#lead_active > 0 and 1 or 0)
       + (#bass_active > 0 and 1 or 0)
       + (#sec_active  > 0 and 1 or 0)
       + (#vst_active  > 0 and 1 or 0)
       + (#strata_active > 0 and 1 or 0)
end

local function get_osc_prompt()
  return OSC_PROMPTS[root_note % 12] or "slow generative landscape, grain, mist"
end

------------------------------------------------------------------------
-- visual helpers
------------------------------------------------------------------------

local function draw_polygon(cx, cy, sides, radius, angle, bri)
  bri = clamp(bri, 0, 15)
  screen.level(bri)
  for i = 0, sides - 1 do
    local a1 = angle + (i / sides) * math.pi * 2
    local a2 = angle + ((i + 1) / sides) * math.pi * 2
    screen.move(cx + math.cos(a1) * radius, cy + math.sin(a1) * radius)
    screen.line(cx + math.cos(a2) * radius, cy + math.sin(a2) * radius)
    screen.stroke()
  end
end

------------------------------------------------------------------------
-- pulse theme
------------------------------------------------------------------------

local function init_pulse()
  V.rings = {}
end

local function pulse_trigger()
  -- burst of staggered rings from center
  local n = math.random(3, 6)
  for i = 1, n do
    if #V.rings < 40 then
      table.insert(V.rings, {cx = 64, cy = 32, radius = i * 2.5, bri = 12 + audio_level * 3, ry = 0.55})
    end
  end
  -- off-center echo rings
  for i = 1, math.random(1, 2) do
    if #V.rings < 40 then
      local ang = math.random() * math.pi * 2
      local d   = 10 + math.random(0, 28)
      table.insert(V.rings, {
        cx     = clamp(64 + math.cos(ang) * d, 8, 120),
        cy     = clamp(32 + math.sin(ang) * d * 0.5, 6, 58),
        radius = 3 + audio_level * 4,
        bri    = 7 + audio_level * 6,
        ry     = 0.4 + math.random() * 0.5,
      })
    end
  end
end

local function draw_pulse()
  local bri_scale = params:get("vis_brightness") / 15.0
  local spd = params:get("vis_speed") * 0.35
  for i = #V.rings, 1, -1 do
    local r = V.rings[i]
    r.radius = r.radius + spd
    r.bri    = r.bri - 0.2
    if r.bri <= 0 or r.radius > 90 then
      table.remove(V.rings, i)
    else
      local b = clamp(math.floor(r.bri * bri_scale), 0, 15)
      if b > 0 then
        screen.level(b)
        local steps = 28
        screen.move(r.cx + r.radius, r.cy)
        for j = 1, steps do
          local a = j / steps * math.pi * 2
          screen.line(r.cx + math.cos(a) * r.radius, r.cy + math.sin(a) * r.radius * r.ry)
        end
        screen.stroke()
      end
    end
  end
  local pb = clamp(math.floor((4 + audio_level * 11) * bri_scale), 0, 15)
  if pb > 0 then
    screen.level(pb)
    screen.circle(64, 32, 1 + audio_level * 8)
    screen.fill()
  end
  if audio_level > 0.25 then
    local ob = clamp(math.floor((1 + audio_level * 5) * bri_scale), 0, 15)
    if ob > 0 then
      screen.level(ob)
      screen.circle(64, 32, 4 + audio_level * 20)
      screen.stroke()
    end
  end
end

------------------------------------------------------------------------
-- drift theme
------------------------------------------------------------------------

local function init_drift()
  V.bands = {}
  local count = params:get("num_particles")
  for i = 1, count do
    V.bands[i] = {
      y     = math.random(0, 63),
      w     = math.random(12, 64),
      h     = math.random(1, 2),
      spd   = (math.random() * 0.3 + 0.05) * (math.random() < 0.5 and 1 or -1),
      bri   = math.random(2, 8),
      phase = math.random() * math.pi * 2,
    }
  end
end

local function draw_drift()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.005
  for _, b in ipairs(V.bands) do
    b.phase = b.phase + vis_spd + audio_level * 0.025
    -- gentle pull toward centre at high audio
    local pull = audio_level * 0.25
    if b.y < 32 then b.y = b.y + pull else b.y = b.y - pull end
    b.y = b.y + b.spd * (vis_spd * 8 + audio_level * 0.3)
    if b.y < -4 then b.y = 68 end
    if b.y >  68 then b.y = -4 end
    local brightness = b.bri + math.sin(b.phase) * 3 + audio_level * 10
    local bri = clamp(math.floor(brightness * bri_scale), 0, 15)
    local w   = math.floor(b.w * (1 + audio_level * 0.7))
    local h   = clamp(math.floor(b.h + audio_level * 4), 1, 6)
    local x   = math.floor((128 - w) / 2)
    local iy  = math.floor(b.y)
    if bri > 0 then
      screen.level(bri)
      screen.rect(x, iy - math.floor(h / 2), w, h)
      screen.fill()
      -- sparkle at brightness peak
      if brightness > 10 and math.random() < 0.2 then
        screen.level(clamp(bri + 3, 0, 15))
        screen.pixel(x + math.random(0, w - 1), iy)
        screen.fill()
      end
    end
  end
end

------------------------------------------------------------------------
-- field theme
------------------------------------------------------------------------

local function init_field()
  V.columns = {}
  local count = math.max(params:get("num_particles"), 16)
  local cw    = math.floor(128 / count)
  for i = 1, count do
    V.columns[i] = {
      x     = (i - 1) * cw,
      cw    = cw,
      h     = math.random(2, 18),
      phase = math.random() * math.pi * 2,
      speed = math.random() * 0.04 + 0.01,
      peak  = 2,
    }
  end
end

local function draw_field()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.015
  for _, c in ipairs(V.columns) do
    c.phase = c.phase + c.speed + vis_spd
    local h = math.floor((c.h + math.sin(c.phase) * c.h * 0.6) * (1 + audio_level * 3.5))
    h = clamp(h, 1, 30)
    if h > c.peak then c.peak = h
    else c.peak = math.max(1, c.peak - 0.12) end
    local cw1 = math.max(1, c.cw - 1)
    local bri = clamp(math.floor((4 + audio_level * 10) * bri_scale), 0, 15)
    if bri > 0 then
      screen.level(bri)
      screen.rect(c.x, 32 - h, cw1, h)
      screen.fill()
      screen.rect(c.x, 32, cw1, h)
      screen.fill()
    end
    local pk_bri = clamp(math.floor((3 + audio_level * 6) * bri_scale), 0, 15)
    if pk_bri > 0 then
      local ph = math.floor(c.peak)
      screen.level(pk_bri)
      screen.rect(c.x, 32 - ph - 1, cw1, 1)
      screen.fill()
      screen.rect(c.x, 32 + ph, cw1, 1)
      screen.fill()
    end
  end
end

------------------------------------------------------------------------
-- hex theme
------------------------------------------------------------------------

local function init_hex()
  V.hex_nodes = {}
  local r = 11
  for row = 0, 5 do
    for col = 0, 8 do
      local x = col * r * 1.732 + (row % 2) * r * 0.866 - 16
      local y = row * r * 1.5 - 8
      if x >= -r and x <= 128 + r and y >= -r and y <= 64 + r then
        table.insert(V.hex_nodes, {
          x = x, y = y, r = r,
          bri   = math.random(1, 3),
          phase = math.random() * math.pi * 2,
          pulse = 0,
        })
      end
    end
  end
end

local function hex_trigger()
  local seeds = {}
  for i = 1, math.random(1, 3) do
    local ni = math.random(1, #V.hex_nodes)
    V.hex_nodes[ni].pulse = 13 + audio_level * 2
    table.insert(seeds, V.hex_nodes[ni])
  end
  -- propagate to hex neighbors
  for _, seed in ipairs(seeds) do
    for _, node in ipairs(V.hex_nodes) do
      local d = math.sqrt((node.x - seed.x)^2 + (node.y - seed.y)^2)
      if d > 2 and d < 26 then
        node.pulse = math.max(node.pulse, 7 + audio_level * 5)
      end
    end
  end
end

local function draw_hex()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.008
  -- connections between bright adjacent nodes
  if audio_level > 0.15 then
    for i = 1, #V.hex_nodes do
      local a  = V.hex_nodes[i]
      local ab = a.bri + math.sin(a.phase) * 1.5 + a.pulse + audio_level * 6
      if ab > 7 then
        for j = i + 1, #V.hex_nodes do
          local b = V.hex_nodes[j]
          local d2 = (a.x - b.x)^2 + (a.y - b.y)^2
          if d2 < 576 then  -- ~24px
            local bb = b.bri + math.sin(b.phase) * 1.5 + b.pulse + audio_level * 6
            if bb > 7 then
              local lb = clamp(math.floor(math.min(ab, bb) * 0.28 * bri_scale), 0, 15)
              if lb > 0 then
                screen.level(lb)
                screen.move(math.floor(a.x), math.floor(a.y))
                screen.line(math.floor(b.x), math.floor(b.y))
                screen.stroke()
              end
            end
          end
        end
      end
    end
  end
  for _, node in ipairs(V.hex_nodes) do
    node.phase = node.phase + vis_spd
    node.pulse = node.pulse * 0.88
    local bri = clamp(math.floor(
      (node.bri + math.sin(node.phase) * 1.5 + node.pulse + audio_level * 6) * bri_scale
    ), 0, 15)
    if bri > 0 then
      draw_polygon(node.x, node.y, 6, node.r * 0.82, node.phase, bri)
    end
  end
end

------------------------------------------------------------------------
-- stars theme  (warp-speed starfield with streak trails)
------------------------------------------------------------------------

local function init_stars()
  stars      = {}
  V.nova_rings = {}
  local count = params:get("num_particles")
  for i = 1, count do
    local angle = math.random() * math.pi * 2
    local speed = math.random() * 0.35 + 0.1
    local dist  = math.random(2, 55)
    local px    = 64 + math.cos(angle) * dist
    local py    = 32 + math.sin(angle) * dist * 0.5
    table.insert(stars, {
      x = px, y = py, px = px, py = py,
      vx = math.cos(angle) * speed,
      vy = math.sin(angle) * speed * 0.5,
      bri = math.random(2, 8),
    })
  end
end

local function stars_trigger()
  for i = 1, math.random(4, 12) do
    local angle = math.random() * math.pi * 2
    local speed = 0.5 + audio_level * 2.0
    table.insert(stars, {
      x = 64, y = 32, px = 64, py = 32,
      vx = math.cos(angle) * speed,
      vy = math.sin(angle) * speed * 0.5,
      bri = 11 + audio_level * 4,
    })
  end
  while #stars > 120 do table.remove(stars, 1) end
  if audio_level > 0.3 and math.random() < 0.45 and #stars > 0 then
    local s = stars[math.random(#stars)]
    table.insert(V.nova_rings, {x = s.x, y = s.y, r = 1.5, bri = 14})
    while #V.nova_rings > 8 do table.remove(V.nova_rings, 1) end
  end
end

local function draw_stars()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.3
  local warp      = 1.0 + audio_level * 3.5
  for _, s in ipairs(stars) do
    s.px = s.x; s.py = s.y
    local spd = vis_spd * warp
    s.x = s.x + s.vx * spd
    s.y = s.y + s.vy * spd
    if s.x < -4 or s.x > 132 or s.y < -4 or s.y > 68 then
      local angle = math.random() * math.pi * 2
      local speed = math.random() * 0.35 + 0.1
      s.x = 64; s.y = 32; s.px = 64; s.py = 32
      s.vx = math.cos(angle) * speed
      s.vy = math.sin(angle) * speed * 0.5
      s.bri = math.random(2, 8)
    end
    local dist = math.sqrt((s.x - 64)^2 + (s.y - 32)^2 * 4)
    local fade = math.min(1.0, dist / 18)
    local vel  = math.sqrt(s.vx^2 + s.vy^2) * warp
    local bri  = clamp(math.floor((s.bri * fade + vel * 2.0 + audio_level * 4) * bri_scale), 0, 15)
    if bri > 0 then
      screen.level(bri)
      local sx, sy = math.floor(s.x), math.floor(s.y)
      local ex, ey = math.floor(s.px), math.floor(s.py)
      if sx == ex and sy == ey then
        screen.pixel(sx, sy); screen.fill()
      else
        screen.move(ex, ey); screen.line(sx, sy); screen.stroke()
      end
    end
  end
  for i = #V.nova_rings, 1, -1 do
    local n = V.nova_rings[i]
    n.r   = n.r + vis_spd * warp * 1.8
    n.bri = n.bri - 0.55
    if n.bri <= 0 or n.r > 48 then
      table.remove(V.nova_rings, i)
    else
      local nb = clamp(math.floor(n.bri * bri_scale), 0, 15)
      if nb > 0 then
        screen.level(nb)
        screen.circle(math.floor(n.x), math.floor(n.y), math.floor(n.r))
        screen.stroke()
      end
    end
  end
end

------------------------------------------------------------------------
-- wave theme  (three interfering sine waves + note-triggered shock)
------------------------------------------------------------------------

local function init_wave()
  V.wave_phase  = 0
  V.wave_phase2 = math.pi * 0.7
  V.wave_shock  = 0
end

local function wave_trigger()
  V.wave_shock = math.min(1.0, V.wave_shock + 0.6 + audio_level * 0.8)
end

local function draw_wave()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.022
  V.wave_phase  = V.wave_phase  + vis_spd + audio_level * 0.055
  V.wave_phase2 = V.wave_phase2 + vis_spd * 1.37 + audio_level * 0.03
  V.wave_shock  = V.wave_shock  * 0.88

  local shock_amp = V.wave_shock * 14
  local amp   = 8 + audio_level * 18 + shock_amp
  local amp2  = (amp * 0.52) + shock_amp * 0.4
  local amp3  = amp * 0.28
  local freq  = 0.042 + audio_level * 0.028
  local freq2 = 0.071 + audio_level * 0.018
  local freq3 = 0.118

  -- fill envelope under primary wave
  local fill_bri = clamp(math.floor((1 + audio_level * 5 + V.wave_shock * 4) * bri_scale), 0, 15)
  if fill_bri > 0 then
    screen.level(fill_bri)
    for x = 0, 127, 2 do
      local wy = math.floor(32 + amp * math.sin(x * freq + V.wave_phase))
      local y1 = clamp(math.min(wy, 32), 0, 63)
      local y2 = clamp(math.max(wy, 32), 0, 63)
      if y2 > y1 then
        screen.move(x, y1); screen.line(x, y2); screen.stroke()
      end
    end
  end

  -- tertiary wave (faintest, fastest)
  local bri3 = clamp(math.floor((2 + audio_level * 4 + V.wave_shock * 5) * bri_scale), 0, 15)
  if bri3 > 0 then
    screen.level(bri3)
    screen.move(0, clamp(math.floor(32 + amp3 * math.sin(V.wave_phase * 1.6)), 0, 63))
    for x = 1, 127 do
      local y = math.floor(32 + amp3 * math.sin(x * freq3 + V.wave_phase * 1.6))
      screen.line(x, clamp(y, 0, 63))
    end
    screen.stroke()
  end

  -- secondary wave
  local bri2 = clamp(math.floor((4 + audio_level * 6 + V.wave_shock * 6) * bri_scale), 0, 15)
  if bri2 > 0 then
    screen.level(bri2)
    screen.move(0, clamp(math.floor(32 + amp2 * math.sin(V.wave_phase2)), 0, 63))
    for x = 1, 127 do
      local y = math.floor(32 + amp2 * math.sin(x * freq2 - V.wave_phase2))
      screen.line(x, clamp(y, 0, 63))
    end
    screen.stroke()
  end

  -- primary wave (brightest)
  local bri1 = clamp(math.floor((7 + audio_level * 8 + V.wave_shock * 8) * bri_scale), 0, 15)
  if bri1 > 0 then
    screen.level(bri1)
    screen.move(0, clamp(math.floor(32 + amp * math.sin(V.wave_phase)), 0, 63))
    for x = 1, 127 do
      local y = math.floor(32 + amp * math.sin(x * freq + V.wave_phase))
      screen.line(x, clamp(y, 0, 63))
    end
    screen.stroke()
  end
end

------------------------------------------------------------------------
-- rain theme  (streaking drops with wind drift + splashes)
------------------------------------------------------------------------

local function init_rain()
  V.rain_drops        = {}
  V.splash_particles  = {}
  local count = params:get("num_particles")
  for i = 1, count do
    local spd = math.random() * 1.2 + 0.4
    table.insert(V.rain_drops, {
      x   = math.random(0, 127),
      y   = math.random(0, 63),
      spd = spd,
      dx  = (math.random() - 0.5) * 0.4,
      len = math.random(2, 7),
      bri = math.random(3, 8),
    })
  end
end

local function rain_trigger()
  for i = 1, math.random(5, 14) do
    if #V.rain_drops < 110 then
      local spd = math.random() * 1.8 + 1.2 + audio_level * 2.5
      table.insert(V.rain_drops, {
        x   = math.random(0, 127),
        y   = -math.random(0, 12),
        spd = spd,
        dx  = (math.random() - 0.5) * 0.6,
        len = math.random(5, 18),
        bri = 9 + audio_level * 6,
      })
    end
  end
end

local function draw_rain()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.35
  local wind      = math.sin(time_val * 0.3) * audio_level * 0.8
  -- splash particles
  for i = #V.splash_particles, 1, -1 do
    local sp = V.splash_particles[i]
    sp.x   = sp.x + sp.vx
    sp.y   = sp.y + sp.vy
    sp.vy  = sp.vy + 0.15
    sp.bri = sp.bri - 0.55
    if sp.bri <= 0 or sp.y > 65 then
      table.remove(V.splash_particles, i)
    else
      local sb = clamp(math.floor(sp.bri * bri_scale), 0, 15)
      if sb > 0 then
        screen.level(sb)
        screen.pixel(math.floor(sp.x), clamp(math.floor(sp.y), 0, 63))
        screen.fill()
      end
    end
  end
  for i = #V.rain_drops, 1, -1 do
    local d = V.rain_drops[i]
    local fall = d.spd * (vis_spd + 0.5 + audio_level * 2.2)
    d.y = d.y + fall
    d.x = d.x + d.dx + wind
    if d.x < 0 then d.x = d.x + 128 end
    if d.x > 127 then d.x = d.x - 128 end
    if d.y > 64 + d.len then
      if #V.splash_particles < 60 then
        local nx = math.floor(d.x)
        for s = 1, math.random(2, 4) do
          local sang = math.pi + (math.random() - 0.5) * math.pi * 0.9
          local sv   = 0.6 + math.random() * 0.9 + audio_level * 0.8
          table.insert(V.splash_particles, {
            x = nx, y = 61,
            vx = math.cos(sang) * sv,
            vy = math.sin(sang) * sv - 0.4,
            bri = d.bri * 0.8,
          })
        end
      end
      d.x   = math.random(0, 127)
      d.y   = -d.len
      d.spd = math.random() * 1.2 + 0.4
      d.dx  = (math.random() - 0.5) * 0.4
      d.len = math.random(2, 7)
      d.bri = math.random(3, 8)
    else
      local bri = clamp(math.floor((d.bri + d.spd * 0.8 + audio_level * 5) * bri_scale), 0, 15)
      if bri > 0 then
        screen.level(bri)
        local ix  = math.floor(d.x)
        local iy  = clamp(math.floor(d.y), 0, 63)
        local iy2 = clamp(math.floor(d.y - d.len), 0, 63)
        screen.move(ix, iy2); screen.line(ix, iy); screen.stroke()
      end
    end
  end
end

------------------------------------------------------------------------
-- spiral theme  (galaxy arms drawn as connected line segments)
------------------------------------------------------------------------

local function init_spiral()
  V.spiral_angle  = 0
  V.spiral_points = {}
  V.spiral_dust   = {}
  local arms  = 4
  local count = math.max(params:get("num_particles"), 40)
  for arm_i = 1, arms do
    local arm_offset = (arm_i - 1) * math.pi * 2 / arms
    for j = 1, math.floor(count / arms) do
      local t = j / math.floor(count / arms) * math.pi * 3.5
      table.insert(V.spiral_points, {t = t, arm = arm_offset, arm_i = arm_i, bri = math.random(2, 6)})
    end
  end
  for i = 1, 22 do
    local t   = math.random() * math.pi * 3.5
    local ang = math.random() * math.pi * 2
    local r   = t * 5.0 + (math.random() - 0.5) * 7
    table.insert(V.spiral_dust, {r = r, ang = ang, drift = (math.random() - 0.5) * 0.002, bri = math.random(1, 3)})
  end
end

local function spiral_trigger()
  for _, p in ipairs(V.spiral_points) do
    p.bri = math.min(13, p.bri + audio_level * 10)
  end
end

local function draw_spiral()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.016
  V.spiral_angle = V.spiral_angle + vis_spd + audio_level * 0.04
  local scale  = 1 + audio_level * 0.55
  local arms   = 4

  -- dust particles
  for _, d in ipairs(V.spiral_dust) do
    d.ang = d.ang + vis_spd * 0.5 + d.drift
    local x = math.floor(64 + math.cos(d.ang) * d.r * scale)
    local y = math.floor(32 + math.sin(d.ang) * d.r * scale * 0.5)
    if x >= 0 and x <= 127 and y >= 0 and y <= 63 then
      local db = clamp(math.floor((d.bri + audio_level * 4) * bri_scale), 0, 15)
      if db > 0 then screen.level(db); screen.pixel(x, y); screen.fill() end
    end
  end

  for arm_i = 1, arms do
    local prev_x, prev_y, prev_bri
    for _, p in ipairs(V.spiral_points) do
      if p.arm_i == arm_i then
        p.bri = p.bri * 0.975 + math.random(1, 4) * 0.025
        local r     = p.t * 5.0 * scale
        local angle = p.t + p.arm + V.spiral_angle
        local x = math.floor(64 + math.cos(angle) * r)
        local y = math.floor(32 + math.sin(angle) * r * 0.5)
        local bri = clamp(math.floor((p.bri + audio_level * 7) * bri_scale), 0, 15)
        if prev_x and bri > 0 and prev_bri > 0
            and x >= 0 and x <= 127 and y >= 0 and y <= 63 then
          screen.level(math.max(bri, prev_bri))
          screen.move(prev_x, prev_y); screen.line(x, y); screen.stroke()
        end
        prev_x = x; prev_y = y; prev_bri = bri
      end
    end
  end

  local cglow = clamp(math.floor((3 + audio_level * 10) * bri_scale), 0, 15)
  if cglow > 0 then
    screen.level(cglow); screen.circle(64, 32, 1 + audio_level * 3); screen.fill()
  end
end

------------------------------------------------------------------------
-- lissajous theme  (harmonic oscilloscope curves, phase-morphing)
------------------------------------------------------------------------

local function init_lissajous()
  V.liss_phase   = 0
  V.liss_ratio_i = 1
  V.liss_history = {}
end

local function liss_trigger()
  V.liss_ratio_i = (V.liss_ratio_i % #V.LISS_RATIOS) + 1
end

local function draw_lissajous()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.007
  V.liss_phase = V.liss_phase + vis_spd + audio_level * 0.012

  local ratio = V.LISS_RATIOS[V.liss_ratio_i]
  local a, b  = ratio[1], ratio[2]
  local amp_x = 56 + audio_level * 8
  local amp_y = 26 + audio_level * 5
  local steps = 120

  -- build current curve
  local cur = {}
  for i = 0, steps do
    local t = i / steps * math.pi * 2
    cur[i + 1] = {
      x = math.floor(64 + amp_x * math.sin(a * t + V.liss_phase)),
      y = math.floor(32 + amp_y * math.sin(b * t)),
    }
  end

  -- ghost history traces
  for hi = 1, #V.liss_history do
    local fade    = 1.0 - hi / (#V.liss_history + 1)
    local ghost_b = clamp(math.floor((3 + audio_level * 3) * fade * bri_scale), 0, 15)
    if ghost_b > 0 then
      local pts = V.liss_history[hi]
      screen.level(ghost_b)
      screen.move(pts[1].x, pts[1].y)
      for j = 2, #pts do screen.line(pts[j].x, pts[j].y) end
      screen.stroke()
    end
  end

  -- echo offset by audio
  local bri2 = clamp(math.floor((2 + audio_level * 6) * bri_scale), 0, 15)
  if bri2 > 0 and audio_level > 0.08 then
    local ph2 = V.liss_phase + audio_level * 0.35
    screen.level(bri2)
    screen.move(math.floor(64 + amp_x * 0.65 * math.sin(a * 0 + ph2)),
                math.floor(32 + amp_y * 0.65 * math.sin(b * 0)))
    for i = 1, steps do
      local t = i / steps * math.pi * 2
      screen.line(math.floor(64 + amp_x * 0.65 * math.sin(a * t + ph2)),
                  math.floor(32 + amp_y * 0.65 * math.sin(b * t)))
    end
    screen.stroke()
  end

  -- primary trace
  local bri1 = clamp(math.floor((7 + audio_level * 8) * bri_scale), 0, 15)
  if bri1 > 0 then
    screen.level(bri1)
    screen.move(cur[1].x, cur[1].y)
    for j = 2, #cur do screen.line(cur[j].x, cur[j].y) end
    screen.stroke()
  end

  -- snapshot for history
  if math.floor(V.liss_phase * 6) % 4 == 0 then
    table.insert(V.liss_history, 1, cur)
    while #V.liss_history > 2 do table.remove(V.liss_history) end
  end
end

------------------------------------------------------------------------
-- tunnel theme  (zooming concentric rectangles, warp on note)
------------------------------------------------------------------------

local function init_tunnel()
  V.tunnel_z   = 0
  V.tunnel_rot = 0
end

local function tunnel_trigger()
  V.tunnel_z = V.tunnel_z + 0.18 + audio_level * 0.12
  if V.tunnel_z >= 1 then V.tunnel_z = V.tunnel_z - 1 end
end

local function draw_tunnel()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.012
  V.tunnel_z   = V.tunnel_z   + vis_spd + audio_level * 0.035
  if V.tunnel_z >= 1 then V.tunnel_z = V.tunnel_z - 1 end
  V.tunnel_rot = V.tunnel_rot + vis_spd * 0.25 + audio_level * 0.007

  -- audio shifts vanishing point slightly
  local ox = 64 + math.sin(V.tunnel_rot * 0.7) * audio_level * 9
  local oy = 32 + math.cos(V.tunnel_rot * 0.5) * audio_level * 4

  local num_rings = 10
  for i = 1, num_rings do
    local t   = ((i / num_rings) + V.tunnel_z) % 1.0
    local s   = t * t
    local hw  = s * 63
    local hh  = s * 31
    local rot = V.tunnel_rot * (1 - s) * 0.5
    local cr  = math.cos(rot)
    local sr  = math.sin(rot)
    local bri = clamp(math.floor((s * 11 + audio_level * 7) * bri_scale), 0, 15)
    if bri > 0 and hw > 0 and hh > 0 then
      screen.level(bri)
      local corners = {{-hw,-hh},{hw,-hh},{hw,hh},{-hw,hh}}
      local fx = math.floor(ox + corners[1][1]*cr - corners[1][2]*sr)
      local fy = math.floor(oy + corners[1][1]*sr + corners[1][2]*cr)
      screen.move(fx, fy)
      for _, c in ipairs(corners) do
        screen.line(math.floor(ox + c[1]*cr - c[2]*sr), math.floor(oy + c[1]*sr + c[2]*cr))
      end
      screen.line(fx, fy)
      screen.stroke()
    end
  end

  local dot_bri = clamp(math.floor((3 + audio_level * 8) * bri_scale), 0, 15)
  if dot_bri > 0 then
    screen.level(dot_bri); screen.pixel(math.floor(ox), math.floor(oy)); screen.fill()
  end
end

------------------------------------------------------------------------
-- bounce theme  (physics balls with trails, audio boosts velocity)
------------------------------------------------------------------------

local function init_bounce()
  V.bounce_balls = {}
  local count = clamp(math.floor(params:get("num_particles") / 6), 2, 8)
  for i = 1, count do
    local angle = math.random() * math.pi * 2
    local speed = math.random() * 1.2 + 0.6
    table.insert(V.bounce_balls, {
      x     = math.random(6, 122),
      y     = math.random(6, 58),
      vx    = math.cos(angle) * speed,
      vy    = math.sin(angle) * speed * 0.7,
      r     = math.random(2, 4),
      bri   = math.random(6, 12),
      trail = {},
    })
  end
end

local function bounce_trigger()
  for _, b in ipairs(V.bounce_balls) do
    local boost = 1.5 + audio_level * 3.0
    b.vx = b.vx * boost
    b.vy = b.vy * boost
    local spd = math.sqrt(b.vx^2 + b.vy^2)
    if spd > 6 then b.vx = b.vx/spd*6; b.vy = b.vy/spd*6 end
    b.bri = math.min(15, b.bri + audio_level * 7)
  end
end

local function draw_bounce()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.28

  -- weak inter-ball attraction
  for i = 1, #V.bounce_balls do
    for j = i + 1, #V.bounce_balls do
      local bi, bj = V.bounce_balls[i], V.bounce_balls[j]
      local dx = bj.x - bi.x
      local dy = bj.y - bi.y
      local d2 = dx * dx + dy * dy
      if d2 > 4 and d2 < 3600 then
        local f = 0.00035
        bi.vx = bi.vx + dx * f; bi.vy = bi.vy + dy * f * 0.7
        bj.vx = bj.vx - dx * f; bj.vy = bj.vy - dy * f * 0.7
      end
    end
  end

  for _, b in ipairs(V.bounce_balls) do
    table.insert(b.trail, {x = b.x, y = b.y})
    while #b.trail > 10 do table.remove(b.trail, 1) end

    local sm = vis_spd + 0.35 + audio_level * 1.8
    b.x = b.x + b.vx * sm
    b.y = b.y + b.vy * sm

    if b.x - b.r < 0   then b.x = b.r;       b.vx =  math.abs(b.vx) end
    if b.x + b.r > 127  then b.x = 127 - b.r; b.vx = -math.abs(b.vx) end
    if b.y - b.r < 0   then b.y = b.r;       b.vy =  math.abs(b.vy) end
    if b.y + b.r > 63   then b.y = 63  - b.r; b.vy = -math.abs(b.vy) end

    b.vx = b.vx * 0.997; b.vy = b.vy * 0.997
    b.bri = b.bri * 0.97 + math.random(4, 8) * 0.03

    local spd_now = math.sqrt(b.vx^2 + b.vy^2)
    for j, t in ipairs(b.trail) do
      local fade = j / #b.trail
      local tbri = clamp(math.floor(b.bri * fade * (0.35 + spd_now * 0.05) * bri_scale), 0, 15)
      if tbri > 0 then
        screen.level(tbri); screen.pixel(math.floor(t.x), math.floor(t.y)); screen.fill()
      end
    end

    local r_vis = b.r + audio_level * 2 + spd_now * 0.12
    local bri   = clamp(math.floor((b.bri + audio_level * 5) * bri_scale), 0, 15)
    if bri > 0 then
      screen.level(bri); screen.circle(math.floor(b.x), math.floor(b.y), r_vis); screen.fill()
    end
  end
end

------------------------------------------------------------------------
-- grid theme  (ripple waves on dot grid, radiating from centre)
------------------------------------------------------------------------

local function init_grid()
  V.grid_nodes   = {}
  V.grid_wave_t  = 0
  V.grid_wave2_t = 0
  V.grid_src2_x  = 20
  V.grid_src2_y  = 10
  local cols, rows = 16, 8
  for row = 0, rows - 1 do
    for col = 0, cols - 1 do
      table.insert(V.grid_nodes, {
        x   = col * 8 + 4,
        y   = row * 8 + 4,
        bri = math.random(1, 3),
        col = col,
        row = row,
      })
    end
  end
end

local function grid_trigger()
  V.grid_wave_t  = V.grid_wave_t  + math.pi * 0.6 + audio_level * math.pi * 1.2
  V.grid_wave2_t = V.grid_wave2_t + math.pi * 0.4 + audio_level * math.pi * 0.9
end

local function draw_grid()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.035
  V.grid_wave_t  = V.grid_wave_t  + vis_spd + audio_level * 0.07
  V.grid_wave2_t = V.grid_wave2_t + vis_spd * 0.71 + audio_level * 0.05
  V.grid_src2_x  = 64 + math.sin(time_val * 0.4) * 44
  V.grid_src2_y  = 32 + math.cos(time_val * 0.3) * 22

  local brights = {}
  for idx, node in ipairs(V.grid_nodes) do
    local dx1  = (node.x - 64) / 58.0
    local dy1  = (node.y - 32) / 30.0
    local d1   = math.sqrt(dx1*dx1 + dy1*dy1) * 3.5
    local dx2  = (node.x - V.grid_src2_x) / 58.0
    local dy2  = (node.y - V.grid_src2_y) / 30.0
    local d2   = math.sqrt(dx2*dx2 + dy2*dy2) * 3.5
    local wave = math.sin(V.grid_wave_t  - d1) * 0.65
              + math.sin(V.grid_wave2_t - d2) * 0.35
    local raw  = node.bri + wave * 6 + audio_level * 9
    local bri  = clamp(math.floor(raw * bri_scale), 0, 15)
    brights[idx] = bri
    if bri > 0 then
      screen.level(bri)
      if wave > 0.4 or audio_level > 0.4 then
        screen.rect(node.x - 1, node.y - 1, 3, 3)
      else
        screen.rect(node.x, node.y, 2, 2)
      end
      screen.fill()
    end
  end

  -- connections between bright horizontal neighbors
  if audio_level > 0.15 then
    for idx, node in ipairs(V.grid_nodes) do
      if brights[idx] and brights[idx] > 5 and node.col < 15 then
        local ridx = idx + 1
        if brights[ridx] and brights[ridx] > 5 then
          local cb = clamp(math.floor(math.min(brights[idx], brights[ridx]) * 0.38), 0, 15)
          if cb > 0 then
            screen.level(cb)
            screen.move(node.x + 2, node.y + 1)
            screen.line(V.grid_nodes[ridx].x, V.grid_nodes[ridx].y + 1)
            screen.stroke()
          end
        end
      end
    end
  end
end

------------------------------------------------------------------------
-- flow theme  (curl-noise vector field particles)
------------------------------------------------------------------------

V.flow_particles = {}

local function init_flow()
  V.flow_particles = {}
  local count = params:get("num_particles")
  for i = 1, count do
    table.insert(V.flow_particles, {
      x     = math.random(0, 127),
      y     = math.random(0, 63),
      bri   = math.random(3, 9),
      age   = math.random(0, 80),
      trail = {},
    })
  end
end

local function flow_trigger()
  for i = 1, math.random(6, 14) do
    if #V.flow_particles < 120 then
      table.insert(V.flow_particles, {
        x     = math.random(0, 127),
        y     = math.random(0, 63),
        bri   = 11 + audio_level * 4,
        age   = 0,
        trail = {},
      })
    end
  end
end

local function draw_flow()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.18
  local t         = time_val
  local ax1 = math.sin(t * 0.31) * math.pi
  local ax2 = math.cos(t * 0.19) * math.pi
  for _, p in ipairs(V.flow_particles) do
    table.insert(p.trail, {x = p.x, y = p.y})
    while #p.trail > 5 do table.remove(p.trail, 1) end
    local nx  = p.x / 38.0
    local ny  = p.y / 19.0
    local ang = math.sin(nx + t * 0.7 + ax1) * math.cos(ny * 1.3 - t * 0.5) * math.pi * 2
             + math.sin(nx * 0.6 - ny + t * 0.4 + ax2) * math.pi
             + math.cos(nx * 1.1 + ny * 0.8 - t * 0.3) * 0.5
    local spd = vis_spd + audio_level * 1.6
    p.x   = p.x + math.cos(ang) * spd
    p.y   = p.y + math.sin(ang) * spd * 0.6
    p.age = p.age + 1
    if p.x < 0 or p.x > 127 or p.y < 0 or p.y > 63 or p.age > 110 then
      p.x   = math.random(0, 127)
      p.y   = math.random(0, 63)
      p.bri = math.random(3, 9)
      p.age = 0
      p.trail = {}
    else
      local fade = 1.0 - p.age / 110.0
      for j = 2, #p.trail do
        local tf  = (j - 1) / #p.trail
        local bri = clamp(math.floor((p.bri * fade * tf * 0.65 + audio_level * 4) * bri_scale), 0, 15)
        if bri > 0 then
          screen.level(bri)
          screen.move(math.floor(p.trail[j-1].x), math.floor(p.trail[j-1].y))
          screen.line(math.floor(p.trail[j].x),   math.floor(p.trail[j].y))
          screen.stroke()
        end
      end
      if #p.trail > 0 then
        local hbri = clamp(math.floor((p.bri * fade + audio_level * 7) * bri_scale), 0, 15)
        if hbri > 0 then
          local last = p.trail[#p.trail]
          screen.level(hbri)
          screen.move(math.floor(last.x), math.floor(last.y))
          screen.line(math.floor(p.x), math.floor(p.y))
          screen.stroke()
        end
      end
    end
  end
end

------------------------------------------------------------------------
-- morph theme  (polygon morphing between shapes)
------------------------------------------------------------------------

local morph_t      = 0
local morph_sides  = {3, 4, 5, 6, 8, 12}
local morph_from_i = 1
local morph_to_i   = 2
local morph_phase  = 0

local function init_morph()
  morph_phase  = 0
  morph_t      = 0
  morph_from_i = 1
  morph_to_i   = 2
  V.morph_vphase = {}
  for i = 1, 16 do V.morph_vphase[i] = math.random() * math.pi * 2 end
end

local function morph_trigger()
  morph_from_i = morph_to_i
  morph_to_i   = (morph_to_i % #morph_sides) + 1
  morph_t      = 0
  for i = 1, 16 do
    V.morph_vphase[i] = V.morph_vphase[i] + (math.random() - 0.5) * math.pi * 1.5
  end
end

local function draw_morph()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.007
  morph_phase = morph_phase + vis_spd + audio_level * 0.012
  morph_t     = math.min(1.0, morph_t + vis_spd * 0.4 + audio_level * 0.006)
  if morph_t >= 1.0 then
    morph_from_i = morph_to_i
    morph_to_i   = (morph_to_i % #morph_sides) + 1
    morph_t      = 0
  end
  if V.morph_vphase then
    for i = 1, 16 do
      V.morph_vphase[i] = V.morph_vphase[i] + vis_spd * 0.4 + audio_level * 0.005
    end
  end

  local t3 = morph_t * morph_t * (3 - 2 * morph_t)
  local sa = morph_sides[morph_from_i]
  local sb = morph_sides[morph_to_i]
  local cx, cy = 64, 32

  for layer = 1, 4 do
    local base_r  = 7 + layer * 6
    local noise_a = (1 + audio_level * 5) * (layer * 0.5 + 0.4)
    local rot_dir = (layer % 2 == 0) and 1 or -1
    local bri = clamp(math.floor((1 + (5 - layer) * 2.5 + audio_level * 9) * bri_scale), 0, 15)
    if bri > 0 then
      screen.level(bri)
      local steps = 48
      local first_x, first_y
      for i = 0, steps do
        local frac   = i / steps
        local snap_a = math.floor(sa * frac + 0.5) / sa * math.pi * 2
        local snap_b = math.floor(sb * frac + 0.5) / sb * math.pi * 2
        local ang    = snap_a + (snap_b - snap_a) * t3 + morph_phase * rot_dir
        local vi1    = math.floor(frac * 7) + 1
        local vi2    = (vi1 % 8) + 1
        local noise  = 0
        if V.morph_vphase then
          noise = math.sin(V.morph_vphase[vi1] + frac * math.pi * 4) * noise_a
                + math.sin(V.morph_vphase[vi2] - frac * math.pi * 3) * noise_a * 0.45
        end
        local r = base_r + noise
        local x = math.floor(cx + math.cos(ang) * r)
        local y = math.floor(cy + math.sin(ang) * r * 0.68)
        if i == 0 then
          screen.move(x, y); first_x, first_y = x, y
        else
          screen.line(x, y)
        end
      end
      screen.stroke()
    end
  end
end

------------------------------------------------------------------------
-- shatter theme  (crack lines that spawn on notes and slowly heal)
------------------------------------------------------------------------

V.shatter_cracks = {}

local function init_shatter()
  V.shatter_cracks  = {}
  V.shatter_flashes = {}
end

local function shatter_trigger()
  local ox  = math.random(20, 108)
  local oy  = math.random(10, 54)
  table.insert(V.shatter_flashes, {x = ox, y = oy, r = 2 + audio_level * 3, bri = 15})
  local num = math.random(5, 9) + math.floor(audio_level * 6)
  for i = 1, num do
    local ang  = math.random() * math.pi * 2
    local len  = math.random(10, 34) * (1 + audio_level)
    local segs = math.random(2, 5)
    local points = {{x = ox, y = oy}}
    local cx, cy = ox, oy
    for s = 1, segs do
      ang = ang + (math.random() - 0.5) * 0.7
      local dl = len / segs
      cx = cx + math.cos(ang) * dl
      cy = cy + math.sin(ang) * dl * 0.6
      table.insert(points, {x = clamp(cx, 0, 127), y = clamp(cy, 0, 63)})
    end
    table.insert(V.shatter_cracks, {points = points, bri = 12 + audio_level * 3})
    -- branch crack
    if math.random() < 0.45 and #V.shatter_cracks < 65 and #points >= 2 then
      local bi   = math.random(2, #points)
      local bang = ang + (math.random() < 0.5 and 1 or -1) * (0.4 + math.random() * 0.5)
      local blen = len * (0.3 + math.random() * 0.4)
      local bpts = {{x = points[bi].x, y = points[bi].y}}
      local bx, by = points[bi].x, points[bi].y
      for s = 1, math.random(1, 3) do
        bang = bang + (math.random() - 0.5) * 0.4
        local dl = blen / 2
        bx = bx + math.cos(bang) * dl; by = by + math.sin(bang) * dl * 0.6
        table.insert(bpts, {x = clamp(bx,0,127), y = clamp(by,0,63)})
      end
      table.insert(V.shatter_cracks, {points = bpts, bri = 9 + audio_level * 3})
    end
  end
  while #V.shatter_cracks > 70 do table.remove(V.shatter_cracks, 1) end
end

local function draw_shatter()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.004
  for i = #V.shatter_flashes, 1, -1 do
    local f = V.shatter_flashes[i]
    f.bri = f.bri - 1.4; f.r = f.r + 0.9
    if f.bri <= 0 then
      table.remove(V.shatter_flashes, i)
    else
      local fb = clamp(math.floor(f.bri * bri_scale), 0, 15)
      if fb > 0 then
        screen.level(fb); screen.circle(math.floor(f.x), math.floor(f.y), math.floor(f.r)); screen.fill()
      end
    end
  end
  for i = #V.shatter_cracks, 1, -1 do
    local c = V.shatter_cracks[i]
    c.bri = c.bri - 0.05 - vis_spd * 2
    if c.bri <= 0 then
      table.remove(V.shatter_cracks, i)
    else
      local bri = clamp(math.floor((c.bri + audio_level * 4) * bri_scale), 0, 15)
      if bri > 0 and #c.points >= 2 then
        screen.level(bri)
        screen.move(math.floor(c.points[1].x), math.floor(c.points[1].y))
        for j = 2, #c.points do
          screen.line(math.floor(c.points[j].x), math.floor(c.points[j].y))
        end
        screen.stroke()
      end
    end
  end
end

------------------------------------------------------------------------
-- code theme  (matrix-style falling character columns)
------------------------------------------------------------------------

V.code_cols  = {}
local CODE_CHARS = {"|","/","\\","-","_",":",".","#","*","+","=","~"}

local function init_code()
  V.code_cols      = {}
  V.code_highlight = 1
  V.code_boost     = 0
  local n = 21
  for i = 0, n - 1 do
    table.insert(V.code_cols, {
      x    = i * 6 + 2,
      y    = math.random(-64, 0),
      spd  = math.random() * 0.8 + 0.4,
      len  = math.random(4, 14),
      bri  = math.random(4, 9),
      char = CODE_CHARS[math.random(#CODE_CHARS)],
      tick = 0,
    })
  end
end

local function code_trigger()
  V.code_boost     = 3.0 + audio_level * 4.0
  V.code_highlight = (V.code_highlight % #V.code_cols) + 1
  V.code_cols[V.code_highlight].bri = 14 + audio_level
end

local function draw_code()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.4
  V.code_boost      = V.code_boost * 0.88
  for ci, c in ipairs(V.code_cols) do
    local is_hot = (ci == V.code_highlight)
    c.tick = c.tick + 1
    local fall = c.spd * (vis_spd + 0.5 + audio_level * 2.0 + V.code_boost)
    c.y = c.y + fall
    local char_rate = math.max(1, math.floor((is_hot and 2 or 7) - audio_level * 4))
    if c.tick % char_rate == 0 then c.char = CODE_CHARS[math.random(#CODE_CHARS)] end
    if c.y > 64 + c.len * 6 then
      c.y   = -c.len * 6 - math.random(0, 40)
      c.spd = math.random() * 0.8 + 0.4
      c.len = math.random(4, 14)
      c.bri = is_hot and (10 + math.random(4)) or math.random(4, 9)
    end
    for j = 0, c.len do
      local ty = math.floor(c.y - j * 6)
      if ty >= 0 and ty <= 63 then
        local b
        if j == 0 then
          local hb = is_hot and (c.bri + 5 + audio_level * 4) or (c.bri + audio_level * 6)
          b = clamp(math.floor(hb * bri_scale), 0, 15)
        else
          local fade = 1.0 - j / c.len
          b = clamp(math.floor(c.bri * fade * (is_hot and 0.75 or 0.55) * bri_scale), 0, 15)
        end
        if b > 0 then
          screen.level(b)
          screen.move(c.x, ty)
          screen.text(j == 0 and c.char or CODE_CHARS[math.random(#CODE_CHARS)])
        end
      end
    end
    c.bri = c.bri * 0.985 + math.random(4, 8) * 0.015
  end
end

------------------------------------------------------------------------
-- orbit theme  (planets orbiting a star, audio perturbs orbits)
------------------------------------------------------------------------

local orbit_bodies  = {}
local orbit_perturb = 0

local function init_orbit()
  orbit_bodies  = {}
  orbit_perturb = 0
  local radii = {10, 18, 27, 38, 50}
  local sizes = {3, 2, 3, 2, 2}
  for i, rad in ipairs(radii) do
    local angle = math.random() * math.pi * 2
    local spd   = (0.018 + math.random() * 0.012) * (i % 2 == 0 and -1 or 1)
    table.insert(orbit_bodies, {
      angle  = angle,
      radius = rad,
      base_r = rad,
      spd    = spd,
      size   = sizes[i],
      bri    = math.random(6, 12),
      trail  = {},
    })
  end
end

local function orbit_trigger()
  orbit_perturb = math.min(1.2, orbit_perturb + 0.6 + audio_level * 0.8)
  for _, b in ipairs(orbit_bodies) do
    b.bri = math.min(15, b.bri + audio_level * 7)
  end
end

local function draw_orbit()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.5
  orbit_perturb   = orbit_perturb * 0.93

  -- faint orbital path ellipses
  local path_bri = clamp(math.floor((1 + audio_level * 2) * bri_scale), 0, 15)
  if path_bri > 0 then
    for _, b in ipairs(orbit_bodies) do
      screen.level(path_bri)
      screen.move(64 + b.base_r, 32)
      for j = 1, 32 do
        local a = j / 32 * math.pi * 2
        screen.line(64 + math.cos(a) * b.base_r, 32 + math.sin(a) * b.base_r * 0.55)
      end
      screen.stroke()
    end
  end

  -- star + corona
  local star_bri = clamp(math.floor((6 + audio_level * 9) * bri_scale), 0, 15)
  if star_bri > 0 then
    screen.level(star_bri); screen.circle(64, 32, 2 + audio_level * 2); screen.fill()
    local corona = clamp(math.floor((2 + audio_level * 5) * bri_scale), 0, 15)
    if corona > 0 then screen.level(corona); screen.circle(64, 32, 4 + audio_level * 4); screen.stroke() end
  end

  for _, b in ipairs(orbit_bodies) do
    b.angle  = b.angle + b.spd * (vis_spd + 1.0 + audio_level * 2.0)
    b.radius = b.base_r + orbit_perturb * math.sin(b.angle * 3) * 7 + audio_level * 5

    local x = 64 + math.cos(b.angle) * b.radius
    local y = 32 + math.sin(b.angle) * b.radius * 0.55

    table.insert(b.trail, {x = x, y = y})
    while #b.trail > 20 do table.remove(b.trail, 1) end

    for j, pt in ipairs(b.trail) do
      local fade = j / #b.trail
      local tbri = clamp(math.floor(b.bri * fade * 0.45 * bri_scale), 0, 15)
      if tbri > 0 then
        screen.level(tbri); screen.pixel(math.floor(pt.x), math.floor(pt.y)); screen.fill()
      end
    end

    b.bri = b.bri * 0.97 + math.random(5, 10) * 0.03
    local pb = clamp(math.floor((b.bri + audio_level * 6) * bri_scale), 0, 15)
    if pb > 0 then
      screen.level(pb); screen.circle(math.floor(x), math.floor(y), b.size); screen.fill()
    end
  end
end

------------------------------------------------------------------------
-- terrain theme
------------------------------------------------------------------------

-- new themes attach their functions as table fields (not top-level locals) to
-- stay under Lua's 200-local-per-chunk limit.

function terrain.fresh_heights()
  local h = {}
  for i = 1, terrain.S do
    h[i] = math.random()
  end
  return h
end

function terrain.init()
  terrain.rows = {}
  for i = 1, terrain.N do
    terrain.rows[i] = {
      z       = (i - 1) / terrain.N,   -- evenly spaced 0 (horizon) .. 1 (foreground)
      heights = terrain.fresh_heights(),
    }
  end
end

function terrain.trigger()
  -- find horizon-most row (smallest z) and stamp a raised peak that rolls forward
  local lo, idx = 2, 1
  for i, r in ipairs(terrain.rows) do
    if r.z < lo then lo = r.z; idx = i end
  end
  local r = terrain.rows[idx]
  local center = math.random(2, terrain.S - 1)
  for i = 1, terrain.S do
    local d = i - center
    r.heights[i] = math.min(1, r.heights[i] + (1.0 + audio_level) * math.exp(-d * d * 0.5))
  end
end

function terrain.draw()
  local bri_scale = params:get("vis_brightness") / 15.0
  local spd       = params:get("vis_speed") * 0.012
  local y_h, y_f  = 20, 60          -- horizon and foreground screen rows

  for _, r in ipairs(terrain.rows) do
    r.z = r.z + spd
    if r.z >= 1 then
      r.z       = r.z - 1
      r.heights = terrain.fresh_heights()
    end
  end
  -- draw far-to-near so nearer (brighter) ridges overdraw distant ones
  table.sort(terrain.rows, function(a, b) return a.z < b.z end)

  for _, r in ipairs(terrain.rows) do
    local z      = r.z
    local persp  = z * z                       -- compress rows toward the horizon
    local row_y  = y_h + (y_f - y_h) * persp
    local half_w = 18 + 46 * z
    local amp    = (2 + audio_level * 14) * (0.25 + 0.75 * z)
    local bri    = clamp(math.floor((2 + 10 * z) * bri_scale), 0, 15)
    if bri > 0 then
      screen.level(bri)
      for i = 1, terrain.S do
        local t = (i - 1) / (terrain.S - 1)
        local x = 64 - half_w + t * half_w * 2
        local y = row_y - r.heights[i] * amp
        if i == 1 then screen.move(x, y) else screen.line(x, y) end
      end
      screen.stroke()
    end
  end
end

------------------------------------------------------------------------
-- lattice theme
------------------------------------------------------------------------

function lattice.init()
  local phi = (1 + math.sqrt(5)) / 2
  lattice.verts = {
    {0,  1,  phi}, {0,  1, -phi}, {0, -1,  phi}, {0, -1, -phi},
    {1,  phi, 0}, {1, -phi, 0}, {-1,  phi, 0}, {-1, -phi, 0},
    {phi, 0,  1}, {phi, 0, -1}, {-phi, 0,  1}, {-phi, 0, -1},
  }
  -- icosahedron edges = vertex pairs at the minimum (edge-length) distance, d^2 = 4
  lattice.edges = {}
  for i = 1, #lattice.verts do
    for j = i + 1, #lattice.verts do
      local a, b = lattice.verts[i], lattice.verts[j]
      local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
      if math.abs(dx * dx + dy * dy + dz * dz - 4) < 0.1 then
        table.insert(lattice.edges, {i, j})
      end
    end
  end
  lattice.rx, lattice.ry = 0, 0
  lattice.kick, lattice.flash = 0, 0
end

function lattice.trigger()
  lattice.kick  = math.min(0.5, lattice.kick + 0.15 + audio_level * 0.2)
  lattice.flash = math.min(8, lattice.flash + 4 + audio_level * 4)
end

function lattice.draw()
  local bri_scale = params:get("vis_brightness") / 15.0
  local spd       = params:get("vis_speed") * 0.04
  lattice.kick    = lattice.kick * 0.9
  lattice.flash   = lattice.flash * 0.85
  lattice.rx      = lattice.rx + spd + lattice.kick
  lattice.ry      = lattice.ry + spd * 0.6 + lattice.kick * 0.7

  local scale = (14 + audio_level * 9) * (1 + lattice.kick * 0.3)
  local cx, cy = 64, 32
  local cosx, sinx = math.cos(lattice.rx), math.sin(lattice.rx)
  local cosy, siny = math.cos(lattice.ry), math.sin(lattice.ry)

  local proj = {}
  for i, v in ipairs(lattice.verts) do
    local x, y, z = v[1], v[2], v[3]
    -- rotate about X then Y
    local y1 = y * cosx - z * sinx
    local z1 = y * sinx + z * cosx
    local x2 = x * cosy + z1 * siny
    local z2 = -x * siny + z1 * cosy
    local persp = 4 / (4 - z2)          -- viewer at +z; nearer vertices project larger
    proj[i] = {
      x = cx + x2 * scale * persp,
      y = cy + y1 * scale * persp,
      z = z2,
    }
  end

  for _, e in ipairs(lattice.edges) do
    local a, b  = proj[e[1]], proj[e[2]]
    local depth = (a.z + b.z) * 0.5
    local norm  = clamp((depth + 1.9) / 3.8, 0, 1)   -- nearer edges brighter
    local bri   = clamp(math.floor((3 + norm * 9 + lattice.flash) * bri_scale), 0, 15)
    if bri > 0 then
      screen.level(bri)
      screen.move(a.x, a.y)
      screen.line(b.x, b.y)
      screen.stroke()
    end
  end
end

------------------------------------------------------------------------
-- kaleido theme
------------------------------------------------------------------------

function kaleido.init()
  kaleido.parts  = {}
  kaleido.shards = {}
  local count = params:get("num_particles")
  for i = 1, count do
    kaleido.parts[i] = {
      r   = math.random() * 30,
      a   = math.random() * (math.pi / 3),   -- angle within one 60-degree wedge
      dr  = 0.15 + math.random() * 0.4,
      da  = (math.random() - 0.5) * 0.04,
      bri = math.random(4, 11),
    }
  end
end

function kaleido.trigger()
  table.insert(kaleido.shards, {
    r   = 0,
    a   = math.random() * (math.pi / 3),
    spd = 1.2 + audio_level * 1.5,
    bri = 13 + audio_level * 2,
  })
  if #kaleido.shards > 12 then table.remove(kaleido.shards, 1) end
end

function kaleido.draw()
  local bri_scale = params:get("vis_brightness") / 15.0
  local spd       = params:get("vis_speed") * 0.5
  local cx, cy    = 64, 32
  local bloom     = 1 + audio_level * 0.8
  local max_r     = 40

  -- plot one wedge point into all six rotations plus their mirrors (6-fold mandala)
  local function plot(r, a, bri)
    if bri <= 0 then return end
    local rr = r * bloom
    screen.level(bri)
    for k = 0, 5 do
      local base = k * (math.pi / 3)
      local a1   = base + a
      local a2   = base - a
      screen.pixel(math.floor(cx + math.cos(a1) * rr), math.floor(cy + math.sin(a1) * rr * 0.62))
      screen.pixel(math.floor(cx + math.cos(a2) * rr), math.floor(cy + math.sin(a2) * rr * 0.62))
    end
    screen.fill()
  end

  for _, p in ipairs(kaleido.parts) do
    p.r = p.r + p.dr * (spd + audio_level * 1.5)
    p.a = p.a + p.da
    if p.a < 0          then p.a = p.a + math.pi / 3 end
    if p.a > math.pi / 3 then p.a = p.a - math.pi / 3 end
    if p.r > max_r then
      p.r   = math.random() * 4
      p.bri = math.random(4, 11)
    end
    plot(p.r, p.a, clamp(math.floor((p.bri + audio_level * 5) * bri_scale), 0, 15))
  end

  for i = #kaleido.shards, 1, -1 do
    local s = kaleido.shards[i]
    s.r   = s.r + s.spd * (spd + 1)
    s.bri = s.bri - 0.4
    if s.bri <= 0 or s.r > max_r then
      table.remove(kaleido.shards, i)
    else
      plot(s.r, s.a, clamp(math.floor(s.bri * bri_scale), 0, 15))
    end
  end

  -- centre glow
  local gb = clamp(math.floor((3 + audio_level * 8) * bri_scale), 0, 15)
  if gb > 0 then
    screen.level(gb)
    screen.circle(cx, cy, 1 + audio_level * 2)
    screen.fill()
  end
end

------------------------------------------------------------------------
-- visual dispatch
------------------------------------------------------------------------

local function init_particles()
  if     theme_index == 1  then init_pulse()
  elseif theme_index == 2  then init_drift()
  elseif theme_index == 3  then init_field()
  elseif theme_index == 4  then init_hex()
  elseif theme_index == 5  then init_stars()
  elseif theme_index == 6  then init_wave()
  elseif theme_index == 7  then init_rain()
  elseif theme_index == 8  then init_spiral()
  elseif theme_index == 9  then init_lissajous()
  elseif theme_index == 10 then init_tunnel()
  elseif theme_index == 11 then init_bounce()
  elseif theme_index == 12 then init_grid()
  elseif theme_index == 13 then init_flow()
  elseif theme_index == 14 then init_morph()
  elseif theme_index == 15 then init_shatter()
  elseif theme_index == 16 then init_code()
  elseif theme_index == 17 then init_orbit()
  elseif theme_index == 18 then terrain.init()
  elseif theme_index == 19 then lattice.init()
  elseif theme_index == 20 then kaleido.init()
  end
end

local function on_note_trigger()
  if     theme_index == 1  then pulse_trigger()
  elseif theme_index == 4  then hex_trigger()
  elseif theme_index == 5  then stars_trigger()
  elseif theme_index == 6  then wave_trigger()
  elseif theme_index == 7  then rain_trigger()
  elseif theme_index == 8  then spiral_trigger()
  elseif theme_index == 9  then liss_trigger()
  elseif theme_index == 10 then tunnel_trigger()
  elseif theme_index == 11 then bounce_trigger()
  elseif theme_index == 12 then grid_trigger()
  elseif theme_index == 13 then flow_trigger()
  elseif theme_index == 14 then morph_trigger()
  elseif theme_index == 15 then shatter_trigger()
  elseif theme_index == 16 then code_trigger()
  elseif theme_index == 17 then orbit_trigger()
  elseif theme_index == 18 then terrain.trigger()
  elseif theme_index == 19 then lattice.trigger()
  elseif theme_index == 20 then kaleido.trigger()
  end
end

------------------------------------------------------------------------
-- sequencer loops
------------------------------------------------------------------------

local function pad_loop()
  while true do
    if playing then
      local notes   = get_pad_notes()
      local rate    = PAD_RATES[params:get("pad_rate")]
      local len     = NOTE_LENS[params:get("pad_note_len")]
      local off_t   = math.min(len, rate * 0.95) * 60 / clock.get_tempo()
      for _, n in ipairs(notes) do pad_note_on(n) end
      on_note_trigger()
      local played = {table.unpack(notes)}
      clock.run(function()
        clock.sleep(off_t)
        for _, n in ipairs(played) do pad_note_off(n) end
      end)
      clock.sync(rate)
    else
      clock.sleep(0.1)
    end
  end
end

local function lead_loop()
  while true do
    if playing then
      sync_offset()
      drunk_sleep()
      local note  = get_lead_note()
      local rate  = LEAD_RATES[params:get("lead_rate")]
      local len   = NOTE_LENS[params:get("lead_note_len")]
      local off_t = math.min(len, rate * 0.95) * 60 / clock.get_tempo()

      if note then
        note = clamp(note + (params:get("lead_oct") - 4) * 12, 0, 127)
        local chord = build_chord(note, params:get("lead_density"))
        for _, n in ipairs(chord) do lead_note_on(n) end
        on_note_trigger()
        local played = chord
        clock.run(function()
          clock.sleep(off_t)
          for _, n in ipairs(played) do lead_note_off(n) end
        end)
      end

      clock.sync(rate)
    else
      clock.sleep(0.1)
    end
  end
end

local function bass_loop()
  while true do
    if playing then
      sync_offset()
      drunk_sleep()
      local note  = get_bass_note()
      local rate  = BASS_RATES[params:get("bass_rate")]
      local len   = NOTE_LENS[params:get("bass_note_len")]
      local off_t = math.min(len, rate * 0.95) * 60 / clock.get_tempo()
      if note and math.random(100) <= params:get("bass_density") then
        bass_note_on(note)
        on_note_trigger()
        local played = note
        clock.run(function()
          clock.sleep(off_t)
          bass_note_off(played)
        end)
      end
      clock.sync(rate)
    else
      clock.sleep(0.1)
    end
  end
end

local function sec_loop()
  while true do
    if playing then
      local rate    = SEC_RATES[params:get("sec_rate")]
      local len     = NOTE_LENS[params:get("sec_note_len")]
      local mode    = params:get("sec_mode")
      local sec_oct = params:get("sec_oct")
      local off_t   = math.min(len, rate * 0.95) * 60 / clock.get_tempo()
      local note    = nil

      if mode == 1 then  -- harmony
        if lead_last then
          note = offset_note(lead_last, params:get("sec_harmony_steps"))
          note = clamp(note + (sec_oct - 4) * 12, 0, 127)
        end
      elseif mode == 2 then  -- echo
        if lead_last then
          note = clamp(lead_last + (sec_oct - 4) * 12, 0, 127)
        end
      elseif mode == 3 then  -- counter
        local notes = get_scale_notes(sec_oct - 1, sec_oct)
        if #notes > 0 then
          sec_pos = clamp(sec_pos, 1, #notes)
          note = notes[sec_pos]
          if math.random() < 0.7 then
            sec_pos = sec_pos + sec_dir
          else
            sec_dir = -sec_dir
            sec_pos = sec_pos + sec_dir
          end
          sec_pos = clamp(sec_pos, 1, #notes)
          if sec_pos <= 2          then sec_dir =  1 end
          if sec_pos >= #notes - 1 then sec_dir = -1 end
        end
      end

      if note then
        local chord = build_chord(note, params:get("sec_density"))
        if mode == 2 then
          local echo_t = params:get("sec_echo_beats") * 60 / clock.get_tempo()
          local played = chord
          clock.run(function()
            clock.sleep(echo_t)
            for _, n in ipairs(played) do sec_note_on(n) end
            clock.run(function()
              clock.sleep(off_t)
              for _, n in ipairs(played) do sec_note_off(n) end
            end)
          end)
        else
          for _, n in ipairs(chord) do sec_note_on(n) end
          local played = chord
          clock.run(function()
            clock.sleep(off_t)
            for _, n in ipairs(played) do sec_note_off(n) end
          end)
        end
      end

      clock.sync(rate)
    else
      clock.sleep(0.1)
    end
  end
end

local function vst_loop()
  while true do
    if playing then
      local rate    = SEC_RATES[params:get("vst_rate")]
      local len     = NOTE_LENS[params:get("vst_note_len")]
      local mode    = params:get("vst_mode")
      local vst_oct = params:get("vst_oct")
      local off_t   = math.min(len, rate * 0.95) * 60 / clock.get_tempo()
      local note    = nil

      if mode == 1 then  -- harmony
        if lead_last then
          note = offset_note(lead_last, params:get("vst_harmony_steps"))
          note = clamp(note + (vst_oct - 4) * 12, 0, 127)
        end
      elseif mode == 2 then  -- echo
        if lead_last then
          note = clamp(lead_last + (vst_oct - 4) * 12, 0, 127)
        end
      elseif mode == 3 then  -- counter
        local notes = get_scale_notes(vst_oct - 1, vst_oct)
        if #notes > 0 then
          vst_pos = clamp(vst_pos, 1, #notes)
          note = notes[vst_pos]
          if math.random() < 0.7 then
            vst_pos = vst_pos + vst_dir
          else
            vst_dir = -vst_dir
            vst_pos = vst_pos + vst_dir
          end
          vst_pos = clamp(vst_pos, 1, #notes)
          if vst_pos <= 2          then vst_dir =  1 end
          if vst_pos >= #notes - 1 then vst_dir = -1 end
        end
      end

      if note then
        local chord = build_chord(note, params:get("vst_density"))
        if mode == 2 then
          local echo_t = params:get("vst_echo_beats") * 60 / clock.get_tempo()
          local played = chord
          clock.run(function()
            clock.sleep(echo_t)
            for _, n in ipairs(played) do vst_note_on(n) end
            clock.run(function()
              clock.sleep(off_t)
              for _, n in ipairs(played) do vst_note_off(n) end
            end)
          end)
        else
          for _, n in ipairs(chord) do vst_note_on(n) end
          local played = chord
          clock.run(function()
            clock.sleep(off_t)
            for _, n in ipairs(played) do vst_note_off(n) end
          end)
        end
      end

      clock.sync(rate)
    else
      clock.sleep(0.1)
    end
  end
end

------------------------------------------------------------------------
-- wow/flutter loop
------------------------------------------------------------------------

local function fx_loop()
  while true do
    clock.sleep(1/60)
    local wow_depth     = params:get("wow_depth")     / 100.0
    local flutter_depth = params:get("flutter_depth") / 100.0

    wow_val = wow_val + (math.random() - 0.5) * 0.15
    wow_val = wow_val * 0.985
    wow_val = math.max(-1, math.min(1, wow_val))

    flutter_hold = flutter_hold + 1
    if flutter_hold >= FLUTTER_HOLD then
      flutter_target = (math.random() - 0.5) * 2.0
      flutter_hold   = 0
    end
    flutter_val = flutter_val * 0.3 + flutter_target * 0.7

    local semitones = wow_val * wow_depth * 2.0
                    + flutter_val * flutter_depth * 0.8
    for voice_id, base_hz in pairs(playing_voices) do
      engine.start(voice_id, base_hz * (2 ^ (semitones / 12)))
    end

    local amp_base = params:get("pad_amp") / 100.0 * 0.8
    if flutter_depth > 0.02 then
      local amp_mod = 1.0 - math.abs(flutter_val) * flutter_depth * 0.5
      engine.level(math.max(0, amp_base * amp_mod))
    end

    -- osc to daydream scope (~15hz)
    osc_tick = osc_tick + 1
    if osc_tick >= 4 then
      osc_tick = 0

      -- continuous params
      osc_emit("/scope/noise_scale",
        {math.abs(wow_val) * wow_depth})
      osc_emit("/scope/kv_cache_attention_bias",
        {math.max(0.15, 1.0 - audio_level * 0.85)})
      osc_emit("/scope/vace_context_scale",
        {active_voice_count() / 5.0 * 1.5})

      -- play state
      if playing ~= last_playing_osc then
        last_playing_osc = playing
        if playing then
          osc_emit("/scope/paused",      {false})
          osc_emit("/scope/reset_cache", {true})
        else
          osc_emit("/scope/paused", {true})
        end
      end

      -- prompt on root/scale change
      if root_note ~= last_root_osc or scale_index ~= last_scale_osc then
        last_root_osc  = root_note
        last_scale_osc = scale_index
        local steps = math.min(20, PAD_RATES[params:get("pad_rate")] * 2)
        osc_emit("/scope/transition_steps", {steps})
        osc_emit("/scope/prompt", {get_osc_prompt()})
      end
    end
  end
end

------------------------------------------------------------------------
-- draw loop
------------------------------------------------------------------------

local function draw_loop()
  while true do
    clock.sleep(1/20)
    if not _menu.mode then
      time_val = time_val + 0.05
      screen.clear()
      screen.aa(0)

      if     theme_index == 1  then draw_pulse()
      elseif theme_index == 2  then draw_drift()
      elseif theme_index == 3  then draw_field()
      elseif theme_index == 4  then draw_hex()
      elseif theme_index == 5  then draw_stars()
      elseif theme_index == 6  then draw_wave()
      elseif theme_index == 7  then draw_rain()
      elseif theme_index == 8  then draw_spiral()
      elseif theme_index == 9  then draw_lissajous()
      elseif theme_index == 10 then draw_tunnel()
      elseif theme_index == 11 then draw_bounce()
      elseif theme_index == 12 then draw_grid()
      elseif theme_index == 13 then draw_flow()
      elseif theme_index == 14 then draw_morph()
      elseif theme_index == 15 then draw_shatter()
      elseif theme_index == 16 then draw_code()
      elseif theme_index == 17 then draw_orbit()
      elseif theme_index == 18 then terrain.draw()
      elseif theme_index == 19 then lattice.draw()
      elseif theme_index == 20 then kaleido.draw()
      end

      local root_names = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
      local root_name  = root_names[(root_note % 12) + 1] or "?"
      local scale_name = musicutil.SCALES[scale_index].name

      if k1_held then
        screen.level(12)
        screen.move(2, 7)
        screen.text(theme_names[theme_index] .. " " .. theme_index .. "/" .. #theme_names)
      else
        screen.level(playing and 12 or 4)
        screen.move(2, 7)
        screen.text(root_name .. " " .. scale_name)
      end

      if playing then
        screen.level(12)
        screen.move(124, 62)
        screen.text("*")
      end

      -- wow/flutter bars
      local wow_d = params:get("wow_depth")
      local flt_d = params:get("flutter_depth")
      local bar_max    = 44
      local lbl_bri    = k3_held and 10 or 3
      local bar_bri    = k3_held and 12 or 4
      local trough_bri = k3_held and 3  or 1

      screen.level(lbl_bri)
      screen.move(2, 57); screen.text("W")
      screen.move(2, 63); screen.text("F")

      if trough_bri > 0 then
        screen.level(trough_bri)
        screen.rect(9, 52, bar_max, 3); screen.fill()
        screen.rect(9, 59, bar_max, 3); screen.fill()
      end
      local wf = math.floor(wow_d / 100 * bar_max)
      local ff = math.floor(flt_d / 100 * bar_max)
      if wf > 0 then screen.level(bar_bri); screen.rect(9, 52, wf, 3); screen.fill() end
      if ff > 0 then screen.level(bar_bri); screen.rect(9, 59, ff, 3); screen.fill() end
      if k3_held then
        screen.level(10)
        screen.move(56, 57); screen.text(wow_d .. "%")
        screen.move(56, 63); screen.text(flt_d .. "%")
      end

      screen.update()
    end
  end
end

------------------------------------------------------------------------
-- params
------------------------------------------------------------------------

local function setup_params()
  local vport_names = {"none"}
  local vport_ids   = {0}
  for i = 1, #midi.vports do
    local n = midi.vports[i].name
    if n ~= nil and n ~= "none" and n ~= "" then
      table.insert(vport_names, i .. ":" .. n)
      table.insert(vport_ids, i)
    end
  end

  params:add_separator("KEY + SCALE")
  local root_opts = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
  params:add_option("root_note", "root", root_opts, root_note + 1)
  params:set_action("root_note", function(v) root_note = v - 1 end)
  local scale_list = {}
  for _, s in ipairs(musicutil.SCALES) do table.insert(scale_list, s.name) end
  params:add_option("scale", "scale", scale_list, default_scale)
  params:set_action("scale", function(v) scale_index = v end)
  params:add_number("oct_low",  "octave low",  1, 6, 3)
  params:add_number("oct_high", "octave high", 1, 7, 5)

  params:add_separator("PAD")
  params:add_option("pad_on",  "pad engine", {"off","on"}, 2)
  params:add_number("pad_amp", "amp", 0, 100, 65)
  params:set_action("pad_amp", function(v) engine.level(v / 100.0 * 0.8) end)
  params:add_option("pad_rate",     "rate",        PAD_RATE_NAMES, 2)
  params:add_option("pad_note_len", "note length", LEN_NAMES,      7)
  params:add_number("pad_density",  "density",     1, 3, 1)
  params:add_number("pad_release_ms", "release ms", 1000, 12000, 5000)
  params:set_action("pad_release_ms", function(v) engine.ampRel(v / 1000.0) end)
  params:add_number("pad_cutoff", "cutoff hz", 80, 2000, 500)
  params:set_action("pad_cutoff", function(v)
    engine.cut(math.max(0.5, math.min(20.0, v / 100.0)))
  end)
  params:add_number("pad_detune", "detune", 0, 100, 25)
  params:set_action("pad_detune", function(v) engine.detune(v * 0.08) end)

  params:add_separator("LEAD")
  params:add_option("midi_lead_dev", "device", vport_names, 1)
  params:set_action("midi_lead_dev", function(v)
    local id = vport_ids[v]
    midi_lead = (id and id > 0) and midi.connect(id) or nil
  end)
  params:add_number("lead_ch",      "channel",     1, 16, 1)
  params:add_number("lead_oct",      "octave",      1, 7,  4)
  params:add_option("lead_rate",     "rate",        LEAD_RATE_NAMES, 2)
  params:add_option("lead_note_len", "note length", LEN_NAMES,       6)
  params:add_number("lead_vel_min", "vel min", 1, 127, 35)
  params:add_number("lead_vel_max", "vel max", 1, 127, 80)
  params:add_number("lead_density", "density", 1, 3, 1)

  params:add_separator("BASS")
  params:add_option("midi_bass_dev", "device", vport_names, 1)
  params:set_action("midi_bass_dev", function(v)
    local id = vport_ids[v]
    midi_bass = (id and id > 0) and midi.connect(id) or nil
  end)
  params:add_number("bass_ch",      "channel",     1, 16, 2)
  params:add_number("bass_oct",     "octave",      1, 3,  2)
  params:add_option("bass_rate",     "rate",        BASS_RATE_NAMES, 2)
  params:add_option("bass_note_len", "note length", LEN_NAMES,       7)
  params:add_number("bass_vel_min", "vel min", 1, 127, 40)
  params:add_number("bass_vel_max", "vel max", 1, 127, 75)
  params:add_number("bass_density", "density %", 1, 100, 100)

  params:add_separator("SEC LEAD")
  params:add_option("midi_sec_dev", "device", vport_names, 1)
  params:set_action("midi_sec_dev", function(v)
    local id = vport_ids[v]
    midi_sec = (id and id > 0) and midi.connect(id) or nil
  end)
  params:add_number("sec_ch",   "channel", 1, 16, 3)
  params:add_option("sec_mode", "mode", {"harmony","echo","counter"}, 1)
  params:add_option("sec_rate",     "rate",        SEC_RATE_NAMES, 2)
  params:add_option("sec_note_len", "note length", LEN_NAMES,      5)
  params:add_number("sec_oct",      "octave",      1, 7,           4)
  params:add_number("sec_harmony_steps", "harmony steps", -7, 7, 2)
  params:add_number("sec_echo_beats",    "echo delay",    1, 8, 2)
  params:add_number("sec_density", "density", 1, 3, 1)

  params:add_separator("VST SYNTH")
  params:add_option("midi_vst_dev", "device", vport_names, 1)
  params:set_action("midi_vst_dev", function(v)
    local id = vport_ids[v]
    midi_vst = (id and id > 0) and midi.connect(id) or nil
  end)
  params:add_number("vst_ch",   "channel", 1, 16, 4)
  params:add_option("vst_mode", "mode", {"harmony","echo","counter"}, 1)
  params:add_option("vst_rate",     "rate",        SEC_RATE_NAMES, 2)
  params:add_option("vst_note_len", "note length", LEN_NAMES,      5)
  params:add_number("vst_oct",      "octave",      1, 7,           4)
  params:add_number("vst_harmony_steps", "harmony steps", -7, 7, 2)
  params:add_number("vst_echo_beats",    "echo delay",    1, 8, 2)
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

    params:add_separator("TIMING")
  params:add_option("seq_state", "state", {"stopped","playing"}, 2)
  params:set_action("seq_state", function(v)
    playing = (v == 2)
    if not playing then all_notes_off() end
  end)
  params:add_number("drunk", "drunk", 0, 100, 20)
  params:add_option("syncopation", "syncopation", {"none","soft","medium","hard"}, 1)

  params:add_separator("WOW / FLUTTER")
  params:add_number("wow_depth",     "wow depth",     0, 100, 35)
  params:add_number("flutter_depth", "flutter depth", 0, 100, 20)

  params:add_separator("DAYDREAM")
  params:add_option("osc_on", "send OSC", {"off","on"}, 1)

  params:add_separator("VISUALS")
  params:add_option("theme", "theme", theme_names, 1)
  params:set_action("theme", function(v) theme_index = v; init_particles() end)
  params:add_number("vis_speed",      "speed",      1, 10,  3)
  params:add_number("vis_brightness", "brightness", 1, 15, 10)
  params:add_number("num_particles",  "particles",  5, 40, 20)
  params:set_action("num_particles",  function()  init_particles() end)

  -- NETWORK: hosts/ports for the strata voice and the DAYDREAM scope. Edited on
  -- device and persisted in the pset, so a DHCP-drifted IP no longer needs a
  -- source edit. Read at send-time by strata_send / osc_emit.
  params:add_separator("NETWORK")
  params:add_text("strata_host", "strata host", "192.168.1.133")
  params:add_number("strata_port", "strata port", 1, 65535, 10111)
  params:add_text("osc_host", "scope host", "192.168.1.229")
  params:add_number("osc_port", "scope port", 1, 65535, 52178)
end

------------------------------------------------------------------------
-- init
------------------------------------------------------------------------

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
    if playing and params:get("strata_on") == 2 then
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

  -- auto-detect first MIDI vport for lead
  for i = 1, #midi.vports do
    local n = midi.vports[i].name
    if n ~= nil and n ~= "none" and n ~= "" then
      midi_lead = midi.connect(i)
      params:set("midi_lead_dev", 2)
      break
    end
  end

  -- PolySub: slow ambient pad tuned for BOC feel
  engine.level(0.52)
  engine.ampAtk(4.0)
  engine.ampDec(0.5)
  engine.ampSus(0.85)
  engine.ampRel(5.0)
  engine.cutAtk(2.0)
  engine.cutDec(0.5)
  engine.cutSus(0.7)
  engine.cutRel(4.0)
  engine.cutEnvAmt(0.4)
  engine.cut(2.5)
  engine.detune(2.0)
  engine.hzLag(0.01)
  engine.shape(0.2)
  engine.timbre(0.45)
  engine.sub(0.35)
  engine.fgain(0.3)
  engine.width(0.9)
  engine.noise(0.0)

  -- audio reactivity poll
  local amp_poll = poll.set("amp_out_l", function(val)
    if val > audio_level_smooth then
      audio_level_smooth = audio_level_smooth * 0.2 + val * 0.8
    else
      audio_level_smooth = audio_level_smooth * 0.92 + val * 0.08
    end
    audio_level = math.min(1.0, audio_level_smooth * 5)
  end)
  amp_poll.time = 1/30
  amp_poll:start()

  init_particles()

  playing = false

  params:read()
  params:bang()

  clock.link.set_start_stop_sync(true)
  clock.transport.start = function()
    clock.run(function()
      clock.sleep(0.05)
      clock.sync(4)
      playing = true
    end)
  end
  clock.transport.stop = function()
  playing = false
    all_notes_off()
  end

  pad_clock  = clock.run(pad_loop)
  lead_clock = clock.run(lead_loop)
  bass_clock = clock.run(bass_loop)
  sec_clock  = clock.run(sec_loop)
  vst_clock  = clock.run(vst_loop)
  strata_clock = clock.run(strata_loop)
  fx_clock   = clock.run(fx_loop)
  draw_clock = clock.run(draw_loop)
end

------------------------------------------------------------------------
-- encoders / keys
------------------------------------------------------------------------

function enc(n, d)
  if k1_held then
    if n == 1 then
      theme_index = ((theme_index - 1 + d) % #theme_names) + 1
      init_particles()
    end
  elseif k2_held then
    if n == 2 then
      root_note = math.max(0, math.min(11, root_note + d))
      params:set("root_note", root_note + 1)
    elseif n == 3 then
      scale_index = math.max(1, math.min(#musicutil.SCALES, scale_index + d))
      params:set("scale", scale_index)
    end
  elseif k3_held then
    if n == 2 then params:delta("wow_depth", d)
    elseif n == 3 then params:delta("flutter_depth", d)
    end
  end
end

function key(n, z)
  if z == 1 then
    if n == 1 then k1_held = true end
    if n == 2 then k2_held = true end
    if n == 3 then k3_held = true end
    if k2_held and k3_held then
      playing = not playing
      if not playing then all_notes_off() end
    end
  elseif z == 0 then
    if n == 1 then k1_held = false end
    if n == 2 then k2_held = false end
    if n == 3 then k3_held = false end
  end
end

------------------------------------------------------------------------
-- cleanup
------------------------------------------------------------------------

function cleanup()
  all_notes_off()
  poll.clear_all()
  if pad_clock  then clock.cancel(pad_clock)  end
  if lead_clock then clock.cancel(lead_clock) end
  if bass_clock then clock.cancel(bass_clock) end
  if sec_clock  then clock.cancel(sec_clock)  end
  if vst_clock  then clock.cancel(vst_clock)  end
  if fx_clock   then clock.cancel(fx_clock)   end
  if draw_clock then clock.cancel(draw_clock) end
end
