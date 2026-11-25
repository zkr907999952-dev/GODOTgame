// 外阴前庭黏膜：跟皮肤 / 脏器同一套腹部柔体位移（拖拽、击腹、凹陷），避免拖腹时留在原地。
// 外圈采样皮肤贴图与外阴皮瓣连续，向内过渡到黏膜色，避免接缝贴图异常。
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, specular_schlick_ggx;

#include "res://shaders/organ_common.gdshaderinc"

uniform vec4 mucosa_color : source_color = vec4(0.81, 0.60, 0.57, 1.0);
uniform float roughness_v = 0.50;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform int has_albedo = 0;

varying float v_row;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 l = to_ab(wp);
	vec3 off = strike_offset(l) + drag_offset(l) + dent_offset(l) + speculum_offset(l) + dilate_offset(l);
	vec3 off_w = ab_dir_to_world(off);
	VERTEX += inverse(mat3(MODEL_MATRIX)) * off_w;
	v_row = COLOR.r;
}

void fragment() {
	vec3 skin_rgb = mucosa_color.rgb;
	if (has_albedo == 1) {
		skin_rgb = texture(albedo_tex, UV).rgb;
	}
	// 外圈（接皮肤）用皮肤贴图，向内过渡到黏膜粉。
	ALBEDO = mix(skin_rgb, mucosa_color.rgb, smoothstep(0.12, 0.72, v_row));
	ROUGHNESS = mix(0.55, roughness_v, smoothstep(0.12, 0.72, v_row));
	SPECULAR = 0.42;
}
