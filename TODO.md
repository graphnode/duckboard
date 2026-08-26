# TODO

Delivered work is not tracked here — `CHANGELOG.md` records what shipped, and the rationale
behind it lives in the code's `##` doc comments. This file is only what is still open.

## Editor

- [ ] **Pick-ladder residue: gizmo LINES far from their origin stay Scene-dock-only.** The fourth
	  rung (shipped) yields near the ORIGIN of owned gizmo-only nodes — Marker3D at its real
	  gizmo_extents, Camera3D with a second probe along its view line, everything else at the icon
	  radius — but a long Path3D curve or a RayCast3D beam is clickable in stock Godot anywhere
	  along the line, and the ladder cannot see the line. Accepted; revisit only if it bites.
- [ ] **Sync Godot grid size** with the plugin's grid size, so orthographic view grids change too.
  - [ ] Try changing how orthographic views render — TrenchBroom shows wireframes there, which
		makes dragging brushes around easier.
- [ ] **Settings panel** to configure the plugin.
- [ ] **Grid-frame residues.** Edit gestures (vertex/edge/face drag, shear, move, the rotate
	  pivot) now snap in the edited solid's PARENT frame (`snap_frame_of` / `snap_point_in` /
	  `snap_delta_in`), so a brush under a rotated parent edits on its own lattice; an identity
	  parent degrades to the old world behaviour exactly. Still open, all deliberate for now:
  - A gesture spanning solids under DIFFERENT parent bases snaps in the PRIMARY's frame — the one
	grid a single drag can honour. The others land off their local grid, as they always did.
	Refusing (status text) is the stricter alternative if it proves confusing.
  - A parent with NON-UNIFORM scale gets the world frame (no per-axis lattice is coherent) rather
	than a refusal. Uniform parent scale is honoured: the grid becomes `grid_size` parent-units.
  - CREATION stays world-space by design — the draw plane, hull commit, shape builder and paste
	author in world axes. Drawing INTO an open group under a rotated parent is therefore still a
	world-space path.
  - The clip tool's on-face snap (`_snap_on_face`) and the face-push scalar are frame-independent
	and were left alone.

## Physics

Shipped: the Physics menu builds a body and a `CollisionShape3D` per convex piece, as real nodes,
and `collision.gd` keeps them in step. What is left open:

- [ ] **A brush deleted with the Delete key leaves its shape behind until the undo history purges
	  it.** Deliberate — the editor parks a deleted node in the history rather than freeing it, so
	  tearing the shape down at that moment would leave Ctrl+Z restoring a brush with no collision.
	  `NOTIFICATION_PREDELETE` catches the real destruction and the scene-open sweep
	  (`_sweep_orphan_shapes`) catches anything saved in between, so nothing is ever *lost* — but a
	  shape can sit in the dock looking live for a while. A better answer would need a hook into the
	  editor's own delete, which `EditorPlugin` does not offer.
- [ ] **An emptied body is left in the scene by Remove from Body.** It may carry a script, layers or
	  children of the user's, so deleting it is not Duckboard's call. Revisit if it proves annoying.
- [ ] Jolt applies a convex radius, so brushes thinner than a few TB units may behave oddly. Shapes
	  under `MIN_POINTS` are already dropped.
- [ ] A `BoxShape3D` fast path for 6-axis-plane brushes is a real perf win and a second
	  representation to keep in step. Deliberately skipped.

- [ ] **A brush nested under a `RigidBody3D` does not become its shape.** Each solid derives its
	  OWN body as a child, so the result is a `StaticBody3D` riding inside the rigid body rather
	  than shapes contributing to it — the brush looks parented to the physics and is not part of
	  it. `tests/town.tscn` has this shape (`Map/RigidBody3D/Brush21`) and only works because a
	  hand-placed `CollisionShape3D` sits alongside it.
  - Same root as the entry below, seen from the other side: a solid's body is its own and cannot
	be lent to an ancestor. Whether to detect it and say so, or document it, is the open part.

- [ ] **Several loose brushes cannot share one body.** Each solid derives its OWN body, so five
	  brushes selected and set to Rigid become five falling objects rather than one crate. The answer
	  today is to GROUP them — a group is one node holding several pieces, so it is one body with one
	  shape per piece, which is exactly the crate — and that is arguably the right answer, since a
	  crate built from five solids IS one object. Worth a line in the README rather than code, unless it proves annoying.
  - Noticed while migrating `tests/town.tscn`, where the old model's one-body-per-selection had been
	used for exactly this. The group there converted cleanly, so the workaround is real.

- [ ] **Moving a PARENT rebuilds every mesh under it, every frame — cost unmeasured.** Brushes ask
	  for transform notifications, so an ancestor's move reaches each one, and in the editor with
	  texture lock off `_notification` calls `_build_mesh()` — a full `ArrayMesh` rebuild, UV2 atlas
	  packing included when lightmapping is on. Dragging a `Node3D` holding a building's worth of
	  brushes therefore rebuilds all of them per frame.
  - **Not measured, and a headless harness cannot measure it**: `_notification` returns early on
	`not Engine.is_editor_hint()`, which a `--script` run cannot turn on, so a timing harness
	measures the skip and reports a reassuring number that means nothing. Profile it in the live
	editor before treating it as a problem — it may well be fine.
  - The universal brush already improved the common case: a group is one node with one mesh, so
	dragging a parent over a twenty-member group is one rebuild rather than twenty.

## Shipping a level

Shipped in 0.5.0: export-time stripping (`export_strip.gd`) and Convert Scene to Plain Nodes,
both riding `Brush.to_plain_nodes`, verified live and against a real export. Edge cases left
open:

- [ ] **A brush inside an instanced sub-scene bakes its UVs against its OWN scene root.** Export
	  customizes each scene file separately, so the accumulated pose stops at the sub-scene root —
	  a world-projected (unlocked) texture on an instance placed at a transform freezes where the
	  sub-scene had it, where a live runtime rebuild would re-project from the instance's world
	  pose. Rare (props are usually texture-locked); document it if it ever bites.
- [ ] **Instance-level overrides of `pieces` are dropped by the strip.** A level that overrides
	  brush geometry ON an instanced brush-scene loses the override when the instanced scene's
	  brush collapses (the property no longer exists), with a load warning in the shipped game.
	  Same class of edge; detect-and-warn at export would be the fix if it proves real.
- [ ] **The Brush-reference scan reads `.gd` sources only.** `node is Brush` inside a script
	  embedded in a `.tscn` (rare) is invisible to it; the failure mode is a script parse error in
	  the shipped build, the workaround is switching the strip option off. The scan already errs
	  toward shipping the addon on any word-boundary `Brush` hit, comments included.

## Brush groups — known limitations

Groups shipped in 0.2.0. What's left, in rough priority order:

- [ ] Godot's own selection (the Scene dock) still sees the whole scene while a group is open.
- [ ] Fragment culling can leave **T-junctions** — a fragment edge meeting a neighbour's face away
	from its vertices — which shows as a hairline crack under lighting. Watch for it on lit geometry
	before deciding whether it needs welding.
- [ ] The wash spares the group's **box**, not its geometry, so a brush poking into that box escapes
	the wash too. Reads as intended in practice; only ever generous around concave groups.

## Linked solids

Shipped in 0.5.0 substantially as designed here: `link_id` on `Brush`, propagation in the undo
writers (`_record_solid_writes` / `_commit_reshape`) plus a live mirror (`Brush.link_mirror`) so
twins follow drags frame by frame, per-instance transforms, always-texture-locked instances with
the carry re-framing alignment per twin, cyan twin bounds, and the Duplicate dropdown carrying
Select All Linked / Break Link. Residuals, all deliberate for now:

- [ ] **CSG results start unlinked.** A world-space carve has no honest replay at a twin's other
	  transform, so `_replace_brushes` output carries no `link_id`. Detect-and-say (status text)
	  if it surprises anyone in practice.
- [ ] **Ungrouping a linked group drops its link**, for the same `_replace_brushes` reason. The
	  surviving twins keep linking to each other.
- [ ] **Merging solids that carry two DIFFERENT link ids produces an unlinked group** rather than
	  choosing a side. One id propagates the merge to every twin; several have no honest answer.
- [ ] **Links do not survive the TrenchBroom clipboard** (`.map` has nowhere to put them); an
	  in-editor duplicate or copy does carry them.
- [ ] **A README line is owed**: linked duplicates versus instancing a `.tscn`, and when each is
	  the right tool. The `.tscn` stays the honest answer for a prop reused across levels.

## Occluders

- [ ] **The two occluder rules want unifying.** A single-piece solid filters its shell per FACE
	  (an untextured face is nodraw and opens a hole); a multi-piece one filters per PIECE and
	  keeps untextured faces, because buried ones would perforate the room from the inside out.
	  Both are right for their case; the unification is "a buried face still occludes, an exposed
	  untextured one does not", which reduces to each rule in its own regime with no piece-count
	  branch.
  - What stops it being mechanical: the shell is built from MERGED pieces, whose faces are not the
	members' faces, so "is this face buried" has nowhere to attach. Either filter before the merge
	by testing faces against the other members (the cull already computes exactly that), or build
	the shell from the cull and give up the coarsening. Worth measuring before choosing.

## 1.0

- [ ] **Port to GDExtension (C++).** For 1.0, `Brush` should be a native node registered in
	  `ClassDB`, exactly like the engine's own — no attached Script resource, so no blue script
	  badge in the Scene dock, and it shows in Create Node as a first-class type. This is *the*
	  reason to do it; the perf gain on the hull solve / clipping is a bonus, not the driver.
  - What ports: `brush.gd` (planes → mesh, hull solve, face clipping, UV carry, texture/UV
	lock). The plugin (`duckboard.gd`) can stay GDScript — it's editor tooling, not the node.
  - Cost, eyes open: a per-platform build step (vs. a `.gd` that just works), edit-compile-reload
	instead of hot reload, and porting ~1500 lines of intricate geometry. Do it only when the API
	is stable — porting a moving target twice is the trap.
  - The universal brush has landed, so the geometry API is stable and the port's unit of work is
	decided: `BrushData` — pure geometry with no node attached, an easier and more natural C++
	boundary than the node.
  - Keep the GDScript `Brush` working until the extension reaches parity, so the editor stays
	usable throughout the port.
  - User extension still works afterwards (`extends Brush` in GDScript over a GDExtension base),
	so the `test.gd` pattern survives — just document the base is now native.

## Known divergences from TrenchBroom (deliberate)

- **Rotation** transforms brush *geometry* (planes), not the node transform, so textures and UVs
  survive untouched and the grid snapping that guards against drift is bypassed rather than
  fought.
- **Scale/shear/rotate** rebuild from the drag-start state each frame instead of composing
  incremental transforms, which is what TrenchBroom's shear tool does and what accumulates error
  there.
- **Clip** deletes a brush consumed entirely by a cut; TrenchBroom logs and drops it silently.
- **Brush tool** prunes placed points to the hull, matching TB's storage model.
- **Only the EDITED element snaps to the grid; untouched geometry is left exactly where it is** —
  TrenchBroom's behaviour, confirmed against it. Every reshape tool (vertex, edge, face,
  face-push, scale, shear) snaps just the corners it moves and passes `snap = false` to
  `Brush.set_from_points(points, snap := true)`, so a brush built or scaled off the current grid
  keeps its fractional coordinates instead of being resized when you edit one part of it. Only the
  DRAW and BRUSH(hull) tools still snap every corner — they create geometry from grid-snapped
  input rather than editing an existing shape. The moved corners are snapped by each tool's own
  drag math (vertex: absolute to the grid; edge/face/push: by a snapped delta). Safe from the old
  runaway-fan because the accumulated float error stays well under the hull tolerance.
- **Minimum scale** is still one grid cell per axis (TB allows arbitrarily thin). The old reason
  (vertex snapping would collapse sub-cell geometry) no longer applies now scale doesn't snap
  vertices; it's kept as a plain safety floor against degenerate near-zero-thickness brushes.
- **Groups are flat** — grouping a selection that contains a group flattens the old one in rather
  than nesting it.
