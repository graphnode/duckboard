# Changelog

All notable changes to Duckboard are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- **Editing several members inside an open group works like editing loose brushes.** Three holes
  closed: the *release* of a `Ctrl`+click fell through to the plain-click path and collapsed the
  member selection back to the one piece under the cursor (0.4.0 had fixed the press half only);
  the same fall-through after `Ctrl` on a vertex/edge/face *handle* dropped the other members —
  and the handles just built on them — the moment the button came up; and a plain press on an
  already-picked member collapsed the pick before a drag could begin, so several members could
  never be dragged together. Member picks now also match by piece rather than by handle, so they
  survive a cut or undo renewing the geometry underneath them.
- **Dragging a vertex moves it by whole grid cells, like edges and faces.** The vertex drag snapped
  the cursor point to the grid instead of the movement, so an off-grid corner was yanked onto the
  lattice by the first pixel of drag rather than keeping its offset and stepping cell by cell.

### Removed

- **The internal `DuckboardSolid` base class**, folded into `Brush`. It was the half that `Brush`
  and the old `BrushGroup` had to share; with one node type left it was a name with one subclass —
  and one that appeared in the Create Node dialog, where creating it bare did nothing useful.
  Scenes are unaffected: nodes always carried the `Brush` script.



## [0.4.0] — 2026-08-04

### Added

- **A selected group shows what it is made of.** Its members are outlined faintly inside the purple
  bounds, so how many it holds and where their seams run is visible without opening it, and it now
  gets the guide spikes and dimension labels any brush gets when you hover it — sized to the member
  under the cursor while the group is open, to the whole object while it is closed. Reaching for the
  Vertex, Edge, Face or Clip tool on a closed group says why it does nothing instead of ignoring you.
- **Duckboard's keys are yours to change.** Every tool, operation and command it binds — the tool
  letters, `Ctrl+G`, `Ctrl+C` / `Ctrl+V` and the rest — is now listed under *Editor Settings ▸
  Shortcuts ▸ Duckboard* and can be rebound there, which matters because several of them deliberately
  shadow Godot's own. Texture Lock ships unbound so you can give it a key, and the palette's tooltips
  show whatever you have set.
- **Nudge the selection with the arrow keys.** Each press moves it one grid cell in the direction
  the key points *on screen*, so it stays intuitive from any camera angle, and `PageUp` / `PageDown`
  move it straight up and down. Hold a key to keep going — the whole run undoes as one step.
  Groups nudge as a single object, exactly as they drag.
- **Box-select handles in the Vertex, Edge and Face tools.** Drag from anywhere you haven't grabbed a
  handle and a rectangle sweeps up every dot inside it, so picking a whole row of faces is one drag
  rather than a `Ctrl`+click each. The dots light as the band crosses them and let go again if you
  pull back off; `Ctrl`+drag adds to what you had. It takes handles and nothing else — the editor's
  own rubber band, which swept up lights, markers and anything else it crossed, no longer runs while
  a tool is up.
- **A plain click means the same thing with a tool up as without.** Clicking a solid selects it,
  clicking empty space drops the selection, and a second click on empty space leaves the open group.
  With a tool active a click used to fall through to nothing at all, so changing which brush you were
  reshaping meant switching the tool off and back on.
- **`Ctrl`+click still selects while a tool is up.** With Vertex, Edge, Face, Scale, Rotate or Shear
  active, `Ctrl`+clicking a brush or group that the tool wanted nothing to do with adds it to the
  selection — or drops it if it was in there — instead of doing nothing at all. Handles already
  picked are kept, so you can bring another brush into a reshape without starting over. `Ctrl` on a
  handle still builds the handle selection, as before.
- **Grid sizes on the number row.** `1` to `9` select 1, 2, 4 ... 256 units directly, instead of
  walking there with `+` and `-`. The keypad is left to Godot's view shortcuts, and the three sizes
  finer than one unit stay where they were, one `-` below.
- **`Ctrl+G` groups, `Shift+Ctrl+G` ungroups** — the same pair already in the palette's Group
  dropdown, now without reaching for it.
- **Convert to Mesh — the way out of Duckboard.** A button on every brush and group that replaces it
  with the plain engine nodes it has been deriving all along: a mesh, a body, its collision shapes
  and its occluder, owned this time, so they save in the `.tscn`, show in the Scene dock, and keep
  working with the addon deleted. It is one-way — the planes, the per-face UV axes and the textures
  held as data all go, because plain nodes have nowhere to keep them — but it is a normal undo step,
  so `Ctrl+Z` brings the editable version back until you save over it. The honest answer to "what
  happens to my level if this project stops".
- **Groups survive the TrenchBroom clipboard, both ways.** Copying a selected group writes it as a
  real TrenchBroom group rather than a pile of loose brushes, and pasting brings any TrenchBroom
  *object* in as a Duckboard group — a group, but also a `func_detail`, a door or a trigger, since
  each of those is one thing over there too. TrenchBroom lets groups nest and Duckboard's do not, so
  a nested tree arrives flattened into one group, and worldspawn and layer brushes still come in
  loose. The whole paste is one undo step however it is organised.

### Changed

- **UV editing stopped paying for geometry it does not change.** A drag on the UV canvas — offset,
  rotate or scale — now re-bakes the mesh alone, where every mouse event used to re-derive all the
  face polygons, re-run the hidden-face cull, re-merge the collision pieces and refit the occluder.
  Moving a brush with Texture Lock on skips the same dead work. Collision and occluder updates
  settle once per frame during any reshape drag rather than once per mouse event, and opening a
  scene builds each brush once instead of twice — big levels open noticeably faster and every drag
  is lighter, most of all on groups.
- **Scenes with groups are about half the size.** A group used to save each member's face polygons
  alongside the planes those polygons are derived from — an answer the planes already give, re-derived
  every time it is needed anyway. It is no longer written: re-saving the test map drops it from 375 KB
  to 196 KB, and nothing about the group changes. Existing scenes open exactly as before and are
  written in the smaller form the next time you save; there is nothing to run and nothing to convert.
- **A group's geometry now always matches the planes that define it.** Because those face polygons
  were stored, a member could drift from its own planes and keep rendering the stale copy until
  something edited it — in the test map the worst had wandered 0.12 grid units (about 4 mm). Groups
  are drawn from the planes directly, so what you see is what the solid actually is. A long-untouched
  group may therefore shift very slightly the first time it is loaded; that shift is the correction.

- **The map editor stops taking the transform toolbar.** Turning it on used to force the viewport
  into Select Mode and grey out Move, Rotate and Scale for the whole scene, so Transform Mode (`Q`)
  simply was not available and moving one lamp meant switching the addon off and on around it. The
  buttons are left alone now: what a press does is decided by what it lands on, not by which mode is
  showing. Land on a brush and it is Duckboard's; land on anything else and it is Godot's, tool
  letters included. The viewport still drops to Select Mode while a brush is selected — a transform
  gizmo over geometry you drag directly is only in the way — and returns to your mode as soon as it
  is not.
- **The `Shift` face highlight reaches faces you cannot see.** Run the cursor over a selected
  brush's outline and the highlight swaps to the face hidden behind it, so pushing a wall *away*
  from you is now as direct as pulling it towards you — no orbiting round the back first. Following
  TrenchBroom: with nothing under the cursor at all, the nearest outline still offers its hidden
  face, and anywhere else on a brush the face you can see is picked as before.

- **The grid is drawn in the world now, not on the screen.** Its lines have a real thickness in
  metres, so they take perspective like the walls they sit on — bold up close, finer as the surface
  recedes, the way a grid painted on the floor would look. Before, every line was held at one pixel
  wide however far away it was, and the grid faded out entirely once cells got small on screen,
  which stripped it off distant floors and off any surface seen at a shallow angle — exactly where
  you were sighting along it. Both of those are gone.
- **The grid sits further back.** Its lines are fainter and a grey rather than white, so they read as
  drawn on the texture instead of washing it out.
- **A group collides as few shapes as its shape allows.** Neighbouring members whose combined shape
  is still convex are now fused into one collision hull, so a wall built from five cuboids collides
  as one box instead of five. The volume is identical — a piece is only merged when the merged hull
  encloses nothing neither piece already did, so an L-shaped pair stays two and a 1 cm ledge is not
  quietly filled in. What you built is untouched; only the physics representation gets simpler.
- **A group's purple bounding box is translucent.** At full opacity a room-sized box put twelve solid
  lines across everything behind it.
- **Brushes gained the two buttons groups already had** — *Rebuild Mesh* and *Recenter Origin* — and
  both nodes now show one identical Collision/Visual inspector layout.
- **A group occludes with as few polygons as its shape allows.** A wall of five cuboids now describes
  itself to the occlusion culler with twelve triangles instead of sixty, using the same merged shape
  its collision already does. Those triangles are redrawn every frame, so the saving lands while the
  game runs.

### Fixed

- **Pasting from TrenchBroom keeps textures kept outside `res://textures/`.** Resolving a `.map`
  texture name probed a fixed handful of folders, so a face wearing anything stored elsewhere came
  back untextured — every round trip through TrenchBroom quietly flattened it. The texture browser's
  own list is asked first now, so whatever the browser shows is what a paste can find.
- **Clicking a handle without dragging no longer fills the undo history.** A press and release on a
  Scale, Shear, Vertex, Edge or Face handle arms the gesture, and the release recorded an undo step
  even though nothing had moved — so `Ctrl+Z` had to be pressed repeatedly to get past edits that
  never happened. It could also nudge a solid whose origin sat off its geometry.
- **Undoing a scale or shear on a group puts its origin back.** The geometry returned to its old
  shape but kept the origin the edit had given it, so the group sat off its own centre until it was
  recentred by hand.
- **Ordinary nodes can be clicked again while the map editor is on.** A press that landed on anything
  that was not a brush started drawing and swallowed the click, so selecting a `MeshInstance3D`, a
  light or a marker in the viewport almost never worked — it read as flaky picking rather than as a
  rule. Duckboard now yields a press that lands on a node the editor can select; drawing in thin air,
  and on brushes, is unchanged.
- **Setting a solid to Trigger Volume no longer errors.** Switching to a trigger changes the body and
  drops the occluder at the same moment, and the second step tripped over the first — leaving the
  brush without its generated mesh until something else rebuilt it.
- **The Scale, Rotate and Shear tools can open a group again.** Double-clicking a group entered it
  with the Vertex, Edge and Face tools but did nothing with these three.
- **Undo history says "Ungroup Brushes"**, pairing with the "Group Brushes" the other direction
  records.
- **Group, Ungroup, CSG, paste and Convert to Mesh no longer fill the Output panel with errors**
  about the brushes they had just replaced. Nothing was ever wrong with the result.
- **A see-through member no longer occludes for its whole group.** Glass, water or a grate built into
  a group culled whatever was behind it, exactly as a see-through *brush* did before 0.3.1 — the same
  mistake, one level down.
- **Pushing a face inside a group is undoable.** `Shift`+drag on a member's face, and the
  `Ctrl`+`Shift` inward split, changed the geometry without recording it — `Ctrl+Z` skipped straight
  past the edit to whatever you did before it, and the change was baked in silently when the group
  closed. Both now land as one undo step on the group, the way every other edit made inside an open
  group already did.
- **The Face tool moves the faces you picked, and only those.** With several brushes selected, it
  used to drag every face lying in the same plane as one you had picked — so raising a single floor
  panel raised every floor at that height across the level, none of them lit as selected. Faces at a
  shared seam are two handles: `Ctrl`+click both to move them together.
- **`Shift`+drag extrudes a member's face inside an open group.** The push refused every face of a
  group — including with the group open, where reshaping members is the whole point — and printed
  errors while doing it. A closed group still refuses, like the other reshaping tools: open it first.
- **The Clip tool cuts an open group's members.** It used to reach a group through its first member
  only, so clipping inside a group cut one piece and ignored the rest of what you had selected.
  `Split` on a member now mints the far half as a *new member of the same group*, exactly as a
  loose brush splits into a second brush.
- **CSG operations stopped pretending a group is its first member.** Convex Merge and Subtract now
  read every piece of a selected group; Intersect and Hollow, which have no honest answer for one,
  grey out and say so instead of quietly acting on a single member. Subtract carves *into* a group
  it touches and the group survives it — the cut fragments become its members, so a doorway cut
  into a grouped building leaves the building one object, where it used to be replaced by loose
  fragments of its first member.
- **Grouping a selection that includes a group no longer leaks a copy of its first member**, and the
  Group item is no longer offered for a single selected group, which it counted twice.
- **Right-click ▸ Select Faces / Select Brushes see inside groups** — and so do Replace with… and
  the browser's yellow in-use outline. All four walked each solid's first member only, so a texture
  used anywhere else in a group was invisible to them, and a Replace could neither reach nor undo a
  group's deeper members.
- **`Ctrl`+click builds a member selection inside an open group.** Picking a second member used to
  read as "the group is already selected — drop it", deselecting everything, so exactly one member
  could ever be held and clipping several members at once was unreachable. Un-picking the last
  member is still what drops the group.
- **The clip ghost shows only on the members the cut will touch.** Previewing a clip inside an open
  group checkered the whole group, even members the cut was never going to reach; the checkerboard
  is now scoped to the picked members, exactly as the cut itself is.
- **Dragging a brush no longer leaves Godot's selection rectangle stuck on screen.** The first few
  pixels of a move drag were still visible to the editor, whose own box-select started over them —
  and since the rest of the drag and the release belong to Duckboard, nothing ever told the
  rectangle to go away. Most visible when dragging members inside an open group.
- **A brush drawn inside an open group is no longer washed out.** New geometry lives as a child of
  the group until the close folds it in, and the isolation wash only spared the group's own
  members — so the brush you had just drawn sat white until the group was closed and reopened.

### Removed

- **The per-face texture and UV methods on the `Brush` node** (`set_face_texture`, `get_face_uv`,
  `fit_face_uv` and friends). They silently read and wrote the FIRST convex piece only, which is a
  wrong answer on any group. Face operations live on the piece handles every pick hands you —
  `brush.piece(0)` reaches a lone brush's faces. A stable user-facing scripting API is planned for
  a later version, once the model settles.

## [0.3.1] — 2026-07-30

### Fixed

- **Occlusion no longer hides things you can see through.** An occluder is a claim that light stops
  at a surface, and Duckboard was making that claim for geometry that is never drawn — so scenery
  behind it was culled and simply vanished. Occlusion now follows what actually renders:
  - A brush or group set to **Trigger Volume** generates no occluder at all. Triggers are usually
	invisible — their faces are left Empty — so the worst case was a damage zone across a corridor
	erasing the corridor. The **Occluder** checkbox greys out on one to say so.
  - A solid with **Transparency** above 0 generates no occluder either. That setting makes every
	surface on it see-through at once, so nothing on it can block the view — which is what made
	water cull the pool floor under it.
  - A face left **Empty** no longer contributes. It is already dropped from the mesh in a running
	game, so an occluder over it described a surface that is not there.
  - Neither does a face wearing a **cut-out texture** — a grate or a railing is full of holes by
	design, and blocking the view through one is exactly wrong.

  What is left to you is a see-through **shader**: it cannot be asked whether it is opaque and is
  assumed to be, since the alternative would switch occlusion off for every material-driven wall in
  a level. Turn **Occluder** off on those brushes.

## [0.3.0] — 2026-07-29

### Added

- **Brushes collide, and they do it by themselves.** Every brush and group now carries a
  **Collision** section in the inspector — Type, Layer and Mask, in the same place and under the
  same names as any other physics node. Type is **Static** by default, because a level is walls and
  floors and the alternative is a map you fall through until you notice. Set it to **None** for
  trim, decals and decoration; **Moving Platform** for lifts and doors; **Rigid Body** for props
  that fall. The palette's **Physics** menu sets it on a whole selection at once.
- **A brush is already a convex hull, so its collision is exact rather than approximated** — and it
  is a solid, so fast bodies can't tunnel through it and a character can't end up inside it, both of
  which happen with the trimesh collision a mesh would otherwise give you. A group is better still:
  it collides as one convex piece per member, which is the exact shape of the room rather than a
  guess at it, and members gained or lost change the shapes to match.
- **Nothing is added to your scene tree, and nothing needs baking.** The body and shapes are built
  when the level loads and never saved, so a room of thirty brushes stays thirty nodes in the Scene
  dock and the `.tscn` stays readable. Reshape a brush and its collision follows; move it, group it,
  reparent it, duplicate it, delete it — the collision is part of the brush and goes with it.
- **Trigger volumes.** A fifth collision Type, **Trigger Volume**, builds an `Area3D` instead of a
  body: geometry you walk straight through that your game can ask about. That is what water, lava,
  ladders, damage zones and level exits have always been in a brush map, and until now the only way
  to build one was to hand-author the node the derived model exists to avoid. It is an ordinary
  `Area3D` with ordinary defaults, so `body_entered` and point queries both work on it unchanged —
  Duckboard builds the volume and stops there; what it MEANS is your code's business. Faces left
  Empty make one invisible, the way a trigger usually wants to be.
- **`get_body()` on brushes and groups**, alongside the existing `get_mesh_instance()`. The generated
  body is unowned and so has no inspector, which left everything Duckboard deliberately does not
  decide — a rigid brush's mass, a static one's `PhysicsMaterial`, a trigger's gravity override and
  its `body_entered` signal — with nowhere to be set from. This is where: reach it from an
  `extends Brush` subclass in `_ready()` and configure it in code.
- **Occlusion.** Brushes and groups also generate an `OccluderInstance3D`, on by default, so level
  geometry hides what is behind it and the renderer can skip drawing it. A brush is the ideal
  occluder — closed, convex and low-polygon — so there is no bake step and no simplification to
  tune. Turn **Occluder** off in the Visual section for glass, railings, grates and anything else
  you can see through. Occlusion culling must be enabled in Project Settings → Rendering for any of
  this to take effect; Duckboard won't switch it on for you.
- **Lightmap UV2, without a bake step.** Turn on **Lightmap Uv2** in the Visual section and a solid
  generates the second UV set [LightmapGI] needs, packed into an atlas at the density set by
  **Lightmap Texel Size**. Off by default, since it is a second UV per vertex on every brush and
  costs nothing to nobody who is not lightmapping. Edit it on a multi-selection to set a whole level
  at once.
  - There is nothing to unwrap: a brush's faces are already flat, so they only need packing, which is
	cheap enough to happen inside the ordinary mesh build. That means the UV2 is regenerated with the
	geometry rather than baked and stored, so it can never go stale — and it is deterministic, so the
	same brush produces the same atlas every load. Anything you keep in that coordinate space
	(painted decals, damage maps) stays where you put it, as long as the geometry does.
  - Godot's own **Unwrap UV2** is not used and could not be: it runs xatlas, which ships only in
	editor builds, so it produces nothing at all in an exported game. It is also ~130x slower per
	solid, which matters when the mesh rebuilds as you edit.
  - Charts are laid out with a two-texel gutter, so bilinear filtering cannot bleed one face's
	lighting into its neighbour along every edge in the level.
- **Rendering properties still live on the brush.** Material Override, Cast Shadow, Layers, GI Mode
  and Transparency are in a **Visual** section and behave exactly as they always did, including
  saving with the scene.
- **Transparent pixels are cut out.** A texture carrying transparent pixels now discards them
  instead of drawing them solid. Brushes stay in the opaque render pass, so shadows, sorting and
  the depth pre-pass behave exactly as they do for any solid brush, and only textures that actually
  carry alpha take the discard path.
- **Untextured faces don't render in the running game.** A face still wearing "Empty" is left out
  of the mesh at run time, so the backs of walls and the undersides of floors — anything you never
  got round to texturing — cost nothing to draw. There is no bake step and no special texture to
  learn: the editor still shows the face so you can see and texture it, and the game simply doesn't
  build it. Grouped brushes do the same.
- **Fit texture to face.** A new button in the texture inspector scales the texture to the nearest
  whole number of repeats that spans the face each way and lines the first repeat up with its
  corner, so nothing is left cut off at an edge. Nearest rather than always-up: a face measuring
  just over two repeats gets two slightly stretched ones, not three squashed ones. Rotation is left
  alone, so a texture turned to follow an angled face keeps its angle.
- **The empty texture is now in the browser**, pinned first and labelled "Empty". Every face that
  has never been textured already wears it, and this is the way to put one back to bare — until now
  only undo could. It ships with the addon, so it can't be removed.
- Dragging the origin in the UV canvas snaps to a face **corner**, not just to the crossing of two
  corners' guidelines — which could land somewhere off the face entirely. Scaling snaps a texture
  edge onto a face edge, so a repeat can be lined up with the face exactly.

### Changed

- **A brush is now a `Node3D`, not a `MeshInstance3D`.** It builds the mesh it renders through, as
  well as its body and shapes, and none of them are saved with the scene. Scripts that say
  `extends Brush` keep working and every tool still tests `node is Brush`, but code reaching for
  `MeshInstance3D` members that are not forwarded — `mesh`, `skeleton`, `custom_aabb`, `lod_bias`
  and the visibility-range properties — needs `get_mesh_instance()` to reach the real node.
  Unchanged: `material_override`, `cast_shadow`, `layers`, `gi_mode`, `transparency`, `get_aabb()`
  and the `*_surface_override_material*` methods. The same applies to `BrushGroup`.
- **Godot's own Mesh menu no longer reaches a group.** 0.2.0 noted that a group being a single
  `MeshInstance3D` let that menu — Unwrap UV2 — apply to a whole room at once. The mesh a group
  renders through is now a generated node that is not saved and cannot be selected, so the menu has
  nothing to act on. Nothing is lost by it: its collision generators were already the wrong tool for
  a group (a trimesh built from the merged mesh has holes where buried faces were culled) and
  collision no longer needs them, and **Lightmap Uv2** above replaces the unwrap with one that works
  in an exported game, which that menu's never did.

- **Textures now start at their own size.** A face took one whole repeat per metre whatever the
  image was, so a 64x128 texture was squeezed into a 32x32-unit square and had to be rescaled by
  hand every time. A texture now covers its own pixel count in map units — 64x128 units for that
  one — which is TrenchBroom's scale 1, and the scale shown in the inspector is TrenchBroom's
  number. Swapping a face's texture keeps the scale, so the new one arrives at its own size too.
  Existing brushes are untouched and keep the mapping they were saved with; "Reset UV to world
  aligned" converts one when you want it.
- **Drawing a shape no longer needs a tool.** Drag from empty space with nothing selected and you
  draw, the way TrenchBroom's Simple Shape tool is always live rather than switched on. The shape
  selector rides with the gesture, so cuboid, stairs, cylinder and cone are reachable without
  pressing anything first.
- The tool that places points on existing faces and builds their convex hull — previously the
  Sweep Tool — is now the **Brush Tool**, which is TrenchBroom's own name for it. TrenchBroom has
  since given "sweep" to an unrelated new tool, so the old name would have meant two things.
- It is also now the only brush-creation button on the palette, and `B` activates it, both
  matching TrenchBroom. `B` previously drew shapes, which no longer needs a button at all.
- **Scenes save to about half the size.** Every brush wrote its finished mesh into the `.tscn` —
  every vertex, every UV, and a material for each surface — even though opening a scene rebuilds
  all of it from the planes and face data regardless, so the saved copy was read, built and thrown
  away. It is no longer written. A map is roughly half the file it was, saving and loading move
  less, and the diff for an edit is the geometry you actually changed rather than pages of
  re-serialised vertex data. Brushes with no per-face material override also stop writing an empty
  slot for one. Nothing about a brush changes on screen, and existing scenes shrink the first time
  they are saved.
- **The grid and the lock toggles are no longer stored on each brush.** A brush carried its own
  copy of the grid size and of both lock modes, written into every scene — but there is only ever
  one grid and one pair of modes, set from the palette and applied to everything at once. The saved
  copy is exactly what let brushes disagree: open a map at a different grid and the brushes already
  in it kept the value they were saved with, while anything newly drawn took the palette's, so two
  brushes sitting side by side snapped to different lattices. They are now settings the palette
  owns and pushes, and none of them reach the saved scene at all. `snap_size` and `grid_display`
  were always the same number and have become one `grid_size`; a script extending `Brush` that
  referred to either wants that instead.
- **Box Size is gone, replaced by `set_box()`.** It was only ever read while building a brush that
  had no shape yet, so on one that already existed the field did nothing: typing in it rebuilt the
  same shape from the planes that actually define it. It also kept the size the brush was born
  with, so anything since dragged, clipped or scaled carried a saved number that no longer
  described it. A box is now something a brush is *built as* rather than a property it goes on
  having — from script, `Brush.new()`, `set_box(size)`, then add it to the tree.
- **The inspector no longer offers to edit a brush's geometry.** `planes` and `face_data` on a
  brush, and `members` on a group, are saved exactly as before — nothing can re-derive them — but
  are no longer shown as editable fields. They carry invariants a typed-in value cannot honour:
  outward normals, a bounded convex solid, and per-face arrays that must stay index-aligned to the
  planes. The tools, the texture dock and the UV canvas are how they are meant to change. A group
  keeps its Rebuild Mesh button, which takes no input.

### Fixed

- **The editor's grid stays put on a see-through brush.** With **Transparency** above 0 the brush's
  faces move into the same render pass as the grid drawn over them, and nothing then said which of
  the two came first — so the grid could end up blended *underneath* its own surface, pulsing light
  and dark as anything animated on that surface moved. The grid is now sorted after the face
  explicitly.

- **A group you can stand inside can be clicked again.** Picking gated each group on its bounding
  box before testing its faces, and that gate wanted an entry face in front of the camera — so a
  group large enough to be *in*, a room or a ground plane spanning the level, failed it from every
  position you actually work from. Neither click-select nor `Shift+click` on a face could reach one.

- **A `Shift+drag` that means nothing no longer leaves a selection rectangle across the viewport.**
  Shift is Godot's own "add to selection" modifier, so its viewport opened a rubber-band box over
  any shift-drag Duckboard hadn't claimed — trying to push a face on a brush you haven't selected
  yet, or starting the drag on thin air. The box then stayed painted on screen, because it only
  closes on a release the editor sees and Duckboard had already taken it. Shift now belongs to
  Duckboard for the whole gesture: a chord that means nothing simply does nothing. (Shift+click no
  longer adds a light or other ordinary node to the selection in the viewport — use `Ctrl+click`,
  which is Duckboard's add modifier, or the Scene dock.)

- **Grouping, deleting or running a CSG op on several brushes no longer floods the output with
  "Node not found".** Selecting more than one node puts a MultiNodeEdit in the inspector, which
  tracks them by node path; removing them while it still held those paths logged one error per
  selected brush, per refresh. The operations always worked — the errors were noise, but enough of
  it to bury a real one. The selection is now let go of before the nodes are removed.

- **A moving brush carries its texture with it in the running game.** Textures are projected from
  world space, so a brush that moved while the game ran — a crate on a `RigidBody3D`, a lift, a
  swinging door — slid out from under its own texture, and re-baked its whole mesh every frame it
  moved to do it. Texture lock is an editor question about dragging brushes about; in a running game
  a moving brush is an object, so its texture now travels with it, whichever way the palette button
  happens to be set. Nothing is rebuilt while it moves.

- **A group's origin follows its geometry again.** A group was centred on its contents once, when
  you made it, and never afterwards — so editing its members walked the origin off into empty
  space, leaving the move gizmo to grab at nothing and making a group awkward to place inside a
  `RigidBody3D`. Closing a group now pulls its origin back to the centre of what it holds. Nothing
  moves on screen and textures stay put; only the origin changes, and it is its own undo step.
  There is a **Recenter Origin** button in the inspector for groups that drifted before this.

- **Pressing an unselected member inside an open group now draws, like everywhere else.** With
  nothing selected, a press-and-drag on a member moved it around — inside a group was the one
  place where a drag meant something different from the rest of the editor. It now draws flush
  against the member's face, and a plain click still selects the member.
- **A brush can be drawn into an open group against geometry outside it.** The draw anchor's pick
  was fenced to the group's members like every editing raycast, so a press on an outside floor or
  wall fell through to the flat draw plane. Anchoring on a surface edits nothing, so the anchor
  now sees the whole map — and the new brush still joins the open group.
- **The wash now spares the group's members, not the group's whole box.** Outside geometry that
  merely poked into the open group's overall bounds escaped the wash with it, sitting there at
  full colour and reading as a member. Each member now carries its own exclusion box, so the wash
  reaches right up to the group's actual solids.
- **The Brush tool's snapped outline sits on the grid lines of a 45° face.** The grid shader and
  the point snap broke the dominant-axis tie differently, so on a face rotated to exactly 45° the
  tool snapped its points against one grid projection while the face drew another, and the yellow
  outline floated off the lines it was supposed to sit on. Both now share one tie-break table.
- **Brushes created inside an open group no longer vanish from the tools until the group is
  closed and reopened.** Anything drawn, extruded or duplicated into an open group arrives as a
  real child brush, but the group's editable set listed only its members — so the new brush could
  not be clicked at all, and worse, a click on it read as empty space and closed the group. The
  editable set now includes what was just created in it.
- **Clicking outside an open group no longer slams it shut.** With something selected, the click
  only deselects — the same thing empty space means anywhere else. With nothing selected, a drag
  draws a new brush inside the group, and only a plain click with nothing selected closes it.
- **The Brush tool now extrudes cleanly from rotated faces.** The placed points and the extruded
  cap were re-snapped onto the world grid after the fact, which dragged the base off any face
  that wasn't axis-aligned and quantized the depth to world grid planes. The base now sits
  exactly on the face, and the depth steps in grid-sized distances along the face's own normal —
  the world grid stays out of it.
- **The grid on a rotated face is now a single clean projection.** All three world grids were
  blended by the face normal, so a tilted face collected extra half-faded line families from the
  other two projections while the lines that belonged to it dimmed. Like TrenchBroom, only the
  dominant projection is drawn now, at full strength — the draw-preview ghost included.
- **The grid size and the lock toggles now reach a scene as soon as it opens.** Brushes arrived
  carrying whatever grid and texture/UV lock state they were saved with, and nothing reconciled
  them against the palette: the face grid drew at the saved cell size until the grid dropdown was
  nudged, and both locks behaved opposite to the buttons showing them until each was switched off
  and back on. This went further than appearance — a brush also *edited* on its saved grid, so
  dragging a vertex, edge or face in a freshly opened scene quietly rounded it to the lattice the
  map was last saved on rather than the one selected in the dropdown.
- Switching scenes with faces selected no longer fills the output with errors. A face selection
  outlived the scene it was made in — the brushes behind it were gone, but the selection still
  pointed at them — so the next refresh of the texture inspector reached through them. A face
  selection is now dropped along with the scene it belongs to.
- A texture or material dropped onto the texture browser now lands wherever you drop it. The
  thumbnails themselves refused drops, so only the bare background between them worked — and on a
  full browser there is barely any of that left.
- Pasting brushes copied from TrenchBroom no longer pastes twice. Godot's own Paste ran as well,
  dropping whatever was on the node clipboard on top of the new brushes and parenting it inside
  one of them. `Ctrl+C` had the same fault the other way, silently replacing that clipboard.
- A texture deleted or moved in the FileSystem no longer costs a brush all of its face data. One
  unresolvable texture aborted the whole load, taking every face's UVs, offsets and materials with
  it; now only the face wearing it falls back to Empty.
- Hidden brushes no longer answer clicks. Anything hidden — by its own eye in the Scene dock or by
  a hidden parent — was still picked by every gesture that reaches geometry, so it stole selections,
  Shift face-picks and texture drops from whatever was visibly behind it.
- Undoing a UV edit now puts the texture inspector and the UV canvas back too. The viewport showed
  the undone mapping while the dock and canvas still showed the one that had just been undone.
- Push/pull a face (Shift+drag) now follows the point you pressed rather than the face's centre. On
  a large face, starting the drag near a corner meant fighting a reference metres away across the
  middle of it.
- A brush drawn on a floor or ceiling no longer starts buried inside the brush underneath. The
  height was rounded down to the grid, so any surface not sitting on the current grid — one
  topping out at 2.3 with the grid on 0.5, or anything thinner than the grid — swallowed the base
  of the new brush. It now sits flush on the surface, and its height steps by whole grid cells
  from there. Against a wall the height still snaps to the world grid rather than to the surface,
  the point up a wall where you clicked being wherever the cursor happened to be rather than a
  surface to stand on.
- Holding Alt to set a height now grows the brush in either direction instead of moving it.
  Dragging down used to carry the whole brush a level below the surface it started on; the level
  you drew on is now always kept, and the drag extends the brush away from it, up or down alike.
  The height also no longer jumps a whole cell the instant the cursor crosses a grid line.
- Which way a new brush leaves a surface no longer depends on where you are looking from. It
  follows the surface itself — build up off a floor, down off a ceiling — so the same click gives
  the same brush whether you view it from above or below.
- A brush drawn against a wall now starts on the outside of it rather than needing to be dragged
  clear of the cell first. Pressing on a face puts the press point exactly on that face, and on a
  grid-aligned one that lands exactly on a grid line, leaving two equally valid cells to start in;
  the one outside the surface is now always chosen, and nudging the cursor either way settles it
  immediately. Pressing anywhere else in a cell was already correct and is unchanged — the brush
  starts in the cell you pressed in.
- Drawing against a wall no longer begins inside it. The drag was measured against a plane rounded
  down to the grid rather than one through the point clicked, so before the mouse had moved at all
  the cursor already read as most of a cell inside the wall — and only a long drag back out pulled
  the brush clear. The plane now passes through the press point, so a nudge either way settles
  which side the brush is on.
- The surface a new brush is drawn against is now picked by face rather than by bounding box, so
  the press lands on the surface actually under the cursor. Among brushes packed close together
  one brush's bounding box overlaps its neighbours, and drawing could start from a box side rather
  than the face clicked.

### Removed

- The separate draw-shapes tool button. Drawing while something is selected went with it — that
  is now the one thing the button could do that the drag gesture does not.

## [0.2.0] — 2026-07-26

### Added

- **Brush groups.** Select several brushes and group them into one node that draws as a
  single mesh, so a room costs one draw call per texture in both the opaque and the shadow
  pass instead of one per brush. There is no bake step to remember — the merged mesh is the
  group's resting form and is saved in the scene, rebuilt only when you change a member.
- Faces buried between touching members are dropped from a group's mesh, including the
  parts of a face a neighbour only partly covers.
- Because a group is a single `MeshInstance3D`, Godot's own Mesh menu — Unwrap UV2 — now
  applies to a whole room at once, which it could never do to a pile of separate brushes.
  (This entry originally recommended that menu's collision generators too. Don't use them
  on a group: the merged mesh has the buried faces culled out of it, so a trimesh built
  from it has holes. Groups collide correctly on their own — see Unreleased.)
- A closed group moves, rotates, scales, shears and flips like a single brush, accepts
  dropped textures on its faces, and drives the UV dock. Clip and the vertex/edge/face
  tools ask you to open it first.
- Double-click a group to open it and edit its members individually; anything you draw
  inside joins the group. `Escape` or a click outside closes it. While a group is open the
  rest of the map is washed back so the group stands out without hiding what surrounds it.
- Ungroup returns the original brushes in place, with their textures and UVs intact.

### Changed

- The Rotate toolbar's angle is now also the step a ring drag snaps to, so rotating by
  hand is no longer locked to 15°. Set it to 5° for fine work, 90° for quarter turns, or
  0° to rotate freely. The field steps in 5° increments instead of 1°.

### Fixed

- Brushes no longer collect junk faces until they stop responding to edits. Reshaping a
  large brush could split one flat face into a fan of near-identical ones, and every edit
  after that added more, until the brush quietly refused to change at all (the console
  showing "past the hull limit"). A brush already spoiled this way is repaired the next
  time it is edited.
- Clicking a brush while the Brush tool is active now selects that brush and leaves the
  tool, instead of staying armed to draw over it. Dragging still draws on top of an
  existing brush as before.
- Escape now steps out one level per press — first the picked vertex/edge/face handles,
  then the active tool, then the brush selection. It used to drop the brush selection
  first and leave the tool armed.
- Deselecting a brush clears its guide spikes and dimension labels immediately, rather
  than leaving them drawn over the viewport until the mouse was moved.

## [0.1.1] — 2026-07-25

### Fixed

- Overlay drawing (wireframes, handles, gizmos and dimension readouts) now projects
  through each 3D view's own camera. With more than one viewport open, every view drew
  through whichever one the mouse was last in, so the overlay appeared in the wrong place
  in all the others.

### Changed

- Scale and shear icons wear the colour their tool draws with in the viewport (green and
  blue) instead of the generic yellow accent, and the two halves of the flip icons are
  stroked alike so they read at the same size.

## [0.1.0] — 2026-07-23

First public version — the full TrenchBroom-style editing core.

### Added

- `Brush` node: convex brushes defined by planes + per-face data, registered as a custom
  node type with `extends Brush` supported for user scripts.
- Draw tools with live ghost previews: cuboid, stairs, cylinder, cone (edge-aligned,
  vertex-aligned, and scalable circle modes).
- Vertex, edge, and face reshape tools with multi-brush shared-handle editing and
  handle selection sets.
- Face push (`Shift+drag`), and `Ctrl+Shift+drag` extrude/split with live previews.
- Clip tool with keep-front/keep-back/keep-both cycling.
- Scale, shear, and rotate tools with modifier refinements and numeric toolbars
  (scale to size / by factors; rotate about a draggable pivot).
- CSG operations: Convex Merge, Subtract, Intersect, Hollow, and two-face bridge.
- Per-face world-projected textures (Valve-220 parallel UVs) with texture lock and
  UV lock; faces can also wear full Godot materials.
- Texture dock: searchable texture/material browser, numeric UV fields, common
  alignment buttons, and an interactive UV canvas; drag & drop from the FileSystem
  dock onto faces or whole brushes.
- Two-way TrenchBroom `.map` clipboard (`Ctrl+C` / `Ctrl+V`) with unit, axis, and UV
  conversion.
- Full TrenchBroom shortcut scheme, per-scene editor-mode toggle, and single-undo-step
  gestures throughout.
