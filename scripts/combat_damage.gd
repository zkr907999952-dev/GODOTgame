extends RefCounted
class_name CombatDamage
## 主流 FPS（CoD / Battlefield 风格）在 100 血上的伤害结算：
## 部位倍率 + 距离衰减。武器基础伤害见各 WeaponDef.damage。

## 部位倍率：头部约 1.7×（两发步枪 / 手枪爆头可杀），四肢略低于躯干。
const ZONE_MULT := {
	"head": 1.7,
	"neck": 1.2,
	"body": 1.0,
	"limb": 0.85,
}

## 距离衰减：start 米内全额，end 米处降到 min 倍率，再远处保持 min。
const FALLOFF := {
	"rifle": {"start": 40.0, "end": 200.0, "min": 0.65},
	"smg": {"start": 18.0, "end": 50.0, "min": 0.50},
	"pistol": {"start": 15.0, "end": 40.0, "min": 0.45},
	"shotgun": {"start": 8.0, "end": 22.0, "min": 0.15},
}

## 最终采用的基础伤害（与 assets/weapons/<id>/<id>.tres 保持一致）
const BASE_DAMAGE := {
	"rifle": 30.0,
	"smg": 22.0,
	"pistol": 34.0,
	"shotgun": 15.0,
}

const PELLETS := {
	"rifle": 1,
	"smg": 1,
	"pistol": 1,
	"shotgun": 8,
}


static func category_of(weapon_id: String, w: Resource = null) -> String:
	if w and "category" in w and str(w.category) != "":
		return str(w.category)
	if BASE_DAMAGE.has(weapon_id):
		return weapon_id
	return "rifle"


static func base_damage(weapon_id: String, w: Resource = null) -> float:
	if w and "damage" in w and float(w.damage) > 0.0:
		return float(w.damage)
	return float(BASE_DAMAGE.get(category_of(weapon_id, w), 30.0))


static func pellets(weapon_id: String, w: Resource = null) -> int:
	if w and "pellets" in w and int(w.pellets) > 0:
		return int(w.pellets)
	return int(PELLETS.get(category_of(weapon_id, w), 1))


static func zone_mult(zone: String) -> float:
	return float(ZONE_MULT.get(zone, 1.0))


static func falloff_mult(category: String, distance_m: float) -> float:
	var f: Dictionary = FALLOFF.get(category, FALLOFF["rifle"])
	var start := float(f["start"])
	var end := float(f["end"])
	var mn := float(f["min"])
	if distance_m <= start:
		return 1.0
	if distance_m >= end:
		return mn
	var t := (distance_m - start) / maxf(end - start, 0.001)
	return lerpf(1.0, mn, clampf(t, 0.0, 1.0))


static func compute(weapon_id: String, distance_m: float, zone: String, w: Resource = null) -> float:
	var cat := category_of(weapon_id, w)
	return base_damage(weapon_id, w) * zone_mult(zone) * falloff_mult(cat, distance_m)


static func ttk_body_shots(weapon_id: String, hp: float = 100.0, w: Resource = null) -> int:
	var d := base_damage(weapon_id, w) * zone_mult("body")
	if d <= 0.0:
		return 0
	return int(ceil(hp / d))


static func zone_from_bone(bone_name: String) -> String:
	var n := bone_name
	if n.contains("Head") or n.begins_with("C_Face") or n.contains("Hair"):
		return "head"
	if n.contains("Neck") or n.contains("Throat"):
		return "neck"
	if n.contains("Arm") or n.contains("Hand") or n.contains("Shoulder") \
			or n.contains("Leg") or n.contains("Foot") or n.contains("Toe") \
			or n.contains("Thumb") or n.contains("Index") or n.contains("Middle") \
			or n.contains("Ring") or n.contains("Pinky"):
		return "limb"
	return "body"


## 未命中物理骨骼时，按相对角色原点的高度 / 径向粗分部位（站立胶囊约 1.64m）。
static func zone_from_point(body: Node, hit: Vector3) -> String:
	var origin := Vector3.ZERO
	if body is Node3D:
		origin = (body as Node3D).global_position
	var local := hit - origin
	if body is Node3D:
		local = (body as Node3D).global_transform.basis.inverse() * (hit - origin)
	var y := local.y
	var radial := Vector2(local.x, local.z).length()
	if y >= 1.46:
		return "head"
	if y >= 1.30:
		return "neck"
	if y < 0.72:
		return "limb"
	if radial > 0.22 and y > 0.85 and y < 1.40:
		return "limb"
	return "body"


static func zone_of(body: Node, hit: Vector3, collider: Object = null) -> String:
	if collider is PhysicalBone3D:
		var bn := str((collider as PhysicalBone3D).bone_name)
		if bn != "":
			return zone_from_bone(bn)
	if body and body.has_method("get_skeleton"):
		var skel: Skeleton3D = body.call("get_skeleton")
		if skel:
			var nearest := ""
			var best := 0.12
			for n in ["C_Head_a", "C_Neck_a", "C_Spine_d", "C_Spine_c", "C_Spine_a", "C_Hip_a",
					"L_UpperArm_a", "R_UpperArm_a", "L_Forearm_a", "R_Forearm_a", "L_Hand_a", "R_Hand_a",
					"L_UpperLeg_a", "R_UpperLeg_a", "L_Foreleg_a", "R_Foreleg_a", "L_Foot_a", "R_Foot_a"]:
				var i := skel.find_bone(n)
				if i < 0:
					continue
				var p := (skel.global_transform * skel.get_bone_global_pose(i)).origin
				var d := p.distance_to(hit)
				if d < best:
					best = d
					nearest = n
			if nearest != "":
				return zone_from_bone(nearest)
	return zone_from_point(body, hit)
