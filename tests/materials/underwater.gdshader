shader_type canvas_item;
// The view from inside the water, drawn as a full-screen pass over the finished frame — see
// fps_player.gd `_build_underwater_overlay`, which builds the CanvasLayer and ColorRect that carry
// it and shows them only while the CAMERA is submerged (the eye probe, not the waist one).
//
// A screen-space pass and not a fog volume or a second camera, because the thing being conveyed is
// "you are looking through water", which is a property of the viewer rather than of the scene. It
// also means a map needs nothing added to it: any brush set to Trigger Volume becomes swimmable and
// looks like water from the inside, with no per-map setup.
//
// Displacement is deliberately the SAME RULE as water.gdshader — each axis warped by a sine of the
// other, Quake's R_DrawTurbSurface — so the surface you see from above and the view you get from
// below are visibly the same phenomenon rather than two unrelated effects that happen to share a
// colour. Amplitude is far smaller here: this is a whole screen, and what reads as a lazy swirl on a
// texture reads as a broken monitor across the viewport.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;

// Multiplied, not blended over: water DARKENS what it filters, and a tint laid on top instead
// washes the scene toward pastel and loses the depth cue entirely. The x3 lifts the mid channel
// back to roughly unity so only the balance changes, not the overall exposure.
uniform vec3 water_tint : source_color = vec3(0.16, 0.44, 0.52);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.55;
// Colour goes first: submerged light loses saturation before it loses brightness.
uniform float desaturation : hint_range(0.0, 1.0) = 0.35;

uniform float amplitude : hint_range(0.0, 0.05) = 0.006;
uniform float waves : hint_range(0.5, 16.0) = 5.0;
uniform float speed : hint_range(0.0, 8.0) = 1.5;

// Closes the frame in, which is what actually sells "submerged" — more than the colour does. It
// stands in for the light falling off with distance in every direction rather than just forward.
uniform float edge_darkening : hint_range(0.0, 1.0) = 0.55;

void fragment() {
	float t = TIME * speed;
	vec2 warped = SCREEN_UV + amplitude * vec2(
		sin(SCREEN_UV.y * waves * TAU + t),
		sin(SCREEN_UV.x * waves * TAU + t));
	// CLAMPED rather than left to the sampler. A sample that runs off the edge is either wrapped —
	// pulling the far side of the screen into the near one, which reads as a tear — or stretched
	// from the border pixel, which is the lesser of the two and what this asks for.
	warped = clamp(warped, vec2(0.0), vec2(1.0));

	vec3 col = texture(screen_tex, warped).rgb;
	float lum = dot(col, vec3(0.2126, 0.7152, 0.0722));
	col = mix(col, vec3(lum), desaturation);
	col = mix(col, col * water_tint * 3.0, tint_strength);

	float edge = smoothstep(0.25, 0.85, distance(SCREEN_UV, vec2(0.5)));
	col *= 1.0 - edge * edge_darkening;

	COLOR = vec4(col, 1.0);
}
