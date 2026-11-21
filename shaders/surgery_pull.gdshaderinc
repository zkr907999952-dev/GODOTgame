// 0.3.8 手术拿取：皮肤 / 截面 / 腹腔 / 红线共用同一套位移，保证拉开时各层对齐。
// mode 0 = 旧径向整体平移；1 = 直线切口：只拉被抓的一侧唇缘（axis 指向该侧），沿切口 a→b 两端权重为 0；
// 2 = 环形洞缘：a = 洞中心，b.x = 洞半径，只拉 axis 方向那一段洞缘。坐标都是腹局部空间。
uniform vec3 surgery_pull_p = vec3(0.0);
uniform vec3 surgery_pull_off = vec3(0.0);
uniform float surgery_pull_r = 0.0;
uniform vec3 surgery_pull_a = vec3(0.0);
uniform vec3 surgery_pull_b = vec3(0.0);
uniform vec3 surgery_pull_axis = vec3(0.0);
uniform float surgery_pull_mode = 0.0;
// 0.4.03：直切口按实际切线折线（两唇中点）判断左右侧，不再用端点连线——
// 经过肚脐时切线会偏离端点连线 1~2mm，另一侧唇缘被误判成同侧一起拉走，截面横在开口上像粘连。
// poly[k].xyz = 腹局部中点，poly[k].w = 弧长；pax[k] = 该处指向被抓一侧的张开方向；sp = 抓点弧长。
const int SURGERY_PULL_MAXP = 24;
uniform int surgery_pull_np = 0;
uniform vec4 surgery_pull_poly[24];
uniform vec4 surgery_pull_pax[24];
uniform float surgery_pull_sp = 0.0;

vec3 surgery_pull_offset(vec3 l) {
	if (surgery_pull_r < 1e-5) return vec3(0.0);
	float w = 0.0;
	if (surgery_pull_mode > 0.5 && surgery_pull_mode < 1.5 && surgery_pull_np >= 2) {
		float bd = 1e9;
		vec3 br = vec3(0.0);
		vec3 bax = vec3(0.0);
		float bs = 0.0;
		for (int k = 0; k < SURGERY_PULL_MAXP - 1; k++) {
			if (k >= surgery_pull_np - 1) break;
			vec3 pa = surgery_pull_poly[k].xyz;
			vec3 pb = surgery_pull_poly[k + 1].xyz;
			vec3 e = pb - pa;
			float t = clamp(dot(l - pa, e) / max(dot(e, e), 1e-10), 0.0, 1.0);
			vec3 r = l - (pa + e * t);
			float d = dot(r, r);
			if (d < bd) {
				bd = d;
				br = r;
				bax = mix(surgery_pull_pax[k].xyz, surgery_pull_pax[k + 1].xyz, t);
				bs = mix(surgery_pull_poly[k].w, surgery_pull_poly[k + 1].w, t);
			}
		}
		float total = max(surgery_pull_poly[surgery_pull_np - 1].w, 1e-5);
		float T = clamp(bs / total, 0.0, 1.0);
		float side = dot(br, normalize(bax + vec3(1e-9)));
		float ends = sqrt(max(sin(3.14159265 * T), 0.0));
		float wside = smoothstep(0.0, 0.0015, side);
		float wfall = 1.0 - smoothstep(0.0, surgery_pull_r, length(br));
		float wgrab = 1.0 - smoothstep(0.0, 0.07, abs(bs - surgery_pull_sp));
		w = ends * wside * wfall * (0.35 + 0.65 * wgrab);
	} else if (surgery_pull_mode > 0.5 && surgery_pull_mode < 1.5) {
		vec3 ab = surgery_pull_b - surgery_pull_a;
		float L2 = max(dot(ab, ab), 1e-8);
		float t = clamp(dot(l - surgery_pull_a, ab) / L2, 0.0, 1.0);
		vec3 q = surgery_pull_a + ab * t;
		vec3 r = l - q;
		float side = dot(r, surgery_pull_axis);
		float ends = sqrt(max(sin(3.14159265 * t), 0.0));
		float wside = smoothstep(0.0, 0.0015, side);
		float wfall = 1.0 - smoothstep(0.0, surgery_pull_r, length(r));
		float tp = clamp(dot(surgery_pull_p - surgery_pull_a, ab) / L2, 0.0, 1.0);
		float wgrab = 1.0 - smoothstep(0.0, 0.07, abs(t - tp) * sqrt(L2));
		w = ends * wside * wfall * (0.35 + 0.65 * wgrab);
	} else if (surgery_pull_mode > 1.5) {
		vec3 r2 = l - surgery_pull_a;
		float dist = length(r2);
		float rim = abs(dist - surgery_pull_b.x);
		float cosang = dot(r2, surgery_pull_axis) / max(dist, 1e-5);
		w = smoothstep(0.15, 0.85, cosang) * (1.0 - smoothstep(0.0, surgery_pull_r, rim));
	} else {
		float d = length(l - surgery_pull_p);
		float t0 = clamp(1.0 - d / max(surgery_pull_r, 1e-4), 0.0, 1.0);
		w = t0 * t0 * (3.0 - 2.0 * t0);
	}
	return surgery_pull_off * w;
}
