# NoiseTerrain: handoff notes (updated 11 Nov 2026, tree fades)

For whoever continues this project (person or AI). Read with `README.md`, which explains how
to use the nodes. This file covers the goal, how the code works, what has been checked, and
what is left.

## Goal

Endless terrain for Godot 4 in GDScript. The owner cares
about the look and likes noise-made data.

Requirements given so far:

- Large noise for biomes, a second noise for detail, and a curve ("gradient") to set lake areas.
- Cells of terrain around the player that add detail as you get close. Smooth, not voxel.
  Height only (no caves or overhangs).
- Drop a cell in at chosen coordinates with its own unique noise texture.
- Lakes. Trees using MultiMesh / billboards, whatever covers ground quickly.
- Wispy clouds that are cheaper than the owner's other cloud systems.
- The WorldEnvironment is a node in the scene that the owner sets up. Scripts point at it and
  must not create or change the Environment.
- Cloud height settable; clouds can be turned off.
- One project for Forward+ (full fidelity, threads, water) and Compatibility / web.
  Different brightness between renderers is acceptable.
- Long-running work must show progress: stage, counts or per cent, console log lines.

## Files

| File | Role |
| --- | --- |
| `addons/noise_terrain/noise_terrain.gd` | `NoiseTerrain`: cell selection, threaded building, show/hide rules, floating origin, water, trees, profiles. |
| `addons/noise_terrain/noise_terrain_settings.gd` | `NoiseTerrainSettings`: the height function and climate. Thread-safe after `prepare()`. |
| `addons/noise_terrain/noise_terrain_cell_override.gd` | `NoiseTerrainCellOverride`: one drop-in cell. |
| `addons/noise_terrain/noise_terrain_sky.gd` | `NoiseTerrainSky`: cloud values, pushed to the sky material and the terrain material. |
| `addons/noise_terrain/shaders/clouds.gdshaderinc` | Cloud noise shared by the sky (clouds) and terrain (shadows). |
| `addons/noise_terrain/shaders/*.gdshader` | `sky_clouds`, `terrain`, `water`, `tree`, `tree_billboard`. |
| `demo/` | Demo scene, fly camera, HUD, `terrain_settings.tres`. |
| `tools/build_demo.gd` | Rebuilds `demo/demo.tscn` and `demo/terrain_settings.tres`. Edit this, not the .tscn, then re-run it. |
| `tools/stream_test.gd` | Headless flight test: holes, double draws, floating origin. |
| `tools/screenshot.gd` | Renders test shots to `user://shots`. |

## How it works

**Height** (`NoiseTerrainSettings._noise_height`): biome noise -> `height_curve` (base height)
and `roughness_curve`; detail fbm plus ridged noise scaled by roughness; lake noise ->
`lake_curve` sinks ground below `lake_max_altitude` (faded by base height, never a hard
cut-off); dunes where moisture is low. Curves are baked into 256-entry tables in `prepare()`
so worker threads never touch a Curve. Overrides blend to zero weight at the cell edge.

**Cells** (`NoiseTerrain`): key is `Vector3i(lod, x, z)`, lod 0 = `cell_size` (4096 m), each
level halves it. `_select` walks the quadtree and splits when the target is nearer than
`size * lod_distance`. `_build` runs on a WorkerThreadPool thread and returns a mesh plus a
tree transform buffer. `_collect` adds finished cells on the main thread. `_resolve` decides
visibility:

- An old cell stays until every wanted cell replacing it is built; new cells stay hidden until then.
- Every big (lod 0) cell in range is always built first and kept hidden as a safety net
  (`_base`). If a wanted cell has nothing standing in for it, the big cell is shown (`_active`)
  and older cells inside it are hidden.
- Skirts (edge strips hanging down) hide cracks between detail levels.

**Trees** (rewritten 11 Nov, to stop popping at detail changes): trees live on a fixed world
grid at the finest level (`cell_size / 2^max_lod / tree_grid` squares). A cell at level L walks
its own `tree_grid` squares and, for each, descends by hash (salt `1000 + level`) to one finest
square, so a coarse cell holds exactly a subset of its children's trees. Each tree gets a rank:
its coarsest level c sets the range `[4^-(max_lod-c+1), 4^-(max_lod-c))` (from 0 at the top
tree level). MultiMesh custom data: x = rank, y = tint. Forest cover uses the true ground
(`settings.height`, slope over 15 m), so every level agrees; the tree's y uses the cell's mesh
so it sits on the drawn ground.

The shaders (`tree_fade.gdshaderinc`, mirrored by `NoiseTerrain.tree_weights()`) keep a share
of ranks that falls by 4x per doubling of distance in ramped steps, finishing before the
matching coarser cell can show (fade distances from `_setup_tree_fades()`). Models and cards
cross-dissolve by distance; close cells carry both. Late cells: `_fresh_rank()` records which
trees a new cell adds over what it replaces; `_start_fresh_fades()` sets instance uniforms
`fresh_rank` / `fresh_time` when the cell first shows, and those trees fade in over 0.35 s on
`tree_clock`.

Later the same day: `tree_detail_boost` (cells hold the trees of level `cell level + boost`,
so `tree_grid << boost` squares, density distance doubled); a quick skip of squares whose
centre moisture is under 0.43 (forest needs over 0.46; moisture changes far less than 0.03
across a square); fades now start short and floor-coloured rather than shrinking from nothing;
the terrain shader includes `tree_fade.gdshaderinc` (instance uniforms moved to
`tree_fresh.gdshaderinc`) and tints the ground with the forest floor at every distance and
with canopy green as `tree_drawn_share()` falls.

**Clouds**: sky shader marches about 16 steps through a flat slab using 2D noise (two
slices blended by height stand in for 3D noise). The terrain shader samples the same noise
along the sun direction for shadows, inside a custom `light()`.

**Floating origin**: shifts by whole cells past `shift_distance`; emits `origin_shifted(offset)`.

**Renderers**: `profile` (AUTO / FULL / LIGHT) and `use_threads` fallback with
`main_thread_budget_ms`. Water shader has a `CURRENT_RENDERER` branch for depth.

## Things learned the hard way

- Godot 4.5's half-resolution sky pass (`AT_HALF_RES_PASS` / `HALF_RES_COLOR`) returned
  white in testing, so clouds are drawn in the full-resolution sky pass.
- In the Compatibility renderer `TIME` is only available inside `sky()`, so it is passed
  into the cloud function as an argument.
- Any hard `if` on a height value in the height function makes a cliff along that contour.
  Always fade. (This was the "jagged wall" bug along coasts.)
- `NoiseTexture2D` generates in the background: `await texture.changed` before `get_image()`.
- `is_loading()` must not report "done" before the first selection has run.
- Build priority must put big cells first, or fast flight starves them and holes appear.
- Tree popping came from placement, not missing fades: trees were seeded per level, sized per
  level and tinted by INSTANCE_ID, so every split swapped in a different forest. Fading over
  that would only cross-dissolve two forests. Fixed placement first, then fades.
- A smooth `(d0/d)^2` density curve is safe but loses about 3x the trees in mid range; the
  stepped, ramped curve keeps most of the old density without pops.
- Fades judged in GDScript tests need a steady clock: use `--fixed-fps 60`.
- The tree shader used to be a material_override, so a custom `tree_mesh` lost its material
  (white, since the shader read vertex colours). Now `_prepare_tree_model()` copies the mesh
  with a tree-shader material per surface, filled from each surface's StandardMaterial3D, and
  `_bake_tree_card()` renders the model in a SubViewport (ortho side view, white ambient only,
  linear tonemap) into the card texture. If no cell is small enough for models, cards cover
  everything (model fade set negative).
- Trees fading in by growing from nothing read as trees rising out of the ground at 1 km,
  and stood out on bright grass. Fading from floor colour on a floor-tinted ground hides them.

## What has been checked

Godot 4.5.1, software rendering (no real GPU), so no frame rates.

- Cell build: about 8 ms per cell on one thread.
- `stream_test.gd` at about 700 m/s and 4 km/s: no holes, no double draws, heights identical
  across origin shifts. Also passes with `--nothreads` and `--nothreads --light`.
- `tree_pop_test.gd`: old version 17,165 pops in 400 frames at 120 m/s (up to 2,155 trees in
  one frame); new version 6 small jumps. At 720 m/s: 11,546 before, 20 small jumps after
  (judged by drawn area, fixed 60 fps clock).
- `tree_subset_test.gd`: coarse trees are an exact subset of the finer cells' trees.
- Tree coverage (`tree_coverage.gd`) against the original version: about 120 to 140% out
  to 2 km (with `tree_detail_boost` 1 and grow 0.25); trees end at about 3.1 km (original cut
  off at about 3.5 km). About 32,000 trees drawn in the test view (original about 22,000).
- Pop test with the boost and the colour fade: 0 at 120 m/s and 0 at 720 m/s (drawn area,
  fixed 60 fps clock).
- Cell build about 12 ms (original 8 ms) in this sandbox.
- Renders checked by eye in Forward+ and Compatibility.
- The owner ran the first version on their own machine: 60 fps on the HUD in their screenshots, and happy with the speed and the mountains. Later versions have not been confirmed there yet.

Not checked: a real browser build; performance on web or low-end hardware.

## Known issues

- Ground cells swap in one step (visible on the ground; trees now fade).
- Water is one level, so lakes only form on low ground.
- Some lake banks are very steep where a lake cuts into a dune or hill (smooth, not jagged).
- Compatibility lights the scene brighter and more saturated; pale sand can blow out. Cause not pinned down.
- Tree cards are a drawn silhouette, not an impostor of the model; models and cards differ a little in colour.
- Clouds are a ceiling only: no flying through them.
- No collision (`get_height(x, z)` is available).

## Possible next steps (none agreed yet)

1. Terrain look: erosion-style noise, better rock/snow/grass shading, per-pixel normals for far cells.
2. Blend between detail levels.
3. Collision near the player.
4. Lakes at altitude; rivers.
5. Proper tree impostors and the owner's own tree models.
6. Use the owner's PaintedClouds system over this terrain (turn `clouds_enabled` off).
7. Browser test and tuning of the LIGHT profile.

## Commands

```
godot --headless --path . --import
godot --headless --path . -s tools/build_demo.gd
godot --headless --path . -s tools/stream_test.gd -- --speed=10 [--nothreads] [--light]
godot --path . -s tools/screenshot.gd -- --quick --only=start,sky
godot --rendering-method gl_compatibility --path .
```
