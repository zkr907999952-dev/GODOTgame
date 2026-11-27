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

// 阴道扩张器：上下两瓣共享同一个圆角矩形（stadium）扩张体积，
// 组织贴合两瓣外壳加上中间空隙的凸包外表面。
// spec_o.xyz = 开口(ab-local)，w = 插入深度（<=0 关闭）
// spec_d.xyz = 朝宫颈方向，w = 尖端半开距（米）
// spec_u.xyz = 开合方向（耻骨/会阴），w = 叶片半宽
// spec_m.x = 混合，y = 外口半高，z = 圆角半径（默认 4 mm）
uniform vec4 spec_o = vec4(0.0);
uniform vec4 spec_d = vec4(0.0);
uniform vec4 spec_u = vec4(0.0);
uniform vec4 spec_m = vec4(0.0);

float stadium_sdf(vec2 p, vec2 he, float cr) {
	float c = max(cr, 0.0005);
	vec2 h = max(he, vec2(c + 0.0004));
	vec2 q = abs(p) - h + vec2(c);
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - c;
}

vec2 stadium_grad(vec2 p, vec2 he, float cr) {
	float c = max(cr, 0.0005);
	vec2 h = max(he, vec2(c + 0.0004));
	vec2 q = abs(p) - h + vec2(c);
	vec2 s = vec2(p.x >= 0.0 ? 1.0 : -1.0, p.y >= 0.0 ? 1.0 : -1.0);
	if (q.x > 0.0 && q.y > 0.0) {
		float L = length(q);
		if (L < 1e-8) return vec2(0.0, s.y);
		return s * (q / L);
	}
	if (q.x > q.y) return vec2(s.x, 0.0);
	return vec2(0.0, s.y);
}

vec2 stadium_ray(vec2 p, vec2 he, float cr) {
	float c = max(cr, 0.0005);
	vec2 h = max(he, vec2(c + 0.0004));
	c = min(c, min(h.x, h.y) - 0.0004);
	float L = length(p);
	if (L < 1e-8) return vec2(0.0, h.y);
	vec2 d = p / L;
	vec2 flat_v = h - vec2(c);
	if (abs(d.x) > 1e-8) {
		float t_side = h.x / abs(d.x);
		if (abs(t_side * d.y) <= flat_v.y + 1e-6) return d * t_side;
	}
	if (abs(d.y) > 1e-8) {
		float t_tb = h.y / abs(d.y);
		if (abs(t_tb * d.x) <= flat_v.x + 1e-6) return d * t_tb;
	}
	vec2 s = vec2(d.x >= 0.0 ? 1.0 : -1.0, d.y >= 0.0 ? 1.0 : -1.0);
	vec2 cc = s * flat_v;
	float b = -2.0 * dot(d, cc);
	float c0 = dot(cc, cc) - c * c;
	float disc = b * b - 4.0 * c0;
	if (disc < 0.0) return vec2(d.x * h.x, d.y * h.y);
	float t = (-b + sqrt(disc)) * 0.5;
	if (t < 0.0) t = (-b - sqrt(disc)) * 0.5;
	t = max(t, 0.0);
	return d * t;
}

vec3 speculum_offset(vec3 p) {
	float depth = spec_o.w;
	if (depth <= 0.0) return vec3(0.0);
	vec3 o = spec_o.xyz;
	vec3 ax = spec_d.xyz;
	float al = length(ax);
	if (al < 1e-5) return vec3(0.0);
	ax /= al;
	vec3 up = spec_u.xyz;
	up = up - ax * dot(up, ax);
	float ul = length(up);
	if (ul < 1e-5) return vec3(0.0);
	up /= ul;
	vec3 side = cross(ax, up);
	float sl = length(side);
	if (sl < 1e-5) return vec3(0.0);
	side /= sl;
	float half_tip = max(spec_d.w, 0.002);
	float half_side = max(spec_u.w, 0.008);
	float mixv = clamp(spec_m.x, 0.0, 1.0);
	float half_closed = max(spec_m.y, 0.002);
	float cr = spec_m.z;
	if (cr < 1e-5) cr = 0.004;
	vec3 v = p - o;
	float s = dot(v, ax);
	// 体外一侧只推 7 mm，避免外口/大腿连接被顶出体表。
	float smin = -0.007;
	float smax = depth + 0.014;
	if (s < smin - 0.012 || s > smax + 0.025) return vec3(0.0);
	float along_w = smoothstep(smin - 0.008, smin, s) * (1.0 - smoothstep(smax, smax + 0.02, s));
	if (along_w < 0.01) return vec3(0.0);
	float along = clamp(s / max(depth, 1e-4), 0.0, 1.0);
	float ry = mix(half_closed, half_tip, along);
	float rx = half_side * mix(1.0, 0.85, along);
	cr = min(cr, min(rx, ry) - 0.0004);
	float xu = dot(v, side);
	float yu = dot(v, up);
	float e = stadium_sdf(vec2(xu, yu), vec2(rx, ry), cr);
	if (e >= 0.0) return vec3(0.0);
	// 沿径向推到外壳，避免近轴点被推到左右侧壁。
	vec2 hit = stadium_ray(vec2(xu, yu), vec2(rx, ry), cr);
	return (side * (hit.x - xu) + up * (hit.y - yu)) * mixv * along_w;
}

// 阴道扩张环：跟着金属球沿轴线走，弹性，球过后回缩到杆径。
// dilate_o.xyz = 外口(ab-local)，w = 球心沿轴深度（可负；w 同时作开关，mix 在 dilate_p.x）
// dilate_d.xyz = 朝宫颈单位轴，w = 球半径
// dilate_p.x = mix，y = 杆半径，z = 尾迹残留（0..1），w = 宫颈深度
uniform vec4 dilate_o = vec4(0.0);
uniform vec4 dilate_d = vec4(0.0);
uniform vec4 dilate_p = vec4(0.0);
// 扩张环相对轴线的侧向偏移（球不在轴上时，环跟着球走）。
uniform vec3 dilate_lat = vec3(0.0);

// 与下面 CPU 的 OrganRig.canal_dilate_radius_at 保持同一公式。
// dilate_p.y 已含杆的撑开余量。dilate_sh[8] / dilate_s01 是延迟回缩的显示半径（沿轴 32 档）。
uniform vec4 dilate_sh[8];
uniform vec2 dilate_s01 = vec2(0.0); // x=s0, y=s1；y<=x 则关闭采样

float dilate_shown_at(float along) {
	float s0 = dilate_s01.x;
	float s1 = dilate_s01.y;
	if (s1 - s0 < 1e-5) return 0.0;
	float u = clamp((along - s0) / (s1 - s0), 0.0, 1.0);
	float f = u * 31.0;
	int i = clamp(int(floor(f)), 0, 30);
	int j = i + 1;
	int ia = i / 4;
	int ib = j / 4;
	float a = dilate_sh[ia][i - ia * 4];
	float b = dilate_sh[ib][j - ib * 4];
	return mix(a, b, clamp(f - float(i), 0.0, 1.0));
}

float dilate_instant_radius(float along) {
	float mixv = dilate_p.x;
	float R = dilate_d.w;
	if (mixv <= 0.001 || R <= 1e-6) return 0.0;
	float ball_s = dilate_o.w;
	float shaft = max(dilate_p.y, 0.0);
	float residual = clamp(dilate_p.z, 0.0, 1.0);
	float ds = along - ball_s;
	float slice = 0.0;
	if (abs(ds) <= R) {
		slice = sqrt(max(R * R - ds * ds, 0.0));
	}
	float target = slice;
	// 杆在球后方（向外口一侧，进入宫腔后也含宫颈段）一直有撑开体积。
	if (along < ball_s && along > -0.04) {
		target = max(target, shaft);
	}
	if (along < ball_s && residual > 0.001) {
		float wake = residual * R * exp(-max(ball_s - along, 0.0) / max(R * 3.2, 0.01));
		target = max(target, shaft + wake);
	}
	return target;
}

float dilate_target_radius(float along) {
	return max(dilate_instant_radius(along), dilate_shown_at(along));
}

// 平滑下限：把半径 r 推到不小于 n，但在 n 附近用二次过渡（C1 连续、单调），
// 返回需要增加的径向位移（>=0）。内外壁共用同一函数，只差 n（外壁 = 内壁 + 壁厚），
// 因此外壁永远不会被内壁追上，也没有 0→常数 的跳变（旧版软区在 need 处有 6.4 mm 台阶，导致撕面）。
float smooth_push(float r, float n, float w) {
	if (r >= n + w) return 0.0;
	if (r <= n - w) return n - r;
	float t = n + w - r;
	return t * t / (4.0 * w);
}

// 0.4.17（t5u）：手术取出的柔体子宫被钢球 / 杆穿着时的撑开（模型空间，只写给 SoftOrgan 材质）。
// 单一单调径向映射 d → max(d, n(d))（平滑过渡）：腔内贴近中线的内膜推到 ≥ 球半径，
// 外膜按原来离中线的距离多推，内外壁次序不变（内膜永远追不上外膜），球处至少保留一层壁厚，也没有台阶。
uniform vec4 soft_ball = vec4(0.0);      // xyz = 球心，w = 球半径（0 = 关）
uniform vec4 soft_shaft = vec4(0.0);     // xyz = 杆进入宫颈处，w = 杆余量半径
uniform float soft_ball_alpha = 0.5;
uniform float soft_ball_wall = 0.0035;

// 目标半径 n(d) = R + a·d + (1−a)·W·(1−e^(−d/W))：中线附近斜率 1（壁厚原样保留到 W），远处斜率 a。
float soft_push_amount(float d, float R) {
	float a = soft_ball_alpha;
	float W = max(soft_ball_wall, 1e-4);
	float n = R + a * d + (1.0 - a) * W * (1.0 - exp(-d / W));
	return smooth_push(d, n, 0.004);
}

// 杆 + 球合成一根胶囊：离线段最近点 t 处的半径 = max(杆, 球截面)（球心处 = 球半径），
// 只沿一个方向推一次，映射对 d 单调。
vec3 soft_ball_push(vec3 p) {
	if (soft_ball.w <= 0.0) return p;
	vec3 B = soft_ball.xyz;
	vec3 A = soft_shaft.w > 0.0 ? soft_shaft.xyz : B;
	vec3 ab = B - A;
	float L2 = dot(ab, ab);
	float t = L2 > 1e-10 ? clamp(dot(p - A, ab) / L2, 0.0, 1.0) : 1.0;
	float back = (1.0 - t) * sqrt(L2);
	float R = max(soft_shaft.w, sqrt(max(soft_ball.w * soft_ball.w - back * back, 0.0)));
	vec3 dv = p - (A + ab * t);
	float d = length(dv);
	if (d > 1e-6) p += dv / d * soft_push_amount(d, R);
	return p;
}

// 外膜相对内膜的壁厚（只有子宫外膜 > 0，其它网格 0）。撑开时内外壁用同一场、外壁多加这一层。
uniform float shell_wall = 0.0;

vec3 dilate_offset(vec3 p) {
	float mixv = max(dilate_p.x, 0.0);
	float R = dilate_d.w;
	if ((mixv <= 0.001 || R <= 1e-6) && dilate_s01.y - dilate_s01.x < 1e-5) return vec3(0.0);
	if (R <= 1e-6) return vec3(0.0);
	vec3 o = dilate_o.xyz;
	vec3 ax = dilate_d.xyz;
	float al = length(ax);
	if (al < 1e-5) return vec3(0.0);
	ax /= al;
	vec3 v = p - o;
	float s = dot(v, ax);
	float ball_s = dilate_o.w;
	float smin = min(-0.04, ball_s - R - 0.02);
	float smax = max(ball_s + R + 0.02, dilate_p.w + R + 0.02);
	if (s < smin - 0.035 || s > smax + 0.035) return vec3(0.0);
	float along_w = smoothstep(smin - 0.03, smin + 0.004, s) * (1.0 - smoothstep(smax - 0.004, smax + 0.03, s));
	if (along_w < 0.01) return vec3(0.0);
	vec3 radial = v - ax * s - dilate_lat;
	float pr = length(radial);
	vec3 rdir;
	if (pr < 1e-6) {
		rdir = normalize(cross(ax, abs(ax.x) < 0.9 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0)));
		pr = 0.0;
	} else {
		rdir = radial / pr;
	}
	float target = dilate_target_radius(s);
	if (target <= 1e-6) return vec3(0.0);
	target += shell_wall;
	float push = smooth_push(pr, target, 0.004);
	if (push <= 0.0) return vec3(0.0);
	float mix_eff = mixv > 0.001 ? mixv : 1.0;
	return rdir * push * mix_eff * along_w;
}

// 子宫 / 宫腔被球撑开。uter_ball.xyz = 球心(ab)，w = 球半径（<=0 关闭）
// uter_ball_p.x = mix，y = 额外壁厚（外膜），z = 最大允许膨胀半径
uniform vec4 uter_ball = vec4(0.0);
uniform vec4 uter_ball_p = vec4(0.0);

uniform vec3 uterus_ball_axis = vec3(0.0);

vec3 uterus_ball_offset(vec3 p) {
	float R = uter_ball.w;
	float mixv = uter_ball_p.x;
	if (R <= 1e-6 || mixv <= 0.001) return vec3(0.0);
	float wall = max(uter_ball_p.y, 0.0);
	float cap = uter_ball_p.z;
	float shaft = max(uter_ball_p.w, 0.0);
	vec3 c = uter_ball.xyz;
	vec3 ax = uterus_ball_axis;
	float al = length(ax);
	vec3 d;
	float need;
	if (al > 1e-5 && shaft > 1e-5) {
		// 胶囊：球心 + 沿杆轴向外口一侧的杆段，宫壁始终包住球和杆。
		ax /= al;
		float slen = max(dilate_o.w, 0.0) + R;
		vec3 a = c;
		vec3 b = c - ax * slen;
		vec3 ab = b - a;
		float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-8), 0.0, 1.0);
		vec3 q = a + ab * t;
		d = p - q;
		// 近球端用球半径，杆段用杆半径，交接处平滑。
		float kball = 1.0 - smoothstep(0.0, max(R, 0.004), t * slen);
		need = mix(shaft, R, kball);
	} else {
		d = p - c;
		need = R;
	}
	// 先对内膜半径限幅，再加壁厚：内外壁同一个场，外壁 = 内壁 + wall。
	if (cap > 1e-5) need = min(need, cap);
	need += wall;
	float dist = length(d);
	if (dist < 1e-6) {
		vec3 fb = al > 1e-5 ? ax * need * 0.25 : vec3(0.0, need * 0.25, 0.0);
		return fb * mixv;
	}
	float push = smooth_push(dist, need, 0.008);
	if (push <= 0.0) return vec3(0.0);
	return (d / dist) * push * mixv;
}

// t89u：片段是否落在钢球/杆的撑开体积内（不含宫壁额外厚度）。
// 宫腔大三角弦会切过球体，看起来像穿模的粉色面；在 organ 着色器里丢掉这些片段。
bool inside_uter_insert(vec3 p, float slop) {
	float R = uter_ball.w;
	float mixv = uter_ball_p.x;
	if (R <= 1e-6 || mixv <= 0.001) return false;
	float shaft = max(uter_ball_p.w, 0.0);
	float capr = uter_ball_p.z;
	vec3 c = uter_ball.xyz;
	vec3 ax = uterus_ball_axis;
	float al = length(ax);
	vec3 d;
	float need;
	if (al > 1e-5 && shaft > 1e-5) {
		ax /= al;
		float slen = max(dilate_o.w, 0.0) + R;
		vec3 a = c;
		vec3 b = c - ax * slen;
		vec3 ab = b - a;
		float tt = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-8), 0.0, 1.0);
		vec3 q = a + ab * tt;
		d = p - q;
		float kball = 1.0 - smoothstep(0.0, max(R, 0.004), tt * slen);
		need = mix(shaft, R, kball);
	} else {
		d = p - c;
		need = R;
	}
	if (capr > 1e-5) need = min(need, capr);
	return length(d) < need - slop;
}


// 弹道通道（最多 4 条）：ball_a.xyz = 入射点(ab-local)，w = 半径；ball_b.xyz = 方向，w = 长度（<=0 关闭）
uniform vec4 ball_a[4];
uniform vec4 ball_b[4];
// 特写穿过时限制通道只画到弹头已经走过的长度；很大 = 整条通道。
uniform float ball_travel = 99.0;

float ball_dist(vec3 l, int i, out float t, out vec3 radial) {
	vec3 a = ball_a[i].xyz;
	vec3 d = ball_b[i].xyz;
	float len = min(ball_b[i].w, max(ball_travel, 0.0));
	vec3 p = l - a;
	t = clamp(dot(p, d), 0.0, len);
	radial = p - d * t;
	return length(radial);
}

// 特写果冻挤开：弹头沿通道把软组织撑开，尖端鼓起，随后缓慢回弹，而不是整段静态撕裂。
// jello_a.xyz = 入射点(ab-local)，w = 当前已走过的长度
// jello_b.xyz = 方向，w = 半径
// jello_p.x = 强度，y = 回弹(0 刚穿过 / 1 基本静止)，z = 墙钟时间（摆动），w = 通道全长
uniform vec4 jello_a = vec4(0.0);
uniform vec4 jello_b = vec4(0.0);
uniform vec4 jello_p = vec4(0.0);

vec3 jello_offset(vec3 l) {
	float reach = jello_a.w;
	float tot = jello_p.w;
	float strength = jello_p.x;
	if (strength <= 1e-5 || (reach <= 0.0 && tot <= 0.0)) return vec3(0.0);
	float rad = max(jello_b.w, 0.007);
	float settle = clamp(jello_p.y, 0.0, 1.0);
	float age = jello_p.z;
	vec3 a = jello_a.xyz;
	vec3 d = jello_b.xyz;
	if (dot(d, d) < 1e-8) return vec3(0.0);
	d = normalize(d);
	vec3 v = l - a;
	float s = dot(v, d);
	// 只影响已经走过的通道，并给尖端一点点前探。
	float ahead = rad * 1.15;
	if (s < -rad * 0.8 || s > reach + ahead) return vec3(0.0);
	float t = clamp(s, 0.0, max(reach, 0.0));
	vec3 radial = v - d * t;
	float dist = length(radial);
	float infl = rad * (3.2 + (1.0 - settle) * 1.2);
	if (dist > infl) return vec3(0.0);
	vec3 nrm = dist > 1e-5 ? radial / dist : vec3(1.0, 0.0, 0.0);
	float shaft = exp(-dist * dist / (rad * rad * 10.0));
	float tip = exp(-((s - reach) * (s - reach)) / (rad * rad * 6.5));
	// 慢动作果冻摆动：穿过时轻柔起伏，停留阶段缓慢回弹，避免气球般鼓胀。
	float wob = 1.0 + (1.0 - settle) * 0.10 * sin(age * 7.2 + dist * 20.0 + s * 11.0);
	wob += settle * 0.04 * sin(age * 3.1 + s * 8.0);
	float live = 1.0 - settle * 0.55;
	float k = strength * shaft * live * wob;
	vec3 o = nrm * (rad * 1.05 * k + rad * 1.15 * tip * (1.0 - settle) * strength);
	// 尖端再沿弹道把组织轻轻推开，像弹头挤过去。
	o += d * tip * rad * 0.35 * (1.0 - settle) * strength;
	return o;
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



// 0.4.11：子宫脱出时阴道沿通道轴拉伸，宫颈端跟到柔体子宫颈。
uniform float canal_stretch_on = 0.0;
uniform vec3 canal_os_rest = vec3(0.0);
uniform vec3 canal_os_now = vec3(0.0);
uniform vec3 canal_open_rest = vec3(0.0);

vec3 canal_stretch(vec3 p) {
	if (canal_stretch_on <= 1e-5) return vec3(0.0);
	vec3 axis = canal_os_rest - canal_open_rest;
	float len2 = dot(axis, axis);
	if (len2 < 1e-8) return vec3(0.0);
	float t = clamp(dot(p - canal_open_rest, axis) / len2, 0.0, 1.0);
	t = t * t * (3.0 - 2.0 * t);
	vec3 mid = canal_open_rest + axis * (dot(p - canal_open_rest, axis) / len2);
	float rad = length(p - mid);
	float rw = 1.0 - smoothstep(0.018, 0.038, rad);
	if (rw <= 1e-5) return vec3(0.0);
	return (canal_os_now - canal_os_rest) * t * rw * canal_stretch_on;
}


// 0.4.12 子宫脱垂：通道被下移的脱出物撑开（t68u 起不再内翻折叠）。只写给阴道网格（prol_o.w = 1）。
// prol_o.xyz = 外口(ab)，w = 开关；prol_a.xyz = 外口→宫颈单位轴，w = 通道长；
// prol_p.x = 下移量 descent，y = 宫颈尖的路径坐标（正 = 在外口里面），z = 子宫长，w = 阴道壁厚；
// prol_r0 / prol_r1 = 子宫截面半径（宫颈尖 → 宫底均分 8 份），与 ProlapseController.mass_radius_at 同一公式。
uniform vec4 prol_o = vec4(0.0);
uniform vec4 prol_a = vec4(0.0, 1.0, 0.0, 0.05);
uniform vec4 prol_p = vec4(0.0);
uniform vec4 prol_r0 = vec4(0.0);
uniform vec4 prol_r1 = vec4(0.0);

float prol_prof(int i) {
	if (i < 4) return prol_r0[i];
	return prol_r1[i - 4];
}

float prol_radius(float a) {
	float U = prol_p.z;
	float r0 = prol_r0.x;
	if (U <= 1e-5 || r0 <= 1e-6) return 0.0;
	if (a < 0.0) {
		float t = clamp(-a / max(r0, 1e-4), 0.0, 1.0);
		return r0 * sqrt(max(1.0 - t * t, 0.0));
	}
	if (a >= U) return 0.0;
	float f = a / U * 7.0;
	int i = clamp(int(floor(f)), 0, 6);
	return mix(prol_prof(i), prol_prof(i + 1), clamp(f - float(i), 0.0, 1.0));
}

// xyz = 位移，w > 0.5 = 该点已内翻（法线反向，黏膜朝外）。
vec4 prolapse_offset4(vec3 p) {
	if (prol_o.w < 0.5) return vec4(0.0);
	float d = prol_p.x;
	if (d <= 1e-5) return vec4(0.0);
	float ramp = clamp(d / 0.01, 0.0, 1.0);
	vec3 ax = prol_a.xyz;
	float al = length(ax);
	if (al < 1e-5) return vec4(0.0);
	ax /= al;
	float L = prol_a.w;
	float tip = prol_p.y;
	float w = prol_p.w;
	vec3 v = p - prol_o.xyz;
	float s = dot(v, ax);
	if (s < -0.012 || s > L + 0.03) return vec4(0.0);
	vec3 radial = v - ax * s;
	float r = length(radial);
	if (r > 0.085) return vec4(0.0);
	vec3 rdir = r > 1e-6 ? radial / r : normalize(cross(ax, abs(ax.x) < 0.9 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0)));
	// t68u 简化：不再做双层内翻折叠（体外也没有套筒），阴道只被下移的脱出物沿径向撑开。
	// t86u：管腔内径 = 子宫/宫颈截面半径 + 壁厚 + 4 mm 余量，避免脱垂子宫穿出阴道壁。
	float mr = prol_radius(s - tip);
	if (mr <= 1e-5) return vec4(0.0);
	float tgt = mr + 2.0 * w + 0.004;
	if (tgt <= r) return vec4(0.0);
	float near = 1.0 - smoothstep(tgt, tgt + 0.028, r);
	near = near * near * (3.0 - 2.0 * near);
	return vec4(rdir * (tgt - r) * near * ramp, 0.0);
}

// 球杆搅动：组织弹性跟随位移（杆停下后回弹到静止扩张形状）。
// stir_off = ab-local 位移；stir_p.xyz = 作用中心（球心），w = 影响半径（<=0 关闭）
uniform vec3 stir_off = vec3(0.0);
uniform vec4 stir_p = vec4(0.0);

vec3 canal_stir_offset(vec3 p) {
	float R = stir_p.w;
	if (R <= 1e-5 || dot(stir_off, stir_off) < 1e-12) return vec3(0.0);
	vec3 d = p - stir_p.xyz;
	float k = exp(-dot(d, d) / (R * R));
	return stir_off * k;
}

// 子宫被球顶直：原先前倾弯折，球在宫腔内推进时绕宫颈把宫体转向杆轴。
// uter_str = 0..1；uter_str_from = 休息宫底方向；uter_str_to = 杆轴；uter_str_len = 作用长度。
uniform float uter_str = 0.0;
uniform vec3 uter_str_pivot = vec3(0.0);
uniform vec3 uter_str_from = vec3(0.0);
uniform vec3 uter_str_to = vec3(0.0);
uniform float uter_str_len = 0.06;

vec3 uterus_straighten_offset(vec3 p) {
	float a = clamp(uter_str, 0.0, 1.0);
	if (a < 1e-4) return vec3(0.0);
	vec3 from = uter_str_from;
	vec3 to = uter_str_to;
	float fl = length(from);
	float tl = length(to);
	if (fl < 1e-5 || tl < 1e-5) return vec3(0.0);
	from /= fl;
	to /= tl;
	vec3 q = p - uter_str_pivot;
	float along = dot(q, from);
	if (along < -0.004) return vec3(0.0);
	float w = clamp(along / max(uter_str_len, 0.01), 0.0, 1.0);
	w = w * w * (3.0 - 2.0 * w);
	float cd = clamp(dot(from, to), -1.0, 1.0);
	float ang = acos(cd) * a * w;
	if (abs(ang) < 1e-5) return vec3(0.0);
	vec3 rax = cross(from, to);
	float rl = length(rax);
	if (rl < 1e-6) return vec3(0.0);
	rax /= rl;
	float c = cos(ang);
	float s = sin(ang);
	vec3 q2 = q * c + cross(rax, q) * s + rax * dot(rax, q) * (1.0 - c);
	return q2 - q;
}

// 插入物顶到宫底后，子宫沿通道轴向深处平移，阴道从外口到宫颈按比例拉长。
// fundus_lift = 平移距离（米）；默认 0，不影响手术 / 脱垂。
uniform float fundus_lift = 0.0;
uniform vec3 fundus_open_ab = vec3(0.0);
uniform vec3 fundus_cerv_ab = vec3(0.0);
uniform vec3 fundus_axis_ab = vec3(0.0, 1.0, 0.0);

vec3 fundus_lift_offset(vec3 p) {
	if (fundus_lift <= 1e-6) return vec3(0.0);
	vec3 ax = fundus_axis_ab;
	float al = length(ax);
	if (al < 1e-5) return vec3(0.0);
	ax /= al;
	vec3 openp = fundus_open_ab;
	vec3 cerv = fundus_cerv_ab;
	float L = max(dot(cerv - openp, ax), 0.02);
	float s = dot(p - openp, ax);
	float t = 0.0;
	if (s <= 0.0) t = 0.0;
	else if (s >= L) t = 1.0;
	else {
		float u = s / L;
		t = u * u * (3.0 - 2.0 * u);
	}
	// 宫颈及以远（宫体、输卵管、卵巢）：整块刚体平移，不做径向衰减。
	// 以前 38–80 mm 衰减会让靠近轴的内膜比外膜走得更远，球从宫底穿出去。
	if (s >= L - 0.008) {
		return ax * fundus_lift * t;
	}
	// 阴道段：内外壁一起拉长，径向范围要盖住整圈管壁。
	vec3 mid = openp + ax * clamp(s, 0.0, L);
	float rad = length(p - mid);
	float rw = 1.0 - smoothstep(0.055, 0.110, rad);
	if (rw <= 1e-5) return vec3(0.0);
	return ax * fundus_lift * t * rw;
}

