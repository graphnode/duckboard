@tool
extends VBoxContainer
## The Texture inspector dock — Duckboard's counterpart to TrenchBroom's Face tab.
##
## The LAYOUT lives in texture_dock.tscn (design it visually there); this script drives it. Static
## widgets are referenced by unique name (`%Search`, `%Thumbs`); only the variable part —
## the texture thumbnails — is built in code, into the `Thumbs` flow container the scene provides.
## The HFlowContainer wraps the thumbnails to the dock width on its own, so there's no column math.
##
## A material browser plus per-face UV controls: it lists the textures under the scanned folders
## and assigns the clicked one to whatever faces are selected; the numeric UV fields
## (offset/scale/angle) and the visual UV canvas edit the selection's mapping.
##
## The dock only DISPLAYS and RAISES intent — it emits `surface_chosen` and lets the plugin apply
## it, because the plugin owns the face selection and the undo/redo manager. That keeps the dock a
## pure view with no reach into the scene.
##
## A browser entry is a SURFACE: a Texture2D (shown flat, applied as a StandardMaterial3D) or a
## Material (shown as a sphere preview, applied as the whole material — Godot's model).

signal surface_chosen(surface: Resource)
## UV field edits. The plugin applies these to the target faces (with undo); the dock is just the UI.
signal uv_offset_changed(offset: Vector2)
signal uv_scale_changed(scale: Vector2)
signal uv_angle_changed(angle: float)
## One of the UV utility buttons was pressed (reset / world / flip_u / flip_v / rotate_ccw / rotate_cw).
signal uv_action(action: String)
## The face was dragged in the UV canvas — offset delta in UV/tile units (single face only).
## A UV-canvas drag began / released — the plugin snapshots undo state once per drag on these.
signal uv_drag_started
signal uv_drag_ended

signal uv_offset_dragged(delta_tiles: Vector2)
## Rotation drag on the UV canvas's origin widget: started (pivot in UV/tile space), then
## absolute deltas (degrees since start). The plugin rotates the face's mapping about the pivot.
signal uv_rotate_started(pivot_uv: Vector2)
signal uv_rotate_dragged(delta_deg: float)
## Scale drag on a UV canvas grid line: started (pivot in UV/tile space), then per-axis factors
## (multipliers on the start scale). The plugin scales the face's mapping about the pivot.
signal uv_scale_started(pivot_uv: Vector2)
signal uv_scale_dragged(factor: Vector2)
## Clicked empty space in the browser (not a tile) — clear the active texture.
signal texture_deselected

## Right-click menu actions on a browser tile. The plugin owns the scene + undo, so the dock only
## raises intent: select every face wearing this surface, select every brush that uses it, or swap
## every use of one surface (texture or material) for another across the whole map.
signal select_faces_requested(surface: Resource)
signal select_brushes_requested(surface: Resource)
signal replace_texture_requested(from_surface: Resource, to_surface: Resource)

## The addon's own folder — its internal textures are never SCANNED into the browser and are never
## auto-adopted from the in-use set. The one exception is the empty default below, which is added
## deliberately as a built-in entry rather than found.
const ADDON_DIR := "res://addons/duckboard/"
## The untextured default, pinned to the front of the browser as "Empty". Every face that has never
## been given a texture already wears it, so it belongs in the browser as the way to put a face BACK
## to bare — otherwise the only route is undo. It doubles as the nodraw marker: an Empty face is
## dropped from the mesh in a running game (see Brush._build_mesh) while still being drawn here, so
## it can be seen, picked and given a real texture. Built in rather than adopted — it ships with the
## addon, so it is not a per-project path and must never land in the loose list or be removed.
const EMPTY_TEXTURE := preload("res://addons/duckboard/textures/__empty.png")
const EMPTY_LABEL := "Empty"
## The browser's ONLY source: a per-project list (a ProjectSettings key, so it lives in project.godot
## and travels through VCS) of every texture path the map has used. Populated by auto-adoption — a
## texture dragged from the FileSystem onto a brush face is applied, lands in the in-use set, and is
## recorded here so it stays browsable next session. There is no folder scan.
const LOOSE_SETTING := "duckboard/textures/loose"
const TextureIconScene := preload("res://addons/duckboard/ui/texture_icon.tscn")
const ViewportDrop := preload("res://addons/duckboard/ui/viewport_drop.gd")   # shared drag-payload rules
const TextureIcon := preload("res://addons/duckboard/ui/texture_icon.gd")
const UVCanvas := preload("res://addons/duckboard/ui/uv_canvas.gd")
const Vector2Field := preload("res://addons/duckboard/ui/vector2_field.gd")

# Right-click menu item ids (see _build_context_menu).
const CTX_SELECT_FACES := 0
const CTX_SELECT_BRUSHES := 1
const CTX_REPLACE := 2
const CTX_COPY_NAME := 3
const CTX_REMOVE := 4

@onready var _search: LineEdit = %Search
@onready var _thumbs: HFlowContainer = %Thumbs
@onready var _fields: GridContainer = %Fields
@onready var _material_info: Label = %MaterialInfo
@onready var _material_size: Label = %MaterialSize
@onready var _uv_buttons: HFlowContainer = %UvButtons
@onready var _uv_canvas: UVCanvas = %UVCanvas
@onready var _vsplit: VSplitContainer = $VSplit

var _offset_field: Vector2Field
var _scale_field: Vector2Field
var _angle_field: EditorSpinSlider
var _angle_multi: Label            # "multi" overlay for the angle field
var _angle_mixed := false          # the angle is currently "multi"

var _entries: Array = []          # {name, path, resource, tile} — resource is a Texture2D or Material
var _context_menu: PopupMenu      # per-tile right-click menu
var _context_entry                # the entry the context menu is acting on (a _entries element)
var _active_surface: Resource     # the "current" surface (red outline); new brushes use this
var _in_use: Dictionary = {}      # set of surfaces used anywhere in the scene (Resource -> true)


func _ready() -> void:
	_search.text_changed.connect(_on_search_changed)
	_uv_canvas.drag_started.connect(func(): uv_drag_started.emit())
	_uv_canvas.drag_ended.connect(func(): uv_drag_ended.emit())
	_uv_canvas.offset_dragged.connect(func(d): uv_offset_dragged.emit(d))
	_uv_canvas.rotate_started.connect(func(p): uv_rotate_started.emit(p))
	_uv_canvas.rotate_dragged.connect(func(d): uv_rotate_dragged.emit(d))
	_uv_canvas.scale_started.connect(func(p): uv_scale_started.emit(p))
	_uv_canvas.scale_dragged.connect(func(f): uv_scale_dragged.emit(f))
	# Left-click on empty browser space (the flow container or the scroll area around it, not a tile)
	# deselects the active texture.
	_thumbs.gui_input.connect(_on_browser_empty_input)
	_thumbs.get_parent().gui_input.connect(_on_browser_empty_input)
	_build_context_menu()
	_build_fields()
	_indent_info_row()
	_scan_textures()
	# Both panes expand with equal stretch ratios, so the split's default (split_offset 0) already
	# sits at 50/50 — no manual offset needed.


# --- UV fields (offset / scale / angle) ------------------------------------

## Build the offset/scale/angle rows from editor-native EditorSpinSliders. Done in code because
## EditorSpinSlider is an editor-only widget; they're added into the `Fields` grid the scene lays out.
func _build_fields() -> void:
	# EditorSpinSlider ties display precision, value snapping, AND scrub speed all to `step`, with no
	# way to separate them. So `step` stays FINE — exact-enough display, smooth scrub, and no coarse
	# snapping of values pushed in from the canvas — while the coarse ↑/↓ keyboard nudge (TrenchBroom's
	# spin-arrow equivalent) is driven separately from a per-field "nudge" meta that _input() reads.
	# (Godot's built-in ↑/↓ can't be retuned independently of step; _input intercepts it first.)
	_offset_field = Vector2Field.new(0.01, "px")
	_scale_field = Vector2Field.new(0.01)
	_angle_field = EditorSpinSlider.new()
	_angle_field.step = 0.1
	_angle_field.min_value = 0.0
	_angle_field.max_value = 360.0
	_angle_field.allow_greater = true   # allow scrubbing past the ends so the handler can wrap
	_angle_field.allow_lesser = true
	_angle_field.hide_slider = true
	_angle_field.suffix = "°"
	_angle_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Coarse ↑/↓ nudges (TrenchBroom parity): angle 15°, scale 0.1. Offset's is the grid size, pushed
	# by the plugin via set_offset_nudge() as the grid dropdown changes (16 is the default grid).
	_angle_field.set_meta("nudge", 15.0)
	_scale_field.set_nudge(0.1)
	_offset_field.set_nudge(16.0)

	_add_field_row("Offset", _offset_field)
	_add_field_row("Scale", _scale_field)
	_add_field_row("Angle", _angle_field)

	# Angle "multi" overlay (the Vector2Fields manage their own); themed here, re-themed in _notification.
	_angle_multi = Vector2Field.make_multi_label()
	_angle_field.add_child(_angle_multi)
	Vector2Field.theme_multi_label(_angle_multi, _angle_field)
	_angle_field.value_focus_entered.connect(_angle_multi.hide)

	_offset_field.value_changed.connect(func(v): uv_offset_changed.emit(v))
	_scale_field.value_changed.connect(func(v): uv_scale_changed.emit(v))
	_angle_field.value_changed.connect(_on_angle_changed)
	# Committing (Enter/blur) a "multi" angle applies the shown value even if unchanged, to unify it.
	_angle_field.value_focus_exited.connect(_on_angle_committed)
	_build_uv_buttons()
	set_uv(Vector2.ZERO, Vector2.ONE, 0.0, false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _angle_multi != null:
		Vector2Field.theme_multi_label(_angle_multi, _angle_field)


## Wrap the angle into [0, 360): 360 -> 0, 0 - step -> 345, and any negative to its positive
## equivalent (-15 -> 345). Then apply the wrapped value to the target faces.
func _on_angle_changed(v: float) -> void:
	_angle_multi.hide()
	var wrapped := fposmod(v, 360.0)
	if not is_equal_approx(wrapped, v):
		_angle_field.set_value_no_signal(wrapped)
		v = wrapped
	uv_angle_changed.emit(v)


## Committing a "multi" angle: apply the shown value even if unchanged, to unify the selection.
func _on_angle_committed() -> void:
	if _angle_mixed:
		_angle_mixed = false
		_on_angle_changed(_angle_field.value)


## Keyboard ↑/↓ nudge for the focused UV field — the replacement for TrenchBroom's spin arrows
## (Godot's own ↑/↓ can't be retuned off `step`, and would use its inspector convention instead).
## Adds/subtracts the field's coarse "nudge" as plain arithmetic — NO snap to a grid — so an
## off-grid value (say a canvas rotation of 37.3°) just moves by ±step. Fires only while one of our
## fields (or its inner text box) holds focus; every other ↑/↓ passes straight through.
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	if event.keycode != KEY_UP and event.keycode != KEY_DOWN:
		return
	var slider := _focused_uv_slider()
	if slider == null:
		return
	var nudge: float = slider.get_meta("nudge", slider.step)
	var dir := 1.0 if event.keycode == KEY_UP else -1.0
	slider.set_value(slider.value + dir * nudge)   # fires value_changed -> applies (+ wraps angle)
	_refresh_spin_text(slider)
	get_viewport().set_input_as_handled()


## EditorSpinSlider only refreshes its editable text box from its OWN arrow-key path (it sets a dirty
## flag); an external set_value() leaves the shown number stale while the field is focused. So after a
## keyboard nudge, push the formatted value into the box ourselves. Harmless when the box is hidden —
## the drawn label already tracks the value on its own.
func _refresh_spin_text(slider: EditorSpinSlider) -> void:
	var le: LineEdit = slider.get_line_edit()
	if le == null:
		return
	le.text = String.num(slider.value, _step_decimals(slider.step))
	le.caret_column = le.text.length()


## Decimal places implied by a step (0.1 -> 1, 0.01 -> 2, >=1 -> 0) — matches how EditorSpinSlider
## formats its own text, so our refresh doesn't change the number of shown digits.
func _step_decimals(step: float) -> int:
	var d := 0
	var s := absf(step)
	while s > 0.0 and s < 1.0 and d < 6:
		s *= 10.0
		d += 1
	return d


## The UV EditorSpinSlider currently holding keyboard focus (directly or via its inner LineEdit),
## or null — identified by the "nudge" meta every UV slider carries.
func _focused_uv_slider() -> EditorSpinSlider:
	var node: Node = get_viewport().gui_get_focus_owner()
	while node != null:
		if node is EditorSpinSlider and node.has_meta("nudge"):
			return node as EditorSpinSlider
		node = node.get_parent()
	return null


## The plugin pushes the current grid size here so ↑/↓ nudges the offset by one grid step, like
## TrenchBroom. Offset is shown in texels/px, so this is the grid size expressed in those units.
func set_offset_nudge(px: float) -> void:
	if _offset_field != null:
		_offset_field.set_nudge(px)


## Show/hide "multi" per field component when the target faces disagree on that value.
func set_mixed(off_x: bool, off_y: bool, scale_x: bool, scale_y: bool, angle: bool) -> void:
	if _offset_field == null:
		return
	_offset_field.set_mixed(off_x, off_y)
	_scale_field.set_mixed(scale_x, scale_y)
	_angle_multi.visible = angle
	_angle_mixed = angle


## The TrenchBroom-style UV utility buttons — the original TB icons, centred, full name on tooltip.
## Each just reports its action id; the plugin applies it to the target faces (with undo).
func _build_uv_buttons() -> void:
	var defs := [
		["Reset UV alignment", "reset", "ResetUV"],
		["Reset UV to world aligned", "world", "ResetUVToWorld"],
		["Fit texture to face", "fit", "FitTexture"],
		["Flip U axis", "flip_u", "FlipUAxis"],
		["Flip V axis", "flip_v", "FlipVAxis"],
		["Rotate UV 90° counter-clockwise", "rotate_ccw", "RotateUVCCW"],
		["Rotate UV 90° clockwise", "rotate_cw", "RotateUVCW"],
	]
	for d in defs:
		var b := Button.new()
		b.flat = true                                    # bare icon — no border or background
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = d[0]
		b.icon = load("res://addons/duckboard/icons/%s.svg" % d[2])
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER   # centre the glyph (no text label)
		b.pressed.connect(uv_action.emit.bind(d[1]))
		_uv_buttons.add_child(b)


func _add_field_row(label_text: String, field: Control) -> void:
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 48
	_fields.add_child(label)
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields.add_child(field)


## Indent the texture-name row so its left edge lines up with the UV VALUE fields rather than the
## row labels — the name then reads as sitting above the offset/scale/angle values. The gutter
## matches _add_field_row's 48px label column (the info row's own separation makes up the rest).
func _indent_info_row() -> void:
	var info_row := _material_info.get_parent()
	if info_row == null:
		return
	var gutter := Control.new()
	gutter.custom_minimum_size.x = 48
	gutter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_row.add_child(gutter)
	info_row.move_child(gutter, 0)


## Push the target faces' UV into the fields (no signal), and enable them only when there's a face
## to edit. `enabled` false greys the row out for an empty/degenerate selection.
func set_uv(offset: Vector2, scale: Vector2, angle: float, enabled: bool) -> void:
	if _offset_field == null:
		return
	_offset_field.set_value(offset)
	_scale_field.set_value(scale)
	_angle_field.set_value_no_signal(angle)
	_offset_field.set_read_only(not enabled)
	_scale_field.set_read_only(not enabled)
	_angle_field.read_only = not enabled
	if _uv_buttons != null:
		for b in _uv_buttons.get_children():
			b.disabled = not enabled




## Feed the visual UV editor the target face's surface (texture OR material), fixed shape and
## matching UV outline (or empty polys to clear it — it works on a single face only).
func set_uv_face(surface: Resource, shape: PackedVector2Array, uv: PackedVector2Array) -> void:
	if _uv_canvas != null:
		_uv_canvas.set_face(surface, shape, uv)


## Name and pixel size of the target face's surface, shown as two informative fields above the UV
## fields — the name (left) and the size (right). Materials have no intrinsic size, so that clears.
func set_material_info(surface: Resource) -> void:
	if _material_info == null:
		return
	if surface == null:
		_material_info.text = "No material"
		_material_size.text = ""
	elif surface is Material:
		_material_info.text = "Material %s" % _surface_name(surface)
		_material_size.text = ""
	else:
		var tex := surface as Texture2D
		_material_info.text = "Texture %s" % _surface_name(tex)
		_material_size.text = "%d × %d" % [tex.get_width(), tex.get_height()]


## Re-list the tiles when the face selection changes. The params are unused — kept so the
## plugin's call site stays a single entry point for selection updates.
func set_target(_count: int, _shared: Resource) -> void:
	if is_node_ready():
		_refresh_tiles()


## The set of surfaces used anywhere in the scene — each gets the yellow "in use" outline. Any of
## them the browser doesn't list yet is auto-adopted first (see _adopt_in_use).
func set_in_use(in_use: Dictionary) -> void:
	_in_use = in_use
	if is_node_ready():
		_adopt_in_use()
		_refresh_tiles()


## The "current"/active surface — red outline, and what new brushes are created with. Owned by the
## plugin (so it survives dock toggles); the dock only displays it and reports clicks.
func set_active(surface: Resource) -> void:
	_active_surface = surface
	if is_node_ready():
		_refresh_tiles()


func _surface_name(res: Resource) -> String:
	if res == null:
		return "none"
	if res.resource_path == "":
		return "unnamed"
	return res.resource_path.get_file().get_basename()


# --- Texture scanning ------------------------------------------------------

## The browser lists ONLY the textures the map has actually used, remembered per-project in the
## loose list — there is no bulk folder scan. A texture enters the browser by being dropped onto a
## brush face (the in-use pass then adopts it, see _adopt_in_use). A listed file that's since gone
## missing is skipped but NOT pruned: a teammate may simply not have pulled it yet, and pruning
## would rewrite the shared project.godot.
func _scan_textures() -> void:
	_entries.clear()
	var seen := {}
	for path in _loose_paths():
		if seen.has(path) or path.begins_with(ADDON_DIR) or not ResourceLoader.exists(path):
			continue
		seen[path] = true
		var res := load(path)
		if res is Texture2D or res is Material:
			_entries.append({"name": path.get_file().get_basename(), "path": path,
				"resource": res, "tile": null})
	# Stable alphabetical order, so the grid doesn't reshuffle between sessions.
	_entries.sort_custom(func(a, b): return a.name.naturalnocasecmp_to(b.name) < 0)
	# Empty goes in AFTER the sort so it is always the first tile, wherever "Empty" would fall
	# alphabetically. `builtin` is what makes it non-removable — see _show_context_menu.
	_entries.push_front({"name": EMPTY_LABEL, "path": EMPTY_TEXTURE.resource_path,
		"resource": EMPTY_TEXTURE, "tile": null, "builtin": true})
	_build_buttons()


func _build_buttons() -> void:
	for child in _thumbs.get_children():
		child.queue_free()
	for entry in _entries:
		_thumbs.add_child(_make_tile(entry))
	_refresh_tiles()


## Build one thumbnail tile and hook it into `entry` (which keeps the tile reference).
func _make_tile(entry: Dictionary) -> TextureIcon:
	var tile := TextureIconScene.instantiate() as TextureIcon
	# A tile would otherwise be a hole in the drop area — see TextureIcon._can_drop_data.
	tile.drop_target = self
	_apply_tile_thumbnail(tile, entry.resource, entry.name)
	tile.pressed.connect(_on_texture_pressed.bind(entry.resource))
	# Right-click opens the per-texture context menu. A Button only fires `pressed` for the left
	# button, so the right-click is caught through gui_input instead.
	tile.gui_input.connect(_on_tile_input.bind(tile, entry))
	entry.tile = tile
	return tile


## Point a tile at a surface: a texture shows flat; a material shows Godot's sphere preview, fetched
## asynchronously from the editor's resource previewer (a static thumbnail, generated once + cached).
func _apply_tile_thumbnail(tile: TextureIcon, resource: Resource, tile_name: String) -> void:
	if resource is Texture2D:
		tile.set_thumbnail(resource, tile_name)
	else:
		tile.set_thumbnail(null, tile_name)   # placeholder until the sphere preview arrives
		_queue_material_preview(resource, tile, tile_name)


func _queue_material_preview(mat: Resource, tile: TextureIcon, tile_name: String) -> void:
	if mat == null or mat.resource_path == "":
		return
	var previewer := EditorInterface.get_resource_previewer()
	if previewer != null:
		previewer.queue_resource_preview(
			mat.resource_path, self, "_on_material_preview", [tile, tile_name])


## Resource-previewer callback: drop the generated sphere onto the tile (if it's still around).
func _on_material_preview(_path: String, preview: Texture2D, _thumbnail: Texture2D,
		userdata: Array) -> void:
	var tile = userdata[0]
	if is_instance_valid(tile) and preview != null:
		tile.set_thumbnail(preview, userdata[1])


# --- Drag textures straight into the browser -------------------------------

## Accept a drag from the FileSystem dock (or a resource picker) that carries any usable texture —
## one or several files, texture/material resources, or whole folders. Godot walks up from the
## control under the cursor to find these, but stops at the first STOP mouse_filter — so the
## thumbnails forward to here explicitly rather than blocking the drop (see TextureIcon).
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	# Cheap check (runs every frame while hovering): accept on the first folder or texture without
	# scanning folders — the full scan happens once, in _drop_data.
	if typeof(data) != TYPE_DICTIONARY:
		return false
	if data.get("type", "") == "resource":
		return ViewportDrop.surface_from_resource(data.get("resource")) != null
	# A FileSystem drag lands the paths under "files" regardless of whether the drag is tagged
	# "files", "dirs" or "files_and_dirs" — so read that array directly rather than gating on type
	# (a folder-only drag is "dirs", which the old "files"-only match silently rejected).
	for path in data.get("files", []):
		if DirAccess.dir_exists_absolute(path) or ViewportDrop.surface_from_path(path) != null:
			return true
	return false


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	var changed := false
	for surface in _dropped_surfaces(data):
		changed = _adopt_dropped(surface) or changed
	if changed:
		ProjectSettings.save()


## Surfaces a browser drop amounts to (textures and materials). Like the viewport's extractor but
## folder-aware: a dropped FileSystem folder is scanned recursively (a deliberate bulk-add).
func _dropped_surfaces(data: Variant) -> Array:
	if typeof(data) != TYPE_DICTIONARY:
		return []
	if data.get("type", "") == "resource":
		var res := ViewportDrop.surface_from_resource(data.get("resource"))
		return [res] if res != null else []
	# "files", "dirs" and "files_and_dirs" all carry their paths under "files"; take them all.
	var out: Array = []
	for path in data.get("files", []):
		if DirAccess.dir_exists_absolute(path):
			_collect_folder_surfaces(path, out)
		else:
			var surface := ViewportDrop.surface_from_path(path)
			if surface != null:
				out.append(surface)
	return out


func _collect_folder_surfaces(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var file := dir.get_next()
	while file != "":
		var full := dir_path.path_join(file)
		if dir.current_is_dir():
			if not file.begins_with("."):
				_collect_folder_surfaces(full, out)
		else:
			var surface := ViewportDrop.surface_from_path(full)
			if surface != null:
				out.append(surface)
		file = dir.get_next()
	dir.list_dir_end()


## List a dropped surface in the browser and remember it, just like a face adoption but without a
## brush. Returns whether the loose list changed (so the caller batches the save).
func _adopt_dropped(surface: Resource) -> bool:
	var path: String = surface.resource_path
	if path == "" or path.begins_with(ADDON_DIR):
		return false
	for entry in _entries:
		if entry.path == path:
			return false   # already listed
	_insert_entry(path.get_file().get_basename(), path, surface)
	return _remember_loose(path)


# --- Auto-adoption ---------------------------------------------------------

## Any texture the scene uses that the browser doesn't list yet gets a tile immediately, and its
## path is remembered per-project so it stays listed next session. This is what makes dropping a
## texture from anywhere in the project onto a brush "just work": the plugin applies it, the face
## puts it in the in-use set, and the next sync lands here. It equally adopts the textures of a
## map authored before its textures were organised under the scanned folders.
func _adopt_in_use() -> void:
	var known := {}
	for entry in _entries:
		known[entry.path] = true
	var remembered := false
	for surface in _in_use:
		var path: String = surface.resource_path
		# No path means an embedded/built-in resource: nothing stable to list or remember. The
		# addon's own textures are internal and never adopted — __empty is already listed as the
		# pinned "Empty" entry, and adopting it would also write an addon path into the loose list.
		if path == "" or known.has(path) or path.begins_with(ADDON_DIR):
			continue
		known[path] = true
		_insert_entry(path.get_file().get_basename(), path, surface)
		remembered = _remember_loose(path) or remembered
	if remembered:
		ProjectSettings.save()


## Insert one surface at its alphabetical spot (entry + tile), keeping the live search filter
## applied to the newcomer so it doesn't ignore whatever is typed in the box.
func _insert_entry(entry_name: String, path: String, resource: Resource) -> void:
	var entry := {"name": entry_name, "path": path, "resource": resource, "tile": null}
	# The sorted insert starts PAST the pinned built-ins: adopting anything that sorts before
	# "Empty" would otherwise take the front tile from it.
	var first := 0
	while first < _entries.size() and _entries[first].get("builtin", false):
		first += 1
	var index := _entries.size()
	for i in range(first, _entries.size()):
		if entry_name.naturalnocasecmp_to(_entries[i].name) < 0:
			index = i
			break
	_entries.insert(index, entry)
	var tile := _make_tile(entry)
	_thumbs.add_child(tile)
	_thumbs.move_child(tile, index)
	var needle := _search.text.strip_edges().to_lower()
	tile.visible = needle == "" or entry_name.to_lower().contains(needle)


## Record `path` in the per-project loose list — the browser's only source. Returns whether the list
## changed; the caller batches the ProjectSettings.save(). The addon's own textures are never
## recorded (they're internal, never browser entries).
func _remember_loose(path: String) -> bool:
	if path.begins_with(ADDON_DIR):
		return false
	var loose := _loose_paths()
	if loose.has(path):
		return false
	loose.append(path)
	ProjectSettings.set_setting(LOOSE_SETTING, loose)
	return true


func _loose_paths() -> PackedStringArray:
	var stored = ProjectSettings.get_setting(LOOSE_SETTING, PackedStringArray())
	if stored is PackedStringArray:
		return stored
	if stored is Array:   # hand-edited project.godot can store a plain array; accept it
		return PackedStringArray(stored)
	return PackedStringArray()


func _on_search_changed(text: String) -> void:
	var needle := text.strip_edges().to_lower()
	for entry in _entries:
		if entry.tile != null:
			entry.tile.visible = needle == "" or entry.name.to_lower().contains(needle)


func _on_texture_pressed(surface: Resource) -> void:
	surface_chosen.emit(surface)


## A left-click that reached the browser background (not a tile) clears the active texture.
func _on_browser_empty_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		texture_deselected.emit()


# --- Per-texture context menu ----------------------------------------------

func _build_context_menu() -> void:
	_context_menu = PopupMenu.new()
	_context_menu.add_item("Select Faces", CTX_SELECT_FACES)
	_context_menu.add_item("Select Brushes", CTX_SELECT_BRUSHES)
	_context_menu.add_item("Replace with…", CTX_REPLACE)
	_context_menu.add_separator()
	_context_menu.add_item("Copy Name", CTX_COPY_NAME)
	_context_menu.add_item("Remove from Browser", CTX_REMOVE)
	# Display the Delete shortcut next to Remove; the tile handles the actual key (see _on_tile_input),
	# and this accelerator also fires it while the menu itself is open.
	_context_menu.set_item_accelerator(_context_menu.get_item_index(CTX_REMOVE), KEY_DELETE)
	_context_menu.id_pressed.connect(_on_context_id)
	add_child(_context_menu)


## Catch a right-click on a tile (open the context menu) or Delete while it's focused (remove it,
## the keyboard shortcut for the menu's Remove). Delete is ignored for in-use textures, matching the
## menu's disabled state — the in-use pass would only re-adopt them.
func _on_tile_input(event: InputEvent, tile: TextureIcon, entry: Dictionary) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_show_context_menu(entry, tile.get_screen_position() + event.position)
	elif event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_DELETE and not _in_use.has(entry.resource) \
			and not entry.get("builtin", false):
		tile.accept_event()
		_remove_entry(entry)


## Open the menu for `entry`, greying out the actions that don't apply. Select/Replace need the
## texture to actually be used somewhere; Remove is pointless while it's in use (the in-use pass
## would re-adopt it on the next sync), so the two sets are mutually exclusive.
func _show_context_menu(entry: Dictionary, screen_pos: Vector2) -> void:
	_context_entry = entry
	var in_use := _in_use.has(entry.resource)
	_context_menu.set_item_disabled(_context_menu.get_item_index(CTX_SELECT_FACES), not in_use)
	_context_menu.set_item_disabled(_context_menu.get_item_index(CTX_SELECT_BRUSHES), not in_use)
	_context_menu.set_item_disabled(_context_menu.get_item_index(CTX_REPLACE), not in_use)
	# A built-in entry ships with the addon rather than being a per-project path, so there is
	# nothing to forget and no way to get it back — Remove stays greyed out whatever its use.
	_context_menu.set_item_disabled(_context_menu.get_item_index(CTX_REMOVE),
		in_use or entry.get("builtin", false))
	_context_menu.reset_size()
	_context_menu.position = Vector2i(screen_pos)
	_context_menu.popup()


func _on_context_id(id: int) -> void:
	if _context_entry == null:
		return
	var entry: Dictionary = _context_entry
	match id:
		CTX_SELECT_FACES:
			select_faces_requested.emit(entry.resource)
		CTX_SELECT_BRUSHES:
			select_brushes_requested.emit(entry.resource)
		CTX_REPLACE:
			_open_replace_picker(entry)
		CTX_COPY_NAME:
			DisplayServer.clipboard_set(entry.name)
		CTX_REMOVE:
			_remove_entry(entry)


## Drop a texture from the browser: free its tile, forget its entry, and stop remembering its path
## in the per-project loose list. Only offered for textures NOT in use (see _show_context_menu), so
## the in-use pass won't immediately re-adopt it.
func _remove_entry(entry: Dictionary) -> void:
	if entry.get("builtin", false):
		return      # backstop: the menu and the Delete key both refuse it already
	var idx := _entries.find(entry)
	if idx == -1:
		return
	if entry.tile != null:
		entry.tile.queue_free()
	_entries.remove_at(idx)
	if _forget_loose(entry.path):
		ProjectSettings.save()


func _forget_loose(path: String) -> bool:
	var loose := _loose_paths()
	var i := loose.find(path)
	if i == -1:
		return false
	loose.remove_at(i)
	ProjectSettings.set_setting(LOOSE_SETTING, loose)
	return true


# --- "Replace with Texture" picker -----------------------------------------

## A throwaway popup listing every OTHER browser texture; clicking one swaps every use of the
## source texture for it across the map (the plugin does the actual replace, with undo). Built fresh
## each time and freed on close — the browser is small and this keeps it trivially in sync.
func _open_replace_picker(source: Dictionary) -> void:
	var popup := PopupPanel.new()
	popup.title = "Replace \"%s\" with…" % source.name
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	popup.add_child(vbox)

	var heading := Label.new()
	heading.text = "Replace \"%s\" with:" % source.name
	vbox.add_child(heading)

	var search := LineEdit.new()
	search.placeholder_text = "Search"
	search.clear_button_enabled = true
	vbox.add_child(search)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	var flow := HFlowContainer.new()
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(flow)

	var picker_tiles: Array = []   # {tile, name} for the live search filter
	for entry in _entries:
		if entry.resource == source.resource:
			continue   # can't replace a surface with itself
		var tile := TextureIconScene.instantiate() as TextureIcon
		_apply_tile_thumbnail(tile, entry.resource, entry.name)
		tile.set_in_use(_in_use.has(entry.resource))
		tile.pressed.connect(_pick_replacement.bind(popup, source.resource, entry.resource))
		flow.add_child(tile)
		picker_tiles.append({"tile": tile, "name": entry.name})

	search.text_changed.connect(func(text: String):
		var needle := text.strip_edges().to_lower()
		for t in picker_tiles:
			t.tile.visible = needle == "" or t.name.to_lower().contains(needle))

	add_child(popup)
	popup.popup_centered(Vector2i(380, 460))


func _pick_replacement(popup: PopupPanel, from_surface: Resource, to_surface: Resource) -> void:
	replace_texture_requested.emit(from_surface, to_surface)
	popup.hide()
	popup.queue_free()


## Drive each tile's outline: red for the active/current surface (one at most), yellow for
## surfaces used in the scene. The tile itself gives red priority when both apply.
func _refresh_tiles() -> void:
	for entry in _entries:
		if entry.tile != null:
			entry.tile.set_selected(entry.resource == _active_surface)
			entry.tile.set_in_use(_in_use.has(entry.resource))
