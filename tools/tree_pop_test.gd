extends SceneTree
## Counts tree "pops" while flying low over forest: a tree whose visibility jumps by more
## than a quarter in one frame (appearing, vanishing, or swapping between model and card).
## Smooth fades change a little each frame and are not counted.
## Run: godot --headless --path . -s tools/tree_pop_test.gd [-- --frames=600 --speed=2 --jobs=0]
## (speed is metres per frame at 60 fps: 2 = 120 m/s, 12 = 720 m/s; jobs 0 = automatic)
## Add --back to fly out for half the frames and back along the same line (reuses kept cells).
## Add --lag for deterministic build lag (no threads, about one cell built per frame).
## Add --fixed-fps 60 before -s so every frame is exactly 1/60 s of game time (time-based
## fade-ins are then judged per real frame; cells get more build time than in real play).

const RANGE := 1500.0 # Only trees this close to the target are checked.
const JUMP := 0.25

var _cache := {} # MultiMeshInstance3D id -> parsed trees


func _init() -> void:
	_run()


func _run() -> void:
	var frames := 600
	var speed := 2.0 # Metres per frame (120 m/s at 60 fps).
	var jobs := 0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--frames="):
			frames = int(a.trim_prefix("--frames="))
		if a.begins_with("--speed="):
			speed = float(a.trim_prefix("--speed="))
		if a.begins_with("--jobs="):
			jobs = int(a.trim_prefix("--jobs="))
	var terrain := NoiseTerrain.new()
	terrain.settings = load("res://demo/terrain_settings.tres")
	terrain.max_jobs = jobs
	if OS.get_cmdline_user_args().has("--lag"):
		# Deterministic build lag: no threads, about one cell built per frame.
		terrain.use_threads = false
		terrain.main_thread_budget_ms = 1.0
	var target := Node3D.new()
	target.position = Vector3(600.0, 140.0, 1500.0)
	terrain.target = target
	root.add_child(target)
	root.add_child(terrain)
	await process_frame
	while terrain.is_loading():
		await process_frame
	for i in 90: # Let start-up fade-ins finish.
		await process_frame
	var fading := terrain.has_method("tree_weights")
	print("tree fades: ", "yes" if fading else "no (old version)")

	var previous := {}
	var centre_now := Vector2.ZERO
	var centre_before := Vector2.ZERO
	var pops := 0
	var pop_frames := 0
	var peak := 0
	var checked := 0
	var appear := 0
	var vanish := 0
	var swap := 0
	var out_and_back := OS.get_cmdline_user_args().has("--back")
	for f in frames:
		if f == frames / 2:
			print("halfway: %d cells waiting, %d built so far" % [terrain.get_pending_count(), terrain.get_build_count() if terrain.has_method("get_build_count") else -1])
		var direction := -1.0 if out_and_back and f >= frames / 2 else 1.0
		target.position += Vector3(speed * 0.3, 0.0, -speed) * direction
		target.position.y = terrain.get_height(target.position.x, target.position.z) + 140.0
		await create_timer(0.0166).timeout
		var now := _visible_trees(terrain, target, fading)
		var w := terrain.to_world(target.position)
		centre_now = Vector2(w.x, w.z)
		var frame_pops := 0
		if f > 0:
			var keys := {}
			for k in now:
				keys[k] = true
			for k in previous:
				keys[k] = true
			for k in keys:
				var a: Vector2 = previous.get(k, Vector2.ZERO)
				var b: Vector2 = now.get(k, Vector2.ZERO)
				# Only judge trees well inside the range on both frames, so crossing its edge is not a pop.
				var p := Vector2(k.x, k.y)
				if p.distance_to(centre_before) > RANGE - 50.0 or p.distance_to(centre_now) > RANGE - 50.0:
					continue
				var jump := maxf(absf(b.x - a.x), absf(b.y - a.y))
				if jump > JUMP:
					frame_pops += 1
					if a.x + a.y < 0.01:
						appear += 1
					elif b.x + b.y < 0.01:
						vanish += 1
					else:
						swap += 1
			checked += keys.size()
		pops += frame_pops
		if frame_pops >= 20:
			print("frame %d: %d pops, %d cells waiting to build" % [f, frame_pops, terrain.get_pending_count()])
		peak = maxi(peak, frame_pops)
		if frame_pops > 0:
			pop_frames += 1
		previous = now
		centre_before = centre_now
		if f % 100 == 0:
			print("frame %d / %d: %d trees in range, %d pops so far" % [f, frames, now.size(), pops])
	print("RESULT: %d pops over %d frames (%d frames had pops, worst frame %d); appear %d, vanish %d, model/card swap %d; %d tree-frames checked" % [
		pops, frames, pop_frames, peak, appear, vanish, swap, checked])
	quit()


## Trees within RANGE of the target -> Vector2(model visibility, card visibility), keyed by
## world position to the nearest metre, so the same tree in two cells counts as one.
func _visible_trees(terrain: NoiseTerrain, target: Node3D, fading: bool) -> Dictionary:
	var out := {}
	var centre := terrain.to_world(target.position)
	var altitude := 0.0
	if fading:
		altitude = terrain.get_lod_altitude()
	for cell in terrain.get_children():
		if not (cell is MeshInstance3D) or not cell.visible or cell.is_queued_for_deletion():
			continue
		var cell_world := terrain.to_world(cell.position)
		for child in cell.get_children():
			if not (child is MultiMeshInstance3D):
				continue
			var trees: Array = _parse(child)
			var fresh_rank := 2.0
			var fresh_age := 1.0
			if fading:
				fresh_rank = float(child.get_instance_shader_parameter("fresh_rank")) if child.get_instance_shader_parameter("fresh_rank") != null else 2.0
				var born = child.get_instance_shader_parameter("fresh_time")
				fresh_age = clampf((terrain.get_tree_clock() - float(born)) / 0.35, 0.0, 1.0) if born != null else 1.0
			var is_model: bool = child.multimesh.mesh != null and child.multimesh.mesh.get_surface_count() > 0 \
					and child.multimesh.mesh.surface_get_array_len(0) > 4
			for t in trees:
				var wx: float = cell_world.x + t[0]
				var wz: float = cell_world.z + t[1]
				var dx := wx - centre.x
				var dz := wz - centre.z
				if dx * dx + dz * dz > RANGE * RANGE:
					continue
				var key := Vector3i(roundi(wx), roundi(wz), 0)
				var w: Vector2 = out.get(key, Vector2.ZERO)
				if fading:
					var weights: Vector2 = terrain.tree_weights(sqrt(dx * dx + dz * dz + altitude * altitude), t[2])
					if t[2] >= fresh_rank:
						weights *= fresh_age
					# Judge what is drawn: dissolved share x drawn area compared with the full tree
					# (see tree_fade_cover and tree_fade_scale in the shader).
					weights = Vector2(_drawn(weights.x), _drawn(weights.y))
					w += Vector2(weights.x, 0.0) if is_model else Vector2(0.0, weights.y)
				else:
					w += Vector2(1.0, 0.0) if is_model else Vector2(0.0, 1.0)
				out[key] = w
	return out


static func _drawn(visibility: float) -> float:
	var size := lerpf(0.7, 1.0, visibility)
	return smoothstep(0.0, 0.6, visibility) * size * size


func _parse(instance: MultiMeshInstance3D) -> Array:
	var id := instance.get_instance_id()
	if _cache.has(id):
		return _cache[id]
	var mm := instance.multimesh
	var stride := 12 + (4 if mm.use_colors else 0) + (4 if mm.use_custom_data else 0)
	var buffer := mm.buffer
	var trees := []
	for i in mm.instance_count:
		var b := i * stride
		var rank := buffer[b + stride - 4] if mm.use_custom_data else 0.0
		trees.append([buffer[b + 3], buffer[b + 11], rank])
	_cache[id] = trees
	return trees
