@tool
extends HBoxContainer
## A compact two-axis numeric field built from EditorSpinSlider — the same widget Godot's inspector
## uses for Vector2 properties (drag-to-scrub, editor-themed). Built in code because EditorSpinSlider
## is an editor-only class and isn't placeable from the scene dock.

signal value_changed(value: Vector2)

var _x: EditorSpinSlider
var _y: EditorSpinSlider
var _x_multi: Label            # "multi" overlay shown when the target faces disagree on x / y
var _y_multi: Label
var _mixed := false            # either axis is currently "multi"


func _init(step := 0.001, suffix := "") -> void:
	# Zero separation + flat sliders (below) joins x and y into one bar, like the inspector's Vector2.
	add_theme_constant_override("separation", 0)
	_x = _make_slider("x", step, suffix)
	_y = _make_slider("y", step, suffix)
	add_child(_x)
	add_child(_y)
	_x_multi = make_multi_label()
	_y_multi = make_multi_label()
	_x.add_child(_x_multi)
	_y.add_child(_y_multi)
	# Any interaction clears "multi": editing either axis sets a uniform value on all faces.
	value_changed.connect(func(_v): _hide_multi())
	_x.value_focus_entered.connect(_hide_multi)
	_y.value_focus_entered.connect(_hide_multi)
	# Committing (Enter or clicking away) applies the shown value even if unchanged, so it can unify
	# a "multi" selection to that value.
	_x.value_focus_exited.connect(_on_value_committed)
	_y.value_focus_exited.connect(_on_value_committed)


func _ready() -> void:
	_apply_theme()


## Flat sliders draw no box of their own — they expect a background behind them (in the inspector,
## the property row provides it). We paint the editor's field background here, so the two flat
## sliders read as one joined box instead of showing the bare dock behind their number areas.
func _draw() -> void:
	var bg := get_theme_stylebox("normal", "LineEdit")
	if bg != null:
		draw_style_box(bg, Rect2(Vector2.ZERO, size))


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_apply_theme()
		queue_redraw()   # the _draw background stylebox is theme-dependent


## Tint the axis labels red/green like the inspector's Vector2 field (property_color_x/y from the
## Editor theme), and re-theme the "multi" overlays — all tracking the active editor theme.
func _apply_theme() -> void:
	_x.add_theme_color_override("label_color", get_theme_color("property_color_x", "Editor"))
	_y.add_theme_color_override("label_color", get_theme_color("property_color_y", "Editor"))
	theme_multi_label(_x_multi, _x)
	theme_multi_label(_y_multi, _y)


## Show/hide the per-axis "multi" overlays (the target faces disagree on that component).
func set_mixed(x_mixed: bool, y_mixed: bool) -> void:
	_x_multi.visible = x_mixed
	_y_multi.visible = y_mixed
	_mixed = x_mixed or y_mixed


func _hide_multi() -> void:
	_x_multi.hide()
	_y_multi.hide()


## Committing a field that was "multi": re-emit even if the value is unchanged, so the shown value
## is applied to every face (unifying the selection). No-op otherwise, to avoid pointless undo steps.
func _on_value_committed() -> void:
	if _mixed:
		_mixed = false
		value_changed.emit(get_value())


## A hidden "multi" label sized to cover a slider's number. Shared with the dock's angle field.
static func make_multi_label() -> Label:
	var l := Label.new()
	l.text = "multi"
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE   # clicks fall through to the slider underneath
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.visible = false
	return l


## Theme a "multi" overlay for `slider`: an opaque fill matching the field interior (to hide the
## number), inset from the left so the coloured axis label (x/y) stays visible. A slider with no
## label (the angle field) gets no inset and is covered fully.
static func theme_multi_label(l: Label, slider: EditorSpinSlider) -> void:
	var fill := StyleBoxFlat.new()
	var sb := slider.get_theme_stylebox("normal", "LineEdit")
	if sb is StyleBoxFlat:
		fill.bg_color = (sb as StyleBoxFlat).bg_color
	l.add_theme_stylebox_override("normal", fill)
	l.add_theme_color_override("font_color", slider.get_theme_color("font_color", "Label"))

	var inset := 0.0
	if not slider.label.is_empty():
		var font := slider.get_theme_font("font", "LineEdit")
		var font_size := slider.get_theme_font_size("font_size", "LineEdit")
		if font != null:
			inset = font.get_string_size(slider.label + " ", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var label_bg := slider.get_theme_stylebox("label_bg", "EditorSpinSlider")
		if label_bg != null:
			inset += label_bg.get_minimum_size().x
	l.offset_left = inset   # anchors are full-rect, so this just moves the left edge past the label


func _make_slider(axis_label: String, step: float, suffix: String) -> EditorSpinSlider:
	var s := EditorSpinSlider.new()
	s.label = axis_label
	s.step = step
	s.min_value = -99999.0
	s.max_value = 99999.0
	s.allow_greater = true
	s.allow_lesser = true
	s.hide_slider = true                       # compact "number you can drag", no fill bar
	s.flat = true                              # draws the label_bg accent; joins with its neighbour
	s.suffix = suffix
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.value_changed.connect(func(_v): value_changed.emit(get_value()))
	return s


func get_value() -> Vector2:
	return Vector2(_x.value, _y.value)


## Push values in without re-firing value_changed (avoids a feedback loop when syncing from state).
func set_value(v: Vector2) -> void:
	_x.set_value_no_signal(v.x)
	_y.set_value_no_signal(v.y)


func set_read_only(on: bool) -> void:
	_x.read_only = on
	_y.read_only = on


func set_step(step: float) -> void:
	_x.step = step
	_y.step = step


## Coarse keyboard-nudge increment for ↑/↓ (add/subtract this), kept separate from the fine `step`
## that drives display precision and scrub speed. Stored as metadata the dock's key handler reads.
func set_nudge(n: float) -> void:
	_x.set_meta("nudge", n)
	_y.set_meta("nudge", n)
