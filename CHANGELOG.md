# Changelog

All notable changes to Duckboard are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- **Drawing a shape no longer needs a tool.** Drag from empty space with nothing selected and you
  draw, the way TrenchBroom's Simple Shape tool is always live rather than switched on. The shape
  selector rides with the gesture, so cuboid, stairs, cylinder and cone are reachable without
  pressing anything first.
- The tool that places points on existing faces and builds their convex hull — previously the
  Sweep Tool — is now the **Brush Tool**, which is TrenchBroom's own name for it. TrenchBroom has
  since given "sweep" to an unrelated new tool, so the old name would have meant two things.
- It is also now the only brush-creation button on the palette, and `B` activates it, both
  matching TrenchBroom. `B` previously drew shapes, which no longer needs a button at all.

### Fixed

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
