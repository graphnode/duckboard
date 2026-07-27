# TODO

Delivered work is not tracked here — `CHANGELOG.md` records what shipped, and the rationale
behind it lives in the code's `##` doc comments. This file is only what is still open.

## Editor

- [ ] **Sync Godot grid size** with the plugin's grid size, so orthographic view grids change too.
  - [ ] Try changing how orthographic views render — TrenchBroom shows wireframes there, which
		makes dragging brushes around easier.
- [ ] **Settings panel** to configure the plugin.

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

## Brush groups — known limitations

Groups shipped in 0.2.0. What's left, in rough priority order:

- [ ] **The group-scope checks sit at the BOTTOM of `_forward_3d_gui_input`**, and every tool branch
	returns before reaching them — so each tool has to opt into "select a member", "close on a press
	outside" and "double-click to open" by hand. This has already produced three separate bugs, one
	per behaviour. Invert it: run the group checks *before* the tool dispatch and let tools opt out.
- [ ] Godot's own selection (the Scene dock) still sees the whole scene while a group is open.
- [ ] A UV drag folds into `members` like any other edit, so it re-runs the full cull even though a
	UV change cannot alter which faces are hidden.
- [ ] Fragment culling can leave **T-junctions** — a fragment edge meeting a neighbour's face away
	from its vertices — which shows as a hairline crack under lighting. Watch for it on lit geometry
	before deciding whether it needs welding.
- [ ] The wash spares the group's **box**, not its geometry, so a brush poking into that box escapes
	the wash too. Reads as intended in practice; only ever generous around concave groups.

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
