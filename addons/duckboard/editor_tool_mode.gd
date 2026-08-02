@tool
extends RefCounted
## Godot's built-in transform gizmo mode. Duckboard manipulates brushes itself — direct drag, no
## gizmo — so while a BRUSH is what is selected the viewport is pushed into the gizmo-free Select Mode
## added in Godot 4.6, and whatever was displaced is put back the moment the selection is somebody
## else's again.
##
## [b]It follows the selection, and it does not disable anything.[/b] An earlier version held Select
## Mode for as long as the map editor was on and greyed the Move / Rotate / Scale buttons out with it,
## which took the transform toolbar away from the entire scene: Transform Mode (`Q`), which is what
## most people leave selected, was not merely displaced but unavailable, and moving one lamp meant
## switching the whole addon off and on around it. The gizmo is only in the way when the thing
## selected is a brush, so that is exactly how long this lasts.
##
## None of the tool-mode API is bound to GDScript: Node3DEditor isn't a public class and
## EditorInterface has no setter. So we reach the toolbar through the tree — the plugin's _toggle is
## parented into the spatial-editor menu, i.e. under Node3DEditor — and identify the mode buttons by
## their editor ICON (ToolSelect/ToolMove/...), which is immune to localization and to the user
## rebinding the shortcuts. Firing a button's `pressed` runs Node3DEditor._menu_item_pressed exactly
## as a real click does: it switches the mode, re-presses the radio buttons and updates the gizmo.
##
## Owned by the Duckboard plugin, reached through `host` for the _toggle anchor.

const TOOL_ICONS := ["ToolTransform", "ToolMove", "ToolRotate", "ToolScale", "ToolSelect"]

var host: Duckboard
var _saved_tool_icon := ""   # icon of the mode button active before we forced Select ("" = none)


func _init(p_host: Duckboard) -> void:
	host = p_host


## Walk up from the plugin's toggle to the Node3DEditor. get_class() returns the real C++ name even
## though the type isn't script-visible, so this doesn't depend on the exact toolbar nesting. Null if
## not found (e.g. the control isn't parented yet).
func _node3d_editor() -> Node:
	var n: Node = host._toggle
	while n != null and n.get_class() != "Node3DEditor":
		n = n.get_parent()
	return n


## The transform mode buttons keyed by their editor-icon name, or {} if the toolbar can't be found.
func _tool_buttons() -> Dictionary:
	var out := {}
	var editor := _node3d_editor()
	if editor == null:
		return out
	var base := EditorInterface.get_base_control()
	var want := {}   # icon Texture2D -> name, so a single pass over the buttons can match them all
	for name in TOOL_ICONS:
		want[base.get_theme_icon(name, "EditorIcons")] = name
	for btn in editor.find_children("*", "Button", true, false):
		if btn.icon != null and want.has(btn.icon):
			out[want[btn.icon]] = btn
	return out


## Force the gizmo-free Select Mode, remembering the mode we displaced. No-op if already in Select
## or if the toolbar internals have moved out from under us.
func force_select() -> void:
	var buttons := _tool_buttons()
	var select: Button = buttons.get("ToolSelect")
	if select == null or select.button_pressed:
		# Already Select, so there is nothing to switch — but whatever was saved LAST time stays
		# saved. Clearing here is what made the mode stick: selecting a second brush ran this again,
		# found Select already pressed because the FIRST one had put it there, and threw away the
		# Transform mode it had displaced. Nothing was left to restore, so deselecting stranded the
		# user in Select. `_saved_tool_icon` is "" to begin with, so a session that was already in
		# Select still restores to nothing.
		return
	_saved_tool_icon = ""
	for name in TOOL_ICONS:
		var b: Button = buttons.get(name)
		if b != null and b.button_pressed:
			_saved_tool_icon = name
			break
	select.emit_signal("pressed")


## Put the viewport back in whatever mode was active before force_select() ran.
## Put back whatever [method force_select] displaced — but only if our Select is still the mode
## showing. The buttons are live now, so the user may have picked Move themselves since; restoring
## over that would undo a choice they made by hand.
func restore() -> void:
	if _saved_tool_icon == "":
		return
	var buttons := _tool_buttons()
	var select: Button = buttons.get("ToolSelect")
	var b: Button = buttons.get(_saved_tool_icon)
	_saved_tool_icon = ""
	if select == null or not select.button_pressed:
		return
	if b != null and not b.button_pressed:
		b.emit_signal("pressed")


## Grey out every transform mode button except Select, so the toolbar can't leave the gizmo-free
## mode while Duckboard is on. The Q/W/E/R/V shortcuts are owned by Node3DEditor and switch the
## mode without going through these buttons, so greying alone wouldn't stop them — but the letters
## that collide with our tools (R, E, F, T, ...) are grabbed in _forward_3d_gui_input via the
## palette's try_shortcut, which claims them wholesale. Q/W and other unused transform keys still
## fall through to the editor; grab them here too if they ever need locking out.
