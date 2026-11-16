// 腹壁透视半透明覆盖层（网页 attachXray fade overlay）：只画孔洞区域，越靠中心越透明
shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_never, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/organ_common.gdshaderinc"
#include "res://shaders/skin_common.gdshaderinc"

void fragment() {
	if (fp_clipped(v_wp, CAMERA_VISIBLE_LAYERS)) discard;
	float hole = xray_hole(v_ab);
	if (hole < 0.012) discard;
	float f = smoothstep(0.012, 1.0, hole);
	skin_surface(UV, true, ALBEDO, METALLIC, ROUGHNESS, SPECULAR, AO, NORMAL_MAP, NORMAL_MAP_DEPTH);
	ALBEDO *= mix(1.0, 0.5, f);
	// 底层不透明皮肤在 hole<0.07 时还在：覆盖层在 0.012→0.06 之间渐入，
	// 避免透明管线与不透明管线的细微光照差异在窗口边缘形成一圈硬边「方框」。
	// 中心保留约三成皮肤透明度，能看见皮肤轮廓位置，内脏仍透过。
	ALPHA = mix(0.96, 0.32, pow(f, 0.72)) * smoothstep(0.012, 0.06, hole);
}
