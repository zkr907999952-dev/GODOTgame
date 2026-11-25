# 子宫脱垂系统

子宫沿**阴道**下移、外翻脱出（不是从腹部创口）：上段阴道内翻，在体内形成双层折叠，在体外成为包住脱出物的外翻套筒（黏膜朝外）；宫颈 / 宫口在最外端露出；外口和阴唇按脱出物截面被撑开。体外部分是柔性悬挂的物理链，会随重力和惯性甩动，可以拖拽和甩。

## 文件

| 文件 | 作用 |
|---|---|
| `scripts/body/prolapse/prolapse_controller.gd` | `ProlapseController`：中央控制器 / 状态机 / 悬挂物理 / 分度 / 触发接口 |
| `scripts/body/prolapse/prolapse_params.gd` | `ProlapseParams`（Resource）：所有可调参数，可存 `.tres` 按角色替换 |
| `scripts/body/prolapse/prolapse_trigger.gd` | `ProlapseTrigger`：触发源基类（扩展点） |
| `scripts/body/prolapse/ball_rod_trigger.gd` | 触发 #1：长杆钢球扯出 |
| `scripts/body/prolapse/prolapse_mass_inserter.gd` | `ProlapseMassInserter`：脱出物作为 VulvaInserter，从里往外撑开外口 |
| `scripts/body/prolapse/prolapse_sleeve.gd` | `ProlapseSleeve`：体外外翻阴道套筒网格 + 连续性自检 |
| `shaders/organ_common.gdshaderinc` | `prolapse_offset4()`：体内阴道内翻折叠 / 通道撑开（只对阴道网格开） |
| `scripts/surgery/soft_organ.gd` | `begin_external / step_external / end_external`：子宫网格 + GPU 蒙皮 + 输卵管卵巢，节点位置由脱垂控制器给 |
| `scripts/tests/v0420_prolapse_check.gd` | 无头自检（全部数值） |

入口：`OrganRig.prolapse()`（第一次调用时创建子节点 `Prolapse`）；`OrganRig.has_prolapse()` = 正在脱垂。

## 状态与分度

连续量：`descent` = 宫颈沿阴道下移的距离（米），`amount() = descent / descent_max()`（0..1）。`descent_max` = 子宫静止轴长度 + 外口到宫颈的长度 + `fundus_out_max`（宫底完全出来后再垂下一点）。

分度（POP-Q 思路，宫颈尖相对外口 / 处女膜的位置，`hymen_band` 默认 ±10 mm）：

| 度 | 条件 | 表现 |
|---|---|---|
| 0 | descent < `grade1_min`（4 mm） | 无 |
| I | 宫颈尖仍在外口以内 > 10 mm | 宫颈在阴道内下移，阴道顶端开始内翻 |
| II | 宫颈尖距外口 ±10 mm | 宫颈到达外口，外口开始被撑开 |
| III | 宫颈尖出外口 > 10 mm，宫底仍在里面 | 宫颈露出，部分子宫在外，套筒出现 |
| IV | 宫底也出了外口 | 子宫完全外翻脱出，悬挂甩动 |

本角色实测阈值（descent / amount）：I 4.0 mm / 0.03，II 45.1 mm / 0.34，III 65.1 mm / 0.49，IV 119.1 mm / 0.90，最大 133.1 mm。`grade_thresholds()` 返回这些值，`grade_for_descent(d)` 可直接查。

状态机：`none` → `driven`（被牵拉）/ `hanging`（松手挂着）/ `reducing`（手术复位中）→ 回到 0 时 `none`。信号：`grade_changed(grade)`、`state_changed(state)`、`triggered(source)`。

## 模型

- **路径坐标 σ**：外口 = 0，向里为正；路径 = 外口 → 宫颈尖（子宫静止位置，PCA 主轴）→ 子宫静止轴。6 个节点（宫颈 0 … 宫底 5）的静止坐标 σᵢ。
- **体内**：σᵢ − descent ≥ 0 的节点沿路径运动学放置（descent = 0 时与原子宫完全重合，实测偏差 0.06 mm）。
- **体外**：其余节点是带惯性和重力的 Verlet 链：段长约束、关节限角（`max_joint_bend`）、外口折角限制（`max_portal_bend`）、不能回到会阴平面以内、不低于 `floor_y`。第一个体外节点到外口的距离 = 已出来的材料长度（部分在里时为精确约束，全部出来后为绳）。
- **牵拉**：`begin_drive(src, node, target)` / `drive_to` / `end_drive`。目标比当前节点更靠外 → descent 增加（`feed_gain`、`feed_speed_max`）；往回推且允许复位 → descent 减少（`reduce_deadband`、`reduce_speed_max`）。被拉节点贴着目标（不超过可用长度）。
- **体外套筒**：沿体外中线生成管，半径 = 子宫截面（8 段分位数剖面）+ 壁厚，根部从外口里面 6 mm 开始，末端停在离宫颈尖 `cervix_expose`（13 mm）处，宫颈露出。管截面朝向按 ±1 个半径窗口取弦方向并限制相邻环倾角，急弯处不会自相穿插。
- **体内阴道**：着色器 `prolapse_offset4`：折叠位置 a = (通道长 + 宫颈尖坐标) / 2，以上的阴道翻进去贴在脱出物表面（法线反向，黏膜朝外），以下被撑到脱出物半径 + 2 倍壁厚。CPU 同公式 `OrganRig.prolapse_offset_ab()` 给自检用。
- **外口 / 阴唇**：`ProlapseMassInserter` 是一段沿阴道轴（里）→ 脱出方向（外）的弯胶囊，半径 = 外口处脱出物截面。外阴模块走自定义插入物路径（`project_out` / `penetration`）。截面变化 ≥ 0.25 mm 或走向变化 ≥ ~1.4° 才重解，甩动中最多每 3 帧一次。

## 触发源（扩展点）

```gdscript
class_name MyTrigger extends "res://scripts/body/prolapse/prolapse_trigger.gd"
func id() -> String: return "my_trigger"
func evaluate(ctx: Dictionary, params: Resource) -> bool: ...   # 条件满足返回 true
func drive_node() -> int: return 0                                # 被牵拉的节点（0 = 宫颈）
```

`organs.prolapse().register_trigger(MyTrigger.new())`，然后在合适的时候 `try_trigger("my_trigger", ctx)`（ctx 里可放 `target` 世界坐标）。触发后就是普通的牵拉：调用方继续 `drive_to(...)`，松手 `end_drive()`。不需要触发源时也可以直接 `begin_drive("xxx", node, target)` 或 `set_amount(a)`（预设 / 读档）。

### 触发 #1：长杆钢球

条件：球已过宫颈在宫腔里；球半径 ≥ `cervix_capacity_r × catch_ratio`（默认 10.5 mm × 1.08 = 11.3 mm，即直径 ≥ 22.7 mm）；往外扯时被宫颈挡住，且扯的速度 ≥ `trigger_pull_speed`（0.16 m/s）或被挡行程 ≥ `trigger_pull_force`（30 mm）。

- 触发后宫颈卡住球（`ball_rod.caught`），拖球 = 拖宫颈，随拉出距离逐度加重；松手后停在已达到的等级挂着，球仍卡着可以再拖。
- 拉到 IV 度后再多拉 `release_over_pull`（30 mm），或把球缩到能过宫颈的大小，球从宫颈脱出，子宫留在原等级。
- 小球、或大球轻轻拉：照旧在宫颈处攒压力后弹出，不脱垂。
- 球杆的闸门修了一处：往外扯得再快也不能一帧直接越过宫颈（先卡住，再弹出或触发）。

## 交互

- **阴道互动模式**：点中体外的脱出物 = 用手拖（相机正对的平面），可以拉出更多、甩、往回推复位。球卡在宫颈时拖拽交给球杆。
- **手术**：脱垂中用手术钳经腹部创口夹子宫，先按向外拉的距离逐渐复位脱垂（`surgery_reduce_gain`、`surgery_reduce_speed_max`），复位到 0 后同一把钳子直接转入正常的经创口扯出。脱垂中不会直接开始创口扯出。子宫已被手术扯出时不会触发脱垂。
- **复原 / 放回内脏 / 手术整身复原**：都会把脱垂完全复原（`reset()`）。
- **断面小窗**：脱垂中加入脱垂子宫和体外套筒的断面拷贝，阴道拷贝带同一组内翻参数；纵向视图自动框住阴道上端到最远的脱出物；横切面放在外口（球卡住时跟球）。
- **HUD**：阴道互动模式里显示「子宫脱垂 N 度 · 说明（百分比）」。

## 自检数值（`v0420_prolapse_check.gd`）

出生重合 0.06 mm；I 度宫颈在外口内 30.7 mm；II 度 +0.2 mm；III 度宫颈出 37.0 mm、宫底仍在内 27.0 mm；IV 度宫底出 7.1 mm、6/6 节点在外、宫底挂在外口（距外口 7.1 mm = 绳长）、距肚脐 18 cm。外口半径 17.1 / 30.2 / 20.7 mm ≥ 脱出物截面，穿模 ≤ 0.35 mm。套筒连续（最大环距 4.6 mm，无 NaN，法线与绕序全朝外），宫颈露出 13 mm。阴道壁与脱出物最小间隙 3.2 mm。甩动峰值 0.30 m/s，3 s 后 1.3%，段长最大拉伸 1.001。手术复位单调到 0 后才转入创口扯出。每帧约 1–1.5 ms（静挂），甩动中平均约 2–2.6 ms（含外阴重解）。

## 已知简化

- 体外宫角出来后输卵管 / 卵巢藏在套筒里（不画在外面）。
- 套筒截面是圆的；会阴只用一个平面挡；检查床面不参与碰撞（`floor_y` 默认关）。
- 外阴重解一次约 6 ms，所以甩动中限频（每 3 帧）——快速甩动时外口最多滞后 1 mm 左右。
- 阴道内翻在着色器里按剖面半径算，子宫网格比 85% 分位数剖面更宽的地方可能轻微贴穿。
- 只有一种触发方式（长杆钢球）；手法 / 腹压等以后按 `ProlapseTrigger` 加。
