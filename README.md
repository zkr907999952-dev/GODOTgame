# 肉场模拟器 / GODOTgame

Godot **4.7.2** 项目（Forward Plus）。角色与地图来自网页原型 [rouchangmoniqi3](https://github.com/zkr907999952-dev/rouchangmoniqi3)。

## 环境

- **引擎**: Godot **4.7.2.stable**
- **仓库**: https://github.com/zkr907999952-dev/GODOTgame
- **主场景**: `scenes/main.tscn`

## 操作

| 按键 | 作用 |
|------|------|
| W A S D / 方向键 | 移动 |
| Shift | 冲刺（仅站立；速度 ≈ 走速×2.5，run* 动画） |
| 空格 | 跳跃（匍匐时改为站起） |
| Ctrl / C | **按住**下蹲（松开关站立；匍匐中无效） |
| Z | 切换匍匐（Ctrl+Z 亦可） |
| 1–8 | 预览舞蹈片段 dance1…dance8 |
| 0 / 9 | 取消舞蹈，回到普通移动动画 |
| 鼠标 | 环视（自动捕获） |
| 滚轮 | 第三人称：拉近/推远距离（1.2–6）；第一人称：FOV（50–90）；HUD 面板打开时忽略 |
| Esc | 关闭 HUD 面板，或释放 / 重新捕获鼠标 |
| **Tab** | **切换游玩模式**：展示互动 ↔ 角色控制 |
| M | 房间 ↔ 城市 切换 |
| HUD「设置」 | 左上角：呼吸 / 眨眼 / 头发物理、鼠标灵敏度 |
| HUD「互动」 | 右侧：拖拽 / 打击 / 拳头 / 刺刀 / 肚脐（模式占位） |
| HUD「摄像机」 | 重置视角、**游玩模式切换**、灵敏度 |

### 游玩模式

| 模式 | 默认 | 相机 | 移动 | 注视 |
|------|------|------|------|------|
| **展示互动** (Display) | ✅ 启动默认 | 第三人称环绕 | 锁定（忽略 WASD） | 头+眼看向相机 |
| **角色控制** (Control) | Tab 切换 | 第一人称 | WASD / 蹲 / 匍 / 冲刺 | 颈头跟随相机（现有 FP） |

从控制切回展示时，环绕轴强制对准角色**当前位置**（CameraPivot 跟随角色），并重新显示头/发/眼网格以便注视。摄像机面板按钮与 Tab 等价。

默认出生在**房间**；按 `M` 传送到城市出生点附近。房间 **+Z 空墙**有一面镜子（SubViewport 镜像相机 → ViewportTexture），便于展示模式下观察自身。

## 界面（HUD）

`scenes/ui/hud.tscn` + `scripts/hud.gd`，挂在主场景 CanvasLayer：

- **设置（左上）**：开关 `SoftSecondary` 的呼吸 / 眨眼 / 头发物理；鼠标灵敏度滑条；面板说明显隐。打开面板时释放鼠标便于点击。
- **互动（右侧）**：五种模式按钮，写入 HUD 内部状态并显示「当前模式」文案。软体拖拽/打击等尚未接入，仅占位。
- **摄像机**：重置视角；**游玩模式**（展示互动 / 角色控制，等同 Tab）；灵敏度（与设置共用）。**展示**：第三人称、锁移动、头+眼 `set_gaze_target` 看向相机，头/发/眼可见。**控制**：第一人称；身体 yaw 跟相机；颈/头 `setBodyLook`；隐藏头/发/眼/嘴防裁切；眼高网页 `stanceEye`（站 1.52 / 蹲 1.06 / 匍 0.3）；近裁剪 ≈0.06；滚轮调 FOV。

## 动画（网页 loco-clips）

角色蒙皮骨架由 `SoftLoco`（`scripts/soft_loco.gd`）每帧驱动，**不依赖 Mixamo FBX**：

- 数据：`assets/characters/tifa/loco-clips.json`（与网页 `src/lib/softbody/loco-clips.json` 同源，26 段）
- 选取逻辑对齐网页 `soft-skeleton.ts` 的 `pickLocoClip` / `applyLocomotion`：站立 idle / 走跑八向、下蹲、匍匐、跳跃；Shift（站立）切 run*；走速 ≈1.65 m/s，冲刺 ×2.5，蹲/匍更慢
- `standIdle`：`STAND_IDLE_MOTION=0.18`、`idle_slow=2.4`，并调用 `nudgeIdleUpright` + **`nudgeIdleArmsBack`**（上臂略向身后 z-0.22，与网页一致）
- 碰撞胶囊底与网格脚底对齐（AABB min.y≈0，胶囊 bottom≈0），避免脚陷入地面
- **朝向**：网页 loco 绑定 mesh 朝 **+Z**，Godot 移动以 **-Z** 为前；`$Body` 施加 **π yaw 偏移**（`BODY_YAW_OFFSET`），使胸部朝向移动/相机前方。偏移后 loco 的 fwd/side 相对 Body **+Z** 取符号（相对旧逻辑取反）
- 采样：欧拉 XYZ（loco）或四元数 slerp（dance）；姿态为角色空间 child-from-parent，经 rest 共轭后写入 `Skeleton3D.set_bone_pose_rotation` / `position`（含 hipY）
- 次级动画 `SoftSecondary`（`scripts/soft_secondary.gd`，默认全开，对齐网页）：
  - **头发 Verlet**：`group=="hair"` 链（HairRoot…Hair_8）；**k≤1（HairRoot+Hair_1）钉在骨架 FK**，仅下段 Verlet 摆动（对齐网页 `pinned = k <= 1`）
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
- 动画为关键帧程序化驱动；已移植头发 Verlet / 眨眼 / 呼吸。软体脏器、刺刀等互动仍为 HUD 占位。
- 下蹲为**按住** Ctrl/C；匍匐为 Z 切换；胶囊近似网页（站 1.64 / 蹲 0.94 / 匍 0.42），底边仍贴地。
- 游玩模式：启动为展示互动；Tab / HUD 切换。展示锁定移动并注视相机；控制为第一人称可移动。滚轮：TP 改距离，FP 改 FOV。
- 房间镜子为 SubViewport 实时镜像（约 768²），非物理反射探针；质量受分辨率与单向面限制，城市地图下隐藏。
- 房间部分材质的法线贴图 UV 与基础色不一致时，Godot 会忽略法线 UV（引擎限制，有警告）。
- 城市 GLB 已从网页版 meshopt 解压；若从网页重新拷贝 `city.glb`，需再跑解压脚本后再导入。
