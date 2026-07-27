@tool
extends RefCounted
## Brush tool: accumulate points on existing faces, then build their CONVEX HULL. The one tool on the
## palette that builds geometry — the Simple Shape drag-a-box needs no tool and no reference geometry,
## so this is how non-cuboid shapes are made, against brushes that already exist. A single click
## places one point; a drag on a face places the rectangle it spans; SHIFT+drag over the flat
## polygon extrudes it into a prism. The live shape is previewed as an unowned Brush (the plugin
## owns the node so scene scans and CSG can exclude it) solved by the same hull code as the result.
##
## Owned by the Duckboard plugin, reached through `host` for the selection grid, the shared
## face raycast / on-face snap, the ray/line/polygon math, undo, the active surface + brush parent,
## the ghost shader, the preview-node slot, and the overlay wireframe/line/fill/status draws.

const Palette := preload("res://addons/duckboard/palette.gd")

var host: Duckboard

const HULL_POINT_PX := 4.0

var placed := PackedVector3Array()      # world space, in placement order
var press := Vector2.ZERO
var anchor := Vector3.ZERO              # snapped press point (world), for a single click
var anchor_raw := Vector3.ZERO          # unsnapped press point, for the outward rectangle snap
var anchor_normal := Vector3.ZERO
var armed := false                      # button down on a face, gesture not yet decided
var rect := PackedVector3Array()        # live rectangle corners while dragging
var extruding := false
var extrude_normal := Vector3.ZERO
var extrude_start := Vector3.ZERO
var extrude_offset := 0.0
var shift_hover := false                # SHIFT held over the polygon: the extrude is available
var ghost_material: ShaderMaterial      # transparent look while extruding
var solid := false                      # the points enclose a volume, so the preview is real
var screen := Vector2.ZERO              # last cursor position, to re-test hover on SHIFT


func _init(p_host: Duckboard) -> void:
	host = p_host


## Fix a point onto a face's plane by solving its dominant axis, leaving the other two alone.
## Used to keep rectangle corners on the face they were drawn on.
func _onto_plane(point: Vector3, normal: Vector3, d: float) -> Vector3:
	var a := normal.abs()
	var axis := 0 if (a.x >= a.y and a.x >= a.z) else (1 if a.y >= a.z else 2)
	if absf(normal[axis]) < 1e-6:
		return point
	var out := point
	var total := 0.0
	for i in 3:
		if i != axis:
			total += normal[i] * out[i]
	out[axis] = (d - total) / normal[axis]
	return out


## Snapped point on whatever face is under the cursor, or null. Same glue-to-face rule the clip
## tool uses: two axes snapped to the grid, the third solved from the plane.
func target(camera: Camera3D, screen_pos: Vector2):
	# include_groups: a closed group is a surface to build against like any brush. The hit comes back
	# as that member's kernel, a real Brush, so everything below is unchanged.
	var hit = host._raycast_brush_faces(
		camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos), true)
	if hit == null:
		return null
	# Both forms: a single click wants the glue-to-face snap, but the rectangle drag snaps its
	# own corners OUTWARD from the raw hit and would be defeated by pre-snapped input.
	return {"point": host._snap_on_face(hit.point, hit.normal, hit.point, host.grid_size),
		"raw": hit.point, "normal": hit.normal, "node": hit.node, "face": hit.face}


func add_points(new_points: PackedVector3Array) -> void:
	for p in new_points:
		var duplicate_found := false
		for existing in placed:
			if existing.distance_squared_to(p) < 1e-8:
				duplicate_found = true
				break
		if not duplicate_found:
			placed.append(p)
	rebuild_preview()
	_prune_points()
	host.update_overlays()


## The four corners of the rectangle spanned by two points on the same face.
##
## Axis-aligned in the WORLD frame, not the face's own tangent frame: the dominant axis of the
## normal is dropped and the rectangle is built in the other two world axes, with the third solved
## from the plane. On a sloped face that gives a world-aligned rectangle projected onto the plane
## rather than one rotated to the face — which is what lets rectangles drawn on different faces line
## up with each other and with the grid.
##
## Corners snap OUTWARD — floor the minimum, ceil the maximum — so the rectangle always grows to the
## enclosing grid lines. Snapping to nearest would let it shrink away from the corner you dragged
## to, which reads as the drag not tracking the cursor.
func rectangle(from: Vector3, to: Vector3, normal: Vector3,
		anchor_pt: Vector3) -> PackedVector3Array:
	var a := normal.abs()
	var axis := 0 if (a.x >= a.y and a.x >= a.z) else (1 if a.y >= a.z else 2)
	var i := (axis + 1) % 3
	var j := (axis + 2) % 3
	var g := host.grid_size
	var low := Vector3(minf(from.x, to.x), minf(from.y, to.y), minf(from.z, to.z))
	var high := Vector3(maxf(from.x, to.x), maxf(from.y, to.y), maxf(from.z, to.z))
	var d := normal.dot(anchor_pt)
	var out := PackedVector3Array()
	for pair in [[false, false], [true, false], [true, true], [false, true]]:
		var p := Vector3.ZERO
		p[i] = ceilf(high[i] / g) * g if pair[0] else floorf(low[i] / g) * g
		p[j] = ceilf(high[j] / g) * g if pair[1] else floorf(low[j] / g) * g
		out.append(_onto_plane(p, normal, d))
	return out


## Plane the placed points lie in, or null when they aren't coplanar (or there aren't enough).
## Extruding only makes sense from a flat polygon — that's the shape being pushed. Works on the
## WORKING points, so a rectangle being dragged is already part of the shape.
func _current_plane() -> Variant:
	var points := _working_points()
	if points.size() < 3:
		return null
	var origin := points[0]
	var normal := Vector3.ZERO
	for i in range(1, points.size() - 1):
		normal += (points[i] - origin).cross(points[i + 1] - origin)
	if normal.length_squared() < 1e-12:
		return null
	normal = normal.normalized()
	var d := normal.dot(origin)
	for p in points:
		if absf(normal.dot(p) - d) > 1e-4:
			return null      # not flat, so there's no polygon to extrude
	return Plane(normal, d)


## The placed points as an ordered ring around the OUTSIDE of the shape — their convex hull, not
## their placement order and not an angle sort about the centroid.
##
## An angle sort looks right until a point lands inside the others: it then gets threaded into the
## ring and the outline crosses itself. The hull simply leaves interior points out, which is also
## what the finished brush will do with them.
func _polygon_ring() -> Variant:
	var plane = _current_plane()
	if plane == null:
		return null
	# Pulled out as a typed local: _current_plane() returns Variant (it can be null), so anything
	# derived from `plane.normal` inline is untyped too and `:=` has nothing to infer from.
	var normal: Vector3 = plane.normal
	var ring := _planar_hull(_working_points(), normal)
	return null if ring.size() < 3 else {"ring": ring, "normal": normal}


## Convex hull of COPLANAR points, returned as an ordered ring. Andrew's monotone chain, run in the
## plane's own 2D frame. Collinear points are dropped (the `<= 0` test), so the ring carries only
## genuine corners.
func _planar_hull(points: PackedVector3Array, normal: Vector3) -> PackedVector3Array:
	if points.size() < 3:
		return points
	var u := _perpendicular_to(normal)
	var v := normal.cross(u).normalized()
	var flat := []
	for i in points.size():
		flat.append({"i": i, "x": points[i].dot(u), "y": points[i].dot(v)})
	flat.sort_custom(func(a, b): return a.x < b.x or (a.x == b.x and a.y < b.y))

	var lower := []
	for p in flat:
		while lower.size() >= 2 and _cross_2d(lower[-2], lower[-1], p) <= 0.0:
			lower.pop_back()
		lower.append(p)
	var upper := []
	for k in range(flat.size() - 1, -1, -1):
		var p = flat[k]
		while upper.size() >= 2 and _cross_2d(upper[-2], upper[-1], p) <= 0.0:
			upper.pop_back()
		upper.append(p)
	lower.pop_back()      # both chains repeat the endpoints
	upper.pop_back()

	var ring := PackedVector3Array()
	for entry in lower + upper:
		ring.append(points[entry.i])
	return ring


func _cross_2d(o, a, b) -> float:
	return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)


## Do these points enclose a volume — i.e. are at least four of them, with at least one off the
## plane of the rest? Anything flatter can only ever be an outline.
func _points_form_solid(points: PackedVector3Array) -> bool:
	if points.size() < 4:
		return false
	var a := points[0]
	var normal := Vector3.ZERO
	for i in range(1, points.size()):
		for j in range(i + 1, points.size()):
			var candidate := (points[i] - a).cross(points[j] - a)
			if candidate.length_squared() > 1e-12:
				normal = candidate.normalized()
				break
		if normal != Vector3.ZERO:
			break
	if normal == Vector3.ZERO:
		return false          # every point is collinear
	var d := normal.dot(a)
	for p in points:
		if absf(normal.dot(p) - d) > 1e-4:
			return true
	return false


## Drop points that aren't corners of the shape. TrenchBroom's only storage IS the hull, so a point
## swallowed by the others ceases to exist — and since points can't be removed individually, keeping
## them would only ever show handles with nothing under them.
func _prune_points() -> void:
	if solid and is_instance_valid(host._hull_preview):
		# A closed solid: the brush already solved the hull, so take its corners.
		placed = host._hull_preview.get_vertices()
		return
	var plane = _current_plane()
	if plane != null:
		var ring := _planar_hull(placed, plane.normal)
		if ring.size() >= 3:
			placed = ring


func _perpendicular_to(n: Vector3) -> Vector3:
	var axis := Vector3.UP if absf(n.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	return n.cross(axis).normalized()


## Is the cursor over the flat polygon placed so far? TrenchBroom only offers the extrude when the ray
## actually hits it, so Shift-dragging anywhere else stays free for other gestures.
func polygon_hovered(camera: Camera3D, screen_pos: Vector2) -> bool:
	var shape = _polygon_ring()
	if shape == null:
		return false
	var origin := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var denom: float = shape.normal.dot(dir)
	if absf(denom) < 1e-6:
		return false
	var t: float = shape.normal.dot(shape.ring[0] - origin) / denom
	if t < 0.0:
		return false
	return host._point_in_polygon(origin + dir * t, shape.ring, shape.normal)


func begin_extrude(camera: Camera3D, screen_pos: Vector2) -> bool:
	var plane = _current_plane()
	if plane == null or not polygon_hovered(camera, screen_pos):
		return false
	extruding = true
	shift_hover = false
	extrude_normal = plane.normal
	extrude_start = host._closest_point_on_line(
		camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos),
		placed[0], plane.normal)
	extrude_offset = 0.0
	return true


func update_extrude(camera: Camera3D, screen_pos: Vector2) -> void:
	# Constrained to the polygon's own normal, so the extrude can only thicken the shape — never skew
	# it into something that isn't a prism.
	var here := host._closest_point_on_line(
		camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos),
		placed[0], extrude_normal)
	var travelled := (here - extrude_start).dot(extrude_normal)
	extrude_offset = snappedf(travelled, host.grid_size)
	rebuild_preview()
	host.update_overlays()


func commit_extrude() -> void:
	var extruded := PackedVector3Array()
	if extruding and not is_zero_approx(extrude_offset):
		for p in placed:
			extruded.append(p + extrude_normal * extrude_offset)
	# Clear the drag state BEFORE folding the extruded points in. _working_points() adds the extrude
	# on top of whatever is stored, so committing first would apply the offset to points that
	# already contain it.
	extruding = false
	extrude_offset = 0.0
	if extruded.is_empty():
		rebuild_preview()
	else:
		add_points(extruded)
	host.update_overlays()


## Every point currently contributing to the shape, including the live gesture.
func _working_points() -> PackedVector3Array:
	var out := placed.duplicate()
	for p in rect:
		out.append(p)
	if extruding and not is_zero_approx(extrude_offset):
		for p in placed:
			out.append(p + extrude_normal * extrude_offset)
	return out


## The hull so far, as an unowned Brush. Reusing the real brush node means the preview is solved by
## the same hull code and textured by the same shader as the result — there is no second
## implementation to disagree with the first.
func rebuild_preview() -> void:
	var points := _working_points()
	var root := EditorInterface.get_edited_scene_root()
	# Decided from the POINTS, never from the preview's plane count. set_from_points silently keeps
	# the old planes when the hull is degenerate, and a freshly built brush's "old planes" are the
	# default 1 m box _ready() gave it — so a plane-count test reads a flat point set as a solid
	# cube, shows it, and then _prune_points adopts that cube's corners as the user's points.
	solid = _points_form_solid(points)
	if root == null or not solid:
		if is_instance_valid(host._hull_preview):
			host._hull_preview.visible = false
		return
	if not is_instance_valid(host._hull_preview):
		host._hull_preview = Brush.new()
		host._hull_preview.grid_size = host.grid_size
		# Seeded BEFORE entering the tree, so _ready() sees real planes and never builds the default
		# box in the first place.
		host._hull_preview.set_from_points(points)
		root.add_child(host._hull_preview)   # unowned -> never saved
	else:
		host._hull_preview.set_from_points(points)
	host._hull_preview.global_position = Vector3.ZERO
	host._hull_preview.visible = true
	# The preview shows the SHAPE, not its surfaces: the same transparent grid ghost the drag-a-box
	# tool uses, so a brush under construction reads the same way whichever tool made it.
	# material_override replaces every face at once, which is what we want — the per-face textures
	# are meaningless until the brush exists.
	#
	# It stays ghosted for as long as the brush is unbuilt, not just while the mouse is down.
	# Snapping to solid on mouse-release would claim the brush exists when Enter hasn't been pressed
	# yet.
	if ghost_material == null:
		ghost_material = ShaderMaterial.new()
		ghost_material.shader = host.GHOST_SHADER
		ghost_material.set_shader_parameter("cell_size", host.grid_size)
	host._hull_preview.material_override = ghost_material


func _clear_preview() -> void:
	if is_instance_valid(host._hull_preview):
		host._hull_preview.queue_free()
	host._hull_preview = null


func reset() -> void:
	placed = PackedVector3Array()
	rect = PackedVector3Array()
	armed = false
	extruding = false
	extrude_offset = 0.0
	shift_hover = false
	solid = false
	_clear_preview()


## Turn the placed points into a real brush. The hull solver is already the brush's own
## set_from_points, so this is mostly bookkeeping.
func commit() -> void:
	var points := _working_points()
	if points.size() < 4:
		return
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var bounds := AABB(points[0], Vector3.ZERO)
	for p in points:
		bounds = bounds.expand(p)
	var g := host.grid_size
	var centre := bounds.get_center()
	centre = Vector3(snappedf(centre.x, g), snappedf(centre.y, g), snappedf(centre.z, g))

	var brush := Brush.new()
	brush.grid_size = host.grid_size
	brush.texture_lock = host.texture_lock
	brush.uv_lock = host.uv_lock
	brush.name = "Brush"
	brush.position = centre
	var local := PackedVector3Array()
	for p in points:
		local.append(p - centre)
	brush.set_from_points(local)
	if brush.planes.size() < 4:
		return                          # degenerate (all points coplanar): nothing to build
	host._apply_active_surface(brush)

	var parent := host._brush_parent()
	var ur := host.get_undo_redo()
	ur.create_action("Create Brush")
	ur.add_do_method(parent, "add_child", brush, true)
	# The hull was solved in WORLD space around `centre`, so the world position is restated after
	# parenting in case the parent carries a transform of its own.
	ur.add_do_property(brush, "global_position", centre)
	ur.add_do_method(brush, "set_owner", root)
	ur.add_do_reference(brush)
	ur.add_undo_method(parent, "remove_child", brush)
	ur.commit_action()

	reset()
	var sel := EditorInterface.get_selection()
	sel.clear()
	sel.add_node(brush)
	host.update_overlays()


func draw(overlay: Control) -> void:
	# Once the shape encloses a volume the ghosted solid carries it, so it gets a wireframe.
	if solid and is_instance_valid(host._hull_preview):
		host._draw_brush_wireframe(overlay, host._hull_preview, Palette.TB_YELLOW)
	# While actually extruding, the solid is the whole story — points and the face highlight would
	# only clutter the thing they just produced.
	if extruding:
		return

	# Holding SHIFT over the flat polygon highlights it before the extrude, so it's clear what's about
	# to be extruded — and clear when the gesture isn't available at all.
	if shift_hover:
		var shape = _polygon_ring()
		if shape != null:
			# Drawn from BOTH sides: the fill is back-face culled, and which way the polygon happens
			# to face depends on the order points were placed.
			host._draw_polygon_fill(overlay, shape.ring, shape.normal, Color(Palette.TB_YELLOW, 0.35))
			host._draw_polygon_fill(overlay, shape.ring, -shape.normal, Color(Palette.TB_YELLOW, 0.35))

	# The OUTLINE of the shape so far, around its outside — including any rectangle being dragged,
	# already merged in. The rectangle is deliberately NOT drawn on its own: the merged outline is
	# the result, and drawing the gesture too would show a box that won't survive.
	var outline = _polygon_ring()
	if outline != null:
		for i in outline.ring.size():
			host._draw_world_line(overlay, outline.ring[i],
				outline.ring[(i + 1) % outline.ring.size()], Color(Palette.TB_YELLOW, 0.95), 2.0)

	# Handles go on the OUTLINE's corners, not on every working point. A point swallowed by the
	# others isn't a corner of the shape and won't survive the merge, so a dot floating inside the
	# outline would be advertising a vertex that is about to stop existing.
	# Explicitly typed: `outline` is Variant (it can be null), so `outline.ring` is untyped too.
	var handles: PackedVector3Array = outline.ring if outline != null else _working_points()
	for p in handles:
		if host._draw_camera.is_position_behind(p):
			continue
		overlay.draw_circle(host._draw_camera.unproject_position(p), HULL_POINT_PX, Palette.TB_YELLOW)
	# The hint tracks what the shape can actually DO right now, rather than listing every key: a flat
	# outline can't be built yet but can be extruded, and only a closed solid can be created. Offering
	# "Enter to create" on a flat shape would just invite a keypress that does nothing.
	if not handles.is_empty():
		var hint := "Esc to clear"
		if solid:
			hint = "Enter to create, Esc to clear"
		elif outline != null:
			hint = "Shift+drag the shape to extrude it, Esc to clear"
		host._draw_status_hint(overlay, ["Brush: %d points   (%s)" % [handles.size(), hint]])
