@tool
extends EditorExportPlugin
## Strips the editing data out of exported builds — [b]the "no bake step" promise, kept at the only
## moment a bake is honest.[/b] The [code].tscn[/code] on disk keeps every brush editable forever;
## this plugin rewrites the IN-MEMORY copy the exporter is about to pack, so the shipped scene
## carries a brush's mesh, transform, materials, body and shapes — and none of its [code]pieces[/code],
## face data or the CSG code that derives them.
##
## Two halves, one switch (the [code]duckboard/strip_brush_editing_data[/code] export option,
## default on):
##
## [b]Scene customization.[/b] The engine instantiates each exported [PackedScene] detached — setters
## run, [code]_ready[/code] does not, nothing enters a tree — and hands the live root to
## [method _customize_scene]. Every node that is exactly a [Brush] (subclasses are deliberately left
## alone — see below) is replaced by [method Brush.to_plain_nodes], the same builder Convert to Mesh
## uses, so an exported scene and an ejected one cannot disagree. The file on disk is never touched.
##
## [b]File skipping.[/b] With every exact brush collapsed to plain nodes, nothing references
## [code]addons/duckboard/[/code] any more, so the whole addon is dropped from the build — except
## [code]textures/__empty.png[/code], kept as cheap insurance for any user material that picked it up.
##
## [b]What holds the file-skip back: a project that still names Brush at run time.[/b] Two cases,
## detected two ways. A script [i]extending[/i] Brush keeps its node un-stripped (the node needs its
## script, its script needs the addon), which the exact-class test handles per node. A script merely
## [i]mentioning[/i] Brush ([code]node is Brush[/code]) would fail to parse in a build with the class
## gone — so [method _export_begin] scans the project's own [code].gd[/code] sources for the word, and
## any hit ships the addon whole. False positives (a comment) cost bytes; a false negative would cost
## a broken build, so the scan reads generously. Turning the option off disables both halves at once
## for anything the scan cannot see.
##
## One small file the host registers in [code]_enter_tree[/code] and drops in [code]_exit_tree[/code],
## exactly like every other helper it owns — not a second addon, and nothing extra to enable.

const Collision := preload("res://addons/duckboard/collision.gd")
## The exact-class test: a node whose script IS this resource is a plain Brush and is stripped; any
## other script — a user's [code]extends Brush[/code] — makes the node theirs, and it ships intact.
const BRUSH_SCRIPT := preload("res://addons/duckboard/brush.gd")

const OPTION_STRIP := "duckboard/strip_brush_editing_data"
const ADDON_DIR := "res://addons/duckboard/"
const KEEP_FILES := ["res://addons/duckboard/textures/__empty.png"]

## Bumped whenever the stripping logic changes. Exports are cached per configuration hash and a
## plugin-script edit does NOT invalidate that cache — without this in the hash, a changed strip
## would keep shipping scenes customized by the old code until the scene files themselves changed.
const STRIP_VERSION := 1

## Whether the project's own scripts name Brush — decided once per export, read per file.
var _addon_referenced := false


func _get_name() -> String:
	return "DuckboardStrip"


func _supports_platform(_platform: EditorExportPlatform) -> bool:
	return true    # the strip is about scene content, which every platform packs the same way


func _get_export_options(_platform: EditorExportPlatform) -> Array[Dictionary]:
	return [{
		"option": {
			"name": OPTION_STRIP,
			"type": TYPE_BOOL,
			"hint": PROPERTY_HINT_NONE,
			"hint_string": "",
		},
		"default_value": true,
	}]


func _get_customization_configuration_hash() -> int:
	return hash([STRIP_VERSION, bool(get_option(OPTION_STRIP))])


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String,
		_flags: int) -> void:
	_addon_referenced = _scan_for_brush_references("res://")
	if _addon_referenced and bool(get_option(OPTION_STRIP)):
		print("Duckboard: a project script names Brush, so the addon ships with this export. "
			+ "Plain Brush nodes are still collapsed to plain engine nodes.")


func _begin_customize_scenes(_platform: EditorExportPlatform,
		_features: PackedStringArray) -> bool:
	return bool(get_option(OPTION_STRIP))


## Replace every exact [Brush] the exported scene owns with the plain nodes it derives. Returns the
## (possibly new) root when anything changed, null when nothing did — null is what keeps an untouched
## scene out of the customization cache's way.
func _customize_scene(scene: Node, _path: String) -> Node:
	var brushes: Array = []
	_collect(scene, scene, brushes)
	for brush in brushes:
		_replace(brush, scene)
	# The root itself can be a Brush — a prop saved as its own scene. There is no parent to swap
	# under, so the replacement BECOMES the root, and disposing of the old one is this method's job.
	if _strippable(scene, scene):
		var root := _replace_root(scene as Brush)
		if root != null:
			scene.free()
			return root
	if brushes.is_empty():
		return null
	return scene


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if not path.begins_with(ADDON_DIR):
		return
	if not bool(get_option(OPTION_STRIP)) or _addon_referenced or path in KEEP_FILES:
		return
	skip()


## Every strippable brush under `node`, TOP-DOWN — and the order is load-bearing for a brush nested
## under another brush. An outer brush must bake while the inner one is still a [Brush]: ensure_tree
## identifies its own derived children by walking for bare [MeshInstance3D] / [CollisionObject3D]
## types, which a Brush is not — but the PLAIN nodes an early inner replacement would leave in its
## place are exactly those types, and the outer bake would adopt one as its own mesh and overwrite
## it. Outer first, the inner brush rides across the carry intact (see _replace) and is replaced in
## its turn under the outer's replacement, whose parent chain [method _pose_of] reads live.
static func _collect(node: Node, root: Node, out: Array) -> void:
	if node != root and _strippable(node, root):
		out.append(node)
	for child in node.get_children():
		_collect(child, root, out)


## Is this node one the strip may claim? Exactly a [Brush] — a subclass is the user's and keeps its
## script — and owned by the scene being customized. A brush inside an instanced sub-scene has
## another owner and is customized on that scene's own export pass, where it IS the owned one.
static func _strippable(node: Node, root: Node) -> bool:
	return node is Brush and node.get_script() == BRUSH_SCRIPT \
		and (node == root or node.owner == root)


## The world pose the brush's UVs must be baked from: the transform chain from the scene root down.
## Nothing here is in a tree, so it is accumulated by hand — the detached equivalent of the
## [code]global_transform[/code] a live bake reads.
static func _pose_of(node: Node3D, root: Node) -> Transform3D:
	var pose := node.transform
	if node == root:
		return pose
	var parent := node.get_parent()
	while parent != null:
		if parent is Node3D:
			pose = (parent as Node3D).transform * pose
		if parent == root:
			break
		parent = parent.get_parent()
	return pose


## Swap one brush for its plain nodes, in place. The user's own children — anything under the brush
## that the scene owns — are carried onto the replacement, whose transform equals the brush's, so
## their local frames read exactly as before. Removal cleared their owners, so the set that had one
## is captured first and re-owned after.
static func _replace(brush: Brush, root: Node) -> void:
	var replacement := Brush.to_plain_nodes(brush, _pose_of(brush, root))
	if replacement == null:
		return
	var parent := brush.get_parent()
	var index := brush.get_index()
	var kept: Array = []
	var owned: Array = []
	for child in brush.get_children():
		if child.owner == root:
			kept.append(child)
			_owned_under(child, root, owned)
	# DETACHED trees never clear owners on remove_child (that is a tree-exit side effect, and there
	# is no tree), so the carried nodes would arrive still claiming one and add_child would warn per
	# node per export. Cleared by hand going out, restored from `owned` coming back — which also
	# keeps this correct if the engine ever does clear them.
	for node in owned:
		node.owner = null
	for child in kept:
		brush.remove_child(child)
	parent.remove_child(brush)
	parent.add_child(replacement)
	parent.move_child(replacement, index)
	# pack() drops any node whose owner is not the scene root, so the replacement subtree is claimed
	# whole — BEFORE the carried children return, whose derived (unowned) descendants must stay so.
	Collision.claim(replacement, root)
	for child in kept:
		replacement.add_child(child)
	for node in owned:
		node.owner = root
	brush.free()


## The root-Brush variant of [method _replace]: the replacement inherits the children and becomes the
## new scene root, so the carried nodes' owner is the replacement itself.
static func _replace_root(brush: Brush) -> Node3D:
	var replacement := Brush.to_plain_nodes(brush, brush.transform)
	if replacement == null:
		return null
	var kept: Array = []
	var owned: Array = []
	for child in brush.get_children():
		if child.owner == brush:
			kept.append(child)
			_owned_under(child, brush, owned)
	for node in owned:
		node.owner = null    # see _replace — detached trees never clear owners on remove_child
	for child in kept:
		brush.remove_child(child)
	Collision.claim(replacement, replacement)
	replacement.owner = null    # a scene root owns its children and no one owns it
	for child in kept:
		replacement.add_child(child)
	for node in owned:
		node.owner = replacement
	return replacement


## Collect `node` and every descendant the scene owns — the set whose owner must be restored after a
## reparent clears it. Descendants with no owner (a surviving subclass brush's derived subtree) are
## left off the list, so they stay out of the packed scene exactly as they were.
static func _owned_under(node: Node, root: Node, out: Array) -> void:
	if node.owner == root:
		out.append(node)
	for child in node.get_children():
		_owned_under(child, root, out)


## Does any project script outside the addon say the word Brush? Word-bounded, so BrushData and a
## user's BrushFactory don't count, but a comment does — over-shipping is the cheap direction.
static func _scan_for_brush_references(dir_path: String) -> bool:
	if dir_path.begins_with(ADDON_DIR):
		return false
	var pattern := RegEx.create_from_string("\\bBrush\\b")
	return _scan_dir(dir_path, pattern)


static func _scan_dir(dir_path: String, pattern: RegEx) -> bool:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return false
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var path := dir_path.path_join(entry)
		if dir.current_is_dir():
			# Hidden folders (.godot, .git) are caches, not sources. The trailing slash matters:
			# without it a sibling like addons/duckboard_extras would be skipped along with the addon.
			if not entry.begins_with(".") and path + "/" != ADDON_DIR:
				if _scan_dir(path, pattern):
					dir.list_dir_end()
					return true
		elif entry.get_extension() == "gd":
			var source := FileAccess.get_file_as_string(path)
			if pattern.search(source) != null:
				dir.list_dir_end()
				return true
		entry = dir.get_next()
	dir.list_dir_end()
	return false
