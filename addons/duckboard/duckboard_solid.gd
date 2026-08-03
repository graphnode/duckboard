@tool
class_name DuckboardSolid
extends Node3D
## What a [Brush] IS underneath: a [Node3D] that DERIVES a renderable, collidable subtree from
## geometry it owns, and lends that subtree its own inspector.
##
## Neither class is a [MeshInstance3D]. Each builds one — together with the body named by
## [member collision_type] and a shape per convex piece — as unowned children that are never
## serialized (see collision.gd). Everything that arrangement implies, and that therefore cannot
## differ between the two, lives here: the collision and visual exports, the property forwarding that
## keeps the generated mesh's settings reachable on the node the scene actually saves, the editor
## grid overlay's on/off switch, and the two maintenance buttons.
##
## [b]It deliberately does NOT hold the geometry.[/b] A brush is ONE convex solid stored as planes; a
## group is N solids stored as face payloads. Those are different representations on purpose — planes
## are the editable primitive that makes convexity true by construction, face payloads are the
## serialization that carries per-face UV and material — so each subclass keeps its own and fills in
## the hooks at the bottom of this file.
##
## [b]Not a user-facing type.[/b] Tools test [code]node is Brush[/code], never this. It was the shared
## base that kept a brush and a group from drifting; those are one class now, so this is simply the
## generated-subtree half of a solid, split out. A user extending Duckboard writes
## [code]extends Brush[/code].

## Raises and maintains the generated subtree — mesh, body, shapes, occluder. Preloaded rather than
## reached through the plugin: a solid must work as a plain runtime node with no EditorPlugin in the
## tree, and one reshaped by a game script has to take its collision with it.
const Collision := preload("res://addons/duckboard/collision.gd")
## Packs the second UV set when [member lightmap_uv2] asks for one. Preloaded for the same reason.
const Lightmap := preload("res://addons/duckboard/lightmap.gd")
## The world-space grid, attached as a material_overlay in the editor only, so it never touches the
## base material and never ships. Each subclass applies it — see [method _apply_grid_overlay].
const GRID_SHADER := preload("res://addons/duckboard/shaders/brush_grid.gdshader")

## Escape hatch for the one risk a persisted mesh carries: if a mesh ever does go stale (a bug, a
## hand-edited [code].tscn[/code], a scene saved by an older version), this rebuilds it from the
## geometry without having to nudge a property to fire a setter. Takes no input and cannot produce a
## shape that isn't one, which is why it earns a button where the geometry itself does not.
@export_tool_button("Rebuild Mesh", "Reload") var rebuild_action := rebuild_mesh

## Pull the origin back into the geometry by hand. The plugin already does this when a group is
## closed, so this is for a solid that drifted before that existed, or one moved by other means.
@export_tool_button("Recenter Origin", "ToolMove") var recenter_action := recenter

## [b]The way OUT of Duckboard.[/b] Replaces this solid with the plain engine nodes it has been
## deriving all along — mesh, body, shapes and occluder — owned this time, so they save in the
## [code].tscn[/code], show in the Scene dock, and keep working with the addon deleted.
##
## One-way: the planes (or members), the per-face UV axes and the textures-as-data all go, because
## plain nodes have nowhere to keep them. It is a normal undo step, so Ctrl+Z brings the solid back
## in the same session — but once the scene is saved over, the geometry is a mesh and that is that.
## Save As first if the editable version is worth keeping.
##
## Deliberately NOT called "Bake". The project's whole pitch is that there is no bake step, and this
## is an exit rather than a step anyone must take.
@export_tool_button("Convert to Mesh", "MeshInstance3D") var convert_action := _request_convert_to_mesh

## What this solid collides as — or [code]NONE[/code] for geometry you walk through.
##
## Stating a body here BUILDS one: a [CollisionObject3D] of the matching class as a child, holding
## the generated [MeshInstance3D] and one [ConvexPolygonShape3D] per convex piece. The nodes are real
## — they render, they collide, they appear in the remote scene tree of a running game — but they are
## never given an `owner`, so they are neither saved in the [code].tscn[/code] nor listed in the Scene
## dock. The level stays one node per solid; the physics is derived from these three properties every
## time the solid enters a tree. See collision.gd.
##
## STATIC by default, because a level is walls and floors and the alternative is a map you fall
## through until you notice. Set it to NONE for trim, decals and decoration.
##
## TRIGGER is the one that does not stop you: it builds an [Area3D], so the solid is walked straight
## through while the game can ask whether you are inside it. That is what water, lava, ladder volumes,
## damage zones and level exits have always been in a brush map, and it is the one body kind whose
## MEANING lives in your code rather than here — Duckboard builds the volume and stops. Both the
## signal route ([code]body_entered[/code]) and the query route ([code]intersect_point[/code] with
## [code]collide_with_areas[/code]) work on it unchanged, because it is an ordinary [Area3D] with
## ordinary defaults. Note that a face still needs a texture to render: a trigger you do not want to
## SEE is one whose faces are left Empty.
##
## A group's shapes are its MEMBERS, coarsened — which makes a group the best case for this design
## rather than the worst, since `members` is already the room's exact convex decomposition. Adjacent
## members whose hull encloses nothing new are fused first, so a wall of five cuboids collides as one
## box; the volume is unchanged, only the piece count. No V-HACD guess, no hollow trimesh for a
## character to be pushed inside.
##
## Exported, unlike the grid size and the texture/UV lock modes. Those are palette state pushed to
## every solid at once, so storing them is storing a copy of a global and letting nodes drift out of
## step with it. These are the opposite: a statement about what THIS solid is for, which nothing else
## could reconstruct.
##
## Grouped and prefix-stripped exactly as [CollisionObject3D] does it, so the inspector shows a
## [b]Collision[/b] fold containing Type, Layer and Mask — the same place, and the same names, a user
## already looks for them on any other physics node. The prefix is what turns `collision_layer` into
## a field labelled "Layer"; it is stripped from the label only, never from the property.
@export_group("Collision", "collision_")

@export var collision_type: Collision.Body = Collision.Body.STATIC:
	set(value):
		if collision_type == value:
			return
		collision_type = value
		_sync_derived()
		# The type decides whether `occluder` applies, so the inspector has to re-ask — otherwise the
		# checkbox stays live-looking until the node is reselected. See _validate_property.
		notify_property_list_changed()

## Physics layers the generated body occupies. Forwarded straight onto it, so the usual layer/mask
## reasoning applies with no Duckboard-specific rules.
@export_flags_3d_physics var collision_layer := 1:
	set(value):
		collision_layer = value
		_sync_derived()

## Physics layers the generated body scans. See [member collision_layer].
@export_flags_3d_physics var collision_mask := 1:
	set(value):
		collision_mask = value
		_sync_derived()

## Whether this solid also generates an [OccluderInstance3D] — geometry that HIDES what is behind it,
## so the renderer can skip drawing it.
##
## On by default, because a brush is the ideal occluder and costs nothing to make one: it is already a
## closed, convex, low-polygon solid, which is precisely what Godot's "Bake Occluders" step spends its
## time trying to approximate from arbitrary art. Level geometry is what occludes in a level, so the
## useful default is the one that needs no thought. Turn it off for glass, railings, grates, trim —
## anything you can see through, where claiming to block the view would cull things that should still
## be visible.
##
## [b]Occlusion culling has to be enabled project-wide before any of this does anything[/b]: Project
## Settings → Rendering → Occlusion Culling → Use Occlusion Culling. Duckboard will not switch it on
## for you; it is a rendering decision with a CPU cost of its own.
##
## Ignored, and shown greyed, while [member collision_type] is TRIGGER — a volume that exists to be
## passed through cannot claim to block the view. See [code]Collision.occludes[/code].
##
## Opens the Visual fold, which the forwarded rendering properties then join — see
## [code]Collision.forward_list[/code]. [b]Kept last among the exports for that reason[/b]: the
## forwarded list is appended after this script's own properties, so anything declared below it would
## come between the fold and its contents.
@export_group("Visual")

@export var occluder := true:
	set(value):
		if occluder == value:
			return
		occluder = value
		_sync_derived()

## Generate the second UV set [LightmapGI] bakes into. Off by default: it is a second UV per vertex
## on every solid in the level, which is dead weight unless something is actually lightmapping them.
##
## [b]There is no bake step and nothing to press.[/b] A face is already flat, so there is nothing to
## unwrap — only to pack — and packing is cheap and deterministic enough to happen inside the ordinary
## mesh build. Turn this on and the UV2 is simply there, in the editor and in the running game, and it
## is rebuilt with the geometry so it can never go stale. See lightmap.gd.
##
## Edit it on a multi-selection to set a whole level at once; the inspector applies the change to
## every selected solid.
@export var lightmap_uv2 := false:
	set(value):
		if lightmap_uv2 == value:
			return
		lightmap_uv2 = value
		_rebake_mesh()

## World size of one lightmap texel, in metres. Smaller is sharper and costs atlas area — 0.25 is
## about one texel per 8 TrenchBroom units.
##
## The same value on every solid is what keeps lightmap density even across a level: a chart is
## measured in texels, so a large wall gets proportionally more of the atlas than a small one instead
## of both being squeezed into the same square.
@export_range(0.01, 4.0, 0.01, "or_greater") var lightmap_texel_size := 0.25:
	set(value):
		value = maxf(value, 0.01)
		if is_equal_approx(lightmap_texel_size, value):
			return
		lightmap_texel_size = value
		if lightmap_uv2:
			_rebake_mesh()

## The [MeshInstance3D] this solid renders through — a generated, unowned child. Cached for the hot
## paths; [method get_mesh_instance] raises it again if it has gone.
##
## No `_saved_mesh` counterpart is needed. The mesh used to be parked across a save to keep a derived
## [ArrayMesh] out of the [code].tscn[/code]; now it hangs off a node with no `owner`, so it cannot be
## serialized in the first place.
var _mesh: MeshInstance3D

## The editor grid overlay material, kept so its cell size can be updated without rebuilding it.
var _grid_material: ShaderMaterial

## Whether the face grid overlay is currently shown. The map editor is the thing the grid serves, so
## the plugin hides it when Duckboard is toggled off, leaving plain textured geometry. Runtime-only
## editor state — not exported — reconciled by the plugin on toggle and on scene change; kept as a
## flag so a rebuild while off doesn't restore the grid.
var _grid_overlay_enabled := true


func get_mesh_instance() -> MeshInstance3D:
	if _mesh == null or not is_instance_valid(_mesh):
		_mesh = Collision.ensure_tree(self, collision_type, collision_layer, collision_mask)
	return _mesh


## The generated [CollisionObject3D] — the [StaticBody3D], [AnimatableBody3D], [RigidBody3D] or
## [Area3D] named by [member collision_type] — or null when that is NONE.
##
## The extension point for everything Duckboard deliberately does not decide: a rigid solid's mass, a
## static one's [PhysicsMaterial], a trigger's gravity override and its `body_entered` signal. The
## node is unowned and so has no inspector of its own; an `extends Brush` subclass reaching it in
## `_ready` (after `super()`) is the supported way to configure it. See [method Collision.body_of].
func get_body() -> CollisionObject3D:
	return Collision.body_of(self)


## The plugin flips this when the map editor is toggled: off hides the face grid so a disabled
## Duckboard leaves plain textured geometry, on brings it back.
func set_grid_overlay_enabled(enabled: bool) -> void:
	if _grid_overlay_enabled == enabled:
		return
	_grid_overlay_enabled = enabled
	_apply_grid_overlay()


# --- Forwarded rendering properties ---------------------------------------
#
# `material_override`, `cast_shadow`, `layers`, `gi_mode` and `transparency` still live on the solid,
# so they show in the inspector, save with the scene, and answer to `brush.material_override = x`
# from a script — but there is no backing field, and every one of them reads and writes the generated
# MeshInstance3D. collision.gd holds the list and the metadata; see there for why the storage flag is
# dynamic.

func _get_property_list() -> Array[Dictionary]:
	# _mesh rather than get_mesh_instance(): the inspector queries this constantly, and answering a
	# property listing has no business raising the subtree.
	return Collision.forward_list(_mesh)


## Grey out `occluder` on a trigger, where it is ignored (see [code]Collision.occludes[/code]).
##
## READ_ONLY and not hidden. A property that disappears reads as a bug in the plugin — the user looks
## for the setting they used yesterday and it is gone. One that is visible and greyed says the thing
## that is actually true: it is still yours, it does not apply to this.
func _validate_property(property: Dictionary) -> void:
	if property.name == &"occluder" and not Collision.occludes(collision_type):
		property.usage |= PROPERTY_USAGE_READ_ONLY


func _get(property: StringName) -> Variant:
	if Collision.is_forwarded(property):
		return get_mesh_instance().get(property)
	return null


func _set(property: StringName, value: Variant) -> bool:
	if Collision.is_forwarded(property):
		# Reached during deserialization too, while the solid is still out of the tree — which is
		# exactly when the mesh instance has to be raised, so get_mesh_instance() rather than _mesh.
		get_mesh_instance().set(property, value)
		# `transparency` is the one forwarded property that changes what the solid IS rather than how
		# it looks: above 0 the whole mesh is see-through and its occluder becomes a lie. None of the
		# other four can invalidate the subtree, so only this one pays for a re-sync.
		if property == &"transparency":
			_sync_derived()
		return true
	return false


func _property_can_revert(property: StringName) -> bool:
	return Collision.is_forwarded(property)


func _property_get_revert(property: StringName) -> Variant:
	return Collision.forward_default(property)


## This solid's world-space bounds, from the mesh it renders through. Kept as a method on the solid
## because both were a [MeshInstance3D] until recently and callers still ask.
func get_aabb() -> AABB:
	return get_mesh_instance().get_aabb()


# Per-surface material overrides, forwarded. [member material_override] arrives through the property
# forward in collision.gd, but these are METHODS and a property forward cannot carry them.
#
# Forwarded rather than left to callers to redirect, because an undo record naming
# `set_surface_override_material` has to name a node that SURVIVES: the mesh instance is generated and
# rebuilt, so an entry pointing at it would come back on undo aimed at a node that no longer exists.
# Pointing it at the solid keeps the record on the saved node and lets the call find whatever mesh is
# current when it runs.

func get_surface_override_material_count() -> int:
	return get_mesh_instance().get_surface_override_material_count()


func get_surface_override_material(surface: int) -> Material:
	return get_mesh_instance().get_surface_override_material(surface)


func set_surface_override_material(surface: int, material: Material) -> void:
	get_mesh_instance().set_surface_override_material(surface, material)


# --- Convert to Mesh ------------------------------------------------------

## This solid as plain engine nodes: a fresh, DETACHED tree the caller parents and claims.
##
## [b]It copies the derived subtree rather than rebuilding one[/b], which is the whole reason this is
## short. A solid already maintains exactly the tree that should be handed over —
## [code]Body → {Mesh, Occluder, Shape0..N}[/code], every level at identity (see collision.gd) — so
## the transformation is a duplicate, three fixes, and an owner. Nothing here re-derives geometry, so
## there is no second implementation to drift out of step with the live one.
##
## The root absorbs the solid's own name and transform, since it takes the solid's place. What it IS
## depends on what there is to keep: the body when there is one (a StaticBody3D holding the mesh is
## the natural shape of a collidable piece of level), the mesh alone when there is neither body nor
## occluder, and a bare [Node3D] to hold the two together in the remaining case.
##
## Static, and taking the solid as an argument, because [b]the export plugin is the second caller[/b].
## Stripping a scene at export time and ejecting one in the editor have to produce the same nodes, and
## the only way to be sure of that is for there to be one builder.
static func to_plain_nodes(solid: DuckboardSolid) -> Node3D:
	if solid == null or not is_instance_valid(solid):
		return null
	# What gets copied has to be current: a solid whose exports changed since its last rebuild still
	# has the old subtree hanging off it, and this is not the place to discover that.
	solid._sync_derived()
	var mesh_src := solid.get_mesh_instance()
	if mesh_src == null:
		return null
	var body_src := solid.get_body()
	var occluder_src := Collision.occluder_of(solid)

	var root: Node3D
	if body_src != null:
		root = body_src.duplicate() as Node3D          # brings mesh, shapes and occluder with it
	elif occluder_src == null:
		root = mesh_src.duplicate() as Node3D
	else:
		# No body, but an occluder to keep: neither child can host the other, so they need a parent.
		root = Node3D.new()
		root.add_child(mesh_src.duplicate())
		root.add_child(occluder_src.duplicate())
	if root == null:
		return null
	root.name = solid.name
	root.transform = solid.transform

	# The editor grid is a second pass added only while Duckboard is running, and it is the one thing
	# on the copied mesh that must not survive: shipped geometry wearing an editor overlay is a bug
	# that renders. NOTHING else about the mesh node is touched — the forwarded rendering properties,
	# the surface overrides and the ArrayMesh all came across with the duplicate and are already right.
	for node in _walk(root):
		if node is MeshInstance3D:
			(node as MeshInstance3D).material_overlay = null
		# Node.duplicate() SHARES sub-resources, and Collision.fit writes a shape's points in place —
		# so a converted shape left sharing with the original would be silently rewritten the next
		# time that original is edited, which it can be: undo puts it back. The mesh and the occluder
		# need no such care, both being replaced wholesale on every rebuild rather than mutated.
		elif node is CollisionShape3D:
			var shape := node as CollisionShape3D
			if shape.shape != null:
				shape.shape = shape.shape.duplicate()
	return root


## Every node in `root`'s subtree, `root` included.
static func _walk(root: Node) -> Array[Node]:
	var out: Array[Node] = [root]
	for child in root.get_children():
		out.append_array(_walk(child))
	return out


## Hand the editor's inspector off the nodes an action is about to REMOVE and onto `next`, the node
## replacing them. Called immediately before the commit by every path that swaps live solids for new
## ones — Group, Ungroup, CSG, .map paste and Convert to Mesh.
##
## [b]Clearing the selection is only half of it, and not the half that matters.[/b] With more than one
## node selected the editor is not inspecting the nodes at all: it is inspecting a [MultiNodeEdit]
## that addresses them by NODE PATH, and that object is held by the editor's inspector HISTORY, which
## the selection does not reach. [code]inspect_object(null)[/code] does not reach it either — the
## engine returns early on a null object and leaves the history exactly as it was. So the stale
## MultiNodeEdit stays current, and the next time anything makes the editor re-read what it is
## inspecting, it resolves every one of those paths against the scene root and logs a "Node not found"
## per node the action legitimately removed — then re-selects whichever ones DID resolve, which asks
## the same question again, three times over before it settles.
##
## Handing it a REAL node ends it at the source: the current object is no longer a MultiNodeEdit, so
## the branch that resolves paths is never entered. `next` is normally still off-tree here, which the
## editor handles (it inspects the node and skips the docks that need it parented), and it is the node
## the caller selects a moment later anyway — so this costs nothing and lands where it was going.
##
## Editor-only, like everything it touches. A static rather than a host method because a solid cannot
## reach the plugin, and two copies of a precaution is how one of them goes stale.
static func hand_inspector_over(next: Node) -> void:
	EditorInterface.get_selection().clear()
	if next != null:
		EditorInterface.edit_node(next)


## What the Convert to Mesh button actually calls — one hop, and the hop is the point.
##
## A tool button invokes its Callable from inside its own `pressed` emission, and the conversion hands
## the inspector over to the replacement ([method hand_inspector_over]), which rebuilds the inspector —
## freeing the very Button that is mid-signal. The engine says so out loud: "Object was freed or
## unreferenced while a signal is being emitted from it". Deferring puts the whole operation on the
## next idle frame, once the emission is over, which is exactly what that error asks for.
##
## Only this button needs it. Rebuild Mesh and Recenter Origin change property VALUES, which the
## inspector re-reads in place; nothing else here replaces the object being inspected.
func _request_convert_to_mesh() -> void:
	convert_to_mesh.call_deferred()


## Backs the Convert to Mesh button: does [method to_plain_nodes] to the LIVE scene, as one undo step.
## Safe to call directly from code — the deferral above belongs to the button, not to the operation.
func convert_to_mesh() -> void:
	if not Engine.is_editor_hint():
		push_warning("Duckboard: Convert to Mesh is an editor action and does nothing at run time.")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var parent := get_parent()
	if scene_root == null or parent == null or not is_inside_tree():
		return
	if self == scene_root:
		# Replacing the root would re-root the scene, which is a different operation with different
		# consequences (the .tscn's type changes) and is not what a button on a node should do.
		push_warning("Duckboard: Convert to Mesh cannot replace the scene root. "
			+ "Move this solid under a parent first.")
		return
	var replacement := to_plain_nodes(self)
	if replacement == null:
		push_warning("Duckboard: Convert to Mesh found no mesh to hand over — is this solid empty?")
		return

	var index := get_index()
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Convert to Mesh")
	ur.add_do_method(parent, "remove_child", self)
	ur.add_do_method(self, "_adopt", parent, replacement, index, scene_root)
	ur.add_do_reference(replacement)
	ur.add_undo_method(parent, "remove_child", replacement)
	ur.add_undo_method(parent, "add_child", self, true)
	ur.add_undo_method(self, "set_owner", scene_root)
	ur.add_undo_method(parent, "move_child", self, index)
	ur.add_undo_reference(self)
	# Before the commit, never after — see [method hand_inspector_over]. A solid is SELECTED when its
	# own button is pressed, so with several of them selected the editor is holding all of them by node
	# path at the moment this removes one.
	hand_inspector_over(replacement)
	ur.commit_action()

	if is_instance_valid(replacement) and replacement.is_inside_tree():
		EditorInterface.get_selection().add_node(replacement)


## Put `replacement` where this solid was and hand it to the document. One method rather than three
## undo entries because `move_child` and the owners are only legal once the node is in the tree, and
## an undo step that half-applies is worse than one that is opaque.
func _adopt(parent: Node, replacement: Node, index: int, scene_owner: Node) -> void:
	parent.add_child(replacement, true)
	parent.move_child(replacement, index)
	Collision.claim(replacement, scene_owner)


# --- Subclass hooks -------------------------------------------------------
#
# Left empty rather than abstract, so a half-written subclass still loads and reports its problem as
# geometry that never appears rather than as a parse error. Each is implemented by [Brush]; none has
# a meaningful default here, because every one of them is the part that depends on the geometry.

## Rebuild the mesh from the geometry, in full. Backs the Rebuild Mesh button.
func rebuild_mesh() -> void:
	pass


## Re-emit the mesh WITHOUT re-deriving what it is made of — the cheap half, for a change that alters
## how the geometry is packed rather than what it is. Only the lightmap settings use it.
##
## Separate from [method rebuild_mesh] because a group splits the two: a full rebuild re-runs the
## O(members^2) cull, and a UV2 toggle has no business paying for that. A brush has no such split and
## points both at the same place.
func _rebake_mesh() -> void:
	pass


## Bring the generated subtree — mesh, body, shapes, occluder — in line with the exports and the
## geometry. The single entry point, so a change of body kind, of layer, or of shape all land in one
## place.
func _sync_derived() -> void:
	pass


## Put the editor grid overlay on the generated mesh, or take it off, per [member _grid_overlay_enabled].
func _apply_grid_overlay() -> void:
	pass


## Pull the origin back into the geometry, moving the node and compensating the geometry so nothing
## appears to move. Backs the Recenter Origin button.
func recenter() -> void:
	pass
