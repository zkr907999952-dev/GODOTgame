shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// Smooth polygonal / sheet-like LEX and dorsal vapor. Edges fade with a
// soft, natural alpha falloff — not a spherical blob.
uniform vec3 u_color : source_color = vec3(0.83, 0.92, 1.0);
uniform float u_alpha : hint_range(0.0, 1.0) = 0.0;
uniform float u_mode : hint_range(0.0, 1.0) = 0.0;
uniform float u_noise : hint_range(0.0, 1.0) = 0.35;

varying vec2 v_uv;
varying vec3 v_local;

void vertex() {
	v_uv = UV;
	v_local = VERTEX;
}

void fragment() {
	// UV edge falloff along the sheet (U = width, V = flow / length).
	float eu = smoothstep(0.0, 0.20, v_uv.x) * smoothstep(1.0, 0.80, v_uv.x);
	float ev = smoothstep(0.0, 0.12, v_uv.y) * smoothstep(1.0, 0.62, v_uv.y);
	float edge = pow(eu * ev, 0.85);
	// Slight interior density variation so the sheet is not a flat card.
	float nse = 0.72 + 0.28 * sin(v_local.x * 5.4 + v_local.z * 3.6);
	nse *= 0.78 + 0.22 * sin(v_local.z * 7.1 - v_local.y * 4.2 + v_uv.x * 6.0);
	float flow = mix(1.0, 0.82 + 0.18 * ev, u_mode);
	float a = edge * u_alpha * mix(1.0, nse, u_noise) * flow;
	if (a < 0.008) {
		discard;
	}
	ALBEDO = u_color;
	ALPHA = a;
	EMISSION = u_color * a * 0.85;
}
