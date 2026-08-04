@tool
class_name BrushPiece
extends RefCounted
## ONE convex piece of a [Brush]: the brush it belongs to, paired with which piece it is.
##
## [b]What a tool holds, and it says so.[/b] A geometry tool works on one convex solid at a time — it
## drags a vertex, solves a hull, clips a half-space — and a [Brush] may be several. It therefore
## needs two things at once that nothing else carries together: the piece's geometry, which lives in
## a [BrushData] that deliberately knows nothing about transforms, and the brush's pose, which the
## piece cannot supply. This is that pair, and nothing more.
##
## [b]It is NOT a stand-in for a Brush.[/b] The alternative it replaced — a hidden scratch [Brush]
## node per member — worked by being indistinguishable from a real brush, which is exactly what made
## it hard to reason about. Tool code names these `piece`, never `node`, so what is being held is
## legible at the call site. The methods share names with [Brush] only where the operation genuinely
## IS the same operation: `get_vertices` on a convex solid means one thing.
##
## [b]It replaces the scratch NODES this used to need.[/b] A group used to materialize a hidden,
## unowned [Brush] per member so the tools had something node-shaped to hold — which meant real nodes
## appearing and disappearing in the scene tree, `duplicate()` carrying stale ones into copies, a
## reference-counting pass to free the idle ones, and an undo record pointing at scratch that had to
## be folded back into the group afterwards. None of that is needed to name a piece.
##
## [b]Identity is stable[/b], which the tools depend on: a drag stores handles at the press and reads
## them again at the release, and the face selection holds {node, face} pairs compared by identity
## across frames. [method Brush.piece] therefore caches one handle per index and hands back the same
## instance until the geometry changes. Never construct one directly — ask the brush.
##
## [b]Everything world-space goes through the brush's transform.[/b] A piece's planes and polygons are
## in the brush's LOCAL frame, exactly as a lone brush's are, so a tool that multiplies by
## [member global_transform] gets the right answer without knowing which of the two it is holding.

## The brush this piece belongs to — where the transform comes from, and the node an undo record has
## to name, since a piece is not a node and cannot be one.
var brush: Brush

## Which piece of [member brush] this is. Indexes [code]Brush.pieces[/code].
var index := 0


func _init(p_brush: Brush, p_index: int) -> void:
	brush = p_brush
	index = p_index


## The piece's geometry. Null only if the brush lost the piece under us, which the caller should
## treat exactly as a freed node: skip it.
func data() -> BrushData:
	return brush.piece_data(index)


func is_alive() -> bool:
	return is_instance_valid(brush) and index < brush.piece_count()


# --- The brush-shaped surface the tools call ------------------------------
#
# Deliberately the same names and signatures a [Brush] carries. A tool holding one of these is not
# supposed to be able to tell the difference, and that is what keeps `tools/` free of any notion of
# pieces at all.

var global_transform: Transform3D:
	get:
		return brush.global_transform if is_instance_valid(brush) else Transform3D.IDENTITY

## Writable, and it moves the whole SOLID — a piece has no origin of its own, the node owns it. The
## transform tools set this once per entry from a per-solid starting position, so every piece of one
## solid asks for the same answer and the repeats are idempotent.
var global_position: Vector3:
	get:
		return brush.global_position if is_instance_valid(brush) else Vector3.ZERO
	set(value):
		if is_instance_valid(brush):
			brush.global_position = value

## The three node-level settings the tools read off whatever they are handed. They belong to the
## solid, not to any one piece, so they simply forward — a tool asking "is texture lock on for this
## geometry?" means the brush the geometry lives in.
var texture_lock: bool:
	get:
		return is_instance_valid(brush) and brush.texture_lock

var uv_lock: bool:
	get:
		return is_instance_valid(brush) and brush.uv_lock

## Whether the geometry is REAL — the tools skip unowned nodes, which are previews and scratch.
var owner: Node:
	get:
		return brush.owner if is_instance_valid(brush) else null

var planes: Array[Plane]:
	get:
		return data().planes
	set(value):
		data().planes = value
		brush.piece_changed()

var face_data: Dictionary:
	get:
		return data().face_data
	set(value):
		if value.is_empty():
			return
		data().face_data = value
		brush.piece_changed()


func get_vertices() -> PackedVector3Array:
	return data().get_vertices()


func get_edges() -> PackedVector3Array:
	return data().get_edges()


func face_polygon(face: int) -> PackedVector3Array:
	return data().face_polygon(face)


func face_center(face: int) -> Vector3:
	return data().face_center(face)


func weld_sq() -> float:
	return data().weld_sq()


## See [method Brush.set_from_points] — the snap is measured in WORLD space, which is why the brush's
## pose goes down with it.
func set_from_points(points: PackedVector3Array, snap := true) -> void:
	data().set_from_points(points, snap, global_transform)
	brush.piece_changed()


func cross_section(plane: Plane) -> PackedVector3Array:
	return data().cross_section(plane)


func clip_by(plane: Plane) -> bool:
	if not data().clip_by(plane):
		return false
	brush.piece_changed()
	return true


## What a cut face on THIS piece would look like — the piece-level half of
## [method Brush.cut_face_mapping], for the clip preview.
func cut_face_mapping(plane: Plane):
	var d := data()
	var donor := d.donor_face(plane)
	if donor < 0 or donor >= d.face_count():
		return null
	return {"material": Brush._material_for(d.face_texture(donor)),
		"u": d.face_axis_u(donor), "v": d.face_axis_v(donor), "offset": d.face_offset(donor)}


## World-space faces of THIS piece, at the brush's pose.
func world_faces() -> Array:
	return data().world_faces(global_transform)


func world_face(face: int) -> Dictionary:
	return data().world_face(face, global_transform)


# --- Per-face surface, forwarded ------------------------------------------
#
# The host reaches these through a face selection, whose entries name a piece and a face index. Each
# is the piece's own face, so they forward to the data and tell the brush to rebuild.

func face_surface(face: int) -> Resource:
	return data().face_surface(face)


func get_face_uv(face: int) -> Dictionary:
	return data().get_face_uv(face)


func face_local_polygon(face: int) -> PackedVector2Array:
	return data().face_local_polygon(face, global_transform)


func face_uv_polygon(face: int) -> PackedVector2Array:
	return data().face_uv_polygon(face, global_transform)


func set_face_texture(face: int, tex: Texture2D) -> void:
	data().set_face_texture(face, tex)
	brush.piece_changed()


func set_face_material(face: int, mat: Material) -> void:
	data().set_face_material(face, mat)
	brush.piece_changed()


func set_face_offset(face: int, offset: Vector2) -> void:
	data().set_face_offset(face, offset)
	brush.mapping_changed()


func set_face_uv(face: int, offset: Vector2, scale: Vector2, angle_deg: float) -> void:
	data().set_face_uv(face, offset, scale, angle_deg)
	brush.mapping_changed()


func copy_face_uv_from(src, src_face: int, dst: int, mode: String) -> void:
	data().copy_face_uv_from(src.data(), src_face, dst, mode, src.global_transform, global_transform)
	brush.mapping_changed()


func reset_face_uv(face: int) -> void:
	data().reset_face_uv(face)
	brush.mapping_changed()


func world_align_face_uv(face: int) -> void:
	data().world_align_face_uv(face)
	brush.mapping_changed()


func fit_face_uv(face: int) -> void:
	data().fit_face_uv(face, global_transform)
	brush.mapping_changed()


func flip_face_u(face: int) -> void:
	data().flip_face_u(face)
	brush.mapping_changed()


func flip_face_v(face: int) -> void:
	data().flip_face_v(face)
	brush.mapping_changed()


func rotate_face_uv(face: int, degrees: float) -> void:
	data().rotate_face_uv(face, degrees)
	brush.mapping_changed()


func set_face_angle_about(face: int, angle_deg: float, pivot_uv: Vector2) -> void:
	data().set_face_angle_about(face, angle_deg, pivot_uv, global_transform)
	brush.mapping_changed()


func set_face_scale_about(face: int, scale: Vector2, pivot_uv: Vector2) -> void:
	data().set_face_scale_about(face, scale, pivot_uv, global_transform)
	brush.mapping_changed()


## Node-shaped questions the host asks of whatever a selection entry holds. Answered by the brush,
## because they are about where the geometry LIVES rather than about the geometry.

## THIS piece's local bounds, in the shape [Brush.get_aabb] answers — the host's bounds
## helpers ask it of whatever they are handed. Deliberately the piece's own box and not the
## solid's: a scale or shear handle sized to the whole group would not frame the piece it is on.
func get_aabb() -> AABB:
	if not is_instance_valid(brush):
		return AABB()
	# THIS piece's box alone, off the brush's cached face payloads — the hover paths ask per piece
	# per mouse motion, so measuring every sibling here would square the cost for nothing.
	var faces: Array = brush._local_faces()
	return Brush.Csg.bounds_of(faces[index]) if index < faces.size() else AABB()


func get_parent() -> Node:
	return brush.get_parent() if is_instance_valid(brush) else null


func is_inside_tree() -> bool:
	return is_instance_valid(brush) and brush.is_inside_tree()


func _to_string() -> String:
	return "BrushPiece(%s#%d)" % [brush.name if is_instance_valid(brush) else "<freed>", index]
