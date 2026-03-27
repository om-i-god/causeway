-- causeway
-- slow generative music for multiple synths
-- pad + lead + bass + secondary voice
-- v1.0

engine.name = "PolySub"

local musicutil = require("musicutil")

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

-- visuals
local time_val    = 0
local theme_index = 1
local theme_names = {"pulse","drift","field","hex"}

local rings      = {}
local bands      = {}
local columns    = {}
local hex_nodes  = {}

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
  rings = {}
end

local function pulse_trigger()
  if #rings < 24 then
    table.insert(rings, {radius = 2 + audio_level * 6, bri = 11 + audio_level * 4})
  end
end

local function draw_pulse()
  local bri_scale = params:get("vis_brightness") / 15.0
  local spd = params:get("vis_speed") * 0.35
  local cx, cy = 64, 32
  for i = #rings, 1, -1 do
    local r = rings[i]
    r.radius = r.radius + spd
    r.bri    = r.bri - 0.25
    if r.bri <= 0 or r.radius > 90 then
      table.remove(rings, i)
    else
      local b = clamp(math.floor(r.bri * bri_scale), 0, 15)
      if b > 0 then
        screen.level(b)
        screen.circle(cx, cy, r.radius)
        screen.stroke()
      end
    end
  end
  local pb = clamp(math.floor((3 + audio_level * 11) * bri_scale), 0, 15)
  if pb > 0 then
    screen.level(pb)
    screen.circle(cx, cy, 2 + audio_level * 10)
    screen.fill()
  end
end

------------------------------------------------------------------------
-- drift theme
------------------------------------------------------------------------

local function init_drift()
  bands = {}
  local count = params:get("num_particles")
  for i = 1, count do
    bands[i] = {
      y     = math.random(0, 63),
      w     = math.random(10, 60),
      spd   = (math.random() * 0.3 + 0.05) * (math.random() < 0.5 and 1 or -1),
      bri   = math.random(2, 8),
      phase = math.random() * math.pi * 2,
    }
  end
end

local function draw_drift()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.005
  for _, b in ipairs(bands) do
    b.phase = b.phase + vis_spd + audio_level * 0.02
    b.y     = b.y + b.spd * (vis_spd * 8 + audio_level * 0.4)
    if b.y < -4 then b.y = 68 end
    if b.y >  68 then b.y = -4 end
    local brightness = b.bri + math.sin(b.phase) * 2 + audio_level * 8
    local bri = clamp(math.floor(brightness * bri_scale), 0, 15)
    local w   = math.floor(b.w * (1 + audio_level * 0.6))
    local x   = math.floor((128 - w) / 2)
    if bri > 0 then
      screen.level(bri)
      screen.move(x, math.floor(b.y))
      screen.line(x + w, math.floor(b.y))
      screen.stroke()
    end
  end
end

------------------------------------------------------------------------
-- field theme
------------------------------------------------------------------------

local function init_field()
  columns = {}
  local count = math.max(params:get("num_particles"), 16)
  local cw    = math.floor(128 / count)
  for i = 1, count do
    columns[i] = {
      x     = (i - 1) * cw,
      cw    = cw,
      h     = math.random(2, 18),
      phase = math.random() * math.pi * 2,
      speed = math.random() * 0.04 + 0.01,
    }
  end
end

local function draw_field()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.015
  for _, c in ipairs(columns) do
    c.phase = c.phase + c.speed + vis_spd
    local h = math.floor((c.h + math.sin(c.phase) * c.h * 0.6) * (1 + audio_level * 3.5))
    h = clamp(h, 1, 31)
    local bri = clamp(math.floor((4 + audio_level * 10) * bri_scale), 0, 15)
    if bri > 0 then
      screen.level(bri)
      screen.rect(c.x, 32 - h, math.max(1, c.cw - 1), h * 2)
      screen.fill()
    end
  end
end

------------------------------------------------------------------------
-- hex theme
------------------------------------------------------------------------

local function init_hex()
  hex_nodes = {}
  local r = 11
  for row = 0, 5 do
    for col = 0, 8 do
      local x = col * r * 1.732 + (row % 2) * r * 0.866 - 16
      local y = row * r * 1.5 - 8
      if x >= -r and x <= 128 + r and y >= -r and y <= 64 + r then
        table.insert(hex_nodes, {
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
  for i = 1, math.random(1, 4) do
    if #hex_nodes > 0 then
      hex_nodes[math.random(1, #hex_nodes)].pulse = 10 + audio_level * 5
    end
  end
end

local function draw_hex()
  local bri_scale = params:get("vis_brightness") / 15.0
  local vis_spd   = params:get("vis_speed") * 0.008
  for _, node in ipairs(hex_nodes) do
    node.phase = node.phase + vis_spd
    node.pulse = node.pulse * 0.92
    local bri = clamp(math.floor(
      (node.bri + math.sin(node.phase) * 1.5 + node.pulse + audio_level * 6) * bri_scale
    ), 0, 15)
    if bri > 0 then
      draw_polygon(node.x, node.y, 6, node.r * 0.82, node.phase, bri)
    end
  end
end

------------------------------------------------------------------------
-- visual dispatch
------------------------------------------------------------------------

local function init_particles()
  if     theme_index == 1 then init_pulse()
  elseif theme_index == 2 then init_drift()
  elseif theme_index == 3 then init_field()
  elseif theme_index == 4 then init_hex()
  end
end

local function on_note_trigger()
  if     theme_index == 1 then pulse_trigger()
  elseif theme_index == 4 then hex_trigger()
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

      if     theme_index == 1 then draw_pulse()
      elseif theme_index == 2 then draw_drift()
      elseif theme_index == 3 then draw_field()
      elseif theme_index == 4 then draw_hex()
      end

      local root_names = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
      local root_name  = root_names[(root_note % 12) + 1] or "?"
      local scale_name = musicutil.SCALES[scale_index].name

      screen.level(playing and 12 or 4)
      screen.move(2, 7)
      screen.text(root_name .. " " .. scale_name)

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

  params:add_separator("VISUALS")
  params:add_option("theme", "theme", theme_names, 1)
  params:set_action("theme", function(v) theme_index = v; init_particles() end)
  params:add_number("vis_speed",      "speed",      1, 10,  3)
  params:add_number("vis_brightness", "brightness", 1, 15, 10)
  params:add_number("num_particles",  "particles",  5, 40, 20)
  params:set_action("num_particles",  function()  init_particles() end)
end

------------------------------------------------------------------------
-- init
------------------------------------------------------------------------

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
  fx_clock   = clock.run(fx_loop)
  draw_clock = clock.run(draw_loop)
end

------------------------------------------------------------------------
-- encoders / keys
------------------------------------------------------------------------

function enc(n, d)
  if k2_held then
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
    if n == 2 then k2_held = true end
    if n == 3 then k3_held = true end
    if k2_held and k3_held then
      playing = not playing
      if not playing then all_notes_off() end
    end
  elseif z == 0 then
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
