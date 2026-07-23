@tool
extends HBoxContainer
## Shape selector for the NEXT brush, shown in the 3D editor's top toolbar while nothing is selected
## and no tool is active — a row of exclusive shape buttons (Cuboid / Stairs / Cylinder / Cone) plus
## a per-shape options strip, mirroring TrenchBroom's shape tool. The plugin reads get_shape() /
## get_params() when it commits a drawn box; [signal changed] fires on any edit so a preview can
## refresh. Spheroids are intentionally omitted (rare in brush maps).

const ICON_PATH := "res://addons/duckboard/icons/%s.svg"
const UNITS_PER_METER := 32.0   # 32 TrenchBroom units == 1 Godot metre; the spinboxes speak TB units

## Emitted whenever the shape or any parameter changes.
signal changed

const SHAPES := [
	{"id": "cuboid",   "icon": "ShapeTool_Cuboid",   "tip": "Cuboid"},
	{"id": "stairs",   "icon": "ShapeTool_Stairs",   "tip": "Stairs"},
	{"id": "cylinder", "icon": "ShapeTool_Cylinder", "tip": "Cylinder"},
	{"id": "cone",     "icon": "ShapeTool_Cone",     "tip": "Cone"},
]
const CIRCLE_MODES := [
	{"id": "edge",     "icon": "CircleEdgeAligned",   "tip": "Edges aligned to the bounding box"},
	{"id": "vertex",   "icon": "CircleVertexAligned", "tip": "Vertices aligned to the bounding box"},
	{"id": "scalable", "icon": "CircleScalable",      "tip": "Scalable circle (vertices on the grid)"},
]
const DIRECTIONS := ["+x", "-x", "+z", "-z"]

var _shape := "cuboid"
var _shape_group: ButtonGroup
var _circle_group: ButtonGroup

var _opts_sep: VSeparator   # divider before the options strip; hidden when the shape has none
var _stairs_opts: HBoxContainer
var _step_spin: SpinBox
var _dir_opt: OptionButton

var _round_opts: HBoxContainer
var _axis_opt: OptionButton
var _sides_spin: SpinBox
var _hollow_box: HBoxContainer
var _hollow_check: CheckBox
var _thick_spin: SpinBox


func _init() -> void:
	add_theme_constant_override("separation", 4)

	_shape_group = ButtonGroup.new()   # exclusive; one shape is always chosen
	for spec in SHAPES:
		var b := _icon_button(spec, _shape_group)
		if spec.id == _shape:
			b.set_pressed_no_signal(true)
		add_child(b)
	_shape_group.pressed.connect(_on_shape_pressed)

	_opts_sep = VSeparator.new()
	add_child(_opts_sep)
	_build_stairs_opts()
	_build_round_opts()
	_update_visible_opts()


## A flat icon toggle, styled to match the plugin's other toolbar toggles (empty idle box, a light
## fill when pressed so the active choice reads without tinting TrenchBroom's coloured icons).
func _icon_button(spec: Dictionary, group: ButtonGroup) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.button_group = group
	b.focus_mode = Control.FOCUS_NONE
	b.icon = load(ICON_PATH % spec.icon)
	b.tooltip_text = spec.tip
	b.expand_icon = false
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.set_meta("id", spec.id)
	var on_style := StyleBoxFlat.new()
	on_style.bg_color = Color(1, 1, 1, 0.16)
	on_style.set_corner_radius_all(3)
	b.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("pressed", on_style)
	b.add_theme_stylebox_override("hover_pressed", on_style)
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color",
			"icon_hover_pressed_color", "icon_focus_color"]:
		b.add_theme_color_override(state, Color.WHITE)
	return b


func _build_stairs_opts() -> void:
	_stairs_opts = HBoxContainer.new()
	_stairs_opts.add_theme_constant_override("separation", 3)
	_stairs_opts.add_child(_label("Step"))
	_step_spin = SpinBox.new()
	_step_spin.min_value = 1
	_step_spin.max_value = 512
	_step_spin.step = 1
	_step_spin.value = 16   # TB units; TrenchBroom's common riser
	_step_spin.tooltip_text = "Step height (map units)"
	_step_spin.value_changed.connect(func(_v: float) -> void: changed.emit())
	_stairs_opts.add_child(_step_spin)
	_stairs_opts.add_child(_label("Dir"))
	_dir_opt = OptionButton.new()
	for d in ["+X", "-X", "+Z", "-Z"]:
		_dir_opt.add_item(d)
	_dir_opt.tooltip_text = "Direction the stairs ascend"
	_dir_opt.item_selected.connect(func(_i: int) -> void: changed.emit())
	_stairs_opts.add_child(_dir_opt)
	add_child(_stairs_opts)


func _build_round_opts() -> void:
	_round_opts = HBoxContainer.new()
	_round_opts.add_theme_constant_override("separation", 3)
	_round_opts.add_child(_label("Axis"))
	_axis_opt = OptionButton.new()
	for a in ["X", "Y", "Z"]:
		_axis_opt.add_item(a)
	_axis_opt.select(1)   # Y: an upright cylinder is the common case
	_axis_opt.tooltip_text = "Axis the shape revolves around"
	_axis_opt.item_selected.connect(func(_i: int) -> void: changed.emit())
	_round_opts.add_child(_axis_opt)

	_round_opts.add_child(_label("Sides"))
	_sides_spin = SpinBox.new()
	_sides_spin.min_value = 3
	_sides_spin.max_value = 96
	_sides_spin.step = 1
	_sides_spin.value = 16
	_sides_spin.tooltip_text = "Number of sides"
	_sides_spin.value_changed.connect(func(_v: float) -> void: changed.emit())
	_round_opts.add_child(_sides_spin)

	_circle_group = ButtonGroup.new()
	for spec in CIRCLE_MODES:
		var b := _icon_button(spec, _circle_group)
		if spec.id == "edge":
			b.set_pressed_no_signal(true)
		_round_opts.add_child(b)
	_circle_group.pressed.connect(func(_b: BaseButton) -> void: changed.emit())

	# Hollow + thickness (cylinder only; hidden for cone).
	_hollow_box = HBoxContainer.new()
	_hollow_box.add_theme_constant_override("separation", 3)
	_hollow_check = CheckBox.new()
	_hollow_check.text = "Hollow"
	_hollow_check.focus_mode = Control.FOCUS_NONE
	_hollow_check.toggled.connect(_on_hollow_toggled)
	_hollow_box.add_child(_hollow_check)
	_thick_spin = SpinBox.new()
	_thick_spin.min_value = 1
	_thick_spin.max_value = 512
	_thick_spin.step = 1
	_thick_spin.value = 8
	_thick_spin.tooltip_text = "Wall thickness (map units)"
	_thick_spin.visible = false
	_thick_spin.value_changed.connect(func(_v: float) -> void: changed.emit())
	_hollow_box.add_child(_thick_spin)
	_round_opts.add_child(_hollow_box)

	add_child(_round_opts)


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _on_shape_pressed(button: BaseButton) -> void:
	_shape = button.get_meta("id", "cuboid")
	_update_visible_opts()
	changed.emit()


func _on_hollow_toggled(pressed: bool) -> void:
	_thick_spin.visible = pressed
	changed.emit()


## Show only the option strip the current shape uses. Cone reuses the cylinder strip minus Hollow.
func _update_visible_opts() -> void:
	_stairs_opts.visible = _shape == "stairs"
	_round_opts.visible = _shape == "cylinder" or _shape == "cone"
	_hollow_box.visible = _shape == "cylinder"
	# The divider only earns its place when an options strip follows it — a cuboid has none, so
	# hiding it stops a separator dangling at the end of the bar.
	_opts_sep.visible = _stairs_opts.visible or _round_opts.visible


func _circle_mode() -> String:
	var b := _circle_group.get_pressed_button()
	return b.get_meta("id", "edge") if b != null else "edge"


func get_shape() -> String:
	return _shape


## Parameters for the current shape, in the units the geometry builder wants (metres, radians-free).
func get_params() -> Dictionary:
	match _shape:
		"stairs":
			return {
				"step_height_m": _step_spin.value / UNITS_PER_METER,
				"direction": DIRECTIONS[_dir_opt.selected],
			}
		"cylinder":
			return {
				"axis": _axis_opt.selected,
				"sides": int(_sides_spin.value),
				"circle_mode": _circle_mode(),
				"hollow": _hollow_check.button_pressed,
				"thickness_m": _thick_spin.value / UNITS_PER_METER,
			}
		"cone":
			return {
				"axis": _axis_opt.selected,
				"sides": int(_sides_spin.value),
				"circle_mode": _circle_mode(),
			}
		_:
			return {}
