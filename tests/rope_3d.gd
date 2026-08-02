@tool
class_name Rope3D extends MeshInstance3D

## A rope, cable or washing line hanging between two points, built as a baked tube mesh.
##
## Nothing here is a brush and nothing here is Duckboard's — a rope is a curve, and a brush is an
## intersection of half-spaces, so the two have nothing to say to each other. This lives in
## [code]tests/[/code] with the rest of the harness because the town scene wants ropes strung between
## its buildings and there is no reason for the addon to grow an opinion about them.
##
## [b]Why a mesh and not physics.[/b] A hanging rope is static: it is a shape, not a simulation. A
## [RigidBody3D] chain jitters at the small radii a rope actually has, costs a solver island each,
## and after all that settles into the curve this script draws directly. [SoftBody3D] is worse — it
## wants a closed mesh and pinning is fiddly. Reach for a simulation only when the player can hit the
## rope, and then write a Verlet chain rather than a joint chain.
##
## [b]How to use it[/b]
##   1. Add a [MeshInstance3D] and attach this script (plain Attach Script — this is not a [Brush],
##      so none of the extend-don't-attach rules apply).
##   2. Put the node at the first anchor. For the second, drop a [Marker3D] where the rope should
##      end and point [member anchor_path] at it — or type [member end_point] in by hand.
##   3. Set [member sag] to taste. Everything rebuilds live in the editor.
##
## The ends are left open on purpose: a rope terminates buried in a wall, a hook or an eyelet, and
## capping it costs triangles to draw a disc nobody ever sees.
##
## [b]Two things that bite in practice.[/b] Sub-pixel geometry shimmers, so keep [member radius] at
## 2-3 cm even when the reference photo says thinner — too thick reads better than sparkling. And a
## thin rope's shadow is nearly all aliasing, so set Cast Shadow to Off on anything that is not
## directly overhead.

## How many UV repeats per metre of rope, lengthwise — the stripe rate of the braid texture. A
## constant rather than an export because it belongs to the MATERIAL, not the rope: two ropes sharing
## a texture and disagreeing about this is a bug every time.
const UV_TILES_PER_METER := 4.0

## Anchor B, in this node's LOCAL space. Anchor A is the origin, so a rope is placed by moving the
## node to one end and dragging this to the other.
##
## [b]Local, which is the trap.[/b] Copying a [Marker3D]'s Position out of the inspector and pasting
## it here does not work: that number is local to the MARKER's parent, so the rope overshoots by
## however far its own origin sits from that parent's. Worse, local space carries rotation, so on a
## rotated rope no amount of subtracting positions fixes it. Point [member anchor_path] at the marker
## instead and the conversion is done properly, every rebuild.
@export var end_point := Vector3(4.0, 0.0, 0.0):
	set(value):
		end_point = value
		rebuild()

## Optional far anchor, as a node rather than a number — the intended way to place a rope.
##
## While this is set, [member end_point] becomes a live readout: each rebuild overwrites it with
## [code]to_local(anchor.global_position)[/code], so the inspector always shows what is actually
## being drawn. Clearing the path leaves the last resolved value behind, which makes it a fine way to
## snap a rope to a marker once and then delete the marker.
##
## Tracked by POLLING, and only in the editor. [Node3D] has no "I moved" signal to connect to, and a
## rope strung between two buildings does not move at run time — so this costs one vector compare per
## editor frame and nothing at all in game. If you need a rope to follow something in game, call
## [method rebuild] yourself when it moves.
@export_node_path("Node3D") var anchor_path: NodePath:
	set(value):
		anchor_path = value
		rebuild()

## How far the middle of the rope droops below the straight line between the anchors, in metres.
##
## The droop is applied as a VERTICAL offset from that chord rather than perpendicular to it, which
## is not a shortcut — it is what a hanging cable actually does. Weight pulls down whatever way the
## rope is oriented, so anchors at different heights give the lopsided sag you want for free, with
## the lowest point sitting nearer the lower anchor.
@export_range(0.0, 20.0, 0.01, "or_greater") var sag := 0.6:
	set(value):
		sag = value
		rebuild()

## Rope thickness. See the header on why erring thick is the right error.
@export_range(0.005, 0.5, 0.001, "or_greater") var radius := 0.03:
	set(value):
		radius = value
		rebuild()

## Subdivisions along the length. The silhouette is the only thing that gives this away, so 16-24 is
## plenty for a rope you walk under and 8 is fine for one across the skyline.
@export_range(2, 128) var segments := 20:
	set(value):
		segments = value
		rebuild()

## Sides of the tube's cross-section. Four reads as round at any distance a rope is seen from, and a
## triangle is a genuine option for background clutter — the normals do the work, not the outline.
@export_range(3, 12) var sides := 4:
	set(value):
		sides = value
		rebuild()

## How sharply the droop concentrates in the middle. Near zero this is a parabola — a light line
## sagging evenly. Wound up, the curve pinches toward the centre and hangs like heavy chain, because
## that is the difference between the two: where the weight is.
@export_range(0.05, 4.0, 0.01) var tension := 1.6:
	set(value):
		tension = value
		rebuild()

## Rope colour.
##
## Deliberately does NOT rebuild the mesh — it recolours the existing material in place, which is
## both faster and the only version that survives being dragged (see [method rebuild]).
##
## This is the cheap route, and it stops where cheap stops. For a rope with an actual braid texture,
## set [member GeometryInstance3D.material_override] in the inspector: it wins over this one with no
## code, and the UVs are already laid out for it — U around the rope, V along it at
## [constant UV_TILES_PER_METER] repeats per metre.
@export var color := Color(0.45, 0.35, 0.23):
	set(value):
		color = value
		_material().albedo_color = color


## Re-entrancy guard. [method rebuild] writes [member end_point] when an anchor is set, and that
## write goes through the property's own setter, which calls [method rebuild] — so without this the
## first anchored rebuild recurses until the stack gives out.
var _resolving := false

## Built once and then only ever recoloured, so that changing [member color] does not churn a new
## resource onto the surface on every frame of a drag.
var _rope_material: StandardMaterial3D = null


## The surface material, created on first use. Left rough — rope is not a shiny thing, and a
## StandardMaterial3D defaults to fully rough, so there is nothing to set but the colour.
func _material() -> StandardMaterial3D:
	if _rope_material == null:
		_rope_material = StandardMaterial3D.new()
		_rope_material.albedo_color = color
	return _rope_material


func _ready() -> void:
	# Editor only, and only worth anything while an anchor is set — see anchor_path.
	set_process(Engine.is_editor_hint())
	rebuild()


func _process(_delta: float) -> void:
	var node := _anchor()
	if node == null:
		return
	# Deliberately compares the RESOLVED point rather than watching the marker's own transform,
	# because the answer changes when either end moves: dragging the rope itself changes what
	# to_local() makes of a marker that has not budged.
	if not to_local(node.global_position).is_equal_approx(end_point):
		rebuild()


## The node [member anchor_path] points at, or null if it is unset, dangling, or aimed at this rope.
##
## That last case is not paranoia — it is one misclick away in the node picker, and it would resolve
## to a zero-length rope whose every vertex lands on the origin.
func _anchor() -> Node3D:
	if anchor_path.is_empty() or not is_inside_tree():
		return null
	var node := get_node_or_null(anchor_path) as Node3D
	return null if node == self else node


## A point on the rope, [param t] running 0 at this node's origin to 1 at [member end_point].
##
## The shape is a true catenary — [code]cosh[/code] is the curve a chain under its own weight takes,
## and it is one line, so there is no reason to approximate it. Normalised so the term is 0 at both
## anchors and exactly 1 at the midpoint, which is what lets [member sag] be stated in metres of
## droop instead of as some opaque curve constant.
func _point(t: float) -> Vector3:
	var u := t * 2.0 - 1.0
	# Floored because the normalisation divides by cosh(c) - 1, which goes to zero with c.
	var c := maxf(tension, 0.05)
	var droop := (cosh(c) - cosh(c * u)) / (cosh(c) - 1.0)
	return end_point * t + Vector3.DOWN * sag * droop


## The direction the rope runs at ring [param i], from its neighbours on either side. Central
## difference rather than forward, so the frame at a ring reflects the curve THROUGH it and the tube
## does not visibly kink where the sag is tightest.
func _tangent(points: PackedVector3Array, i: int) -> Vector3:
	var delta := points[mini(i + 1, points.size() - 1)] - points[maxi(i - 1, 0)]
	return delta.normalized() if delta.length_squared() > 1e-12 else Vector3.RIGHT


## Rebuilds the mesh: resolves the anchor if there is one, then sweeps a ring of vertices along the
## curve and stitches the quads between consecutive rings.
##
## Public because a rope that follows something at run time needs a way to be told, and there is no
## signal that would tell it by itself.
##
## [b]The existing [ArrayMesh] is refilled rather than replaced, and that is not a micro-optimisation
## — it is what makes the inspector usable.[/b] Assigning [member MeshInstance3D.mesh] calls
## [method Object.notify_property_list_changed], because the node's `surface_material_override/N`
## slots depend on how many surfaces the new mesh has. The inspector answers that by throwing away
## and rebuilding its property editors — including the [EditorSpinSlider] under your mouse, which
## takes the drag with it. So dragging Sag would rebuild the mesh, and the rebuild would cancel the
## drag, once per frame, forever.
##
## Measured, not assumed: assigning a fresh mesh five times fires property_list_changed five times;
## clearing and refilling the same one fires it zero times, with the surface count unchanged.
func rebuild() -> void:
	if _resolving:
		return
	var node := _anchor()
	if node != null:
		_resolving = true
		end_point = to_local(node.global_position)
		_resolving = false

	var count := maxi(segments, 2)
	var points := PackedVector3Array()
	for i in count + 1:
		points.append(_point(float(i) / float(count)))

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# One vertex more per ring than there are sides. The extra one sits on top of the first but
	# carries U = 1 instead of U = 0, which is how the texture wraps without a seam that smears the
	# whole braid across the last face.
	var stride := sides + 1
	var step := TAU / float(sides)
	var arc := 0.0
	for i in points.size():
		if i > 0:
			arc += points[i].distance_to(points[i - 1])
		var forward := _tangent(points, i)
		# A rope hanging vertically has no meaningful "up" to frame its cross-section against, and
		# the cross product collapses. Any other reference direction will do at that point.
		var reference := Vector3.UP if absf(forward.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
		var side := reference.cross(forward).normalized()
		# side.cross(normal) == forward, i.e. a right-handed basis — which is what the winding order
		# below assumes when it puts the front faces on the outside.
		var normal := forward.cross(side)
		# Zero at both anchors, one at the middle. Nothing in this script reads it: it is there for a
		# wind shader, which needs exactly this mask to sway the rope without tearing it off its
		# hooks. Free to carry, and impossible to reconstruct in a vertex shader after the fact.
		var sway := sin(PI * float(i) / float(count))
		for j in stride:
			var radial := side * cos(step * j) + normal * sin(step * j)
			# The radial IS the surface normal of a tube, exactly, so there is nothing to be gained
			# by averaging face normals after the fact.
			st.set_normal(radial)
			st.set_color(Color(sway, 0.0, 0.0))
			st.set_uv(Vector2(float(j) / float(sides), arc * UV_TILES_PER_METER))
			st.add_vertex(points[i] + radial * radius)

	for i in count:
		for j in sides:
			var near_first := i * stride + j
			var far_first := (i + 1) * stride + j
			st.add_index(near_first)
			st.add_index(far_first)
			st.add_index(far_first + 1)
			st.add_index(near_first)
			st.add_index(far_first + 1)
			st.add_index(near_first + 1)

	st.generate_tangents()
	st.set_material(_material())

	# See the note above: same resource in, same resource out, so the node is never told its property
	# list moved. Only the very first build assigns anything, and that one cannot be mid-drag.
	var array_mesh := mesh as ArrayMesh
	if array_mesh == null:
		array_mesh = ArrayMesh.new()
	else:
		array_mesh.clear_surfaces()
	st.commit(array_mesh)
	if mesh != array_mesh:
		mesh = array_mesh
