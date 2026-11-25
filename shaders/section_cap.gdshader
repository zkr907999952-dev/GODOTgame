// 断面图切割填充：只画背面，颜色为组织色，剖切面内侧形成色块。
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_front, unshaded, shadows_disabled;

#include "res://shaders/organ_common.gdshaderinc"

uniform vec4 cap_color : source_color = vec4(0.91, 0.55, 0.60, 1.0);
uniform int tissue = 3;
uniform float section_on = 0.0;
uniform vec3 section_point = vec3(0.0);
uniform vec3 section_normal = vec3(0.0, 0.0, 1.0);
uniform vec3 canal_open_ab = vec3(0.0);
uniform vec3 canal_axis_ab = vec3(0.0, 1.0, 0.0);
uniform float stylize_layers = 1.0;

varying vec3 v_world;
varying vec3 v_ab;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 l = to_ab(wp);
	vec3 off = strike_offset(l) + drag_offset(l) + dent_offset(l) + speculum_offset(l) + dilate_offset(l) + uterus_ball_offset(l);
	off += prolapse_offset4(l + off).xyz;
	vec3 off_w = ab_dir_to_world(off);
	VERTEX += inverse(mat3(MODEL_MATRIX)) * off_w;
	wp += off_w;
	v_world = wp;
	v_ab = l + off;
}

vec3 tissue_color(int id) {
	if (id == 0) return vec3(0.91, 0.75, 0.66);
	if (id == 1) return vec3(0.95, 0.86, 0.62);
	if (id == 2) return vec3(0.72, 0.28, 0.32);
	if (id == 3) return vec3(0.91, 0.55, 0.60);
	if (id == 4) return vec3(0.70, 0.30, 0.40);
	if (id == 5) return vec3(0.45, 0.16, 0.22);
	if (id == 6) return vec3(0.78, 0.82, 0.86);
	return cap_color.rgb;
}

void fragment() {
	if (section_on > 0.5) {
		vec3 n = section_normal;
		float nl = length(n);
		if (nl > 1e-5) {
			n /= nl;
			float s = dot(v_world - section_point, n);
			if (s < 0.0002) {
				discard;
			}
		}
	}
	int id = tissue;
	if (stylize_layers > 0.5 && tissue == 3) {
		vec3 ax = canal_axis_ab;
		float al = length(ax);
		if (al > 1e-5) {
			ax /= al;
			vec3 v = v_ab - canal_open_ab;
			float pr = length(v - ax * dot(v, ax));
			if (pr < 0.008) id = 3;
			else if (pr < 0.013) id = 2;
			else if (pr < 0.020) id = 1;
			else id = 0;
		}
	}
	vec3 col = tissue_color(id);
	if (section_on > 0.5) {
		vec3 n = normalize(section_normal);
		float s = dot(v_world - section_point, n);
		float edge = 1.0 - smoothstep(0.0002, 0.0018, s);
		col = mix(col, vec3(0.08, 0.05, 0.06), edge * 0.95);
	}
	ALBEDO = col;
	ROUGHNESS = 1.0;
}
