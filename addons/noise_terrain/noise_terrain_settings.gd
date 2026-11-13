class_name NoiseTerrainSettings
extends Resource
## The recipe for the endless terrain: every height comes from world coordinates and the seed,
## so any spot can be worked out on its own, in any order, on any thread.
##
## Layers:
##  1. Biome noise (very large) -> height_curve gives the base land height, roughness_curve says how hilly.
##  2. Detail noise (smaller, fractal) adds hills, ridged mountains and dunes on top.
##  3. Lake noise -> lake_curve sinks low ground below the water line to make lakes.
##  4. Cell overrides replace or add to chosen cells with a height-map texture.

@export var seed: int = 1
## Size in metres of the biggest (most distant) terrain cell. Cell overrides use this size too.
@export var cell_size: float = 4096.0
## World height of the water surface.
@export var sea_level: float = 0.0

@export_group("Biome noise (large)")
## Metres across one biome feature (continent, mountain range, plain).
@export var biome_scale: float = 18000.0
## Biome noise (0 to 1) -> base land height as a fraction of max_height. Below 0 is under water.
@export var height_curve: Curve
## Biome noise (0 to 1) -> how strong the detail noise is there (0 flat, 1 full mountains).
@export var roughness_curve: Curve
@export var max_height: float = 2200.0

@export_group("Detail noise")
## Metres across one hill or mountain.
@export var detail_scale: float = 3200.0
## Height in metres the detail noise can add where roughness is 1.
@export var detail_height: float = 1300.0
@export_range(1, 8) var detail_octaves: int = 6
## 0 = rolling hills, 1 = sharp ridged mountains.
@export_range(0.0, 1.0) var ridge_amount: float = 0.7
## Sand dunes in dry areas: height and length in metres.
@export var dune_height: float = 22.0
@export var dune_scale: float = 260.0

@export_group("Lakes")
## Metres across one lake.
@export var lake_scale: float = 2600.0
## Lake noise (0 to 1) -> how far the ground sinks (0 none, 1 fully below water). Edit to set how common lakes are and how steep the shores.
@export var lake_curve: Curve
@export var lake_depth: float = 18.0
## Lakes only form on ground lower than this (the water is one level everywhere).
@export var lake_max_altitude: float = 140.0

@export_group("Climate")
## Metres across one wet or dry region. Dry = desert and dunes, wet = grass and forest.
@export var moisture_scale: float = 14000.0
@export var tree_line: float = 1250.0
@export var snow_line: float = 1650.0

@export_group("Cell overrides")
@export var overrides: Array[NoiseTerrainCellOverride] = []

const _LUT := 256

var _biome := FastNoiseLite.new()
var _detail := FastNoiseLite.new()
var _ridge := FastNoiseLite.new()
var _dune := FastNoiseLite.new()
var _lake := FastNoiseLite.new()
var _moist := FastNoiseLite.new()
var _height_lut := PackedFloat32Array()
var _rough_lut := PackedFloat32Array()
var _lake_lut := PackedFloat32Array()
var _cells := {} # Vector2i -> [PackedFloat32Array, width, height, NoiseTerrainCellOverride]
var _prepared := false


## Fills in any missing curves with sensible defaults.
func ensure_defaults() -> void:
	if height_curve == null:
		height_curve = _curve([[0.0, -0.3], [0.3, -0.06], [0.37, 0.008], [0.55, 0.03], [0.75, 0.22], [1.0, 0.6]], -1.0, 1.0)
	if roughness_curve == null:
		roughness_curve = _curve([[0.0, 0.05], [0.37, 0.04], [0.5, 0.1], [0.7, 0.55], [1.0, 1.0]], 0.0, 1.0)
	if lake_curve == null:
		lake_curve = _curve([[0.0, 0.0], [0.5, 0.0], [0.72, 1.0], [1.0, 1.0]], 0.0, 1.0)


static func _curve(points: Array, low: float, high: float) -> Curve:
	var c := Curve.new()
	c.min_value = low
	c.max_value = high
	for p in points:
		c.add_point(Vector2(p[0], p[1]))
	return c


## Call once on the main thread before any height queries. Bakes the curves and height maps
## into plain arrays so worker threads can read them safely. Await it: noise textures may
## still be generating.
func prepare() -> void:
	ensure_defaults()
	_setup(_biome, 0, 1.0 / biome_scale, 4, FastNoiseLite.FRACTAL_FBM)
	_setup(_detail, 1, 1.0 / detail_scale, detail_octaves, FastNoiseLite.FRACTAL_FBM)
	_setup(_ridge, 2, 1.0 / (detail_scale * 1.7), maxi(detail_octaves - 1, 1), FastNoiseLite.FRACTAL_RIDGED)
	_setup(_dune, 3, 1.0 / dune_scale, 2, FastNoiseLite.FRACTAL_RIDGED)
	_setup(_lake, 4, 1.0 / lake_scale, 2, FastNoiseLite.FRACTAL_FBM)
	_setup(_moist, 5, 1.0 / moisture_scale, 3, FastNoiseLite.FRACTAL_FBM)
	_height_lut = _bake(height_curve)
	_rough_lut = _bake(roughness_curve)
	_lake_lut = _bake(lake_curve)
	_cells.clear()
	for o in overrides:
		if o == null or o.height_map == null:
			continue
		var image := o.height_map.get_image()
		if image == null: # A NoiseTexture2D that is still generating.
			await o.height_map.changed
			image = o.height_map.get_image()
		if image == null:
			push_warning("NoiseTerrain: override at %s has no readable image, skipped." % o.cell)
			continue
		if image.is_compressed():
			image.decompress()
		var w := image.get_width()
		var h := image.get_height()
		var data := PackedFloat32Array()
		data.resize(w * h)
		for y in h:
			for x in w:
				data[y * w + x] = image.get_pixel(x, y).r
		_cells[o.cell] = [data, w, h, o]
		print("[NoiseTerrain] override cell %s ready (%dx%d height map)" % [o.cell, w, h])
	_prepared = true


func _setup(n: FastNoiseLite, offset: int, frequency: float, octaves: int, fractal: int) -> void:
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = seed * 31 + offset * 1013
	n.frequency = frequency
	n.fractal_type = fractal
	n.fractal_octaves = octaves


func _bake(c: Curve) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(_LUT)
	for i in _LUT:
		a[i] = c.sample(float(i) / float(_LUT - 1))
	return a


static func _lut(a: PackedFloat32Array, t: float) -> float:
	var f := clampf(t, 0.0, 1.0) * float(_LUT - 1)
	var i := int(f)
	if i >= _LUT - 1:
		return a[_LUT - 1]
	return lerpf(a[i], a[i + 1], f - float(i))


## 0 = dry (desert), 1 = wet (forest). Safe on any thread after prepare().
func moisture(x: float, z: float) -> float:
	return clampf(_moist.get_noise_2d(x, z) * 0.9 + 0.5, 0.0, 1.0)


## Ground height in metres at a world position. Safe on any thread after prepare().
func height(x: float, z: float) -> float:
	var h := _noise_height(x, z)
	if _cells.is_empty():
		return h
	var cx := floori(x / cell_size)
	var cz := floori(z / cell_size)
	var entry = _cells.get(Vector2i(cx, cz))
	if entry == null:
		return h
	var o: NoiseTerrainCellOverride = entry[3]
	var u := x / cell_size - float(cx)
	var v := z / cell_size - float(cz)
	var edge := minf(minf(u, 1.0 - u), minf(v, 1.0 - v)) / o.blend_margin
	var weight := smoothstep(0.0, 1.0, edge)
	var mapped := o.base_height + o.height_scale * _bilinear(entry[0], entry[1], entry[2], u, v)
	if o.mode == NoiseTerrainCellOverride.Mode.ADD:
		return h + mapped * weight
	return lerpf(h, mapped, weight)


func _noise_height(x: float, z: float) -> float:
	var b := _biome.get_noise_2d(x, z) * 0.9 + 0.5
	var base := _lut(_height_lut, b) * max_height
	var rough := _lut(_rough_lut, b)
	var d := _detail.get_noise_2d(x, z)
	var r := _ridge.get_noise_2d(x, z) * 0.5 + 0.5
	var h := base + rough * detail_height * (d * 0.4 + ridge_amount * r * r) + d * 14.0
	# Lakes: sink low ground under the water line.
	# The lake strength fades in and out with the base height (never a hard cut-off, which
	# would leave a cliff along that contour): none on the sea bed, none on high ground.
	if base > sea_level - lake_depth * 3.0 and base < lake_max_altitude:
		var sink := _lut(_lake_lut, _lake.get_noise_2d(x, z) * 0.9 + 0.5)
		if sink > 0.0:
			sink *= smoothstep(lake_max_altitude, lake_max_altitude * 0.4, base)
			sink *= smoothstep(sea_level - lake_depth * 3.0, sea_level + 4.0, base)
			sink = sink * sink * (3.0 - 2.0 * sink) # Ease in and out for gentle shores.
			h = lerpf(h, minf(h, sea_level - lake_depth), sink)
	# Dunes in dry areas above the water.
	if dune_height > 0.0:
		var dry := smoothstep(0.42, 0.3, moisture(x, z))
		if dry > 0.0:
			var dune := _dune.get_noise_2d(x * 0.45 + z * 0.2, z) * 0.5 + 0.5
			h += dry * dune_height * dune * smoothstep(sea_level + 2.0, sea_level + 30.0, h) * (1.0 - rough * 0.7)
	return h


static func _bilinear(data: PackedFloat32Array, w: int, h: int, u: float, v: float) -> float:
	var fx := clampf(u, 0.0, 1.0) * float(w - 1)
	var fy := clampf(v, 0.0, 1.0) * float(h - 1)
	var x0 := int(fx)
	var y0 := int(fy)
	var x1 := mini(x0 + 1, w - 1)
	var y1 := mini(y0 + 1, h - 1)
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var top := lerpf(data[y0 * w + x0], data[y0 * w + x1], tx)
	var bottom := lerpf(data[y1 * w + x0], data[y1 * w + x1], tx)
	return lerpf(top, bottom, ty)
