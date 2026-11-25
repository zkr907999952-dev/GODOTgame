extends Resource
## 外阴柔体 / 开合的数据参数。换角色或以后加玩具时只改资源，不必改脚本。
class_name VulvaParams

@export_group("开合骨骼")
## 左右大阴唇铰链最大转角（弧度）。拨开动作用。
@export var max_spread_angle: float = deg_to_rad(55.0)
## 环向变形骨骼数量（外口一圈），用于粗开合。以后可加 hood / minora 专用骨。
@export var ring_bone_count: int = 8
## 命名骨骼（扩展点）：以后可把蒙皮绑到这些名字上。
@export var bone_names: PackedStringArray = PackedStringArray([
	"hood", "majora_l", "majora_r", "minora_l", "minora_r",
	"introitus_ant", "introitus_post", "introitus_l", "introitus_r",
])

@export_group("软体")
@export var pbd_iters: int = 3
@export var stiffness: float = 0.82
@export var max_edge_stretch: float = 1.85
@export var along_range: float = 0.028
## 插入变形衰减：1 = 只在裂隙，0 = 身体接缝锁定。
@export var insert_falloff: float = 1.0
## 周围皮肤跟随外口撑开的衰减半径（米）。接缝可以移动，远处躯干不动。
@export var skin_falloff: float = 0.038

@export_group("拓扑")
@export var subdiv: int = 1
@export var vest_rings: int = 72
@export var vest_rows: int = 10

@export_group("静息 / 外观")
@export var mucosa_color: Color = Color(0.81, 0.60, 0.57, 1.0)
@export var region_half_x: float = 0.017
@export var region_dy: float = 0.010
