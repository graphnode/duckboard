extends CharacterBody3D

## A throwaway first-person controller for walking a Duckboard map at eye height instead of
## judging it from the editor camera. It lives in `tests/` because it is part of the development
## harness — Duckboard ships no player and no gameplay, and nothing in `addons/duckboard/` may
## depend on this file.
##
## Deliberately self-contained: no Input Map actions (the project defines none), no autoloads, no
## project settings. Drop `fps_player.tscn` into a map, place it where you want to start, press F6.
## Keys are read as PHYSICAL keycodes, so the layout is WASD on an AZERTY keyboard too.
##
## Collision comes from the brushes themselves — this script assumes the map is already solid.
##
##   move        W A S D             jump    Space
##   look        mouse               sprint  hold Shift
##   free-fly    V (toggle noclip)   up/down Space / Ctrl while flying
##   release     Esc, click to look again

# Speeds are written in TrenchBroom units and converted, so they read the way they would in a .map
# and stay correct if the scale convention ever moves. They are Quake's own numbers, which is what
# a map built to TrenchBroom's grid is implicitly designed around: 320 u/s covers a 64-unit
# corridor in a fifth of a second, and a 270 u/s jump clears a 48-unit ledge.
const UNITS := Brush.UNITS_PER_METER
const WALK_SPEED := 180.0 / UNITS
const JUMP_SPEED := 200.0 / UNITS
const GRAVITY := 800.0 / UNITS
const NOCLIP_SPEED := 640.0 / UNITS
## A 16-unit stair with slack. Brush maps are full of them and a capsule will not climb one on its
## own, so anything at or below this height is stepped over rather than blocking (see _step_up).
const STEP_HEIGHT := 18.0 / UNITS
## Ground control is near-instant on purpose — this is a measuring tool, not a game feel study.
## Air control stays low so a jump commits, which is how a gap reads as jumpable or not.
const GROUND_ACCEL := 14.0
const AIR_ACCEL := 2.0
const PITCH_LIMIT := deg_to_rad(89.0)

@export_range(0.05, 5.0, 0.05) var mouse_sensitivity := 1.0
@export var sprint_multiplier := 2.5
## Printed once on spawn. Off for anyone using this as a base for something real.
@export var print_controls := true

## Yaw lives on the body and pitch on the camera, so turning cannot tilt the movement basis.
var _yaw := 0.0
var _pitch := 0.0
var _noclip := false
var _camera: Camera3D
var _claimed_camera := false


func _ready() -> void:
	_camera = get_node_or_null(^"Camera3D") as Camera3D
	if _camera == null:
		push_error("fps_player: no child Camera3D named \"Camera3D\" — look and free-fly are off.")
	else:
		# Maps often keep a stray Camera3D from an editor session, and the last camera to become
		# current wins. Claiming it here beats one that is EARLIER in the scene; _physics_process
		# claims it once more on the first frame, which also beats one that is later.
		_camera.current = true
		_pitch = _camera.rotation.x

	# The spawn facing is whatever the node was placed at, so aiming the player is done in the
	# editor. Roll and pitch on the body are dropped — a body that is not upright cannot walk.
	_yaw = rotation.y
	rotation = Vector3(0.0, _yaw, 0.0)

	# Without this, walking DOWN a stair leaves the floor for a frame and the descent turns into a
	# series of little launches. It must cover a step for the climb in _step_up to settle.
	floor_snap_length = STEP_HEIGHT

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if print_controls:
		print("fps_player: WASD move, mouse look, Space jump, Shift sprint, V noclip, Esc release.")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := (event as InputEventMouseMotion).relative * 0.0022 * mouse_sensitivity
		_yaw = wrapf(_yaw - motion.x, -PI, PI)
		_pitch = clampf(_pitch - motion.y, -PITCH_LIMIT, PITCH_LIMIT)
		rotation.y = _yaw
		if _camera != null:
			_camera.rotation.x = _pitch
		return

	# Esc frees the cursor so the window can be left or the debugger reached; a click takes it back.
	# Both are swallowed, or the click that re-captures also fires at the game underneath.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			get_viewport().set_input_as_handled()
		return

	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		match (event as InputEventKey).physical_keycode:
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				get_viewport().set_input_as_handled()
			KEY_V:
				_set_noclip(not _noclip)
				get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	# Once, on the first frame: by now every camera in the map has entered the tree, so this is the
	# last word regardless of where the player was placed in the scene.
	if not _claimed_camera:
		_claimed_camera = true
		if _camera != null:
			_camera.current = true

	var wish := _wish_direction()
	var sprint := sprint_multiplier if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0

	if _noclip:
		# Straight along the look axis, vertical included — the point of free-fly is to leave the
		# floor plane. No gravity, no collision, so this ignores move_and_slide entirely.
		velocity = wish * NOCLIP_SPEED * sprint
		global_position += velocity * delta
		return

	var speed := WALK_SPEED * sprint

	# Horizontal only: gravity owns Y, and folding the look pitch into the walk direction would
	# make looking down slow the player to a crawl.
	var target := Vector3(wish.x, 0.0, wish.z)
	if target.length_squared() > 0.0:
		target = target.normalized() * speed
	var accel := GROUND_ACCEL if is_on_floor() else AIR_ACCEL
	velocity.x = move_toward(velocity.x, target.x, speed * accel * delta)
	velocity.z = move_toward(velocity.z, target.z, speed * accel * delta)

	if is_on_floor():
		if Input.is_physical_key_pressed(KEY_SPACE):
			velocity.y = JUMP_SPEED
	else:
		velocity.y -= GRAVITY * delta

	_step_up(delta)
	move_and_slide()


## The intended direction of travel in world space, from the camera's own basis so free-fly follows
## the look. Length is 0 or 1.
func _wish_direction() -> Vector3:
	var input := Vector3(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		0.0,
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	if _noclip:
		input.y = (float(Input.is_physical_key_pressed(KEY_SPACE))
			- float(Input.is_physical_key_pressed(KEY_CTRL)))
	# In noclip the camera's basis carries the pitch, so forward means where you are looking. On
	# foot only the yaw is wanted, and that is the body's — the pitch is stripped by construction.
	var basis := global_transform.basis
	if _noclip and _camera != null:
		basis = _camera.global_transform.basis
	var dir := basis * input
	return dir.normalized() if dir.length_squared() > 0.0 else Vector3.ZERO


## Lift the body over a low obstruction so stairs are walkable. A capsule stops dead against a
## 16-unit step otherwise, which makes most brush maps untestable.
##
## The test is deliberately two probes and no sweep: blocked at foot height, clear one step higher.
## That distinguishes a stair from a wall — a wall is blocked at both — without needing to know
## anything about the geometry. The lift is committed before move_and_slide so the same frame's
## motion carries the body forward onto the step, and `floor_snap_length` pulls it back down if
## there was nothing to land on.
func _step_up(delta: float) -> void:
	if not is_on_floor():
		return
	var motion := Vector3(velocity.x, 0.0, velocity.z) * delta
	if motion.length_squared() < 0.000001:
		return
	if not test_move(global_transform, motion):
		return   # nothing in the way
	var raised := global_transform.translated(Vector3.UP * STEP_HEIGHT)
	if test_move(raised, motion):
		return   # blocked up there too, so it is a wall and not a step
	global_position = raised.origin


func _set_noclip(on: bool) -> void:
	_noclip = on
	# Both directions: the body must not be pushed out of geometry it flew into, and must not fall
	# through the world while flying.
	set_collision_layer_value(1, not on)
	set_collision_mask_value(1, not on)
	velocity = Vector3.ZERO
	print("fps_player: noclip ", "ON" if on else "OFF")
