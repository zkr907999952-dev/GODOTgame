// 腹部透视 / 脏器互动 公共代码（移植自网页 figure.tsx injectXray + belly-strike.ts + peristalsis.ts）
// 所有互动坐标都在「腹部局部坐标系」(ab-local)：原点 = 姿态后的肚脐，轴 = C_Spine_a 骨骼的 右/上/前。

uniform vec3 ab_navel = vec3(0.0, 1.06, 0.11);
uniform vec3 ab_right = vec3(1.0, 0.0, 0.0);
uniform vec3 ab_up = vec3(0.0, 1.0, 0.0);
uniform vec3 ab_fwd = vec3(0.0, 0.0, 1.0);

// 击腹冲击波（最多 4 个）：xyz = ab-local 原点，w = 已过时间(s)，w<0 为空
uniform vec4 strike_pos[4];
// x = force, y = range, z = rebound
uniform vec4 strike_par[4];

// 拖拽：抓取点 / 当前位移（ab-local），半径
uniform vec3 drag_grab = vec3(0.0);
uniform vec3 drag_off = vec3(0.0);
uniform float drag_radius = 0.16;

vec3 to_ab(vec3 w) {
	vec3 d = w - ab_navel;
	return vec3(dot(d, ab_right), dot(d, ab_up), dot(d, ab_fwd));
}

vec3 ab_dir_to_world(vec3 o) {
	return o.x * ab_right + o.y * ab_up + o.z * ab_fwd;
}

// 网页 BellyStrike.apply：环形波 + 中心凹陷
vec3 strike_offset(vec3 p) {
	vec3 q = p;
	for (int i = 0; i < 4; i++) {
		vec4 w = strike_pos[i];
		if (w.w < 0.0) continue;
		float force = strike_par[i].x;
		float range = strike_par[i].y;
		float rebound = strike_par[i].z;
		float t = w.w;
		float rec = 1.05 + (1.0 - clamp(rebound, 0.0, 1.0)) * 2.4;
		float decay = 0.28 + rebound * 0.85;
		float dx = q.x - w.x;
		float dy = q.y - w.y;
		float r = sqrt(dx * dx + dy * dy);
		float span = 0.055 + range * 0.13;
		float ring_r = t * (0.18 + range * 0.15);
		float width = 0.03 + range * 0.024;
		float life = max(0.0, 1.0 - t / rec);
		float fade = life * life * (3.0 - 2.0 * life);
		float rr = (r - ring_r) / width;
		float ring = exp(-rr * rr);
		float hole = exp(-(r * r) / (span * span * 0.55)) * exp(-t * decay);
		float amp = force * fade;
		float inv = r < 1e-4 ? 0.0 : 1.0 / r;
		float push = amp * (0.03 * ring + 0.026 * hole);
		float crush = amp * (0.062 * hole + 0.018 * ring);
		q.x += dx * inv * push;
		q.y += dy * inv * push * 0.7;
		q.z -= crush;
	}
	return q - p;
}

// 网页 setTissueDrag（软笼拖拽）近似：以抓取点为中心的高斯衰减位移
vec3 drag_offset(vec3 p) {
	vec3 d = p - drag_grab;
	float s = drag_radius * 0.5;
	float w = exp(-dot(d, d) / (2.0 * s * s));
	return drag_off * w;
}

// 拳交 / 刺刀「杆」（网页 FistPlay.deformColon / BayonetPlay.deformGuts）：把杆周围的肠管推到杆半径外。
// rod_a: xyz = 起点(ab-local)，w = 长度（<=0 关闭）；rod_d: xyz = 方向，w = 半径；rod_m: x = 混合，y = 起点前的余量(s_min)
uniform vec4 rod_a[2];
uniform vec4 rod_d[2];
uniform vec4 rod_m[2];

// rod_m: x=混合, y=s_min, z=入口半径（0 则与杆头半径相同，用于手臂由粗到细）
vec3 rod_offset(vec3 p) {
	vec3 q = p;
	for (int i = 0; i < 2; i++) {
		float reach = rod_a[i].w;
		if (reach <= 0.0) continue;
		vec3 a = rod_a[i].xyz;
		vec3 d = rod_d[i].xyz;
		vec3 v = q - a;
		float smin = rod_m[i].y;
		float s = clamp(dot(v, d), smin, reach);
		float w = 1.0 - smoothstep(reach - 0.01, reach + 0.05, s);
		if (w < 0.02) continue;
		float tip_r = rod_d[i].w;
		float base_r = rod_m[i].z;
		if (base_r < 1e-5) base_r = tip_r;
		float t = clamp((s - smin) / max(reach - smin, 1e-4), 0.0, 1.0);
		float rad = mix(base_r, tip_r, t);
		vec3 c = a + d * s;
		vec3 o = q - c;
		float len = length(o);
		float want = rad + 0.01 * w;
		float mixv = rod_m[i].x;
		// 网页 deformColon / deformGuts：杆内顶点撑到半径外
		if (len < want) {
			vec3 o2 = len > 1e-5 ? o * (want / len) : vec3(want, 0.0, 0.0);
			q += (c + o2 - q) * w * mixv;
			o = q - c;
			len = length(o);
		}
		// 附近肠袢被推开（软衰减），让通道随拳头移动时更明显
		float infl = rad * 2.9 + 0.02;
		if (len < infl) {
			float aw = 1.0 - smoothstep(want * 0.8, infl, len);
			aw = aw * aw * w;
			vec3 nrm = len > 1e-5 ? o / len : vec3(1.0, 0.0, 0.0);
			q += nrm * max(0.0, infl - len) * 0.52 * mixv * aw;
		}
	}
	return q - p;
}

// 子宫被拳头顶到时的整体位移 / 压缩 / 倾斜（脚本里弹簧积分后写入）
uniform vec3 uter_pivot = vec3(0.0);
uniform vec3 uter_off = vec3(0.0);
uniform vec4 uter_rot = vec4(0.0, 1.0, 0.0, 0.0); // xyz 轴, w 弧度
uniform vec4 uter_sq = vec4(0.0, 1.0, 0.0, 0.0);  // xyz 压缩轴, w 压缩量 0..1

vec3 uter_offset(vec3 p) {
	vec3 q = p - uter_pivot;
	vec3 sax = uter_sq.xyz;
	float ca = uter_sq.w;
	if (ca > 1e-5 && dot(sax, sax) > 0.25) {
		sax = normalize(sax);
		q -= sax * dot(q, sax) * ca;
	}
	float ang = uter_rot.w;
	vec3 rax = uter_rot.xyz;
	if (abs(ang) > 1e-5 && dot(rax, rax) > 0.25) {
		rax = normalize(rax);
		float c = cos(ang);
		float s = sin(ang);
		q = q * c + cross(rax, q) * s + rax * dot(rax, q) * (1.0 - c);
	}
	return (uter_pivot + q + uter_off) - p;
}

// 刺入前的压陷（网页 squeezeTarget → setTissueDrag 小半径）：xyz = 中心，w = 半径；dent_off = 位移
uniform vec4 dent = vec4(0.0);
uniform vec3 dent_off = vec3(0.0);

vec3 dent_offset(vec3 p) {
	if (dent.w <= 0.0) return vec3(0.0);
	vec3 d = p - dent.xyz;
	return dent_off * exp(-dot(d, d) / (dent.w * dent.w));
}

// 弹道通道（最多 4 条）：ball_a.xyz = 入射点(ab-local)，w = 半径；ball_b.xyz = 方向，w = 长度（<=0 关闭）
uniform vec4 ball_a[4];
uniform vec4 ball_b[4];

float ball_dist(vec3 l, int i, out float t, out vec3 radial) {
	vec3 a = ball_a[i].xyz;
	vec3 d = ball_b[i].xyz;
	float len = ball_b[i].w;
	vec3 p = l - a;
	t = clamp(dot(p, d), 0.0, len);
	radial = p - d * t;
	return length(radial);
}

float ball_wound(vec3 l) {
	float h = 0.0;
	for (int i = 0; i < 4; i++) {
		if (ball_b[i].w <= 0.0) continue;
		float t;
		vec3 radial;
		float dist = ball_dist(l, i, t, radial);
		float rad = max(ball_a[i].w, 0.0035);
		h = max(h, 1.0 - smoothstep(rad * 0.4, rad * 1.05, dist));
		float te = length(l - ball_a[i].xyz);
		float tx = length(l - (ball_a[i].xyz + ball_b[i].xyz * ball_b[i].w));
		h = max(h, 1.0 - smoothstep(rad * 0.7, rad * 1.7, min(te, tx)));
	}
	return clamp(h, 0.0, 1.0);
}

vec3 ball_tear(vec3 l) {
	vec3 o = vec3(0.0);
	for (int i = 0; i < 4; i++) {
		if (ball_b[i].w <= 0.0) continue;
		float t;
		vec3 radial;
		float dist = ball_dist(l, i, t, radial);
		float rad = max(ball_a[i].w, 0.004);
		float k = exp(-dist * dist / (rad * rad * 2.8)) * rad * 0.85;
		if (dist > 1e-5) o += (radial / dist) * k;
	}
	return o;
}

float ball_hurt(vec3 l) {
	float h = 0.0;
	for (int i = 0; i < 4; i++) {
		if (ball_b[i].w <= 0.0) continue;
		float t;
		vec3 radial;
		float dist = ball_dist(l, i, t, radial);
		float rad = max(ball_a[i].w * 2.2, 0.012);
		h = max(h, exp(-dist * dist / (rad * rad)));
	}
	return h;
}


