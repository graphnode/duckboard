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
//
// cull_disabled so the surface EXISTS FROM UNDERNEATH. Faces are back-face culled like any other
// geometry, and a swimmer is inside the brush looking at the back of its top face — so the water
// simply was not there from below, and surfacing had no visual moment at all. Two-sided costs one
// extra triangle's worth of fill on a handful of faces and buys the whole underside of the effect.
render_mode diffuse_lambert, specular_disabled, cull_disabled;

// repeat_enable is REQUIRED, not cosmetic: Duckboard bakes world-projected UVs in TILE units, so a
// face several metres across arrives with coordinates far outside 0..1 and would otherwise clamp
// to a smear of edge pixels. filter_nearest matches the plugin's own default material.
uniform sampler2D albedo : source_color, filter_nearest, repeat_enable;

// All three are in TILE units, so they are independent of the texture's resolution and of how the
// face is scaled: swapping a 64px water tile for a 256px one keeps the motion identical.
uniform float amplitude : hint_range(0.0, 0.5) = 0.08;
uniform float waves : hint_range(0.25, 8.0) = 1.0;
uniform float speed : hint_range(0.0, 8.0) = 1.5;

// How far the surface yields in the depth test, as a FRACTION of its distance from the camera.
// Proportional and not absolute on purpose: depth precision falls off with distance too, so a
// constant nudge that clears a fight up close does nothing at range.
uniform float depth_bias : hint_range(0.0, 0.02) = 0.002;

// Water loses to anything COPLANAR with it, deliberately.
//
// A dock, a pier deck or a ledge built flush with the waterline puts two surfaces at exactly the
// same depth, and the winner of that comparison is then decided by float rounding — which changes
// per pixel and per frame, and is seen as the pair flickering against each other. It only became
// visible when this shader went two-sided (see cull_disabled above): before that the top face did
// not exist from below and never met the underside of the pier at all.
//
// Pushing the water back settles it in the right direction. Solid geometry is the thing you can
// stand on, so it should win; the water plane is the thing that yields. In open water there is
// nothing to yield to and this changes nothing visible.
//
// The whole view-space position is scaled, not just its z. The camera sits at the view-space origin,
// so scaling moves the vertex ALONG the ray through it — screen position is x/z and y/z and both are
// unchanged, leaving depth as the only thing that moves. It also cannot divide by zero or normalize
// a zero vector, which the obvious "push along the view direction" spelling does for any vertex that
// lands on the camera — and a swimmer WILL put the camera inside this brush.
void vertex() {
	vec3 view = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	POSITION = PROJECTION_MATRIX * vec4(view * (1.0 + depth_bias), 1.0);
}

void fragment() {
	float t = TIME * speed;
	vec2 warped = UV + amplitude * vec2(
		sin(UV.y * waves * TAU + t),
		sin(UV.x * waves * TAU + t));
	ALBEDO = texture(albedo, warped).rgb;
	// If the underside comes out dark, the fix is `NORMAL = FRONT_FACING ? NORMAL : -NORMAL;` here.
	// It is left out because it depends on whether the engine has already flipped the normal for the
	// back face, and guessing wrong shades the ceiling of the pool in shadow — which reads as a hole
	// in the world. Lighting the underside as if it faced the sky is the physically nearer answer
	// either way: the light a swimmer sees came down THROUGH the surface.
}
