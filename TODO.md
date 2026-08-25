# TODO

Delivered work is not tracked here — `CHANGELOG.md` records what shipped, and the rationale
behind it lives in the code's `##` doc comments. This file is only what is still open.

## Editor

- [ ] **Duplicating a solid errors: "Child node disappeared while duplicating."** Reproduced by
	  duplicating the Stairs brush from the viewport; the node still copies, so it is noisy rather
	  than broken. NOT from the context-aware input work — nothing in it touches duplication.
  - **The derived subtree meets `Node::duplicate()`.** `Node::_duplicate` copies the generated
	children (they are unowned, not internal, so it sees them), and `_duplicate_properties` then
	walks original and copy **in lockstep by child index**. Setting `planes` / `members` on the copy
	re-runs `_sync_derived` → `Collision.ensure_tree`, which adds a body, re-parents the mesh under
	it, or frees an occluder — mid-walk. The indices stop lining up and the engine reports it.
	`_duplicate_brushes` already calls `Collision.reset(copy)`, but only AFTER `duplicate()` returns,
	which is too late to help.
  - **Likely fix: make the generated nodes INTERNAL children** —
	`add_child(node, false, INTERNAL_MODE_BACK)`. Internal children are excluded from
	`get_child_count(false)` and from duplication entirely, which is exactly what these are. Needs
	every walk in `collision.gd` to pass `include_internal = true`, and Convert to Mesh re-checked
	(it duplicates the subtree deliberately).
- [ ] **Some node types still cannot be clicked while the map editor is on.** The press ladder yields
	  to the editor by GUESSING what it would pick: `instances_cull_ray` + AABB for
	  `GeometryInstance3D`, icon proximity for lights, and a physics ray for `CollisionObject3D`.
	  Anything that renders nothing AND has no collider — `Marker3D`, `Camera3D`, a bare `Node3D` —
	  is invisible to all three and stays Scene-dock only.
  - The editor's own test is `Node3DEditor::gizmo_bvh_ray_query` + `EditorNode3DGizmo::intersect_ray`.
	Neither is bound to GDScript, so it cannot be mirrored — every version of this is an
	approximation, and three separate ones were wrong before the current shape (a brush behind the
	target, an `AreaLight3D`'s influence AABB, then bodies).
  - **The alternative that ends the guessing**: claim a press ONLY when it hits a brush and pass
	everything else. Costs the drag-in-empty-space draw, which would have to move behind the Brush
	tool or a modifier.
  - Also unverified: whether editor-world physics queries answer at all, the editor never stepping
	physics. If bodies do not select, that is the first thing to check.


- [ ] **A brush nested under another brush is duplicated twice.** `_duplicate_brushes` calls
	  `brush.duplicate()`, which is recursive, AND iterates the inner brush separately — adding that
	  second copy under the ORIGINAL parent. Select both and `Ctrl`+drag and the inner one comes out
	  twice. Narrow (it needs Brush-under-Brush, which nothing encourages) but it is a real defect.
	  The shared-sub-resource half of duplication is already handled — `Collision.reset(copy)` drops
	  the generated subtree so a copy cannot rewrite its original's shapes.
  - Fix is probably to drop any source whose ancestor is also in the source list, the same rule a
	Scene-dock duplicate follows.

- [ ] **Sync Godot grid size** with the plugin's grid size, so orthographic view grids change too.
  - [ ] Try changing how orthographic views render — TrenchBroom shows wireframes there, which
		makes dragging brushes around easier.
- [ ] **Settings panel** to configure the plugin.
- [ ] **Consider making the duck toggle a UI toggle, not a functionality toggle.** Today it turns the
	  whole mode off, including Duckboard's own viewport picking, which hands selection back to the
	  editor — and the editor cannot pick a brush, because a brush's mesh is an unowned child and
	  unowned visuals are invisible to viewport click-picking (verified; `_edit_group_` does not help).
	  So with the toggle off, brushes are selectable only from the Scene dock.
  - The fix that keeps both: let the toggle control the toolbar and the gestures, but keep the
	brush raycast live always, so clicking a brush selects it — and, optionally, switches the mode
	back on. Costs nothing when the mode is on, and removes the only regression the derived-node
	collision model introduces.
  - Care needed: with the mode "off" the viewport must still behave like stock Godot for everything
	that is not a brush click, so this cannot go through the normal STOP path. See the input
	contract in CLAUDE.md.
- [ ] **A rotated or off-grid parent takes the grid away from the brushes under it.** Brushes are
	  ordinary nodes, so nothing stops a user grouping them under a `Node3D` and then rotating or
	  translating that parent to an arbitrary pose. Every snap the plugin performs is world-space,
	  so from that moment on the brushes inside snap to a grid that no longer lines up with their
	  own local axes, and dragging a face produces off-grid geometry. `tests/town.tscn` already has
	  this shape (`Buildings`), it just happens to sit at identity.
  - **Mechanism confirmed** (read, not guessed): `BrushData.set_from_points` snaps in WORLD space
	and converts back — `to_local * Vector3(snappedf(world.x, g), …)`. Under a rotated parent the
	result is a local coordinate that is not on the local grid, so the drift is real geometry, not
	just a display artefact, and nothing corrects it afterwards.
  - Options: snap in the SOLID's own local space instead of world; refuse to edit brushes under a
	non-identity-basis parent and say why; or show it in the status text and leave the user to it.
  - **Leaning local-space.** `set_from_points` already takes `to_world`, so inverting the rule is
	small; it makes a nested brush behave like an unnested one; and it degrades to exactly today's
	behaviour whenever the parent sits at identity, which is every existing scene. Refusing to edit
	protects correctness but forbids something users will reasonably want to do.
  - **Non-uniform parent SCALE is a separate question and probably wants refusing outright.** The
	mesh renders scaled and collision scales with it (verified: a parent at (2,1,0.5) gives the body
	that world scale while the hull's own points still span (1,1,1) — the hull is local, the physics
	server applies the chain), but `grid_size` stops meaning anything in that subtree and a
	non-uniformly scaled convex hull is where Jolt is least well behaved.

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

Shipped: export-time stripping (`export_strip.gd`, an `EditorExportPlugin` behind a default-on
export option) and *Convert Scene to Plain Nodes* under Project → Tools — both riding the one
builder, `Brush.to_plain_nodes`, which now bakes the RUNTIME mesh (nodraw dropped, no overlay)
from an explicit pose so it works on the detached scenes export customization hands over. The
TODO entry that used to sit here assumed the mesh was serialized into the `.tscn`; it is not any
more (it hangs off an unowned generated child), so the "gate the `_ready` rebuild on editor hint"
half died — a runtime rebuild is the designed behaviour for unstripped play, and the export bake
is what removes it from shipped builds. What is still open:

- [ ] **Verify in the live editor and against a real export preset.** The headless harness covers
	  the detached strip against `tests/town.tscn` (47 solids replaced, ownership intact, pack
	  clean, nested Stairs/StairsCollider handled); it cannot cover the whole-scene convert's
	  undo/redo (needs `EditorInterface`), the export option surfacing per preset, the
	  customization cache (bump `STRIP_VERSION` when iterating on the strip), or the file-skip
	  actually thinning the `.pck`.
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

- Fixed: a group's origin was set once at creation and never again, so editing members walked it off
  into empty space. `Brush.recenter()` covers every solid whatever its piece count, and
  `_close_brush_group` calls it as its own undo step — but only when the edit actually moved the
  origin, or closing an untouched group littered the history. The trap it has to respect:
  `_lock_transform` must be re-based immediately after the move, or the DEFERRED transform
  notification measures a delta and texture lock compensates for a movement that never happened.
- [ ] **The group-scope checks sit at the BOTTOM of `_forward_3d_gui_input`**, and every tool branch
	returns before reaching them — so each tool has to opt into "select a member", "close on a press
	outside" and "double-click to open" by hand. This has already produced three separate bugs, one
	per behaviour. Invert it: run the group checks *before* the tool dispatch and let tools opt out.
- [ ] Godot's own selection (the Scene dock) still sees the whole scene while a group is open.
- [ ] A UV drag re-runs the full cull even though a UV change cannot alter which faces are hidden.
	**The universal brush did NOT fix this**, though this entry predicted it would: a UV write now
	lands on one piece's face data rather than reassigning a member list, but it still goes through
	`Brush.piece_changed()`, which invalidates `_surfaces` along with everything else. Splitting
	that invalidator into "geometry changed" and "mapping changed" is the actual fix, and it is
	small now that there is one of them.
- [ ] Fragment culling can leave **T-junctions** — a fragment edge meeting a neighbour's face away
	from its vertices — which shows as a hairline crack under lighting. Watch for it on lit geometry
	before deciding whether it needs welding.
- [ ] The wash spares the group's **box**, not its geometry, so a brush poking into that box escapes
	the wash too. Reads as intended in practice; only ever generous around concave groups.

## Linked groups

- [ ] **Ctrl+Shift+D makes a LINKED duplicate: editing any instance edits all of them.** TrenchBroom's
	  linked groups, and the feature that makes a repeated thing — a window, a pillar, a lamp post —
	  worth building once. Each instance keeps its own `Transform3D` and nothing else of its own; the
	  geometry is shared, so a change to one lands in every copy in the same undo step.
  - **The model already fits.** A solid is one node whose `pieces` array is the source of
	truth and whose mesh is derived, and pieces are held in the node's LOCAL frame precisely so its
	transform stays meaningful. Two linked instances are therefore *the same `pieces` value
	under two transforms* — the shared payload is exactly one property, and the mesh, the collision
	shapes and the occluder all re-derive per instance for free from the existing setter.
  - **Identity is a `link_id: StringName`, not a node reference.** `@export_storage` on
	`DuckboardSolid`, empty meaning unlinked, minted on the source the first time it is
	linked-duplicated. A NodePath or an object reference cannot do the job: instances get reparented,
	copy/pasted between scenes, and deleted, and the set has to survive all three. An id also makes
	"is this linked" a local question — no scan needed to draw the cue — while the propagation scan
	stays a cheap walk of the edited scene.
  - **Propagation belongs in the undo action, not in the setter.** The `members` setter looks like the
	obvious choke point, and it is the wrong one: undo/redo replays through `add_do_property`, which
	writes the property directly, so a setter-side fan-out would re-run on every redo and record
	nothing on undo. It has to be the writer that fans out — one host helper that takes the undo/redo
	and the new value and adds do/undo properties for **every** member of the link set inside the same
	`create_action`. Miss one path and Ctrl+Z restores one instance while its twins keep the new shape,
	which is a desync you do not see until you look at the other end of the level. Today's write sites:
	`duckboard.gd:2774`, `:3817`, `:4074`, `:4133` and the group-edit fold-back at `:6142`.
  - **`recenter()` is the trap.** It walks the origin into the geometry by writing members *and*
	moving the node — so run on one instance it shifts the shared members while only that instance's
	transform compensates, and every other copy jumps by the offset. Propagate it as a paired write:
	the same members to all, and each instance's own transform moved by the same local offset. Cheap,
	since `recenter()` already computes that offset — but it has to be deliberate, and the DEFERRED
	transform notification / `_lock_transform` re-base hazard noted above applies once per instance.
  - **What must NOT propagate:** transform, name, and the palette-copy settings (`grid_size`,
	`texture_lock`, `uv_lock`) which are per-node snapshots of global state, not statements about the
	solid. Collision needs no rule — it is derived from members, so it rebuilds per instance already.
  - **Decide what a shared UV means.** Member face dicts keep their U/V axes and offset in WORLD
	space, so the identical payload at a different position textures differently — the same
	world-projection every unlocked move produces today. Consistent, and probably right; TrenchBroom
	instead keeps alignment identical across instances. Pick one knowingly rather than discovering it.
  - **UI.** A cue that a solid is linked (the purple bounds already discriminate a group, so this
	wants its own colour or a badge — see the icon conventions), plus *Select All Linked* and *Break
	Link*, the latter being a clear of `link_id` over the selection. A palette button beside Duplicate
	(`ui/tool_palette.gd:73`) and a `"duplicate_linked"` entry beside `"duplicate"`
	(`shortcuts.gd:52`). Check Ctrl+Shift+D against the editor's own bindings, and remember
	`AFTER_GUI_INPUT_STOP` alone does not claim a shortcut — see the input contract in CLAUDE.md.
  - **Why not just instance a `.tscn`.** Godot already gives shared editing that way, and it stays the
	honest answer for a prop reused across levels — but the edit happens in another scene tab, the
	instance is override-only in place, and it costs a file per group. This feature is the
	TrenchBroom gesture: duplicate where you stand and edit either copy in the same viewport. Worth a
	README line naming both.
  - **It is really linked *solids*.** A single brush repeated is the same wish, so `link_id` goes on
	`DuckboardSolid` from the start and the shared payload becomes `pieces` when the universal brush
	below collapses the two types — at which point this stops being a group feature entirely. Nothing
	is needed for export: a linked set collapses to N independent `MeshInstance3D`s, the link leaving
	with the script, which is the correct outcome.

## The universal brush

**One node type holding one or more convex solids**, replacing `Brush` + `BrushGroup` + the
`DuckboardSolid` parent. A solid with one piece behaves as a brush does today; one with several
behaves as a group (purple bounds, open/close to edit members). Mostly a user-experience change —
"a group is a brush that happens to contain several" rather than a separate kind of thing — but the
back end is where it pays for itself, because the split it removes is already being erased at
runtime by the kernel layer.

**The evidence it is worth doing**, gathered before committing to it:

  - A member is **already a `Brush`, serialized badly.** `members` stores `world_faces()` output —
	`{plane, u, v, offset, tex, material, points}` per face — which is planes + face_data plus a baked
	polygon cache. In `tests/town.tscn` those `points` arrays are **36% of the file** (84,910 of
	234,015 chars across 709 arrays), and they are pure derived data a `Brush` re-derives on load
	rather than storing.
  - The round trip is **already lossy**: `world_faces()` skips planes that bound nothing, so
	`Brush → member → kernel → Brush` cannot preserve a brush's exact plane list. Storing planes
	verbatim is strictly more faithful.
  - Logic is **knowingly written twice** — `_lock_uvs`, `_carry_uv_axes`, `recenter`,
	`_apply_grid_overlay`, `_sync_derived`. `brush_group.gd:402` says outright that the UV carry is
	"restated here rather than borrowed", because a group's faces are data and a brush's are arrays.
	A shared piece type deletes that reason.

Two steps, separable. Step 1 is where the payoff is and carries none of step 2's risk.

- [x] **Step 1 — extract `BrushData` from `brush.gd`.** Shipped. The planes, the face data and the pure
	  geometry/UV math (`face_polygon`, `get_vertices`, `get_edges`, `clip_by`, `set_from_points`,
	  `_hull_planes`, `_carry_face_data`, the per-face UV API) move to a piece type that knows nothing
	  about nodes. What stays on the node: transform, mesh bake, collision, occluder, grid overlay —
	  everything that needs a place in the scene tree.
  - **`RefCounted` with dict serialization, NOT `Resource`.** A `Resource`-typed array under
	`@export_storage` writes a `[sub_resource]` block per piece into the `.tscn`, and `duplicate()`
	shares sub-resources — the same footgun already documented in `DuckboardSolid.to_plain_nodes`,
	where a converted `CollisionShape3D` left sharing its shape would be silently rewritten later.
  - **Cost, measured.** Roughly 230 call sites outside `brush.gd` touch brush internals: `.planes`
	×57, `.face_data` ×35, `world_faces()` ×26, `set_world_faces` ×18, `set_from_points` ×18,
	`face_polygon` ×21, the per-face UV API ×35, `get_vertices`/`get_edges`/`clip_by` ×21 — plus 31
	`global_transform` reads in `tools/`. Tools hold a `Node3D` and call `node.clip_by(p)` today;
	they would hold a `(node, piece)` pair or a handle. That is the whole job.
  - Worth doing even if step 2 never happens: it removes the duplicated implementations above and a
	third of the scene file, and it is what stabilises the geometry API before the GDExtension port
	(see 1.0 — porting a moving target twice is the trap named there).

- [x] **Step 2 — collapse `Brush` and `BrushGroup` into one node** holding `pieces: Array[BrushData]`.
	Shipped, and `BrushGroup` is deleted outright rather than left as a shim: the scene re-saved
	its geometry as `pieces` through the compat class, so nothing needed the class to load. What
	arrived beyond the plan: `BrushPiece`, the `(brush, index)` pair the tools hold; a plugin-side
	piece selection, because the editor's selection holds nodes and a member is no longer one; and
	a move that translates a piece's planes rather than the node.
	  Mostly deletion once step 1 has landed.
  - **What goes: the whole kernel layer.** `kernel_for`, `kernels`, `kernel_index`,
	`set_kernels_visible`, `read_back_kernels`, `_refresh_kernels`, `_drop_kernels`, `_kernel_pose`,
	`_kernels_shown`, plus the host's `_group_of_kernel`, `_selectable_of`, `_snapshot_kernel_groups`,
	`_fold_kernel_writes`, `_release_idle_kernels` and the `_group_drag` begin/end wrapped around
	rotate, scale, shear and flip. The kernels exist only to make a member reachable through the brush
	code path; a piece already is one.
  - Six selection helpers were to collapse to "two or three". In practice only `_scene_groups`
	went; the rest survive because they answer genuinely different questions once a group is a
	brush — which nodes are selected, which pieces a tool may reshape, which a whole-object gesture
	may act on. `_selected_transformables` is now a one-line alias and could go.
  - **The purple bounds are the discriminator, and they already exist** —
	`_draw_group_bounds` (`duckboard.gd:3527`) draws `Palette.TB_PURPLE` on selection. That is what
	answers the one real hazard here: a CSG subtract turning a one-piece solid into a several-piece
	one changes how the tools behave, and the cue has to say so. It fires at the right moment, since
	the result of an op is selected.
	- Draw **both** for a multi-piece solid — the face-accurate wireframe *and* the purple box.
	  Today the box replaces the wireframe, which is right when a group is a different kind of thing
	  and a regression when it is "still just a brush".
	- Say why in the status hint when a tool is greyed for a multi-piece solid ("5 pieces —
	  double-click to open"). The box says what it is; it does not say why the tool went dead.
	- Keep it selection-only. Bounds that follow the cursor lit up during ordinary mouselook — see
	  the reasoning at `duckboard.gd:3418`.
  - **What it does not fix**, so nobody expects it to: groups stay flat (though *unrepresentable*
	rather than *refused*, since a `BrushData` is not a node — which matches the preference stated
	elsewhere in this file); the open/close ritual survives, being about picking and isolation rather
	than about types; and CSG on a multi-piece solid is still genuinely hard, so it keeps refusing.

- [ ] **The two occluder rules want unifying, but not during a refactor.** A loose brush filters its
	  shell per FACE (`Brush._face_polygons` → `face_occludes`), so an untextured face is nodraw and
	  opens a hole. A group filters per MEMBER (`SolidSet.occludes`) and KEEPS untextured faces,
	  because in a group they are usually buried between members and dropping them would perforate the
	  room from the inside out. Both are right for their case, and a universal solid has to pick per
	  piece count, which is what it does today.
  - The tempting unification is what the group's own doc is really saying: **a buried face still
	occludes, an exposed untextured one does not.** That reduces to the brush rule at one piece and to
	the group rule wherever members touch, with no piece-count branch at all.
  - What stops it being mechanical: the shell is built from MERGED pieces, whose faces are not the
	members' faces, so "is this face buried" has nowhere to attach. It would mean either filtering
	before the merge by testing each face against the other members (the cull already computes exactly
	that — see `SolidSet.visible_fragments`), or building the shell from the cull instead of from the
	merge and giving up the coarsening. Worth measuring before choosing.

- [x] **Versioning is per SOLID, not per scene.** Shipped exactly as argued, `data_version`
	defaulting to 0 so it always serializes. Tempting to stamp the scene once, but it cannot
	  work and the reason is load order: **property setters run during deserialization, while the node
	  is still out of the tree** — stated outright at `duckboard_solid.gd:256`, and the whole
	  `_lock_transform` ordering hazard at `brush.gd:253` exists because of it. At the moment `pieces`
	  is being decoded the solid has no parent, so a scene-root stamp is unreadable at precisely the
	  point it would be needed to interpret the bytes.
  - Second, independent reason: **solids travel between scenes.** Paste a brush from one scene into
	another, instance a `.tscn` of props into a level, keep a brush in its own file — and a per-scene
	stamp claims one version while a pasted payload is another, with the stamp on the wrong object to
	repair it. A per-solid version is carried by the thing it describes and cannot desynchronize from
	it. The same distinction `collision_type` and `grid_size` already draw: a statement about what
	THIS solid is, versus palette state that is a copy of a global.
  - Cost is a rounding error — one int across ~28 solids in `town.tscn`, against a change that
	deletes 85KB of `points` from the same file.
  - **The trap that makes per-node versioning look broken.** `PackedScene` omits any property equal
	to the node's default, so `@export_storage var data_version := DATA_VERSION` writes *nothing* for
	a current solid — and the next version ships with a new default, silently re-labelling every
	scene saved under the old one. Default it to `0` instead and stamp the real number whenever
	`pieces` is written: it is then never equal to the default, so it always serializes, and `0`
	unambiguously means "predates versioning".
  - A per-scene marker is only ever advisory ("fully upgraded, skip the scan") and must never decode
	anything. Probably not worth it — a second source of truth that can lie, to save a loop over
	thirty nodes.
  - **No migration from pre-versioning scenes** (decided). The universal brush ships with `pieces` and
	`data_version` from day one; existing scenes get a one-shot manual upgrade or nothing. That drops
	the `planes`/`face_data` setter-aliases and the `brush_group.gd` deprecation shim that
	compatibility would otherwise need, and keeps this a clean minor bump — `extends Brush` survives
	untouched as the documented extension point, since the universal brush *is* `Brush`.

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
  - **The universal brush lands first**, for that exact reason: it is the last change that reshapes
	the geometry API, and it also decides what the port's unit of work IS. Afterwards the thing to
	port is `BrushData` — pure geometry with no node attached, which is the easier and more natural
	C++ boundary than today's `Brush`.
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
