extends Resource
## 子宫脱垂的数据参数。可存成 .tres 按角色 / 体型替换，代码里不写死数值。
class_name ProlapseParams

@export_group("分度（POP-Q 风格，按宫颈相对处女膜/外口的有符号距离）")
## 宫颈在外口 ±hymen_band 以内 = II 度；更靠内 = I 度；更靠外且宫底仍在体内 = III 度；宫底出外口 = IV 度。
@export var hymen_band: float = 0.010
## 下移小于这个值仍算 0 度（静止抖动）。
@export var grade1_min: float = 0.004
## IV 度时宫底最多伸出外口多少（悬挂的颈部长度）。t68u：0.014 → 0.05，最重时挂得更低。
@export var fundus_out_max: float = 0.05

@export_group("外形")
## 阴道壁厚（通道被撑开时贴在脱出物外的厚度）。
@export var wall: float = 0.0032
## 专用模型里宫颈段的长度（宫颈黏膜材质；之后是宫体材质）。
@export var cervix_expose: float = 0.013
## IV 度时宫底到外口之间的阴道壁蒂（被拉长的阴道壁）半径：t73u 加粗到 16 mm，用阴道黏膜（肉粉色）材质。
@export var neck_r: float = 0.016
## 脱垂期间简化子宫链的节点数（宫颈 → 宫底）。
@export var nodes: int = 5

@export_group("脱垂黏膜配色（统一、红润、湿润）")
## 参考：阴道鳞状上皮呈湿润粉红（Obgyn Key；Manitoba Pap module）；
## 外宫颈光滑粉红，宫口周围可略红；脱出块为湿润粉红至粉红偏红的黏膜
##（Merck Professional / 临床脱垂外观），不是苍白萎缩粉，也不是深暗红。
## 有贴图时这些颜色乘在阴道黏膜贴图上，保留原有细节，只统一染色。
@export var mucosa_tex_tint: Color = Color(1.04, 0.78, 0.74, 1.0)
@export var mucosa_solid: Color = Color(0.80, 0.48, 0.46, 1.0)
## 宫颈 / 宫口周围略深、更红润，与宫体同色系，避免硬边。
@export var cervix_tex_tint: Color = Color(0.98, 0.68, 0.65, 1.0)
@export var cervix_solid: Color = Color(0.74, 0.40, 0.40, 1.0)
@export var mucosa_wet: float = 0.62
@export var mucosa_roughness: float = 0.30

@export_group("大腿碰撞")
## 胶囊半径。轴再向外偏 thigh_lateral_offset，外侧仍接近 75 mm 命中箱，
## 内侧更瘦，站姿两腿之间留出脱垂悬垂的通道，避免把子宫托在腿根上。
@export var thigh_r: float = 0.058
## 胶囊轴相对股骨向外（离开正中面）偏移，加厚外侧、打开内侧间隙。
@export var thigh_lateral_offset: float = 0.015
## 髋关节端内缩，避免胶囊吃到会阴 / 外口；髋端按开口圆柱处理，没有能托住子宫的球面帽。
@export var thigh_hip_inset: float = 0.055
## 脱出物表面相对胶囊再留的空隙。
@export var thigh_margin: float = 0.003
## 截面半径按子宫网格分位数测得后再乘这个系数。
@export var radius_scale: float = 1.0
## 截面取网格径向距离的分位数（0.5 = 平均外形，0.9 = 几乎包住整个网格）。
@export var radius_quantile: float = 0.85

@export_group("柔性悬挂")
@export var iterations: int = 6
## 体外每步（60 Hz）保留的速度：甩动后摆几秒才停。
@export var air_damp: float = 0.986
@export var max_speed: float = 5.0
## 相邻两段最大夹角（弧度）。子宫是肌性器官，整体可弯但不软塌。
@export var max_joint_bend: float = 0.40
## 外口处脱出物相对通道方向最多折多少（会阴是软的）。
@export var max_portal_bend: float = 1.45

@export_group("外口重解（性能）")
## 外口截面变化至少这么多（米）才重解外阴。
@export var introitus_r_step: float = 0.0005
## 脱出方向变化：点积低于这个值（约 10°，低通后）才重解。
@export var introitus_dir_dot: float = 0.985
## 甩动中两次外阴重解之间至少隔几个物理帧。
@export var introitus_cooldown: int = 10
## 外口走向低通时间常数（秒）：甩动时外阴只跟平均走向重解。
@export var introitus_dir_tau: float = 0.5

@export_group("拖拽 / 复位")
## 拉力（目标超出可用长度的米数）换算成下移速度的增益（1/s）。
@export var feed_gain: float = 14.0
@export var feed_speed_max: float = 0.30
## 往回推（目标比可用长度短）时手法复位。
@export var hand_reduce: bool = true
@export var reduce_deadband: float = 0.012
@export var reduce_speed_max: float = 0.18
## 手术时经腹部创口向外拉子宫：钳尖每向外 1 m 复位多少米。
@export var surgery_reduce_gain: float = 1.0
@export var surgery_reduce_speed_max: float = 0.25

@export_group("触发 #1：长杆钢球扯出")
## 宫颈不卡球时能通过的最大球半径。
@export var cervix_capacity_r: float = 0.0105
## 球半径 ≥ capacity × ratio 才可能被宫颈卡住。
@export var catch_ratio: float = 1.08
## 指针向外拉的速度阈值（m/s）或被挡住的拉出量阈值（m），满足其一即算「强行扯出」。
@export var trigger_pull_speed: float = 0.16
@export var trigger_pull_force: float = 0.030
## IV 度后继续扯，球终于从宫颈脱出。
@export var release_over_pull: float = 0.03
