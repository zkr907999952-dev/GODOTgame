// 断面填充：顶点色来自剖切面与真实变形网格的截面多边形，不再用解析椭球/管道/腹形色块。
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, unshaded, shadows_disabled;

void fragment() {
	ALBEDO = COLOR.rgb;
}
