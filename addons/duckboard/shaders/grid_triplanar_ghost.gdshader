shader_type spatial;
// depth_prepass_alpha: the ghost writes depth in a pre-pass, so its own NEAR faces occlude its far
// ones (and, for multi-brush shapes like stairs or a hollow cylinder, near brushes occlude far
// brushes) instead of every transparent face blending at full strength. depth_draw_never left the
// far grid showing through the near grid, which read as visual noise — TrenchBroom depth-sorts here.
// default cull_back: back faces of each convex piece are still dropped.
render_mode unshaded, depth_prepass_alpha;

// Transparent triplanar grid for the brush "ghost" preview. Same world-space grid as the
// real brush material, but semi-transparent faces with brighter grid lines, so you can see
// through it while placing. Kept as a separate shader so the opaque brush material stays
// pristine (writing ALPHA would push it into the transparent pipeline).

uniform float cell_size = 1.0;
uniform float major_size = 2.0;   // fixed world interval (64 TB units), not a grid multiple
// TrenchBroom ghost palette: dark warm fill, soft light-grey grid, red edges (edges are
// drawn separately as a wireframe). Tuned to match TB's new-brush preview.
uniform vec4 face_color : source_color = vec4(0.30, 0.31, 0.33, 0.72);
uniform vec4 line_color : source_color = vec4(0.78, 0.78, 0.80, 0.45);
uniform vec4 major_color : source_color = vec4(0.90, 0.90, 0.92, 0.65);

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float grid_coverage(vec2 coord, float size) {
	vec2 c = coord / size;
	vec2 g = abs(fract(c - 0.5) - 0.5) / fwidth(c);
	return 1.0 - min(min(g.x, g.y), 1.0);
}

float triplanar_grid(float size) {
	vec3 n = abs(world_normal);
	n /= max(n.x + n.y + n.z, 1e-5);
	float gx = grid_coverage(world_pos.yz, size);
	float gy = grid_coverage(world_pos.xz, size);
	float gz = grid_coverage(world_pos.xy, size);
	return gx * n.x + gy * n.y + gz * n.z;
}

void fragment() {
	float minor = triplanar_grid(cell_size);
	float major = triplanar_grid(major_size);

	vec3 rgb = face_color.rgb;
	float a = face_color.a;
	rgb = mix(rgb, line_color.rgb, minor);
	a = max(a, minor * line_color.a);
	rgb = mix(rgb, major_color.rgb, major);
	a = max(a, major * major_color.a);

	ALBEDO = rgb;
	ALPHA = a;
}
