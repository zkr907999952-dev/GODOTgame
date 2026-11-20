// 手术切口红色渐变涂鸦：写在皮肤表面，非透视下也可见；跟随腹部蒙皮与柔体位移。
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, diffuse_burley, specular_schlick_ggx, shadows_disabled;

#include "res://shaders/organ_common.gdshaderinc"

uniform vec3 surgery_pull_p = vec3(0.0);
uniform vec3 surgery_pull_off = vec3(0.0);
uniform float surgery_pull_r = 0.0;
uniform float surface_lift = 0.0016;
// 0.3.6：比 0.3.5 更浅、更淡的红色涂鸦。脚本 TRAIL_COLOR_* 与此保持一致。
uniform vec3 trail_color_deep = vec3(0.78, 0.32, 0.32);
uniform vec3 trail_color_bright = vec3(1.0, 0.58, 0.55);
uniform float trail_alpha = 0.72;

vec3 surgery_pull_offset(vec3 l) {
	if (surgery_pull_r < 1e-5) return vec3(0.0);
	float d = length(l - surgery_pull_p);
	float t = clamp(1.0 - d / max(surgery_pull_r, 1e-4), 0.0, 1.0);
	float k = t * t * (3.0 - 2.0 * t);
	return surgery_pull_off * k;
}

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 l = to_ab(wp);
	vec3 off = strike_offset(l) + drag_offset(l) + dent_offset(l) + surgery_pull_offset(l);
	vec3 off_w = ab_dir_to_world(off);
	VERTEX += inverse(mat3(MODEL_MATRIX)) * off_w;
	// 沿法线微微抬起，避免被不透明皮肤深度盖住，看起来像写在皮肤上。
	VERTEX += NORMAL * surface_lift;
}

void fragment() {
	float across = 1.0 - abs(UV.y * 2.0 - 1.0);
	float soft = smoothstep(0.0, 0.62, across);
	ALBEDO = mix(trail_color_deep, trail_color_bright, pow(soft, 0.7));
	ROUGHNESS = 0.48;
	METALLIC = 0.0;
	float ends = smoothstep(0.0, 0.07, UV.x) * smoothstep(1.0, 0.93, UV.x);
	ends = max(ends, 0.72);
	ALPHA = mix(0.12, trail_alpha, pow(soft, 1.05)) * ends;
}
