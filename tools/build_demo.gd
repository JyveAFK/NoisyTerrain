extends SceneTree
## Rebuilds demo/terrain_settings.tres and demo/demo.tscn.
## Run: godot --headless -s tools/build_demo.gd


func _init() -> void:
	var settings := NoiseTerrainSettings.new()
	settings.ensure_defaults()

	# A drop-in cell: one cell replaced by its own unique noise (a field of rock spires).
	var special := FastNoiseLite.new()
	special.noise_type = FastNoiseLite.TYPE_CELLULAR
	special.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_DIV
	special.frequency = 0.02
	special.seed = 7
	var texture := NoiseTexture2D.new()
	texture.width = 256
	texture.height = 256
	texture.noise = special
	var override := NoiseTerrainCellOverride.new()
	override.cell = Vector2i(0, -1)
	override.height_map = texture
	override.base_height = 40.0
	override.height_scale = 700.0
	override.blend_margin = 0.25
	settings.overrides = [override]
	print("save settings: ", ResourceSaver.save(settings, "res://demo/terrain_settings.tres"))
	settings = load("res://demo/terrain_settings.tres")

	var root := Node3D.new()
	root.name = "Demo"

	var terrain := NoiseTerrain.new()
	terrain.name = "NoiseTerrain"
	terrain.settings = settings
	root.add_child(terrain)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-38.0, -35.0, 0.0)
	sun.light_energy = 1.3
	sun.light_color = Color(1.0, 0.96, 0.9)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 1500.0
	root.add_child(sun)

	# The environment lives in the scene, so it can be edited in the inspector like any other.
	var sky_material := ShaderMaterial.new()
	sky_material.shader = load("res://addons/noise_terrain/shaders/sky_clouds.gdshader")
	var sky_resource := Sky.new()
	sky_resource.sky_material = sky_material
	sky_resource.radiance_size = Sky.RADIANCE_SIZE_64
	sky_resource.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky_resource
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.74, 0.83, 0.92)
	env.fog_density = 0.000035
	env.fog_sun_scatter = 0.15
	env.fog_sky_affect = 0.0
	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	world.environment = env
	root.add_child(world)

	var sky := NoiseTerrainSky.new()
	sky.name = "NoiseTerrainSky"
	root.add_child(sky)
	sky.terrain = terrain
	sky.sun = sun
	sky.world_environment = world

	var camera := Camera3D.new()
	camera.name = "FlyCamera"
	camera.set_script(load("res://demo/fly_camera.gd"))
	camera.position = Vector3(600.0, 420.0, 1500.0)
	camera.rotation_degrees = Vector3(-12.0, 15.0, 0.0)
	camera.near = 0.5
	camera.far = 80000.0
	camera.fov = 65.0
	root.add_child(camera)
	camera.terrain = terrain
	camera.current = true

	var layer := CanvasLayer.new()
	layer.name = "HUD"
	root.add_child(layer)
	var label := Label.new()
	label.name = "Info"
	label.set_script(load("res://demo/hud.gd"))
	label.position = Vector2(12.0, 8.0)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	layer.add_child(label)
	label.terrain = terrain
	label.camera = camera

	for node in [terrain, sun, world, sky, camera, layer, label]:
		node.owner = root
	var scene := PackedScene.new()
	print("pack: ", scene.pack(root))
	print("save scene: ", ResourceSaver.save(scene, "res://demo/demo.tscn"))
	quit()
