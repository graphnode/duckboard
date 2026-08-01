shader_type spatial;
// Quake-style turbulent water. The surface stays perfectly FLAT — what waves is the texture
// lookup, exactly as R_DrawTurbSurface did: each coordinate is displaced by a sine of the other
// axis, which is what gives the swirl rather than a plain shear in one direction.
//
// Displacing the vertices instead would look wrong here for two reasons: Quake's water never did
// it, and a Duckboard face is a planar polygon clipped out of a half-space, so bending it would
// pull the surface off the plane its neighbours are cut against and open seams at the edges.
//
// There IS a vertex() below and it does move every vertex, which is worth squaring with the
// paragraph above before you read it: it slides them along the view ray, so the projected silhouette
// comes out bit-identical and only the DEPTH changes. No shape displacement — a depth bias, and the
// distinction is the whole reason it is written the way it is.
//
// Unlit-ish on purpose: no specular, plain lambert. A retro water plane reads as flat colour, and
// a highlight sliding over a warped lookup gives the whole thing away as modern.
//
// cull_disabled so EVERY face of the volume exists from both sides. Faces are back-face culled like
// any other geometry, and a swimmer is inside the brush looking at the back of them — so the water
// simply was not there from below, and surfacing had no visual moment at all. Two-sided costs one
// extra triangle's worth of fill on a handful of faces and buys the whole underside of the effect.
//
//
// TWO-SIDED, BUT ONE LAYER — WHY THIS MATERIAL IS RENDERED TWICE
//
// Two-sided and see-through together mean a closed brush hands the camera TWO surfaces down every
// view ray: the one facing you and, behind it, the far side of the volume facing away. Both get
// blended, so the water doubles up wherever they overlap — and the far one is usually a wall, which
// takes almost nothing from a sun that lights the top fully, so it arrives as a dark panel hanging
// inside the cube. That is the bug this arrangement exists to kill. Only the NEAREST water surface
// should ever be shaded; a cube of water should look like a cube, not like an aquarium.
//
// Sorting cannot fix it, which is worth stating so nobody spends an afternoon on render_priority:
// every face of the brush carries this same material, so duckboard emits all six as ONE surface in
// ONE draw call (brush.gd `_build_mesh` groups faces by material), and a see-through brush lands in
// the transparent pass with depth writes off. Inside a single draw call the triangles go down in
// plane order and nothing re-sorts them, so which of the two layers wins is decided by how the
// brush's planes happen to be ordered — which is why it looked like one arbitrary side was picked on.
// There is no ordering left to correct. The far fragments have to not be produced at all.
//
// So the material is split across two passes, and `far_side` says which one is running:
//
//   pass 1 (this material)      far_side = false — draws only the faces turned TOWARDS the camera
//   pass 2 (its `next_pass`)    far_side = true  — draws only the faces turned AWAY
//
// with depth_draw_always so pass 1 leaves its depth behind. A convex solid gives at most one of each
// down any ray, so the two cases fall out on their own and neither needs to know where the camera is:
//
//   camera OUTSIDE   pass 1 draws the near face and writes depth; every far fragment in pass 2 is
//                    then behind something and fails the depth test. One layer.
//   camera INSIDE    every face is turned away, so pass 1 draws nothing at all and writes no depth;
//                    pass 2 draws the surface the swimmer is looking at. One layer.
//
// Culling would say this far more directly than the discard in fragment() does — pass 1 is cull_back
// and pass 2 is cull_front, and that is exactly what they mean. It is spelled as a uniform because
// cull mode is a RENDER MODE, fixed at compile time, and going that way would fork this file into two
// near-identical shaders that then have to be kept in step by hand. One shader, one uniform, one
// place to edit what water looks like.
render_mode diffuse_lambert, specular_disabled, cull_disabled, depth_draw_always;

// Which of the two passes above is running. The `next_pass` material sets it true; nothing else ever
// touches it. See the block comment — a lone material with this left false is not broken, it just
// goes back to being invisible from the inside.
//
// The one chore the split leaves behind: water.tres carries every other uniform TWICE, once per pass,
// so retuning `amplitude` or swapping the texture means doing it on both. Getting it wrong is quiet
// rather than loud — the passes never draw the same pixel, so the mismatch shows up only as the water
// changing character the moment you go under. `render_priority` is the exception and the two are
// meant to differ: the near pass sits at -1 and the far pass at 0, below the editor's grid overlay at
// 1 (brush.gd `_apply_grid_overlay`), which has to stay last of the three.
uniform bool far_side = false;

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

// The face's own OUTWARD normal, in world space, taken here because here is the last place it is
// still intact: cull_disabled makes the engine hand a back face a FLIPPED normal in fragment(), and
// the whole of pass 2 is back faces, so by the time the far side is being shaded the direction it
// actually points has been lost.
varying vec3 face_normal;

void vertex() {
	face_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 view = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	POSITION = PROJECTION_MATRIX * vec4(view * (1.0 + depth_bias), 1.0);
}

void fragment() {
	// The culling this pass would be doing if cull mode could come from a uniform — see the header.
	// Pass 1 keeps the faces turned towards the camera, pass 2 keeps the ones turned away, and no
	// pixel is ever claimed by both.
	if (FRONT_FACING == far_side) {
		discard;
	}
	// Lit by the face's OWN outward normal whichever side it is seen from, so the underside of the
	// surface shades exactly as the top does and the two passes cannot disagree about what a face
	// looks like. That is the physically nearer answer as well as the consistent one — the light a
	// swimmer sees came down THROUGH the surface. Stated rather than inherited, because pass 2 is
	// entirely back faces and their flipped normals would light the ceiling of the pool from below,
	// which reads as a hole in the world.
	NORMAL = normalize((VIEW_MATRIX * vec4(face_normal, 0.0)).xyz);

	float t = TIME * speed;
	vec2 warped = UV + amplitude * vec2(
		sin(UV.y * waves * TAU + t),
		sin(UV.x * waves * TAU + t));
	ALBEDO = texture(albedo, warped).rgb;
}
