class_name NoiseTerrainSky
extends Node
## Controls the fast cloud ceiling and keeps the terrain's cloud shadows lined up with it.
##
## It does not create or change the Environment. Point world_environment at your own
## WorldEnvironment node: if its sky uses the sky_clouds.gdshader material, the clouds are
## drawn there. Fog, tonemap, sky colours and everything else stay exactly as you set them.
## With no WorldEnvironment (or a different sky) the cloud shadows on the ground still work.

@export var terrain: NoiseTerrain
@export var sun: DirectionalLight3D
## Your WorldEnvironment node. Only its cloud sky material is touched, and only the cloud values below.
@export var world_environment: WorldEnvironment

@export_group("Clouds")
## Turn the whole cloud layer off (no clouds in the sky, no shadows on the ground),
## for example to use a different cloud system.
@export var clouds_enabled: bool = true:
	set(value):
		clouds_enabled = value
		_dirty = true
## Height in metres of the flat cloud bases. Keep it above your highest mountains and the player.
@export var cloud_height: float = 6400.0:
	set(value):
		cloud_height = value
		_dirty = true
## How tall the clouds are, in metres, above cloud_height.
@export var cloud_thickness: float = 500.0:
	set(value):
		cloud_thickness = value
		_dirty = true
@export_range(0.0, 1.0) var cloud_coverage: float = 0.32:
	set(value):
		cloud_coverage = value
		_dirty = true
## Metres across one tile of cloud noise: bigger = bigger clouds.
@export var cloud_scale: float = 12000.0:
	set(value):
		cloud_scale = value
		_dirty = true
## 0 = smooth puffs, 1 = frayed, wispy edges.
@export_range(0.0, 1.0) var cloud_wisp: float = 0.6:
	set(value):
		cloud_wisp = value
		_dirty = true
@export_range(0.01, 0.5) var cloud_softness: float = 0.14:
	set(value):
		cloud_softness = value
		_dirty = true
## Metres per second.
@export var cloud_wind: Vector2 = Vector2(8.0, 3.0):
	set(value):
		cloud_wind = value
		_dirty = true
@export_range(0.0, 1.0) var cloud_shadow_strength: float = 0.8:
	set(value):
		cloud_shadow_strength = value
		_dirty = true
## Ray steps through the cloud layer. Fewer = faster, more = smoother.
@export_range(4, 48) var cloud_steps: int = 8:
	set(value):
		cloud_steps = value
		_dirty = true
## Optional replacement for the built-in cloud noise (a seamless greyscale texture).
@export var cloud_noise: Texture2D:
	set(value):
		cloud_noise = value
		_dirty = true

const _SKY_SHADER := "res://addons/noise_terrain/shaders/sky_clouds.gdshader"

var _dirty := true
var _noise: Texture2D
var _terrain_hooked := false
var _warned := false


func _ready() -> void:
	if terrain != null:
		terrain.origin_shifted.connect(func(_offset: Vector3) -> void: _dirty = true)


func _process(_delta: float) -> void:
	# The terrain makes its material a moment after start-up; hook it up once it exists.
	if not _terrain_hooked and terrain != null and terrain.terrain_material != null:
		_terrain_hooked = true
		_dirty = true
	if _dirty:
		apply()
	if sun != null and terrain != null and terrain.terrain_material != null:
		terrain.terrain_material.set_shader_parameter("sun_direction", sun.global_transform.basis.z)


## The cloud sky material on the WorldEnvironment, or null if it has a different sky.
func get_sky_material() -> ShaderMaterial:
	if world_environment == null or world_environment.environment == null or world_environment.environment.sky == null:
		return null
	var material := world_environment.environment.sky.sky_material as ShaderMaterial
	if material == null or material.shader == null or material.shader.resource_path != _SKY_SHADER:
		return null
	return material


## Pushes the cloud values to the sky and the terrain. Runs by itself when a value changes.
func apply() -> void:
	_dirty = false
	if cloud_noise != null:
		_noise = cloud_noise
	elif _noise == null or not (_noise is NoiseTexture2D):
		_noise = _make_noise()
	var targets: Array[ShaderMaterial] = []
	var sky_material := get_sky_material()
	if sky_material != null:
		targets.append(sky_material)
		sky_material.set_shader_parameter("cloud_steps", cloud_steps)
	elif clouds_enabled and not _warned:
		_warned = true
		print("[NoiseTerrainSky] no cloud sky found (set world_environment, and give its Sky a ShaderMaterial using sky_clouds.gdshader). Cloud shadows still work; clouds are not drawn.")
	if terrain != null and terrain.terrain_material != null:
		targets.append(terrain.terrain_material)
		terrain.terrain_material.set_shader_parameter("cloud_shadow_strength", cloud_shadow_strength)
	var origin := terrain.get_origin() if terrain != null else Vector2.ZERO
	for m in targets:
		m.set_shader_parameter("clouds_enabled", clouds_enabled)
		m.set_shader_parameter("cloud_noise", _noise)
		m.set_shader_parameter("cloud_scale", cloud_scale)
		m.set_shader_parameter("cloud_coverage", cloud_coverage)
		m.set_shader_parameter("cloud_softness", cloud_softness)
		m.set_shader_parameter("cloud_wisp", cloud_wisp)
		m.set_shader_parameter("cloud_base", cloud_height)
		m.set_shader_parameter("cloud_thickness", cloud_thickness)
		m.set_shader_parameter("cloud_wind", cloud_wind)
		m.set_shader_parameter("world_origin", origin)


static func _make_noise() -> NoiseTexture2D:
	var texture := NoiseTexture2D.new()
	texture.width = 512
	texture.height = 512
	texture.seamless = true
	texture.generate_mipmaps = true
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 0.012
	n.fractal_octaves = 5
	n.fractal_gain = 0.55
	texture.noise = n
	return texture
