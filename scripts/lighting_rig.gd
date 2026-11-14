extends Node3D
## 光照 / 环境（房间 + 城市），参考网页 scene.tsx StudioLights / CityLights / Canvas(ACES, 曝光 1.05)。
##
## 房间：网页是「环境光 + 半球光 + 主光 + 冷色侧补 + 两盏暖色点光（吸顶灯 / 台灯）」，不投影。
## Godot 版保留同样的色温与主次关系，并加上阴影：
## - 主光（方向光，暖白）从角色正前上方打来（Godot 版角色出生时面向 -Z、观察相机在房间内正面，
##   所以把网页相对「相机侧」的主光方向绕角色转 180°），PSSM 2 段、短阴影距离（房间 12m）→ 阴影清晰，
##   bias / normal bias 调小防止「漂浮」（peter-panning），柔化 + 不完全不透明，阴影不死黑。
## - 墙 / 天花板 / 地板 不投射阴影：之前方向光从房顶外面照进来，整个房间被天花板挡在阴影里，
##   主光实际上没照到角色，只剩跟随相机的点光 → 画面发平、皮肤发灰、地面没有接触阴影。
## - 冷色侧补光（不投影）+ 背后轮廓光（不投影），吸顶灯 / 台灯照亮房间。
## - 环境光（暖灰）+ ACES 色调映射（曝光 1.05，同网页）。
## 城市：太阳（暖白，PSSM 4 段 80m）+ 天空环境光（ProceduralSky：天蓝 / 草绿地面反射）+ 冷色天光补光，
## 背景 #7eafd0 + 深度雾 220–3400m（网页 WorldClip）。

const ROOM_BG := Color("#1a1614")
const CITY_BG := Color("#7eafd0")
## 只照角色（player 把所有身体网格加到这一层），用于第一人称补光，不会在墙上打出光斑。
const CHAR_LIGHT_LAYER := 1 << 17

var current: String = ""
var room_env: Environment
var city_env: Environment
var _we: WorldEnvironment
var _room: Node3D
var _city: Node3D


func _ready() -> void:
	room_env = _make_room_env()
	city_env = _make_city_env()
	_we = WorldEnvironment.new()
	_we.name = "WorldEnvironment"
	add_child(_we)
	_room = _build_room_lights()
	_city = _build_city_lights()
	set_map("room")


func set_map(id: String) -> void:
	current = "room" if id == "room" else "city"
	var in_room := current == "room"
	_room.visible = in_room
	_city.visible = not in_room
	_we.environment = room_env if in_room else city_env


func _base_env() -> Environment:
	var env := Environment.new()
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.05
	env.tonemap_white = 6.0
	# 不开 SSAO：透视窗口的半透明覆盖层走透明管线、不吃 SSAO，开了会在窗口边缘看到一圈明暗不同的方框。
	env.ssao_enabled = false
	env.glow_enabled = false
	return env


func _make_room_env() -> Environment:
	var env := _base_env()
	env.background_mode = Environment.BG_COLOR
	env.background_color = ROOM_BG
	# 网页 ambient #e6d8c8 0.34 + hemisphere #f2ebe3/#3a322c 0.48 → 暖灰环境光
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#cdbfb2")
	env.ambient_light_energy = 0.2
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	return env


func _make_city_env() -> Environment:
	var env := _base_env()
	env.background_mode = Environment.BG_COLOR
	env.background_color = CITY_BG
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color("#8fb3cf")
	sky_mat.sky_horizon_color = Color("#e3e4df")
	sky_mat.ground_horizon_color = Color("#b9b2a4")
	sky_mat.ground_bottom_color = Color("#6b6a58")
	sky_mat.sun_angle_max = 30.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.28
	env.ambient_light_sky_contribution = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = CITY_BG
	env.fog_depth_begin = 220.0
	env.fog_depth_end = 3400.0
	env.fog_depth_curve = 1.0
	env.fog_sky_affect = 0.0
	return env


func _dir_light(nm: String, from: Vector3, to: Vector3, color: Color, energy: float) -> DirectionalLight3D:
	var l := DirectionalLight3D.new()
	l.name = nm
	l.light_color = color
	l.light_energy = energy
	l.shadow_enabled = false
	l.position = from
	l.look_at_from_position(from, to, Vector3.UP if absf((to - from).normalized().y) < 0.99 else Vector3.FORWARD)
	return l


func _omni(nm: String, pos: Vector3, color: Color, energy: float, rng: float) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.name = nm
	l.position = pos
	l.light_color = color
	l.light_energy = energy
	l.omni_range = rng
	l.omni_attenuation = 1.4
	l.light_specular = 0.15  # 墙面是光滑材质，高光太强会出现亮斑
	l.shadow_enabled = false
	return l


func _build_room_lights() -> Node3D:
	var g := Node3D.new()
	g.name = "RoomLights"
	add_child(g)
	var c := Vector3(-0.2, 1.0, 0.3)  # 出生点（胸腹高度）
	# 主光：前上方偏左（相对角色），暖白，投影
	var key := _dir_light("Key", c + Vector3(-1.9, 3.1, -2.2), c, Color("#fff1e0"), 0.72)
	key.shadow_enabled = true
	key.shadow_bias = 0.02
	key.shadow_normal_bias = 0.6
	key.shadow_blur = 1.6
	key.shadow_opacity = 0.82
	key.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	key.directional_shadow_split_1 = 0.25
	key.directional_shadow_max_distance = 12.0
	key.directional_shadow_blend_splits = true
	key.directional_shadow_pancake_size = 4.0
	g.add_child(key)
	# 冷色侧补光（网页 #c8d0dc 0.32），不投影
	g.add_child(_dir_light("Fill", c + Vector3(2.4, 1.6, -0.4), c, Color("#c8d0dc"), 0.26))
	# 背后轮廓光：勾出肩 / 腰 / 发丝轮廓，不投影、不出高光斑
	var rim := _dir_light("Rim", c + Vector3(0.6, 2.2, 2.6), c, Color("#ffe6d0"), 0.35)
	rim.light_specular = 0.6
	g.add_child(rim)
	# 网页吸顶灯 (0,2.55,-1.35) #ffd7b0 / 台灯 (1.4,1.7,-2.1) #ffc98a（房间原位）
	g.add_child(_omni("CeilingLamp", Vector3(0.0, 2.45, -1.35), Color("#ffd7b0"), 0.8, 7.0))
	g.add_child(_omni("Lamp", Vector3(1.4, 1.7, -2.1), Color("#ffc98a"), 0.5, 4.2))
	return g


func _build_city_lights() -> Node3D:
	var g := Node3D.new()
	g.name = "CityLights"
	add_child(g)
	# 网页 CityLights：太阳 (80,140,40) #fff4d6 1.35 + 天光 (-50,40,-30) #8eb4d8 0.28
	var sun := _dir_light("Sun", Vector3(80, 140, 40), Vector3.ZERO, Color("#fff4d6"), 0.95)
	sun.shadow_enabled = true
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 1.0
	sun.shadow_blur = 1.3
	sun.shadow_opacity = 0.78
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_split_1 = 0.06
	sun.directional_shadow_split_2 = 0.18
	sun.directional_shadow_split_3 = 0.45
	sun.directional_shadow_max_distance = 90.0
	sun.directional_shadow_blend_splits = true
	g.add_child(sun)
	g.add_child(_dir_light("SkyFill", Vector3(-50, 40, -30), Vector3.ZERO, Color("#8eb4d8"), 0.3))
	return g


## 房间结构（墙 / 天花板 / 地板，ModernBedroom_Structure）不投影（见文件头）；家具照常投影。
static func tune_room_shadows(room: Node) -> void:
	for n in room.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi != null and "structure" in String(mi.name).to_lower():
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
