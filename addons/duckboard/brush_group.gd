@tool
@icon("res://addons/duckboard/icons/GroupedBrushes.svg")
class_name BrushGroup
extends DuckboardSolid
## TrenchBroom's `func_group`: several brushes that read as one unit — but with the Godot twist that
## is the whole point, [b]a group is ONE node with ONE mesh[/b].
##
## That makes this the "bake" idea with no bake step. The combined mesh IS the group's at-rest
## representation, so a map is always already baked, group by group, as it is built: N brushes
## collapse to M surfaces (M = distinct textures), which cuts the opaque pass AND the shadow pass
## (a directional light re-draws every caster once per PSSM cascade). Because the result is a single
## MeshInstance3D, Godot's own Mesh menu — Create Trimesh/Convex Collision, Unwrap UV2 — starts
## applying to a whole room, which it cannot do to N separate brushes. Distinct from CSG Convex
## Merge, which is the permanent, convex-only fusion into one [b]brush[/b].
##
## [b]`members` is the source of truth[/b], the mesh is derived. Each entry is one member solid,
## stored as exactly what [code]Brush.world_faces()[/code] emits — a list of
## {plane, u, v, offset, tex, material, points} face dicts — so absorbing a brush and handing one
## back are [code]set_world_faces()[/code] round-trips with no bespoke serialization. Members are
## held in the group's LOCAL frame, which is what keeps the node's own Transform3D meaningful:
## moving the group moves its contents, and it nests under a moved parent correctly.
##
## The UV axes/offset inside a face dict stay WORLD-space (they always are — see
## Brush.world_faces), so the texture is world-projected exactly as it is on a loose brush, and the
## mesh re-bakes when the group moves.
##
## Registered by `class_name` alone like [Brush], so `node is BrushGroup` works in scans and the
## node appears in Create Node. A CLOSED group is opaque to the plugin's `node is Brush` scans for
## free — its members are data, not nodes, so they are simply not there to be found.

## For _clip, the half-space polygon clip the CSG core already uses. Its EPS matches CULL_EPS
## exactly, so the two agree on what "on the plane" means — and the subtraction below is the same
## clipping the CSG ops do, just applied to visibility instead of to solids.
const Csg := preload("res://addons/duckboard/csg.gd")

## Tolerance for "this corner is inside that member" in the hidden-face test. Matches Csg.CLEAN's
## noise scale: far-from-origin quad clipping leaves ~1e-5 m of float error on derived corners, so a
## flush interface must survive that, while staying far below the finest grid feature (0.125 TB =
## 3.9e-3 m) so a deliberate hairline gap is NOT swallowed and punched into a hole.
const CULL_EPS := 1e-4

## Twice the area below which a fragment is discarded as a clipping sliver (the polygon-area helper
## returns 2x the area, so this compares against that directly). Four orders of magnitude below the
## smallest sane face — one TrenchBroom unit squared is (0.03125 m)^2 ~ 1e-3 — so real geometry can
## never be swallowed, while the hairline slivers a split leaves along a shared edge are.
const MIN_FRAGMENT_AREA2 := 1e-7


## Every member solid, in the group's LOCAL frame. Assigning rebuilds the mesh — the setter is the
## single choke point, so the persisted mesh cannot drift from the members that define it no matter
## which edit path wrote them.
##
## Stored but not shown, for the same reason as [member Brush.planes]: this is the group's source of
## truth, a list of face dicts with structure a typed-in value could not honour. The Rebuild Mesh
## button below stays visible — it is the one safe manual action, and takes no input.
@export_storage var members: Array = []:
	set(value):
		members = value
		_pieces = []         # the merged decomposition is derived from exactly what just changed
		_shell = []          # and so is the occluder built out of it
		_refresh_kernels()   # they hold a copy of the geometry that just changed
		# At RUN TIME this assignment states a projection for the pose the group is in NOW, so the
		# settle in _rebuild_mesh must not then carry it through movement that predates it. The
		# editor is left alone: there the transform handler keeps the reference current, and
		# _lock_transform is stated outright by the paths that need it (recenter, absorb).
		if not Engine.is_editor_hint() and is_inside_tree():
			_lock_transform = _to_world()
		_rebuild_mesh()

## The same three settings [Brush] carries, held here so the group can hand them to its kernels.
## Without them a kernel is born with the defaults, and a group would reshape as though texture lock
## were off however the palette is set — the tools read these off the node they are given.
##
## None are exported, for the reasons given on [Brush]: all three are palette state pushed to every
## node at once, so saving them stores a copy of a global and lets nodes drift out of step with it.

## The grid, in metres: the lattice members reshape on, and the cell size the face overlay draws.
var grid_size := 1.0:
	set(value):
		# Floored, so a zero or negative grid can't reach snappedf or the overlay shader.
		grid_size = maxf(value, 0.001)
		if _grid_material != null:
			_grid_material.set_shader_parameter("cell_size", grid_size)
		_push_to_kernels()

## Editor-only, exactly as [member Brush.texture_lock] is: a group that moves in a running game
## carries its texture with it whichever way this is set. See _notification.
var texture_lock := false:
	set(value):
		texture_lock = value
		# Turning it on states that the projection is right for the pose the group is in NOW, so the
		# reference pose is re-based rather than the texture jumping by the accumulated difference.
		_lock_transform = _to_world()
		_push_to_kernels()

var uv_lock := false:
	set(value):
		uv_lock = value
		_push_to_kernels()

## The cull result, cached: {surface key: [visible face dicts]}. Derived, so deliberately not
## exported. Which faces are hidden depends only on where the members sit RELATIVE TO EACH OTHER —
## all of it group-local — so moving the group cannot change it. That is what lets a drag re-bake
## UVs without re-running the O(members^2 x faces x planes) test every frame.
var _surfaces := {}

## The merged decomposition, cached: one piece per convex piece of the coarsened solid. Derived from
## `members` alone — like `_surfaces`, it depends only on where the members sit relative to each
## other, so moving the group cannot invalidate it. Empty means "not computed yet".
var _pieces: Array = []

## The occluder's shell, cached: the face polygons of the merged pieces. A second cache rather than a
## view of `_pieces`, because the occluder merges a different INPUT — see [method _occluder_shell].
var _shell: Array = []

## Member index -> scratch Brush. See kernel_for.
var _kernels := {}

## Are the kernels standing in for the combined mesh right now (a transform drag, or an open group)?
## Every rebuild has to respect this: folding an edit back assigns `members`, which rebuilds — and
## without this the combined mesh would come back UNDER the live kernels, leaving a stale copy of the
## geometry frozen on screen while the kernels moved.
var _kernels_shown := false

## The pose the cached kernels were built at. NOTIFICATION_TRANSFORM_CHANGED is DEFERRED, so a
## caller that moves the group and asks for a kernel in the same frame — which is exactly what a
## drag does — would otherwise be handed one holding stale world geometry at a no-longer-identity
## transform. Comparing the pose on the way out makes that impossible regardless of notification
## timing; the notification is still used, but only to free the nodes promptly.
var _kernel_pose := Transform3D.IDENTITY

## The pose the members' UV projection was computed for. The delta from here is what texture lock
## absorbs when the group moves — the same reference [Brush] keeps for itself.
var _lock_transform := Transform3D.IDENTITY


func _ready() -> void:
	# Only reads the transform, so it can't fight a gizmo.
	set_notify_transform(true)
	# duplicate() copies CHILDREN, so a group copied while kernels happened to be alive arrives
	# carrying stale scratch nodes. Real kernels are made on demand and never persist, and they are
	# unowned so they cannot come from a saved scene — anything matching here is copy debris, and
	# the copy's own kernel cache does not know about it, so nothing else would ever free it.
	for child in get_children():
		if child.name.begins_with("__kernel_"):
			child.queue_free()
	_lock_transform = _to_world()
	# Collision needs no call of its own here: _rebuild_mesh is where it is kept in step, and this
	# reaches it with the group finally in the tree.
	#
	# A LOADED group arrives with all of that already done. Deserialization assigns `members` while the
	# node is still out of the tree, and that setter runs the full rebuild — so by the time _ready is
	# reached the cull has been computed, the collision subtree raised and the occluder fitted, and all
	# three are group-LOCAL and cannot have been invalidated by arriving in the tree. Only the bake is
	# owed, because its UVs are sampled at WORLD positions and out of the tree there was no world pose
	# to sample at; `_lock_transform`, just stated above, is the pose it now bakes for.
	#
	# Re-culling here instead was the whole expensive half of the rebuild run twice for every group in
	# the scene, on every load, for an answer that could not have changed.
	if _surfaces.is_empty():
		_rebuild_mesh()
	else:
		_rebake()


func _notification(what: int) -> void:
	# No PRE_SAVE / POST_SAVE pair any more: the combined mesh and the grid overlay both live on a
	# generated child with no `owner`, which [PackedScene] does not pack, so the two derived things
	# that had to be hidden from the serialiser are now out of its reach entirely. Exactly as Brush.
	#
	# UVs are baked into the mesh from WORLD positions, so moving the node needs the bake redone —
	# the axes and offset are unchanged, only the positions they are sampled at have moved. The
	# cull is group-local and therefore still valid, so this re-bakes from the cache rather than
	# re-deriving which faces are hidden.
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_inside_tree():
		# Movement needs NO collision work: the shapes are descendants sitting at identity, so they move
		# with the group the way every child does. Only a change of `members` reaches _sync_derived.
		#
		# TEXTURE LOCK IS AN EDITOR MODE, and in a running game the answer can only be "locked" — a
		# group that moves at run time is an OBJECT, and a world-projected texture would scroll
		# across its own faces as it travelled. Brush._notification carries the full argument; the
		# run-time settle is likewise deferred to the one place the axes are read again, which for a
		# group is _rebuild_mesh (the fragment dicts the cull may have copied have to be rebuilt from
		# the carried members, so it is the whole rebuild rather than the bake alone).
		if not Engine.is_editor_hint():
			return
		var current := global_transform
		if texture_lock:
			# Lock ON: carry the projection through the move so the texture travels with the group.
			# The FULL delta pose, not just the offset, so a rotated group turns its texture too.
			var delta := current * _lock_transform.affine_inverse()
			if not delta.is_equal_approx(Transform3D.IDENTITY):
				_lock_uvs(delta)
				_lock_transform = current
				_refresh_kernels()
				return           # _lock_uvs already rebuilt
		_lock_transform = current
		_refresh_kernels()   # a kernel holds world-space geometry, which the move just invalidated
		_rebake()
		return
	# Parentage no longer says anything about collision — the body is a CHILD of this group, so moving
	# the group in the Scene dock takes its physics along by the ordinary rules of the scene graph, and
	# destruction needs no hook because children die with their parent. The kernels still do, being
	# scratch nodes this group owns outright.
	if what == NOTIFICATION_PREDELETE:
		_drop_kernels()


# --- Frame conversion -----------------------------------------------------

## Carry a list of face dicts through `xform`. The PLANE maps by the inverse-transpose (it
## transforms like a normal, not a point) and the polygon by the full transform — the same rule
## Brush._to_world_plane uses, so it stays correct even under scale. The UV axes and offset are left
## alone BY DESIGN: they are world-space, and leaving them fixed is what makes a group's texture
## world-projected like a brush's.
static func transform_faces(faces: Array, xform: Transform3D) -> Array:
	var normal_basis := xform.basis.inverse().transposed()
	var out := []
	for f in faces:
		var p: Plane = f["plane"]
		var n := (normal_basis * p.normal).normalized()
		var on_plane := xform * (p.normal * p.d)
		var pts := PackedVector3Array()
		for c in f["points"]:
			pts.append(xform * c)
		var moved: Dictionary = f.duplicate()
		moved["plane"] = Plane(n, n.dot(on_plane))
		moved["points"] = pts
		out.append(moved)
	return out


## This group's pose, safe to ask for before the node is in the tree (where global_transform errors).
func _to_world() -> Transform3D:
	return global_transform if is_inside_tree() else Transform3D.IDENTITY


## One member as WORLD-space faces — ready to hand straight to Brush.set_world_faces(), which is how
## both Ungroup and edit-mode materialize a member.
func world_member(index: int) -> Array:
	if index < 0 or index >= members.size():
		return []
	return transform_faces(members[index], _to_world())


## Every member in world space, in member order.
func world_members() -> Array:
	var out := []
	for i in members.size():
		out.append(world_member(i))
	return out


## The inverse trip: world-space faces (a brush being absorbed, or a kernel being read back) folded
## into this group's local frame, ready to store in `members`.
func to_local_faces(faces: Array) -> Array:
	return transform_faces(faces, _to_world().affine_inverse())


# --- Member kernels -------------------------------------------------------

## One member, borrowed back as a real [Brush] — the group's KERNEL for that member.
##
## The point is that every operation on a group's geometry runs the IDENTICAL brush code path
## instead of a parallel implementation that would drift: same hull solve, same UV carry, same
## snapping rules, same face picking. A tool holding a kernel cannot tell it apart from a loose
## brush, which is what lets picking, and later the transform tools, work on groups with no
## group-specific branches.
##
## Pinned to the identity GLOBAL transform, so local == world and the kernel's own planes are world
## planes. Unowned, so it is never saved; hidden, so it never renders over the combined mesh — the
## group's own mesh is what you see. Cached per member, and dropped wholesale whenever `members` or
## the group's transform changes, since either invalidates the world-space copy it holds.
func kernel_for(index: int) -> Brush:
	if index < 0 or index >= members.size():
		return null
	# Refresh rather than drop: the deferred TRANSFORM_CHANGED may not have arrived yet, and a caller
	# that moves the group and asks for a kernel in the same frame must still get correct geometry —
	# without losing the node identity a selected face is holding.
	if not _kernel_pose.is_equal_approx(_to_world()):
		_refresh_kernels()
	var existing = _kernels.get(index)
	if is_instance_valid(existing):
		return existing
	var kernel := Brush.new()
	kernel.name = "__kernel_%d" % index
	add_child(kernel)
	kernel.owner = null            # never serialized
	kernel.visible = false
	kernel.global_transform = Transform3D.IDENTITY
	# After the transform, because texture_lock re-bases its reference pose when assigned.
	_apply_settings(kernel)
	kernel.set_world_faces(world_member(index))
	_kernels[index] = kernel
	return kernel


## Every member as a live kernel, in member order — what the tools are given while the group is OPEN.
## Materializes the full set, unlike the on-demand picking path.
func kernels() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for i in members.size():
		var kernel := kernel_for(i)
		if kernel != null:
			out.append(kernel)
	return out


## Is this node one of our kernels, and if so whose? Returns the member index, or -1. Lets the host
## turn a pick that landed on a kernel back into "member N of this group".
func kernel_index(node: Node) -> int:
	for i in _kernels:
		if _kernels[i] == node:
			return i
	return -1


## Swap the combined mesh for the member kernels, or back again.
##
## While a transform drag is reshaping the members, the kernels are what the tools are actually
## deforming, so they are what belongs on screen — otherwise the group sits frozen until release,
## since the combined mesh only rebuilds when `members` changes. Their own meshes are regenerated by
## Brush's plane setter as the drag runs, so showing them costs nothing beyond the visibility flag.
##
## The combined mesh is CLEARED rather than the node hidden: hiding a Node3D hides its children, and
## the kernels are children. What you see mid-drag is therefore un-culled and un-batched — the
## interior faces between members are momentarily back — and it snaps to the merged mesh on release.
func set_kernels_visible(shown: bool) -> void:
	_kernels_shown = shown
	if not shown:
		# HIDDEN, not freed: a face selected on this group is holding one of these nodes, and the
		# picking path reuses them. release_kernels() is what actually lets them go.
		for i in _kernels:
			var kernel = _kernels[i]
			if is_instance_valid(kernel):
				kernel.visible = false
		_rebuild_mesh()
		return
	for i in members.size():
		kernel_for(i)      # the whole set, not just the ones picking happened to need
	for i in _kernels:
		var kernel = _kernels[i]
		if is_instance_valid(kernel):
			kernel.visible = true
	get_mesh_instance().mesh = null


## Fold the kernels' current geometry back into member form. Members the kernels do not cover are
## carried through untouched, so a partially materialized group is still safe to read back.
func read_back_kernels() -> Array:
	if _kernels.is_empty():
		return []
	var out := members.duplicate()
	for i in _kernels:
		var kernel = _kernels[i]
		if is_instance_valid(kernel) and i < out.size():
			out[i] = to_local_faces(kernel.world_faces())
	return out


func _apply_settings(kernel: Brush) -> void:
	kernel.grid_size = grid_size
	kernel.texture_lock = texture_lock
	kernel.uv_lock = uv_lock


## Keep live kernels in step when a setting changes under them — the grid dropdown moves while a
## group is selected, or a lock is toggled mid-session.
func _push_to_kernels() -> void:
	for i in _kernels:
		var kernel = _kernels[i]
		if is_instance_valid(kernel):
			_apply_settings(kernel)


## Re-seed the live kernels from the current members, KEEPING their node identity.
##
## Freeing them would be simpler, but a selected or hovered FACE is held as {node, face} — so
## replacing the node behind it on every edit would leave the selection pointing at a corpse the
## next time the overlay drew. Kernels whose member no longer exists are freed; the rest are refilled
## in place, so the same instance keeps answering for the same member across edits and moves.
## Let the kernels go. They are cheap but not free — one hidden Brush per member — so the host drops
## them once a group is neither selected nor holding a selected face, rather than letting every group
## ever touched keep a shadow copy of itself alive.
func release_kernels() -> void:
	_drop_kernels()


func _refresh_kernels() -> void:
	_kernel_pose = _to_world()
	if _kernels.is_empty():
		return
	for i in _kernels.keys():
		var kernel = _kernels[i]
		if not is_instance_valid(kernel):
			_kernels.erase(i)
			continue
		if i >= members.size():
			kernel.queue_free()      # its member is gone
			_kernels.erase(i)
			continue
		kernel.global_transform = Transform3D.IDENTITY   # the parent may have moved under it
		kernel.set_world_faces(world_member(i))


func _drop_kernels() -> void:
	for i in _kernels:
		var k = _kernels[i]
		if is_instance_valid(k):
			k.queue_free()
	_kernels.clear()


## Carry every member's UV projection through a world transform `delta`, so each point keeps the UV
## it had and the texture travels with the group.
##
## The same identity [Brush] applies to itself in _lock_uvs — newAxes = oldAxes * delta⁻¹, with the
## offset absorbing the translation, and the axis map being the inverse-transpose because projection
## axes transform like normals rather than points. It is restated here rather than borrowed because a
## group's faces live in `members` as data, not in a brush's per-face arrays.
##
## Rebuilds rather than re-bakes: a fragmented face is stored as a COPY in the surface cache, so
## mutating the member payload alone would leave those fragments carrying the old projection.
func _lock_uvs(delta: Transform3D) -> void:
	_carry_uv_axes(delta)
	_rebuild_mesh()


## The member half of the carry, without the rebuild — what the run-time settle in _rebuild_mesh
## needs, since it is about to rebuild anyway.
func _carry_uv_axes(delta: Transform3D) -> void:
	var axis_map := delta.basis.inverse().transposed()
	var shift := delta.origin
	for member in members:
		for face in member:
			var u: Vector3 = axis_map * face["u"]
			var v: Vector3 = axis_map * face["v"]
			face["offset"] = (face["offset"] as Vector2) - Vector2(u.dot(shift), v.dot(shift))
			face["u"] = u
			face["v"] = v


## Store a list of WORLD-space solids (each one a world_faces() payload) as this group's members.
##
## The node must ALREADY sit at its final pose, because the fold to local reads global_transform —
## which is why the Group undo action parents the node and sets its transform before calling this.
## One assignment to `members`, so one mesh rebuild and one undoable property.
func absorb_world(solids: Array) -> void:
	var folded := []
	for s in solids:
		folded.append(to_local_faces(s))
	members = folded


## How far the origin sits from the centre of the members' bounds, in LOCAL space. Zero means the
## origin is already where [method recenter] would put it.
##
## Bounds centre rather than a centroid, matching both [code]Brush.recenter[/code] and the
## [code]_solids_center[/code] a group is first placed at — so a group that has not been edited since
## it was made reports zero and is left alone.
func center_offset() -> Vector3:
	var bounds := AABB()
	var first := true
	for m in members:
		if first:
			bounds = _member_bounds(m)
			first = false
		else:
			bounds = bounds.merge(_member_bounds(m))
	return Vector3.ZERO if first else bounds.get_center()


## Pull the origin back into the geometry, exactly as [code]Brush.recenter[/code] does for one solid.
##
## A group is placed at the centre of what it swallowed when it is CREATED, and then never again —
## while brushes recenter after clip, scale, shear, CSG and paste. So editing members inside an open
## group walks the origin away from the geometry, which makes the gizmo grab in mid-air and makes a
## group awkward to place inside a [RigidBody3D]. This is the missing half.
##
## Nothing moves in world space: the members shift back by the offset and the node forward by the
## same amount, so this is a pure re-parameterisation of where the origin sits. That is also why it
## is safe to run whenever — but NOT why it is safe to run outside undo, since restoring `members`
## without also restoring the transform would jump the geometry. Callers record both.
func recenter() -> void:
	if not is_inside_tree():
		return
	var offset := center_offset()
	if offset.length_squared() < 1e-12:
		return                    # already centred; skip the churn
	# transform_faces maps the planes by the inverse-transpose and the points by the full transform,
	# and leaves the WORLD-space UV axes and offsets alone — which is exactly right here, because the
	# geometry is about to end up back where it started and its projection must not move with it.
	# It takes ONE solid's faces, so it is applied per member — `members` is a list of solids.
	var shift := Transform3D(Basis.IDENTITY, -offset)
	var shifted := []
	for m in members:
		shifted.append(transform_faces(m, shift))
	members = shifted
	global_position = global_position + global_transform.basis * offset
	# The node moved but the geometry did not. Re-base BEFORE the deferred NOTIFICATION_TRANSFORM_
	# CHANGED arrives, or texture lock measures a delta and compensates for a movement that never
	# happened. Brush gets this free by restoring face_data last; a group has no equivalent, so it is
	# stated here.
	_lock_transform = _to_world()
	# The members setter already rebuilt — but it did so against the OLD transform, and UVs bake from
	# WORLD positions, so that bake read every vertex `offset` away from where it now is. The cull is
	# group-local and therefore still valid, so only the bake is redone. Kernels hold world geometry
	# and are invalidated by the same move.
	_refresh_kernels()
	_rebake()


# --- Mesh generation ------------------------------------------------------

## Rebuild the combined mesh from `members`, batching by SURFACE across the whole group and dropping
## faces that no viewer can ever see.
##
## Batching keys on a face's material override if it has one, else its texture — the same rule Brush
## uses per-brush, lifted to span all members. Because it spans them, two members sharing a texture
## share a draw call, which is the whole render argument for grouping: M surfaces per group instead
## of N brushes. UVs bake in world space, so cross-member texture continuity is free.
## [DuckboardSolid] hooks. A group is the class that makes the split worth having: [method
## rebuild_mesh] re-runs the O(members^2) cull, while [method _rebake_mesh] re-emits the mesh from the
## cull already cached — which is what a lightmap toggle wants, since packing UV2 cannot change which
## faces are hidden.
func rebuild_mesh() -> void:
	_rebuild_mesh()


func _rebake_mesh() -> void:
	_rebake()


func _rebuild_mesh() -> void:
	# Settle the movement the RUN-TIME transform handler deliberately left owed (see _notification):
	# the axes are world-space and the cull is about to copy them into fragments, so they first have
	# to be carried through everything the group has moved since the projection was last stated.
	# Editor-side there is never anything owed — the handler settles on the spot.
	if not Engine.is_editor_hint() and is_inside_tree():
		var pose := _to_world()
		var owed := pose * _lock_transform.affine_inverse()
		if not owed.is_equal_approx(Transform3D.IDENTITY):
			_carry_uv_axes(owed)
			_lock_transform = pose
	_surfaces = _cull_surfaces()
	_rebake()
	# The ONE place collision is kept in step: `members` changing is the only thing that can alter the
	# shapes, and this is the single choke point that runs from, so collision cannot drift from the
	# geometry however the members were written. No is_inside_tree() guard — the subtree is built from
	# this group's OWN children, so it can be raised while the group is still detached (during
	# deserialization, or between BrushGroup.new() and add_child) and travels into the tree with it.
	_sync_derived()


## Bring the generated subtree — mesh, body, shapes — in line with the exports and the members.
## Mirrors Brush._sync_derived; the only difference is that a group hands over one hull PER MEMBER,
## so this is also where a member gained or lost turns into a shape gained or lost.
func _sync_derived() -> void:
	# Same two whole-solid vetoes a brush applies, for the same reasons — see Brush._sync_derived.
	_mesh = Collision.ensure_tree(self, collision_type, collision_layer, collision_mask,
		occluder and Collision.occludes(collision_type) and not Collision.faded(_mesh))
	Collision.fit(_mesh.get_parent() as CollisionObject3D, _member_hulls())
	Collision.fit_occluder(self, _occluder_shell())


## The decomposition `members` already is, COARSENED wherever two pieces fuse into a single convex one
## without gaining any volume — the shared answer collision and occlusion are both a view of.
##
## `members` stays the source of truth and is not touched: the mesh and the cull still see the room
## exactly as it was built. What changes is the PIECE COUNT — a wall of five cuboids becomes one box,
## which is the case a grid-built level produces constantly.
##
## Cached, because [method Csg.merge_pieces] is quadratic in the piece count and hulls as it goes. It
## is invalidated by the `members` setter, the one choke point every edit path already passes through
## — the same arrangement `_surfaces` uses, and for the same reason.
func _member_pieces() -> Array:
	if _pieces.is_empty() and not members.is_empty():
		_pieces = Csg.merge_pieces(members)
	return _pieces


## One local-space point cloud per convex collision piece — [method _member_pieces] as corners, which
## is the form [ConvexPolygonShape3D] wants. collision.gd welds the duplicates shared edges produce.
func _member_hulls() -> Array:
	var out: Array = []
	for piece in _member_pieces():
		out.append(piece["points"])
	return out


## The occluder's shell: the merged pieces as face polygons, in local space.
##
## [b]The same coarsening collision gets, and it pays off harder here.[/b] The occluder used to be
## every face of every member — the whole surface INCLUDING the walls buried between touching members,
## which are inside the solid and can never block anything the outer surface does not already block.
## A wall of five cuboids shipped thirty quads to describe a box. Merging first drops it to six, and
## an occluder is CPU-rasterized every frame, so this is the one derived thing whose size is a
## per-frame cost rather than a load-time one. The volume is identical either way — [method
## Csg.merge_pieces] only fuses when the fused hull encloses nothing new — so the shell still
## describes exactly the solid that is there.
##
## [b]See-through members are dropped BEFORE the merge, and the order is the point.[/b] A member that
## light gets through cannot claim to stop it, one level down from the whole-solid vetoes in
## [method _sync_derived] — and merged into an opaque neighbour it would be impossible to take out
## again, since the fused piece has no members left to ask. Filtering first also means the common case
## costs nothing: with every member opaque the input is `members` and the collision merge IS this
## merge, so it is reused rather than run twice.
##
## Under-occluding is the safe direction, which is what makes dropping a member sound even though it
## opens a hole in the shell: the worst case is a few things drawn that could have been skipped. See
## [method Brush.face_occludes] for the same reasoning per face.
func _occluder_shell() -> Array:
	if not _shell.is_empty() or members.is_empty():
		return _shell
	var opaque: Array = []
	for m in members:
		if _member_occludes(m):
			opaque.append(m)
	var pieces: Array = _member_pieces() if opaque.size() == members.size() \
		else Csg.merge_pieces(opaque)
	for piece in pieces:
		_shell.append_array(Csg.piece_polygons(piece))
	return _shell


## Does this member present surfaces solid enough to block the view? The per-member half of
## [method Brush.face_occludes], and deliberately NOT [method _member_opaque], which answers the
## cull's question rather than this one (a [ShaderMaterial] is taken at its word here, exactly as it
## is on a loose brush, instead of being assumed see-through).
##
## A face stating NO surface at all — no material and no texture — is skipped rather than counted
## against the member. On a loose brush that face is nodraw and says "does not occlude"; inside a
## group it is almost always a face BURIED against a neighbour, never textured because nobody can see
## it, and reading it as see-through would switch occlusion off for most of a real room.
func _member_occludes(faces: Array) -> bool:
	for f in faces:
		var mat: Material = f["material"]
		var tex: Texture2D = f["tex"]
		if mat == null and (tex == null or tex == Brush.DEFAULT_TEXTURE):
			continue
		if not Brush.face_occludes(tex, mat):
			return false
	return true


## Which faces survive, grouped by surface — the expensive half, run only when `members` changes.
func _cull_surfaces() -> Dictionary:
	# Precomputed per member, because the hidden-face test asks about them once per FACE of every
	# other member: the AABB is the cheap reject, and a see-through member must never occlude.
	var bounds := []
	var occludes := []
	for m in members:
		bounds.append(_member_bounds(m))
		occludes.append(_member_opaque(m))

	# {surface key: [face dict, ...]} — the key is a Material or a Texture2D. A face that is only
	# PARTLY buried contributes several entries, one per surviving fragment, each carrying the
	# original face's plane / UV axes / texture so it renders identically to the whole face.
	var by_surface := {}
	for i in members.size():
		for f in members[i]:
			if f["points"].size() < 3:
				continue           # this face got clipped away entirely
			var mat: Material = f["material"]
			var key: Resource = mat if mat != null else f["tex"]
			for frag in _visible_fragments(i, f, bounds, occludes):
				var entry: Dictionary = f
				if frag != f["points"]:
					entry = f.duplicate()
					entry["points"] = frag
				if not by_surface.has(key):
					by_surface[key] = []
				by_surface[key].append(entry)
	return by_surface


## UV2 for every fragment the mesh will draw, keyed by the fragment dictionary, or an empty map when
## lightmapping is off for this group.
##
## The CULLED set, unlike the occluder's: a face buried between two members is never drawn, so giving
## it atlas space would spend texels on lighting nobody can see. That is the opposite of the choice
## collision and occlusion make, and for the opposite reason — those describe the solid, this
## describes what is rendered.
##
## Keyed by the dictionary rather than by index because _cull_surfaces may split one face into several
## fragments, and the bake loop walks fragments, not faces.
func _fragment_uv2() -> Dictionary:
	if not lightmap_uv2:
		return {}
	var frags: Array = []
	var polys: Array = []
	var normals: Array = []
	for key in _surfaces:
		for f in _surfaces[key]:
			frags.append(f)
			polys.append(f["points"])
			normals.append((f["plane"] as Plane).normal)
	var packed := Lightmap.pack(polys, normals, lightmap_texel_size)
	var out := {}
	for i in frags.size():
		if i < packed.size():
			out[frags[i]] = packed[i]
	return out


## Build the mesh from the cached cull result — the cheap half, also run on every move, because the
## UVs are sampled at WORLD positions and those change when the group does.
func _rebake() -> void:
	# The kernels ARE the geometry while they are shown, so the combined mesh must stay away —
	# including when a fold-back assigns `members` mid-edit and rebuilds through here.
	if _kernels_shown or members.is_empty() or _surfaces.is_empty():
		get_mesh_instance().mesh = null
		return

	var to_world := _to_world()
	var array_mesh := ArrayMesh.new()
	# One atlas for the whole group, packed before any surface is emitted — UV2 addresses the mesh,
	# not the surface, so fragments on different surfaces must not overlap in it. Keyed by the
	# fragment dictionary itself, because a fragment is what the loop below actually walks and the
	# cull may have split one face into several of them.
	var uv2 := _fragment_uv2()

	# Untextured faces are left out in a running game, exactly as a loose Brush leaves them out (see
	# Brush._build_mesh). Grouping geometry must not change what renders, and a group is precisely
	# where the nodraw saving is worth most — a room's worth of faces nobody ever textured.
	var drop_untextured := not Engine.is_editor_hint()
	for key in _surfaces:
		if drop_untextured and key == Brush.DEFAULT_TEXTURE:
			continue
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for f in _surfaces[key]:
			var poly: PackedVector3Array = f["points"]
			var n: Vector3 = (f["plane"] as Plane).normal
			var u: Vector3 = f["u"]
			var v: Vector3 = f["v"]
			var off: Vector2 = f["offset"]
			var frag_uv2: PackedVector2Array = uv2.get(f, PackedVector2Array())
			# Triangle fan, each triangle reversed for Godot's front-face convention. Vertices are
			# already group-local (that is the frame members are stored in); only the UV needs the
			# world position.
			for i in range(1, poly.size() - 1):
				for k in [0, i + 1, i]:
					var world: Vector3 = to_world * poly[k]
					st.set_normal(n)
					st.set_uv(Vector2(world.dot(u), world.dot(v)) + off)
					if k < frag_uv2.size():
						st.set_uv2(frag_uv2[k])
					st.add_vertex(poly[k])
		# Brush's, not a copy of it: a group's faces must render exactly as they did while they were
		# loose brushes, and the only way to guarantee that is to build them the same way.
		st.set_material(key if key is Material else Brush._material_for(key as Texture2D))
		st.commit(array_mesh)

	get_mesh_instance().mesh = array_mesh
	_apply_grid_overlay()


## The parts of this face of member `owner` that a viewer outside the union could actually see: the
## face polygon with every other member's volume subtracted. Empty means the face is wholly buried.
##
## Two flush cubes lose BOTH sides of their shared interface, which is correct — that interface is
## interior to the union, and dropping it takes the coincident-face z-fighting with it. A face that
## is only PARTLY buried is cut down to its visible remainder rather than kept whole, so a small
## block against a large wall costs the wall only the area it genuinely hides.
##
## Everything here is group-LOCAL, which is what makes the result cacheable: moving the group cannot
## change which of its parts bury which others.
func _visible_fragments(owner: int, face: Dictionary, bounds: Array, occludes: Array) -> Array:
	var frags := [face["points"]]
	var face_bounds := _points_bounds(face["points"])
	for j in members.size():
		if j == owner or not occludes[j]:
			continue
		# GROWN by the tolerance, because the case this test exists for — a flush interface — is
		# exactly the case AABB.intersects() calls a miss: it treats touching boxes as
		# non-overlapping, and a buried face's box touches its occluder's by definition. Testing
		# the WHOLE face's bounds stays valid after it has been cut up, since every fragment lies
		# inside them.
		if not (bounds[j] as AABB).grow(CULL_EPS).intersects(face_bounds):
			continue
		frags = _subtract_member(frags, members[j])
		if frags.is_empty():
			break
	return frags


## Subtract one convex member's volume from a set of polygons, returning what is left over.
##
## Sutherland-Hodgman turned inside out. Walking the occluder's planes, the part of a piece lying
## OUTSIDE any one plane can never be inside the occluder — a convex solid is the intersection of
## its half-spaces — so that part survives immediately and stops being considered. Only the part
## still inside carries on to the next plane, and whatever is still inside after every plane is
## inside the solid and gets dropped. Splitting a convex polygon by a plane yields convex pieces, so
## fragments stay convex and the triangle fan in _rebake keeps working unchanged.
func _subtract_member(frags: Array, occluder: Array) -> Array:
	var survivors := []
	var remaining := frags
	for g in occluder:
		if remaining.is_empty():
			break
		var still_inside := []
		for frag in remaining:
			var halves := _split(frag, g["plane"])
			if _area2(halves[0]) > MIN_FRAGMENT_AREA2:
				survivors.append(halves[0])
			if _area2(halves[1]) > MIN_FRAGMENT_AREA2:
				still_inside.append(halves[1])
		remaining = still_inside
	return survivors


## Split a polygon by a plane into [outside, inside]. The wholly-one-side cases are settled up front
## rather than falling through to the clip, because a polygon lying exactly IN the plane — a flush
## interface, the very thing this pass exists for — would otherwise come back intact as BOTH halves
## and survive as its own occluder's shadow.
func _split(poly: PackedVector3Array, plane: Plane) -> Array:
	var has_outside := false
	var has_inside := false
	for p in poly:
		var d := plane.distance_to(p)
		if d > CULL_EPS:
			has_outside = true
		elif d < -CULL_EPS:
			has_inside = true
	if not has_outside:      # every corner on or behind the plane — this covers the coplanar case
		return [PackedVector3Array(), poly]
	if not has_inside:
		return [poly, PackedVector3Array()]
	return [Csg._clip(poly, Plane(-plane.normal, -plane.d)), Csg._clip(poly, plane)]


## Twice the area of a planar polygon, via the Newell sum — needs no projection or basis, and
## degenerates to zero for slivers and collinear points, which is exactly what it is used to catch.
func _area2(poly: PackedVector3Array) -> float:
	if poly.size() < 3:
		return 0.0
	var n := Vector3.ZERO
	for i in poly.size():
		n += poly[i].cross(poly[(i + 1) % poly.size()])
	return n.length()


## May this member hide another member's faces? Only if nothing about it can be seen through — a
## plain texture face is opaque, a BaseMaterial3D is opaque only with transparency disabled, and
## anything else (a ShaderMaterial, which could discard or blend) is assumed see-through. Culling
## behind glass would delete geometry the player can look straight at, so the doubt resolves toward
## keeping faces.
func _member_opaque(faces: Array) -> bool:
	for f in faces:
		var mat: Material = f["material"]
		if mat == null:
			continue
		if mat is BaseMaterial3D \
				and (mat as BaseMaterial3D).transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
			continue
		return false
	return true


## The whole group's extent in its OWN local space — the box the isolation wash spares, and a
## cheap stand-in for the group's reach wherever the combined mesh is not available to ask.
##
## Reads the live child brushes while they are on screen and the members otherwise, because those are
## the two places the current geometry can be: open or mid-drag the kernels are what a tool is
## deforming and `members` is one commit behind, while at rest there may be no kernels at all.
##
## Every child [Brush] counts, not just the kernels — geometry drawn, pasted or duplicated into an
## open group arrives as a REAL child node and only becomes a member when the group closes (see
## _brush_parent in duckboard.gd). Leaving those out would let the wash fall over a brush the moment
## it was added to the group it belongs to.
func local_bounds() -> AABB:
	var out := AABB()
	var have := false
	if _kernels_shown:
		var from_world := _to_world().affine_inverse()
		for child in get_children():
			if not (child is Brush) or not (child as Brush).visible:
				continue
			# Kernels are pinned to the identity global transform so this collapses to their own
			# AABB, but a brush just drawn into the group carries a transform of its own.
			# get_aabb() off the Brush, which forwards to the MeshInstance3D it renders through — a
			# brush is a Node3D now, so the cast that used to work here no longer does.
			var box := (from_world * (child as Node3D).global_transform) \
				* (child as Brush).get_aabb()
			out = box if not have else out.merge(box)
			have = true
	if have:
		return out
	for m in members:
		var box := _member_bounds(m)
		out = box if not have else out.merge(box)
		have = true
	return out


## The individual boxes local_bounds() merges — one per live kernel (or drawn-in child) while the
## kernels are on screen, one per member otherwise. The isolation wash spares THESE rather than the
## merged extent, so outside geometry poking between members no longer escapes the wash with them.
func local_bounds_list() -> Array[AABB]:
	var out: Array[AABB] = []
	if _kernels_shown:
		var from_world := _to_world().affine_inverse()
		for child in get_children():
			if not (child is Brush) or not (child as Brush).visible:
				continue
			out.append((from_world * (child as Node3D).global_transform)
				* (child as Brush).get_aabb())
	if not out.is_empty():
		return out
	for m in members:
		out.append(_member_bounds(m))
	return out


func _member_bounds(faces: Array) -> AABB:
	var out := AABB()
	var first := true
	for f in faces:
		for c in f["points"]:
			if first:
				out = AABB(c, Vector3.ZERO)
				first = false
			else:
				out = out.expand(c)
	return out


func _points_bounds(points: PackedVector3Array) -> AABB:
	if points.is_empty():
		return AABB()
	var out := AABB(points[0], Vector3.ZERO)
	for i in range(1, points.size()):
		out = out.expand(points[i])
	return out


func _apply_grid_overlay() -> void:
	var target := get_mesh_instance()
	if not Engine.is_editor_hint() or not _grid_overlay_enabled:
		target.material_overlay = null
		return
	if _grid_material == null:
		_grid_material = ShaderMaterial.new()
		_grid_material.shader = GRID_SHADER
		_grid_material.render_priority = 1   # sorted after the surface — see Brush._apply_grid_overlay
	_grid_material.set_shader_parameter("cell_size", grid_size)
	target.material_overlay = _grid_material
