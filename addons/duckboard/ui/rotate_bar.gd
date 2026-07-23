@tool
extends HBoxContainer
## Rotate options for the 3D editor's top toolbar, shown only while the Rotate tool is active and a
## brush is selected (mirrors TrenchBroom's rotate bar). Two groups:
##
##   Center [x y z] [Reset]          — the pivot, in TB units (Z-up). Committing the field re-homes
##                                     the widget; Reset snaps it back to the selection's centre.
##   Rotate by [deg°] about [axis] [Apply]  — a one-shot rotation of the selection.
##
## The bar holds no geometry state: it emits [signal center_edited] / [signal center_reset] /
## [signal apply_pressed] and the plugin (brush_plugin) owns the pivot and does the transform. The
## plugin pushes the current pivot back in via [method set_center_tb].

## Emitted when the Center field is committed. [param center] is in TB units (Z-up), matching display.
signal center_edited(center: Vector3)

## Emitted when Reset is clicked — the plugin recomputes the pivot from the selection bounds.
signal center_reset

## Emitted when Apply is clicked. [param degrees] is signed; [param axis] is 0/1/2 == TB X/Y/Z.
signal apply_pressed(degrees: float, axis: int)

const Vec3TextField := preload("res://addons/duckboard/ui/vec3_text_field.gd")

var _center: Vec3TextField
var _deg: SpinBox
var _axis: OptionButton


func _init() -> void:
	add_theme_constant_override("separation", 4)

	add_child(_label("Center"))
	_center = Vec3TextField.new()
	_center.tooltip_text = "Pivot as X Y Z in TB units (space-separated)"
	_center.value_changed.connect(func(v: Vector3) -> void: center_edited.emit(v))
	add_child(_center)

	var reset := Button.new()
	reset.text = "Reset"
	reset.focus_mode = Control.FOCUS_NONE
	reset.tooltip_text = "Snap the pivot back to the selection's centre"
	# Drop focus first: the button is FOCUS_NONE, so without this the field keeps keyboard focus and
	# set_center_tb's typing-guard would swallow the value Reset pushes back.
	reset.pressed.connect(func() -> void:
		_center.release_focus()
		center_reset.emit())
	add_child(reset)

	add_child(VSeparator.new())

	add_child(_label("Rotate by"))
	_deg = SpinBox.new()
	_deg.min_value = -359
	_deg.max_value = 359
	_deg.step = 1
	_deg.value = 15   # TrenchBroom's default angle snap
	_deg.suffix = "°"
	_deg.custom_minimum_size.x = 60
	_deg.tooltip_text = "Angle to rotate by (degrees)"
	add_child(_deg)

	add_child(_label("about"))
	_axis = OptionButton.new()
	for a in ["X", "Y", "Z"]:
		_axis.add_item(a)
	_axis.tooltip_text = "Axis to rotate about"
	add_child(_axis)

	var apply := Button.new()
	apply.text = "Apply"
	apply.focus_mode = Control.FOCUS_NONE
	apply.pressed.connect(func() -> void: apply_pressed.emit(_deg.value, _axis.selected))
	add_child(apply)


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


## Show the pivot the plugin holds, in TB units. Skipped while the field is being edited so a refresh
## (selection change, apply) can't clobber what the user is typing.
func set_center_tb(v: Vector3) -> void:
	if _center.has_focus():
		return
	_center.set_vector(v)
