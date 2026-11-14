// 体内脏器（大肠/小肠/子宫/膀胱/卵巢…）：湿润、微透光的粉红组织。
// 顶点：肠蠕动（网页 GutPeristalsis）+ 击腹冲击波（BellyStrike，仅肠）+ 拖拽软组织位移（organs soft=0.82）。
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx, shadows_disabled;

#include "res://shaders/organ_common.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool use_tex = false;
uniform vec4 base_color : source_color = vec4(0.77, 0.47, 0.42, 1.0);
uniform float roughness = 0.48;
uniform float normal_scale = 0.9;
uniform float wet = 0.45;
uniform bool is_gut = false;
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
	vec3 off = strike_offset(l) * strike_k + drag_offset(l) * organ_soft;
	wp += ab_dir_to_world(off);
	VERTEX = (inverse(MODEL_MATRIX) * vec4(wp, 1.0)).xyz;
}

void fragment() {
	vec3 c = base_color.rgb;
	if (use_tex) {
		c = texture(albedo_tex, UV).rgb * base_color.rgb;
		NORMAL_MAP = texture(normal_tex, UV).rgb;
		NORMAL_MAP_DEPTH = normal_scale;
	}
	if (!FRONT_FACING) c *= 0.55;
	ALBEDO = c;
	METALLIC = 0.0;
	ROUGHNESS = roughness;
	SPECULAR = 0.55;
	CLEARCOAT = wet;
	CLEARCOAT_ROUGHNESS = 0.18;
	SSS_STRENGTH = 0.35;
	// 轻微边缘透光（湿润浆膜感）
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	EMISSION = c * fres * 0.06;
}
