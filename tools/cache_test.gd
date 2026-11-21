extends SceneTree
## Checks the cell cache and the merge margin:
##  1. Round trip: fly 1 km away and back; how many cells on screen at the start are the very
##     same cells as before (kept and reused, not rebuilt), and how many builds the return took.
##  2. Far trip: fly 5 km away; kept cells beyond their keep distance must be gone, and the
##     kept memory must stay under the limit (run with a small limit).
##  3. Hover: swing back and forth 30 m either side of a few spots, and 55 m either side of a
##     256 m cell's split distance; changes to the cells on screen (flicker).
##  4. Floating origin: after shifts, every live and kept cell sits where its key says.
##  5. All along: no kept cell is ever visible.
## Run: godot --headless --path . -s tools/cache_test.gd [-- --cache-mb=20]

var terrain: NoiseTerrain
var target: Node3D
var cached_visible := 0
var worst_mb := 0.0


func _init() -> void:
	_run()


func _run() -> void:
	terrain = NoiseTerrain.new()
	terrain.settings = load("res://demo/terrain_settings.tres")
	var has_cache := "cache_memory_mb" in terrain
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--cache-mb=") and has_cache:
			terrain.set("cache_memory_mb", float(a.trim_prefix("--cache-mb=")))
	target = Node3D.new()
	terrain.target = target
	var start := Vector3(600.0, 0.0, 1500.0)
	target.position = _at(start)
	root.add_child(target)
	root.add_child(terrain)
	await process_frame
	await _settle()
	print("cache: %s" % ("yes, limit %.0f MB, keep factor %.1f, merge margin %.2f" % [terrain.get("cache_memory_mb"), terrain.get("keep_distance_factor"), terrain.get("merge_margin")] if has_cache else "no (old version)"))

	# 1. Round trip.
	var before := _visible_ids()
	await _fly_to(start + Vector3(1000.0, 0.0, 0.0))
	var builds_at_far := _builds()
	await _fly_to(start)
	var after := _visible_ids()
	var same := 0
	for key in after:
		if before.get(key, -1) == after[key]:
			same += 1
	print("round trip 1 km: %d of %d cells on screen at the start are the same cells as before; builds on the way back: %s" % [
		same, after.size(), str(_builds() - builds_at_far) if has_cache else "n/a"])

	# 2. Far trip.
	await _fly_to(start + Vector3(5000.0, 0.0, 0.0))
	var too_far := 0
	if has_cache:
		var cache: Dictionary = terrain.get("_cache")
		var at: Vector3 = terrain.get("_select_at")
		for key in cache:
			var size: float = terrain.settings.cell_size / float(1 << key.x)
			var limit: float = 2.0 * size * terrain.lod_distance * terrain.get("merge_margin") * terrain.get("keep_distance_factor")
			if terrain.call("_cell_distance", key, at.x, at.y, at.z) > limit:
				too_far += 1
		print("far trip 5 km: %d kept cells (%.1f MB), %d beyond their keep distance; most kept memory seen %.1f MB" % [
			cache.size(), terrain.get_cache_mb(), too_far, worst_mb])

	# 3. Hover near a few spots.
	var flips := 0
	var spots := [Vector3(2000, 0, 300), Vector3(-1700, 0, 2600), Vector3(4300, 0, -900), Vector3(900, 0, -3100)]
	for spot in spots:
		await _fly_to(spot)
		var ends := []
		for swing in 6:
			var side: float = 30.0 if swing % 2 == 0 else -30.0
			await _fly_to(spot + Vector3(side, 0.0, 0.0), 6.0)
			ends.append(_visible_keys())
		for k in range(3, ends.size()): # From the second full swing on (the first may settle a split).
			if ends[k] != ends[k - 2]:
				flips += 1
	print("hover +-30 m at %d spots, 6 swings each: %d changes to the cells on screen after the first full swing" % [spots.size(), flips])
	# 3b. Hover exactly on a split boundary: a 256 m cell's split distance, crossed every swing.
	var size4: float = terrain.settings.cell_size / float(1 << 4)
	var kx := floori(start.x / size4)
	var kz := floori(start.z / size4)
	var edge_x := float(kx + 1) * size4
	var mid_z := (float(kz) + 0.5) * size4
	var h := terrain.settings.height(edge_x + 400.0, mid_z)
	var alt := (maxf(h, 0.0) + 140.0 - h) * 0.6
	var reach := size4 * terrain.lod_distance
	var boundary := Vector3(edge_x + sqrt(maxf(reach * reach - alt * alt, 0.0)), 0.0, mid_z)
	await _fly_to(boundary)
	var cell_split := []
	for swing in 8:
		var side: float = 55.0 if swing % 2 == 0 else -55.0
		await _fly_to(boundary + Vector3(side, 0.0, 0.0), 6.0)
		var child := Vector3i(5, kx * 2, kz * 2)
		var at := terrain.to_world(target.position)
		var alt_now := maxf(target.position.y - terrain.get_height(target.position.x, target.position.z), 0.0) * 0.6
		var ddx := at.x - clampf(at.x, float(kx) * size4, float(kx + 1) * size4)
		var ddz := at.z - clampf(at.z, float(kz) * size4, float(kz + 1) * size4)
		var dist := sqrt(ddx * ddx + ddz * ddz + alt_now * alt_now)
		var state := "split" if terrain._nodes.has(child) and terrain._nodes[child].visible else ("cell" if terrain._nodes.has(Vector3i(4, kx, kz)) and terrain._nodes[Vector3i(4, kx, kz)].visible else "parent")
		cell_split.append("%s@%.0f" % [state, dist])
	var changes := 0
	for k in range(1, cell_split.size()):
		if cell_split[k].get_slice("@", 0) != cell_split[k - 1].get_slice("@", 0):
			changes += 1
	print("hover +-55 m across a 256 m cell's split distance, 8 swings: the cell changed detail %d times (state@distance each swing: %s)" % [changes, str(cell_split)])

	# 4. Floating origin: go past the shift distance and back.
	await _fly_to(start + Vector3(9000.0, 0.0, 0.0), 60.0)
	await _fly_to(start, 60.0)
	var misplaced := 0
	var all := {}
	all.merge(terrain._nodes)
	if has_cache:
		all.merge(terrain.get("_cache"))
	for key in all:
		var size: float = terrain.settings.cell_size / float(1 << key.x)
		var world: Vector3 = terrain.to_world(all[key].position)
		if absf(world.x - float(key.y) * size) > 0.01 or absf(world.z - float(key.z) * size) > 0.01:
			misplaced += 1
	print("floating origin: origin now %s, %d cells (live and kept) out of place" % [terrain.get_origin(), misplaced])
	print("kept cells seen visible on any frame: %d" % cached_visible)
	quit()


func _at(p: Vector3) -> Vector3:
	var o := terrain.get_origin() if terrain != null and terrain.is_inside_tree() else Vector2.ZERO
	var scene := Vector3(p.x - o.x, 0.0, p.z - o.y)
	scene.y = maxf(terrain.settings.height(p.x, p.z) if terrain.is_inside_tree() else 0.0, 0.0) + 140.0
	return scene


## Fly in a straight line (world coordinates) at speed metres per frame, then wait until built.
func _fly_to(world: Vector3, speed := 2.0) -> void:
	var here := terrain.to_world(target.position)
	var flat := Vector3(world.x - here.x, 0.0, world.z - here.z)
	var steps := maxi(int(flat.length() / speed), 1)
	for i in steps:
		var p := here + flat * float(i + 1) / float(steps)
		target.position = _at(p)
		await create_timer(1.0 / 60.0).timeout
		_watch()
	await _settle()


func _settle() -> void:
	for i in 3:
		await process_frame
	while terrain.is_loading():
		await process_frame
		_watch()
	for i in 3:
		await process_frame
		_watch()


func _watch() -> void:
	if "_cache" in terrain:
		var cache: Dictionary = terrain.get("_cache")
		for key in cache:
			if cache[key].visible:
				cached_visible += 1
		worst_mb = maxf(worst_mb, terrain.get_cache_mb())


func _builds() -> int:
	return terrain.get_build_count() if terrain.has_method("get_build_count") else 0


func _visible_ids() -> Dictionary:
	var out := {}
	for key in terrain._nodes:
		if terrain._nodes[key].visible:
			out[key] = terrain._nodes[key].get_instance_id()
	return out


func _visible_keys() -> Array:
	var out := []
	for key in terrain._nodes:
		if terrain._nodes[key].visible:
			out.append(key)
	out.sort()
	return out
