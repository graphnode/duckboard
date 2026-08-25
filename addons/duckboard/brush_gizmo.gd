@tool
extends EditorNode3DGizmoPlugin
## Makes a [Brush] selectable by GODOT'S OWN viewport picking — with no owner, no dock entry and
## nothing serialized. PROTOTYPE: see the trade-offs at the end.
##
## The editor picks nodes through two channels. Visual instances resolve a hit by walking up
## [code]get_owner()[/code] — which a brush's unowned generated mesh stops dead, and ownership
## cannot be granted without also serializing the mesh and listing it in the Scene dock (one flag
## drives all three). Lights, cameras and markers use the OTHER channel: their gizmo declares
## collision geometry, and [code]gizmo_bvh_ray_query[/code] picks the NODE the gizmo belongs to.
## That channel is scriptable, and this plugin puts a brush's own triangles on it: the editor's
## stock click-select now answers with the [Brush] node itself.
##
## What this buys, before any ladder logic is touched: a brush is clickable in the states where
## Duckboard hands the viewport to the editor — the duck toggle OFF, and the stand-down while a
## foreign node is selected — where it used to be reachable only from the Scene dock or through
## the deferred recapture. The press ladder is unchanged; with the mode on, Duckboard still claims
## presses before the editor sees them.
##
## The gizmo draws NOTHING — collision triangles only, so there is no visual double of the mesh
## and nothing new on screen. The triangles are the editor build's (nodraw faces included), read
## straight off the generated mesh: brush, body and mesh all sit at identity to one another, so
## mesh-local IS gizmo-local and no transform bookkeeping exists to go stale.
##
## Kept in step by [method Brush.piece_changed] calling [code]update_gizmos()[/code] on geometry
## changes — not on UV changes, which cannot move a triangle.
##
## Known prototype caveats, to verify in use: the View ▸ Gizmos menu lists "Brush" and hiding it
## there silently turns this picking off; and the editor's box select may or may not include
## gizmo-collision nodes (its region test predates this use).

const BRUSH_SCRIPT := preload("res://addons/duckboard/brush.gd")


func _get_gizmo_name() -> String:
	return "Brush"


func _has_gizmo(node: Node3D) -> bool:
	return node is Brush


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var brush := gizmo.get_node_3d() as Brush
	if brush == null or not is_instance_valid(brush):
		return
	var mesh: Mesh = brush.get_mesh_instance().mesh
	if mesh == null or mesh.get_surface_count() == 0:
		return
	gizmo.add_collision_triangles(mesh.generate_triangle_mesh())
