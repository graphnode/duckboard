@tool
extends RefCounted
## Rotate tool: a TrenchBroom-style three-ring widget that rotates the selection's GEOMETRY about a
## movable pivot (planes rewritten, node orbits the pivot, basis untouched). Rebuilt from the drag's
## start state every frame so a long drag can't accumulate error. Also drives the one-shot rotation
## from the top-toolbar rotate bar.
##
## Owned by the Duckboard plugin, reached through `host` for the selection, grid, constraint picking,
## TB-unit conversion, plane/face transforms, the rotate bar, and the overlay draw helpers.

const Palette := preload("res://addons/duckboard/palette.gd")

var host: Duckboard

# Drag state. `center` is the pivot; held across drags until the selection changes (center_valid).
var center := Vector3.ZERO
var center_valid := false          # recomputed when the selection changes
var axis := -1                     # 0/1/2 while dragging a ring, -1 = none
var nodes: Array[Node3D] = []
var start_planes: Array = []
var start_faces: Array = []
var start_positions: Array = []
var start_angle := 0.0
var angle := 0.0                   # snapped, radians
var active := false
var moving_center := false
var center_alt := false            # ALT while moving the pivot: vertical instead of planar
var center_start := Vector3.ZERO   # pivot position at grab, so the drag can show its offset
var screen := Vector2.ZERO         # last cursor pos in the drag, so an ALT press can recompute
var hover_axis := -1
var hover_center := false


func _init(p_host: Duckboard) -> void:
	host = p_host


## Widget radius in WORLD units, sized so it covers a constant number of pixels whatever the
## distance. A world-space radius would shrink to nothing across a large map; tying it to the
## brush size would make it useless on both very small and very large brushes.
func ring_radius(camera: Camera3D, at: Vector3) -> float:
	var depth: float = maxf((at - camera.global_position).dot(-camera.global_transform.basis.z), 0.01)
	var viewport_height: float = camera.get_viewport().get_visible_rect().size.y
	if viewport_height < 1.0:
		return 1.0
	var world_per_pixel := 2.0 * depth * tan(deg_to_rad(camera.fov) * 0.5) / viewport_height
	return host.RING_RADIUS_PX * world_per_pixel


## The pivot, defaulting to the centre of the selection and snapped to the grid so rotated
## geometry keeps landing on it. Held across drags until the selection changes, since moving the
## pivot and then rotating about it is the whole point of having a movable one.
func center_for(brushes: Array[Node3D]) -> Vector3:
	if not center_valid:
		var c := host._selection_world_aabb(brushes).get_center()
		var g := host.grid_size
		center = Vector3(snappedf(c.x, g), snappedf(c.y, g), snappedf(c.z, g))
		center_valid = true
	return center


func begin_drag(camera: Camera3D, screen_pos: Vector2, alt: bool, blocked: bool) -> bool:
	var brushes := host._selected_geometry()
	if brushes.is_empty() or blocked:
		return false
	var at := center_for(brushes)
	var radius := ring_radius(camera, at)

	# The centre handle wins over the rings: it sits where all three cross, so near it every
	# ring is also close.
	if not camera.is_position_behind(at) \
			and screen_pos.distance_to(camera.unproject_position(at)) < host.RING_GRAB_PX:
		moving_center = true
		center_alt = alt
		center_start = at   # baseline for the distance legs drawn during the drag
		screen = screen_pos     # so an ALT press before the first move can recompute
		active = true
		return true

	if alt:
		return false      # a modifier on a ring is not a rotate gesture
	var picked := pick_ring(camera, screen_pos, at, radius)
	if picked < 0:
		return false
	nodes = brushes
	start_planes = []
	start_faces = []
	start_positions = []
	for node in brushes:
		start_planes.append(node.planes.duplicate())
		start_faces.append(node.face_data)
		start_positions.append(node.global_position)
	axis = picked
	var a = _angle_on_ring(camera, screen_pos, at, picked)
	if a == null:
		return false
	start_angle = a
	angle = 0.0
	active = true
	return true


## Nearest ring within the grab radius, measured in SCREEN space against the ring's projected
## outline. Screen space is the honest measure here: a ring seen edge-on collapses to a line, and
## a world-space distance would make it almost impossible to grab.
func pick_ring(camera: Camera3D, screen_pos: Vector2, at: Vector3, radius: float) -> int:
	var signs := _rotate_octant(at, camera.global_position)
	var best := -1
	var best_dist := host.RING_GRAB_PX
	for ax in 3:
		for seg in _ring_segments(at, radius, ax, signs):
			if camera.is_position_behind(seg[0]) or camera.is_position_behind(seg[1]):
				continue
			var d := _point_segment_distance_2d(screen_pos,
				camera.unproject_position(seg[0]), camera.unproject_position(seg[1]))
			if d < best_dist:
				best_dist = d
				best = ax
	return best


## The segments of a ring that lie in the camera-facing octant, as [start, end] pairs.
func _ring_segments(at: Vector3, radius: float, ax: int, signs: Vector3) -> Array:
	var out := []
	for i in host.RING_SEGMENTS:
		var a := _ring_point(at, radius, ax, TAU * i / host.RING_SEGMENTS)
		var b := _ring_point(at, radius, ax, TAU * (i + 1) / host.RING_SEGMENTS)
		if _in_octant(a - at, signs) and _in_octant(b - at, signs):
			out.append([a, b])
	return out


func _ring_point(at: Vector3, radius: float, ax: int, ang: float) -> Vector3:
	var u: Vector3 = host.MOVE_AXES[(ax + 1) % 3]
	var v: Vector3 = host.MOVE_AXES[(ax + 2) % 3]
	return at + (u * cos(ang) + v * sin(ang)) * radius


## Which octant of the rings faces the camera. Only that octant is drawn or grabbable, which is
## why TrenchBroom's widget reads as three quarter-arcs meeting at a corner rather than three
## overlapping circles — and it's what resolves the otherwise ambiguous pick where all three
## rings cross near the silhouette.
func _rotate_octant(at: Vector3, camera_position: Vector3) -> Vector3:
	var view := (at - camera_position).normalized()
	if absf(view.y) > 0.9999:
		return Vector3(1.0, -1.0, 1.0)   # straight down the up axis: no meaningful near corner
	return Vector3(
		-1.0 if view.x > 0.0 else 1.0,
		-1.0 if view.y > 0.0 else 1.0,
		-1.0 if view.z > 0.0 else 1.0)


func _in_octant(offset: Vector3, signs: Vector3) -> bool:
	return offset.x * signs.x >= 0.0 and offset.y * signs.y >= 0.0 and offset.z * signs.z >= 0.0


func _point_segment_distance_2d(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 1e-9:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## Angle of the cursor around the pivot, measured in the ring's own plane.
func _angle_on_ring(camera: Camera3D, screen_pos: Vector2, at: Vector3, ax: int):
	var normal: Vector3 = host.MOVE_AXES[ax]
	var origin := camera.project_ray_origin(screen_pos)
	var ray := camera.project_ray_normal(screen_pos)
	var denom := normal.dot(ray)
	if absf(denom) < 1e-6:
		return null                    # looking along the ring's plane; angle is undefined
	var t := normal.dot(at - origin) / denom
	var hit := origin + ray * t
	var u: Vector3 = host.MOVE_AXES[(ax + 1) % 3]
	var v: Vector3 = host.MOVE_AXES[(ax + 2) % 3]
	var offset := hit - at
	return atan2(offset.dot(v), offset.dot(u))


func update_drag(camera: Camera3D, screen_pos: Vector2) -> void:
	screen = screen_pos   # remembered so an ALT press can recompute without a mouse move
	if moving_center:
		# The pivot moves on the horizontal plane, or straight up with ALT — the same constraint
		# the move/vertex/edge tools use. Snapped, so it keeps landing on grid intersections.
		var point = host._constraint_point(
			camera, screen_pos, center_alt, center.y, center)
		if point == null:
			return
		var g := host.grid_size
		center = Vector3(snappedf(point.x, g), snappedf(point.y, g), snappedf(point.z, g))
		if is_instance_valid(host._rotate_bar) and host._rotate_bar.visible:
			host._rotate_bar.set_center_tb(host._world_to_tb_point(center))   # keep the field tracking the drag
		host.update_overlays()
		return

	var a = _angle_on_ring(camera, screen_pos, center, axis)
	if a == null:
		return
	# The bar's angle field is the snap step, so the drag lands on the same increments Apply uses.
	# A step of 0 leaves snappedf a no-op, which is exactly the free rotation that asks for.
	var step := deg_to_rad(host.rotate_snap_deg())
	angle = snappedf(a - start_angle, step)
	_apply_rotation()
	host.update_overlays()


## Apply a one-shot rotation from the rotate bar. TB axis 0/1/2 (X/Y/Z) maps to one of the plugin's
## own MOVE_AXES with a sign: the up-axis swap sends TB Y onto Godot's -BACK (FORWARD), which the drag
## path expresses as the BACK ring turned the other way.
func apply_oneshot(degrees: float, tb_axis: int) -> void:
	const TB_AXIS_MAP := [[0, 1.0], [2, -1.0], [1, 1.0]]   # tb x/y/z -> [MOVE_AXES index, angle sign]
	var brushes := host._selected_geometry()
	if brushes.is_empty() or is_zero_approx(degrees):
		return
	center_for(brushes)   # make sure `center` is populated for this selection
	nodes = brushes
	start_planes = []
	start_faces = []
	start_positions = []
	for node in brushes:
		start_planes.append(node.planes.duplicate())
		start_faces.append(node.face_data)
		start_positions.append(node.global_position)
	axis = int(TB_AXIS_MAP[tb_axis][0])
	angle = deg_to_rad(degrees) * float(TB_AXIS_MAP[tb_axis][1])
	moving_center = false
	active = true
	_apply_rotation()          # rewrites planes/positions/face_data from the start state
	commit_drag()              # records the undo action and resets the drag state


## Rotate the brushes' GEOMETRY about the pivot: planes are rewritten, the node orbits the pivot,
## and the node's basis is never touched. Rebuilt from the starting state every frame rather than
## composed, so a long drag can't accumulate error and dragging back to 0 restores exactly.
func _apply_rotation() -> void:
	var turn := Basis(host.MOVE_AXES[axis], angle)
	var shift := center - turn * center
	for i in nodes.size():
		var node: Node3D = nodes[i]
		host._transform_brush_planes(node, start_planes[i], turn)
		node.global_position = center \
			+ turn * (start_positions[i] - center)
		# Assigned last either way, so the plane carry can't get a say — but WHICH value depends
		# on texture lock, unlike a flip.
		#
		# Lock ON: carry the projection through the rotation, so the texture turns with the
		# brush. Lock OFF: restore the ORIGINAL projection untouched, so the brush rotates
		# underneath a world-fixed texture. That's TrenchBroom's behaviour — rotation runs
		# through the same alignment-lock path as every other transform, and is NOT the special
		# case a flip is (a mirrored brush must carry its texture or it stops being a mirror).
		node.face_data = host._transform_face_data(start_faces[i], turn, shift) \
			if node.texture_lock else start_faces[i]


func commit_drag() -> void:
	if active and not moving_center and not nodes.is_empty() \
			and not is_zero_approx(angle):
		var ur := host.get_undo_redo()
		ur.create_action("Rotate Brush")
		for i in nodes.size():
			var node: Node3D = nodes[i]
			# A group's kernel is transient: the group records the whole reshape as one `members`
			# change (host._end_group_drag), so recording the kernel here would leave undo pointing
			# at a node that is freed the moment the drag ends. Only owned nodes are real geometry.
			if node.owner == null:
				continue
			# Position first, then planes, then face_data — assigning planes rebuilds and
			# overwrites the UV state, and moving the node can shift it again under texture lock.
			ur.add_do_property(node, "global_position", node.global_position)
			ur.add_do_property(node, "planes", node.planes.duplicate())
			ur.add_do_property(node, "face_data", node.face_data)
			ur.add_undo_property(node, "global_position", start_positions[i])
			ur.add_undo_property(node, "planes", start_planes[i])
			ur.add_undo_property(node, "face_data", start_faces[i])
		ur.commit_action(false)   # already applied during the drag
	reset()


func reset() -> void:
	active = false
	moving_center = false
	center_alt = false
	axis = -1
	angle = 0.0
	nodes = []
	start_planes = []
	start_faces = []
	start_positions = []


func draw(overlay: Control) -> void:
	var brushes := host._selected_geometry()
	if brushes.is_empty():
		return
	var at := center_for(brushes)
	var radius := ring_radius(host._draw_camera, at)
	var hot_axis := axis if active and not moving_center else hover_axis
	var signs := _rotate_octant(at, host._draw_camera.global_position)
	for ax in 3:
		# Dim the rings that aren't in play so the live one reads clearly.
		var col: Color = host.AXIS_COLORS[ax]
		var hot := ax == hot_axis
		if hot_axis >= 0 and not hot:
			col = Color(col, 0.2)
		_draw_ring(overlay, at, radius, ax, signs, col, 2.5 if hot else 1.5)

	# Axis cross through the pivot while dragging, so the rotation axis is unmistakable.
	if active and not moving_center:
		var a: Vector3 = host.MOVE_AXES[axis]
		host._draw_world_line(overlay, at - a * radius, at + a * radius,
			Color(host.AXIS_COLORS[axis], 0.7), 1.5)

	# Dragging the pivot itself: show the same axis-aligned distance legs the move tool uses, so you
	# can read how far (in TB units) it has travelled — X/Z along the ground, Y last (ALT = vertical).
	if moving_center:
		host._draw_axis_legs(overlay, center_start, at - center_start)

	if not host._draw_camera.is_position_behind(at):
		var screen_at := host._draw_camera.unproject_position(at)
		var hot_center := moving_center or hover_center
		overlay.draw_circle(screen_at, host.CENTER_HANDLE_PX + (1.0 if hot_center else 0.0),
			host.ROTATE_CENTER_HOT if hot_center else host.ROTATE_CENTER_COLOR)
		# Hover affordance, mirroring the brush vertex handles: a red ring plus a position readout in
		# TB units (same convention as the Center field). Skipped mid-drag, where the axis legs above
		# already report the offset.
		if hover_center and not moving_center:
			overlay.draw_arc(screen_at, host.CENTER_HANDLE_PX + 3.0, 0.0, TAU, 24, Palette.TB_RED, 2.0, true)
			var tb := host._world_to_tb_point(at)
			host._draw_dim_label(overlay, overlay.get_theme_default_font(), host.LABEL_FONT_SIZE,
				screen_at - Vector2(0.0, host.CENTER_HANDLE_PX + 26.0),
				"%d %d %d" % [roundi(tb.x), roundi(tb.y), roundi(tb.z)],
				Color(Palette.TB_RED, host._label_style.bg_color.a))

	if active and not moving_center and not is_zero_approx(angle):
		var font := overlay.get_theme_default_font()
		var label_at := host._draw_camera.unproject_position(at)
		host._draw_dim_label(overlay, font, host.LABEL_FONT_SIZE, label_at + Vector2(0, -24),
			"%d°" % int(round(rad_to_deg(angle))))


func _draw_ring(overlay: Control, at: Vector3, radius: float, ax: int,
		signs: Vector3, col: Color, width: float) -> void:
	for seg in _ring_segments(at, radius, ax, signs):
		host._draw_world_line(overlay, seg[0], seg[1], col, width)
