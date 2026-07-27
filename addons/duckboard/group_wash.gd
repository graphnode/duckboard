@tool
extends CompositorEffect

## The isolation wash: a full-screen compute pass that fades the whole viewport toward white,
## EXCEPT inside the open group's member boxes. Unity's prefab mode, in the Godot editor viewport.
##
## The point is spatial feedback. Hiding the rest of the map (a `cull_mask` solo) would isolate just
## as well, but you place a group BY its surroundings — a washed-out map still shows you where the
## grouped wall meets the room, a hidden one does not.
##
## Runs at PRE_TRANSPARENT, after opaque geometry and the sky. That is not for the transparent pass
## itself — nothing here relies on draw order — it is simply the last stage at which the colour
## buffer still holds the finished solid scene and nothing else.
##
## [b]Everything below _init runs on the RENDERING thread.[/b] The group's boxes arrive from the
## main thread through set_bounds() under a Mutex; nothing here ever touches a scene node.
##
## Attached to (and detached from) the editor's viewport cameras by [GroupIsolate] — see that file
## for the plumbing. Forward+ / Mobile only, which is what the compositor supports at all.

## How the exclusion works, and what it costs.
##
## The shader reconstructs each pixel's world position from the depth buffer, maps it into the open
## group's LOCAL space, and leaves the pixel alone if it lands inside any member's bounding box.
## The boxes are oriented, not axis-aligned — tested after the transform, so a rotated group keeps
## a tight fit instead of a swollen world-axis box around it.
##
## The alternative was to give the group's geometry transparent-pass materials so it would draw over
## the wash. That works, but it means duplicating and rewriting a material per surface, redoing it
## every time a member's mesh is rebuilt (which is every drag frame), and accepting that
## transparent-pass geometry is excluded from SSAO and screen-space reflections. A box test in the
## shader needs none of that and cannot fall out of step with the geometry.
##
## The price is that the exclusion is boxes, not the geometry itself. It used to be ONE box — the
## group's whole extent — which spared everything inside it, including outside brushes that merely
## poked into the group's bounds; they sat there at full colour, reading as members. It is now one
## box PER MEMBER, so the spared region hugs the actual solids and context escapes the wash only
## where it genuinely interpenetrates a member.
const SHADER_SOURCE := """
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_image;
// Per-member boxes in the group's local space, packed as [min.xyz, pad][max.xyz, pad] pairs.
layout(set = 0, binding = 2, std430) restrict readonly buffer Boxes {
	vec4 data[];
} boxes;

layout(push_constant, std430) uniform Params {
	mat4 clip_to_local;   // NDC -> the open group's local space, in one matrix
	vec4 sizes;           // x = raster width, y = raster height, z = box count
	vec4 tint;            // rgb = what the context fades toward, a = how far along it is
	vec4 wash;            // x = desaturate, y = depth remap, z = flip Y, w = unused
} params;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.sizes.xy);
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
	// w <= 0 is behind the eye or an unwritten depth sample: not in any box, so wash it.
	bool inside = false;
	if (local.w > 0.0) {
		vec3 p = local.xyz / local.w;
		int count = int(params.sizes.z);
		for (int i = 0; i < count; i++) {
			if (all(greaterThanEqual(p, boxes.data[i * 2].xyz))
					&& all(lessThanEqual(p, boxes.data[i * 2 + 1].xyz))) {
				inside = true;
				break;
			}
		}
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

## The open group's per-member boxes, written by the main thread and read by the render thread.
## Packed ready for the GPU: 8 floats per box, [min.xyz, 0, max.xyz, 0], margin already applied.
var _mutex := Mutex.new()
var _to_local := Projection()
var _boxes := PackedFloat32Array()
var _fade := 0.0
# Render-thread only: the storage buffer the packed boxes upload into, recreated when the count
# changes and updated in place otherwise (the RID is part of the uniform-set cache key).
var _box_buffer := RID()
var _box_buffer_size := 0


func _init() -> void:
	effect_callback_type = STAGE
	needs_normal_roughness = false
	_rd = RenderingServer.get_rendering_device()


## The boxes to spare — one per member — in the group's own local space, plus the transform that
## gets there from world. Called from the main thread on every viewport redraw while a group is
## open (see GroupIsolate).
func set_bounds(world_to_local: Transform3D, boxes: Array) -> void:
	var packed := PackedFloat32Array()
	for box: AABB in boxes:
		var lo := box.position - Vector3.ONE * MARGIN
		var hi := box.end + Vector3.ONE * MARGIN
		packed.append_array([lo.x, lo.y, lo.z, 0.0, hi.x, hi.y, hi.z, 0.0])
	_mutex.lock()
	_to_local = Projection(world_to_local)
	_boxes = packed
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
		if _box_buffer.is_valid():
			_rd.free_rid(_box_buffer)


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
	var packed_boxes := _boxes
	_mutex.unlock()
	if fade <= 0.0 or not _ensure_pipeline():
		return

	# Upload the boxes. An empty list still uploads one degenerate box so the buffer binding is
	# always valid; count 0 in the push constant means the loop never reads it anyway.
	var box_count := packed_boxes.size() / 8
	if packed_boxes.is_empty():
		packed_boxes = PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	var box_bytes := packed_boxes.to_byte_array()
	if not _box_buffer.is_valid() or _box_buffer_size != box_bytes.size():
		if _box_buffer.is_valid():
			_rd.free_rid(_box_buffer)
		_box_buffer = _rd.storage_buffer_create(box_bytes.size(), box_bytes)
		_box_buffer_size = box_bytes.size()
	else:
		_rd.buffer_update(_box_buffer, 0, box_bytes.size(), box_bytes)

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
		push.append_array([float(size.x), float(size.y), float(box_count), 0.0])
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

		var box_uniform := RDUniform.new()
		box_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		box_uniform.binding = 2
		box_uniform.add_id(_box_buffer)

		# The cache invalidates itself when the viewport is reconfigured and the buffers change, so
		# this neither leaks sets nor hands the shader a stale buffer.
		var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, [color, depth, box_uniform])

		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, _pipeline)
		_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		_rd.compute_list_set_push_constant(list, push.to_byte_array(), push.size() * 4)
		_rd.compute_list_dispatch(list, groups_x, groups_y, 1)
		_rd.compute_list_end()
