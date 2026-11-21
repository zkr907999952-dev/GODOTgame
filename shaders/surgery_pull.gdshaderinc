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

vec3 surgery_pull_offset(vec3 l) {
	if (surgery_pull_r < 1e-5) return vec3(0.0);
	float w = 0.0;
	if (surgery_pull_mode > 0.5 && surgery_pull_mode < 1.5) {
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
