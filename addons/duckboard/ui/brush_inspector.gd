@tool
extends EditorInspectorPlugin
## Lays the Brush inspector's three action buttons out as ONE row of equal thirds, where the
## [code]@export_tool_button[/code] annotations stack them as three full-width rows of different
## widths. The annotations remain on [Brush] untouched — this plugin INTERCEPTS their properties
## and answers with the row instead, so a project using brush.gd with Duckboard disabled still
## gets the stacked buttons rather than nothing.
##
## Registered by the host in _enter_tree, like every other editor-side helper. Only the single
## Brush case is claimed: a multi-selection inspects a MultiNodeEdit, which _can_handle declines,
## so the annotations' own buttons serve it exactly as before.

## property name -> [short label, editor icon, method to call, tooltip]. The METHODS are the same
## ones the annotations bind, so the two presentations cannot act differently — including Convert
## going through the deferral that keeps it from freeing the button mid-signal.
const ACTIONS := {
	"rebuild_action": ["Rebuild", "Reload", "rebuild_mesh",
		"Rebuild the mesh from the stored geometry."],
	"recenter_action": ["Recenter", "ToolMove", "recenter",
		"Pull the origin back into the geometry."],
	"convert_action": ["Convert", "MeshInstance3D", "_request_convert_to_mesh",
		"Replace this solid with the plain engine nodes it derives: mesh, body, shapes,\n"
		+ "occluder. One-way: undoable this session, but once saved over, the mesh is all\n"
		+ "there is."],
}


func _can_handle(object: Object) -> bool:
	return object is Brush


## The row is added where the FIRST action property would have appeared, and all three are
## suppressed — returning true is what keeps the default button editors from being built.
func _parse_property(object: Object, _type: Variant.Type, name: String, _hint: PropertyHint,
		_hint_text: String, _usage: int, _wide: bool) -> bool:
	if not ACTIONS.has(name):
		return false
	if name == "rebuild_action":
		add_custom_control(_button_row(object as Brush))
	return true


func _button_row(brush: Brush) -> Control:
	var row := HBoxContainer.new()
	var theme_holder := EditorInterface.get_base_control()
	for name in ACTIONS:
		var spec: Array = ACTIONS[name]
		var button := Button.new()
		button.text = spec[0]
		button.icon = theme_holder.get_theme_icon(spec[1], &"EditorIcons")
		button.tooltip_text = spec[3]
		# Equal thirds: every button expands with the same stretch, whatever its label width, so
		# the row reads as one control instead of three loose ones. Clipping beats overflowing on
		# a narrow inspector — the icon and tooltip still say what a truncated label cannot.
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.clip_text = true
		var method: String = spec[2]
		button.pressed.connect(func() -> void:
			if is_instance_valid(brush):
				brush.call(method))
		row.add_child(button)
	return row
