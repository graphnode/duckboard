@tool
extends LineEdit
## A compact single-line X Y Z field: three numbers separated by spaces, e.g. "-480 1184 864".
## Accepts either "." or "," as the decimal mark and any run of spaces between axes, and reformats to
## a canonical "x y z" on commit. While the text can't be read as three numbers it wears a red border
## and commits nothing — an invalid entry is simply ignored, and the field falls back to the last
## good value when focus leaves. [signal value_changed] fires only on a valid commit (Enter / focus
## out); [method get_vector] / [method is_valid] let a caller read it on demand (e.g. an Apply button).

signal value_changed(value: Vector3)

var _last_valid := Vector3.ZERO
var _invalid_shown := false


func _init() -> void:
	custom_minimum_size.x = 132
	tooltip_text = "Three numbers: X Y Z (space-separated)"
	text_changed.connect(_on_text_changed)
	text_submitted.connect(_on_commit)
	focus_exited.connect(func() -> void: _on_commit(text))


## Show `v` as canonical text without firing value_changed (used when syncing from state).
func set_vector(v: Vector3) -> void:
	_last_valid = v
	text = _format(v)
	_set_invalid(false)


## The current value if the text parses, else the last good value.
func get_vector() -> Vector3:
	var v = _parse(text)
	return v if v != null else _last_valid


func is_valid() -> bool:
	return _parse(text) != null


func _on_text_changed(new_text: String) -> void:
	# Empty stays neutral (mid-edit), not red; any non-empty text that won't parse is flagged.
	_set_invalid(not new_text.strip_edges().is_empty() and _parse(new_text) == null)


## Commit on Enter or focus-out: apply and reformat when valid, otherwise ignore the edit and snap
## the field back to the last good value so it never sits in a broken state.
func _on_commit(submitted: String) -> void:
	var v = _parse(submitted)
	if v == null:
		text = _format(_last_valid)
		_set_invalid(false)
		return
	_last_valid = v
	text = _format(v)
	_set_invalid(false)
	value_changed.emit(v)


## Parse "x y z" into a Vector3, or null. Commas become dots first (locale decimal marks), then any
## whitespace run splits the axes; exactly three numeric tokens are required.
func _parse(s: String):
	var cleaned := s.replace(",", ".").strip_edges()
	var parts := cleaned.split(" ", false)
	if parts.size() != 3:
		return null
	for p in parts:
		if not p.is_valid_float():
			return null
	return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())


## Up to three decimals, trailing zeros (and a bare point) trimmed, so integers read as integers.
func _format(v: Vector3) -> String:
	return "%s %s %s" % [_num(v.x), _num(v.y), _num(v.z)]


func _num(f: float) -> String:
	var s := String.num(f, 3)
	if s.contains("."):
		s = s.rstrip("0").rstrip(".")
	return "0" if s == "-0" or s.is_empty() else s


## Toggle a red border by overriding the LineEdit's box styleboxes (and clearing the override when
## valid). Derived from the active theme so it tracks light/dark editor themes.
func _set_invalid(on: bool) -> void:
	if on == _invalid_shown:
		return
	_invalid_shown = on
	if not on:
		remove_theme_stylebox_override("normal")
		remove_theme_stylebox_override("focus")
		return
	for sb_name in ["normal", "focus"]:
		var base := get_theme_stylebox(sb_name, "LineEdit")
		var red: StyleBoxFlat
		if base is StyleBoxFlat:
			red = (base as StyleBoxFlat).duplicate()
		else:
			red = StyleBoxFlat.new()
		red.set_border_width_all(1)
		red.border_color = Color(0.9, 0.28, 0.28)
		add_theme_stylebox_override(sb_name, red)
