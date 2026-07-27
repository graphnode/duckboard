# Changelog

All notable changes to Duckboard are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

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
- Because a group is a single `MeshInstance3D`, Godot's own Mesh menu — Create Trimesh /
  Convex Collision Sibling, Unwrap UV2 — now applies to a whole room at once, which it
  could never do to a pile of separate brushes.
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
