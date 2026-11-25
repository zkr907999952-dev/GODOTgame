extends Resource
## 子宫脱垂的数据参数。可存成 .tres 按角色 / 体型替换，代码里不写死数值。
class_name ProlapseParams

@export_group("分度（POP-Q 风格，按宫颈相对处女膜/外口的有符号距离）")
## 宫颈在外口 ±hymen_band 以内 = II 度；更靠内 = I 度；更靠外且宫底仍在体内 = III 度；宫底出外口 = IV 度。
@export var hymen_band: float = 0.010
## 下移小于这个值仍算 0 度（静止抖动）。
@export var grade1_min: float = 0.004
## IV 度时宫底最多伸出外口多少（悬挂的颈部长度）。
@export var fundus_out_max: float = 0.014

@export_group("外形")
## 外翻阴道套筒的壁厚（包在脱出物外面，黏膜朝外）。
@export var wall: float = 0.0032
## 宫颈露在套筒外的长度（阴道穹窿附着在宫颈上的位置）。
@export var cervix_expose: float = 0.013
## IV 度时外口处套筒颈部的最小半径。
@export var neck_r: float = 0.010
## 截面半径按子宫网格分位数测得后再乘这个系数。
@export var radius_scale: float = 1.0
## 截面取网格径向距离的分位数（0.5 = 平均外形，0.9 = 几乎包住整个网格）。
@export var radius_quantile: float = 0.85

@export_group("柔性悬挂")
@export var iterations: int = 12
## 体外每步（60 Hz）保留的速度：甩动后摆几秒才停。
@export var air_damp: float = 0.986
@export var max_speed: float = 5.0
## 相邻两段最大夹角（弧度）。子宫是肌性器官，整体可弯但不软塌。
@export var max_joint_bend: float = 0.40
## 外口处脱出物相对通道方向最多折多少（会阴是软的）。
@export var max_portal_bend: float = 1.45

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
