class_name NoiseTerrain
extends Node3D
## Endless height-based terrain streamed in cells around a target (camera or player).
##
## The world is a grid of big cells (settings.cell_size). Each cell splits into four smaller
## cells as the target gets close, again and again up to max_lod, so detail arrives where you
## are and far land stays cheap. Every cell uses the same number of triangles whatever its size.
## Cells are built on worker threads and swapped in only when their replacements are ready,
## so there are no holes. Trees are placed per cell: models up close, flat cards further out.

## Sent after a floating-origin shift: everything in the world moved by -offset.
signal origin_shifted(offset: Vector3)
## Sent as cells finish building: done and total for the current batch.
signal progress(done: int, total: int)

@export var settings: NoiseTerrainSettings
## The node the terrain follows. Leave empty to follow the current camera.
@export var target: Node3D

@export_group("Detail")
## How many big cells are drawn in each direction (view distance = this x cell_size).
@export_range(1, 12) var view_cells: int = 5
## How many times a cell can split. Smallest cell = cell_size / 2^max_lod.
@export_range(0, 7) var max_lod: int = 5
## A cell splits when the target is nearer than this many cell widths. Higher = more detail further out.
@export_range(0.8, 4.0) var lod_distance: float = 1.7
## Squares along one side of every cell.
@export_range(8, 128) var cell_resolution: int = 48

@export_group("Platform")
## FULL = everything exactly as set on this node. LIGHT = the lighter values below.
## AUTO = FULL everywhere except web builds, which get LIGHT. Forward+ on desktop is never reduced.
@export var profile: Profile = Profile.AUTO
## LIGHT profile: upper limits applied to view_cells, cell_resolution and tree_grid.
@export_range(1, 12) var light_view_cells: int = 3
@export_range(8, 128) var light_cell_resolution: int = 32
@export_range(4, 64) var light_tree_grid: int = 14
## Build cells on worker threads. Switched off by itself where threads are not available
## (web exports without thread support); cells are then built on the main thread within the budget below.
@export var use_threads: bool = true
## Without threads: milliseconds per frame spent building cells. Lower = smoother, slower to fill in.
@export_range(1.0, 30.0) var main_thread_budget_ms: float = 5.0

@export_group("Streaming")
## Cells built at the same time. 0 = pick from the processor count.
@export var max_jobs: int = 0
## Finished cells added to the scene per frame.
@export_range(1, 32) var cells_per_frame: int = 6
## Print a progress line for every streaming batch, not only the big ones.
@export var log_all_batches: bool = false
## A cell merges back into its bigger parent only once you are this many times further than
## the distance it split at, so hovering near the boundary does not flicker. 1 = no margin.
@export_range(1.0, 2.0) var merge_margin: float = 1.15
## Cells you move away from are kept, hidden, instead of being thrown away, so coming back
## shows them at once with no rebuild. A cell is only dropped once you are this many times
## further than where it stops being shown (its parent's merge distance), so it scales with
## cell size. 1 = drop as soon as it stops being shown.
@export_range(1.0, 10.0) var keep_distance_factor: float = 3.0
## Upper limit on the kept (hidden) cells, in megabytes of mesh and tree data (an estimate).
## Past it, the furthest kept cells are dropped first.
@export var cache_memory_mb: float = 100.0
## Re-centre the world when the target is this far from the origin (0 = never).
@export var shift_distance: float = 8192.0
## Move the target back with the world when the origin shifts.
@export var move_target_on_shift: bool = true

@export_group("Water")
@export var water: bool = true

@export_group("Trees")
@export var trees: bool = true
@export var tree_height: float = 16.0
## Tree positions tried along one side of every cell (so trees thin out with distance).
@export_range(4, 64) var tree_grid: int = 32
## Cells this size or smaller get trees.
@export var tree_max_cell_size: float = 1024.0
## Cells this size or smaller get tree models; larger ones get flat cards.
@export var tree_model_cell_size: float = 256.0
## Optional replacement for the built-in tree model: about 1 unit tall, base at the origin.
## Its materials are used (StandardMaterial3D colour, texture, vertex colours, roughness,
## UV scale, alpha scissor), and distant cards are baked from it at start-up.
@export var tree_mesh: Mesh
## Bake the distant tree cards from the tree model (needs a display). Off = drawn conifer shape.
@export var bake_tree_cards: bool = true
## Pushes the tree thinning further out: mid-distance cells hold the trees of cells this
## many levels finer. 1 = twice as far before trees thin (about 4x the trees in mid-range
## cells, more building work); 0 = thin as soon as the cells allow. The LIGHT profile uses 0.
@export_range(0, 2) var tree_detail_boost: int = 1
## Ground colour under trees, also the colour trees start from as they fade in.
@export var forest_floor_color: Color = Color(0.14, 0.18, 0.08)
## How much distant trees grow to make up for being fewer (0 = all the same size).
@export_range(0.0, 1.0) var tree_grow_rate: float = 0.25

@export_group("Materials")
@export var terrain_material: ShaderMaterial
@export var water_material: ShaderMaterial

enum Profile { AUTO, FULL, LIGHT }

const _SHADERS := "res://addons/noise_terrain/shaders/"

var _nodes := {} # Vector3i(lod, x, z) -> MeshInstance3D, built and in the scene
var _desired := {} # Vector3i -> distance, the cells we want on screen
var _base := {} # Every big cell in range. These are always built and kept as a safety net.
var _active := {} # Big cells currently shown as a stand-in because finer cells are late.
var _cache := {} # Vector3i -> MeshInstance3D: built cells no longer wanted, kept hidden for reuse.
var _cache_bytes := 0
var _was_split := {} # Cells split on the last selection (for the merge margin).
var _build_count := 0
var _select_at := Vector3.ZERO # World x, z and altitude term of the last selection.
var _queue: Array[Vector3i] = []
var _running := {}
var _results: Array = []
var _mutex := Mutex.new()
var _indices := PackedInt32Array()
var _origin_x := 0.0
var _origin_z := 0.0
var _last_select := Vector3(INF, INF, INF)
var _started := false
var _batch_total := 0
var _batch_done := 0
var _batch_start := 0
var _batch_logged := -1
var _tree_model: Mesh
var _tree_card: Mesh
var _tree_card_material: ShaderMaterial
var _tree_materials: Array[ShaderMaterial] = [] # Card and every model surface: all get the fade values.
var _water_node: MeshInstance3D
var _tree_top_lod := 0 # The coarsest cell level that gets trees.
var _tree_top_level := 0 # The tree level those cells hold (_tree_top_lod + boost).
var _tree_fade := {} # Distances shared with the tree shaders; see _setup_tree_fades().
var _lod_altitude := 0.0
var _clock := 0.0 # Seconds, shared with the tree shaders for fade-ins.
var _closing := false


func _ready() -> void:
	if settings == null:
		settings = NoiseTerrainSettings.new()
	var light := profile == Profile.LIGHT or (profile == Profile.AUTO and OS.has_feature("web"))
	if light:
		view_cells = mini(view_cells, light_view_cells)
		cell_resolution = mini(cell_resolution, light_cell_resolution)
		tree_grid = mini(tree_grid, light_tree_grid)
		tree_detail_boost = 0
	if use_threads and (OS.has_feature("nothreads") or (OS.has_feature("web") and not OS.has_feature("threads"))):
		use_threads = false
	print("[NoiseTerrain] renderer: %s, profile: %s, cell building: %s" % [
		"Compatibility" if is_compatibility_renderer() else "Forward+ / Mobile",
		"light" if light else "full",
		"worker threads" if use_threads else "main thread, %.0f ms per frame" % main_thread_budget_ms])
	print("[NoiseTerrain] stage 1/3: preparing noise, curves and override cells")
	await settings.prepare()
	print("[NoiseTerrain] stage 2/3: materials and tree meshes")
	_make_materials()
	_indices = _make_indices(cell_resolution)
	var source := tree_mesh if tree_mesh != null else _make_tree_model()
	_tree_model = _prepare_tree_model(source)
	_tree_card = _make_tree_card()
	await _bake_tree_card(source)
	_setup_tree_fades()
	if water:
		_make_water()
	print("[NoiseTerrain] stage 3/3: streaming cells (smallest cell %.0f m, view %.1f km)" % [
		settings.cell_size / float(1 << max_lod), view_cells * settings.cell_size / 1000.0])
	_started = true


func _exit_tree() -> void:
	_closing = true
	_queue.clear()
	for key in _running:
		if _running[key] >= 0:
			WorkerThreadPool.wait_for_task_completion(_running[key])
	_running.clear()


# ---------------------------------------------------------------- public helpers

## True when the game is running on the Compatibility (OpenGL / WebGL) renderer.
static func is_compatibility_renderer() -> bool:
	if RenderingServer.has_method("get_current_rendering_method"):
		return RenderingServer.call("get_current_rendering_method") == "gl_compatibility"
	return str(ProjectSettings.get_setting_with_override("rendering/renderer/rendering_method")) == "gl_compatibility"


## Ground height at a scene position (the position your nodes use).
func get_height(scene_x: float, scene_z: float) -> float:
	return settings.height(scene_x + _origin_x, scene_z + _origin_z)


## Scene position -> true world position (differs after floating-origin shifts).
func to_world(scene_position: Vector3) -> Vector3:
	return scene_position + Vector3(_origin_x, 0.0, _origin_z)


func get_origin() -> Vector2:
	return Vector2(_origin_x, _origin_z)


## True while cells are still being built.
func is_loading() -> bool:
	return _last_select.x == INF or not _queue.is_empty() or not _running.is_empty()


## Seconds on the tree fade clock (see tree_fresh in tree_fade.gdshaderinc).
func get_tree_clock() -> float:
	return _clock


## The altitude term the cell picker and the tree fades use (height above ground x 0.6).
func get_lod_altitude() -> float:
	return _lod_altitude


## How visible a tree is, as Vector2(model, card), each 0 to 1. Mirrors tree_fade.gdshaderinc
## (without the screen-space dissolve). metric = distance from the detail centre, including
## the altitude term; rank = the tree's rank (INSTANCE_CUSTOM.x).
func tree_weights(metric: float, rank: float) -> Vector2:
	var keep := 1.0
	var u := log(maxf(metric, 1.0) / _tree_fade.density) / log(2.0)
	if u > 0.0:
		var k := floorf(u)
		keep = pow(2.0, -2.0 * (k + smoothstep(0.35, 1.0, u - k)))
	var thin := (1.0 - smoothstep(0.25, 1.0, rank / keep)) * (1.0 - smoothstep(_tree_fade.far_start, _tree_fade.far_end, metric))
	var share := 1.0 - smoothstep(_tree_fade.model_start, _tree_fade.model_end, metric)
	return Vector2(thin * share, thin * (1.0 - share))


func get_cell_count() -> int:
	return _nodes.size()


## Built cells kept hidden for reuse.
func get_cached_count() -> int:
	return _cache.size()


## Estimated memory of the kept cells, in megabytes.
func get_cache_mb() -> float:
	return float(_cache_bytes) / 1048576.0


## How many cells have been built since start-up (reused cells do not count).
func get_build_count() -> int:
	return _build_count


func get_pending_count() -> int:
	return _queue.size() + _running.size()


# ---------------------------------------------------------------- per frame

func _process(delta: float) -> void:
	if not _started:
		return
	_clock += delta
	var follow := target if target != null else get_viewport().get_camera_3d()
	if follow == null:
		return
	var p := follow.global_position
	if shift_distance > 0.0 and Vector2(p.x, p.z).length() > shift_distance:
		_shift_origin(follow)
		p = follow.global_position
	_lod_altitude = maxf(p.y - get_height(p.x, p.z), 0.0) * 0.6
	for m in _fade_materials():
		m.set_shader_parameter("lod_center", p)
		m.set_shader_parameter("lod_altitude", _lod_altitude)
		m.set_shader_parameter("tree_clock", _clock)
	var smallest := settings.cell_size / float(1 << max_lod)
	if p.distance_to(_last_select) > smallest * 0.35:
		_last_select = p
		_select(p.x + _origin_x, p.y, p.z + _origin_z)
	_start_jobs()
	_collect()
	if _water_node != null:
		_water_node.position = Vector3(snappedf(p.x, 64.0), settings.sea_level, snappedf(p.z, 64.0))


func _shift_origin(follow: Node3D) -> void:
	var s := settings.cell_size
	var p := follow.global_position
	var offset := Vector3(snappedf(p.x, s), 0.0, snappedf(p.z, s))
	if offset == Vector3.ZERO:
		return
	_origin_x += offset.x
	_origin_z += offset.z
	for key in _nodes:
		_nodes[key].position -= offset
	for key in _cache:
		_cache[key].position -= offset
	if move_target_on_shift:
		follow.global_position -= offset
	_last_select -= offset
	_push_origin()
	print("[NoiseTerrain] floating origin moved to (%.0f, %.0f)" % [_origin_x, _origin_z])
	origin_shifted.emit(offset)


func _push_origin() -> void:
	terrain_material.set_shader_parameter("world_origin", Vector2(_origin_x, _origin_z))
	if water_material != null:
		water_material.set_shader_parameter("origin_wrap", Vector2(fposmod(_origin_x, 1024.0), fposmod(_origin_z, 1024.0)))


# ---------------------------------------------------------------- choosing cells

func _select(wx: float, wy: float, wz: float) -> void:
	var s := settings.cell_size
	var altitude := maxf(wy - settings.height(wx, wz), 0.0) * 0.6
	_desired.clear()
	_base.clear()
	var cx := floori(wx / s)
	var cz := floori(wz / s)
	var reach := (float(view_cells) + 0.5) * (float(view_cells) + 0.5)
	var split_now := {}
	for dz in range(-view_cells, view_cells + 1):
		for dx in range(-view_cells, view_cells + 1):
			if float(dx * dx + dz * dz) <= reach:
				_base[Vector3i(0, cx + dx, cz + dz)] = true
				_visit(0, cx + dx, cz + dz, wx, wz, altitude, split_now)
	_was_split = split_now
	_select_at = Vector3(wx, wz, altitude)
	_reuse_cached()
	_queue.clear()
	for key in _desired:
		if not _nodes.has(key) and not _running.has(key):
			_queue.append(key)
	for key in _base:
		if not _desired.has(key) and not _nodes.has(key) and not _running.has(key):
			_queue.append(key)
	# Most urgent last, so pop_back() hands it out. Big cells always go first (they are the
	# safety net); after that, urgency is distance measured in cell widths.
	_queue.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return _urgency(a) > _urgency(b))
	var waiting := _queue.size() + _running.size()
	if waiting > 0:
		if _batch_done >= _batch_total:
			_batch_done = 0
			_batch_start = Time.get_ticks_msec()
			_batch_logged = -1
		_batch_total = _batch_done + waiting
	_resolve()
	_trim_cache(wx, wz, altitude)


func _visit(lod: int, x: int, z: int, wx: float, wz: float, altitude: float, split_now: Dictionary) -> void:
	var size := settings.cell_size / float(1 << lod)
	var key := Vector3i(lod, x, z)
	var distance := _cell_distance(key, wx, wz, altitude)
	# Split at the usual distance; once split, merge back only a little further out. (Only the
	# merge moves: a coarse cell is never shown closer than size x lod_distance, which the tree
	# fades rely on.)
	var limit := size * lod_distance * (merge_margin if _was_split.has(key) else 1.0)
	if lod < max_lod and distance < limit:
		split_now[key] = true
		for j in 2:
			for i in 2:
				_visit(lod + 1, x * 2 + i, z * 2 + j, wx, wz, altitude, split_now)
	else:
		_desired[key] = distance


func _cell_distance(key: Vector3i, wx: float, wz: float, altitude: float) -> float:
	var size := settings.cell_size / float(1 << key.x)
	var dx := wx - clampf(wx, float(key.y) * size, float(key.y + 1) * size)
	var dz := wz - clampf(wz, float(key.z) * size, float(key.z + 1) * size)
	return sqrt(dx * dx + dz * dz + altitude * altitude)


# ---------------------------------------------------------------- the cell cache

## Brings kept cells that are wanted again back into play (still hidden: _resolve shows them
## when it is their turn). Their trees fade in as for a newly built cell.
func _reuse_cached() -> void:
	if _cache.is_empty():
		return
	for wanted in [_desired, _base]:
		for key in wanted:
			if _nodes.has(key) or not _cache.has(key):
				continue
			var cell: MeshInstance3D = _cache[key]
			_cache.erase(key)
			_cache_bytes -= int(cell.get_meta("bytes", 0))
			if cell.get_child_count() > 0:
				cell.set_meta("fresh_rank", _fresh_rank(key))
			_nodes[key] = cell


## Hides a cell that is no longer wanted and keeps it for reuse.
func _retire(key: Vector3i) -> void:
	var cell: MeshInstance3D = _nodes[key]
	_nodes.erase(key)
	_active.erase(key)
	cell.visible = false
	if cell.has_meta("fresh_rank"):
		cell.remove_meta("fresh_rank")
	_cache[key] = cell
	_cache_bytes += int(cell.get_meta("bytes", 0))


## Drops kept cells once you are far enough away (keep_distance_factor times the distance at
## which each stops being shown), then the furthest ones while over the memory limit.
func _trim_cache(wx: float, wz: float, altitude: float) -> void:
	if _cache.is_empty():
		return
	var distances := {}
	for key in _cache.keys():
		var size := settings.cell_size / float(1 << key.x)
		var shown_until := 2.0 * size * lod_distance * merge_margin
		var distance := _cell_distance(key, wx, wz, altitude)
		if distance > shown_until * maxf(keep_distance_factor, 1.0):
			_drop_cached(key)
		else:
			distances[key] = distance
	var limit := int(cache_memory_mb * 1048576.0)
	if _cache_bytes <= limit:
		return
	var order := distances.keys()
	order.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return distances[a] > distances[b])
	for key in order:
		if _cache_bytes <= limit:
			break
		_drop_cached(key)


func _drop_cached(key: Vector3i) -> void:
	var cell: MeshInstance3D = _cache[key]
	_cache.erase(key)
	_cache_bytes -= int(cell.get_meta("bytes", 0))
	cell.queue_free()


func _urgency(key: Vector3i) -> float:
	if key.x == 0:
		return -1.0
	return _desired[key] * float(1 << key.x)


static func _parent(key: Vector3i) -> Vector3i:
	return Vector3i(key.x - 1, floori(key.y / 2.0), floori(key.z / 2.0))


## Decides which built cells are shown. An old cell stays until everything replacing it is
## ready, and new cells stay hidden until the old one can go, so the ground never has a hole
## and never draws twice. If flying outruns the builders, the big cell underneath is shown
## as a coarse stand-in until the finer cells catch up.
func _resolve() -> void:
	var blocked := {} # Cells with a wanted, unfinished cell somewhere inside them.
	for key in _desired:
		if not _nodes.has(key):
			var k: Vector3i = key
			while k.x > 0:
				k = _parent(k)
				blocked[k] = true
	var kept := {}
	var spare_roots: Array[Vector3i] = []
	for key in _nodes.keys():
		if _desired.has(key):
			_active.erase(key)
			continue
		if key.x == 0 and _base.has(key):
			spare_roots.append(key)
			continue
		var keep := false
		if blocked.has(key):
			keep = true # Splitting: its smaller cells are not all ready.
		else:
			var k: Vector3i = key
			while k.x > 0:
				k = _parent(k)
				if _desired.has(k):
					keep = not _nodes.has(k) # Merging: the bigger cell is not ready.
					break
		if keep:
			kept[key] = true # Stays as it is: shown, or hidden under an older cell that is also kept.
		else:
			_retire(key)

	# Find wanted cells that nothing is standing in for, and switch on the big cell under them.
	if not spare_roots.is_empty():
		var below := {} # Cells that have an old, shown cell somewhere inside them.
		for key in kept:
			if _nodes[key].visible:
				var k: Vector3i = key
				while k.x > 0:
					k = _parent(k)
					below[k] = true
		var holes := {}
		for key in _desired:
			if _nodes.has(key) or key.x == 0 or below.has(key):
				continue
			var covered := false
			var k: Vector3i = key
			while k.x > 1:
				k = _parent(k)
				if _nodes.has(k) and _nodes[k].visible:
					covered = true
					break
			if not covered:
				while k.x > 0:
					k = _parent(k)
				holes[k] = true
		for root in spare_roots:
			var cell: MeshInstance3D = _nodes[root]
			if _active.has(root):
				if blocked.has(root):
					kept[root] = true
				else:
					_active.erase(root)
					cell.visible = false
			elif holes.has(root):
				_active[root] = true
				kept[root] = true
				cell.visible = true
				for key in kept: # Hide older cells inside it so nothing draws twice.
					if key.x > 0 and _root_of(key) == root:
						_nodes[key].visible = false
			else:
				cell.visible = false

	for key in _desired:
		if _nodes.has(key):
			var show := true
			var k: Vector3i = key
			while k.x > 0:
				k = _parent(k)
				if kept.has(k) and _nodes[k].visible:
					show = false
					break
			_nodes[key].visible = show
	_start_fresh_fades()


## Starts the fade-in of a cell's new trees the first time it is shown.
func _start_fresh_fades() -> void:
	for key in _nodes:
		var cell: MeshInstance3D = _nodes[key]
		if cell.visible and cell.has_meta("fresh_rank"):
			var rank: float = cell.get_meta("fresh_rank")
			cell.remove_meta("fresh_rank")
			for child in cell.get_children():
				if child is MultiMeshInstance3D:
					child.set_instance_shader_parameter("fresh_rank", rank)
					child.set_instance_shader_parameter("fresh_time", _clock)


static func _root_of(key: Vector3i) -> Vector3i:
	var k := key
	while k.x > 0:
		k = _parent(k)
	return k


# ---------------------------------------------------------------- building cells

func _start_jobs() -> void:
	if not use_threads:
		# No threads: build here, most urgent first, until this frame's time budget is spent.
		var start := Time.get_ticks_usec()
		while not _queue.is_empty():
			var key: Vector3i = _queue.pop_back()
			_running[key] = -1
			_build(key)
			if float(Time.get_ticks_usec() - start) >= main_thread_budget_ms * 1000.0:
				break
		return
	var limit := max_jobs if max_jobs > 0 else clampi(OS.get_processor_count() - 2, 1, 6)
	while _running.size() < limit and not _queue.is_empty():
		var key: Vector3i = _queue.pop_back()
		_running[key] = WorkerThreadPool.add_task(_build.bind(key), false, "NoiseTerrain cell")


func _collect() -> void:
	_mutex.lock()
	var take := mini(cells_per_frame, _results.size())
	var ready := _results.slice(0, take)
	_results = _results.slice(take)
	_mutex.unlock()
	if ready.is_empty():
		return
	for r in ready:
		var key: Vector3i = r.key
		if _running[key] >= 0:
			WorkerThreadPool.wait_for_task_completion(_running[key])
		_running.erase(key)
		_batch_done += 1
		_build_count += 1
		if _nodes.has(key) or _cache.has(key):
			continue
		_add_cell(r)
		if not (_desired.has(key) or _base.has(key)):
			_retire(key) # Arrived after it stopped being wanted: keep it for later.
	_resolve()
	_trim_cache(_select_at.x, _select_at.y, _select_at.z)
	_report()


func _report() -> void:
	progress.emit(_batch_done, _batch_total)
	if _batch_total < 20 and not log_all_batches:
		return
	var tenth := _batch_done * 10 / maxi(_batch_total, 1)
	if tenth != _batch_logged:
		_batch_logged = tenth
		print("[NoiseTerrain] building cells: %d / %d (%d%%), %d on screen" % [
			_batch_done, _batch_total, _batch_done * 100 / maxi(_batch_total, 1), _nodes.size()])
	if _batch_done >= _batch_total:
		print("[NoiseTerrain] batch finished: %d cells in %.2f s" % [
			_batch_total, float(Time.get_ticks_msec() - _batch_start) / 1000.0])


func _add_cell(r: Dictionary) -> void:
	var cell := MeshInstance3D.new()
	cell.mesh = r.mesh
	cell.position = Vector3(r.x - _origin_x, 0.0, r.z - _origin_z)
	cell.visible = false
	if r.tree_count > 0:
		cell.set_meta("fresh_rank", _fresh_rank(r.key))
		# Cards everywhere (the shader hides them up close); models as well in close cells,
		# so the two can dissolve into each other by distance instead of swapping per cell.
		cell.add_child(_tree_instance(r, _tree_card, _tree_card_material, false))
		if r.size <= tree_model_cell_size:
			cell.add_child(_tree_instance(r, _tree_model, null, true)) # Materials are on the mesh.
	# Estimated GPU memory: vertex (position, normal, colour), 16-bit indices, tree instances
	# (cards everywhere, models as well in close cells).
	var trees_bytes: int = r.tree_count * 64 * (2 if r.size <= tree_model_cell_size else 1)
	cell.set_meta("bytes", r.vertex_count * 20 + _indices.size() * 2 + trees_bytes)
	add_child(cell)
	_nodes[r.key] = cell


## Which of a new cell's trees are new compared with what is on screen now: trees ranked at or
## above the returned value. Splitting from a bigger cell: the ones that cell lacked. Merging
## from smaller cells: none (2.0). Nothing there before: all of them (0.0).
func _fresh_rank(key: Vector3i) -> float:
	var k := key
	while k.x > 0:
		k = _parent(k)
		if _nodes.has(k) and _nodes[k].visible:
			return pow(0.25, float(max_lod - _tree_level(k.x))) if k.x >= _tree_top_lod else 0.0
	for other in _nodes:
		if other.x > key.x and _nodes[other].visible:
			var shift: int = other.x - key.x
			if Vector3i(key.x, other.y >> shift, other.z >> shift) == key:
				return 2.0
	return 0.0


func _tree_instance(r: Dictionary, mesh: Mesh, material: Material, shadows: bool) -> MultiMeshInstance3D:
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_custom_data = true
	multi.mesh = mesh
	multi.instance_count = r.tree_count
	multi.buffer = r.tree_buffer
	multi.custom_aabb = r.mesh.custom_aabb
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multi
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


## The tree level a cell holds: its own level plus the boost, at most the finest.
func _tree_level(cell_level: int) -> int:
	return mini(cell_level + tree_detail_boost, max_lod)


## Forest cover from 0 to 1. Used for the ground colour and for placing trees.
static func forest_cover(s: NoiseTerrainSettings, moist: float, h: float, normal_y: float) -> float:
	return smoothstep(0.46, 0.6, moist) * smoothstep(s.sea_level + 2.0, s.sea_level + 10.0, h) \
			* smoothstep(s.tree_line + 150.0, s.tree_line - 150.0, h) * smoothstep(0.74, 0.88, normal_y)


## Runs on a worker thread. Reads settings only; touches nothing in the scene.
func _build(key: Vector3i) -> void:
	if _closing:
		return
	var s := settings
	var size := s.cell_size / float(1 << key.x)
	var n := cell_resolution
	var step := size / float(n)
	var ox := float(key.y) * size
	var oz := float(key.z) * size

	# Heights on a grid one square wider than the cell, so edge normals match the neighbours.
	var gw := n + 3
	var heights := PackedFloat32Array()
	heights.resize(gw * gw)
	for j in gw:
		var wz := oz + float(j - 1) * step
		for i in gw:
			heights[j * gw + i] = s.height(ox + float(i - 1) * step, wz)

	var vw := n + 1
	var main := vw * vw
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	vertices.resize(main + 4 * vw)
	normals.resize(main + 4 * vw)
	colours.resize(main + 4 * vw)
	var low := INF
	var high := -INF
	var sea := s.sea_level
	for j in vw:
		var wz := oz + float(j) * step
		for i in vw:
			var g := (j + 1) * gw + i + 1
			var h := heights[g]
			var normal := Vector3(heights[g - 1] - heights[g + 1], 2.0 * step, heights[g - gw] - heights[g + gw]).normalized()
			var moist := s.moisture(ox + float(i) * step, wz)
			var forest := forest_cover(s, moist, h, normal.y)
			var v := j * vw + i
			vertices[v] = Vector3(float(i) * step, h, float(j) * step)
			normals[v] = normal
			colours[v] = Color(moist, forest, 0.0, 1.0)
			low = minf(low, h)
			high = maxf(high, h)

	# Skirts: a strip hanging down from each edge hides the cracks between cells of different detail.
	var skirt := size * 0.06 + 2.0
	for k in vw:
		var edge := [k, n * vw + k, k * vw, k * vw + n]
		for e in 4:
			var src: int = edge[e]
			var dst := main + e * vw + k
			vertices[dst] = vertices[src] - Vector3(0.0, skirt, 0.0)
			normals[dst] = normals[src]
			colours[dst] = colours[src]

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = _indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, terrain_material)
	mesh.custom_aabb = AABB(Vector3(0.0, low - skirt, 0.0), Vector3(size, high - low + skirt + tree_height * 4.0, size))

	var tree_buffer := PackedFloat32Array()
	var tree_count := 0
	if trees and key.x >= _tree_top_lod:
		# Trees live on one fixed world grid at the finest level. Each square of this cell's
		# tree grid stands for 4^n finest squares and picks one of them (by hash, one level at
		# a time), so a coarse cell holds exactly a subset of the trees its smaller cells hold:
		# same spot, size, turn and tint. Nothing moves when cells split or merge.
		# With tree_detail_boost a cell holds the trees of a finer level (more squares).
		var tree_level := _tree_level(key.x)
		var t := tree_grid << (tree_level - key.x)
		var fine_size := s.cell_size / float(1 << max_lod) / float(tree_grid)
		var square := s.cell_size / float(1 << tree_level) / float(tree_grid)
		tree_buffer.resize(t * t * 16)
		for tj in t:
			for ti in t:
				var gx := key.y * t + ti
				var gz := key.z * t + tj
				# Quick skip: moisture barely changes across one square, so a square well
				# below the forest threshold at its centre has no trees anywhere in it.
				if s.moisture((float(gx) + 0.5) * square, (float(gz) + 0.5) * square) < 0.43:
					continue
				var fx := gx
				var fz := gz
				for level in range(tree_level, max_lod):
					var q := int(_hash(fx, fz, 1000 + level) * 4.0)
					fx = fx * 2 + (q & 1)
					fz = fz * 2 + (q >> 1)
				var wx := (float(fx) + _hash(fx, fz, 11)) * fine_size
				var wz := (float(fz) + _hash(fx, fz, 12)) * fine_size
				# Forest test on the true ground, not this cell's mesh, so every level agrees.
				var moist := s.moisture(wx, wz)
				if moist <= 0.46:
					continue
				var ht := s.height(wx, wz)
				# Slope across about 15 m, like a mid-detail cell sees it: small bumps don't
				# stop trees, and it matches the forest tint on the ground better.
				var slope_x := s.height(wx + 15.0, wz) - ht
				var slope_z := s.height(wx, wz + 15.0) - ht
				var cover := forest_cover(s, moist, ht, 15.0 / sqrt(slope_x * slope_x + slope_z * slope_z + 225.0))
				if cover <= 0.02 or _hash(fx, fz, 13) > pow(cover, 0.6):
					continue
				# Rank: the coarsest level that still holds this tree sets its range, so the
				# distance thinning drops trees in the same order the coarse cells do.
				var c := tree_level
				var ux := gx
				var uz := gz
				while c > _tree_top_level:
					var px := ux >> 1
					var pz := uz >> 1
					if int(_hash(px, pz, 1000 + c - 1) * 4.0) != ((ux & 1) | ((uz & 1) << 1)):
						break
					c -= 1
					ux = px
					uz = pz
				var rank_top := pow(0.25, float(max_lod - c))
				var rank_bottom := 0.0 if c == _tree_top_level else rank_top * 0.25
				var rank := lerpf(rank_bottom, rank_top, _hash(fx, fz, 14))
				# Sit on this cell's drawn ground.
				var u := (wx - ox) / step
				var w := (wz - oz) / step
				var i0 := clampi(int(u), 0, n - 1)
				var j0 := clampi(int(w), 0, n - 1)
				var g := (j0 + 1) * gw + i0 + 1
				var tx := u - float(i0)
				var tz := w - float(j0)
				var h := lerpf(lerpf(heights[g], heights[g + 1], tx), lerpf(heights[g + gw], heights[g + gw + 1], tx), tz)
				var scale := tree_height * (0.7 + 0.6 * _hash(fx, fz, 15))
				var angle := TAU * _hash(fx, fz, 16)
				var cs := cos(angle) * scale
				var sn := sin(angle) * scale
				var b := tree_count * 16
				tree_buffer[b] = cs
				tree_buffer[b + 1] = 0.0
				tree_buffer[b + 2] = sn
				tree_buffer[b + 3] = wx - ox
				tree_buffer[b + 4] = 0.0
				tree_buffer[b + 5] = scale
				tree_buffer[b + 6] = 0.0
				tree_buffer[b + 7] = h - 0.3
				tree_buffer[b + 8] = -sn
				tree_buffer[b + 9] = 0.0
				tree_buffer[b + 10] = cs
				tree_buffer[b + 11] = wz - oz
				tree_buffer[b + 12] = rank
				tree_buffer[b + 13] = _hash(fx, fz, 17) # Tint.
				tree_buffer[b + 14] = 0.0
				tree_buffer[b + 15] = 0.0
				tree_count += 1
		tree_buffer.resize(tree_count * 16)

	var result := {
		"key": key, "mesh": mesh, "x": ox, "z": oz, "size": size,
		"tree_buffer": tree_buffer, "tree_count": tree_count, "vertex_count": vertices.size(),
	}
	_mutex.lock()
	_results.append(result)
	_mutex.unlock()


static func _hash(x: int, y: int, salt: int) -> float:
	var h := (x * 374761393 + y * 668265263 + salt * 1442695041) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	h = h ^ (h >> 16)
	return float(h & 0xFFFFFF) / 16777216.0


# ---------------------------------------------------------------- one-off setup

static func _make_indices(n: int) -> PackedInt32Array:
	var vw := n + 1
	var main := vw * vw
	var out := PackedInt32Array()
	for j in n:
		for i in n:
			var a := j * vw + i
			out.append_array([a, a + 1, a + vw, a + 1, a + vw + 1, a + vw])
	# Skirt strips, drawn both ways round so they show from either side.
	for e in 4:
		for k in n:
			var a: int
			var b: int
			match e:
				0:
					a = k
					b = k + 1
				1:
					a = n * vw + k
					b = n * vw + k + 1
				2:
					a = k * vw
					b = (k + 1) * vw
				_:
					a = k * vw + n
					b = (k + 1) * vw + n
			var c := main + e * vw + k
			var d := c + 1
			out.append_array([a, b, c, b, d, c, a, c, b, b, c, d])
	return out


func _make_materials() -> void:
	var grey := NoiseTexture2D.new()
	grey.width = 256
	grey.height = 256
	grey.seamless = true
	grey.generate_mipmaps = true
	var grey_noise := FastNoiseLite.new()
	grey_noise.frequency = 0.03
	grey_noise.fractal_octaves = 4
	grey.noise = grey_noise
	var bumps: NoiseTexture2D = grey.duplicate()
	bumps.as_normal_map = true
	bumps.bump_strength = 6.0
	if terrain_material == null:
		terrain_material = ShaderMaterial.new()
		terrain_material.shader = load(_SHADERS + "terrain.gdshader")
	terrain_material.set_shader_parameter("detail_noise", grey)
	terrain_material.set_shader_parameter("detail_normal", bumps)
	terrain_material.set_shader_parameter("sea_level", settings.sea_level)
	terrain_material.set_shader_parameter("snow_line", settings.snow_line)
	if water and water_material == null:
		water_material = ShaderMaterial.new()
		water_material.shader = load(_SHADERS + "water.gdshader")
		water_material.set_shader_parameter("wave_normal", bumps)
	_tree_card_material = ShaderMaterial.new()
	_tree_card_material.shader = load(_SHADERS + "tree_billboard.gdshader")
	_tree_materials = [_tree_card_material]
	_push_origin()


## Works out the distances the tree shaders fade over, from the cell sizes, so each change
## happens before the cell holding those trees can swap. A cell of size S only ever shows
## things at least S x lod_distance away, which gives safe limits.
func _setup_tree_fades() -> void:
	var smallest := settings.cell_size / float(1 << max_lod)
	_tree_top_lod = 0
	while _tree_top_lod < max_lod and settings.cell_size / float(1 << _tree_top_lod) > tree_max_cell_size:
		_tree_top_lod += 1
	_tree_top_level = _tree_level(_tree_top_lod)
	var tree_top := settings.cell_size / float(1 << _tree_top_lod)
	var model_limit := 2.0 * minf(tree_model_cell_size, tree_top) * lod_distance
	var far_limit := 2.0 * tree_top * lod_distance
	_tree_fade = {
		# 0.8 leaves room for the cell picker only re-checking every so often, and for build time.
		"density": smallest * lod_distance * 0.85 * float(1 << tree_detail_boost),
		"model_start": model_limit * 0.55,
		"model_end": model_limit * 0.75,
		"far_start": far_limit * 0.72,
		"far_end": far_limit * 0.9,
	}
	if tree_model_cell_size >= tree_top: # Models all the way out: no cards needed.
		_tree_fade.model_start = far_limit * 10.0
		_tree_fade.model_end = far_limit * 11.0
	elif tree_model_cell_size < smallest: # No cell is small enough for models: cards everywhere.
		_tree_fade.model_start = -2.0
		_tree_fade.model_end = -1.0
	for m in _fade_materials():
		m.set_shader_parameter("forest_floor_color", forest_floor_color)
		m.set_shader_parameter("density_distance", _tree_fade.density)
		m.set_shader_parameter("model_fade_start", _tree_fade.model_start)
		m.set_shader_parameter("model_fade_end", _tree_fade.model_end)
		m.set_shader_parameter("far_fade_start", _tree_fade.far_start)
		m.set_shader_parameter("far_fade_end", _tree_fade.far_end)
		m.set_shader_parameter("grow_rate", tree_grow_rate)
	print("[NoiseTerrain] tree fades: all trees within %.0f m, models to cards %.0f-%.0f m, gone by %.0f m (detail boost %d)" % [
		_tree_fade.density, _tree_fade.model_start, _tree_fade.model_end, _tree_fade.far_end, tree_detail_boost])


func _make_water() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(160000.0, 160000.0)
	_water_node = MeshInstance3D.new()
	_water_node.mesh = plane
	_water_node.material_override = water_material
	_water_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_water_node.position.y = settings.sea_level
	add_child(_water_node)


## A small conifer, 1 unit tall: a trunk and two cones, coloured per vertex.
func _fade_materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = _tree_materials.duplicate()
	out.append(terrain_material)
	return out


## A copy of the tree mesh where every surface draws with the fading tree shader, filled in
## from that surface's own material.
func _prepare_tree_model(source: Mesh) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for i in source.get_surface_count():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, source.surface_get_arrays(i))
		var original := source.surface_get_material(i)
		if original == null and source is PrimitiveMesh:
			original = (source as PrimitiveMesh).material
		var material := _tree_surface_material(original, i)
		mesh.surface_set_material(i, material)
		if not _tree_materials.has(material):
			_tree_materials.append(material)
	print("[NoiseTerrain] tree model: %d surface(s), %s" % [mesh.get_surface_count(), "built-in conifer" if tree_mesh == null else "your tree_mesh"])
	return mesh


func _tree_surface_material(original: Material, index: int) -> ShaderMaterial:
	# Your own shader can be used as it is if it includes tree_fade.gdshaderinc.
	if original is ShaderMaterial and original.shader != null and original.shader.code.contains("tree_fade.gdshaderinc"):
		return original
	var m := ShaderMaterial.new()
	m.shader = load(_SHADERS + "tree.gdshader")
	if original is BaseMaterial3D:
		var b := original as BaseMaterial3D
		m.set_shader_parameter("albedo_color", b.albedo_color)
		if b.albedo_texture != null:
			m.set_shader_parameter("albedo_texture", b.albedo_texture)
		m.set_shader_parameter("use_vertex_color", b.vertex_color_use_as_albedo)
		m.set_shader_parameter("roughness_value", b.roughness)
		m.set_shader_parameter("uv_scale", Vector2(b.uv1_scale.x, b.uv1_scale.y))
		m.set_shader_parameter("uv_offset", Vector2(b.uv1_offset.x, b.uv1_offset.y))
		if b.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			m.set_shader_parameter("alpha_scissor", b.alpha_scissor_threshold)
		elif b.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			m.set_shader_parameter("alpha_scissor", 0.5) # Blended trees cannot dissolve; cut at half.
	elif original != null:
		push_warning("NoiseTerrain: tree_mesh surface %d uses a %s without tree_fade.gdshaderinc; drawn with the tree shader using vertex colours instead." % [index, original.get_class()])
	return m


## Renders a side view of the tree (with its own materials, flat white light, so the image
## holds plain colours) into the card texture, so distant cards look like the model.
func _bake_tree_card(source: Mesh) -> void:
	var aabb := source.get_aabb()
	var top := maxf(aabb.end.y, 0.05)
	var half := maxf(maxf(absf(aabb.position.x), absf(aabb.end.x)), maxf(absf(aabb.position.z), absf(aabb.end.z)))
	half = maxf(half, 0.02)
	_tree_card_material.set_shader_parameter("width", half * 2.0)
	_tree_card_material.set_shader_parameter("card_height", top)
	if not bake_tree_cards or DisplayServer.get_name() == "headless":
		print("[NoiseTerrain] tree cards: drawn conifer shape (no bake)")
		return
	print("[NoiseTerrain] tree cards: baking from the tree model...")
	var height_px := 256
	var width_px := clampi(roundi(height_px * half * 2.0 / top), 16, 512)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(width_px, height_px)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var world := WorldEnvironment.new()
	world.environment = env
	viewport.add_child(world)
	var model := MeshInstance3D.new()
	model.mesh = source
	viewport.add_child(model)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.size = top
	camera.near = 0.01
	camera.far = 20.0
	camera.position = Vector3(0.0, top * 0.5, 5.0)
	viewport.add_child(camera)
	camera.current = true
	add_child(viewport)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	viewport.queue_free()
	if image == null or image.is_empty():
		print("[NoiseTerrain] tree cards: bake failed, using the drawn conifer shape")
		return
	image.convert(Image.FORMAT_RGBA8)
	# Fill the clear pixels with the tree's average colour, so mipmaps don't darken the edges.
	var sum := Color(0, 0, 0, 0)
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			var c := image.get_pixel(x, y)
			if c.a > 0.5:
				sum += c
				count += 1
	if count < 10:
		print("[NoiseTerrain] tree cards: the bake came out empty, using the drawn conifer shape")
		return
	var average := sum / float(count)
	for y in image.get_height():
		for x in image.get_width():
			var c := image.get_pixel(x, y)
			if c.a <= 0.5:
				image.set_pixel(x, y, Color(average.r, average.g, average.b, 0.0))
	image.generate_mipmaps()
	_tree_card_material.set_shader_parameter("card_texture", ImageTexture.create_from_image(image))
	_tree_card_material.set_shader_parameter("use_card_texture", true)
	print("[NoiseTerrain] tree cards: baked %dx%d from the tree model" % [width_px, height_px])


static func _make_tree_model() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_cone(st, 0.0, 0.3, 0.035, 0.03, 5, Color(0.2, 0.13, 0.08))
	_cone(st, 0.16, 0.72, 0.27, 0.0, 7, Color(0.08, 0.2, 0.05))
	_cone(st, 0.45, 1.0, 0.19, 0.0, 7, Color(0.13, 0.27, 0.07))
	st.generate_normals()
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.9
	st.set_material(material)
	return st.commit()


static func _cone(st: SurfaceTool, y0: float, y1: float, r0: float, r1: float, sides: int, colour: Color) -> void:
	st.set_color(colour)
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var p0 := Vector3(cos(a0) * r0, y0, sin(a0) * r0)
		var p1 := Vector3(cos(a1) * r0, y0, sin(a1) * r0)
		var q0 := Vector3(cos(a0) * r1, y1, sin(a0) * r1)
		var q1 := Vector3(cos(a1) * r1, y1, sin(a1) * r1)
		st.add_vertex(p0)
		st.add_vertex(q0)
		st.add_vertex(p1)
		if r1 > 0.0:
			st.add_vertex(p1)
			st.add_vertex(q0)
			st.add_vertex(q1)


## One flat card, 1 unit tall; the shader turns it to the camera and cuts out the tree shape.
static func _make_tree_card() -> Mesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-0.3, 1, 0), Vector3(0.3, 1, 0), Vector3(-0.3, 0, 0), Vector3(0.3, 0, 0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 1, 3, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
