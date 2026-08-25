@tool
extends RefCounted
## The Duplicate dropdown at the head of the palette's actions group: plain Duplicate, LINKED
## Duplicate, and the two link-management ops. The palette owns and styles the button (see
## tool_palette `_build_duplicate_button`); this fills its popup and runs the ops, so all the
## linking behaviour outside the fan-out itself stays in one place.
##
## Modelled on group_ops.gd — same build_menu / update_menu / _on_menu shape, same greying
## discipline. The duplicates themselves live on the host (`_duplicate_selected_brushes`), which
## the Ctrl+D / Ctrl+Shift+D claims in the key ladder call directly; this popup is the mouse
## route to the same two calls.
##
## What LINKING means is documented on [member Brush.link_id]; the fan-out that makes it true is
## `Duckboard._record_solid_writes`. Worth knowing here: a PLAIN duplicate of an already-linked
## solid joins its set (duplicate() copies `link_id` with every other stored property), which is
## TrenchBroom's behaviour for linked groups and the reason Break Link exists.

const DUPLICATE := 0
const DUPLICATE_LINKED := 1
const SELECT_LINKED := 2
const BREAK_LINK := 3

var host: Duckboard
var _popup: PopupMenu


func _init(p_host: Duckboard) -> void:
	host = p_host


func build_menu() -> void:
	_popup = host._palette.get_duplicate_popup()
	_popup.add_item("Duplicate", DUPLICATE)
	_popup.add_item("Linked Duplicate", DUPLICATE_LINKED)
	_popup.add_separator()
	_popup.add_item("Select All Linked", SELECT_LINKED)
	_popup.add_item("Break Link", BREAK_LINK)
	_popup.id_pressed.connect(_on_menu)


## Grey what the selection can't satisfy: the duplicates need solids, the link pair needs a LINKED
## solid among them. The button itself greys only when nothing at all can run.
func update_menu() -> void:
	if not is_instance_valid(_popup):
		return
	var solids := host._selected_solids()
	var any_linked := false
	for solid in solids:
		if solid is Brush and solid.link_id != &"":
			any_linked = true
			break
	if is_instance_valid(host._palette):
		host._palette.set_duplicate_enabled(not solids.is_empty())
	_popup.set_item_disabled(_popup.get_item_index(DUPLICATE), solids.is_empty())
	_popup.set_item_disabled(_popup.get_item_index(DUPLICATE_LINKED), solids.is_empty())
	_popup.set_item_disabled(_popup.get_item_index(SELECT_LINKED), not any_linked)
	_popup.set_item_disabled(_popup.get_item_index(BREAK_LINK), not any_linked)


func _on_menu(id: int) -> void:
	match id:
		DUPLICATE: host._duplicate_selected_brushes()
		DUPLICATE_LINKED: host._duplicate_selected_brushes(true)
		SELECT_LINKED: select_linked()
		BREAK_LINK: break_link()


## Extend the selection to every scene solid sharing a link id with a selected one — the whole set
## the next edit would touch, made explicit. A selection change, so no undo step.
func select_linked() -> void:
	var ids := {}
	for solid in host._selected_solids():
		if solid is Brush and solid.link_id != &"":
			ids[solid.link_id] = true
	if ids.is_empty():
		return
	var selection := EditorInterface.get_selection()
	# ignore_isolation: the point is to SEE the whole set, an open group's fence notwithstanding.
	for node in host._scene_brushes(false, true):
		if node is Brush and ids.has(node.link_id) and not (node in selection.get_selected_nodes()):
			selection.add_node(node)


## Clear `link_id` on the SELECTED solids, as one undo step. Deliberately only the selected ones:
## breaking one instance out of a set of five leaves the other four linked to each other, which is
## what "break THIS one's link" means. Select All Linked first to dissolve a whole set.
func break_link() -> void:
	var linked: Array = []
	for solid in host._selected_solids():
		if solid is Brush and solid.link_id != &"":
			linked.append(solid)
	if linked.is_empty():
		return
	var ur := host.get_undo_redo()
	ur.create_action("Break Link")
	for solid in linked:
		ur.add_undo_property(solid, "link_id", solid.link_id)
		ur.add_do_property(solid, "link_id", &"")
	ur.commit_action()
	host.update_overlays()   # the cyan twin boxes go out with the link
	update_menu()
