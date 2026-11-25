// 断面图切割填充：真正的几何裁剪后，只把跨越剖切面的那一层压平，形成组织色平切面。
// 不是把整个背面投影到平面上（空腔 / 开口子宫 / 离面的金属棒会被投影撕碎并涂黑）。
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
// 参与切面填充的最大深度（米）。薄壁（皮肤/宫壁）用小值，实心金属棒用大于半径的值。
uniform float cap_thickness = 0.016;

varying vec3 v_world;
varying vec3 v_ab;
varying float v_s;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 l = to_ab(wp);
	vec3 off = strike_offset(l) + drag_offset(l) + dent_offset(l) + speculum_offset(l) + dilate_offset(l) + canal_stir_offset(l) + uterus_straighten_offset(l) + uterus_ball_offset(l);
	off += prolapse_offset4(l + off).xyz;
	vec3 off_w = ab_dir_to_world(off);
	VERTEX += inverse(mat3(MODEL_MATRIX)) * off_w;
	wp += off_w;
	v_s = 1.0;
	if (section_on > 0.5) {
		vec3 n = section_normal;
		float nl = length(n);
		if (nl > 1e-5) {
			n /= nl;
			float s = dot(wp - section_point, n);
			v_s = s;
			// 只把被裁掉一侧、落在切面厚度内的顶点移到切面上（略偏保留侧，避免与裁剪 pass 深度冲突）。
			// 远离切面的顶点不动：不会把整面后壁或离面的棒身摊到切面上。
			if (s < 0.0 && s > -cap_thickness) {
				vec3 dw = n * (-s + 0.0003);
				wp += dw;
				VERTEX += inverse(mat3(MODEL_MATRIX)) * dw;
			}
		}
	}
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
		// 只画原来就在被裁侧、且贴近切面的片段 = 真实交线处的平切填充。
		// 保留侧由 cut pass 绘制；远离切面的几何不投影、不填充。
		if (v_s > 0.0002) {
			discard;
		}
		if (v_s < -cap_thickness) {
			discard;
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
		// 切面边缘一线深色，切面本体保持组织色（不再把整个切面混成近黑）。
		float edge = 1.0 - smoothstep(-0.0008, 0.0002, v_s);
		col = mix(col, vec3(0.22, 0.12, 0.13), edge * 0.28);
	}
	ALBEDO = col;
	ROUGHNESS = 1.0;
	if (tissue == 6) {
		ROUGHNESS = 0.12;
	}
}
