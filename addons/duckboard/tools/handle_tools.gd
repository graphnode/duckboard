@tool
extends RefCounted
## Vertex / Edge / Face reshape tools — one subsystem, because they differ only in what counts as a
## handle (a corner, an edge midpoint, a face centre) while hover, selection and dragging are all
## expressed in WORLD positions rather than per-tool indices. A drag moves exactly the handles in the
## selection — the ones drawn red — and nothing else. Because a handle IS a world position, brushes
## meeting at a shared corner or edge contribute one handle between them and so reshape together
## without tearing a seam. Only the edited element snaps; the rest of the brush is left where it was.
##
## Owned by the Duckboard plugin, reached through `host` for the selection, grid, undo, the shared
## reshape-recorder, the draw camera + line/label helpers, and the handle-size constants.

const Palette := preload("res://addons/duckboard/palette.gd")

var host: Duckboard

# Shared handle model. `hover` is the handle under the cursor; `selection` is the picked set, as
# world positions — a plain click replaces it, CTRL+click adds/removes, like brush selection one
# level down.
var hover
var selection := PackedVector3Array()

# Vertex tool. Every selected brush with a corner at the grabbed position moves together. Parallel
# arrays, one entry per participating brush.
var vertex_nodes: Array[Node3D] = []
var vertex_index_sets: Array = []          # PackedInt32Array of corner indices per node
var vertex_start_points: Array = []        # corner set per node at grab time
var vertex_start_planes: Array = []        # for undo
var vertex_start_faces: Array = []         # UV state for undo (restoring planes alone re-runs carry)
var vertex_alt := false
var vertex_plane_y := 0.0
var vertex_line_point := Vector3.ZERO
var vertex_origin := Vector3.ZERO          # where it started, world space (for the legs)
var vertex_current := Vector3.ZERO         # where it is now, world space

# Edge tool: dragging an edge moves both its endpoints, on every selected brush that shares it.
var edge_nodes: Array[Node3D] = []
var edge_index_sets: Array = []
var edge_start_points: Array = []
var edge_start_planes: Array = []
var edge_start_faces: Array = []
var edge_origin := Vector3.ZERO            # midpoint at grab time (world)
var edge_mid := Vector3.ZERO               # current midpoint (world)
var edge_alt := false
var edge_plane_y := 0.0
var edge_line_point := Vector3.ZERO

# Box select. A drag that grabbed no handle sweeps a rectangle instead and picks every handle inside
# it — TrenchBroom's rubber band, one level down from the one that selects brushes. Screen space,
# because a rectangle is what the user is aiming with.
var marquee_active := false
var marquee_from := Vector2.ZERO
var marquee_to := Vector2.ZERO
var marquee_add := false
var _marquee_base := PackedVector3Array()   # what was picked before the sweep, for an additive one

# Face tool: dragging a face moves all its corners together. Faces are picked by their centre, so
# two brushes abutting at a seam are two handles — CTRL+click both to move them as one.
var face_nodes: Array[Node3D] = []
var face_index_sets: Array = []
var face_start_points: Array = []
var face_start_planes: Array = []
var face_start_faces: Array = []
var face_origin := Vector3.ZERO            # centroid at grab time (world)
var face_center := Vector3.ZERO            # current centroid (world)
var face_alt := false
var face_plane_y := 0.0
var face_line_point := Vector3.ZERO


func _init(p_host: Duckboard) -> void:
	host = p_host


# --- Shared handle model --------------------------------------------------

## Every handle position the ACTIVE tool offers, in world space, deduplicated. One handle per
## position however many brushes meet there — which is exactly how they behave when dragged.
func handle_positions() -> PackedVector3Array:
	var out := PackedVector3Array()
	for node in host._selected_brushes():
		var to_world: Transform3D = node.global_transform
		var candidates := PackedVector3Array()
		match host._tool_mode:
			"vertex":
				for local in node.get_vertices():
					candidates.append(to_world * local)
			"edge":
				var edges: PackedVector3Array = node.get_edges()
				for e in range(0, edges.size(), 2):
					candidates.append(to_world * ((edges[e] + edges[e + 1]) * 0.5))
			"face":
				for f in node.planes.size():
					if node.face_polygon(f).size() >= 3:
						candidates.append(to_world * node.face_center(f))
		for p in candidates:
			var seen := false
			for existing in out:
				if existing.distance_squared_to(p) < 1e-6:
					seen = true
					break
			if not seen:
				out.append(p)
	return out


## Nearest handle to the cursor within the grab radius, or null.
func nearest_handle(camera: Camera3D, screen_pos: Vector2):
	var best = null
	var best_dist := host.VERTEX_GRAB_PX
	for p in handle_positions():
		if camera.is_position_behind(p):
			continue
		var d := screen_pos.distance_to(camera.unproject_position(p))
		if d < best_dist:
			best_dist = d
			best = p
	return best


## How far the selected handles have travelled in the drag currently underway, or zero if none is.
func _handle_drag_delta() -> Vector3:
	if not vertex_nodes.is_empty():
		return vertex_current - vertex_origin
	if not edge_nodes.is_empty():
		return edge_mid - edge_origin
	if not face_nodes.is_empty():
		return face_center - face_origin
	return Vector3.ZERO


## Is this WORLD position one of the selected handles?
##
## The live drag delta is subtracted first. The selection stores where the handles were when they
## were picked, but the geometry has already moved by the time this is asked mid-drag — raw
## positions would match only the handle under the cursor; probing with the delta removed keeps
## the whole set matched.
func _handle_selected(position: Vector3) -> bool:
	var probe := position - _handle_drag_delta()
	for p in selection:
		if p.distance_squared_to(probe) < 1e-6:
			return true
	return false


## Drop handle picks the current brush selection no longer offers — called when that selection
## changes.
##
## A pick is a world POSITION, so it means nothing once the brush that put a handle there is no longer
## being edited. Testing each entry against the live handles is what tells the two cases apart:
## selecting a DIFFERENT brush leaves nothing standing and the picks go, while ADDING one (CTRL+click
## with a tool up) leaves every existing handle exactly where it was, so the faces already picked
## survive — which is the whole point of extending the selection mid-edit.
##
## Not while a drag is live: the geometry has already moved by then, so the live handles sit at the
## dragged positions and every entry would fail to match and be thrown away mid-gesture.
func prune_selection() -> void:
	if selection.is_empty():
		return
	if not vertex_nodes.is_empty() or not edge_nodes.is_empty() or not face_nodes.is_empty():
		return
	var live := handle_positions()
	var kept := PackedVector3Array()
	for p in selection:
		for q in live:
			if q.distance_squared_to(p) < 1e-6:
				kept.append(p)
				break
	selection = kept


func toggle_handle(position: Vector3) -> void:
	for i in selection.size():
		if selection[i].distance_squared_to(position) < 1e-6:
			selection.remove_at(i)
			return
	selection.append(position)


## Does a candidate handle at `dist` pixels beat the best one found so far? `have` says whether there
## IS one yet; `picked` and `best_picked` say whether each is already in the handle selection.
##
## An already-selected handle wins over a nearer one that isn't, however much nearer. Several handles
## overlap inside the grab radius — a face's own centre and the centre of the face BEHIND it, two
## abutting brushes' corners — and this pick decides which one the drag claims. Claiming an unselected
## handle replaces the whole selection with it (see _claim_handle), so a plain nearest-wins quietly
## threw a box select away the moment the cursor sat one pixel nearer some other dot: the grabbed
## face moved and everything else picked with it stayed put.
##
## It cannot misfire the other way. Two handles this close are drawn on top of each other, so there is
## no aiming between them to lose — and a handle you meant to grab INSTEAD of the selection is still
## grabbed by clicking it with nothing else selected nearby, or after a click clears the picks.
## Nearest still decides between two handles of the same standing.
func _beats_pick(dist: float, picked: bool, have: bool, best_dist: float, best_picked: bool) -> bool:
	if not have:
		return true
	if picked != best_picked:
		return picked
	return dist < best_dist


## Called when a handle is grabbed WITHOUT ctrl. Dragging something that isn't selected makes it the
## selection first — otherwise the drag would act on handles the user can't see they picked.
func _claim_handle(position: Vector3) -> void:
	if not _handle_selected(position):
		selection = PackedVector3Array([position])


## Follow the handles that were just dragged. The selection stores WORLD positions, so once the
## geometry moves the stored entries name spots where nothing is any more. EVERY entry moves, not
## just the grabbed one: they all travelled by the same delta.
func _remap_handle(from: Vector3, to: Vector3) -> void:
	var delta := to - from
	if delta.length_squared() < 1e-12:
		return
	for i in selection.size():
		selection[i] += delta


## Position readout for a handle, in TrenchBroom units — the numbers you'd type into a .map file
## rather than Godot metres.
func _handle_label(position: Vector3) -> String:
	return "%d %d %d" % [
		roundi(position.x * host.UNITS_PER_METER),
		roundi(position.y * host.UNITS_PER_METER),
		roundi(position.z * host.UNITS_PER_METER)]


## The handle the ring and readout belong to: the one being DRAGGED if there is one, otherwise the
## one under the cursor. During a drag the cursor drifts off the handle it grabbed, so following the
## hover would leave the ring stranded where the handle used to be — and the readout is at its most
## useful mid-drag, where it reports where the geometry is going.
func _focus_handle():
	if not vertex_nodes.is_empty():
		return vertex_current
	if not edge_nodes.is_empty():
		return edge_mid
	if not face_nodes.is_empty():
		return face_center
	return hover


## Index of the corner of `node` sitting at a given WORLD position, or -1. Matching in world space is
## the point: each brush has its own local frame, so a shared seam only looks shared from outside.
func _index_of_world(node: Node3D, corners: PackedVector3Array, world: Vector3) -> int:
	var to_local := node.global_transform.affine_inverse()
	return _index_of(corners, to_local * world, node.weld_sq())


## Must use the SAME tolerance the brush welds corners at (hence it's passed in, not assumed). A
## looser one matches both ends of a short edge to a single index, so the drag writes twice to one
## vertex and only that end moves.
func _index_of(points: PackedVector3Array, target: Vector3, tolerance_sq: float) -> int:
	for i in points.size():
		if points[i].distance_squared_to(target) < tolerance_sq:
			return i
	return -1


# --- Box select -----------------------------------------------------------

## Start a rubber band at the press position. `additive` (CTRL) keeps what was already picked, so a
## second sweep extends the set rather than replacing it.
func begin_marquee(from: Vector2, additive: bool) -> void:
	marquee_active = true
	marquee_from = from
	marquee_to = from
	marquee_add = additive
	_marquee_base = selection.duplicate()
	# The hover ring belongs to the handle the cursor last rested on. Left up under a band that has
	# since swept elsewhere it reads as a second, stuck selection.
	hover = null


## Re-pick as the band is dragged, so the dots light up live rather than only on release.
##
## Recomputed from the BASE each time instead of accumulated: shrinking the band back off a handle
## has to drop it again. The rectangle IS the selection — it is not a brush that paints one.
func update_marquee(camera: Camera3D, to: Vector2) -> void:
	marquee_to = to
	var rect := marquee_rect()
	var picked := _marquee_base.duplicate() if marquee_add else PackedVector3Array()
	for p in handle_positions():
		if camera.is_position_behind(p):
			continue
		if not rect.has_point(camera.unproject_position(p)):
			continue
		var seen := false
		for q in picked:
			if q.distance_squared_to(p) < 1e-6:
				seen = true
				break
		if not seen:
			picked.append(p)
	selection = picked


func end_marquee() -> void:
	marquee_active = false
	_marquee_base = PackedVector3Array()


func marquee_rect() -> Rect2:
	return Rect2(marquee_from, Vector2.ZERO).expand(marquee_to)


## The band itself. Yellow, the handle colour, so it reads as picking HANDLES rather than as the
## editor's own rubber band — which is exactly what it replaces, and which would have swept up every
## light and marker it crossed.
func draw_marquee(overlay: Control) -> void:
	if not marquee_active:
		return
	var rect := marquee_rect()
	overlay.draw_rect(rect, Color(Palette.TB_YELLOW, 0.10), true)
	overlay.draw_rect(rect, Color(Palette.TB_YELLOW, 0.9), false, 1.0)


# --- Vertex tool ----------------------------------------------------------

## Grab the nearest corner under the cursor. Vertices are derived from the planes, so the set changes
## as the brush is reshaped — we re-query rather than cache indices.
func begin_vertex_drag(camera: Camera3D, screen_pos: Vector2) -> bool:
	# Only picks WHICH corner; the participating brushes are gathered from its world position below,
	# so the index into this particular brush isn't needed.
	var best_node: Node3D = null
	var best_local := Vector3.ZERO
	var best_dist := host.VERTEX_GRAB_PX
	var best_picked := false
	for node in host._selected_brushes():
		var corners: PackedVector3Array = node.get_vertices()
		for i in corners.size():
			var world_point: Vector3 = node.global_transform * corners[i]
			if camera.is_position_behind(world_point):
				continue
			var d := screen_pos.distance_to(camera.unproject_position(world_point))
			if d >= host.VERTEX_GRAB_PX:
				continue
			var picked := _handle_selected(world_point)
			if _beats_pick(d, picked, best_node != null, best_dist, best_picked):
				best_dist = d
				best_picked = picked
				best_node = node
				best_local = corners[i]
	if best_node == null:
		return false

	var world: Vector3 = best_node.global_transform * best_local
	_claim_handle(world)

	# Every SELECTED handle, on every brush that has a corner there. Two things fall out of the same
	# loop: a multi-handle selection moves as one, and two brushes meeting at a seam each contribute
	# their own vertex — moving only the grabbed one would tear a hole between them.
	vertex_nodes = []
	vertex_index_sets = []
	vertex_start_points = []
	vertex_start_planes = []
	vertex_start_faces = []
	for node in host._selected_brushes():
		var corners: PackedVector3Array = node.get_vertices()
		var indices := PackedInt32Array()
		for handle in selection:
			var index := _index_of_world(node, corners, handle)
			if index >= 0 and not indices.has(index):
				indices.append(index)
		if indices.is_empty():
			continue
		vertex_nodes.append(node)
		vertex_index_sets.append(indices)
		vertex_start_points.append(corners)   # hull is re-solved from these each frame
		vertex_start_planes.append(node.planes.duplicate())
		vertex_start_faces.append(node.face_data)
	if vertex_nodes.is_empty():
		return false
	vertex_origin = world
	vertex_current = world
	vertex_plane_y = world.y
	vertex_line_point = world
	vertex_alt = false
	return true


func _vertex_handle_point(camera: Camera3D, screen_pos: Vector2):
	return host._constraint_point(camera, screen_pos, vertex_alt, vertex_plane_y, vertex_line_point)


## Move the grabbed corner freely — only that vertex changes, so the brush deforms rather than
## scaling. Snapped in WORLD space, then converted back into the brush's local space.
func update_vertex_drag(camera: Camera3D, screen_pos: Vector2, alt_now: bool) -> void:
	if alt_now != vertex_alt:
		# Re-anchor at where we already are so switching constraint doesn't jump.
		var here = _vertex_handle_point(camera, screen_pos)
		if here != null:
			if alt_now:
				vertex_line_point = here
			else:
				vertex_plane_y = here.y
		vertex_alt = alt_now

	var point = _vertex_handle_point(camera, screen_pos)
	if point == null:
		return
	var g := host.grid_size
	var world := Vector3(snappedf(point.x, g), snappedf(point.y, g), snappedf(point.z, g))
	# Snap the DELTA, not each corner: with several handles selected they have to keep their relative
	# positions, and snapping each one independently would collapse them together.
	var delta := world - vertex_origin

	# Move the selected corners on each participating brush and re-solve its hull. Points that end up
	# inside the new hull are simply dropped by it, and fresh faces appear where the shape now needs
	# them.
	for i in vertex_nodes.size():
		var node: Node3D = vertex_nodes[i]
		var start: PackedVector3Array = vertex_start_points[i]
		var local_delta: Vector3 = node.global_transform.basis.inverse() * delta
		var points := start.duplicate()
		for index in vertex_index_sets[i]:
			points[index] = start[index] + local_delta
		# snap = false: the moved corners already carry the snapped delta, so only the DRAGGED
		# vertices land on the grid. Snapping here would re-snap every OTHER corner onto the current
		# grid too, resizing a brush that was built (or scaled/sheared) off it — matching TrenchBroom,
		# where only the edited element snaps and the rest of the brush is untouched.
		node.set_from_points(points, false)
	vertex_current = vertex_origin + delta
	host.update_overlays()


func commit_vertex_drag() -> void:
	if not vertex_nodes.is_empty():
		var ur := host.get_undo_redo()
		ur.create_action("Move Vertex")
		for i in vertex_nodes.size():
			host._record_reshape(ur, vertex_nodes[i], vertex_start_planes[i], vertex_start_faces[i])
		ur.commit_action(false)   # already applied during the drag
	_remap_handle(vertex_origin, vertex_current)
	reset_vertex()


func reset_vertex() -> void:
	vertex_nodes = []
	vertex_index_sets = []
	vertex_start_points = []
	vertex_start_planes = []
	vertex_start_faces = []
	vertex_alt = false


func draw_vertex_handles(overlay: Control) -> void:
	var idle := Color(0.95, 0.8, 0.25, 0.9)
	# TrenchBroom draws an engaged handle RED, matching the ring around it — one colour for "this is
	# the one you are acting on", rather than white competing with the yellow idle dots.
	var active := Palette.TB_RED
	for node in host._selected_brushes():
		for local in node.get_vertices():
			var corner: Vector3 = node.global_transform * local
			if host._draw_camera.is_position_behind(corner):
				continue
			# Tested in WORLD space, so every brush sharing a selected corner lights up — which is
			# also the cue that they'll move together.
			var dragged: bool = _handle_selected(corner)
			overlay.draw_circle(host._draw_camera.unproject_position(corner), host.VERTEX_HANDLE_PX,
				active if dragged else idle)


# --- Edge tool ------------------------------------------------------------

## Grab the nearest edge midpoint. Dragging an edge moves BOTH its endpoints together.
func begin_edge_drag(camera: Camera3D, screen_pos: Vector2) -> bool:
	# Pick the edge by its midpoint, but remember its ENDPOINTS in world space — that's what
	# identifies the same edge on a neighbouring brush.
	var best_node: Node3D = null
	var best_mid := Vector3.ZERO
	var best_a := Vector3.ZERO
	var best_b := Vector3.ZERO
	var best_dist := host.VERTEX_GRAB_PX
	var best_picked := false
	for node in host._selected_brushes():
		var edges: PackedVector3Array = node.get_edges()
		for e in range(0, edges.size(), 2):
			var mid_local: Vector3 = (edges[e] + edges[e + 1]) * 0.5
			var mid_world: Vector3 = node.global_transform * mid_local
			if camera.is_position_behind(mid_world):
				continue
			var d := screen_pos.distance_to(camera.unproject_position(mid_world))
			if d >= host.VERTEX_GRAB_PX:
				continue
			var picked := _handle_selected(mid_world)
			if _beats_pick(d, picked, best_node != null, best_dist, best_picked):
				best_dist = d
				best_picked = picked
				best_node = node
				best_mid = mid_world
				best_a = node.global_transform * edges[e]
				best_b = node.global_transform * edges[e + 1]
	if best_node == null:
		return false

	_claim_handle(best_mid)

	# Endpoints of every SELECTED edge, on every brush that has that edge. Collected as a flat index
	# set rather than pairs: edges sharing a corner would otherwise move it twice.
	edge_nodes = []
	edge_index_sets = []
	edge_start_points = []
	edge_start_planes = []
	edge_start_faces = []
	for node in host._selected_brushes():
		var points: PackedVector3Array = node.get_vertices()
		var edges: PackedVector3Array = node.get_edges()
		var to_world: Transform3D = node.global_transform
		var tolerance: float = node.weld_sq()
		var indices := PackedInt32Array()
		for e in range(0, edges.size(), 2):
			if not _handle_selected(to_world * ((edges[e] + edges[e + 1]) * 0.5)):
				continue
			var ia := _index_of(points, edges[e], tolerance)
			var ib := _index_of(points, edges[e + 1], tolerance)
			# Both ends must resolve to DISTINCT corners, or the edge would fold in on itself.
			if ia < 0 or ib < 0 or ia == ib:
				continue
			for index in [ia, ib]:
				if not indices.has(index):
					indices.append(index)
		if indices.is_empty():
			continue
		edge_nodes.append(node)
		edge_index_sets.append(indices)
		edge_start_points.append(points)
		edge_start_planes.append(node.planes.duplicate())
		edge_start_faces.append(node.face_data)
	if edge_nodes.is_empty():
		return false
	edge_origin = best_mid
	edge_mid = best_mid
	edge_plane_y = best_mid.y
	edge_line_point = best_mid
	edge_alt = false
	return true


func update_edge_drag(camera: Camera3D, screen_pos: Vector2, alt_now: bool) -> void:
	if alt_now != edge_alt:
		var here = host._constraint_point(camera, screen_pos, edge_alt, edge_plane_y, edge_line_point)
		if here != null:
			if alt_now:
				edge_line_point = here
			else:
				edge_plane_y = here.y
		edge_alt = alt_now

	var point = host._constraint_point(camera, screen_pos, edge_alt, edge_plane_y, edge_line_point)
	if point == null:
		return
	# Snap the DELTA rather than each endpoint, so the edge keeps its length and both ends stay
	# grid-aligned.
	var g := host.grid_size
	var raw: Vector3 = point - edge_origin
	var delta := Vector3(snappedf(raw.x, g), snappedf(raw.y, g), snappedf(raw.z, g))
	for i in edge_nodes.size():
		var node: Node3D = edge_nodes[i]
		var start: PackedVector3Array = edge_start_points[i]
		var local_delta: Vector3 = node.global_transform.basis.inverse() * delta
		var points := start.duplicate()
		for index in edge_index_sets[i]:
			points[index] = start[index] + local_delta
		# snap = false, as with the vertex tool: only the moved endpoints shift, the rest of the
		# brush is left exactly where it was rather than re-snapped onto the current grid.
		node.set_from_points(points, false)
	edge_mid = edge_origin + delta
	host.update_overlays()


func commit_edge_drag() -> void:
	if not edge_nodes.is_empty():
		var ur := host.get_undo_redo()
		ur.create_action("Move Edge")
		for i in edge_nodes.size():
			host._record_reshape(ur, edge_nodes[i], edge_start_planes[i], edge_start_faces[i])
		ur.commit_action(false)   # already applied during the drag
	_remap_handle(edge_origin, edge_mid)
	reset_edge()


func reset_edge() -> void:
	edge_nodes = []
	edge_index_sets = []
	edge_start_points = []
	edge_start_planes = []
	edge_start_faces = []
	edge_alt = false


func draw_edge_handles(overlay: Control) -> void:
	var idle := Color(0.95, 0.8, 0.25, 0.9)
	# TrenchBroom draws an engaged handle RED, matching the ring around it — one colour for "this is
	# the one you are acting on", rather than white competing with the yellow idle dots.
	var active := Palette.TB_RED
	for node in host._selected_brushes():
		var edges: PackedVector3Array = node.get_edges()
		for e in range(0, edges.size(), 2):
			var mid: Vector3 = node.global_transform * ((edges[e] + edges[e + 1]) * 0.5)
			if host._draw_camera.is_position_behind(mid):
				continue
			var dragged: bool = _handle_selected(mid)
			overlay.draw_circle(host._draw_camera.unproject_position(mid), host.VERTEX_HANDLE_PX,
				active if dragged else idle)


# --- Face tool ------------------------------------------------------------

## Grab the nearest face centre. Dragging a face moves ALL of its corners together.
func begin_face_drag(camera: Camera3D, screen_pos: Vector2) -> bool:
	# A face is picked — and identified — by its centre in world space, the position its handle dot is
	# drawn at.
	var best_node: Node3D = null
	var best_center := Vector3.ZERO
	var best_dist := host.VERTEX_GRAB_PX
	var best_picked := false
	for node in host._selected_brushes():
		for f in node.planes.size():
			if node.face_polygon(f).size() < 3:
				continue                       # face clipped away entirely
			var center_world: Vector3 = node.global_transform * node.face_center(f)
			if camera.is_position_behind(center_world):
				continue
			var d := screen_pos.distance_to(camera.unproject_position(center_world))
			if d >= host.VERTEX_GRAB_PX:
				continue
			var picked := _handle_selected(center_world)
			if not _beats_pick(d, picked, best_node != null, best_dist, best_picked):
				continue
			best_dist = d
			best_picked = picked
			best_node = node
			best_center = center_world
	if best_node == null:
		return false

	_claim_handle(best_center)

	# Only faces whose own centre is in the handle selection take part — the same rule the vertex and
	# edge tools use, and the same set the overlay lights red.
	#
	# Matching by world PLANE instead would sweep in every coplanar face in the level: a brush across
	# the map whose top sits at the same height shares the plane exactly, so dragging one floor face
	# would drag every floor. Two brushes abutting at a seam have DIFFERENT face centres, hence
	# different handles, so joining them is a CTRL+click — visible and deliberate, rather than a
	# neighbourhood the tool guesses at.
	face_nodes = []
	face_index_sets = []
	face_start_points = []
	face_start_planes = []
	face_start_faces = []
	for node in host._selected_brushes():
		var points: PackedVector3Array = node.get_vertices()
		var tolerance: float = node.weld_sq()
		var indices := PackedInt32Array()
		for f in node.planes.size():
			var poly: PackedVector3Array = node.face_polygon(f)
			if poly.size() < 3:
				continue
			if not _handle_selected(node.global_transform * node.face_center(f)):
				continue
			for corner in poly:
				var i := _index_of(points, corner, tolerance)
				if i >= 0 and not indices.has(i):
					indices.append(i)
		if indices.size() < 3:
			continue                           # couldn't resolve the corners; skip this brush
		face_nodes.append(node)
		face_index_sets.append(indices)
		face_start_points.append(points)
		face_start_planes.append(node.planes.duplicate())
		face_start_faces.append(node.face_data)
	if face_nodes.is_empty():
		return false
	face_origin = best_center
	face_center = best_center
	face_plane_y = best_center.y
	face_line_point = best_center
	face_alt = false
	return true


func update_face_drag(camera: Camera3D, screen_pos: Vector2, alt_now: bool) -> void:
	if alt_now != face_alt:
		var here = host._constraint_point(camera, screen_pos, face_alt, face_plane_y, face_line_point)
		if here != null:
			if alt_now:
				face_line_point = here
			else:
				face_plane_y = here.y
		face_alt = alt_now

	var point = host._constraint_point(camera, screen_pos, face_alt, face_plane_y, face_line_point)
	if point == null:
		return
	# One snapped delta for every corner, so the face translates rigidly rather than skewing.
	var g := host.grid_size
	var raw: Vector3 = point - face_origin
	var delta := Vector3(snappedf(raw.x, g), snappedf(raw.y, g), snappedf(raw.z, g))
	for n in face_nodes.size():
		var node: Node3D = face_nodes[n]
		var start: PackedVector3Array = face_start_points[n]
		var local_delta: Vector3 = node.global_transform.basis.inverse() * delta
		var points := start.duplicate()
		for i in face_index_sets[n]:
			points[i] = start[i] + local_delta
		# snap = false, as with vertex and edge: only the dragged face's corners move to grid.
		node.set_from_points(points, false)
	face_center = face_origin + delta
	host.update_overlays()


func commit_face_drag() -> void:
	if not face_nodes.is_empty():
		var ur := host.get_undo_redo()
		ur.create_action("Move Face")
		for i in face_nodes.size():
			host._record_reshape(ur, face_nodes[i], face_start_planes[i], face_start_faces[i])
		ur.commit_action(false)   # already applied during the drag
	_remap_handle(face_origin, face_center)
	reset_face()


func reset_face() -> void:
	face_nodes = []
	face_index_sets = []
	face_start_points = []
	face_start_planes = []
	face_start_faces = []
	face_alt = false


func draw_face_handles(overlay: Control) -> void:
	var idle := Color(0.95, 0.8, 0.25, 0.9)
	# TrenchBroom draws an engaged handle RED, matching the ring around it — one colour for "this is
	# the one you are acting on", rather than white competing with the yellow idle dots.
	var active := Palette.TB_RED
	for node in host._selected_brushes():
		for f in node.planes.size():
			if node.face_polygon(f).size() < 3:
				continue
			var center: Vector3 = node.global_transform * node.face_center(f)
			if host._draw_camera.is_position_behind(center):
				continue
			var dragged: bool = _handle_selected(center)
			overlay.draw_circle(host._draw_camera.unproject_position(center), host.VERTEX_HANDLE_PX,
				active if dragged else idle)


# --- Shared overlay draws -------------------------------------------------

## Red ring on the hovered handle, plus a position readout for VERTICES only.
##
## A vertex is a point, so its coordinates are the whole truth about it. An edge midpoint or a face
## centre is a derived average — the number would name a spot that isn't a feature of the geometry,
## and reads as more precise than it is. The ring still marks all three as live.
func draw_handle_hover(overlay: Control) -> void:
	var focus = _focus_handle()
	if focus == null or host._draw_camera.is_position_behind(focus):
		return
	var at := host._draw_camera.unproject_position(focus)
	overlay.draw_arc(at, host.VERTEX_HANDLE_PX + 3.0, 0.0, TAU, 24, Palette.TB_RED, 2.0, true)
	if host._tool_mode != "vertex":
		return
	# Same translucency as the dark pills, so the readout sits in the scene rather than on top of it
	# — only the hue differs.
	host._draw_dim_label(overlay, overlay.get_theme_default_font(), host.LABEL_FONT_SIZE,
		at - Vector2(0.0, host.VERTEX_HANDLE_PX + 26.0), _handle_label(focus),
		Color(Palette.TB_RED, host._label_style.bg_color.a))


## Yellow guide lines through the dragged handle, running the full length on all six directions, so
## you can sight it against the rest of the level while dragging.
func draw_vertex_spikes(overlay: Control, at: Vector3) -> void:
	var col := Color(0.95, 0.8, 0.25, 0.35)
	for axis in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
		host._draw_world_line(overlay, at - axis * host.VERTEX_SPIKE_LENGTH,
			at + axis * host.VERTEX_SPIKE_LENGTH, col, 1.0)
