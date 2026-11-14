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
varying vec3 v_wp;
// 第一人称近裁球：只对「不渲染 fp_head 图层(19)」的相机生效 → 第一人称主相机；镜子 / 第三人称不受影响。
uniform vec3 fp_eye_w = vec3(0.0);
uniform float fp_clip_r = 0.0;

bool fp_clipped(vec3 wp, uint cam_layers) {
	return fp_clip_r > 0.0 && (cam_layers & (1u << 18u)) == 0u && distance(wp, fp_eye_w) < fp_clip_r;
}

// 躯干截面轮廓（静止姿态，相对肚脐）：y / 半宽 / 前表面 z / 后表面 z。由 organ_rig 从 organs_meta.json 写入。
// 透视窗口按截面收进轮廓内：只挖前半个腹壁，侧壁和后壁永远保留（从孔里看进去是暗红腔壁），
// 修复腰部变细处（半宽 ≈9cm < 窗口 12cm+10cm 渐隐）整个截面被挖穿、能直接看到身后背景的问题。
const int PROF_MAX = 24;
uniform int prof_n = 0;
uniform float prof_y[24];
uniform float prof_hx[24];
uniform float prof_zf[24];
uniform float prof_zb[24];

vec3 torso_profile(float y) {
	if (prof_n <= 0) return vec3(0.15, 0.01, -0.13);
	if (y <= prof_y[0]) return vec3(prof_hx[0], prof_zf[0], prof_zb[0]);
	for (int i = 1; i < PROF_MAX; i++) {
		if (i >= prof_n) break;
		if (y <= prof_y[i]) {
			float t = (y - prof_y[i - 1]) / max(1e-5, prof_y[i] - prof_y[i - 1]);
			return mix(vec3(prof_hx[i - 1], prof_zf[i - 1], prof_zb[i - 1]), vec3(prof_hx[i], prof_zf[i], prof_zb[i]), t);
		}
	}
	int k = prof_n - 1;
	return vec3(prof_hx[k], prof_zf[k], prof_zb[k]);
}

float xray_hole(vec3 l) {
	float band = smoothstep(xray_y0, xray_y0 + 0.08, l.y) * (1.0 - smoothstep(xray_y1 - 0.04, xray_y1, l.y));
	vec3 pr = torso_profile(l.y);
	// 外缘留在轮廓内 1.5cm（侧壁不挖），内缘再往里 4.5cm 渐隐
	float w_out = min(xray_xmax + 0.1, pr.x - 0.015);
	float w_in = min(xray_xmax * 0.65, w_out - 0.045);
	float torso = 1.0 - smoothstep(w_in, w_out, abs(l.x));
	float front = smoothstep(xray_zfront - 0.16, xray_zfront + 0.04, l.z);
	// 只挖截面前半（后壁 / 侧后壁保留）
	float zmid = 0.5 * (pr.y + pr.z);
	front *= smoothstep(zmid, zmid + 0.035, l.z);
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
	v_wp = wp;
}

void skin_surface(vec2 uv, bool front, inout vec3 albedo, inout float metal, inout float rough,
		inout float spec, inout float ao, inout vec3 nmap, inout float nmap_depth) {
	vec4 a = texture(albedo_tex, uv) * albedo_color;
	vec4 orm = has_orm ? texture(orm_tex, uv) : vec4(1.0);
	albedo = a.rgb;
	metal = metallic * orm.b;
	// 躯干贴图 G≈0.49 × 0.578 → 粗糙度只有 ≈0.28，像抹了油：朝上的胸口/锁骨/肩带在高位主光
	// 和吸顶灯下镜面高光连成一片发白。皮肤下限 0.45、镜面强度上限 0.36。
	rough = max(roughness * orm.g, 0.45);
	spec = min(specular, 0.36);
	// glTF metallicRoughness 贴图的 R 通道不是 AO（此模型无 occlusionTexture；躯干贴图 R≈0.17），
	// 之前当 AO 用 → 一旦有环境光，躯干明显发灰发脏。
	ao = 1.0;
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
