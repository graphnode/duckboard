@tool
@icon("res://addons/duckboard/icons/ShapeTool_Cuboid.svg")
class_name Brush
extends MeshInstance3D
## Convex brush, Quake / TrenchBroom style: the solid is the INTERSECTION OF HALF-SPACES.
##
## Registered globally so the Scene dock and Create Node dialog call it a Brush, and so the
## plugin can ask `node is Brush` rather than comparing `get_script()` against a preload — the
## latter silently fails for a node whose script was reloaded or inherited.
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
## MeshInstance3D. Every tool tests [code]node is Brush[/code], so a subclass is a first-class
## brush with no further work.
##
## Two overrides must chain to [code]super()[/code] or the brush breaks quietly:
## [code]_ready()[/code] (nothing is built without it) and [code]_notification()[/code] (texture
## lock stops compensating for movement). [code]@tool[/code] is needed for the brush to appear
## while editing rather than only at runtime.
##
## `planes` is the source of truth. Each plane's normal points outward, so a point is inside
## the brush when `plane.distance_to(p) <= 0` for every plane. Convexity is therefore
## guaranteed by construction — a dented shape simply cannot be represented, which is what
## the vertex/edge/face tools need.
##
## Faces are derived, not stored: each face starts as a huge quad on its plane and is clipped
## by every other plane. That means topology changes for free — drag a corner far enough and
## a face shrinks to nothing and disappears, exactly like TrenchBroom.
##
## [code]set_box()[/code] remains the creation convenience the draw tool uses; it lays out 6 axis
## planes. A cuboid is BUILT that way and is a plane solid from then on — no size is kept.

## What an untextured face wears — and, by that token, the nodraw marker: a face still carrying it
## is left OUT of the mesh in a running game (see _build_mesh), so anything you never got around to
## texturing costs nothing to draw. The editor still shows it, so it stays visible to work on.
const DEFAULT_TEXTURE := preload("res://addons/duckboard/textures/__empty.png")
## Cut-out alpha cuts at the halfway point: a retro texture's mask is 0 or 255, so anything strictly
## inside the range works and the middle is the most forgiving of a resized or filtered source.
const ALPHA_SCISSOR_THRESHOLD := 0.5
const FACE_SHADER := preload("res://addons/duckboard/shaders/brush_face.gdshader")
## The world-space grid, attached as a material_overlay (a second pass) only in the editor, so it
## never touches the base material and never ships. See _apply_grid_overlay.
const GRID_SHADER := preload("res://addons/duckboard/shaders/brush_grid.gdshader")
const UNITS_PER_METER := 32.0
## Assumed texel size when a face's texture can't be resolved. Matches map_io's assumption, so a
## face keeps the same scale numbers across a .map round trip.
const DEFAULT_TEX_SIZE := Vector2(64, 64)

## Half-extent of a face polygon before it gets clipped by the other planes.
## Only has to exceed any brush's extent. Kept modest on purpose: clipping a quad this large
## loses float precision, and that noise is what turns "the same point" into two.
const BIG := 512.0
## Tolerance for "is this point on that plane".
const EPS := 0.0001
## Two planes count as the same face when their normals agree to this dot product AND their
## distances to within PLANE_MERGE_DIST. Deliberately TIGHT: with grid-snapped corners,
## coplanar triples yield planes differing only at float precision, so anything looser starts
## merging genuinely distinct faces — which silently deletes vertices and flattens folds into
## diagonals.
const PLANE_MERGE_DOT := 0.9999
const PLANE_MERGE_DIST := 0.001

## Hard ceiling on hull input. The solve is O(n^4), so without a cap a corrupted brush can
## lock the editor solid rather than merely look wrong.
const MAX_HULL_POINTS := 64

## How slivery a triple may be before it is not allowed to define a hull face, as the triangle's
## smallest altitude expressed as a FRACTION OF THE POINT CLOUD'S OWN EXTENT.
##
## Three points only fix a plane in proportion to how far the middle one sits off the line through
## the other two. Take three corners 2mm apart on a 3m brush and the normal that comes out is
## numerically meaningless — yet nothing rejected it, because Plane(a, b, c) NORMALISES, so the
## `normal.length_squared() < 0.5` test only ever catches an exactly degenerate triple. Worse, a
## plane built from a near-collinear triple lies nearly tangent to the cloud, so it also passes the
## "every other point on one side" test and is accepted as a face. Each one is a phantom, and the
## phantoms breed: they intersect to make more clustered corners, which make more slivery triples.
## Measured on a fanned brush, 31 corners produced 211 planes where a valid hull allows 2n-4 = 58.
##
## Relative, not another absolute epsilon: the question is whether a triple is well conditioned FOR
## THIS BRUSH, and a tolerance in metres would mean something different on a doorframe than on a
## room. 1e-3 is ~an order of magnitude below the thinnest brush anyone builds (a 3cm panel across a
## 4m span is 8e-3) yet far above the noise that fans a hull; 1e-2 was measured to start eating the
## real faces of thin brushes.
const HULL_MIN_ALTITUDE := 1e-3

## Absolute floor for the weld tolerance; see weld_sq().
const WELD_SQ := 1e-8

## The brush itself: the half-spaces whose intersection IS the solid. Stored but NOT shown in the
## inspector — this is the single source of truth, and it has invariants (outward normals, a
## bounded convex intersection) that a hand-typed value cannot be trusted to keep. It is written by
## the tools, which maintain them; a field offering to edit it by hand could only produce a brush
## that isn't one. Storage is still required — nothing can re-derive a shape that was never saved.
@export_storage var planes: Array[Plane] = []:
	set(value):
		# Faces are re-derived on every hull solve, and the plane list is reordered, grown and
		# shrunk freely — so per-face data must be carried across by MATCHING planes, never by
		# index, or textures would shuffle between faces on every edit.
		var previous := planes
		var snapshot := _face_snapshot()
		planes = value
		_poly_cache.clear()   # derived faces are only valid for the planes that made them
		_carry_face_data(previous, snapshot)
		_rebuild()

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
		# Floored, so a zero or negative grid can't reach snappedf or the overlay shader.
		grid_size = maxf(value, 0.001)
		_sync_grid()

## Whether the face grid overlay is currently shown. The map editor is the thing the grid serves,
## so the plugin hides it (set_grid_overlay_enabled) when Duckboard is toggled off, leaving brushes
## as plain textured geometry. Runtime-only editor state — not exported — reconciled by the plugin
## on toggle and on scene change; kept as a flag so a rebuild while off doesn't restore the grid.
var _grid_overlay_enabled := true

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
var texture_lock := false:
	set(value):
		texture_lock = value
		_lock_transform = global_transform if is_inside_tree() else Transform3D.IDENTITY

## Holds each face's UV axes through geometry edits, so the texture stretches and shears with
## the face instead of re-snapping to the nearest world axis. Off is the classic Quake
## behaviour, where a face tilting past 45 degrees flips projection and the texture jumps.
##
## A mode, not brush data — see `texture_lock`. Read only by the plane-change carry.
var uv_lock := false

## Face polygons, cached per plane. The overlay asks for these on every redraw (wireframe,
## vertex handles, edge handles), and recomputing means re-clipping every face against every
## other plane each mouse-move. They only change when `planes` does.
var _poly_cache: Array = []

## Pose the current UV projection was computed for. The delta from here — the FULL transform,
## not just the translation — is what gets absorbed while texture lock is on.
var _lock_transform := Transform3D.IDENTITY

## The editor grid overlay material, kept so its cell size can be updated without rebuilding it.
var _grid_material: ShaderMaterial

## The mesh, parked across a save. See _notification: the mesh is DERIVED — _ready rebuilds it
## unconditionally from `planes` and `face_data` — so serialising it writes a large ArrayMesh (and
## the StandardMaterial3D subresources its surfaces reference) that load parses, allocates, and
## immediately throws away. Holding the reference here rather than rebuilding in POST_SAVE keeps
## the round trip to two pointer assignments, so saving costs nothing.
var _saved_mesh: Mesh

## Texture of each mesh surface, in surface order. The clip preview swaps a surface's material
## for the ghost shader and back, and needs to know which texture to restore.
var _surface_tex: Array[Texture2D] = []
## The actual Material built for each surface (a StandardMaterial3D for texture faces, or the custom
## material for material faces) — so the clip ghost can restore exactly what it replaced rather than
## re-deriving a StandardMaterial3D and clobbering a face's custom material.
var _surface_material: Array[Material] = []

var _face_tex: Array[Texture2D] = []
## Optional per-face material OVERRIDE. When non-null the face renders with this Material directly
## (a full "replace the whole material" — Godot's model, not TrenchBroom's), and `_face_tex[f]` is
## ignored for rendering. Null means the classic path: a StandardMaterial3D built from `_face_tex[f]`.
var _face_material: Array[Material] = []
var _face_offset: Array[Vector2] = []
## Explicit per-face projection axes, rather than derived from the normal each frame.
var _face_axis_u: Array[Vector3] = []
var _face_axis_v: Array[Vector3] = []

## The per-face texture/UV state as one value, so it can be saved with the scene and captured
## atomically by undo.
##
## It IS derived — `planes`' setter re-carries it on every edit — but re-deriving it is a
## ONE-WAY trip: the carry assumes it is stepping forward from the shape it was last computed
## for, applying UV lock and plane reprojection as it goes. Restoring only `planes` therefore
## runs the carry a SECOND time (old shape -> older shape) instead of putting the previous
## mapping back. Recording this alongside `planes` is what makes undo exact rather than
## recomputed.
##
## Assigned AFTER `planes` (its setter clobbers these arrays), so undo must order it that way.
##
## Stored but not shown: it is five parallel arrays that must stay index-aligned to `planes`, which
## no inspector field can enforce. The texture dock and the UV canvas are how it is meant to be
## edited. Storage is required — the note above is precisely why it cannot be recomputed.
@export_storage var face_data: Dictionary:
	get:
		var data := {
			"tex": _face_tex.duplicate(),
			"offset": _face_offset.duplicate(),
			"u": _face_axis_u.duplicate(),
			"v": _face_axis_v.duplicate(),
		}
		# "material" is left out entirely when no face carries an override — by far the common
		# case, and otherwise a per-face array of nothing but nulls in every saved brush. The
		# setter reads it through .get and _ensure_face_defaults pads the gap back to all-null,
		# so the dict round-trips identically.
		#
		# ONLY this key may be elided. "tex"/"offset"/"u"/"v" are indexed positionally by the
		# clip donor path below and by _transform_face_data, both of which would fault on a
		# missing key; nothing indexes "material" on a face_data dict.
		for m in _face_material:
			if m != null:
				data["material"] = _face_material.duplicate()
				break
		return data
	set(value):
		if value.is_empty():
			return
		_face_tex.assign(_coerce(value.get("tex", []), true))
		# A dict without a "material" key is fine: the empty default pads to all-null in
		# _ensure_face_defaults — i.e. plain texture faces.
		_face_material.assign(_coerce(value.get("material", []), false))
		_face_offset.assign(value.get("offset", []))
		_face_axis_u.assign(value.get("u", []))
		_face_axis_v.assign(value.get("v", []))
		_ensure_face_defaults()
		_build_mesh()
		# Assigning this IS the statement that the projection is right for the pose the brush is
		# in now, so re-base the texture-lock reference to match. Without it the deferred
		# NOTIFICATION_TRANSFORM_CHANGED arrives later, measures a delta against a stale pose,
		# and applies the movement compensation a SECOND time on top of a value that already
		# accounted for it — the texture flickers for a frame before the next update overrides
		# it. Doing it here covers every caller that moves a brush and then states its UVs:
		# rotate, flip, clip, recenter, and undo.
		_lock_transform = global_transform if is_inside_tree() else Transform3D.IDENTITY


func _ready() -> void:
	if planes.size() < 4:
		set_box(Vector3.ONE)   # a brush that arrived with no shape becomes a unit cube
	elif not _prune_planes():   # pruning assigns `planes`, whose setter already rebuilds
		_rebuild()
	set_notify_transform(true)  # only reads the transform, so it can't fight a gizmo
	_lock_transform = global_transform


## Absorb movement into the UV projection while the lock is on, so the texture stays put relative
## to the faces. Reads the transform and writes only shader uniforms — never the transform — so
## it can't fight the editor's own dragging.
func _notification(what: int) -> void:
	# The grid overlay is an editor-only material, so it must not be written into the saved scene:
	# strip it just before a save and put it back after. Otherwise every brush would serialise a
	# ShaderMaterial subresource that _ready would immediately discard at runtime anyway.
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		material_overlay = null
		# Same argument, one property over: the mesh is derived from `planes` + `face_data` and
		# _ready rebuilds it on every load, so the serialised copy is never the one that renders.
		_saved_mesh = mesh
		mesh = null
		return
	if what == NOTIFICATION_EDITOR_POST_SAVE:
		_apply_grid_overlay()
		mesh = _saved_mesh
		_saved_mesh = null
		return
	if what != NOTIFICATION_TRANSFORM_CHANGED or not is_inside_tree():
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


## Carry the UV projection through a world transform `delta` so every point keeps the UV it had:
## solving uv_new(delta * p) == uv_old(p) gives newAxes = oldAxes * delta⁻¹, with the offset
## absorbing the translation.
##
## This is the same identity the flip and rotate tools apply directly — the only difference is
## that they know their transform up front, while this one derives it from the node moving. A
## rotation is therefore handled by the same three lines as a translation.
func _lock_uvs(delta: Transform3D) -> void:
	_ensure_face_defaults()
	# The inverse-transpose, not the basis itself: it is what maps the PROJECTION axes (which
	# transform like normals, not like points), and it stays correct if the brush is ever scaled.
	var axis_map := delta.basis.inverse().transposed()
	var shift := delta.origin
	for f in planes.size():
		var u: Vector3 = axis_map * _face_axis_u[f]
		var v: Vector3 = axis_map * _face_axis_v[f]
		# The NEW axes are what the translation is measured against.
		_face_offset[f] -= Vector2(u.dot(shift), v.dot(shift))
		_face_axis_u[f] = u
		_face_axis_v[f] = v
	_build_mesh()


func _centroid(poly: PackedVector3Array) -> Vector3:
	if poly.is_empty():
		return Vector3.ZERO
	var total := Vector3.ZERO
	for p in poly:
		total += p
	return total / poly.size()


## A point on the seam — the line where the old and new planes meet — nearest `near`. Both
## mappings agree there, so pinning the UV to it keeps the texture from sliding as a face tilts.
func _seam_reference(old_plane: Plane, new_plane: Plane, near: Vector3) -> Vector3:
	var direction := old_plane.normal.cross(new_plane.normal)
	var denominator := direction.length_squared()
	if denominator < 1e-12:
		return near
	# Any point on both planes: ((d1*n2 - d2*n1) x (n1 x n2)) / |n1 x n2|^2. The RAW cross
	# product, not the normalized one — the denominator must match the vector in the cross,
	# or the point lands off the seam whenever the planes aren't perpendicular.
	var on_seam := (new_plane.normal * old_plane.d - old_plane.normal * new_plane.d) \
		.cross(direction) / denominator
	# Then slide along the seam to the point closest to `near`.
	direction = direction.normalized()
	return on_seam + direction * direction.dot(near - on_seam)


## Rotate the axes onto a new normal, keeping their length (i.e. their texture scale).
func _reproject_axes(u: Vector3, v: Vector3, new_normal: Vector3) -> Array:
	var old_normal := u.cross(v)
	if old_normal.length_squared() < 1e-12:
		return [u, v]
	old_normal = old_normal.normalized()
	var axis := old_normal.cross(new_normal)
	if axis.length_squared() < 1e-12:
		return [u, v]
	var turn := Basis(axis.normalized(), old_normal.angle_to(new_normal))
	return [turn * u, turn * v]


## The affine map taking a face's OLD corners onto its new ones, or null when UV lock should
## leave the face alone.
##
## TrenchBroom's rule: collect matched corner pairs, and if 3 or more never moved, give up —
## you cannot hold four corners' UVs while moving one. Reference points are the unmoved corners
## FIRST, then moved ones, which is what keeps stationary corners pinned.
func _uv_lock_transform(old_poly: PackedVector3Array, new_poly: PackedVector3Array) -> Variant:
	if old_poly.size() < 3 or old_poly.size() != new_poly.size():
		return null
	var shift := _ring_alignment(old_poly, new_poly)
	if shift < 0:
		return null

	var unmoved := []
	var moved := []
	var tolerance := weld_sq()
	for i in old_poly.size():
		var from: Vector3 = old_poly[i]
		var to: Vector3 = new_poly[(i + shift) % new_poly.size()]
		if from.distance_squared_to(to) < tolerance:
			unmoved.append([from, to])
		else:
			moved.append([from, to])
	if unmoved.size() >= 3:
		return null            # the bail-out: face keeps its mapping untouched
	var refs := unmoved + moved
	if refs.size() < 3:
		return null
	return _points_transform(refs[0], refs[1], refs[2])


## Rotational offset that best lines the two corner rings up. Clipping can rotate where a
## polygon starts, so pairing by raw index would mismatch corners.
func _ring_alignment(a: PackedVector3Array, b: PackedVector3Array) -> int:
	var count := a.size()
	var best := -1
	var best_score := INF
	for shift in count:
		var score := 0.0
		for i in count:
			score += a[i].distance_squared_to(b[(i + shift) % count])
		if score < best_score:
			best_score = score
			best = shift
	return best


## Affine transform mapping three point pairs onto each other. A fourth point is synthesised
## along each triangle's normal so the map is well-defined off-plane (unit scale perpendicular).
func _points_transform(p0: Array, p1: Array, p2: Array) -> Variant:
	var a0: Vector3 = p0[0]
	var a1: Vector3 = p1[0]
	var a2: Vector3 = p2[0]
	var b0: Vector3 = p0[1]
	var b1: Vector3 = p1[1]
	var b2: Vector3 = p2[1]
	var a_normal := (a1 - a0).cross(a2 - a0)
	var b_normal := (b1 - b0).cross(b2 - b0)
	if a_normal.length_squared() < 1e-12 or b_normal.length_squared() < 1e-12:
		return null            # collinear reference points
	var a := Basis(a1 - a0, a2 - a0, a_normal.normalized())
	var b := Basis(b1 - b0, b2 - b0, b_normal.normalized())
	if absf(a.determinant()) < 1e-9:
		return null
	var linear := b * a.inverse()
	return Transform3D(linear, b0 - linear * a0)


## Default UV projection axes for a face with normal `n` — seeds a NEW face, and re-snaps when
## UV lock is off. Chosen so textures sit upright: U points
## right for a viewer facing the face, V points down — so world-up reads as texture-up and the frame
## is unmirrored (u × v = n). Near-horizontal faces (floor/ceiling) have no "up on the face", so U
## falls back to world +X. Continuous in `n` (no paraxial 45° jump) and exact unit world axes for the
## axis-aligned faces of a box.
func _uv_axes(n: Vector3) -> Array:
	var nn := n.normalized()
	# u0 = right-for-viewer (n × up), v = down (n × u0). Every face then flips U (negate U,
	# keep V) — the orientation that reads correctly here; V still points down, so textures stay
	# upright.
	var u0: Vector3
	if absf(nn.dot(Vector3.UP)) > 0.999:
		u0 = Vector3.RIGHT
	else:
		u0 = nn.cross(Vector3.UP).normalized()
	var v := nn.cross(u0).normalized()
	return [-u0, v]


## Make a stored surface list safe to assign into its typed array, replacing anything that is no
## longer the right type with the default (a texture) or null (a material).
##
## A saved scene can outlive a resource: a texture deleted or moved in the FileSystem, or one the
## addon itself retired between versions. Godot loads the missing entry as a plain Resource, and
## assigning that to a TypedArray aborts the WHOLE assignment — so one dead texture used to cost a
## brush every face's UVs and materials, not just the one face wearing it.
func _coerce(raw: Array, textures: bool) -> Array:
	var out := []
	for item in raw:
		if textures:
			out.append(item if item is Texture2D else DEFAULT_TEXTURE)
		else:
			out.append(item if item is Material else null)
	return out


## Drop planes that are near-duplicates of one another, and report whether anything changed.
##
## The hull merges these as it solves, but saved data can still carry a redundant pair — and it
## stays broken (sliver faces, a phantom corner with too many edges) until something re-solves
## it, so it's healed on load rather than left baked into the scene.
func _prune_planes() -> bool:
	var kept: Array[Plane] = []
	for candidate in planes:
		var duplicate := false
		for existing in kept:
			if existing.normal.dot(candidate.normal) > PLANE_MERGE_DOT \
					and absf(existing.d - candidate.d) < PLANE_MERGE_DIST:
				duplicate = true
				break
		if not duplicate:
			kept.append(candidate)
	if kept.size() == planes.size():
		return false
	planes = kept
	return true


## Lay out the six outward planes of an axis-aligned box `size` across, centred on the brush's own
## origin. For an axis plane at ±h the distance is h either way, because the normal flips with the
## side. Assigning `planes` rebuilds, so the brush is a finished box when this returns.
##
## This is the CONSTRUCTION path for a cuboid — `Brush.new()`, `set_box(size)`, then add it to the
## tree — and the fallback _ready uses for a brush that arrived with no planes at all. It is a
## method rather than a `box_size` property because a box is something a brush is BUILT as, not a
## property it goes on having: `planes` is the source of truth from here on, and one drag of a
## vertex leaves any remembered size describing a shape the brush no longer has.
func set_box(size: Vector3) -> void:
	# Floored so a zero or negative extent can't produce a degenerate or inside-out solid.
	var h := Vector3(maxf(size.x, 0.001), maxf(size.y, 0.001), maxf(size.z, 0.001)) * 0.5
	planes = [
		Plane(Vector3.RIGHT, h.x), Plane(Vector3.LEFT, h.x),
		Plane(Vector3.UP, h.y), Plane(Vector3.DOWN, h.y),
		Plane(Vector3.BACK, h.z), Plane(Vector3.FORWARD, h.z),
	]   # setter rebuilds


# --- Faces from planes ----------------------------------------------------

## Polygon of face `index`, cached. Empty when the face has been cut away entirely.
func face_polygon(index: int) -> PackedVector3Array:
	if _poly_cache.size() != planes.size():
		_poly_cache.resize(planes.size())
	if _poly_cache[index] == null:
		_poly_cache[index] = _compute_face_polygon(index)
	return _poly_cache[index]


## A huge quad on the plane, clipped by every other plane.
func _compute_face_polygon(index: int) -> PackedVector3Array:
	return _polygon_for(planes[index], planes, index)


## The polygon a plane cuts out of the solid bounded by `bounds`, or empty if it contributes no
## face at all. [param skip] is the plane's own index when it is one of them (a plane must not
## clip itself); pass -1 for a plane from outside the set, which is how the clip tool previews a
## cut before committing to it.
func _polygon_for(plane: Plane, bounds: Array, skip: int) -> PackedVector3Array:
	var u := _perpendicular(plane.normal)
	var v := plane.normal.cross(u).normalized()
	var origin := plane.normal * plane.d
	var poly := PackedVector3Array([
		origin + (u + v) * BIG, origin + (v - u) * BIG,
		origin - (u + v) * BIG, origin + (u - v) * BIG])

	for other in bounds.size():
		if other == skip:
			continue
		poly = _clip(poly, bounds[other])
		if poly.size() < 3:
			return PackedVector3Array()

	# Clipping leaves duplicate points wherever a plane passes exactly through a corner, and
	# COLLINEAR points wherever one merely grazes an edge. Both produce bogus "edges": the
	# first zero-length, the second a sliver whose midpoint sits on top of a real vertex.
	poly = _drop_collinear(_dedupe(poly))
	if poly.size() < 3:
		return PackedVector3Array()

	# Make the winding counter-clockwise as seen from outside (Newell normal along the plane).
	if _polygon_normal(poly).dot(plane.normal) < 0.0:
		poly.reverse()
	return poly


## Keep only genuine corners: a point whose neighbours run straight through it isn't one, and
## leaving it in splits a single edge into two, one of which can be vanishingly short.
func _drop_collinear(poly: PackedVector3Array) -> PackedVector3Array:
	var count := poly.size()
	if count < 3:
		return poly
	var out := PackedVector3Array()
	for i in count:
		var previous := poly[(i - 1 + count) % count]
		var current := poly[i]
		var next := poly[(i + 1) % count]
		var into := current - previous
		var away := next - current
		if into.length_squared() < weld_sq() or away.length_squared() < weld_sq():
			continue
		# Cross product of the unit directions is ~0 when the path doesn't turn here.
		if into.normalized().cross(away.normalized()).length() < 0.0005:
			continue
		out.append(current)
	return out if out.size() >= 3 else poly


## Drop consecutive duplicate points, including the wrap-around pair.
func _dedupe(poly: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for point in poly:
		if out.size() > 0 and out[out.size() - 1].distance_squared_to(point) < weld_sq():
			continue
		out.append(point)
	while out.size() > 1 and out[0].distance_squared_to(out[out.size() - 1]) < weld_sq():
		out.resize(out.size() - 1)
	return out


## Sutherland-Hodgman: keep the part of `poly` inside the half-space (distance <= 0).
func _clip(poly: PackedVector3Array, plane: Plane) -> PackedVector3Array:
	var out := PackedVector3Array()
	var count := poly.size()
	for i in count:
		var a := poly[i]
		var b := poly[(i + 1) % count]
		var da := plane.distance_to(a)
		var db := plane.distance_to(b)
		if da <= EPS:
			out.append(a)
		if (da > EPS and db < -EPS) or (da < -EPS and db > EPS):
			out.append(a.lerp(b, da / (da - db)))
	return out


func _polygon_normal(poly: PackedVector3Array) -> Vector3:
	var n := Vector3.ZERO
	var count := poly.size()
	for i in count:
		var a := poly[i]
		var b := poly[(i + 1) % count]
		n += Vector3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
	return n


func _perpendicular(n: Vector3) -> Vector3:
	var helper := Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT
	return n.cross(helper).normalized()


## Every distinct corner of the solid, in local space — what the vertex tool grabs.
func get_vertices() -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in planes.size():
		for point in face_polygon(i):
			var duplicate_found := false
			for existing in out:
				if existing.distance_squared_to(point) < weld_sq():
					duplicate_found = true
					break
			if not duplicate_found:
				out.append(point)
	return out


## Centroid of a face's polygon, in local space — where the face tool's handle sits.
## Returns Vector3.INF for a face that's been clipped away entirely.
func face_center(index: int) -> Vector3:
	var poly := face_polygon(index)
	if poly.size() < 3:
		return Vector3.INF
	var total := Vector3.ZERO
	for point in poly:
		total += point
	return total / poly.size()


## SQUARED distance below which two points are the SAME corner, scaled to the grid.
##
## Every real corner is a grid point, so two of them are at least a cell apart — anything much
## closer is float noise or a degenerate pinch (where 3+ planes converge, clipping emits two
## corners a hair apart and they show up as a hair-length edge with a handle on top of a
## vertex). 2% of a cell is far below any real feature and far above the noise.
##
## Everything that compares points must use THIS — the polygon dedupe, the vertex list, the
## edge list, and the plugin's index lookup. Mismatched tolerances between those have been the
## single most common source of bugs in this system.
func weld_sq() -> float:
	var w := maxf(1e-4, grid_size * 0.02)
	return w * w


## Every distinct edge, as consecutive pairs [a0, b0, a1, b1, ...] in local space. Each edge
## is shared by exactly two faces, so we dedupe ignoring direction.
func get_edges() -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in planes.size():
		var poly := face_polygon(i)
		var count := poly.size()
		for k in count:
			var a := poly[k]
			var b := poly[(k + 1) % count]
			if a.distance_squared_to(b) < weld_sq():
				continue        # degenerate: its midpoint would sit on a vertex
			var known := false
			for e in range(0, out.size(), 2):
				if (out[e].distance_squared_to(a) < weld_sq() and out[e + 1].distance_squared_to(b) < weld_sq()) \
						or (out[e].distance_squared_to(b) < weld_sq() and out[e + 1].distance_squared_to(a) < weld_sq()):
					known = true
					break
			if not known:
				out.append(a)
				out.append(b)
	return out


## The polygon this plane would cut out of the brush, in LOCAL space — the cross-section. Empty
## if the plane misses the brush entirely, which is also how the clip tool knows a cut does
## nothing here.
func cross_section(plane: Plane) -> PackedVector3Array:
	return _polygon_for(plane, planes, -1)


## Every face of the piece of this brush that lies INSIDE `plane`, in local space, as
## {poly, normal} pairs.
##
## Same construction as a clip, but nothing is assigned — so the clip tool can show the chunk it
## is about to remove without touching the brush. Pass the flipped clip plane to get the
## discarded piece rather than the kept one.
##
## The OUTWARD NORMAL is returned alongside each polygon rather than left to be re-derived: a
## caller that wants to draw only the faces pointing at it would otherwise have to guess the
## winding convention, and getting that backwards silently draws every face instead of half.
func section_polygons(plane: Plane) -> Array:
	var merged: Array[Plane] = planes.duplicate()
	merged.append(plane)
	var out := []
	for i in merged.size():
		var poly := _polygon_for(merged[i], merged, i)
		if poly.size() >= 3:
			out.append({"poly": poly, "normal": merged[i].normal})
	return out


## The existing face a cut along `plane` should take its look from: whichever points most nearly
## the same way. Shared by the real clip and its preview so the two can't disagree.
func _donor_face(plane: Plane) -> int:
	var donor := -1
	var best := INF
	for i in planes.size():
		var difference: float = (planes[i].normal - plane.normal).length_squared()
		if difference < best:
			best = difference
			donor = i
	return donor


## What a cut face would end up looking like — the real texture and its UV mapping, so the clip
## preview can bake matching UVs and show the actual surface rather than a flat colour. Returns
## {material, u, v, offset} or null. The caller bakes UV = dot(world_point, u) + offset per vertex,
## the same rule _build_mesh uses, so the preview lines up with the brush's other faces.
func cut_face_mapping(plane: Plane):
	var donor := _donor_face(plane)
	if donor < 0 or donor >= _face_tex.size():
		return null
	return {"material": _material_for(_face_tex[donor]),
		"u": _face_axis_u[donor], "v": _face_axis_v[donor], "offset": _face_offset[donor]}


## Clip the brush with a plane, discarding everything on the plane's OUTWARD side. Returns false
## if nothing solid survives, in which case the caller should delete the brush.
##
## This is the whole clip operation, and it's this small because a brush IS an intersection of
## half-spaces: cutting one just adds another half-space. The manual's "removing other planes
## from it if they become superfluous" falls out too — after the cut, any plane whose polygon
## has vanished no longer bounds anything, so it is dropped in the same assignment. Without that
## the plane list would grow on every clip and never shrink.
func clip_by(plane: Plane) -> bool:
	# The cut face inherits its look from whichever EXISTING face points most nearly the same
	# way. A fresh face with the default texture would stand out against the brush it came from,
	# and this is nearly always what you'd have picked by hand. Chosen BEFORE the clip, while
	# the original faces are still here.
	var donor := _donor_face(plane)
	var before := face_data

	var merged: Array[Plane] = planes.duplicate()
	merged.append(plane)
	var kept: Array[Plane] = []
	for i in merged.size():
		if _polygon_for(merged[i], merged, i).size() >= 3:
			kept.append(merged[i])
	if kept.size() < 4:
		return false          # fewer than 4 faces cannot bound a solid
	planes = kept

	if donor >= 0:
		var index := kept.find(plane)
		if index >= 0:
			var data := face_data
			data["tex"][index] = before["tex"][donor]
			data["u"][index] = before["u"][donor]
			data["v"][index] = before["v"][donor]
			data["offset"][index] = before["offset"][donor]
			face_data = data
	return true


## Move the node's origin to the centre of the brush's own geometry WITHOUT moving the brush:
## the planes shift back by exactly what the origin shifts forward, so nothing changes on screen.
##
## Worth doing because the shape-changing tools (vertex/edge/face drags, scale, shear) rewrite
## the geometry in local space and leave `position` where it was, so the origin drifts away from
## the brush — Godot's own gizmo and the inspector's position field slowly stop matching it. The
## rigid operations (move, rotate, flip) carry the origin along and need no correction.
##
## Deliberately not 0,0,0: mesh vertices are 32-bit, so a brush far from the world origin would
## carry huge local coordinates and lose precision — and our corners are re-derived by clipping
## on every edit, which is exactly where that error would compound.
func recenter() -> void:
	if planes.size() < 4 or not is_inside_tree():
		return
	var points := get_vertices()
	if points.is_empty():
		return
	var low := points[0]
	var high := points[0]
	for p in points:
		low = low.min(p)
		high = high.max(p)
	var offset := (low + high) * 0.5
	if offset.length_squared() < 1e-12:
		return                    # already centred; skip the churn

	# The UV state must survive untouched. Assigning `planes` runs the carry, and under UV lock
	# a pure translation moves EVERY corner of every face — no unmoved corners, so the lock
	# would happily solve for a transform and shift the axes. Moving the node then fires
	# NOTIFICATION_TRANSFORM_CHANGED and texture lock compensates for a move that never
	# happened. Restoring the snapshot last undoes both; nothing here changes world geometry.
	var keep := face_data
	var shifted: Array[Plane] = []
	for p in planes:
		# n·(x + offset) <= d  =>  n·x <= d - n·offset
		shifted.append(Plane(p.normal, p.d - p.normal.dot(offset)))
	planes = shifted
	global_position = global_position + global_transform.basis * offset
	face_data = keep


## Rebuild the brush as the CONVEX HULL of `points`.
##
## This is how vertex dragging has to work. A box has 8 corners but only 6 planes, so sliding
## the planes that meet at a corner just moves three whole faces — i.e. resizes the box. Moving
## a single vertex means changing the point set and re-solving the hull, which is what lets new
## faces appear (and old ones vanish), exactly like TrenchBroom.
## [param snap] grid-snaps every corner. Every in-tree tool passes FALSE — the vertex, edge and face
## handles snap the DELTA they drag and leave the rest of the brush alone, and scale and shear
## rebuild from the drag-start corners through an exact affine map, where snapping the result would
## force the vertices back onto integers and distort the transform. TrenchBroom behaves the same way:
## only the edited element snaps, and the other corners land wherever the geometry puts them.
##
## So the default of true is for callers that build a brush from scratch out of already-snapped
## corners (the hull tool), not for reshaping an existing one.
##
## Snapping is therefore about INTENT — which lattice a corner belongs on — and is NOT what keeps a
## hull from fanning one face into a dozen. That job belongs to HULL_MIN_ALTITUDE, which applies
## whatever `snap` is.
func set_from_points(points: PackedVector3Array, snap := true) -> void:
	var g := grid_size
	# Snap in WORLD space, not local. The brush's local origin is the box CENTRE, which sits
	# half a cell off the grid whenever a dimension is an odd number of cells — so snapping
	# local coordinates would pull every corner onto a DIFFERENT lattice than the one the draw
	# tool used, and the whole mesh jumps the instant a drag begins.
	var to_world := global_transform if is_inside_tree() else Transform3D.IDENTITY
	var to_local := to_world.affine_inverse()
	var cleaned := PackedVector3Array()
	for p in points:
		var candidate := p
		if snap:
			var world: Vector3 = to_world * p
			candidate = to_local * Vector3(
				snappedf(world.x, g), snappedf(world.y, g), snappedf(world.z, g))
		# Dedupe: coincident corners keep `n` high and fill the hull with degenerate triples —
		# the solve is O(n^4), so that is what turns a bad brush into a hang.
		var seen := false
		for existing in cleaned:
			if existing.distance_squared_to(candidate) < weld_sq():
				seen = true
				break
		if not seen:
			cleaned.append(candidate)
	if cleaned.size() > MAX_HULL_POINTS:
		push_warning("Brush: %d points is past the hull limit; ignoring edit." % cleaned.size())
		return
	var hull := _hull_planes(cleaned)
	if hull.size() >= 4:      # ignore degenerate results (all points coplanar/collinear)
		planes = hull


## Brute-force hull: every triple of points defines a candidate plane, and it's a hull face if
## all the other points lie on one side of it. O(n^4), but n is a handful of corners so this is
## far cheaper than it looks — and it's exact, unlike an incremental hull with epsilon drift.
##
## A triple is only allowed to vote if it is well enough conditioned to mean anything: see
## HULL_MIN_ALTITUDE, which is what stops one flat face fanning into dozens of phantoms.
func _hull_planes(points: PackedVector3Array) -> Array[Plane]:
	var out: Array[Plane] = []
	var count := points.size()
	if count < 3:
		return out
	# The conditioning threshold scales with the brush, so measure it once from the cloud itself
	# rather than per triple.
	var low := points[0]
	var high := points[0]
	for p in points:
		low = low.min(p)
		high = high.max(p)
	var min_altitude := (high - low).length() * HULL_MIN_ALTITUDE
	# Duplicate planes bound a razor-thin wedge, which shows up as a sliver face and a phantom
	# corner. Grid-snapped input keeps genuine duplicates float-identical, so the tight
	# threshold catches them without touching real folds.
	for i in count:
		for j in range(i + 1, count):
			for k in range(j + 1, count):
				var a := points[i]
				var b := points[j]
				var c := points[k]
				# Reject the triple unless its thinnest altitude clears the threshold. The cross
				# product is twice the triangle's area, so area*2/longest edge is the distance from
				# the most in-line corner to the line through the other two — exactly how much
				# evidence this triple actually offers about the plane's tilt.
				var twice_area := (b - a).cross(c - a).length()
				var longest := maxf((b - a).length(), maxf((c - a).length(), (c - b).length()))
				if longest <= 0.0 or twice_area / longest < min_altitude:
					continue                      # too near-collinear to fix a plane
				var candidate := Plane(a, b, c)
				if candidate.normal.length_squared() < 0.5:
					continue                      # the three points are collinear
				var any_above := false
				var any_below := false
				for m in count:
					var d := candidate.distance_to(points[m])
					if d > EPS:
						any_above = true
					elif d < -EPS:
						any_below = true
					if any_above and any_below:
						break
				if any_above and any_below:
					continue                      # points on both sides: not a hull face
				# Orient outward, so "inside" stays distance <= 0.
				var face := Plane(-candidate.normal, -candidate.d) if any_above else candidate
				var known := false
				for existing in out:
					if existing.normal.dot(face.normal) > PLANE_MERGE_DOT \
							and absf(existing.d - face.d) < PLANE_MERGE_DIST:
						known = true
						break
				if not known:
					out.append(face)
	return out


# --- Per-face texture API -------------------------------------------------

## Texel size of what a face wears. The projection axes are TILES per metre while TrenchBroom's
## scale is TEXELS per unit, and the texture's own pixel size is the whole of the difference: at
## scale 1 a texture covers exactly its own pixel count in TB units, so a 64x128 image spans
## 64x128 units (2m x 4m) rather than one tile per metre whatever its size.
func _face_texel_size(face: int) -> Vector2:
	if face >= 0 and face < _face_tex.size():
		var tex: Texture2D = _face_tex[face]
		if tex != null:
			var size := tex.get_size()
			if size.x > 0.0 and size.y > 0.0:
				return size
	return DEFAULT_TEX_SIZE


## Default axes for a face: TrenchBroom's scale 1, i.e. the texture at its own pixel size.
func _default_axes(face: int, n: Vector3) -> Array:
	var base := _uv_axes(n)
	var size := _face_texel_size(face)
	return [(base[0] as Vector3) * (UNITS_PER_METER / size.x),
		(base[1] as Vector3) * (UNITS_PER_METER / size.y)]


## Hold a face's SCALE NUMBER across a texture swap, so the incoming texture lands at the same
## texel scale and therefore at its own pixel size — TrenchBroom keeps `scale` as an attribute, so
## a tile's world size follows the texture rather than the texture being squeezed into the old
## tile. Axes are tiles per metre and the offset is in tiles, so both scale by the ratio of the two
## texel sizes; that is also what keeps the offset a fixed number of TEXELS, as TB stores it.
func _hold_texel_scale(face: int, before: Vector2) -> void:
	var after := _face_texel_size(face)
	if before.x <= 0.0 or before.y <= 0.0 or after.x <= 0.0 or after.y <= 0.0:
		return
	var fx := before.x / after.x
	var fy := before.y / after.y
	if is_equal_approx(fx, 1.0) and is_equal_approx(fy, 1.0):
		return
	_face_axis_u[face] = _face_axis_u[face] * fx
	_face_axis_v[face] = _face_axis_v[face] * fy
	_face_offset[face] = Vector2(_face_offset[face].x * fx, _face_offset[face].y * fy)


func set_face_texture(face: int, tex: Texture2D) -> void:
	_ensure_face_defaults()
	var before := _face_texel_size(face)
	_face_tex[face] = tex if tex != null else DEFAULT_TEXTURE
	_face_material[face] = null   # a texture drops any material override: back to StandardMaterial3D
	_hold_texel_scale(face, before)
	_rebuild()


## Give a face a full Material to render with, replacing the StandardMaterial3D that a texture would
## get (Godot's "assign a material" model). The baked UVs still apply, so a material that samples UV1
## respects the face's offset/scale/angle. Cleared by set_face_texture.
func set_face_material(face: int, mat: Material) -> void:
	_ensure_face_defaults()
	if face < 0 or face >= planes.size():
		return
	var before := _face_texel_size(face)
	_face_material[face] = mat
	# Sync the texture slot to the material's albedo (or the empty default) rather than leaving the
	# now-irrelevant previous texture behind: keeps face_data coherent and makes the UV canvas and
	# offset-in-pixels reflect what the material actually shows.
	_face_tex[face] = _surface_texture_of(mat)
	_hold_texel_scale(face, before)
	_rebuild()


## What the face wears: its Material override if it has one, else its Texture2D. This is the unit the
## texture browser, in-use highlighting and the right-click actions all key on.
func face_surface(face: int) -> Resource:
	if face >= 0 and face < _face_material.size() and _face_material[face] != null:
		return _face_material[face]
	if face >= 0 and face < _face_tex.size():
		return _face_tex[face]
	return null


## The face's outline in a 2D frame built from the UNIT base axes — the FIXED shape the visual UV
## editor draws. Depending only on the normal, never on the current mapping, is what keeps the
## outline still while offset/scale/angle change, and it stays in world units so the outline is the
## face at its true proportions. Paired with face_uv_polygon (same vertices), the two define the
## affine map used to paint the texture behind the outline.
##
## The frames are NOT equal at scale 1: the axes there are 32/texel-size, so they match only for a
## 32x32 texture. The canvas is unaffected — it derives its map from the two polygons it is handed —
## and the texture is then drawn at its true size relative to the face, which is the point.
func face_local_polygon(face: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	if face < 0 or face >= planes.size():
		return out
	var poly := face_polygon(face)
	if poly.size() < 3:
		return out
	var axes := _uv_axes(planes[face].normal)
	var e1: Vector3 = axes[0]
	var e2: Vector3 = axes[1]
	var to_world := global_transform if is_inside_tree() else Transform3D.IDENTITY
	for p in poly:
		var world: Vector3 = to_world * p
		out.append(Vector2(world.dot(e1), world.dot(e2)))
	return out


## The face's outline in UV (tile) space — each vertex projected exactly as the mesh bakes it
## (world_vertex · axis + offset). Drives the visual UV editor's face outline.
func face_uv_polygon(face: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	if face < 0 or face >= planes.size():
		return out
	_ensure_face_defaults()
	var to_world := global_transform if is_inside_tree() else Transform3D.IDENTITY
	var u: Vector3 = _face_axis_u[face]
	var v: Vector3 = _face_axis_v[face]
	var off: Vector2 = _face_offset[face]
	for p in face_polygon(face):
		var world: Vector3 = to_world * p
		out.append(Vector2(world.dot(u), world.dot(v)) + off)
	return out


## Read a face's UV as intuitive parameters: offset (tile units), per-axis SIGNED scale (world size
## of one tile along that axis — unit base = 1; negative = that axis is mirrored), and angle (degrees
## CCW about the face normal). Decomposed from the stored projection axes against the paraxial base.
## First pass: assumes the U/V axes stay orthogonal (no UV shear), which brush faces normally do.
##
## The angle is folded to (-90°, 90°]: a U axis rotated past that range is reported as the smaller
## angle plus a NEGATIVE scale.x (a horizontal flip). This makes Flip U / Flip V show up as a sign
## flip on scale X / scale Y with the angle unchanged, matching TrenchBroom, instead of a 180° turn.
func get_face_uv(face: int) -> Dictionary:
	_ensure_face_defaults()
	if face < 0 or face >= planes.size():
		return {"offset": Vector2.ZERO, "scale": Vector2.ONE, "angle": 0.0}
	var n: Vector3 = planes[face].normal
	var base: Array = _uv_axes(n)
	var base_u: Vector3 = base[0]
	var base_v: Vector3 = base[1]
	var u: Vector3 = _face_axis_u[face]
	var v: Vector3 = _face_axis_v[face]
	var len_u := u.length()
	var len_v := v.length()

	var angle := 0.0
	if len_u > 0.000001:
		# Angle base_u -> u about the normal, normalised to [0, 360).
		var raw := atan2(base_u.cross(u / len_u).dot(n), base_u.dot(u / len_u))
		if raw < 0.0:
			raw += TAU
		angle = raw

	# scale.y carries the frame's handedness, so a V flip is visible in the fields (scale.x stays
	# positive). With a full 0–360 angle a U flip reads as a 180° rotation rather than a sign flip.
	var sign_y := 1.0
	if len_u > 0.000001 and len_v > 0.000001:
		if signf(u.cross(v).dot(n)) != signf(base_u.cross(base_v).dot(n)):
			sign_y = -1.0

	# TrenchBroom's scale: TEXELS per unit, so 1 means the texture at its own pixel size. The axes
	# are tiles per metre, and the texture's pixel size is the whole of the conversion.
	var size := _face_texel_size(face)
	var scale := Vector2(
		UNITS_PER_METER / (len_u * size.x) if len_u > 0.000001 else 1.0,
		sign_y * UNITS_PER_METER / (len_v * size.y) if len_v > 0.000001 else 1.0)
	return {"offset": _face_offset[face], "scale": scale, "angle": rad_to_deg(angle)}


## Set only a face's UV offset (tile units), leaving its projection axes untouched. Direct, so it
## never disturbs scale/angle (unlike routing through set_face_uv, which rebuilds the axes).
func set_face_offset(face: int, offset: Vector2) -> void:
	_ensure_face_defaults()
	if face < 0 or face >= planes.size():
		return
	_face_offset[face] = offset
	_rebuild()


## Rebuild a face's projection axes from offset (tile units), per-axis scale and angle (degrees) —
## the inverse of get_face_uv. Axes are the paraxial base rotated by `angle` about the normal, each
## divided by its scale.
func set_face_uv(face: int, offset: Vector2, scale: Vector2, angle_deg: float) -> void:
	_ensure_face_defaults()
	if face < 0 or face >= planes.size():
		return
	var n: Vector3 = planes[face].normal.normalized()
	var base: Array = _uv_axes(n)
	var rot := Basis(n, deg_to_rad(angle_deg))
	var sx: float = scale.x if absf(scale.x) > 0.000001 else 1.0
	var sy: float = scale.y if absf(scale.y) > 0.000001 else 1.0
	# Inverse of get_face_uv: `scale` is TrenchBroom's texels per unit, so the texture's pixel size
	# converts it back to the tiles-per-metre the axes are in.
	var size := _face_texel_size(face)
	_face_axis_u[face] = (rot * (base[0] as Vector3)) * (UNITS_PER_METER / (sx * size.x))
	_face_axis_v[face] = (rot * (base[1] as Vector3)) * (UNITS_PER_METER / (sy * size.y))
	_face_offset[face] = offset
	_rebuild()


## Copy another face's UV alignment onto face `dst` of this brush — the geometry half of
## TrenchBroom's ALT+click UV transfer. `src_brush`/`src_face`
## name the source (may be this same brush); the surface itself is copied separately by the plugin.
## [param mode]:
##   "projection" — adopt the source's world-space UV axes, snapped to the nearest 90° orientation
##                  for this face's normal (may stretch when the two normals differ a lot).
##   "rotation"   — rotate the source's UV axes onto this face's normal (no stretch).
## The offset is then re-solved so the mapping agrees at a point on the seam (the line the two faces'
## planes share), making the texture continuous across the shared edge. Parallel planes share no
## seam, so the source offset carries directly — exactly right for a coplanar/parallel copy.
##
## Duckboard stores explicit world-space per-face axes, i.e. it IS TrenchBroom's PARALLEL (Valve 220)
## UV system, so both modes transfer the mapping the way TrenchBroom does for parallel faces.
func copy_face_uv_from(src_brush: Brush, src_face: int, dst: int, mode: String) -> void:
	_ensure_face_defaults()
	src_brush._ensure_face_defaults()
	if dst < 0 or dst >= planes.size() or src_face < 0 or src_face >= src_brush.planes.size():
		return
	var u_s: Vector3 = src_brush._face_axis_u[src_face]
	var v_s: Vector3 = src_brush._face_axis_v[src_face]
	var o_s: Vector2 = src_brush._face_offset[src_face]
	# Face normals in WORLD space — the axes and offset already live in world space.
	var n_s := (src_brush.global_transform.basis * src_brush.planes[src_face].normal).normalized()
	var n_t := (global_transform.basis * planes[dst].normal).normalized()

	var u_new := u_s
	var v_new := v_s
	if mode == "rotation":
		var axis := n_s.cross(n_t)
		if axis.length_squared() > 1e-12:
			var turn := Basis(axis.normalized(), n_s.angle_to(n_t))
			u_new = turn * u_s
			v_new = turn * v_s
	else:   # "projection"
		var snapped := _project_uv_axes(u_s, v_s, n_s, n_t)
		u_new = snapped[0]
		v_new = snapped[1]

	# Pin the mapping at a point on the seam so the texture runs continuously across the edge.
	var new_off := o_s
	if n_s.cross(n_t).length_squared() > 1e-9:
		var src_ref := src_brush.global_transform * src_brush._centroid(src_brush.face_polygon(src_face))
		var dst_ref := global_transform * _centroid(face_polygon(dst))
		var ref := _seam_reference(Plane(n_s, src_ref), Plane(n_t, dst_ref), dst_ref)
		var desired := Vector2(ref.dot(u_s), ref.dot(v_s)) + o_s
		new_off = desired - Vector2(ref.dot(u_new), ref.dot(v_new))

	_face_axis_u[dst] = u_new
	_face_axis_v[dst] = v_new
	_face_offset[dst] = new_off
	_rebuild()


## The source UV axes rotated by a MULTIPLE of 90° so their frame's normal best matches `n_t`, or
## returned unchanged when the source orientation already matches best — the projection copy as
## TrenchBroom does it. Keeps the world-space axes as verbatim as possible (hence the possible
## stretch on a very different normal). Robust to the axis handedness convention: it derives whether
## u×v runs along +normal or −normal from the SOURCE and matches the target the same way.
func _project_uv_axes(u_s: Vector3, v_s: Vector3, n_s: Vector3, n_t: Vector3) -> Array:
	var un_s := u_s.cross(v_s)
	if un_s.length_squared() < 1e-12:
		return [u_s, v_s]
	var target_n := signf(un_s.normalized().dot(n_s)) * n_t
	var cands := [[u_s, v_s], [v_s, u_s]]
	for spec in [[u_s, 90.0], [u_s, -90.0], [v_s, 90.0], [v_s, -90.0]]:
		var r := Basis((spec[0] as Vector3).normalized(), deg_to_rad(spec[1] as float))
		cands.append([r * u_s, r * v_s])
	var best := 0
	var best_dot := -INF
	for i in cands.size():
		var cn: Vector3 = (cands[i][0] as Vector3).cross(cands[i][1] as Vector3)
		if cn.length_squared() < 1e-12:
			continue
		var d := cn.normalized().dot(target_n)
		if d > best_dot:
			best_dot = d
			best = i
	# Index 0 (no change) and 1 (180° flip) both mean "keep the source axes"; only a real 90°
	# rotation is adopted, matching TrenchBroom.
	return cands[best] if best >= 2 else [u_s, v_s]


# --- CSG support (cross-brush geometry) -----------------------------------

## A world-space description of every bounding face, for CSG and any other operation that reasons
## about several brushes at once. Each entry is {plane, u, v, offset, tex, material, points}: the PLANE
## is in world space (outward normal), the UV axes/offset are already world-space (they always are —
## see the note on copy_face_uv_from), so a face copied onto another brush keeps its exact projection
## regardless of either brush's transform, and `points` is the face polygon in WORLD space (for
## exporters that need three points on the plane, e.g. the .map writer). Faces that bound nothing (a
## plane clipped away entirely) are skipped, so the list is exactly the solid's real faces.
func world_faces() -> Array:
	var out := []
	for i in planes.size():
		var f := world_face(i)
		if not f.is_empty():
			out.append(f)
	return out


## The single world-space FACE dict for one plane index — the same {plane, u, v, offset, tex, material,
## points} entry world_faces() pools, so callers that act on a specific face (e.g. bridging a two-face
## selection into a brush) can pull it by plane index without re-deriving. Returns {} when the plane is
## out of range or bounds nothing (clipped away, fewer than three corners).
func world_face(index: int) -> Dictionary:
	_ensure_face_defaults()
	if index < 0 or index >= planes.size():
		return {}
	var poly := face_polygon(index)
	if poly.size() < 3:
		return {}
	var to_world := global_transform if is_inside_tree() else Transform3D.IDENTITY
	var world_poly := PackedVector3Array()
	for p in poly:
		world_poly.append(to_world * p)
	return {
		"plane": _to_world_plane(planes[index]),
		"u": _face_axis_u[index],
		"v": _face_axis_v[index],
		"offset": _face_offset[index],
		"tex": _face_tex[index],
		"material": _face_material[index],
		"points": world_poly,
	}


## Rebuild this brush from a CSG blueprint — the same {plane, u, v, offset, tex, material} entries
## world_faces() produces, after a merge / subtract / intersect / hollow. The node MUST sit at the
## identity transform (CSG works in world space, so a world plane IS the local plane); the caller
## should recenter() afterwards to pull the origin into the geometry and keep local coordinates small.
##
## Planes are taken VERBATIM — no hull re-solve — so the blueprint is trusted to bound a valid convex
## solid (the CSG core guarantees that and drops degenerate results). Returns false, changing nothing,
## if fewer than four faces were supplied — too few to bound a solid.
func set_world_faces(faces: Array) -> bool:
	if faces.size() < 4:
		return false
	var new_planes: Array[Plane] = []
	for f in faces:
		new_planes.append(f["plane"])
	planes = new_planes   # setter re-derives faces, pads face_data, rebuilds
	var data := {"tex": [], "material": [], "offset": [], "u": [], "v": []}
	for f in faces:
		data["tex"].append(f["tex"])
		data["material"].append(f["material"])
		data["offset"].append(f["offset"])
		data["u"].append(f["u"])
		data["v"].append(f["v"])
	face_data = data   # AFTER planes, whose setter would otherwise clobber these arrays
	return true


## A local plane carried into world space. The normal maps by the inverse-transpose (it transforms
## like a normal, not a point), a point on the plane maps by the full transform, and the new distance
## is read from the two — correct even if the brush is ever scaled.
func _to_world_plane(p: Plane) -> Plane:
	var t := global_transform if is_inside_tree() else Transform3D.IDENTITY
	var n := (t.basis.inverse().transposed() * p.normal).normalized()
	var point := t * (p.normal * p.d)
	return Plane(n, n.dot(point))


# --- UV utility operations (TrenchBroom-style) ----------------------------

## Re-align the texture to the paraxial (world-axis) base orientation with zero offset, keeping the
## current scale. Undoes rotation/skew and re-centres without resizing.
func reset_face_uv(face: int) -> void:
	if face < 0 or face >= planes.size():
		return
	var uv := get_face_uv(face)
	set_face_uv(face, Vector2.ZERO, uv.scale, 0.0)


## Reset to world-aligned defaults: paraxial base axes, zero offset, unit scale.
func world_align_face_uv(face: int) -> void:
	set_face_uv(face, Vector2.ZERO, Vector2.ONE, 0.0)


## Fit the texture to the face: scale it to the NEAREST whole number of repeats that spans the face
## each way, then offset it so the first repeat starts exactly at the face's corner. The texture may
## still tile — fitting a long wall to one repeat would stretch it unrecognisably — but no repeat is
## left cut off at an edge, which is the fiddly part to do by hand.
##
## Nearest rather than ceil: a face measuring 2.1 repeats wants two slightly stretched ones, not
## three squashed ones. Rotation is deliberately untouched, so a texture turned to follow an angled
## face keeps its angle and only its scale and offset are solved.
func fit_face_uv(face: int) -> void:
	_ensure_face_defaults()
	if face < 0 or face >= planes.size():
		return
	# Measured through the CURRENT mapping, so the fit is relative to how the face sits now: the
	# span is already in tiles, i.e. in repeats, which is the number being rounded.
	var poly := face_uv_polygon(face)
	if poly.size() < 3:
		return
	var lo := poly[0]
	var hi := poly[0]
	for p in poly:
		lo = lo.min(p)
		hi = hi.max(p)
	var span := hi - lo
	if span.x < 0.000001 or span.y < 0.000001:
		return      # degenerate face (edge-on sliver): nothing to fit to
	var kx := maxf(1.0, roundf(span.x)) / span.x
	var ky := maxf(1.0, roundf(span.y)) / span.y
	# The offset is re-solved rather than scaled: `lo - offset` is the face's corner in RAW axis
	# space, so negating its scaled form lands that corner on the tile boundary at zero. Doing it
	# in one step keeps the corner exact instead of accumulating a rounding drift per fit.
	var off: Vector2 = _face_offset[face]
	_face_axis_u[face] = _face_axis_u[face] * kx
	_face_axis_v[face] = _face_axis_v[face] * ky
	_face_offset[face] = Vector2(-kx * (lo.x - off.x), -ky * (lo.y - off.y))
	_rebuild()


## Mirror the texture by negating a projection axis (U or V).
func flip_face_u(face: int) -> void:
	_ensure_face_defaults()
	if face < 0 or face >= planes.size():
		return
	_face_axis_u[face] = -_face_axis_u[face]
	_rebuild()


func flip_face_v(face: int) -> void:
	_ensure_face_defaults()
	if face < 0 or face >= planes.size():
		return
	_face_axis_v[face] = -_face_axis_v[face]
	_rebuild()


## Rotate the UV projection by `degrees` about the face normal (both axes together). Positive is
## counter-clockwise looking along the normal toward the face.
func rotate_face_uv(face: int, degrees: float) -> void:
	_ensure_face_defaults()
	if face < 0 or face >= planes.size():
		return
	var rot := Basis(planes[face].normal.normalized(), deg_to_rad(degrees))
	_face_axis_u[face] = rot * _face_axis_u[face]
	_face_axis_v[face] = rot * _face_axis_v[face]
	_rebuild()


## Set the mapping to an ABSOLUTE angle while pinning it at `pivot_uv`: the world point that
## currently maps to pivot_uv still maps to it afterwards, so the texture visibly rotates about
## that point — TrenchBroom's rotate-about-origin. Falls back to a plain angle set when the pivot
## can't be resolved (degenerate face or mapping).
func set_face_angle_about(face: int, angle_deg: float, pivot_uv: Vector2) -> void:
	_ensure_face_defaults()
	if face < 0 or face >= planes.size():
		return
	var pivot_world = _face_point_for_uv(face, pivot_uv)   # resolved BEFORE the mapping changes
	var uv := get_face_uv(face)
	set_face_uv(face, uv.offset, uv.scale, angle_deg)
	if pivot_world == null:
		return
	var p: Vector3 = pivot_world
	set_face_offset(face, pivot_uv
		- Vector2(p.dot(_face_axis_u[face]), p.dot(_face_axis_v[face])))


## Set the mapping to an ABSOLUTE per-axis scale while pinning it at `pivot_uv`: the world point
## that currently maps to pivot_uv still maps to it afterwards, so the texture visibly scales about
## that point — TrenchBroom's scale-about-origin. Keeps the current angle. Same pivot maths as
## set_face_angle_about; falls back to a plain scale set when the pivot can't be resolved.
func set_face_scale_about(face: int, scale: Vector2, pivot_uv: Vector2) -> void:
	_ensure_face_defaults()
	if face < 0 or face >= planes.size():
		return
	var pivot_world = _face_point_for_uv(face, pivot_uv)   # resolved BEFORE the mapping changes
	var uv := get_face_uv(face)
	set_face_uv(face, uv.offset, scale, uv.angle)
	if pivot_world == null:
		return
	var p: Vector3 = pivot_world
	set_face_offset(face, pivot_uv
		- Vector2(p.dot(_face_axis_u[face]), p.dot(_face_axis_v[face])))


## The WORLD point on `face` whose current UV is `uv_target` — the inverse of the face's affine
## UV map, restricted to the face's plane (parametrised by an in-plane orthonormal frame, then a
## 2x2 solve). Null when the face or its mapping is degenerate.
func _face_point_for_uv(face: int, uv_target: Vector2):
	var poly := face_polygon(face)
	if poly.size() < 3:
		return null
	var to_world := global_transform if is_inside_tree() else Transform3D.IDENTITY
	var p0: Vector3 = to_world * poly[0]
	var e1: Vector3 = to_world * poly[1] - p0
	if e1.length_squared() < 0.000000000001:
		return null
	e1 = e1.normalized()
	var n: Vector3 = (to_world.basis * planes[face].normal).normalized()
	var e2 := n.cross(e1)
	var u: Vector3 = _face_axis_u[face]
	var v: Vector3 = _face_axis_v[face]
	var col1 := Vector2(e1.dot(u), e1.dot(v))   # d(uv) per metre along e1
	var col2 := Vector2(e2.dot(u), e2.dot(v))   # ... and along e2
	var det := col1.x * col2.y - col1.y * col2.x
	if absf(det) < 0.000000001:
		return null
	var d := uv_target - (Vector2(p0.dot(u), p0.dot(v)) + _face_offset[face])
	return p0 + e1 * ((d.x * col2.y - d.y * col2.x) / det) \
		+ e2 * ((col1.x * d.y - col1.y * d.x) / det)


## Bring every per-face array to exactly planes.size(). Each is normalised INDEPENDENTLY — keying
## the fill off one array crashes _build_mesh when a saved face_data dict has that array full but
## another short or missing. Short arrays are default-filled, long ones truncated.
func _ensure_face_defaults() -> void:
	var count := planes.size()
	# Bounded for-ranges, NOT `while size() < count`: if the append expression ever errors (bad
	# saved data can trigger it), a while that re-measures the array makes no progress and spins
	# forever — the editor freezes in an error loop during scene load. A for-range always
	# terminates; the resize() below squares up anything an error left short.
	for i in range(_face_tex.size(), count):
		_face_tex.append(DEFAULT_TEXTURE)
	for i in range(_face_material.size(), count):
		_face_material.append(null)   # no override: plain texture face
	for i in range(_face_offset.size(), count):
		_face_offset.append(Vector2.ZERO)
	# _face_tex is padded above, so the texel size a default axis needs is already available.
	for i in range(_face_axis_u.size(), count):
		_face_axis_u.append(_default_axes(i, planes[i].normal)[0])
	for i in range(_face_axis_v.size(), count):
		_face_axis_v.append(_default_axes(i, planes[i].normal)[1])
	# Normally every array is now exactly count and this is a no-op truncation guard; only after
	# an append error can it pad (with zeroes) — visibly wrong UVs, but never a crash or a hang.
	_face_tex.resize(count)
	_face_material.resize(count)
	_face_offset.resize(count)
	_face_axis_u.resize(count)
	_face_axis_v.resize(count)


## Captures the OLD polygons as well as the projections — UV lock is solved from the
## correspondence between a face's old and new corners, so the old ring is required.
## Called while `planes` and the polygon cache still hold the previous state.
func _face_snapshot() -> Array:
	_ensure_face_defaults()
	var out := []
	for i in planes.size():
		out.append({
			"tex": _face_tex[i], "material": _face_material[i], "offset": _face_offset[i],
			"u": _face_axis_u[i], "v": _face_axis_v[i],
			"plane": planes[i], "poly": face_polygon(i)})
	return out


## Match each new plane to the old face it came from (closest normal) and inherit its data.
## UV LOCK decides what happens to the projection axes: held, the mapping survives the edit and
## the texture stretches with the geometry; released, the axes re-derive from the new normal,
## which is the classic Quake re-snap — and the visible jump when a face tilts past 45 degrees.
func _carry_face_data(previous: Array[Plane], snapshot: Array) -> void:
	_face_tex = []
	_face_material = []
	_face_offset = []
	_face_axis_u = []
	_face_axis_v = []
	for i in planes.size():
		var n := planes[i].normal
		var best := -1
		var best_dot := 0.7          # below this it is not the same face any more
		for j in previous.size():
			var d := previous[j].normal.dot(n)
			if d > best_dot:
				best_dot = d
				best = j
		if best < 0 or best >= snapshot.size():
			# A face with no ancestor is a NEW one: default texture at TB scale 1. Appended before
			# the axes are derived, so _default_axes can read the texel size it needs.
			_face_tex.append(DEFAULT_TEXTURE)
			_face_material.append(null)
			_face_offset.append(Vector2.ZERO)
			var fresh := _default_axes(_face_tex.size() - 1, n)
			_face_axis_u.append(fresh[0])
			_face_axis_v.append(fresh[1])
			continue
		var record: Dictionary = snapshot[best]
		var u: Vector3 = record.u
		var v: Vector3 = record.v
		var offset: Vector2 = record.offset
		var old_plane: Plane = record.plane
		var new_poly := face_polygon(i)

		# 1. ALWAYS-ON plane reprojection, independent of uv_lock. When a face tilts, its axes
		#    are re-projected onto the new normal and the mapping is pinned at a point on the
		#    seam (the line both planes share) so it doesn't slide. Parallel planes share no
		#    seam, so an outline-only change does nothing at all.
		if absf(old_plane.normal.dot(n)) < 0.99999 and new_poly.size() >= 3:
			var seam_dir := old_plane.normal.cross(n)
			if seam_dir.length_squared() > 1e-12:
				var reference := _seam_reference(old_plane, planes[i], _centroid(new_poly))
				var wanted := Vector2(reference.dot(u), reference.dot(v)) + offset
				var reprojected := _reproject_axes(u, v, n)
				u = reprojected[0]
				v = reprojected[1]
				offset = wanted - Vector2(reference.dot(u), reference.dot(v))

		# 2. UV LOCK: preserve the UVs at the face's own corners, so the texture stretches and
		#    shears with the geometry. TrenchBroom bails when 3+ corners stayed put (you can't
		#    hold 4 corners' UVs while moving one), which is exactly why dragging a single
		#    vertex leaves its own quad untouched but dragging an EDGE — 2 corners moving —
		#    scales the texture on the faces sharing it.
		if uv_lock:
			# Untyped: the solve returns null when it bails (see _uv_lock_transform).
			var m: Variant = _uv_lock_transform(record.poly, new_poly)
			if m != null:
				var inverse: Transform3D = m.affine_inverse()
				# newAxes = oldAxes * M^-1 makes uv_new(M*p) == uv_old(p) for every p. The
				# axes are NOT re-normalised: they absorb M's scale and shear.
				var anchor := _centroid(record.poly)
				var before := Vector2(anchor.dot(u), anchor.dot(v)) + offset
				u = inverse.basis.transposed() * u
				v = inverse.basis.transposed() * v
				var moved_anchor: Vector3 = m * anchor
				offset = before - Vector2(moved_anchor.dot(u), moved_anchor.dot(v))

		_face_tex.append(record.tex)
		_face_material.append(record.material)
		_face_offset.append(offset)
		_face_axis_u.append(u)
		_face_axis_v.append(v)


# --- Mesh generation ------------------------------------------------------

## Full rebuild: re-derives the face polygons (clipping) and builds the mesh. Called when the
## GEOMETRY changes. When only the pose or the UV mapping changed, call _build_mesh directly —
## the polygon cache is still valid and re-clipping every face would be wasted work.
func _rebuild() -> void:
	if planes.size() < 4:
		return
	_ensure_face_defaults()
	_build_mesh()


## Build the mesh from the (cached) face polygons, baking the texture UV into the vertex channel
## and grouping faces by TEXTURE into one surface each.
##
## One surface per texture, one material per surface — so a brush with a single texture is ONE
## draw call instead of one per face. The UV is `dot(world_vertex, axis) + offset`, baked per
## vertex — exact because the mapping is affine.
func _build_mesh() -> void:
	if planes.size() < 4:
		return
	# WORLD transform, so a moved brush bakes UVs from where it actually is. That is what lets a
	# world-fixed texture (lock off) stay put as the brush slides — _notification re-bakes on move.
	var to_world := global_transform if is_inside_tree() else Transform3D.IDENTITY

	# Group face indices by their SURFACE — a face's material override if it has one, else its
	# texture. Same-surface faces share one draw call; the axes live in the vertices, not uniforms.
	var by_surface := {}
	for f in planes.size():
		if face_polygon(f).size() < 3:
			continue        # this face got clipped away entirely
		var mat: Material = _face_material[f] if f < _face_material.size() else null
		var key: Resource = mat if mat != null else _face_tex[f]
		if not by_surface.has(key):
			by_surface[key] = []
		by_surface[key].append(f)

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
	for key in by_surface:
		if drop_untextured and key == DEFAULT_TEXTURE:
			continue
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for f in by_surface[key]:
			var poly := face_polygon(f)
			var n: Vector3 = planes[f].normal
			var u: Vector3 = _face_axis_u[f]
			var v: Vector3 = _face_axis_v[f]
			var off: Vector2 = _face_offset[f]
			# Triangle fan, each triangle reversed for Godot's front-face convention.
			for i in range(1, poly.size() - 1):
				for k in [0, i + 1, i]:
					var world: Vector3 = to_world * poly[k]
					st.set_normal(n)
					st.set_uv(Vector2(world.dot(u), world.dot(v)) + off)
					st.add_vertex(poly[k])
		# A material face renders with its material verbatim; a texture face gets a StandardMaterial3D.
		var surf_mat: Material = key if key is Material else _material_for(key as Texture2D)
		st.set_material(surf_mat)
		st.commit(array_mesh)
		_surface_material.append(surf_mat)
		_surface_tex.append(_surface_texture_of(key))

	mesh = array_mesh
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


## STATIC, and the single implementation: BrushGroup renders the very same faces once they are
## merged, so it calls this rather than keeping a copy. It kept one until alpha scissoring was added
## here and silently did not reach grouped brushes — a duplicate that has to "stay identical" only
## advertises the next time it won't.
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


## The texture that represents a surface for the clip ghost (whose shader samples an albedo): the
## texture itself, a material's albedo if it has one, else the placeholder.
func _surface_texture_of(surface: Resource) -> Texture2D:
	if surface is Texture2D:
		return surface as Texture2D
	if surface is BaseMaterial3D and (surface as BaseMaterial3D).albedo_texture != null:
		return (surface as BaseMaterial3D).albedo_texture
	return DEFAULT_TEXTURE


## The CLIP-preview material for a surface: the ghost shader carrying the same texture plus the
## cut plane. Swapped in only while a clip is being previewed on this brush (see set_clip_ghost),
## because the discard it does can't be expressed by a StandardMaterial3D.
func _clip_material(tex: Texture2D, packed_plane: Vector4) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = FACE_SHADER
	mat.set_shader_parameter("albedo_tex", tex)
	mat.set_shader_parameter("clip_ghost_plane", packed_plane)
	return mat


## Attach the world-space grid as a material_overlay — a second pass over the mesh — but only in
## the editor, so the shipped brush has none of it and the base material stays clean. One overlay
## per brush (it's per-instance, not per-surface); its cell size tracks the grid.
func _apply_grid_overlay() -> void:
	if not Engine.is_editor_hint() or not _grid_overlay_enabled:
		material_overlay = null
		return
	if _grid_material == null:
		_grid_material = ShaderMaterial.new()
		_grid_material.shader = GRID_SHADER
	_grid_material.set_shader_parameter("cell_size", grid_size)
	material_overlay = _grid_material


## The plugin flips this when the map editor is toggled: off hides the face grid so a disabled
## Duckboard leaves plain textured brushes, on brings it back.
func set_grid_overlay_enabled(enabled: bool) -> void:
	if _grid_overlay_enabled == enabled:
		return
	_grid_overlay_enabled = enabled
	_apply_grid_overlay()


## Ghost the part of this brush lying on the plane's OUTWARD side — the side a clip would discard.
##
## Swaps each surface between its plain StandardMaterial3D and the ghost shader, rather than
## pushing a uniform, because the default material is a StandardMaterial3D that has no such
## uniform. Restoring rebuilds the plain materials, which is safe because it happens only at the end
## of a clip interaction, and committing a clip rebuilds the brush from scratch anyway. Pass a
## WORLD-space plane.
func set_clip_ghost(plane: Plane, enabled: bool) -> void:
	var am := mesh as ArrayMesh
	if am == null:
		return
	var packed := Vector4(plane.normal.x, plane.normal.y, plane.normal.z, plane.d)
	for i in am.get_surface_count():
		var tex: Texture2D = _surface_tex[i] if i < _surface_tex.size() else DEFAULT_TEXTURE
		if enabled:
			am.surface_set_material(i, _clip_material(tex, packed))
		else:
			# Restore EXACTLY what was there — a face's custom material, not a re-derived
			# StandardMaterial3D that would wipe it.
			am.surface_set_material(i, _surface_material[i] if i < _surface_material.size() \
				else _material_for(tex))


## The grid cell size lives on the overlay material, not the per-face materials.
func _sync_grid() -> void:
	if _grid_material != null:
		_grid_material.set_shader_parameter("cell_size", grid_size)
