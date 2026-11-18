shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec3 u_color : source_color = vec3(0.83, 0.92, 1.0);
uniform float u_alpha : hint_range(0.0, 1.0) = 0.0;
uniform float u_mode : hint_range(0.0, 1.0) = 0.0; // 0 = soft disc, 1 = ring

varying vec2 v_uv;

void vertex() {
	v_uv = UV;
}

void fragment() {
	vec2 p = v_uv * 2.0 - 1.0;
	float r = length(p);
	float ring = smoothstep(0.12, 0.40, r) * (1.0 - smoothstep(0.55, 1.0, r));
	float disc = (1.0 - smoothstep(0.0, 1.0, r)) * 0.55 + ring;
	float a = mix(disc, ring, u_mode) * u_alpha;
	if (a < 0.008) {
		discard;
	}
	ALBEDO = u_color;
	ALPHA = a;
	EMISSION = u_color * a;
}
