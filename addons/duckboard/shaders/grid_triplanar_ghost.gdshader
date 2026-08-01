shader_type spatial;
// depth_prepass_alpha: the ghost writes depth in a pre-pass, so its own NEAR faces occlude its far
// ones (and, for multi-brush shapes like stairs or a hollow cylinder, near brushes occlude far
// brushes) instead of every transparent face blending at full strength. depth_draw_never left the
// far grid showing through the near grid, which read as visual noise — TrenchBroom depth-sorts here.
// default cull_back: back faces of each convex piece are still dropped.
render_mode unshaded, depth_prepass_alpha;

// Transparent world-space grid for the brush "ghost" preview. Same world-space grid as the
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
// World-space line thickness, matching brush_grid.gdshader — see there for why the width lives in
// metres instead of pixels. The two have to agree or the brush changes appearance the instant the
// ghost becomes real.
uniform float line_width : hint_range(0.001, 0.2) = 0.02;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// World-space thickness with a one-pixel AA ramp — identical to brush_grid.gdshader, which carries
// the full reasoning.
float grid_coverage(vec2 coord, float size) {
	vec2 d = abs(fract(coord / size - 0.5) - 0.5) * size;
	vec2 aa = max(fwidth(coord), vec2(1e-8));
	vec2 cov = clamp((line_width * 0.5 - d) / aa + 0.5, 0.0, 1.0);
	return max(cov.x, cov.y);
}

// Winner-take-all dominant-axis pick, same as brush_grid.gdshader (TrenchBroom's Grid.fragsh):
// one projection per face at full strength, so a rotated ghost shows a clean grid instead of
// three superimposed half-faded line families. Flat faces mean a constant normal, so no popping.
// Tie-break table (>=, X then Y then Z) matches _snap_on_face — see brush_grid.gdshader for why
// the tables must agree exactly.
vec2 dominant_plane() {
	vec3 n = abs(world_normal);
	if (n.x >= n.y && n.x >= n.z) {
		return world_pos.yz;
	}
	if (n.y >= n.z) {
		return world_pos.xz;
	}
	return world_pos.xy;
}

float face_grid(float size) {
	return grid_coverage(dominant_plane(), size);
}

void fragment() {
	float minor = face_grid(cell_size);
	float major = face_grid(major_size);

	vec3 rgb = face_color.rgb;
	float a = face_color.a;
	rgb = mix(rgb, line_color.rgb, minor);
	a = max(a, minor * line_color.a);
	rgb = mix(rgb, major_color.rgb, major);
	a = max(a, major * major_color.a);

	ALBEDO = rgb;
	ALPHA = a;
}
