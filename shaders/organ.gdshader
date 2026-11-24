// 体内脏器（大肠/小肠/子宫/膀胱/卵巢…）：湿润、微透光的粉红组织。
// 顶点：肠蠕动（网页 GutPeristalsis）+ 击腹冲击波（BellyStrike，仅肠）+ 拖拽软组织位移（organs soft=0.82）+ 特写果冻挤开。
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx, shadows_disabled;

#include "res://shaders/organ_common.gdshaderinc"

// 拳交时把被杆撑出的脏器限制在（含鼓包的）体表剖面内，避免穿出皮肤。
uniform int organ_contain = 0;
uniform int prof_n = 0;
uniform sampler2D prof_tex : hint_default_black, filter_nearest, repeat_disable;
uniform vec4 prof_bias = vec4(0.0);
uniform vec4 prof_scale = vec4(1.0);
uniform vec4 fist_bulge = vec4(0.0);
uniform vec2 fist_lean = vec2(0.0);
uniform vec4 fist_par = vec4(1.4, 1.0, 0.7, 1.0);
uniform float contain_margin = 0.008;

vec4 organ_prof_at(int i) {
	vec4 s = texture(prof_tex, vec2((float(i) + 0.5) / 24.0, 0.5));
	return s * prof_scale + prof_bias;
}

vec3 organ_torso_profile(float y) {
	if (prof_n <= 0) return vec3(0.15, 0.01, -0.13);
	vec4 a = organ_prof_at(0);
	if (y <= a.r) return a.gba;
	for (int i = 1; i < 24; i++) {
		if (i >= prof_n) break;
		vec4 b = organ_prof_at(i);
		if (y <= b.r) {
			float t = (y - a.r) / max(1e-5, b.r - a.r);
			return mix(a.gba, b.gba, t);
		}
		a = b;
	}
	return a.gba;
}

vec3 organ_fist_offset(vec3 l) {
	if (fist_bulge.w <= 0.0 || fist_bulge.z <= 0.0) return vec3(0.0);
	float over = fist_bulge.z;
	float front = clamp((l.z + 0.124) / 0.11, 0.0, 1.0);
	float d = length(l.xy - fist_bulge.xy);
	float r = 0.16 * max(0.2, fist_par.y);
	float t = d / max(r, 1e-4);
	float b = 0.0;
	if (t < 1.0) {
		float u = 1.0 - t;
		b = u * u * u * (u * (u * 6.0 - 15.0) + 10.0) * front;
	}
	float rise = fist_par.z;
	vec3 o = vec3(0.0);
	o.z += over * 0.9 * fist_par.x * rise * b;
	o.y += over * 0.26 * fist_par.x * rise * b;
	o.x += fist_lean.x * 0.07 * over * b * 6.0 * fist_par.w * rise;
	o.z += fist_lean.y * 0.05 * over * b * 6.0 * fist_par.w * rise;
	return o;
}

vec3 contain_inside_skin(vec3 l) {
	if (organ_contain <= 0 || prof_n <= 0) return l;
	vec3 pr = organ_torso_profile(l.y);
	vec3 bulge = organ_fist_offset(l);
	float hx = max(pr.x - contain_margin, 0.02);
	float zf = pr.y + bulge.z - contain_margin;
	float zb = pr.z + min(bulge.z, 0.0) + contain_margin;
	vec3 q = l;
	if (abs(q.x) > hx) q.x = sign(q.x) * hx;
	if (q.z > zf) q.z = zf;
	if (q.z < zb) q.z = zb;
	return q;
}


uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool use_tex = false;
uniform vec4 base_color : source_color = vec4(0.77, 0.47, 0.42, 1.0);
uniform float roughness = 0.48;
uniform float normal_scale = 0.9;
uniform float wet = 0.45;
uniform bool is_gut = false;
uniform bool is_uterus = false;
uniform float organ_soft = 0.82;
uniform float strike_k = 1.0;
uniform float peri_amp = 0.3;
uniform float peri_on = 1.0;
uniform float peri_waves = 1.55;  // 蠕动波数（沿肠管）
uniform float peri_seg = 1.0;     // 分节收缩强度倍数

float lobe(float frac, float width) {
	float d = min(frac, 1.0 - frac);
	float t = 1.0 - min(1.0, d / max(1e-4, width));
	return t * t * (3.0 - 2.0 * t);
}

// clk = 脚本里按速度积分的三个时钟：∫(0.03+0.2s)dt、∫(0.45+0.9s)dt、∫(0.25+0.5s)dt
// （速度滑条实时调整时相位连续，不会跳变）
uniform vec3 peri_clock = vec3(0.0);
// 肠道伤痕（网页 GutHealth 掉血变红）：xyz = ab-local，w = 程度
uniform vec4 dmg[12];
varying vec3 v_l0;

float pulse(float along, vec3 clk, float amp) {
	float n = max(0.2, peri_waves);
	float p = fract(along * n - clk.x * n);
	float perist = lobe(p, 0.34);
	float p2 = fract(along * 0.85 - clk.x * 0.55);
	float perist2 = lobe(p2, 0.42);
	float haustra = 0.5 + 0.5 * sin(along * 12.0 * PI - clk.y);
	float mixv = 0.5 + 0.5 * sin(along * 7.0 * PI + clk.z);
	float hs = haustra * haustra * (3.0 - 2.0 * haustra);
	float ms = mixv * mixv * (3.0 - 2.0 * mixv);
	float seg = hs * 0.45 + ms * 0.25;
	float shape = perist * 0.62 + perist2 * 0.28 + seg * 0.18 * peri_seg;
	return shape * (0.16 + amp * 0.42);
}

void vertex() {
	if (is_gut && peri_on > 0.0) {
		float k = pulse(CUSTOM0.x, peri_clock, peri_amp) * peri_on;
		VERTEX -= CUSTOM0.yzw * k;
	}
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 l = to_ab(wp);
	v_l0 = l;
	vec3 off = strike_offset(l) * strike_k + drag_offset(l) * organ_soft + dent_offset(l) * organ_soft + ball_tear(l) + jello_offset(l);
	// 腹部鼓包/搅动时，肠子和其它脏器跟着体表一起走（对照网页 FistPlay.deformColon + 肚皮 fist_offset）。
	// 以前只在 contain 里当边界，脏器不会随腹部鼓起或左右搅动。
	vec3 belly = organ_fist_offset(l);
	if (is_gut) {
		off += belly * 0.95;
		off += rod_offset(l + off);
	} else if (is_uterus) {
		off += belly * 0.72;
		off += uter_offset(l);
		off += rod_offset(l + off) * 0.55;
		off += speculum_offset(l + off);
	} else {
		off += belly * 0.62;
		off += speculum_offset(l + off);
	}
	// 0.4.11：阴道宫颈端跟随脱出的柔体子宫颈（未脱出时 canal_stretch_on=0）。
	off += canal_stretch(l + off);
	vec3 off_w = ab_dir_to_world(off);
	wp += off_w;
	VERTEX += inverse(mat3(MODEL_MATRIX)) * off_w;
	if (organ_contain > 0) {
		vec3 l2 = to_ab(wp);
		vec3 c = contain_inside_skin(l2);
		vec3 dw = ab_dir_to_world(c - l2);
		if (dot(dw, dw) > 1e-12) {
			wp += dw;
			VERTEX += inverse(mat3(MODEL_MATRIX)) * dw;
		}
	}
}

void fragment() {
	vec3 c = base_color.rgb;
	if (use_tex) {
		c = texture(albedo_tex, UV).rgb * base_color.rgb;
		NORMAL_MAP = texture(normal_tex, UV).rgb;
		NORMAL_MAP_DEPTH = normal_scale;
	}
	float hurt = 0.0;
	for (int i = 0; i < 12; i++) {
		if (dmg[i].w <= 0.0) continue;
		vec3 dd = v_l0 - dmg[i].xyz;
		hurt = max(hurt, dmg[i].w * exp(-dot(dd, dd) / (0.03 * 0.03)));
	}
	hurt = max(hurt, ball_hurt(v_l0) * 0.9);
	c *= vec3(1.0, 1.0 - hurt * 0.88, 1.0 - hurt * 0.9);
	if (!FRONT_FACING) c *= 0.55;
	ALBEDO = c;
	METALLIC = 0.0;
	// Mobile 渲染器没有清漆层和皮下散射：写了那些内置输出会导致整段 shader 在真机上编译失败，
	// 内脏回退成原来的不透明材质，透视窗口里什么也看不见。用粗糙度 + 微弱自发光近似湿润感。
	ROUGHNESS = clamp(roughness * (1.0 - wet * 0.28), 0.18, 0.95);
	SPECULAR = 0.55;
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	EMISSION = c * (fres * 0.06 + wet * 0.035);
}
