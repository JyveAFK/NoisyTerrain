extends SceneTree
## Renders test shots of the demo to user://shots. Run with a display:
## godot --path . -s tools/screenshot.gd
## Add "-- --quick" for a fast low-detail pass, or "-- --only=start,sky" to pick shots.
## "--clouds=off" and "--cloudheight=1500" test the cloud controls.
## "--view=name:x:y:z:pitch:yaw" renders your own views instead (repeatable).
## "--hemisphere-trees" swaps in a few-sided hemisphere with its own material as tree_mesh.

var shots := [
	["start", Vector3(600, 420, 1500), Vector3(-12, 15, 0)],
	["sky", Vector3(600, 420, 1500), Vector3(28, 15, 0)],
	["high", Vector3(600, 2600, 1500), Vector3(-25, 15, 0)],
	["special_cell", Vector3(2048, 900, 600), Vector3(-30, 0, 0)],
	["low", Vector3(900, -1, 300), Vector3(-4, 60, 0)],
	["far_away", Vector3(30000, 900, -22000), Vector3(-14, 200, 0)],
]


func _init() -> void:
	_run()


func _run() -> void:
	var scene: Node = load("res://demo/demo.tscn").instantiate()
	if OS.get_cmdline_user_args().has("--hemisphere-trees"):
		# Test: a few-sided hemisphere with its own material, as a custom tree_mesh.
		var dome := SphereMesh.new()
		dome.radius = 0.5
		dome.height = 1.0
		dome.radial_segments = 4
		dome.rings = 1
		dome.is_hemisphere = true
		var olive := StandardMaterial3D.new()
		olive.albedo_color = Color(0.45, 0.4, 0.1)
		dome.material = olive
		scene.get_node("NoiseTerrain").tree_mesh = dome
	root.add_child(scene)
	var terrain: NoiseTerrain = scene.get_node("NoiseTerrain")
	var camera: Camera3D = scene.get_node("FlyCamera")
	camera.set_process(false)
	camera.set_process_unhandled_input(false)
	terrain.max_jobs = 2
	if OS.get_cmdline_user_args().has("--nothreads"):
		terrain.use_threads = false
	var clouds: NoiseTerrainSky = scene.get_node("NoiseTerrainSky")
	var tag := ""
	for a in OS.get_cmdline_user_args():
		if a == "--clouds=off":
			clouds.clouds_enabled = false
			tag = "_clouds_off"
		if a.begins_with("--cloudheight="):
			clouds.cloud_height = float(a.trim_prefix("--cloudheight="))
			tag = "_height_" + a.trim_prefix("--cloudheight=")
	var custom := []
	for a in OS.get_cmdline_user_args():
		# --view=name:x:y:z:pitch:yaw (world position, degrees); can be given more than once.
		if a.begins_with("--view="):
			var v := a.trim_prefix("--view=").split(":")
			custom.append([v[0], Vector3(float(v[1]), float(v[2]), float(v[3])), Vector3(float(v[4]), float(v[5]), 0.0)])
	if not custom.is_empty():
		shots = custom
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			var wanted := a.trim_prefix("--only=").split(",")
			shots = shots.filter(func(shot: Array) -> bool: return shot[0] in wanted)
		if a == "--quick":
			terrain.view_cells = 2
			terrain.max_lod = 3
			terrain.tree_grid = 10
			terrain.max_jobs = 2
	DirAccess.make_dir_recursive_absolute("user://shots")
	for i in 5:
		await process_frame
	for shot in shots:
		var p: Vector3 = shot[1]
		# Positions are given in world space; convert for the floating origin.
		var o := terrain.get_origin()
		camera.global_position = Vector3(p.x - o.x, p.y, p.z - o.y)
		camera.rotation_degrees = shot[2]
		await process_frame
		o = terrain.get_origin()
		if p.y < 0.0:
			camera.global_position.y = maxf(terrain.get_height(camera.global_position.x, camera.global_position.z), 0.0) + 12.0
		var t := Time.get_ticks_msec()
		for i in 4:
			await process_frame
		while terrain.is_loading():
			await process_frame
		for i in 6:
			await process_frame
		var image := root.get_texture().get_image()
		image.save_png("user://shots/%s%s.png" % [shot[0], tag])
		print("shot %s: %d cells, loaded in %.1f s, origin %s" % [shot[0], terrain.get_cell_count(), (Time.get_ticks_msec() - t) / 1000.0, terrain.get_origin()])
	quit()
