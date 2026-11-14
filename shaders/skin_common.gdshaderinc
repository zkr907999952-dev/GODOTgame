// 皮肤材质参数（从导入的 StandardMaterial3D 拷贝）+ 透视区域 + 皮肤凹陷
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D orm_tex : hint_default_white, filter_linear_mipmap, repeat_enable; // r=AO g=rough b=metal
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform float metallic = 1.0;
uniform float roughness = 0.6;
uniform float specular = 0.5;
uniform float normal_scale = 1.0;
uniform bool has_orm = true;
uniform bool has_normal = true;

// 网页 xrayHole 参数（相对肚脐）：yX0-navel.y, yX1-navel.y, xMax, skinZ-0.01-navel.z
uniform float xray = 0.38;
uniform float xray_y0 = -0.2;
uniform float xray_y1 = 0.145;
uniform float xray_xmax = 0.12;
uniform float xray_zfront = -0.01;
uniform vec3 cavity_color : source_color = vec3(0.32, 0.09, 0.07);
// 击腹/拖拽 对皮肤的影响系数（网页 skeleton.impulse / setTissueDrag 软笼）
uniform float skin_strike_k = 0.55;
uniform float skin_drag_k = 1.0;

varying vec3 v_ab;

float xray_hole(vec3 l) {
	float band = smoothstep(xray_y0, xray_y0 + 0.08, l.y) * (1.0 - smoothstep(xray_y1 - 0.04, xray_y1, l.y));
	float torso = 1.0 - smoothstep(xray_xmax * 0.65, xray_xmax + 0.1, abs(l.x));
	float front = smoothstep(xray_zfront - 0.16, xray_zfront + 0.04, l.z);
	return clamp(band * torso * front * xray, 0.0, 1.0);
}

float belly_mask(vec3 l) {
	float mx = 1.0 - smoothstep(0.12, 0.22, abs(l.x));
	float my = smoothstep(-0.34, -0.22, l.y) * (1.0 - smoothstep(0.2, 0.3, l.y));
	float mz = smoothstep(-0.08, 0.0, l.z);
	return mx * my * mz;
}

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 l = to_ab(wp);
	float m = belly_mask(l);
	vec3 off = (strike_offset(l) * skin_strike_k + drag_offset(l) * skin_drag_k) * m;
	l += off;
	wp += ab_dir_to_world(off);
	VERTEX = (inverse(MODEL_MATRIX) * vec4(wp, 1.0)).xyz;
	v_ab = l;
}

void skin_surface(vec2 uv, bool front, inout vec3 albedo, inout float metal, inout float rough,
		inout float spec, inout float ao, inout vec3 nmap, inout float nmap_depth) {
	vec4 a = texture(albedo_tex, uv) * albedo_color;
	vec4 orm = has_orm ? texture(orm_tex, uv) : vec4(1.0);
	albedo = a.rgb;
	metal = metallic * orm.b;
	rough = roughness * orm.g;
	spec = specular;
	ao = orm.r;
	if (has_normal) {
		nmap = texture(normal_tex, uv).rgb;
		nmap_depth = normal_scale;
	}
	// 透视开启时，从孔洞看到的体壁内侧画成暗红腔壁（网页直接丢弃背面）
	if (!front && xray > 0.001) {
		albedo = cavity_color;
		metal = 0.0;
		rough = 0.55;
	}
}
