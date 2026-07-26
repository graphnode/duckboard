shader_type spatial;
// Quake-style turbulent water. The surface stays perfectly FLAT — what waves is the texture
// lookup, exactly as R_DrawTurbSurface did: each coordinate is displaced by a sine of the other
// axis, which is what gives the swirl rather than a plain shear in one direction.
//
// Displacing the vertices instead would look wrong here for two reasons: Quake's water never did
// it, and a Duckboard face is a planar polygon clipped out of a half-space, so bending it would
// pull the surface off the plane its neighbours are cut against and open seams at the edges.
//
// Unlit-ish on purpose: no specular, plain lambert. A retro water plane reads as flat colour, and
// a highlight sliding over a warped lookup gives the whole thing away as modern.
render_mode diffuse_lambert, specular_disabled;

// repeat_enable is REQUIRED, not cosmetic: Duckboard bakes world-projected UVs in TILE units, so a
// face several metres across arrives with coordinates far outside 0..1 and would otherwise clamp
// to a smear of edge pixels. filter_nearest matches the plugin's own default material.
uniform sampler2D albedo : source_color, filter_nearest, repeat_enable;

// All three are in TILE units, so they are independent of the texture's resolution and of how the
// face is scaled: swapping a 64px water tile for a 256px one keeps the motion identical.
uniform float amplitude : hint_range(0.0, 0.5) = 0.08;
uniform float waves : hint_range(0.25, 8.0) = 1.0;
uniform float speed : hint_range(0.0, 8.0) = 1.5;

void fragment() {
	float t = TIME * speed;
	vec2 warped = UV + amplitude * vec2(
		sin(UV.y * waves * TAU + t),
		sin(UV.x * waves * TAU + t));
	ALBEDO = texture(albedo, warped).rgb;
}
