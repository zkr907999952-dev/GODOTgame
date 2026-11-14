# 腹壁透视 + 体内脏器 移植笔记（网页 rouchangmoniqi3 → Godot）

## 网页是怎么做的

| 部分 | 网页实现（文件） |
|------|------------------|
| 资源 | `public/models/intestines.glb`（15.6MB，Sketchfab 大肠 Tjocktarm×2 + 小肠 Tunntarm，带 2K/4K 贴图+法线）、`public/models/pelvis.glb`（0.76MB，子宫/膀胱/卵巢/输卵管/韧带/阴道/外阴，纯色材质） |
| 摆放 | `figure.tsx`：`findNavel` 在躯干网格上找肚脐 → `sampleBand` 得腹腔盒（宽 ±0.11–0.13，深 skinZ-0.1…skinZ-0.012）→ `placeGuts`（缩放 s,s,1.2s 塞进 navel-0.16…navel+0.22，再 `liftColonFlexures` / `fitGutEnvelope` 按躯干截面收窄 / `balanceLowerGuts` / `tuckColonSides` / `centerGutsInCavity`）；`placePelvisPack` 去掉外阴，子宫缩放到高 5.8cm、顶在 navel.y-0.06，膀胱 ×0.7，`stubVagina` 把阴道收成短管；`liftGutsOffUterus` 把肠推离子宫 |
| 跟随身体 | 脏器顶点用 `SoftSkeleton.bind(..., "organs")` 绑定，仅允许 `/Spine|Hip/` 骨骼、软度 0.82，随走/蹲/匍匐/呼吸和软笼形变 |
| 透视 | `attachXray`：躯干材质（skin/dress）注入 `xrayHole()`——以「姿态后肚脐 + C_Spine_a 轴」为坐标系，`band(y0=-0.2,y1=+0.145) × torso(|x|<0.12) × front(z)` × `abdomenXray`。主材质 `hole>0.07` 时 discard（挖孔，且丢弃背面），另加一层透明 overlay：`alpha = mix(0.96,0.05,fade^0.72)`、颜色 ×mix(1,0.5,fade)。默认 `abdomenXray=0.38`，X 键 0/0.38 切换，摄像机面板有「透视开/关」按钮 + 「腹部半透明」滑条 0–1；另有「脏器」显示开关；腹内弱补光 `bellyLight`（#a07060） |
| 肠蠕动 | `peristalsis.ts`：对每根肠管做测地线距离得 `along`(0..1) 与径向向量 `rad`（≤2.2cm），每帧 `pos -= rad * pulse(along,t,amp,speed)`；默认 gutAmp 0.3 / gutSpeed 0.5，被打击后兴奋度 `gutExc` 提升幅度/速度 |
| 击腹（strike） | `belly-strike.ts`：点击腹部 `fireStrike(point)`，最多 4 个波，环形外扩 + 中心凹陷（crush 沿 -z），`rebound` 控制恢复；同时 `skeleton.impulse` 让软笼抖动、`gutHealth.hit` 掉血变色；屏幕上画一个外扩白环 |
| 拖拽（drag） | `skeleton.setTissueDrag(grab, target, 0.16)`：抓腹壁软笼，脏器因绑定软度 0.82 一起被带动，松手后弹簧回弹；鼠标在「过抓点、法线=相机前向」平面上取目标 |
| 拳头/刺刀/肚脐 | `fist-play.ts` / `bayonet-play.ts` / `navel-morph.ts`：沿大肠插入手臂、刺刀刺入+伤口、肚脐插入形变——依赖手臂/刺刀模型与大量专用逻辑 |

## Godot 移植了什么

- `tools/bake_organs.py`（Blender 4.2 + numpy）：**逐行移植上面的摆放函数**，在 `Tifa_Web_Skinned.glb`（已对齐网页 fitStanding 1.66）上找肚脐/截面，结果：navel ≈ (0, 1.060, 0.114)，子宫盒 y 0.941–1.000。肠模型焊接 UV 缝后减面到 ~3.5 万顶点；按网页算法烘 `along`/`rad`；蒙皮权重从最近的躯干皮肤顶点转移，只保留 `C_Hip_a`、`C_Spine_a..d`（对应网页 organs 绑定规则）。输出 gzip 二进制 `assets/organs/organs_mesh.bin`（2.8MB）+ 4 张 1024 JPG（共 ~250KB）+ `organs_meta.json`。
- `scripts/organs/organ_rig.gd`：运行时读包 → ArrayMesh（CUSTOM0 = along+rad）→ `MeshInstance3D` 挂在 Tifa `Skeleton3D` 下并复用身体 Skin 的同名 bind pose，所以随 SoftLoco 走/蹲/匍匐和 SoftSecondary 呼吸（脊柱缩放）一起动。
- 透视：躯干两块网格换成 `skin_xray.gdshader`（复刻导入的 StandardMaterial：albedo/ORM/normal + 挖孔）+ `next_pass` `skin_xray_fade.gdshader`（半透明覆盖层），参数与网页一致；坐标系每帧取 C_Spine_a 姿态 × 肚脐。镜子/第一人称用同一材质，所以表现一致。差异：网页丢弃躯干背面；这里透视时背面画成暗红腔壁，避免透过身体看到背景。
- 互动：拖拽（高斯衰减位移，皮肤 1.0、脏器 0.82；松手临界欠阻尼弹簧回弹）与击腹（BellyStrike 公式原样写进顶点着色器；肠 1.0，盆腔 0.4，皮肤在腹部遮罩内 0.55；白色外扩环；肠蠕动兴奋）。命中检测用腹部椭球（由躯干截面 profile 拟合，等价网页腹前隐形命中盒）。
- 未移植：GutHealth 掉血变色/血条、彭腹 inflate、拳头/刺刀/肚脐三种模式（HUD 仍为占位）。
