@tool
extends EditorPlugin
class_name Duckboard
## Duckboard: TrenchBroom-style map editing for Godot. Hides the built-in 3D grid, offers a
## grid-size dropdown, and draws grid-snapped convex brushes by LMB-dragging in the 3D viewport.
##
## The grid dropdown IS the snap size (in TB units; 32 TB == 1 m). It drives what the
## brush drawing snaps to. With no on-screen grid, "grid size" just means "snap size".
##
## Drawing: only arms when nothing is selected (so a normal click still selects). We always
## draw on a horizontal (XZ) plane and extrude up; a brush hit sets the plane height from the
## hit point, a miss uses TrenchBroom's default-point distance (8 m) along the mouse ray.

const ToolPalette := preload("res://addons/duckboard/ui/tool_palette.gd")
const ShapeBar := preload("res://addons/duckboard/ui/shape_bar.gd")
const RotateBar := preload("res://addons/duckboard/ui/rotate_bar.gd")
const ScaleBar := preload("res://addons/duckboard/ui/scale_bar.gd")
const ShapeBuilder := preload("res://addons/duckboard/shape_builder.gd")
const TextureDockScene := preload("res://addons/duckboard/ui/texture_dock.tscn")
const TextureDrop := preload("res://addons/duckboard/ui/texture_drop.gd")
const Csg := preload("res://addons/duckboard/csg.gd")
const MapClipboard := preload("res://addons/duckboard/io/map_clipboard.gd")
const CsgOps := preload("res://addons/duckboard/csg_ops.gd")
const GroupOps := preload("res://addons/duckboard/group_ops.gd")
const PhysicsOps := preload("res://addons/duckboard/physics_ops.gd")
const Collision := preload("res://addons/duckboard/collision.gd")
const GroupIsolate := preload("res://addons/duckboard/group_isolate.gd")
const EditorToolMode := preload("res://addons/duckboard/editor_tool_mode.gd")
const RotateTool := preload("res://addons/duckboard/tools/rotate_tool.gd")
const ShearTool := preload("res://addons/duckboard/tools/shear_tool.gd")
const ClipTool := preload("res://addons/duckboard/tools/clip_tool.gd")
const ScaleTool := preload("res://addons/duckboard/tools/scale_tool.gd")
const HullTool := preload("res://addons/duckboard/tools/hull_tool.gd")
const HandleTools := preload("res://addons/duckboard/tools/handle_tools.gd")
const Palette := preload("res://addons/duckboard/palette.gd")   # shared TB_* overlay colours
const GHOST_SHADER := preload("res://addons/duckboard/shaders/grid_triplanar_ghost.gdshader")
const TOGGLE_ICON := preload("res://addons/duckboard/icons/RubberDuck.svg")

# Grid / snap sizes in TrenchBroom units. 32 TB == 1 Godot metre.
const UNITS_PER_METER := 32.0
const SIZES: Array[float] = [0.125, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0, 256.0]

# TrenchBroom's default point distance is 256 game units; 256 / 32 = 8 m. The no-hit
# draw plane sits at the height of the point 8 m along the pick ray THROUGH THE MOUSE.
const DEFAULT_POINT_DISTANCE := 8.0
const DRAG_THRESHOLD_PX := 6.0   # min pixel drag before we start drawing (vs. a click)

# Editor settings we override while the mode is on, restored when it's off: the selection colours
# go transparent so Godot's AABB box doesn't cover the face wireframe we draw ourselves. (We leave
# the built-in grid alone.) Node3DEditor re-reads these live when the group changes.
const SELECTION_BOX_OVERRIDES := {
	"editors/3d/selection_box_color": Color(0, 0, 0, 0),
	"editors/3d/active_selection_box_color": Color(0, 0, 0, 0),
}

var _size_index := 7             # 16 TB == 0.5 m (TrenchBroom's default grid)
var grid_size := 1.0             # metres per cell, derived from the dropdown
var texture_lock := false        # palette options; new brushes inherit them
var uv_lock := false
var _option: OptionButton
var _shape_bar: Control          # top-toolbar shape selector, shown only when about to draw (shape_bar.gd)
var _rotate_bar: Control         # top-toolbar rotate options, shown only in the Rotate tool (rotate_bar.gd)
var _scale_bar: Control          # top-toolbar scale options, shown only in the Scale tool (scale_bar.gd)
var _csg_ops: CsgOps             # CSG dropdown ops at the palette's foot (see csg_ops.gd)
var _group_ops: GroupOps         # Group/Ungroup dropdown beside it (see group_ops.gd)
var _physics_ops: PhysicsOps     # Physics-body dropdown beside those (see physics_ops.gd)
var _group_isolate := GroupIsolate.new()   # the open group's isolation wash (see group_isolate.gd)
var _palette: Control            # left-edge tool palette (see tool_palette.gd)
var _map_clipboard: MapClipboard    # .map copy/paste (see io/map_clipboard.gd)
var _tool_mode_lock: EditorToolMode # forces Godot's Select gizmo mode + locks it (see editor_tool_mode.gd)
var _texture_dock: VBoxContainer    # right-dock Texture inspector (see texture_dock.gd)
var _active_surface: Resource       # "current" surface (Texture2D or Material): new brushes get it, dock shows it red
## Last viewport camera we saw input through. Palette actions fire from a button and get no
## camera of their own, but view-relative operations (flip) need one.
var _last_camera: Camera3D
var _toggle: Button              # master on/off for the whole map-editor mode
## Toggle styleboxes: the transparent idle box, and a highlighted "hint" box swapped onto the idle
## (unpressed) state when a brush is selected while the mode is off, nudging you to turn it on.
var _toggle_idle_style: StyleBox
var _toggle_hint_style: StyleBox
var _toggle_hinting := false     # guards the swap so it can't redundantly re-apply
## Transient viewport pill flashed when a brush is selected while the mode is off — the "why" that
## points at the highlighted toggle. Cleared by a timer; the token voids a stale timer if the
## selection changes again before it fires.
var _hint_toast := false
var _hint_toast_token := 0
## Rate limit so the pill doesn't reappear on every brush click during normal editing. It flashes
## again only once the cooldown lapses, OR when the user RE-selects the same brush (deselect then
## pick it again) — a deliberate "show me that again" that beats the cooldown so a missed message
## can always be recalled. The highlight itself is never rate-limited; only the pill is.
const HINT_REPEAT_COOLDOWN_MSEC := 30000
var _hint_last_brush_id := 0     # instance id of the last brush we hinted for (id, so a freed node is safe)
## Seeded a full cooldown in the past so the very first hint fires even seconds after editor launch.
var _hint_last_shown_msec := -HINT_REPEAT_COOLDOWN_MSEC
var _enabled := false            # off by default; per-scene state is restored on scene change
var _enabled_scenes := {}        # scene_file_path -> true, persisted in the editor layout
var _saved := {}                 # saved selection-box colours
var _selection_box_hidden := false   # guards hide/restore so they can't double-apply

# Drawing state.
var _armed := false
var _drawing := false
var _press_pos := Vector2.ZERO
var _axis := 1                   # draw-plane axis: 0=X, 1=Y, 2=Z
var _plane_coord := 0.0          # height of the horizontal drag plane (re-anchored on mod change)
var _grid_origin_y := 0.0        # what the HEIGHT snaps to: the face drawn on, or 0 in empty space
var _draw_grows_up := true       # which side of the draw plane this brush occupies
var _face_axis := -1             # axis of the face drawn against (-1 = none), for the outward snap
var _face_sign := 0.0            # +1 if that face looks along +axis, -1 if along -axis
# A press outside the OPEN group, with nothing selected, that armed the draw gesture. Whether it
# meant "draw inside the group" or "leave the group" is decided on release — drag draws, plain
# click leaves — the same split CTRL uses for duplicate-vs-multiselect.
var _group_close_pending := false
# The member a press landed on with nothing selected, draw armed. A drag draws flush against it;
# a plain click selects it on release — by hand, because a kernel is unowned and Godot's own
# click-select cannot pick it.
var _group_click_member: Node3D = null

## Slack for grid rounding, as a fraction of one cell — see the sums in _box_from.
const GRID_EPS := 1e-4
var _hit_point                   # Vector3 surface point we clicked, or null (empty space)
var _start                       # Vector3 or null — the fixed base corner (initial handle)
var _current                     # Vector3 or null — handle position under the cursor

# Drag modifiers, matching TrenchBroom's shape drawing: ALT alone drags the
# handle along a vertical line, SHIFT squares the footprint, ALT+SHIFT squares all 3 (cube).
var _alt := false
var _square := false
var _alt_line_point := Vector3.ZERO   # vertical-line origin, FROZEN when ALT goes down
var _preview: Node3D
var _preview_box: MeshInstance3D
## Live ghosts of the actual shape (stairs/cylinder/cone) while drawing — real Brushes rendered with
## the ghost material. Cuboid uses _preview_box instead and leaves these empty.
var _preview_brushes: Array[Node3D] = []
## Cache guard: the shape only changes when the SNAPPED box or a parameter does, so the (possibly
## O(n^4)) rebuild runs on that, not on every mouse motion. Empty forces the next update to rebuild.
var _preview_shape_key := ""

# TrenchBroom-style direct move: grab a brush and drag it — no gizmo. Horizontal plane drag
# by default, ALT switches to the vertical line. Same constraint machinery as drawing.
var _move_armed := false         # pressed on a brush, waiting to pass the drag threshold
var _move_active := false
var _move_press_pos := Vector2.ZERO
var _move_plane_y := 0.0         # horizontal drag plane, taken from the grabbed point
var _move_grab_point := Vector3.ZERO   # exact surface point grabbed; the move legs start here
var _move_line_point := Vector3.ZERO   # vertical-line origin while ALT is held
var _move_alt := false
var _move_ctrl := false          # CTRL at press: drag a duplicate instead of the original
var _move_duplicated := false
## Brush pressed with CTRL held. Held until release, because CTRL+click means "toggle selection"
## but CTRL+drag means "duplicate", and only the mouse can say which.
var _ctrl_click_node: Node3D

## Groups whose members the active transform drag is reshaping, each mapped to the `members` it
## started with. Populated only between _begin_group_drag and _end_group_drag.
var _group_drag := {}

## The group currently OPENED for editing, or null. While one is open the editor is isolated to it:
## its members are live kernels that the tools treat as ordinary brushes, and nothing outside answers
## to picking or selection. Single, not a stack — the member schema is deliberately flat.
var _open_group: Node3D

# CTRL paint selection (TrenchBroom quick select): with nothing selected, holding CTRL and pressing
# the mouse begins a drag that adds every brush the held cursor sweeps over. A plain click adds just
# the one under it. Latched from press to release, so it can't be confused with CTRL+drag duplicate
# (which only applies once a selection exists).
var _paint_selecting := false

# SHIFT + face: TrenchBroom's face-level selection, the counterpart to CTRL's brush-level one.
# A face under the cursor with SHIFT held can be pushed along its own normal, or clicked to
# become the selection the texture inspector acts on.
var _shift_face_hover = null          # {node, face} under the cursor, or null
var _shift_face_press = null          # {node, face} the button went down on
# Set for as long as a left button that went down WITH SHIFT is held, whether or not the chord under
# it meant anything here. Duckboard claims the whole gesture on the strength of it — see
# _forward_3d_gui_input.
var _shift_gesture := false

# Texture drag-and-drop from the FileSystem dock onto brush faces (see ui/texture_drop.gd).
var _texture_drop: TextureDrop
var _drop_face_hover = null           # {node, face} a texture drag is hovering, or null (also the hint)
var _shift_face_press_pos := Vector2.ZERO
var _shift_face_press_point := Vector3.ZERO   # where on the face the press landed, in world space
var _shift_face_ctrl := false         # CTRL held at press: a drag EXTRUDES a new brush
## Selected faces, as {node, face} — what the texture inspector will read and write.
var _selected_faces: Array = []

# TrenchBroom's ALT+click UV transfer. With exactly ONE face selected
# as the source, ALT paints its material + alignment onto the faces you click / double-click (whole
# brush) / drag over. The whole gesture is applied live and banked as one undo step on release.
var _uv_copy_active := false
var _uv_copy_mode := ""          # "projection" | "rotation" | "material"
var _uv_copy_from = null         # {node, face} to copy FROM next; advances along a drag run
var _uv_copy_before := {}        # node -> face_data snapshot, captured before its first mutation
var _uv_copy_group_before := {}  # group -> members snapshot, when the gesture paints a grouped face
var _uv_copy_painted := {}       # "instance_id:face" -> true, faces already painted this gesture
## A double-click's whole-brush paint. Its undo step MERGE_ENDS into the single-click transfer that
## Godot always fires just before it (same button, first of the pair), so a double-click reads as one
## undo, matching TrenchBroom. Plain clicks/drags stay unmerged, so separate transfers never fuse.
var _uv_copy_whole := false
# A face being pushed along its normal. Same reshape as face mode, constrained to one axis.
var _push_nodes: Array[Node3D] = []
var _push_start_planes: Array = []
var _push_start_faces: Array = []
var _push_local_index := -1          # the pushed face's index into _push_start_planes[0]
var _push_normal := Vector3.ZERO
var _push_plane_d := 0.0              # the face's plane distance before the push
var _push_applied_offset := 0.0      # how far the source face was ACTUALLY moved (offset, minus guard clamping)
var _push_origin := Vector3.ZERO
var _push_offset := 0.0
var _push_active := false
# CTRL+SHIFT+drag variant: instead of moving the face, extrude a NEW brush from it (outward) or split
# it (inward). The source is never touched live either way — the drag only previews; commit decides.
var _push_new_brush := false
var _push_source_faces: Array = []             # source brush's world faces at press, for the plane-based extrude
var _push_source_face_index := -1              # which of _push_source_faces is the pushed one
var _push_preview: Node3D                      # live, unowned Brush shown while extruding OUTWARD (real textures)
var _push_locks: Array = []           # lock toggles suppressed for the push, restored after
var _move_start_handle := Vector3.ZERO
var _move_nodes: Array[Node3D] = []
var _move_starts: Array[Vector3] = []    # baseline, rebased when the constraint changes
var _move_origins: Array[Vector3] = []   # true starting positions, for undo

# Active palette tool ("" = plain selection). See tool_palette.gd for the ids.
var _tool_mode := ""

# Vertex / edge / face reshape tools — one subsystem sharing a world-position handle model
# (see tools/handle_tools.gd). These handle-pick/handle-draw pixel radii stay here because the
# box-geometry picker and other overlays reference them too.
const VERTEX_GRAB_PX := 9.0
const VERTEX_HANDLE_PX := 4.0
var _handle_tools: HandleTools         # vertex/edge/face reshape subsystem (see tools/handle_tools.gd)

# Scale tool. Unlike vertex/edge/face — which reshape ONE brush by moving its own corners —
# scaling acts on the selection's world bounding box and maps every brush through the same
# affine transform, so a multi-brush selection scales as one object.
const SCALE_HANDLE_PX := 5.0
const SCALE_GRAB_PX := 12.0
var _scale_tool: ScaleTool             # bounding-box resize widget + one-shot bar (see tools/scale_tool.gd)

# Shear tool. Shares the scale tool's SIDE handles and picking, but the grabbed face slides
# WITHIN its own plane instead of along its normal, and the opposite face stays put — so the
# brush leans rather than resizing. Two degrees of freedom, unlike scale's one.
var _shear_tool: ShearTool             # side-handle shear (see tools/shear_tool.gd)

# Rotate tool. A widget of three axis rings centred on the selection, plus a centre handle that
# moves the pivot.
#
# The MESH itself rotates — the node's basis is never touched. That's possible because a brush
# is defined by its PLANES, and rotating a plane is exact at any angle, so this can bypass
# set_from_points and the grid snapping that would otherwise mangle a brush turned by anything
# other than a multiple of 90 degrees. Same mechanism the flip uses.
const RING_RADIUS_PX := 64.0
const RING_GRAB_PX := 8.0
const RING_SEGMENTS := 64
const CENTER_HANDLE_PX := 4.5
## Pivot dot colour — a warm gold that reads distinctly against the red/green/blue axis rings.
const ROTATE_CENTER_COLOR := Color(1.0, 0.85, 0.2)
const ROTATE_CENTER_HOT := Color(1.0, 0.95, 0.6)
## TrenchBroom rotates in fixed angular steps rather than off the grid size. This is only the
## fallback — the live step is the rotate bar's angle field (see [method rotate_snap_deg]), which
## starts at this same value.
const ANGLE_SNAP_DEG := 15.0
var _rotate_tool: RotateTool           # three-ring rotate widget + one-shot bar (see tools/rotate_tool.gd)

var _clip_tool: ClipTool               # clip-plane cut widget (see tools/clip_tool.gd)

# Brush tool: convex hull from points placed on faces (see tools/hull_tool.gd).
var _hull_tool: HullTool
var _hull_preview: Node3D              # unowned Brush preview; the plugin owns it so scene scans + CSG can exclude it

var _clip_preview: MeshInstance3D          # unowned geometry for the face the cut would create

# Hover highlight: dimension labels + red edges extended outward, TrenchBroom-style.
# The length is FIXED, not a multiple of the edge — guides are the same length whatever the
# brush's size. TrenchBroom's guides are 512 game units (16 m here);
# we run longer deliberately, because our guides read as shorter than TB's in practice.
const SPIKE_LENGTH := 32.0                 # 1024 TB units
## Vertex/edge/face drag guides. Separate from the bounds guides above even though both started
## at TrenchBroom's 512: these radiate from a single dragged point rather than tracing a box, so
## tuning one to taste should not silently move the other.
const VERTEX_SPIKE_LENGTH := 16.0          # 512 TB units


# Move indicator: the drag delta split into X/Y/Z legs so you can read the distance per axis.
const MOVE_AXES := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
const AXIS_COLORS := [
	Color(0.96, 0.25, 0.32),   # X
	Color(0.45, 0.84, 0.28),   # Y
	Color(0.25, 0.55, 0.96),   # Z
]
var _hover_brush: Node3D

# 2D-overlay dimension readouts.
#
# The camera the overlay projects through. Outside a draw it is the camera of the view we last saw
# input through (hover, drags, the shape ghost); DURING a draw the force-draw callback swaps in the
# camera of the view being drawn, so each open view projects through its own.
var _draw_camera: Camera3D
# overlay Control -> that view's Camera3D. Keyed by the surface we are handed; Control is not
# reference-counted, so this holds no ownership and stale entries are caught by is_instance_valid.
var _overlay_cameras: Dictionary = {}
var _box_center := Vector3.ZERO
var _box_size := Vector3.ZERO
var _label_style: StyleBoxFlat   # subtly rounded dark pill behind each label


func _enter_tree() -> void:
	# No add_custom_type() here on purpose. `class_name Brush` already lists the type in the
	# Create Node dialog, and the icon comes from @icon in brush.gd — which SUBCLASSES inherit,
	# whereas a custom type's icon applies only to that exact script, so a user's `extends Brush`
	# lost the icon. Registering both would also list Brush twice.
	grid_size = _cell_meters()
	_map_clipboard = MapClipboard.new(self)
	_csg_ops = CsgOps.new(self)
	_group_ops = GroupOps.new(self)
	_physics_ops = PhysicsOps.new(self)
	_texture_drop = TextureDrop.new(self)
	_tool_mode_lock = EditorToolMode.new(self)
	_rotate_tool = RotateTool.new(self)
	_shear_tool = ShearTool.new(self)
	_clip_tool = ClipTool.new(self)
	_scale_tool = ScaleTool.new(self)
	_hull_tool = HullTool.new(self)
	_handle_tools = HandleTools.new(self)
	_label_style = StyleBoxFlat.new()
	_label_style.bg_color = Color(0.09, 0.09, 0.11, 0.88)
	_label_style.set_corner_radius_all(4)
	_build_toggle()
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _toggle)
	_build_toolbar()
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _option)
	_shape_bar = ShapeBar.new()
	_shape_bar.changed.connect(_on_shape_changed)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _shape_bar)
	_rotate_bar = RotateBar.new()
	_rotate_bar.center_edited.connect(_on_rotate_center_edited)
	_rotate_bar.center_reset.connect(_on_rotate_center_reset)
	_rotate_bar.apply_pressed.connect(_on_rotate_apply)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _rotate_bar)
	_scale_bar = ScaleBar.new()
	_scale_bar.apply_pressed.connect(_on_scale_apply)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _scale_bar)
	_palette = ToolPalette.new()
	_palette.tool_changed.connect(_on_tool_changed)
	_palette.option_toggled.connect(_on_option_toggled)
	_palette.action_triggered.connect(_on_action_triggered)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, _palette)
	_csg_ops.build_menu()   # fills the palette's CSG dropdown, so it must follow the palette's creation
	_group_ops.build_menu()   # ditto for the Group dropdown beside it
	_physics_ops.build_menu()   # and the Physics dropdown beside those
	# The Texture dock is added/removed with the map-editor toggle (see _apply_state), not here, so
	# it's only present while you're actually editing a map.
	set_input_event_forwarding_always_enabled()
	set_force_draw_over_forwarding_enabled()   # so _forward_3d_force_draw_over_viewport fires
	scene_changed.connect(_on_scene_changed)
	# Undo/redo writes properties straight onto the brushes without passing through any of our
	# code, so the overlay (wireframe, handles, dimension labels) would keep showing the shape
	# from before the Ctrl+Z. This covers every action at once rather than each commit site.
	get_undo_redo().version_changed.connect(update_overlays)
	get_undo_redo().version_changed.connect(_update_transform_bars)   # keep the size/pivot fields live after undo
	get_undo_redo().version_changed.connect(_refresh_uv_views)        # ...and the UV fields + canvas
	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)
	_on_selection_changed()                    # set the palette's initial enabled state
	_sync_to_current_scene()                   # starts off unless this scene was toggled on


func _exit_tree() -> void:
	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)
	var selection := EditorInterface.get_selection()
	if selection.selection_changed.is_connected(_on_selection_changed):
		selection.selection_changed.disconnect(_on_selection_changed)
	_reset_draw()
	_group_isolate.abort()  # the editor's cameras outlive the plugin; never leave the wash on one
	_tool_mode = ""        # so the clip cleanup below tears down rather than rebuilds
	_clip_tool.update_ghost()   # un-ghost brushes and drop the unowned preview geometry
	_restore_selection_box()
	_tool_mode_lock.restore()   # hand the viewport back to whatever transform mode we displaced
	if is_instance_valid(_shape_bar):
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _shape_bar)
		_shape_bar.queue_free()
	if is_instance_valid(_rotate_bar):
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _rotate_bar)
		_rotate_bar.queue_free()
	if is_instance_valid(_scale_bar):
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _scale_bar)
		_scale_bar.queue_free()
	# The CSG dropdown lives inside the palette, so it's freed with it below.
	if is_instance_valid(_option):
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _option)
		_option.queue_free()
	if is_instance_valid(_palette):
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, _palette)
		_palette.queue_free()
	_hide_texture_dock()
	_texture_drop.remove_catchers()
	if is_instance_valid(_toggle):
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _toggle)
		_toggle.queue_free()


# --- Master toggle --------------------------------------------------------

func _build_toggle() -> void:
	_toggle = Button.new()
	_toggle.toggle_mode = true
	_toggle.button_pressed = _enabled
	_toggle.tooltip_text = "Toggle brush map editor."
	_toggle.icon = TOGGLE_ICON
	# No `expand_icon`: the duck is a real 16x16 Godot-convention icon, matching the editor's own
	# toolbar icons. Expanding it to fill the button would just resample and blur it, and the
	# button already centres a smaller icon on its own — no transparent padding needed in the SVG.
	# Button.icon_alignment defaults to LEFT, which pins an icon-only button's icon against the
	# left edge instead of centring it in the 36x36 square. Only CENTER actually centres it.
	_toggle.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toggle.custom_minimum_size = Vector2(36, 36)
	# NOT `flat`: that skips the stylebox in every state, so the pressed background — the
	# thing that shows the mode is on — would never draw. Empty the idle state instead.
	# A light neutral box carries the on-state; the icon is left untinted so it stays legible.
	var on_style := StyleBoxFlat.new()
	on_style.bg_color = Color(1, 1, 1, 0.16)
	on_style.set_corner_radius_all(3)
	# The hint box replaces the idle one when a brush is selected while off: a warm border + soft
	# fill that reads as "attention", distinct from the neutral white on-state (see _update_toggle_hint).
	var hint_style := StyleBoxFlat.new()
	hint_style.bg_color = Color(1.0, 0.75, 0.2, 0.18)
	hint_style.set_corner_radius_all(3)
	hint_style.set_border_width_all(1)
	hint_style.border_color = Color(1.0, 0.75, 0.2, 0.9)
	_toggle_idle_style = StyleBoxEmpty.new()
	_toggle_hint_style = hint_style
	_toggle.add_theme_stylebox_override("normal", _toggle_idle_style)
	_toggle.add_theme_stylebox_override("pressed", on_style)
	_toggle.add_theme_stylebox_override("hover_pressed", on_style)
	# The editor theme accent-tints pressed icons by default; white cancels that out.
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color",
			"icon_hover_pressed_color", "icon_focus_color"]:
		_toggle.add_theme_color_override(state, Color.WHITE)
	_toggle.toggled.connect(_on_toggled)


## Nudge, don't auto-toggle: when the mode is off and the selection holds a brush, highlight the
## toggle and flash a transient viewport pill (see _forward_3d_force_draw_over_viewport) so the way
## in is obvious, without seizing the editor chrome the way an automatic mode flip would. Any other
## state — mode on, or nothing brush-ish selected — is the plain idle button. Idempotent via
## _toggle_hinting, and safe to call from anywhere.
func _update_toggle_hint() -> void:
	if not is_instance_valid(_toggle):
		return
	var brushes := _selected_brushes()
	var want := not _enabled and not brushes.is_empty()
	if want == _toggle_hinting:
		return
	_toggle_hinting = want
	# The highlight tracks `want` exactly — always on while a brush is selected off-mode.
	_toggle.add_theme_stylebox_override("normal",
		_toggle_hint_style if want else _toggle_idle_style)
	# Bumping the token voids any in-flight clear timer, whichever way we just flipped.
	var token := _hint_toast_token + 1
	_hint_toast_token = token
	if not want:
		_hint_toast = false
		update_overlays()
		return
	# The PILL is rate-limited: flash it only when the cooldown has lapsed, or when the user
	# re-selects the same brush (a deliberate re-read that always wins). Either way, remember this
	# brush so the next reselect of it counts as a re-read.
	var brush_id := brushes[0].get_instance_id()
	var now := Time.get_ticks_msec()
	var reselect_same := brush_id == _hint_last_brush_id
	var cooled := now - _hint_last_shown_msec >= HINT_REPEAT_COOLDOWN_MSEC
	_hint_last_brush_id = brush_id
	_hint_toast = reselect_same or cooled
	if _hint_toast:
		_hint_last_shown_msec = now
		# Flash, then fade: a one-shot timer clears it unless a newer flip has since re-armed.
		get_tree().create_timer(4.0).timeout.connect(func() -> void:
			if _hint_toast_token == token:
				_hint_toast = false
				update_overlays())
	update_overlays()


## User flipped the toggle: remember the choice for THIS scene, then apply it.
func _on_toggled(pressed: bool) -> void:
	_enabled = pressed
	var key := _current_scene_key()
	if key != "":
		if pressed:
			_enabled_scenes[key] = true
		else:
			_enabled_scenes.erase(key)
	_apply_state()


## Adopt whatever state was stored for the scene now being edited (default: off).
func _sync_to_current_scene() -> void:
	# A face selection belongs to the scene it was made in, and every node behind it is freed the
	# moment that scene closes. _on_selection_changed cannot do this: it only clears the face
	# selection when the node selection is NON-empty, and a closing scene empties it.
	_selected_faces = []
	_enabled = bool(_enabled_scenes.get(_current_scene_key(), false))
	_apply_state()
	_push_palette_to_scene()


## Reconcile the brushes a scene arrived with to the palette's CURRENT settings.
##
## The grid dropdown and the two lock toggles are global: each pushes to every brush in the scene
## the moment the user changes it, so the palette — not the node — is the source of truth. A scene
## loaded from disk brings the values that were serialised into it instead, and nothing reconciled
## them, so the two disagreed until the user happened to touch a control. That is why the face grid
## drew at the saved cell size until the dropdown was nudged, and why the locks behaved opposite to
## the buttons showing them until they were toggled off and back on.
##
## `grid_size` matters beyond appearance: set_from_points() re-snaps corners to the brush's OWN
## grid, so a stale one silently rounds every vertex/edge/face edit back to the lattice the scene
## was saved on. _apply_state has already settled whether the overlay is shown at all; this settles
## what it and the edit grid are set to.
##
## None of the three is exported any more, so a loaded scene arrives with the defaults rather than
## with values that could disagree with the palette. This is what makes them agree.
func _push_palette_to_scene() -> void:
	_refresh_brush_grid_overlay()   # brushes and groups alike
	for node in _scene_brushes(true):
		node.texture_lock = texture_lock
		node.uv_lock = uv_lock
	# Groups hand both settings down to their kernels, so a grouped wall reconciles with the rest.
	for group in _scene_groups():
		group.texture_lock = texture_lock
		group.uv_lock = uv_lock


## Scenes are keyed by file path. An unsaved scene has none, so its state can't persist.
func _current_scene_key() -> String:
	var root := EditorInterface.get_edited_scene_root()
	return root.scene_file_path if root != null else ""


## Push `_enabled` onto the UI, the viewport behaviour and the built-in grid. Off hands the
## viewport back to plain Godot: no drag-to-draw, no Delete interception, palette + grid
## dropdown hidden, built-in grid restored.
func _apply_state() -> void:
	if not _enabled:
		_reset_draw()   # abort any drag in progress
		_reset_move()
		if _uv_copy_active:
			_commit_uv_copy()   # bank an in-progress ALT transfer before the mode goes away
		_hover_brush = null
		update_overlays()
	if is_instance_valid(_option):
		_option.visible = _enabled
	_update_shape_bar()
	_update_transform_bars()   # the rotate/scale bars hide with the mode too
	_csg_ops.update_menu()   # the CSG button hides with the palette; keep its item states current
	_group_ops.update_menu()   # same for the Group button beside it
	_physics_ops.update_menu()   # and the Physics button beside those
	if is_instance_valid(_palette):
		_palette.visible = _enabled
	if is_instance_valid(_toggle) and _toggle.button_pressed != _enabled:
		_toggle.set_pressed_no_signal(_enabled)   # syncing shouldn't re-fire _on_toggled
	if _enabled:
		_hide_selection_box()
		_tool_mode_lock.force_select()
		_tool_mode_lock.set_lock(true)
		_show_texture_dock()
		_texture_drop.add_catchers()
	else:
		_restore_selection_box()
		_tool_mode_lock.set_lock(false)
		_tool_mode_lock.restore()
		_hide_texture_dock()
		_texture_drop.remove_catchers()
	_set_brush_grid_overlays(_enabled)
	_update_toggle_hint()   # turning the mode on clears the hint; off may re-arm it


## Show or hide the per-face grid overlay on every brush in the scene. It's a map-editing aid, so it
## goes away with the rest of the mode when Duckboard is off, and comes back when it's on again.
func _set_brush_grid_overlays(visible: bool) -> void:
	# Previews included: a ghost that kept its grid while every real brush lost theirs would read
	# as a rendering bug rather than as the mode being off. Groups too — a group draws the same
	# face grid, so leaving it on would make the mode look half-off.
	for node in _scene_brushes(true):
		node.set_grid_overlay_enabled(visible)
	for group in _scene_groups():
		group.set_grid_overlay_enabled(visible)


# --- Texture dock ---------------------------------------------------------

## The Texture dock lives only while the map editor is on. Godot keys dock layout by control name,
## so re-adding the same-named dock restores wherever the user had dragged it.
func _show_texture_dock() -> void:
	if is_instance_valid(_texture_dock):
		return
	_texture_dock = TextureDockScene.instantiate()
	_texture_dock.surface_chosen.connect(_on_surface_chosen)
	_texture_dock.uv_offset_changed.connect(_on_uv_offset_changed)
	_texture_dock.uv_scale_changed.connect(_on_uv_scale_changed)
	_texture_dock.uv_angle_changed.connect(_on_uv_angle_changed)
	_texture_dock.uv_action.connect(_on_uv_action)
	_texture_dock.uv_offset_dragged.connect(_on_uv_offset_dragged)
	_texture_dock.uv_rotate_started.connect(_on_uv_rotate_started)
	_texture_dock.uv_rotate_dragged.connect(_on_uv_rotate_dragged)
	_texture_dock.uv_scale_started.connect(_on_uv_scale_started)
	_texture_dock.uv_scale_dragged.connect(_on_uv_scale_dragged)
	_texture_dock.texture_deselected.connect(_on_texture_deselected)
	_texture_dock.select_faces_requested.connect(_on_select_faces_requested)
	_texture_dock.select_brushes_requested.connect(_on_select_brushes_requested)
	_texture_dock.replace_texture_requested.connect(_on_replace_texture_requested)
	# ↑/↓ nudges the offset field by the grid size (TB parity). Deferred so the dock's _ready (which
	# builds the fields) has run first; kept in sync afterwards by _on_size_selected / _step_grid.
	call_deferred("_sync_offset_nudge")
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _texture_dock)
	# Give the tab the editor's own MeshTexture glyph (also shown in Editor > Editor Docks).
	set_dock_tab_icon(_texture_dock, EditorInterface.get_base_control().get_theme_icon(
		"MeshTexture", "EditorIcons"))
	_sync_texture_dock()   # populate it with the current selection immediately
	_focus_texture_dock()  # raise its tab to the front


## Make the Texture dock the active tab of whatever dock it landed in, so toggling the map editor on
## surfaces it rather than leaving it hidden behind the Inspector.
##
## Waits TWO process frames: add_control_to_dock reparents into the dock's TabContainer, and the
## editor then restores that dock's saved current tab a frame later — setting it any sooner just
## gets overwritten. Walks up to the TabContainer in case the control is nested inside a wrapper.
func _focus_texture_dock() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_instance_valid(_texture_dock):
		return
	var node: Node = _texture_dock
	var tabs := node.get_parent()
	while tabs != null and not (tabs is TabContainer):
		node = tabs
		tabs = tabs.get_parent()
	if tabs is TabContainer:
		(tabs as TabContainer).current_tab = node.get_index()


func _hide_texture_dock() -> void:
	if is_instance_valid(_texture_dock):
		remove_control_from_docks(_texture_dock)
		_texture_dock.queue_free()
	_texture_dock = null


# --- Drop hover state + material clearing (shared: drop, browser menu, shift-face) ---

func _set_drop_face_hover(entry) -> void:
	if str(entry) != str(_drop_face_hover):
		_drop_face_hover = entry
		update_overlays()


## Assigning a texture REPLACES what the brush shows, so any material_override or per-surface
## override on it — typically strays from Godot's built-in viewport drop, which lands whenever
## duckboard isn't there to intercept it — is cleared as part of the same undo step.
## They'd keep painting over the per-face materials, and surface overrides don't even track the
## brush's surfaces (those are regrouped by texture on every rebuild). material_overlay (the grid
## aid) is a different property and is left alone.
func _clear_material_overrides(ur: EditorUndoRedoManager, node: Node3D) -> void:
	if node.material_override != null:
		ur.add_undo_property(node, "material_override", node.material_override)
		ur.add_do_property(node, "material_override", null)
		node.material_override = null
	for s in node.get_surface_override_material_count():
		var m: Material = node.get_surface_override_material(s)
		if m != null:
			ur.add_undo_method(node, "set_surface_override_material", s, m)
			ur.add_do_method(node, "set_surface_override_material", s, null)
			node.set_surface_override_material(s, null)


# --- Per-scene persistence (stored in the editor layout, so scenes stay clean) ---

func _get_window_layout(configuration: ConfigFile) -> void:
	configuration.set_value("Duckboard", "enabled_scenes", _enabled_scenes.keys())


func _set_window_layout(configuration: ConfigFile) -> void:
	_enabled_scenes.clear()
	for path in configuration.get_value("Duckboard", "enabled_scenes", []):
		_enabled_scenes[path] = true
	_sync_to_current_scene()


func _on_scene_changed(_root: Node) -> void:
	_sync_to_current_scene()
	_warn_about_orphaned_brushes()
	# No orphan-shape sweep: a solid's body and shapes are its own CHILDREN, so a deleted brush takes
	# them with it and a saved scene cannot contain collision for geometry that is no longer there.
	# The sweep this used to run — and the whole delete/undo hazard it tiptoed around — went with the
	# derived-node model. See collision.gd.


## Selection drives which palette buttons are usable, and the overlay needs a repaint so the
## selection wireframe appears immediately rather than on the next mouse move.
func _on_selection_changed() -> void:
	if is_instance_valid(_palette):
		# Two different questions: most tools need SOMETHING selected, but the per-solid ones need a
		# BRUSH. With only a closed group selected they would otherwise sit enabled and do nothing.
		_palette.set_selection_state(
			not EditorInterface.get_selection().get_selected_nodes().is_empty(),
			not _selected_brushes().is_empty())
	# DEFERRED, and that matters. This frees nodes — a group's kernels — and doing that from inside a
	# selection-changed callback mutates the scene tree while the editor is still settling the very
	# selection that caused it, which makes the dock re-sync from stale state and put the previous
	# selection back. Only GROUPS have kernels, which is exactly why only groups could not be picked
	# from the Scene tree while brushes could.
	_release_idle_kernels.call_deferred()
	# A moved rotation pivot belongs to the selection it was placed for; carrying it onto a
	# different brush would rotate that one about a point nowhere near it.
	_rotate_tool.center_valid = false
	# Handle selections belong to the brushes that offered them, for the same reason.
	_handle_tools.selection = PackedVector3Array()
	# Selecting a BRUSH supersedes any face selection — they're alternatives, and this also
	# catches selections made from the Scene dock rather than the viewport. Guarded on non-empty
	# because _select_face clears the brush selection on its way to selecting a face.
	if not EditorInterface.get_selection().get_selected_nodes().is_empty():
		_selected_faces = []
	# Clip is the one tool that does NOT survive a deselect. Every other tool is a mode you keep
	# while hopping between brushes, but clip carries half-placed points that mean nothing once
	# there's nothing to cut — leaving it armed just strands them on screen.
	if _tool_mode == "clip" and EditorInterface.get_selection().get_selected_nodes().is_empty() \
			and is_instance_valid(_palette):
		_palette.clear_tool()
	# Re-target the ghost: a brush dropped from the selection has to be un-ghosted, or it stays
	# half-erased with nothing on screen explaining it.
	_clip_tool.update_ghost()
	# The guide spikes and dimension labels only belong to a brush that is BOTH hovered and
	# selected, but _update_hover re-tests that on mouse MOTION alone — so deselecting without
	# moving the cursor (Escape, or a click in the Scene dock) left them painted over a brush that
	# is no longer selected until the mouse happened to twitch.
	if is_instance_valid(_hover_brush) \
			and not (_hover_brush in EditorInterface.get_selection().get_selected_nodes()):
		_hover_brush = null
	# A brush selection is a full face selection to the inspector, so retarget it here too.
	_sync_texture_dock()
	_update_shape_bar()   # a selection hides the shape selector; clearing it brings it back
	# DEFERRED for the same reason the kernel release above is, and this is the one that actually
	# mattered. It reaches _selected_geometry(), which MATERIALISES a kernel per member of every
	# selected group — an add_child() each. Run straight from here, selecting a group in the Scene
	# tree mutates the scene tree while the editor is still settling that selection, the dock
	# re-syncs from stale state, and the pick is reverted ~35 ms later.
	#
	# It is group-specific for a reason: only a group has kernels, so only a group mutates anything
	# on being selected. Brushes and ordinary Godot nodes were always fine, which is exactly the
	# asymmetry that pointed here.
	_update_transform_bars.call_deferred()   # rotate/scale bars: refresh their pivot/size fields
	_csg_ops.update_menu()    # grey CSG items the current selection can't run
	_group_ops.update_menu()  # and the Group items, which count groups as well as brushes
	_physics_ops.update_menu()  # and the Physics items, which read the bodies the selection is in
	_update_toggle_hint() # highlight the toggle if a brush is selected while the mode is off
	update_overlays()


# --- Brush replacement (shared: CSG ops + .map paste) ---------------------

## Replace a set of brushes with a set of CSG blueprints as ONE undo step: the old nodes are removed
## and each blueprint becomes a fresh Brush. New brushes are forced to the identity transform before
## set_world_faces (CSG works in world space, so a world plane must land as the local plane), then
## recentred so their origin sits in their own geometry. The whole swap is one create_action, so a
## single Ctrl+Z brings the originals back and drops the results.
func _replace_brushes(old_nodes: Array, blueprints: Array, action_name: String) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null or blueprints.is_empty():
		return
	# The results stay where the inputs were, so a CSG op, a clip or an ungroup performed inside an
	# organising node keeps its geometry there instead of popping out to the scene root. Only a
	# selection spread across different parents falls back to the general rule.
	var parent := _shared_parent(old_nodes)
	if parent == null:
		parent = _brush_parent()
	# Collision follows the geometry: the results collide the way the inputs did. It is three property
	# values now rather than a set of nodes to move — the shapes themselves are the results' own
	# children, built on demand, so a clip or a subtract changing the COUNT of solids needs no thought
	# here at all.
	var kind: int = Collision.Body.STATIC
	var layer := 1
	var mask := 1
	for old in old_nodes:
		if "collision_type" in old:
			kind = old.get("collision_type")
			layer = old.get("collision_layer")
			mask = old.get("collision_mask")
			break

	# Build and configure the result nodes up front (still off-tree).
	var new_nodes: Array[Node3D] = []
	for _bp in blueprints:
		var brush := Brush.new()
		brush.grid_size = grid_size
		brush.texture_lock = texture_lock
		brush.uv_lock = uv_lock
		brush.collision_type = kind
		brush.collision_layer = layer
		brush.collision_mask = mask
		brush.name = "Brush"
		new_nodes.append(brush)

	var ur := get_undo_redo()
	ur.create_action(action_name)
	# Remove the inputs. Their collision goes with them, being their own children, and comes back with
	# them on undo for the same reason — there is nothing to record either way.
	for old in old_nodes:
		var old_parent: Node = old.get_parent()
		ur.add_do_method(old_parent, "remove_child", old)
		ur.add_undo_method(old_parent, "add_child", old, true)
		ur.add_undo_method(old, "set_owner", root)
		ur.add_undo_reference(old)
	# Add the results: parent, own, force world-identity, stamp the blueprint, recenter.
	for i in new_nodes.size():
		var brush := new_nodes[i]
		ur.add_do_method(parent, "add_child", brush, true)
		ur.add_do_method(brush, "set_owner", root)
		ur.add_do_property(brush, "global_transform", Transform3D.IDENTITY)
		ur.add_do_method(brush, "set_world_faces", blueprints[i])
		ur.add_do_method(brush, "recenter")
		ur.add_do_reference(brush)
		ur.add_undo_method(parent, "remove_child", brush)
	# Let go of the inputs BEFORE they are removed. A multi-node selection puts a MultiNodeEdit in the
	# inspector, which addresses its nodes by NODE PATH and re-resolves them on every refresh — commit
	# first and it is left holding paths to nodes that no longer exist, one "Node not found" per input
	# per refresh. The results are selected immediately below, so nothing is lost by clearing here.
	EditorInterface.get_selection().clear()
	ur.commit_action()

	# Select the results so the next action (and the overlay) targets them.
	_select_nodes(new_nodes)
	_selected_faces = []
	update_overlays()


# --- Grid size dropdown ---------------------------------------------------

func _build_toolbar() -> void:
	_option = OptionButton.new()
	_option.tooltip_text = "Grid / snap size (TrenchBroom units)"
	_option.fit_to_longest_item = true
	for i in SIZES.size():
		_option.add_item("Grid %s" % _format_tb(SIZES[i]), i)
	_option.select(_size_index)
	_option.item_selected.connect(_on_size_selected)


func _on_size_selected(index: int) -> void:
	_size_index = index
	grid_size = _cell_meters()
	_refresh_brush_grid_overlay()
	_sync_offset_nudge()


## Is the draw gesture live? This is the WHOLE of the Simple Shape tool: it has no palette button,
## because in TrenchBroom it is not something you switch on — it is simply what a drag means when
## nothing else has claimed it. So it needs the mode on, no tool owning the viewport, and nothing
## (brush or face) selected. A selection means the drag is reaching for THAT instead — box-select,
## or a move — so the gesture stands down rather than drawing over whatever the user just picked.
##
## Also the shape selector's visibility, which is why it is a predicate and not an inline test: the
## bar is how you choose cuboid/stairs/cylinder/cone, so it must be on screen exactly when this
## can fire, never a frame apart from it.
func _shape_gesture_live() -> bool:
	return _enabled and _tool_mode == "" \
			and EditorInterface.get_selection().get_selected_nodes().is_empty() \
			and _selected_faces.is_empty()


## The shape selector belongs to the draw gesture, so it shows exactly when a drag WOULD draw —
## every caller of this is a place that could have changed the answer.
func _update_shape_bar() -> void:
	if not is_instance_valid(_shape_bar):
		return
	_shape_bar.visible = _shape_gesture_live()


# --- Rotate / scale option bars (top toolbar) ------------------------------
# The Rotate and Scale tools each get a strip of options in the 3D editor's top menu, shown only
# while that tool is live and a brush is selected. They speak TB units (Z-up) like the rest of the
# UI; the plugin owns the pivot/geometry and does the maths, the bars are just widgets. See
# rotate_bar.gd / scale_bar.gd.

## Show the rotate bar in the Rotate tool and the scale bar in the Scale tool, each only when a
## brush is actually selected, and push the live pivot / size into whichever is visible.
func _update_transform_bars() -> void:
	# [b]Never ask for geometry just to decide whether a bar is visible.[/b] _selected_geometry()
	# MATERIALISES a kernel per member of every selected group — an add_child each — so calling it
	# unconditionally meant that merely SELECTING a group mutated the scene tree. The editor, still
	# settling that selection, re-synced from stale state and put the previous one back: which is why
	# a group could not be picked in the Scene tree while a brush, which has no kernels and so mutates
	# nothing, could. Only the rotate and scale bars read real geometry, and only while their tool is
	# up — a tool that is running needs the kernels anyway, because it deforms them.
	var rotate_up := _enabled and _tool_mode == "rotate"
	var scale_up := _enabled and _tool_mode == "scale"
	var has_brush := _has_selected_geometry()
	var brushes: Array[Node3D] = []
	if rotate_up or scale_up:
		brushes = _selected_geometry()
		has_brush = not brushes.is_empty()
	if is_instance_valid(_rotate_bar):
		_rotate_bar.visible = rotate_up and has_brush
		if _rotate_bar.visible:
			_rotate_bar.set_center_tb(_world_to_tb_point(_rotate_tool.center_for(brushes)))
	if is_instance_valid(_scale_bar):
		_scale_bar.visible = scale_up and has_brush
		if _scale_bar.visible:
			_scale_bar.set_size_tb(_world_size_to_tb(_selection_world_aabb(brushes).size))


## Is anything with geometry selected — WITHOUT building anything to find out?
##
## The cheap counterpart to [method _selected_geometry], for the callers that only need the yes/no.
## A group answers from its `members` data, so no kernel is raised and the scene tree is untouched.
func _has_selected_geometry() -> bool:
	if not _selected_brushes().is_empty():
		return true
	for group in _selected_groups():
		if not (group as BrushGroup).members.is_empty():
			return true
	return false


# TB is Z-up, Godot is Y-up; 32 TB units == 1 metre. These mirror map_io's conversion so the bars
# read out the same numbers TrenchBroom (and the .map clipboard) would.
func _world_to_tb_point(v: Vector3) -> Vector3:
	return Vector3(v.x, -v.z, v.y) * UNITS_PER_METER


func _tb_point_to_world(v: Vector3) -> Vector3:
	return Vector3(v.x, v.z, -v.y) / UNITS_PER_METER


## A bounding-box size (always positive), TB axes. Y and Z swap with the up-axis change; the sign
## flip on Z is irrelevant to an extent.
func _world_size_to_tb(v: Vector3) -> Vector3:
	return Vector3(absf(v.x), absf(v.z), absf(v.y)) * UNITS_PER_METER


func _tb_size_to_world(v: Vector3) -> Vector3:
	return Vector3(absf(v.x), absf(v.z), absf(v.y)) / UNITS_PER_METER


## A live edit of a Center field re-homes the pivot and holds it (so it isn't recomputed from the
## bounds on the next refresh), then redraws the ring widget at its new spot.
func _on_rotate_center_edited(center_tb: Vector3) -> void:
	_rotate_tool.center = _tb_point_to_world(center_tb)
	_rotate_tool.center_valid = true
	update_overlays()


## The angular step a ring drag snaps to, in degrees — whatever the rotate bar's angle field holds,
## so one control governs both the drag and Apply. Falls back to [constant ANGLE_SNAP_DEG] before
## the bar exists (during _enter_tree, and if a drag somehow outlives it).
func rotate_snap_deg() -> float:
	if not is_instance_valid(_rotate_bar):
		return ANGLE_SNAP_DEG
	return _rotate_bar.angle_snap_deg()


## Reset drops the held pivot so the tool recomputes it from the selection bounds, then pushes the
## fresh value back into the field.
func _on_rotate_center_reset() -> void:
	_rotate_tool.center_valid = false
	var brushes := _selected_geometry()
	if is_instance_valid(_rotate_bar) and not brushes.is_empty():
		_rotate_bar.set_center_tb(_world_to_tb_point(_rotate_tool.center_for(brushes)))
	update_overlays()


## Apply a one-shot rotation from the bar; the tool does the transform, we refresh the bar/overlay
## (button-fired, not viewport-fired, so nothing else redraws the wireframe).
func _on_rotate_apply(degrees: float, tb_axis: int) -> void:
	# Wrapped like a drag: the one-shot reshapes kernels exactly as a ring drag does, so the groups
	# need the same read-back — without it the rotation would land on the kernels and be dropped
	# with them, changing nothing.
	_begin_group_drag()
	_rotate_tool.apply_oneshot(degrees, tb_axis)
	_end_group_drag("Rotate Group")
	_update_transform_bars()
	update_overlays()


## Apply a one-shot scale from the bar. Both modes reduce to a per-axis Godot factor about the
## selection's centre: "size" divides the target size by the current one, "factors" is the factor
## straight through. Axes are remapped from TB (Z-up) to Godot (Y-up) — Y and Z swap.
func _on_scale_apply(mode: String, values: Vector3) -> void:
	# Wrapped like a drag, for the same reason as the rotate bar: scale_selection reshapes kernels
	# and commits through the same path, so the groups need the read-back or the scale is dropped
	# with the kernels.
	_begin_group_drag()
	var brushes := _selected_geometry()
	if brushes.is_empty():
		_end_group_drag("Scale Group")
		return
	var factor: Vector3
	if mode == "size":
		var target := _tb_size_to_world(values)          # desired Godot size
		var current := _selection_world_aabb(brushes).size
		factor = Vector3(
			target.x / current.x if current.x > 1e-6 else 1.0,
			target.y / current.y if current.y > 1e-6 else 1.0,
			target.z / current.z if current.z > 1e-6 else 1.0)
	else:
		factor = Vector3(values.x, values.z, values.y)   # TB axis order -> Godot axis order
	_scale_tool.scale_selection(brushes, factor)
	_end_group_drag("Scale Group")
	_update_transform_bars()


## A shape or parameter changed. Mid-draw, rebuild the live ghost for the new shape (invalidating the
## per-cell cache) so switching Cuboid→Cylinder or bumping the side count updates immediately.
func _on_shape_changed() -> void:
	if _drawing and _start != null and _current != null and is_instance_valid(_draw_camera):
		_preview_shape_key = ""
		_update_preview(_start, _current, _draw_camera)


## Step the grid one notch coarser (+1) or finer (-1), keeping the dropdown in sync.
func _step_grid(direction: int) -> void:
	var idx := clampi(_size_index + direction, 0, SIZES.size() - 1)
	if idx == _size_index:
		return   # already at the end of the range
	_size_index = idx
	grid_size = _cell_meters()
	if is_instance_valid(_option):
		_option.select(_size_index)   # select() doesn't emit item_selected, so no double-apply
	_refresh_brush_grid_overlay()
	_sync_offset_nudge()


## Re-render the grid overlay on every brush face at the new size (TrenchBroom does the same),
## and adopt the new snap for FUTURE edits. Geometry is left alone: the node's setter only floors
## the value and re-points the overlay shader at it, so assigning it never moves or re-snaps an
## existing brush. It must be kept current because set_from_points() re-snaps corners to the
## brush's OWN grid: left at the creation-time value, switching to a finer grid silently rounded
## every vertex/edge/face edit back to the coarse lattice the brush was drawn on.
func _refresh_brush_grid_overlay() -> void:
	# Previews included: an in-progress shape snaps on the same grid as the geometry it will join.
	for node in _scene_brushes(true):
		node.grid_size = grid_size
	# Groups hand it down to their kernels, so a group's face grid tracks the dropdown like every
	# other surface and its members reshape on the current grid.
	for group in _scene_groups():
		group.grid_size = grid_size


func _cell_meters() -> float:
	return SIZES[_size_index] / UNITS_PER_METER


## Push the current grid size to the texture dock as the offset field's ↑/↓ nudge (TB parity — the
## offset steps by one grid unit). Offset is shown in texels; the grid's TB-unit number carries over.
func _sync_offset_nudge() -> void:
	if is_instance_valid(_texture_dock):
		_texture_dock.set_offset_nudge(float(SIZES[_size_index]))


## "1.0" -> "1", "0.25" -> "0.25".
func _format_tb(v: float) -> String:
	return str(int(v)) if v == floorf(v) else str(v)


# --- Hide the selection AABB box ------------------------------------------

## Guarded so a second call can't capture the already-overridden values as the "originals"
## (which would make restore a no-op and strand the settings changed).
func _hide_selection_box() -> void:
	if _selection_box_hidden:
		return
	var es := EditorInterface.get_editor_settings()
	_saved.clear()
	for key in SELECTION_BOX_OVERRIDES:
		if es.has_setting(key):
			_saved[key] = es.get_setting(key)
			es.set_setting(key, SELECTION_BOX_OVERRIDES[key])
	_selection_box_hidden = true


func _restore_selection_box() -> void:
	if not _selection_box_hidden:
		return
	var es := EditorInterface.get_editor_settings()
	for key in _saved:
		es.set_setting(key, _saved[key])
	_saved.clear()
	_selection_box_hidden = false


# --- Viewport input / drawing ---------------------------------------------

## SHIFT belongs to Duckboard for the WHOLE gesture, even when the chord under it means nothing.
##
## The editor's viewport arms its rubber-band region select from a mouse MOTION, and the test it
## arms on is "nothing is selected yet, OR the append modifier is held" — and its append modifier is
## SHIFT. So every SHIFT drag that this plugin left unclaimed opened a selection box: a face push
## refused because its brush isn't selected, a drag that began on thin air, a shift chord inside a
## tool that doesn't use one. Worse, the box only closes on a release the EDITOR sees, and several
## of the release paths below consume theirs — so the rectangle stayed painted across the viewport
## until the next click, over a gesture that did nothing.
##
## Claiming it here rather than in the twenty-odd `return AFTER_GUI_INPUT_PASS` sites below is the
## whole point: this is one rule, applied once, and it cannot be forgotten at a branch added later.
## The gestures that DO own a shift chord (the face push, the hull extrude, proportional scale)
## already answer STOP on their own and never reach the upgrade.
func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	var result := _dispatch_3d_gui_input(camera, event)
	if not _shift_gesture:
		return result
	if not _enabled:
		_shift_gesture = false   # mode toggled off mid-drag: the gesture is no longer ours
		return result
	var mm := event as InputEventMouseMotion
	if mm != null:
		# The button mask is the only honest answer to "is the drag still running". A release over a
		# dock or outside the window never reaches _dispatch to clear the flag, and without this the
		# viewport would swallow motion for the rest of the session.
		if (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			_shift_gesture = false
			return result
		if result == AFTER_GUI_INPUT_PASS:
			return AFTER_GUI_INPUT_STOP
		return result
	# The PRESS has to be claimed too, not just the motion over it. Passing it and then stopping the
	# release is the shape that wedges the editor: its viewport records the pressed node and only
	# resolves it on a release it never gets, so it re-applies that node after every later selection
	# change (see the deliberate pass further down, which is why THAT one keeps both halves).
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed \
			and result == AFTER_GUI_INPUT_PASS:
		return AFTER_GUI_INPUT_STOP
	return result


func _dispatch_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if not _enabled:
		return AFTER_GUI_INPUT_PASS   # mode off: the viewport behaves like stock Godot

	# Remembered for the palette actions, which fire from a button press and so never receive a
	# camera. Flipping is defined relative to the view, so it needs the one you last looked
	# through — not viewport 0, which may not be the split you're working in.
	_last_camera = camera

	# ALT/SHIFT change what a scale drag MEANS (centre anchor, proportional), so the box has to
	# follow them mid-drag rather than waiting for the next mouse move.
	var modifier := event as InputEventKey
	# SHIFT arms the polygon extrude, so the highlight has to follow the KEY, not the next mouse
	# move — you'll usually be sitting still over the polygon when you press it.
	if modifier != null and _tool_mode == "brush" and modifier.keycode == KEY_SHIFT \
			and not _hull_tool.extruding:
		# `pressed` is the authority for the key this event is about; the modifier flags don't
		# reliably include it.
		var hovering := modifier.pressed and _hull_tool.polygon_hovered(camera, _hull_tool.screen)
		if hovering != _hull_tool.shift_hover:
			_hull_tool.shift_hover = hovering
			update_overlays()
		return AFTER_GUI_INPUT_PASS   # SHIFT keeps its meaning everywhere else

	if modifier != null and _shear_tool.active and modifier.keycode == KEY_ALT:
		_shear_tool.update_drag(camera, _shear_tool.screen, modifier.pressed)
		return AFTER_GUI_INPUT_STOP

	if modifier != null and _tool_mode == "scale" \
			and modifier.keycode in [KEY_ALT, KEY_SHIFT]:
		# For a modifier's OWN event, alt_pressed/shift_pressed describe the state as the event
		# was generated, which does not reliably include the key doing the pressing — reading
		# them here left ALT stuck on its pre-event value. `pressed` is the authority for
		# whichever key this event is about; the flags still stand for the other one.
		var alt_now := modifier.alt_pressed
		var shift_now := modifier.shift_pressed
		if modifier.keycode == KEY_ALT:
			alt_now = modifier.pressed
		else:
			shift_now = modifier.pressed
		if _scale_tool.active:
			_scale_tool.update_drag(camera, _scale_tool.screen, alt_now, shift_now)
			return AFTER_GUI_INPUT_STOP
		# Merely hovering: refresh the preview but let the key through, since ALT still has its
		# usual meaning everywhere else in the viewport.
		if alt_now != _scale_tool.center_anchor:
			_scale_tool.center_anchor = alt_now
			update_overlays()
		return AFTER_GUI_INPUT_PASS

	# ALT switches the pivot drag between the horizontal plane and the vertical line, and must follow
	# the KEY mid-drag (not wait for the next mouse move), same as the scale block above.
	if modifier != null and _rotate_tool.moving_center and modifier.keycode == KEY_ALT:
		_rotate_tool.center_alt = modifier.pressed
		_rotate_tool.update_drag(camera, _rotate_tool.screen)
		return AFTER_GUI_INPUT_STOP

	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		# Paste TrenchBroom's clipboard (.map brushes) as real brushes. CMD/CTRL+V, ahead of the
		# per-tool handling so it works whatever tool is active. Only claims the event when the
		# clipboard actually parses to brushes, so a stray CTRL+V still falls through otherwise.
		if key.keycode == KEY_V and (key.ctrl_pressed or key.meta_pressed) \
				and not key.shift_pressed and not key.alt_pressed:
			if _map_clipboard.paste():
				return _claim_key()
			return AFTER_GUI_INPUT_PASS
		# Copy the selected brushes as .map text (CTRL/CMD+C). Claims the event only when something
		# was copied, so an empty selection still falls through to the editor's own copy.
		if key.keycode == KEY_C and (key.ctrl_pressed or key.meta_pressed) \
				and not key.shift_pressed and not key.alt_pressed:
			if _map_clipboard.copy():
				return _claim_key()
			return AFTER_GUI_INPUT_PASS
		# TrenchBroom tool shortcuts (B/C/V/E/F/R/T/G, U, Ctrl+D, Ctrl+F, Ctrl+Alt+F). The palette
		# owns the key map and each button's enabled state, so a shortcut does exactly what clicking
		# its button would. Claimed whether or not the button is live so the editor's own single-key
		# bindings (R = rotate, F = focus, E/T transform modes) can't fire while the map editor is on
		# — this is the hard version of the soft lock in EditorToolMode.set_lock. Runs after copy/paste so
		# their Ctrl chords win, and before the per-tool gesture keys, none of which are letters.
		if is_instance_valid(_palette) and _palette.try_shortcut(key):
			return _claim_key()
		if _tool_mode == "brush":
			if key.keycode in [KEY_ENTER, KEY_KP_ENTER]:
				_hull_tool.commit()
				return AFTER_GUI_INPUT_STOP
			# All or nothing: TrenchBroom has no way to remove individual points either.
			if key.keycode == KEY_ESCAPE and not _hull_tool.placed.is_empty():
				_hull_tool.reset()
				update_overlays()
				return AFTER_GUI_INPUT_STOP
		if _tool_mode == "clip":
			if key.keycode in [KEY_ENTER, KEY_KP_ENTER]:
				if key.ctrl_pressed or key.meta_pressed:
					_clip_tool.cycle_mode()
				else:
					_clip_tool.apply()
				return AFTER_GUI_INPUT_STOP
			# Delete drops the most recent clip point rather than the selected brushes — while
			# the tool is mid-cut that's unmistakably what it means.
			if key.keycode == KEY_DELETE and not _clip_tool.points.is_empty():
				_clip_tool.remove_last_point()
				update_overlays()
				return AFTER_GUI_INPUT_STOP
			# Escape is a single step out of the whole gesture: drop the points AND the tool,
			# rather than requiring a second press. The brush selection is a level further out
			# and survives, exactly as it does for every other tool — another press drops it.
			if key.keycode == KEY_ESCAPE:
				_clip_tool.reset()
				if is_instance_valid(_palette):
					_palette.clear_tool()
				update_overlays()
				return AFTER_GUI_INPUT_STOP
		if key.keycode == KEY_DELETE:
			if _delete_selected_brushes():
				return AFTER_GUI_INPUT_STOP   # handled, so Godot never shows its dialog
			return AFTER_GUI_INPUT_PASS
		# Faces first: they're a selection in their own right, and Escape's job is to drop
		# whatever is currently selected before it starts dropping the tool.
		if key.keycode == KEY_ESCAPE and not _selected_faces.is_empty():
			_selected_faces = []
			_shift_face_hover = null
			_sync_texture_dock()
			_csg_ops.update_menu()   # the face-bridge greys back out once the faces are dropped
			_update_shape_bar()   # dropping the face selection re-arms drawing, so show the selector
			update_overlays()
			return AFTER_GUI_INPUT_STOP
		# Escape unwinds exactly ONE level per press, innermost first: the handles picked inside the
		# tool, then the tool itself, then the node selection, and last the open group. Each level is
		# a separate decision the user made, so a single keystroke undoing several of them would
		# always throw away more than was asked for.
		if key.keycode == KEY_ESCAPE and _tool_mode in ["vertex", "edge", "face"] \
				and not _handle_tools.selection.is_empty():
			_handle_tools.selection = PackedVector3Array()
			update_overlays()
			return AFTER_GUI_INPUT_STOP
		if key.keycode == KEY_ESCAPE and _tool_mode != "":
			if is_instance_valid(_palette):
				_palette.clear_tool()
			return AFTER_GUI_INPUT_STOP
		# Then the node selection, dropped HERE rather than by letting the key fall through to Godot.
		# Handing a step of the ladder to the editor made this rung silently stop working, and took the
		# group rung below with it — that one is gated on the selection being empty, so a deselect that
		# never happens is also a group that can never be left. Every rung is Duckboard's own now.
		if key.keycode == KEY_ESCAPE:
			var selection := EditorInterface.get_selection()
			if not selection.get_selected_nodes().is_empty():
				selection.clear()
				_selected_faces = []
				_update_transform_bars()
				_update_shape_bar()
				update_overlays()
				return AFTER_GUI_INPUT_STOP
		# LAST rung: with the faces dropped, the tool dropped and nothing selected, Escape leaves the
		# group. Deliberately last — Escape should clear your working state before it changes which
		# scope you are editing in, or one stray press would throw away the context you are in.
		if key.keycode == KEY_ESCAPE and _open_group != null \
				and EditorInterface.get_selection().get_selected_nodes().is_empty():
			_close_brush_group()
			return AFTER_GUI_INPUT_STOP
		# Grid size, TrenchBroom-style. CTRL/CMD are left alone so the editor's zoom
		# shortcuts keep working; SHIFT is allowed because '+' is Shift+'=' on most layouts.
		if not key.ctrl_pressed and not key.meta_pressed:
			if key.keycode in [KEY_EQUAL, KEY_PLUS, KEY_KP_ADD]:
				_step_grid(1)
				return AFTER_GUI_INPUT_STOP
			if key.keycode in [KEY_MINUS, KEY_KP_SUBTRACT]:
				_step_grid(-1)
				return AFTER_GUI_INPUT_STOP

	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			# Recorded BEFORE anything below claims or refuses the press, because the point of it is
			# to cover the branches that refuse. Assigned rather than only set, so an ordinary press
			# clears a flag a stray gesture left behind.
			_shift_gesture = mb.shift_pressed

			# ALT + face while exactly one face is selected: TrenchBroom's UV transfer.
			# ALT projects the source face's mapping onto the target,
			# ALT+SHIFT rotates it on, ALT+CTRL copies the material only. Click paints the clicked
			# face, double-click the whole brush, drag every face swept over. Checked FIRST so
			# ALT+SHIFT routes here rather than into the SHIFT face-push below, and so the single
			# source face stays selected to copy from.
			var copy_mode := _uv_copy_chord(mb)
			if _tool_mode == "" and copy_mode != "" and _selected_faces.size() == 1:
				# Groups included, or the ray passes straight THROUGH a group and transfers onto
				# whatever happens to be behind it.
				var copy_hit = _raycast_brush_faces(camera.project_ray_origin(mb.position),
					camera.project_ray_normal(mb.position), true)
				if copy_hit != null:
					_begin_uv_copy(copy_mode, copy_hit.node, copy_hit.face, mb.double_click)
				return AFTER_GUI_INPUT_STOP   # we own the ALT gesture whether or not it hit

			# SHIFT + face, outside any tool. A press arms both possibilities — push the face, or
			# select it — and the release decides, exactly as CTRL does for brushes.
			if _tool_mode == "" and mb.shift_pressed:
				# Groups included, so a closed group's faces can be SELECTED. The face-PUSH half of
				# this gesture refuses them without needing a guard: it only arms when the pressed
				# node is itself selected, and a kernel never is — picking maps it to its group.
				var face_hit = _raycast_brush_faces(camera.project_ray_origin(mb.position),
					camera.project_ray_normal(mb.position), true)
				if face_hit != null:
					_shift_face_press = {"node": face_hit.node, "face": face_hit.face}
					_shift_face_press_pos = mb.position
					_shift_face_press_point = face_hit.point
					# CTRL held decides the drag gesture: extrude a new brush rather than push.
					# On a click (no drag) CTRL still means "add to face selection" instead.
					_shift_face_ctrl = mb.ctrl_pressed
					return AFTER_GUI_INPUT_STOP
				# No face under the press. Answered PASS on its own terms — there is nothing here to
				# handle — and _forward_3d_gui_input turns it into a STOP anyway, because the editor
				# would read a shift drag over thin air as a rubber-band select.
				return AFTER_GUI_INPUT_PASS

			# Any click WITHOUT shift drops the face selection: clicking a brush means you meant
			# the brush, clicking empty space means you meant nothing. Falls through afterwards
			# so the click still selects, draws or arms a move as usual.
			if _tool_mode == "" and not _selected_faces.is_empty():
				_selected_faces = []
				_sync_texture_dock()
				_csg_ops.update_menu()   # the face-bridge greys back out once the faces are dropped
				_update_shape_bar()
				update_overlays()

			# CTRL on a handle builds the handle SELECTION rather than starting a drag — the
			# same binding that multi-selects brushes, one level down. Checked before the
			# per-tool grabs so it applies to all three uniformly.
			if _tool_mode in ["vertex", "edge", "face"] and mb.ctrl_pressed:
				var picked = _handle_tools.nearest_handle(camera, mb.position)
				if picked != null:
					_handle_tools.toggle_handle(picked)
					update_overlays()
					return AFTER_GUI_INPUT_STOP
				if mb.double_click and _open_group_under(camera, mb.position):
					return AFTER_GUI_INPUT_STOP
				if _leave_group_on_outside_press(camera, mb.position):
					return AFTER_GUI_INPUT_STOP
				if _select_member_under(camera, mb.position, mb.ctrl_pressed):
					return AFTER_GUI_INPUT_STOP
				return AFTER_GUI_INPUT_PASS

			# Vertex/edge modes own the mouse: grab a handle, else let the click select.
			if _tool_mode == "vertex":
				if _handle_tools.begin_vertex_drag(camera, mb.position):
					_begin_group_drag()   # reshaping a member of an open group folds into `members`
					return AFTER_GUI_INPUT_STOP
				if mb.double_click and _open_group_under(camera, mb.position):
					return AFTER_GUI_INPUT_STOP
				if _leave_group_on_outside_press(camera, mb.position):
					return AFTER_GUI_INPUT_STOP
				if _select_member_under(camera, mb.position, mb.ctrl_pressed):
					return AFTER_GUI_INPUT_STOP
				return AFTER_GUI_INPUT_PASS
			if _tool_mode == "edge":
				if _handle_tools.begin_edge_drag(camera, mb.position):
					_begin_group_drag()
					return AFTER_GUI_INPUT_STOP
				if mb.double_click and _open_group_under(camera, mb.position):
					return AFTER_GUI_INPUT_STOP
				if _leave_group_on_outside_press(camera, mb.position):
					return AFTER_GUI_INPUT_STOP
				if _select_member_under(camera, mb.position, mb.ctrl_pressed):
					return AFTER_GUI_INPUT_STOP
				return AFTER_GUI_INPUT_PASS
			if _tool_mode == "face":
				if _handle_tools.begin_face_drag(camera, mb.position):
					_begin_group_drag()
					return AFTER_GUI_INPUT_STOP
				if mb.double_click and _open_group_under(camera, mb.position):
					return AFTER_GUI_INPUT_STOP
				if _leave_group_on_outside_press(camera, mb.position):
					return AFTER_GUI_INPUT_STOP
				if _select_member_under(camera, mb.position, mb.ctrl_pressed):
					return AFTER_GUI_INPUT_STOP
				return AFTER_GUI_INPUT_PASS
			if _tool_mode == "scale":
				if _scale_tool.begin_drag(camera, mb.position):
					_begin_group_drag()
					return AFTER_GUI_INPUT_STOP
				if _leave_group_on_outside_press(camera, mb.position):
					return AFTER_GUI_INPUT_STOP
				if _select_member_under(camera, mb.position, mb.ctrl_pressed):
					return AFTER_GUI_INPUT_STOP
				return AFTER_GUI_INPUT_PASS
			if _tool_mode == "brush":
				# SHIFT extrudes the polygon placed so far along its normal; otherwise the press
				# starts a gesture whose kind (point / rectangle) is decided on release.
				if mb.shift_pressed and _hull_tool.begin_extrude(camera, mb.position):
					return AFTER_GUI_INPUT_STOP
				if mb.double_click:
					var hit = _hull_tool.target(camera, mb.position)
					if hit != null:
						var corners := PackedVector3Array()
						var to_world: Transform3D = hit.node.global_transform
						for p in hit.node.face_polygon(hit.face):
							corners.append(to_world * p)
						_hull_tool.add_points(corners)
						return AFTER_GUI_INPUT_STOP
					return AFTER_GUI_INPUT_PASS
				var target = _hull_tool.target(camera, mb.position)
				if target != null:
					_hull_tool.armed = true
					_hull_tool.press = mb.position
					_hull_tool.anchor = target.point
					_hull_tool.anchor_raw = target.raw
					_hull_tool.anchor_normal = target.normal
					return AFTER_GUI_INPUT_STOP
				return AFTER_GUI_INPUT_PASS
			if _tool_mode == "clip":
				if mb.double_click:
					if _clip_tool.match_face(camera, mb.position):
						return AFTER_GUI_INPUT_STOP
					return AFTER_GUI_INPUT_PASS
				# An existing point wins over placing a new one, so points stay adjustable.
				if _clip_tool.begin_point_drag(camera, mb.position):
					return AFTER_GUI_INPUT_STOP
				if _clip_tool.add_point(camera, mb.position):
					_clip_tool.pending_drag = true
					_clip_tool.press_pos = mb.position
					return AFTER_GUI_INPUT_STOP
				return AFTER_GUI_INPUT_PASS
			if _tool_mode == "rotate":
				# Ring drags take no modifiers at all and a held modifier refuses the drag; the
				# centre handle allows ALT (vertical move) but not SHIFT or CTRL.
				if _rotate_tool.begin_drag(camera, mb.position, mb.alt_pressed,
						mb.shift_pressed or mb.ctrl_pressed):
					_begin_group_drag()
					return AFTER_GUI_INPUT_STOP
				if _leave_group_on_outside_press(camera, mb.position):
					return AFTER_GUI_INPUT_STOP
				if _select_member_under(camera, mb.position, mb.ctrl_pressed):
					return AFTER_GUI_INPUT_STOP
				return AFTER_GUI_INPUT_PASS
			if _tool_mode == "shear":
				# SHIFT or CTRL held means this isn't a shear gesture at all — TrenchBroom
				# refuses to start the drag rather than ignoring them, leaving those chords
				# free for selection.
				if not mb.shift_pressed and not mb.ctrl_pressed \
						and _shear_tool.begin_drag(camera, mb.position):
					_begin_group_drag()
					return AFTER_GUI_INPUT_STOP
				if _leave_group_on_outside_press(camera, mb.position):
					return AFTER_GUI_INPUT_STOP
				if _select_member_under(camera, mb.position, mb.ctrl_pressed):
					return AFTER_GUI_INPUT_STOP
				return AFTER_GUI_INPUT_PASS

			# Double-click with no tool: open the group under the cursor, or close the one that is
			# open when the click lands outside it. Brush and clip keep their own double-click
			# meanings — this only runs when no tool owns the viewport.
			if _tool_mode == "" and mb.double_click and _open_group_under(camera, mb.position):
				return AFTER_GUI_INPUT_STOP

			# Outside the open group with no tool, a press is NOT an immediate leave. With a
			# selection it only deselects. With nothing selected it either starts a draw (drag)
			# or leaves the group (plain click) — decided on release via _group_close_pending,
			# which is what makes drag-to-draw possible inside an open group at all. CTRL is
			# left alone so paint-select keeps working over the members.
			if _tool_mode == "" and _open_group != null and not mb.ctrl_pressed \
					and _raycast_brushes(camera.project_ray_origin(mb.position),
						camera.project_ray_normal(mb.position)) == null:
				var group_sel := EditorInterface.get_selection()
				if not group_sel.get_selected_nodes().is_empty():
					group_sel.clear()
					_update_transform_bars()
					_update_shape_bar()
					update_overlays()
					return AFTER_GUI_INPUT_STOP
				if _shape_gesture_live():
					_group_close_pending = true
					_begin_box_draw(camera, mb.position)
					return AFTER_GUI_INPUT_STOP
				_close_brush_group()
				return AFTER_GUI_INPUT_STOP

			# Selecting a member is handled HERE in full — plain, CTRL and paint alike — rather than
			# left to the paths a closed brush uses. A member is an unowned node, so the editor's own
			# click-select cannot pick it at all, and routing only part of the gesture through the
			# ordinary machinery left CTRL and quick-select silently doing nothing.
			if _tool_mode == "" and _open_group != null:
				var member_hit = _raycast_brush_faces(camera.project_ray_origin(mb.position),
					camera.project_ray_normal(mb.position))
				if member_hit != null:
					var sel := EditorInterface.get_selection()
					if mb.ctrl_pressed:
						# Same split as outside a group: CTRL with nothing selected starts a paint
						# drag, CTRL on an existing selection adds or removes the one member.
						if sel.get_selected_nodes().is_empty():
							_paint_selecting = true
							_paint_select_at(camera, mb.position)
						else:
							_toggle_selected(member_hit.node)
						return AFTER_GUI_INPUT_STOP
					# Nothing selected: the press means DRAW, the same thing it means outside a
					# group — flush against the member face under the cursor. Selecting is what a
					# plain CLICK means, resolved on release via _group_click_member.
					if sel.get_selected_nodes().is_empty() and _shape_gesture_live():
						_group_click_member = member_hit.node
						_begin_box_draw(camera, mb.position)
						return AFTER_GUI_INPUT_STOP
					_select_only(member_hit.node)
					_selected_faces = []
					# Armed like any other brush press, so a drag still moves the member.
					_move_armed = true
					_move_press_pos = mb.position
					_move_plane_y = member_hit.point.y
					_move_grab_point = member_hit.point
					_move_alt = mb.alt_pressed
					_move_ctrl = false
					return AFTER_GUI_INPUT_STOP

			# No tool. Pressing a brush arms a MOVE (selection happens on RELEASE, if the press never
			# became a drag — see _select_clicked; the move
			# takes over past the drag threshold). CTRL means "add to the selection" and drives the
			# paint-select below. A press on EMPTY SPACE with nothing selected draws — that is
			# TrenchBroom's Simple Shape tool, which is never switched on, it is just what a drag
			# means when nothing else has claimed it (see _shape_gesture_live).
			_armed = false
			# Nothing selected + CTRL: press-and-drag PAINTS a selection (TrenchBroom quick
			# select). There's nothing to duplicate yet, so a CTRL drag here builds the selection
			# instead — every brush the held cursor sweeps over is added, and a plain click adds
			# just the one under it. Held from press to release via _paint_selecting. Checked
			# BEFORE the draw so a CTRL drag over thin air still opens a selection, not a brush.
			if mb.ctrl_pressed \
					and EditorInterface.get_selection().get_selected_nodes().is_empty():
				_paint_selecting = true
				_paint_select_at(camera, mb.position)
				return AFTER_GUI_INPUT_STOP
			# Nothing selected: DRAW, wherever the press landed — thin air OR an existing face.
			# Starting on a face is the point of it, that being how you build flush against what is
			# already there, and _begin_box_draw anchors on the surface it hits.
			#
			# This has to win over the move branch below, not just cover the empty-space case. With
			# an empty selection _begin_move bails (there is nothing to move), so arming a move left
			# _move_active false and every motion PASSing to Godot — which is what drew a box-select
			# rectangle over the drag instead of a brush. The move branch is unreachable-by-design
			# here: it needs a selection, and this predicate requires there be none.
			if _shape_gesture_live():
				_begin_box_draw(camera, mb.position)
				# CONSUMED, where this used to pass. The pass was only ever there so Godot's own
				# click-select would select the brush the press landed on; it cannot pick a solid any
				# more, and what it does instead is start a rubber-band select over the drag and then
				# resolve it against a selection this gesture has already changed — which lands the
				# previous brush back on screen as the selection just after a new one was drawn.
				# The gesture is ours from the press: nothing is left for the editor to do with it.
				return AFTER_GUI_INPUT_STOP
			# Groups included: CTRL+click has to reach them, or adding a group to a selection
			# falls through to Godot, whose append modifier is SHIFT — so the click reads as a
			# plain one and REPLACES the selection.
			var grabbed = _raycast_brushes(
				camera.project_ray_origin(mb.position), camera.project_ray_normal(mb.position),
				true)
			if grabbed != null:
				_move_armed = true
				_move_press_pos = mb.position
				_move_plane_y = grabbed.point.y
				_move_grab_point = grabbed.point
				_move_alt = mb.alt_pressed
				_move_ctrl = mb.ctrl_pressed
				# Re-anchor on the SURFACE wherever the exact pick can say where that is. `grabbed` is
				# a bounding-box hit, and the box around a group is the box around a whole room — for a
				# level-spanning one the ray enters it nowhere near any geometry, which would start the
				# drag at a point the user never touched and make it jump on the first motion.
				var press_face = _raycast_brush_faces(
					camera.project_ray_origin(mb.position),
					camera.project_ray_normal(mb.position), true)
				if press_face != null:
					_move_plane_y = press_face.point.y
					_move_grab_point = press_face.point
				# Grabbing something OUTSIDE the current selection makes it the selection, here on the
				# PRESS — because the drag this may turn into moves the selection, not the thing under
				# the cursor. Godot's own click-select used to do this for us on the passed-through
				# press; it cannot pick a solid any more, so pressing one brush and dragging moved a
				# different, still-selected one. Already-selected targets are left alone, so pressing
				# one brush of a multi-selection still drags the whole set.
				if not mb.ctrl_pressed:
					var press_target: Node = _selectable_of(press_face.node) if press_face != null \
							else grabbed.node
					var press_sel := EditorInterface.get_selection()
					if press_target != null and is_instance_valid(press_target) \
							and not (press_target in press_sel.get_selected_nodes()):
						_select_only(press_target)
						_selected_faces = []
				if mb.ctrl_pressed:
					# CTRL+click toggles selection, CTRL+drag duplicates — and which one
					# this is isn't known until the mouse either moves or doesn't. Consume
					# the press so Godot's plain-click "replace the selection" never runs,
					# and decide on release.
					#
					# Pick the toggle target by exact mesh face, not the bounding-box hit
					# above: with brushes packed close together one brush's AABB overlaps the
					# one actually under the cursor, and the coarse pick would toggle the
					# wrong (close-by) brush. The face pick matches what a plain click selects,
					# and the anchor it implies has already been applied above.
					if press_face != null:
						# A group face answers as that member's KERNEL, which is not something
						# the user can select — the group is.
						_ctrl_click_node = _selectable_of(press_face.node)
					else:
						_ctrl_click_node = grabbed.node
					return AFTER_GUI_INPUT_STOP
				# PASSED, deliberately, even though the selection is already made above and Godot's
				# click-select can no longer pick a solid.
				#
				# Consuming it here looked free and was not. Godot's viewport records the node a press
				# landed on and only resolves it on the RELEASE; swallow both and that pending node is
				# never cleared, so the editor re-applies it after every later selection change — a
				# brush pressed once in the viewport became impossible to select away from, in the
				# Scene dock as much as anywhere. Traced: six dock picks in a row, each reverted ~35 ms
				# later to the pressed group, with nothing in the plugin writing the selection.
				#
				# The cost of passing is that Godot may start a rubber-band box over the drag. That is
				# a cosmetic annoyance; a selection that cannot be changed is not.
			# Nothing under the cursor, with something selected. `_shape_gesture_live` refuses to draw
			# while a selection stands, and rightly so — a drag that starts ON a brush has to move it.
			# But a drag starting on EMPTY SPACE can't move anything, so drawing is its only sensible
			# meaning, and requiring a deselect first turns "draw a row of brushes" into a press of
			# Escape between every one.
			#
			# It claims the drag Godot would have used for a rubber-band select. That box cannot pick a
			# solid any more (their meshes are unowned), so in a Duckboard scene it selects nothing —
			# but it CAN still catch lights, markers and other ordinary nodes, and that goes with this.
			# CTRL is left alone, so the paint-select gesture above still reaches empty space.
			#
			# `grabbed == null` is load-bearing: the branch above does NOT return for a plain press on
			# a solid — it arms a move and falls through to here — so without this test, pressing a
			# brush would arm a move AND start a draw, and every click would build a brush.
			if grabbed == null and _tool_mode == "" and not mb.ctrl_pressed \
					and _selected_faces.is_empty():
				_begin_box_draw(camera, mb.position)
				return AFTER_GUI_INPUT_STOP
			return AFTER_GUI_INPUT_PASS
		else:
			# The gesture ends here however it is answered below, so the flag is dropped up front and
			# the rest of this ladder reads the local. Every early return past this point would
			# otherwise have to remember to clear it.
			var shift_gesture := _shift_gesture
			_shift_gesture = false

			if _paint_selecting:
				# End the CTRL paint gesture. Every swept brush was added live during the drag,
				# so release just closes it out.
				_paint_selecting = false
				return AFTER_GUI_INPUT_STOP
			if _uv_copy_active:
				_commit_uv_copy()   # bank the whole ALT gesture as one undo step
				return AFTER_GUI_INPUT_STOP
			if _push_active:
				_commit_face_push()
				_shift_face_press = null
				return AFTER_GUI_INPUT_STOP
			if _shift_face_press != null:
				# Pressed on a face with SHIFT and never dragged: that was a selection click.
				var entry = _shift_face_press
				_shift_face_press = null
				# CTRL+SHIFT adds to the face selection, the same way CTRL adds to the brush
				# selection — SHIFT picks the level, CTRL says "as well as".
				_select_face(entry.node, entry.face, mb.ctrl_pressed)
				return AFTER_GUI_INPUT_STOP
			if not _handle_tools.vertex_nodes.is_empty():
				_handle_tools.commit_vertex_drag()
				_end_group_drag("Reshape Group")
				return AFTER_GUI_INPUT_STOP
			if not _handle_tools.edge_nodes.is_empty():
				_handle_tools.commit_edge_drag()
				_end_group_drag("Reshape Group")
				return AFTER_GUI_INPUT_STOP
			if not _handle_tools.face_nodes.is_empty():
				_handle_tools.commit_face_drag()
				_end_group_drag("Reshape Group")
				return AFTER_GUI_INPUT_STOP
			if _scale_tool.active:
				_scale_tool.commit_drag()
				_end_group_drag("Scale Group")
				return AFTER_GUI_INPUT_STOP
			if _shear_tool.active:
				_shear_tool.commit_drag()
				_end_group_drag("Shear Group")
				return AFTER_GUI_INPUT_STOP
			if _rotate_tool.active:
				_rotate_tool.commit_drag()
				_end_group_drag("Rotate Group")
				return AFTER_GUI_INPUT_STOP
			if _hull_tool.extruding:
				_hull_tool.commit_extrude()
				return AFTER_GUI_INPUT_STOP
			if _hull_tool.armed:
				# No drag: a single point. Dragged: the rectangle it swept out.
				if _hull_tool.rect.is_empty():
					_hull_tool.add_points(PackedVector3Array([_hull_tool.anchor]))
				else:
					_hull_tool.add_points(_hull_tool.rect)
					_hull_tool.rect = PackedVector3Array()
				_hull_tool.armed = false
				return AFTER_GUI_INPUT_STOP
			if _clip_tool.drag_index >= 0 or _clip_tool.pending_drag:
				_clip_tool.drag_index = -1
				_clip_tool.pending_drag = false
				return AFTER_GUI_INPUT_STOP
			if _move_armed:
				var was_moving := _move_active
				var ctrl_clicked := _ctrl_click_node
				if was_moving:
					_commit_move()
				_reset_move()
				_ctrl_click_node = null
				# Pressed with CTRL and never dragged: that was a multi-select click.
				if not was_moving and ctrl_clicked != null:
					_toggle_selected(ctrl_clicked)
					return AFTER_GUI_INPUT_STOP
				# A plain click (no drag) SELECTS. This used to pass the event to Godot and let its own
				# click-select do the work, which no longer picks a solid at all — see _select_clicked.
				if not was_moving and _select_clicked(camera, mb.position):
					return AFTER_GUI_INPUT_STOP
				# `shift_gesture` in the test, and it is the one PASS in this ladder that could
				# outrun the catch-all below. No shift press can arm a move today — the shift branch
				# claims the press long before the move branch is reached — so this is unreachable,
				# and it is written anyway because the alternative is a rule enforced from two
				# hundred lines away. Passing a release whose PRESS was consumed is the exact shape
				# that wedges the editor's pending-click node, and it should not be one refactor away.
				return AFTER_GUI_INPUT_STOP if (was_moving or shift_gesture) \
					else AFTER_GUI_INPUT_PASS
			# A SHIFT gesture nothing above claimed ends HERE, doing nothing at all — the face push
			# was refused, or there was never a face under the press. Falling through would read the
			# release as a plain click and select whatever the cursor has drifted over, or clear the
			# selection when it has drifted over nothing; neither is what the user asked for by
			# holding SHIFT. Placed after every commit branch, so the shift chords the tools DO use
			# (proportional scale, hull extrude) still land their drag.
			if shift_gesture:
				return AFTER_GUI_INPUT_STOP
			var was_drawing := _drawing
			# Armed a draw is not the same as having DRAWN one: with nothing selected a press on a
			# brush arms the shape gesture, and only a drag gives it an extent. No extent means the
			# gesture was a plain click, and a plain click selects (below).
			var drew := _drawing and _current != null
			if drew:
				_commit_shape(_start, _current, camera)
			# The press that armed this gesture landed outside the open group with nothing
			# selected: a drag drew inside the group, which therefore stays open around its new
			# brush; a plain click is the leave.
			var leave_group := _group_close_pending and not was_drawing
			var click_member: Node3D = _group_click_member if not was_drawing else null
			_group_close_pending = false
			_reset_draw()
			# The press landed on a member with nothing selected and never became a drag: a
			# click, and a click selects.
			if click_member != null and is_instance_valid(click_member):
				_select_only(click_member)
				update_overlays()
				return AFTER_GUI_INPUT_STOP
			if leave_group:
				_close_brush_group()
				return AFTER_GUI_INPUT_STOP
			# The gesture armed a draw but never got an extent: a plain click on whatever was under the
			# cursor, and a click selects. This is the path a press with NOTHING selected takes, so
			# without it the first selection of a session could never be made.
			#
			# Guarded on the selection still being EMPTY, which is the whole point: this branch is only
			# reachable when nothing was selected at press time (_shape_gesture_live requires it), so
			# anything selected by now was selected BY THIS GESTURE — a committed shape selects the
			# brush it just made. Without the guard that new brush is immediately replaced by whatever
			# happens to sit under the cursor, which is the surface the shape was drawn against.
			# `not drew` is the whole guard: a committed shape selects the brush it just made, and
			# without it that brush would be replaced a line later by whatever sits under the cursor —
			# which is the surface the shape was drawn against.
			if not drew:
				if _select_clicked(camera, mb.position):
					return AFTER_GUI_INPUT_STOP
				# Nothing under the cursor, so the gesture was a click on EMPTY SPACE, which deselects.
				# Done here rather than left to Godot: the press is consumed above so a drag on empty
				# space can draw, which means the release never reaches the editor to be read as one.
				var empty_sel := EditorInterface.get_selection()
				if not empty_sel.get_selected_nodes().is_empty() or not _selected_faces.is_empty():
					empty_sel.clear()
					_selected_faces = []
					_update_transform_bars()
					_update_shape_bar()
					update_overlays()
					return AFTER_GUI_INPUT_STOP
			return AFTER_GUI_INPUT_STOP if was_drawing else AFTER_GUI_INPUT_PASS

	var mm := event as InputEventMouseMotion
	if mm != null:
		_draw_camera = camera          # keep the overlay's camera fresh for hover drawing
		_update_hover(camera, mm.position)

	# CTRL paint select: keep adding whatever brush the held cursor sweeps over. Runs before the
	# drag branches below because while it's active none of them are (the press consumed the click).
	if mm != null and _paint_selecting:
		_paint_select_at(camera, mm.position)
		return AFTER_GUI_INPUT_STOP

	# ALT drag-paint: copy onto every face swept over, each transferring from the LAST
	# painted face so the alignment flows continuously along the run (TrenchBroom).
	if mm != null and _uv_copy_active:
		var paint_hit = _raycast_brush_faces(camera.project_ray_origin(mm.position),
			camera.project_ray_normal(mm.position), true)
		if paint_hit != null and _paint_uv_copy(paint_hit.node, paint_hit.face):
			_uv_copy_from = {"node": paint_hit.node, "face": paint_hit.face}
			update_overlays()
		return AFTER_GUI_INPUT_STOP
	if mm != null and not _handle_tools.vertex_nodes.is_empty():
		_handle_tools.update_vertex_drag(camera, mm.position, mm.alt_pressed)
		return AFTER_GUI_INPUT_STOP

	if mm != null and not _handle_tools.edge_nodes.is_empty():
		_handle_tools.update_edge_drag(camera, mm.position, mm.alt_pressed)
		return AFTER_GUI_INPUT_STOP

	if mm != null and not _handle_tools.face_nodes.is_empty():
		_handle_tools.update_face_drag(camera, mm.position, mm.alt_pressed)
		return AFTER_GUI_INPUT_STOP

	if mm != null and _scale_tool.active:
		_scale_tool.update_drag(camera, mm.position, mm.alt_pressed, mm.shift_pressed)
		return AFTER_GUI_INPUT_STOP

	# Idle in scale mode: track which handle is targeted so the overlay can highlight it before
	# the click, which is the only cue that picking doesn't need an exact hover.
	if mm != null and _push_active:
		_update_face_push(camera, mm.position)
		return AFTER_GUI_INPUT_STOP

	# Dragging away from a SHIFT-pressed face pushes it (or extrudes a new brush, with CTRL), but
	# only if its brush is SELECTED — reshaping or building off geometry you haven't selected
	# would be far too easy to do by accident.
	if mm != null and _shift_face_press != null:
		if mm.position.distance_to(_shift_face_press_pos) > DRAG_THRESHOLD_PX:
			if _shift_face_press.node in EditorInterface.get_selection().get_selected_nodes() \
					and _begin_face_push(camera, _shift_face_press.node, _shift_face_press.face,
						_shift_face_ctrl, _shift_face_press_point):
				_update_face_push(camera, mm.position)
			else:
				_shift_face_press = null
		return AFTER_GUI_INPUT_STOP

	# SHIFT hover: outline the face the cursor is over, so it's clear what a click would take. Skipped
	# while a camera-navigation button is held (RMB mouse-look, MMB orbit/pan) — that motion is moving
	# the view, not picking a face, and leaving the highlight on during a look reads as a stray glitch.
	if mm != null and _tool_mode == "":
		var previous = _shift_face_hover
		_shift_face_hover = null
		var navigating := (mm.button_mask & (MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_MIDDLE)) != 0
		if mm.shift_pressed and not navigating:
			var hit = _raycast_brush_faces(camera.project_ray_origin(mm.position),
				camera.project_ray_normal(mm.position), true)
			if hit != null:
				_shift_face_hover = {"node": hit.node, "face": hit.face}
		if str(previous) != str(_shift_face_hover):
			update_overlays()

	# Handle hover for the reshape tools. Skipped mid-drag: the handle is already committed, and
	# re-picking under a moving cursor would make the readout jump to a neighbour.
	if mm != null and _tool_mode in ["vertex", "edge", "face"] \
			and _handle_tools.vertex_nodes.is_empty() and _handle_tools.edge_nodes.is_empty() and _handle_tools.face_nodes.is_empty():
		var hovered = _handle_tools.nearest_handle(camera, mm.position)
		if hovered != _handle_tools.hover:
			_handle_tools.hover = hovered
			update_overlays()

	if mm != null and _hull_tool.extruding:
		_hull_tool.update_extrude(camera, mm.position)
		return AFTER_GUI_INPUT_STOP

	if mm != null and _tool_mode == "brush" and not _hull_tool.armed:
		_hull_tool.screen = mm.position
		var hovering := mm.shift_pressed and _hull_tool.polygon_hovered(camera, mm.position)
		if hovering != _hull_tool.shift_hover:
			_hull_tool.shift_hover = hovering
			update_overlays()

	if mm != null and _hull_tool.armed:
		if mm.position.distance_to(_hull_tool.press) > DRAG_THRESHOLD_PX:
			var target = _hull_tool.target(camera, mm.position)
			if target != null:
				# The rectangle stays on the face the drag STARTED on, so crossing onto a
				# neighbouring face mid-drag can't tilt it out of that plane.
				_hull_tool.rect = _hull_tool.rectangle(_hull_tool.anchor_raw, target.raw,
					_hull_tool.anchor_normal, _hull_tool.anchor)
				_hull_tool.rebuild_preview()
				update_overlays()
		return AFTER_GUI_INPUT_STOP

	# Dragging away from a just-placed point plants the second one and hands the drag straight to
	# it, so the pair is positioned in a single gesture.
	if mm != null and _clip_tool.pending_drag and _clip_tool.drag_index < 0:
		# Keep RETRYING until a distinct point can be placed, rather than giving up on the first
		# failure. The drag threshold is in pixels but the point snaps in world units, so the
		# first few pixels of movement land on the same grid position as the point just placed
		# — a legitimate duplicate rejection. Cancelling there killed the whole gesture before
		# it could reach the next cell.
		if mm.position.distance_to(_clip_tool.press_pos) > DRAG_THRESHOLD_PX \
				and _clip_tool.add_point(camera, mm.position):
			_clip_tool.drag_index = _clip_tool.points.size() - 1
		return AFTER_GUI_INPUT_STOP

	if mm != null and _clip_tool.drag_index >= 0:
		_clip_tool.update_point_drag(camera, mm.position)
		return AFTER_GUI_INPUT_STOP

	if mm != null and _tool_mode == "clip":
		_clip_tool.update_hover(camera, mm.position)

	if mm != null and _rotate_tool.active:
		_rotate_tool.update_drag(camera, mm.position)
		return AFTER_GUI_INPUT_STOP

	if mm != null and _tool_mode == "rotate":
		var rot_brushes := _selected_geometry()
		var axis := -1
		var on_center := false
		if not rot_brushes.is_empty():
			var c := _rotate_tool.center_for(rot_brushes)
			on_center = not camera.is_position_behind(c) \
				and mm.position.distance_to(camera.unproject_position(c)) < RING_GRAB_PX
			if not on_center:
				axis = _rotate_tool.pick_ring(camera, mm.position, c, _rotate_tool.ring_radius(camera, c))
		if axis != _rotate_tool.hover_axis or on_center != _rotate_tool.hover_center:
			_rotate_tool.hover_axis = axis
			_rotate_tool.hover_center = on_center
			update_overlays()

	if mm != null and _shear_tool.active:
		_shear_tool.update_drag(camera, mm.position, mm.alt_pressed)
		return AFTER_GUI_INPUT_STOP

	if mm != null and _tool_mode == "shear":
		var shear_brushes := _selected_geometry()
		var shear_dir := Vector3i.ZERO
		if not shear_brushes.is_empty():
			shear_dir = _pick_scale_handle(
				camera, mm.position, _selection_world_aabb(shear_brushes), false)
		if shear_dir != _shear_tool.hover_dir:
			_shear_tool.hover_dir = shear_dir
			update_overlays()

	if mm != null and _tool_mode == "scale":
		_scale_tool.screen = mm.position
		var brushes := _selected_geometry()
		var dir := Vector3i.ZERO
		if not brushes.is_empty():
			dir = _pick_scale_handle(camera, mm.position, _selection_world_aabb(brushes))
		if dir != _scale_tool.hover_dir or mm.alt_pressed != _scale_tool.center_anchor:
			_scale_tool.hover_dir = dir
			_scale_tool.center_anchor = mm.alt_pressed
			update_overlays()

	if mm != null and _move_armed:
		if not _move_active and mm.position.distance_to(_move_press_pos) > DRAG_THRESHOLD_PX:
			_begin_move(camera, mm.position)
		if _move_active:
			_update_move(camera, mm.position, mm.alt_pressed)
			return AFTER_GUI_INPUT_STOP
		return AFTER_GUI_INPUT_PASS

	if mm != null and _armed:
		if not _drawing and mm.position.distance_to(_press_pos) > DRAG_THRESHOLD_PX:
			_begin_preview()
			_drawing = true
		if _drawing:
			var alt_now := mm.alt_pressed
			var shift_now := mm.shift_pressed
			# ALT *alone* drags the vertical line (TrenchBroom tests modifiers for exact
			# equality, so ALT+SHIFT stays a horizontal drag and squares all three axes).
			var line_drag := alt_now and not shift_now
			if alt_now != _alt or shift_now != _square:
				# Modifiers changed: re-anchor the constraint at the CURRENT handle position
				# so the cursor already sits on it — no jump, and no runaway feedback from
				# re-deriving the anchor every frame.
				if line_drag:
					_alt_line_point = _current
				else:
					_plane_coord = _current.y   # horizontal plane at the current height
			_alt = alt_now
			_square = shift_now

			var handle = _line_drag_point(camera, mm.position) if line_drag \
				else _point_on_plane(camera, mm.position)
			if handle != null:
				if line_drag:
					# Snap the vertical handle to the NEAREST grid line rather than handing
					# _box_from a raw height, which rounds outward (floor the low end, ceil the
					# high end) and so grew the box by a WHOLE cell the instant the cursor
					# crossed a line.
					handle.y = _grid_origin_y + snappedf(handle.y - _grid_origin_y, grid_size)
				_current = handle
			_update_preview(_start, _current, camera)
		return AFTER_GUI_INPUT_STOP   # consume motion so Godot doesn't box-select

	return AFTER_GUI_INPUT_PASS


# --- Draw plane -----------------------------------------------------------

func _setup_draw_plane(camera: Camera3D, screen_pos: Vector2) -> void:
	# Always draw on a horizontal (XZ) plane and extrude up — never a vertical wall, even
	# when starting on a side face.
	#
	# Draw-plane HEIGHT (matches TrenchBroom): a brush hit uses the hit
	# point's height; a miss uses the height of the point DEFAULT_POINT_DISTANCE (8 m == 256
	# TB units) along the pick ray THROUGH THE MOUSE — so aiming lower draws lower. The
	# height is floored to the grid so the base encloses that point, as TB does.
	_axis = 1
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	# FACE-accurate, matching TrenchBroom, whose initial handle is a BrushHitType hit point. The
	# AABB pick used here before answered with a point on a BOUNDING BOX rather than on the face
	# clicked: against packed geometry one brush's box overlaps the solid actually under the
	# cursor, so the press point could land INSIDE it and the first cell started buried, which is
	# only escaped by dragging clear of the whole cell. The CTRL-click path already re-picks with
	# this raycast, and for the same reason. It costs a per-face test, but runs once per press.
	#
	# Groups count here: a closed group is a surface you draw ON, like any brush, so the draw plane
	# takes its height from one. What gets drawn lands as an ordinary sibling — a closed group never
	# absorbs geometry built against it (only an OPEN group adopts, see _brush_parent).
	#
	# ignore_isolation: with a group OPEN the pick is normally fenced to its members, but the
	# anchor only needs a surface to stand on — hitting an outside face edits nothing, and it is
	# how a brush is drawn INTO the group flush against the world around it.
	var hit = _raycast_brush_faces(from, dir, true, true)
	_hit_point = hit.point if hit != null else null
	# Which way the face LOOKS, from its own outward normal rather than from a box side, so an
	# angled face answers with the axis it most nearly faces. A press lands exactly ON the face, so
	# on a grid-aligned one that axis comes out zero-width — see the outward snap in _box_from,
	# which needs this to know which of the two neighbouring cells is the one outside the surface.
	if hit != null:
		var n: Vector3 = hit.normal
		var an := n.abs()
		_face_axis = 0 if (an.x >= an.y and an.x >= an.z) else (1 if an.y >= an.z else 2)
		_face_sign = signf(n[_face_axis])
	else:
		_face_axis = -1
		_face_sign = 0.0
	# Only a HORIZONTAL face (axis 1 — a floor or a ceiling) carries a height worth being flush
	# with. That is the surface you are building on, so the plane IS it and the vertical grid
	# anchors to it: flooring it to the grid instead sinks the base INTO the brush underneath
	# whenever the face isn't itself grid-aligned — a brush topping out at 2.3 on a 0.5 grid
	# started at 2.0, buried by 0.3, and a face thinner than the grid was buried whole.
	#
	# A VERTICAL face carries no such height. The point up a wall where the ray landed is just
	# wherever the mouse happened to be, so pinning the base to it stood the new brush at an
	# arbitrary mid-cell height against a perfectly grid-aligned wall. Walls and empty space both
	# fall back to the world grid, floored so the base encloses the aimed-at point, as TB does.
	# The plane passes through the PRESS POINT itself, never a rounded version of it — exactly
	# TrenchBroom's horizontal_plane(initialHandlePosition). The drag reads the cursor by
	# intersecting this plane every motion event, so a plane sitting even slightly below the point
	# clicked makes that very first intersection land somewhere else: against a wall the ray
	# carries on THROUGH it, putting the cursor most of a cell inside the solid before the mouse
	# has moved at all. That is what made the first cell start buried and take a long drag to pull
	# clear. Rounding belongs to the BOUNDS (below), not to the plane the gesture is measured on.
	_plane_coord = hit.point.y if hit != null \
		else (from + dir * DEFAULT_POINT_DISTANCE).y
	if hit != null and _face_axis == 1:
		_grid_origin_y = hit.point.y
		# Which way the brush leaves the surface is decided by the SURFACE ITSELF, never by where
		# the camera is: the face's outward normal points away from the solid, so a floor builds
		# upward and a ceiling hangs downward, whichever side you happen to be viewing from.
		# Testing the camera instead made one and the same click build in opposite directions
		# depending on whether you were looking down at it or up at it.
		_draw_grows_up = _face_sign > 0.0
	else:
		_grid_origin_y = 0.0
		_draw_grows_up = true   # a wall or thin air has no side to prefer: up, as TB does


## Arm a box-draw gesture for the Brush tool. The drag is drawn and committed by the shared
## _armed/_drawing machinery in the motion + release handlers, so this just seeds the base corner
## (at the clicked surface, or the default draw plane in empty space) and lets that machinery run.
func _begin_box_draw(camera: Camera3D, screen_pos: Vector2) -> void:
	_armed = true
	_press_pos = screen_pos
	_setup_draw_plane(camera, screen_pos)
	# Anchor at the SURFACE clicked rather than where the ray carries on to meet the (often lower)
	# draw plane, so starting on a side face doesn't bury the first cells inside the existing brush.
	if _hit_point != null:
		_start = Vector3(_hit_point.x, _plane_coord, _hit_point.z)
	else:
		_start = _point_on_plane(camera, screen_pos)
	if _start == null:
		_armed = false
	else:
		_current = _start   # handle starts on the base corner


## Raw world point where the mouse ray meets the draw plane (already exact on the plane
## axis). Grid snapping happens later in _box_from. Null if the ray is parallel to the plane.
func _point_on_plane(camera: Camera3D, screen_pos: Vector2):
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	return Plane(_axis_vector(_axis), _plane_coord).intersects_ray(from, dir)


## Box spanning the base corner and the current handle — TrenchBroom's snapBounds():
## min snaps DOWN, max snaps UP (always outward), then any flat axis gets one cell on the
## side away from the camera. There is no separate "height": the handle carries all 3 axes.
func _box_from(a: Vector3, b: Vector3, cam_pos: Vector3) -> Dictionary:
	var g := grid_size

	# SHIFT squares the footprint; with ALT as well, the height matches too -> cube.
	if _square:
		var dx := b.x - a.x
		var dz := b.z - a.z
		var m := maxf(absf(dx), absf(dz))
		b.x = a.x + (m if dx >= 0.0 else -m)
		b.z = a.z + (m if dz >= 0.0 else -m)
		if _alt:
			var dy := b.y - a.y
			b.y = a.y + (m if dy >= 0.0 else -m)

	var lo := [minf(a.x, b.x), minf(a.y, b.y), minf(a.z, b.z)]
	var hi := [maxf(a.x, b.x), maxf(a.y, b.y), maxf(a.z, b.z)]
	var cam := [cam_pos.x, cam_pos.y, cam_pos.z]
	# The footprint always snaps to the WORLD grid, but the vertical axis snaps to _grid_origin_y —
	# the face being built on, or 0 in empty space. Rounding height against the world grid instead
	# would pull the base straight back off a face that isn't grid-aligned (see _setup_draw_plane).
	var origin := [0.0, _grid_origin_y, 0.0]

	# The brush ALWAYS keeps the whole grid cell the PRESS POINT sits in, on the draw-plane axis.
	# Without that the span is just min..max of the base corner and the ALT handle, so dragging the
	# handle below the plane made it the new base and the whole brush jumped to the far side — it
	# MOVED a level instead of growing one. It also settles the zero-height case outright: the
	# height can no longer reach the camera test below, which is what made one and the same drag
	# build up or down depending on where you happened to be standing.
	#
	# The CONTAINING cell, note, not "one cell from the press point" — the plane is deliberately
	# unrounded, so measuring a cell off an off-grid press straddles two of them and hands back a
	# brush twice as tall as it should be.
	var o: float = origin[_axis]
	var cell_lo := floorf((a[_axis] - o) / g + GRID_EPS) * g + o
	var cell_hi := ceilf((a[_axis] - o) / g - GRID_EPS) * g + o
	if cell_hi <= cell_lo:
		# Exactly on a grid line — which a flush surface always is, being the origin itself — so
		# there is no containing cell, only the two touching it. Take the one it grows towards.
		if _draw_grows_up:
			cell_hi = cell_lo + g
		else:
			cell_lo = cell_hi - g
	lo[_axis] = minf(lo[_axis], cell_lo)
	hi[_axis] = maxf(hi[_axis], cell_hi)

	# GRID_EPS is not optional once the origin can be non-zero. Vector3 components are 32-bit while
	# these sums are 64-bit, so a height that IS exactly on a line comes back a few 1e-8 under it,
	# and a bare floorf() then drops the whole cell — the base fell a full cell for no movement at
	# all. Nudging the division by a ten-thousandth of a cell lands such values back on their line
	# and is far too small to affect a real drag. The old code needed none of this only because the
	# origin was always 0, where the values in play are exact in both widths.
	for i in 3:
		lo[i] = floorf((lo[i] - origin[i]) / g + GRID_EPS) * g + origin[i]
		hi[i] = ceilf((hi[i] - origin[i]) / g - GRID_EPS) * g + origin[i]
		if hi[i] <= lo[i]:
			# Zero width on this axis: the press and the handle floor and ceil to the same line,
			# so one of the two cells touching it has to be chosen. Everywhere inside a cell this
			# never happens — floor and ceil already answer with the cell the press point is in,
			# which is why dragging from mid-cell behaves and only faces misbehaved.
			#
			# On the axis of the FACE being drawn against it always happens, because the press
			# lands exactly on that face and a grid-aligned face sits on a grid line. Take the cell
			# OUTSIDE the surface, so the brush starts clear of what it was drawn against. The
			# camera used to break this tie, which is why the brush so often began buried and had
			# to be dragged a whole cell outward to escape.
			if i == _face_axis:
				if _face_sign > 0.0:
					hi[i] = lo[i] + g
				else:
					lo[i] = hi[i] - g
			elif lo[i] < cam[i]:
				hi[i] = lo[i] + g
			else:
				lo[i] = hi[i] - g

	var lo_v := Vector3(lo[0], lo[1], lo[2])
	var hi_v := Vector3(hi[0], hi[1], hi[2])
	return {"size": hi_v - lo_v, "center": (lo_v + hi_v) * 0.5}


## ALT drag: closest point between the mouse pick ray and the FROZEN vertical line — the same
## line-handle pick TrenchBroom uses for vertical drags. Unclamped, so
## dragging below the base grows the brush downward. Null if the ray is parallel to the line.
##
## The line origin is captured once when ALT goes down (the handle already sits on it, so
## there's no jump). It must not be re-derived per frame — the feedback makes the drag run away.
func _line_drag_point(camera: Camera3D, screen_pos: Vector2):
	var ro := camera.project_ray_origin(screen_pos)
	var rd := camera.project_ray_normal(screen_pos)   # unit length
	var up := Vector3.UP
	var w0 := ro - _alt_line_point
	var b := rd.dot(up)
	var denom := 1.0 - b * b        # a*c - b*b, with a == c == 1
	if absf(denom) < 1e-6:
		return null                 # looking straight up/down along the line
	var tc := (up.dot(w0) - b * rd.dot(w0)) / denom
	return _alt_line_point + up * tc


func _axis_vector(axis: int) -> Vector3:
	match axis:
		0: return Vector3.RIGHT
		1: return Vector3.UP
		_: return Vector3.BACK


# --- Ray vs. existing brushes (AABB, axis-aligned) ------------------------

## World-space AABB of a brush. Transforming the mesh's local AABB by the global transform
## accounts for rotation (and scale); treating the brush as an axis-aligned box around its origin
## does not.
func _brush_world_aabb(node) -> AABB:
	return node.global_transform * node.get_aabb()


## Where a newly created brush should be parented: alongside the brushes that already exist,
## rather than always at the scene root.
##
## Levels get organised into groups sooner or later, and a tool that always drops new geometry at
## the root means dragging every brush into place afterwards. The parent of a SELECTED brush wins
## — you are most likely building next to what you are already working on — and otherwise the
## parent of the first brush in the scene. A scene with no brushes yet falls back to the root.
##
## Nothing has to be dodged on the way. A brush's physics lives INSIDE it now, so no parent in the
## scene is off-limits — the rule that used to climb past every enclosing [CollisionObject3D] (a brush
## drawn beside a crate is not part of the crate, and would have arrived with no shape while its
## neighbours had one) describes a problem this design does not have.
func _brush_parent() -> Node:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	# An OPEN group adopts whatever is built inside it — draw, hull, .map paste and duplicate all
	# arrive here, so redirecting one function is what makes "new geometry joins the group" true for
	# every creation path at once. A CLOSED group never absorbs; it is a surface, not a container.
	if _open_group != null and is_instance_valid(_open_group):
		return _open_group
	for node in _selected_brushes():
		if node.get_parent() != null:
			return node.get_parent()
	# The previews are unowned Brushes living at the root; _scene_brushes drops them, so they can't
	# vote for the root as everyone's parent.
	for node in _scene_brushes():
		if node.get_parent() != null:
			return node.get_parent()
	return root


## The one parent every node in `nodes` shares, or null if they disagree (or the list is empty).
## "Put the answer back where the question came from" only means something when there is a single
## place it came from.
func _shared_parent(nodes: Array) -> Node:
	var shared: Node = null
	for node in nodes:
		var parent: Node = (node as Node).get_parent()
		if parent == null:
			return null
		if shared == null:
			shared = parent
		elif shared != parent:
			return null
	return shared


## Nodes that look like brushes but no longer ARE one, because a script was attached over the
## top of brush.gd. They keep the exported `planes` data but none of the behaviour, so every
## tool ignores them and they sit in the scene looking broken with nothing to say why.
func _orphaned_brushes() -> Array[Node3D]:
	var out: Array[Node3D] = []
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return out
	# Node3D, not MeshInstance3D: a brush IS a Node3D now, and an orphan keeps whatever type it was
	# saved as — so searching for the old base would miss every brush written since.
	for node in root.find_children("*", "Node3D", true, false):
		if node is Brush or node is BrushGroup or node.get_script() == null:
			continue
		# `planes` is the brush's source of truth; nothing else in a Godot scene exports it.
		if "planes" in node:
			out.append(node)
	return out


## Warn once per scene about brushes whose script was replaced. Attaching a script REPLACES the
## node's script rather than adding to it, which is an easy mistake to make and produces no error
## of its own — the node simply stops responding to every tool.
func _warn_about_orphaned_brushes() -> void:
	var orphaned := _orphaned_brushes()
	if orphaned.is_empty():
		return
	var names := PackedStringArray()
	for node in orphaned:
		names.append(String(node.name))
	push_warning(("Duckboard: %s no longer use the Brush script, so the tools skip them. " +
		"Attaching a script REPLACES brush.gd — make your script `extends Brush` (and call " +
		"super() in _ready) instead.") % ", ".join(names))


## Add the brush under the cursor to the selection, if any and not already in it. Drives the CTRL
## paint gesture: called on press and on every motion while _paint_selecting, so sweeping the held
## cursor across brushes builds the selection one by one. Uses the exact mesh-face pick, so it only
## grabs a brush the cursor is genuinely over.
func _paint_select_at(camera: Camera3D, screen_pos: Vector2) -> void:
	var hit = _raycast_brush_faces(
		camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos), true)
	if hit == null:
		return
	var selection := EditorInterface.get_selection()
	# Groups sweep into a quick-select like anything else, as whole objects: a group face answers
	# as that member's kernel, and adding a kernel would put an invisible scratch node in the
	# user's selection.
	var node := _selectable_of(hit.node)
	if node not in selection.get_selected_nodes():
		selection.add_node(node)


## TrenchBroom's CTRL+click: add the brush if it isn't selected, drop it if it is. Godot binds
## this to SHIFT, but SHIFT is reserved for FACE selection here — the same split TrenchBroom
## uses, and it only applies while map-editor mode is on, so the editor's own bindings come back
## the moment it's switched off.
## The group this node is a kernel of, or null if it is an ordinary brush. Writing to a kernel means
## writing to a group, and the two have to be recorded differently — see _fold_kernel_writes.
func _group_of_kernel(node: Node):
	if node == null:
		return null
	var parent := node.get_parent()
	if parent is BrushGroup and parent.kernel_index(node) >= 0:
		return parent
	return null


## The node a pick should hand to the SELECTION. A kernel is scratch geometry the user never sees,
## so it stands in for its group and never for itself; anything else is already selectable.
func _selectable_of(node: Node) -> Node:
	var group = _group_of_kernel(node)
	# While a group is OPEN its members are the things being edited, so a kernel selects as itself —
	# that is what lets the per-solid tools reach one member. Closed, the group stands in for it.
	if group == null or group == _open_group:
		return node
	return group


## Snapshot the `members` of every group among `nodes` that is represented by a kernel, so a write
## about to land on those kernels can be recorded as a group-level change.
func _snapshot_kernel_groups(nodes) -> Dictionary:
	var out := {}
	for node in nodes:
		var group = _group_of_kernel(node)
		if group != null and not out.has(group):
			out[group] = group.members.duplicate(true)
	return out


## Open a per-face write on ONE node, recording whichever state actually persists: an ordinary
## brush's `face_data`, or — when the node is a group's kernel — nothing yet, because the group's
## `members` is the durable state and _end_face_write folds it in afterwards. Returns the snapshot to
## hand back to that call.
func _begin_face_write(ur: EditorUndoRedoManager, node: Node3D) -> Dictionary:
	var before := _snapshot_kernel_groups([node])
	if before.is_empty():
		ur.add_undo_property(node, "face_data", node.face_data)
	return before


## Close a write opened by _begin_face_write. The caller commits with `false` — everything here is
## already applied.
func _end_face_write(ur: EditorUndoRedoManager, node: Node3D, before: Dictionary) -> void:
	if before.is_empty():
		ur.add_do_property(node, "face_data", node.face_data)
	_fold_kernel_writes(ur, before)


## Fold writes that landed on kernels back into their groups, as ONE `members` property each.
##
## A kernel is transient, so recording its `face_data` would leave undo pointing at scratch. The
## group's members are the real state, and reading the kernels back is what turns an edit made
## through the brush code path into a durable group edit. Pairs with _snapshot_kernel_groups, and
## expects the caller's action to be committed with `false` — the members are applied here.
func _fold_kernel_writes(ur: EditorUndoRedoManager, before: Dictionary) -> void:
	for group in before:
		if not is_instance_valid(group):
			continue
		var after: Array = group.read_back_kernels()
		if after.is_empty():
			continue
		group.members = after
		ur.add_do_property(group, "members", after)
		ur.add_undo_property(group, "members", before[group])


func _toggle_selected(node: Node) -> void:
	var selection := EditorInterface.get_selection()
	if node in selection.get_selected_nodes():
		selection.remove_node(node)
	else:
		selection.add_node(node)


## Make `node` the entire selection, and make it STICK.
##
## Setting the selection inside [method _forward_3d_gui_input] is not the last word on it. The editor
## does its own selection bookkeeping after the input callback returns, and it still holds whatever it
## believed was selected before — so a node selected during input handling gets replaced a few
## milliseconds later by the previous one, with nothing in the plugin doing it.
##
## Traced on a drag-create: the draw handler ends with the new brush selected, and 7 ms later
## `selection_changed` reports the PREVIOUS brush, with no Duckboard frame on the stack. Re-asserting
## on the next idle puts ours after the editor's, which is the only way to win an ordering we do not
## control. Guarded so it does nothing when the selection already agrees — the common case, and it
## keeps this from fighting a selection the user changed in the meantime.
func _select_only(node: Node) -> void:
	_select_nodes([node])


## The same, for the paths that create SEVERAL nodes at once — a CSG result, a paste, a split.
func _select_nodes(nodes: Array) -> void:
	var live: Array = []
	for node in nodes:
		if node is Node and is_instance_valid(node):
			live.append(node)
	var selection := EditorInterface.get_selection()
	selection.clear()
	for node in live:
		selection.add_node(node)
	_reassert_selection.call_deferred(live)


func _reassert_selection(nodes: Array) -> void:
	var live: Array = []
	for node in nodes:
		if is_instance_valid(node) and (node as Node).is_inside_tree():
			live.append(node)
	if live.is_empty():
		return
	var selection := EditorInterface.get_selection()
	var current := selection.get_selected_nodes()
	if current.size() == live.size():
		var same := true
		for node in live:
			if not (node in current):
				same = false
				break
		if same:
			return
	selection.clear()
	for node in live:
		selection.add_node(node)


## Select the solid under the cursor, replacing the selection. Returns whether anything was hit.
##
## [b]The job the editor's own click-select used to do for us.[/b] It cannot any more: a solid renders
## through a generated [MeshInstance3D] that has no `owner`, and the editor resolves a viewport click
## by walking up [code]get_owner()[/code] from the visual it hit — a walk an unowned node stops dead.
## So a press on a brush reached Godot, picked nothing, and selected nothing. Face selection kept
## working throughout, because that never left Duckboard's hands; only NODE selection was delegated.
##
## The open group's member path has always selected explicitly for exactly this reason — members were
## the first unowned visuals in the plugin. Every solid is one now, so every solid needs the same
## treatment, and this is the one place that does it.
##
## An already-selected target is left alone, so pressing one brush of a multi-selection still drags
## the whole set instead of collapsing it to the one under the cursor.
func _select_clicked(camera: Camera3D, screen_pos: Vector2) -> bool:
	# The exact FACE pick, not the coarse bounding-box one: with brushes packed close together a box
	# overlaps its neighbour, and the coarse hit would select a brush the cursor is not over.
	var hit = _raycast_brush_faces(camera.project_ray_origin(screen_pos),
		camera.project_ray_normal(screen_pos), true)
	if hit == null:
		return false
	# A group's face answers as that member's KERNEL, which is not something the user can select —
	# the group is, unless the group is the one currently open.
	var target := _selectable_of(hit.node)
	if target == null or not is_instance_valid(target):
		return false
	if target in EditorInterface.get_selection().get_selected_nodes():
		return true
	# Through _select_only, not a bare clear/add: this runs inside the input callback, and the editor
	# overwrites a selection made there once it does its own bookkeeping afterwards.
	_select_only(target)
	_selected_faces = []
	return true


## Combined world bounds of several brushes — the box the flip mirrors about and the scale tool
## puts its handles on, so a multi-selection is treated as one object rather than each brush
## transforming independently.
func _selection_world_aabb(brushes: Array[Node3D]) -> AABB:
	if brushes.is_empty():
		return AABB()
	var bounds := _brush_world_aabb(brushes[0])
	for i in range(1, brushes.size()):
		bounds = bounds.merge(_brush_world_aabb(brushes[i]))
	return bounds


## Nearest brush along the ray, by bounding box. `include_groups` adds closed groups, which is what
## lets the Brush tool set its draw plane from a group's surface — a group is a drawing surface like
## any brush. Off by default so the gestures with no group handling (notably move-on-press) keep
## seeing only brushes.
func _raycast_brushes(from: Vector3, dir: Vector3, include_groups := false):
	var best = null
	# The previews are excluded with the rest of the unowned brushes: an in-progress shape must
	# never block picking the real geometry behind it.
	var candidates := _scene_brushes()
	if include_groups:
		candidates.append_array(_scene_groups())
	for node in candidates:
		if not _pickable(node):
			continue
		var bounds := _brush_world_aabb(node)
		if bounds.size == Vector3.ZERO:
			continue      # an empty group bounds nothing to hit
		# STRICT about an origin inside the box, unlike the exact face pick, and that asymmetry is
		# deliberate. Nothing tests a face after this, so a box counted as hit IS the answer: stand
		# inside a room built as a group and every press — including one aimed at the sky through its
		# doorway — would come back holding that group, selecting it and arming a move on it. Here,
		# "the camera is inside it" has to keep meaning "the ray is not pointed at it".
		var res = _ray_aabb(from, dir, bounds.position, bounds.end)
		if res != null and (best == null or res.t < best.t):
			res["point"] = from + dir * res.t
			res["node"] = node
			best = res
	return best


## Claim a key event OUTRIGHT, not merely for the viewport.
##
## AFTER_GUI_INPUT_STOP only halts the viewport's own _gui_input — enough for keys it handles
## inline, like Delete. Editor MENU/DOCK accelerators fire later, in the shortcut_input phase, which
## STOP never reaches, so a chord Duckboard has already acted on runs a SECOND time as the editor's
## own command: Focus Selection (F), Duplicate (Ctrl+D), and — the one that actually bites — Paste,
## which dropped Godot's node clipboard on top of the pasted .map brushes and parented it into
## whatever happened to be selected, i.e. inside a brush. Marking the event handled on the viewport
## cuts that phase off.
func _claim_key() -> int:
	var vp := get_viewport()
	if vp != null:
		vp.set_input_as_handled()
	return AFTER_GUI_INPUT_STOP


## Can the ray see this node at all? Hiding a brush — with the Scene dock's eye, or by hiding an
## ancestor — is how you get it out of the way, so it must stop answering picks too: every gesture
## that reaches geometry goes through a raycast, and a hidden brush that still replies steals
## clicks, SHIFT face-picks and texture drops from whatever is visibly behind it.
##
## Deliberately checked in the RAYCASTS rather than in _scene_brushes, which also feeds CSG, the
## group ops and the styling pass — being invisible should stop something being picked, not quietly
## drop it out of an operation the user aimed at it by name.
func _pickable(node: Node3D) -> bool:
	return node.is_visible_in_tree()


## Slab test: the distance along `dir` at which the ray meets the box, or null for a miss.
##
## `inside_hits` settles what an origin ALREADY INSIDE the box means, which the two callers want
## answered opposite ways. Off — the default — it is a miss, because there is no entry face ahead of
## the ray, and for an obstruction test ("is this prop between the camera and the face?") a box you
## are standing in is not in the way of anything. On, it is a hit at the EXIT distance, which is what
## a picking GATE needs: without it nothing you can stand inside is ever tested — a room built as a
## group, a ground plane spanning the level, any brush big enough to walk into.
##
## The exit distance, not zero, and that distinction is the whole reason this is a parameter rather
## than a fix in place. At zero the biggest box in the scene is the nearest hit from everywhere
## inside it, which is exactly how a level-spanning group ends up answering every click in the map.
func _ray_aabb(from: Vector3, dir: Vector3, aabb_min: Vector3, aabb_max: Vector3,
		inside_hits := false):
	var tmin := -INF
	var tmax := INF
	var hit_axis := -1
	var hit_sign := 1.0
	for i in 3:
		if absf(dir[i]) < 1e-8:
			if from[i] < aabb_min[i] or from[i] > aabb_max[i]:
				return null
			continue
		var inv := 1.0 / dir[i]
		var t1 := (aabb_min[i] - from[i]) * inv
		var t2 := (aabb_max[i] - from[i]) * inv
		var face_sign := -1.0        # entering the min face -> outward normal is -axis
		if t1 > t2:
			var tmp := t1
			t1 = t2
			t2 = tmp
			face_sign = 1.0
		if t1 > tmin:
			tmin = t1
			hit_axis = i
			hit_sign = face_sign
		tmax = minf(tmax, t2)
		if tmin > tmax:
			return null
	if tmin < 0.0:
		if not inside_hits or tmax < 0.0:
			return null      # tmax < 0: the whole box is behind the ray, inside or not
		# Origin inside the box. The entry-face fields describe a face behind the camera and are
		# meaningless here — nothing reads them, and this is the only caller that could.
		return {"t": tmax, "axis": hit_axis, "sign": hit_sign}
	return {"t": tmin, "axis": hit_axis, "sign": hit_sign}


# --- Preview ("ghost") ----------------------------------------------------

func _begin_preview() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	# The preview node stays at the ORIGIN: the box mesh and the shape ghosts are positioned in world
	# space by their own transforms, which keeps the shape brushes (whose corners are world-space)
	# from being double-offset by a moved parent.
	_preview = Node3D.new()

	# Faces: transparent triplanar grid ghost (same world grid as the real brush).
	var ghost_mat := ShaderMaterial.new()
	ghost_mat.shader = GHOST_SHADER
	ghost_mat.set_shader_parameter("cell_size", grid_size)
	_preview_box = MeshInstance3D.new()
	_preview_box.mesh = BoxMesh.new()
	_preview_box.material_override = ghost_mat
	_preview.add_child(_preview_box)
	# The red outline is drawn in the 2D overlay (see _draw_wireframe), not as 3D geometry.

	root.add_child(_preview)   # unowned -> not saved, hidden from Scene dock
	_preview_brushes = []
	_preview_shape_key = ""


func _update_preview(a: Vector3, b: Vector3, camera: Camera3D) -> void:
	if not is_instance_valid(_preview):
		return
	var box := _box_from(a, b, camera.global_position)
	var shape := "cuboid"
	var params := {}
	if is_instance_valid(_shape_bar):
		shape = _shape_bar.get_shape()
		params = _shape_bar.get_params()
	if shape == "cuboid":
		# Fast path: one box mesh, no hull solving and no per-cell rebuild.
		if not _preview_brushes.is_empty():
			_clear_preview_brushes()
		_preview_box.visible = true
		(_preview_box.mesh as BoxMesh).size = box.size
		_preview_box.position = box.center
	else:
		_preview_box.visible = false
		# The snapped box only changes when the cursor crosses a grid cell, so the real geometry is
		# rebuilt on THAT (and on a shape/param change), not on every mouse motion — cheap enough
		# even for a many-sided cylinder's hull solve.
		var key := "%s|%s|%s|%s" % [shape, box.center, box.size, params]
		if key != _preview_shape_key:
			_preview_shape_key = key
			_rebuild_preview_brushes(shape, box, params)
	# Feed the 2D overlay that draws the dimension labels (the bounding-box guide, all shapes).
	_box_center = box.center
	_box_size = box.size
	_draw_camera = camera
	update_overlays()


## Rebuild the live shape ghosts from the current box + parameters — real Brushes built exactly as
## the commit does, but rendered with the ghost material and no grid overlay, and left UNOWNED so
## they neither save nor show in the Scene dock. Same convention as the brush tool's hull preview.
func _rebuild_preview_brushes(shape: String, box: Dictionary, params: Dictionary) -> void:
	_clear_preview_brushes()
	if not is_instance_valid(_preview):
		return
	var ghost: Material = _preview_box.material_override
	var point_sets: Array = ShapeBuilder.build(shape, box.center, box.size, params, grid_size)
	for pts in point_sets:
		if pts.size() < 4:
			continue
		var bounds := AABB(pts[0], Vector3.ZERO)
		for p in pts:
			bounds = bounds.expand(p)
		var centre := bounds.get_center()
		var brush := Brush.new()
		brush.grid_size = grid_size
		brush.position = centre
		var local := PackedVector3Array()
		for p in pts:
			local.append(p - centre)
		brush.set_from_points(local, false)
		if brush.planes.size() < 4:
			brush.free()
			continue
		brush.set_grid_overlay_enabled(false)   # the ghost material already carries the world grid
		brush.material_override = ghost
		_preview.add_child(brush)
		_preview_brushes.append(brush)


func _clear_preview_brushes() -> void:
	for b in _preview_brushes:
		if is_instance_valid(b):
			b.queue_free()
	_preview_brushes = []


# --- 2D overlay: dimension labels with dark backgrounds -------------------

const LABELS := ["X", "Y", "Z"]
const LABEL_OFFSET := 0.3   # metres, pushes the anchor just off the edge

## Anchor offset (from box centre) for each dimension label, per the TrenchBroom layout:
##   Y  -> the screen-LEFT vertical edge (centred vertically)
##   X  -> the FAR Z edge, Z -> the FAR X edge; both take their height from the camera
##         (top when looking down, bottom when looking up) so they never sit over the mesh.
func _label_offset(axis: int, half: Vector3, cam: Vector3, center: Vector3, right: Vector3) -> Vector3:
	var near_y := _nz(cam.y - center.y)   # +1 camera above (looking down), -1 looking up
	match axis:
		0:  # X: centred along X, far Z, camera-side height
			return Vector3(0.0, near_y * (half.y + LABEL_OFFSET), -_nz(cam.z - center.z) * (half.z + LABEL_OFFSET))
		2:  # Z: centred along Z, far X, camera-side height
			return Vector3(-_nz(cam.x - center.x) * (half.x + LABEL_OFFSET), near_y * (half.y + LABEL_OFFSET), 0.0)
		_:  # Y: screen-left vertical edge, centred vertically
			return Vector3(-_nz(right.x) * (half.x + LABEL_OFFSET), 0.0, -_nz(right.z) * (half.z + LABEL_OFFSET))


## Sign that is never zero (so a label never collapses onto an axis).
func _nz(v: float) -> float:
	return -1.0 if v < 0.0 else 1.0


# --- Direct move (TrenchBroom-style) --------------------------------------

## Selected nodes that are actually our brushes.
func _selected_brushes() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for n in EditorInterface.get_selection().get_selected_nodes():
		# in-tree check: an undone brush can still be selected while unparented, and reading
		# its global_transform then is an error.
		if n is Brush and n.is_inside_tree():
			out.append(n)
	return out


## The selected groups, as the deliberate COUNTERPART to _selected_brushes: a BrushGroup is not a
## Brush, so every tool that asks for brushes already ignores groups for free — which is exactly the
## refusal the design wants from clip and the handle tools. Only the ops that mean to act on whole
## groups ask for this.
func _selected_groups() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for n in EditorInterface.get_selection().get_selected_nodes():
		if n is BrushGroup and n.is_inside_tree():
			out.append(n)
	return out


## Every Brush in the edited scene — the scene-side counterpart to _selected_brushes, and the ONE
## place that answers "which brushes exist right now".
##
## It is a single function on purpose. Opening a group has to scope every tool to that group's
## members; written out at each scan site, one site would inevitably be missed and a tool would
## quietly reach a brush outside the open group. Here it will be two lines, in one place.
##
## `include_previews` keeps the unowned scratch brushes the tools park in the scene — the hull,
## push and clip previews. They are deliberately unowned so they are never saved, which is exactly
## what marks them as not-real-geometry, so the default drops them and only the passes that style
## every brush on screen (grid overlay, snap size, the lock toggles) ask for them.
## `ignore_isolation` bypasses the open-group fence for callers that only need a SURFACE, not an
## editing target — the draw anchor being the one so far. It must never be passed by a tool that
## reshapes what it hits.
func _scene_brushes(include_previews := false, ignore_isolation := false) -> Array[Node3D]:
	# ISOLATION. With a group open, the only brushes that exist as far as the tools are concerned are
	# its members — that is what stops a tool quietly reaching geometry outside the group being
	# edited. Deliberately not applied to the preview-inclusive form: that one is the whole-scene
	# STYLING pass (grid overlay, snap size, the lock toggles), and leaving the rest of the level
	# unstyled would read as a rendering fault rather than as isolation.
	if not include_previews and not ignore_isolation \
			and _open_group != null and is_instance_valid(_open_group):
		# Members PLUS anything real drawn into the group while it has been open. New geometry
		# arrives as an owned child brush (see _brush_parent) and only folds into `members` on
		# close, so without the second half a freshly drawn brush would be invisible to every
		# raycast — unselectable, and reading as "outside the group", which used to close it.
		var editable: Array[Node3D] = []
		editable.assign(_open_group.kernels())
		for child in _open_group.get_children():
			if child is Brush and child.owner != null:
				editable.append(child)
		return editable
	var out: Array[Node3D] = []
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return out
	# Node3D, not MeshInstance3D. A brush stopped being a mesh instance when collision became derived,
	# and searching for the old base matches only the generated Mesh children — none of which are
	# brushes, so this returned NOTHING: no brush could be picked, and no brush was reachable to have
	# its grid overlay refreshed. The type here must stay the loosest thing every brush still is.
	for node in root.find_children("*", "Node3D", true, false):
		if not node is Brush or not node.is_inside_tree():
			continue
		if not include_previews and node.owner == null:
			continue
		out.append(node)
	return out


## Let go of the kernels of any group that is neither selected nor holding a selected face.
##
## Kernels persist across edits so a selected face keeps pointing at a live node, which means nothing
## frees them on its own — without this, every group ever picked or dragged would keep one hidden
## Brush per member alive for the rest of the session.
func _release_idle_kernels() -> void:
	var selected := _selected_groups()
	for group in _scene_groups():
		if selected.has(group) or group == _open_group:
			continue
		var holds_face := false
		for entry in _selected_faces:
			if is_instance_valid(entry.node) and entry.node.get_parent() == group:
				holds_face = true
				break
		if not holds_face:
			group.release_kernels()


## Everything selected that a GEOMETRY tool should reshape: loose brushes, plus every member of a
## selected group borrowed back as a kernel.
##
## This is what lets rotate / scale / shear act on a closed group with no group-specific code in the
## tools at all — they are handed Brush nodes either way, so a grouped wall and a loose one go
## through the identical hull solve, UV carry and snapping rules.
func _selected_geometry() -> Array[Node3D]:
	var out := _selected_brushes()
	for group in _selected_groups():
		for i in group.members.size():
			var kernel: Brush = group.kernel_for(i)
			if kernel != null:
				out.append(kernel)
	return out


## Everything selected that a WHOLE-OBJECT gesture may act on: brushes and closed groups alike.
##
## Move, duplicate and delete are node-level — they touch the transform or the tree, never the
## geometry — so a closed group takes part exactly as a brush does, which is what "a group behaves
## like an object" means. The GEOMETRY ops (clip, the vertex/edge/face tools) keep asking
## _selected_brushes, and that is precisely what makes them refuse a group until it is opened.
func _selected_transformables() -> Array[Node3D]:
	var out := _selected_brushes()
	out.append_array(_selected_groups())
	return out


## Every BrushGroup in the edited scene — the group-side counterpart to _scene_brushes. Separate on
## purpose: a group is not a Brush, so the tools that ask for brushes keep ignoring groups, and only
## the passes that opt in (see the raycasts' include_groups) ever see one.
func _scene_groups() -> Array[Node3D]:
	var out: Array[Node3D] = []
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return out
	# Node3D for the same reason as _scene_brushes — see there.
	for node in root.find_children("*", "Node3D", true, false):
		if node is BrushGroup and node.is_inside_tree():
			out.append(node)
	return out


## Where the cursor lands under the active constraint: the horizontal plane by default, or
## the frozen vertical line while ALT is held.
func _move_handle_point(camera: Camera3D, screen_pos: Vector2):
	var ro := camera.project_ray_origin(screen_pos)
	var rd := camera.project_ray_normal(screen_pos)
	if _move_alt:
		var up := Vector3.UP
		var w0 := ro - _move_line_point
		var b := rd.dot(up)
		var denom := 1.0 - b * b
		if absf(denom) < 1e-6:
			return null
		return _move_line_point + up * ((up.dot(w0) - b * rd.dot(w0)) / denom)
	return Plane(Vector3.UP, _move_plane_y).intersects_ray(ro, rd)


func _begin_move(camera: Camera3D, screen_pos: Vector2) -> void:
	# Groups move with the brushes: a move is a node-transform gesture, and a group's members are
	# stored in its LOCAL frame, so moving the node carries them with it exactly.
	var brushes := _selected_transformables()
	if brushes.is_empty():
		return
	# CTRL held at press: leave the originals alone and drag fresh copies instead.
	if _move_ctrl:
		brushes = _duplicate_brushes(brushes)
		if brushes.is_empty():
			return
		_move_duplicated = true
	# Anchor both constraints at the point we grabbed on the horizontal plane.
	var ro := camera.project_ray_origin(screen_pos)
	var rd := camera.project_ray_normal(screen_pos)
	var anchor = Plane(Vector3.UP, _move_plane_y).intersects_ray(ro, rd)
	if anchor == null:
		return
	_move_line_point = anchor
	var handle = _move_handle_point(camera, screen_pos)
	if handle == null:
		return
	_move_active = true
	_move_start_handle = handle
	_move_nodes = brushes
	_move_starts = []
	_move_origins = []
	for b in brushes:
		_move_starts.append(b.global_position)
		_move_origins.append(b.global_position)


## Copy each brush in place and select the copies, so the drag moves them while the originals
## stay put. They're added to the tree immediately (so they're visible mid-drag); undo/redo
## bookkeeping is registered later, in _commit_move.
func _duplicate_brushes(source: Array[Node3D]) -> Array[Node3D]:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return []
	var copies: Array[Node3D] = []
	var selection := EditorInterface.get_selection()
	selection.clear()
	for brush in source:
		var copy := brush.duplicate() as Node3D
		# duplicate() brings the generated body, mesh and shapes across as copies that SHARE their
		# sub-resources with the original's — so reshaping the copy would rewrite the original's
		# collision. Dropped here and rebuilt from the copy's own data on its first rebuild.
		Collision.reset(copy)
		# A copy always collides with its original, so force_readable_name is what turns
		# "Brush" into "Brush2" rather than "@Brush@28359".
		brush.get_parent().add_child(copy, true)
		copy.owner = root
		copies.append(copy)
		selection.add_node(copy)
	return copies


func _update_move(camera: Camera3D, screen_pos: Vector2, alt_now: bool) -> void:
	if alt_now != _move_alt:
		_rebase_move(camera, screen_pos, alt_now)
	var handle = _move_handle_point(camera, screen_pos)
	if handle == null:
		return
	# Snap the DELTA to whole cells: brushes start grid-aligned so they stay aligned, and a
	# multi-selection keeps its relative offsets.
	var g := grid_size
	var d: Vector3 = handle - _move_start_handle
	d = Vector3(roundf(d.x / g) * g, roundf(d.y / g) * g, roundf(d.z / g) * g)
	for i in _move_nodes.size():
		_move_nodes[i].global_position = _move_starts[i] + d
	update_overlays()   # redraw the move indicator


## Switching between horizontal and vertical mid-drag: re-anchor the new constraint where we
## already are and rebase the baseline, so the delta restarts at zero and nothing jumps.
func _rebase_move(camera: Camera3D, screen_pos: Vector2, alt_now: bool) -> void:
	var prev = _move_handle_point(camera, screen_pos)   # under the OLD constraint
	for i in _move_nodes.size():
		_move_starts[i] = _move_nodes[i].global_position
	if prev != null:
		if alt_now:
			_move_line_point = prev
		else:
			_move_plane_y = prev.y      # keep dragging at the height we reached
	_move_alt = alt_now
	var handle = _move_handle_point(camera, screen_pos)
	if handle != null:
		_move_start_handle = handle


func _commit_move() -> void:
	var ur := get_undo_redo()
	if _move_duplicated:
		# The copies are already in the tree, so commit_action(false) records the action
		# WITHOUT re-running it: undo removes them, redo re-adds them where they ended up.
		var root := EditorInterface.get_edited_scene_root()
		ur.create_action("Duplicate Brush")
		for node in _move_nodes:
			var parent := node.get_parent()
			ur.add_do_reference(node)
			ur.add_do_method(parent, "add_child", node)
			ur.add_do_method(node, "set_owner", root)
			ur.add_do_property(node, "global_position", node.global_position)
			ur.add_undo_method(parent, "remove_child", node)
		ur.commit_action(false)
		return

	ur.create_action("Move Brush")
	for i in _move_nodes.size():
		# Undo restores the ORIGINAL position, not the last mid-drag rebase.
		ur.add_do_property(_move_nodes[i], "global_position", _move_nodes[i].global_position)
		ur.add_undo_property(_move_nodes[i], "global_position", _move_origins[i])
	ur.commit_action()


func _reset_move() -> void:
	_move_armed = false
	_move_active = false
	_move_alt = false
	_move_ctrl = false
	_move_duplicated = false
	_move_nodes = []
	_move_starts = []
	_move_origins = []


## The FORCE variant, enabled by set_force_draw_over_forwarding_enabled(), so it fires even
## though the plugin doesn't "edit" a selected node.
##
## ONE plugin, up to FOUR open 3D views. This callback fires once per visible view, but every
## drawing helper — here and in tools/ — projects world→screen through the single _draw_camera,
## which tracks the view we last saw INPUT through. So all four views drew the same wireframe at
## the same screen position regardless of what each was actually looking at. The overlay Control
## we are handed belongs to the view being drawn, so its camera is reachable from it: point
## _draw_camera at that one for the duration of this view's draw, then put back the input camera
## (which _on_shape_changed and the drag paths still rely on).
## The isolation wash's fade is the only thing here that animates on its own, so processing is turned
## on when a group opens or closes and off again the moment the fade settles — an idle plugin should
## not be waking every frame.
##
## The editor re-renders its 3D views on demand rather than continuously, so a fade nobody asks to
## see would land as a single jump between two still frames; update_overlays() is what asks.
func _process(delta: float) -> void:
	if _group_isolate.advance(delta):
		update_overlays()
	else:
		set_process(false)


func _forward_3d_force_draw_over_viewport(overlay: Control) -> void:
	# The wash's spared box follows the open group's geometry, and this is the one callback that
	# fires on every redraw — including the redraws a drag causes, which is when the box moves.
	if _open_group != null:
		_group_isolate.sync(_open_group)
	var input_camera := _draw_camera
	var view_camera := _camera_for_overlay(overlay)
	if view_camera != null:
		_draw_camera = view_camera
	_draw_overlay(overlay)
	_draw_camera = input_camera


## The editor's 3D views are siblings under one parent, so a camera found by searching upward from
## the overlay would be *some* view's camera, not necessarily this one. Search only the overlay's
## own Node3DEditorViewport subtree (the overlay is a sibling of the SubViewportContainer that
## holds the view's camera, hence starting one level up) and hand back null otherwise, which leaves
## the caller on the pre-fix single-camera behaviour rather than blanking the overlay entirely.
##
## Cached: this runs on every redraw of every view, and both the overlay surfaces and the view
## cameras live as long as the editor does.
func _camera_for_overlay(overlay: Control) -> Camera3D:
	var cached = _overlay_cameras.get(overlay)
	if is_instance_valid(cached):
		return cached
	var host_view := overlay.get_parent()
	if host_view == null:
		return null
	var camera := _find_view_camera(host_view)
	if camera != null:
		_overlay_cameras[overlay] = camera
	return camera


## Depth-first hunt for the camera that renders one editor 3D view. get_camera_3d() is asked first
## because it names the camera the view is ACTUALLY rendering through; the plain node search is the
## fallback for a view whose camera is not flagged current, where get_camera_3d() answers null.
func _find_view_camera(node: Node) -> Camera3D:
	if node is Camera3D:
		return node as Camera3D
	if node is SubViewport:
		var active := (node as SubViewport).get_camera_3d()
		if active != null:
			return active
	for child in node.get_children():
		var camera := _find_view_camera(child)
		if camera != null:
			return camera
	return null


func _draw_overlay(overlay: Control) -> void:
	# The off-mode nudge is text-only (no camera), so it draws ahead of the guard the rest needs.
	# Its wording names the OFF state so it can't be mistaken for one of the in-tool hints below.
	if _hint_toast and not _enabled:
		_draw_status_hint(overlay, ["Brush map editor is off",
			"Turn on the highlighted toolbar button to edit this brush"])
	if not _enabled or _draw_camera == null:
		return
	# Only while the drag actually has a valid target (the same condition that shows the yellow drop
	# highlight) — not over other meshes or empty space.
	if _drop_face_hover != null:
		_draw_status_hint(overlay, ["Drop onto a face to texture it",
			"Hold Shift to texture the whole brush"])
	if _drawing and _box_size != Vector3.ZERO:
		# The red outline traces the ACTUAL shape (each preview brush's edges), TrenchBroom-style —
		# for a cuboid that's just the box, so the box outline stands in when there are no ghosts.
		if _preview_brushes.is_empty():
			_draw_wireframe(overlay, _box_center, _box_size)
		else:
			for b in _preview_brushes:
				if is_instance_valid(b):
					_draw_brush_wireframe(overlay, b)
		_draw_dimension_labels(overlay, _box_center, _box_size)
		# ALT switches the drag to vertical so the new brush's height can be set. Hidden once
		# ALT is already down — no point naming a key you are holding.
		if not _alt:
			_draw_status_hint(overlay, ["Hold Alt to change height"])
		return
	# Selected brushes always show a face-accurate wireframe (replacing Godot's AABB box).
	for node in _selected_brushes():
		_draw_brush_wireframe(overlay, node)
	# Groups get TrenchBroom's purple BOUNDS rather than a face-accurate outline: the point is to
	# say "this is one object", not to trace the geometry, which the combined mesh already shows.
	#
	# SELECTION ONLY, deliberately. Bounds that also followed the cursor lit up during ordinary
	# mouselook — the ray sits near the viewport centre while orbiting, so groups flashed at every
	# camera move — and standing purple boxes are tiring while doing work that has nothing to do
	# with groups. You find a group by clicking it, as with any other object.
	for node in _selected_groups():
		_draw_group_bounds(overlay, node)
	# Face-level selection and hover sit above the brush wireframe and outside any tool, so they
	# are drawn before the per-tool branches return.
	_draw_face_selection(overlay)

	if _move_active:
		# Keep the spikes up while dragging so you can sight the brush against the level.
		for node in _move_nodes:
			var moving := _brush_world_aabb(node)
			_draw_edge_extensions(overlay, moving.get_center(), moving.size)
		_draw_move_axes(overlay)
		return
	if _tool_mode == "vertex":
		if not _handle_tools.vertex_nodes.is_empty():
			_handle_tools.draw_vertex_spikes(overlay, _handle_tools.vertex_current)
			_draw_axis_legs(overlay, _handle_tools.vertex_origin, _handle_tools.vertex_current - _handle_tools.vertex_origin)
		_handle_tools.draw_vertex_handles(overlay)
		_handle_tools.draw_handle_hover(overlay)
		return
	if _tool_mode == "edge":
		if not _handle_tools.edge_nodes.is_empty():
			_handle_tools.draw_vertex_spikes(overlay, _handle_tools.edge_mid)
			_draw_axis_legs(overlay, _handle_tools.edge_origin, _handle_tools.edge_mid - _handle_tools.edge_origin)
		_handle_tools.draw_edge_handles(overlay)
		_handle_tools.draw_handle_hover(overlay)
		return
	if _tool_mode == "face":
		if not _handle_tools.face_nodes.is_empty():
			_handle_tools.draw_vertex_spikes(overlay, _handle_tools.face_center)
			_draw_axis_legs(overlay, _handle_tools.face_origin, _handle_tools.face_center - _handle_tools.face_origin)
		_handle_tools.draw_face_handles(overlay)
		_handle_tools.draw_handle_hover(overlay)
		return
	if _tool_mode == "scale":
		_scale_tool.draw(overlay)
		return
	if _tool_mode == "shear":
		_shear_tool.draw(overlay)
		return
	if _tool_mode == "rotate":
		_rotate_tool.draw(overlay)
		return
	if _tool_mode == "clip":
		_clip_tool.draw_handles(overlay)
		return
	if _tool_mode == "brush":
		_hull_tool.draw(overlay)
		return
	# is_instance_valid() is not enough: undoing a draw leaves the node alive (the undo history
	# holds a reference) but unparented, and global_transform is invalid until it's back in.
	if is_instance_valid(_hover_brush) and _hover_brush.is_inside_tree():
		# Use the WORLD AABB so a rotated brush's guides wrap what you actually see rather
		# than its unrotated local box.
		var bounds := _brush_world_aabb(_hover_brush)
		_draw_edge_extensions(overlay, bounds.get_center(), bounds.size)
		_draw_dimension_labels(overlay, bounds.get_center(), bounds.size)


## Track which brush is under the cursor so the overlay can highlight it. The guides only
## appear when the brush is BOTH selected and hovered (TrenchBroom's behaviour) — hovering
## alone would spray spikes across the viewport as you move the mouse.
##
## Never consumes the event: hovering must not interfere with clicking, selecting or dragging.
func _update_hover(camera: Camera3D, screen_pos: Vector2) -> void:
	var previous := _hover_brush
	_hover_brush = null
	if not _drawing and not _move_active:
		var hit = _raycast_brushes(
			camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos))
		if hit != null and hit.node in EditorInterface.get_selection().get_selected_nodes():
			_hover_brush = hit.node
	if _hover_brush != previous:
		update_overlays()


## Red brush outline in 2D: thick + anti-aliased, always crisp, no z-fighting with the ghost
## faces.
func _draw_wireframe(overlay: Control, center: Vector3, size: Vector3,
		tint := Palette.TB_RED) -> void:
	var h := size * 0.5
	var c := center
	var corners := [
		c + Vector3(-h.x, -h.y, -h.z), c + Vector3(h.x, -h.y, -h.z),
		c + Vector3(h.x, -h.y, h.z), c + Vector3(-h.x, -h.y, h.z),
		c + Vector3(-h.x, h.y, -h.z), c + Vector3(h.x, h.y, -h.z),
		c + Vector3(h.x, h.y, h.z), c + Vector3(-h.x, h.y, h.z),
	]
	var edges := [0, 1, 1, 2, 2, 3, 3, 0,  4, 5, 5, 6, 6, 7, 7, 4,  0, 4, 1, 5, 2, 6, 3, 7]
	var col := tint
	var i := 0
	while i < edges.size():
		var a: Vector3 = corners[edges[i]]
		var b: Vector3 = corners[edges[i + 1]]
		i += 2
		if _draw_camera.is_position_behind(a) or _draw_camera.is_position_behind(b):
			continue
		overlay.draw_line(_draw_camera.unproject_position(a), _draw_camera.unproject_position(b), col, 2.0, true)


## A group's purple bounding box, TrenchBroom's grouped-selection cue. Read off the combined mesh's
## AABB, so it costs nothing to keep current: the mesh is rebuilt whenever `members` changes.
func _draw_group_bounds(overlay: Control, node) -> void:
	var bounds := _brush_world_aabb(node)
	if bounds.size == Vector3.ZERO:
		return
	_draw_wireframe(overlay, bounds.get_center(), bounds.size, Palette.TB_PURPLE)


func _draw_dimension_labels(overlay: Control, center: Vector3, size: Vector3) -> void:
	var font := overlay.get_theme_default_font()
	var font_size := LABEL_FONT_SIZE
	var half := size * 0.5
	var cam := _draw_camera.global_position
	var right := _draw_camera.global_transform.basis.x
	for a in 3:
		var world := center + _label_offset(a, half, cam, center, right)
		if _draw_camera.is_position_behind(world):
			continue
		var screen := _draw_camera.unproject_position(world)
		var text := "%s: %d" % [LABELS[a], int(round(size[a] * UNITS_PER_METER))]
		_draw_dim_label(overlay, font, font_size, screen, text)


## One continuous red guide line along each of the bounds' 12 edges, overshooting a fixed length
## past both ends.
##
## Continuous is the point: the line runs THROUGH the edge rather than stopping at the corners,
## so the twelve guides trace the bounding box and extend beyond it in the same stroke. There is
## no separately drawn box — the guides are the box, which is why they're all one weight and one
## colour rather than a bright edge with faint spikes attached.
func _draw_edge_extensions(overlay: Control, center: Vector3, size: Vector3) -> void:
	var h := size * 0.5
	var corners := [
		center + Vector3(-h.x, -h.y, -h.z), center + Vector3(h.x, -h.y, -h.z),
		center + Vector3(h.x, -h.y, h.z), center + Vector3(-h.x, -h.y, h.z),
		center + Vector3(-h.x, h.y, -h.z), center + Vector3(h.x, h.y, -h.z),
		center + Vector3(h.x, h.y, h.z), center + Vector3(-h.x, h.y, h.z),
	]
	var edges := [0, 1, 1, 2, 2, 3, 3, 0,  4, 5, 5, 6, 6, 7, 7, 4,  0, 4, 1, 5, 2, 6, 3, 7]
	var ext_col := Color(Palette.TB_RED, 0.30)
	var i := 0
	while i < edges.size():
		var a: Vector3 = corners[edges[i]]
		var b: Vector3 = corners[edges[i + 1]]
		i += 2
		var ext: Vector3 = (b - a).normalized() * SPIKE_LENGTH
		_draw_world_line(overlay, a - ext, b + ext, ext_col, 1.0)


func _draw_move_axes(overlay: Control) -> void:
	if _move_nodes.is_empty() or _move_origins.is_empty():
		return
	# Legs start at the exact point on the surface you grabbed, not the brush's centre.
	_draw_axis_legs(overlay, _move_grab_point,
		_move_nodes[0].global_position - _move_origins[0])


## Walk a delta as axis-aligned legs from `from`, each in its axis colour and labelled with
## the distance in TB units. Horizontal first (X then Z), vertical last, so the path runs
## along the ground before rising. Zero-length axes are skipped entirely.
## Shared by the move tool and the vertex tool.
func _draw_axis_legs(overlay: Control, from: Vector3, delta: Vector3) -> void:
	var components := [delta.x, delta.y, delta.z]
	var font := overlay.get_theme_default_font()

	var cursor := from
	for a in [0, 2, 1]:   # horizontal legs first (X then Z), vertical last
		var amount: float = components[a]
		if is_zero_approx(amount):
			continue
		var next: Vector3 = cursor + MOVE_AXES[a] * amount
		_draw_world_line(overlay, cursor, next, AXIS_COLORS[a], 2.0)
		var mid: Vector3 = (cursor + next) * 0.5
		if not _draw_camera.is_position_behind(mid):
			_draw_dim_label(overlay, font, LABEL_FONT_SIZE, _draw_camera.unproject_position(mid),
				"%s: %d" % [LABELS[a], int(round(amount * UNITS_PER_METER))])
		cursor = next


# --- Vertex tool ----------------------------------------------------------

## Texture lock picks the UV projection space: OFF pins textures to WORLD space (aligned to
## the grid, tiling across brushes), ON pins them to the brush so they ride along when it
## moves. Applied to every brush, and remembered for newly drawn ones.
func _on_option_toggled(option_id: String, pressed: bool) -> void:
	if option_id == "texture_lock":
		texture_lock = pressed
	elif option_id == "uv_lock":
		uv_lock = pressed
	else:
		return
	# Previews included: a ghost that ignored the lock toggles would texture differently from the
	# brush it is about to become. Groups pass the setting on to their kernels, so a grouped wall
	# rotates under the same alignment-lock rule as a loose one.
	for node in _scene_brushes(true):
		if option_id == "texture_lock":
			node.texture_lock = pressed
		else:
			node.uv_lock = pressed
	for group in _scene_groups():
		if option_id == "texture_lock":
			group.texture_lock = pressed
		else:
			group.uv_lock = pressed


func _on_action_triggered(action_id: String) -> void:
	match action_id:
		"duplicate": _duplicate_selected_brushes()
		"flip_h": _flip_selected_brushes(true)
		"flip_v": _flip_selected_brushes(false)


## Mirror the selected brushes about the centre of their combined bounds.
##
## The axis is VIEW-relative, as in TrenchBroom: horizontal flips along the camera's right,
## vertical along its up, each snapped to the world axis it leans on most. That's why the
## buttons are worth having at all — "horizontal" means what you see on screen, so the same
## click does something different depending on where you're standing.
##
## Mirroring about the bounds centre keeps everything grid-aligned for free: the bounds are
## made of grid-aligned corners, so reflecting through their midpoint lands back on the same
## lattice with no snapping needed.
func _flip_selected_brushes(horizontal: bool) -> void:
	var brushes := _selected_brushes()
	var groups := _selected_groups()
	if (brushes.is_empty() and groups.is_empty()) or _last_camera == null:
		return
	var basis := _last_camera.global_transform.basis
	var axis := _dominant_axis(basis.x if horizontal else basis.y)
	# The pivot spans the WHOLE selection, groups included, so a mixed flip mirrors everything
	# about one line instead of each object about its own centre.
	var pivot := _selection_world_aabb(_selected_transformables()).get_center()

	var ur := get_undo_redo()
	ur.create_action("Flip Horizontally" if horizontal else "Flip Vertically")
	# Groups mirror as one `members` property each. The geometry itself goes through the SAME
	# _flip_brush the loose brushes get, by borrowing each member back as a kernel — so a grouped
	# wall and a loose one come out identical rather than through a second implementation.
	for group in groups:
		var before: Array = group.members.duplicate(true)
		var after := _flip_group_members(group, axis, pivot)
		group.members = after      # applied here, like the brushes below, for commit_action(false)
		ur.add_do_property(group, "members", after)
		ur.add_undo_property(group, "members", before)
	for node in brushes:
		var old_planes: Array[Plane] = node.planes.duplicate()
		var old_faces: Dictionary = node.face_data
		var old_position: Vector3 = node.global_position
		_flip_brush(node, axis, pivot)
		# Applied already, so record both directions explicitly. face_data comes after planes
		# in each direction because assigning planes rebuilds and overwrites it.
		ur.add_do_property(node, "global_position", node.global_position)
		ur.add_do_property(node, "planes", node.planes.duplicate())
		ur.add_do_property(node, "face_data", node.face_data)
		ur.add_undo_property(node, "global_position", old_position)
		ur.add_undo_property(node, "planes", old_planes)
		ur.add_undo_property(node, "face_data", old_faces)
	ur.commit_action(false)
	# The overlay only redraws when asked. Nothing else triggers it here: the selection didn't
	# change and the palette button, not the viewport, is what fired this.
	update_overlays()


# --- Group edit-mode (open / close) ----------------------------------------

## Open a group for editing: its members become live kernels the tools treat as ordinary brushes,
## and _scene_brushes stops answering with anything else.
##
## Opening is a VIEW state, not an edit — nothing is recorded, because nothing has changed yet. Edits
## made while open each fold into the group's `members` as they happen, exactly as they do on a
## closed group, so undo behaves identically either side of opening.
func _open_brush_group(group) -> void:
	if _open_group == group or group == null:
		return
	_close_brush_group()
	_open_group = group
	group.set_kernels_visible(true)
	_group_isolate.enter(group)   # wash the rest of the map back, so only this group reads as live
	set_process(true)             # drive the wash's fade-in (see _process)
	# The group node itself is no longer the thing being edited; its members are.
	EditorInterface.get_selection().clear()
	_selected_faces = []
	_group_ops.update_menu()   # Group/Ungroup are refused inside an open group
	_update_transform_bars()
	update_overlays()


## Select the open group's member under the cursor, and say so by returning true.
##
## A member is an UNOWNED node, and Godot's own click-select only ever picks from the saved scene —
## so a press that lands on one does nothing whatsoever unless the plugin selects it here. With no
## tool active that already happens as part of a richer gesture (CTRL toggle, paint-drag, arming a
## move); with a tool up the press is not also a move, so only the selection itself is wanted.
##
## Without this, hopping from one member to the next meant leaving the group and coming back, which
## is the opposite of what having the group open is for.
func _select_member_under(camera: Camera3D, pos: Vector2, ctrl: bool) -> bool:
	if _open_group == null:
		return false
	var hit = _raycast_brush_faces(camera.project_ray_origin(pos), camera.project_ray_normal(pos))
	if hit == null:
		return false
	if ctrl:
		_toggle_selected(hit.node)
	else:
		_select_only(hit.node)
		_selected_faces = []
	update_overlays()
	return true


## Double-click on a closed group opens it, and says so by returning true.
##
## Offered to the vertex/edge/face tools as well as to the no-tool case, because those are exactly
## the tools a closed group REFUSES — with one of them up, double-clicking a group has only one
## possible meaning: get inside so the tool applies. The palette greys those buttons out when a group
## is selected but does not unpress them, so the tool is still the active mode and the gesture would
## otherwise land nowhere.
##
## Brush and clip are left out on purpose: both already assign their own meaning to a double-click.
## The pick is by exact FACE, never by bounding box. A group's AABB is the box around a whole ROOM,
## and a level-spanning one — a ground plane, a skybox shell — encloses most of the map, so a
## box-level pick hands back that group for a double-click anywhere on screen. Opening it then
## isolates picking to ITS members, and every following click either grabs one of them or just drops
## the selection, so the editor reads as stuck on a group the user never pointed at, with no way out
## but another double-click.
func _open_group_under(camera: Camera3D, pos: Vector2) -> bool:
	var hit = _raycast_brush_faces(camera.project_ray_origin(pos),
		camera.project_ray_normal(pos), true)
	if hit == null:
		return false
	# A group face answers as that member's kernel, so ask what the pick SELECTS as: that is the
	# group, and it is the same resolution a single click uses, so click and double-click can never
	# disagree about which group is under the cursor.
	var target := _selectable_of(hit.node)
	if not (target is BrushGroup):
		return false
	_open_brush_group(target)
	return true


## A press that grabbed nothing inside the open group leaves the group, and says so by returning
## true. Picking is isolated to the members, so "grabbed nothing" already means "outside the group".
##
## The subtlety is that a press landing squarely on a brush ELSEWHERE in the map looks identical to a
## press on empty space, because the isolated raycast cannot see that brush at all. Without this the
## editor's own click-select would happily pick it up and a handle tool would start reshaping it,
## through an open group, with no way to tell from the screen that anything had left the group's
## scope. Which is why every tool that can act on a bare press has to ask — not just the no-tool case.
##
## Consumed by the caller, so the click that ends the scope doesn't also select what it landed on.
func _leave_group_on_outside_press(camera: Camera3D, pos: Vector2) -> bool:
	if _open_group == null:
		return false
	if _raycast_brushes(camera.project_ray_origin(pos), camera.project_ray_normal(pos)) != null:
		return false
	# With a selection standing, the first outside press only DROPS it — the same thing clicking
	# empty space means anywhere else — so a stray click can't throw the user out of the group
	# mid-edit. Leaving takes a press with nothing selected at all.
	var sel := EditorInterface.get_selection()
	if not sel.get_selected_nodes().is_empty() or not _selected_faces.is_empty():
		sel.clear()
		_selected_faces = []
		_sync_texture_dock()
		_update_transform_bars()
		update_overlays()
		return true
	_close_brush_group()
	return true


## Pull a group's origin back into its geometry, as its own undo step.
##
## Editing members walks the origin away from them — a group is centred when it is CREATED and never
## again — which leaves the move gizmo grabbing at empty space and makes a group fiddly to place
## inside a body. Closing the group is the natural moment to fix it: the members have just settled,
## and nothing is mid-drag.
##
## Its OWN action rather than folded into the close above, for two reasons. The close has two
## branches, only one of which is undoable at all, so there is no single action to join; and undo has
## to restore the transform AND the members together — restoring members alone would leave the
## geometry displaced by exactly the offset this removed. Skipped entirely when the group is already
## centred, so closing an untouched group does not litter the undo history.
func _recenter_group(group) -> void:
	if not is_instance_valid(group) or not group.is_inside_tree():
		return
	if group.center_offset().length_squared() < 1e-12:
		return
	var ur := get_undo_redo()
	ur.create_action("Recenter Group")
	ur.add_do_method(group, "recenter")
	# Transform first: the members setter re-bakes UVs from WORLD positions, so it has to run with
	# the transform already put back or the restored mesh is projected from the wrong place.
	ur.add_undo_property(group, "global_transform", group.global_transform)
	ur.add_undo_property(group, "members", group.members.duplicate(true))
	ur.commit_action()


## Collapse the open group back to one node and one mesh.
##
## Anything drawn, pasted or duplicated into the group while it was open arrived as a real child
## brush (see _brush_parent) rather than as a member, so those are absorbed here — that is what makes
## "new geometry joins the open group" true at the point it stops being a node.
func _close_brush_group() -> void:
	if _open_group == null:
		return
	var group = _open_group
	_open_group = null
	_group_isolate.exit()
	set_process(true)      # keep ticking until the wash has faded back out
	if is_instance_valid(group):
		var members: Array = group.read_back_kernels()
		if members.is_empty():
			members = group.members.duplicate(true)
		var adopted: Array[Node3D] = []
		for child in group.get_children():
			if child is Brush and child.owner != null:
				members.append(group.to_local_faces(child.world_faces()))
				adopted.append(child)
		if adopted.is_empty():
			group.members = members
		else:
			# Absorbing real nodes IS an edit, so it is one undo step: the brushes go away and the
			# group gains them as members.
			var ur := get_undo_redo()
			ur.create_action("Add to Group")
			ur.add_do_property(group, "members", members)
			ur.add_undo_property(group, "members", group.members.duplicate(true))
			for child in adopted:
				ur.add_do_method(group, "remove_child", child)
				ur.add_undo_method(group, "add_child", child, true)
				ur.add_undo_method(child, "set_owner", EditorInterface.get_edited_scene_root())
				ur.add_undo_reference(child)
			ur.commit_action()
		group.set_kernels_visible(false)
		group.release_kernels()
		_recenter_group(group)
	EditorInterface.get_selection().clear()
	_selected_faces = []
	_group_ops.update_menu()   # Group/Ungroup are refused inside an open group
	_update_transform_bars()
	update_overlays()


# --- Group transform drags -------------------------------------------------

## Start reshaping the selected groups: snapshot what each began with, and put its kernels on screen
## in place of the combined mesh so the drag deforms visible geometry instead of leaving the group
## frozen until release.
##
## Safe to call for any drag: with no group selected it does nothing, so the begin/end pair can wrap
## the transform tools unconditionally.
func _begin_group_drag() -> void:
	_group_drag = {}
	for group in _selected_groups():
		_group_drag[group] = group.members.duplicate(true)
		group.set_kernels_visible(true)
	# An OPEN group is edited through its kernels directly, so it is never in the selection — but its
	# members are still the durable state, and an edit made inside it has to fold back the same way.
	if _open_group != null and is_instance_valid(_open_group) and not _group_drag.has(_open_group):
		_group_drag[_open_group] = _open_group.members.duplicate(true)


## Finish it: fold each group's reshaped kernels back into one undoable `members` change, and put
## the combined mesh back.
##
## ONE property per group is the whole undo story — the kernels never enter the history, because
## they are transient nodes that undo could only point at after they were freed. The tools skip them
## when recording for exactly that reason, so a mixed brush-and-group drag lands as two entries: the
## tool's own for the loose brushes, and this one for the groups.
func _end_group_drag(action_name: String) -> void:
	if _group_drag.is_empty():
		return
	var ur := get_undo_redo()
	var started := false
	for group in _group_drag:
		if not is_instance_valid(group):
			continue
		var after: Array = group.read_back_kernels()
		if after.is_empty():
			group.set_kernels_visible(false)   # nothing to record, but the mesh must come back
			continue
		if not started:
			ur.create_action(action_name)
			started = true
		ur.add_do_property(group, "members", after)
		ur.add_undo_property(group, "members", _group_drag[group])
		# Applied here, so the action only RECORDS (commit_action(false)).
		group.members = after
		if group != _open_group:
			group.set_kernels_visible(false)   # back to the combined mesh; an open one stays open
	_group_drag = {}
	if started:
		ur.commit_action(false)
	update_overlays()


## Mirror every member of a group through `pivot`, returning the new member list.
##
## Each member is borrowed back as a kernel and handed to _flip_brush, so the mirror, the plane
## reflection and the UV treatment are literally the brush code — there is no second implementation
## to drift. The group NODE is left where it is: the members are stored in its local frame, so
## folding the mirrored world geometry back through the unchanged transform is exact, and moving
## the node as well would mirror the group twice.
func _flip_group_members(group, axis: Vector3, pivot: Vector3) -> Array:
	var out := []
	for i in group.members.size():
		var kernel: Brush = group.kernel_for(i)
		if kernel == null:
			out.append(group.members[i])
			continue
		_flip_brush(kernel, axis, pivot)
		out.append(group.to_local_faces(kernel.world_faces()))
	return out


## Reflect one brush's geometry through `pivot` along world-space `axis`.
##
## The brush's own basis is deliberately left alone. Reflecting the TRANSFORM instead would give
## it a negative determinant, which flips face culling and normals for everything downstream, so
## the mirror is folded into the local planes and the node just moves.
func _flip_brush(node: Node3D, axis: Vector3, pivot: Vector3) -> void:
	var before: Dictionary = node.face_data   # mirrored explicitly below, not carried
	var reflect := Basis(
		Vector3.RIGHT - axis * (2.0 * axis.x),
		Vector3.UP - axis * (2.0 * axis.y),
		Vector3.BACK - axis * (2.0 * axis.z))
	_transform_brush_planes(node, node.planes, reflect)
	node.global_position = pivot + _reflect_point(node.global_position - pivot, axis)
	node.face_data = _transform_face_data(before, reflect, pivot - reflect * pivot)


## Carry the UV mapping through a rigid world transform (p -> linear*p + shift) so the texture
## goes exactly where the geometry goes. Used by both flip and rotate: a mirror and a rotation
## are the same kind of map, and the texture should follow either one rigidly.
##
## Assigning the result LAST deliberately overwrites whatever the plane carry and texture lock
## did on the way through, which is what makes these operations independent of both toggles.
## Those decide how a texture responds to being *edited* or *moved*; this is neither — it's the
## same brush seen from a different pose, so the transformed texture is the only right answer.
##
## Faces line up by index because the transformed planes are built in the original order.
func _transform_face_data(before: Dictionary, linear: Basis, shift: Vector3) -> Dictionary:
	# The shader reads uv = (p·u, p·v) + offset in WORLD space. Solving uv_new(M·p) == uv_old(p)
	# for a rigid M gives u_new = linear·u_old, with the offset absorbing the translation.
	var axis_u: Array = before.get("u", [])
	var axis_v: Array = before.get("v", [])
	var offsets: Array = before.get("offset", [])
	var out_u := []
	var out_v := []
	var out_offset := []
	for i in axis_u.size():
		var u: Vector3 = linear * (axis_u[i] as Vector3)
		var v: Vector3 = linear * (axis_v[i] as Vector3)
		out_u.append(u)
		out_v.append(v)
		out_offset.append((offsets[i] as Vector2) - Vector2(u.dot(shift), v.dot(shift)))
	return {"tex": before.get("tex", []), "offset": out_offset, "u": out_u, "v": out_v}


## Rewrite a brush's planes under a rigid world transform, WITHOUT touching its geometry through
## set_from_points — that grid-snaps every corner, which is fine for axis-aligned edits but would
## mangle a brush rotated to any angle that isn't a multiple of 90 degrees.
##
## Planes carry no such problem: a half-space n·x <= d maps to (L^-T n)·x <= d under any
## invertible L, exactly, at any angle. The brush's own basis is left alone so the transform
## never picks up a negative determinant or a non-uniform scale.
func _transform_brush_planes(node: Node3D, start_planes: Array, linear: Basis) -> void:
	var brush_basis := node.global_transform.basis
	var local := brush_basis.inverse() * linear * brush_basis
	var normal_map := local.inverse().transposed()
	var out: Array[Plane] = []
	for p in start_planes:
		var n: Vector3 = normal_map * (p as Plane).normal
		var length := n.length()
		if length < 1e-9:
			continue
		out.append(Plane(n / length, (p as Plane).d / length))
	node.planes = out


func _reflect_point(v: Vector3, axis: Vector3) -> Vector3:
	return v - axis * (2.0 * v.dot(axis))


## The world axis a direction leans on most. Flips have to land on a world axis or they would
## shear the brush off the grid; the sign is irrelevant since a mirror is symmetric.
func _dominant_axis(dir: Vector3) -> Vector3:
	var a := dir.abs()
	if a.x >= a.y and a.x >= a.z:
		return Vector3.RIGHT
	return Vector3.UP if a.y >= a.z else Vector3.BACK


## Copy the selected brushes in place and select the copies, matching CTRL+drag minus the drag
## (and Godot's own CTRL+D, which already does this for any node). Leaving the copy exactly on
## top of the original is deliberate: it's what TrenchBroom and Godot both do, and any offset we
## invented would fight whichever direction the user actually wants to move it.
func _duplicate_selected_brushes() -> void:
	var brushes := _selected_transformables()
	if brushes.is_empty():
		return
	var root := EditorInterface.get_edited_scene_root()
	var copies := _duplicate_brushes(brushes)   # already parented, owned and selected
	if copies.is_empty():
		return
	var ur := get_undo_redo()
	# commit_action(false) records WITHOUT re-running: the copies are already in the tree.
	ur.create_action("Duplicate Brush")
	for node in copies:
		var parent := node.get_parent()
		ur.add_do_reference(node)
		ur.add_do_method(parent, "add_child", node, true)
		ur.add_do_method(node, "set_owner", root)
		ur.add_do_property(node, "global_position", node.global_position)
		ur.add_undo_method(parent, "remove_child", node)
	ur.commit_action(false)


func _on_tool_changed(tool_id: String) -> void:
	_tool_mode = tool_id
	_handle_tools.reset_vertex()
	_handle_tools.reset_edge()
	_handle_tools.reset_face()
	# Handles belong to the tool that offered them: a vertex selection means nothing in face
	# mode, and carrying it over would drag geometry the user never picked.
	_handle_tools.selection = PackedVector3Array()
	_scale_tool.reset()
	_shear_tool.reset()
	_rotate_tool.reset()
	_clip_tool.reset()
	_hull_tool.reset()
	_handle_tools.hover = null
	_scale_tool.hover_dir = Vector3i.ZERO
	_shear_tool.hover_dir = Vector3i.ZERO
	_rotate_tool.hover_axis = -1
	_rotate_tool.hover_center = false
	_rotate_tool.center_valid = false   # re-centre the widget when the tool is re-entered
	_update_shape_bar()            # entering/leaving a tool shows or hides the shape selector
	_update_transform_bars()       # ...and shows the matching rotate/scale options bar
	update_overlays()


# --- Shared reshape recorder + brush wireframe ----------------------------

## Recentre a reshaped brush and record the whole change for undo. Shared by the vertex, edge and
## face tools (handle_tools.gd) and the SHIFT+face push, which differ only in which corners moved.
##
## Reading the position BEFORE recentring is enough: none of these drags move the node, so what's
## there now is what it was at drag start.
func _record_reshape(ur: EditorUndoRedoManager, node: Node3D, planes_before: Array,
		faces_before: Dictionary) -> void:
	var before := node.global_position
	node.recenter()
	# position, then planes, then face_data in both directions: assigning planes rebuilds and
	# overwrites the UV state, and moving the node can shift it again under texture lock.
	ur.add_do_property(node, "global_position", node.global_position)
	ur.add_do_property(node, "planes", node.planes.duplicate())
	ur.add_do_property(node, "face_data", node.face_data)
	# A kernel is scratch: reshaping a member of an OPEN group is recorded as that group's `members`
	# by the surrounding group write, so recording the node here would point undo at a corpse.
	if _group_of_kernel(node) != null:
		return
	ur.add_undo_property(node, "global_position", before)
	ur.add_undo_property(node, "planes", planes_before)
	ur.add_undo_property(node, "face_data", faces_before)


## Selection highlight: the brush's real face outlines, so you can read the faces instead of a
## bounding box. Shared edges get drawn twice (once per adjacent face) — cheap enough, and it keeps
## the code to a plain loop over the derived polygons.
##
## Edges belonging only to faces that point away from the camera are occluded by the brush, so they
## draw in a darker, fainter tone; edges on a camera-facing face draw at full strength. Brushes are
## convex, so a face's outward normal versus the eye direction settles it. Two passes (hidden faces
## first, then visible ones on top) keep silhouette edges — shared by one hidden and one visible
## face — bright.
func _draw_brush_wireframe(overlay: Control, node, tint := Palette.TB_RED) -> void:
	var front_col := Color(tint, 0.95)
	var back_col := Color(tint.darkened(0.5), 0.1)   # occluded edges: dark, see-through
	var xform: Transform3D = node.global_transform
	var normal_basis := xform.basis.inverse().transposed()   # normals transform by inverse-transpose
	var eye := _draw_camera.global_position
	for want_facing in [false, true]:
		var col := front_col if want_facing else back_col
		for f in node.planes.size():
			var poly: PackedVector3Array = node.face_polygon(f)
			var count := poly.size()
			if count < 3:
				continue
			var world_normal: Vector3 = (normal_basis * node.planes[f].normal).normalized()
			var face_world: Vector3 = xform * node.face_center(f)
			var facing: bool = world_normal.dot(eye - face_world) > 0.0
			if facing != want_facing:
				continue
			for i in count:
				_draw_world_line(overlay, xform * poly[i], xform * poly[(i + 1) % count], col, 1.5)


## Shared drag constraint: the horizontal plane at `plane_y`, or the vertical line through
## `line_point` while ALT is held. Used by the rotate-pivot drag and the vertex/edge/face reshape
## tools (handle_tools.gd) alike.
func _constraint_point(camera: Camera3D, screen_pos: Vector2, alt: bool, plane_y: float,
		line_point: Vector3):
	var ro := camera.project_ray_origin(screen_pos)
	var rd := camera.project_ray_normal(screen_pos)
	if alt:
		var up := Vector3.UP
		var w0 := ro - line_point
		var b := rd.dot(up)
		var denom := 1.0 - b * b
		if absf(denom) < 1e-6:
			return null
		return line_point + up * ((up.dot(w0) - b * rd.dot(w0)) / denom)
	return Plane(Vector3.UP, plane_y).intersects_ray(ro, rd)


# --- Shared handle picking / box + line geometry --------------------------
# The bounding-box handle picker and its ray/box/line math. Used by the scale tool
# (tools/scale_tool.gd), the shear tool (side handles only), and the overlay box draws.

## Which handle the cursor is targeting, or ZERO for none.
##
## Two mechanisms, both taken from TrenchBroom's scale tool, and the second is the answer
## to "how does it know without me hovering the face":
##
##  1. FRONT sides are picked by an honest ray/rectangle intersection — you really are pointing
##     at them — and corners by a fat screen-space radius. Whichever is nearest ALONG THE RAY
##     wins, so the near face beats the far one for free.
##  2. If that finds nothing, a BACK side is picked with NO distance limit at all, by which
##     back-facing side has a boundary edge closest to the ray. The cursor can be anywhere on
##     screen and still resolve to a side. That's the forgiving part — and note it hands back
##     the FAR side, which is exactly what makes the far face reachable at all.
##
## TrenchBroom gets corner-over-edge priority by making corner spheres physically larger rather
## than by a rule. We say it outright instead: with the two distances along the ray nearly equal
## at a corner, a size comparison would flicker between them.
## [param corners] is false for the shear tool, which only has side handles — a sheared corner
## has no meaning, so offering one would be a dead click.
func _pick_scale_handle(camera: Camera3D, screen_pos: Vector2, bounds: AABB,
		corners := true) -> Vector3i:
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)
	# No handles from inside the box — every side is behind you, so nothing you grabbed would
	# move the way you expect.
	if bounds.has_point(ray_origin):
		return Vector3i.ZERO

	for dir in (_scale_corner_dirs() if corners else [] as Array[Vector3i]):
		var world := _handle_position(bounds, dir)
		if camera.is_position_behind(world):
			continue
		if screen_pos.distance_to(camera.unproject_position(world)) < SCALE_GRAB_PX:
			return dir

	# Front sides. Every side is tested, not just the front-facing ones: a ray from outside
	# crosses the near face at a smaller t, so nearest-along-ray sorts them correctly by itself.
	var best := Vector3i.ZERO
	var best_t := INF
	for dir in _scale_side_dirs():
		var t = _ray_side_intersection(ray_origin, ray_dir, bounds, dir)
		if t != null and t < best_t:
			best_t = t
			best = dir
	if best != Vector3i.ZERO:
		return best

	# Unbounded fallback: nearest boundary edge of a side facing AWAY from us.
	var best_dist := INF
	for dir in _scale_side_dirs():
		var axis := _dir_axis(dir)
		var normal := Vector3.ZERO
		normal[axis] = float(dir[axis])
		if normal.dot(ray_dir) < 0.0:
			continue                       # front-facing; handled above
		for edge in _side_edges(bounds, dir):
			var d := _ray_segment_distance(ray_origin, ray_dir, edge[0], edge[1])
			if d < best_dist:
				best_dist = d
				best = dir
	return best


func _dir_axis(dir: Vector3i) -> int:
	return 0 if dir.x != 0 else (1 if dir.y != 0 else 2)


## Ray parameter where it crosses this side's rectangle, or null if it misses.
func _ray_side_intersection(origin: Vector3, dir: Vector3, bounds: AABB, side: Vector3i):
	var axis := _dir_axis(side)
	if absf(dir[axis]) < 1e-9:
		return null
	var lo := bounds.position
	var hi := bounds.position + bounds.size
	var plane_coord: float = hi[axis] if side[axis] > 0 else lo[axis]
	var t: float = (plane_coord - origin[axis]) / dir[axis]
	if t < 0.0:
		return null
	var hit := origin + dir * t
	for i in 3:
		if i == axis:
			continue
		if hit[i] < lo[i] or hit[i] > hi[i]:
			return null
	return t


## The four corners of one side, in ring order.
func _side_quad(bounds: AABB, side: Vector3i) -> Array:
	var axis := _dir_axis(side)
	var lo := bounds.position
	var hi := bounds.position + bounds.size
	var fixed: float = hi[axis] if side[axis] > 0 else lo[axis]
	var a := (axis + 1) % 3
	var b := (axis + 2) % 3
	var quad := []
	for pair in [[false, false], [true, false], [true, true], [false, true]]:
		var p := Vector3.ZERO
		p[axis] = fixed
		p[a] = hi[a] if pair[0] else lo[a]
		p[b] = hi[b] if pair[1] else lo[b]
		quad.append(p)
	return quad


## The four boundary edges of one side, as [start, end] pairs.
func _side_edges(bounds: AABB, side: Vector3i) -> Array:
	var quad := _side_quad(bounds, side)
	var out := []
	for i in 4:
		out.append([quad[i], quad[(i + 1) % 4]])
	return out


## Shortest distance between a ray and a line SEGMENT (clamped at both ends, so an edge doesn't
## act like an infinite line and win from far past its own extent).
func _ray_segment_distance(origin: Vector3, dir: Vector3, a: Vector3, b: Vector3) -> float:
	var seg := b - a
	var w := origin - a
	var seg_sq := seg.length_squared()
	if seg_sq < 1e-12:
		return _ray_point_distance(origin, dir, a)
	# Closest approach of two infinite lines (`dir` is unit, so its own dot is 1), then the
	# segment parameter is clamped back into [0, 1] and the ray's into [0, inf).
	var b_dot := dir.dot(seg)
	var c_dot := dir.dot(w)
	var f_dot := seg.dot(w)
	var denom := seg_sq - b_dot * b_dot
	var s := 0.0
	if absf(denom) > 1e-12:
		s = clampf((f_dot - b_dot * c_dot) / denom, 0.0, 1.0)
	else:
		s = clampf(-f_dot / seg_sq, 0.0, 1.0)   # parallel: any s works, pick the nearest end
	return _ray_point_distance(origin, dir, a + seg * s)


func _ray_point_distance(origin: Vector3, dir: Vector3, point: Vector3) -> float:
	var t := maxf((point - origin).dot(dir), 0.0)
	return point.distance_to(origin + dir * t)


## World position of a handle: for each axis, the max side, the min side, or the centre when
## that axis isn't part of the handle. Corners and side centres both fall out of this.
func _handle_position(bounds: AABB, dir: Vector3i) -> Vector3:
	var lo := bounds.position
	var hi := bounds.position + bounds.size
	var mid := bounds.get_center()
	return Vector3(
		hi.x if dir.x > 0 else (lo.x if dir.x < 0 else mid.x),
		hi.y if dir.y > 0 else (lo.y if dir.y < 0 else mid.y),
		hi.z if dir.z > 0 else (lo.z if dir.z < 0 else mid.z))


## The 8 corner directions, as (±1, ±1, ±1).
func _scale_corner_dirs() -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for x in [-1, 1]:
		for y in [-1, 1]:
			for z in [-1, 1]:
				out.append(Vector3i(x, y, z))
	return out


## The 6 side directions, as a single ±1 component.
func _scale_side_dirs() -> Array[Vector3i]:
	return [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
		Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]


## Scale a box to `new_size` while holding `anchor` fixed.
func _bounds_scaled_about(from: AABB, new_size: Vector3, anchor: Vector3) -> AABB:
	var factor := Vector3.ONE
	for i in 3:
		if from.size[i] > 1e-9:
			factor[i] = new_size[i] / from.size[i]
	return AABB(anchor + (from.position - anchor) * factor, new_size)


func _aabb_from_points(a: Vector3, b: Vector3) -> AABB:
	var lo := Vector3(minf(a.x, b.x), minf(a.y, b.y), minf(a.z, b.z))
	var hi := Vector3(maxf(a.x, b.x), maxf(a.y, b.y), maxf(a.z, b.z))
	return AABB(lo, hi - lo)


## Point on an infinite line closest to a ray. No range limit — that's the point.
func _closest_point_on_line(ray_origin: Vector3, ray_dir: Vector3,
		line_origin: Vector3, line_dir: Vector3) -> Vector3:
	var w := ray_origin - line_origin
	var b_dot := ray_dir.dot(line_dir)
	var denom := 1.0 - b_dot * b_dot     # both directions are unit length
	if absf(denom) < 1e-9:
		return line_origin               # looking straight down the line; nothing to resolve
	var t := (line_dir.dot(w) - b_dot * ray_dir.dot(w)) / denom
	return line_origin + line_dir * t


## Snap a point on a line so that ONE of its coordinates lands on the grid, choosing whichever
## candidate moves the point least. Snapping each axis independently would pull the point off
## the line entirely, which for a corner's diagonal would break the drag.
func _snap_along_line(point: Vector3, origin: Vector3, dir: Vector3, g: float) -> Vector3:
	if g <= 0.0:
		return point
	var current := dir.dot(point - origin)
	var best := current
	var best_gap := INF
	for i in 3:
		if absf(dir[i]) < 1e-9:
			continue
		var coord: float = point[i]
		for candidate in [floorf(coord / g) * g, ceilf(coord / g) * g]:
			var t: float = (candidate - origin[i]) / dir[i]
			var gap := absf(t - current)
			if gap < best_gap:
				best_gap = gap
				best = t
	return origin + dir * best


func _is_side_dir(dir: Vector3i) -> bool:
	return absi(dir.x) + absi(dir.y) + absi(dir.z) == 1


func _draw_box_outline(overlay: Control, bounds: AABB, col: Color, width: float) -> void:
	var lo := bounds.position
	var hi := bounds.position + bounds.size
	var corners := [
		Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z),
		Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z),
		Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z),
		Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z),
	]
	var edges := [0, 1, 1, 2, 2, 3, 3, 0,  4, 5, 5, 6, 6, 7, 7, 4,  0, 4, 1, 5, 2, 6, 3, 7]
	var i := 0
	while i < edges.size():
		_draw_world_line(overlay, corners[edges[i]], corners[edges[i + 1]], col, width)
		i += 2


# --- SHIFT + face: selection and push --------------------------------------

## World plane of one face of a brush.
func _face_world_plane(node: Node3D, face: int) -> Plane:
	var normal: Vector3 = (node.global_transform.basis
		* (node.planes[face] as Plane).normal).normalized()
	return Plane(normal, normal.dot(node.global_transform * node.face_center(face)))


func _face_world_polygon(node: Node3D, face: int) -> PackedVector3Array:
	var to_world: Transform3D = node.global_transform
	var out := PackedVector3Array()
	for p in node.face_polygon(face):
		out.append(to_world * p)
	return out


func _face_entry_matches(entry, node: Node3D, face: int) -> bool:
	return entry != null and entry.node == node and entry.face == face


func _face_is_selected(node: Node3D, face: int) -> bool:
	for entry in _selected_faces:
		if _face_entry_matches(entry, node, face):
			return true
	return false


## Push a face along its own normal. Deliberately NOT the free face-mode drag: the gesture starts
## from a hover on the face itself, so the only motion that reads as "move this face" is in and
## out along the way it points.
func _begin_face_push(camera: Camera3D, node: Node3D, face: int, new_brush: bool,
		press_point: Vector3) -> bool:
	# Both gestures move THIS face's plane on the source brush — the plain push always, the new-brush
	# extrude only when dragged inward (the cut). Guard the shared setup on a real face.
	if node.face_polygon(face).size() < 3:
		_push_active = false
		return false

	var plane := _face_world_plane(node, face)
	_push_normal = plane.normal
	_push_plane_d = plane.d
	# Anchored at the point PRESSED, not the face's centre. _update_face_push solves the mouse ray
	# against the line through here along the normal, and that solve degrades the further the ray
	# passes from the line — so on a large face, grabbing near a corner meant fighting a line
	# metres away across the middle of it. The press point puts the line directly under the cursor
	# wherever it started.
	#
	# Safe for the snapping below: `base` is _push_origin.dot(_push_normal), and both the centre
	# and the press point lie ON the face's plane, so both give the same plane distance. Only the
	# line's lateral position moves, which is the whole point.
	_push_origin = press_point
	_push_offset = 0.0
	_push_applied_offset = 0.0
	_push_active = true
	_push_new_brush = new_brush
	# The hover entry holds a face INDEX, and re-solving the hull can reorder the plane list —
	# so it stops naming this face the moment the push starts.
	_shift_face_hover = null

	# Source-brush plane move (TrenchBroom "resize brush"): move the face's PLANE and let the hull
	# re-derive from the intersection of half-spaces. Moving the corner VERTICES instead would keep
	# their XZ fixed and merely lengthen the face; moving the plane lets the neighbours re-clip it,
	# so the top of a clipped pyramid slid up follows the slopes to a point — exactly like TB. This
	# same data drives the new-brush extrude's inward cut.
	_push_nodes = [node]
	_push_local_index = face   # planes.duplicate() preserves order, so the index is stable
	_push_start_planes = [node.planes.duplicate()]
	_push_start_faces = [node.face_data]
	# Both locks are suppressed for the duration, then put back. Turning them OFF is not the
	# same as restoring the old face_data afterwards: face_data is index-aligned to `planes`,
	# and re-solving the hull can reorder that list — so writing the old array back by index
	# lands textures on the wrong faces. Letting the normal plane-matched carry run with the
	# locks clear is what "as if both options were off" actually means.
	_push_locks = [{"texture": node.texture_lock, "uv": node.uv_lock}]
	node.texture_lock = false
	node.uv_lock = false

	if new_brush:
		# Extrude a fresh brush FROM the face. TrenchBroom immediately creates the new brush and then
		# resizes it like a normal SHIFT-drag — so the extrusion is bounded by the SOURCE's neighbour
		# planes (it follows the taper to a point, not a straight cuboid) and inherits the source's
		# looks rather than a "new brush" placeholder texture. Snapshot the source's world faces now;
		# the blueprint is rebuilt from them each frame.
		_push_source_faces = node.world_faces()
		_push_source_face_index = _world_face_index(_push_source_faces, _push_normal, _push_plane_d)
		if _push_source_face_index < 0:
			_reset_face_push()
			return false
	return true


## Where the pushed face has got to, as an index into the brush's CURRENT plane list. Matched by
## plane — the normal is unchanged by the push and the distance moves with it — because indices
## do not survive a hull re-solve.
func _push_face_index(node: Node3D) -> int:
	var wanted := _push_plane_d + _push_offset
	for f in node.planes.size():
		if node.face_polygon(f).size() < 3:
			continue
		var plane := _face_world_plane(node, f)
		if plane.normal.dot(_push_normal) >= 0.999 and absf(plane.d - wanted) < 0.001:
			return f
	return -1


func _update_face_push(camera: Camera3D, screen_pos: Vector2) -> void:
	var on_line := _closest_point_on_line(
		camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos),
		_push_origin, _push_normal)
	# ABSOLUTE snap: snap the moved face's world DISTANCE along the normal to the grid, not the
	# delta from the drag start. A face that began off the current grid (e.g. built at grid 16,
	# now editing at 64) therefore extrudes to the nearest grid line first — a partial step — and
	# then moves in whole grid increments, instead of the delta-snap which could never reach a
	# grid line from an off-grid start.
	var base := _push_origin.dot(_push_normal)
	var raw := (on_line - _push_origin).dot(_push_normal)
	_push_offset = snappedf(base + raw, grid_size) - base

	# The face normal points OUTWARD: a positive offset pulls away from the solid, a negative one
	# drives into it. The SOURCE brush is never touched live either way. OUTWARD shows the new brush
	# for real — a live, fully-textured preview grows as you drag (committed on release). INWARD keeps
	# the brush whole and previews just the CUTTING FACE (a yellow overlay), splitting only on release.
	if _push_new_brush:
		if _push_offset > 0.0:
			_update_extrude_preview()   # real textured brush, grows live
		else:
			_clear_extrude_preview()
			if _push_offset < 0.0 and not _face_moved_planes(_push_offset).is_empty():
				_push_applied_offset = _push_offset   # deepest valid cut so far (guarded)
		update_overlays()
		return

	# Plain push (resize): this one DOES move live — the face slides as you drag.
	_apply_face_plane_move()
	update_overlays()


## The source's planes with the pushed face moved by `offset` along its own normal, or [] if that
## move would collapse the solid (the anti-erase guard). Pure computation — assigns nothing.
func _face_moved_planes(offset: float) -> Array[Plane]:
	var start: Array = _push_start_planes[0]
	var idx := _push_local_index
	var node: Node3D = _push_nodes[0]
	var local_normal: Vector3 = (start[idx] as Plane).normal
	# Map the world-space push onto the plane's own axis. For the usual rotation-only brush this is
	# just the offset; the projection keeps it correct under a rotated basis.
	var local_delta: Vector3 = node.global_transform.basis.inverse() * (_push_normal * offset)
	var delta_d: float = local_normal.dot(local_delta)
	# Only the pushed plane's distance changes; every other plane keeps its exact original.
	var modified: Array[Plane] = []
	modified.assign(start)
	modified[idx] = Plane(local_normal, (start[idx] as Plane).d + delta_d)
	if _planes_bound_solid(modified):
		return modified
	return []


## Apply the pushed face's plane move to the source brush LIVE (the plain-push resize), guarded so it
## can never erase the brush. No-op when the move would collapse the solid — the face clamps.
func _apply_face_plane_move() -> void:
	var moved := _face_moved_planes(_push_offset)
	if moved.is_empty():
		return
	_push_nodes[0].planes = moved
	_push_applied_offset = _push_offset


## Live preview of the OUTWARD extrude: an unowned Brush stamped from the extrusion blueprint with its
## REAL inherited face textures (no ghost material), so the new brush appears to grow for real as you
## drag. Transient — cleared on release, then re-made as the committed brush. At identity so a world
## plane IS the local plane; not recentred (it's throwaway).
func _update_extrude_preview() -> void:
	var root := EditorInterface.get_edited_scene_root()
	var blueprint := _extruded_blueprint(_push_offset)
	if root == null or blueprint.size() < 4:
		_clear_extrude_preview()
		return
	if not is_instance_valid(_push_preview):
		_push_preview = _blank_brush()
		root.add_child(_push_preview)   # unowned -> never saved, excluded from brush enumeration
	_push_preview.global_transform = Transform3D.IDENTITY
	_push_preview.set_world_faces(blueprint)


func _clear_extrude_preview() -> void:
	if is_instance_valid(_push_preview):
		_push_preview.queue_free()
	_push_preview = null


## Whether a set of local planes still bounds a real solid (>= 4 faces with area). Pure geometry, so
## the CSG pruner does the work — this is the anti-erase guard for face pushes and cuts.
func _planes_bound_solid(planes: Array) -> bool:
	var faces := []
	for p in planes:
		faces.append({"plane": p})
	return Csg._prune(faces).size() >= 4


## The offset the extruded slab should span. Outward the source isn't cut, so the raw cursor offset
## is exact. Inward the slab must match the source's ACTUAL cut plane (the guard may have clamped it
## short of the cursor), so use the applied offset — otherwise an overshoot slab overlaps the source.
func _effective_push_offset() -> float:
	return _push_applied_offset if _push_offset < 0.0 else _push_offset


## World-space polygon of the CUTTING FACE at the given depth: the pushed face's plane slid inward by
## `offset`, clipped by the source's other (neighbour) planes — i.e. the cross-section the moving
## plane carves through the still-whole brush. Empty if there's no cut yet. Drives the inward preview.
func _cut_face_polygon(offset: float) -> PackedVector3Array:
	if _push_source_face_index < 0 or is_zero_approx(offset):
		return PackedVector3Array()
	var cut_plane := Plane(_push_normal, _push_plane_d + offset)
	var neighbours := []
	for i in _push_source_faces.size():
		if i != _push_source_face_index:
			neighbours.append(_push_source_faces[i]["plane"])
	return Csg._polygon(cut_plane, neighbours, -1)


## Index of the world face whose plane matches (normal, d), or -1. Used to find the pushed face in a
## world_faces() snapshot, which skips clipped-away faces so it isn't index-aligned to `planes`.
func _world_face_index(faces: Array, normal: Vector3, d: float) -> int:
	for i in faces.size():
		var plane: Plane = faces[i]["plane"]
		if plane.normal.dot(normal) >= 0.999 and absf(plane.d - d) < 0.001:
			return i
	return -1


## World-face blueprint for the extruded brush at the given offset: the source's NEIGHBOUR faces
## (kept verbatim, so their planes bound the same taper and their textures continue), plus two caps
## wearing the pushed face's look — the moved outer face and the inner seam sitting on the source's
## original face. Pruned so neighbour planes that don't actually bound the slab drop out. Empty if
## the offset collapses it. The result follows the source's slopes exactly, like a SHIFT-drag resize.
func _extruded_blueprint(offset: float) -> Array:
	if _push_source_face_index < 0 or is_zero_approx(offset):
		return []
	var look: Dictionary = _push_source_faces[_push_source_face_index]
	var blueprint := []
	for i in _push_source_faces.size():
		if i != _push_source_face_index:
			blueprint.append((_push_source_faces[i] as Dictionary).duplicate())
	# The slab spans between the original face (at _push_plane_d) and the moved plane (+ offset),
	# whichever way the drag went. Cap the HIGH side with +normal and the LOW side with -normal so it
	# encloses a solid for both an OUTWARD extrude and an INWARD cut (where it's the split-off piece).
	var hi := maxf(_push_plane_d, _push_plane_d + offset)
	var lo := minf(_push_plane_d, _push_plane_d + offset)
	blueprint.append(_cap_face(Plane(_push_normal, hi), look))
	blueprint.append(_cap_face(Plane(-_push_normal, -lo), look))
	return Csg._prune(blueprint)


## A cap face on `plane` wearing `look`'s UV axes / offset / surface (a world_faces() entry).
func _cap_face(plane: Plane, look: Dictionary) -> Dictionary:
	return {"plane": plane, "u": look["u"], "v": look["v"], "offset": look["offset"],
		"tex": look["tex"], "material": look["material"]}


## The release decides which gesture the CTRL+SHIFT drag was, by the sign of the final offset — so a
## single drag can swing outward (extrude) and inward (cut) freely and only commit what it ends on.
## The source was never touched during the drag (it stayed whole), so crossing needs no undo.
func _commit_face_push() -> void:
	if _push_active and not is_zero_approx(_push_offset):
		if _push_new_brush and _push_offset > 0.0:
			_commit_face_extrude()   # outward: add a brand-new brush, source untouched
		elif _push_new_brush:
			_commit_face_split()     # inward: split the source, keeping the far part + the slab
		else:
			# Plain push (resize): the geometry is already applied live, guarded so it still has
			# volume. If the guard clamped every step (a face driven straight through), the planes
			# never changed — record nothing rather than leave a no-op undo step.
			var node: Node3D = _push_nodes[0]
			if node.planes != _push_start_planes[0]:
				var ur := get_undo_redo()
				ur.create_action("Push Face")
				_record_reshape(ur, node, _push_start_planes[0], _push_start_faces[0])
				ur.commit_action(false)   # already applied during the drag
	_reset_face_push()


## A fresh Brush carrying this plugin's snap/grid settings, ready to be stamped with a blueprint.
func _blank_brush() -> Brush:
	var brush := Brush.new()
	brush.grid_size = grid_size
	brush.name = "Brush"
	return brush


## Register the do/undo methods that add `brush` and stamp it from a world-face blueprint — the CSG
## flow: parent, own, force world-identity, set_world_faces (world plane = local plane), recenter to
## pull the origin into the geometry. Caller opens/commits the action.
func _add_blueprint_brush(ur: EditorUndoRedoManager, parent: Node, root: Node, brush: Brush,
		blueprint: Array) -> void:
	ur.add_do_method(parent, "add_child", brush, true)
	ur.add_do_method(brush, "set_owner", root)
	ur.add_do_property(brush, "global_transform", Transform3D.IDENTITY)
	ur.add_do_method(brush, "set_world_faces", blueprint)
	ur.add_do_method(brush, "recenter")
	ur.add_do_reference(brush)
	ur.add_undo_method(parent, "remove_child", brush)


## Turn the outward extrusion into a real brush: bounded by the source's neighbour planes (follows
## the taper) with its faces inheriting the source's looks. The source is left untouched.
func _commit_face_extrude() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var blueprint := _extruded_blueprint(_effective_push_offset())
	if blueprint.size() < 4:
		return
	var brush := _blank_brush()
	var ur := get_undo_redo()
	ur.create_action("Extrude Brush")
	_add_blueprint_brush(ur, _brush_parent(), root, brush, blueprint)
	ur.commit_action()

	_select_only(brush)


## Commit an inward CTRL+SHIFT drag as a SPLIT. The brush stayed WHOLE during the drag (only the
## yellow cutting-face outline previewed it), so the cut is applied HERE: the source keeps the far
## part, and the slab between the cut plane and the original face becomes its own new brush — one undo
## step. Uses the guarded applied offset, so an overshoot past the far side clamps instead of erasing.
func _commit_face_split() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	if is_zero_approx(_push_applied_offset):
		return   # never a valid cut depth
	var cut := _face_moved_planes(_push_applied_offset)
	if cut.is_empty():
		return
	var node: Node3D = _push_nodes[0]
	var blueprint := _extruded_blueprint(_push_applied_offset)
	# Apply the cut to the source now (it was left whole while dragging).
	node.planes = cut
	if blueprint.size() < 4:
		# Can't form the slab: keep the cut alone rather than losing the whole gesture.
		var ur0 := get_undo_redo()
		ur0.create_action("Cut Face")
		_record_reshape(ur0, node, _push_start_planes[0], _push_start_faces[0])
		ur0.commit_action(false)
		return

	var slab := _blank_brush()
	var ur := get_undo_redo()
	ur.create_action("Split Brush")
	# The source cut is applied above; _record_reshape's do-methods re-assert the same values, so
	# committing WITH execution (for the slab's add_child) leaves the source exactly as it sits.
	_record_reshape(ur, node, _push_start_planes[0], _push_start_faces[0])
	_add_blueprint_brush(ur, _brush_parent(), root, slab, blueprint)
	ur.commit_action()

	# Keep the existing selection (the source brush stays selected) and ADD the new slab, rather
	# than replacing the selection with just the slab.
	EditorInterface.get_selection().add_node(slab)


func _reset_face_push() -> void:
	_clear_extrude_preview()   # drop the live extrude preview, whether it committed or was abandoned
	# Restore the toggles the push suppressed, whether it committed or was abandoned.
	for i in _push_locks.size():
		var node: Node3D = _push_nodes[i]
		if is_instance_valid(node):
			node.texture_lock = _push_locks[i].texture
			node.uv_lock = _push_locks[i].uv
	_push_locks = []
	_push_active = false
	_push_new_brush = false
	_push_applied_offset = 0.0
	_push_local_index = -1
	_push_source_faces = []
	_push_source_face_index = -1
	_push_nodes = []
	_push_start_planes = []
	_push_start_faces = []
	_push_offset = 0.0


## SHIFT+click selects the face and DESELECTS its brush. The two are alternatives: the texture
## inspector works on faces, every other tool works on brushes, and leaving both selected would
## leave it ambiguous which one an operation is aimed at.
func _select_face(node: Node3D, face: int, add: bool) -> void:
	if not add:
		_selected_faces = []
	for i in _selected_faces.size():
		if _face_entry_matches(_selected_faces[i], node, face):
			_selected_faces.remove_at(i)     # clicking a selected face again drops it
			_sync_texture_dock()
			_csg_ops.update_menu()   # a two-face selection lights up Convex Merge's face-bridge
			_update_shape_bar()      # dropping the last face re-arms drawing, so show the selector
			update_overlays()
			return
	_selected_faces.append({"node": node, "face": face})
	EditorInterface.get_selection().clear()
	_sync_texture_dock()
	_csg_ops.update_menu()   # a two-face selection lights up Convex Merge's face-bridge
	# Not left to the selection_changed above: clear() on an ALREADY empty selection emits nothing,
	# which is exactly the case here — picking a face with no brush selected. The bar would then
	# stay up over a gesture that has just stood down.
	_update_shape_bar()
	update_overlays()


## The UV-transfer mode for a mouse-button chord, or "" if it isn't one. Exact-mask, exactly like
## TrenchBroom: ALT alone projects, ALT+SHIFT rotates, ALT+CTRL/CMD
## copies the material only; any other combination (ALT+SHIFT+CTRL, no ALT) is not a transfer.
func _uv_copy_chord(mb: InputEventMouseButton) -> String:
	if not mb.alt_pressed:
		return ""
	var ctrl := mb.ctrl_pressed or mb.meta_pressed
	if mb.shift_pressed and not ctrl:
		return "rotation"
	if ctrl and not mb.shift_pressed:
		return "material"
	if not mb.shift_pressed and not ctrl:
		return "projection"
	return ""


## Start an ALT UV-transfer gesture: paint the first target — the clicked face, or every face of its
## brush on a double-click — from the single selected source face. Applied live; the whole gesture is
## banked as one undo step by _commit_uv_copy on release, and a drag extends it (see the motion
## handler), each face then copying from the LAST painted one.
func _begin_uv_copy(mode: String, node: Node3D, face: int, whole_brush: bool) -> void:
	_uv_copy_active = true
	_uv_copy_mode = mode
	_uv_copy_whole = whole_brush
	_uv_copy_before = {}
	_uv_copy_group_before = {}
	_uv_copy_painted = {}
	_uv_copy_from = _selected_faces[0]
	if whole_brush:
		# Double-click: every face of the target brush, all from the ORIGINAL source (no chaining).
		for f in node.planes.size():
			if node.face_polygon(f).size() >= 3:
				_paint_uv_copy(node, f)
	elif _paint_uv_copy(node, face):
		# A drag continues from the face just painted, so the alignment flows across the run.
		_uv_copy_from = {"node": node, "face": face}
	update_overlays()


## Copy the current source face's surface — and, unless the mode is material-only, its UV alignment —
## onto (node, face). Snapshots the node's face_data once per gesture (so the whole thing is one undo
## step) and skips faces already painted, so a wandering drag can't stack transfers. Returns whether
## it actually painted a face.
func _paint_uv_copy(node: Node3D, face: int) -> bool:
	if _uv_copy_from == null or not is_instance_valid(node):
		return false
	var src_node: Node3D = _uv_copy_from.node
	var src_face: int = _uv_copy_from.face
	if not is_instance_valid(src_node) or face < 0 or face >= node.planes.size():
		return false
	if node.face_polygon(face).size() < 3:
		return false          # a clipped-away face has no surface to paint
	var key := "%d:%d" % [node.get_instance_id(), face]
	if _uv_copy_painted.has(key):
		return false
	_uv_copy_painted[key] = true
	if not _uv_copy_before.has(node):
		_uv_copy_before[node] = node.face_data
		# Painting a grouped face lands on that member's kernel, so the group's members are what
		# gets recorded — snapshot them the first time this gesture touches the group.
		var group = _group_of_kernel(node)
		if group != null and not _uv_copy_group_before.has(group):
			_uv_copy_group_before[group] = group.members.duplicate(true)
	# The surface (material or texture) is copied in every mode.
	_apply_surface_to_face(node, face, _face_surface_of(src_node, src_face))
	if _uv_copy_mode != "material":
		node.copy_face_uv_from(src_node, src_face, face, _uv_copy_mode)
	return true


## Bank the live-applied ALT gesture as one undo step, and adopt the copied surface as the current
## one (like a drop does). No-op when nothing was painted.
func _commit_uv_copy() -> void:
	if not _uv_copy_before.is_empty():
		var ur := get_undo_redo()
		# A double-click's whole-brush pass folds into the single-click transfer Godot fired first
		# (MERGE_ENDS keeps that action's original undo state and swaps in this pass's result), so the
		# pair is one undo step. Every other gesture stays its own step.
		ur.create_action("Transfer Face Attributes",
			UndoRedo.MERGE_ENDS if _uv_copy_whole else UndoRedo.MERGE_DISABLE)
		for node in _uv_copy_before:
			if not is_instance_valid(node) or _group_of_kernel(node) != null:
				continue   # a kernel's write is recorded as its group's members, just below
			ur.add_undo_property(node, "face_data", _uv_copy_before[node])
			_clear_material_overrides(ur, node)
			ur.add_do_property(node, "face_data", node.face_data)
		_fold_kernel_writes(ur, _uv_copy_group_before)
		ur.commit_action(false)   # already applied live
		if _uv_copy_from != null and is_instance_valid(_uv_copy_from.node):
			var surface := _face_surface_of(_uv_copy_from.node, _uv_copy_from.face)
			if surface != null:
				_active_surface = surface
		_sync_texture_dock()
	_uv_copy_active = false
	_uv_copy_mode = ""
	_uv_copy_whole = false
	_uv_copy_from = null
	_uv_copy_before = {}
	_uv_copy_group_before = {}
	_uv_copy_painted = {}


## The faces the inspector acts on: the explicit face selection, or — when whole brushes are
## selected instead — every face of those brushes. A selected brush IS a full face selection, so
## the inspector treats the two the same rather than needing a separate "whole brush" path.
func _target_faces() -> Array:
	# Prune freed nodes first. A face selection outlives the brush it was made on whenever one is
	# deleted, undone away, or left behind by a closing scene, and every consumer feeds entry.node
	# straight into a typed Node3D parameter — which faults on a freed instance rather than quietly
	# skipping it. Clearing on scene change covers the common case; this covers the rest.
	for i in range(_selected_faces.size() - 1, -1, -1):
		if not is_instance_valid(_selected_faces[i].node):
			_selected_faces.remove_at(i)
	if not _selected_faces.is_empty():
		return _selected_faces.duplicate()
	var out: Array = []
	for node in _selected_brushes():
		for f in node.planes.size():
			if node.face_polygon(f).size() >= 3:
				out.append({"node": node, "face": f})
	return out


## Push the current target to the dock: how many faces, and the texture they share (or null when
## they differ), so the browser can show it and the header can name it.
func _sync_texture_dock() -> void:
	if not is_instance_valid(_texture_dock):
		return
	var faces := _target_faces()
	var shared: Resource = null
	var first := true
	for entry in faces:
		var surf: Resource = _face_surface_of(entry.node, entry.face)
		if first:
			shared = surf
			first = false
		elif surf != shared:
			shared = null
			break
	# Faces sharing one surface make it the active/current one (TrenchBroom's behaviour), so it
	# carries over to new brushes. A mixed or empty selection leaves it as-is.
	if shared != null:
		_active_surface = shared
	_texture_dock.set_target(faces.size(), shared)
	_texture_dock.set_active(_active_surface)
	_texture_dock.set_in_use(_in_use_surfaces())
	_refresh_uv_views()


## The dock's UV fields and canvas for the current target faces. Split out of _sync_texture_dock so
## undo/redo can put the MAPPING back on screen without also re-running the whole-scene in-use scan
## that the rest of that function does.
##
## Wired to the undo manager's version_changed alongside the viewport redraw (see _enter_tree).
## Without it an undone UV edit moved the texture back on the brush but left the dock and the UV
## canvas showing the mapping that had just been undone — the canvas reads its polygons once, when
## pushed, so nothing brought it back by itself.
func _refresh_uv_views() -> void:
	if not is_instance_valid(_texture_dock):
		return
	var faces := _target_faces()
	# UV fields: show the first target face's values, editable only when there's a face to edit.
	# Offset is stored in tile units but shown in pixels (× texture size), matching TrenchBroom.
	if faces.is_empty():
		_texture_dock.set_uv(Vector2.ZERO, Vector2.ONE, 0.0, false)
		_texture_dock.set_material_info(null)
		_texture_dock.set_mixed(false, false, false, false, false)
	else:
		var node0: Node3D = faces[0].node
		var face0: int = faces[0].face
		var uv: Dictionary = node0.get_face_uv(face0)
		var tex: Texture2D = _face_texture_of(node0, face0)
		_texture_dock.set_uv(_tile_to_px(uv.offset, tex), uv.scale, uv.angle, true)
		_texture_dock.set_material_info(_face_surface_of(node0, face0))
		var m := _uv_mixed_flags(faces)
		_texture_dock.set_mixed(m.off_x, m.off_y, m.scale_x, m.scale_y, m.angle)
	_push_uv_canvas()   # single-face only; empty otherwise


## Every SURFACE referenced by any brush in the edited scene, as a set (Resource -> true). Drives the
## dock's yellow "in use" outline — a material face marks its material, a texture face its texture.
func _in_use_surfaces() -> Dictionary:
	var used: Dictionary = {}
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		_gather_in_use(root, used)
	return used


func _gather_in_use(node: Node, used: Dictionary) -> void:
	if node is Brush:
		for f in node.planes.size():
			var s: Resource = node.face_surface(f)
			if s != null:
				used[s] = true
	for child in node.get_children():
		_gather_in_use(child, used)


func _face_texture_of(node: Node3D, face: int) -> Texture2D:
	var tex_list: Array = node.face_data.get("tex", [])
	return tex_list[face] if face < tex_list.size() else null


## The surface a face wears (its material override, else its texture) — the unit the browser,
## in-use highlight and right-click actions key on.
func _face_surface_of(node: Node3D, face: int) -> Resource:
	return node.face_surface(face)


## UV offset is stored in tile units (1.0 = one texture tile); the dock shows it in texture pixels.
## Which UV components differ across the target faces — drives the dock's "multi" overlays. Offset
## is compared in the pixels the field shows (so equal tile offsets on different-sized textures,
## which display as different px, count as differing — as they should).
func _uv_mixed_flags(faces: Array) -> Dictionary:
	var m := {"off_x": false, "off_y": false, "scale_x": false, "scale_y": false, "angle": false}
	if faces.size() < 2:
		return m
	var base_uv: Dictionary = faces[0].node.get_face_uv(faces[0].face)
	var base_off: Vector2 = _tile_to_px(base_uv.offset, _face_texture_of(faces[0].node, faces[0].face))
	for i in range(1, faces.size()):
		var e = faces[i]
		var uv: Dictionary = e.node.get_face_uv(e.face)
		var off: Vector2 = _tile_to_px(uv.offset, _face_texture_of(e.node, e.face))
		if not is_equal_approx(off.x, base_off.x): m.off_x = true
		if not is_equal_approx(off.y, base_off.y): m.off_y = true
		if not is_equal_approx(uv.scale.x, base_uv.scale.x): m.scale_x = true
		if not is_equal_approx(uv.scale.y, base_uv.scale.y): m.scale_y = true
		if not is_equal_approx(uv.angle, base_uv.angle): m.angle = true
	return m


## Tile units <-> texels, for the dock's offset field. An unresolved texture falls back to the same
## assumed size Brush and map_io use, rather than to a bare 1:1 — passing tiles through untouched
## while labelling them "px" was the one place the three disagreed.
func _tile_size_of(tex: Texture2D) -> Vector2:
	if tex != null:
		var s := tex.get_size()
		if s.x > 0.0 and s.y > 0.0:
			return s
	return Brush.DEFAULT_TEX_SIZE


func _tile_to_px(tile: Vector2, tex: Texture2D) -> Vector2:
	var s := _tile_size_of(tex)
	return Vector2(tile.x * s.x, tile.y * s.y)


func _px_to_tile(px: Vector2, tex: Texture2D) -> Vector2:
	var s := _tile_size_of(tex)
	return Vector2(px.x / s.x, px.y / s.y)


## Paint every face of a freshly built brush with the active/current texture, so new geometry
## inherits the texture chosen in the browser. No-op when nothing is active. Extrude (shift+drag)
## does NOT use this — it carries the source brush's texture instead.
func _apply_active_surface(brush: Brush) -> void:
	if _active_surface == null:
		return
	for f in brush.planes.size():
		_apply_surface_to_face(brush, f, _active_surface)


## Put a surface on a face: a Material replaces the whole material (Godot's model), a Texture2D goes
## through the StandardMaterial3D path. The single branch every apply/drop/replace site funnels through.
func _apply_surface_to_face(node: Node3D, face: int, surface: Resource) -> void:
	if surface is Material:
		node.set_face_material(face, surface)
	else:
		node.set_face_texture(face, surface as Texture2D)


## Apply a browser choice to every target face, as one undo step. face_data captures the whole
## per-face state, so recording it before and after is exact.
## Clicking empty browser space clears the active/current texture, so new brushes fall back to the
## default (__empty). Doesn't touch any face's texture. The active follows the selection again on
## the next selection change.
func _on_texture_deselected() -> void:
	_active_surface = null
	if is_instance_valid(_texture_dock):
		_texture_dock.set_active(null)


func _on_surface_chosen(surface: Resource) -> void:
	# Clicking a swatch always makes it the active/current surface — that's what new brushes get,
	# whether or not any face is selected right now.
	_active_surface = surface
	var faces := _target_faces()
	if faces.is_empty():
		_sync_texture_dock()   # nothing to paint; just reflect the new active surface in the dock
		return
	var ur := get_undo_redo()
	ur.create_action("Set Face Material" if surface is Material else "Set Face Texture")
	# Group faces by node so each brush's face_data is recorded once, not per face.
	var by_node := {}
	for entry in faces:
		if not by_node.has(entry.node):
			by_node[entry.node] = []
		by_node[entry.node].append(entry.face)
	# A face on a closed group answers as that member's kernel. The write runs through the same
	# per-face code either way, but it is RECORDED as the group's `members` — a kernel is scratch,
	# and undo pointing at it would reach a freed node.
	var group_before := _snapshot_kernel_groups(by_node.keys())
	for node in by_node:
		var is_kernel := _group_of_kernel(node) != null
		if not is_kernel:
			ur.add_undo_property(node, "face_data", node.face_data)
			_clear_material_overrides(ur, node)
		for f in by_node[node]:
			_apply_surface_to_face(node, f, surface)
		if not is_kernel:
			ur.add_do_property(node, "face_data", node.face_data)
	_fold_kernel_writes(ur, group_before)
	ur.commit_action(false)   # already applied
	_sync_texture_dock()


# --- Browser context-menu actions ------------------------------------------

## Every brush face in the scene that wears `surface` (texture or material), as {node, face} — the
## units the texture inspector reads and writes.
func _faces_using(surface: Resource) -> Array:
	var out: Array = []
	for node in _scene_brushes():
		for f in node.planes.size():
			if node.face_surface(f) == surface and node.face_polygon(f).size() >= 3:
				out.append({"node": node, "face": f})
	return out


## Right-click ▸ Select Faces: make every face wearing this surface the face selection the inspector
## acts on. Mirrors _select_face — set the faces, clear the node selection (a brush selection would
## supersede a face one), then sync. No-op if nothing uses it.
func _on_select_faces_requested(surface: Resource) -> void:
	var faces := _faces_using(surface)
	if faces.is_empty():
		return
	_selected_faces = faces
	_shift_face_hover = null
	EditorInterface.get_selection().clear()
	_sync_texture_dock()
	_update_shape_bar()   # a face selection stands the default draw down (see _shape_gesture_live)
	update_overlays()


## Right-click ▸ Select Brushes: select every brush with at least one face wearing this surface.
## add_node fires selection_changed, which resyncs the dock and clears any face selection for us.
func _on_select_brushes_requested(surface: Resource) -> void:
	var sel := EditorInterface.get_selection()
	sel.clear()
	for node in _scene_brushes():
		for f in node.planes.size():
			if node.face_surface(f) == surface:
				sel.add_node(node)
				break


## Right-click ▸ Replace with…: swap every use of `from_surface` for `to_surface` across the whole
## map, as one undo step. Each brush's face_data is recorded once (all its matching faces repainted
## together), matching how _on_surface_chosen batches.
func _on_replace_texture_requested(from_surface: Resource, to_surface: Resource) -> void:
	if to_surface == null or from_surface == to_surface:
		return
	var ur := get_undo_redo()
	var started := false
	for node in _scene_brushes():
		var faces: Array = []
		for f in node.planes.size():
			if node.face_surface(f) == from_surface:
				faces.append(f)
		if faces.is_empty():
			continue
		if not started:
			ur.create_action("Replace Surface")
			started = true
		ur.add_undo_property(node, "face_data", node.face_data)
		_clear_material_overrides(ur, node)
		for f in faces:
			_apply_surface_to_face(node, f, to_surface)
		ur.add_do_property(node, "face_data", node.face_data)
	if not started:
		return   # nothing used the source surface
	ur.commit_action(false)   # already applied
	if _active_surface == from_surface:
		_active_surface = to_surface
	_sync_texture_dock()


func _on_uv_offset_changed(value: Vector2) -> void:
	_apply_uv("offset", value)


func _on_uv_scale_changed(value: Vector2) -> void:
	_apply_uv("scale", value)


func _on_uv_angle_changed(value: float) -> void:
	_apply_uv("angle", value)


## Drag inside the UV canvas: add the delta (tile units) to the single target face's offset, as one
## merged undo step. The canvas is single-face only, so this never touches a multi selection.
func _on_uv_offset_dragged(delta_tiles: Vector2) -> void:
	var faces := _target_faces()
	if faces.size() != 1:
		return
	var node: Node3D = faces[0].node
	var face: int = faces[0].face
	var ur := get_undo_redo()
	ur.create_action("Set Face UV", UndoRedo.MERGE_ENDS)
	var group_before := _begin_face_write(ur, node)
	var current: Vector2 = node.get_face_uv(face).offset
	node.set_face_offset(face, current + delta_tiles)
	_end_face_write(ur, node, group_before)
	ur.commit_action(false)
	# Lightweight refresh: update the canvas + offset field only, skipping the scene-wide in-use scan
	# a full _sync would do on every drag event.
	_push_uv_canvas()
	var uv: Dictionary = node.get_face_uv(face)
	var tex: Texture2D = _face_texture_of(node, face)
	_texture_dock.set_uv(_tile_to_px(uv.offset, tex), uv.scale, uv.angle, true)


# A rotate drag on the UV canvas's origin widget. The start angle and pivot are captured once at
# drag start; every drag event then sets an ABSOLUTE angle (start + total delta), so per-event
# float error can't accumulate over a long drag.
var _uv_rotate_base := 0.0
var _uv_rotate_pivot := Vector2.ZERO


func _on_uv_rotate_started(pivot_uv: Vector2) -> void:
	var faces := _target_faces()
	if faces.size() != 1:
		return
	_uv_rotate_base = faces[0].node.get_face_uv(faces[0].face).angle
	_uv_rotate_pivot = pivot_uv


## Rotate the single target face's mapping about the origin widget, as one merged undo step. The
## numeric angle field deliberately does NOT do this — it keeps rotating about the projection
## origin as before; the pivot behaviour belongs to the canvas widget alone.
func _on_uv_rotate_dragged(delta_deg: float) -> void:
	var faces := _target_faces()
	if faces.size() != 1:
		return
	var node: Node3D = faces[0].node
	var face: int = faces[0].face
	var ur := get_undo_redo()
	ur.create_action("Set Face UV", UndoRedo.MERGE_ENDS)
	var group_before := _begin_face_write(ur, node)
	node.set_face_angle_about(face, _uv_rotate_base + delta_deg, _uv_rotate_pivot)
	_end_face_write(ur, node, group_before)
	ur.commit_action(false)
	# Lightweight refresh, same as the offset drag: canvas + fields, no scene-wide in-use scan.
	_push_uv_canvas()
	var uv: Dictionary = node.get_face_uv(face)
	var tex: Texture2D = _face_texture_of(node, face)
	_texture_dock.set_uv(_tile_to_px(uv.offset, tex), uv.scale, uv.angle, true)


# A scale drag on a UV canvas grid line. The base scale and pivot are captured once at drag start;
# every event then sets an ABSOLUTE scale (base * total factor), mirroring the rotate drag so
# per-event float error can't accumulate.
var _uv_scale_base := Vector2.ONE
var _uv_scale_pivot := Vector2.ZERO


func _on_uv_scale_started(pivot_uv: Vector2) -> void:
	var faces := _target_faces()
	if faces.size() != 1:
		return
	_uv_scale_base = faces[0].node.get_face_uv(faces[0].face).scale
	_uv_scale_pivot = pivot_uv


## Scale the single target face's mapping about the origin widget, as one merged undo step. `factor`
## multiplies the base scale per axis (one axis is 1.0 — the drag only touches the grabbed line's).
func _on_uv_scale_dragged(factor: Vector2) -> void:
	var faces := _target_faces()
	if faces.size() != 1:
		return
	var node: Node3D = faces[0].node
	var face: int = faces[0].face
	var ur := get_undo_redo()
	ur.create_action("Set Face UV", UndoRedo.MERGE_ENDS)
	var group_before := _begin_face_write(ur, node)
	node.set_face_scale_about(face, _uv_scale_base * factor, _uv_scale_pivot)
	_end_face_write(ur, node, group_before)
	ur.commit_action(false)
	# Lightweight refresh, same as the offset drag: canvas + fields, no scene-wide in-use scan.
	_push_uv_canvas()
	var uv: Dictionary = node.get_face_uv(face)
	var tex: Texture2D = _face_texture_of(node, face)
	_texture_dock.set_uv(_tile_to_px(uv.offset, tex), uv.scale, uv.angle, true)


## Apply one UV component (offset / scale / angle) from the dock field to every target face, each
## keeping its own other two components, as one undo step. Not re-synced to the dock afterwards, so a
## live drag on the EditorSpinSlider isn't fought by a value push mid-drag.
func _apply_uv(kind: String, value: Variant) -> void:
	var faces := _target_faces()
	if faces.is_empty():
		return
	var ur := get_undo_redo()
	# MERGE_ENDS collapses a live slider drag (many value_changed events) into one undo step.
	ur.create_action("Set Face UV", UndoRedo.MERGE_ENDS)
	var by_node := {}
	for entry in faces:
		if not by_node.has(entry.node):
			by_node[entry.node] = []
		by_node[entry.node].append(entry.face)
	var group_before := _snapshot_kernel_groups(by_node.keys())
	for node in by_node:
		var is_kernel := _group_of_kernel(node) != null
		if not is_kernel:
			ur.add_undo_property(node, "face_data", node.face_data)
		for f in by_node[node]:
			if kind == "offset":
				# The field is in pixels; convert back to tile units with this face's texture size.
				node.set_face_offset(f, _px_to_tile(value, _face_texture_of(node, f)))
			else:
				var uv: Dictionary = node.get_face_uv(f)
				var scale: Vector2 = value if kind == "scale" else uv.scale
				var angle: float = value if kind == "angle" else uv.angle
				node.set_face_uv(f, uv.offset, scale, angle)
		if not is_kernel:
			ur.add_do_property(node, "face_data", node.face_data)
	_fold_kernel_writes(ur, group_before)
	ur.commit_action(false)   # already applied
	_push_uv_canvas()             # live-update the visual editor (fields don't re-sync mid-drag)


## Push the target face to the visual editor — but ONLY when exactly one face is selected; the UV
## canvas works on a single face, so it stays empty for a whole-brush or multi-face selection.
## Cheaper than a full _sync_texture_dock, so it's safe to call on every field edit.
func _push_uv_canvas() -> void:
	if not is_instance_valid(_texture_dock):
		return
	var faces := _target_faces()
	if faces.size() == 1:
		var n: Node3D = faces[0].node
		var f: int = faces[0].face
		_texture_dock.set_uv_face(_face_surface_of(n, f), n.face_local_polygon(f), n.face_uv_polygon(f))
	else:
		_texture_dock.set_uv_face(null, PackedVector2Array(), PackedVector2Array())


## Apply a UV utility button (reset / world / flip / rotate) to every target face as one undo step.
func _on_uv_action(action: String) -> void:
	var faces := _target_faces()
	if faces.is_empty():
		return
	var ur := get_undo_redo()
	ur.create_action("UV " + action)
	var by_node := {}
	for entry in faces:
		if not by_node.has(entry.node):
			by_node[entry.node] = []
		by_node[entry.node].append(entry.face)
	var group_before := _snapshot_kernel_groups(by_node.keys())
	for node in by_node:
		var is_kernel := _group_of_kernel(node) != null
		if not is_kernel:
			ur.add_undo_property(node, "face_data", node.face_data)
		for f in by_node[node]:
			match action:
				"reset": node.reset_face_uv(f)
				"world": node.world_align_face_uv(f)
				"fit": node.fit_face_uv(f)
				"flip_u": node.flip_face_u(f)
				"flip_v": node.flip_face_v(f)
				"rotate_ccw": node.rotate_face_uv(f, 90.0)
				"rotate_cw": node.rotate_face_uv(f, -90.0)
		if not is_kernel:
			ur.add_do_property(node, "face_data", node.face_data)
	_fold_kernel_writes(ur, group_before)
	ur.commit_action(false)   # already applied
	_sync_texture_dock()       # refresh the fields to the new values


## Yellow outline on the face SHIFT is hovering, red outline and tint on selected faces.
func _draw_face_selection(overlay: Control) -> void:
	for entry in _selected_faces:
		if not is_instance_valid(entry.node) or entry.face >= entry.node.planes.size():
			continue
		var poly := _face_world_polygon(entry.node, entry.face)
		if poly.size() < 3:
			continue
		var plane := _face_world_plane(entry.node, entry.face)
		_draw_polygon_fill(overlay, poly, plane.normal, Color(Palette.TB_RED, 0.30))
		for i in poly.size():
			_draw_world_line(overlay, poly[i], poly[(i + 1) % poly.size()], Color(Palette.TB_RED, 0.95), 2.0)

	# While pushing, the face is re-found by plane; hovering isn't tracked at all mid-drag.
	var outline = null
	if _push_active and not _push_nodes.is_empty():
		var node: Node3D = _push_nodes[0]
		var index := _push_face_index(node)
		if index >= 0:
			outline = _face_world_polygon(node, index)
	elif _shift_face_hover != null and not _face_is_selected(
			_shift_face_hover.node, _shift_face_hover.face):
		outline = _face_world_polygon(_shift_face_hover.node, _shift_face_hover.face)
	if outline != null:
		for i in outline.size():
			_draw_world_line(overlay, outline[i], outline[(i + 1) % outline.size()],
				Color(Palette.TB_YELLOW, 0.95), 2.0)

	# Inward CTRL+SHIFT cut: the brush stays whole and only the CUTTING FACE is outlined — the slice
	# the moving plane makes through the solid — so it reads as a pending cut. (Outward has no overlay:
	# the live, fully-textured extrude preview brush shows the new geometry for real instead.)
	if _push_active and _push_new_brush and _push_offset < 0.0:
		var cut_poly := _cut_face_polygon(_push_applied_offset)
		for i in cut_poly.size():
			_draw_world_line(overlay, cut_poly[i], cut_poly[(i + 1) % cut_poly.size()],
				Color(Palette.TB_YELLOW, 0.95), 2.0)

	# A texture drag hovering a face marks its landing spot — filled, so it reads as "this whole
	# face gets painted", unlike the outline-only shift hover which precedes a push. With SHIFT
	# held the drop paints the entire brush, so the whole brush lights up instead.
	if _drop_face_hover != null and is_instance_valid(_drop_face_hover.node) \
			and _drop_face_hover.face < _drop_face_hover.node.planes.size():
		var node: Node3D = _drop_face_hover.node
		if _drop_face_hover.get("whole", false):
			_draw_brush_wireframe(overlay, node, Palette.TB_YELLOW)
			for f in node.planes.size():
				var fp := _face_world_polygon(node, f)
				if fp.size() >= 3:
					_draw_polygon_fill(overlay, fp, _face_world_plane(node, f).normal,
						Color(Palette.TB_YELLOW, 0.18))
		else:
			var poly := _face_world_polygon(node, _drop_face_hover.face)
			if poly.size() >= 3:
				var plane := _face_world_plane(node, _drop_face_hover.face)
				_draw_polygon_fill(overlay, poly, plane.normal, Color(Palette.TB_YELLOW, 0.30))
				for i in poly.size():
					_draw_world_line(overlay, poly[i], poly[(i + 1) % poly.size()],
						Color(Palette.TB_YELLOW, 0.95), 2.0)


# --- Shared face raycast / on-face snap -----------------------------------
# Used by the clip tool (tools/clip_tool.gd), the texture drop catchers, and the brush-hull tool.

## Ray against real brush FACES, not the AABB. The clip tool needs the actual face a point lands
## on — its plane is what the point gets glued to — and an AABB would give the wrong plane for
## anything rotated or sheared.
##
## `include_groups` extends the pick to a CLOSED group's member faces, so a group can be built
## against like any other surface. It is opt-IN rather than automatic because ten call sites share
## this raycast and they do not agree: the brush and shape tools want groups, while clip and the
## vertex/edge/face tools must keep refusing them (those reshape a single member, which means
## opening the group first).
##
## A group hit is answered with that member's KERNEL, so the returned entry keeps its
## {node: Brush, face: int} shape and every caller works unchanged. The member faces are tested as
## plain data first and the kernel is materialized only for the winner — spinning one up per member
## per raycast would put a hidden node behind every member of every group, which is exactly the cost
## the single-node design exists to avoid.
func _raycast_brush_faces(from: Vector3, dir: Vector3, include_groups := false,
		ignore_isolation := false):
	var best = null
	# The in-progress shape must not block placing points behind it — which the unowned-preview
	# exclusion in _scene_brushes now covers, along with the push and clip ghosts.
	for node in _scene_brushes(false, ignore_isolation):
		if not _pickable(node):
			continue
		var to_world: Transform3D = node.global_transform
		for f in node.planes.size():
			var poly: PackedVector3Array = node.face_polygon(f)
			if poly.size() < 3:
				continue
			var world_poly := PackedVector3Array()
			for p in poly:
				world_poly.append(to_world * p)
			var normal := _polygon_normal_world(world_poly)
			var denom := normal.dot(dir)
			if denom >= 0.0:
				continue                       # back-facing; the front face wins
			var t := normal.dot(world_poly[0] - from) / denom
			if t < 0.0 or (best != null and t >= best.t):
				continue
			var point := from + dir * t
			if not _point_in_polygon(point, world_poly, normal):
				continue
			best = {"t": t, "point": point, "node": node, "face": f, "normal": normal}
	if not include_groups:
		return best

	# The loose-brush answer, kept aside. The group pass overwrites `best` the moment a member face
	# beats it, and resolving that face back to a kernel can still fail afterwards — so this is what
	# there is to fall back on. It used to return null instead, throwing away a hit the caller had
	# every right to and reading, at the call site, as "nothing under the cursor".
	var solid_best = best

	# Groups, tested against the member payload rather than against the combined mesh. The mesh
	# holds CULLED FRAGMENTS, so it is the wrong thing to pick against — a whole member face is
	# what a tool wants to glue to, and a buried one is never the nearest hit anyway.
	var winner := {}
	for group in _scene_groups():
		if not _pickable(group):
			continue
		var gb := _brush_world_aabb(group)
		# Counting an origin INSIDE the box as a hit, unlike the coarse pick. This is only a gate —
		# every face behind it is still tested exactly — so widening it can add correct picks and
		# cannot invent wrong ones. Without it, a group you can stand inside was unpickable from
		# where you actually work: walk into a room built as one, or under a level-spanning ground
		# plane, and neither click-select nor SHIFT+click on a face could reach it at all, because
		# the ray had no entry face ahead of it to measure.
		if gb.size == Vector3.ZERO or _ray_aabb(from, dir, gb.position, gb.end, true) == null:
			continue
		var solids: Array = group.world_members()
		for mi in solids.size():
			for f in solids[mi]:
				var world_poly: PackedVector3Array = f["points"]
				if world_poly.size() < 3:
					continue
				var normal := _polygon_normal_world(world_poly)
				var denom := normal.dot(dir)
				if denom >= 0.0:
					continue
				var t := normal.dot(world_poly[0] - from) / denom
				if t < 0.0 or (best != null and t >= best.t):
					continue
				var point := from + dir * t
				if not _point_in_polygon(point, world_poly, normal):
					continue
				best = {"t": t, "point": point, "node": null, "face": -1, "normal": normal}
				winner = {"group": group, "member": mi, "plane": f["plane"]}
	if winner.is_empty():
		return best

	# The winning member becomes a kernel, and its face index is recovered by MATCHING PLANES rather
	# than by trusting the payload's ordering: set_world_faces runs the plane setter, which is free
	# to prune and reorder, so a positional index would silently name a different face.
	var kernel: Brush = winner.group.kernel_for(winner.member)
	if kernel == null:
		return solid_best
	var face_index := _plane_index_of(kernel, winner.plane)
	if face_index < 0:
		return solid_best
	best["node"] = kernel
	best["face"] = face_index
	return best


## Index of the plane in `brush` matching `plane`, or -1. Uses Brush's own merge thresholds so
## "the same face" means here exactly what it means there.
func _plane_index_of(brush, plane: Plane) -> int:
	for i in brush.planes.size():
		var p: Plane = brush.planes[i]
		if p.normal.dot(plane.normal) > Brush.PLANE_MERGE_DOT \
				and absf(p.d - plane.d) < Brush.PLANE_MERGE_DIST:
			return i
	return -1


func _polygon_normal_world(poly: PackedVector3Array) -> Vector3:
	# Newell's method: robust for any planar polygon, unlike picking three arbitrary vertices
	# which degenerates when they happen to be near-collinear.
	var n := Vector3.ZERO
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		n += Vector3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x),
			(a.x - b.x) * (a.y + b.y))
	return n.normalized()


func _point_in_polygon(point: Vector3, poly: PackedVector3Array, normal: Vector3) -> bool:
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		if (b - a).cross(point - a).dot(normal) < -1e-5:
			return false
	return true


## Snap a point to the grid AS PROJECTED ONTO its face, rather than in all three axes.
##
## Snapping all three would push the point off the face — into it or out of it — so instead the
## two axes across the face are snapped and the third is solved from the plane equation. The
## point therefore stays exactly on the face while landing on the face's own grid, which is what
## keeps a clip plane passing through real grid positions.
func _snap_on_face(point: Vector3, normal: Vector3, origin: Vector3, g: float) -> Vector3:
	var a := normal.abs()
	var axis := 0 if (a.x >= a.y and a.x >= a.z) else (1 if a.y >= a.z else 2)
	if absf(normal[axis]) < 1e-6:
		return point
	var out := point
	var d := normal.dot(origin)
	var total := 0.0
	for i in 3:
		if i == axis:
			continue
		out[i] = snappedf(point[i], g)
		total += normal[i] * out[i]
	out[axis] = (d - total) / normal[axis]
	return out


## Fill one world-space polygon on the overlay. FRONT-FACING ONLY: the ghost is a convex solid,
## so drawing its back faces too would double the alpha everywhere and read as a solid block
## rather than a translucent one.
## Returns whether it actually drew, so the caller can match an outline to the same faces.
func _draw_polygon_fill(overlay: Control, poly: PackedVector3Array, normal: Vector3,
		col: Color) -> bool:
	if poly.size() < 3:
		return false
	# The normal is passed in, not re-derived from the winding: a wrong guess doesn't cull the
	# far faces, it culls NOTHING, and the overlapping fills compose to something opaque.
	if normal.dot(poly[0] - _draw_camera.global_position) >= 0.0:
		return false
	var screen := PackedVector2Array()
	for p in poly:
		if _draw_camera.is_position_behind(p):
			return false    # partly behind the camera; the projection would be nonsense
		screen.append(_draw_camera.unproject_position(p))
	overlay.draw_colored_polygon(screen, col)
	return true


# --- Shared overlay draw helpers -----------------------------------------

func _draw_quad_fill(overlay: Control, quad: Array, col: Color) -> void:
	var screen := PackedVector2Array()
	for p in quad:
		if _draw_camera.is_position_behind(p):
			return
		screen.append(_draw_camera.unproject_position(p))
	overlay.draw_colored_polygon(screen, Color(col, 0.25))
	for i in quad.size():
		_draw_world_line(overlay, quad[i], quad[(i + 1) % quad.size()], Color(col, 0.95), 2.0)


## Draw a world-space segment, CLIPPED to the near plane rather than dropped when it crosses it.
##
## unproject_position() is meaningless behind the camera, so a segment with one endpoint back
## there can't be projected as-is — but discarding the whole line makes long guides blink out
## the moment either end passes you, which is exactly when you're closest and most want them.
## Clipping keeps the visible part.
func _draw_world_line(overlay: Control, a: Vector3, b: Vector3, col: Color, width: float) -> void:
	var view := _draw_camera.global_transform
	var to_view := view.affine_inverse()
	var pa: Vector3 = to_view * a
	var pb: Vector3 = to_view * b
	# Camera looks down -Z in view space, so depth is -z. Sit just in front of the near plane;
	# exactly on it still projects unreliably.
	var near := _draw_camera.near + 0.001
	var da := -pa.z - near
	var db := -pb.z - near
	if da < 0.0 and db < 0.0:
		return                       # entirely behind
	if da < 0.0:
		pa = pa.lerp(pb, da / (da - db))
	elif db < 0.0:
		pb = pb.lerp(pa, db / (db - da))
	overlay.draw_line(_draw_camera.unproject_position(view * pa),
		_draw_camera.unproject_position(view * pb), col, width, true)


## Screen-space nudge applied to every dimension label. draw_string() anchors on the text
## BASELINE, and the pill is centred on the projected 3D point — this is the taste knob for
## how the label sits relative to its edge. Positive Y moves labels down.
const LABEL_SCREEN_NUDGE := Vector2(0.0, 2.0)

## Pills attached to GEOMETRY — dimensions, axis distances, handle positions, rotation angle.
## Smaller than the status line, which is a sentence you read rather than a number you glance at.
const LABEL_FONT_SIZE := 12
## Status line at the top of the viewport.
const STATUS_FONT_SIZE := 14
## Y of the top edge of the shared status/hint pill (top-centre of the viewport).
const STATUS_TOP := 10.0
## Baseline shift INSIDE the pill. Centring on ascent+descent is only correct for text that
## actually uses both: everything we draw is digits and capitals, whose ink stops well short of
## the descender, so the metrics-correct baseline leaves them sitting visibly high.
const LABEL_TEXT_NUDGE := 1.0

## [param fill] overrides the pill's colour — the handle readout uses red, which is what marks it
## as "this exact spot" rather than a measurement.
## The one status/hint panel every tool and the texture drop share: a roomy dark pill pinned
## top-centre of the viewport, one line per entry (the first bright, the rest dimmed as secondary
## hints). Reuses the tool labels' pill style at the status font size.
func _draw_status_hint(overlay: Control, lines: Array) -> void:
	if lines.is_empty():
		return
	var font := overlay.get_theme_default_font()
	var font_size := LABEL_FONT_SIZE
	var line_h := font.get_ascent(font_size) + font.get_descent(font_size)
	var gap := 4.0
	var pad := Vector2(12, 8)
	var content_w := 0.0
	for line in lines:
		content_w = maxf(content_w, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	var content := Vector2(content_w, line_h * lines.size() + gap * (lines.size() - 1))
	var box := Rect2(Vector2.ZERO, content + pad * 2.0)
	box.position = Vector2((overlay.size.x - box.size.x) * 0.5, STATUS_TOP)
	overlay.draw_style_box(_label_style, box)

	var y := box.position.y + pad.y + font.get_ascent(font_size)
	var first := true
	for line in lines:
		var lw := font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var x := box.position.x + (box.size.x - lw) * 0.5
		var col := Color(0.92, 0.92, 0.94) if first else Color(0.72, 0.72, 0.76)
		overlay.draw_string(font, Vector2(x, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)
		y += line_h + gap
		first = false


func _draw_dim_label(overlay: Control, font: Font, font_size: int, at: Vector2, text: String,
		fill := Color.TRANSPARENT) -> void:
	# Size the pill from real font metrics so the text is genuinely centred inside it.
	var ascent := font.get_ascent(font_size)
	var descent := font.get_descent(font_size)
	var text_size := Vector2(font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x, ascent + descent)
	var center := at + LABEL_SCREEN_NUDGE
	var pad := Vector2(6, 3)

	var box := Rect2(center - text_size * 0.5 - pad, text_size + pad * 2.0)
	if fill.a > 0.0:
		var tinted := _label_style.duplicate() as StyleBoxFlat
		tinted.bg_color = fill
		overlay.draw_style_box(tinted, box)
	else:
		overlay.draw_style_box(_label_style, box)
	var baseline := Vector2(center.x - text_size.x * 0.5,
		center.y - text_size.y * 0.5 + ascent + LABEL_TEXT_NUDGE)
	overlay.draw_string(font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.92, 0.92, 0.94))


# --- Commit ---------------------------------------------------------------

## Delete the selected brushes immediately — no confirmation dialog — but still undoable.
## Only fires when EVERY selected node is one of our brushes; anything else falls through to
## Godot's normal (confirmed) delete. Returns true if we handled it.
func _delete_selected_brushes() -> bool:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return false
	var nodes := EditorInterface.get_selection().get_selected_nodes()
	if nodes.is_empty():
		return false
	for n in nodes:
		if not (n is Brush or n is BrushGroup):
			return false

	# Deleting a MEMBER of an open group has to remove it from `members`. The node is only its
	# stand-in, so freeing that alone left the member in place and it came back on close.
	if _open_group != null and is_instance_valid(_open_group):
		var doomed: Array[int] = []
		for n in nodes:
			var index: int = _open_group.kernel_index(n)
			if index >= 0:
				doomed.append(index)
		if not doomed.is_empty() and doomed.size() == nodes.size():
			doomed.sort()
			doomed.reverse()      # drop from the back so the earlier indices stay valid
			var after: Array = _open_group.members.duplicate(true)
			for index in doomed:
				after.remove_at(index)
			var member_ur := get_undo_redo()
			member_ur.create_action("Delete Brush")
			member_ur.add_do_property(_open_group, "members", after)
			member_ur.add_undo_property(
				_open_group, "members", _open_group.members.duplicate(true))
			member_ur.commit_action()
			# Member indices shifted, so rebuild the stand-ins rather than re-seeding stale ones.
			_open_group.release_kernels()
			_open_group.set_kernels_visible(true)
			EditorInterface.get_selection().clear()
			update_overlays()
			return true

	var ur := get_undo_redo()
	ur.create_action("Delete Brush")
	for n in nodes:
		var parent := n.get_parent()
		if parent == null:
			continue
		ur.add_do_method(parent, "remove_child", n)
		# Undo: put it back where it was, then re-own it so it saves with the scene.
		ur.add_undo_method(parent, "add_child", n)
		ur.add_undo_method(parent, "move_child", n, n.get_index())
		ur.add_undo_method(n, "set_owner", root)
		ur.add_undo_reference(n)   # keeps the node alive while it's out of the tree
	# Cleared BEFORE the commit for the same reason as the group and CSG paths: the inspector's
	# MultiNodeEdit holds NODE PATHS to the selection and re-resolves them, so deleting first leaves
	# it chasing nodes that are gone.
	EditorInterface.get_selection().clear()
	ur.commit_action()
	return true


## Turn the drawn box into the shape the toolbar has selected. Cuboid keeps the original single-box
## path; every other shape goes through the geometry builder, which may return SEVERAL convex point
## sets (a box per stair step, a wall per hollow-cylinder side). Each becomes a Brush built with
## set_from_points — the same construction the hull tool uses — and the whole lot commits as ONE
## "Draw <Shape>" undo step, then is selected together.
func _commit_shape(a: Vector3, b: Vector3, camera: Camera3D) -> void:
	var shape := "cuboid"
	var params := {}
	if is_instance_valid(_shape_bar):
		shape = _shape_bar.get_shape()
		params = _shape_bar.get_params()
	if shape == "cuboid":
		_commit_brush(a, b, camera)   # unchanged fast path: one axis-aligned box
		return

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var box := _box_from(a, b, camera.global_position)
	var point_sets: Array = ShapeBuilder.build(shape, box.center, box.size, params, grid_size)
	var parent := _brush_parent()
	var g := grid_size
	# Build every brush first (each needs a valid hull), then commit them together. A point set that
	# collapses — a zero-thickness step, a degenerate ring — is dropped rather than spawning a
	# broken brush; its orphan node is freed since it never entered the tree.
	var built: Array = []
	for pts in point_sets:
		if pts.size() < 4:
			continue
		var bounds := AABB(pts[0], Vector3.ZERO)
		for p in pts:
			bounds = bounds.expand(p)
		var centre := bounds.get_center()
		centre = Vector3(snappedf(centre.x, g), snappedf(centre.y, g), snappedf(centre.z, g))
		var brush := Brush.new()
		brush.grid_size = grid_size
		brush.texture_lock = texture_lock
		brush.uv_lock = uv_lock
		brush.name = "Brush"
		brush.position = centre
		var local := PackedVector3Array()
		for p in pts:
			local.append(p - centre)
		# snap = false: the builder already placed every vertex deliberately (on the ellipse, at the
		# stair risers). Re-snapping here would pull round shapes onto the grid and distort them —
		# the "scalable" circle mode is the one that snaps, and it does so inside the builder.
		brush.set_from_points(local, false)
		if brush.planes.size() < 4:
			brush.free()
			continue
		_apply_active_surface(brush)
		built.append({"brush": brush, "centre": centre})
	if built.is_empty():
		return

	var ur := get_undo_redo()
	ur.create_action("Draw %s" % shape.capitalize())
	for entry in built:
		ur.add_do_method(parent, "add_child", entry.brush, true)
		ur.add_do_property(entry.brush, "global_position", entry.centre)
		ur.add_do_method(entry.brush, "set_owner", root)
		ur.add_do_reference(entry.brush)
		ur.add_undo_method(parent, "remove_child", entry.brush)
	ur.commit_action()

	var made: Array = []
	for entry in built:
		made.append(entry.brush)
	_select_nodes(made)
	update_overlays()


func _commit_brush(a: Vector3, b: Vector3, camera: Camera3D) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var parent := _brush_parent()
	var box := _box_from(a, b, camera.global_position)
	var brush := Brush.new()
	brush.grid_size = grid_size
	brush.texture_lock = texture_lock
	brush.uv_lock = uv_lock
	brush.set_box(box.size)   # the brush's entire geometry: planes empty until this runs
	brush.name = "Brush"
	_apply_active_surface(brush)

	var ur := get_undo_redo()
	ur.create_action("Draw Brush")
	# force_readable_name: without it a name COLLISION resolves to "@Brush@28359" instead of
	# "Brush2". The name set above is only honoured while it's unique, so a collision needs the flag.
	ur.add_do_method(parent, "add_child", brush, true)
	ur.add_do_method(brush, "set_owner", root)
	ur.add_do_reference(brush)
	# The box was computed in WORLD space, so the position is set after parenting — a parent with
	# its own transform would otherwise place the brush somewhere else entirely.
	ur.add_do_property(brush, "global_position", box.center)
	ur.add_undo_method(parent, "remove_child", brush)
	ur.commit_action()

	_select_only(brush)


func _reset_draw() -> void:
	if is_instance_valid(_preview):
		_preview.queue_free()   # frees the box mesh and any shape ghosts parented under it
	_preview = null
	_preview_box = null
	_preview_brushes = []
	_preview_shape_key = ""
	_drawing = false
	_armed = false
	_group_close_pending = false
	_group_click_member = null
	_start = null
	_current = null
	_hit_point = null
	_alt = false
	_square = false
	_box_size = Vector3.ZERO
	# _draw_camera is deliberately NOT cleared here. It is the overlay's camera reference, used
	# by every tool's drawing — not part of this gesture's state. Clearing it blanked the whole
	# overlay (wireframes, handles, everything) on any click that ended up here, until the next
	# mouse motion set it again.
	update_overlays()   # clear the dimension labels
