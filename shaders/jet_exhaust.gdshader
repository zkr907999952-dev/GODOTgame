shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 u_color : source_color = vec3(0.85, 0.96, 1.0);
uniform float u_alpha = 0.7;

varying float v_t;
varying vec3 v_pos;

void vertex() {
	// Lathe mesh is authored along +Y in [ -0.5, 0.5 ]; after +90° X it points aft.
	v_t = VERTEX.y + 0.5;
	v_pos = VERTEX;
}

void fragment() {
	float t = clamp(v_t, 0.0, 1.0);
	float radial = length(v_pos.xz) * 2.0;
	float core = 1.0 - smoothstep(0.0, 0.62, radial);
	float head = smoothstep(0.0, 0.045, t);
	float tail = pow(1.0 - smoothstep(0.28, 1.0, t), 1.55);
	float a = head * tail * (0.22 + core * 0.88) * u_alpha;
	vec3 col = mix(u_color * 1.75, u_color * 0.05, pow(t, 0.62));
	ALBEDO = col;
	ALPHA = a;
}
