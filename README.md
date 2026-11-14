# 肉场模拟器 / GODOTgame

Godot **4.7.2** 项目（Forward Plus）。角色与地图来自网页原型 [rouchangmoniqi3](https://github.com/zkr907999952-dev/rouchangmoniqi3)。

## 环境

- **引擎**: Godot **4.7.2.stable**
- **仓库**: https://github.com/zkr907999952-dev/GODOTgame
- **主场景**: `scenes/main.tscn`

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
| T | 循环互动模式（拖拽 / 打击 / 拳头 / 刺刀 / 肚脐） |
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
| 空格 | 跳跃（匍匐时改为站起） |
| Ctrl / C | **切换**下蹲（再按站起；匍匐中按一下先站起） |
| Z | 切换匍匐（Ctrl+Z 亦可） |
| 滚轮 | FOV（50–90） |
| 1–8 / 0 / 9 | 预览舞蹈 dance1…dance8 / 取消舞蹈 |
| 鼠标左键 | 腹部互动（以屏幕中心为准） |
| R | 复位视角 |

### 通用

| 按键 | 作用 |
|------|------|
| **Tab** | 切换 展示互动 ↔ 角色控制（切回观察时相机从眼位平滑飞出到正面） |
| M | 房间 ↔ 城市 |
| Esc | 关闭 HUD 面板 / 释放鼠标 |
| HUD「设置」 | 呼吸 / 眨眼 / 头发物理 / **乳摇物理**开关、**乳摇强度**滑条、鼠标灵敏度 |
| HUD「互动」 | 拖拽 / 打击 已接入脏器；拳头 / 刺刀 / 肚脐 仍为占位 |

### 腹部透视与体内脏器（移植自网页 figure.tsx）

- **脏器**：网页的大肠/小肠（`intestines.glb`）与盆腔包（子宫、膀胱、卵巢、输卵管、韧带；外阴已按网页删除）由 `tools/bake_organs.py` 按网页同款算法摆进腹腔，蒙皮到 `C_Hip_a` / `C_Spine_a..d`，随走、蹲、匍匐、呼吸一起动；肠管有网页同款**蠕动**。
- **透视**：只作用于腹前区域（肚脐上下 −0.205…+0.12m、左右约 ±0.12m、身体前侧），中心挖孔 + 半透明边缘过渡，强度 0–1（默认 0.38）。镜子、第一人称同样生效。
- **互动**（展示互动模式为主，角色控制模式也可用）：
  - **拖拽**：按住左键拖动腹壁，皮肤与肠/子宫一起被拉动（脏器跟随 0.82），松手弹簧回弹。
  - **打击**：点击腹部 → 环形冲击波 + 中心凹陷压到肠管上，约 1.7s 回弹，同时肠蠕动短时加快。
- **布局（Godot 版下调）**：网页原布局在这个角色上整体偏高（小肠团顶到乳房下缘）。现在小肠团中心在肚脐下约 4.6cm（范围约 0.88–1.16m，肚脐 1.06m），结肠肝曲/脾曲只抬 2.2cm；子宫 0.90–0.96m 位于耻骨后，膀胱在其前下方；全部顶点都在躯干皮肤内、透视窗口内（`validate_headless` 检查）。参数在 `tools/bake_organs.py` 顶部（`GUT_CENTER_DY` 等）。
- 细节见 `docs/organs_port_notes.md`。渲染自检：`xvfb-run -a godot --path . -s res://scripts/tests/organs_check.gd`（截图到 `user://organs_check` 或 `ORGANS_CHECK_OUT`）。

### 游玩模式

| 模式 | 默认 | 相机 | 移动 | 注视 |
|------|------|------|------|------|
| **展示互动** (Display) | ✅ 启动默认 | 第三人称环绕 | 锁定（忽略 WASD） | 头+眼看向相机 |
| **角色控制** (Control) | Tab 切换 | 第一人称 | WASD / 蹲 / 匍 / 冲刺 | 颈头跟随相机；身体 yaw 在静止时滞后约 ±60°（共约 120° 自由环视）再跟上 |

从控制切回展示时，环绕轴强制对准角色**当前位置**（CameraPivot 跟随角色），并重新显示头/发/眼网格以便注视。摄像机面板按钮与 Tab 等价。

默认出生在**房间**；按 `M` 传送到城市出生点附近。房间 **+Z 空墙**整面是镜子：镜中相机放在当前活动相机关于镜面的镜像位置、正对镜面，用**离轴视锥（PROJECTION_FRUSTUM，近裁面 = 镜面）**渲染，贴图与镜面 1:1 对应，视差/左右镜像天然正确；展示 TP / 控制 FP 均适用，FP 下镜中可见完整头脸（头部用渲染层 19 仅对主相机隐藏）。镜子背面透明（从墙外看得到房间）。

## 界面（HUD）

`scenes/ui/hud.tscn` + `scripts/hud.gd`，挂在主场景 CanvasLayer：

- **设置（左上）**：开关 `SoftSecondary` 的呼吸 / 眨眼 / 头发物理；鼠标灵敏度滑条；面板说明显隐。打开面板时释放鼠标便于点击。
- **互动（右侧）**：五种模式按钮，写入 `OrganRig.interact_mode`。拖拽 / 打击 已接入腹壁与脏器；拳头 / 刺刀 / 肚脐 仍占位。
- **摄像机**：重置视角；**透视**（腹部透视开关 / 腹部半透明滑条 / 显示脏器 / 肠蠕动）；**游玩模式**（展示互动 / 角色控制，等同 Tab）；灵敏度（与设置共用）。**展示**：第三人称、锁移动、头+眼 `set_gaze_target` 看向相机，头/发/眼可见。**控制**：第一人称；身体 yaw **不**瞬时跟相机（静止时约 ±60° 死区 / 共约 120° 自由看，移动时朝向移动方向）；颈/头 `setBodyLook`；隐藏头/发/眼/嘴防裁切；眼高网页 `stanceEye`（站 1.52 / 蹲 1.06 / 匍 0.3，蹲↔站 **0.7s** 过渡）；近裁剪 ≈0.06；俯仰 ≈±89°；滚轮调 FOV。

## 动画（网页 loco-clips）

角色蒙皮骨架由 `SoftLoco`（`scripts/soft_loco.gd`）每帧驱动，**不依赖 Mixamo FBX**：

- 数据：`assets/characters/tifa/loco-clips.json`（与网页 `src/lib/softbody/loco-clips.json` 同源，26 段）
- 选取逻辑对齐网页 `soft-skeleton.ts` 的 `pickLocoClip` / `applyLocomotion`：站立 idle / 走跑八向、下蹲、匍匐、跳跃；Shift（站立）切 run*；走速 ≈1.65 m/s，冲刺 ×2.5，蹲/匍更慢
- `standIdle`：`STAND_IDLE_MOTION=0.18`、`idle_slow=2.4`，并调用 `nudgeIdleUpright` + **`nudgeIdleArmsBack`**（上臂略向身后 z-0.22，与网页一致）
- 碰撞胶囊底与网格脚底对齐（AABB min.y≈0，胶囊 bottom≈0），避免脚陷入地面
- **朝向**：网页 loco 绑定 mesh 朝 **+Z**，Godot 移动以 **-Z** 为前；`$Body` 施加 **π yaw 偏移**（`BODY_YAW_OFFSET`），使胸部朝向移动/相机前方。偏移后 loco 的 fwd/side 相对 Body **+Z** 取符号（相对旧逻辑取反）
- 采样：欧拉 XYZ（loco）或四元数 slerp（dance）；姿态为角色空间 child-from-parent，经 rest 共轭后写入 `Skeleton3D.set_bone_pose_rotation` / `position`（含 hipY）
- 次级动画 `SoftSecondary`（`scripts/soft_secondary.gd`，默认全开，对齐网页）：
  - **头发 Verlet**：`group=="hair"` 链（HairRoot…Hair_8）；**k≤1（HairRoot+Hair_1）钉在骨架 FK**，仅下段 Verlet 摆动（对齐网页 `pinned = k <= 1`），根部发段的形状回复力更强（发梢更软）
  - **头发蒙皮（头皮固定）**：网页运行时 `reskinHair` 会把头顶/刘海/贴头皮的发片全部改绑到头骨，只有垂下的发尾按高度插值到 Hair_2..8。Godot 版之前直接用了原始权重，头顶顶点也带 0.2–0.5 的 Hair_2+ 权重，所以甩发时头顶跟着动。`tools/fix_hair_skin.py` 已把这一步烘进 `Tifa_Web_Skinned.glb`：按高度（冠部以上=0）× 离头皮距离（<8mm=0，>35mm=1）× 前额区，平滑过渡；约 82% 的头发顶点完全刚性跟头，`validate_headless` 检查甩发时头顶顶点相对头骨位移 = 0。
  - **头发渲染**（`scripts/character_look.gd`）：原材质是「alpha 混合 + 深度预通道」，同一网格里的发片无法排序，看起来发灰、透出头皮。改为 alpha scissor 0.38（网页 alphaTest）+ alpha-to-coverage（项目开启 MSAA 2×）实心主通道 + 半透明边缘第二通道；头皮在头发覆盖区域用 `scalp_mask.png` 细节遮罩染成发根色，缝隙里不会再透肤色。
  - **乳摇物理**（`scripts/breast_physics.gd`）：每侧一个世界空间质点弹簧-阻尼（竖直 2.1Hz / 水平 2.6Hz，阻尼比 0.16，240Hz 固定子步）+ 一个 4.8Hz 乳尖二级弹簧；锚点随 C_Spine_d 运动，所以走、跑、跳（失重上浮 / 落地下坠）、急停、转身、蹲起都会自然驱动；位移写到 `L/R_Breast_a_Phy`（带权重的骨），乳尖滞后转成绕乳房中心的小角度摆动；椭球软限幅防穿模；左右频率差 6% 产生自然相位差。HUD「设置」里可开关、调强度。
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
| `scenes/maps/room.tscn` / `city.tscn` | 运行时对 MeshInstance3D 调用 `create_trimesh_collision()` 生成精细凹多边形碰撞；城市会跳过树叶等装饰网格 |

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
scripts/map_collision.gd
scripts/game_root.gd
scripts/hud.gd
scripts/validate_headless.gd
scripts/room_mirror.gd
scripts/organs/organ_rig.gd
scripts/breast_physics.gd（乳摇弹簧）
scripts/character_look.gd（头发 / 头皮材质）
scripts/tests/fix_check.gd（内脏 / 头发 / 相机 / 乳摇 渲染自检）
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

- 城市首次进入会为大量网格生成 trimesh，加载稍慢；树叶无碰撞。
- 动画为关键帧程序化驱动；已移植头发 Verlet / 眨眼 / 呼吸、腹部透视与脏器（拖拽 / 打击 / 蠕动）。拳头、刺刀、肚脐互动和网页的肠道血量变色、彭腹仍未移植。
- 脏器网格是运行时从 `assets/organs/organs_mesh.bin` 读取的（非 Godot 资源）。若以后导出游戏，需要在导出预设的「要导出的非资源文件」里加 `assets/organs/*.bin, assets/organs/*.json`。重新烘焙：`/workspace/tools/blender/blender --background --python tools/bake_organs.py`。
- 第一人称低头时胸部会挡住大部分腹部，透视效果在镜子里或第三人称更容易看到。
- 网页的腹部软笼没有完整移植：拖拽 / 打击在着色器里做顶点位移（皮肤 + 脏器），法线不重算。
- 下蹲为**切换** Ctrl/C（0.7s 过渡）；匍匐为 Z 切换；胶囊近似网页（站 1.64 / 蹲 0.94 / 匍 0.42），底边仍贴地。
- 游玩模式：启动为展示互动（观察视角，光标常显）；Tab / HUD 切换。展示锁定移动并注视相机；控制为第一人称可移动。滚轮：观察视角改距离，FP 改 FOV。观察相机碰撞在城市地图只用球体扫掠（没有墙盒）。
- 乳摇只驱动 a_Phy 一根骨（模型里 b_Phy 没有蒙皮权重），所以是整体平移 + 摆动，不是网页那种逐顶点软体形变。
- 房间镜子为 SubViewport 实时平面镜：只渲染屏幕上可见的镜面区域，分辨率按屏幕像素密度自适应（上限 2048）；相机在镜后或镜子不在视野内时停止渲染，城市地图下隐藏。渲染自检：`xvfb-run -a godot --path . -s res://scripts/tests/mirror_check.gd`（截图输出到 user://mirror_check，或用环境变量 MIRROR_CHECK_OUT 指定）。
- 房间部分材质的法线贴图 UV 与基础色不一致时，Godot 会忽略法线 UV（引擎限制，有警告）。
- 城市 GLB 已从网页版 meshopt 解压；若从网页重新拷贝 `city.glb`，需再跑解压脚本后再导入。
