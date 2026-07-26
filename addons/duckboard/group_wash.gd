@tool
extends CompositorEffect

## The isolation wash: a full-screen compute pass that fades the whole viewport toward white,
## EXCEPT inside the open group's box. Unity's prefab mode, in the Godot editor viewport.
##
## The point is spatial feedback. Hiding the rest of the map (a `cull_mask` solo) would isolate just
## as well, but you place a group BY its surroundings — a washed-out map still shows you where the
## grouped wall meets the room, a hidden one does not.
##
## Runs at PRE_TRANSPARENT, after opaque geometry and the sky. That is not for the transparent pass
## itself — nothing here relies on draw order — it is simply the last stage at which the colour
## buffer still holds the finished solid scene and nothing else.
##
## [b]Everything below _init runs on the RENDERING thread.[/b] The group's box arrives from the main
## thread through set_bounds() under a Mutex; nothing here ever touches a scene node.
##
## Attached to (and detached from) the editor's viewport cameras by [GroupIsolate] — see that file
## for the plumbing. Forward+ / Mobile only, which is what the compositor supports at all.

## How the exclusion works, and what it costs.
##
## The shader reconstructs each pixel's world position from the depth buffer, maps it into the open
## group's LOCAL space, and leaves the pixel alone if it lands inside the group's bounding box. The
## box is oriented, not axis-aligned — it is tested after the transform, so a rotated group keeps a
## tight fit instead of a swollen world-axis box around it.
##
## The alternative was to give the group's geometry transparent-pass materials so it would draw over
## the wash. That works, but it means duplicating and rewriting a material per surface, redoing it
## every time a member's mesh is rebuilt (which is every drag frame), and accepting that
## transparent-pass geometry is excluded from SSAO and screen-space reflections. A box test in the
## shader needs none of that and cannot fall out of step with the geometry.
##
## The price is that the exclusion is the BOX, not the geometry: another brush that pokes into the
## group's bounds also escapes the wash. In practice that reads as intended — what is interpenetrating
## the group is exactly the context you are aligning against — and the box is the group's own extent,
## so it is only ever generous around concave shapes.
const SHADER_SOURCE := """
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_image;

layout(push_constant, std430) uniform Params {
	mat4 clip_to_local;   // NDC -> the open group's local space, in one matrix
	vec4 box_min;         // xyz = the group's local AABB min, w = raster width
	vec4 box_max;         // xyz = the group's local AABB max, w = raster height
	vec4 tint;            // rgb = what the context fades toward, a = how far along it is
	vec4 wash;            // x = desaturate, y = depth remap, z = flip Y, w = unused
} params;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.box_min.w, params.box_max.w);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}

	// Reconstruct where this pixel actually is in the world, then in the group's frame.
	vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
	vec2 ndc_xy = uv * 2.0 - 1.0;
	if (params.wash.z > 0.5) {
		ndc_xy.y = -ndc_xy.y;
	}
	float depth = texelFetch(depth_image, pixel, 0).r;
	float ndc_z = params.wash.y > 0.5 ? depth * 2.0 - 1.0 : depth;

	vec4 local = params.clip_to_local * vec4(ndc_xy, ndc_z, 1.0);
	// w <= 0 is behind the eye or an unwritten depth sample: not in the box, so wash it.
	bool inside = false;
	if (local.w > 0.0) {
		vec3 p = local.xyz / local.w;
		inside = all(greaterThanEqual(p, params.box_min.xyz))
			&& all(lessThanEqual(p, params.box_max.xyz));
	}
	if (inside) {
		return;
	}

	// Both stages scale with the fade, so the pass is a no-op at 0 and the context settles into
	// place rather than snapping the instant a group opens.
	vec4 color = imageLoad(color_image, pixel);
	float grey = dot(color.rgb, vec3(0.2125, 0.7154, 0.0721));
	vec3 washed = mix(color.rgb, vec3(grey), params.wash.x);
	washed = mix(washed, params.tint.rgb, params.tint.a);
	imageStore(color_image, pixel, vec4(washed, color.a));
}
"""

## What the context fades toward, and how far. A dark neutral rather than white: the viewport is
## usually a lit map on a dark background, so washing toward white turns the whole screen into a
## light source and the group has to compete with it. Sinking the context instead leaves the group as
## the brightest thing on screen, which is the same separation without the glare.
##
## Desaturating first means a red wall and a blue one stop being tellable apart at a glance, so the
## eye goes to the group; the tint then keeps enough contrast to still read the silhouettes behind.
const TINT := Color(0.16, 0.16, 0.19)
const STRENGTH := 0.68
const DESATURATE := 0.8

## How long the wash takes to reach full strength, in seconds. Short enough not to feel like waiting,
## long enough that opening a group reads as the view settling rather than a flash.
const FADE_SECONDS := 0.18

## Where in the pipeline the wash runs, which decides what it can reach.
##
## POST_TRANSPARENT is after the transparent pass, so transparent materials are washed along with
## everything else — at PRE_TRANSPARENT they render over the finished wash and stay at full colour,
## which reads as a bug rather than as a rule. The cost is that transparent geometry writes no depth,
## so those pixels are tested against whatever opaque surface lies BEHIND them: a see-through panel
## in front of the group is washed with the wall behind it. That is the right answer far more often
## than it is the wrong one, since a panel is normally seen against the same context it belongs to.
const STAGE := EFFECT_CALLBACK_TYPE_POST_TRANSPARENT

## Two render-convention switches, kept as named constants because they are the only part of the
## depth reconstruction that cannot be reasoned out from the API alone, and each is a one-line flip
## if the wash comes out mirrored or the exclusion box lands at the wrong depth.
##
## The projection comes from the renderer itself, so its inverse already accounts for whatever depth
## range and reverse-Z the backend uses — hence both default to off. Vulkan's NDC has Y down, which
## is the same direction as the pixel coordinates we build the UV from, so they agree as they are.
const DEPTH_NDC_REMAP := false   # true if the depth sample needs [0,1] -> [-1,1]
const FLIP_Y := false            # true if the wash comes out vertically mirrored

## A little slack around the group so the box never crops the silhouette it is protecting — a face
## exactly on the boundary would otherwise flicker between washed and not as the camera moves.
const MARGIN := 0.02

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _sampler: RID

## The open group's box, written by the main thread and read by the render thread.
var _mutex := Mutex.new()
var _to_local := Projection()
var _box_min := Vector3.ZERO
var _box_max := Vector3.ZERO
var _fade := 0.0


func _init() -> void:
	effect_callback_type = STAGE
	needs_normal_roughness = false
	_rd = RenderingServer.get_rendering_device()


## The box to spare, in the group's own local space, plus the transform that gets there from world.
## Called from the main thread on every viewport redraw while a group is open (see GroupIsolate).
func set_bounds(world_to_local: Transform3D, box: AABB) -> void:
	_mutex.lock()
	_to_local = Projection(world_to_local)
	_box_min = box.position - Vector3.ONE * MARGIN
	_box_max = box.end + Vector3.ONE * MARGIN
	_mutex.unlock()


## How far into the fade we are, 0 to 1. Zero parks the effect without detaching it, which is what
## lets the wash fade back OUT on close instead of vanishing a frame before the group reassembles.
func set_fade(fade: float) -> void:
	_mutex.lock()
	_fade = fade
	_mutex.unlock()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd != null:
		# Freeing the shader takes the pipeline with it (the device tracks the dependency); the
		# sampler is independent and has to go separately.
		if _shader.is_valid():
			_rd.free_rid(_shader)
		if _sampler.is_valid():
			_rd.free_rid(_sampler)


## Compile on first use, on the render thread. Compiling from source rather than shipping a `.glsl`
## costs one compile per editor session and saves an imported resource, its `.import` sidecar and a
## reimport step in the addon a user copies into their project.
func _ensure_pipeline() -> bool:
	if _pipeline.is_valid():
		return true
	if _rd == null:
		return false

	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = SHADER_SOURCE
	var spirv := _rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		push_error("[duckboard] group wash shader: " + spirv.compile_error_compute)
		return false
	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		return false

	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(state)

	_pipeline = _rd.compute_pipeline_create(_shader)
	return _pipeline.is_valid()


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if _rd == null or callback_type != STAGE:
		return
	_mutex.lock()
	var fade := _fade
	var to_local := _to_local
	var box_min := _box_min
	var box_max := _box_max
	_mutex.unlock()
	if fade <= 0.0 or not _ensure_pipeline():
		return

	var buffers: RenderSceneBuffersRD = render_data.get_render_scene_buffers()
	var scene: RenderSceneDataRD = render_data.get_render_scene_data()
	if buffers == null or scene == null:
		return
	# The INTERNAL size: the 3D render resolution before any upscale, which is what the buffers we
	# are about to read and write are actually sized to.
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return

	var groups_x := (size.x - 1) / 8 + 1
	var groups_y := (size.y - 1) / 8 + 1

	for view in buffers.get_view_count():
		# NDC -> view -> world -> group-local, collapsed into one matrix so the shader does a single
		# multiply per pixel. Inverting the renderer's OWN projection is what makes the depth
		# decoding correct without knowing its near/far or depth range.
		var clip_to_local := to_local * Projection(scene.get_cam_transform()) \
			* scene.get_view_projection(view).inverse()

		var push := PackedFloat32Array()
		for column in [clip_to_local.x, clip_to_local.y, clip_to_local.z, clip_to_local.w]:
			push.append_array([column.x, column.y, column.z, column.w])
		push.append_array([box_min.x, box_min.y, box_min.z, float(size.x)])
		push.append_array([box_max.x, box_max.y, box_max.z, float(size.y)])
		push.append_array([TINT.r, TINT.g, TINT.b, STRENGTH * fade])
		push.append_array([DESATURATE * fade,
			1.0 if DEPTH_NDC_REMAP else 0.0, 1.0 if FLIP_Y else 0.0, 0.0])

		var color := RDUniform.new()
		color.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		color.binding = 0
		color.add_id(buffers.get_color_layer(view))

		var depth := RDUniform.new()
		depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		depth.binding = 1
		depth.add_id(_sampler)
		depth.add_id(buffers.get_depth_layer(view))

		# The cache invalidates itself when the viewport is reconfigured and the buffers change, so
		# this neither leaks sets nor hands the shader a stale buffer.
		var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, [color, depth])

		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, _pipeline)
		_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		_rd.compute_list_set_push_constant(list, push.to_byte_array(), push.size() * 4)
		_rd.compute_list_dispatch(list, groups_x, groups_y, 1)
		_rd.compute_list_end()
