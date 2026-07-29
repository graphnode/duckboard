@tool
extends RefCounted
## Texture drag-and-drop from the FileSystem dock onto brush faces. One invisible drop catcher per 3D
## viewport, alive only while the map editor is on. Each accepts a FileSystem/resource drag carrying
## a texture (or a material, whose albedo texture is taken) and lands it on the brush face under the
## cursor. The catcher is a dumb Control (see ui/viewport_drop.gd); the raycast, the highlight and the
## undo commit all happen here.
##
## Owned by the Duckboard plugin, reached through `host`. Hover state (_drop_face_hover) and
## _clear_material_overrides stay on the plugin — the overlay draws the hover, and material-clearing
## is shared with the browser menu and shift-face paint.

const ViewportDrop := preload("res://addons/duckboard/ui/viewport_drop.gd")

var host: Duckboard
var _catchers: Array[Control] = []


func _init(p_host: Duckboard) -> void:
	host = p_host


func add_catchers() -> void:
	if not _catchers.is_empty():
		return
	for i in 4:   # the spatial editor always owns 4 viewports; hidden ones get no mouse anyway
		var vp := EditorInterface.get_editor_viewport_3d(i)
		if vp == null:
			continue
		var catcher := ViewportDrop.new()
		catcher.viewport = vp
		catcher.probe = _probe
		catcher.commit = _commit
		catcher.reset = _reset
		# The editor's own drop handling (the "Dropping a material..." preview) lives on an input
		# `surface` Control that sits ABOVE the SubViewportContainer inside Node3DEditorViewport.
		# The catcher must be parented above THAT — as the last child of Node3DEditorViewport — or
		# the surface soaks up every drag query and the catcher never hears about the drop.
		var container: Control = vp.get_parent()               # SubViewportContainer
		var editor_vp := container.get_parent() as Control     # Node3DEditorViewport, hosting `surface`
		if editor_vp != null:
			container = editor_vp
		container.add_child(catcher)
		# MUST be the anchors-AND-offsets call: plain set_anchors_preset keeps the control's
		# current rect by compensating the offsets, and a freshly created Control's rect is
		# zero-sized — leaving an invisible dot that hit-testing never finds.
		catcher.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_catchers.append(catcher)


func remove_catchers() -> void:
	for c in _catchers:
		if is_instance_valid(c):
			c.queue_free()
	_catchers = []
	host._set_drop_face_hover(null)


## The brush face a texture drag at `pos` would land on, or null — either no brush is under the
## cursor, or a NON-brush mesh sits closer along the ray. In that second case the drop belongs to
## Godot's built-in handling (the catcher yields), so props keep taking normal material drops
## while the map editor is on. The obstruction test is AABB-coarse, which matches how coarsely
## the built-in drop itself picks its target.
func _hit(camera: Camera3D, pos: Vector2):
	var from := camera.project_ray_origin(pos)
	var dir := camera.project_ray_normal(pos)
	# Groups included: a texture drops onto a grouped surface like any other. The hit comes back as
	# that member's kernel, so everything below — the obstruction test, the highlight, the drop
	# itself — is unchanged.
	var hit = host._raycast_brush_faces(from, dir, true)
	if hit == null:
		return null
	var root := EditorInterface.get_edited_scene_root()
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if node is Brush or not node.is_inside_tree() or not node.visible:
			continue
		# A solid RENDERS through a generated MeshInstance3D now, and that node is not a Brush — so
		# without this every brush would count as something obstructing the drop onto itself, and no
		# texture could ever be dropped on anything. Only geometry the user placed can obstruct.
		if _inside_solid(node):
			continue
		var aabb: AABB = node.global_transform * node.get_aabb()
		var res = host._ray_aabb(from, dir, aabb.position, aabb.end)
		if res != null and res.t < hit.t:
			return null
	return hit


## Does `node` live inside a [Brush] or [BrushGroup]? True for the mesh and body a solid builds for
## itself, false for anything the user put in the scene.
func _inside_solid(node: Node) -> bool:
	var walk := node.get_parent()
	while walk != null:
		if walk is Brush or walk is BrushGroup:
			return true
		walk = walk.get_parent()
	return false


## Is there a brush face under a texture drag? Also moves the drop highlight there — the whole
## brush when SHIFT is held (the drop then paints every face), else the single face.
func _probe(camera: Camera3D, pos: Vector2) -> bool:
	var hit = _hit(camera, pos)
	# A drag generates no _forward_3d_gui_input, so the overlay's camera is aimed here instead.
	host._draw_camera = camera
	if hit == null:
		host._set_drop_face_hover(null)
	else:
		host._set_drop_face_hover({"node": hit.node, "face": hit.face,
			"whole": Input.is_key_pressed(KEY_SHIFT)})
	return hit != null


func _reset() -> void:
	host._set_drop_face_hover(null)


## Land a dropped surface (texture or material) on the face under the cursor — or on EVERY face of
## its brush when SHIFT is held — as one undo step. The face needn't be selected; the drop names its
## own target, like painting in TrenchBroom. The surface becomes the active/current one, and
## _sync_texture_dock's in-use pass auto-adopts it into the browser.
func _commit(surface: Resource, camera: Camera3D, pos: Vector2) -> void:
	host._set_drop_face_hover(null)
	var hit = _hit(camera, pos)
	if hit == null:
		return
	host._active_surface = surface
	var whole := Input.is_key_pressed(KEY_SHIFT)
	var noun := "Material" if surface is Material else "Texture"
	var ur := host.get_undo_redo()
	ur.create_action("Drop %s on Brush" % noun if whole else "Drop %s on Face" % noun)
	# Dropping on a closed group lands on the hit MEMBER's kernel, so the change is recorded as that
	# group's `members` instead of the kernel's face_data — the kernel is scratch and undo must not
	# point at it. SHIFT therefore textures the whole MEMBER, not the whole group, which matches what
	# the cursor was over.
	var group_before := host._snapshot_kernel_groups([hit.node])
	var is_kernel := not group_before.is_empty()
	if not is_kernel:
		ur.add_undo_property(hit.node, "face_data", hit.node.face_data)
		host._clear_material_overrides(ur, hit.node)
	if whole:
		for f in hit.node.planes.size():
			host._apply_surface_to_face(hit.node, f, surface)
	else:
		host._apply_surface_to_face(hit.node, hit.face, surface)
	if not is_kernel:
		ur.add_do_property(hit.node, "face_data", hit.node.face_data)
	host._fold_kernel_writes(ur, group_before)
	ur.commit_action(false)   # already applied
	host._sync_texture_dock()
