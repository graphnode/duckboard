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
	var solids := host._selected_solids()
	var count := solids.size()
	# Merge and Subtract read a selected group as its pieces; Intersect and Hollow have no honest
	# answer for one (a group is a UNION of convex pieces, and both ops are defined on a convex
	# solid), so they grey rather than quietly act on the first piece.
	var has_group := false
	for b in solids:
		if b.is_group():
			has_group = true
			break
	var can_bridge := host._selected_faces.size() == 2
	# One brush already feeds Subtract/Hollow, and two selected faces feed Merge, so the button is live
	# from either; with neither, no op can run, so grey the whole button rather than open a dead menu.
	if is_instance_valid(host._palette):
		host._palette.set_csg_enabled(count >= 1 or can_bridge)
	_popup.set_item_disabled(_popup.get_item_index(CSG_MERGE), count < 2 and not can_bridge)
	_popup.set_item_disabled(_popup.get_item_index(CSG_SUBTRACT), count < 1)
	_popup.set_item_disabled(_popup.get_item_index(CSG_HOLLOW), count < 1 or has_group)
	_popup.set_item_disabled(_popup.get_item_index(CSG_INTERSECT), count < 2 or has_group)


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
	var brushes := host._selected_solids()
	if brushes.size() < 2:
		return
	# Flattened to convex pieces: a selected group merges as its members — the hull of everything —
	# where asking the node facade would take its first piece and quietly drop the rest.
	var solids := []
	for b in brushes:
		solids.append_array(b.world_pieces())
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
	# _entry_live, not is_instance_valid: a face entry holds a BrushPiece, which stays a valid
	# RefCounted after the brush behind it is freed.
	if not host._entry_live(a.node) or not host._entry_live(b.node):
		return
	var face_a: Dictionary = a.node.world_face(a.face)
	var face_b: Dictionary = b.node.world_face(b.face)
	var blueprints := Csg.bridge_faces(face_a, face_b)
	if blueprints.is_empty():
		push_warning("Duckboard: those two faces are coplanar; no brush can be built between them.")
		return
	host._replace_brushes([], blueprints, "CSG Bridge Faces")


## Keep only the volume common to every selected brush. Aborts (leaving the brushes) when they
## don't all overlap, rather than deleting them into an empty result.
func intersect() -> void:
	var brushes := host._selected_solids()
	if brushes.size() < 2:
		return
	for b in brushes:
		if b.is_group():
			# A group is a UNION of pieces and the intersection of unions is not a per-piece
			# question — refused (and greyed in the menu) rather than answered with piece 0.
			push_warning("Duckboard: Intersect works on convex brushes; ungroup the group first.")
			return
	var solids := brushes.map(func(b): return b.world_faces())
	var blueprints := Csg.intersect(solids)
	if blueprints.is_empty():
		push_warning("Duckboard: the selected brushes don't overlap; nothing to intersect.")
		return
	host._replace_brushes(brushes, blueprints, "CSG Intersect")


## Subtract the selected brushes from every OTHER brush they touch. The others are replaced by
## their carved fragments; the selected (subtrahend) brushes are removed, as TrenchBroom does.
func subtract() -> void:
	var subtrahends := host._selected_solids()
	if subtrahends.is_empty():
		return
	# Flattened: a group subtracts as its pieces, each a convex subtrahend of its own.
	var sub_solids := []
	for b in subtrahends:
		sub_solids.append_array(b.world_pieces())
	# Every other brush that shares volume with any subtrahend is a target. A LOOSE brush is
	# replaced by its carved fragments; a GROUP is carved piece by piece and KEEPS its node — the
	# fragments become its pieces, so cutting a doorway into a grouped room leaves the room a room.
	var targets: Array[Node3D] = []
	var rewrites := {}
	var consumed: Array[Node3D] = []
	for other in host._scene_brushes():
		if other in subtrahends:
			continue
		if other.is_group():
			var new_pieces := []
			var carved := false
			for piece in other.world_pieces():
				var touched := false
				for s in sub_solids:
					if Csg.overlaps(piece, s):
						touched = true
						break
				if not touched:
					new_pieces.append(piece)
					continue
				carved = true
				new_pieces.append_array(Csg.subtract(piece, sub_solids))
			if not carved:
				continue
			if new_pieces.is_empty():
				consumed.append(other)   # the cut swallowed the whole group
			else:
				rewrites[other] = new_pieces
			continue
		var other_solid: Array = other.world_faces()
		for s in sub_solids:
			if Csg.overlaps(other_solid, s):
				targets.append(other)
				break
	if targets.is_empty() and rewrites.is_empty() and consumed.is_empty():
		push_warning("Duckboard: nothing in contact with the selection to subtract from.")
		return
	# Carve each loose target by all subtrahends; collect every surviving fragment.
	var blueprints: Array = []
	for target in targets:
		blueprints.append_array(Csg.subtract(target.world_faces(), sub_solids))
	# The subtrahends are consumed too, so they go in the removal list alongside the carved targets
	# and any group the cut swallowed whole.
	var removed: Array[Node3D] = targets.duplicate()
	removed.append_array(consumed)
	removed.append_array(subtrahends)
	host._replace_brushes(removed, blueprints, "CSG Subtract", [], rewrites)


## Turn each selected brush into a shell of walls one grid cell thick.
func hollow() -> void:
	var brushes := host._selected_solids()
	if brushes.is_empty():
		return
	for b in brushes:
		if b.is_group():
			# Hollowing each member of a group gives walls within walls, not a shell of the group —
			# there is no honest per-piece answer, so it refuses (and greys in the menu).
			push_warning("Duckboard: Hollow works on convex brushes; ungroup the group first.")
			return
	var thickness := host._cell_meters()
	var blueprints: Array = []
	for b in brushes:
		blueprints.append_array(Csg.hollow(b.world_faces(), thickness))
	if blueprints.is_empty():
		push_warning("Duckboard: Hollow produced nothing.")
		return
	host._replace_brushes(brushes, blueprints, "CSG Hollow")
