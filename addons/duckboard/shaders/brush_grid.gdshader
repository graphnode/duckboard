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
// Grey rather than white, and faint. The grid is a ruler laid over the work, not part of it: white
// lines at these alphas lift the whole surface toward the fog colour and read as a haze on the
// texture, where a darker grey reads as a line drawn ON it. Minor and major differ only in weight —
// same hue, so the two tiers are one grid at two strengths instead of two competing overlays.
uniform vec4 grid_color : source_color = vec4(0.45, 0.45, 0.48, 0.09);
uniform vec4 major_color : source_color = vec4(0.55, 0.55, 0.58, 0.18);

// Line thickness in WORLD metres (0.02 m = 0.64 TB units), the same for both tiers so the major
// lines read as brighter rather than fatter. World-space is the point: the line is part of the
// scene, so it takes perspective like everything else — thick with your nose against a wall,
// a hairline across the far end of the room. A screen-space width (the fwidth trick) would instead
// hold it at one pixel by silently growing the line in world terms as it recedes.
uniform float line_width : hint_range(0.001, 0.2) = 0.02;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// Coverage of a `line_width`-thick world-space line every `size` units.
//
// `d` is the world distance from this fragment to the nearest grid line, so the line's footprint on
// screen is decided by perspective alone — nothing here compensates for distance or viewing angle.
// fwidth survives for ONE job only: `aa` is how much world the pixel spans, which turns the hard
// in/out test into a one-pixel ramp. Without it a receding line alternates between fully on and
// fully off along the surface and crawls as the camera moves.
//
// The clamp is what makes the far field behave. Once a pixel spans more world than the line is
// thick, `half_w / aa` shrinks below the 0.5 the ramp is centred on and coverage decays on its own
// — no distance term, just a line honestly reported as too thin to fill a pixel.
float grid_coverage(vec2 coord, float size) {
	vec2 d = abs(fract(coord / size - 0.5) - 0.5) * size;
	vec2 aa = max(fwidth(coord), vec2(1e-8));
	vec2 cov = clamp((line_width * 0.5 - d) / aa + 0.5, 0.0, 1.0);
	return max(cov.x, cov.y);
}

// The single world plane this face most points along — TrenchBroom's winner-take-all axis pick
// (Grid.fragsh), not a blend. Blending by the normal drew the OTHER projections' line families
// across a rotated face as half-strength ghosts spaced wider than a cell, while dimming the lines
// that belonged there. A brush face is flat, so its normal is constant and a hard pick cannot pop
// mid-face; the dropped projections are exactly the lines TrenchBroom never draws.
// The tie-break table (>=, X then Y then Z) matches _snap_on_face and the hull tool's _onto_plane
// EXACTLY. On a face rotated to a perfect 45° two normal components tie, and if this table breaks
// the tie differently from the snap code the tools snap points on one projection while the grid
// draws another — the silhouette visibly off the lines it is supposed to sit on.
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

// Always WORLD space: it represents the editor's grid, not the brush, so it deliberately does not
// turn with geometry.
float face_grid(float size) {
	return grid_coverage(dominant_plane(), size);
}

void fragment() {
	// Major lines are a fixed 2 m reference, but the two coarsest grids (128 TB = 4 m, 256 TB = 8 m)
	// are coarser than that — a finer "major" grid drawn over a coarser minor one reads as the wrong
	// spacing entirely. Clamp so the major interval is never finer than the cell: at those sizes the
	// two tiers coincide and the grid simply shows at its own size.
	float major_interval = max(major_size, cell_size);
	float minor = face_grid(cell_size) * grid_color.a;
	float major = face_grid(major_interval) * major_color.a;
	// Major drawn over minor: same layering the old combined shader used, now expressed as one
	// translucent output instead of two mixes onto the texture.
	ALBEDO = mix(grid_color.rgb, major_color.rgb, major);
	ALPHA = max(minor, major);
}
