@tool
extends ConfirmationDialog
## A warning the user is allowed to switch off: "this will lose the following — carry on?", with a
## [b]Don't warn me again[/b] box. Raised by [code]Duckboard.warn_before[/code], which owns the one
## instance and the setting the box writes to; this file is the view and nothing else.
##
## [b]Everything goes in ONE container, and that is not a style choice.[/b] [AcceptDialog] OVERLAYS
## its children rather than stacking them — every Control child is anchored to the same content rect,
## and [code]_get_contents_minimum_size[/code] takes the MAX over them rather than the sum. Its
## built-in message label is one of those children, so setting `dialog_text` as well would print the
## message underneath this content instead of above it. The label is left empty and the whole layout
## lives in the VBox below.
##
## Phrased as a question with Cancel meaning "don't", so the destructive answer is never the one you
## get by dismissing the window.

## The list is what the user is really reading, so it gets room; the rest follows the theme.
const LIST_INDENT := 12

## Text width, and therefore the dialog's. Set on the labels rather than on the window, because
## [AcceptDialog] sizes itself from its contents — a width forced on the Window alone is overridden
## the moment it works out its own minimum. Wide enough that a "X — the group will be Y" line stays on
## one line, which is what makes the list scannable rather than a paragraph.
const TEXT_WIDTH := 720


var _lead: Label
var _list: VBoxContainer
var _forget: CheckBox


## Did the user tick "Don't warn me again"? Read by the caller after `confirmed` — a tick only counts
## when the action was actually confirmed, which is why this is read there and not on toggle.
var forget: bool:
	get:
		return _forget != null and _forget.button_pressed


func _init() -> void:
	# PRESET_FULL_RECT through set_anchors_and_offsets_preset, never set_anchors_preset: the latter
	# moves the anchors and leaves the OFFSETS at the rect the control was built with, which for a
	# code-built control is (0, 0, 0, 0) — an invisible, zero-sized box.
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", 10)
	add_child(box)

	_lead = Label.new()
	_lead.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lead.custom_minimum_size.x = TEXT_WIDTH
	box.add_child(_lead)

	var indent := MarginContainer.new()
	indent.add_theme_constant_override("margin_left", LIST_INDENT)
	box.add_child(indent)
	_list = VBoxContainer.new()
	indent.add_child(_list)

	# Pushed to the bottom so it reads as a footnote to the decision rather than part of the list.
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(spacer)

	_forget = CheckBox.new()
	_forget.text = "Don't warn me again"
	box.add_child(_forget)


## What the checkbox means, and where to undo it. Supplied by the caller because it names the caller's
## own setting — and because Editor Settings cannot show a description for a plugin's setting, this
## tooltip is the only place the explanation can be read at all.
func set_forget_tooltip(text: String) -> void:
	_forget.tooltip_text = text


## Fill the dialog for one warning. `items` are the specifics — one line each, because a wall of
## prose is what makes a warning get switched off unread.
func setup(p_title: String, lead: String, items: PackedStringArray, ok_text: String) -> void:
	title = p_title
	_lead.text = lead
	ok_button_text = ok_text
	for child in _list.get_children():
		child.queue_free()
	for item in items:
		var line := Label.new()
		line.text = "•  %s" % item
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		line.custom_minimum_size.x = TEXT_WIDTH - LIST_INDENT
		_list.add_child(line)
	# Unticked every time it is raised. A box that remembers its last state would let a stray tick
	# survive a Cancel and switch the warning off on the NEXT, unrelated confirmation.
	_forget.button_pressed = false
