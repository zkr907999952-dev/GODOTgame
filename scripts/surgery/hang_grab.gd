extends RefCounted
class_name HangGrab
## 未发布（t96u / t97u）：悬垂物理器官的共享抓取接口。普通互动工具（拖拽手、打击、拳交、刺刀、肚脐……）
## 以及手术模式里没有选工具时，都可以抓住并拖动任何悬垂在体外的物理器官：
## 取出悬挂的子宫、输卵管 / 卵巢、肠袢、脱垂子宫。
##
## 器官解算节点加入 GROUP 组，并实现（鸭子类型）：
##   hang_pick(origin, dir) -> Dictionary   {"t": 沿射线距离, "point": 射线上的命中点, "anchor": 被抓质点位置, ...}；没命中返回 {}
##   hang_grab(hit, origin, dir) -> bool
##   hang_drag(anchor_target: Vector3) -> void   被抓质点的目标位置
##   hang_release() -> void
## 脱垂子宫的网格（ProlapseUterusModel）只登记进组，解算在其父节点 ProlapseController，由这里适配。

const GROUP := "hang_grab_organs"


static func _prolapse_sim(n: Node) -> Node:
	var pc := n.get_parent()
	if pc and pc.has_method("ray_pick") and pc.has_method("begin_drive") and pc.has_method("drive_to") and pc.has_method("end_drive"):
		return pc
	return null


static func node_pick(n: Node, origin: Vector3, dir: Vector3) -> Dictionary:
	if n == null or not is_instance_valid(n) or not n.is_inside_tree():
		return {}
	if n.has_method("hang_pick"):
		return n.call("hang_pick", origin, dir)
	var pc := _prolapse_sim(n)
	if pc == null or not bool(pc.call("is_active")):
		return {}
	var hit: Dictionary = pc.call("ray_pick", origin, dir)
	if hit.is_empty():
		return {}
	var nodes: PackedVector3Array = pc.call("node_positions")
	var ni := int(hit["node"])
	if ni < 0 or ni >= nodes.size():
		return {}
	var pt: Vector3 = hit["point"]
	return {"t": (pt - origin).dot(dir.normalized()), "point": pt, "anchor": nodes[ni], "node": ni, "part": "prolapse"}


## 所有登记的悬垂器官里离相机最近的命中：{"organ": Node, "hit": Dictionary}。
static func pick(tree: SceneTree, origin: Vector3, dir: Vector3) -> Dictionary:
	if tree == null:
		return {}
	var best := {}
	var best_t := INF
	for n in tree.get_nodes_in_group(GROUP):
		var hit := node_pick(n, origin, dir)
		if hit.is_empty():
			continue
		var t := float(hit.get("t", INF))
		if t > 0.0 and t < best_t:
			best_t = t
			best = {"organ": n, "hit": hit}
	return best


static func grab(n: Node, hit: Dictionary, origin: Vector3, dir: Vector3) -> bool:
	if n == null or not is_instance_valid(n):
		return false
	if n.has_method("hang_grab"):
		return bool(n.call("hang_grab", hit, origin, dir))
	var pc := _prolapse_sim(n)
	if pc == null:
		return false
	pc.call("begin_drive", "hand", int(hit["node"]), hit["anchor"], true)
	return true


static func drag(n: Node, anchor_target: Vector3) -> void:
	if n == null or not is_instance_valid(n) or not anchor_target.is_finite():
		return
	if n.has_method("hang_drag"):
		n.call("hang_drag", anchor_target)
		return
	var pc := _prolapse_sim(n)
	if pc:
		pc.call("drive_to", anchor_target)


static func release(n: Node) -> void:
	if n == null or not is_instance_valid(n):
		return
	if n.has_method("hang_release"):
		n.call("hang_release")
		return
	var pc := _prolapse_sim(n)
	if pc and str(pc.get("drive_source")) == "hand":
		pc.call("end_drive")
