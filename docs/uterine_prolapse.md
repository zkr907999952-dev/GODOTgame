# 子宫脱垂系统

子宫沿**阴道**下移、脱出（不是从腹部创口）：脱垂期间原子宫 / 宫颈 / 输卵管卵巢隐藏，换成一个**专用的简化子宫 + 宫颈模型**（复用原材质）；宫颈 / 宫口在最外端；阴道只被脱出物沿径向撑开（t68u 起不再内翻折叠，体外也没有外翻套筒）；外口和阴唇按脱出物截面被撑开。体外部分是柔性悬挂的物理链，会随重力和惯性甩动，手、手术钳、手术拿取工具都可以拖。

> t68u 性能重做：原来的「SoftOrgan（3839 顶点 + GPU 蒙皮 + 输卵管卵巢）+ 体外套筒网格 + 阴道着色器双层折叠」太卡，改为下面的简化结构，甩动中控制器每帧开销约 5.3–6.3 ms → 0.55–1.25 ms（见文末）。

## 文件

| 文件 | 作用 |
|---|---|
| `scripts/body/prolapse/prolapse_controller.gd` | `ProlapseController`：中央控制器 / 状态机 / 悬挂物理 / 分度 / 触发接口 |
| `scripts/body/prolapse/prolapse_params.gd` | `ProlapseParams`（Resource）：所有可调参数，可存 `.tres` 按角色替换 |
| `scripts/body/prolapse/prolapse_trigger.gd` | `ProlapseTrigger`：触发源基类（扩展点） |
| `scripts/body/prolapse/ball_rod_trigger.gd` | 触发 #1：长杆钢球扯出 |
| `scripts/body/prolapse/prolapse_mass_inserter.gd` | `ProlapseMassInserter`：脱出物作为 VulvaInserter，从里往外撑开外口 |
| `scripts/body/prolapse/prolapse_uterus_model.gd` | `ProlapseUterusModel`（t68u）：脱垂专用的简化子宫 + 宫颈网格（约 310–370 顶点，两个面） |
| `shaders/organ_common.gdshaderinc` | `prolapse_offset4()`：阴道通道被脱出物撑开（只对阴道网格开；t68u 去掉了内翻折叠） |
| `scripts/tests/v0420_prolapse_check.gd` | 无头自检（全部数值，含每帧开销） |

（t68u 删除了 `prolapse_sleeve.gd`；`soft_organ.gd` 的 `begin_external / step_external / end_external` 不再被脱垂使用。`soft_organ()` 现在返回专用模型、`sleeve()` 返回 null，供断面小窗兼容。）

入口：`OrganRig.prolapse()`（第一次调用时创建子节点 `Prolapse`）；`OrganRig.has_prolapse()` = 正在脱垂。

## 状态与分度

连续量：`descent` = 宫颈沿阴道下移的距离（米），`amount() = descent / descent_max()`（0..1）。`descent_max` = 子宫静止轴长度 + 外口到宫颈的长度 + `fundus_out_max`（宫底完全出来后再垂下的长度，t68u 由 14 mm 加到 50 mm，最大时子宫垂得更低）。

分度（POP-Q 思路，宫颈尖相对外口 / 处女膜的位置，`hymen_band` 默认 ±10 mm）：

| 度 | 条件 | 表现 |
|---|---|---|
| 0 | descent < `grade1_min`（4 mm） | 无 |
| I | 宫颈尖仍在外口以内 > 10 mm | 宫颈在阴道内下移，阴道上段被撑开 |
| II | 宫颈尖距外口 ±10 mm | 宫颈到达外口，外口开始被撑开 |
| III | 宫颈尖出外口 > 10 mm，宫底仍在里面 | 宫颈露出，部分子宫在外 |
| IV | 宫底也出了外口 | 子宫完全脱出，悬挂甩动，宫底到外口之间是一段细颈 |

本角色实测阈值（descent / amount）：I 4.0 mm / 0.024，II 45.1 mm / 0.267，III 65.1 mm / 0.385，IV 119.1 mm / 0.704，最大 169.1 mm（t68u 前 133.1 mm）。`grade_thresholds()` 返回这些值，`grade_for_descent(d)` 可直接查。

状态机：`none` → `driven`（被牵拉）/ `hanging`（松手挂着）/ `reducing`（手术复位中）→ 回到 0 时 `none`。信号：`grade_changed(grade)`、`state_changed(state)`、`triggered(source)`。

## 模型

- **路径坐标 σ**：外口 = 0，向里为正；路径 = 外口 → 宫颈尖（子宫静止位置，PCA 主轴）→ 子宫静止轴。`params.nodes`（默认 5）个节点（宫颈 0 … 宫底 4）的静止坐标 σᵢ，节点直接放在腹部坐标里（不再借用 SoftOrgan）。
- **体内**：σᵢ − descent ≥ 0 的节点沿路径运动学放置（descent ≈ 0 时模型宫颈尖与原宫颈重合，实测 0.00 mm）。
- **体外**：其余节点是带惯性和重力的 Verlet 链（`iterations` 默认 6）：段长约束、关节限角（`max_joint_bend`）、外口折角限制（`max_portal_bend`）、不能回到会阴平面以内、不低于 `floor_y`。第一个体外节点到外口的距离 = 已出来的材料长度。
- **牵拉**：`begin_drive(src, node, target, allow_reduce, allow_feed)` / `drive_to` / `end_drive`。目标比当前节点更靠外 → descent 增加（`feed_gain`、`feed_speed_max`）；往回推且允许复位 → descent 减少（`reduce_deadband`、`reduce_speed_max`）。被拉节点贴着目标（不超过可用长度）。`allow_feed = false, allow_reduce = false` = 只拖动 / 甩动（手术拿取工具）。
- **专用子宫模型（`ProlapseUterusModel`，t68u）**：沿节点的 Catmull-Rom 中线生成 12 边低面数管：宫颈尖是带宫口小凹的半球顶，宫颈段 3 环，宫体 14 环（截面 = 原子宫网格测得的 8 段分位数剖面 `mass_radius_at`，与外口撑开、阴道着色器同一公式），宫底收口；IV 度宫底出外口后宫底到外口里 8 mm 接一段 `neck_r` 粗的细颈（阴道穹窿的蒂）。面 0 = 宫颈 + 细颈，用原阴道（黏膜）材质的副本；面 1 = 宫体，用原子宫材质的副本（关掉 is_uterus / 柔体 / 脱垂形变开关，颜色和贴图不变）。网格建在腹部局部坐标里、节点变换 = 腹部坐标系，身体移动 / 呼吸时不重建；链形状变化 < 0.08 mm 时跳过重建（静挂时 30 帧约 7 次）。原子宫、宫腔、输卵管、卵巢在脱垂期间隐藏（体外不画输卵管卵巢）。
- **阴道（简化）**：着色器 `prolapse_offset4` 只做径向撑开：脱出物经过处的阴道壁被撑到脱出物半径 + 2 倍壁厚（不再内翻折叠，体外也没有套筒）。CPU 同公式 `OrganRig.prolapse_offset_ab()` 给自检用。参数在腹部坐标里，只有下移量 / 通道变化 ≥ 0.15 mm 才重写材质参数。
- **通道缓存**：外口 / 宫颈 / 朝上方向在腹部坐标里缓存，每 20 个物理帧才重新拟合一次（拟合要 CPU 姿态整根阴道，以前每帧都做）。
- **外口 / 阴唇**：`ProlapseMassInserter` 是一段沿阴道轴（里）→ 脱出方向（外）的弯胶囊，半径 = 外口处脱出物截面。脱出方向先低通（`introitus_dir_tau` 0.5 s），截面变化 ≥ `introitus_r_step`（0.5 mm）或低通后走向变化 ≥ ~10°（`introitus_dir_dot` 0.985）才重解，甩动中最多每 `introitus_cooldown`（10）帧一次；截面变化 > 1.5 mm 立即重解，保证不穿模。

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
- **观察 / 普通互动视角（t68u）**：任何互动工具下左键点中体外悬垂的子宫都会先变成用手拖（`player_controller._try_begin_prolapse_hand`，同一驱动接口，可拉出 / 推回 / 甩）。
- **手术钳（t68u）**：直接夹住阴道口外悬垂的子宫拖动 / 甩动（`_fc_kind = "prolapse_out"`，可加重也可推回）；经腹部创口夹子宫时仍是先按向外拉的距离逐渐复位脱垂（`surgery_reduce_gain`、`surgery_reduce_speed_max`），复位到 0 后同一把钳子直接转入正常的经创口扯出。脱垂中不会直接开始创口扯出。子宫已被手术扯出时不会触发脱垂。
- **手术拿取工具（T-11）**：可拖动 / 甩动体外的脱垂子宫，只移动，不加重也不复位。
- **复原 / 放回内脏 / 手术整身复原**：都会把脱垂完全复原（`reset()`）。
- **断面小窗**：脱垂中加入专用子宫模型的断面拷贝（拷贝是模型的子节点，跟着它的变换和网格），阴道拷贝带同一组撑开参数；纵向视图自动框住阴道上端到最远的脱出物；横切面放在外口（球卡住时跟球）。
- **HUD**：阴道互动模式里显示「子宫脱垂 N 度 · 说明（百分比）」。

## 自检数值（`v0420_prolapse_check.gd`）

专用模型 314 顶点（IV 度带细颈 365），原子宫 3839；两个面复用原子宫 / 阴道材质；刚激活时宫颈尖与原宫颈重合 0.00 mm。I 度宫颈在外口内 30.7 mm；II 度 +0.2 mm；III 度宫颈出 36.9 mm、宫底仍在内 27.1 mm；IV 度宫底出 25.1 mm、5/5 节点在外、宫底挂在外口（= 绳长）、距肚脐 19.7 cm；最大 IV 度宫底出 50 mm（t68u 前 ≤ 14 mm）。外口半径 17.1 / 30.2 / 20.7 mm ≥ 脱出物截面，穿模 0。模型连续（最大环距 4.5 mm，IV 度 8.3 mm），体外部分法线与绕序全部朝外；体内阴道 → 前倾宫体急弯内侧有少量三角压叠（I–III 度 4 / 8 / 22 个 / 480，看不见）。阴道不再内翻（0 个折叠顶点），壁与脱出物最小间隙 3.2 mm。甩动峰值 0.36 m/s，3 s 后 3.7%，段长最大拉伸 1.007。手拖 101.5 → 169.3 → 69.3 mm；观察视角手拖 101.6 → 169.2 mm；手术钳直接拖体外子宫侧移 38 mm；手术复位单调到 0 后才转入创口扯出。

### 每帧开销（t68u 前后，`ProlapseController.last_step_usec`，无头单独运行，每种 240 帧平均）

| 情况 | t68u 前（SoftOrgan + 套筒 + 折叠） | t68u 后 |
|---|---|---|
| 静挂 amount 0.5 | 1257–1459 µs | 226–240 µs |
| 甩动 amount 0.5 | 5631–5804 µs | 1139–1255 µs |
| 静挂 amount 0.97 | 1628 µs | 292–295 µs |
| 甩动 amount 0.97 | 5327–6344 µs | 549–554 µs |

t68u 后的分解（甩动 0.5）：模型重建 ≈ 220–240 µs、外阴重解摊到每帧 ≈ 860–950 µs（一次约十几 ms，低通 + 限频后很少发生）、链物理 ≈ 20 µs、阴道参数 ≈ 4 µs。t68u 前的数字不含 SoftOrgan 的 GPU 蒙皮和套筒网格的渲染开销，实际差距更大。

## 已知简化

- 体外不画输卵管 / 卵巢（脱垂期间整体隐藏）。
- 模型截面是圆的；会阴只用一个平面挡；检查床面不参与碰撞（`floor_y` 默认关）。
- 体内急弯处模型内侧的环会互相压叠几个三角（被阴道 / 身体挡住）。
- 外阴重解一次十几 ms，甩动中走向低通 + 限频：快速甩动时外口阴唇跟随会滞后（截面变化大时仍立即重解，不穿模）。
- 只有一种触发方式（长杆钢球）；手法 / 腹压等以后按 `ProlapseTrigger` 加。
