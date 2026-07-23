@tool
extends RefCounted
## Clip tool: up to three clip points define a plane, and applying it adds that plane to every
## selected brush. Three outcomes (keep-front / split / keep-back), cycled with CTRL+RETURN and
## applied with RETURN. Points snap onto real brush faces (TrenchBroom only allows clip points on
## existing geometry), and each point votes for the world axes of the faces it touches so a
## two-point cut can guess its third point along a sensible axis.
##
## Owned by the Duckboard plugin, reached through `host` for the selection, grid, the shared
## face raycast / on-face snap, the unowned clip-preview slot, undo, the draw camera, and the
## shared overlay line/status draws.

const Palette := preload("res://addons/duckboard/palette.gd")

var host: Duckboard

# Up to three clip points define a plane; applying it adds that plane to every selected brush.
# Three outcomes, cycled with CTRL+RETURN and applied with RETURN.
const CLIP_KEEP_FRONT := 0     # discard what's behind the plane
const CLIP_SPLIT := 1          # keep both halves, as two brushes
const CLIP_KEEP_BACK := 2      # discard what's in front
const CLIP_POINT_PX := 5.0
const CLIP_GRAB_PX := 10.0
## Distance to the guessed third point. TrenchBroom uses 128 units; only the DIRECTION matters,
## but the magnitude has to stay well clear of the collinearity epsilon.
const CLIP_THIRD_POINT_DISTANCE := 4.0     # 128 TB units

var points: Array[Vector3] = []      # world space, max 3
## Per point, the world axes voted for by the faces that point touches — TrenchBroom's "help
## vectors". Parallel to `points`. See _help_axis().
var help: Array = []
var mode := CLIP_KEEP_FRONT
var hover                            # Vector3 or null: the orange feedback sphere
var drag_index := -1                 # point being dragged, -1 = none
## A point was just placed by a press and the button is still down. If the cursor then moves, a
## SECOND point is placed and dragged — so click-click and click-drag both give two points.
var pending_drag := false
var press_pos := Vector2.ZERO
var ghosted: Array[Node3D] = []      # brushes currently showing the discard ghost


func _init(p_host: Duckboard) -> void:
	host = p_host


## Where a clip point would land for the cursor, or null when there's no brush face under it.
## In the 3D view TrenchBroom only allows clip points on existing geometry, which is also what
## makes the glue-to-face rule well defined.
func _target(camera: Camera3D, screen_pos: Vector2):
	var hit = host._raycast_brush_faces(
		camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos))
	if hit == null:
		return null
	var point := host._snap_on_face(hit.point, hit.normal, hit.point, host.snap_size)
	return {"point": point, "help": _help_vectors(hit.node, point)}


## The world axes a clip point votes for: the dominant axis of every face it touches.
##
## Touching is decided by which face PLANES the point lies on. For a point on the brush's
## surface that's exact: it sits inside every half-space, so lying on a plane means lying on that
## face. A point in the middle of a face therefore votes once, one on an edge twice, and one on a
## corner three or more times — which is the whole mechanism, since snapping (above) deliberately
## lands points on vertices and edges.
##
## Each normal is reduced to its dominant SIGNED world axis before voting, so a sloped face votes
## exactly as its nearest axis-aligned equivalent would. Nothing here carries a real slope.
func _help_vectors(node: Node3D, world_point: Vector3) -> Array:
	var to_world: Transform3D = node.global_transform
	var local: Vector3 = to_world.affine_inverse() * world_point
	var tolerance: float = sqrt(node.weld_sq())
	var out := []
	for f in node.planes.size():
		if node.face_polygon(f).size() < 3:
			continue
		if absf((node.planes[f] as Plane).distance_to(local)) > tolerance:
			continue
		var axis := _dominant_signed_axis(
			(to_world.basis * (node.planes[f] as Plane).normal).normalized())
		if not out.has(axis):
			out.append(axis)
	return out


func _dominant_signed_axis(n: Vector3) -> Vector3:
	var a := n.abs()
	var axis := 0 if (a.x >= a.y and a.x >= a.z) else (1 if a.y >= a.z else 2)
	var out := Vector3.ZERO
	out[axis] = 1.0 if n[axis] > 0.0 else -1.0
	return out


## Vote across every placed point's help vectors to pick the direction the guessed plane runs
## along. Plurality over six buckets (+X +Y +Z -X -Y -Z); on a tie the up axis wins if it's
## involved, otherwise X. The winner's SIGN is discarded — the third point only fixes the plane's
## orientation, and which side is kept is a separate decision.
func _help_axis() -> Vector3:
	var counts := [0, 0, 0, 0, 0, 0]
	for vectors in help:
		for v in vectors:
			var axis := 0 if absf(v.x) > 0.5 else (1 if absf(v.y) > 0.5 else 2)
			counts[axis if v[axis] > 0.0 else axis + 3] += 1

	var first := 0
	for i in range(1, 6):
		if counts[i] > counts[first]:
			first = i
	var second := -1
	for i in range(first + 1, 6):
		if second < 0 or counts[i] > counts[second]:
			second = i
	if second < 0 or counts[first] > counts[second]:
		return host.MOVE_AXES[first % 3]
	# Tied: prefer up (TrenchBroom prefers Z, its up axis), else X.
	if first % 3 == 1 or second % 3 == 1:
		return Vector3.UP
	return Vector3.RIGHT


## The clip plane implied by the points placed so far, or null if there isn't one yet.
func _current_plane():
	if points.size() >= 3:
		var plane := Plane(points[0], points[1], points[2])
		return null if plane.normal.length_squared() < 0.5 else plane
	if points.size() == 2:
		var third = _third_point()
		if third == null:
			return null
		var plane := Plane(points[0], points[1], third)
		return null if plane.normal.length_squared() < 0.5 else plane
	return null


## The guessed third point: out along the voted-on axis from the second point. The guessed plane
## therefore always CONTAINS the two points and runs along a world axis — it is never tilted to
## match a sloped face.
func _third_point():
	var third: Vector3 = points[1] + _help_axis() * CLIP_THIRD_POINT_DISTANCE
	if _collinear(points[0], points[1], third):
		return null
	return third


func _collinear(a: Vector3, b: Vector3, c: Vector3) -> bool:
	return (b - a).cross(c - a).length_squared() < 1e-8


## The plane actually applied, flipped for the "keep back" mode. Our brushes discard whatever
## lies on a plane's OUTWARD side, so the mode is expressed purely by which way the normal faces.
func _plane_for_mode(flip: bool):
	var plane = _current_plane()
	if plane == null:
		return null
	return Plane(-plane.normal, -plane.d) if flip else plane


## True when clipping `node` by `plane` (its +normal side discarded) would leave nothing solid:
## every vertex sits on the discarded side or on the plane itself. This is the "Brush is empty"
## case, most often from matching a brush to one of its OWN faces — cutting a solid by its own
## boundary can only shave away nothing or erase the whole thing. Matches clip_by's own test
## (a convex piece survives iff some vertex is strictly on the kept side).
func _cut_empties(node: Node3D, plane: Plane) -> bool:
	var local := _world_plane_to_local(plane, node.global_transform)
	for v in node.get_vertices():
		if local.distance_to(v) < -1e-4:
			return false      # a vertex on the kept side: a real solid survives the cut
	return true


## Reject duplicates, and reject a third point collinear with the first two — that plane would be
## undefined. Implicitly caps at three.
func _can_add_point(point: Vector3) -> bool:
	if points.size() >= 3:
		return false
	for existing in points:
		if existing.distance_squared_to(point) < 1e-8:
			return false
	if points.size() == 2 and _collinear(points[0], points[1], point):
		return false
	return true


func add_point(camera: Camera3D, screen_pos: Vector2) -> bool:
	var hit_target = _target(camera, screen_pos)
	if hit_target == null or not _can_add_point(hit_target.point):
		return false
	points.append(hit_target.point)
	help.append(hit_target.help)
	update_ghost()
	host.update_overlays()
	return true


## Drop the most recent clip point. While the tool is mid-cut, DELETE means this rather than
## deleting the selected brushes.
func remove_last_point() -> void:
	if points.is_empty():
		return
	points.remove_at(points.size() - 1)
	help.remove_at(help.size() - 1)
	update_ghost()


## Grab an existing clip point to move it. Dragging re-glues it to whatever face is under the
## cursor, so a point can be walked around the geometry after the fact.
func begin_point_drag(camera: Camera3D, screen_pos: Vector2) -> bool:
	for i in points.size():
		if camera.is_position_behind(points[i]):
			continue
		if screen_pos.distance_to(camera.unproject_position(points[i])) < CLIP_GRAB_PX:
			drag_index = i
			return true
	return false


func update_point_drag(camera: Camera3D, screen_pos: Vector2) -> void:
	var hit_target = _target(camera, screen_pos)
	if hit_target == null:
		return          # no face under the cursor: leave the point where it is
	points[drag_index] = hit_target.point
	# Only overwrite the help vectors when the new position actually voted for something.
	# Dragging across a spot that yields none would otherwise wipe the point's contribution and
	# make the guessed plane jump for no visible reason.
	if not hit_target.help.is_empty():
		help[drag_index] = hit_target.help
	update_ghost()
	host.update_overlays()


## Live feedback sphere: track where a point WOULD land under the cursor and repaint when it moves.
func update_hover(camera: Camera3D, screen_pos: Vector2) -> void:
	var hit_target = _target(camera, screen_pos)
	var next = hit_target.point if hit_target != null else null
	if next != hover:
		hover = next
		host.update_overlays()


## Match the clip plane to an existing brush face, TrenchBroom's double-click gesture. The three
## points come from the face itself, so the clip plane is EXACTLY the face's plane rather than a
## reconstruction of it — which is what avoids the hairline gaps you'd get from re-deriving it.
func match_face(camera: Camera3D, screen_pos: Vector2) -> bool:
	var hit = host._raycast_brush_faces(
		camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos))
	if hit == null:
		return false
	var poly: PackedVector3Array = hit.node.face_polygon(hit.face)
	if poly.size() < 3:
		return false
	var to_world: Transform3D = hit.node.global_transform
	# Built element by element: an untyped literal can't be assigned to a typed Array, and that
	# only bites at runtime.
	points = []
	help = []
	for i in 3:
		points.append(to_world * poly[i])
		help.append([_dominant_signed_axis(hit.normal)])
	# Orient the plane to the face's OUTWARD normal so which side gets cut is defined by the face,
	# not by the winding of the three vertices we happened to read. _current_plane() rebuilds the
	# plane from these points in order, so reversing them flips its normal.
	if Plane(points[0], points[1], points[2]).normal.dot(hit.normal) < 0.0:
		points.reverse()
		help.reverse()
	# Default to discarding the face's EMPTY (outward) side: matching a face trims flush against it
	# and keeps the solid side. Cutting a brush by its OWN face is then a harmless no-op until the
	# mode is flipped, rather than an accidental delete.
	mode = CLIP_KEEP_FRONT
	update_ghost()
	host.update_overlays()
	return true


func cycle_mode() -> void:
	mode = (mode + 1) % 3
	update_ghost()
	host.update_overlays()


## Push (or clear) the ghost on the brushes the clip would cut. Previously-ghosted brushes are
## tracked and cleared explicitly: the ghost lives in a shader uniform on the brush's own
## materials, so a brush that leaves the selection mid-gesture would otherwise stay half-erased
## with nothing on screen to explain why.
func update_ghost() -> void:
	for node in ghosted:
		if is_instance_valid(node):
			node.set_clip_ghost(Plane(), false)
	ghosted = []
	if is_instance_valid(host._clip_preview):
		host._clip_preview.queue_free()
	host._clip_preview = null
	if host._tool_mode != "clip" or mode == CLIP_SPLIT:
		return                      # a split discards nothing, so nothing is ghosted
	var plane = _plane_for_mode(mode == CLIP_KEEP_BACK)
	if plane == null:
		return
	for node in host._selected_brushes():
		if _cut_empties(node, plane):
			continue      # would erase the whole brush: the overlay warns instead of ghosting it
		node.set_clip_ghost(plane, true)
		ghosted.append(node)
	_build_preview(plane)


## Real 3D geometry for the face the cut would create, using the material it would actually get.
##
## Not an overlay polygon: this has to be TEXTURED and depth-tested, and the 2D overlay can be
## neither — it draws flat colour over the finished frame, so it can't sample a texture in world
## space and can't be occluded by anything in front of it. Unowned, so it never reaches the
## saved scene.
func _build_preview(plane: Plane) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var mesh := ArrayMesh.new()
	for node in host._selected_brushes():
		var local := _world_plane_to_local(plane, node.global_transform)
		var section: PackedVector3Array = node.cross_section(local)
		if section.size() < 3:
			continue
		var mapping = node.cut_face_mapping(local)
		if mapping == null:
			continue
		# Built in WORLD space, so the preview node needs no transform of its own. UVs are baked
		# here the same way the brush bakes its own (dot(world, axis) + offset), so the cut face's
		# texture lines up with the surrounding faces.
		var to_world: Transform3D = node.global_transform
		var u: Vector3 = mapping.u
		var v: Vector3 = mapping.v
		var off: Vector2 = mapping.offset
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for i in range(1, section.size() - 1):
			for k in [0, i + 1, i]:      # same winding the brush itself uses
				var world: Vector3 = to_world * section[k]
				st.set_normal(plane.normal)
				st.set_uv(Vector2(world.dot(u), world.dot(v)) + off)
				st.add_vertex(world)
		st.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, mapping.material)

	if mesh.get_surface_count() == 0:
		return
	host._clip_preview = MeshInstance3D.new()
	host._clip_preview.mesh = mesh
	host._clip_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(host._clip_preview)   # unowned -> not saved, hidden from the Scene dock


func reset() -> void:
	points = []
	help = []
	drag_index = -1
	pending_drag = false
	hover = null
	update_ghost()


## Apply the clip plane to every selected brush.
func apply() -> void:
	var plane = _plane_for_mode(mode == CLIP_KEEP_BACK)
	if plane == null:
		return
	var brushes := host._selected_brushes()
	if brushes.is_empty():
		return
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return

	# Refuse a cut that would erase an entire brush (matching a brush to its own face, most often)
	# rather than silently deleting it. Prints an error to the Godot Output and leaves the points.
	# Split can't empty anything, so it's exempt.
	if mode != CLIP_SPLIT:
		for node in brushes:
			if _cut_empties(node, plane):
				printerr("Clip cancelled: the cut would leave a brush with no volume.")
				return

	var ur := host.get_undo_redo()
	ur.create_action("Clip Brush")
	var survivors: Array[Node3D] = []
	for node in brushes:
		var local := _world_plane_to_local(plane, node.global_transform)
		# The far half is made FIRST, from the untouched brush, because clipping the original
		# would destroy the shape the copy needs.
		var other: Node3D = null
		if mode == CLIP_SPLIT:
			other = node.duplicate() as Node3D
			node.get_parent().add_child(other, true)
			other.owner = root
			if not other.clip_by(Plane(-local.normal, -local.d)):
				other.get_parent().remove_child(other)
				other = null

		var before_planes: Array[Plane] = node.planes.duplicate()
		var before_faces: Dictionary = node.face_data
		var before_position: Vector3 = node.global_position
		if node.clip_by(local):
			node.recenter()
			ur.add_do_property(node, "global_position", node.global_position)
			ur.add_do_property(node, "planes", node.planes.duplicate())
			ur.add_do_property(node, "face_data", node.face_data)
			ur.add_undo_property(node, "global_position", before_position)
			ur.add_undo_property(node, "planes", before_planes)
			ur.add_undo_property(node, "face_data", before_faces)
			survivors.append(node)
		else:
			# The cut removed everything, so the brush itself goes.
			var parent := node.get_parent()
			ur.add_do_method(parent, "remove_child", node)
			ur.add_undo_method(parent, "add_child", node)
			ur.add_undo_method(parent, "move_child", node, node.get_index())
			ur.add_undo_method(node, "set_owner", root)
			ur.add_undo_reference(node)

		if other != null:
			other.recenter()
			var parent := other.get_parent()
			ur.add_do_reference(other)
			ur.add_do_method(parent, "add_child", other, true)
			ur.add_do_method(other, "set_owner", root)
			ur.add_do_property(other, "global_position", other.global_position)
			ur.add_undo_method(parent, "remove_child", other)
			survivors.append(other)
	ur.commit_action(false)   # already applied

	var selection := EditorInterface.get_selection()
	selection.clear()
	for node in survivors:
		selection.add_node(node)
	reset()
	host.update_overlays()


## World plane -> a brush's local space. n·x <= d becomes (Bᵀn)·p <= d - n·o for x = B·p + o.
func _world_plane_to_local(plane: Plane, xform: Transform3D) -> Plane:
	var n: Vector3 = xform.basis.transposed() * plane.normal
	var d: float = plane.d - plane.normal.dot(xform.origin)
	var length := n.length()
	return Plane(n / length, d / length)


func draw_handles(overlay: Control) -> void:
	var plane = _plane_for_mode(mode == CLIP_KEEP_BACK)

	# The piece about to be removed is ghosted by the FACE SHADER (see update_ghost), not drawn
	# here. An overlay polygon sits on top of the viewport and can only tint what's already been
	# rendered — it can never reveal the brush behind the doomed chunk, which is the whole point
	# of showing it.

	# The cut itself, drawn as the cross-section it makes through each selected brush — the most
	# direct answer to "what is this going to do".
	if plane != null:
		for node in host._selected_brushes():
			var local := _world_plane_to_local(plane, node.global_transform)
			var section: PackedVector3Array = node.cross_section(local)
			if section.size() < 3:
				continue
			var to_world: Transform3D = node.global_transform
			# Only the OUTLINE here — the face itself is real geometry now (_build_preview), so it
			# can carry the actual texture and be occluded properly. The outline stays in the
			# overlay because it should read at any angle, including edge-on where the face
			# collapses to nothing.
			var world_section := PackedVector3Array()
			for p in section:
				world_section.append(to_world * p)
			for i in world_section.size():
				host._draw_world_line(overlay, world_section[i],
					world_section[(i + 1) % world_section.size()], Color(Palette.TB_ORANGE, 0.95), 2.0)

	for point in points:
		if host._draw_camera.is_position_behind(point):
			continue
		overlay.draw_circle(host._draw_camera.unproject_position(point), CLIP_POINT_PX, Palette.TB_ORANGE)

	# Feedback sphere: where a point WOULD land, shown only when one actually could be placed.
	if hover != null and points.size() < 3 \
			and not host._draw_camera.is_position_behind(hover):
		overlay.draw_circle(host._draw_camera.unproject_position(hover),
			CLIP_POINT_PX, Color(Palette.TB_ORANGE, 0.45))

	# Only while a cut is actually being defined. Applying clears the points, so the message
	# leaves with them rather than lingering over a finished cut — and, as with the brush tool,
	# "Enter to apply" only appears once there IS a plane to apply.
	if not points.is_empty():
		var names := ["Keep front", "Split", "Keep back"]
		var hint := "Ctrl+Enter to cycle, Esc to clear"
		if plane != null:
			hint = "Enter to apply, Ctrl+Enter to cycle, Esc to clear"
		host._draw_status_hint(overlay, ["Clip: %s   (%s)" % [names[mode], hint]])
