@tool
extends RefCounted
## TrenchBroom .map clipboard. TrenchBroom copies brushes to the system clipboard as .map text, so
## CTRL+V here brings them in as real brushes — the fast path for grabbing prefabs or round-tripping
## a shape through TB — and CTRL+C copies the selection back out. Entity wrappers (worldspawn,
## func_detail, …) are flattened away; Godot has no Quake entities, only brushes.
##
## Owned by the Duckboard plugin, reached through `host` for the selection, the paste camera framing,
## the grid size and brush replacement. Parsing/serialising lives in io/map_io.gd.

const MapIO := preload("res://addons/duckboard/io/map_io.gd")

## Search order for resolving a .map texture NAME to a project texture. Anything unresolved (a name
## from a wad we don't have) falls back to the brush's default texture. The addon's own textures dir
## is included so TrenchBroom's __TB_empty resolves to OUR empty default rather than staying null.
const _MAP_TEX_DIRS := ["res://textures/", "res://textures/special/", "res://textures/other/",
	"res://addons/duckboard/textures/"]
const _MAP_TEX_EXTS := ["png", "jpg", "jpeg", "webp", "tga", "bmp"]

var host: Duckboard


func _init(p_host: Duckboard) -> void:
	host = p_host


## Paste clipboard brushes in TrenchBroom's .map format. Returns false — claiming nothing, so a plain
## CTRL+V still reaches the editor — when the clipboard holds no parseable brush.
func paste() -> bool:
	var text := DisplayServer.clipboard_get()
	if text.strip_edges().is_empty():
		return false
	# Grouped, not flat: an entity in the paste — a TrenchBroom group, or a func_detail / door /
	# trigger, all of which are one object over there — comes in as one Duckboard group. See
	# MapIO.parse_solids for how TB's nesting flattens into our single level.
	var parsed := MapIO.parse_solids(text)
	var blueprints := _blueprints_for(parsed["loose"])
	var groups: Array = []
	for g in parsed["groups"]:
		var members := _blueprints_for(g["brushes"])
		if not members.is_empty():
			groups.append({"name": g["name"], "blueprints": members})
	if blueprints.is_empty() and groups.is_empty():
		return false
	# Drop the paste in front of the camera, framed to fit, rather than at its original TB world
	# coordinates (usually far from wherever you're looking). The move is SNAPPED to the grid — a
	# whole number of cells — so geometry that came in grid-aligned (TrenchBroom's does) stays
	# aligned instead of being nudged off by the camera-relative offset.
	#
	# Framed over EVERYTHING the paste carries, grouped and loose alike, and every piece then shifted
	# by that one translation — framing each group on its own would scatter a copy that was laid out
	# as one scene across the viewport.
	if is_instance_valid(host._last_camera):
		var b := MapIO.bounds(MapIO.parse(text))
		var half_fov := deg_to_rad(host._last_camera.fov) * 0.5
		var dist: float = maxf(b.radius / maxf(sin(half_fov), 0.01) * 1.1, b.radius + 2.0)
		var forward := -host._last_camera.global_transform.basis.z
		var target: Vector3 = host._last_camera.global_position + forward * dist
		var t: Vector3 = target - b.center
		var g := host.grid_size
		t = Vector3(snappedf(t.x, g), snappedf(t.y, g), snappedf(t.z, g))
		_translate_blueprints(blueprints, t)
		for group in groups:
			_translate_blueprints(group["blueprints"], t)
	host._replace_brushes([], blueprints, "Paste TrenchBroom Brushes", groups)
	return true


## A list of raw parsed brushes turned into the {plane, u, v, offset, tex, material} blueprints the
## brush core consumes. Brushes that convert to nothing (fewer than four usable planes) drop out.
func _blueprints_for(raw_brushes: Array) -> Array:
	var size_for := func(tex_name: String) -> Vector2: return _map_texture_size(tex_name)
	var tex_for := func(tex_name: String) -> Texture2D: return _map_texture(tex_name)
	var out: Array = []
	for faces in raw_brushes:
		var bp := MapIO.brush_to_blueprint(faces, size_for, tex_for)
		if not bp.is_empty():
			out.append(bp)
	return out


## Slide every blueprint face by a world translation, keeping textures glued to the faces: the plane
## rides along (d += n·t) and the UV offset absorbs the shift (off -= (t·u, t·v)) — the same identity
## the brush's own texture lock applies for a move, so the paste keeps its look wherever it lands.
func _translate_blueprints(blueprints: Array, t: Vector3) -> void:
	if t.length_squared() < 1e-12:
		return
	for bp in blueprints:
		for f in bp:
			var n: Vector3 = f["plane"].normal
			f["plane"] = Plane(n, f["plane"].d + n.dot(t))
			f["offset"] = f["offset"] - Vector2(t.dot(f["u"]), t.dot(f["v"]))


## A .map texture name resolved to a project texture. Names are wad-relative and extensionless, so we
## probe the usual texture folders. Unresolved names fall back to the brush's DEFAULT_TEXTURE rather
## than null: set_world_faces stores the texture verbatim (unlike set_face_texture, which maps null →
## default), so a null here would render blank faces. This is also what makes __TB_empty come through.
func _map_texture(tex_name: String) -> Texture2D:
	for dir in _MAP_TEX_DIRS:
		for ext in _MAP_TEX_EXTS:
			var path: String = str(dir) + tex_name + "." + str(ext)
			if ResourceLoader.exists(path):
				return load(path) as Texture2D
	return Brush.DEFAULT_TEXTURE


## Texel size of a resolved .map texture, for the UV conversion; the Valve-220 default when unknown.
func _map_texture_size(tex_name: String) -> Vector2:
	var tex := _map_texture(tex_name)
	return tex.get_size() if tex != null else MapIO.DEFAULT_TEX_SIZE


## Copy the selected brushes to the clipboard as TrenchBroom .map text (Valve 220), so a shape can be
## pasted into TrenchBroom or back into Duckboard. Returns false — claiming nothing — when the
## selection holds no brush, so a plain CTRL+C still reaches the editor.
func copy() -> bool:
	var brushes := host._selected_brushes()
	var selected_groups := host._selected_groups()
	if brushes.is_empty() and selected_groups.is_empty():
		return false
	var out: Array = []
	for b in brushes:
		var faces := _solid_to_map(b.world_faces())
		if not faces.is_empty():
			out.append(faces)
	# A selected group travels as a group: one func_group entity holding its members, so TrenchBroom
	# receives the thing you copied rather than a pile of loose brushes it would make you re-group.
	# Members are read as world solids, which is the same payload Ungroup hands to the brush core.
	var groups: Array = []
	for group in selected_groups:
		var members: Array = []
		for member in group.world_members():
			var faces := _solid_to_map(member)
			if not faces.is_empty():
				members.append(faces)
		if not members.is_empty():
			groups.append({"name": String(group.name), "brushes": members})
	if out.is_empty() and groups.is_empty():
		return false
	DisplayServer.clipboard_set(MapIO.to_map(out, groups))
	return true


## One solid's world_faces() payload in the shape MapIO.to_map writes. Empty for anything that does
## not bound a solid — four faces is the minimum, and a serialised three-sided "brush" is nothing a
## reader could rebuild.
func _solid_to_map(world_faces: Array) -> Array:
	var faces: Array = []
	for wf in world_faces:
		var tex: Texture2D = wf["tex"]   # material faces sync this to their albedo, so it covers both
		faces.append({
			"points": wf["points"],
			"normal": wf["plane"].normal,
			"u": wf["u"], "v": wf["v"], "offset": wf["offset"],
			"tex": _map_texture_name(tex),
			"size": tex.get_size() if tex != null else MapIO.DEFAULT_TEX_SIZE,
		})
	return faces if faces.size() >= 4 else []


## A texture resolved back to a wad-style .map name — its file basename, or __TB_empty for the default
## (or an in-memory texture with no path). The inverse of _map_texture's name lookup.
func _map_texture_name(tex: Texture2D) -> String:
	if tex == null or tex == Brush.DEFAULT_TEXTURE:
		return "__TB_empty"
	var path := tex.resource_path
	return path.get_file().get_basename() if not path.is_empty() else "__TB_empty"
