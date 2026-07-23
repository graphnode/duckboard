@tool
extends VSplitContainer
## A VSplitContainer whose divider is drawn as a full-width line instead of the faint grabber dots,
## so it reads as a draggable seam. Still draggable — the grabber is only hidden visually, and
## hovering the divider still shows the vertical-resize cursor.

const LINE_ALPHA := 0.3
const LINE_WIDTH := 2.0


func _ready() -> void:
	dragger_visibility = DRAGGER_HIDDEN
	sort_children.connect(queue_redraw)
	resized.connect(queue_redraw)


func _draw() -> void:
	if get_child_count() < 2:
		return
	var top := get_child(0) as Control
	if top == null:
		return
	# The divider sits in the separation gap between the two panes; draw a line down its centre.
	var y := top.position.y + top.size.y + get_theme_constant("separation") * 0.5
	var color := get_theme_color("font_color", "Label")
	color.a = LINE_ALPHA
	draw_line(Vector2(0.0, y), Vector2(size.x, y), color, LINE_WIDTH)
