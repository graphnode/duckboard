@tool
extends RefCounted
## Scale tool: drag a bounding-box handle (8 corners or 6 sides) to resize the selection's GEOMETRY
## about the opposite handle — or the box centre while ALT is held. A side handle scales one axis,
## a corner scales all three; SHIFT scales the other axes proportionally. Rebuilt from the drag's
## start bounds every frame so a long drag can't accumulate error, and an invalid (collapsed or
## inverted) frame is simply skipped so the drag stays recoverable. Also drives the one-shot scale
## from the top-toolbar scale bar.
##
## Owned by the Duckboard plugin, reached through `host` for the selection, grid, the shared handle
## picking / box-and-line geometry, undo, and the overlay box/quad/dimension draws.

const Palette := preload("res://addons/duckboard/palette.gd")

var host: Duckboard

var nodes: Array[Node3D] = []
var start_points: Array = []       # PackedVector3Array per node, LOCAL space
var start_planes: Array = []
var start_faces: Array = []
var start_bounds := AABB()         # selection bounds at grab time (world)
var bounds := AABB()               # bounds as dragged (world)
## Which sides move, per axis: +1 = the max side, -1 = the min side, 0 = this axis is pinned.
## A face handle sets one component, a corner handle all three — that single difference is the
## whole distinction between scaling on one axis and on three.
var dir := Vector3i.ZERO
var grab := Vector3.ZERO           # handle position at drag start (world)
## The handle is constrained to a LINE, not to a plane like the other tools: a side runs along its
## own normal, a corner along the diagonal through the opposite corner. Both lines pass through the
## box centre, which is why ALT is free to mean "anchor at centre" here — the line is the same
## either way — while it means "drag vertically" everywhere else.
var line_origin := Vector3.ZERO
var line_dir := Vector3.ZERO
## Where the cursor's ray met the handle line at the moment of the press. The drag measures from
## HERE, not from the handle itself.
var line_press := Vector3.ZERO
var active := false
var screen := Vector2.ZERO         # last cursor position, to re-run on modifier changes
## ALT: both opposite sides move, so both get drawn. Tracked while merely hovering too, not only
## during a drag, so the preview matches what a click would do.
var center_anchor := false
var hover_dir := Vector3i.ZERO     # handle the cursor is targeting, for the highlight


func _init(p_host: Duckboard) -> void:
	host = p_host


## Scale `brushes` so their combined bounding box multiplies by `factor` per Godot axis, holding
## the box centre fixed. Drives the same drag machinery the handles use (validity floor, affine
## remap, undo commit) so a bar scale behaves exactly like dragging a handle to the same size.
func scale_selection(brushes: Array[Node3D], factor: Vector3) -> void:
	var from := host._selection_world_aabb(brushes)
	start_bounds = from   # _bounds_valid reads this
	var new_size := Vector3(from.size.x * factor.x, from.size.y * factor.y, from.size.z * factor.z)
	var target := host._bounds_scaled_about(from, new_size, from.get_center())
	if not _bounds_valid(target):
		reset()
		return   # would collapse a brush below a grid cell; refuse, as the drag does
	nodes = brushes
	start_points = []
	start_planes = []
	start_faces = []
	for node in brushes:
		start_points.append(node.get_vertices())
		start_planes.append(node.planes.duplicate())
		start_faces.append(node.face_data)
	bounds = target
	active = true
	_apply()             # remaps every brush's vertices onto the new bounds
	commit_drag()        # records the undo action and resets the drag state
	host.update_overlays()


## Grab a bounding-box handle: one of the 8 corners, or one of the 6 sides.
func begin_drag(camera: Camera3D, screen_pos: Vector2) -> bool:
	var brushes := host._selected_geometry()
	if brushes.is_empty():
		return false
	var b := host._selection_world_aabb(brushes)
	var d := host._pick_scale_handle(camera, screen_pos, b)
	if d == Vector3i.ZERO:
		return false

	nodes = brushes
	start_points = []
	start_planes = []
	start_faces = []
	for node in brushes:
		start_points.append(node.get_vertices())
		start_planes.append(node.planes.duplicate())
		start_faces.append(node.face_data)
	start_bounds = b
	bounds = b
	dir = d
	grab = host._handle_position(b, d)
	var line := _handle_line(b, d)
	line_origin = line[0]
	line_dir = line[1]
	line_press = host._closest_point_on_line(
		camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos),
		line_origin, line_dir)
	screen = screen_pos
	active = true
	return true


## The line the handle slides along: a side moves along its own normal, a corner along the diagonal
## from the opposite corner. Both pass through the box centre.
func _handle_line(b: AABB, d: Vector3i) -> Array:
	var here := host._handle_position(b, d)
	if host._is_side_dir(d):
		var axis := host._dir_axis(d)
		var normal := Vector3.ZERO
		normal[axis] = float(d[axis])
		return [here, normal]
	var opposite := host._handle_position(b, -d)
	var along := here - opposite
	if along.length_squared() < 1e-12:
		along = Vector3.UP
	return [here, along.normalized()]


## ALT anchors the scale at the box centre (so both sides move); SHIFT scales the other axes by the
## same ratio. CTRL is deliberately unused — TrenchBroom's scale tool ignores it too.
func update_drag(camera: Camera3D, screen_pos: Vector2, alt: bool, shift: bool) -> void:
	screen = screen_pos
	center_anchor = alt
	# Where the cursor's ray comes closest to the handle line, snapped along it. Unbounded, so the
	# cursor can wander well off the box and the drag still tracks.
	var on_line := host._closest_point_on_line(
		camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos),
		line_origin, line_dir)
	# Carry the grab offset: the handle moves BY however far the cursor has travelled along the
	# line, so it starts exactly where it was and follows relative to the press.
	var proposed := grab + (on_line - line_press)
	var snapped := host._snap_along_line(proposed, line_origin, line_dir, host.snap_size)
	var delta := snapped - grab

	# Always recomputed from the DRAG-START bounds, never applied incrementally. That's what makes
	# an invalid box recoverable: a frame that would invert the box is simply skipped, and dragging
	# back out resumes exactly, with no accumulated error to undo.
	var next = _bounds_for(delta, alt, shift)
	if next == null or not _bounds_valid(next):
		return
	bounds = next
	_apply()
	host.update_overlays()


## One grid cell is the floor for every axis. TrenchBroom only refuses a non-positive extent, but
## our corners are grid-snapped on every hull re-solve, so anything thinner than a cell snaps flat
## and the brush is gone.
##
## The floor never DEMANDS growth: an axis that already started thinner than a cell (the grid can be
## made coarser than an existing brush) only has to keep the size it had, or the tool would freeze
## on that brush entirely.
func _bounds_valid(candidate: AABB) -> bool:
	for i in 3:
		var floor_size: float = minf(start_bounds.size[i], host.snap_size)
		if candidate.size[i] < floor_size - 1e-6:
			return false
	return true


## The new bounds for a drag delta, or null when it would collapse or invert the box.
func _bounds_for(delta: Vector3, at_center: bool, proportional: bool):
	var from := start_bounds
	if host._is_side_dir(dir):
		var axis := host._dir_axis(dir)
		var normal := Vector3.ZERO
		normal[axis] = float(dir[axis])
		# Only the component along the side's own normal counts.
		var length_delta := normal.dot(delta)
		if at_center:
			length_delta *= 2.0   # both sides move, so the grabbed one still tracks the cursor
		var new_length: float = from.size[axis] + length_delta
		if new_length <= 0.0:
			return null
		var new_size := from.size
		new_size[axis] = new_length
		if proportional:
			var ratio: float = new_length / from.size[axis]
			for i in 3:
				if i != axis:
					new_size[i] = from.size[i] * ratio
		var anchor := from.get_center() if at_center else host._handle_position(from, -dir)
		return host._bounds_scaled_about(from, new_size, anchor)

	var old_corner := host._handle_position(from, dir)
	var opposite := host._handle_position(from, -dir)
	var anchor := from.get_center() if at_center else opposite
	var new_corner := old_corner + delta
	# Reject rather than clamp: if any axis has crossed the anchor the box has turned inside out,
	# and skipping the frame keeps the drag recoverable.
	for i in 3:
		if is_equal_approx(new_corner[i], anchor[i]):
			return null
		if (old_corner[i] > anchor[i]) != (new_corner[i] > anchor[i]):
			return null
	if at_center:
		return host._aabb_from_points(anchor - (new_corner - anchor), new_corner)
	return host._aabb_from_points(opposite, new_corner)


## Map every brush through the affine transform taking the ORIGINAL bounds onto the current ones.
## Rebuilt from the starting geometry each frame rather than applied incrementally, so the drag
## can't accumulate rounding as it goes.
func _apply() -> void:
	var from := start_bounds
	var factor := Vector3.ONE
	for axis in 3:
		if from.size[axis] > 1e-6:
			factor[axis] = bounds.size[axis] / from.size[axis]
	var origin := from.position
	var target := bounds.position
	for i in nodes.size():
		var node: Node3D = nodes[i]
		var to_world: Transform3D = node.global_transform
		var to_local := to_world.affine_inverse()
		var source: PackedVector3Array = start_points[i]
		var moved := PackedVector3Array()
		for p in source:
			var world: Vector3 = to_world * p
			moved.append(to_local * (target + (world - origin) * factor))
		# No corner snap: the handle already snapped along its line, and forcing the scaled vertices
		# back onto integers would distort the result. TrenchBroom leaves them fractional.
		node.set_from_points(moved, false)


func commit_drag() -> void:
	if active and not nodes.is_empty():
		var ur := host.get_undo_redo()
		ur.create_action("Scale Brush")
		for i in nodes.size():
			var node: Node3D = nodes[i]
			# A group's kernel is transient — the group records the reshape as one `members` change
			# (host._end_group_drag), so recording it here would point undo at a freed node.
			if node.owner == null:
				continue
			var before: Vector3 = node.global_position
			node.recenter()
			ur.add_do_property(node, "global_position", node.global_position)
			ur.add_do_property(node, "planes", node.planes.duplicate())
			ur.add_do_property(node, "face_data", node.face_data)
			ur.add_undo_property(node, "global_position", before)
			ur.add_undo_property(node, "planes", start_planes[i])
			ur.add_undo_property(node, "face_data", start_faces[i])
		ur.commit_action(false)   # already applied during the drag
	reset()


## The green bounding box, its corner handles, and a highlight on whichever handle the cursor is
## targeting. Drawn OVER the usual red brush wireframe: the box is what the drag acts on, while the
## red outlines still show what's actually being reshaped.
func draw(overlay: Control) -> void:
	var brushes := host._selected_geometry()
	if brushes.is_empty():
		return
	var b := bounds if active else host._selection_world_aabb(brushes)
	host._draw_box_outline(overlay, b, Color(Palette.TB_RED, 0.9), 1.5)

	# The targeted SIDE is filled translucent green with green edges — a side has no dot of its own,
	# so the fill is what tells you which face a drag would move. With a centre anchor the OPPOSITE
	# side is filled too, because it moves as well — while HOVERING as much as while dragging, so
	# holding ALT shows what the drag is about to do before committing to it.
	var targeted := dir if active else hover_dir
	if targeted != Vector3i.ZERO and host._is_side_dir(targeted):
		_box_side_fill(overlay, b, targeted)
		if center_anchor:
			_box_side_fill(overlay, b, -targeted)

	for d in host._scale_corner_dirs():
		var world := host._handle_position(b, d)
		if host._draw_camera.is_position_behind(world):
			continue
		var at := host._draw_camera.unproject_position(world)
		var hot := d == targeted
		overlay.draw_circle(at, host.SCALE_HANDLE_PX + (1.0 if hot else 0.0),
			Color.WHITE if hot else Color(Palette.TB_GREEN, 0.95))

	# While dragging, the live dimensions are the useful readout.
	if active:
		host._draw_dimension_labels(overlay, b.get_center(), b.size)


## Translucent green face plus a green outline. Drawn as a screen-space polygon from the projected
## corners, which is fine because a box side is always convex and planar.
func _box_side_fill(overlay: Control, b: AABB, d: Vector3i) -> void:
	host._draw_quad_fill(overlay, host._side_quad(b, d), Palette.TB_GREEN)


func reset() -> void:
	active = false
	nodes = []
	start_points = []
	start_planes = []
	start_faces = []
	dir = Vector3i.ZERO
	center_anchor = false
