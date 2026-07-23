@tool
extends Control
## Visual UV editor. The face outline is FIXED (its real geometric shape); the texture behind it is
## what moves / scales / rotates as the UV mapping changes — like TrenchBroom's UV view. Mouse wheel
## zooms toward the cursor; middle-drag pans. Works on a SINGLE face only; empty otherwise.
##
## Fed the face's fixed shape (face-local 2D, world units) and the same vertices in UV space. The
## affine map between them places the tiled texture onto the fixed face, so editing offset/scale/
## angle slides the texture under a stationary outline.
##
## Interaction, following TrenchBroom's UV editor: left-drag anywhere moves the texture (offset).
## The yellow dot is the material ORIGIN — drag it to move it, or drag one of the red axis lines
## through it to set that coordinate alone. The big yellow circle — or Ctrl+drag anywhere —
## ROTATES the material about the origin. The gray lines are the UV grid (the material's tiling
## edges); each is a scale handle — drag one to scale the material about the origin.

const BG_COLOR := Color(0.10, 0.10, 0.11)
const OUTLINE := Color.WHITE
const CONTEXT_DIM := Color(0.42, 0.42, 0.42)   # modulate for the texture OUTSIDE the face
## Axis marker at the face centre: U red, V green — the 2D convention (X/Y), since the face's
## normal is the missing third axis. Colours match the editor's own axis gizmo.
const AXIS_U_COLOR := Color(0.96, 0.20, 0.30)
const AXIS_V_COLOR := Color(0.53, 0.84, 0.01)
const AXIS_LEN := 34.0                      # marker arm length, screen pixels (zoom-independent)
## The origin widget, TrenchBroom colours: yellow handles, red origin axes, gray UV grid.
const GRID_COLOR := Color(0.65, 0.65, 0.65, 0.45)
const ORIGIN_COLOR := Color(1.0, 0.698039, 0.0)
const ORIGIN_AXIS_COLOR := Color(0.86, 0.20, 0.20)
const HOVER_COLOR := Color(0.86, 0.20, 0.20)   # TrenchBroom red — hovered or active origin / ring
const ORIGIN_R := 6.0                       # filled origin dot: 12 px diameter
const RING_R := 32.0                        # rotation handle circle: 64 px diameter
const HANDLE_HIT := 6.0                     # grab slack around handles, px
const ORIGIN_SNAP_PX := 8.0                 # origin guideline snaps to a face vertex within this, px
const ROT_SNAP_RAD := 0.0872665             # ~5°: a guideline snaps onto a face edge within this
const PAD := 1.7                            # the face fills ~1/PAD of the view; the rest is context
const MAX_TILES := 2000                     # perf guard on the background tiling
const ZOOM_STEP := 1.15
const MIN_ZOOM := 0.05
const MAX_ZOOM := 50.0

## Left-drag moved the texture — delta in UV/tile units. The plugin adds it to the face's offset.
signal offset_dragged(delta_tiles: Vector2)
## A rotate drag began on the rotation handle; `pivot_uv` is the origin in UV/tile space.
signal rotate_started(pivot_uv: Vector2)
## Rotate drag update: TOTAL angle since rotate_started, in degrees, in the stored-angle
## convention — the plugin sets `start angle + delta` about the pivot.
signal rotate_dragged(delta_deg: float)
## A scale drag began on a grid line; `pivot_uv` is the origin in UV/tile space.
signal scale_started(pivot_uv: Vector2)
## Scale drag update: per-axis factor since scale_started (one axis stays 1.0). The plugin sets
## `start scale * factor` about the pivot.
signal scale_dragged(factor: Vector2)

var _texture: Texture2D
var _shape: PackedVector2Array   # face outline, face-local 2D (world units) — the FIXED shape
var _uv: PackedVector2Array      # same vertices in UV space — defines the texture mapping

## Offscreen material preview. A material face can't be drawn by draw_colored_polygon (that takes a
## Texture2D), so a quad wearing the material is rendered in a tiny SubViewport and snapshotted to a
## tiling texture — the canvas then tiles the ACTUAL MATERIAL (its lighting / normal / roughness
## response), not just its albedo, behind the outline.
const MAT_PREVIEW_SIZE := 256
var _mat_viewport: SubViewport
var _mat_quad: MeshInstance3D
var _shown_material: Material     # the material currently snapshotted into _texture (skip re-render)

var _zoom := 1.0
var _pan := Vector2.ZERO
var _panning := false
var _drag_mode := ""             # "" / offset / origin[_u/_v] / rotate / scale_u / scale_v
var _uv_to_canvas := Transform2D.IDENTITY      # last-drawn UV→canvas map (drag deltas, hit-tests)
var _shape_to_canvas := Transform2D.IDENTITY   # last-drawn shape→canvas map (origin placement)
var _u_dir := Vector2.RIGHT      # the texture's U/V directions on the canvas, unit (last drawn)
var _v_dir := Vector2.DOWN

## The material origin (rotation pivot), SHAPE space: it stays put on the face while the mapping
## changes under it. Pure view state — nothing on the brush stores it.
var _origin_shape := Vector2.ZERO

## Which handle the idle cursor is over: origin / rotate / scale_u / scale_v / "" — drawn red.
var _hover := ""

## The grid line under the cursor (hover) or grabbed (scale drag): axis "u"/"v" and its integer UV
## coordinate. Draws that one line red. Empty axis = no line is hot.
var _scale_axis := ""
var _scale_line := 0

# Scale drags are driven in CANVAS space, frozen at drag start; see _begin_scale. The grabbed grid
# line follows the cursor while the origin's UV is pinned, so the emitted factor is just the ratio
# of the cursor's distance from the origin (along the axis) to the grab point's distance.
var _scale_pivot_uv := Vector2.ZERO
var _scale_oc := Vector2.ZERO         # origin in canvas space (the scale pivot; the shape is fixed)
var _scale_dir := Vector2.RIGHT       # axis direction on canvas, unit (U or V)
var _scale_d0 := 1.0                   # grab point's signed distance from origin along the axis

# Rotation drags are driven in CANVAS space, frozen at drag start; see _begin_rotate. The guideline
# follows the cursor 1:1 on screen, and the emitted stored-angle delta is that screen rotation
# converted through the mapping's orientation (so mirrored mappings turn the right way).
var _rotate_pivot_uv := Vector2.ZERO   # pivot in UV space, for the rotate_started signal
var _rotate_oc := Vector2.ZERO         # pivot in canvas space (fixed: the shape doesn't move)
var _rotate_grab := 0.0                # screen angle of the grab point about the pivot
var _rotate_u0 := 0.0                  # screen angle of the U guideline at drag start
var _rotate_orient := 1.0             # sign(det uv→canvas): +1 normal, -1 mirrored mapping


func _ready() -> void:
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED   # so the face polygon can tile the texture
	# Nearest, like the brush materials: the inherited linear+mipmap filtering blurs the pixel-art
	# textures into mush, especially under this canvas's scaled draw transform.
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	clip_contents = true   # tiles, grid and origin axes all draw past the rect on purpose
	resized.connect(queue_redraw)
	mouse_exited.connect(_on_mouse_exited)


## Show a single face (shape + matching UV surface — a Texture2D or a Material), or clear the editor
## when `shape` is empty.
func set_face(surface: Resource, shape: PackedVector2Array, uv: PackedVector2Array) -> void:
	if shape != _shape:
		# A DIFFERENT face (or reshaped geometry): default the origin to the bottom-left corner of
		# the face's AABB, like TrenchBroom. UV-only edits keep the shape identical, so the origin
		# stays put through offset/rotate drags — including the ones this canvas itself drives.
		# Shape Y runs downward (matching the canvas), so "bottom" is the max-Y edge.
		_origin_shape = Vector2.ZERO
		if not shape.is_empty():
			var lo := shape[0]
			var hi := shape[0]
			for p in shape:
				lo = lo.min(p)
				hi = hi.max(p)
			_origin_shape = Vector2(lo.x, hi.y)
	if surface is Material:
		# Re-render only when the material itself changes — UV drags re-feed the same material and
		# must reuse the existing snapshot, or every drag would kick off a fresh viewport render.
		if surface != _shown_material:
			_shown_material = surface
			_texture = _material_albedo(surface)   # instant stand-in until the render lands
			_render_material(surface)
	else:
		_shown_material = null
		_texture = surface as Texture2D
	_shape = shape
	_uv = uv
	queue_redraw()


func _material_albedo(mat: Resource) -> Texture2D:
	if mat is BaseMaterial3D:
		return (mat as BaseMaterial3D).albedo_texture
	return null


## Lazily build the offscreen 3D scene that renders a material: a unit quad wearing the material,
## square-on to an orthographic camera that frames it exactly (so one snapshot == one UV tile), lit
## by a key light plus flat ambient so normal/roughness show without the tiling reading as a gradient.
func _ensure_material_viewport() -> void:
	if _mat_viewport != null:
		return
	_mat_viewport = SubViewport.new()
	_mat_viewport.size = Vector2i(MAT_PREVIEW_SIZE, MAT_PREVIEW_SIZE)
	_mat_viewport.own_world_3d = true          # isolated world: only our quad/camera/light
	_mat_viewport.transparent_bg = false
	_mat_viewport.msaa_3d = Viewport.MSAA_DISABLED   # no silhouette AA, so the tile edges stay clean
	_mat_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_mat_viewport)

	var quad := MeshInstance3D.new()
	var qmesh := QuadMesh.new()
	qmesh.size = Vector2.ONE
	quad.mesh = qmesh
	_mat_viewport.add_child(quad)
	_mat_quad = quad

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 1.0                              # ortho height 1 frames the 1×1 quad edge to edge
	cam.position = Vector3(0.0, 0.0, 1.0)       # looks down -Z at the quad's front face
	cam.current = true
	_mat_viewport.add_child(cam)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35.0, -25.0, 0.0)
	_mat_viewport.add_child(key)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.7, 0.7)
	env.ambient_light_energy = 1.0
	env_node.environment = env
	_mat_viewport.add_child(env_node)


## Render `mat` on the quad and snapshot it into a tiling texture. Async: the viewport needs a frame
## to draw before its image is readable; guarded against the shown material changing mid-await.
func _render_material(mat: Material) -> void:
	_ensure_material_viewport()
	_mat_quad.material_override = mat
	_mat_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	if mat != _shown_material or not is_instance_valid(_mat_viewport):
		return
	var img := _mat_viewport.get_texture().get_image()
	if img != null and img.get_width() > 0:
		_texture = ImageTexture.create_from_image(img)
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_at(event.position, ZOOM_STEP)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_at(event.position, 1.0 / ZOOM_STEP)
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = event.pressed
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and _shape.size() >= 3:
				_drag_mode = _pick_drag_mode(event.position, event.ctrl_pressed)
				if _drag_mode == "rotate" and not _begin_rotate(event.position):
					_drag_mode = ""
				elif (_drag_mode == "scale_u" or _drag_mode == "scale_v") \
						and not _begin_scale(event.position):
					_drag_mode = ""
			else:
				_drag_mode = ""
				_update_hover(event.position)
				queue_redraw()   # a drag that hid the origin widget just ended — show it again now
	elif event is InputEventMouseMotion:
		if _panning:
			_pan += event.relative
			queue_redraw()
			return
		match _drag_mode:
			"offset":
				# Move the texture with the cursor -> change the offset. The linear part is
				# constant during an offset drag, so the last-drawn transform is safe to use.
				offset_dragged.emit(_uv_to_canvas.affine_inverse().basis_xform(-event.relative))
			"origin", "origin_u", "origin_v":
				_drag_origin(event.position)
			"rotate":
				# The guideline follows the cursor on screen; snap it onto a face edge, then convert
				# that screen rotation to a stored-angle delta through the mapping's orientation.
				var cur: float = (event.position - _rotate_oc).angle()
				var target := _snap_rotation(_rotate_u0 + (cur - _rotate_grab))
				rotate_dragged.emit(rad_to_deg(-_rotate_orient * (target - _rotate_u0)))
			"scale_u", "scale_v":
				# The grabbed grid line follows the cursor while the origin's UV stays pinned; the
				# scale factor is just how far the cursor is from the origin now vs. at the grab.
				var k: float = (event.position - _scale_oc).dot(_scale_dir) / _scale_d0
				scale_dragged.emit(Vector2(k, 1.0) if _scale_axis == "u" else Vector2(1.0, k))
			_:
				_update_hover(event.position)


## What a left-press at `pos` grabs, TrenchBroom-style. Checked in overlay order: the origin dot,
## the rotation ring, then the origin's axis lines (each sets one coordinate alone). Ctrl turns
## the whole canvas into the rotation handle. Anything else drags the texture (offset).
func _pick_drag_mode(pos: Vector2, ctrl: bool) -> String:
	if ctrl:
		return "rotate"
	var oc := _shape_to_canvas * _origin_shape
	if pos.distance_to(oc) <= ORIGIN_R + HANDLE_HIT:
		return "origin"
	if absf(pos.distance_to(oc) - RING_R) <= HANDLE_HIT:
		return "rotate"
	if absf((pos - oc).cross(_v_dir)) <= HANDLE_HIT:
		return "origin_u"   # the line ALONG V: dragging it moves the origin along U
	if absf((pos - oc).cross(_u_dir)) <= HANDLE_HIT:
		return "origin_v"
	var g := _grid_hit(pos)
	if not g.is_empty():
		return "scale_u" if g.axis == "u" else "scale_v"
	return "offset"


## Move the origin to (a constrained projection of) the cursor, snapping its guidelines onto face
## vertices. Stored in shape space so it survives the mapping edits it is about to pivot. The axis
## modes move along that axis only, which is what TrenchBroom's separate X/Y origin lines are for.
func _drag_origin(pos: Vector2) -> void:
	var oc := _shape_to_canvas * _origin_shape
	var target := pos
	if _drag_mode == "origin_u":
		target = oc + _u_dir * (pos - oc).dot(_u_dir)
	elif _drag_mode == "origin_v":
		target = oc + _v_dir * (pos - oc).dot(_v_dir)
	target = _snap_origin(target)
	_origin_shape = _shape_to_canvas.affine_inverse() * target
	queue_redraw()


## Snap the origin's guidelines to face features. Working in the U/V frame, the V guideline is the
## line of constant U-coordinate and the U guideline the line of constant V-coordinate; pulling
## either coordinate onto a candidate makes that guideline pass through it. Candidates are every
## face vertex's U/V coordinate plus the U/V midpoints of the face bounds — an imaginary edge down
## the middle each way. Free drags snap both (so a rectangle's four vertices snap the origin to the
## face); axis drags snap only the coordinate they move. Returns the adjusted canvas point.
func _snap_origin(p: Vector2) -> Vector2:
	var frame := Transform2D(_u_dir, _v_dir, Vector2.ZERO)
	if absf(frame.determinant()) < 0.000000000001:
		return p
	var inv := frame.affine_inverse()
	var cp := inv.basis_xform(p)
	var us := PackedFloat32Array()
	var vs := PackedFloat32Array()
	var lo := inv.basis_xform(_shape_to_canvas * _shape[0])
	var hi := lo
	for s in _shape:
		var cv := inv.basis_xform(_shape_to_canvas * s)
		us.append(cv.x)
		vs.append(cv.y)
		lo = lo.min(cv)
		hi = hi.max(cv)
	us.append((lo.x + hi.x) * 0.5)   # vertical imaginary edge down the middle
	vs.append((lo.y + hi.y) * 0.5)   # horizontal imaginary edge down the middle
	if _drag_mode != "origin_v":
		cp.x = _nearest(cp.x, us)   # the V guideline (constant U) — free and origin_u drags move it
	if _drag_mode != "origin_u":
		cp.y = _nearest(cp.y, vs)   # the U guideline (constant V) — free and origin_v drags move it
	return frame.basis_xform(cp)


## The candidate nearest `value` within ORIGIN_SNAP_PX, or `value` itself when none is close enough.
func _nearest(value: float, candidates: PackedFloat32Array) -> float:
	var best := ORIGIN_SNAP_PX
	var out := value
	for c in candidates:
		if absf(c - value) < best:
			best = absf(c - value)
			out = c
	return out


## Snap a guideline's screen angle onto a face edge. The origin crosshair has 90° symmetry (U and V
## are perpendicular) and an edge is a line (180° symmetry), so alignment is `angle == edge (mod
## 90°)`. Returns the nearest such angle within ROT_SNAP_RAD, else the input unchanged.
func _snap_rotation(a: float) -> float:
	var best := ROT_SNAP_RAD
	var snapped := a
	var n := _shape.size()
	for i in n:
		var e := (_shape_to_canvas * _shape[(i + 1) % n]) - (_shape_to_canvas * _shape[i])
		if e.length_squared() < 0.000000000001:
			continue
		var diff: float = a - e.angle()
		diff -= PI * 0.5 * roundf(diff / (PI * 0.5))   # fold to (-45°, 45°]
		if absf(diff) < best:
			best = absf(diff)
			snapped = a - diff
	return snapped


## Update which handle the idle cursor hovers (origin dot, rotation ring, or a grid scale line) and
## repaint on change. Grid hovers also record which line is hot, so _draw can paint it red.
func _update_hover(pos: Vector2) -> void:
	var h := ""
	var axis := ""
	var line := 0
	if _shape.size() >= 3:
		var m := _pick_drag_mode(pos, false)
		if m == "origin" or m == "rotate":
			h = m
		elif m == "scale_u" or m == "scale_v":
			var g := _grid_hit(pos)
			if not g.is_empty():
				h = m
				axis = g.axis
				line = g.line
	if h != _hover or axis != _scale_axis or line != _scale_line:
		_hover = h
		_scale_axis = axis
		_scale_line = line
		queue_redraw()


## The UV grid line under `pos`, as {axis: "u"/"v", line: int}, or {} when the cursor is on no line.
## A vertical line is constant-U (a scale_u handle); a horizontal line constant-V. The nearer of the
## two wins. Distances are measured in canvas pixels so the slack matches the visible line spacing.
func _grid_hit(pos: Vector2) -> Dictionary:
	if absf(_uv_to_canvas.determinant()) < 0.000000000001:
		return {}
	var uc := _uv_to_canvas.affine_inverse() * pos
	var su := _uv_to_canvas.basis_xform(Vector2.RIGHT).length()
	var sv := _uv_to_canvas.basis_xform(Vector2.DOWN).length()
	var iu := roundi(uc.x)
	var iv := roundi(uc.y)
	var du: float = absf(uc.x - iu) * su if su > 0.0 else INF
	var dv: float = absf(uc.y - iv) * sv if sv > 0.0 else INF
	if du <= HANDLE_HIT and (dv > HANDLE_HIT or du <= dv):
		return {"axis": "u", "line": iu}
	if dv <= HANDLE_HIT:
		return {"axis": "v", "line": iv}
	return {}


## Capture the scale frame at drag start, in canvas space: the pivot (origin), the axis direction,
## and the grab point's signed distance from the pivot along that axis. The grabbed line then tracks
## the cursor and the emitted factor is the live-distance / grab-distance ratio. False = degenerate
## (no line, or the grab sits on the pivot where the ratio is undefined).
func _begin_scale(pos: Vector2) -> bool:
	if absf(_uv_to_canvas.determinant()) < 0.000000000001:
		return false
	var g := _grid_hit(pos)
	if g.is_empty():
		return false
	var oc := _shape_to_canvas * _origin_shape
	var dir: Vector2 = _u_dir if g.axis == "u" else _v_dir
	var d0 := (pos - oc).dot(dir)
	if absf(d0) < HANDLE_HIT:
		return false   # grabbed a line through the origin: no distance to scale against
	_scale_axis = g.axis
	_scale_line = g.line
	_scale_oc = oc
	_scale_dir = dir
	_scale_d0 = d0
	_scale_pivot_uv = _uv_to_canvas.affine_inverse() * oc
	scale_started.emit(_scale_pivot_uv)
	return true


func _on_mouse_exited() -> void:
	if _hover != "" or _scale_axis != "":
		_hover = ""
		_scale_axis = ""
		queue_redraw()


## Capture the rotation frame ONCE at drag start, in canvas space: the pivot, the grab angle about
## it, and the U guideline's screen angle. The guideline then tracks the cursor 1:1 on screen while
## the emitted stored-angle delta is that screen rotation divided back through the mapping's
## orientation — so a mirrored mapping turns the correct way. Freezing these avoids the applied
## rotation (which changes the live mapping each event) feeding back into the measurement. The
## origin doesn't move during a rotate, so the canvas pivot stays valid. False = degenerate.
func _begin_rotate(pos: Vector2) -> bool:
	if absf(_uv_to_canvas.determinant()) < 0.000000000001:
		return false
	var oc := _shape_to_canvas * _origin_shape
	var grab := pos - oc
	if grab.length_squared() < 0.000000000001:
		return false   # grabbed exactly on the pivot: no defined angle to measure from
	_rotate_oc = oc
	_rotate_grab = grab.angle()
	_rotate_u0 = _u_dir.angle()
	_rotate_orient = signf(_uv_to_canvas.determinant())
	_rotate_pivot_uv = _uv_to_canvas.affine_inverse() * oc
	rotate_started.emit(_rotate_pivot_uv)
	return true


func _zoom_at(m: Vector2, factor: float) -> void:
	var new_zoom := clampf(_zoom * factor, MIN_ZOOM, MAX_ZOOM)
	factor = new_zoom / _zoom
	var origin := size * 0.5 + _pan
	_pan = m - (m - origin) * factor - size * 0.5
	_zoom = new_zoom
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR)
	if _shape.size() < 3 or _uv.size() != _shape.size() or size.x < 4.0 or size.y < 4.0:
		return   # no single face selected, or degenerate

	# Fit the FIXED face shape into the view (uniform scale, undistorted), plus zoom/pan.
	var lo := _shape[0]
	var hi := _shape[0]
	for p in _shape:
		lo = lo.min(p)
		hi = hi.max(p)
	var extent := (hi - lo).max(Vector2(0.001, 0.001))
	var c2d := (lo + hi) * 0.5
	var fit := minf(size.x / (extent.x * PAD), size.y / (extent.y * PAD)) * _zoom
	var origin := size * 0.5 + _pan
	var shape_to_canvas := Transform2D(Vector2(fit, 0.0), Vector2(0.0, fit), origin - c2d * fit)
	_shape_to_canvas = shape_to_canvas   # cached for the origin widget and hit-tests

	# uv -> shape (affine from three correspondences), then uv -> canvas.
	var uv_basis := Transform2D(_uv[1] - _uv[0], _uv[2] - _uv[0], _uv[0])
	if absf(uv_basis.determinant()) < 0.000000000001:
		return
	var shape_basis := Transform2D(_shape[1] - _shape[0], _shape[2] - _shape[0], _shape[0])
	var uv_to_canvas := shape_to_canvas * shape_basis * uv_basis.affine_inverse()
	_uv_to_canvas = uv_to_canvas   # cache for drag-delta conversion in _gui_input
	var have_map := absf(uv_to_canvas.determinant()) > 0.000000000001

	# Fixed face outline points (canvas space).
	var pts := PackedVector2Array()
	for s in _shape:
		pts.append(shape_to_canvas * s)

	if _texture != null:
		# Context: the tiled texture, DIMMED — everything outside the face reads as "outside".
		if have_map:
			var cover := _uv_cover(uv_to_canvas.affine_inverse())
			var i0 := floori(cover.position.x)
			var i1 := ceili(cover.end.x)
			var j0 := floori(cover.position.y)
			var j1 := ceili(cover.end.y)
			if (i1 - i0) * (j1 - j0) <= MAX_TILES:
				draw_set_transform_matrix(uv_to_canvas)
				for i in range(i0, i1):
					for j in range(j0, j1):
						draw_texture_rect(_texture, Rect2(Vector2(i, j), Vector2.ONE), false, CONTEXT_DIM)
				draw_set_transform_matrix(Transform2D.IDENTITY)
		# The face itself at full brightness. The brightness step at its border marks the face on
		# ANY texture colour — no single outline colour can (red on red, white on white).
		draw_colored_polygon(pts, Color.WHITE, _uv, _texture)

	# The UV grid: the material's tiling edges, in gray — where the texture repeats. Each line is
	# also a scale handle: the hovered or grabbed one draws red and drags to scale about the origin.
	# Endpoints are transformed by hand so the line width stays 1 px instead of scaling with the map.
	if have_map:
		# Which grid line is hot (red): the grabbed one mid-drag, else the hovered one.
		var hot_axis := ""
		var hot_line := 0
		if _drag_mode == "scale_u" or _drag_mode == "scale_v" \
				or _hover == "scale_u" or _hover == "scale_v":
			hot_axis = _scale_axis
			hot_line = _scale_line
		var cover := _uv_cover(uv_to_canvas.affine_inverse())
		var i0 := floori(cover.position.x)
		var i1 := ceili(cover.end.x)
		var j0 := floori(cover.position.y)
		var j1 := ceili(cover.end.y)
		if (i1 - i0) + (j1 - j0) <= MAX_TILES:
			for i in range(i0, i1 + 1):
				var hot_u: bool = hot_axis == "u" and i == hot_line
				draw_line(uv_to_canvas * Vector2(i, cover.position.y),
					uv_to_canvas * Vector2(i, cover.end.y),
					HOVER_COLOR if hot_u else GRID_COLOR, 2.0 if hot_u else 1.0)
			for j in range(j0, j1 + 1):
				var hot_v: bool = hot_axis == "v" and j == hot_line
				draw_line(uv_to_canvas * Vector2(cover.position.x, j),
					uv_to_canvas * Vector2(cover.end.x, j),
					HOVER_COLOR if hot_v else GRID_COLOR, 2.0 if hot_v else 1.0)

	# Thin accent outline on top of the brightness step.
	var closed := pts.duplicate()
	closed.append(pts[0])
	draw_polyline(closed, OUTLINE, 1.5)

	# Axis marker at the middle of the outline: arrows along the texture's U and V directions as
	# they lie on this face — the at-a-glance read-out of the mapping's rotation (and mirroring:
	# a flipped axis points the other way). Fixed pixel size, like a HUD widget, so zoom doesn't
	# swallow it. V points along +V in UV space, i.e. texture-down.
	if have_map:
		_u_dir = uv_to_canvas.basis_xform(Vector2.RIGHT).normalized()
		_v_dir = uv_to_canvas.basis_xform(Vector2.DOWN).normalized()
		var centre := shape_to_canvas * c2d
		_draw_axis_arrow(centre, _u_dir, AXIS_U_COLOR)
		_draw_axis_arrow(centre, _v_dir, AXIS_V_COLOR)
		draw_circle(centre, 3.0, Color.WHITE)

		# TrenchBroom's origin widget: the yellow dot IS the origin (drag it — or one of the red
		# axis lines through it, one coordinate at a time — to move it); the yellow circle
		# rotates the material about it. The axis lines follow the material's U/V directions. The
		# whole widget hides during a scale drag — the grid lines are the handles then.
		if _drag_mode != "scale_u" and _drag_mode != "scale_v":
			var oc := shape_to_canvas * _origin_shape
			var far := size.x + size.y + 4000.0
			draw_line(oc - _u_dir * far, oc + _u_dir * far, ORIGIN_AXIS_COLOR, 1.0)
			draw_line(oc - _v_dir * far, oc + _v_dir * far, ORIGIN_AXIS_COLOR, 1.0)
			# The ring hides while the origin itself is being placed — TrenchBroom shows one handle
			# at a time. Hovered or active handles turn red, matching the viewport's selection colour.
			var dragging_origin := _drag_mode == "origin" or _drag_mode == "origin_u" \
				or _drag_mode == "origin_v"
			if not dragging_origin:
				var ring_hot := _hover == "rotate" or _drag_mode == "rotate"
				draw_arc(oc, RING_R, 0.0, TAU, 64,
					HOVER_COLOR if ring_hot else ORIGIN_COLOR, 2.0, true)
			var origin_hot := _hover == "origin" or dragging_origin
			draw_circle(oc, ORIGIN_R, HOVER_COLOR if origin_hot else ORIGIN_COLOR)


## UV-space rect covering the whole canvas: transform the four corners and take the bounds.
func _uv_cover(inv: Transform2D) -> Rect2:
	var cover_lo: Vector2 = inv * Vector2.ZERO
	var cover_hi := cover_lo
	for corner in [Vector2(size.x, 0.0), Vector2(0.0, size.y), size]:
		var uc: Vector2 = inv * corner
		cover_lo = cover_lo.min(uc)
		cover_hi = cover_hi.max(uc)
	return Rect2(cover_lo, cover_hi - cover_lo)


func _draw_axis_arrow(from: Vector2, dir: Vector2, color: Color) -> void:
	var tip := from + dir * AXIS_LEN
	draw_line(from, tip, color, 2.0)
	var side := dir.orthogonal()
	draw_colored_polygon(PackedVector2Array([
		tip + dir * 7.0, tip - side * 4.0, tip + side * 4.0]), color)
