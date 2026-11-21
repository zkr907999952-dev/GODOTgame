// 手术切口断面 / 弹孔柱状壁：肉色内壁，并跟随腹部柔体位移（与皮肤同一套 strike/drag/dent）。
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx, shadows_disabled;

#include "res://shaders/organ_common.gdshaderinc"
#include "res://shaders/surgery_pull.gdshaderinc"

uniform vec4 albedo_color : source_color = vec4(0.72, 0.28, 0.26, 1.0);
uniform float roughness = 0.55;
uniform float metallic = 0.0;
uniform float xray = 0.0;


void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 l = to_ab(wp);
	vec3 off = strike_offset(l) + drag_offset(l) + dent_offset(l) + surgery_pull_offset(l);
	vec3 off_w = ab_dir_to_world(off);
	VERTEX += inverse(mat3(MODEL_MATRIX)) * off_w;
}

void fragment() {
	ALBEDO = albedo_color.rgb;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	SPECULAR = 0.28;
	if (xray > 0.001) {
		ALPHA = mix(1.0, 0.32, clamp(xray, 0.0, 1.0));
	} else {
		ALPHA = albedo_color.a;
	}
}
