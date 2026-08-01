@tool
extends RefCounted
## Physics collision for brushes and groups — DERIVED, not authored.
##
## [b]A brush IS a convex hull[/b], so its collision shape is a lookup rather than a computation:
## [code]Brush.get_vertices()[/code] already returns welded hull corners, which is exactly what
## [ConvexPolygonShape3D] wants. A group goes one better — [code]members[/code] is the EXACT convex
## decomposition of a room, so its shapes are that decomposition, COARSENED: neighbouring members
## whose convex hull encloses nothing new are fused first (see [code]Csg.merge_hulls[/code]), so a
## wall built from five cuboids collides as one box rather than five. The volume is identical either
## way — only the piece count falls — and `members` itself is never touched, so the mesh, the cull and
## the occluder still see the room exactly as it was built.
##
## That is why none of Godot's own Mesh menu entries are the answer here. A trimesh
## ([ConcavePolygonShape3D]) is a hollow shell, so fast bodies tunnel through it, characters get
## pushed inside it, and a [RigidBody3D] cannot use it at all; "Create Single Convex" fills in an
## L-shaped room; "Create Multiple Convex" runs V-HACD to *guess* at a decomposition we already hold
## exactly. Worse for a group specifically: [code]_cull_surfaces()[/code] drops faces buried between
## touching members, so a trimesh built from a group's merged mesh would have holes in it. Shapes
## here come from [code]planes[/code] / [code]members[/code] and never from the mesh.
##
## [b]The nodes are real, but they are not yours and they are not saved.[/b] A solid builds its body,
## its mesh and its shapes as ordinary engine nodes when it enters the tree, and never gives them an
## [code]owner[/code]. That one omission does all the work: [PackedScene] packs only owned nodes, so
## nothing reaches the [code].tscn[/code], and the editor's Scene dock lists only nodes owned by the
## scene root, so nothing clutters the tree. They exist, they render, they collide, they are visible in
## the remote tree while running — they are simply not part of the document.
##
## The price is paid in the viewport: an unowned [VisualInstance3D] is invisible to the editor's click
## picking (it resolves a hit by walking up [code]get_owner()[/code], and an unowned node stops that
## walk dead — [code]_edit_group_[/code] does not rescue it). Duckboard raycasts brushes itself, so
## this costs nothing while the map editor is on; with it off, a brush is selectable from the Scene
## dock only. See TODO — making the toggle a UI toggle rather than a functionality toggle removes it.
##
## An earlier design made them owned, saved nodes on the theory that hiding engine functionality is
## user-hostile. In use it was worse: a level of N solids became a tree of rather more than N nodes,
## and every editing path then had to answer for them — brushes reparented under bodies, shapes
## orphaned by a delete, sub-resources shared by a duplicate, bodies left empty by a removal. Deriving
## them removes the whole class of problem, and [b]Convert to Mesh[/b] is the answer for anyone who
## wants the nodes for real: it writes exactly this tree with owners set, and hands it over for good.
##
## [b]The pose is free.[/b] The tree a solid builds is
## [code]Solid → Body → {Mesh, Shape0..ShapeN}[/code], every level of it at identity, so a shape's
## local space IS the solid's local space — which is the space [code]get_vertices()[/code] and
## [code]_member_hulls()[/code] already return. Nothing here composes a transform, and moving the solid
## moves everything under it the way the scene graph always has. With no body the mesh hangs directly
## off the solid instead; that is the only variation.

## The body a solid asks for: walls and floors (STATIC), lifts and doors driven by an
## [AnimationPlayer] or by code (ANIMATABLE), props that fall (RIGID), and volumes that notice you
## are in them without stopping you (TRIGGER — water, lava, ladders, damage zones, level exits).
##
## TRIGGER was left out of the first version on the argument that an [Area3D] needs a signal handler
## to mean anything, so offering one would be a menu entry that appears to do nothing. That was
## wrong, and it was wrong for a reason worth stating: it measured the entry by what the PLUGIN does
## with it, when the entry exists so the GAME can. A trigger brush is the oldest brush entity there
## is — Quake shipped water, lava, teleports and every `trigger_*` as exactly this, geometry you pass
## through that the game asks about — and there was no way to build one here without hand-authoring
## the node the whole derived model exists to avoid.
##
## A bare [CharacterBody3D] genuinely is inert, and stays out.
##
## RIGID is the reason the generated mesh sits UNDER the body rather than beside it. A [RigidBody3D]
## drives its own global transform, so a mesh anywhere but underneath is left behind the moment the
## body moves — which is the flaw in the obvious arrangement, and the one thing worth not copying
## from the prior art.
##
## APPENDED, never reordered. The value is what [code]collision_type[/code] serialises into a
## [code].tscn[/code], so inserting a kind in the middle would silently re-read every saved level:
## every RIGID prop in it would come back as something else.
enum Body { NONE, STATIC, ANIMATABLE, RIGID, TRIGGER }

## Body kind to engine class. A dictionary rather than a match statement so it is one edit to add a
## kind, and so [method make_body] can stay four lines.
const BODY_CLASS := {
	Body.STATIC: "StaticBody3D",
	Body.ANIMATABLE: "AnimatableBody3D",
	Body.RIGID: "RigidBody3D",
	Body.TRIGGER: "Area3D",
}

## Names for the generated nodes. They surface in the remote scene tree while the game runs and in
## the output of Convert to Mesh, so they are worth reading.
const BODY_NAME := "Body"
const MESH_NAME := "Mesh"
const OCCLUDER_NAME := "Occluder"
const SHAPE_PREFIX := "Shape"

## Two corners are the same below this SQUARED distance. Matches Csg.WELD_SQ: the points arriving
## here are polygon corners derived by clipping, so the same corner reached along two different
## faces differs by float noise, and handing the duplicate to the hull builder is pure waste.
const WELD_SQ := 1e-10

## Fewest points that can bound a volume. Below it there is no solid to collide with, and Jolt
## would log a degenerate-hull warning per shape.
const MIN_POINTS := 4


## Fully see-through by the whole-instance fade? Then it occludes nothing, whatever its faces say.
##
## [member GeometryInstance3D.transparency] above 0 makes EVERY surface on the mesh translucent at
## once — that is what the property is — so there is no face left on the solid that could honestly
## claim to stop light. Cheap and exact, and it catches the case per-face reasoning cannot: an
## opaquely textured pane of glass is opaque per face and see-through per instance.
static func faded(mesh: MeshInstance3D) -> bool:
	return mesh != null and is_instance_valid(mesh) and mesh.transparency > 0.0


## Can a solid of this kind block visibility? False for [constant Body.TRIGGER], and that is not a
## preference — it is the difference between the feature working and quietly ruining a level.
##
## A trigger is usually INVISIBLE: its faces are left Empty, which drops them from the mesh but not
## from the geometry, and the occluder is built from the geometry. So a volume you cannot see and
## walk straight through would have culled everything behind it — a damage zone across a corridor
## erasing the corridor. Occlusion is a claim that light does not get past, and the one body kind
## that exists precisely because things DO get past it can never make that claim.
##
## Asked here rather than left to the [code]occluder[/code] export because the export is the user's
## answer to "should this occlude", and this is the prior question of whether it is allowed to.
static func occludes(kind: Body) -> bool:
	return kind != Body.TRIGGER


## A body of the requested kind, configured and detached. Returns null for [constant Body.NONE],
## which is the caller's cue to hold no body at all rather than an inert one.
static func make_body(kind: Body, layer: int, mask: int) -> CollisionObject3D:
	if not BODY_CLASS.has(kind):
		return null
	var body := ClassDB.instantiate(BODY_CLASS[kind]) as CollisionObject3D
	if body == null:
		return null
	body.name = BODY_NAME
	body.collision_layer = layer
	body.collision_mask = mask
	return body


## Build or update the generated subtree under `solid`, and return the [MeshInstance3D] its geometry
## should be written to. The one call both [Brush] and [BrushGroup] make — they are unrelated classes,
## so anything they share has to live here or be written twice.
##
## Idempotent, and cheap when nothing changed: an existing mesh node is kept (so the [ArrayMesh] and
## any forwarded properties on it survive), an existing body of the right class is kept, and only a
## CHANGE of body kind frees and rebuilds one. The mesh is re-parented, never re-made — losing it on a
## body swap would drop a frame of rendering and every property mirrored onto it.
##
## Nothing here is given an `owner`; see the file header for why, and [method claim] for the one place
## that changes.
static func ensure_tree(solid: Node3D, kind: Body, layer: int, mask: int,
		occlude := false) -> MeshInstance3D:
	var mesh_node: MeshInstance3D = null
	var occluder: OccluderInstance3D = null
	# THROUGH body_of, not a walk of its own. The two used to each carry their own rule and they
	# disagreed — this one kept the LAST CollisionObject3D child it saw, body_of returned the FIRST —
	# so with two of them the body a caller was handed to configure was not the body being kept.
	# There is meant to be one, but "meant to be" is what a shared answer is for.
	var body: CollisionObject3D = body_of(solid)
	# Found by walking rather than by a cached reference: this has to survive the node being
	# duplicated, re-entering the tree, or reloading, none of which carry a plain `var` across.
	#
	# OccluderInstance3D is checked FIRST because it is a VisualInstance3D but not a MeshInstance3D —
	# the order only matters for readability, but getting it backwards on a future subclass would
	# quietly make the occluder answer as the mesh.
	for child in solid.get_children():
		if child is OccluderInstance3D:
			occluder = child as OccluderInstance3D
		elif child is MeshInstance3D:
			mesh_node = child as MeshInstance3D
	if body != null:
		for inner in body.get_children():
			if inner is OccluderInstance3D:
				occluder = inner as OccluderInstance3D
			elif inner is MeshInstance3D:
				mesh_node = inner as MeshInstance3D

	# A TRIGGER NEVER OCCLUDES, whatever the export says — see [method occludes].
	occlude = occlude and occludes(kind)

	var wanted: String = BODY_CLASS.get(kind, "")
	if body != null and body.get_class() != wanted:
		# Rescue the mesh and the occluder before the body takes them down as its children.
		if mesh_node != null and mesh_node.get_parent() == body:
			body.remove_child(mesh_node)
		if occluder != null and occluder.get_parent() == body:
			body.remove_child(occluder)
		solid.remove_child(body)
		body.free()
		body = null
	if body == null and wanted != "":
		body = make_body(kind, layer, mask)
		if body != null:
			solid.add_child(body)
	if body != null:
		# Layer and mask are cheap to restate and this is the only place that owns them, so there is
		# no separate path to keep in step when either export changes.
		body.collision_layer = layer
		body.collision_mask = mask

	if mesh_node == null:
		mesh_node = MeshInstance3D.new()
		mesh_node.name = MESH_NAME
	var home: Node = body if body != null else solid
	if mesh_node.get_parent() != home:
		if mesh_node.get_parent() != null:
			mesh_node.get_parent().remove_child(mesh_node)
		home.add_child(mesh_node)

	# The occluder rides with the mesh rather than with the solid, so a RigidBody3D carries its
	# occlusion as it tumbles instead of leaving it behind at the spawn pose.
	if occlude and occluder == null:
		occluder = OccluderInstance3D.new()
		occluder.name = OCCLUDER_NAME
	elif not occlude and occluder != null:
		# The parent CAN be null here, and the case is not exotic: a change of body kind above has
		# already rescued the occluder out of the old body, leaving it orphaned. Both happen in the
		# same call whenever a solid is set to TRIGGER — the body becomes an Area3D and `occlude` is
		# forced false — which made that one change abort ensure_tree and hand the caller a null mesh.
		# Guarded exactly as the mesh is a few lines above; the asymmetry was the whole bug.
		if occluder.get_parent() != null:
			occluder.get_parent().remove_child(occluder)
		occluder.free()
		occluder = null
	if occluder != null and occluder.get_parent() != home:
		if occluder.get_parent() != null:
			occluder.get_parent().remove_child(occluder)
		home.add_child(occluder)
	return mesh_node


## Bring `body`'s shapes in line with `hulls` — the one entry point a solid calls when its geometry
## changed. `hulls` is one local-space point cloud per convex piece: a brush hands over one, a group
## one per piece of its merged decomposition (which is at most one per member, and usually fewer).
##
## Shapes are grown and shrunk in place rather than torn down and rebuilt, so a body never spends a
## frame with the wrong number of them, and the physics server is never handed an empty hull (which
## logs "Failed to build convex hull" once per shape).
##
## Deliberately outside UndoRedo, and it has no undo problem to solve: nothing written here is saved,
## and it is all derived from `planes` / `members`, which are what the undo record actually holds.
## Undoing an edit re-runs the setter, which re-runs this, and reproduces the shapes exactly.
static func fit(body: CollisionObject3D, hulls: Array) -> void:
	if body == null:
		return
	var shapes: Array[CollisionShape3D] = []
	for child in body.get_children():
		if child is CollisionShape3D:
			shapes.append(child as CollisionShape3D)

	# A momentarily degenerate solid — mid-drag, or a hull that collapsed — keeps the shapes it has
	# rather than losing collision for a frame and getting it back.
	if hulls.is_empty():
		return

	while shapes.size() > hulls.size():
		var extra: CollisionShape3D = shapes.pop_back()
		body.remove_child(extra)
		# Freed rather than queued: a replacement made in the same frame would otherwise overlap the
		# shape it replaces and the body would briefly collide twice.
		extra.free()
	while shapes.size() < hulls.size():
		var made := CollisionShape3D.new()
		made.name = "%s%d" % [SHAPE_PREFIX, shapes.size()]
		body.add_child(made)
		shapes.append(made)

	for i in shapes.size():
		var points := weld(hulls[i])
		if points.size() < MIN_POINTS:
			continue          # a degenerate piece bounds no volume; leave the last good hull in place
		var convex := shapes[i].shape as ConvexPolygonShape3D
		if convex == null:
			# Built complete and only then assigned, so the physics server never sees zero points.
			convex = ConvexPolygonShape3D.new()
			convex.points = points
			shapes[i].shape = convex
			continue
		# Cheap guard against pointless writes: this runs on every rebuild, and re-assigning an
		# identical point array dirties the resource for nothing.
		if convex.points != points:
			convex.points = points


## Fill `solid`'s occluder from its face polygons, or do nothing when it has none.
##
## A brush is the ideal occluder and needs no baking to become one: it is already a closed, convex,
## low-polygon solid, which is exactly what [OccluderInstance3D] wants and exactly what Godot's
## "Bake Occluders" step spends its time trying to approximate from arbitrary art. The polygons here
## are the same ones the mesh is built from, so the occluder can never describe a shape the level
## does not actually have.
##
## [b]Occlusion culling has to be switched on to do anything[/b] — Project Settings →
## Rendering → Occlusion Culling → Use Occlusion Culling. Off (the default), these nodes are built and
## simply never consulted. Duckboard does not turn it on: it is a project-wide rendering decision with
## a CPU cost of its own, and making it silently on the user's behalf would be exactly the kind of
## hidden behaviour this design exists to avoid.
##
## A FRESH [ArrayOccluder3D] every time, never an in-place edit. [code]Node.duplicate()[/code] shares
## sub-resources, so mutating one would rewrite the original's occluder the way it once rewrote the
## original's collision hull — see [method reset]. Geometry changes are not a per-frame event, so the
## allocation is cheap insurance.
static func fit_occluder(solid: Node3D, polygons: Array) -> void:
	var node := occluder_of(solid)
	if node == null:
		return
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for entry in polygons:
		var poly: PackedVector3Array = entry
		if poly.size() < 3:
			continue
		var base := verts.size()
		verts.append_array(poly)
		# The same fan, and the same reversal, the mesh bake uses — so the occluder's triangles face
		# the way the rendered ones do rather than presenting their backs to the camera.
		for i in range(1, poly.size() - 1):
			idx.append(base)
			idx.append(base + i + 1)
			idx.append(base + i)
	if verts.size() < 3 or idx.is_empty():
		node.occluder = null
		return
	var built := ArrayOccluder3D.new()
	built.set_arrays(verts, idx)
	node.occluder = built


## The [CollisionObject3D] a solid generated for itself, or null when its type is [constant
## Body.NONE]. Found by walking, for the same reason [method ensure_tree] walks.
##
## Public because a derived body is otherwise UNREACHABLE. It is unowned, so it is not in the Scene
## dock and has no inspector — which is the whole bargain, and it means the dozen properties Duckboard
## does not forward (a [RigidBody3D]'s mass and gravity scale, a [StaticBody3D]'s
## [PhysicsMaterial], an [Area3D]'s gravity and damping overrides and its two entered/exited signals)
## have nowhere to be set from. This is where: reach it from an `extends Brush` subclass in `_ready`
## and configure it in code, which is the same place the rest of a brush entity's behaviour belongs.
##
## Deliberately not a forwarded property list like the rendering ones. Those five are properties a
## LEVEL DESIGNER sets on geometry; these are per-body-class and mostly per-game, and mirroring four
## classes' worth of them into every brush's inspector would swap a real gap for a much worse one.
##
## [codeblock]
## @tool
## extends Brush
##
## func _ready() -> void:
##     super()                                   # required, or the brush stops building itself
##     if Engine.is_editor_hint():
##         return
##     var area := get_body() as Area3D          # collision_type must be TRIGGER
##     if area != null:
##         area.body_entered.connect(_on_entered)
## [/codeblock]
##
## The FIRST collision child wins, and [method ensure_tree] adopts the same one by calling this — a
## solid is only ever built with one, and the two answering differently is a bug that has already
## happened once.
static func body_of(solid: Node) -> CollisionObject3D:
	for child in solid.get_children():
		if child is CollisionObject3D:
			return child as CollisionObject3D
	return null


## The [OccluderInstance3D] a solid generated for itself, or null. Found by walking, for the same
## reason [method ensure_tree] walks: no cached reference survives a duplicate or a reload.
static func occluder_of(solid: Node3D) -> OccluderInstance3D:
	for child in solid.get_children():
		if child is OccluderInstance3D:
			return child as OccluderInstance3D
		if child is CollisionObject3D:
			for inner in child.get_children():
				if inner is OccluderInstance3D:
					return inner as OccluderInstance3D
	return null


## Tear the generated subtree off `solid` so the next [method ensure_tree] builds it from scratch.
##
## For DUPLICATES, and it is not optional. [code]Node.duplicate()[/code] copies children — so a copied
## solid arrives with a body, a mesh and shapes of its own — but it SHARES sub-resources, so the
## copy's [ConvexPolygonShape3D] is the very same resource as the original's. Reshaping either one
## then rewrites the other's collision while its geometry stays put: verified, and silent.
##
## Rebuilding is the fix rather than deep-copying, because every one of these nodes is derived. There
## is nothing on them worth carrying across that is not already re-derived from `planes` / `members`
## and the three collision exports, all of which [code]duplicate()[/code] copies properly.
##
## The MESH is rescued rather than dropped, and only the body goes. Two reasons: the forwarded
## rendering properties live on that node, so freeing it would lose the `material_override` a copy is
## entitled to inherit; and its [ArrayMesh] is re-derived by the `planes` / `members` setter that
## [code]duplicate()[/code] runs anyway, so it is never the shared one. The shapes are the only
## genuinely shared resources, and they go with the body that holds them.
##
## Matches exactly what [method ensure_tree] would claim, so the two cannot disagree about which
## children are Duckboard's — a user's own child node is left alone.
static func reset(solid: Node) -> void:
	var mesh_node: MeshInstance3D = null
	var bodies: Array[Node] = []
	var occluders: Array[Node] = []
	for child in solid.get_children():
		if child is OccluderInstance3D:
			occluders.append(child)
		elif child is MeshInstance3D:
			mesh_node = child as MeshInstance3D
		elif child is CollisionObject3D:
			bodies.append(child)
			for inner in child.get_children():
				if inner is OccluderInstance3D:
					occluders.append(inner)
				elif inner is MeshInstance3D:
					mesh_node = inner as MeshInstance3D
	# Lifted clear before the body is freed, or it would be taken down as a child of it.
	if mesh_node != null and mesh_node.get_parent() != solid:
		mesh_node.get_parent().remove_child(mesh_node)
		solid.add_child(mesh_node)
	# The occluder is NOT rescued: its ArrayOccluder3D is a shared sub-resource on a copy, exactly as
	# the collision hull is, and it is rebuilt from the geometry a moment later anyway.
	for node in occluders:
		node.get_parent().remove_child(node)
		node.free()
	for body in bodies:
		solid.remove_child(body)
		body.free()


# --- Forwarded rendering properties ---------------------------------------
#
# A solid used to BE a MeshInstance3D, so these lived on it: they showed in the inspector and saved
# with the scene. The mesh is a generated, unowned child now — which PackedScene does not pack — so
# without forwarding, a user's material override would vanish the moment they saved. [Brush] and
# [BrushGroup] are unrelated classes with no shared base, so the machinery lives here and each of
# them delegates its _get / _set / _get_property_list to it.

## The properties worth keeping reachable on the solid itself. Deliberately CLOSED — everything else
## on the mesh is reached through the solid's [code]get_mesh_instance()[/code]. `material_overlay` is
## excluded on purpose: it is the editor grid, owned by the solid's own _apply_grid_overlay, and a
## user writing to it would simply be overwritten on the next rebuild.
const FORWARDED := [&"material_override", &"cast_shadow", &"layers", &"gi_mode", &"transparency"]

## Property metadata and defaults, lifted from a real [MeshInstance3D] once and cached. Copied from
## the engine rather than hand-written, so the inspector gets the exact hints it would otherwise have
## — `cast_shadow` as its enum, `layers` as the render-layer grid — and none of it can fall out of
## step with a future Godot that changes a default.
static var _forward_meta: Array[Dictionary] = []
static var _forward_defaults := {}


static func _forward_cache() -> void:
	if not _forward_meta.is_empty():
		return
	var probe := MeshInstance3D.new()
	for entry in probe.get_property_list():
		if entry["name"] in FORWARDED:
			_forward_meta.append(entry.duplicate())
			_forward_defaults[entry["name"]] = probe.get(entry["name"])
	probe.free()


static func is_forwarded(property: StringName) -> bool:
	return property in FORWARDED


static func forward_default(property: StringName) -> Variant:
	_forward_cache()
	return _forward_defaults.get(property)


## The forwarded properties as a property list, declared with STORAGE only while one is actually SET.
##
## [PackedScene] does not consult [code]_property_get_revert[/code] for properties that arrive this
## way — it stores whatever carries the STORAGE flag — so every solid would otherwise serialise
## [code]layers = 1[/code], [code]gi_mode = 1[/code], [code]cast_shadow = 1[/code],
## [code]transparency = 0.0[/code] and a null [code]material_override[/code]: five lines of nothing,
## on every brush in a level. Dropping the flag at the default value is what the engine does for its
## own properties, and this reproduces it.
##
## `mesh` may be null — the inspector queries the property list constantly, and answering must never
## be a reason to raise the subtree. Nothing built yet means nothing set yet, which is the default.
static func forward_list(mesh: MeshInstance3D) -> Array[Dictionary]:
	_forward_cache()
	var out: Array[Dictionary] = []
	# NO group header of its own. The solid's script opens a "Visual" fold on its `occluder` export and
	# leaves it open, and this list is appended straight after the script's own — so these land inside
	# that fold. Emitting a second "Visual" marker here would split the inspector into two folds with
	# the same name. The fold matters: the render layers below must not read as the physics layers in
	# the Collision fold, and Godot calls both of them "Layers".
	for entry in _forward_meta:
		var copy := entry.duplicate()
		var key: StringName = copy["name"]
		var current: Variant = _forward_defaults[key]
		if mesh != null and is_instance_valid(mesh):
			current = mesh.get(key)
		copy["usage"] = PROPERTY_USAGE_EDITOR if current == _forward_defaults[key] \
				else PROPERTY_USAGE_DEFAULT
		out.append(copy)
	return out


## Hand a generated subtree over to the document — give every node an `owner` so it serialises and
## shows in the Scene dock. The single line that turns Duckboard's private nodes into the user's, and
## the reason Convert to Mesh and the export plugin can share one builder with the live path.
static func claim(node: Node, owner: Node) -> void:
	node.owner = owner
	for child in node.get_children():
		claim(child, owner)


## Collapse points that are the same corner reached along different faces. The hull builder tolerates
## duplicates, but every one is a point it re-tests against the hull for no gain.
static func weld(points: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p in points:
		var seen := false
		for kept in out:
			if kept.distance_squared_to(p) < WELD_SQ:
				seen = true
				break
		if not seen:
			out.append(p)
	return out
