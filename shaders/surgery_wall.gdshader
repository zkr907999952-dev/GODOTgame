// 手术切口断面 / 弹孔柱状壁：肉色内壁，并跟随腹部柔体位移（与皮肤同一套 strike/drag/dent）。
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx, shadows_disabled;

#include "res://shaders/organ_common.gdshaderinc"
#include "res://shaders/surgery_pull.gdshaderinc"

uniform vec4 albedo_color : source_color = vec4(0.72, 0.28, 0.26, 1.0);
uniform float roughness = 0.55;
uniform float metallic = 0.0;
uniform float xray = 0.0;
// 0.3.9：腹腔袋在腹股沟折痕附近（腹局部 y 很低、偏外侧）不画，屈髋躺下时那里会从折痕露出。
uniform float clip_low = 0.0;
uniform float clip_low_y = -0.19;
varying vec3 v_ab;


void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 l = to_ab(wp);
	v_ab = l;
	vec3 off = strike_offset(l) + drag_offset(l) + dent_offset(l) + surgery_pull_offset(l);
	vec3 off_w = ab_dir_to_world(off);
	VERTEX += inverse(mat3(MODEL_MATRIX)) * off_w;
}

void fragment() {
	if (clip_low > 0.5 && v_ab.y < clip_low_y + 1.5 * max(abs(v_ab.x) - 0.06, 0.0)) {
		discard;
	}
	ALBEDO = albedo_color.rgb;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	SPECULAR = 0.28;
	// 透视开着时整袋半透明。depth_draw_opaque 只在 ALPHA==1 时写深度，
	// 因此 0.32 不会把袋里的内脏挡住。xray 用开关（>0 即开），不要按强度混回不透明。
	if (xray > 0.001) {
		ALPHA = 0.32;
	} else {
		ALPHA = albedo_color.a;
	}
}
