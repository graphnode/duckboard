@tool
extends Brush

## A worked example of a BRUSH ENTITY: a Trigger Volume brush that behaves like water, floating any
## [RigidBody3D] that falls into it.
##
## It exists to show the seam. Duckboard builds the [Area3D] and stops there — it has no notion of
## water, and should not: "wet" is a game rule, and a map editor that shipped one would be shipping
## an opinion about your game. What it does ship is the volume, the exact convex shape of it, and
## [method Brush.get_body] to reach it. Everything below this line is the game's half, and it is
## about forty lines.
##
## [b]How to use it[/b]
##   1. Draw a brush and set Physics -> Trigger Volume (or Collision -> Type in the inspector).
##   2. Attach this script — NOT with "Attach Script", which REPLACES brush.gd and leaves you with a
##      node that is no longer a brush. Use Extend Script from brush.gd, or set the script on a
##      brush you created with `WaterVolume.new()`. This is the one sharp edge in the whole
##      arrangement and it catches everyone once.
##   3. Give its top face a water material and set Transparency to taste.
##
## [b]Two rules that are not optional[/b]
##   - [code]@tool[/code] on the FIRST line. [Brush] is a tool script and does its geometry work in
##     the editor; a subclass without it stops that dead, and the brush stops rebuilding as you drag
##     its vertices. Nothing warns you.
##   - [code]super()[/code] in [method _ready] and [method _notification]. Both do real work in
##     [Brush] — raising the generated subtree, keeping it in step with the transform — and an
##     override that swallows them breaks the brush silently.
##
## [b]The cheap alternative[/b]: an [Area3D] can do a version of this with no per-frame code at all.
## Set `gravity_space_override` to REPLACE and `gravity` to a small negative number in [method _ready]
## and every rigid body inside rises. Five lines instead of forty — and it gives up the two things
## worth having. It applies the same lift however deep a body is, so nothing settles: a crate rises,
## leaves the water, falls back, and bobs forever. And it applies the same lift to EVERYTHING, so a
## steel box floats exactly as well as a barrel does. Depth decides where a prop comes to rest;
## density decides whether it comes up at all.

## What this volume is made of, in kg/m³. Fresh water is 1000; make it 1025 for sea water, or wind it
## up past 13000 for the mercury pool your game presumably needs.
##
## [b]Density is the whole of it, and it is why a crate floats and a steel box does not.[/b] The lift
## on a submerged body is the weight of the water it displaces, so the sign of the result is decided
## by a ratio and nothing else: lighter per litre than the water, it rises; heavier, it sinks. Mass
## does not enter into it, which is correct — a big oak crate and a small one float the same way,
## because the big one displaces proportionally more.
@export_range(100.0, 15000.0, 5.0) var water_density := 1000.0
## Used for any prop that does not say what it is made of — see [method _density_of]. Just under
## water, so an unmarked body floats low rather than vanishing, which is the more debuggable failure.
@export_range(10.0, 15000.0, 5.0) var default_density := 800.0
## The taper from "touching the surface" to "fully under", roughly the height of the props you expect
## to float. It is what gives a stable waterline instead of a body bouncing through the surface, and
## with it a prop settles at the depth where lift and weight balance — which for oak in water is
## about half under, exactly as it should be.
@export_range(0.05, 8.0, 0.05) var float_depth := 0.6
## Water is thick. Combined with the space's own damping rather than replacing it, so a body keeps
## whatever damping it was authored with and gains this on top.
@export_range(0.0, 20.0, 0.1) var linear_damp := 2.0
@export_range(0.0, 20.0, 0.1) var angular_damp := 1.5

## Cached because it is read once per body per frame. Refreshed whenever the geometry moves — see
## _notification.
var _surface_y := 0.0


func _ready() -> void:
	super()   # REQUIRED — see the header
	if Engine.is_editor_hint():
		return

	var area := get_body() as Area3D
	if area == null:
		push_warning("water_volume: %s is not a Trigger Volume — set Physics -> Trigger Volume."
			% name)
		return
	# Damping is handed to the AREA rather than applied by hand each frame. The physics server already
	# knows how to blend it with whatever the body carries, and doing it here would mean writing
	# `linear_velocity` from script every frame, which fights the solver instead of asking it.
	area.linear_damp_space_override = Area3D.SPACE_OVERRIDE_COMBINE
	area.linear_damp = linear_damp
	area.angular_damp_space_override = Area3D.SPACE_OVERRIDE_COMBINE
	area.angular_damp = angular_damp

	_refresh_surface()
	set_physics_process(true)


## Buoyancy, applied per overlapping body.
##
## Polled rather than driven by `body_entered`, because the force depends on how deep the body is
## RIGHT NOW and that changes every frame. The signals are still the right tool for the things that
## happen once — a splash sound, a bubble particle, starting a drowning timer.
func _physics_process(_delta: float) -> void:
	var area := get_body() as Area3D
	if area == null:
		return
	var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	for node in area.get_overlapping_bodies():
		var body := node as RigidBody3D
		if body == null or body.freeze:
			continue
		# How far the body's centre sits below the surface, tapered to 0..1. Its ORIGIN, not its
		# bounding box: a prop's origin is where its author put it, which is a better stand-in for
		# its centre of buoyancy than a box that a long thin object would make nonsense of.
		var depth := _surface_y - body.global_position.y
		var submersion := clampf(depth / float_depth, 0.0, 1.0)
		if submersion <= 0.0:
			continue
		# A crate that has settled is ASLEEP, and forces on a sleeping body are discarded — so
		# without this a prop that came to rest on the bottom would never float back up.
		body.sleeping = false
		# Archimedes, with the volume cancelled out. The lift is the weight of the displaced water,
		# `water_density * volume * gravity`; the body's own weight is `body_density * volume *
		# gravity`; so expressing the lift as `mass * gravity * (water / body)` gives the same force
		# without anyone having to know what the volume IS — which is just as well, because a
		# RigidBody3D cannot tell you. Gravity is left to act normally, so the two simply compete and
		# the ratio decides who wins.
		var ratio := water_density / _density_of(body)
		body.apply_central_force(Vector3.UP * body.mass * gravity * ratio * submersion)


## What a prop is made of, in kg/m³ — checked most specific first, and the reason a crate and a steel
## box in the same pool behave differently.
##
## Four places, because there are two kinds of prop and each has two ways to be told:
##   1. a `density` PROPERTY, for a prop carrying a script — typed, exported, discoverable;
##   2. `density` in the METADATA, for one that does not — the Metadata section of any node's
##      inspector, no script and no code at all;
##   3. either of those on the body's PARENT. This is the case for a Duckboard prop, and it is not
##      optional: a rigid brush's [RigidBody3D] is generated and unowned, so it is not in the Scene
##      dock and has no inspector to put anything on. Its parent brush is the node the user actually
##      has, so that is where the marking goes — and for the Crate in tests/town.tscn it is one
##      metadata entry, `density = 400`, and nothing else;
##   4. `default_density`, so an unmarked prop still does something.
##
## Two routes and not one because the choice is real: a prop with behaviour of its own already has a
## script and an export is the better home, while a plain crate should not need one to be wooden.
func _density_of(body: RigidBody3D) -> float:
	for node in [body, body.get_parent()]:
		if node == null:
			continue
		if &"density" in node:
			return maxf(float(node.get(&"density")), 1.0)
		if node.has_meta(&"density"):
			return maxf(float(node.get_meta(&"density")), 1.0)
	return default_density


## The world height of the waterline: the highest corner of this brush's own hull.
##
## [b]This is the part only a brush editor can give you.[/b] The volume, its shape and its surface are
## one object — there is no separate "water plane" node to place, keep in step with the geometry, and
## get wrong. Reshape the brush and the waterline follows, because it IS the brush.
##
## From [method Brush.get_vertices] rather than from [method Brush.get_aabb], and the difference
## matters for exactly the brush you would build here: a trigger with every face left Empty renders
## nothing at run time, so its MESH bounds are empty and its AABB collapses to a point. The hull
## corners are the geometry itself and are there whether anything draws or not.
func _refresh_surface() -> void:
	var top := -INF
	for corner in get_vertices():
		top = maxf(top, (global_transform * corner).y)
	_surface_y = top if top > -INF else global_position.y


func _notification(what: int) -> void:
	super(what)   # REQUIRED — see the header
	if what == NOTIFICATION_TRANSFORM_CHANGED and not Engine.is_editor_hint():
		_refresh_surface()
