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

// 躯干截面轮廓（静止姿态，相对肚脐）：24×1 RGBA8 纹理，解码后为 (y, half_x, z_front, z_back)。
// 不用 float[24] 数组（Mobile 上传常失败），也不用 RGBAF/半浮点纹理——中端 GLES/Vulkan
// 设备经常不支持或被强制成 UNORM，负数和 >1 的剖面被裁掉，透视窗口会完全消失。
const int PROF_MAX = 24;
uniform int prof_n = 0;
uniform sampler2D prof_tex : hint_default_black, filter_nearest, repeat_disable;
uniform vec4 prof_bias = vec4(0.0);
uniform vec4 prof_scale = vec4(1.0);
// 无纹理兜底：肚脐空间椭球窗口。真机若 sampler / include / 解码失败，仍能挖出腹窗。
uniform vec3 hole_center = vec3(0.0, -0.02, 0.03);
uniform vec3 hole_radius = vec3(0.10, 0.16, 0.09);

vec4 prof_at(int i) {
	vec4 t = texture(prof_tex, vec2((float(i) + 0.5) / 24.0, 0.5));
	return t * prof_scale + prof_bias;
}

vec3 torso_profile(float y) {
	if (prof_n <= 0) return vec3(0.15, 0.01, -0.13);
	vec4 a = prof_at(0);
	if (y <= a.r) return a.gba;
	for (int i = 1; i < PROF_MAX; i++) {
		if (i >= prof_n) break;
		vec4 b = prof_at(i);
		if (y <= b.r) {
			float t = (y - a.r) / max(1e-5, b.r - a.r);
			return mix(a.gba, b.gba, t);
		}
		a = b;
	}
	return a.gba;
}

float xray_hole_analytic(vec3 l) {
	// 纯 float 椭球，不采样、不依赖 int / 剖面纹理。
	vec3 q = (l - hole_center) / max(hole_radius, vec3(0.02));
	float ell = 1.0 - smoothstep(0.72, 1.05, length(q));
	float band = smoothstep(xray_y0, xray_y0 + 0.08, l.y) * (1.0 - smoothstep(xray_y1 - 0.04, xray_y1, l.y));
	float front = smoothstep(xray_zfront - 0.16, xray_zfront + 0.04, l.z);
	float mid = 1.0 - smoothstep(0.11, 0.16, abs(l.x));
	return clamp(ell * band * front * mid, 0.0, 1.0);
}

float xray_hole_profile(vec3 l) {
	if (prof_n <= 0) return 0.0;
	float band = smoothstep(xray_y0, xray_y0 + 0.08, l.y) * (1.0 - smoothstep(xray_y1 - 0.04, xray_y1, l.y));
	vec3 pr = torso_profile(l.y);
	// 剖面若没解码出来（全 0），不要把窗口掐死
	if (pr.x < 0.02) return 0.0;
	float w_out = min(xray_xmax + 0.1, pr.x - 0.015);
	float w_in = min(xray_xmax * 0.65, w_out - 0.045);
	float torso = 1.0 - smoothstep(w_in, w_out, abs(l.x));
	float front = smoothstep(xray_zfront - 0.16, xray_zfront + 0.04, l.z);
	float zmid = 0.5 * (pr.y + pr.z);
	front *= smoothstep(zmid, zmid + 0.035, l.z);
	return clamp(band * torso * front, 0.0, 1.0);
}

// 弹道特写局部透视球：ab-local 圆心 + 半径（0=关闭）。与腹部窗口独立，结束时必须清零。
uniform vec3 xray_sphere_ab = vec3(0.0);
uniform float xray_sphere_r = 0.0;
uniform float xray_sphere_k = 1.0;

float xray_sphere_hole(vec3 l) {
	if (xray_sphere_r <= 0.001) return 0.0;
	float d = distance(l, xray_sphere_ab);
	float inner = xray_sphere_r * 0.70;
	return (1.0 - smoothstep(inner, xray_sphere_r, d)) * clamp(xray_sphere_k, 0.0, 1.0);
}

float xray_hole(vec3 l) {
	// 剖面与椭球取较大值：纹理可用时窗口更贴合体型，失败时椭球仍保证开孔。
	// 特写局部球与腹部窗口取较大值，互不影响；半径为 0 时完全退回旧行为。
	float base = clamp(max(xray_hole_profile(l), xray_hole_analytic(l)) * xray, 0.0, 1.0);
	return clamp(max(base, xray_sphere_hole(l)), 0.0, 1.0);
}

float belly_mask(vec3 l) {
	float mx = 1.0 - smoothstep(0.12, 0.22, abs(l.x));
	float my = smoothstep(-0.34, -0.22, l.y) * (1.0 - smoothstep(0.2, 0.3, l.y));
	float mz = smoothstep(-0.08, 0.0, l.z);
	return mx * my * mz;
}

// 拳交鼓包（网页 soft-skeleton fistDepth 段）：x,y = 拳心(ab-local)，z = 顶出量(wallOver)，w = 开关
uniform vec4 fist_bulge = vec4(0.0);
uniform vec2 fist_lean = vec2(0.0);
// x = 鼓包强度，y = 范围，z = 抬升，w = 杠杆
uniform vec4 fist_par = vec4(1.4, 1.0, 0.7, 1.0);

float smoother(float d, float r) {
	float t = d / max(r, 1e-4);
	if (t >= 1.0) return 0.0;
	float u = 1.0 - t;
	return u * u * u * (u * (u * 6.0 - 15.0) + 10.0);
}

vec3 fist_offset(vec3 l) {
	if (fist_bulge.w <= 0.0 || fist_bulge.z <= 0.0) return vec3(0.0);
	float over = fist_bulge.z;
	// 网页 front = clamp((z_rest + 0.01) / 0.11)，z_rest = ab-local z + 肚脐 z(≈0.114)
	float front = clamp((l.z + 0.124) / 0.11, 0.0, 1.0);
	float b = smoother(length(l.xy - fist_bulge.xy), 0.16 * max(0.2, fist_par.y)) * front;
	float rise = fist_par.z;
	vec3 o = vec3(0.0);
	o.z += over * 0.9 * fist_par.x * rise * b;
	o.y += over * 0.26 * fist_par.x * rise * b;
	o.x += fist_lean.x * 0.07 * over * b * 6.0 * fist_par.w * rise;
	o.z += fist_lean.y * 0.05 * over * b * 6.0 * fist_par.w * rise;
	return o;
}

// 肚脐形变（网页 navel-morph.ts applyNavelMorph）：杏仁形开口向内凹陷成管，开口外 0.32 圈渐隐。
// navel_m = (hx, hy, D, cap)，navel_s = (squeeze, planeZ)，均为 ab-local（原点 = 肚脐）
uniform float navel_on = 0.0;
uniform vec4 navel_m = vec4(0.0);
uniform vec2 navel_s = vec2(0.0, 0.006);

float almond_u(float dx, float dy, float hx, float hy) {
	float ny = dy / max(1e-6, hy);
	float point = ny >= 0.0 ? 0.58 : 0.34;
	float pinch = max(0.16, 1.0 - point * ny * ny);
	return length(vec2(dx / max(1e-6, hx * pinch), ny));
}

vec3 navel_offset(vec3 l) {
	if (navel_on <= 0.0) return vec3(0.0);
	float D = navel_m.z;
	float sq = navel_s.x;
	float pz = navel_s.y;
	if (D < 0.008 * 0.092 && sq < 0.008) return vec3(0.0);
	if (l.z < pz - 0.05 || length(l.xy) > 0.052) return vec3(0.0);
	float u = almond_u(l.x, l.y, navel_m.x, navel_m.y);
	if (u > 1.32) return vec3(0.0);
	float cap = navel_m.w;
	float target_u;
	float along;
	if (u <= 1.0) {
		if (u < 0.2) {
			float th = (u / 0.2) * PI * 0.5;
			target_u = sin(th);
			along = D - cap * (1.0 - cos(th));
		} else {
			target_u = 1.0;
			along = (D - cap) * (1.0 - (u - 0.2) / 0.8);
		}
	} else {
		float f = 1.0 - (u - 1.0) / 0.32;
		float s = f * f * (3.0 - 2.0 * f);
		return vec3(0.0, 0.0, (pz - l.z) * s * 0.16);
	}
	if (u < 1e-4) return vec3(-l.x, -l.y, pz - D - l.z);
	float k = target_u / u;
	vec2 t = l.xy * k;
	if (sq > 0.001 && u > 0.12 && u < 1.18) {
		float pin = sq * 0.58 * sin(PI * min(1.0, u / 1.05));
		t *= (1.0 - pin);
	}
	return vec3(t - l.xy, pz - along - l.z);
}

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 l = to_ab(wp);
	float m = belly_mask(l);
	vec3 off = (strike_offset(l) * skin_strike_k + drag_offset(l) * skin_drag_k + dent_offset(l)) * m + fist_offset(l) + navel_offset(l);
	l += off;
	vec3 off_w = ab_dir_to_world(off);
	wp += off_w;
	// 只对位移做 3×3 逆，避免 inverse(MODEL_MATRIX) 作用在带大平移的点上：
	// 移动端精度会让透视躯干相对四肢/肚脐偏移。
	VERTEX += inverse(mat3(MODEL_MATRIX)) * off_w;
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
