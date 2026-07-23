@tool
extends RefCounted
## TrenchBroom's Edit -> CSG: Convex Merge / Subtract / Hollow / Intersect, as a dropdown at the foot
## of the left tool palette. The palette owns and styles the button (see tool_palette `_build_csg_button`);
## this fills its popup and runs the ops, so all the CSG behaviour stays in one place. The geometry
## lives in csg.gd; this is the editor glue (selection, menu state, undo-backed replacement).
##
## Owned by the Duckboard plugin, reached through `host` for the selection, the palette, the grid size
## and the shared brush-replacement step (host._replace_brushes, also used by paste).

const Csg := preload("res://addons/duckboard/csg.gd")

const CSG_MERGE := 0
const CSG_SUBTRACT := 1
const CSG_HOLLOW := 2
const CSG_INTERSECT := 3

var host: Duckboard
var _popup: PopupMenu


func _init(p_host: Duckboard) -> void:
	host = p_host


func build_menu() -> void:
	_popup = host._palette.get_csg_popup()
	_popup.add_item("Convex Merge", CSG_MERGE)
	_popup.add_item("Subtract", CSG_SUBTRACT)
	_popup.add_item("Hollow", CSG_HOLLOW)
	_popup.add_item("Intersect", CSG_INTERSECT)
	_popup.id_pressed.connect(_on_menu)


## Grey out items the selection can't satisfy: Merge needs two brushes OR exactly two faces (the
## face-bridge), Intersect two brushes, Subtract and Hollow at least one brush. Keeps the menu honest
## instead of failing silently on click.
func update_menu() -> void:
	if not is_instance_valid(_popup):
		return
	var count := host._selected_brushes().size()
	var can_bridge := host._selected_faces.size() == 2
	# One brush already feeds Subtract/Hollow, and two selected faces feed Merge, so the button is live
	# from either; with neither, no op can run, so grey the whole button rather than open a dead menu.
	if is_instance_valid(host._palette):
		host._palette.set_csg_enabled(count >= 1 or can_bridge)
	_popup.set_item_disabled(_popup.get_item_index(CSG_MERGE), count < 2 and not can_bridge)
	_popup.set_item_disabled(_popup.get_item_index(CSG_SUBTRACT), count < 1)
	_popup.set_item_disabled(_popup.get_item_index(CSG_HOLLOW), count < 1)
	_popup.set_item_disabled(_popup.get_item_index(CSG_INTERSECT), count < 2)


func _on_menu(id: int) -> void:
	match id:
		CSG_MERGE: merge()
		CSG_SUBTRACT: subtract()
		CSG_HOLLOW: hollow()
		CSG_INTERSECT: intersect()


## Merge every selected brush into their single convex hull — or, when the selection is exactly two
## faces instead of whole brushes, bridge those two faces into a new brush (see bridge_faces).
func merge() -> void:
	if host._selected_faces.size() == 2:
		bridge_faces()
		return
	var brushes := host._selected_brushes()
	if brushes.size() < 2:
		return
	var solids := brushes.map(func(b): return b.world_faces())
	var blueprints := Csg.convex_merge(solids)
	if blueprints.is_empty():
		push_warning("Duckboard: Convex Merge produced nothing.")
		return
	host._replace_brushes(brushes, blueprints, "CSG Convex Merge")


## Build a brush spanning the two selected faces (their convex hull). The two source brushes are left
## as they are — only a new brush is added. Coplanar faces bound no volume, so the hull is degenerate;
## rather than spawn a flat brush, report it and do nothing.
func bridge_faces() -> void:
	if host._selected_faces.size() != 2:
		return
	var a: Dictionary = host._selected_faces[0]
	var b: Dictionary = host._selected_faces[1]
	if not is_instance_valid(a.node) or not is_instance_valid(b.node):
		return
	var face_a: Dictionary = a.node.world_face(a.face)
	var face_b: Dictionary = b.node.world_face(b.face)
	var blueprints := Csg.bridge_faces(face_a, face_b)
	if blueprints.is_empty():
		push_warning("Duckboard: those two faces are coplanar — no brush can be built between them.")
		return
	host._replace_brushes([], blueprints, "CSG Bridge Faces")


## Keep only the volume common to every selected brush. Aborts (leaving the brushes) when they
## don't all overlap, rather than deleting them into an empty result.
func intersect() -> void:
	var brushes := host._selected_brushes()
	if brushes.size() < 2:
		return
	var solids := brushes.map(func(b): return b.world_faces())
	var blueprints := Csg.intersect(solids)
	if blueprints.is_empty():
		push_warning("Duckboard: the selected brushes don't overlap — nothing to intersect.")
		return
	host._replace_brushes(brushes, blueprints, "CSG Intersect")


## Subtract the selected brushes from every OTHER brush they touch. The others are replaced by
## their carved fragments; the selected (subtrahend) brushes are removed, as TrenchBroom does.
func subtract() -> void:
	var subtrahends := host._selected_brushes()
	if subtrahends.is_empty():
		return
	var sub_solids := subtrahends.map(func(b): return b.world_faces())
	# Every other brush that shares volume with any subtrahend is a target.
	var targets: Array[Node3D] = []
	for other in _all_scene_brushes():
		if other in subtrahends:
			continue
		var other_solid: Array = other.world_faces()
		for s in sub_solids:
			if Csg.overlaps(other_solid, s):
				targets.append(other)
				break
	if targets.is_empty():
		push_warning("Duckboard: nothing in contact with the selection to subtract from.")
		return
	# Carve each target by all subtrahends; collect every surviving fragment.
	var blueprints: Array = []
	for target in targets:
		blueprints.append_array(Csg.subtract(target.world_faces(), sub_solids))
	# The subtrahends are consumed too, so they go in the removal list alongside the carved targets.
	var removed: Array[Node3D] = targets.duplicate()
	removed.append_array(subtrahends)
	host._replace_brushes(removed, blueprints, "CSG Subtract")


## Turn each selected brush into a shell of walls one grid cell thick.
func hollow() -> void:
	var brushes := host._selected_brushes()
	if brushes.is_empty():
		return
	var thickness := host._cell_meters()
	var blueprints: Array = []
	for b in brushes:
		blueprints.append_array(Csg.hollow(b.world_faces(), thickness))
	if blueprints.is_empty():
		push_warning("Duckboard: Hollow produced nothing.")
		return
	host._replace_brushes(brushes, blueprints, "CSG Hollow")


## Every Brush in the edited scene (excluding the unowned hull/clip previews, which live at the root).
func _all_scene_brushes() -> Array[Node3D]:
	var out: Array[Node3D] = []
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return out
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if node is Brush and node != host._hull_preview and node != host._push_preview \
				and node != host._clip_preview and node.owner != null:
			out.append(node)
	return out
