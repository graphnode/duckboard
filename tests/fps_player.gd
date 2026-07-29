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
## Walking into a RigidBody3D nudges it (see _push_bodies), so a map's loose props can be tested
## without writing gameplay code. A brush set to Trigger Volume is swum through (see _sample_water):
## Duckboard builds the Area3D, and deciding that "inside this one means water" is this file's job,
## which is the division the trigger kind exists to make.
##
##   move        W A S D             jump    Space
##   look        mouse               sprint  hold Shift
##   free-fly    V (toggle noclip)   up/down Space / Ctrl while flying
##   swim        W A S D along the look, Space up, Ctrl down; swim into a bank to climb out
##   release     Esc, click to look again

# Speeds are written in TrenchBroom units and converted, so they read the way they would in a .map
# and stay correct if the scale convention ever moves. They are Quake's own numbers, which is what
# a map built to TrenchBroom's grid is implicitly designed around: 320 u/s covers a 64-unit
# corridor in a fifth of a second, and a 270 u/s jump clears a 48-unit ledge.
## Built in code rather than placed in fps_player.tscn, so the scene stays the three nodes it was and
## anyone who already has a copy of it gets this for free.
const UNDERWATER_SHADER := preload("res://tests/materials/underwater.gdshader")

const UNITS := Brush.UNITS_PER_METER
const WALK_SPEED := 180.0 / UNITS
const JUMP_SPEED := 200.0 / UNITS
const GRAVITY := 800.0 / UNITS
const NOCLIP_SPEED := 640.0 / UNITS
## A 16-unit stair with slack. Brush maps are full of them and a capsule will not climb one on its
## own, so anything at or below this height is stepped over rather than blocking (see _step_up).
const STEP_HEIGHT := 16.0 / UNITS
## Ground control is near-instant on purpose — this is a measuring tool, not a game feel study.
## Air control stays low so a jump commits, which is how a gap reads as jumpable or not.
const GROUND_ACCEL := 14.0
const AIR_ACCEL := 2.0
const PITCH_LIMIT := deg_to_rad(89.0)
## The fastest a body can be shoved by walking into it, whatever the player's own speed. Well under
## WALK_SPEED so a pushed crate is always something you catch up with rather than chase.
const PUSH_SPEED_LIMIT := 90.0 / UNITS

## Swimming, in the same TrenchBroom units as the rest. Quake's numbers again: water is slower than
## the ground, you sink gently when you stop swimming, and control is sluggish enough that a pool
## reads as a different medium rather than as walking with the gravity turned off.
const SWIM_SPEED := 140.0 / UNITS
const SWIM_ACCEL := 6.0
## How fast you settle when nothing is pressed. Slow on purpose: a drifting sink is what lets you
## judge the DEPTH of a pool while floating in it, which is the thing a map editor wants tested.
const SINK_SPEED := 40.0 / UNITS
## Where the two water probes sit, as a fraction of the camera's own height above the body origin —
## so they follow whatever capsule fps_player.tscn is built with instead of restating its numbers.
## The waist decides whether you are swimming, the eye whether the swim is free in three dimensions.
const WAIST_FRACTION := 0.55
## Only reached when the Camera3D is missing, which is already an error by then.
const EYE_HEIGHT := 1.6

@export_range(0.05, 5.0, 0.05) var mouse_sensitivity := 1.0
@export var sprint_multiplier := 2.5
## Newtons of shove, applied while in contact. This is a force and not an impulse on purpose: a
## default 1 kg crate slides away easily, a 20 kg one barely budges, and neither can be launched.
## Zero turns pushing off, and the player treats every rigid body as a wall.
@export_range(0.0, 200.0, 0.5) var push_force := 12.0
## Printed once on spawn. Off for anyone using this as a base for something real.
@export var print_controls := true

## Which physics layers a Trigger Volume has to be on to count as WATER. Duckboard's trigger kind is
## a plain [Area3D] carrying no notion of what it is for, so something has to decide, and a layer is
## the decision a level designer can already make from the brush's own Collision fold. Everything
## else on these layers is ignored, because the probe asks for areas only.
@export_flags_3d_physics var water_layers := 1

## The full-screen tint and warp shown while the camera itself is under. Off for anyone who wants to
## bring their own — nothing else depends on it.
@export var underwater_overlay := true

## Yaw lives on the body and pitch on the camera, so turning cannot tilt the movement basis.
var _yaw := 0.0
var _pitch := 0.0
var _noclip := false
var _camera: Camera3D
var _claimed_camera := false

## Water state for the current frame, from _sample_water. `_in_water` means the waist is under, which
## is what turns walking into swimming; `_submerged` means the eyes are too, which is what decides
## whether the swim is free in three dimensions or pinned to the surface.
var _in_water := false
var _submerged := false
var _was_in_water := false
## Restored on leaving the water — a snapped body is glued to the pool floor and cannot swim up.
var _snap_length := 0.0
var _underwater: ColorRect


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
	_snap_length = floor_snap_length

	if underwater_overlay:
		_build_underwater_overlay()

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

	var sprint := sprint_multiplier if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0

	if _noclip:
		# Straight along the look axis, vertical included — the point of free-fly is to leave the
		# floor plane. No gravity, no collision, so this ignores move_and_slide entirely.
		velocity = _wish_direction(true) * NOCLIP_SPEED * sprint
		global_position += velocity * delta
		return

	_sample_water()
	if _in_water:
		_swim(delta)
		return
	if _was_in_water:
		_leave_water()

	var wish := _wish_direction()
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
	# The speed the player MEANT to travel at, kept because move_and_slide rewrites `velocity` —
	# it strips the component that went into whatever was hit. For a body being shoved that component
	# IS the shove, so measuring it afterwards reads zero and nothing is ever pushed.
	var intent := velocity
	move_and_slide()
	_push_bodies(delta, intent)


## Am I in water, and how deep — the whole of what this controller asks the map.
##
## Two point queries against AREAS ONLY, which is the part that matters. Every solid brush in the map
## is on layer 1 as well, so a query that also answered for bodies would report the pool's own walls
## as water. Asking by point rather than listening to `body_entered` is deliberate: a signal says
## "you touched it", and a swim controller needs "how much of you is under", which is two questions
## about two heights and cannot be answered by one boolean the engine keeps for you.
func _sample_water() -> void:
	_was_in_water = _in_water
	var head := _camera.position.y if _camera != null else EYE_HEIGHT
	_in_water = _water_at(global_position + Vector3.UP * (head * WAIST_FRACTION))
	# Only asked when the waist is already under. A head in water with a waist out of it is not a
	# state a level can produce, and skipping the query costs nothing to be sure of.
	_submerged = _in_water and _water_at(global_position + Vector3.UP * head)
	if _underwater != null:
		# The EYE probe drives the screen, not the waist one: what the overlay claims is "you are
		# looking through water", and wading chest-deep is not that.
		_underwater.visible = _submerged


## The full-screen underwater pass, built rather than placed — see UNDERWATER_SHADER.
##
## A [CanvasLayer] and not a quad in front of the camera: the shader samples the finished frame, so
## it has to run after the 3D is drawn, and a canvas layer is the one place that is true by
## construction rather than by getting a render priority right.
func _build_underwater_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Underwater"
	layer.layer = 10   # over any HUD a map of this harness's descendants might add
	var rect := ColorRect.new()
	# The ...and_offsets_ variant, which is not interchangeable with set_anchors_preset: that one
	# leaves the offsets alone, and a Control built in code starts at zero size — so the anchors
	# would say "full rect" while the rectangle stayed 0x0 and nothing ever drew.
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = UNDERWATER_SHADER
	rect.material = mat
	rect.visible = false
	layer.add_child(rect)
	add_child(layer)
	_underwater = rect


func _water_at(point: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var query := PhysicsPointQueryParameters3D.new()
	query.position = point
	query.collision_mask = water_layers
	query.collide_with_areas = true
	query.collide_with_bodies = false
	return not space.intersect_point(query, 1).is_empty()


## Swim: gravity off, and the look direction becomes the direction of travel in all three axes.
##
## That last part is the whole difference from walking. On foot the pitch is stripped so looking down
## cannot slow you; in water it is the steering, which is what makes a submerged room readable by
## swimming through it rather than guessable from its plan.
func _swim(delta: float) -> void:
	if not _was_in_water:
		# Kill the fall on the way in. Dropping off a pier at terminal velocity and keeping it puts
		# you on the bottom before the swim controls can answer, which reads as the water not being
		# there at all.
		velocity.y = maxf(velocity.y, -SWIM_SPEED)
		# A snapped body is glued to the pool floor and cannot swim up off it.
		floor_snap_length = 0.0

	var wish := _wish_direction(true)
	var lift := float(Input.is_physical_key_pressed(KEY_SPACE)) \
		- float(Input.is_physical_key_pressed(KEY_CTRL))
	var target := wish * SWIM_SPEED
	target.y = clampf(target.y + lift * SWIM_SPEED, -SWIM_SPEED, SWIM_SPEED)

	if wish.length_squared() == 0.0 and lift == 0.0:
		# Nothing pressed: drift down. It is what lets the floor of a pool be reached, and its depth
		# judged, without holding a key the whole way.
		target.y = -SINK_SPEED
	elif not _submerged and lift <= 0.0 and target.y > 0.0:
		# Head already in the air. Swimming forward while looking up cannot lift you any further, so
		# the surface holds and you make way across it instead of climbing an invisible ramp.
		target.y = 0.0

	velocity = velocity.move_toward(target, SWIM_SPEED * SWIM_ACCEL * delta)

	# SPACE at the surface is a kick against it rather than a stroke through it, so it leaves at jump
	# speed — applied straight past the gradual acceleration above, because that is not a smooth
	# thing. It is how you clear a lip you are already level with; anything higher is _swim_out's job.
	if not _submerged and lift > 0.0:
		velocity.y = JUMP_SPEED

	var intent := velocity
	_swim_out(delta)
	move_and_slide()
	_push_bodies(delta, intent)


## Haul out of the water onto a ledge you have swum into. The counterpart of _step_up, and needed for
## the same reason: without it a pool is a trap.
##
## [b]The height that matters is measured from the WATER LINE, not from the feet.[/b] Floating at the
## surface puts the waist at the surface, which leaves the feet the better part of a metre UNDER it —
## so a pier standing a mere 8 units proud of the water is really a 1.1 m climb, half again what a
## jump from solid ground clears. That is why swimming at it and pressing SPACE did nothing, and why
## no amount of tuning JUMP_SPEED was going to be the answer: the kick was being asked to cover the
## submerged part of the body as well as the ledge.
##
## So the lift offered here is `waist + STEP_HEIGHT` — enough to put the feet one ordinary step above
## the water line, wherever the body happens to be floating. The same two probes _step_up uses decide
## whether to take it: blocked at the current height, clear at the raised one. A wall is blocked at
## both and refuses, which is what stops this from being a climb-anything.
##
## Only from the SURFACE. Fully submerged there is no water line to climb out onto, and the ledge
## overhead is a ceiling rather than a step.
func _swim_out(delta: float) -> bool:
	if _submerged:
		return false
	var motion := Vector3(velocity.x, 0.0, velocity.z) * delta
	# No motion means no intent: drifting against a ledge must not haul you onto it, or floating in a
	# corner would silently eject you.
	if motion.length_squared() < 0.000001:
		return false
	if not test_move(global_transform, motion):
		return false   # open water ahead
	var head := _camera.position.y if _camera != null else EYE_HEIGHT
	var raised := global_transform.translated(Vector3.UP * (head * WAIST_FRACTION + STEP_HEIGHT))
	if test_move(raised, motion):
		return false   # blocked up there too, so it is a wall and not a bank
	global_position = raised.origin
	# The sink is cancelled but nothing is added: the lift has already done the work, and gravity
	# takes the body down onto the ledge over the next few frames.
	velocity.y = maxf(velocity.y, 0.0)
	return true


## Back on dry land: put the stair snap back. The upward velocity is deliberately NOT touched — it is
## the kick that is carrying you over the lip, and clamping it here is what would drop you back in.
func _leave_water() -> void:
	_was_in_water = false
	floor_snap_length = _snap_length


## Shove any RigidBody3D the body just slid against. A CharacterBody3D is infinitely heavy to the
## physics server and pushes nothing on its own — it stops dead against a crate — so the contacts
## move_and_slide already resolved are replayed here as forces on the other body.
##
## Three deliberate restraints keep this gentle enough to be a measuring tool:
## - The push is HORIZONTAL. Standing on a crate would otherwise stamp it into the floor, and
##   brushing the top edge of one would flick it up.
## - It is a force, so mass decides how much a body actually moves, and a light body reaching
##   PUSH_SPEED_LIMIT stops gaining speed however long the contact lasts.
## - Nothing is applied to a body already moving away faster than the player is closing, so walking
##   behind a rolling barrel does not keep feeding it.
##
## The force lands at the contact point rather than the centre of mass, which is what lets a tall
## crate tip when it is shoved high up — usually the thing being tested.
##
## `intent` is the pre-slide velocity: see _physics_process for why the post-slide one is useless.
func _push_bodies(delta: float, intent: Vector3) -> void:
	if push_force <= 0.0:
		return
	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		var body := collision.get_collider() as RigidBody3D
		if body == null or body.freeze:
			continue
		# A crate that has settled is ASLEEP, and an impulse handed to a sleeping body is discarded —
		# so the first shove against anything at rest would do nothing at all.
		body.sleeping = false

		# Away from the player, flattened. A near-vertical contact (floor or ceiling of a body) has
		# nothing left after the flatten and is skipped.
		var push_dir := -collision.get_normal()
		push_dir.y = 0.0
		if push_dir.length_squared() < 0.0001:
			continue
		push_dir = push_dir.normalized()

		# How fast the player is closing on the body, and how fast the body is already leaving. The
		# gap between them is all that is left to give.
		var closing := intent.dot(push_dir)
		if closing <= 0.0:
			continue
		var target := minf(closing, PUSH_SPEED_LIMIT)
		var current := body.linear_velocity.dot(push_dir)
		if current >= target:
			continue

		# Never more than it takes to reach `target` this frame — that ceiling is what makes a light
		# body settle at a walking pace instead of accelerating away.
		var impulse := minf(push_force * delta, body.mass * (target - current))
		body.apply_impulse(push_dir * impulse, collision.get_position() - body.global_position)


## The intended direction of travel in world space. Length is 0 or 1.
##
## `free` swaps the body's basis for the camera's, so forward means where you are LOOKING rather than
## where you are facing — which is what free-fly and swimming both want, and what walking must not
## have (see _physics_process).
func _wish_direction(free := false) -> Vector3:
	var input := Vector3(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		0.0,
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	if _noclip:
		input.y = (float(Input.is_physical_key_pressed(KEY_SPACE))
			- float(Input.is_physical_key_pressed(KEY_CTRL)))
	# The camera's basis carries the pitch. On foot only the yaw is wanted, and that is the body's —
	# the pitch is stripped by construction.
	var basis := global_transform.basis
	if free and _camera != null:
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
##
## RIGID BODIES ARE NEVER STEPPED ON, whatever the probes say. Loose props are exactly the geometry
## the two-probe test misreads: a crate built as a hollow frame is a low rail with open space above
## it, which is indistinguishable from a stair by those two probes alone — so the player climbed
## into a waist-high crate instead of shoving it. The answer to a prop is to push it (_push_bodies),
## and getting on top of one is what jumping is for.
func _step_up(delta: float) -> void:
	if not is_on_floor():
		return
	var motion := Vector3(velocity.x, 0.0, velocity.z) * delta
	if motion.length_squared() < 0.000001:
		return
	# Several collisions, not just the first: the deepest contact against a crate's frame may well be
	# the static floor beside it, and one rigid body anywhere in the way is enough to call this off.
	var hit := KinematicCollision3D.new()
	if not test_move(global_transform, motion, hit, 0.001, false, 4):
		return   # nothing in the way
	for i in hit.get_collision_count():
		if hit.get_collider(i) is RigidBody3D:
			return
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
	# Free-fly skips _sample_water entirely, so the water state would otherwise freeze at whatever it
	# was when V was pressed — flying out of a pool and landing would leave the stair snap off.
	_in_water = false
	_submerged = false
	if _underwater != null:
		_underwater.visible = false
	_leave_water()
	print("fps_player: noclip ", "ON" if on else "OFF")
