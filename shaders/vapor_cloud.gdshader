shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec3 u_color : source_color = vec3(0.83, 0.92, 1.0);
uniform float u_alpha : hint_range(0.0, 1.0) = 0.0;
uniform float u_mode : hint_range(0.0, 1.0) = 0.0; // 0 = soft volume, 1 = more ring-like
uniform float u_noise : hint_range(0.0, 1.0) = 0.35;

varying vec3 v_local;

void vertex() {
	v_local = VERTEX;
}

void fragment() {
	// Soft volumetric ellipsoid: density is a 3D falloff from the centre,
	// thickened along the view ray (not a UV paper disc).
	vec3 n = normalize(NORMAL);
	vec3 v = normalize(VIEW);
	float ndv = abs(dot(n, v));
	float thick = pow(clampf(ndv, 0.0, 1.0), 0.55);
	float r = length(v_local) / 0.5;
	float core = exp(-2.1 * r * r);
	float ring = smoothstep(0.12, 0.42, r) * (1.0 - smoothstep(0.62, 1.08, r));
	float dens = mix(core * (0.35 + 0.65 * thick), ring * thick, u_mode);
	float nse = 0.58 + 0.42 * sin(v_local.x * 7.3 + v_local.y * 5.1 + v_local.z * 6.4);
	nse *= 0.72 + 0.28 * sin(v_local.y * 9.1 - v_local.z * 4.6);
	float a = dens * u_alpha * mix(1.0, nse, u_noise);
	if (a < 0.008) {
		discard;
	}
	ALBEDO = u_color;
	ALPHA = a;
	EMISSION = u_color * a;
}
