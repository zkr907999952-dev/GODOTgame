# 武器模块

## 素材与许可
- **Kuptchi「PSX-Weapons Assets [Free Pack]」**，https://kuptchi.itch.io/f （RetroWeaponPack_V1）。
- 许可（包内 Readme.pdf + itch 页面）：个人 / 商业项目免费使用，不要求署名（作者希望注明），**不得转售素材本身**。致谢：Kuptchi。
- 仓库只提交转换后的游戏用资源（约 2.3 MB）：武器网格 `.scn`、Albedo 贴图（PSX 最近邻、无 mipmap、无损）、包内剪影图标（裁剪到 ≤256×128）、枪口火焰贴图、弹壳网格、烘焙后的手部动作数据。原始 FBX / .blend / 手臂网格不入库。
- 包里没有：狙击枪、近战武器、音效、准星 / HUD / 轮盘图形（这些由 Godot 绘制）。

## 武器（包里全部 4 把）
| id | 名称 | 类别 | 射击方式 | RPM | 弹匣 / 初始备弹（上限） | 其他 |
|---|---|---|---|---|---|---|
| pistol | 手枪 M1911（Pistol_01） | pistol | 半自动 | 450 | 8+1 / 40（96） | 空仓挂机动画 |
| rifle | 突击步枪 AR-15（Rifle_01） | rifle | 全自动 | 780 | 30+1 / 90（240） | |
| smg | 冲锋枪 Uzi（SMG_01，消音） | smg | 全自动 | 950 | 32+1 / 128（256） | 小枪口焰 |
| shotgun | 泵动霰弹枪 870（Shotgun_01） | shotgun | 泵动 | 70 | 6 / 30（60） | 8 弹丸，逐发装填，可扣扳机打断 |

定义是数据驱动的：每把武器 `assets/weapons/<id>/<id>.tres`（`WeaponDef`，`scripts/weapons/weapon_def.gd`）。`WeaponSystem.load_defs()` 自动扫描 `assets/weapons/*/` 下的 `.tres` 并按 `order` 排序，新增武器 = 新目录 + 网格 + 图标 + 手部动作 + `.tres`，不用改代码。
字段：射击方式 semi/auto/pump/melee（melee 预留挥砍）、rpm、mag_size、reserve_start/max、chamber_plus_one、pellets、damage、range_m、spread/bloom、recoil_pitch/yaw/recover、kick、draw/holster/reload/reload_empty 时间、shell_reload、muzzle/eject 位置、flash_scale、view_offset/view_scale、ads_fov、sfx_fire/reload/dry。

## 操作
| 输入 | 作用 |
|---|---|
| 1–9 | 选第 1–9 把（当前武器再按 = 收枪） |
| 滚轮（持枪） | 循环切换 |
| Q 按住 | 武器轮盘（每页 8 格，滚轮翻页；中心 = 收枪；松开 Q 选中） |
| HUD「武器」 | 武器菜单（按类别分组卡片，剪影图标 + 右下角 弹匣/备弹） |
| G | 收枪 / 取出上一把 |
| 左键 | 开火（半自动 / 泵动每次一发；全自动按住连发） |
| 右键 | 开镜 ADS |
| R | **持枪 = 换弹**；空手 = 复位视角（同一个键，按是否持枪区分） |
| 触屏 | 「武器」按住 → 轮盘，拖到格子松手；持枪时「开火」（按住，拖动同时转视角）、「换弹」 |

只在角色控制（第一人称）模式生效，展示模式下隐藏武器并恢复原来的左键互动。

## 弹药规则（参考常见 FPS）
- 战术换弹：保留弹匣余弹；弹匣非空时可多装 1 发进膛（+1）。例：30 发步枪 10/90 → 31/69。
- 空仓换弹：没有 +1，耗时更长（素材没有单独动画，用换弹动画放慢到 1.3×）。
- 空枪扣扳机：咔哒（`dry_fired` 信号），有备弹时自动换弹。
- 霰弹枪：开始 → 逐发 → 结束，装填中扣扳机在当前这发装完后结束。
- 右下角弹药 HUD：图标、名称、弹匣 / 备弹（低弹量变黄、空仓变红），状态（换弹中 / 取枪 / 按 R 换弹 / 没有备弹）。

## 效果
- 枪口火焰：包内 MuzzleFlash 贴图做加色公告板 + OmniLight，随机旋转 / 缩放，至少显示一个渲染帧（低帧率也能看到）。
- 后坐：相机俯仰 / 左右随机踢动，按 `recoil_recover` 指数回正；视模型后坐 + 抬枪；散布随连射扩散并恢复；ADS 减小散布和后坐。
- 抛壳：包内 9mm / 5.56 / 霰弹弹壳网格，简单抛物线，最多 16 个。
- 声音：素材没有音频，`WeaponDef.sfx_*` + `sfx(event, weapon_id)` 信号留作接入。

## 手：用我们自己角色的手
1. 离线烘焙（仓库外的探针工程）：逐帧播放素材手臂动画，把枪的位置朝向、左右手腕位置、手掌朝向（以「腕→中指根」和「食指根→小指根」构成的基）、肘部位置、15 个手指关节的几何弯曲角转换到 Godot 相机空间，存成 `<id>_arms.res`（30 fps）。手臂网格本身不导入。
2. 运行时（`weapon_system.gd`）：在 loco 动画写完骨骼之后，对角色的 `L_/R_ Shoulder_a / UpperArm_a / Forearm_a / Hand_a` 做两骨 IK，让手腕和手掌朝向对上烘焙目标；部分手腕扭转分给前臂；左手够不到时肩胛前伸、沿枪管往回滑、手臂最多拉长 18%。手指 `Index/Middle/Ring/Pinky/Thumb _a/_b/_c` 按「目标弯曲角 − 我们手指 rest 弯曲角」旋转。
3. 片段：idle / walk / run / aim / draw / hide / fire / fire_aim / reload（霰弹：reload_start / step / end），0.14 s 交叉淡化；枪本体的 Fire / Reload / 空仓挂机 / 泵动动画同步播放。
4. 收枪或切到展示模式时 IK 权重淡出，恢复 loco 姿势。

## 弹道（占位）
`ballistics.gd`：屏幕中心射线（排除玩家自己），`hit(position, normal, collider, weapon_id)` 信号 + 调试弹孔（最多 48 个）；每发（霰弹每颗弹丸）发出 `shot_fired(origin, dir, weapon_id)`。伤害 / 穿透 / 下坠留作后续。

## 自检
`godot --headless --path . -s res://scripts/tests/weapons_check.gd` → `weapons_check: fails=0`。覆盖：数据加载、展示模式隐藏、数字键 / 菜单 / Q 轮盘 / 循环 / 触屏轮盘选枪、半自动 1 秒 1 发、全自动 780 RPM 1 秒约 13 发、减弹、换弹算术（+1）、空仓换弹更慢、R 键换弹、空枪咔哒 + 自动换弹、霰弹 8 弹丸 + 逐发装填、枪口火焰开关、后坐回正、shot_fired 信号、触屏开火 / 换弹、G 收枪、IK 手腕误差。
加 `SHOT_DIR=<目录>` 且非 headless 运行时保存两张截图（第一人称持步枪、Q 轮盘）。
