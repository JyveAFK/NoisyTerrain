extends Label
## On-screen read-out: frame rate, position, cells on screen and streaming progress.

@export var terrain: NoiseTerrain
@export var camera: Camera3D

var _done := 0
var _total := 0


func _ready() -> void:
	if terrain != null:
		terrain.progress.connect(func(done: int, total: int) -> void:
			_done = done
			_total = total)


func _process(_delta: float) -> void:
	if terrain == null or camera == null:
		return
	var w := terrain.to_world(camera.global_position)
	var state := "ready"
	if terrain.is_loading():
		state = "building cells %d / %d (%d%%)" % [_done, _total, _done * 100 / maxi(_total, 1)]
	text = "%d fps   %s\nposition %.0f, %.0f   height %.0f m   speed %.0f m/s\ncells on screen %d   waiting %d   kept %d (%.0f MB)   built %d\nRight mouse or Tab: look   WASD QE: fly   Shift: fast   Wheel: speed" % [
		Engine.get_frames_per_second(), state, w.x, w.z, w.y, camera.speed,
		terrain.get_cell_count(), terrain.get_pending_count(), terrain.get_cached_count(), terrain.get_cache_mb(), terrain.get_build_count()]
