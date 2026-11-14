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
