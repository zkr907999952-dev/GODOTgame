# 蒂法的玉腹沙盒 / GODOTgame

Godot **4.7.2** 项目（Forward Plus）。角色与地图来自网页原型 [rouchangmoniqi3](https://github.com/zkr907999952-dev/rouchangmoniqi3)。

## 环境

- **引擎**: Godot **4.7.2.stable**
- **仓库**: https://github.com/zkr907999952-dev/GODOTgame
- **主场景**: `scenes/main.tscn`

## 载具（0.2.17）

房间默认有一张检查床（放在地板上，不与家具床/墙重叠）；进入城市后，两架战斗机并排停在机场跑道起点（约 x=-1000, z=300）的跑道面上，道路上再刷几辆跑车。

- 顶栏「载具」：在**准星（屏幕中心）**指向的地面生成跑车、战斗机或检查床；「清除生成的载具」只删除菜单生成的（保留跑道默认飞机和家里的检查床）；「重置默认载具」会按当前地图重新放置默认载具。
- PC：靠近载具或已在载具内时按 **F** 进入 / 离开。不在载具附近时，观察模式的 F 仍是视觉中心循环。车上 / 飞机上默认第三人称，可按 **V** 或界面按钮在第一/第三人称间切换。检查床保持可看自己身体的第一人称，观察模式不改变躺姿。离开任何载具后角色恢复直立站姿和进入前的朝向。
- 跑车（PC）：**W/S** 前进/倒车，**A/D** 转向，按住 **Shift** 氮气加速，**空格** 手刹/漂移。手机：摇杆控制前进/后退和转向，右侧为加速键和手刹/漂移键。
- 战斗机（PC）：**S** 拉杆抬头，**W** 推杆俯冲，**A/D** 滚转，**Q/E** 偏航，**Shift** 加速/加推力，**C** 减速/减推力。油门杆最后一段为加力。操纵面：W/S 同时带动推力矢量喷口和水平尾翼；A/D 同时带动副翼和差动喷口；Q/E 带动垂尾舵面；加速时喷口瓣张开，减速时襟翼放下且喷口收缩。手机：摇杆俯仰/滚转，右侧加速和减速键，加速键上方为左右偏航键。
- 占用载具时 Q/G 不会误开武器轮盘或收枪。手机上下车按钮仍然可用。
- 跑车使用 Godot `VehicleBody3D` + `VehicleWheel3D`（Jolt），碰撞为贴合模型、已预烘焙的多凸包（不含车轮；运行时不再现场计算凸包，避免打开地图传送时卡死）。战斗机是刚体气动（升力 / 迎角失速 / 起降），操纵面、推力矢量喷口和马赫环喷流沿用并加强了现有绑定。
- 检查床：进入后角色躺在台面上，髋部在座垫、上身贴合靠背、头在头枕、左右腿分别搭在左右腿架上（截石位，不交叉、不左右对调）。默认可低头看自己的身体；切到观察模式时姿势保持。离开时站在房间地板上、仍在房间内（不会被天花板射线送到屋顶外）。
- 在房间打开俯视地图只预览城市，不会刷出城市场景默认载具，也不会藏起家里的检查床；确认传送 / 回家 / 切换地图时才真正切地图，并保持可走动。

自检：`godot --headless --path . -s res://scripts/tests/vehicles_check.gd`

## 操作

两个相机状态：**展示互动（观察视角，第三人称，默认）** 与 **角色控制（第一人称）**，Tab 切换。

### 观察视角（展示互动，按键/鼠标同网页 OrbitControls）

| 输入 | 作用 |
|------|------|
| 鼠标**右键**拖动 | 环绕角色（带阻尼，俯仰限制同网页 0.08π–0.9π） |
| 鼠标**中键**拖动 / **Shift/Ctrl + 右键**拖动 | 平移视点（屏幕平面） |
| 滚轮 | 推近 / 拉远（0.2–6.2m，对数缩放） |
| 鼠标**左键** | 腹部互动（光标常显，直接点） |
| F | 视觉中心循环：面部 → 胸部 → 腹部 → 阴部（同网页 CAM_FOCUS 按钮） |
| R | 复位视角（网页 ORBIT_HOME：正面略偏右、略俯视、看向腹部）并清除腹部互动形变 |
| T | 循环互动模式（拖拽 / 打击 / 拳交 / 刺刀 / 长刺刀 / 肚脐） |
| X | 腹部透视开 / 关（默认开，强度 0.38） |
| B | 呼吸开 / 关 |
| H | 隐藏 / 显示界面 |
| HUD「摄像机」 | 视觉中心按钮、缩放滑条、平移方向键（◀▲▼▶/近）、**自动旋转**、4 个**视角预设**（右键保存 / 左键调用） |

默认观察位**在房间内、正对角色**（角色背对镜子面向房间，镜中可见背影）。相机有碰撞：房间墙内包围盒（网页 `pullCameraOutOfWalls`）+ 对场景碰撞体做球体扫掠，撞墙立即拉近、离开后平滑恢复，不会穿墙出屋。

### 角色控制（第一人称）

| 按键 | 作用 |
|------|------|
| 鼠标 | 环视（点击画面捕获鼠标；Esc 释放 / 再按重新捕获） |
| W A S D / 方向键 | 移动（相对视角方向） |
| Shift | 冲刺（仅站立；速度 ≈ 走速×2.5，run* 动画） |
| 空格 | 跳跃（蹲/匍匐时改为站起；头顶空间不够时不站起） |
| Ctrl / C | **切换**下蹲（再按站起；匍匐中按一下先站起） |
| Z | 切换匍匐（仅角色控制模式；展示模式下 Z 无效） |
| 滚轮 | FOV（50–90）；**持枪时 = 循环切换武器** |
| 1–9 | 武器槽位：第 1…9 把武器（再按当前武器的数字 = 收枪）；舞蹈预览只在展示模式 |
| 鼠标左键 | 腹部互动（以屏幕中心为准）；**持枪时 = 开火**（半自动 / 泵动每次按一下一发，全自动按住连发） |
| 鼠标右键 | 持枪时 = 开镜（ADS，FOV 收窄、散布减小） |
| Q（按住） | 武器轮盘：移动鼠标指向格子，松开 Q 选中；中心 = 收枪；轮盘打开时滚轮翻页（每页 8 把）。手机按住「武器」时，轮盘以当前点击点为拉选原点。 |
| G | 收枪 / 取出上一把武器 |
| R | 持枪时 = **换弹**；空手时 = 复位视角（按键冲突的约定） |
| E | **切换拖拽尸体**（准星对准已死亡布娃娃且在手臂范围内；再按放下。地上的尸体需蹲下或趴下才能抓住。观察视角同样可用。与 T 循环腹部互动模式互不占用） |
| HUD「武器」 | 武器菜单：按类别分组的武器卡片（剪影图标 + 右下角弹药数），点选切换 / 收枪 |

### 通用

| 按键 | 作用 |
|------|------|
| **Tab** | 切换 展示互动 ↔ 角色控制（切回观察时相机从眼位平滑飞出到正面） |
| M | 打开 / 关闭**地图菜单**（俯视地图打开时 M / Esc 关闭俯视） |
| Esc | 关闭 HUD 面板 / 释放鼠标 |
| H / X / B / T / R / E | 两种模式通用：界面、透视、呼吸、互动模式、复位（角色控制持枪时 R = 换弹）；E = 切换拖拽尸体 |
| 1–8 / 0 / 9 | 展示模式：预览舞蹈 dance1…dance8 / 取消舞蹈（角色控制模式 1–9 = 武器槽位） |
| HUD「地图」 | 地图菜单：卧室；城市出生点 / 林荫大道 / 跨海大桥（坡道）/ 码头栈桥 / 机场跑道；「俯视地图」 |

**按键路由**：所有离散按键只在 `game_root.gd` 的 `KEYMAP`（common / display / control / overhead）里定义一次，按当前模式查表后调用 `run_action`。HUD 所有按钮、滑条、开关都是 `FOCUS_NONE`，不会抢键盘焦点，所以角色控制模式按**空格**只会跳跃，不会再"按下"刚点过的菜单按钮；Tab / 方向键也不再被 GUI 焦点导航吃掉。HUD 面板打开时**仍可左键互动**腹部。

### 地图菜单与城市大地图

- 大地图 = 网页项目的 `public/models/city.glb`（网页只有 home / city 两张图），3000×3000m，约 1238 个网格 / 68 万三角面。
- 「地图」面板：选择出生点直接传送（保持当前游玩模式，方便在城市里用角色控制测试物理）；打开地图菜单时不显示武器 / 弹药 UI。「俯视地图」= 网页 CityMapPanel 的移植：鼠标拖动平移、滚轮缩放（36–1600m 高度），手机双指捏合缩放、中点平移，单击放置标记，「传送」到标记处落地，「回家」回城市出生点，「清除」去掉标记。
- 城市有天空色 #7eafd0 + 雾 220–3400m（网页 WorldClip）；房间保持原光照。
| HUD「设置」 | 呼吸 / 眨眼 / 头发物理 / **乳摇物理**开关、**乳摇强度**滑条、鼠标灵敏度、**无限备弹**（默认开，备弹显示 ∞，仍需换弹） |
| HUD「互动」 | 拖拽 / 打击 / 拳交 / 刺刀 / 长刺刀 已接入（参数面板 + 分身：创建分身 / 清除所有分身）；肚脐 仍为占位 |

### 腹部透视与体内脏器（移植自网页 figure.tsx）

- **脏器**：网页的大肠/小肠（`intestines.glb`）与盆腔包（子宫、膀胱、卵巢、输卵管、韧带；外阴已按网页删除）由 `tools/bake_organs.py` 按网页同款算法摆进腹腔，蒙皮到 `C_Hip_a` / `C_Spine_a..d`，随走、蹲、匍匐、呼吸一起动；肠管有网页同款**蠕动**。
- **蠕动参数**（HUD「摄像机」→ 透视）：蠕动幅度、蠕动速度、蠕动波密度（0.4–4，默认 1.55）、分节收缩（0–2，默认 1.0）+「蠕动参数复位」。速度改为积分相位，拖动滑条不会跳帧。
- **透视**：只作用于腹前区域（肚脐上下 −0.205…+0.15m、左右约 ±0.12m、身体前侧），中心挖孔 + 半透明边缘过渡，强度 0–1（默认 0.38）。镜子、第一人称同样生效。
  窗口按躯干截面轮廓（`organs_meta.json` 的 profile）收窄：外缘留在轮廓内 1.5cm、只挖截面前半，侧壁 / 后壁永远保留，从孔里看进去是暗红腔壁。
  之前腰部（肚脐上 4–11cm，半宽只有约 9cm）比固定窗口（12cm + 10cm 渐隐）还窄，整圈截面连同后背一起被挖掉，正面能直接看穿到身后背景。
- **互动**（展示互动模式为主，角色控制模式也可用）：
  - **拖拽**：按住左键拖动腹壁，皮肤与肠/子宫一起被拉动（脏器跟随 0.82），松手弹簧回弹。
  - **打击**：点击腹部 → 环形冲击波 + 中心凹陷压到肠管上，约 1.7s 回弹，同时肠蠕动短时加快。
  - 冲击环 / 拖拽标记按腹部局部轴缩放（任何地图、任何朝向都是正圆；之前用了世界轴缩放，身体转过角度后被拉成椭圆）。
- **布局**：网页原布局在这个角色上整体偏高；Godot 版按标注调到肚脐下约 2.6cm（`GUT_CENTER_DY=-0.026`），并收窄 `GUT_SCALE_X=0.9` / 压扁 `GUT_SCALE_Y=0.94`（以顶部为锚），肠团范围约 0.956–1.180m（肚脐 1.06m），在子宫上方；透视窗口 y 为 −0.205…+0.15m；子宫 0.90–0.96m 位于耻骨后，膀胱在其前下方；全部顶点都在躯干皮肤内、透视窗口内（`validate_headless` 检查）。参数在 `tools/bake_organs.py` 顶部（`GUT_CENTER_DY` 等）。
- 细节见 `docs/organs_port_notes.md`。渲染自检：`xvfb-run -a godot --path . -s res://scripts/tests/organs_check.gd`（截图到 `user://organs_check` 或 `ORGANS_CHECK_OUT`）。

### 游玩模式

| 模式 | 默认 | 相机 | 移动 | 注视 |
|------|------|------|------|------|
| **展示互动** (Display) | ✅ 启动默认 | 第三人称环绕 | 锁定（忽略 WASD） | 头+眼看向相机 |
| **角色控制** (Control) | Tab 切换 | 第一人称 | WASD / 蹲 / 匍 / 冲刺 | 颈头跟随相机；身体 yaw 在静止时滞后约 ±60°（共约 120° 自由环视）再跟上 |

从控制切回展示时，环绕轴强制对准角色**当前位置**（CameraPivot 跟随角色），并重新显示头/发/眼网格以便注视。摄像机面板按钮与 Tab 等价。

默认出生在**房间**；按 `M` 传送到城市出生点附近。房间 **+Z 空墙**整面是镜子：镜中相机放在当前活动相机关于镜面的镜像位置、正对镜面，用**离轴视锥（PROJECTION_FRUSTUM，近裁面 = 镜面）**渲染，贴图与镜面 1:1 对应，视差/左右镜像天然正确；展示 TP / 控制 FP 均适用，FP 下镜中可见完整头脸（头部用渲染层 19 仅对主相机隐藏）。镜子背面透明（从墙外看得到房间）。

### 手机 / 触屏（详见 `docs/touch_mobile_navel.md`）

- 观察：单指点身体=当前工具，双击后拖=环绕，空白处单指拖=环绕，双指=平移+捏合缩放。
- 控制：左下摇杆（外圈奔跑），右侧拖动转视角，右下 互动 / 下蹲（长按匍匐）/ 跳跃，左侧竖条缩放，顶部「切换」。
- 竖屏手机：菜单面板变成底部抽屉（可滚动，「收起」）；设置里可开关触屏操作。
- 肚脐互动：互动面板「肚脐」，按住肚脐往里拖=插入；自动抽插 / 搅动。

## 武器（详见 `docs/weapons.md`）

- 4 把武器全部来自 **Kuptchi「PSX-Weapons Assets [Free Pack]」**（https://kuptchi.itch.io/f）：手枪 M1911（半自动）、突击步枪 AR-15（全自动）、冲锋枪 Uzi（全自动）、泵动霰弹枪 870（泵动 + 逐发装填）。包里没有狙击枪 / 近战武器。
- 每把武器一个 `WeaponDef` 资源（`assets/weapons/<id>/<id>.tres`）：射速、弹匣 / 备弹、后坐力、散布、换弹时间、枪口位置等全部数据驱动；新增武器只需放一个新目录 + `.tres`。
- 手：素材的手臂网格**没有导入**；素材手臂动画被烘焙成「相机空间的手腕位置 / 手掌朝向 / 手指弯曲」，运行时用 IK 驱动**角色自己的**手臂和手指骨骼。
- 只在角色控制（第一人称）模式下可用，展示模式隐藏。触屏：「武器」按住拖到轮盘格子松手选枪，持枪时出现「开火」（按住，可同时拖动转视角）/「换弹」按钮。
- 弹道：真实弹头网格按速度 / 重力 / 阻力飞行（手枪下坠更明显，步枪更平直，霰弹 8 粒），命中世界留下弹痕；击中人体有入射/出射创口、弹道通道，肠道和子宫被击中会发红并受冲击。详见 `docs/weapons.md`。信号 `shot_fired` / `hit` / `body_hit` / `organ_path` 留给后续毁伤系统（规划见 `docs/wound_system_plan.md`）。
- 弹壳：物理刚体落地，按武器抛对应型号，10 秒后消失，最多 40 个；霰弹在泵动时抛壳。
- 弹道特写：设置里可开关（默认开）并调整概率（默认 20%）。弹道穿过肠道或子宫时有机会慢动作跟随，类似狙击精英；点击或触摸可跳过。素材没有音效，射击 / 换弹 / 空枪声只留了钩子（`WeaponDef.sfx_*` + `sfx` 信号）。
- 素材许可：个人和商业项目都可免费使用，不要求署名（作者希望注明），**不得转售素材**。仓库只放转换后的游戏用资源，原始包不入库。致谢：Kuptchi。

## 界面（HUD）

`scenes/ui/hud.tscn` + `scripts/hud.gd`，挂在主场景 CanvasLayer：

- **设置（左上）**：开关 `SoftSecondary` 的呼吸 / 眨眼 / 头发物理；鼠标灵敏度滑条；面板说明显隐。打开面板时释放鼠标便于点击。
- **互动（右侧）**：五种模式按钮，写入 `OrganRig.interact_mode`。拖拽 / 打击 / 拳交 / 刺刀 / 长刺刀 已接入（见 `docs/insert_tools_clones.md`）；肚脐 仍占位。下方「分身」：创建分身（站在视线所指处，可互动，第一人称也可）/ 清除所有分身（上限 8）。
- **地图（左上，设置右侧）**：地图菜单（见上）。
- **摄像机**：重置视角；**透视**（腹部透视开关 / 腹部半透明滑条 / 显示脏器 / 肠蠕动 / 4 个蠕动参数滑条 + 复位）；**游玩模式**（展示互动 / 角色控制，等同 Tab）；灵敏度（与设置共用）。**展示**：第三人称、锁移动、头+眼 `set_gaze_target` 看向相机，头/发/眼可见。**控制**：第一人称；身体 yaw **不**瞬时跟相机（静止时约 ±60° 死区 / 共约 120° 自由看，移动时朝向移动方向）；颈/头 `setBodyLook`；隐藏头/发/眼/嘴防裁切；眼高网页 `stanceEye`（站 1.52 / 蹲 1.06 / 匍 0.3，蹲↔站身体 **0.7s** 过渡，眼位 0.3s ease-out 先到位、起身时前后分量跟身体同速，过渡中近裁球 0.13m）；颈/头看向按当前姿态（蹲/趴时脊柱前倾、脖子弯曲）重新解算，始终看向视线方向；近裁剪 ≈0.06；俯仰 ≈±89°；滚轮调 FOV。

## 动画（网页 loco-clips）

角色蒙皮骨架由 `SoftLoco`（`scripts/soft_loco.gd`）每帧驱动，**不依赖 Mixamo FBX**：

- 数据：`assets/characters/tifa/loco-clips.json`（与网页 `src/lib/softbody/loco-clips.json` 同源，26 段）
- 选取逻辑对齐网页 `soft-skeleton.ts` 的 `pickLocoClip` / `applyLocomotion`：站立 idle / 走跑八向、下蹲、匍匐、跳跃；Shift（站立）切 run*；走速 ≈1.65 m/s，冲刺 ×2.5，蹲/匍更慢
- `standIdle`：`STAND_IDLE_MOTION=0.18`、`idle_slow=2.4`，并调用 `nudgeIdleUpright` + **`nudgeIdleArmsBack`**（上臂略向身后 z-0.22，与网页一致）
- 碰撞圆柱底与网格脚底对齐（AABB min.y≈0，圆柱 bottom≈0），避免脚陷入地面
- **朝向**：网页 loco 绑定 mesh 朝 **+Z**，Godot 移动以 **-Z** 为前；`$Body` 施加 **π yaw 偏移**（`BODY_YAW_OFFSET`），使胸部朝向移动/相机前方。偏移后 loco 的 fwd/side 相对 Body **+Z** 取符号（相对旧逻辑取反）
- 采样：欧拉 XYZ（loco）或四元数 slerp（dance）；姿态为角色空间 child-from-parent，经 rest 共轭后写入 `Skeleton3D.set_bone_pose_rotation` / `position`（含 hipY）
- 次级动画 `SoftSecondary`（`scripts/soft_secondary.gd`，默认全开，对齐网页）：
  - **头发 Verlet**：`group=="hair"` 链（HairRoot…Hair_8）；**k≤1（HairRoot+Hair_1）钉在骨架 FK**，仅下段 Verlet 摆动（对齐网页 `pinned = k <= 1`），根部发段的形状回复力更强（发梢更软）
  - **头发蒙皮（头皮固定）**：网页运行时 `reskinHair` 会把头顶/刘海/贴头皮的发片全部改绑到头骨，只有垂下的发尾按高度插值到 Hair_2..8。Godot 版之前直接用了原始权重，头顶顶点也带 0.2–0.5 的 Hair_2+ 权重，所以甩发时头顶跟着动。`tools/fix_hair_skin.py` 已把这一步烘进 `Tifa_Web_Skinned.glb`：按高度（冠部以上=0）× 离头皮距离（<8mm=0，>35mm=1）× 前额区，平滑过渡；约 82% 的头发顶点完全刚性跟头，`validate_headless` 检查甩发时头顶顶点相对头骨位移 = 0。
  - **头发渲染**（`scripts/character_look.gd`）：原材质是「alpha 混合 + 深度预通道」，同一网格里的发片无法排序，看起来发灰、透出头皮。改为 alpha scissor 0.38（网页 alphaTest）+ alpha-to-coverage（项目开启 MSAA 2×）实心主通道 + 半透明边缘第二通道；头皮在头发覆盖区域用 `scalp_mask.png` 细节遮罩染成发根色，缝隙里不会再透肤色。
  - **乳摇物理**（`scripts/breast_physics.gd`）：每侧一个世界空间质点弹簧-阻尼（竖直 2.1Hz / 水平 2.6Hz，阻尼比 0.16，240Hz 固定子步）+ 一个 4.8Hz 乳尖二级弹簧；锚点随 C_Spine_d 运动，所以走、跑、跳（失重上浮 / 落地下坠）、急停、转身、蹲起都会自然驱动；位移写到 `L/R_Breast_a_Phy`（带权重的骨），乳尖滞后转成绕乳房中心的小角度摆动；椭球软限幅防穿模；左右频率差 6% 产生自然相位差。HUD「设置」里可开关、调强度。
    观察模式下转视角也会带动（网页 pushViewSpin）：相机环绕的方位角 / 俯仰角速度偏移弹簧平衡点（身体局部轴，横向为主，限幅 3cm），转动时甩开、停下回弹衰减；角色控制模式仍只由身体运动驱动。
  - **眨眼**：睑骨 `L/R_(U|D)lid_[A-E]`，blinkT/nextBlink/blinkAmt 周期驱动
  - **呼吸**：web 同款 breathAmp/Speed/Chest 波形；骨级近似为 C_Spine_a..d（及 Breast_Spo）**相对 rest 的 X/Z 缩放膨胀**（吸入变宽/加深），峰值约 **1–2%**（腹略重于上胸），**不做脊柱 X 俯仰**（网页是软组织 ~1cm tz 膨胀）；软笼顶点位移仍未移植

## 本地运行

1. 安装 [Godot 4.7.2](https://godotengine.org/download/)
2. `git pull origin main`
3. 用编辑器打开 `project.godot`（首次会导入角色 / 房间 / 城市）
4. 按 **F5** 运行

无头自检（可选）：

```bash
godot --headless --path . --script res://scripts/validate_headless.gd
```

## 角色（蒙皮绑定）

| 来源（网页项目） | 用途 |
|------|------|
| `public/models/tifa.glb`（约 16MB） | 角色网格 + 贴图（原文件无骨架） |
| `src/lib/softbody/nude-rig-data.json` | 185 骨 + 每顶点 4 影响权重 |
| `src/lib/softbody/loco-clips.json` | 走跑蹲爬跳 + 舞蹈关键帧 |

导入本仓库时已用 Blender 脚本 `tools/bake_tifa_skinned.py` 烘成：

- `assets/characters/tifa/Tifa_Web_Skinned.glb`（约 15MB，Skin + 185 bones）
- 对齐网页 `fitStanding(1.66)`：脚底贴地、身高约 1.66m、骨骼与网格同一坐标系
- `assets/characters/tifa/loco-clips.json`：运行时程序化动画

**已删除的大体积资源**：原 `tifa_nude/`（FBX+4K TGA）与 `tifa_clothed/`。

若需重新烘培：

```bash
/workspace/tools/blender/blender --background --python tools/bake_tifa_skinned.py
```

（需本机有网页项目路径下的 `tifa.glb` 与 `nude-rig-data.json`，脚本内路径可改。）

## 地图与碰撞

| 资源 | 说明 |
|------|------|
| `assets/maps/room.glb` | 房间（约 2.8MB），缩放 0.7 + Y 轴 180°，对齐网页站立姿态 |
| `assets/maps/city.glb` | 城市（已去掉 meshopt，约 14MB，便于 Godot 导入） |
| `scenes/maps/room.tscn` + `scripts/room_collision.gd` | 房间用**盒体碰撞**（地板、天花、四面墙含镜面墙、柱、梁、床、床头柜、椅子、柜子）；不再用逐网格 trimesh（1cm 地毯边会卡住角色，镜子那面没有墙会掉出房间） |
| `scenes/maps/city.tscn` | 运行时对 MeshInstance3D 调用 `create_trimesh_collision()`（约 1136 个静态体，跳过树叶/细小网格，约 0.4s）；物理引擎 Jolt（活动边处理，trimesh 接缝不卡） |

## 光照（`scripts/lighting_rig.gd`）

参考网页 `scene.tsx`（StudioLights / CityLights，ACES 曝光 1.05）：
- **房间**：主光（暖白方向光，角色正前上方，投影：PSSM 2 段 / 12m、小 bias、柔化、不透明度 0.82）、冷色侧补光、背后轮廓光、吸顶灯 + 台灯（网页原位），暖灰环境光。房间结构网格（墙/天花/地板）不投影——之前方向光从房顶外照进来，整个房间都在天花板的阴影里。
- **城市**：太阳（PSSM 4 段 / 90m）+ 天光补光 + 程序天空环境光，背景 #7eafd0 + 深度雾 220–3400m。
- 主光仰角约 32°（能量 0.6、镜面 0.55），吸顶灯 0.45，环境光 房间 0.26 / 城市 0.34：避免高位主光 + 吸顶灯把朝上的胸口/锁骨/肩打成一条过亮带。皮肤粗糙度下限 0.45、镜面上限 0.36（原贴图算下来只有 ≈0.28，像抹油）。
- 眼睛 / 面部材质关掉导入的 AO（glTF ORM 的 R 通道不是 AO，眼球 R≈0.27 → 城市里眼窝只剩天空环境光时眼白发黑），眼球粗糙度 0.42 有湿润高光。
- 第一人称跟随相机的补光只照角色（房间 0.18 / 城市 0.06，移动时 ×0.45，同网页 BodyFillLight；衰减 0.6，避免近处胸口/手被打白），观察模式关闭。
- 第一人称时头/发/眼对主相机隐藏，但挂了「只投影」副本（SHADOWS_ONLY，同蒙皮），影子里有头。
- 镜中相机用 LINEAR 色调映射（主视口已做 ACES，避免镜子里双重色调映射发灰）。
- 不开 SSAO：透视窗口的半透明覆盖层走透明管线、不吃 SSAO，会在窗口边缘出现方框。

### 角色物理（角色控制）

- Jolt 物理 + **物理插值**（`project.godot`）；相机在 `_process` 用自己记录的插值原点放置，60Hz 物理不再抖动，传送时立即对齐。
- 移动对齐网页 Quake 式加速/摩擦：地面加速 12、空中 3.4、摩擦 6.4、重力 20、起跳 6.0 m/s、土狼时间与跳跃缓冲各 0.14s、最大下落 58 m/s。
- 碰撞体改为**圆柱**（半径 0.3，站 1.64 / 蹲 0.94 / 匍 0.42）：胶囊圆底在台阶边会滑落；自动**上台阶** 0.3m（`test_move`）；坡度上限 46°、贴地 0.32m、墙面滑动；起身前检查头顶空间。
- `validate_headless` 有测试场：35° 斜墙滑行、0.2m 台阶、20° 坡、松键减速、低天花板禁止站起、城市出生点落地并行走。

## 项目结构

```
project.godot
scenes/main.tscn
scenes/characters/tifa.tscn
scenes/maps/room.tscn
scenes/maps/city.tscn
scripts/player_controller.gd
scripts/soft_loco.gd
scripts/soft_secondary.gd
scripts/map_collision.gd（城市 trimesh）
scripts/room_collision.gd（房间盒体碰撞）
scripts/map_view.gd（俯视地图相机 / 标记）
scripts/game_root.gd（地图切换 + 按键路由 KEYMAP）
scripts/hud.gd
scripts/weapons/weapon_system.gd（武器状态机 / 开火 / 换弹 / 后坐 / 枪口火焰 / 手部 IK）
scripts/weapons/weapon_def.gd（WeaponDef 资源）, arm_clips.gd（烘焙手部动作采样）, ballistics.gd（弹头飞行）, casing_system.gd（物理弹壳）, bullet_cam.gd（弹道特写）
scripts/game_settings.gd（设置持久化，含弹道特写开关 / 概率）
scripts/ui/weapon_wheel.gd（Q 轮盘）, weapon_ui.gd（武器菜单 + 弹药 HUD）
scripts/tests/weapons_check.gd（武器自检，headless）
scripts/tests/ballistics_check.gd（弹壳 / 弹道 / 毁伤 / 特写自检，headless）
assets/weapons/<id>/（网格 .scn、贴图、剪影图标、烘焙手部动作 _arms.res、定义 .tres）, assets/weapons/shared/（枪口火焰、弹壳）
scripts/validate_headless.gd
scripts/room_mirror.gd
scripts/organs/organ_rig.gd
scripts/breast_physics.gd（乳摇弹簧）
scripts/character_look.gd（头发 / 头皮材质）
scripts/tests/fix_check.gd（内脏 / 头发 / 相机 / 乳摇 渲染自检）
scripts/tests/fix_check3.gd（透视正面 / 光照 / 城市击腹+拖拽 / 第一人称跑跳 渲染自检）
scripts/tests/fix_check4.gd（上半身高光 / 蹲姿头部朝向（镜子）/ 下蹲过渡 / 影子带头 / 城市面部 渲染自检）
scripts/lighting_rig.gd（房间 / 城市 光照与环境）
tools/fix_hair_skin.py（头发头皮权重修正，已烘进 GLB）
shaders/organ.gdshader, skin_xray*.gdshader, *.gdshaderinc, fx_ring.gdshader
assets/organs/organs_mesh.bin（gzip，2.8MB）+ organs_meta.json + 4×JPG
tools/bake_organs.py
scenes/ui/hud.tscn
scenes/maps/room_mirror.tscn
assets/characters/tifa/Tifa_Web_Skinned.glb
assets/characters/tifa/loco-clips.json
assets/maps/room.glb
assets/maps/city.glb
tools/bake_tifa_skinned.py
```

`.godot/` 已被 `.gitignore` 忽略，请勿提交导入缓存。

## 已知限制

- 城市首次进入会为大量网格生成 trimesh，加载稍慢；树叶无碰撞。城市里走/跑速度与房间相同（网页城市里是 5.8× / 11×，未移植）。
- 蠕动参数不保存（项目目前所有设置都不持久化）。
- 动画为关键帧程序化驱动；已移植头发 Verlet / 眨眼 / 呼吸、腹部透视与脏器（拖拽 / 打击 / 蠕动）。拳头、刺刀、肚脐互动和网页的肠道血量变色、彭腹仍未移植。
- 脏器网格是运行时从 `assets/organs/organs_mesh.bin` 读取的（非 Godot 资源）。导出预设的「要导出的非资源文件」已包含 `assets/organs/*.bin, assets/organs/*.json`，否则安卓包里没有内脏数据。重新烘焙：`/workspace/tools/blender/blender --background --python tools/bake_organs.py`。
- 第一人称低头时胸部会挡住大部分腹部，透视效果在镜子里或第三人称更容易看到。
- 网页的腹部软笼没有完整移植：拖拽 / 打击在着色器里做顶点位移（皮肤 + 脏器），法线不重算。
- 下蹲为**切换** Ctrl/C（0.7s 过渡）；匍匐为 Z 切换；圆柱碰撞体近似网页（站 1.64 / 蹲 0.94 / 匍 0.42），底边贴地。
- 游玩模式：启动为展示互动（观察视角，光标常显）；Tab / HUD 切换。展示锁定移动并注视相机；控制为第一人称可移动。滚轮：观察视角改距离，FP 改 FOV。观察相机碰撞在城市地图只用球体扫掠（没有墙盒）。
- 乳摇只驱动 a_Phy 一根骨（模型里 b_Phy 没有蒙皮权重），所以是整体平移 + 摆动，不是网页那种逐顶点软体形变。
- 房间镜子为 SubViewport 实时平面镜（镜子 SubViewport 关闭物理插值，否则移动时镜像滞后一帧）：只渲染屏幕上可见的镜面区域，分辨率按屏幕像素密度自适应（上限 2048）；相机在镜后或镜子不在视野内时停止渲染，城市地图下隐藏。渲染自检：`xvfb-run -a godot --path . -s res://scripts/tests/mirror_check.gd`（截图输出到 user://mirror_check，或用环境变量 MIRROR_CHECK_OUT 指定）。
- 房间部分材质的法线贴图 UV 与基础色不一致时，Godot 会忽略法线 UV（引擎限制，有警告）。
- 城市 GLB 已从网页版 meshopt 解压；若从网页重新拷贝 `city.glb`，需再跑解压脚本后再导入。
- 弹道与毁伤：第一层已可用（创口、通道、冲击、肠道/子宫发红），完整的内脏状态机、出血和永久空腔见 `docs/wound_system_plan.md`，本轮未做断肢或血液流体。特写是电影速度跟随，不是按真实 800 m/s 放慢到能看清的物理时间。
- 武器：素材手臂比我们角色前伸，视模型按武器缩放（`view_scale` 0.8）并后移，左手够不到时沿枪管往回滑、允许肩胛前伸和手臂最多拉长 18%，所以握把位置和素材不完全一致；冲锋枪左手是素材的托举姿势。素材没有空仓换弹动画（空仓换弹 = 换弹动画放慢 1.3×，手枪有空仓挂机）、没有音效、没有狙击枪 / 近战。弹道只是射线 + 调试弹孔，伤害未接入。

