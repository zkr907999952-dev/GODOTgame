// 断面图体腔填充：用体表网格本身判定「体内 / 体外」，不再靠腹部剖面表的盒子。
// 做法：裁掉剖切面朝相机一侧，其余体表按「离相机最近的一层」着色：
//   最近的是背面 = 射线从切面起点就在体内 → 体腔色（暗红）；
//   最近的是正面 = 射线从体外进入另一块身体（例如远侧大腿）→ 体外色（黑）；
//   什么都没碰到 = 体外，保持清屏黑。
// 因此双腿之间的裆部（切面上在体外）不会被填充，体外部分始终是黑色。
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, unshaded, shadows_disabled;

#include "res://shaders/organ_common.gdshaderinc"

uniform vec4 inside_color : source_color = vec4(0.48, 0.20, 0.26, 1.0);
uniform vec4 outside_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float section_on = 0.0;
uniform vec3 section_point = vec3(0.0);
uniform vec3 section_normal = vec3(0.0, 0.0, 1.0);
uniform float exclude_limbs = 0.0;
uniform vec3 limb_a[8];
uniform vec3 limb_b[8];
uniform float limb_r[8];
uniform int limb_count = 0;

varying vec3 v_world;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 l = to_ab(wp);
	// 与皮肤切面环同一套体表变形（打击 / 拖拽 / 按压），填充和轮廓才对得上。
	vec3 off = strike_offset(l) + drag_offset(l) + dent_offset(l);
	vec3 off_w = ab_dir_to_world(off);
	VERTEX += inverse(mat3(MODEL_MATRIX)) * off_w;
	v_world = wp + off_w;
}

bool in_excluded_limb(vec3 wp) {
	if (exclude_limbs < 0.5 || limb_count < 1) return false;
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

void fragment() {
	if (section_on < 0.5) {
		discard;
	}
	vec3 n = section_normal;
	float nl = length(n);
	if (nl > 1e-5) {
		n /= nl;
		if (dot(v_world - section_point, n) < 0.00015) {
			discard;
		}
	}
	if (in_excluded_limb(v_world)) {
		discard;
	}
	ALBEDO = FRONT_FACING ? outside_color.rgb : inside_color.rgb;
}
