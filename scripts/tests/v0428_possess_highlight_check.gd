extends SceneTree
## 未发布（t103u）：分身描边只在附身切换菜单（互动面板的分身清单）打开时出现，
## 高亮悬停 / 选中的候选；关闭菜单、附身之后都清掉，离开的身体不留高亮。
##   godot --headless --path . -s res://scripts/tests/v0428_possess_highlight_check.gd

var main: Node
var player: Node
var pz: Node
var hud: Node
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("v0428: OK   ", msg)
	else:
		fails += 1
		push_error("v0428: FAIL " + msg)


## 场景里所有角色网格上的描边材质数（不只看 Possession 自己的记录）。
func _outlined_anywhere() -> int:
	var mat: Material = pz.get("_outline_mat")
	var n := 0
	for host in [player] + (main.call("get_clones") as Array):
		for mi in (host as Node).find_children("*", "MeshInstance3D", true, false):
			if (mi as MeshInstance3D).material_overlay == mat:
				n += 1
	return n


func _outlined_on(host: Node) -> int:
	var mat: Material = pz.get("_outline_mat")
	var n := 0
	for mi in host.find_children("*", "MeshInstance3D", true, false):
		if (mi as MeshInstance3D).material_overlay == mat:
			n += 1
	return n


func _menu(on: bool) -> void:
	var btn: Button = hud.get("_btn_interact")
	if bool(hud.call("is_panel_open")) != on:
		btn.emit_signal("pressed")
	await _frames(2)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _frames(24)
	player = main.get_node("Player")
	pz = main.get("possession")
	hud = main.get_node("HUD")
	main.call("clear_clones")
	await _frames(2)
	var p0: Vector3 = player.global_position
	main.call("spawn_clone", p0 + Vector3(1.4, 0, -0.6))
	main.call("spawn_clone", p0 + Vector3(-1.4, 0, -0.6))
	await _frames(4)
	var cl: Array = main.call("get_clones")
	var a: Node = cl[0]
	var b: Node = cl[1]
	# 菜单关着时选中不描边
	pz.call("select", a)
	await _frames(2)
	_ok(_outlined_anywhere() == 0, "selecting with the menu closed draws no outline (%d)" % _outlined_anywhere())
	# 打开菜单 → 选中项描边
	await _menu(true)
	_ok(bool(pz.get("menu_open")), "opening the interact panel marks the possession menu open")
	_ok(_outlined_on(a) > 0 and _outlined_anywhere() == _outlined_on(a), "menu open: the selected clone is outlined (%d meshes)" % _outlined_on(a))
	# 悬停另一个 → 只高亮悬停的；移开回到选中项
	hud.call("_on_clone_row_hover", b, true)
	await _frames(1)
	_ok(_outlined_on(b) > 0 and _outlined_on(a) == 0, "hovering another row outlines only that candidate")
	hud.call("_on_clone_row_hover", b, false)
	await _frames(1)
	_ok(_outlined_on(a) > 0 and _outlined_on(b) == 0, "leaving the row returns the outline to the selection")
	# 关闭菜单 → 清掉
	await _menu(false)
	_ok(not bool(pz.get("menu_open")) and _outlined_anywhere() == 0, "closing the menu clears every outline (%d)" % _outlined_anywhere())
	# 菜单里点选 + 附身：附身后谁都不高亮（包括刚离开的身体）
	await _menu(true)
	pz.call("select", null)
	hud.call("_on_clone_row_pressed", a)
	await _frames(1)
	_ok(pz.get("selected") == a and _outlined_on(a) > 0, "clicking a row selects and outlines it")
	var a_body: Node = a.get("body")
	hud.call("_on_possess_selected")
	await _frames(3)
	_ok(player.get("_body") == a_body, "possessed the selected clone from the menu")
	_ok(pz.get("selected") == null and _outlined_anywhere() == 0, "after possessing, nothing is outlined, not even the body you left (%d)" % _outlined_anywhere())
	var me_body: Node = player.get("_body")
	var me_cnt := 0
	for mi in me_body.find_children("*", "MeshInstance3D", true, false):
		if (mi as MeshInstance3D).material_overlay == pz.get("_outline_mat"):
			me_cnt += 1
	_ok(me_cnt == 0, "the newly controlled body has no leftover outline")
	await _menu(false)
	# 菜单关着时用准星 / P 附身：也不留高亮
	var t0 := Time.get_ticks_msec()
	while bool(pz.call("is_transitioning")) and Time.get_ticks_msec() - t0 < 3000:
		await process_frame
	pz.call("possess", b)
	await _frames(3)
	_ok(_outlined_anywhere() == 0 and pz.get("selected") == null, "possessing with the menu closed leaves no highlight")
	await _menu(true)
	_ok(_outlined_anywhere() == 0, "reopening the menu after a swap shows nothing until you pick a clone")
	await _menu(false)
	print("v0428: fails=", fails)
	quit(1 if fails > 0 else 0)
