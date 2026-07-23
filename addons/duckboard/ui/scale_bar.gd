@tool
extends HBoxContainer
## Scale options for the 3D editor's top toolbar, shown only while the Scale tool is active and a
## brush is selected (mirrors TrenchBroom's scale bar):
##
##   Scale objects [to size | to factors] [x y z] [Apply]
##
## "to size"    — the field is the target bounding-box size in TB units (Z-up).
## "to factors" — the field is per-axis multipliers of the current size.
##
## The bar holds no geometry: [signal apply_pressed] hands the plugin the mode and the three values;
## the plugin (brush_plugin) reads the selection's current bounds and does the transform. The plugin
## pushes the live size in via [method set_size_tb] so "to size" opens pre-filled. An unparseable
## entry (see Vec3TextField) is refused by the field itself, and Apply then does nothing.

## Emitted when Apply is clicked with valid input. [param mode] is "size" or "factors"; [param values]
## carries the three fields (a TB-unit size, or three factors) in TB axis order (X, Y, Z).
signal apply_pressed(mode: String, values: Vector3)

const Vec3TextField := preload("res://addons/duckboard/ui/vec3_text_field.gd")

const MODE_SIZE := 0
const MODE_FACTORS := 1

var _mode: OptionButton
var _values: Vec3TextField
var _size_tb := Vector3.ONE   # last size the plugin pushed, so "to size" can pre-fill


func _init() -> void:
	add_theme_constant_override("separation", 4)

	add_child(_label("Scale objects"))
	_mode = OptionButton.new()
	_mode.add_item("to size", MODE_SIZE)
	_mode.add_item("to factors", MODE_FACTORS)
	_mode.tooltip_text = "Scale to an absolute size, or by per-axis factors"
	_mode.item_selected.connect(_on_mode_changed)
	add_child(_mode)

	_values = Vec3TextField.new()
	add_child(_values)

	var apply := Button.new()
	apply.text = "Apply"
	apply.focus_mode = Control.FOCUS_NONE
	apply.pressed.connect(_on_apply)
	add_child(apply)

	_configure_for_mode()


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


## The plugin pushes the selection's current bounding-box size (TB units). Kept so "to size" shows a
## real starting size; applied straight away when that's the active mode and the field isn't focused.
func set_size_tb(v: Vector3) -> void:
	_size_tb = v
	if _mode.selected == MODE_SIZE and not _values.has_focus():
		_values.set_vector(v)


func _on_mode_changed(_index: int) -> void:
	_configure_for_mode()


## Reseed the field for the active mode: the current size for "to size", identity 1 1 1 for factors.
func _configure_for_mode() -> void:
	if _mode.selected == MODE_SIZE:
		_values.tooltip_text = "Target size as X Y Z in TB units"
		_values.set_vector(_size_tb)
	else:
		_values.tooltip_text = "Per-axis multipliers as X Y Z"
		_values.set_vector(Vector3.ONE)


func _on_apply() -> void:
	if not _values.is_valid():
		return   # the field shows the error; nothing to apply
	var mode := "size" if _mode.selected == MODE_SIZE else "factors"
	apply_pressed.emit(mode, _values.get_vector())
