# Causeway — Polish & Health pass (design)

Date: 2026-06-07
Status: approved (pending spec review)

## Goal

Three independent, verifiable health fixes to bring Causeway's docs, code
structure, and network config up to the state of the actual code. No new musical
or visual features. Each workstream is self-contained and can ship on its own.

Source of truth for current behavior: `DEVLOG.md` (accurate/current) plus the
code in `causeway.lua`. The `README.md` is the stale artifact.

Local verification gate for every code change: `luac -p causeway.lua` must pass.
On-device reload retest is required but cannot be done from this machine — each
code workstream below lists what the user verifies on the norns.

---

## A. README + version header (docs only, no logic change)

**Problem.** `README.md` describes an older Causeway:
- Lists 4 voices; reality is 6 outputs — pad / lead / bass / sec lead / VST
  **+ Strata** (OSC to a second norns). The **DAYDREAM** video-prompt OSC
  sidecar is not mentioned at all.
- Lists 4 visual themes "selectable from params"; reality is **20 themes**,
  **live-cycled with K1+E1** (not chosen from params).
- Controls table is missing **K1+E1** (cycle theme) and **K2+K3** (play/stop).
- Header in `causeway.lua` still reads `-- v1.0`.

**Change.**
1. `README.md` voices table: add the **Strata** row (output: OSC → 2nd norns;
   role: 6th voice, sampler on a second device). Keep pad/lead/bass/sec/VST.
2. Add a **Strata OSC voice** subsection (melodic / chordal / arp modes; OSC
   paths `/strata/noteon`, `/strata/noteoff`, `/strata/alloff`; host/port now in
   params — see C).
3. Add a **DAYDREAM** subsection: optional second OSC stream, off by default,
   emits music-derived control values + a root-keyed text prompt to an external
   generative-video scope; one-way.
4. Controls table: add `K1 held + E1 → cycle visual theme` and
   `K2 + K3 together → play / stop`.
5. Replace the 4-theme "visual themes" table with all 20 (names from
   `theme_names`: pulse, drift, field, hex, stars, wave, rain, spiral, liss,
   tunnel, bounce, grid, flow, morph, shatter, code, orbit, terrain, lattice,
   kaleido) and correct the selection text to "cycled live with K1+E1."
6. Add a **Network** section documenting the NETWORK params group (from C).
7. Bump the `causeway.lua` header comment `-- v1.0` → `-- v1.4`.

**Verification.** Doc read-through; `luac -p` still passes after the one-line
header edit. No behavioral change to verify on device.

---

## B. 200-local refactor — moderate (`local V = {}` state namespace)

**Problem.** `causeway.lua` has **198 top-level (column-0) local declarations**,
2 under Lua's hard 200-locals-per-chunk limit. Because of this, the three newest
themes were declared as **globals** (`terrain`, `lattice`, `kaleido` at lines
~170–172) — a documented workaround that pollutes the global namespace and means
any further top-level local fails to compile.

**Change.** Introduce a single state namespace and migrate per-theme mutable
state into it:
1. Add `local V = {}` once (one local).
2. Migrate the ~25 per-theme state locals declared around lines 141–174 into
   fields of `V` — e.g. `local wave_phase = 0` → `V.wave_phase = 0`;
   `local spiral_points = {}` → `V.spiral_points = {}`. This covers the scalar
   phase/counter locals and the per-theme tables (hex_nodes, stars, rain_drops,
   bounce_balls, grid_nodes, spiral_points, liss_history, spiral_dust,
   shatter_flashes, morph_vphase, LISS_RATIOS, etc.).
3. Migrate the three ex-globals into the same namespace:
   `terrain` → `V.terrain`, `lattice` → `V.lattice`, `kaleido` → `V.kaleido`,
   and remove the global declarations + the explanatory "200-local limit"
   comment block.
4. Update every reference to these names throughout the theme `init_/draw_/
   trigger_` functions to the `V.` form.

**Scope guardrails.**
- Do **not** move `theme_index`/`theme_names` if they're read by control/UI code
  outside the theme functions — only if it's clean to do so. Migrating pure
  per-theme animation state is sufficient; the goal is dropping the local count,
  not maximal tidiness.
- The 37 theme `init_/draw_/trigger_` functions stay as plain `local function`s.
- Target end state: top-level local count ≈ **170–175** (≈25 freed), giving
  ~25–30 slots of headroom and **zero** script-defined globals for theme state.

**Risk.** Touches working visual code via many find/replace references; a missed
reference reads/writes the wrong (now-nil global) name. Mitigations:
- After migration, grep for any surviving bare references to the migrated names
  (e.g. `\bwave_phase\b` not preceded by `V.`) — must be zero hits.
- `luac -p causeway.lua` must pass.
- Confirm new top-level local count is < 190 (`grep -cE "^local " causeway.lua`).

**Verification (on device).** Reload script; cycle through **all 20 themes**
with K1+E1 and confirm each animates and responds to notes/audio level —
especially terrain, lattice, kaleido (the ex-globals) and any theme whose state
was migrated.

---

## C. Network hosts → params (NETWORK group, text params)

**Problem.** `STRATA_HOST`/`STRATA_PORT` and `OSC_HOST`/`OSC_PORT` are hardcoded
constants (lines ~27–28, ~64–65). Every DHCP-driven IP change requires editing
source. The user runs multiple norns whose IPs drift.

**Change.**
1. Add a **NETWORK** params group with:
   - `strata host` — text param, default `"192.168.1.133"`
   - `strata port` — number param, default `10111`, range 1–65535
   - `osc host` (DAYDREAM/scope host) — text param, default `"192.168.1.229"`
   - `osc port` — number param, default `52178`, range 1–65535
2. Send helpers read params at send-time instead of constants:
   - `strata_send` → `osc.send({params:get("strata_host"),
     params:get("strata_port")}, path, {...})`
   - `osc_emit`/DAYDREAM sender → same pattern with `osc_host`/`osc_port`.
3. Remove the four `local` constants (frees up to 4 more top-level locals,
   compounding with B).
4. Text params persist in the pset, so the value survives reloads once set.

**Risk.** Low/additive. The one subtlety: params must exist before any send
fires. Mitigation: add the NETWORK group during `init()` param construction
alongside the other groups, before clocks start; guard send helpers are only
called after init (they already are — sends happen inside running clocks).

**Verification (on device).** Confirm NETWORK group appears in params; edit
`strata host`, confirm Strata voice on the second norns still receives notes;
confirm value persists across a script reload.

---

## Sequencing

A, B, C are independent. Suggested order: **B → C → A**, because B and C both
reduce the local count and touch `causeway.lua`, and A's README "Network"
section should describe C's final param names. Each lands as its own commit with
`luac -p` passing.

## Out of scope

- No new musical behavior, no new themes, no UI redesign.
- No change to the OSC message formats or the DAYDREAM prompt table.
- No `luacheck` setup (only `luac -p` available locally).
