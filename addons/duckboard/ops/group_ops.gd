@tool
extends RefCounted
## TrenchBroom's Edit -> Group / Ungroup, as a dropdown at the foot of the left tool palette. The
## palette owns and styles the button (see tool_palette `_build_group_button`); this fills its popup
## and runs the ops, so all the grouping behaviour stays in one place. The node lives in
## brush.gd; this is the editor glue (selection, menu state, undo-backed replacement).
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
	# group within a group, and letting it through built a group as a child of the one being
	# edited — reading its transform before it was in the tree, which is where the is_inside_tree()
	# errors came from. Close the group and group its members from the outside instead.
	var inside := host._open_group != null
	var groups := host._selected_groups().size()
	# A group IS a solid, so _selected_solids already counts it — adding the group count again
	# would let a single selected group read as two combinable things.
	var combinable := host._selected_solids().size()
	if is_instance_valid(host._palette):
		host._palette.set_group_enabled(not inside and (combinable >= 2 or groups >= 1))
	_popup.set_item_disabled(_popup.get_item_index(GROUP), inside or combinable < 2)
	_popup.set_item_disabled(_popup.get_item_index(UNGROUP), inside or groups < 1)


func _on_menu(id: int) -> void:
	match id:
		GROUP: group()
		UNGROUP: ungroup()


## Absorb the selected brushes — and the pieces of any selected group — into one new multi-piece
## [Brush].
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
	# Every solid exactly once, its pieces flattened — a LOOSE brush contributes one piece, a
	# selected group its members. Reading groups through world_faces() as well used to add a
	# group's first piece a second time and consume the node twice.
	var consumed := host._selected_solids()
	if consumed.size() < 2:
		return
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return

	var solids := []
	for b in consumed:
		solids.append_array(b.world_pieces())
	if solids.is_empty():
		return

	var parent := host._brush_parent()
	var pose := Transform3D(Basis.IDENTITY, _solids_center(solids))
	# Whatever they all already agree on comes across; the rest is what the warning is about.
	var plan := _reconcile(consumed)
	var carry: Dictionary = plan["carry"]
	var lost: PackedStringArray = plan["lost"]

	host.warn_before("confirm_group_when_settings_differ", "Group Brushes",
		"A group is ONE node, so it holds a single value for each of these and what you are "
		+ "grouping does not agree on them. Geometry, textures and UVs are unaffected.",
		lost, "Group Anyway",
		func() -> void: _apply_group(consumed, carry, parent, solids, pose, root))


## The undo-backed half of [method group], run once the user has answered any warning.
##
## The group node is built HERE rather than up front, so a cancelled warning leaves nothing behind: an
## unparented [Brush] is not reference-counted, and one made before the question was asked would
## be leaked by every No.
##
## Re-validates its inputs for the same reason. A dialog is asynchronous, and between the question and
## the answer the user can delete a brush, close the scene or open a different one — none of which was
## possible when this was a straight-through call.
func _apply_group(consumed: Array[Node3D], carry: Dictionary, parent: Node,
		solids: Array, pose: Transform3D, root: Node) -> void:
	if not is_instance_valid(parent) or not is_instance_valid(root) or not parent.is_inside_tree():
		return
	for node in consumed:
		if not is_instance_valid(node) or not node.is_inside_tree():
			return

	var group_node := Brush.new()
	group_node.name = "BrushGroup"
	group_node.grid_size = host.grid_size
	group_node.texture_lock = host.texture_lock
	group_node.uv_lock = host.uv_lock
	for property in carry:
		group_node.set(property, carry[property])

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

	# Dropped BEFORE the commit, not after: the editor is holding the selected brushes by NODE PATH and
	# would be left chasing paths to nodes this action removes. See
	# [method DuckboardSolid.hand_inspector_over] — the group is where it is headed a few lines below
	# anyway, so handing it over early costs nothing.
	DuckboardSolid.hand_inspector_over(group_node)
	# Same reasoning, same side of the commit: the face selection and the SHIFT hover name the brushes.
	host._drop_face_state()

	ur.commit_action()

	# Select the result so the next action (and the overlay) targets it.
	if is_instance_valid(group_node) and group_node.is_inside_tree():
		EditorInterface.get_selection().add_node(group_node)
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
		blueprints.append_array(g.world_pieces())
	if blueprints.is_empty():
		push_warning("Duckboard: the selected group is empty — nothing to ungroup.")
		return
	# "Ungroup Brushes", pairing with the "Group Brushes" the other direction records — the history
	# reads as one operation and its inverse. The MENU item stays the plain verb; a menu is read in
	# the context of what is selected, an undo entry on its own.
	host._replace_brushes(groups, blueprints, "Ungroup Brushes")


## Everything a solid holds ONCE for the whole node, so a group cannot keep one per member. Geometry
## is not here and never can be: planes, per-face textures, UV axes and materials all travel into
## `members` untouched, which is what makes grouping lossless for the map itself.
##
## Ordered as the inspector orders them, because that is where the user will go looking after reading
## the warning.
const SOLID_PROPERTIES := [
	{"name": &"collision_type", "label": "Collision type"},
	{"name": &"collision_layer", "label": "Collision layer"},
	{"name": &"collision_mask", "label": "Collision mask"},
	{"name": &"occluder", "label": "Occluder"},
	{"name": &"lightmap_uv2", "label": "Lightmap UV2"},
	{"name": &"lightmap_texel_size", "label": "Lightmap texel size"},
	{"name": &"material_override", "label": "Material override"},
	{"name": &"cast_shadow", "label": "Cast shadow"},
	{"name": &"layers", "label": "Render layers"},
	{"name": &"gi_mode", "label": "Global illumination"},
	{"name": &"transparency", "label": "Transparency"},
	{"name": &"visible", "label": "Visible"},
]

## Named values for the enums, so the warning says "Rigid Body" rather than "3".
const COLLISION_NAMES := ["None", "Static", "Moving Platform", "Rigid Body", "Trigger Volume"]
const CAST_SHADOW_NAMES := ["Off", "On", "Double-Sided", "Shadows Only"]


## What the new group should inherit, and what it cannot:
## [code]{"carry": {property: value}, "lost": [one readable line each]}[/code].
##
## [b]Unanimity is the whole rule, and it is the honest one.[/b] Five Rigid Body brushes have exactly
## one answer to "what does this group collide as", and resetting them to Static merely because a
## group is a fresh node would throw away information nobody had to lose. Where they genuinely
## disagree there IS no right answer, so the group keeps its own default and the user is told what it
## just dropped — that is a decision, and decisions get shown rather than made quietly.
##
## A CUSTOM SCRIPT is reported but never carried: a brush wearing `extends Brush` is a brush with
## behaviour, and a group has nowhere to put it. Named per node rather than counted, because "which
## one was it" is the next question.
func _reconcile(consumed: Array[Node3D]) -> Dictionary:
	var carry := {}
	var lost := PackedStringArray()
	# A throwaway group is the only honest answer to "what will it be instead?" — it reads the real
	# defaults, including the forwarded ones, which live on the generated mesh rather than in a
	# constant. Freed on the way out; nothing here is ever shown or parented.
	var defaults := Brush.new()
	for spec in SOLID_PROPERTIES:
		var property: StringName = spec["name"]
		var value: Variant = consumed[0].get(property)
		var agreed := true
		for node in consumed:
			if node.get(property) != value:
				agreed = false
				break
		if agreed:
			carry[property] = value
			continue
		lost.append("%s — the group will be %s" % [spec["label"],
			_describe(property, defaults.get(property))])
	defaults.free()
	for node in consumed:
		var script := node.get_script()
		if script != null and script != Brush:
			# The file name is worth having and is not guaranteed: a script built in memory has no
			# resource_path, and naming it "()" would read as a bug in the warning.
			var file := (script as Resource).resource_path.get_file()
			lost.append("%s has its own script%s, which a group cannot carry"
				% [node.name, "" if file.is_empty() else " (%s)" % file])
	return {"carry": carry, "lost": lost}


## One property value as the inspector would show it.
func _describe(property: StringName, value: Variant) -> String:
	match property:
		&"collision_type":
			return COLLISION_NAMES[value] if value < COLLISION_NAMES.size() else str(value)
		&"cast_shadow":
			return CAST_SHADOW_NAMES[value] if value < CAST_SHADOW_NAMES.size() else str(value)
		&"visible":
			return "visible" if value else "hidden"
		&"material_override":
			return "empty" if value == null else str(value)
	# After the match, so `visible` keeps its own wording: a checkbox reads as on/off, never as "true".
	if typeof(value) == TYPE_BOOL:
		return "on" if value else "off"
	return str(value)


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
