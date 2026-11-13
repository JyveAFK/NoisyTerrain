extends SceneTree
## Checks the tree rule that stops popping: every tree in a coarse cell must also be in the
## smaller cells beneath it, with the same size, tint and rank. Also times cell builds.
## Run: godot --headless --path . -s tools/tree_subset_test.gd

func _init() -> void:
	_run()
func _run() -> void:
	var terr := NoiseTerrain.new()
	terr.settings = load("res://demo/terrain_settings.tres")
	await terr.settings.prepare()
	terr._indices = NoiseTerrain._make_indices(terr.cell_resolution)
	terr.terrain_material = ShaderMaterial.new()
	terr._tree_card_material = ShaderMaterial.new()
	terr._tree_materials = [terr._tree_card_material]
	terr._setup_tree_fades()
	var missing := 0
	var checked := 0
	var rank_bad := 0
	var fine_total := 0
	# Coarse cells at level 2 and 3 in a few places, against all their level-5 descendants.
	for coarse in [Vector3i(2, 0, 1), Vector3i(2, -3, 2), Vector3i(3, 1, 3), Vector3i(3, -5, -4), Vector3i(2, 7, -6)]:
		var parent := _trees(terr, coarse)
		var children := {}
		var span: int = 1 << (5 - coarse.x)
		for j in span:
			for i in span:
				for t in _trees(terr, Vector3i(5, coarse.y * span + i, coarse.z * span + j)):
					children[Vector2i(roundi(t.x * 100), roundi(t.z * 100))] = t
		fine_total += children.size()
		for t in parent:
			checked += 1
			var k := Vector2i(roundi(t.x * 100), roundi(t.z * 100))
			var found := Vector2i(999999, 0)
			for dz in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					if children.has(k + Vector2i(dx, dz)):
						found = k + Vector2i(dx, dz)
			if found.x == 999999:
				missing += 1
				print("missing tree at ", t)
				continue
			var c: Dictionary = children[found]
			if absf(c.scale - t.scale) > 0.001 or absf(c.tint - t.tint) > 0.0001 or absf(c.rank - t.rank) > 0.0001:
				rank_bad += 1
	print("coarse trees checked %d, missing from the fine cells %d, differing size/tint/rank %d (fine cells hold %d)" % [checked, missing, rank_bad, fine_total])
	# Timing
	for lod in [5, 2]:
		var t0 := Time.get_ticks_usec()
		for i in 12:
			terr._build(Vector3i(lod, i, 3))
		print("level %d cell build: %.1f ms each" % [lod, (Time.get_ticks_usec() - t0) / 12000.0])
	quit()

func _trees(terr: NoiseTerrain, key: Vector3i) -> Array:
	terr._results.clear()
	terr._build(key)
	var r: Dictionary = terr._results[0]
	var out := []
	var b: PackedFloat32Array = r.tree_buffer
	for i in r.tree_count:
		var o: int = i * 16
		out.append({"x": r.x + b[o + 3], "z": r.z + b[o + 11], "scale": b[o + 5], "rank": b[o + 12], "tint": b[o + 13]})
	return out
