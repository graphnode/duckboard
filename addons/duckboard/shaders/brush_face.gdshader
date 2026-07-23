shader_type spatial;

// Brush face: as SIMPLE as a textured surface can be, so it stays swappable — a user can drop in
// their own material (or replace this with a StandardMaterial3D) and lose nothing but the two
// editor aids below. Everything world-space that used to live here — the grid — moved out to
// brush_grid.gdshader, attached as a material_overlay only in the editor.
//
// The texture UV is BAKED into the mesh's UV channel by Brush._build_mesh, so there is no
// projection to do here: just sample. Baking is exact because uv = dot(world, axis) + offset is
// affine, and it lets every face that shares a texture share one material (one draw call).

uniform sampler2D albedo_tex : source_color, filter_nearest, repeat_enable;
uniform float roughness_val : hint_range(0.0, 1.0) = 0.9;

// Clip-tool preview. Fragments on this plane's OUTWARD side belong to the piece the clip would
// remove, and are punched out in a screen-space checkerboard so the geometry BEHIND them shows
// through — a 2D overlay drawn over the viewport can only tint, never reveal what's occluded.
//
// This is the one editor aid kept in the BASE material, because it works by `discard` and an
// overlay pass cannot remove the base surface's pixels. It costs one varying and a branch that is
// dead whenever no clip is in progress; a user who swaps the material simply loses the clip
// preview on it, which is fine for an editor-only affordance. `discard` rather than ALPHA keeps the
// material opaque — writing ALPHA would force the whole level into the transparent pass.
uniform vec4 clip_ghost_plane = vec4(0.0);   // xyz = world normal, w = distance; zero = off

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (dot(clip_ghost_plane.xyz, clip_ghost_plane.xyz) > 0.0
			&& dot(world_pos, clip_ghost_plane.xyz) - clip_ghost_plane.w > 0.0) {
		// Screen-space checkerboard, so the holes stay a constant size on screen instead of
		// scaling with distance the way a world-space pattern would.
		if (mod(floor(FRAGCOORD.x) + floor(FRAGCOORD.y), 2.0) < 1.0) {
			discard;
		}
	}
	ALBEDO = texture(albedo_tex, UV).rgb;
	ROUGHNESS = roughness_val;
}
