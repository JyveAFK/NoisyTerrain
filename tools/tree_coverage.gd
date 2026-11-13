extends SceneTree
## Tree coverage (visibility x drawn size^2, summed) in distance rings around a fixed spot,
## at two heights. Use it to compare density settings before and after a change.
## Run: godot --headless --path . -s tools/tree_coverage.gd [-- --grid=32]
func _init() -> void:
	_run()
func _run() -> void:
	var terrain := NoiseTerrain.new()
	terrain.settings = load("res://demo/terrain_settings.tres")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--grid="):
			terrain.tree_grid = int(a.trim_prefix("--grid="))
	var target := Node3D.new()
	target.position = Vector3(600.0, 0.0, 1500.0)
	terrain.target = target
	root.add_child(target)
	root.add_child(terrain)
	await process_frame
	var ground := terrain.get_height(600.0, 1500.0)
	var results := []
	for alt in [60.0, 300.0]:
		target.position.y = ground + alt
		await process_frame
		await process_frame
		while terrain.is_loading():
			await process_frame
		await process_frame
		var fading := terrain.has_method("tree_weights")
		var altitude: float = terrain.call("get_lod_altitude") if fading else maxf(alt, 0.0) * 0.6
		var rings := [0.0, 0.0, 0.0, 0.0, 0.0]
		var edges := [250.0, 500.0, 1000.0, 2000.0, 3500.0]
		var count := 0
		for cell in terrain.get_children():
			if not (cell is MeshInstance3D) or not cell.visible or cell.is_queued_for_deletion():
				continue
			for child in cell.get_children():
				if not (child is MultiMeshInstance3D):
					continue
				var mm: MultiMesh = child.multimesh
				var is_model: bool = mm.mesh.surface_get_array_len(0) > 4
				var stride := 12 + (4 if mm.use_custom_data else 0)
				var buf := mm.buffer
				for i in mm.instance_count:
					var o := i * stride
					var x: float = cell.position.x + buf[o + 3]
					var z: float = cell.position.z + buf[o + 11]
					var scale: float = buf[o + 5]
					var d := Vector2(x - target.position.x, z - target.position.z).length()
					var m := sqrt(d * d + altitude * altitude)
					var w := 1.0
					if fading:
						var ww: Vector2 = terrain.call("tree_weights", m, buf[o + 12])
						w = ww.x if is_model else ww.y
						var thin := ww.x + ww.y
						var fades: Dictionary = terrain.get("_tree_fade")
						var grow: float = terrain.get("tree_grow_rate")
						scale *= (1.0 + grow * log(maxf(m / fades.density, 1.0)) / log(2.0)) * lerpf(0.7, 1.0, thin)
					if fading:
						w = smoothstep(0.0, 0.6, w)
					if w <= 0.0:
						continue
					for e in 5:
						if d < edges[e]:
							rings[e] += w * scale * scale
							break
					count += 1
		results.append([alt, rings, count])
	for r in results:
		var line := "alt %3d m:" % r[0]
		var edges := ["<250", "250-500", "500-1k", "1-2k", "2-3.5k"]
		for e in 5:
			line += "  %s %7.0f" % [edges[e], r[1][e] / 1000.0]
		print(line, "   (trees drawn %d)" % r[2])
	quit()
