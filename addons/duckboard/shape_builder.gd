@tool
extends RefCounted
## Pure geometry for the shape tool: turns a drawn bounding box + shape parameters into one or more
## sets of world-space corner points, each of which becomes a convex Brush (via set_from_points).
##
## Non-convex shapes are decomposed into convex pieces here — stairs into one box per step, a hollow
## cylinder into one wall segment per side — because a Brush is a single convex solid. Everything is
## axis-aligned in world space (the draw box is), so no rotation is involved; a shape's "axis" or
## "direction" only picks which world axis it grows along.
##
## Mirrors TrenchBroom's shape tool. Cylinders/cones fill the box as an ELLIPTIC cross-section (the
## box needn't be square), matching TrenchBroom.

## Entry point. Returns Array[PackedVector3Array] — one convex point set per brush to create.
static func build(shape: String, center: Vector3, size: Vector3, params: Dictionary, snap: float) -> Array:
	match shape:
		"stairs":
			return _stairs(center, size, params)
		"cylinder":
			return _cylinder(center, size, params, snap)
		"cone":
			return _cone(center, size, params, snap)
		_:
			return [_box_points(center, size)]


## The 8 corners of an axis-aligned box.
static func _box_points(center: Vector3, size: Vector3) -> PackedVector3Array:
	var h := size * 0.5
	var pts := PackedVector3Array()
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				pts.append(center + Vector3(sx * h.x, sy * h.y, sz * h.z))
	return pts


static func _set_axis(v: Vector3, axis: int, value: float) -> Vector3:
	if axis == 0:
		v.x = value
	elif axis == 1:
		v.y = value
	else:
		v.z = value
	return v


## A box given as [lo, hi] per axis, built axis by axis so the run/width/height mapping stays
## readable at the call site.
static func _axis_box(run_axis: int, run: Array, width_axis: int, width: Array, y: Array) -> PackedVector3Array:
	var lo := Vector3.ZERO
	var hi := Vector3.ZERO
	lo = _set_axis(lo, run_axis, run[0]);   hi = _set_axis(hi, run_axis, run[1])
	lo = _set_axis(lo, width_axis, width[0]); hi = _set_axis(hi, width_axis, width[1])
	lo.y = y[0]; hi.y = y[1]
	return _box_points((lo + hi) * 0.5, hi - lo)


## A solid staircase: one box per step, each rising from the floor to its own tread height, so the
## steps stack into a solid profile. `step_height_m` sets the riser; the count fills the box height
## exactly (rise = H / count), and the tread depth fills the run axis (run = depth / count).
static func _stairs(center: Vector3, size: Vector3, params: Dictionary) -> Array:
	var step_h: float = params.get("step_height_m", 0.5)
	var dir: String = params.get("direction", "+x")
	var low := center - size * 0.5
	var high := center + size * 0.5
	var run_axis := 0 if dir == "+x" or dir == "-x" else 2
	var width_axis := 2 if run_axis == 0 else 0
	var height := size.y
	var run_len: float = size[run_axis]
	if step_h <= 0.0:
		step_h = height
	var count := maxi(1, int(round(height / step_h)))
	var rise := height / count
	var run := run_len / count
	var ascending := dir == "+x" or dir == "+z"
	var out: Array = []
	for i in count:
		var top_y := low.y + (i + 1) * rise
		var r0: float
		var r1: float
		if ascending:
			r0 = low[run_axis] + i * run
			r1 = low[run_axis] + (i + 1) * run
		else:
			r1 = high[run_axis] - i * run
			r0 = high[run_axis] - (i + 1) * run
		out.append(_axis_box(run_axis, [r0, r1], width_axis,
			[low[width_axis], high[width_axis]], [low.y, top_y]))
	return out


## The (u, v) ring of an N-gon inscribed in the box's elliptic cross-section. Vertex-aligned puts a
## vertex on the +u box side; edge-aligned offsets by half a step so an edge midpoint sits there;
## scalable is vertex-aligned with every point snapped to the grid (TrenchBroom's grid-safe circle).
static func _ring(center: Vector3, size: Vector3, axis: int, sides: int, mode: String, snap: float) -> Array:
	var u_axis := (axis + 1) % 3
	var v_axis := (axis + 2) % 3
	var ru: float = size[u_axis] * 0.5
	var rv: float = size[v_axis] * 0.5
	var cu: float = center[u_axis]
	var cv: float = center[v_axis]
	var offset := 0.0 if mode == "vertex" or mode == "scalable" else PI / sides
	var ring: Array = []
	for k in sides:
		var th := offset + k * TAU / sides
		var pu := cu + ru * cos(th)
		var pv := cv + rv * sin(th)
		if mode == "scalable":
			pu = snappedf(pu, snap)
			pv = snappedf(pv, snap)
		ring.append(Vector2(pu, pv))
	return ring


## Compose a world point from a ring (u, v) and a position along the shape axis.
static func _point(axis: int, uv: Vector2, along: float) -> Vector3:
	var u_axis := (axis + 1) % 3
	var v_axis := (axis + 2) % 3
	var p := Vector3.ZERO
	p = _set_axis(p, axis, along)
	p = _set_axis(p, u_axis, uv.x)
	p = _set_axis(p, v_axis, uv.y)
	return p


static func _cylinder(center: Vector3, size: Vector3, params: Dictionary, snap: float) -> Array:
	var axis: int = params.get("axis", 1)
	var sides := maxi(3, int(params.get("sides", 16)))
	var mode: String = params.get("circle_mode", "edge")
	var a0: float = (center - size * 0.5)[axis]
	var a1: float = (center + size * 0.5)[axis]
	var outer := _ring(center, size, axis, sides, mode, snap)

	if not params.get("hollow", false):
		# Solid prism: convex hull of the top and bottom rings.
		var pts := PackedVector3Array()
		for uv in outer:
			pts.append(_point(axis, uv, a0))
			pts.append(_point(axis, uv, a1))
		return [pts]

	# Hollow: an inner ring at the SAME angles, so each side becomes one convex wall segment.
	var thick: float = params.get("thickness_m", 0.25)
	var u_axis := (axis + 1) % 3
	var v_axis := (axis + 2) % 3
	var inner: Array = []
	for k in sides:
		var o: Vector2 = outer[k]
		# Pull each point toward the centre by `thick` along u and v — an approximate wall offset,
		# clamped so the inner ring can't cross the centre and invert the wall.
		var du: float = o.x - center[u_axis]
		var dv: float = o.y - center[v_axis]
		var iu := center[u_axis] + signf(du) * maxf(absf(du) - thick, snap * 0.5)
		var iv := center[v_axis] + signf(dv) * maxf(absf(dv) - thick, snap * 0.5)
		inner.append(Vector2(iu, iv))

	var out: Array = []
	for k in sides:
		var k2 := (k + 1) % sides
		var seg := PackedVector3Array()
		for uv in [outer[k], outer[k2], inner[k2], inner[k]]:
			seg.append(_point(axis, uv, a0))
			seg.append(_point(axis, uv, a1))
		out.append(seg)
	return out


static func _cone(center: Vector3, size: Vector3, params: Dictionary, snap: float) -> Array:
	var axis: int = params.get("axis", 1)
	var sides := maxi(3, int(params.get("sides", 16)))
	var mode: String = params.get("circle_mode", "edge")
	var a0: float = (center - size * 0.5)[axis]
	var a1: float = (center + size * 0.5)[axis]
	var base := _ring(center, size, axis, sides, mode, snap)
	var pts := PackedVector3Array()
	for uv in base:
		pts.append(_point(axis, uv, a0))
	var u_axis := (axis + 1) % 3
	var v_axis := (axis + 2) % 3
	pts.append(_point(axis, Vector2(center[u_axis], center[v_axis]), a1))   # apex
	return [pts]
