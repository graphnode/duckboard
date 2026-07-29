@tool
extends RefCounted
## TrenchBroom's Edit -> Group / Ungroup, as a dropdown at the foot of the left tool palette. The
## palette owns and styles the button (see tool_palette `_build_group_button`); this fills its popup
## and runs the ops, so all the grouping behaviour stays in one place. The node lives in
## brush_group.gd; this is the editor glue (selection, menu state, undo-backed replacement).
##
## Modelled on csg_ops.gd, its sibling at the same corner of the palette — same build_menu /
## update_menu / _on_menu shape, same greying discipline, and Ungroup reuses the very same
## host._replace_brushes step that CSG and .map paste go through.
##
## Owned by the Duckboard plugin, reached through `host` for the selection, the palette, the grid
## size and the shared brush-replacement step.

const GROUP := 0
const UNGROUP := 1

var host: Duckboard
var _popup: PopupMenu


func _init(p_host: Duckboard) -> void:
	host = p_host


func build_menu() -> void:
	_popup = host._palette.get_group_popup()
	_popup.add_item("Group", GROUP)
	_popup.add_item("Ungroup", UNGROUP)
	_popup.id_pressed.connect(_on_menu)


## Grey out items the selection can't satisfy: Group needs two things to combine (brushes, groups,
## or a mix), Ungroup needs at least one group. Keeps the menu honest instead of failing silently on
## click, exactly as the CSG menu does.
func update_menu() -> void:
	if not is_instance_valid(_popup):
		return
	# Both ops are refused inside an OPEN group. The schema is flat, so there is nowhere to put a
	# group within a group, and letting it through built a BrushGroup as a child of the one being
	# edited — reading its transform before it was in the tree, which is where the is_inside_tree()
	# errors came from. Close the group and group its members from the outside instead.
	var inside := host._open_group != null
	var groups := host._selected_groups().size()
	var combinable := host._selected_brushes().size() + groups
	if is_instance_valid(host._palette):
		host._palette.set_group_enabled(not inside and (combinable >= 2 or groups >= 1))
	_popup.set_item_disabled(_popup.get_item_index(GROUP), inside or combinable < 2)
	_popup.set_item_disabled(_popup.get_item_index(UNGROUP), inside or groups < 1)


func _on_menu(id: int) -> void:
	match id:
		GROUP: group()
		UNGROUP: ungroup()


## Absorb the selected brushes — and the members of any selected group — into one new BrushGroup.
##
## A selected GROUP contributes its MEMBERS rather than itself: the schema is deliberately flat, so
## there is nowhere to put a group inside a group, and flattening is what "make these things one
## thing" already reads as. The old group node is consumed along with the brushes; only Ctrl+Z
## brings the previous grouping back.
##
## The new node is placed at the centre of everything it swallowed, so its origin sits in its own
## geometry and local coordinates stay small — the same courtesy _replace_brushes does with
## recenter(). The whole swap is one create_action.
func group() -> void:
	if host._open_group != null:
		return   # see update_menu: no group inside a group
	var brushes := host._selected_brushes()
	var groups := host._selected_groups()
	if brushes.size() + groups.size() < 2:
		return
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return

	var solids := []
	for b in brushes:
		solids.append(b.world_faces())
	for g in groups:
		solids.append_array(g.world_members())
	if solids.is_empty():
		return

	var consumed: Array[Node3D] = []
	consumed.append_array(brushes)
	consumed.append_array(groups)

	var parent := host._brush_parent()
	var group_node := BrushGroup.new()
	group_node.name = "BrushGroup"
	group_node.grid_size = host.grid_size
	group_node.texture_lock = host.texture_lock
	group_node.uv_lock = host.uv_lock
	var pose := Transform3D(Basis.IDENTITY, _solids_center(solids))

	var ur := host.get_undo_redo()
	ur.create_action("Group Brushes")
	for old in consumed:
		var old_parent: Node = old.get_parent()
		ur.add_do_method(old_parent, "remove_child", old)
		ur.add_undo_method(old_parent, "add_child", old, true)
		ur.add_undo_method(old, "set_owner", root)
		ur.add_undo_reference(old)
	# Order matters: the node has to be in the tree and AT ITS FINAL POSE before absorb_world, which
	# folds the world-space solids through global_transform to get the group-local members.
	ur.add_do_method(parent, "add_child", group_node, true)
	ur.add_do_method(group_node, "set_owner", root)
	ur.add_do_property(group_node, "global_transform", pose)
	ur.add_do_method(group_node, "absorb_world", solids)
	ur.add_do_reference(group_node)
	ur.add_undo_method(parent, "remove_child", group_node)

	# Dropped BEFORE the commit, not after. With several nodes selected the inspector holds a
	# MultiNodeEdit, which addresses them by NODE PATH and re-resolves those paths on every refresh.
	# Commit first and the brushes are gone while it still holds their paths, so it logs a
	# "Node not found" per selected brush, per refresh. Letting go of them first costs nothing — the
	# result is selected a few lines below anyway.
	var sel := EditorInterface.get_selection()
	sel.clear()

	ur.commit_action()

	# Select the result so the next action (and the overlay) targets it.
	if is_instance_valid(group_node) and group_node.is_inside_tree():
		sel.add_node(group_node)
	host._selected_faces = []
	host.update_overlays()


## Explode every selected group back into loose brushes, one per member, and delete the group.
##
## Lossless because a member IS a world_faces() payload: handing it to _replace_brushes runs the
## same set_world_faces round-trip that CSG results and .map paste already use, so planes, textures
## and UV axes come back exactly as they went in.
func ungroup() -> void:
	if host._open_group != null:
		return   # see update_menu
	var groups := host._selected_groups()
	if groups.is_empty():
		return
	var blueprints := []
	for g in groups:
		blueprints.append_array(g.world_members())
	if blueprints.is_empty():
		push_warning("Duckboard: the selected group is empty — nothing to ungroup.")
		return
	host._replace_brushes(groups, blueprints, "Ungroup")


## Centre of the bounding box of every corner in every solid — where the new group's origin goes.
func _solids_center(solids: Array) -> Vector3:
	var bounds := AABB()
	var first := true
	for s in solids:
		for f in s:
			for c in f["points"]:
				if first:
					bounds = AABB(c, Vector3.ZERO)
					first = false
				else:
					bounds = bounds.expand(c)
	return bounds.get_center()
