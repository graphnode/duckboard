@tool
extends PanelContainer
## A section header styled like the editor's Inspector category rows (EditorInspectorCategory).
##
## It reuses the very theme items the inspector category draws with — the "bg" stylebox, the bold
## editor font, the editor font color and the class-icon size — so it tracks whatever editor theme
## is active (classic, modern, or a custom one) instead of hard-coding colors. Godot's own category
## is a single custom-drawn Control; this rebuilds the same look from plain controls so it stays
## editable in a scene.
##
## `icon_name` is an EditorIcons name (e.g. "MeshTexture"); leave it empty for a text-only header.

@export var title := "":
	set(value):
		title = value
		if is_node_ready():
			_label.text = value

## Name of an editor icon (the EditorIcons theme type), or "" for no icon.
@export var icon_name := "":
	set(value):
		icon_name = value
		if is_node_ready():
			_apply_editor_theme()

@onready var _hbox: HBoxContainer = %HBox
@onready var _icon: TextureRect = %Icon
@onready var _label: Label = %Label

# Applying theme overrides re-emits NOTIFICATION_THEME_CHANGED; this guards against re-entry.
var _applying := false


func _ready() -> void:
	_label.text = title
	_apply_editor_theme()


func _notification(what: int) -> void:
	# The editor re-emits this when the user switches themes, so the header restyles live.
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_apply_editor_theme()


func _apply_editor_theme() -> void:
	if _applying:
		return
	_applying = true
	# Background: the exact stylebox the inspector uses for its category rows. The category is a
	# plain Control that just draws the box, so the box must not add to our size — zero its content
	# margins on a copy, and let custom_minimum_size (below) own the height instead.
	var bg := get_theme_stylebox("bg", "EditorInspectorCategory")
	if bg != null:
		var box: StyleBox = bg.duplicate()
		box.content_margin_left = 0.0
		box.content_margin_top = 0.0
		box.content_margin_right = 0.0
		box.content_margin_bottom = 0.0
		add_theme_stylebox_override("panel", box)

	# Bold editor font + the category's font color (from the Tree type, as the inspector uses).
	var font := get_theme_font("bold", "EditorFonts")
	var font_size := get_theme_font_size("bold_size", "EditorFonts")
	if font != null:
		_label.add_theme_font_override("font", font)
	if font_size > 0:
		_label.add_theme_font_size_override("font_size", font_size)
	_label.add_theme_color_override("font_color", get_theme_color("font_color", "Tree"))

	# Match the class-icon size the inspector draws its category icons at.
	var icon_size := get_theme_constant("class_icon_size", "Editor")
	if icon_size > 0:
		_icon.custom_minimum_size = Vector2(icon_size, icon_size)

	# No extra icon-text separation: the class icon fills its box (as the inspector sizes it) but
	# carries its own transparent margin, which already lands the visible gap at ~8px and scales
	# with the icon/DPI. Pinned to 0 so the theme's default HBox separation doesn't add to it.
	_hbox.add_theme_constant_override("separation", 0)

	# Height mirrors EditorInspectorCategory.get_minimum_size(): tallest of icon/text plus a
	# vertical separation. The "bg" stylebox carries no vertical margin (classic theme), so this
	# min size is what gives the row its ~32px, not the panel padding.
	var text_h := font.get_height(font_size) if font != null else 0.0
	var content_h: float = maxf(float(icon_size), text_h)
	custom_minimum_size.y = content_h + get_theme_constant("separation", "EditorPropertyContainer")

	if icon_name != "":
		_icon.texture = get_theme_icon(icon_name, "EditorIcons")
		_icon.visible = true
	else:
		_icon.texture = null
		_icon.visible = false

	_applying = false
