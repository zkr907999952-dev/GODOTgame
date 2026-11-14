// 击腹冲击环 / 拖拽戳点标记（网页 ringRef / pokeRef）：无光照、不做深度测试
shader_type spatial;
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never, cull_disabled;

uniform vec4 color : source_color = vec4(0.95, 0.94, 0.91, 0.8);
uniform float inner = 0.92;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float a = smoothstep(inner - 0.03, inner, r) * (1.0 - smoothstep(0.97, 1.0, r));
	ALBEDO = color.rgb;
	ALPHA = color.a * a;
}
