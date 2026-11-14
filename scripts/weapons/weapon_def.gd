extends Resource
class_name WeaponDef
## 一把武器的全部数据（数据驱动：新增武器 = 新建 assets/weapons/<id>/<id>.tres + 模型 / 图标 / 手部动作）。

@export var id: String = ""
@export var display_name: String = ""
## pistol / rifle / smg / shotgun / sniper / melee —— 轮盘 / 菜单按类别分组
@export var category: String = "rifle"
@export var order: int = 0
@export var scene: PackedScene
@export var icon: Texture2D
## 手部动作（Kuptchi 手臂动画烘焙成相机空间数据，见 tools/bake_weapon_arms.gd）
@export var arms: Resource
## semi = 半自动（每次按下一发）· auto = 全自动 · pump = 泵动（每发后拉护木）· melee = 近战挥砍
@export_enum("semi", "auto", "pump", "melee") var fire_mode: String = "semi"
@export var rpm: float = 600.0
@export var mag_size: int = 30
@export var reserve_start: int = 90
@export var reserve_max: int = 210
## 空仓外的战术换弹保留膛内一发（+1）
@export var chamber_plus_one: bool = true
## 每次射击的弹丸数（霰弹 8）
@export var pellets: int = 1
@export var damage: float = 30.0
@export var range_m: float = 300.0
## 腰射散布（度）/ 连射散布增长（度/发）/ 最大散布 / 恢复（度/秒）
@export var spread_deg: float = 1.2
@export var bloom_deg: float = 0.35
@export var spread_max_deg: float = 4.0
@export var spread_recover: float = 8.0
## 后坐力：相机上跳（度）、左右随机（度）、恢复速度（1/秒）、枪身后坐（米）/ 上翻（度）
@export var recoil_pitch: float = 1.6
@export var recoil_yaw: float = 0.5
@export var recoil_recover: float = 9.0
@export var kick_back: float = 0.035
@export var kick_rot: float = 4.0
## 动作时长（秒）；0 = 用动画长度
@export var draw_time: float = 0.0
@export var holster_time: float = 0.0
@export var reload_time: float = 0.0
@export var reload_empty_time: float = 0.0
## 霰弹逐发装填：开始 / 每发 / 结束
@export var shell_reload: bool = false
## 枪口（枪模型根节点坐标）、抛壳口、弹壳网格名（shells.scn 子节点）
@export var muzzle: Vector3 = Vector3(0.6, 0.165, 0.0)
@export var eject: Vector3 = Vector3(0.15, 0.17, 0.02)
@export var shell: String = "5_56mm_Shell"
@export var flash_scale: float = 1.0
## 第一人称视模型整体偏移（相机空间，米）——角色手臂够得着护木
@export var view_offset: Vector3 = Vector3.ZERO
## 视模型围绕相机缩放（屏幕上大小不变，但离肩更近，方便自己的手臂够到）
@export var view_scale: float = 0.8
## 开镜视野
@export var ads_fov: float = 50.0
## 声音（素材包没有音频：留接口，填 AudioStream 即可）
@export var sfx_fire: AudioStream
@export var sfx_reload: AudioStream
@export var sfx_dry: AudioStream
