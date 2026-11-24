// 外阴前庭黏膜：跟皮肤 / 脏器同一套腹部柔体位移（拖拽、击腹、凹陷），避免拖腹时留在原地。
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, specular_schlick_ggx;

#include "res://shaders/organ_common.gdshaderinc"

uniform vec4 mucosa_color : source_color = vec4(0.81, 0.60, 0.57, 1.0);
uniform float roughness_v = 0.50;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 l = to_ab(wp);
	vec3 off = strike_offset(l) + drag_offset(l) + dent_offset(l) + speculum_offset(l);
	vec3 off_w = ab_dir_to_world(off);
	VERTEX += inverse(mat3(MODEL_MATRIX)) * off_w;
}

void fragment() {
	ALBEDO = mucosa_color.rgb;
	ROUGHNESS = roughness_v;
	SPECULAR = 0.42;
}
