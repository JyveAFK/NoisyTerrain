extends Camera3D
## Free-flight camera for the demo. Right mouse button (or Tab) to look, WASD to fly,
## Q/E down/up, Shift to go fast, mouse wheel to change speed.

@export var speed: float = 120.0
@export var boost: float = 8.0
@export var terrain: NoiseTerrain
@export var min_clearance: float = 3.0

var _looking := false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_set_looking(event.pressed)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			speed *= 1.25
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			speed /= 1.25
	elif event is InputEventKey and event.pressed and event.keycode == KEY_TAB:
		_set_looking(not _looking)
	elif event is InputEventMouseMotion and _looking:
		rotation.y -= event.relative.x * 0.0025
		rotation.x = clampf(rotation.x - event.relative.y * 0.0025, -1.5, 1.5)


func _set_looking(on: bool) -> void:
	_looking = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE


func _ready() -> void:
	# The Compatibility renderer has a less precise depth buffer: pull the near plane out
	# and the far plane in, or distant land and water flicker. Forward+ keeps the full range.
	if NoiseTerrain.is_compatibility_renderer():
		near = maxf(near, 3.0)
		far = minf(far, 40000.0)


func _process(delta: float) -> void:
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): move.z -= 1.0
	if Input.is_key_pressed(KEY_S): move.z += 1.0
	if Input.is_key_pressed(KEY_A): move.x -= 1.0
	if Input.is_key_pressed(KEY_D): move.x += 1.0
	if Input.is_key_pressed(KEY_E): move.y += 1.0
	if Input.is_key_pressed(KEY_Q): move.y -= 1.0
	var rate := speed * (boost if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	global_position += global_transform.basis * move.normalized() * rate * delta
	if terrain != null and not terrain.is_loading() or terrain != null and terrain.get_cell_count() > 0:
		var ground := maxf(terrain.get_height(global_position.x, global_position.z), terrain.settings.sea_level)
		global_position.y = maxf(global_position.y, ground + min_clearance)
