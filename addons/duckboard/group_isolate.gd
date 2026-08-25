extends RefCounted

## Puts the isolation wash on the editor's own 3D viewports while a group is open, and takes it off
## again cleanly. The shader lives in [GroupWash]; this is the main-thread half — which cameras get
## the compositor, and keeping the excluded boxes in step with the group as it is edited.
##
## A [Compositor] set on a [Camera3D] applies to that camera's viewport only, which is exactly the
## granularity wanted here: the editor's viewport cameras are not part of the user's scene, so
## nothing is serialized and no WorldEnvironment is disturbed. The previous compositor is remembered
## per camera and put back on exit, in case something else ever wants one.

const GroupWash := preload("res://addons/duckboard/group_wash.gd")

## The editor's 3D viewports, which the four-viewport layouts split between. There are always four
## slots regardless of the layout in use; the unused ones simply have no camera yet.
const VIEWPORT_COUNT := 4

var _wash: GroupWash
var _compositor: Compositor
## Camera -> the compositor it had before we touched it (usually null). Doubles as the record of
## which cameras we are currently attached to.
var _restore := {}
## The fade, and where it is heading: 1 while a group is open, 0 once it closes. Detaching is
## deferred until it actually reaches 0, so the wash lifts smoothly instead of cutting out.
var _fade := 0.0
var _target := 0.0


## Start washing everything outside `group`. Idempotent: opening a second group while one is open
## just re-points the box.
func enter(group: Node3D, extras: Array = []) -> void:
	if _wash == null:
		_wash = GroupWash.new()
		_compositor = Compositor.new()
		_compositor.compositor_effects = [_wash]
	_target = 1.0
	_wash.set_fade(_fade)
	sync(group, extras)
	for i in VIEWPORT_COUNT:
		var viewport := EditorInterface.get_editor_viewport_3d(i)
		if viewport == null:
			continue
		var camera := viewport.get_camera_3d()
		if camera == null or _restore.has(camera):
			continue
		_restore[camera] = camera.compositor
		camera.compositor = _compositor


## Push the open group's per-member boxes to the render thread. Called on every viewport redraw,
## because a member being dragged moves its box and the wash has to follow it within the same frame.
##
## The boxes come from the solid's pieces, which a tool writes straight into — so they now track a
## drag as it happens rather than lagging a commit behind it, as they did when the live geometry sat
## in scratch nodes waiting to be folded back. MARGIN in [GroupWash] still covers the overshoot.
func sync(group: Node3D, extras: Array = []) -> void:
	if _wash == null:
		return
	if group == null or not is_instance_valid(group) or not group.has_method("local_bounds_list"):
		return
	var to_group: Transform3D = group.global_transform.affine_inverse()
	var boxes: Array[AABB] = group.local_bounds_list()
	# Geometry drawn INTO the open group lives as an owned child brush until the close folds it in
	# (see Duckboard._brush_parent) — spared here too, or a freshly drawn member sits washed white
	# until the group is closed and reopened. Each child's boxes fold through its own pose into the
	# group's frame, which is the space the shader tests in.
	for child in group.get_children():
		if child is Brush and child.owner != null and child.is_inside_tree():
			var into_group: Transform3D = to_group * (child as Node3D).global_transform
			for box in (child as Brush).local_bounds_list():
				boxes.append(into_group * box)
	# `extras` are the open group's LINKED TWINS (the host passes them): edits inside the group
	# land on them live, so washing them white would hide exactly the thing the link cue promises
	# to show. Folded through their own poses into the group frame, like the drawn-in children.
	for solid in extras:
		if solid is Brush and is_instance_valid(solid) and solid.is_inside_tree():
			var into_group: Transform3D = to_group * (solid as Node3D).global_transform
			for box in (solid as Brush).local_bounds_list():
				boxes.append(into_group * box)
	_wash.set_bounds(to_group, boxes)


## Advance the fade, and report whether it is still moving — the host keeps redrawing the viewport
## for as long as this returns true, since the editor only re-renders on demand and an animation
## nothing asks for would show as a single jump between two still frames.
func advance(delta: float) -> bool:
	if _wash == null:
		return false
	_fade = move_toward(_fade, _target, delta / GroupWash.FADE_SECONDS)
	_wash.set_fade(_fade)
	if _fade == 0.0 and _target == 0.0:
		_detach()      # fully lifted: give the cameras back
		return false
	return _fade != _target


## Begin lifting the wash. The cameras keep the compositor until the fade reaches zero (see
## advance), so calling this does not by itself put anything back.
func exit() -> void:
	_target = 0.0


## Drop the wash immediately, mid-fade or not — for teardown, where there is no next frame to finish
## an animation in.
func abort() -> void:
	_target = 0.0
	_fade = 0.0
	if _wash != null:
		_wash.set_fade(0.0)
	_detach()


func _detach() -> void:
	for camera in _restore:
		if is_instance_valid(camera):
			camera.compositor = _restore[camera]
	_restore.clear()
