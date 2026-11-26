// 断面图平面填充：按体内/器官内外测试给切面着色（不依赖闭合网格的薄壳投影）。
// 腹腔/盆腔：深粉；阴道壁与宫壁实心着色，管腔/宫腔保持中空（更深的腔色，不是背景黑）。
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, unshaded, shadows_disabled;

#include "res://shaders/organ_common.gdshaderinc"

uniform vec3 section_point = vec3(0.0);
uniform vec3 section_normal = vec3(0.0, 0.0, 1.0);
uniform vec3 canal_open_ab = vec3(0.0);
uniform vec3 canal_axis_ab = vec3(0.0, 1.0, 0.0);
uniform vec3 canal_cerv_ab = vec3(0.0);
uniform vec3 uter_axis_ab = vec3(0.0, 1.0, 0.0);
uniform float uter_len = 0.055;
uniform float uter_rad = 0.022;
uniform float uter_wall = 0.006;
uniform float vag_lumen = 0.007;
uniform float vag_wall = 0.007;
uniform vec3 rod_tip_w = vec3(0.0);
uniform float rod_radius = 0.0;
uniform vec3 rod_axis_w = vec3(0.0, 1.0, 0.0);
uniform float rod_shaft_r = 0.004;
uniform float rod_shaft_len = 0.18;
uniform int prof_n = 0;
uniform sampler2D prof_tex : hint_default_black, filter_nearest, repeat_disable;
uniform vec4 prof_bias = vec4(0.0);
uniform vec4 prof_scale = vec4(1.0);
uniform float fill_on = 1.0;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

vec4 prof_sample(int i) {
	vec4 t = texture(prof_tex, vec2((float(i) + 0.5) / 24.0, 0.5));
	return t * prof_scale + prof_bias;
}

vec3 torso_profile(float y) {
	if (prof_n < 2) {
		return vec3(0.13, 0.02, -0.12);
	}
	vec4 a = prof_sample(0);
	if (y <= a.r) return a.gba;
	for (int i = 1; i < 24; i++) {
		if (i >= prof_n) break;
		vec4 b = prof_sample(i);
		if (y <= b.r) {
			float t = (y - a.r) / max(1e-5, b.r - a.r);
			return mix(a.gba, b.gba, t);
		}
		a = b;
	}
	return a.gba;
}

bool torso_inside(vec3 l, float inset) {
	if (prof_n < 2) {
		return false;
	}
	vec4 a0 = prof_sample(0);
	vec4 a1 = prof_sample(max(prof_n - 1, 0));
	if (l.y < a0.r - 0.04 || l.y > a1.r + 0.02) {
		return false;
	}
	vec3 pr = torso_profile(l.y);
	float hx = pr.x - inset;
	float zf = pr.y - inset;
	float zb = pr.z + inset;
	if (hx < 0.02) {
		return false;
	}
	return abs(l.x) <= hx && l.z <= zf && l.z >= zb;
}

void fragment() {
	if (fill_on < 0.5) {
		discard;
	}
	vec3 n = section_normal;
	float nl = length(n);
	if (nl < 1e-5) {
		discard;
	}
	n /= nl;
	if (abs(dot(v_world - section_point, n)) > 0.003) {
		discard;
	}
	vec3 l = to_ab(v_world);
	vec3 ax = canal_axis_ab;
	float al = length(ax);
	if (al < 1e-5) {
		ax = vec3(0.0, 1.0, 0.0);
	} else {
		ax /= al;
	}
	vec3 openp = canal_open_ab;
	vec3 cerv = canal_cerv_ab;
	float canal_len = max(dot(cerv - openp, ax), 0.03);
	vec3 v = l - openp;
	float along = dot(v, ax);
	vec3 latv = v - ax * along;
	float pr = length(latv);
	vec3 col = vec3(-1.0);

	vec3 rod_ab = to_ab(rod_tip_w);
	if (rod_radius > 1e-5 && length(l - rod_ab) <= rod_radius + 0.0004) {
		col = vec3(0.78, 0.82, 0.86);
	} else if (rod_radius > 1e-5 && length(rod_axis_w) > 1e-5) {
		vec3 rd = normalize(rod_axis_w);
		vec3 wp = v_world;
		vec3 ro = rod_tip_w;
		float tsh = clamp(-dot(wp - ro, rd), 0.0, rod_shaft_len);
		float dsh = length((wp - ro) + rd * tsh);
		if (dsh <= rod_shaft_r + 0.0003 && tsh > rod_radius * 0.35) {
			col = vec3(0.78, 0.82, 0.86);
		}
	}

	vec3 uax = uter_axis_ab;
	if (length(uax) < 1e-5) {
		uax = ax;
	} else {
		uax = normalize(uax);
	}
	float ulen = max(uter_len, 0.03);
	float ur = max(uter_rad, 0.012);
	float uw = clamp(uter_wall, 0.004, 0.012);
	vec3 u0 = cerv + uax * (ulen * 0.52);
	vec3 du = l - u0;
	float ua = dot(du, uax);
	vec3 urad = du - uax * ua;
	float q_out = (ua * ua) / pow(ulen * 0.52, 2.0) + dot(urad, urad) / (ur * ur);
	float rin = max(ur - uw, 0.006);
	float lin = max(ulen * 0.52 - uw, 0.012);
	float q_in = (ua * ua) / (lin * lin) + dot(urad, urad) / (rin * rin);
	bool in_uter_wall = q_out <= 1.0 && q_in >= 1.0;
	bool in_uter_lumen = q_in < 1.0;
	float vl = max(vag_lumen, 0.003);
	float vw = max(vag_wall, 0.004);
	float vag_lo = -0.012;
	float vag_hi = canal_len + 0.002;
	bool along_vag = along >= vag_lo && along <= vag_hi;
	// 宫颈处让子宫优先，阴道只画到宫口前。
	if (along > canal_len - 0.002) {
		along_vag = along_vag && !in_uter_wall && !in_uter_lumen;
	}
	bool in_vag_wall = along_vag && pr >= vl && pr <= vl + vw;
	bool in_vag_lumen = along_vag && pr < vl;

	if (col.x < 0.0) {
		if (in_uter_wall) col = vec3(0.70, 0.30, 0.40);
		else if (in_uter_lumen) col = vec3(0.45, 0.16, 0.22);
		else if (in_vag_wall) col = vec3(0.91, 0.55, 0.60);
		else if (in_vag_lumen) col = vec3(0.58, 0.24, 0.30);
		else if (torso_inside(l, 0.010)) col = vec3(0.48, 0.20, 0.26);
		else if (torso_inside(l, 0.0)) col = vec3(0.91, 0.75, 0.66);
	}
	if (col.x < 0.0) {
		discard;
	}
	ALBEDO = col;
}
