extends SceneTree
## Checks what is shown while cells build (run on old and new versions):
##  - stand-ins: visible cells closer than their split distance although all four smaller
##    cells are already built (on screen or kept) - a coarse cell shown for no reason,
##  - cover: random points across the view are under at most one visible cell, and under
##    exactly one wherever any built cell covers them,
##  - stationary: once the target stops, building and the visible set settle and stay put,
##  - accounting: the cache's memory total matches the cells in it,
##  - cost: the slowest visibility update during the first load.
## Run: godot --headless --path . -s tools/standin_test.gd [-- --cache-mb=10] [--lag]
## --lag: no threads, about one cell built per frame (deterministic build lag).

var terrain: NoiseTerrain


func _init() -> void:
	_run()


func _run() -> void:
	terrain = NoiseTerrain.new()
	terrain.settings = load("res://demo/terrain_settings.tres")
	if OS.get_cmdline_user_args().has("--lag"):
		# Deterministic build lag: no threads, about one cell built per frame.
		terrain.use_threads = false
		terrain.main_thread_budget_ms = 1.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--cache-mb=") and "cache_memory_mb" in terrain:
			terrain.set("cache_memory_mb", float(a.trim_prefix("--cache-mb=")))
	var target := Node3D.new()
	target.position = Vector3(600.0, 140.0, 1500.0)
	terrain.target = target
	root.add_child(target)
	root.add_child(terrain)
	await process_frame
	var worst_resolve := 0.0
	while terrain.is_loading():
		await process_frame
		var t0 := Time.get_ticks_usec()
		terrain._resolve()
		worst_resolve = maxf(worst_resolve, (Time.get_ticks_usec() - t0) / 1000.0)
	print("slowest visibility update during the first load: %.2f ms" % worst_resolve)

	var standin_frames := 0
	var standin_cells := 0
	var overlaps := 0
	var gaps := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for f in 600:
		if f == 300:
			print("at the turn: %d cells waiting, %d built so far" % [terrain.get_pending_count(), terrain.get_build_count() if terrain.has_method("get_build_count") else -1])
		var dir := 1.0 if f < 300 else -1.0
		target.position += Vector3(1.2, 0.0, -4.0) * dir
		target.position.y = maxf(terrain.get_height(target.position.x, target.position.z), 0.0) + 140.0
		await create_timer(1.0 / 60.0).timeout
		var at := terrain.to_world(target.position)
		# Judge against the position the terrain last chose cells for (it re-chooses every ~45 m).
		var chosen: Vector3 = terrain._last_select
		var at_chosen := terrain.to_world(chosen)
		var alt := maxf(chosen.y - terrain.get_height(chosen.x, chosen.z), 0.0) * 0.6
		var count := 0
		for key in terrain._nodes:
			if not terrain._nodes[key].visible or key.x >= terrain.max_lod:
				continue
			var size: float = terrain.settings.cell_size / float(1 << key.x)
			if _distance(key, at_chosen, alt) >= size * terrain.lod_distance:
				continue
			var all_built := true
			for j in 2:
				for i in 2:
					if not _built(Vector3i(key.x + 1, key.y * 2 + i, key.z * 2 + j)):
						all_built = false
			if all_built:
				count += 1
		standin_cells += count
		if count > 0:
			standin_frames += 1
		# Cover check at random points within 6 km.
		for n in 60:
			var p := Vector2(at.x, at.z) + Vector2(rng.randf_range(-6000, 6000), rng.randf_range(-6000, 6000))
			var shown := 0
			var any_built := false
			for level in terrain.max_lod + 1:
				var size: float = terrain.settings.cell_size / float(1 << level)
				var key := Vector3i(level, floori(p.x / size), floori(p.y / size))
				if terrain._nodes.has(key) and terrain._nodes[key].visible:
					shown += 1
				if _built(key):
					any_built = true
			if shown > 1:
				overlaps += 1
			if any_built and shown == 0:
				gaps += 1
	print("flight out and back (240 m/s): frames with needless coarse stand-ins %d (cells %d); points under two visible cells %d; built points with nothing shown %d" % [
		standin_frames, standin_cells, overlaps, gaps])

	# Stationary: stop, settle, then watch for changes.
	while terrain.is_loading():
		await process_frame
	for i in 10:
		await process_frame
	var builds := _builds()
	var shown_before := _visible()
	for i in 180:
		await process_frame
	print("stationary for 180 frames: builds %d, visible set changed: %s" % [_builds() - builds, str(_visible() != shown_before)])

	if "_cache" in terrain:
		var total := 0
		var cache: Dictionary = terrain.get("_cache")
		for key in cache:
			total += int(cache[key].get_meta("bytes", 0))
		print("cache accounting: recorded %d bytes, actual %d bytes (%s); %d kept cells" % [terrain.get("_cache_bytes"), total, "match" if total == terrain.get("_cache_bytes") else "MISMATCH", cache.size()])
	quit()


func _built(key: Vector3i) -> bool:
	if terrain._nodes.has(key):
		return true
	return "_cache" in terrain and terrain.get("_cache").has(key)


func _distance(key: Vector3i, at: Vector3, alt: float) -> float:
	var size: float = terrain.settings.cell_size / float(1 << key.x)
	var dx := at.x - clampf(at.x, float(key.y) * size, float(key.y + 1) * size)
	var dz := at.z - clampf(at.z, float(key.z) * size, float(key.z + 1) * size)
	return sqrt(dx * dx + dz * dz + alt * alt)


func _builds() -> int:
	return terrain.get_build_count() if terrain.has_method("get_build_count") else 0


func _visible() -> Array:
	var out := []
	for key in terrain._nodes:
		if terrain._nodes[key].visible:
			out.append(key)
	out.sort()
	return out
