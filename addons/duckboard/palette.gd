@tool
## Shared colour palette for the Duckboard overlays, in TrenchBroom's flavour. One source of truth
## for both the plugin and the per-tool helpers (rotate/shear/scale/clip/hull), reached as
## `Palette.TB_RED` etc. via a preload — never re-defined per file.

# Red bounding box / selection outline.
const TB_RED := Color(0.86, 0.20, 0.20)
# Green scale handles (TrenchBroom's other tools' handles are yellow).
const TB_GREEN := Color(0.35, 0.85, 0.35)
# Blue shear highlight.
const TB_BLUE := Color(0.35, 0.6, 0.95)
# Yellow point/handle work — the vertex/edge/face handles and the brush tool's placed points.
const TB_YELLOW := Color(0.95, 0.8, 0.25)
# Orange clip points and cut outline.
const TB_ORANGE := Color(1.0, 0.6, 0.15)
# Purple group bounds — TrenchBroom draws a grouped selection's AABB in this violet.
# The only translucent entry, and deliberately so: a group's box is the one wireframe that is drawn
# around geometry you are still meant to READ rather than around the thing you are acting on. At
# full opacity a room-sized box puts twelve solid lines across the level behind it; the other
# overlays are handles and cut lines, which have to stay crisp.
const TB_PURPLE := Color(0.68, 0.45, 0.95, 0.55)
