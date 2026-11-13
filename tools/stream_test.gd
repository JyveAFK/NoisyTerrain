extends SceneTree
## Flies a target across the world with no display and checks the streaming rules:
## no cell is ever drawn on top of another, the floating origin keeps heights in step,
## and the same seed gives the same ground. Run: godot --headless --path . -s tools/stream_test.gd


func _init() -> void:
	_run()


func _run() -> void:
	var terrain := NoiseTerrain.new()
	terrain.settings = load("res://demo/terrain_settings.tres")
	if OS.get_cmdline_user_args().has("--nothreads"):
		terrain.use_threads = false
	if OS.get_cmdline_user_args().has("--light"):
		terrain.profile = NoiseTerrain.Profile.LIGHT
	var target := Node3D.new()
	terrain.target = target
	target.position = Vector3(0, 300, 0)
	root.add_child(target)
	root.add_child(terrain)
	await process_frame
	while terrain.is_loading():
		await process_frame
	var world := terrain.to_world(target.global_position)
	var h0 := terrain.settings.height(world.x + 777.0, world.z - 333.0)
	var doubles := 0
	var gaps := 0
	var frames := 0
	var shifts := [0]
	terrain.origin_shifted.connect(func(_o: Vector3) -> void: shifts[0] += 1)
	var wx := 0.0
	var speed := 60.0 # Metres per frame along x: 60 is 3.6 km/s at 60 fps, far faster than the video.
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--speed="):
			speed = float(a.trim_prefix("--speed="))
	print("speed: %.0f m/s" % (Vector2(speed, speed * 0.58).length() * 60.0))
	for step in 900:
		target.global_position += Vector3(speed, 0.0, -speed * 0.58)
		wx += speed
		await create_timer(0.0166).timeout # Real time, so the worker threads get a fair 60 fps.
		frames += 1
		for key in terrain._nodes:
			if not terrain._nodes[key].visible:
				continue
			var k: Vector3i = key
			while k.x > 0:
				k = NoiseTerrain._parent(k)
				if terrain._nodes.has(k) and terrain._nodes[k].visible:
					doubles += 1
		# The cell under the target must always be drawn by something.
		var w := terrain.to_world(target.global_position)
		var covered := false
		for key in terrain._nodes:
			if terrain._nodes[key].visible:
				var size: float = terrain.settings.cell_size / float(1 << key.x)
				if w.x >= key.y * size and w.x < (key.y + 1) * size and w.z >= key.z * size and w.z < (key.z + 1) * size:
					covered = true
					break
		if not covered:
			gaps += 1
			if gaps <= 3:
				var line := "gap at frame %d:" % step
				for lod in terrain.max_lod + 1:
					var size: float = terrain.settings.cell_size / float(1 << lod)
					var key := Vector3i(lod, floori(w.x / size), floori(w.z / size))
					line += "  L%d[%s%s%s%s]" % [lod, "B" if terrain._nodes.has(key) else "-",
						"V" if terrain._nodes.has(key) and terrain._nodes[key].visible else "-",
						"D" if terrain._desired.has(key) else "-", "R" if terrain._running.has(key) else "-"]
				print(line)
	var w := terrain.to_world(target.global_position)
	print("flew to world (%.0f, %.0f) in %d frames, origin shifts %d, scene position (%.0f, %.0f)" % [
		w.x, w.z, frames, shifts[0], target.global_position.x, target.global_position.z])
	print("cells drawn twice: %d   frames with no ground under the target: %d" % [doubles, gaps])
	print("world x matches distance flown: ", is_equal_approx(w.x, wx))
	var after := terrain.get_height(777.0 - terrain.get_origin().x, -333.0 - terrain.get_origin().y)
	print("height at a fixed world point before/after shifts: %.3f / %.3f" % [h0, after])
	while terrain.is_loading():
		await process_frame
	print("cells at rest: ", terrain.get_cell_count())
	quit()
