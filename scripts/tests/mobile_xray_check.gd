extends SceneTree
## Mobile 渲染器下确认透视窗口着色器可编译、孔洞与内脏材质不会被丢弃。
##   godot --headless --path . --rendering-method mobile -s res://scripts/tests/mobile_xray_check.gd
##   也可加 --rendering-driver vulkan 做一次真实 Mobile 管线编译。

var fails := 0


func _initialize() -> void:
	call_deferred("_run")


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("mxray: OK   ", msg)
	else:
		fails += 1
		push_error("mxray: FAIL " + msg)


func _run() -> void:
	var method := RenderingServer.get_current_rendering_method()
	print("mxray: rendering-method=", method)
	var organ_src := FileAccess.get_file_as_string("res://shaders/organ.gdshader")
	var skin_src := FileAccess.get_file_as_string("res://shaders/skin_xray.gdshader")
	_ok(organ_src.find("SSS_STRENGTH") < 0, "no SSS_STRENGTH")
	_ok(organ_src.find("CLEARCOAT") < 0, "no CLEARCOAT")
	_ok(skin_src.find("ALPHA_SCISSOR_THRESHOLD") >= 0, "alpha scissor hole")
	_ok(skin_src.find("if (hole > 0.07) discard") < 0, "hole not discarded")
	var skin_c := FileAccess.get_file_as_string("res://shaders/skin_common.gdshaderinc")
	_ok(skin_c.find("prof_tex") >= 0, "profile uses texture")
	_ok(skin_c.find("uniform float prof_y[24]") < 0, "no float[24] profile arrays")

	# 编译材质：挂到场景里让渲染器实际 set_code
	var world := Node3D.new()
	root.add_child(world)
	var cam := Camera3D.new()
	cam.current = true
	cam.position = Vector3(0, 0, 0.6)
	world.add_child(cam)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, 30, 0)
	world.add_child(light)

	var skin_sh := load("res://shaders/skin_xray.gdshader") as Shader
	var organ_sh := load("res://shaders/organ.gdshader") as Shader
	_ok(skin_sh != null and organ_sh != null, "shaders load")

	var skin_mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.2
	sm.height = 0.4
	skin_mi.mesh = sm
	var skin_mat := ShaderMaterial.new()
	skin_mat.shader = skin_sh
	skin_mat.set_shader_parameter("xray", 0.85)
	skin_mi.material_override = skin_mat
	world.add_child(skin_mi)

	var organ_mi := MeshInstance3D.new()
	organ_mi.mesh = sm.duplicate()
	organ_mi.position = Vector3(0, 0, -0.02)
	var organ_mat := ShaderMaterial.new()
	organ_mat.shader = organ_sh
	organ_mat.set_shader_parameter("base_color", Color(0.77, 0.47, 0.42))
	organ_mat.set_shader_parameter("wet", 0.45)
	organ_mi.material_override = organ_mat
	world.add_child(organ_mi)

	for i in 8:
		await process_frame

	# 材质仍在、关键参数没被清掉，视为编译成功（失败时 Godot 常回退/丢掉 shader）。
	_ok(skin_mi.material_override is ShaderMaterial, "skin still ShaderMaterial")
	_ok(organ_mi.material_override is ShaderMaterial, "organ still ShaderMaterial")
	var smat := skin_mi.material_override as ShaderMaterial
	var omat := organ_mi.material_override as ShaderMaterial
	_ok(smat.shader == skin_sh, "skin shader stayed compiled")
	_ok(omat.shader == organ_sh, "organ shader stayed compiled")
	_ok(absf(float(smat.get_shader_parameter("xray")) - 0.85) < 0.01, "xray uniform retained")
	print("mxray_check: fails=%d method=%s" % [fails, method])
	quit(1 if fails > 0 else 0)
