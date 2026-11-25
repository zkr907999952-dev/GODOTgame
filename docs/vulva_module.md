# 外阴 / 阴道入口模块

阴部交互是后续核心功能。本模块把外阴网格、开合骨骼、软体和「插入物」从 `OrganRig` 里拆出来，底子按可扩展来做。

## 文件

| 路径 | 作用 |
|---|---|
| `scripts/body/vulva/vulva_system.gd` | 对外入口。OrganRig 只拿这一份。 |
| `scripts/body/vulva_flaps.gd` | 皮瓣剪裁、接缝圈、骨骼+PBD、网格修复。System 继承它。 |
| `scripts/body/vulva/vulva_params.gd` | 数据参数（刚度、骨骼名、圈数、拉伸上限）。 |
| `scripts/body/vulva/vulva_inserter.gd` | 通用插入物接口。 |
| `scripts/body/vulva/envelope_inserter.gd` | 椭圆 / 双叶截面实现（扩张器、胶囊、圆截面道具）。 |
| `shaders/vulva_soft.gdshader` | 前庭黏膜：外圈跟皮肤贴图连续，向内过渡到黏膜色。 |

## 网格与顶点组

接缝圈（前庭）把躯干皮肤开口焊到阴道外口，补洞、统一法线、加密拓扑，并带连续 UV / 切线 / 蒙皮。命名组（`VulvaSystem.groups` / `group_indices(name)`）：

- `labia_majora_l` / `labia_majora_r` — 大阴唇（靠外）
- `labia_minora_l` / `labia_minora_r` — 小阴唇（靠裂隙）
- `clitoral_hood` — 前联合、阴蒂包皮预留
- `introitus_ring` — 外口圈（皮瓣开口边）
- `canal_seg_0` … `canal_seg_N` — 前庭沿深度的一圈圈（0 = 外口边，最后一行 = 阴道外口）
- `body_seam` — 与身体皮肤焊接。拨开时锁定；插入时若叶片顶到接缝，接缝和周围皮肤按衰减一起让开，避免撕边或穿模

以后要单独变形某一层（例如只拉小阴唇或只撑某一段阴道），对这个组的顶点施加位移即可，不必再切网格。

## 插入物接口（扩展点）

不要在外阴脚本里为扩张器 / 手指 / 玩具写 `if`。任意道具实现 `VulvaInserter`：

- `mix()` — 0 未插入，1 完全在位
- `envelope()` — `{half_x, half_y, blade_sep, axis, up}`，外口平面上的截面包络
- `project_out(p, origin, axis, up)` — 把顶点推出物体
- `penetration(p, …)` — 穿模深度
- `cross_section(origin, axis, up)` — 可选，精确多边形截面

然后 `vulva.set_inserter(ins)`。已有：

- `EnvelopeInserter`：双叶（扩张器随开合角变化的叶片包络）或单椭圆 / 圆（棒、指节）
- `VulvaSystem.set_capsule_insert(origin, axis, radius, mix)` — 钳子、手指的快捷入口

取出后 `set_inserter(null)` 或 `mix=0`，软体回到静息。

## 开合骨骼与参数

粗运动：左右大阴唇铰链（拨开动作）+ 外口环向骨骼（插入物截面）。细运动：PBD 边约束 + 碰撞投影。进到插入物体积里的顶点完全推出，位移用拉普拉斯传到周围；再按 `skin_falloff` 写回躯干皮肤，外口就能被撑成真实截面而不撕破。刚度、迭代、最大拉伸、圈数、衰减半径、骨骼名都在 `VulvaParams`，可做成 `.tres` 按角色替换。

## OrganRig / 扩张器怎么接

`OrganRig.set_speculum_labia(...)` 仍可用；内部会配一个 `EnvelopeInserter` 再交给本模块。测试继续走 `rig.vulva` 上的原 API（`set_spread`、`introitus_half_extents`、`debug_mesh_quality` 等）。

## 以后建议的扩展

- 阴蒂 / 包皮独立网格或形变骨，绑到 `clitoral_hood`
- 小阴唇更密的一圈，只用 `labia_minora_*`
- 通道按 `canal_seg_*` 做深度相关的润滑 / 箍紧参数
- 新道具：实现 `VulvaInserter`（也可用网格 SDF 做 `project_out`）；非解析包络会走接口，椭圆/双叶走热路径
- 把 `VulvaParams` 存成资源，按角色或体型加载
- 通道深度方向的软体（按 `canal_seg_*` 分段刚度），以及阴蒂/小阴唇独立骨驱动
- 周围皮肤衰减可换成预计算的谐波权或骨骼蒙皮，而不必改插入物接口
