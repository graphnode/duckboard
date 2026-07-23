@tool
extends RefCounted
## Shear tool: leans the selection so a grabbed side face slides while the opposite face stays put.
## Side handles only (no corners). The constraint depends on the face: top/bottom shear freely within
## the face plane (2-DOF, ALT is a no-op), the four sides shear along a single horizontal line
## (1-DOF, ALT swaps it for the world-vertical). Multi-brush selections shear as one solid.
##
## Owned by the Duckboard plugin, reached through `host` for the selection/bounds, handle picking,
## the line/axis math, grid size, undo, and the shared box/quad overlay draws.

const Palette := preload("res://addons/duckboard/palette.gd")

var host: Duckboard

var nodes: Array[Node3D] = []
var start_points: Array = []
var start_planes: Array = []
var start_faces: Array = []
var bounds := AABB()
var dir := Vector3i.ZERO
var press := Vector3.ZERO           # picked point under the current constraint at press
var offset := Vector3.ZERO          # current in-plane displacement of the grabbed face
var base := Vector3.ZERO            # offset carried across an ALT constraint switch
var active := false
var vertical := false               # ALT: drag straight up/down instead of sideways
var screen := Vector2.ZERO
var hover_dir := Vector3i.ZERO


func _init(p_host: Duckboard) -> void:
	host = p_host


func begin_drag(camera: Camera3D, screen_pos: Vector2) -> bool:
	var brushes := host._selected_brushes()
	if brushes.is_empty():
		return false
	var b := host._selection_world_aabb(brushes)
	var d := host._pick_scale_handle(camera, screen_pos, b, false)   # sides only
	if d == Vector3i.ZERO:
		return false
	var hit = _constraint_point(camera, screen_pos, b, d, false)
	if hit == null:
		return false

	nodes = brushes
	start_points = []
	start_planes = []
	start_faces = []
	for node in brushes:
		start_points.append(node.get_vertices())
		start_planes.append(node.planes.duplicate())
		start_faces.append(node.face_data)
	bounds = b
	dir = d
	press = hit
	offset = Vector3.ZERO
	base = Vector3.ZERO
	vertical = false
	screen = screen_pos
	active = true
	return true


## Where the cursor lands under the constraint for this face — and the constraint is NOT simply
## the face's plane:
##
##  * TOP or BOTTOM face: a PLANE (the face's own). Two degrees of freedom — this is the "slide
##    the roof around" case, and ALT is deliberately a no-op here.
##  * The four SIDE faces: a single horizontal LINE, `normal x up`, lying in the face. One
##    degree of freedom. ALT swaps it for the world-vertical line.
##
## So the direction comes from the face's orientation, never from which way the mouse moved.
## Free 2-DOF dragging on a vertical face would let you shear sideways and vertically at once,
## which reads as the brush squirming rather than leaning.
func _constraint_point(camera: Camera3D, screen_pos: Vector2, b: AABB,
		d: Vector3i, want_vertical: bool):
	var axis := host._dir_axis(d)
	var normal := Vector3.ZERO
	normal[axis] = float(d[axis])
	var center := host._handle_position(b, d)
	var origin := camera.project_ray_origin(screen_pos)
	var ray := camera.project_ray_normal(screen_pos)

	if axis == 1:                       # top/bottom: free within the face plane
		var denom := normal.dot(ray)
		if absf(denom) < 1e-6:
			return null                 # edge-on to the face; no usable intersection
		var t := normal.dot(center - origin) / denom
		return null if t < 0.0 else origin + ray * t

	var line_dir := Vector3.UP if want_vertical else normal.cross(Vector3.UP).normalized()
	return host._closest_point_on_line(origin, ray, center, line_dir)


func update_drag(camera: Camera3D, screen_pos: Vector2, alt: bool) -> void:
	screen = screen_pos
	# ALT only means anything on the vertical faces; the top and bottom are already 2-DOF.
	var wants_vertical := alt and host._dir_axis(dir) != 1
	if wants_vertical != vertical:
		# Switching constraint mid-drag: bank what's been sheared so far and re-anchor under the
		# new one, so the brush holds its lean instead of snapping back.
		var rebased = _constraint_point(camera, screen_pos, bounds, dir, wants_vertical)
		if rebased != null:
			base = offset
			press = rebased
			vertical = wants_vertical

	var hit = _constraint_point(camera, screen_pos, bounds, dir, vertical)
	if hit == null:
		return
	# Snapped as a DELTA, relative to the press. Absolute snapping would need one coordinate to
	# snap against, and a sheared face has no such coordinate — this keeps the LEAN on the grid.
	var raw: Vector3 = base + (hit - press)
	var g := host.snap_size
	var delta := Vector3(snappedf(raw.x, g), snappedf(raw.y, g), snappedf(raw.z, g))
	delta[host._dir_axis(dir)] = 0.0   # never along the normal; that would resize, not shear
	offset = delta
	_apply()
	host.update_overlays()


## Lean every brush so the grabbed face has moved by `offset` while the opposite face stays exactly
## where it is.
##
## Each point is displaced in proportion to how far it lies between the two faces: 0 at the
## fixed one, 1 at the grabbed one. Points outside the selection bounds extrapolate, which is
## correct — a multi-brush selection shears as one solid.
func _apply() -> void:
	var axis := host._dir_axis(dir)
	var lo := bounds.position
	var hi := bounds.position + bounds.size
	var fixed: float = lo[axis] if dir[axis] > 0 else hi[axis]
	var span: float = hi[axis] - lo[axis] if dir[axis] > 0 else lo[axis] - hi[axis]
	if absf(span) < 1e-9:
		return
	for i in nodes.size():
		var node: Node3D = nodes[i]
		var to_world: Transform3D = node.global_transform
		var to_local := to_world.affine_inverse()
		var source: PackedVector3Array = start_points[i]
		var moved := PackedVector3Array()
		for p in source:
			var world: Vector3 = to_world * p
			var fraction: float = (world[axis] - fixed) / span
			moved.append(to_local * (world + offset * fraction))
		# No corner snap, as with scale: the shear delta is already grid-snapped, and snapping the
		# result would pull the leaned vertices back onto integers.
		node.set_from_points(moved, false)


func commit_drag() -> void:
	if active and not nodes.is_empty():
		var ur := host.get_undo_redo()
		ur.create_action("Shear Brush")
		for i in nodes.size():
			var node: Node3D = nodes[i]
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


func reset() -> void:
	active = false
	nodes = []
	start_points = []
	start_planes = []
	start_faces = []
	dir = Vector3i.ZERO
	offset = Vector3.ZERO
	base = Vector3.ZERO
	vertical = false


## Same layout as the scale overlay, in blue. No corner dots: shear has side handles only.
func draw(overlay: Control) -> void:
	var brushes := host._selected_brushes()
	if brushes.is_empty():
		return
	# Both recomputed from the live geometry every frame, so the box and the highlighted face
	# grow with the lean instead of sitting on the drag-start shape. Keeping them on the SAME
	# bounds is the point: the blue rect is a face of the red box, and drawing them from
	# different boxes left it visibly detached once the shear opened up.
	#
	# The shear MATH still uses `bounds` — feeding it these live bounds would compound the
	# transform frame over frame.
	var live := host._selection_world_aabb(brushes)
	host._draw_box_outline(overlay, live, Color(Palette.TB_RED, 0.9), 1.5)
	var targeted := dir if active else hover_dir
	if targeted != Vector3i.ZERO:
		host._draw_quad_fill(overlay, host._side_quad(live, targeted), Palette.TB_BLUE)
