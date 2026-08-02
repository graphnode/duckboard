@tool
extends Control
## Vertical tool palette pinned to the left edge of the 3D viewport, mirroring
## TrenchBroom's tool bar.
##
## The palette lives in the 3D editor's left HSplitContainer, so the user can drag
## it wider. It responds to that width in three stages (the same progression as
## Blender's tool shelf), so the icons can be learned without hovering for tooltips:
##
##   narrow  -> one column of icons
##   wider   -> two columns of icons
##   widest  -> one column of icon + label
##
## The root is a plain Control rather than the VBoxContainer it looks like. A
## Container reports its children's combined minimum size, so once the palette grew
## to two columns the split refused to drag back below two buttons wide and the
## narrow stage became unreachable. A plain Control ignores its children's minimums,
## which keeps every stage reversible.
##
## The buttons carry no behaviour of their own — they only track their own pressed
## state and announce it via [signal tool_changed] / [signal option_toggled]; the
## plugin hangs the actual tool behaviour off those signals.

## The rebindable key map. Read live for every tooltip and every key test, so the palette never holds
## its own idea of what a shortcut is.
const Shortcuts := preload("res://addons/duckboard/shortcuts.gd")

const ICON_PATH := "res://addons/duckboard/icons/%s.svg"

## TrenchBroom's icons are drawn at 24 px; anything larger just resamples.
const ICON_SIZE := 24

## Breathing room around each icon, giving a square click target.
const BUTTON_PADDING := 10

## Gap between an icon and its label, plus trailing padding, in label mode.
const LABEL_PADDING := 16

## Breathing room between the palette's edges and the buttons. Matters now that the buttons
## paint a real background — without it they sit flush against the viewport edge.
const PALETTE_MARGIN := 3

## Emitted when the active tool changes. [param tool_id] is "" when the palette
## falls back to no tool (clicking the active tool again unpresses it, matching
## TrenchBroom returning to plain selection).
signal tool_changed(tool_id: String)

## Emitted when one of the non-exclusive buttons changes state.
signal option_toggled(option_id: String, pressed: bool)

## Emitted when a one-shot operation button is clicked. Separate from [signal option_toggled]
## because actions fire and are done — they hold no state to report.
signal action_triggered(action_id: String)

## Mutually exclusive tool modes — only one can be active at a time. The keyboard shortcut for each
## is NOT here: an id matching an entry in [code]Shortcuts.BINDINGS[/code] is bound, and what it is
## bound to is whatever the user has it set to (see [method try_shortcut] and [method _tooltip]).
const TOOLS := [
	# No button for the Simple Shape tool, matching TrenchBroom: it is never switched on, it is what
	# a drag means when no tool owns the viewport (see `_shape_gesture_live` in the plugin).
	{"id": "brush",  "icon": "BrushTool",  "tip": "Brush Tool (hull from points)"},
	{"id": "clip",   "icon": "ClipTool",   "tip": "Clip Tool"},
	{"id": "vertex", "icon": "VertexTool", "tip": "Vertex Tool"},
	{"id": "edge",   "icon": "EdgeTool",   "tip": "Edge Tool"},
	{"id": "face",   "icon": "FaceTool",   "tip": "Face Tool"},
	{"id": "rotate", "icon": "RotateTool", "tip": "Rotate Tool"},
	{"id": "scale",  "icon": "ScaleTool",  "tip": "Scale Tool"},
	{"id": "shear",  "icon": "ShearTool",  "tip": "Shear Tool"},
]

## Object operations. These act on the current selection rather than entering a mode.
const ACTIONS := [
	{"id": "duplicate", "icon": "DuplicateObjects", "tip": "Duplicate"},
	{"id": "flip_h",    "icon": "FlipHorizontally", "tip": "Flip Horizontally"},
	{"id": "flip_v",    "icon": "FlipVertically",   "tip": "Flip Vertically"},
]

## Sticky options. TrenchBroom ships a separate _off/_on icon for each of these,
## so the button swaps its icon instead of relying on the pressed style alone.
## "Texture lock" matches TrenchBroom's alignment lock (no default shortcut); "UV Lock" is bound to U.
const OPTIONS := [
	{"id": "texture_lock", "icon": "AlignmentLock", "tip": "Texture Lock"},
	{"id": "uv_lock",      "icon": "UVLock",        "tip": "UV Lock"},
]

var _tool_group: ButtonGroup
var _csg_button: MenuButton  # foot-of-palette CSG dropdown; the plugin fills its popup
var _group_button: MenuButton  # foot-of-palette Group dropdown; the plugin fills its popup
var _physics_button: MenuButton  # foot-of-palette Physics dropdown; the plugin fills its popup
var _box: VBoxContainer  # holds the groups; the root Control just supplies the width
# Shared state styles: `flat` buttons draw almost nothing when pressed, so the active tool
# gets the accent-tinted background the editor's own toggles use.
var _style_pressed: StyleBoxFlat
var _style_hover: StyleBoxFlat
var _style_hover_pressed: StyleBoxFlat
var _style_empty: StyleBoxEmpty
var _icon_px: int        # icon edge length, editor-scale aware
var _button_px: int      # square button edge length
var _margin_px: int      # inset between the palette edge and the buttons
var _label_pad_px: int   # horizontal padding inside a button, label mode only
var _label_px: int       # width the palette needs before labels fit
var _grids: Array[GridContainer] = []
var _buttons: Array[Button] = []
var _columns := 0        # 0 == "not laid out yet", so the first pass always applies
var _labelled := false


func _init() -> void:
	var scale := EditorInterface.get_editor_scale()
	_icon_px = int(round(ICON_SIZE * scale))
	_button_px = int(round((ICON_SIZE + BUTTON_PADDING) * scale))
	_margin_px = int(round(PALETTE_MARGIN * scale))
	_label_pad_px = int(round(8 * scale))

	# SIZE_FILL is what makes the split hand us its full width — without it a split
	# child is pinned to its minimum size and dragging appears to do nothing.
	# The minimum includes the margins, so the narrowest stage still fits a full square button.
	custom_minimum_size = Vector2(_button_px + _margin_px * 2, 0)
	size_flags_horizontal = Control.SIZE_FILL
	size_flags_vertical = Control.SIZE_FILL
	clip_contents = true

	_build_state_styles(scale)

	_box = VBoxContainer.new()
	_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	_box.offset_left = _margin_px
	_box.offset_top = _margin_px
	_box.offset_right = -_margin_px
	_box.offset_bottom = -_margin_px
	_box.add_theme_constant_override("separation", int(round(2 * scale)))
	add_child(_box)

	_tool_group = ButtonGroup.new()
	# Let the active tool be clicked off, rather than forcing one to always be held down.
	_tool_group.allow_unpress = true
	_tool_group.pressed.connect(_on_tool_pressed)

	_add_group(TOOLS, _tool_group)
	_box.add_child(HSeparator.new())
	_add_group(ACTIONS, null, false, true)
	_box.add_child(HSeparator.new())
	_add_group(OPTIONS, null, true)
	_box.add_child(HSeparator.new())
	_build_csg_button()
	_build_group_button()
	_build_physics_button()


## Backgrounds for the hover / pressed states, tinted with the editor's accent colour so the
## active tool reads at a glance instead of relying on the icon tint alone.
##
## Note we do NOT use `Button.flat` for the clean idle look: flat skips the stylebox draw in
## EVERY state, not just normal, so a flat button can never show a pressed background. Instead
## the normal (and disabled) states get an empty stylebox and the rest are styled.
func _build_state_styles(scale: float) -> void:
	var radius := int(round(3 * scale))

	# The background alone carries the active state. We deliberately don't tint the icon:
	# TrenchBroom's icons are already coloured, so an accent tint makes them illegible.
	_style_pressed = StyleBoxFlat.new()
	_style_pressed.bg_color = Color(1, 1, 1, 0.16)
	_style_pressed.set_corner_radius_all(radius)

	_style_hover_pressed = StyleBoxFlat.new()
	_style_hover_pressed.bg_color = Color(1, 1, 1, 0.22)
	_style_hover_pressed.set_corner_radius_all(radius)

	# Neutral for plain hover, so hovering never looks like the tool is already active.
	_style_hover = StyleBoxFlat.new()
	_style_hover.bg_color = Color(1, 1, 1, 0.09)
	_style_hover.set_corner_radius_all(radius)

	_style_empty = StyleBoxEmpty.new()   # idle + disabled draw nothing


func _ready() -> void:
	# Labels only fit once the widest one does, so measure against the real theme font.
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	var widest := 0.0
	for button in _buttons:
		widest = maxf(widest, font.get_string_size(
			button.get_meta("label"), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	_label_px = _button_px + int(ceil(widest)) \
		+ int(round(LABEL_PADDING * EditorInterface.get_editor_scale()))
	# Measured against the inner width, so the palette margins don't make labels wrap early.
	# The in-button padding is deliberately NOT added on top — LABEL_PADDING already covers
	# the icon-to-text gap and trailing room, and counting both delayed the label stage.
	_label_px += _margin_px * 2

	resized.connect(_relayout)
	_relayout()


## Each group is its own grid so the separators between them stay full-width — an
## HSeparator placed directly in a GridContainer would only occupy a single cell.
## [param sticky] marks options that swap between an _off and _on icon.
## [param actions] marks one-shot operations, which are plain buttons rather than toggles.
func _add_group(specs: Array, group: ButtonGroup = null, sticky := false,
		actions := false) -> void:
	var grid := GridContainer.new()
	grid.columns = 1
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for spec in specs:
		var button := _make_button(spec, group, sticky, actions)
		if group != null:
			pass                                  # exclusive tools report via the ButtonGroup
		elif actions:
			button.pressed.connect(_on_action_pressed.bind(spec.id))
		elif sticky:
			button.toggled.connect(_on_lock_toggled.bind(button, spec))
		else:
			button.toggled.connect(_on_option_toggled.bind(spec.id))
		grid.add_child(button)
		_buttons.append(button)
	_box.add_child(grid)
	_grids.append(grid)


## Builds one flat toggle button, icon-only until the palette is wide enough for text.
func _make_button(spec: Dictionary, group: ButtonGroup, sticky: bool, action := false) -> Button:
	var button := Button.new()
	# Actions run and are done, so they must NOT latch — a toggle would leave "Duplicate"
	# stuck looking active after one click.
	button.toggle_mode = not action
	button.tooltip_text = _tooltip(spec)
	button.button_group = group
	button.set_meta("id", spec.id)
	button.set_meta("label", spec.tip)
	# Sticky options start in their _off state and swap icons as they flip.
	button.icon = _load_icon("%s_off" % spec.icon if sticky else spec.icon)
	_apply_button_style(button)
	return button


## Shared visual dressing for every palette button — the tools, the actions, and the CSG menu
## button all wear the same square icon, accent hover/pressed backgrounds, and an untinted icon so
## TrenchBroom's own colours survive. Behaviour (toggle vs one-shot vs menu) is left to the caller.
func _apply_button_style(button: Button) -> void:
	button.focus_mode = Control.FOCUS_NONE
	# `icon_alignment` is separate from `alignment` (which only positions text). It defaults to
	# LEFT; the theme's normal-state padding used to hide that, but our empty style has none.
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# expand_icon would rescale the icon to whatever width the side dock happens to
	# hand us — which starts near zero — so the icons visibly shrank. Keep it off and
	# let the icon dictate the button size instead of the other way round.
	button.expand_icon = false
	button.custom_minimum_size = Vector2(_button_px, _button_px)
	button.add_theme_constant_override("icon_max_width", _icon_px)
	button.clip_text = true
	# The editor theme tints pressed/hovered icons with the accent colour by default, which
	# muddies TrenchBroom's already-coloured icons. White multiplies by 1, i.e. no tint.
	# `disabled` is left alone so greyed-out buttons still look greyed out.
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color",
			"icon_hover_pressed_color", "icon_focus_color"]:
		button.add_theme_color_override(state, Color.WHITE)
	button.add_theme_stylebox_override("normal", _style_empty)
	button.add_theme_stylebox_override("disabled", _style_empty)
	button.add_theme_stylebox_override("pressed", _style_pressed)
	button.add_theme_stylebox_override("hover_pressed", _style_hover_pressed)
	button.add_theme_stylebox_override("hover", _style_hover)


## The CSG dropdown sits at the palette's foot, below its own separator. Unlike the tools and
## actions it opens a menu instead of reporting a click, so the plugin owns the popup's items and
## their enable state (see brush_plugin `_build_csg_menu`); the palette only styles the button,
## keeps it in the responsive flow, and pops the menu out to the side so it clears the viewport
## edge instead of dropping down under it. Its own grid keeps the separator above it full-width,
## matching the other groups.
func _build_csg_button() -> void:
	_csg_button = MenuButton.new()
	_csg_button.tooltip_text = "Constructive solid geometry on the selected brushes."
	_csg_button.icon = _load_icon("CSG")
	# Kept out of the selection-driven greying (see ALWAYS_ENABLED): the button always opens, and
	# the popup greys the individual ops the current selection can't run.
	_csg_button.set_meta("id", "csg")
	_csg_button.set_meta("label", "CSG")
	_apply_button_style(_csg_button)
	_csg_button.get_popup().about_to_popup.connect(_on_csg_about_to_popup)
	var grid := GridContainer.new()
	grid.columns = 1
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(_csg_button)
	_box.add_child(grid)
	_grids.append(grid)
	_buttons.append(_csg_button)


## The plugin populates and wires this popup; exposing it keeps all CSG behaviour in one place
## (brush_plugin) while the widget lives with its siblings here.
func get_csg_popup() -> PopupMenu:
	return _csg_button.get_popup()


## Grey the whole CSG button when the selection can run no op at all. Driven from the plugin (see
## brush_plugin `_update_csg_menu`) rather than set_selection_state because "can run a CSG op" counts
## brushes, not just any selected node — hence "csg" sits in ALWAYS_ENABLED so the two don't fight.
func set_csg_enabled(enabled: bool) -> void:
	if is_instance_valid(_csg_button):
		_csg_button.disabled = not enabled


## Pinned to the left edge, a downward popup would spill off the viewport, so open it to the
## button's right instead. The default position is set before `about_to_popup` fires, so
## overriding it here wins.
func _on_csg_about_to_popup() -> void:
	var popup := _csg_button.get_popup()
	popup.position = Vector2i(_csg_button.get_screen_position()) \
		+ Vector2i(int(_csg_button.size.x), 0)


## Group / Ungroup, sitting beside the CSG dropdown because they are the other pair of ops that act
## on a whole selection rather than being a viewport gesture. Same division of labour: the plugin
## fills and wires the popup (see group_ops.gd), the palette only styles the button and keeps it in
## the responsive flow.
func _build_group_button() -> void:
	_group_button = MenuButton.new()
	# The chords live in the tooltip rather than as popup accelerators on purpose: a PopupMenu
	# accelerator fires whenever the editor window is focused, hidden menu or not, so it would keep
	# grouping brushes with the map-editing mode switched OFF — and collide with Godot's own Ctrl+G
	# while it was at it. The plugin claims both chords in the viewport instead (see duckboard.gd).
	_group_button.tooltip_text = "Combine the selected brushes into one group, or break one open." \
		+ "  (Ctrl+G / Shift+Ctrl+G)"
	_group_button.icon = _load_icon("GroupObjects")
	# Kept out of the selection-driven greying (see ALWAYS_ENABLED): group_ops greys the button
	# itself, because "can group" counts brushes and groups, not just any selected node.
	_group_button.set_meta("id", "group")
	_group_button.set_meta("label", "Group")
	_apply_button_style(_group_button)
	_group_button.get_popup().about_to_popup.connect(_on_group_about_to_popup)
	var grid := GridContainer.new()
	grid.columns = 1
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(_group_button)
	_box.add_child(grid)
	_grids.append(grid)
	_buttons.append(_group_button)


func get_group_popup() -> PopupMenu:
	return _group_button.get_popup()


func set_group_enabled(enabled: bool) -> void:
	if is_instance_valid(_group_button):
		_group_button.disabled = not enabled


## Physics, sitting with the CSG and Group dropdowns because it is the third op that acts on a whole
## selection rather than being a viewport gesture. Same division of labour: the plugin fills and wires
## the popup (see physics_ops.gd), the palette only styles the button and keeps it in the responsive
## flow.
func _build_physics_button() -> void:
	_physics_button = MenuButton.new()
	_physics_button.tooltip_text = \
		"Put the selected solids in a physics body, with a collision shape each."
	_physics_button.icon = _load_icon("Physics")
	# Kept out of the selection-driven greying (see ALWAYS_ENABLED): physics_ops greys the button
	# itself, because what it can offer depends on which bodies the selection is already in.
	_physics_button.set_meta("id", "physics")
	_physics_button.set_meta("label", "Physics")
	_apply_button_style(_physics_button)
	_physics_button.get_popup().about_to_popup.connect(_on_physics_about_to_popup)
	var grid := GridContainer.new()
	grid.columns = 1
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(_physics_button)
	_box.add_child(grid)
	_grids.append(grid)
	_buttons.append(_physics_button)


func get_physics_popup() -> PopupMenu:
	return _physics_button.get_popup()


func set_physics_enabled(enabled: bool) -> void:
	if is_instance_valid(_physics_button):
		_physics_button.disabled = not enabled


func _on_physics_about_to_popup() -> void:
	var popup := _physics_button.get_popup()
	popup.position = Vector2i(_physics_button.get_screen_position()) \
		+ Vector2i(int(_physics_button.size.x), 0)


func _on_group_about_to_popup() -> void:
	var popup := _group_button.get_popup()
	popup.position = Vector2i(_group_button.get_screen_position()) \
		+ Vector2i(int(_group_button.size.x), 0)


func _load_icon(icon_name: String) -> Texture2D:
	return load(ICON_PATH % icon_name) as Texture2D


# --- Keyboard shortcuts ---------------------------------------------------
## The palette owns the key bindings because it already owns the buttons and their enabled state:
## a shortcut should do exactly what clicking its button does, including being ignored while the
## button is greyed. The plugin forwards viewport key events here (it can't see the buttons) and
## consumes whatever we claim, so the editor's own single-key shortcuts (R = rotate, F = focus,
## E/T = transform modes) can't fire underneath us while the map editor is on.

## Builds the tooltip: the plain tip, plus the CURRENT binding in parentheses. Read live rather than
## baked in at build time, so a shortcut the user rebinds is described correctly the next time the
## palette is built — a tooltip still promising "R" after they moved it is worse than none.
func _tooltip(spec: Dictionary) -> String:
	var chord := Shortcuts.as_text(spec.id)
	return "%s  (%s)" % [spec.tip, chord] if not chord.is_empty() else spec.tip


func _button_by_id(id: String) -> Button:
	for button in _buttons:
		if button.get_meta("id", "") == id:
			return button
	return null


## Called by the plugin for each viewport key press. Returns true when [param key] is one of our
## shortcuts, so the caller consumes it — even if the matched button is disabled, so these keys
## belong to Duckboard wholesale while it's active and the editor never rotates/focuses underneath.
## The bound action only runs when the button is actually enabled (see [method activate_shortcut]).
func try_shortcut(key: InputEventKey) -> bool:
	for spec in TOOLS + ACTIONS + OPTIONS:
		if Shortcuts.matches(spec.id, key):
			activate_shortcut(spec.id)
			return true
	return false


## Runs the shortcut for [param id] as if its button were clicked. A disabled button (nothing to
## act on) or a hidden palette does nothing, exactly as a click would. Tools toggle within their
## group (re-pressing the active tool clears it); sticky options flip and swap icon via their own
## `toggled` handler; one-shot actions just fire. Returns whether anything ran.
func activate_shortcut(id: String) -> bool:
	var button := _button_by_id(id)
	if button == null or button.disabled or not visible:
		return false
	if button.button_group != null:                    # exclusive tool
		if button.button_pressed:
			# Re-pressing the active tool clears it. Setting pressed=false emits no group signal
			# (only presses do), so announce the drop ourselves, matching clear_tool().
			button.set_pressed_no_signal(false)
			tool_changed.emit("")
		else:
			# Setting pressed=true unpresses the group's other buttons and emits the group's
			# `pressed`, which routes through _on_tool_pressed just like a real click.
			button.button_pressed = true
	elif button.toggle_mode:                            # sticky option (texture/uv lock)
		button.button_pressed = not button.button_pressed
	else:                                               # one-shot action (duplicate / flip)
		button.pressed.emit()
	return true


# --- Responsive layout ----------------------------------------------------

## Picks a stage from the current width. Only touches the buttons when the stage
## actually changes, so this stays cheap and can't feed back into `resized`.
func _relayout() -> void:
	var w := size.x
	var labelled := w >= _label_px
	var columns := 1
	if not labelled and w - _margin_px * 2 >= _button_px * 2:
		columns = 2
	if columns == _columns and labelled == _labelled:
		return
	_columns = columns
	_labelled = labelled

	# The styleboxes are shared and every button changes stage together, so retuning their
	# content margins here indents the icon in label mode. Icon-only stages keep zero padding,
	# otherwise the icon couldn't stay centred in a square button. All states get the SAME
	# margins, or the contents would shift as you hover.
	var pad := _label_pad_px if labelled else 0
	for style in [_style_empty, _style_pressed, _style_hover, _style_hover_pressed]:
		style.content_margin_left = pad
		style.content_margin_right = pad

	for grid in _grids:
		grid.columns = columns
	for button in _buttons:
		button.text = button.get_meta("label") if labelled else ""
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT if labelled else HORIZONTAL_ALIGNMENT_CENTER
		# Icon hugs the text in label mode, centres in the square icon-only stages.
		button.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT if labelled else HORIZONTAL_ALIGNMENT_CENTER
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL if labelled else Control.SIZE_SHRINK_CENTER
		# In label mode the text sets the width; otherwise pin it square.
		button.custom_minimum_size.x = 0 if labelled else _button_px


# --- Signals --------------------------------------------------------------

## Buttons set_selection_state leaves alone. "brush" and the sticky locks stay usable with an empty
## selection (it builds points against whatever is already there, so it needs no selection of its
## own; the locks are settings). "csg" is here not because it's always live but because the plugin
## greys it itself via set_csg_enabled — brush count, not node count, decides whether any CSG op can
## run. Everything else acts ON a brush.
const ALWAYS_ENABLED := ["brush", "texture_lock", "uv_lock", "csg", "group", "physics"]


## Tools that reshape ONE solid's geometry and therefore need a brush, not merely a selection.
##
## A closed group offers them nothing to grab — its members are data, not nodes — and the answer is
## to open the group, not to leave a live button that quietly does nothing when pressed. Every other
## tool and action works on a group as a whole (move, duplicate, delete, flip, rotate, scale, shear),
## so those stay keyed to the selection at large.
const NEEDS_BRUSH := ["clip", "vertex", "edge", "face"]


## Grey out the buttons that have nothing to act on. The active tool is deliberately KEPT when
## the selection empties: deselecting is a constant part of moving between brushes, and dropping
## the mode every time meant re-picking it after each one. The tool stays pressed (greyed while
## there is nothing to act on) and resumes the moment a brush is selected again. Escape is the
## way out of a mode — see clear_tool().
##
## `has_brush` is deliberately narrower than `has_selection`: with only a group selected there IS a
## selection, but nothing a per-solid tool can reshape. A mixed brush-and-group selection satisfies
## both, and those tools then act on the brushes and ignore the group, which is what they already do.
func set_selection_state(has_selection: bool, has_brush: bool) -> void:
	for button in _buttons:
		var id: String = button.get_meta("id", "")
		if ALWAYS_ENABLED.has(id):
			continue
		button.disabled = not (has_brush if NEEDS_BRUSH.has(id) else has_selection)


## Drop back to no tool from code (the viewport's Escape handler uses this). Unpresses
## without a signal and announces the change once, so it can't re-enter through the group.
func clear_tool() -> void:
	var active := _tool_group.get_pressed_button()
	if active == null:
		return
	active.set_pressed_no_signal(false)
	tool_changed.emit("")


func _on_tool_pressed(button: BaseButton) -> void:
	# allow_unpress means this fires with the button already released, in which case
	# no tool is active any more.
	tool_changed.emit(button.get_meta("id", "") if button.button_pressed else "")


func _on_action_pressed(action_id: String) -> void:
	action_triggered.emit(action_id)


func _on_option_toggled(pressed: bool, option_id: String) -> void:
	option_toggled.emit(option_id, pressed)


func _on_lock_toggled(pressed: bool, button: Button, spec: Dictionary) -> void:
	button.icon = _load_icon("%s_%s" % [spec.icon, "on" if pressed else "off"])
	option_toggled.emit(spec.id, pressed)
