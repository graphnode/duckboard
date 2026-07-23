@tool
extends Control
## Invisible drop target laid over one 3D editor viewport, so textures AND materials can be dragged
## from the FileSystem dock (or any resource picker) straight onto a brush face.
##
## The control must not disturb normal viewport input, so it idles at MOUSE_FILTER_IGNORE. During
## a drag that carries something a face can wear — a texture, or a whole material — it claims the
## mouse (STOP) only while a BRUSH face would take the drop, re-yielding the moment the cursor moves
## off brushes (see _process). Claiming shadows Godot's own viewport drop on purpose (its
## material_override fights the brush's per-face materials); yielding hands that same built-in
## behaviour back for non-brush meshes, so props still take material drops.
##
## The control is a dumb catcher: the PLUGIN decides whether a face is under the cursor (`probe`),
## draws the drop highlight, and commits the drop (`commit`) — it owns the raycast and the undo
## manager, exactly as it does for the texture dock.

## Matches the texture dock's scan list, so anything browsable is also droppable.
const IMAGE_EXTENSIONS := ["png", "jpg", "jpeg", "webp", "tga", "bmp"]
const RESOURCE_EXTENSIONS := ["tres", "res", "material"]

var probe: Callable      ## func(camera: Camera3D, pos: Vector2) -> bool — face under the cursor?
var commit: Callable     ## func(surface: Resource, camera: Camera3D, pos: Vector2) — apply it (tex or material)
var reset: Callable      ## func() — the drag ended or left this viewport; clear any highlight
var viewport: SubViewport  ## the editor viewport this control covers (camera + pixel size)


## Whether a drag this catcher can land is currently live. Guards _process: Godot force-enables
## processing at READY for any script that defines _process, so set_process alone can't be
## trusted to keep the claim check off outside drags.
var _drag_live := false


func _init() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE


func _ready() -> void:
	# After READY's automatic set_process(true), so it sticks (in _init it would be overridden).
	set_process(false)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_DRAG_BEGIN:
			# Every Control hears this regardless of its mouse filter — only a drag that carries
			# something a face can wear starts the per-frame claim check; every other drag passes
			# through untouched.
			if extract_surface(get_viewport().gui_get_drag_data()) != null:
				_drag_live = true
				set_process(true)
		NOTIFICATION_DRAG_END:
			_drag_live = false
			set_process(false)
			mouse_filter = MOUSE_FILTER_IGNORE
			_reset()
		NOTIFICATION_MOUSE_EXIT:
			_reset()   # the drag moved to another viewport or a dock; drop the highlight


## Runs only while a surface drag is live. Claim the mouse exactly while a brush face would take
## the drop; yield (IGNORE) otherwise so the drag falls through to Godot's built-in handling
## underneath. The filter can't be decided once at drag start — what's under the cursor changes
## as it moves, and going IGNORE also stops _can_drop_data queries, so this re-arms from outside.
func _process(_delta: float) -> void:
	if not _drag_live:
		mouse_filter = MOUSE_FILTER_IGNORE
		set_process(false)
		return
	var pos := get_local_mouse_position()
	if not Rect2(Vector2.ZERO, size).has_point(pos):
		mouse_filter = MOUSE_FILTER_IGNORE
		return
	var claimed: bool = probe.call(_camera(), _viewport_pos(pos))
	mouse_filter = MOUSE_FILTER_STOP if claimed else MOUSE_FILTER_IGNORE


func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if extract_surface(data) == null:
		return false
	return probe.call(_camera(), _viewport_pos(at_position))


func _drop_data(at_position: Vector2, data: Variant) -> void:
	var surface := extract_surface(data)
	if surface != null:
		commit.call(surface, _camera(), _viewport_pos(at_position))


func _reset() -> void:
	if reset.is_valid():
		reset.call()


func _camera() -> Camera3D:
	return viewport.get_camera_3d()


## Control-local position → viewport pixels. Identical unless the editor renders 3D at a reduced
## resolution (the SubViewport is then smaller than the container this control fills).
func _viewport_pos(pos: Vector2) -> Vector2:
	if size.x <= 0.0 or size.y <= 0.0:
		return pos
	return pos * Vector2(viewport.size) / size


## The FIRST surface a drag payload amounts to, or null. See surfaces_in() for the rules.
static func extract_surface(data: Variant) -> Resource:
	var all := surfaces_in(data)
	return all[0] if not all.is_empty() else null


## Every surface a drag payload amounts to: image files → textures, material files/resources → the
## material itself (a whole-material assign, NOT its albedo), Texture2D resources → textures. A
## multi-file drag yields several; anything unusable is skipped. Extension-gated so a stray drag of a
## scene or script never triggers a load.
static func surfaces_in(data: Variant) -> Array:
	var out: Array = []
	if typeof(data) != TYPE_DICTIONARY:
		return out
	match data.get("type", ""):
		"files":
			for path in data.get("files", []):
				var s := surface_from_path(path)
				if s != null:
					out.append(s)
		"resource":
			var s := surface_from_resource(data.get("resource"))
			if s != null:
				out.append(s)
	return out


static func surface_from_path(path: String) -> Resource:
	var ext := path.get_extension().to_lower()
	if IMAGE_EXTENSIONS.has(ext):
		return load(path) as Texture2D
	if RESOURCE_EXTENSIONS.has(ext) and ResourceLoader.exists(path):
		return surface_from_resource(load(path))
	return null


## A dropped resource as a paintable surface: a Material stays a Material (Godot's whole-material
## assign), a Texture2D stays a texture. A material's albedo is NOT unwrapped — dropping a material
## replaces the face's material rather than stealing only its texture.
static func surface_from_resource(res: Variant) -> Resource:
	if res is Material:
		return res
	if res is Texture2D:
		return res
	return null
