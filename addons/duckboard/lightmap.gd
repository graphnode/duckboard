@tool
extends RefCounted
## UV2 for lightmapping — packed, not unwrapped.
##
## [b]A brush needs no unwrapping.[/b] Every face is already a planar convex polygon, so the hard half
## of the problem — cutting arbitrary art into charts that lie flat — is answered by the geometry
## before anyone asks. What is left is packing those charts into one atlas without overlap, which is
## a rectangle-fitting problem and nothing more.
##
## That is why [method ArrayMesh.lightmap_unwrap] is the wrong tool here despite existing. It runs
## xatlas to SOLVE the flattening, which costs a visible pause per mesh, and it is editor-only — the
## module is not in an exported build. A Duckboard mesh is derived: it is rebuilt from `planes` /
## `members` every time a scene loads, in the editor and in the running game alike. Anything that
## cannot be reproduced on load cannot be part of that mesh, so an unwrap that has to be baked and
## stored would be a bake step in a plugin whose whole argument is that there is not one.
##
## Packing here is deterministic and cheap, so the same brush produces the same atlas every load and
## nothing has to be saved.
##
## [b]Charts are laid out in texels, then normalised.[/b] `texel_size` is the world size of one
## lightmap texel, so a face keeps a consistent lightmap density with every other face in the level
## regardless of how big it is — which is what stops a small face being blurry next to a large one.
## The atlas grows to whatever square holds the shelves, and the whole thing is scaled into 0..1 at
## the end because that is the range Godot samples UV2 in.

## Blank texels kept between charts and around the atlas edge.
##
## Lightmaps are sampled with bilinear filtering, so a texel on a chart's edge blends with whatever
## sits next to it. Without a gutter that is the neighbouring face's lighting, and the seam shows up
## as a bright or dark fringe along every edge in the level. Two texels is the usual minimum: one for
## the filter kernel either side.
const PADDING := 2

## Smallest a chart may be on either axis, in texels. A face thinner than one texel would collapse to
## a zero-width rect that the packer would happily stack many of at the same spot, and every one of
## them would then sample the same lighting.
const MIN_CHART := 1


## UV2 for each polygon in `polygons`, in the same order, or an empty array when there is nothing to
## pack. Each entry is one UV2 per vertex of that polygon, matching its winding.
##
## `polygons` are in the solid's LOCAL space and `normals` gives the plane normal of each, so a chart
## is measured in the plane it actually lies in rather than in the axis-aligned box around it — a
## 45-degree wall packs as its true size, not as the larger square its bounds describe.
static func pack(polygons: Array, normals: Array, texel_size: float) -> Array:
	if polygons.is_empty() or texel_size <= 0.0:
		return []

	# 1. Flatten every polygon into its own plane and measure it.
	var charts: Array = []
	for i in polygons.size():
		var poly: PackedVector3Array = polygons[i]
		if poly.size() < 3:
			charts.append(null)
			continue
		var axes := _plane_axes(normals[i])
		var flat := PackedVector2Array()
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for p in poly:
			var q := Vector2(p.dot(axes[0]), p.dot(axes[1]))
			flat.append(q)
			lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
			hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
		var span := hi - lo
		charts.append({
			"flat": flat,
			"origin": lo,
			"w": maxi(int(ceil(span.x / texel_size)), MIN_CHART) + PADDING,
			"h": maxi(int(ceil(span.y / texel_size)), MIN_CHART) + PADDING,
			"index": i,
		})

	# 2. Shelf-pack, tallest first. Sorting by height is what makes a shelf run full rather than
	# leaving a ragged strip of wasted texels above every short chart on it.
	#
	# The comparator is a TOTAL order — height, then width, then the face's own index — so no two
	# charts ever compare equal and the result cannot depend on whether the sort is stable. Ordering
	# by height alone is deterministic in practice today, but only because a given sort implementation
	# breaks ties the same way every time; a future engine changing that would silently re-shuffle
	# every atlas in a project. That matters more than it looks: UV2 is a coordinate space users store
	# things in — painted decals, damage maps, anything baked per-texel — and re-shuffling the atlas
	# moves their data onto the wrong faces with nothing to indicate it happened.
	var order: Array = []
	for c in charts:
		if c != null:
			order.append(c)
	order.sort_custom(func(a, b):
		if a["h"] != b["h"]:
			return a["h"] > b["h"]
		if a["w"] != b["w"]:
			return a["w"] > b["w"]
		return a["index"] < b["index"])

	# A square-ish atlas: start from the total area and let the shelves overrun it if they must. Godot
	# does not require a power of two, and rounding up to one would waste up to three quarters of it.
	var area := 0
	var widest := 0
	for c in order:
		area += c["w"] * c["h"]
		widest = maxi(widest, c["w"])
	var atlas_w := maxi(int(ceil(sqrt(float(area)))), widest) + PADDING
	var pen_x := PADDING
	var pen_y := PADDING
	var shelf_h := 0
	for c in order:
		if pen_x + c["w"] > atlas_w:
			pen_x = PADDING
			pen_y += shelf_h
			shelf_h = 0
		c["x"] = pen_x
		c["y"] = pen_y
		pen_x += c["w"]
		shelf_h = maxi(shelf_h, c["h"])
	var atlas_h := pen_y + shelf_h + PADDING
	# One divisor for both axes keeps texels SQUARE. Normalising each axis by its own extent would
	# stretch the lightmap on whichever axis is shorter, so the density guarantee above would hold
	# only in one direction.
	var scale := 1.0 / float(maxi(maxi(atlas_w, atlas_h), 1))

	# 3. Hand back a UV2 per vertex, in the caller's original order. `charts` is index-parallel to
	# `polygons` — a degenerate face left a null in it rather than being skipped — so the caller can
	# index the result by face without tracking which ones were dropped.
	var out: Array = []
	out.resize(polygons.size())
	for i in charts.size():
		var c = charts[i]
		if c == null:
			out[i] = PackedVector2Array()
			continue
		var uv2 := PackedVector2Array()
		var origin: Vector2 = c["origin"]
		# Half the padding on each side, so the gutter sits around the chart rather than shoving it
		# against the neighbour on one side.
		var base := Vector2(float(c["x"]) + PADDING * 0.5, float(c["y"]) + PADDING * 0.5)
		for q in c["flat"]:
			uv2.append((base + (q - origin) / texel_size) * scale)
		out[i] = uv2
	return out


## An orthonormal basis in the plane of `normal`. Only has to be STABLE, not meaningful: the chart is
## measured and packed in whatever frame comes back, and a lightmap has no orientation of its own the
## way a texture does. Picking the axis the normal leans on least keeps the cross product away from
## zero.
static func _plane_axes(normal: Vector3) -> Array:
	var n := normal.normalized()
	var seed := Vector3.UP
	if absf(n.dot(seed)) > 0.9:
		seed = Vector3.RIGHT
	var u := n.cross(seed).normalized()
	return [u, n.cross(u).normalized()]
