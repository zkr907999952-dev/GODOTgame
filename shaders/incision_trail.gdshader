// 手术切口红色渐变轨迹：沿皮肤表面绘制，中心更密、边缘柔化。
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, diffuse_burley, specular_schlick_ggx;

void fragment() {
	float across = 1.0 - abs(UV.y * 2.0 - 1.0);
	float soft = smoothstep(0.0, 0.62, across);
	vec3 deep = vec3(0.38, 0.02, 0.03);
	vec3 bright = vec3(0.95, 0.12, 0.10);
	ALBEDO = mix(deep, bright, pow(soft, 0.7));
	ROUGHNESS = 0.42;
	METALLIC = 0.0;
	float ends = smoothstep(0.0, 0.07, UV.x) * smoothstep(1.0, 0.93, UV.x);
	ends = max(ends, 0.6);
	ALPHA = mix(0.12, 0.94, pow(soft, 1.1)) * ends;
}
