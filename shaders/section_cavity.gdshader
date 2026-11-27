// 断面腹腔背景：铺在剖切面上的四边形，腹形剖面内涂腹膜色。
// 比 CPU 求交便宜，并向外扩一圈盖住器官/皮肤轮廓缝，避免黑边撕裂。
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, depth_test_disabled, cull_disabled, unshaded, shadows_disabled;

#include "res://shaders/organ_common.gdshaderinc"

uniform vec4 fill_color : source_color = vec4(0.48, 0.20, 0.26, 1.0);
uniform float section_on = 1.0;
uniform vec3 section_point = vec3(0.0);
uniform vec3 section_normal = vec3(0.0, 0.0, 1.0);
uniform float dilate = 0.012;
uniform float inside_all = 0.0;
uniform int prof_n = 0;
uniform sampler2D prof_tex : hint_default_black, filter_nearest, repeat_disable;
uniform vec4 prof_bias = vec4(0.0);
uniform vec4 prof_scale = vec4(1.0);
uniform vec3 hole_center = vec3(0.0, -0.02, 0.03);
uniform vec3 hole_radius = vec3(0.12, 0.18, 0.11);
uniform int limb_count = 0;
uniform vec3 limb_a[8];
uniform vec3 limb_b[8];
uniform float limb_r[8];

varying vec3 v_world;

vec4 cav_prof_at(int i) {
	vec4 t = texture(prof_tex, vec2((float(i) + 0.5) / 24.0, 0.5));
	return t * prof_scale + prof_bias;
}

vec3 cav_torso(float y) {
	if (prof_n <= 0) return vec3(0.16, 0.02, -0.14);
	vec4 a = cav_prof_at(0);
	if (y <= a.r) return a.gba;
	for (int i = 1; i < 24; i++) {
		if (i >= prof_n) break;
		vec4 b = cav_prof_at(i);
		if (y <= b.r) {
			float t = (y - a.r) / max(1e-5, b.r - a.r);
			return mix(a.gba, b.gba, t);
		}
		a = b;
	}
	return a.gba;
}

bool in_limb(vec3 wp) {
	if (limb_count < 1) return false;
	int n = min(limb_count, 8);
	for (int i = 0; i < n; i++) {
		vec3 a = limb_a[i];
		vec3 b = limb_b[i];
		float r = limb_r[i] + 0.008;
		vec3 ab = b - a;
		float den = dot(ab, ab);
		float u = den > 1e-10 ? clamp(dot(wp - a, ab) / den, 0.0, 1.0) : 0.0;
		if (length(wp - (a + ab * u)) <= r) return true;
	}
	return false;
}

bool inside_body(vec3 wp) {
	if (inside_all > 0.5) return true;
	if (in_limb(wp)) return false;
	vec3 l = to_ab(wp);
	vec3 pr = cav_torso(l.y);
	float hx = max(pr.x + dilate, 0.04);
	float zf = pr.y + dilate;
	float zb = pr.z - dilate;
	// 剖面解码失败时用兜底椭球，避免腹腔露出背景黑。
	if (pr.x < 0.02) {
		vec3 q = (l - hole_center) / max(hole_radius + vec3(dilate), vec3(0.04));
		return length(q) <= 1.05;
	}
	// y 略超出剖面表也继续填，挡住宫底/盆底边缘的黑缝。
	vec4 p0 = cav_prof_at(0);
	vec4 p1 = cav_prof_at(max(prof_n - 1, 0));
	float y0 = p0.r - 0.05;
	float y1 = p1.r + 0.05;
	if (l.y < y0 || l.y > y1) {
		vec3 q2 = (l - hole_center) / max(hole_radius + vec3(dilate), vec3(0.04));
		return length(q2) <= 1.05;
	}
	return abs(l.x) <= hx && l.z <= zf && l.z >= zb;
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (section_on < 0.5) {
		discard;
	}
	if (!inside_body(v_world)) {
		discard;
	}
	ALBEDO = fill_color.rgb;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
