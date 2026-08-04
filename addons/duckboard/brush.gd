@tool
@icon("res://addons/duckboard/icons/ShapeTool_Cuboid.svg")
class_name Brush
extends Node3D
## Convex brush, Quake / TrenchBroom style: one or more [BrushData] given a place in the world.
##
## Registered globally so the Scene dock and Create Node dialog call it a Brush, and so the
## plugin can ask `node is Brush` rather than comparing `get_script()` against a preload — the
## latter silently fails for a node whose script was reloaded or inherited.
##
## [b]One piece is a brush; several are a group.[/b] Nothing else about the node changes with the
## count — one transform, one mesh, one body, one entry in the Scene dock either way. See
## [member pieces].
##
## [b]The shape lives in [BrushData], not here.[/b] The half-spaces, the derived face polygons, the
## per-face UV projection and every operation over them (clip, hull re-solve, UV carry) are in that
## file, which knows nothing about nodes. This one owns everything that needs a place in the scene:
## the transform, the generated mesh / body / shapes / occluder, texture lock, the editor grid
## overlay, and the mapping from a world-space gesture onto local geometry.
##
## The WHOLE-SOLID operations stay on this node (set_box, set_from_points, clip_by, the world-face
## trips), forwarding to the data and rebuilding afterwards. The PER-FACE texture and UV API lives
## on [BrushPiece] — the handle every tool and pick answers with — so face operations name which
## piece they mean by construction. Reach a lone brush's faces through [code]piece(0)[/code].
##
## [b]Attaching your own script to a brush.[/b] A node has only ONE script, so attaching one
## normally REPLACES this file and the node stops being a brush at all. Instead, extend it:
## [codeblock]
## @tool
## extends Brush
##
## func _ready() -> void:
##     super()          # REQUIRED: sets up the planes, the mesh and the texture-lock reference
##     ...
## [/codeblock]
## In the Attach Script dialog, set [i]Inherits[/i] to [code]Brush[/code] rather than
## Node3D. Every tool tests [code]node is Brush[/code], so a subclass is a first-class
## brush with no further work.
##
## Two overrides must chain to [code]super()[/code] or the brush breaks quietly:
## [code]_ready()[/code] (nothing is built without it) and [code]_notification()[/code] (texture
## lock stops compensating for movement). [code]@tool[/code] is needed for the brush to appear while
## editing rather than only at runtime.
##
## [b]A brush is a Node3D, not a MeshInstance3D.[/b] It BUILDS one — see [member collision_type] —
## along with its body and shapes, as unowned children that are never saved. The rendering properties
## worth reaching are forwarded onto this node ([code]material_override[/code],
## [code]cast_shadow[/code], [code]layers[/code], [code]gi_mode[/code], [code]transparency[/code]),
## so they still show in the inspector and still save with the scene; anything else lives on the
## generated [MeshInstance3D], which [method get_mesh_instance] hands back.
##
## [code]set_box()[/code] remains the creation convenience the draw tool uses; it lays out 6 axis
## planes. A cuboid is BUILT that way and is a plane solid from then on — no size is kept.

# Re-exported from [BrushData] for the callers that have always spelled them `Brush.DEFAULT_TEXTURE`
# — including user code extending Brush. Aliases, never copies — a second literal is how two
# tolerances drift apart. Only the constants something outside [BrushData] actually reads; the
# geometric tolerances live there alone.
const DEFAULT_TEXTURE := BrushData.DEFAULT_TEXTURE
const DEFAULT_TEX_SIZE := BrushData.DEFAULT_TEX_SIZE
const UNITS_PER_METER := BrushData.UNITS_PER_METER

## Cut-out alpha cuts at the halfway point: a retro texture's mask is 0 or 255, so anything strictly
## inside the range works and the middle is the most forgiving of a resized or filtered source.
const ALPHA_SCISSOR_THRESHOLD := 0.5
const FACE_SHADER := preload("res://addons/duckboard/shaders/brush_face.gdshader")

## Raises and maintains the generated subtree — mesh, body, shapes, occluder. Preloaded rather than
## reached through the plugin: a solid must work as a plain runtime node with no EditorPlugin in the
## tree, and one reshaped by a game script has to take its collision with it.
const Collision := preload("res://addons/duckboard/collision.gd")
## Packs the second UV set when [member lightmap_uv2] asks for one. Preloaded for the same reason.
const Lightmap := preload("res://addons/duckboard/lightmap.gd")
## The world-space grid, attached as a material_overlay in the editor only, so it never touches the
## base material and never ships. See [method _apply_grid_overlay].
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
## One-way: the pieces, the per-face UV axes and the textures-as-data all go, because plain nodes
## have nowhere to keep them. It is a normal undo step, so Ctrl+Z brings the solid back in the same
## session — but once the scene is saved over, the geometry is a mesh and that is that. Save As
## first if the editable version is worth keeping.
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
## A group's shapes are its PIECES, coarsened — which makes a group the best case for this design
## rather than the worst, since the pieces are already the room's exact convex decomposition.
## Adjacent pieces whose hull encloses nothing new are fused first, so a wall of five cuboids
## collides as one box; the volume is unchanged, only the piece count. No V-HACD guess, no hollow
## trimesh for a character to be pushed inside.
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


## What [member pieces] currently serialises as. Stamped into every brush that is written, so a later
## change of shape can tell what it is reading instead of having to infer it.
const DATA_VERSION := 1

## The format the stored geometry is in. [b]Defaults to 0, meaning "predates versioning", and is
## re-stamped on every write.[/b] [PackedScene] omits any property equal to the node's default, so a
## field defaulting to the current version would write nothing — and the next version, shipping a new
## default, would silently re-label every scene saved under the old one.
##
## Per SOLID rather than per scene, and that is not a preference: property setters run during
## deserialization while the node is still OUT of the tree, so at the moment `pieces` is decoded this
## node cannot reach a scene root to ask what version it is. Solids also travel between scenes —
## copy/paste, an instanced sub-scene — so a scene-level stamp could describe a payload that came
## from somewhere else. A version carried by the data it describes cannot desynchronize from it.
@export_storage var data_version := 0

## Every convex piece this brush is made of, as plain data: one [code]{planes, face_data}[/code] entry
## each, in the brush's own local frame.
##
## [b]Usually exactly one[/b], which is what a brush has always been. More than one makes the same
## node a GROUP — several solids that read and move as a single object — and nothing else about the
## node changes: one transform, one mesh, one body, one entry in the Scene dock.
##
## Stored but not shown: structure a typed-in value could not honour, with invariants (outward
## normals, a bounded convex intersection per piece) only the tools maintain. The Rebuild Mesh button
## stays visible — it is the one safe manual action, and takes no input.
@export_storage var pieces: Array:
	get:
		var out := []
		for s in _solids:
			out.append({"planes": s.planes.duplicate(), "face_data": s.face_data})
		return out
	set(value):
		_solids = _decode_pieces(value)
		_geometry_changed()

## The pieces themselves — the brush's geometry, and what [member pieces] is a serialisable view of.
##
## A piece never notifies: every path that mutates one goes through this node's own facade below,
## which rebuilds explicitly — so the rebuild happens exactly where it always did, in an order that
## can be read off the call rather than inferred from a signal graph.
var _solids: Array[BrushData] = []

## The brush's half-spaces — [b]the first piece's[/b], which for an ordinary one-piece brush is simply
## the brush's. This is what every tool has always addressed, and it keeps meaning that.
##
## [b]No longer stored, but still LOADED.[/b] A scene written before [member pieces] existed names
## this property, and a plain script variable's setter still receives that value — so an older brush
## opens with no migration step. It is kept out of new saves by [method _validate_property], because
## the same geometry reaching disk twice is how the two copies start disagreeing.
var planes: Array[Plane]:
	get:
		return _first().planes
	set(value):
		_first().planes = value
		_geometry_changed()

## The per-face texture/UV state of the FIRST piece, as one value — so undo can capture it
## atomically alongside `planes`.
##
## It IS derived — the `planes` setter re-carries it on every edit — but re-deriving it is a ONE-WAY
## trip: the carry assumes it is stepping forward from the shape it was last computed for, applying
## UV lock and plane reprojection as it goes. Restoring only `planes` therefore runs the carry a
## SECOND time (old shape -> older shape) instead of putting the previous mapping back. Recording
## this alongside `planes` is what makes undo exact rather than recomputed.
##
## Assigned AFTER `planes` (its setter clobbers the face arrays), so undo must order it that way.
##
## Not stored and still loaded, exactly as [member planes] is — see there.
var face_data: Dictionary:
	get:
		return _first().face_data
	set(value):
		if value.is_empty():
			return
		# BEFORE the data assignment, because the bake below reads it. Assigning this IS the statement
		# that the projection is right for the pose the brush is in now, so re-base the texture-lock
		# reference to match. Without it the deferred NOTIFICATION_TRANSFORM_CHANGED arrives later,
		# measures a delta against a stale pose, and applies the movement compensation a SECOND time
		# on top of a value that already accounted for it — the texture flickers for a frame before
		# the next update overrides it. Doing it here covers every caller that moves a brush and then
		# states its UVs: rotate, flip, clip, recenter, and undo.
		_lock_transform = global_transform if is_inside_tree() else Transform3D.IDENTITY
		_first().face_data = value
		# The derived payloads carry the texture, the material and the UV axes, so they and the cull
		# keyed off them are stale the moment this lands. Cheap for one piece — nothing buries
		# anything — and it is what keeps a freshly-loaded brush from baking against the surfaces it
		# had before its face data arrived.
		_faces = []
		_surfaces = {}
		_shell = []
		_build_mesh()

## The grid, in metres: the lattice set_from_points snaps corners to, AND the cell size the face
## overlay draws. One value, because they are one thing — the overlay is a picture OF the lattice,
## so a brush drawn on a grid it isn't showing would be lying about where its corners can land.
##
## Deliberately NOT exported. There is exactly one grid — the plugin's dropdown — and it is pushed
## to every brush at once, so a per-brush value is a cache of a global rather than data about this
## brush. Serialising it is what used to let brushes disagree: a scene loaded at a different grid
## kept its saved value while newly drawn brushes took the palette's, so two brushes side by side
## snapped to different lattices. Not saving it makes that unrepresentable.
##
## The brush still holds it rather than reading the plugin: set_from_points and weld_sq are called
## on a plain runtime Brush, which must work with no EditorPlugin in the tree.
var grid_size := 1.0:
	set(value):
		grid_size = maxf(value, 0.001)
		for piece in _solids:
			piece.grid_size = grid_size
		_sync_grid()

## TrenchBroom's alignment lock. Textures are ALWAYS projected from world space; this decides
## whether each face's projection absorbs the brush's movement (texture appears stuck to the
## face) or is left alone (brush slides under a world-fixed texture).
##
## Turning it on is deliberately silent — it just re-bases the reference pose, locking the
## texture exactly where it currently sits rather than shifting it.
##
## Not exported, for the same reason as `grid_size`: it is a palette MODE, not a property of this
## brush. Nothing reads it except a manipulation in progress — the transform handler below and the
## rotate tool — so a brush at rest is identical whichever way it is set, and the plugin pushes the
## current mode to every brush on scene load anyway.
##
## EDITOR-ONLY, therefore. In a running game the question it asks does not arise — a brush that moves
## there is an object carrying its texture with it — so the transform handler ignores this and always
## behaves as though it were on. See _notification.
var texture_lock := false:
	set(value):
		texture_lock = value
		_lock_transform = global_transform if is_inside_tree() else Transform3D.IDENTITY

## Holds each face's UV axes through geometry edits — see [member BrushData.uv_lock], which is where
## it is actually read. A mode, not brush data, so it is not exported.
var uv_lock := false:
	set(value):
		uv_lock = value
		for piece in _solids:
			piece.uv_lock = value

## Piece index -> [BrushPiece], so a piece keeps its identity across frames. Dropped only when the
## PIECE LIST changes, never on a mere reshape — see [method piece].
var _handles := {}

## The cull result, cached: {surface key: [visible face dicts]}. Which faces are hidden depends only
## on where the pieces sit RELATIVE TO EACH OTHER — all of it local — so moving the brush cannot
## change it, which is what lets a drag re-bake UVs without re-running the cull.
var _surfaces := {}

## The pieces as local-space face payloads, cached. This is the polygon data a group used to SAVE.
var _faces: Array = []

## The coarsened convex decomposition, cached. Derived from the pieces alone.
var _merged: Array = []

## The occluder's face polygons, cached. A second cache rather than a view of `_merged`, because with
## one piece it is built from a different input entirely — see [method _occluder_shell].
var _shell: Array = []

## Pose the current UV projection was computed for. The delta from here — the FULL transform,
## not just the translation — is what gets absorbed while texture lock is on.
var _lock_transform := Transform3D.IDENTITY

## Texture of each mesh surface, in surface order. The clip preview swaps a surface's material
## for the ghost shader and back, and needs to know which texture to restore.
var _surface_tex: Array[Texture2D] = []
## The actual Material built for each surface (a StandardMaterial3D for texture faces, or the custom
## material for material faces) — so the clip ghost can restore exactly what it replaced rather than
## re-deriving a StandardMaterial3D and clobbering a face's custom material.
var _surface_material: Array[Material] = []


# --- Pieces ---------------------------------------------------------------

## The first piece, raised on demand. Everything the tools address — `planes`, the per-face UV API,
## the clip — means THIS one, because a tool works on a single convex solid and always has.
##
## Created rather than returned null when there is none, so `Brush.new()` followed by `set_box()` (the
## draw tool's construction path) works with no separate initialisation step.
func _first() -> BrushData:
	if _solids.is_empty():
		_solids.append(_new_piece())
	return _solids[0]


## A fresh piece (or an independent copy of `from`) carrying this brush's node-level modes. Every
## path that creates or adopts a piece goes through here, so `grid_size` and `uv_lock` reach it
## exactly once — a construction site that stamps them by hand is how two brushes side by side
## ended up snapping to different lattices.
func _new_piece(from: BrushData = null) -> BrushData:
	var solid := from.duplicate_data() if from != null else BrushData.new()
	solid.grid_size = grid_size
	solid.uv_lock = uv_lock
	return solid


## How many convex pieces this brush is. One is an ordinary brush; more makes it a group.
func piece_count() -> int:
	return _solids.size()


## Does this solid read as a GROUP — several pieces rather than one? The one spelling of that
## question, so the refusal rules and the pick paths cannot drift on what "a group" means.
func is_group() -> bool:
	return _solids.size() > 1


## Piece `index`'s geometry, or the first piece's when the index is out of range — which keeps a
## stale handle harmless rather than a crash.
func piece_data(index: int) -> BrushData:
	if index < 0 or index >= _solids.size():
		return _first()
	return _solids[index]


## Piece `index` as something a geometry tool can hold — see [BrushPiece].
##
## CACHED, and that is load-bearing: a drag stores handles at the press and reads them at the release,
## and the face selection holds {node, face} pairs compared by identity across frames. Handing back a
## fresh object each call would leave every one of those comparisons false. The cache is dropped
## whenever the geometry changes, exactly as the derived face view is.
func piece(index: int) -> BrushPiece:
	if index < 0 or index >= _solids.size():
		return null
	var existing = _handles.get(index)
	if existing != null:
		return existing
	var made := BrushPiece.new(self, index)
	_handles[index] = made
	return made


## Every piece as a handle, in piece order — what a geometry tool is given for this brush.
func pieces_of() -> Array:
	var out: Array = []
	for i in _solids.size():
		out.append(piece(i))
	return out


## A piece was reshaped through its handle. Same invalidation as any other geometry write, minus the
## handle cache — the handles still name the same pieces, and dropping them would break the identity a
## drag in progress is holding.
func piece_changed() -> void:
	data_version = DATA_VERSION
	_faces = []
	_merged = []
	_shell = []
	_surfaces = {}
	_rebuild()


## A piece's UV PROJECTION moved and nothing else — the cheap tier, for the writes that fire per
## mouse event during a UV drag.
##
## Everything derived stays valid: which faces are buried, the merged decomposition, collision and
## the occluder cannot change when only texture axes do. The cached payloads are patched in place —
## each carries the piece and face it describes, so the fresh axes are a lookup, not a re-derivation
## — and only the mesh is re-baked. A surface change (texture or material) is NOT this: it moves the
## bake's surface key and the cull's opacity answer, so it takes [method piece_changed].
func mapping_changed() -> void:
	data_version = DATA_VERSION
	for key in _surfaces:
		for f in _surfaces[key]:
			_refresh_mapping(f)
	# The originals too, not just the cull's survivors — a buried face's payload must not go stale,
	# or the next full rebuild would read old axes off it. Fragments in _surfaces are copies, which
	# is why both walks exist; a dict in both is patched twice, harmlessly.
	for payload in _faces:
		for f in payload:
			_refresh_mapping(f)
	_build_mesh()


## Fresh UV axes for one cached face payload, read off the piece it describes.
func _refresh_mapping(f: Dictionary) -> void:
	var pi: int = f.get("piece", 0)
	var fi: int = f.get("face", 0)
	if pi >= _solids.size():
		return
	var d := _solids[pi]
	if fi >= d.face_count():
		return
	f["u"] = d.face_axis_u(fi)
	f["v"] = d.face_axis_v(fi)
	f["offset"] = d.face_offset(fi)


## Turn a stored piece list into live solids, accepting the in-memory hand-offs too.
##
## Entries may be [BrushData] (a piece passed straight across, e.g. from a group being folded in) or
## a [code]{planes, face_data}[/code] Dictionary (what a saved scene holds). Both appear, so both are
## read; there is no format sniffing beyond that, because `pieces` did not exist before version 1.
func _decode_pieces(value: Array) -> Array[BrushData]:
	var out: Array[BrushData] = []
	for entry in value:
		if entry is BrushData:
			out.append(_new_piece(entry))
			continue
		if not (entry is Dictionary) or not (entry as Dictionary).has("planes"):
			continue
		var solid := _new_piece()
		var typed: Array[Plane] = []
		typed.assign((entry as Dictionary)["planes"])
		solid.planes = typed
		solid.face_data = (entry as Dictionary).get("face_data", {})
		out.append(solid)
	return out


## Everything that has to happen when the geometry changes, wherever the change came from: stamp the
## version, drop what was derived, and rebuild. [method piece_changed] IS that, so the paths cannot
## drift — this adds only the handle drop, because here the piece LIST may have changed and a handle
## may name a piece that is gone.
func _geometry_changed() -> void:
	_handles.clear()
	piece_changed()


## Keep `planes` and `face_data` OUT of new saves while leaving them readable and settable.
##
## They are the first piece's, and `pieces` already carries it — writing both would put the same
## geometry on disk twice, which is how two copies start disagreeing. The properties still exist and
## their setters still fire, which is what lets a scene written before `pieces` load untouched.
func _validate_property(property: Dictionary) -> void:
	if property.name == &"planes" or property.name == &"face_data":
		property.usage &= ~PROPERTY_USAGE_STORAGE
	# `occluder` is ignored on a trigger (see [code]Collision.occludes[/code]) — greyed, not hidden.
	# A property that disappears reads as a bug in the plugin; one that is visible and greyed says
	# the thing that is actually true: it is still yours, it does not apply to this.
	if property.name == &"occluder" and not Collision.occludes(collision_type):
		property.usage |= PROPERTY_USAGE_READ_ONLY


func _ready() -> void:
	# BEFORE the rebuild, not after — this is the pose the stored projection was authored FOR.
	#
	# _build_mesh settles whatever movement the run-time transform handler left owed, measured as
	# `global_transform * _lock_transform⁻¹`. Deserialization sets properties while the node is still
	# OUT of the tree, so the face_data setter can only leave _lock_transform at IDENTITY — and a
	# rebuild reached before this line therefore measured the brush's whole world pose as movement it
	# owed, and carried the UV projection through it. Nothing had moved: the brush was loaded where it
	# was saved. The effect was a texture re-projected from the brush's origin instead of from world
	# space, i.e. shifted by its own position — invisible on a tiling texture that happened to land on
	# a whole repeat, and plainly wrong on anything aligned to its face.
	#
	# Stating it here makes the first in-tree rebuild owe nothing, which is the truth.
	_lock_transform = global_transform
	if _solids.is_empty() or (_solids.size() == 1 and _first().face_count() < 4):
		set_box(Vector3.ONE)    # a brush that arrived with no shape becomes a unit cube
	else:
		# Redundant planes saved into the scene stay broken (sliver faces, a phantom corner with too
		# many edges) until something re-solves them, so they are healed on load. Either way exactly
		# one rebuild follows, which is why the return value is not branched on.
		for piece in _solids:
			piece.prune_planes()
		_geometry_changed()
	set_notify_transform(true)  # only reads the transform, so it can't fight a gizmo
	# The mesh, the body and the shape need no call of their own here: every branch above reaches
	# _rebuild, which builds the mesh and then fits the collision to it. _build_mesh raises the
	# subtree if it is somehow not there yet, so a brush is never left rendering nothing.


## Absorb movement into the UV projection while the lock is on, so the texture stays put relative
## to the faces. Reads the transform and writes only shader uniforms — never the transform — so
## it can't fight the editor's own dragging.
func _notification(what: int) -> void:
	# Nothing to strip before a save any more, and nothing to put back after. The mesh and the grid
	# overlay both live on a generated child with no `owner`, which [PackedScene] does not pack — so
	# the two derived things that used to have to be hidden from the serialiser are now unreachable
	# by it. The PRE_SAVE / POST_SAVE pair this file used to carry is simply gone.
	#
	# Parentage no longer matters either. The body is a CHILD of this brush rather than an ancestor
	# it had to be found under, so moving a brush in the Scene dock takes its physics along by the
	# ordinary rules of the scene graph, and there is nothing to reconcile a frame later. Destruction
	# needs no hook for the same reason: children die with their parent.
	if what != NOTIFICATION_TRANSFORM_CHANGED or not is_inside_tree():
		return
	# Movement needs NO collision work. The shape is a descendant sitting at identity, so it moves
	# with this brush the way every child does — which is also what keeps a physics-driven crate free
	# of per-frame work. Only a change of GEOMETRY reaches _sync_derived.
	#
	# TEXTURE LOCK IS AN EDITOR MODE, and in a running game the answer can only be "locked". A brush
	# that moves at run time is an OBJECT — a crate on a RigidBody3D, a lift, a door — and a
	# world-projected texture would scroll across its own faces as it travelled, which is never what
	# a moving object wants. The mode is not even exported (see `texture_lock`), so a running game
	# would otherwise get whichever way the palette happened to be set.
	#
	# Nothing is done here, not even the carry: the mesh already renders correctly.
	# BrushData.carry_uv_axes solves uv_new(delta * p) == uv_old(p), so the UVs baked before the move
	# and the axes carried through it describe the SAME texture — only the stored world-space AXES are
	# left owing the movement, and _build_mesh settles that at the one moment they are read again. A
	# physics-driven brush therefore costs nothing per frame instead of re-baking its whole mesh.
	if not Engine.is_editor_hint():
		return
	var current := global_transform
	if not texture_lock:
		_lock_transform = current
		# Re-bake so a world-fixed texture stays put as the brush slides: the UVs are baked into
		# the mesh from world positions, so moving the node needs the bake redone. The axes and
		# offset are unchanged; only the world positions the UVs are sampled at have moved.
		_build_mesh()
		return
	# The FULL delta pose, not just the offset between origins: rotating a brush with the
	# editor's own gizmo has to turn the texture with it, and a translation-only correction
	# would leave it projected from the brush's old orientation.
	var delta := current * _lock_transform.affine_inverse()
	if not delta.is_equal_approx(Transform3D.IDENTITY):
		_lock_uvs(delta)
		_lock_transform = current


## Carry the UV projection through a world transform `delta` so every point keeps the UV it had, then
## re-bake. The carry itself is [method BrushData.carry_uv_axes]; this is the half that needs a mesh.
## A pure mapping change — the cull is transform-invariant, so dragging a locked brush patches the
## cached axes and re-bakes instead of re-culling every face per transform event.
func _lock_uvs(delta: Transform3D) -> void:
	for piece in _solids:
		piece.carry_uv_axes(delta)
	mapping_changed()


## This brush's pose, safe to ask for before the node is in the tree (where global_transform errors).
func _to_world() -> Transform3D:
	return global_transform if is_inside_tree() else Transform3D.IDENTITY


# --- Geometry facade ------------------------------------------------------
#
# Everything below forwards to [member _data] and rebuilds. The signatures are unchanged from when
# the maths lived here, because a tool holding a Brush has no business knowing where it moved to.
# Reads are pass-through; writes rebuild exactly as the equivalent assignment used to.

## Lay out the six outward planes of an axis-aligned box `size` across, centred on the brush's own
## origin. This is the CONSTRUCTION path for a cuboid — `Brush.new()`, `set_box(size)`, then add it to
## the tree — and the fallback _ready uses for a brush that arrived with no planes at all.
func set_box(size: Vector3) -> void:
	_first().set_box(size)
	_geometry_changed()


func face_polygon(index: int) -> PackedVector3Array:
	return _first().face_polygon(index)


## Every distinct corner of the solid, in local space — what the vertex tool grabs.
func get_vertices() -> PackedVector3Array:
	return _first().get_vertices()


## Every distinct edge, as consecutive pairs [a0, b0, a1, b1, ...] in local space.
func get_edges() -> PackedVector3Array:
	return _first().get_edges()


## Centroid of a face's polygon, in local space — where the face tool's handle sits.
func face_center(index: int) -> Vector3:
	return _first().face_center(index)


## SQUARED distance below which two points are the SAME corner, scaled to the grid. Everything that
## compares points must use this one — see [method BrushData.weld_sq].
func weld_sq() -> float:
	return _first().weld_sq()


## The polygon this plane would cut out of the brush, in LOCAL space — the cross-section.
## First-piece only, and loud about it on a group — ask each piece (see [method pieces_of]).
func cross_section(plane: Plane) -> PackedVector3Array:
	if is_group():
		push_error("Brush.cross_section() on a group reads its first piece only — ask each piece (pieces_of()).")
	return _first().cross_section(plane)


## Clip the brush with a plane, discarding everything on the plane's OUTWARD side. Returns false
## if nothing solid survives, in which case the caller should delete the brush.
func clip_by(plane: Plane) -> bool:
	# A group refuses OUTRIGHT: cutting "the brush" through the first-piece facade would carve one
	# member and claim the job done. True, not false — false means "nothing survives, delete me",
	# and the geometry here is untouched.
	if is_group():
		push_error("Brush.clip_by() cannot cut a group — clip its pieces (BrushPiece.clip_by).")
		return true
	if not _first().clip_by(plane):
		return false
	# The cut face's mapping was just stated for the pose the brush is in, exactly as an assignment to
	# `face_data` would state it — so the texture-lock reference is re-based for the same reason.
	_lock_transform = _to_world()
	_geometry_changed()
	return true


## Rebuild the brush as the CONVEX HULL of `points` (local space). See
## [method BrushData.set_from_points] — [param snap] is measured in WORLD space, which is why the
## brush's own pose goes with it.
func set_from_points(points: PackedVector3Array, snap := true) -> void:
	_first().set_from_points(points, snap, _to_world())
	_geometry_changed()


## Move the node's origin to the centre of the brush's own geometry WITHOUT moving the brush:
## the planes shift back by exactly what the origin shifts forward, so nothing changes on screen.
##
## Worth doing because the shape-changing tools (vertex/edge/face drags, scale, shear) rewrite
## the geometry in local space and leave `position` where it was, so the origin drifts away from
## the brush — Godot's own gizmo and the inspector's position field slowly stop matching it. The
## rigid operations (move, rotate, flip) carry the origin along and need no correction.
func recenter() -> void:
	if _solids.is_empty() or not is_inside_tree():
		return
	# The union's bounds, not the first piece's: the origin belongs to the whole solid, so a group
	# recentres on everything it contains, exactly as a lone brush does on its single piece.
	var offset := center_offset()
	if offset.length_squared() < 1e-12:
		return                    # already centred; skip the churn
	# The UV state must survive untouched. Shifting the planes runs the carry, and under UV lock a
	# pure translation moves EVERY corner of every face — no unmoved corners, so the lock would
	# happily solve for a transform and shift the axes. Moving the node then fires
	# NOTIFICATION_TRANSFORM_CHANGED and texture lock compensates for a move that never happened.
	# Restoring each piece's mapping undoes both; nothing here changes world geometry.
	for piece_data_ in _solids:
		var keep := piece_data_.face_data
		piece_data_.shift(offset)
		piece_data_.face_data = keep
	piece_changed()
	global_position = global_position + global_transform.basis * offset
	# The node moved but the geometry did not. Re-base BEFORE the deferred transform notification
	# arrives, or texture lock measures a delta and compensates for a movement that never happened.
	_lock_transform = _to_world()
	_build_mesh()


# --- CSG support (cross-brush geometry) -----------------------------------

## A world-space description of every bounding face, for CSG and any other operation that reasons
## about several brushes at once. See [method BrushData.world_faces] for the entry shape.
##
## [b]The FIRST piece's[/b] — and on a group that is a partial answer, so it says so loudly instead
## of lying quietly. Every caller that means "all of it" reads [method world_pieces]; this stays the
## single-solid convenience it has always been.
func world_faces() -> Array:
	if is_group():
		push_error("Brush.world_faces() on a %d-piece group answers its first piece only — use world_pieces()."
			% _solids.size())
	return _first().world_faces(_to_world())


## The single world-space FACE dict for one plane index — the same entry world_faces() pools.
func world_face(index: int) -> Dictionary:
	return _first().world_face(index, _to_world())


## Rebuild this brush from a CSG blueprint. The node MUST sit at the identity transform (CSG works in
## world space, so a world plane IS the local plane); the caller should recenter() afterwards to pull
## the origin into the geometry and keep local coordinates small.
func set_world_faces(faces: Array) -> bool:
	if not _first().set_world_faces(faces):
		return false
	# The blueprint states the projection for the pose the brush is in, exactly as an assignment to
	# `face_data` does — so the texture-lock reference is re-based the same way. See that setter.
	_lock_transform = _to_world()
	_geometry_changed()
	return true


## How far the origin sits from the centre of the geometry, in LOCAL space. Zero means the origin is
## already where [method recenter] would put it.
func center_offset() -> Vector3:
	var boxes := local_bounds_list()
	if boxes.is_empty():
		return Vector3.ZERO
	var bounds: AABB = boxes[0]
	for i in range(1, boxes.size()):
		bounds = bounds.merge(boxes[i])
	return bounds.get_center()


## Every piece as a world-space [code]world_faces()[/code] payload, in piece order — what Ungroup,
## the .map writer and the clipboard all hand around.
func world_pieces() -> Array:
	var out := []
	var to_world := _to_world()
	for solid in _solids:
		out.append(solid.world_faces(to_world))
	return out


## The inverse trip: world-space faces folded into this brush's local frame.
func to_local_faces(faces: Array) -> Array:
	return _transform_faces(faces, _to_world().affine_inverse())


## Store a list of WORLD-space solids (each a world_faces() payload) as this brush's pieces.
##
## The node must ALREADY sit at its final pose, because the fold to local reads global_transform —
## which is why the Group action parents the node and sets its transform before calling this. One
## assignment to `pieces`, so one rebuild and one undoable property.
func absorb_world(solids: Array) -> void:
	var folded := []
	for solid in solids:
		var data := _new_piece()
		if data.set_world_faces(to_local_faces(solid)):
			folded.append(data)
	pieces = folded


## Carry a list of face dicts through `xform`: the plane by [method BrushData.to_world_plane], the
## polygon by the full transform. The UV axes and offset are left alone BY DESIGN: they are
## world-space, and leaving them fixed is what keeps the texture world-projected.
static func _transform_faces(faces: Array, xform: Transform3D) -> Array:
	var out := []
	for f in faces:
		var pts := PackedVector3Array()
		for c in f["points"]:
			pts.append(xform * c)
		var moved: Dictionary = f.duplicate()
		moved["plane"] = BrushData.to_world_plane(f["plane"], xform)
		moved["points"] = pts
		out.append(moved)
	return out


## This brush's extent in its OWN local space as one box per piece — what the isolation wash spares.
## Per piece rather than merged, so outside geometry poking between pieces does not escape with them.
func local_bounds_list() -> Array[AABB]:
	var out: Array[AABB] = []
	for m in _local_faces():
		out.append(Csg.bounds_of(m))
	return out


# --- Mesh generation ------------------------------------------------------

## Full rebuild: re-derives the face polygons (clipping) and builds the mesh. Called when the
## GEOMETRY changes. When only the pose or the UV mapping changed, call _build_mesh directly —
## the polygon cache is still valid and re-clipping every face would be wasted work.
## Backs the Rebuild Mesh button, and the lightmap settings.
##
## Both point at the same place: re-deriving the whole thing IS the cheap path, because the cull and
## the merge are cached against the pieces and invalidated by the one write that changes them.
func rebuild_mesh() -> void:
	_geometry_changed()


func _rebake_mesh() -> void:
	_geometry_changed()


func _rebuild() -> void:
	if _solids.is_empty():
		return
	# OFF-TREE, nothing is built. Deserialization runs the `pieces` setter before the node has a
	# tree, so everything derived here would be culled and baked against the identity transform and
	# thrown away the moment _ready runs the real build — scene load used to pay the whole pipeline
	# twice per brush. Reading geometry off-tree needs no rebuild (world_faces and friends read the
	# pieces, not the caches), and every path into the tree passes through _ready, which rebuilds.
	if not is_inside_tree():
		return
	_surfaces = _cull_faces(_local_faces())
	_build_mesh()
	# Collision and the occluder wait for END OF FRAME. The mesh and cull above are the visual
	# feedback a drag needs; the physics fit and occluder rebuild are invisible mid-gesture, and a
	# high-rate mouse delivers several input events per frame — each of which lands here during a
	# reshape drag. Deferring coalesces them to one fit per frame, at idle. The subtree is still the
	# brush's OWN children, so the fit needs no parent and survives reparenting; a brush freed before
	# the deferred call simply drops it.
	if not _derived_queued:
		_derived_queued = true
		_run_sync_derived.call_deferred()


## True while an end-of-frame [method _sync_derived] is already booked — see [method _rebuild].
var _derived_queued := false


func _run_sync_derived() -> void:
	_derived_queued = false
	if _solids.is_empty() or not is_inside_tree():
		return
	_sync_derived()


## Bring the generated subtree — mesh, body, shapes, occluder — in line with the exports and the
## geometry. The single entry point, so a change of body kind, of layer, or of shape all land in one
## place.
##
## Cheap to call and safe to call often: [code]ensure_tree[/code] keeps whatever is already correct
## and only builds what is missing, and [code]fit[/code] skips a shape whose points have not moved.
func _sync_derived() -> void:
	# `faded` is read from the mesh as it stands, BEFORE the tree is rebuilt, which is the only order
	# available — `transparency` lives on the node this call returns. First build reads null and gets
	# false, and that is correct: a brush with no mesh yet has no transparency yet. The value arrives
	# later through the property forward, and _set re-runs this when it does.
	_mesh = Collision.ensure_tree(self, collision_type, collision_layer, collision_mask,
		occluder and Collision.occludes(collision_type) and not Collision.faded(_mesh))
	# Null when there is no body — the mesh hangs off the brush directly then — and fit() takes that
	# as "nothing to do", so NONE needs no branch of its own here.
	#
	# ONE shape per piece, coarsened: the pieces already ARE an exact convex decomposition, so a
	# multi-piece brush needs no V-HACD guess and no hollow trimesh. A SINGLE piece skips the merge
	# machinery outright and hands over its welded corners — the same shape a brush has always had,
	# read off the cached polygons instead of re-clipping every face to rediscover them.
	Collision.fit(_mesh.get_parent() as CollisionObject3D,
		[_first().get_vertices()] if _solids.size() == 1 else _piece_points(_merged_pieces()))
	Collision.fit_occluder(self, _occluder_shell())


## The pieces as local-space face payloads, built once and cached. Deriving this is one clip pass per
## piece — the same pass a brush has always run on load.
func _local_faces() -> Array:
	if _faces.is_empty() and not _solids.is_empty():
		_faces = _faces_of(_solids)
	return _faces


## The convex decomposition the pieces already are, coarsened wherever two fuse into a single convex
## piece without gaining volume — the shared answer collision and occlusion are both a view of. The
## solids stay the source of truth; what changes is the PIECE COUNT, so a wall of five cuboids
## becomes one box. Cached because the merge is quadratic in the piece count.
func _merged_pieces() -> Array:
	if _merged.is_empty() and not _solids.is_empty():
		_merged = Csg.merge_pieces(_local_faces())
	return _merged


## The occluder's shell, and [b]the one place the piece count genuinely changes the answer.[/b]
##
## With ONE piece every face is exterior, so "not drawn" and "not blocking the view" mean the same
## thing: an untextured face is nodraw at run time and must leave a hole in the shell, which is what
## the per-face filter does.
##
## With SEVERAL, most untextured faces are BURIED between touching pieces — not drawn because they
## are inside the solid, which is the strongest reason there is to keep them in a shell. Filtering
## those out would perforate a room from the inside out, so the test moves up to whole pieces and the
## shell is built from the merged decomposition instead.
##
## Both rules are right for their case; unifying them is a real question rather than a tidy-up, and
## it is written up in TODO.md rather than guessed at here.
func _occluder_shell() -> Array:
	if not _shell.is_empty() or _solids.is_empty():
		return _shell
	if _solids.size() == 1:
		var out: Array = []
		var solid := _first()
		for i in solid.face_count():
			if not face_occludes(solid.face_texture(i), solid.face_material(i)):
				continue
			var poly := solid.face_polygon(i)
			if poly.size() >= 3:
				out.append(poly)
		_shell = out
		return _shell
	_shell = _shell_of(_local_faces(), _merged_pieces())
	return _shell


## UV2 for every fragment the mesh will draw, keyed by the fragment dictionary, or an empty map when
## lightmapping is off.
##
## The CULLED set: a face buried between two pieces is never drawn, so giving it atlas space would
## spend texels on lighting nobody can see. That is the opposite of the choice collision and occlusion
## make, and for the opposite reason — those describe the solid, this describes what is rendered.
##
## Keyed by the dictionary rather than by index because the cull may split one face into several
## fragments, and the bake loop walks fragments, not faces.
func _fragment_uv2() -> Dictionary:
	if not lightmap_uv2:
		return {}
	var frags: Array = []
	var polys: Array = []
	var normals: Array = []
	for key in _surfaces:
		for f in _surfaces[key]:
			frags.append(f)
			polys.append(f["points"])
			normals.append((f["plane"] as Plane).normal)
	var packed := Lightmap.pack(polys, normals, lightmap_texel_size)
	var out := {}
	for i in frags.size():
		if i < packed.size():
			out[frags[i]] = packed[i]
	return out


## Does this face present a surface solid enough to claim it blocks the view?
##
## [b]Occlusion has to follow what actually RENDERS, not what exists.[/b] A face left Empty is
## dropped from the mesh in a running game and a cut-out texture is full of holes by design — an
## occluder over either claims that light stops at a surface the player can see straight through, and
## the geometry behind it is culled and simply gone. This is the same class of mistake the trigger
## volume made, one level down: it is the [b]drawn[/b] surface that occludes, never the geometry.
##
## Wrong in the two directions costs wildly different amounts, which is what settles every judgement
## call here. An occluder that is too SMALL draws a few things it could have skipped. One that is too
## BIG deletes scenery the player is looking at. So anything unclear resolves to "does not occlude".
##
## The one exception is a [ShaderMaterial], which cannot be asked whether it is opaque and is taken
## at its word that it is — the same assumption the renderer makes until a shader says otherwise.
## Excluding those instead would quietly switch occlusion off for every material-driven wall in a
## level. If you write a see-through shader, turn Occluder off on the brushes wearing it.
static func face_occludes(tex: Texture2D, mat: Material) -> bool:
	if mat != null:
		var base := mat as BaseMaterial3D
		return base == null or base.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED
	if tex == null or tex == DEFAULT_TEXTURE:
		return false      # never drawn in a running game — see _build_mesh
	return not _has_cutout_alpha(tex)


## Build the mesh from the (cached) face polygons, baking the texture UV into the vertex channel
## and grouping faces by TEXTURE into one surface each.
##
## One surface per texture, one material per surface — so a brush with a single texture is ONE
## draw call instead of one per face. The UV is `dot(world_vertex, axis) + offset`, baked per
## vertex — exact because the mapping is affine.
func _build_mesh() -> void:
	if _solids.is_empty():
		return
	# WORLD transform, so a moved brush bakes UVs from where it actually is. That is what lets a
	# world-fixed texture (lock off) stay put as the brush slides — _notification re-bakes on move.
	var to_world := _to_world()

	# Settle the movement the RUN-TIME transform handler deliberately left owed (see _notification).
	# The axes are world-space and are about to be read, so they first have to be carried through
	# everything the brush has moved since the projection was last stated — otherwise a game script
	# reshaping a wall on a moving platform would re-project it from where it set off. Editor-side
	# there is never anything owed, because the handler settles on the spot.
	if not Engine.is_editor_hint() and is_inside_tree():
		var owed := to_world * _lock_transform.affine_inverse()
		if not owed.is_equal_approx(Transform3D.IDENTITY):
			for piece in _solids:
				piece.carry_uv_axes(owed)
			_faces = []
			_surfaces = _cull_faces(_local_faces())
			_lock_transform = to_world

	if _surfaces.is_empty():
		_surfaces = _cull_faces(_local_faces())

	# Packed across ALL fragments at once, before any surface is emitted: UV2 addresses one atlas for
	# the whole mesh, so two faces that happen to land on different surfaces must still not overlap.
	var uv2 := _fragment_uv2()

	var array_mesh := ArrayMesh.new()
	_surface_tex = []
	_surface_material = []
	# UNTEXTURED faces are left out of the mesh IN A RUNNING GAME. That is the whole nodraw feature,
	# and it needs no marker texture and no bake step: a face nobody textured is a face nobody meant
	# to see, so the thing you would have reached for a "nodraw" texture to say is already said by
	# leaving it alone. TrenchBroom shows its skip texture while editing and strips those faces at
	# compile time; a Brush rebuilds its mesh on _ready in a running game exactly as it does in the
	# editor, so the same split falls out of one condition with no second representation to keep in
	# step. In the EDITOR the face is drawn as usual — it has to stay visible to be worked on.
	#
	# A face with a MATERIAL override is never dropped: its key is the material, not the texture,
	# so assigning one to an otherwise-untextured face keeps it, which is what assigning it meant.
	var drop_untextured := not Engine.is_editor_hint()
	for key in _surfaces:
		if drop_untextured and key == DEFAULT_TEXTURE:
			continue
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for f in _surfaces[key]:
			var poly: PackedVector3Array = f["points"]
			var n: Vector3 = (f["plane"] as Plane).normal
			var u: Vector3 = f["u"]
			var v: Vector3 = f["v"]
			var off: Vector2 = f["offset"]
			var frag_uv2: PackedVector2Array = uv2.get(f, PackedVector2Array())
			# Triangle fan, each triangle reversed for Godot's front-face convention. Vertices are
			# already local; only the UV needs the world position.
			for i in range(1, poly.size() - 1):
				for k in [0, i + 1, i]:
					var world: Vector3 = to_world * poly[k]
					st.set_normal(n)
					st.set_uv(Vector2(world.dot(u), world.dot(v)) + off)
					# Set on the SAME vertices and in the same order as the fan above, so the atlas
					# coordinate travels with the corner it was measured from.
					if k < frag_uv2.size():
						st.set_uv2(frag_uv2[k])
					st.add_vertex(poly[k])
		# A material face renders with its material verbatim; a texture face gets a StandardMaterial3D.
		var surf_mat: Material = key if key is Material else _material_for(key as Texture2D)
		st.set_material(surf_mat)
		st.commit(array_mesh)
		_surface_material.append(surf_mat)
		_surface_tex.append(BrushData._surface_texture_of(key))

	get_mesh_instance().mesh = array_mesh
	_apply_grid_overlay()


## The DEFAULT material: a plain StandardMaterial3D carrying just the texture. The per-face UV is
## baked into the vertices and the grid lives in the overlay, so there is nothing custom left — a
## user can drop in their own material and lose nothing but the two editor aids. Nearest filtering
## keeps the pixel-art textures crisp.
## Shared per texture, and STATIC so it is shared across brushes as well as across rebuilds. A mesh
## rebuild asks for a material every time — every move, reshape and UV drag — and this used to hand
## back a freshly allocated one each call, so a level held one material per brush per texture rather
## than one per texture, and churned a new resource on every edit.
##
## Sharing loses nothing: the material is derived wholly from the texture, and nothing here mutates
## one after handing it out. Editing a brush's material in the inspector was never durable anyway —
## the next rebuild replaced it — so there is no per-brush state to protect.
static var _material_cache: Dictionary = {}


## STATIC, and the single implementation — every solid renders the same faces whatever its piece
## count. A group used to keep its own copy of this, until alpha scissoring was added here and
## silently did not reach grouped brushes: a duplicate that has to "stay identical" only advertises
## the next time it won't.
static func _material_for(tex: Texture2D) -> StandardMaterial3D:
	var key: Texture2D = tex if tex != null else DEFAULT_TEXTURE
	var cached = _material_cache.get(key)
	if cached != null:
		return cached
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = key
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.roughness = 0.9
	# Cut-out, never blended. A retro texture's transparent pixels are meant to VANISH, not to be
	# composited, so ALPHA_SCISSOR is what they want: the fragment is discarded and the brush stays
	# in the opaque queue, keeping depth pre-pass, sorting and shadows exactly as a solid brush has
	# them. TRANSPARENCY_ALPHA would move it to the transparent queue and cost all three for
	# nothing. Only applied where there IS alpha, since discard forgoes early-Z on some hardware.
	if _has_cutout_alpha(key):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = ALPHA_SCISSOR_THRESHOLD
	_material_cache[key] = mat
	return mat


## Does this texture carry pixels meant to be discarded? `detect_alpha` separates NONE from BIT (a
## hard on/off mask — exactly the retro cut-out case) and BLEND, and either of the latter two wants
## scissoring. Read once per texture, since the material it decides is cached alongside it.
##
## Undecidable answers say YES: scissoring a texture with no alpha discards nothing and merely
## forgoes an optimisation, whereas NOT scissoring one that needs it draws the mask as solid black.
static func _has_cutout_alpha(tex: Texture2D) -> bool:
	if tex == null:
		return false
	var img := tex.get_image()
	if img == null:
		return true
	if img.is_compressed() and img.decompress() != OK:
		return true      # VRAM-compressed and not readable back: assume it needs it
	return img.detect_alpha() != Image.ALPHA_NONE


## The CLIP-preview material for a surface: the ghost shader carrying the same texture plus the
## cut plane, scoped to `boxes` (LOCAL-space member bounds) when the cut touches only some members.
## Swapped in only while a clip is being previewed on this brush (see set_clip_ghost), because the
## discard it does can't be expressed by a StandardMaterial3D.
func _clip_material(tex: Texture2D, packed_plane: Vector4, boxes: Array) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = FACE_SHADER
	mat.set_shader_parameter("albedo_tex", tex)
	mat.set_shader_parameter("clip_ghost_plane", packed_plane)
	# More boxes than the shader carries falls back to ghosting the whole solid — over-showing the
	# effect is the safe direction, and sixteen hand-picked members is already past any real cut.
	var count := boxes.size() if boxes.size() <= 16 else 0
	mat.set_shader_parameter("clip_ghost_box_count", count)
	if count > 0:
		var lo := PackedVector3Array()
		var hi := PackedVector3Array()
		for i in count:
			# Grown a hair so a fragment lying exactly on its own box face still counts as inside.
			var box: AABB = (boxes[i] as AABB).grow(0.001)
			lo.append(box.position)
			hi.append(box.end)
		mat.set_shader_parameter("clip_ghost_box_lo", lo)
		mat.set_shader_parameter("clip_ghost_box_hi", hi)
	return mat


## Attach the world-space grid as a material_overlay — a second pass over the mesh — but only in
## the editor, so the shipped brush has none of it and the base material stays clean. One overlay
## per brush (it's per-instance, not per-surface); its cell size tracks the grid.
func _apply_grid_overlay() -> void:
	var target := get_mesh_instance()
	if not Engine.is_editor_hint() or not _grid_overlay_enabled:
		target.material_overlay = null
		return
	if _grid_material == null:
		_grid_material = ShaderMaterial.new()
		_grid_material.shader = GRID_SHADER
		# Sorted AFTER the surface it decorates, explicitly. An opaque brush needs no such promise —
		# its faces render in the opaque pass and this one in the transparent pass, so the grid is
		# always last. Give the brush a `transparency` above 0 and the faces are forced into the
		# transparent pass too, where both draws sit at the same depth with nothing left to order
		# them: the grid could end up UNDERNEATH its own surface. That is what made the lines on a
		# translucent brush pulse light and dark — the grid was being blended through the face, so a
		# face that animates (a water shader warping its lookup) modulated the grid along with it.
		_grid_material.render_priority = 1
	_grid_material.set_shader_parameter("cell_size", grid_size)
	target.material_overlay = _grid_material


## Ghost the part of this brush lying on the plane's OUTWARD side — the side a clip would discard.
##
## Swaps each surface between its plain StandardMaterial3D and the ghost shader, rather than
## pushing a uniform, because the default material is a StandardMaterial3D that has no such
## uniform. Restoring rebuilds the plain materials, which is safe because it happens only at the end
## of a clip interaction, and committing a clip rebuilds the brush from scratch anyway. Pass a
## WORLD-space plane.
func set_clip_ghost(plane: Plane, enabled: bool, boxes: Array = []) -> void:
	var am := get_mesh_instance().mesh as ArrayMesh
	if am == null:
		return
	var packed := Vector4(plane.normal.x, plane.normal.y, plane.normal.z, plane.d)
	for i in am.get_surface_count():
		var tex: Texture2D = _surface_tex[i] if i < _surface_tex.size() else DEFAULT_TEXTURE
		if enabled:
			am.surface_set_material(i, _clip_material(tex, packed, boxes))
		else:
			# Restore EXACTLY what was there — a face's custom material, not a re-derived
			# StandardMaterial3D that would wipe it.
			am.surface_set_material(i, _surface_material[i] if i < _surface_material.size() \
				else _material_for(tex))


## The grid cell size lives on the overlay material, not the per-face materials.
func _sync_grid() -> void:
	if _grid_material != null:
		_grid_material.set_shader_parameter("cell_size", grid_size)


# --- Geometry of the piece SET --------------------------------------------
#
# The three questions that are about several pieces taken together rather than about any one of them:
# which faces a viewer could actually SEE, the coarsened convex decomposition, and the occluder shell.
#
# The polygon machinery for all three — the cull, the fragment subtraction, the merge — lives in
# csg.gd, next to the clipping whose tolerances it must agree with. What stays here is the MATERIAL
# policy: whether a piece is solid enough to hide faces or block light is a question about
# transparency and shader trust, which the geometry core deliberately knows nothing about.
const Csg := preload("res://addons/duckboard/csg.gd")


## Every solid's faces as payload dicts, in whatever frame the solids are already in. The shape the
## rest of this file reads: {plane, u, v, offset, tex, material, points} per face.
##
## This is the data a group used to SAVE. It is derived here instead, at the cost of one clip pass
## per solid — the same pass a loose brush runs on load.
static func _faces_of(solids: Array) -> Array:
	var out: Array = []
	for i in solids.size():
		var payload: Array = (solids[i] as BrushData).world_faces()
		# Stamped with its piece, pairing with the "face" index the payload already carries — the
		# mapping-only refresh reads fresh UV axes through the two without re-deriving anything.
		for f in payload:
			f["piece"] = i
		out.append(payload)
	return out


# --- What is visible ------------------------------------------------------

## Which faces survive, grouped by surface — the expensive half, so callers cache it. The clipping
## itself is [method Csg.cull_faces]; this half answers the two questions the geometry core refuses
## to: how solid each piece's materials are, and how big it is.
static func _cull_faces(faces: Array) -> Dictionary:
	# Precomputed per solid, because the hidden-face test asks about them once per FACE of every
	# other solid: the AABB is the cheap reject, and a see-through solid must never occlude.
	var bounds := []
	var opaque_flags := []
	for m in faces:
		bounds.append(Csg.bounds_of(m))
		opaque_flags.append(_piece_opaque(m))
	return Csg.cull_faces(faces, bounds, opaque_flags)


## May this solid hide another's faces? Only if nothing about it can be seen through — a plain
## texture face is opaque, a BaseMaterial3D is opaque only with transparency disabled, and anything
## else (a ShaderMaterial, which could discard or blend) is assumed see-through. Culling behind glass
## would delete geometry the player can look straight at, so the doubt resolves toward keeping faces.
static func _piece_opaque(faces: Array) -> bool:
	for f in faces:
		var mat: Material = f["material"]
		if mat == null:
			continue
		if mat is BaseMaterial3D \
				and (mat as BaseMaterial3D).transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
			continue
		return false
	return true


# --- Collision and occlusion ----------------------------------------------

## One point cloud per convex collision piece — [method _merged_pieces] as corners, which is the form
## [ConvexPolygonShape3D] wants. collision.gd welds the duplicates shared edges produce.
static func _piece_points(pieces: Array) -> Array:
	var out: Array = []
	for piece in pieces:
		out.append(piece["points"])
	return out


## The occluder's shell: the merged pieces as face polygons.
##
## [b]The same coarsening collision gets, and it pays off harder here.[/b] The occluder used to be
## every face of every solid — the whole surface INCLUDING the walls buried between touching pieces,
## which are inside the union and can never block anything the outer surface does not already block.
## A wall of five cuboids shipped thirty quads to describe a box. Merging first drops it to six, and
## an occluder is CPU-rasterized every frame.
##
## [b]See-through solids are dropped BEFORE the merge, and the order is the point.[/b] A piece that
## light gets through cannot claim to stop it — and merged into an opaque neighbour it would be
## impossible to take out again, since the fused piece has no members left to ask. Filtering first
## also means the common case costs nothing: with everything opaque the input is the whole set and
## the collision merge IS this merge, so it is reused rather than run twice.
##
## Under-occluding is the safe direction, which is what makes dropping a piece sound even though it
## opens a hole in the shell: the worst case is a few things drawn that could have been skipped.
static func _shell_of(faces: Array, already_merged: Array) -> Array:
	var opaque: Array = []
	for m in faces:
		if _piece_occludes(m):
			opaque.append(m)
	var pieces: Array = already_merged if opaque.size() == faces.size() \
		else Csg.merge_pieces(opaque)
	var out: Array = []
	for piece in pieces:
		out.append_array(Csg.piece_polygons(piece))
	return out


## Does this solid present surfaces solid enough to block the view? The per-solid half of
## [method face_occludes], and deliberately NOT [method _piece_opaque], which answers the cull's
## question rather than this one (a [ShaderMaterial] is taken at its word here, exactly as it is on a
## loose brush, instead of being assumed see-through).
##
## A face stating NO surface at all — no material and no texture — is skipped rather than counted
## against the solid. On a loose brush that face is nodraw and says "does not occlude"; among several
## solids it is almost always a face BURIED against a neighbour, never textured because nobody can
## see it, and reading it as see-through would switch occlusion off for most of a real room.
static func _piece_occludes(faces: Array) -> bool:
	for f in faces:
		var mat: Material = f["material"]
		var tex: Texture2D = f["tex"]
		if mat == null and (tex == null or tex == DEFAULT_TEXTURE):
			continue
		if not face_occludes(tex, mat):
			return false
	return true


# --- The generated subtree and its inspector --------------------------------
#
# The half of a brush that knows nothing about half-spaces: raising and reaching the derived
# mesh/body/shapes/occluder, the property forwarding that keeps the generated mesh's settings on the
# node the scene actually saves, and Convert to Mesh — the way out of the addon.

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


# `material_override`, `cast_shadow`, `layers`, `gi_mode` and `transparency` still live on the solid,
# so they show in the inspector, save with the scene, and answer to `brush.material_override = x`
# from a script — but there is no backing field, and every one of them reads and writes the generated
# MeshInstance3D. collision.gd holds the list and the metadata; see there for why the storage flag is
# dynamic.

func _get_property_list() -> Array[Dictionary]:
	# _mesh rather than get_mesh_instance(): the inspector queries this constantly, and answering a
	# property listing has no business raising the subtree.
	return Collision.forward_list(_mesh)


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
## because it was a [MeshInstance3D] until recently and callers still ask.
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
static func to_plain_nodes(solid: Brush) -> Node3D:
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
