# TODO

## Core

- [x] **Rename the plugin** — it's now called **duckboard**.
  - [x] Display name, description, author, version (`plugin.cfg`), and the editor-layout key.
  - [x] Renamed the `addons/brush` directory to `addons/duckboard`, rewriting `project.godot`,
		every `preload`, `main.tscn`'s ext_resources and the `.import` sidecars. The `.uid` files
		moved with it, so existing scene references resolve unchanged.
  - [x] User scripts: attaching a script REPLACES `brush.gd` and the node stops being a brush.
		Documented `extends Brush` (with `super()` in `_ready`) as the supported route — it works
		because the tools test `node is Brush`, which matches subclasses. The plugin warns on
		scene load about nodes that still carry `planes` but have lost the script.
  - [x] The files inside are still called `brush*.gd` — worth renaming only if it stops reading
		as "the brush implementation", which is what they are.
- [x] **Custom node class `Brush`** — `class_name Brush` plus `add_custom_type`, so it appears in
	  the Create Node dialog with an icon and the Scene dock names it. The plugin now asks
	  `node is Brush` instead of comparing `get_script()` against a preload.
- [x] **Texture picker inspector** — set textures on faces and configure their UVs. Right dock,
	  modelled on TrenchBroom's Face tab.
  - [x] **Stage 1 — material browser.** `face_dock.gd`: scans `res://textures/`, thumbnail grid
		with search, click assigns to the target faces (the face selection, or all faces of
		selected brushes) as one undo step. Dock is a pure view; the plugin owns selection + undo.
  - [x] **Drag textures onto brushes + auto-adoption.** A texture (or material — its albedo is
		taken) dragged from the FileSystem dock onto a brush paints the face under the cursor —
		or, with SHIFT held, every face of that brush — as one undo step, with a yellow filled
		highlight (face or whole brush) marking the landing spot during the drag.
		(`viewport_drop.gd`: an invisible per-viewport catcher that claims the mouse only while a
		brush face would take the drop, so Godot's own material drop still works on non-brush
		meshes.) Assigning a texture also clears any material_override / surface overrides on the
		brush — strays from Godot's built-in drop that would paint over the per-face materials.
		Any texture the map uses that the scan doesn't cover is auto-adopted into the browser and
		remembered per-project in `duckboard/textures/loose` (ProjectSettings, so it travels
		through VCS). Later: per-scene filters on top of the per-project list, drops into the
		dock itself, and "add folder as collection".
  - [x] **Stage 2 — numeric fields** (offset X/Y, scale X/Y, angle). Offset/Scale `Vector2Field`s
		and an Angle `EditorSpinSlider` (wraps 0–360°) in the dock, with "multi" overlays for mixed
		selections; dock signals `uv_offset/scale/angle_changed` → plugin `_apply_uv(...)` as undo
		steps. No new per-face storage — the math from the ParallelUVCoordSystem research:
		- scale ← from axis LENGTH (TB: `scale = k / (len * texSize)`; ours folds it into len).
		- offset ← our `_face_offset` (tile units; multiply by texture px for TB-style texels).
		- angle ← signed CCW angle about the face normal from the BASE u-axis to our u-axis; set
		  angle rotates the axes from base by that delta (`quat(normal, radians)`).
		- **Base axis: the CONTINUOUS `computeInitialAxes(normal)` (Z-dom → seed world-up, else
		  world-forward), NOT our paraxial `_uv_axes` table** — the table jumps at 45°, so on a
		  rotated brush the displayed angle would flicker as a face crosses the boundary.
		- flip H/V = negate a scale component (mirror an axis). reset = axes back to base.
  - [x] **Stage 3 — common buttons**: Reset UV alignment, Reset to world-aligned, Flip U, Flip V
		(`_build_uv_buttons`; reset in `brush.gd`, flip as a negative scale component).
		**Fit: deliberately not implemented.**
  - [x] **Stage 4 — the UV canvas** — tiled surface + face outline, plus interactive drag / rotate
		/ scale handles (`offset_dragged`, `rotate_started/dragged`, `scale_started/dragged`).
		Renders the actual per-face **material** (not just its albedo) via an offscreen SubViewport
		snapshot, re-rendered only when the material changes; textures drawn directly.
  - [x] **Materials (godot-original, not a TB feature).** A face wears a "surface" — a `Texture2D`
		(wrapped in a `StandardMaterial3D` as before) or a whole `Material` used verbatim. The
		browser scans and shows materials as sphere thumbnails alongside textures; dropping/picking
		a material replaces the face's material, putting a texture back restores a
		`StandardMaterial3D`. `set_face_material` syncs the texture slot to the material albedo so
		`face_data` stays coherent, and `face_surface()` exposes either.
- [x] **Multi-brush tools** — make tools work on multiple selected brushes, like TrenchBroom.
  - [x] Move, scale, shear, rotate, clip, flip, duplicate already act on the whole selection.
  - [x] Vertex / edge / face reshaping now moves the handle on **every** selected brush that
		shares it, matched in world space (corner by position, edge by both endpoints, face by
		world plane). Stops seams tearing open between abutting brushes.
  - [x] **CTRL+click** toggles a brush in the selection (TrenchBroom's binding; Godot's SHIFT is
		reserved for face selection). Coexists with CTRL+drag-duplicate by deciding on release.
  - [x] **Handle selection sets** — click selects a handle, CTRL+click adds/removes, and dragging
		any of them moves the whole set. All three tools share one model: a set of world
		positions, resolved to corner indices per brush and translated by one snapped delta.
- [x] **Tool properties next to the spatial toolbar** — some tools need options, added to the 3D
	  editor's top toolbar (`CONTAINER_SPATIAL_EDITOR_MENU`), each shown only while its tool is active
	  and a brush is selected. The bars hold no geometry state — they emit signals and the plugin owns
	  the transform, pushing live values back in.
  - [x] Create brush tool (default).
  - [x] Scale (`scale_bar.gd`) — "to size" (target bounding box in TB units) or "to factors"
		(per-axis multipliers); the plugin pre-fills the live size.
  - [x] Rotate (`rotate_bar.gd`) — a pivot Center (TB units, with Reset to the selection centre) and
		a one-shot "Rotate by N° about axis" Apply.

## Minor

- [x] **Shift-select face** (good for texture picking) and drag the face (similar to face mode).
  - Decided: full TrenchBroom modifier scheme — CTRL multi-selects brushes, SHIFT selects faces.
	Only applies while map-editor mode is on, so Godot's own bindings return when it's off.
  - [x] CTRL half done (see above).
  - [x] Brush selected + SHIFT + hover a face → that face's edges turn yellow.
  - [x] While yellow, drag → moves the face's PLANE along its own normal (TrenchBroom "resize
		brush"), and the hull re-derives from the intersection of half-spaces — so the top of a
		clipped pyramid slid up follows the slopes to a point, rather than merely lengthening.
		Guarded so a face driven past the far side clamps instead of erasing the brush. Texture lock
		and UV lock are both ignored for this move. Requires the brush to be selected, so a stray
		SHIFT+drag can't silently reshape geometry you never picked.
  - [x] **CTRL+SHIFT+drag** a face is a NEW-brush gesture whose direction is decided on release, so a
		single drag can swing outward and inward freely. OUTWARD extrudes a new brush — bounded by the
		source's NEIGHBOUR planes (it follows the taper to a point, not a straight cuboid) and
		inheriting the source's face looks, like TrenchBroom (create the brush, then resize it). INWARD
		SPLITS the brush at the cut plane: the source keeps the far part and the slab becomes its own
		new brush, as one undo step. Guarded both ways so it can never consume the whole brush.
		- The source is **never touched live** while dragging. OUTWARD shows the new brush for real: a
		  live, fully-textured preview Brush (unowned, never saved) grows as you drag, committed on
		  release. INWARD keeps the source whole and previews just the **cutting face** — the slice the
		  moving plane makes through the solid, as a yellow outline — so it reads as a pending cut, and
		  the split runs on release. No grey/placeholder ghost in either direction.
  - [x] SHIFT+click a face (whether or not its brush is selected) → the face becomes selected and
		the brush is deselected. Edges red, face tinted red. This is what the texture inspector
		acts on.
  - [x] **CTRL+SHIFT+click** adds a face to the selection — SHIFT picks the level, CTRL says
		"as well as", mirroring brush selection one level up.
  - [x] Face selection is a PARTIAL brush selection: the texture inspector treats several selected
		faces exactly as it treats a whole selected brush, editing them as one set. `_target_faces()`
		yields the explicit `_selected_faces` (or all faces of selected brushes); `_apply_uv` and
		`_on_uv_action` group by node and apply to every face as one undo step, and the dock shows
		"multi" overlays when they differ. The single-face UV canvas stays empty for a multi
		selection by design.
- [ ] **Sync Godot grid size** with the plugin's grid size, so orthographic view grids change too.
  - [ ] Try changing how orthographic views render — TrenchBroom shows wireframes there, which
		makes dragging brushes around easier.
- [x] **`.map` clipboard, both directions** (`map_io.gd`) — CTRL+V pastes TrenchBroom's Valve-220
	  `.map` clipboard text as brushes; CTRL+C copies the selection back out as `.map`. Both fall
	  back to the editor's own binding when there's nothing to act on (unparseable clipboard / empty
	  selection), so Godot's copy/paste still works.
  - Fits our model closely: a `.map` brush is a list of faces, each three plane points plus a
	texture name and UV parameters — our `Brush` is already planes-plus-per-face-data, so faces
	convert directly to/from the CSG blueprint shape.
  - Handles the unit scale (`.map` TB units ÷ 32 = metres), the Z-up↔Y-up axis swap, and the
	Valve-220 explicit-axis UV convention our `face_data` already matches. Winding follows TB's
	`cross(p3-p1, p2-p1)` convention (a centroid guess flipped angled faces); write snaps points to
	0.01u to shed clipping noise; paste lands framed in front of the camera, grid-snapped.
- [x] **CSG operations** (`csg.gd`) — Convex Merge / Subtract / Hollow / Intersect from a dropdown at
	  the foot of the left tool palette, greyed per the selection (Merge/Intersect need ≥2 brushes, or
	  Merge exactly two faces). Merge snaps the pooled point cloud to a fixed noise-scale quantum
	  (`Csg.CLEAN`, NOT the grid) before hulling so coplanar faces stay coplanar (else far-from-origin
	  clipping noise fans one flat quad into a dozen near-coplanar triangles) without the result
	  depending on the grid dropdown or moving genuinely off-grid corners. Selecting exactly two faces
	  routes Merge to `bridge_faces`: the convex hull of both faces' corners, added as a new brush that
	  fills the gap between them (the source brushes are left alone); coplanar faces bound no volume, so
	  it reports "those two faces are coplanar" and does nothing. Plus shape tools on the draw toolbar
	  (`shape_bar.gd` / `shape_builder.gd`): cuboid, stairs, cylinder, cone, with a live ghost of the
	  real shape while dragging and edge/vertex/scalable circle alignment for the round ones.
- [ ] **Settings panel** to configure the plugin.
- [ ] **Bake brushes into a merged mesh.** Combine a selection (or a whole group) of convex
	  brushes into one concave `ArrayMesh` for the shipped level — brushes are the editing
	  representation, the baked mesh is the runtime one.
  - Each brush already produces a per-face `ArrayMesh`; baking is mostly concatenating those
	surfaces into one, merged per material so a level isn't one draw call per face.
  - Open questions to settle when we build it: keep the source brushes (bake to a sibling /
	child, non-destructive) vs. replace them; whether to weld coplanar abutting faces or leave
	them; and how it interacts with the collision item below (a merged concave mesh wants a
	trimesh collider, which is static-only).
  - Cuts BOTH render passes, not just the opaque one. With UVs baked and materials shared,
	opaque draws already batch well (measured: 32 brushes → 15 opaque calls). The remaining cost
	is shadows: a directional light re-draws every caster once per PSSM cascade (4 by default),
	which is where "+73 with the directional light" came from. Merging brushes into fewer
	instances shrinks the shadow-caster count per cascade too — so a baked level is cheaper in
	both the opaque and the shadow pass. (Cheap interim levers that need no baking:
	`directional_shadow_mode` = fewer splits, and `cast_shadow = OFF` on brushes that needn't
	cast.)
- [x] **Extras TrenchBroom lacks** but competing map editors have, e.g. hollow brush (create
	  brushes with thickness to represent the original brush).

## Handle feedback (from testing)

- [x] Hovered vertex/edge/face shows a red ring, and vertices a red-backed position readout in
	  TB units. Edges and faces get no readout — their handle is a derived average, so a
	  coordinate there would name a spot that isn't a feature of the geometry.
- [x] Selected handles draw red; idle ones stay yellow. The ring and readout follow the handle
	  being dragged rather than the cursor.

## 1.0

- [ ] **Port to GDExtension (C++).** For 1.0, `Brush` should be a native node registered in
	  `ClassDB`, exactly like the engine's own — no attached Script resource, so no blue script
	  badge in the Scene dock, and it shows in Create Node as a first-class type. This is *the*
	  reason to do it; the perf gain on the hull solve / clipping is a bonus, not the driver.
  - What ports: `brush.gd` (planes → mesh, hull solve, face clipping, UV carry, texture/UV
	lock). The plugin (`brush_plugin.gd`) can stay GDScript — it's editor tooling, not the node.
  - Cost, eyes open: a per-platform build step (vs. a `.gd` that just works), edit-compile-reload
	instead of hot reload, and porting ~1500 lines of intricate geometry. Do it only when the API
	is stable — porting a moving target twice is the trap.
  - Keep the GDScript `Brush` working until the extension reaches parity, so the editor stays
	usable throughout the port.
  - User extension still works afterwards (`extends Brush` in GDScript over a GDExtension base),
	so the `test.gd` pattern survives — just document the base is now native.

## Brush groups (design — not built yet)

TrenchBroom's `func_group`: several brushes stay individually editable but read as one unit
(purple wireframe AABB). The Godot twist, and the whole point: **a group is one node with one
mesh** — the render-batching win, at rest and at runtime. This *is* the "bake" idea, reframed so
there's **no bake step**: the combined mesh is the group's at-rest representation, so the map is
always already baked, group by group, as you build it. Distinct from **CSG Convex Merge**, which
is the permanent, convex-only, one-brush fusion.

- [ ] **`GroupedBrushes` node** — `extends MeshInstance3D`, `@tool`, `class_name GroupedBrushes`,
	  `@icon("res://addons/duckboard/icons/GroupedBrushes.svg")` (icon already exists, unused).
	  Register like `Brush` (`brush.gd:5-9`) so `node is GroupedBrushes` works in scans and the
	  Scene dock. **Option C** of the research: single leaf node at rest, members materialized only
	  while editing.
  - **At rest (saved/shipped state):** one exported `members: Array` — each entry a member's full
	brush state (`planes` + `face_data` + local transform, what `Brush` already exports). No child
	nodes. Plus one combined `ArrayMesh`, built by lifting the by-surface batch loop
	(`brush.gd:1369-1405`) to iterate **all members**, keying surfaces by texture/material **across
	the whole group** → M draw calls (M = distinct textures), strictly fewer than N separate
	brushes. UVs already bake in world space (`brush.gd:1394-1396`), so cross-member continuity is
	free. **Keep the baked mesh in the `.tscn`** (don't strip it) so runtime loads one mesh with no
	rebuild; `@tool` rebuild fires only in-editor when a member changes.
  - **Open group (editing, transient, never saved):** double-click to open → materialize each
	member as a real `Brush` node (`Brush.new()`, assign state, `owner = null` so it's not
	serialized), hide the combined mesh. All existing tools then work unchanged — everything keys
	on `node is Brush` (`_selected_brushes()`, `duckboard.gd:2017`). Esc / click-outside → read
	members back via `world_faces()`, rebuild combined mesh, free the scratch nodes. Explode↔collapse
	is lossless because `world_faces()`/`set_world_faces()` round-trip exactly (`brush.gd:1057`/`1088`).
  - **Group op:** reuse the `_replace_brushes` house style (`duckboard.gd:763`) — one
	`create_action`: absorb selected brushes into `members`, remove originals, `set_owner(root)`,
	build mesh. **Ungroup op:** instantiate a `Brush` per member (`set_world_faces` group→world),
	parent to root, `set_owner`, delete the group.
  - **Overlay:** purple AABB from the combined mesh `get_aabb()`, drawn in
	`_forward_3d_draw_over_viewport`. (MCP `screenshot_editor` won't show overlay draws — verify in
	the real editor.)
- **Hard parts / risks (where the actual work is):**
  - Group edit-mode state machine — which group is open, enter/exit, and scoping tools to the open
	group's members. A **closed** group is opaque to the `find_children("*","MeshInstance3D")` +
	`node is Brush` scans (members aren't nodes — automatically skipped, correct); an **open**
	group's scratch members *would* appear, so tools must be told to see only the open group.
  - Keep scratch member nodes out of undo history and `owner`-less, or they'd serialize.
  - Runtime-vs-editor duality: baked mesh authoritative at runtime, `members` authoritative
	in-editor; keep them coherent (rebuild-on-edit).
- **Collision + lightmap UV2 come free BECAUSE it's a single mesh — another reason for the design,
  not extra scope.** Godot's own Mesh menu on a `MeshInstance3D` already does "Create Trimesh/Convex
  Collision Sibling" and "Unwrap UV2 for Lightmap/AO", but those act on **one mesh**. So collapsing
  a group to a single mesh is exactly what makes Godot's built-ins apply to it — N separate brushes
  can't use them as a unit. No custom collision/UV2 code needed. (Optional later: convenience
  buttons in the dock that just proxy those Mesh-menu actions on the selected group.)
- **Cross-group batching cap** — batching stops at the group boundary (M draw calls *per group*, M =
  distinct textures), so grouping granularity *is* the batching strategy; a few large groups ship
  fewer draw calls than many tiny ones.
- **Open questions:** nested groups (defer to v2?); closed-group display (AABB only, or AABB +
  faint member wireframes?); enter gesture (double-click vs toolbar button); whether members keep
  stable identity across open/close (affects whether `members` entries carry an id).
- **First slice:** `GroupedBrushes` node + combined-mesh builder + group/ungroup ops (no edit-mode
  yet) — already delivers single-mesh efficiency and non-destructive ungroup. Layer open/close
  edit-mode on top after.

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
