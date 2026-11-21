# NoiseTerrain (stage 1)

Endless noise terrain for Godot 4 with lakes, trees and a fast cloud ceiling.
Open the project and run `demo/demo.tscn`. Right mouse (or Tab) to look, WASD to fly,
Q/E down/up, Shift for speed, mouse wheel to change speed.

Built and tested in Godot 4.5.1 (Forward+). Everything is GDScript and shaders.

## The pieces

| Node / resource | What it does |
| --- | --- |
| `NoiseTerrain` | Streams the ground in cells around a target, on worker threads. Adds water and trees. |
| `NoiseTerrainSettings` | The terrain recipe: seed, noises, curves, lakes, climate, cell overrides. |
| `NoiseTerrainCellOverride` | Drops a height-map texture (or its own unique noise) into one cell. |
| `NoiseTerrainSky` | Cloud controls (height, on/off, coverage...) and the cloud shadows on the ground. Points at your `WorldEnvironment`; it never creates or changes the Environment. |

## How the height is made (`NoiseTerrainSettings`)

1. **Biome noise** (very large) is read through two curves: `height_curve` gives the base
   land height (below 0 is sea), `roughness_curve` says how hilly that biome is.
2. **Detail noise** adds hills and ridged mountains, scaled by the roughness. Dunes appear in dry areas.
3. **Lake noise** is read through `lake_curve`, which sinks low ground under the water line.
   Edit that curve to make lakes rarer, commoner, or steeper-sided.
4. **Moisture noise** picks desert, grass or forest. Height picks the tree line and snow line.
5. **Cell overrides** replace (or add to) chosen cells, blended at the edges so there is no seam.

Every height comes only from world position and the seed, so the same seed always gives the same world.

## How the cells work (`NoiseTerrain`)

- The world is a grid of big cells (`cell_size`, 4096 m). A cell splits into four as you get
  near, up to `max_lod` times (smallest 128 m). Every cell has the same triangle count.
- Old cells stay until their replacements are built, so there are no holes or double draws.
- Big cells are always built first as a safety net. If you outrun the builders you see
  coarse ground, never a gap.
- Skirts hide the cracks between cells of different detail.
- A floating origin re-centres the world every `shift_distance` metres. Connect to
  `origin_shifted(offset)` to move your own nodes. `get_height(x, z)` gives ground height.
- Progress is printed to the console (stage, cells done / total, per cent) and sent on the
  `progress(done, total)` signal, which the demo HUD shows.

## Keeping cells (the cache)

Cells you move away from are not thrown away: they are hidden and kept, so coming back shows
them at once instead of rebuilding. Settings on `NoiseTerrain` (Streaming group):

- `keep_distance_factor` (default 3): a kept cell is dropped once you are this many times
  further than where it stops being shown (where its bigger parent takes over). It is a
  multiple, so it scales with every cell size: a 128 m cell is kept to about 1.5 km, a 1 km
  cell to about 12 km.
- `cache_memory_mb` (default 100): limit on kept cells (an estimate of their mesh and tree
  memory). Past it, the furthest are dropped first. Most cells are 0.1-0.2 MB, forested 256 m
  cells up to about 0.5 MB. With the default keep distance the cache settles around
  300 cells / 30 MB on its own, so the limit is a safety net.
- `merge_margin` (default 1.15): a cell merges back into its parent only 15% further out
  than it split, so hovering near a boundary does not flicker. Only merging moves (a coarse
  cell is never shown closer than its split distance, which the tree fades rely on).

Kept cells that are wanted again come back without a rebuild, and cells that finish building
after you have moved on are kept rather than thrown away. The HUD shows kept cells, their
memory and cells built so far; `get_cached_count()`, `get_cache_mb()` and `get_build_count()`
give the same.

## Trees

Every tree is a fixed thing in the world. Trees sit on one fine world grid, and a coarser
cell holds a subset of exactly the same trees (same spot, size, turn and tint) as the smaller
cells beneath it, so nothing moves when cells split or merge. Forest cover is tested on the
true ground (moisture, height, slope over about 15 m), not on each cell's mesh, so every
level agrees about where forest is.

All the thinning and swapping happens smoothly in the tree shaders, by distance from the
detail centre, ahead of the cell changes:

- **Density:** all trees close in (about 370 m with the default `tree_detail_boost` of 1);
  each doubling of distance keeps a quarter of them, ramped, and finished before the coarser
  cell that lacks those trees can appear.
- **Fading in and out:** a fading tree starts a little short and in the forest-floor colour,
  so it sits into the ground tint, then darkens to its own colour as it reaches full height.
  A screen-door dissolve covers the first part, while it is still floor-coloured.
- **Models and cards:** close cells hold both; the model dissolves into the card at about
  480 to 650 m.
- **Far edge:** trees fade out by about 3.1 km.
- **Late cells:** if a cell arrives late (very fast flight, slow machine), the trees it adds
  fade in over about 0.35 s instead of appearing at once.

**The ground under the forest.** The terrain shader tints the ground wherever the forest data
puts trees, using the same weighting the trees are placed with: a darker forest floor at every
distance (`forest_floor_color` on `NoiseTerrain`, `forest_floor_strength` on the terrain
material), turning to canopy green (`forest_color`) as the trees thin out with distance. Far
forest is mostly painted on the ground, and trees fading in appear on matching ground.

Settings on `NoiseTerrain`:

- `tree_grid` (default 32): base density. Lower it to build cells faster.
- `tree_detail_boost` (default 1): mid-distance cells hold the trees of the next finer level,
  so thinning happens twice as far out. About 4x the trees in mid-range cells; 0 is cheaper.
  The LIGHT profile uses 0.
- `tree_grow_rate` (default 0.25): how much distant trees grow to make up for being fewer.
- `forest_floor_color`: ground under trees, and the colour fading trees start from.

The console prints the fade distances at start-up. They are worked out from `cell_size`,
`max_lod`, `lod_distance` and `tree_detail_boost`, so they stay in step if you change those.
**Your own tree model.** Set `tree_mesh` (about 1 unit tall, base at the origin; any mesh,
including a PrimitiveMesh such as a few-sided SphereMesh hemisphere). Its materials are kept:
each surface's StandardMaterial3D colour, texture, vertex-colour setting, roughness, UV scale
and alpha scissor are copied into the fading tree shader, so it fades like the built-in tree.
A surface with your own ShaderMaterial is used as it is if that shader includes
`tree_fade.gdshaderinc` and `tree_fresh.gdshaderinc` (see `shaders/tree.gdshader`); other
shader materials fall back to vertex colours, with a warning.

**Distant cards are baked from the model** at start-up (`bake_tree_cards`, on by default): a
side view with flat lighting, so the cards carry its plain colours and get lit in the scene.
Without a display (headless) the drawn conifer shape is used. The console says which.

## Clouds

One flat layer drawn in the sky shader: about 16 steps through 2D noise, no 3D textures,
no compositor pass, no baking. The same noise is read by the terrain shader for cloud shadows.
It is a ceiling: you cannot fly through it (it fades out as you reach the base).

The demo's `WorldEnvironment` node sits at the scene root with its Environment saved in the
scene: edit fog, tonemap, glow and so on there. The sky colours are on its sky material
(Environment > Sky > Sky Material). `NoiseTerrainSky.world_environment` points at that node
and only sets the cloud values on the sky material. `cloud_height` sets the height of the
cloud bases; untick `clouds_enabled` to remove the clouds and their shadows. To use the
clouds in your own scene, give your Sky a ShaderMaterial with `shaders/sky_clouds.gdshader`.

## Renderers and web

One project runs on Forward+, Mobile and Compatibility (OpenGL / WebGL). Nothing is reduced on
Forward+: the options below only act on web builds, or when you pick them.

- `profile` (on `NoiseTerrain`): `AUTO` = full detail everywhere except web builds, which get
  the light values. `FULL` = always exactly what is set on the node. `LIGHT` = always the
  `light_view_cells`, `light_cell_resolution` and `light_tree_grid` limits.
- `use_threads`: cells build on worker threads. Where threads are missing (a web export
  without thread support) it switches itself off and builds on the main thread instead,
  spending at most `main_thread_budget_ms` per frame.
- The water shader picks the right depth maths for the renderer by itself.
- The demo camera pulls its near and far planes in on Compatibility, whose depth buffer is
  less precise. Do the same on your own camera (near about 3 m, far about 40 km or less).
- Compatibility lights the scene brighter and more saturated than Forward+. Lower the sun
  energy or the environment exposure for that renderer if you want them closer.
- The console prints which renderer, profile and build mode are in use at start-up.

To try it on desktop: `godot --rendering-method gl_compatibility --path .`

## Tools

- `tools/build_demo.gd` rebuilds the demo scene and settings.
- `tools/stream_test.gd` flies the world headless and checks for holes and double draws.
- `tools/tree_pop_test.gd` flies low over forest and counts trees that pop (appear, vanish or
  swap model/card in one frame). Add `--fixed-fps 60` before `-s` for a 1/60 s game clock.
- `tools/tree_subset_test.gd` checks coarse cells hold exactly a subset of the finer cells' trees.
- `tools/tree_coverage.gd` measures tree coverage by distance, to compare density settings.
- `tools/cache_test.gd`: round trip reuse, keep distance and memory limit (`-- --cache-mb=10`),
  hover flicker at a split boundary, floating origin with kept cells.
- `tools/standin_test.gd`: coarse cells shown although finer ones are built, view cover (no
  overlaps, no gaps), settling when stopped, cache accounting. `--lag` = one cell built per frame.
- `tools/tree_pop_test.gd -- --back` flies out and back along the same line; `--lag` as above.
- `tools/screenshot.gd` renders test shots.

## Not done yet

- Collision (use `get_height` for now).
- Smooth blending of the ground between detail levels (ground cells swap in one step; trees fade).
- Water is one level everywhere, so lakes only form on low ground.
- Tree cards use a drawn silhouette, not a baked impostor of the model.
