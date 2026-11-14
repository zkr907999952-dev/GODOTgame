# 拳交 / 刺刀 / 长刺刀 与 分身：网页 → Godot 对照

网页源码：`rouchangmoniqi3/src/lib/softbody/fist-play.ts`、`bayonet-play.ts`、`gut-health.ts`、
`soft-skeleton.ts`（fistDepth 段）、`components/studio/figure.tsx`（setup / 每帧 / 指针）、`studio-store.ts`（默认值）。

## 坐标
网页工具都在「身体静止坐标」里工作；Godot 用 OrganRig 的 **ab-local**（原点 = 姿态后的肚脐，轴取 C_Spine_a），
等于「网页 rest 坐标 − 肚脐」，所以网页常数直接可用。网页 `findCrotch` / `findAnus` 在本模型上跑出的点写成常量
（`organ_rig.gd` CROTCH_REST / ANUS_REST）；结肠末端用网页 `pickColon` 的规则（along≥0.9 平均高度最低的肠管），
在解析 `organs_mesh.bin` 时算出 → 拳头进入方向。

## 拳交（网页 FistPlay）
| 网页 | Godot |
|---|---|
| `dragTo`（往里推=加深，横向=转向 ×0.28）、`clampPitch` 0.3–1.22、`clampLateral` 腰部截面 | `insert_tools.gd` `fist_drag_to` / `_clamp_pitch` / `_clamp_lateral`（截面用 organs_meta profile） |
| thrust / stir 自动抽插 / 搅动、arousal → 呼吸 | `fist_step`；arousal 写 SoftSecondary.breath_boost |
| `wallOver` → soft-skeleton 腹部鼓包（smoother 0.16·spread、front 遮罩、lean x/z、bulge/rise/lever） | `skin_common.gdshaderinc` `fist_offset`（GPU 顶点） |
| `deformColon` 杆（半径 0.018·(0.55+gut·0.7)，混合 0.9·gut） | `organ_common.gdshaderinc` `rod_offset`（rod 0，只作用于肠） |
| prepareArm（拳端顶部 8% → 原点，残端 −Y，0.38m，#c9947a） | `prop_meshes.gd` `arm_mesh` |
| 参数：鼓包 1.4 / 范围 1 / 肠道 1 / 杠杆 1 / 最大深度 1 / 抬升 0.7 / 速度… | HUD「拳交参数」 |

## 刺刀 / 长刺刀（网页 BayonetPlay + GutHealth）
| 网页 | Godot |
|---|---|
| 点腹部选入口（悬停 0.075m）、拖刀柄、30° 锥限制 | `blade_pick` / `blade_drag_to` / `_clamp_cone`；入口标记 = 红色圆环 |
| 刺入前压陷 squeezeTarget（0.07 → 0.055） | `dent` / `dent_offset`（皮肤 + 脏器） |
| rawPen ≥ 0.92·SQUEEZE_MAX 刺破 → 伤口贴花 + 冲击 + 肠道损伤 | `_puncture`：Decal（wounds.webp 2×2 图集，亮度 alpha + 径向渐隐）、无圆环冲击波、gut 兴奋 |
| 长刀刺穿背部 exit wound | `_try_exit_wound`（沿刀身在躯干截面里找出口） |
| auto（1.7/s 进，停 0.16s，1.5/s 出）、pump（0.16+0.8·波，2.35 rad/s） | `blade_step`；HUD「自动刺入」「连续抽插」 |
| deformGuts 杆（半径 0.016·(0.7+gut·0.55)，混合 0.88·gut，s_min −0.012） | `rod_offset`（rod 1） |
| GutHealth 变红 (1, 1−0.88h, 1−0.9h) | `organ.gdshader` `dmg[12]` 伤痕点 |
| 短 0.248m（刃 60%）/ 长 0.42m（刃 75%） | `prop_meshes.gd` `bayonet_mesh`（最长轴、稀疏端为刀尖、刃口转向 +Z） |

## 分身
- `scripts/clone_doll.gd`：同一 glb 实例（网格 / 贴图共享）+ CharacterLook + SoftLoco 待机（动画 JSON 静态缓存）
  + SoftSecondary（呼吸 / 眨眼 / 头发 / 胸部）+ 看向当前相机 + 独立 OrganRig（脏器网格静态缓存，只建材质）。
- `game_root.gd`：`spawn_clone()`（相机中心射线落点，打到墙退 0.35m，再向下找地面；面朝相机）、`clear_clones()`、
  上限 8（HUD 提示）；切换地图时清空。
- 互动：所有 OrganRig 在组 `organ_rigs`，`player_controller.pick_interact_rig` 选射线最先命中的角色；
  第一人称用准星射线，可以操作任何分身。显示 / 工具参数跟本体同步，形变 / 伤口 / 深度各自独立。R 全部复位。
- 镜子：分身在第 1 层，镜面相机自动反射。

## 自检
`scripts/tests/tools_clones_check.gd`（headless）：三种工具插入 / 刺破 / 伤口 / 复位、抬头时发梢与胸部间距、
3 个分身 + 第一人称点击分身 #2（只有 #2 受影响）、清除后无孤儿节点。设置 `SHOT_DIR` 并用 Forward+ 渲染时保存 2 张图。
