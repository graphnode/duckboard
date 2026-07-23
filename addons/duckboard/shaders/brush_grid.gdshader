shader_type spatial;

// The editor's world-space grid, drawn as a material_overlay — a SECOND pass over the brush mesh,
// on top of whatever base material the brush (or the user) supplies. Splitting it out is what lets
// the base material stay trivial and fully swappable: this shader owns everything world-space, and
// the plugin only attaches it in the editor, so the shipped brush never carries it.
//
// Transparent and unshaded: it contributes grid lines and nothing else, so away from a line ALPHA
// is 0 and the base material shows through untouched. depth_draw_never keeps it from writing depth
// over the surface it sits on.
render_mode blend_mix, cull_back, unshaded, depth_draw_never;

uniform float cell_size = 0.5;
// Major lines sit at a FIXED world interval (TrenchBroom uses 64 units = 2 m), so they stay put as
// the grid size changes rather than scaling with it.
uniform float major_size = 2.0;
uniform vec4 grid_color : source_color = vec4(1.0, 1.0, 1.0, 0.15);
uniform vec4 major_color : source_color = vec4(1.0, 1.0, 1.0, 0.30);

// Grid fade. Measured in cells-per-pixel: once a cell shrinks toward the size of a pixel the lines
// merge and wash the surface out, so we fade that layer instead. Distance-driven in practice
// (further = denser), and it also handles grazing angles.
uniform float fade_start : hint_range(0.0, 1.0) = 0.20;
uniform float fade_end : hint_range(0.0, 2.0) = 0.80;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// Anti-aliased line coverage every `size` units (fwidth keeps lines ~1px at any distance), faded
// out once the cells get too small on screen to read as a grid.
float grid_coverage(vec2 coord, float size) {
	vec2 c = coord / size;
	vec2 w = fwidth(c);
	vec2 g = abs(fract(c - 0.5) - 0.5) / w;
	float coverage = 1.0 - min(min(g.x, g.y), 1.0);
	return coverage * (1.0 - smoothstep(fade_start, fade_end, max(w.x, w.y)));
}

// Grid for whichever world axes this face points along, blended by its normal. Always WORLD space:
// it represents the editor's grid, not the brush, so it deliberately does not turn with geometry.
float triplanar_grid(float size) {
	vec3 n = abs(world_normal);
	n /= max(n.x + n.y + n.z, 1e-5);
	return grid_coverage(world_pos.yz, size) * n.x
		+ grid_coverage(world_pos.xz, size) * n.y
		+ grid_coverage(world_pos.xy, size) * n.z;
}

void fragment() {
	// Major lines are a fixed 2 m reference, but the two coarsest grids (128 TB = 4 m, 256 TB = 8 m)
	// are coarser than that — a finer "major" grid drawn over a coarser minor one reads as the wrong
	// spacing entirely. Clamp so the major interval is never finer than the cell: at those sizes the
	// two tiers coincide and the grid simply shows at its own size.
	float major_interval = max(major_size, cell_size);
	float minor = triplanar_grid(cell_size) * grid_color.a;
	float major = triplanar_grid(major_interval) * major_color.a;
	// Major drawn over minor: same layering the old combined shader used, now expressed as one
	// translucent output instead of two mixes onto the texture.
	ALBEDO = mix(grid_color.rgb, major_color.rgb, major);
	ALPHA = max(minor, major);
}
