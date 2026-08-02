# TODO

Delivered work is not tracked here — `CHANGELOG.md` records what shipped, and the rationale
behind it lives in the code's `##` doc comments. This file is only what is still open.

## Editor

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
  - Options, none obviously right yet: snap in the parent's space instead of world space; refuse
	to edit brushes under a non-identity-basis parent and say why; or show it in the status text
	and leave the user to it. Worth deciding before the parent-transform case becomes common.

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

- [ ] **Several loose brushes cannot share one body.** Each solid derives its OWN body, so five
	  brushes selected and set to Rigid become five falling objects rather than one crate. The answer
	  today is to GROUP them — a `BrushGroup` is one node, so it is one body with one shape per member,
	  which is exactly the crate — and that is arguably the right answer, since a crate built from five
	  solids IS one object. Worth a line in the README rather than code, unless it proves annoying.
  - Noticed while migrating `tests/town.tscn`, where the old model's one-body-per-selection had been
	used for exactly this. The group there converted cleanly, so the workaround is real.

## Shipping a level

- [ ] **Strip the editing data from exported builds.** A shipped game needs a brush's *mesh*,
	  transform and materials — never its `planes`, `face_data` or `members`, and never the CSG
	  code that derives them. Do it with **no user-facing bake step** (the thing that makes Godot's
	  own CSG nodes annoying): the `.tscn` keeps everything and stays re-editable, and the export
	  is the only place the data disappears.
  - **Two targets, two fixes — don't conflate them.** Playing from the editor (F5) does *not* go
	through the export pipeline, so it loads the scene off disk with the script and the whole
	brush state intact. Export-time stripping fixes the shipped `.pck`; only a runtime guard fixes
	F5. `OS.has_feature` tells them apart: editor `editor_hint`, F5 `editor_runtime`, exported
	`template`.
  - **Runtime half (do first, it's free).** `_ready` (`brush.gd:193`) calls `_prune_planes()` /
	`_rebuild()`, and `_build_mesh` ends with `mesh = array_mesh` (`brush.gd:1409`) — so the
	`ArrayMesh` is *both* serialised into the `.tscn` and recomputed from the planes at every
	level load. Gate that rebuild on `Engine.is_editor_hint()` and the stored mesh becomes
	authoritative at runtime. Same rule the group design already commits to (keep the baked mesh
	in the `.tscn`).
  - **Export half.** An `EditorExportPlugin` (registered from `duckboard.gd` with
	`add_export_plugin()`), `_begin_customize_scenes()` → `true`. The engine loads each
	`PackedScene`, instantiates it with `GEN_EDIT_STATE_INSTANCE`, hands the live tree to
	`_customize_scene()`, then re-packs *that* — the file on disk is never touched. For each
	`Brush` / `BrushGroup` whose `owner` is the scene root: null `material_overlay`, then
	`set_script(null)`. The node collapses to a plain `MeshInstance3D` keeping name, transform,
	mesh and surface materials, while `planes` / `face_data` / `members` and the whole
	`brush.gd` → `csg.gd` / `shape_builder.gd` preload chain stop being referenced. With nothing
	referencing them, `_export_file()` + `skip()` can then drop all of `addons/duckboard/`
	**except `textures/__empty.png`** — that PNG is a genuine runtime dependency (default albedo
	for untextured faces); `brush_face.gdshader` is clip-preview only and `brush_grid.gdshader`
	is overlay only, so both are editor-only.
  - **Make it an export option** (`_get_export_options()`), default on. `set_script(null)` breaks
	any user gameplay code doing `node is Brush`, so that has to be opt-out-able. Variant worth
	weighing: swap to a tiny `DuckboardSurface extends MeshInstance3D` that `Brush` extends,
	instead of nulling — users keep a type to test against and the CSG chain still goes.
  - **Gotchas found while researching, in the order they'll bite:**
	- The grid overlay starts shipping the moment scene customization is enabled. Export
	  re-instantiates the scene, which runs the property setters → `_rebuild()` →
	  `_apply_grid_overlay()`, gated only on `Engine.is_editor_hint()` — **true** during export.
	  `PackedScene.pack()` does not emit `NOTIFICATION_EDITOR_PRE_SAVE`, so the existing strip
	  (`brush.gd:209`) never fires. Null it explicitly in `_customize_scene`.
	- Exports are cached per configuration hash: scenes are only re-customized if modified since
	  the last export, and editing the plugin script does *not* invalidate that. Bump a version
	  const inside `_get_customization_configuration_hash()` while iterating or you'll debug a
	  stale export.
	- `pack()` drops any node whose `owner` isn't the scene root — set it on anything added.
	- Skip nodes with `owner != scene_root` (they came from an instanced sub-scene; editing them
	  in the parent only records overrides, and their own file gets customized on its own pass).
	- Instantiation at export runs setters but not `_ready()` — the tree is never entered.
	- One-click deploy *does* go through export; F5 does not.
  - Godot has no built-in per-node "exclude from build" flag; the export plugin is the sanctioned
	route (godot-proposals discussion #14979). The alternative — telling users to exclude
	`addons/duckboard/*` in the export preset's Resources tab — is manual, per-preset, and breaks
	the scene if the brushes still carry their script, so it's a fallback at best.
  - It is **not a second addon**. `EditorExportPlugin` has to be its own class — GDScript has no
	multiple inheritance, so it cannot be `duckboard.gd` itself — but it is one small file the host
	instantiates and registers in `_enter_tree`, dropped in `_exit_tree`, exactly like every other
	helper the host owns. Nothing extra for a user to enable. It does not belong in `io/` (that is
	pure text↔geometry); root, beside `group_ops.gd`.
  - **Collision needs nothing from it.** The bodies and shapes are ordinary engine nodes already in
	the `.tscn`, so they survive script-stripping untouched — which is one of the things the earlier
	derive-at-load design would have made this plugin responsible for.

- [ ] **"Convert to Plain Nodes" — the way OUT of Duckboard.** The same transformation the export
	  performs, but applied to the LIVE edited scene through undo/redo instead of to an in-memory
	  copy: brushes collapse to plain `MeshInstance3D`, scripts nulled, and the addon can be deleted
	  afterwards without the level noticing. The bodies and shapes are already plain nodes and simply
	  stay put. One `static func` transformation with two callers — export and this — so the two
	  cannot drift.
  - **Build it BEFORE the export plugin, not after.** It is the export plugin's test harness: it
	shows exactly what a shipped scene will contain, visibly, in the editor, instead of leaving
	that to be debugged through a per-configuration-hash export cache that does not invalidate when
	the plugin script changes (see the gotcha above), and it is how the stripping gets checked
	against `tests/town.tscn` with real eyes on it.
  - Worth it on its own, though: an addon that can eject to plain engine nodes at any time is a far
	easier one to adopt, and it is the honest answer to "what happens to my level if this project
	stops, or Godot 5 lands". Earns a README line.
  - One-way, so it wants a confirmation dialog and a "Save As first" nudge, and it belongs under
	Project → Tools (`add_tool_menu_item`) rather than on the palette — a destructive whole-scene
	operation is not a brush gesture. Do NOT call it "Bake": the project's whole pitch is that there
	is no bake step, and this is an exit, not a step anyone must take.

## Brush groups — known limitations

Groups shipped in 0.2.0. What's left, in rough priority order:

- Fixed: a group's origin was set once at creation and never again, so editing members walked it off
  into empty space. `BrushGroup.recenter()` mirrors `Brush.recenter()`, and `_close_brush_group`
  calls it as its own undo step. Two traps it has to respect, both found the hard way:
  `transform_faces` takes ONE solid's faces, so it is applied per member rather than to `members`;
  and `_lock_transform` must be re-based immediately after the move, or the DEFERRED transform
  notification measures a delta and texture lock compensates for a movement that never happened.
- [ ] **The group-scope checks sit at the BOTTOM of `_forward_3d_gui_input`**, and every tool branch
	returns before reaching them — so each tool has to opt into "select a member", "close on a press
	outside" and "double-click to open" by hand. This has already produced three separate bugs, one
	per behaviour. Invert it: run the group checks *before* the tool dispatch and let tools opt out.
- [ ] Godot's own selection (the Scene dock) still sees the whole scene while a group is open.
- [ ] A UV drag folds into `members` like any other edit, so it re-runs the full cull even though a
	UV change cannot alter which faces are hidden. Likely to fall out of the universal brush below,
	where a UV change writes to one piece's face data rather than reassigning the whole member list.
- [ ] Fragment culling can leave **T-junctions** — a fragment edge meeting a neighbour's face away
	from its vertices — which shows as a hairline crack under lighting. Watch for it on lit geometry
	before deciding whether it needs welding.
- [ ] The wash spares the group's **box**, not its geometry, so a brush poking into that box escapes
	the wash too. Reads as intended in practice; only ever generous around concave groups.

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

- [ ] **Step 1 — extract `BrushData` from `brush.gd`.** The planes, the face data and the pure
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

- [ ] **Step 2 — collapse `Brush` and `BrushGroup` into one node** holding `pieces: Array[BrushData]`.
	  Mostly deletion once step 1 has landed.
  - **What goes: the whole kernel layer.** `kernel_for`, `kernels`, `kernel_index`,
	`set_kernels_visible`, `read_back_kernels`, `_refresh_kernels`, `_drop_kernels`, `_kernel_pose`,
	`_kernels_shown`, plus the host's `_group_of_kernel`, `_selectable_of`, `_snapshot_kernel_groups`,
	`_fold_kernel_writes`, `_release_idle_kernels` and the `_group_drag` begin/end wrapped around
	rotate, scale, shear and flip. The kernels exist only to make a member reachable through the brush
	code path; a piece already is one.
  - Six selection helpers (`_selected_brushes`, `_selected_groups`, `_selected_geometry`,
	`_selected_transformables`, `_scene_brushes`, `_scene_groups`) collapse to two or three.
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

- [ ] **Versioning is per SOLID, not per scene.** Tempting to stamp the scene once, but it cannot
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
