shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, shadows_disabled;

uniform vec3 u_color : source_color = vec3(0.04, 0.04, 0.045);
uniform sampler2D u_tex : source_color, filter_linear_mipmap, repeat_enable;

varying vec4 v_col;
varying vec2 v_uv;

void vertex() {
	v_col = COLOR;
	v_uv = UV;
}

void fragment() {
	float mask = texture(u_tex, v_uv).r;
	float a = v_col.a * mask;
	if (a < 0.02) {
		discard;
	}
	ALBEDO = u_color;
	ALPHA = a;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
