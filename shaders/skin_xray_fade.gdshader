// 腹壁透视半透明覆盖层（网页 attachXray fade overlay）：只画孔洞区域，越靠中心越透明
shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_never, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/organ_common.gdshaderinc"
#include "res://shaders/skin_common.gdshaderinc"

void fragment() {
	float hole = xray_hole(v_ab);
	if (hole < 0.012) discard;
	float f = smoothstep(0.012, 1.0, hole);
	skin_surface(UV, true, ALBEDO, METALLIC, ROUGHNESS, SPECULAR, AO, NORMAL_MAP, NORMAL_MAP_DEPTH);
	ALBEDO *= mix(1.0, 0.5, f);
	ALPHA = mix(0.96, 0.05, pow(f, 0.72));
}
