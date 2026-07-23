@tool
extends Button
## One texture thumbnail tile for the Texture dock's browser.
##
## Fixed 64px wide; the height follows the texture's aspect ratio plus the caption line, so the
## thumbnail never distorts. The TextureRect is sized to the image and bottom-aligned, so the tile's
## outline hugs the texture itself (not letterbox padding) and images rest on the caption.
##
## Two outline states, driven by the dock: RED for the texture on the current face selection (only
## ever one), YELLOW (#ffb200) for textures used somewhere in the scene (any number). Red wins when
## a tile is both. The border is a Panel over the texture, so toggling it never nudges the layout.
## The caption is centred and ellipsised so any name fits the width.

const WIDTH := 64.0
## The caption shrinks to fit the tile width (TrenchBroom does the same) down to this floor, below
## which it ellipsises instead of becoming unreadable.
const LABEL_MIN_FONT_SIZE := 8
## Outline + caption tint for the selected texture — TrenchBroom's brush red, as in the map editor.
const SELECTED_COLOR := Color(0.86, 0.2, 0.2)
## Outline for textures currently used in the scene. #ffb200.
const IN_USE_COLOR := Color(1.0, 0.698039, 0.0)

@onready var _texture_rect: TextureRect = $VBoxContainer/TextureRect
@onready var _border: Panel = $VBoxContainer/TextureRect/Border
@onready var _label: Label = $VBoxContainer/Label
@onready var _vbox: VBoxContainer = $VBoxContainer

var _texture: Texture2D
var _caption := ""
var _selected := false
var _in_use := false
var _selected_box: StyleBoxFlat
var _in_use_box: StyleBoxFlat


## Point the tile at a texture and give it a caption. Safe to call before the tile is in the tree.
func set_thumbnail(texture: Texture2D, caption: String) -> void:
	_texture = texture
	_caption = caption
	if is_node_ready():
		_apply()


## The texture on the current face selection wears the red outline. Only one tile is ever selected.
func set_selected(value: bool) -> void:
	_selected = value
	if is_node_ready():
		_refresh_outline()


## Textures used anywhere in the scene wear the yellow outline. Red wins when a tile is both.
func set_in_use(value: bool) -> void:
	_in_use = value
	if is_node_ready():
		_refresh_outline()


func _ready() -> void:
	_selected_box = _make_border(SELECTED_COLOR)
	_in_use_box = _make_border(IN_USE_COLOR)
	_apply()


## The editor theme (hence the base font size) changed — re-fit the caption. Overriding the child
## Label's font size can't recurse this handler: THEME_CHANGED propagates to children, not up here.
func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready() and _texture != null:
		_fit_label_font()
		_fit_to_ratio()


func _make_border(color: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.draw_center = false
	box.border_width_left = 2
	box.border_width_top = 2
	box.border_width_right = 2
	box.border_width_bottom = 2
	box.border_color = color
	return box


func _apply() -> void:
	_texture_rect.texture = _texture
	_label.text = _caption
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER   # centre a shrunk name in the fixed row
	# Tooltip: name on the first line, pixel size on the second.
	if _texture != null:
		tooltip_text = "%s\n%d × %d" % [_caption, _texture.get_width(), _texture.get_height()]
	else:
		tooltip_text = _caption
	_fit_label_font()   # before _fit_to_ratio: the chosen size sets the caption's height
	_fit_to_ratio()
	_refresh_outline()


## Shrink the caption's font until the full name fits the tile width, down to LABEL_MIN_FONT_SIZE;
## past that the Label's own ellipsis (clip_text + TRIM_ELLIPSIS in the scene) takes over. Measured
## from the theme's base size each time — the override is cleared first — so it's idempotent across
## repeated calls and theme changes.
func _fit_label_font() -> void:
	_label.remove_theme_font_size_override("font_size")
	_label.custom_minimum_size.y = 0.0   # measure the natural base-font height first
	if _caption == "":
		return
	var base := _label.get_theme_font_size("font_size")
	var font := _label.get_theme_font("font")
	# Reserve the caption row at the BASE size so shrinking a long name never shortens the tile —
	# otherwise tiles in a row would take different heights and the textures would stagger up and
	# down. The shrunk text is centred inside this fixed-height row (set once in _apply).
	var base_h := _label.get_minimum_size().y
	var avail := WIDTH - 2.0   # a hair of breathing room inside the fixed 64px tile
	var size := base
	while size > LABEL_MIN_FONT_SIZE \
			and font.get_string_size(_caption, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > avail:
		size -= 1
	if size < base:
		_label.add_theme_font_size_override("font_size", size)
	_label.custom_minimum_size.y = base_h


## Width is fixed at 64; the image height follows the texture's aspect ratio. The TextureRect is
## sized to exactly that, so its full-rect Border child frames the texture rather than any padding.
func _fit_to_ratio() -> void:
	var image_h := WIDTH
	if _texture != null and _texture.get_width() > 0:
		image_h = WIDTH * float(_texture.get_height()) / float(_texture.get_width())
	image_h = ceilf(image_h)
	_texture_rect.custom_minimum_size = Vector2(0.0, image_h)
	var caption_h := _label.get_minimum_size().y
	var separation := _vbox.get_theme_constant("separation")
	custom_minimum_size = Vector2(WIDTH, image_h + separation + caption_h)


## Red when selected, else yellow when in use, else none. Caption turns red only when selected.
func _refresh_outline() -> void:
	if _selected:
		_border.add_theme_stylebox_override("panel", _selected_box)
		_border.visible = true
		_label.add_theme_color_override("font_color", SELECTED_COLOR)
	elif _in_use:
		_border.add_theme_stylebox_override("panel", _in_use_box)
		_border.visible = true
		_label.remove_theme_color_override("font_color")
	else:
		_border.visible = false
		_label.remove_theme_color_override("font_color")
