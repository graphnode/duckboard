@tool
extends RefCounted
## Convex CSG for brushes — Convex Merge, Subtract, Hollow, Intersect (TrenchBroom's Edit → CSG).
##
## Pure geometry, world space, no scene knowledge: the plugin extracts each brush's faces with
## Brush.world_faces(), calls one of the ops here, and rebuilds nodes from the returned blueprints
## with Brush.set_world_faces(). Because a Brush IS an intersection of half-spaces and its UV axes
## already live in world space, every op reduces to shuffling planes and copying face data verbatim.
##
## Vocabulary:
##   FACE      a Dictionary {plane, u, v, offset, tex, material}, plane world-space, outward normal.
##   SOLID     Array[FACE] — one convex brush (exactly Brush.world_faces()).
##   BLUEPRINT Array[FACE] — one convex result brush, ready for Brush.set_world_faces().
## Every op returns Array[BLUEPRINT]: possibly empty (nothing survives — the caller deletes the
## inputs and makes nothing), one (Merge/Intersect), or several (Subtract/Hollow fragments).
##
## Degenerate results are dropped: a fragment that bounds no solid (< 4 real faces) is discarded, so
## a brush wholly consumed by a Subtract simply yields []. Intersect of non-overlapping brushes and
## Hollow with a wall thicker than the brush also yield [] / a no-op — see each function.

## Half-extent of the working quad a plane starts as before the others clip it. Matches Brush.BIG.
const BIG := 512.0
## "On the plane" tolerance for clipping / hull side tests. Matches Brush.EPS.
const EPS := 0.0001
## Two points are the same corner below this SQUARED distance — float noise from plane intersections,
## well under any real (grid-scale) feature.
const WELD_SQ := 1e-10
## Corner-cloud cleanup quantum. `_verts` re-derives corners by clipping BIG-wide quads, so far-from-
## origin float32 error leaves a corner reading 3.000022 instead of 3.0; left in, the O(n^4) hull reads
## that as a real tilt and fans one flat quad into a dozen near-coplanar faces. Snapping to this fixed
## noise-scale quantum before hulling sheds the error. It is deliberately NOT the grid size: hull
## corners can legitimately sit off the current grid (a brush built finer, a fractional clip corner),
## and grid-snapping would move those real vertices — the merge must not depend on the grid dropdown.
## 1e-4 m is ~40x below the finest grid feature (0.125 TB = 3.9e-3 m) yet above realistic float32 noise.
const CLEAN := 1e-4
## Two planes are the same face at this normal dot AND distance. Matches Brush's tight thresholds, so
## coplanar-but-float-different planes merge without collapsing genuinely distinct folds.
const PLANE_MERGE_DOT := 0.9999
const PLANE_MERGE_DIST := 0.001
## A result face inherits from a source face this closely aligned. Looser than the merge thresholds:
## a hull/wall face need only be clearly the "same direction" as the source it takes its look from.
const COPLANAR_DOT := 0.999
const COPLANAR_DIST := 0.01

## Ceiling on the pooled cloud a collision merge may hull, mirroring Brush.MAX_HULL_POINTS and there
## for the same reason: _hull is O(n^4). It bounds only the TRANSIENT union of two candidates, since
## a successful merge re-derives its corners from the hull planes — so it caps how intricate a single
## pair may be, never how many pieces a group may collapse to.
const MERGE_MAX_POINTS := 64

## How much bigger than the true union a merged hull may measure and still count as exact.
##
## RELATIVE, because the quantity is a volume and volumes scale as the cube of the level's units — a
## fixed cubic-metre slack would be meaningless on a doorframe and reckless on a room. The absolute
## floor covers solids so small the relative term underflows into the clipping noise.
##
## Deliberately tight. Every bit of slack here is space the collision hull is allowed to INVENT: too
## loose and an L-shaped pair fuses, filling the inside corner with solid nobody built, which reads
## as an invisible wall. 1e-4 is far below the wedge any real misalignment produces (two 1 m cubes
## offset by a single centimetre already disagree by 5e-3 of their union) and far above the ~1e-5 m
## corner error BIG-quad clipping leaves.
const MERGE_VOLUME_EPS := 1e-4
const MERGE_VOLUME_FLOOR := 1e-9


# --- Operations -----------------------------------------------------------

## The convex hull of every selected brush merged into one — TrenchBroom's Convex Merge. Each hull
## face takes its look from the input face it lies on (or, for a bridging face that's genuinely new,
## the nearest-facing input face). Returns one blueprint, or [] if the inputs are degenerate.
static func convex_merge(solids: Array) -> Array:
	var pts := PackedVector3Array()
	var sources := []
	for s in solids:
		for f in s:
			sources.append(f)
		for p in _verts(s):
			_pool_corner(pts, p)
	return _hull_blueprint(pts, sources)


## Bridge two selected faces into one convex brush — the convex hull of both faces' corners, so the
## faces become opposite walls of a new solid and the gap between them is filled. Each result face
## takes its look from whichever source face it lies on or most nearly faces (see _inherit). Returns
## one blueprint, or [] when the two faces are coplanar / collinear and so bound no volume — the
## degenerate case the caller reports and skips. `face_a`/`face_b` are world-space FACE dicts
## (Brush.world_face()), whose `points` are the face polygon in world space.
static func bridge_faces(face_a: Dictionary, face_b: Dictionary) -> Array:
	if face_a.is_empty() or face_b.is_empty():
		return []
	var sources := [face_a, face_b]
	var pts := PackedVector3Array()
	for f in sources:
		for p in f["points"]:
			_pool_corner(pts, p)
	return _hull_blueprint(pts, sources)


## Add one corner to the pooled cloud, snapped to the fixed CLEAN quantum (NOT the grid size — see
## CLEAN) and welded against corners already pooled. The snap sheds the float noise far-from-origin
## quad clipping leaves on derived corners, so the O(n^4) hull stops reading that noise as a genuine
## tilt and fanning one flat quad into a dozen near-coplanar faces; real (off-grid) corners stay put.
static func _pool_corner(pts: PackedVector3Array, p: Vector3) -> void:
	var q := Vector3(snappedf(p.x, CLEAN), snappedf(p.y, CLEAN), snappedf(p.z, CLEAN))
	for e in pts:
		if e.distance_squared_to(q) < WELD_SQ:
			return
	pts.append(q)


## Convex hull of a pooled corner cloud as a blueprint: one FACE per hull plane, each inheriting its
## look from `sources`. Returns [] (not [[]]) when the cloud bounds no solid — fewer than four corners,
## no sources, or a flat/collinear hull of fewer than four planes.
static func _hull_blueprint(pts: PackedVector3Array, sources: Array) -> Array:
	if pts.size() < 4 or sources.is_empty():
		return []
	var hull := _hull(pts)
	if hull.size() < 4:
		return []
	var faces := []
	for hp in hull:
		faces.append(_inherit(hp, sources))
	return [faces]


## The common volume of every selected brush — TrenchBroom's Intersect. The intersection of convex
## solids is just the intersection of all their half-spaces, so this unions every plane and keeps the
## ones that still bound something. Each kept face is an input face and carries its own look. Returns
## one blueprint, or [] when the brushes don't all overlap (the caller should then leave them alone
## rather than delete them into nothing).
static func intersect(solids: Array) -> Array:
	var faces := []
	for s in solids:
		faces.append_array(s)
	faces = _prune(_dedupe_planes(faces))
	if faces.size() < 4:
		return []
	return [faces]


## Carve every subtrahend out of the minuend — TrenchBroom's Subtract, for the case of one brush
## being cut. `minuend` is a single solid; `subtrahends` are the solids removed from it. The result
## is generally non-convex, so it comes back as several convex fragments (or [] if the minuend is
## wholly consumed). Fragments that came from the minuend keep its look; the freshly exposed cut
## faces wear the subtrahend's look (the surface of the hole matches the brush that made it).
static func subtract(minuend: Array, subtrahends: Array) -> Array:
	var pieces := [minuend]
	for b in subtrahends:
		var next := []
		for p in pieces:
			if overlaps(p, b):
				next.append_array(_subtract_one(p, b))
			else:
				next.append(p)   # no overlap: carving would only shatter it for nothing
		pieces = next
	return pieces


## Turn a solid into a shell of walls one grid cell (or any `thickness`) thick — TrenchBroom's
## Hollow. The inner void is the brush with every face pushed inward by `thickness`; the walls are
## the brush minus that void, so each wall inherits the original face's look inside and out. Returns
## the wall fragments, or the brush unchanged when the walls would meet in the middle (thickness too
## large to leave a void) — never an empty solid.
static func hollow(solid: Array, thickness: float) -> Array:
	if thickness <= 0.0:
		return [solid]
	var inner := []
	for f in solid:
		var p: Plane = f["plane"]
		# Inside is n·x <= d, so lowering d slides the plane inward along its own normal.
		inner.append(_face(Plane(p.normal, p.d - thickness), f))
	inner = _prune(inner)
	if inner.size() < 4:
		return [solid]   # the walls swallow the whole brush: leave it solid
	return _subtract_one(solid, inner)


## Whether two solids share actual volume (not merely touch). True exactly when the intersection of
## their half-spaces still bounds a solid. Used to skip carving a brush a subtrahend doesn't reach.
static func overlaps(a: Array, b: Array) -> bool:
	var faces := a.duplicate()
	faces.append_array(b)
	return _prune(_dedupe_planes(faces)).size() >= 4


# --- Collision decomposition ----------------------------------------------

## One point cloud per convex piece covering EXACTLY the volume `solids` covers, merged wherever two
## pieces happen to fuse into a single convex one. A wall built from five cuboids comes back as one
## box; an L-shaped pair comes back as two.
##
## [b]This coarsens the decomposition, it never changes the shape.[/b] Two convex solids may be
## replaced by their convex hull only if that hull encloses nothing neither of them already enclosed,
## and that is decided by VOLUME rather than by any guess about how the pieces are arranged:
## [code]vol(hull(A ∪ B)) <= vol(A) + vol(B) - vol(A ∩ B)[/code]. Equality means the hull is exactly
## the union and the merge is free; anything more is space the hull would invent, and the pair is
## left alone. No adjacency heuristic, no axis assumption, no tolerance on the geometry itself.
##
## [code]A ∩ B[/code] costs nothing to build: an intersection of half-spaces IS the concatenation of
## their planes, which is the whole reason this test is affordable on the plane-based model.
##
## Greedy and repeated to a fixed point, so a row of cuboids fuses two at a time until one is left.
## Each merge re-derives its corners from the hull PLANES rather than keeping the pooled cloud, which
## is what stops the point count growing: two 8-corner boxes fuse into a box with 8 corners, not 16.
static func merge_hulls(solids: Array) -> Array:
	var pieces := []
	for s in solids:
		var piece = _piece(_planes_of(s))
		if piece != null:
			pieces.append(piece)

	var fused_any := true
	while fused_any:
		fused_any = false
		var i := 0
		while i < pieces.size():
			var j := i + 1
			while j < pieces.size():
				var fused = _fuse(pieces[i], pieces[j])
				if fused == null:
					j += 1
					continue
				pieces[i] = fused
				pieces.remove_at(j)
				fused_any = true
			i += 1

	var out := []
	for p in pieces:
		out.append(p["points"])
	return out


## The two pieces as one, or null when the hull would enclose space neither of them did.
static func _fuse(a: Dictionary, b: Dictionary):
	# Pieces that do not even touch can never fuse exactly, and this is the cheap way to know it —
	# the volume test below builds two hulls and would otherwise run for every pair in the group.
	if not a["aabb"].grow(EPS).intersects(b["aabb"].grow(EPS)):
		return null
	var cloud := PackedVector3Array(a["points"])
	cloud.append_array(b["points"])
	# The O(n^4) hull is the reason for a ceiling. It applies to the TRANSIENT pooled cloud only:
	# a successful merge collapses back to its own corner count, so a long wall never accumulates.
	if cloud.size() > MERGE_MAX_POINTS:
		return null
	var hull := _hull(cloud)
	if hull.size() < 4:
		return null
	# A ∩ B is the concatenation of their half-spaces — but DEDUPED first, or a plane the two share
	# is counted as two coincident faces and the intersection measures double. Two identical solids
	# reported an overlap of 2x their volume, which drove the union NEGATIVE and refused every merge
	# it should have waved through.
	var overlap := volume(_planes_of(_dedupe_planes(_as_faces(a["planes"] + b["planes"]))))
	var union_volume: float = a["volume"] + b["volume"] - overlap
	if volume(hull) > union_volume + MERGE_VOLUME_EPS * maxf(union_volume, 0.0) + MERGE_VOLUME_FLOOR:
		return null
	return _piece(hull)


## A merge candidate: its planes, its corners, its volume and its bounds — or null when the planes
## bound no solid.
static func _piece(planes: Array):
	var faces := _prune(_dedupe_planes(_as_faces(planes)))
	if faces.size() < 4:
		return null
	var kept := _planes_of(faces)
	var points := _verts(faces)
	if points.size() < 4:
		return null
	var bounds := AABB(points[0], Vector3.ZERO)
	for p in points:
		bounds = bounds.expand(p)
	return {"planes": kept, "points": points, "volume": volume(kept), "aabb": bounds}


## Volume of the convex solid bounded by `planes`, or 0 when they bound nothing.
##
## The divergence theorem over the closed surface: [code]V = 1/3 Σ (p·n) A[/code] over the faces. With
## outward UNIT normals, [code]plane.d[/code] IS [code]p·n[/code] for every point on that face — so a
## face contributes [code]d * area / 3[/code] and no representative point has to be picked.
static func volume(planes: Array) -> float:
	var total := 0.0
	for i in planes.size():
		var poly := _polygon(planes[i], planes, i)
		if poly.size() < 3:
			continue
		total += planes[i].d * _area(poly, planes[i].normal)
	return total / 3.0


## Bare FACEs carrying nothing but their planes — enough for every geometric question in this
## section, none of which cares what a face looks like.
static func _as_faces(planes: Array) -> Array:
	var out := []
	for p in planes:
		out.append({"plane": p})
	return out


## Area of a planar polygon, as its vector area projected back onto its own normal.
static func _area(poly: PackedVector3Array, normal: Vector3) -> float:
	var vector_area := Vector3.ZERO
	var count := poly.size()
	for i in count:
		vector_area += poly[i].cross(poly[(i + 1) % count])
	return absf(vector_area.dot(normal)) * 0.5


# --- Subtract core --------------------------------------------------------

## a \ b as convex fragments. Classic Quake/TrenchBroom decomposition: for each face i of b, the
## fragment is a, clipped OUTSIDE b's plane i, and INSIDE b's planes 0..i-1. The fragments partition
## a\b with no overlaps and no gaps. Assumes a and b overlap (caller checks).
static func _subtract_one(a: Array, b: Array) -> Array:
	var out := []
	for i in b.size():
		var frag := a.duplicate()                       # a's faces, keeping a's look
		frag.append(_face(_flip(b[i]["plane"]), b[i]))  # the cut face: outside b's plane i, wearing b
		for j in range(i):
			frag.append(_face(b[j]["plane"], b[j]))     # inside b's earlier planes (interior seams)
		frag = _prune(_dedupe_planes(frag))
		if frag.size() >= 4:
			out.append(frag)
	return out


# --- Face plumbing --------------------------------------------------------

## A result face on `plane` wearing `src`'s look (UV axes/offset and surface copied verbatim — they
## are world-space, so no reprojection is needed). `src` null gives a bare default face.
static func _face(plane: Plane, src) -> Dictionary:
	if src == null:
		return {"plane": plane, "u": Vector3.RIGHT, "v": Vector3.DOWN,
			"offset": Vector2.ZERO, "tex": null, "material": null}
	return {"plane": plane, "u": src["u"], "v": src["v"], "offset": src["offset"],
		"tex": src["tex"], "material": src["material"]}


## Build a result face on `plane` inheriting from the best of `sources`: a genuinely coplanar source
## if one exists (the face lies ON it), else the nearest-facing one (a bridging face takes the look of
## whatever it most resembles, like the clip tool's donor face).
static func _inherit(plane: Plane, sources: Array) -> Dictionary:
	var best := -1
	var best_dot := -INF
	var coplanar := -1
	for i in sources.size():
		var sp: Plane = sources[i]["plane"]
		var dot := sp.normal.dot(plane.normal)
		if dot > best_dot:
			best_dot = dot
			best = i
		if dot > COPLANAR_DOT and absf(sp.d - plane.d) < COPLANAR_DIST:
			coplanar = i
	var src = sources[coplanar] if coplanar >= 0 else (sources[best] if best >= 0 else null)
	return _face(plane, src)


static func _flip(p: Plane) -> Plane:
	return Plane(-p.normal, -p.d)


static func _planes_of(faces: Array) -> Array:
	var out := []
	for f in faces:
		out.append(f["plane"])
	return out


## Drop faces whose plane duplicates an earlier one, so a razor-thin double face never survives (two
## coincident planes each leave the other's polygon intact and both would render). Keeps the first,
## which for a subtract fragment means an original minuend face outranks a coincident cut face.
static func _dedupe_planes(faces: Array) -> Array:
	var kept := []
	for f in faces:
		var p: Plane = f["plane"]
		var dup := false
		for k in kept:
			var kp: Plane = k["plane"]
			if kp.normal.dot(p.normal) > PLANE_MERGE_DOT and absf(kp.d - p.d) < PLANE_MERGE_DIST:
				dup = true
				break
		if not dup:
			kept.append(f)
	return kept


## Keep only faces that still bound something — the plane's polygon, clipped by all the others, has
## real area. Returns the surviving faces (fewer than 4 means no solid: the caller drops it). A
## single pass, like Brush.clip_by: superfluous planes fall away in one go.
static func _prune(faces: Array) -> Array:
	var planes := _planes_of(faces)
	var kept := []
	for i in faces.size():
		if _polygon(planes[i], planes, i).size() >= 3:
			kept.append(faces[i])
	return kept


# --- Geometry primitives (mirror Brush's, in world space) -----------------

## The polygon `plane` cuts out of the solid bounded by `planes`, or empty if it bounds nothing.
## `skip` is the plane's own index (a plane can't clip itself); pass -1 for a plane from outside.
static func _polygon(plane: Plane, planes: Array, skip: int) -> PackedVector3Array:
	var u := _perp(plane.normal)
	var v := plane.normal.cross(u).normalized()
	var o := plane.normal * plane.d
	var poly := PackedVector3Array([
		o + (u + v) * BIG, o + (v - u) * BIG, o - (u + v) * BIG, o + (u - v) * BIG])
	for i in planes.size():
		if i == skip:
			continue
		poly = _clip(poly, planes[i])
		if poly.size() < 3:
			return PackedVector3Array()
	return _dedupe(poly)


## Sutherland-Hodgman: keep the part of `poly` inside the half-space (distance <= 0).
static func _clip(poly: PackedVector3Array, plane: Plane) -> PackedVector3Array:
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


## Drop consecutive duplicate points, including the wrap-around pair.
static func _dedupe(poly: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for point in poly:
		if out.size() > 0 and out[out.size() - 1].distance_squared_to(point) < WELD_SQ:
			continue
		out.append(point)
	while out.size() > 1 and out[0].distance_squared_to(out[out.size() - 1]) < WELD_SQ:
		out.resize(out.size() - 1)
	return out


static func _perp(n: Vector3) -> Vector3:
	var helper := Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT
	return n.cross(helper).normalized()


## Every distinct corner of a solid, in world space — gathered from its face polygons.
static func _verts(faces: Array) -> PackedVector3Array:
	var planes := _planes_of(faces)
	var out := PackedVector3Array()
	for i in faces.size():
		for p in _polygon(planes[i], planes, i):
			var seen := false
			for e in out:
				if e.distance_squared_to(p) < WELD_SQ:
					seen = true
					break
			if not seen:
				out.append(p)
	return out


## Brute-force convex hull as outward planes — every point triple is a face if all other points lie
## on one side. Mirrors Brush._hull_planes; O(n^4) but n is a handful of corners.
static func _hull(points: PackedVector3Array) -> Array[Plane]:
	var out: Array[Plane] = []
	var count := points.size()
	for i in count:
		for j in range(i + 1, count):
			for k in range(j + 1, count):
				var candidate := Plane(points[i], points[j], points[k])
				if candidate.normal.length_squared() < 0.5:
					continue                      # collinear triple
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
					continue                      # points both sides: not a hull face
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
