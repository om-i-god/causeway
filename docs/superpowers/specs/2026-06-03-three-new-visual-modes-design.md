# Three New Visual Modes for Causeway

**Date:** 2026-06-03
**Status:** Approved

## Goal

Add three new audio-reactive visual themes to Causeway, growing the roster from
17 to 20. New themes: **terrain**, **lattice**, **kaleido**. They become theme
indices 18, 19, 20 and are cycled with K1+E1 like all others.

## Existing pattern (to follow)

Every theme is a trio of file-local functions:

- `init_X()` — (re)initialise the theme's particle/state tables.
- `X_trigger()` — *optional*; called on note-on for note-reactive themes.
- `draw_X()` — render one frame to the 128x64 mono screen.

Each theme is wired into **four dispatch sites**:

1. `theme_names` table (~line 136) — name appended in roster order.
2. `init_particles()` if/elseif chain (~line 1821).
3. note-trigger if/elseif chain (~line 1842) — only for themes with a trigger.
4. `draw` if/elseif chain (~line 2152).

### Shared contract

- Screen: 128 wide x 64 tall, monochrome, levels 0-15.
- `audio_level` — global, 0..1, smoothed + reactive (peak-fast / decay-slow).
- Params: `vis_brightness` (used as `params:get("vis_brightness")/15.0` scale),
  `vis_speed`, `num_particles`.
- All brightness writes clamp to 0..15 and multiply by the brightness scale,
  matching existing themes (e.g. `draw_pulse`, `draw_drift`).
- Render budget: `draw_loop` runs ~30fps. Keep per-frame vertex/sample counts
  modest so norns stays smooth.

No new params. No changes to existing themes. No softcut/engine changes.

## The three modes

### 18 - terrain

Wireframe heightfield scrolling toward the viewer.

- ~10 horizontal ridge rows marching from horizon (top: small, dim, narrow) to
  foreground (bottom: large, bright, wide) using fake linear perspective.
- Each row holds ~12 height samples. Row vertical amplitude scales with
  `audio_level` — loud => jagged peaks, quiet => near-flat plains.
- Rows advance toward the viewer at `vis_speed`; when a row passes the bottom it
  recycles to the horizon with fresh height samples.
- `terrain_trigger()` injects a raised peak bump at the horizon row that then
  rolls forward over subsequent frames.
- Brightness per row scales with depth (nearer = brighter) and the global scale.

### 19 - lattice

A single rotating wireframe icosahedron centred on screen.

- 12 vertices / 30 edges (icosahedron reads better than a cube at this size).
- Continuous rotation about two axes, rate from `vis_speed`.
- Perspective projection; edges drawn as lines; per-edge brightness scaled by
  average depth (nearer edges brighter) and the global brightness scale.
- `audio_level` pulses overall scale (size breathes with the audio).
- `lattice_trigger()` adds a momentary spin-kick (extra angular velocity that
  decays) plus a brief brightness flash.

### 20 - kaleido

Six-fold mirrored mandala of drifting particles.

- `num_particles` particles live inside one 60-degree wedge; the wedge is
  reflected/rotated 6x around centre to form live radial symmetry.
- Particles drift outward / orbit; radius driven by `audio_level` (louder =>
  bigger bloom).
- `kaleido_trigger()` seeds a bright shard at centre that travels outward,
  appearing in all six reflections simultaneously.
- Particle brightness scaled by the global brightness scale; recycle particles
  that drift off the usable radius back toward centre.

## Validation

- `luac -p causeway.lua` must pass (syntax/compile).
- Subagent code review of the diff.
- No hardware playtest this session unless requested; the heaviest themes
  (terrain, lattice) are kept within the stated vertex/sample budgets to protect
  framerate.

## Out of scope

- New params, menu/UI changes, changes to existing 17 themes, the HTML devlog /
  animated preview chips (those can be updated in a later pass if desired).
