@tool
extends RefCounted
## The Physics dropdown at the foot of the left tool palette — where a solid is told what it collides
## as.
##
## [b]It sets three properties, and that is the whole of it.[/b] A solid derives its own body and
## shapes from [code]collision_type[/code], [code]collision_layer[/code] and
## [code]collision_mask[/code] whenever it enters a tree (see collision.gd), so choosing "Static Body"
## here is a property write and nothing more. No node is created, moved, reparented or destroyed, the
## scene tree does not grow by a single entry, and undo is the ordinary undo of a property.
##
## That is a deliberate reversal. An earlier version of this file built the bodies and shapes as real,
## saved nodes and wired the selection into them — some three hundred lines of planning reparents,
## matching shape counts to convex pieces, rescuing shapes orphaned by a delete and restoring the lot
## in the right order on undo. It worked, and using it was miserable: a room of thirty brushes became a
## tree of ninety nodes, and every other editing path in the plugin had to answer for the extra ones.
## Deriving the nodes deleted that entire surface, and this file with it.
##
## [b]Why these body kinds and no others.[/b] [StaticBody3D] is world geometry, [AnimatableBody3D] the
## moving platform that pushes what it touches, [RigidBody3D] the thing that falls over. An [Area3D]
## trigger or a [CharacterBody3D] needs a script or a signal handler to mean anything, so offering
## either would be a menu entry that appears to do nothing. Build those by hand.
##
## Modelled on group_ops.gd and csg_ops.gd, its neighbours at the same corner of the palette — same
## build_menu / update_menu / _on_menu shape, same greying discipline. Owned by the Duckboard plugin
## and reached through `host` for the selection, the undo history and the palette.

const Collision := preload("res://addons/duckboard/collision.gd")

## Menu id -> the [enum Collision.Body] it states and what it is called. The ids ARE the enum values,
## so the menu, the property and the radio check are one number with no mapping table to drift.
const KINDS := {
	Collision.Body.NONE: {"label": "No Collision", "verb": "Remove Collision"},
	Collision.Body.STATIC: {"label": "Static Body", "verb": "Make Static Body"},
	Collision.Body.ANIMATABLE: {"label": "Moving Platform", "verb": "Make Moving Platform"},
	Collision.Body.RIGID: {"label": "Rigid Body", "verb": "Make Rigid Body"},
}

## The order they appear in, most-used first. NONE last, separated: it is the one that takes something
## away, and it should not sit where a mis-click lands.
const ORDER := [
	Collision.Body.STATIC, Collision.Body.ANIMATABLE, Collision.Body.RIGID, Collision.Body.NONE,
]

var host: Duckboard
var _popup: PopupMenu


func _init(p_host: Duckboard) -> void:
	host = p_host


func build_menu() -> void:
	_popup = host._palette.get_physics_popup()
	# Radio items rather than plain ones: collision_type is one choice out of four, and the menu is
	# also the only place the CURRENT choice is visible without opening the inspector.
	for kind in ORDER:
		if kind == Collision.Body.NONE:
			_popup.add_separator()
		_popup.add_radio_check_item(KINDS[kind]["label"], kind)
	_popup.id_pressed.connect(_on_menu)


## Tick whichever kind the selection already is, and grey the lot when there is nothing to state it
## about — exactly as the CSG and Group menus do.
##
## A mixed selection ticks nothing, which is the honest answer: the items still work, and clicking one
## makes the whole selection agree.
func update_menu() -> void:
	if _popup == null:
		return
	var targets := _targets()
	var enabled := not targets.is_empty()
	var shared := _shared_kind(targets)
	for i in _popup.item_count:
		if _popup.is_item_separator(i):
			continue
		var id := _popup.get_item_id(i)
		_popup.set_item_disabled(i, not enabled)
		_popup.set_item_checked(i, enabled and id == shared)
	host._palette.set_physics_enabled(enabled)


## Every selected solid — brushes and groups alike. Duck-typed on the property rather than on the
## classes, so a user's `extends Brush` subclass is as much a target as a plain one.
func _targets() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for node in EditorInterface.get_selection().get_selected_nodes():
		if node is Node3D and "collision_type" in node:
			out.append(node as Node3D)
	return out


## The kind every target agrees on, or -1 when they disagree or there are none.
func _shared_kind(targets: Array[Node3D]) -> int:
	var shared := -1
	for node in targets:
		var kind: int = node.get("collision_type")
		if shared == -1:
			shared = kind
		elif shared != kind:
			return -1
	return shared


func _on_menu(id: int) -> void:
	if not KINDS.has(id):
		return
	var targets := _targets()
	if targets.is_empty():
		return
	var ur := host.get_undo_redo()
	ur.create_action(KINDS[id]["verb"])
	for node in targets:
		# A plain property, both ways. The body and shapes follow from the setter, on redo and on undo
		# alike, so there is nothing else to record — which is the entire point of the derived model.
		ur.add_do_property(node, "collision_type", id)
		ur.add_undo_property(node, "collision_type", node.get("collision_type"))
	ur.commit_action()
	update_menu()
