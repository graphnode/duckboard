@tool
extends RefCounted
## Read (and later write) the Quake `.map` brush format TrenchBroom uses for its clipboard, so shapes
## copy straight between TrenchBroom and Duckboard. Pure text↔geometry, no scene knowledge: parse()
## turns pasted text into raw faces, brush_to_blueprint() turns one brush's faces into the same
## {plane, u, v, offset, tex, material} blueprint the CSG core produces, and the plugin builds nodes
## from it exactly as it does for CSG results.
##
## Only the Valve 220 face form is handled — the one TrenchBroom writes ("mapversion" "220"): each
## face carries EXPLICIT world-space U/V axes, which is precisely our per-face model (see the note on
## Brush.copy_face_uv_from — our face_data IS TB's parallel/Valve-220 system). The older Standard form
## (no axes, paraxial) isn't emitted by a 220 copy, so it's out of scope.

const UNITS_PER_METER := 32.0        ## 32 TB units == 1 Godot metre.
const DEFAULT_TEX_SIZE := Vector2(64, 64)   ## Assumed texel size when a texture can't be resolved.

## One number: optional sign, digits, decimal, exponent. Kept narrow so it can't swallow a bracket
## or paren the way \S+ would.
const _NUM := "\\s*([-+0-9.eE]+)"
## A full Valve-220 face line: three points, texture, [U axis + offset], [V axis + offset], rot sx sy.
## Groups 1-9 points, 10 texture, 11-14 U, 15-18 V, 19 rot, 20 sx, 21 sy.
const _FACE_RE := "^\\(" + _NUM + _NUM + _NUM + "\\s*\\)\\s*\\(" + _NUM + _NUM + _NUM \
	+ "\\s*\\)\\s*\\(" + _NUM + _NUM + _NUM + "\\s*\\)\\s+(\\S+)" \
	+ "\\s*\\[" + _NUM + _NUM + _NUM + _NUM + "\\s*\\]" \
	+ "\\s*\\[" + _NUM + _NUM + _NUM + _NUM + "\\s*\\]" + _NUM + _NUM + _NUM


# --- Coordinate conversion (TB Z-up <-> Godot Y-up) ------------------------
# A right-handed rotation sending TB's up (Z) onto Godot's up (Y): (x, y, z) -> (x, z, -y). Points
# additionally scale by 1/32; directions (axes, normals) rotate only.

static func _tb_to_godot_dir(v: Vector3) -> Vector3:
	return Vector3(v.x, v.z, -v.y)


static func _godot_to_tb_dir(v: Vector3) -> Vector3:
	return Vector3(v.x, -v.z, v.y)


static func _tb_to_godot_point(v: Vector3) -> Vector3:
	return _tb_to_godot_dir(v) / UNITS_PER_METER


static func _godot_to_tb_point(v: Vector3) -> Vector3:
	return _godot_to_tb_dir(v) * UNITS_PER_METER


# --- Parse ----------------------------------------------------------------

## Every brush in the pasted text, flat, whatever entity carried it — each brush an Array of raw face
## dicts {p1, p2, p3 (Vector3, TB units), tex (String), u/v ([4 floats]), rot, sx, sy}. What a caller
## wants when only the GEOMETRY matters (framing a paste, measuring it); see [method parse_solids]
## for the form that keeps the grouping.
static func parse(text: String) -> Array:
	var out := []
	for e in parse_entities(text):
		out.append_array(e["brushes"])
	return out


## A key/value line inside an entity: `"classname" "func_group"`. Values may be empty, and anything
## that is not a face line and not this is simply not ours.
const _PROP_RE := "^\"([^\"]*)\"\\s+\"([^\"]*)\""


## Every ENTITY in the pasted text, in file order, as {props: Dictionary, brushes: Array} — brushes
## being the same raw-face lists [method parse] returns. Loose top-level solids (a TrenchBroom copy of
## world geometry can be a bare `{ … }` with no entity around it) are pooled into one synthetic
## worldspawn entity, so no caller has to special-case them.
##
## A block-STACK classified by CONTENT, not by depth: a `{` may open an entity or a brush, and only
## what it gathered by its closing `}` says which. Four faces is the minimum that bounds a solid, so a
## block that collected that many IS a brush and anything else — key/values, an empty wrapper — is an
## entity. Entities never nest in .map (precisely why TrenchBroom links groups by `_tb_group` instead
## of nesting them), so the block under a brush is always the entity that owns it.
static func parse_entities(text: String) -> Array:
	var re := RegEx.new()
	re.compile(_FACE_RE)
	var prop_re := RegEx.new()
	prop_re.compile(_PROP_RE)
	var entities := []
	var world := {"props": {"classname": "worldspawn"}, "brushes": []}
	var stack: Array = []   # each entry: {props, brushes, faces} gathered in that open block
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with("//"):
			continue
		if line.begins_with("{"):
			stack.append({"props": {}, "brushes": [], "faces": []})
			continue
		if line.begins_with("}"):
			if stack.is_empty():
				continue
			var block: Dictionary = stack.pop_back()
			if block["faces"].size() >= 4:
				# A solid. It belongs to the block still open under it, or to the world when the
				# copy was a bare brush with no entity around it at all.
				if stack.is_empty():
					world["brushes"].append(block["faces"])
				else:
					stack.back()["brushes"].append(block["faces"])
			else:
				entities.append({"props": block["props"], "brushes": block["brushes"]})
			continue
		if stack.is_empty():
			continue        # a stray line outside any block (shouldn't happen in a valid paste)
		var f := _parse_face(line, re)
		if not f.is_empty():
			stack.back()["faces"].append(f)
			continue
		var m := prop_re.search(line)
		if m != null:
			stack.back()["props"][m.get_string(1)] = m.get_string(2)
	if not world["brushes"].is_empty():
		entities.append(world)
	return entities


## The paste split into what Duckboard actually builds: {loose: [brush, …], groups: [{name, brushes},
## …]}.
##
## Every entity that is not worldspawn and not a layer becomes ONE group — a TrenchBroom group, yes,
## but also a func_detail, a door or a trigger, because each of those is one object over there and a
## Duckboard group is what an object is over here.
##
## TrenchBroom NESTS groups; Duckboard's schema is deliberately flat, so a nested tree arrives as a
## single group. A .map file cannot nest entities either, which is what makes that easy: TB links a
## child to its parent with `_tb_group` = the parent's `_tb_id`, so flattening is walking that chain
## to its OUTERMOST group and pooling every descendant's solids there.
static func parse_solids(text: String) -> Dictionary:
	var entities := parse_entities(text)
	var index_by_id := {}
	for i in entities.size():
		var id := String(entities[i]["props"].get("_tb_id", ""))
		if not id.is_empty():
			index_by_id[id] = i
	var loose := []
	var groups := []
	var slot := {}          # owner entity index -> index into `groups`
	for i in entities.size():
		var owner := _outermost_group(entities, index_by_id, i)
		if owner < 0:
			loose.append_array(entities[i]["brushes"])
			continue
		if not slot.has(owner):
			slot[owner] = groups.size()
			groups.append({"name": _entity_name(entities[owner]["props"]), "brushes": []})
		groups[slot[owner]]["brushes"].append_array(entities[i]["brushes"])
	# A group that carried no solid at all — an empty TB group, or one holding only point entities,
	# which have no geometry for us to build — is dropped here rather than becoming an empty node.
	var kept := []
	for g in groups:
		if not g["brushes"].is_empty():
			kept.append(g)
	return {"loose": loose, "groups": kept}


## Is this entity plain world geometry rather than an object? worldspawn is — and so is a LAYER,
## which TrenchBroom also writes as a `func_group`: a layer organises a map, it is not a thing you
## pick up, so its brushes come in loose.
static func _entity_is_world(props: Dictionary) -> bool:
	if String(props.get("_tb_type", "")) == "_tb_layer":
		return true
	return String(props.get("classname", "worldspawn")) == "worldspawn"


## Index of the OUTERMOST non-world entity at or above `start`, or -1 when it sits in the world.
## The walk is capped and self-checked: `_tb_group` values come out of a file, and a cycle in them
## would otherwise hang the paste rather than fail it.
static func _outermost_group(entities: Array, index_by_id: Dictionary, start: int) -> int:
	var owner := -1
	var at := start
	for _hop in 32:
		if at < 0 or at >= entities.size():
			break
		var props: Dictionary = entities[at]["props"]
		if not _entity_is_world(props):
			owner = at
		var parent := String(props.get("_tb_group", ""))
		if parent.is_empty() or not index_by_id.has(parent):
			break
		var next: int = index_by_id[parent]
		if next == at:
			break
		at = next
	return owner


## What to call the node a group entity becomes: TrenchBroom's own group name if it has one, else the
## classname — so a pasted `func_detail` at least says in the scene tree what it came in as.
static func _entity_name(props: Dictionary) -> String:
	var out := String(props.get("_tb_name", ""))
	if out.is_empty():
		out = String(props.get("classname", ""))
	return out if not out.is_empty() else "BrushGroup"


static func _parse_face(line: String, re: RegEx) -> Dictionary:
	var m := re.search(line)
	if m == null:
		return {}
	var num := func(i: int) -> float: return m.get_string(i).to_float()
	return {
		"p1": Vector3(num.call(1), num.call(2), num.call(3)),
		"p2": Vector3(num.call(4), num.call(5), num.call(6)),
		"p3": Vector3(num.call(7), num.call(8), num.call(9)),
		"tex": m.get_string(10),
		"u": [num.call(11), num.call(12), num.call(13), num.call(14)],
		"v": [num.call(15), num.call(16), num.call(17), num.call(18)],
		"rot": num.call(19), "sx": num.call(20), "sy": num.call(21),
	}


# --- Convert one brush's faces to a Godot blueprint -----------------------

## Turn one brush's raw faces into a {plane, u, v, offset, tex, material} blueprint (world space,
## Godot units) — the same shape Brush.set_world_faces() consumes.
##
## Winding follows TrenchBroom's convention exactly: a face's outward normal is `cross(p3-p1, p2-p1)`.
## This is deterministic — NOT a centroid guess — which matters because a `.map` face's three points
## are arbitrary points ON the plane (often a unit apart), not the brush's corners; their average can
## fall OUTSIDE an angled solid and flip planes the wrong way, exploding the half-space intersection
## into a huge/unbounded brush. Our TB->Godot map is a proper rotation (det +1), so the same cross
## product on the converted points yields the correctly-oriented normal. UV: the Valve-220 texel
## mapping `dot(P_tb, axis)/scale + off` becomes our tile mapping `dot(P_godot, u) + offset` — one
## tile is one texture repeat, so the axis absorbs the 32 units/metre and the texel size, and the
## offset divides into tiles.
##
## `size_for(tex_name) -> Vector2` gives a texture's texel size (falls back to DEFAULT_TEX_SIZE);
## `tex_for(tex_name) -> Texture2D` resolves the surface (null when unresolved). Both optional — the
## plugin supplies them so this stays scene-free.
static func brush_to_blueprint(faces: Array, size_for := Callable(), tex_for := Callable()) -> Array:
	if faces.size() < 4:
		return []
	var out := []
	for f in faces:
		var a := _tb_to_godot_point(f["p1"])
		var b := _tb_to_godot_point(f["p2"])
		var c := _tb_to_godot_point(f["p3"])
		var normal := (c - a).cross(b - a)   # TrenchBroom winding: cross(p3-p1, p2-p1), points OUT
		if normal.length_squared() < 1e-12:
			continue   # three collinear points define no plane
		normal = normal.normalized()
		var plane := Plane(normal, normal.dot(a))

		var size := DEFAULT_TEX_SIZE
		if size_for.is_valid():
			var s: Vector2 = size_for.call(f["tex"])
			if s.x > 0.0 and s.y > 0.0:
				size = s
		var uarr: Array = f["u"]
		var varr: Array = f["v"]
		var au := _tb_to_godot_dir(Vector3(uarr[0], uarr[1], uarr[2]))
		var av := _tb_to_godot_dir(Vector3(varr[0], varr[1], varr[2]))
		var sx: float = f["sx"] if absf(f["sx"]) > 1e-6 else 1.0
		var sy: float = f["sy"] if absf(f["sy"]) > 1e-6 else 1.0
		var u := au * (UNITS_PER_METER / (sx * size.x))
		var v := av * (UNITS_PER_METER / (sy * size.y))
		var offset := Vector2(uarr[3] / size.x, varr[3] / size.y)
		var tex: Texture2D = tex_for.call(f["tex"]) if tex_for.is_valid() else null
		out.append({"plane": plane, "u": u, "v": v, "offset": offset, "tex": tex, "material": null})

	return out if out.size() >= 4 else []


# --- Write (Godot brushes -> .map text) -----------------------------------

## Serialise brushes to TrenchBroom's Valve-220 .map clipboard text, so a Duckboard selection can be
## pasted into TrenchBroom (or back into Duckboard). `brushes` is an Array of brushes; each brush is
## an Array of face dicts {points (PackedVector3Array, world Godot), normal (world outward), u, v
## (world axes), offset (tiles), tex (String name), size (Vector2 texels)}.
##
## `groups` is the same thing one level up — [{name: String, brushes: Array}] — and each entry writes
## as the `func_group` entity TrenchBroom reads back as a group, tagged `_tb_type` `_tb_group` and
## given the `_tb_id` a nested group would hang off. (Duckboard's groups never nest, so nothing ever
## does hang off it; the id is written because TB expects a group to carry one.)
##
## The worldspawn entity is emitted even with no loose brushes in it. It costs a pasting TrenchBroom
## nothing — worldspawn brushes merge into the world it already has, and an empty one contributes
## none — and it is what declares `mapversion 220` for the whole paste.
static func to_map(brushes: Array, groups: Array = []) -> String:
	var lines := PackedStringArray()
	lines.append("// entity 0")
	lines.append("{")
	lines.append("\"mapversion\" \"220\"")
	lines.append("\"classname\" \"worldspawn\"")
	_append_brushes(lines, brushes)
	lines.append("}")
	for gi in groups.size():
		lines.append("// entity %d" % (gi + 1))
		lines.append("{")
		lines.append("\"classname\" \"func_group\"")
		lines.append("\"_tb_type\" \"_tb_group\"")
		lines.append("\"_tb_name\" \"%s\"" % _quote_safe(String(groups[gi].get("name", "BrushGroup"))))
		lines.append("\"_tb_id\" \"%d\"" % (gi + 1))
		_append_brushes(lines, groups[gi].get("brushes", []))
		lines.append("}")
	return "\n".join(lines) + "\n"


static func _append_brushes(lines: PackedStringArray, brushes: Array) -> void:
	for bi in brushes.size():
		lines.append("// brush %d" % bi)
		lines.append("{")
		for f in brushes[bi]:
			lines.append(_face_to_line(f))
		lines.append("}")


## A name safe to sit inside a quoted .map value. A stray quote or newline would end the value early
## and turn every line after it into garbage — and a group's name is a NODE name, i.e. whatever the
## user typed in the Scene dock.
static func _quote_safe(s: String) -> String:
	return s.replace("\"", "'").replace("\n", " ").replace("\r", " ")


## One Valve-220 face line. The three plane points are ordered so TrenchBroom reads the outward
## normal (its normal is cross(p3-p1, p2-p1)); we pick the winding that agrees with the face's known
## normal, so it can't come out inverted. The world UV axes become unit TB axes plus a scale
## (sx = 32 / (|u| · texW)) and a texel offset (off · texW) — the exact inverse of the read path.
static func _face_to_line(f: Dictionary) -> String:
	var poly: PackedVector3Array = f["points"]
	var normal: Vector3 = f["normal"]
	var q0 := poly[0]
	var q1 := poly[1]
	var q2 := poly[2]
	# cross(q2-q0, q1-q0) is TB's normal for the emit order (q0, q1, q2); flip the last two points
	# when it faces inward so the written winding always points out.
	var e1 := q0
	var e2 := q1
	var e3 := q2
	if (q2 - q0).cross(q1 - q0).dot(normal) < 0.0:
		e2 = q2
		e3 = q1
	var size: Vector2 = f["size"]
	if size.x <= 0.0 or size.y <= 0.0:
		size = DEFAULT_TEX_SIZE
	var u: Vector3 = f["u"]
	var v: Vector3 = f["v"]
	var off: Vector2 = f["offset"]
	var lu := u.length()
	var lv := v.length()
	var au := _godot_to_tb_dir(u / lu) if lu > 1e-9 else Vector3.RIGHT
	var av := _godot_to_tb_dir(v / lv) if lv > 1e-9 else Vector3(0, 0, -1)
	var sx := UNITS_PER_METER / (lu * size.x) if lu > 1e-9 else 1.0
	var sy := UNITS_PER_METER / (lv * size.y) if lv > 1e-9 else 1.0
	return "%s %s %s %s [ %s %s %s %s ] [ %s %s %s %s ] 0 %s %s" % [
		_pt(e1), _pt(e2), _pt(e3), f["tex"],
		_n(au.x), _n(au.y), _n(au.z), _n(off.x * size.x),
		_n(av.x), _n(av.y), _n(av.z), _n(off.y * size.y),
		_n(sx), _n(sy)]


## Sub-unit precision the exported points are snapped to. Face vertices are re-derived by clipping
## large quads, which leaves ~0.001-unit float noise (−656 reads back as −656.0005); snapping this
## fine kills the noise so grid-aligned geometry writes clean integers, while never nudging any real
## feature (0.01 TB unit = 1/3200 m).
const POINT_SNAP := 0.01

## A world point as a TB "( x y z )" triple, snapped to POINT_SNAP so clipping noise doesn't leak in.
static func _pt(p: Vector3) -> String:
	var t := _godot_to_tb_point(p).snapped(Vector3.ONE * POINT_SNAP)
	return "( %s %s %s )" % [_n(t.x), _n(t.y), _n(t.z)]


## Compact number: up to 6 decimals, with a trailing ".0" (and any trailing zeros) dropped so whole
## numbers write bare — "57.0" -> "57", "1.060660" -> "1.06066". The "." guard keeps a bare integer
## from having its own digits stripped, and negative zero normalises to "0".
static func _n(x: float) -> String:
	var s := String.num(x, 6)
	if s.contains("."):
		s = s.rstrip("0").rstrip(".")
	if s == "-0":
		s = "0"
	return s


## Centre and bounding radius (Godot space, metres) of a parsed brush set — for framing a paste in
## the viewport. Uses the face-defining points, which sit on the solids' surfaces, so the centre is a
## fair middle and the radius covers the whole paste.
static func bounds(brushes: Array) -> Dictionary:
	var pts := PackedVector3Array()
	for faces in brushes:
		for f in faces:
			pts.append(_tb_to_godot_point(f["p1"]))
			pts.append(_tb_to_godot_point(f["p2"]))
			pts.append(_tb_to_godot_point(f["p3"]))
	if pts.is_empty():
		return {"center": Vector3.ZERO, "radius": 0.0}
	var center := Vector3.ZERO
	for p in pts:
		center += p
	center /= float(pts.size())
	var radius := 0.0
	for p in pts:
		radius = maxf(radius, center.distance_to(p))
	return {"center": center, "radius": radius}
