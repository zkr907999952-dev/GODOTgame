# 触屏操作 / 手机布局 / 肚脐互动

## 触屏（移植自网页 `figure.tsx` 触摸处理 + `overlay.tsx` 摇杆 / 按钮）

`scripts/ui/touch_controls.gd`（HUD 子节点，全屏、`mouse_filter=IGNORE`，只吃 `InputEventScreenTouch/Drag`）。
每根手指独立记录角色：`ui / btn:<id> / stick / look / zoom / tool / orbit / two`，任意多指同时操作互不干扰。

| | 网页 | Godot |
|---|---|---|
| 观察·单指点身体 | 当前工具（打击 / 拖拽 / 拳交 / 刺刀 / 肚脐） | 同（`player.touch_tool_begin/drag/end`，与鼠标左键同一路径） |
| 观察·双击后拖动 | 环绕（TAP_MS 340 / TAP_PX 38） | 同 |
| 观察·单指在空白处拖 | 无操作 | **扩展**：环绕（手机上更顺手） |
| 观察·双指 | 平移 + 捏合缩放（第二指取消工具） | 同 |
| 控制·左下摇杆 | 128px，半径 0.32·size，死区 0.15，外圈 ≥0.72 奔跑 | 同（`touch_move / touch_sprint`） |
| 控制·其余区域拖动 | 转视角，灵敏度 0.00305·0.9 | 同（`touch_look`） |
| 控制·按钮 | 互动（屏幕中心射线，按住时视线移动=拖工具）/ 下蹲（长按 500ms 匍匐）/ 跳跃 | 同 |
| 控制·左侧竖条 | 视野缩放 | 同（FOV） |
| 「切换·观察/控制」 | 顶部按钮 | 同（放在顶栏与提示下方） |

- 触屏模式在 Android/iOS 或 `DisplayServer.is_touchscreen_available()` 时自动开启；设置面板「触屏操作（摇杆 / 手势）」可手动开关。PC 键鼠不变。
- `input_devices/pointing/emulate_mouse_from_touch=true`：GUI（按钮、滑条、滚动）靠模拟鼠标；游戏里触屏开启时忽略
  `device == DEVICE_ID_EMULATION` 的鼠标事件，所以一次点按只处理一次（测试：打击只产生 1 个波）。
- 手指落在 HUD 控件上 = `ui`，不触发场景手势。

## 手机界面布局（`hud.gd::_apply_layout`）

- `canvas_items` + `expand` 拉伸，基准 1280×720；手机上按 DPI/160 设置 `content_scale_size`（逻辑分辨率 ≈ 设备 pt）。
- 安全区 `DisplayServer.get_display_safe_area()`（刘海 / 底部条）。
- 触屏时按钮 / 开关最小 44px、滑条 32px（网页 h-11）。
- 竖屏手机（触屏且逻辑宽 < 640，网页 sm 断点）：设置 / 地图 / 摄像机 / 互动 面板变成**底部抽屉**（铺满宽度、最高半屏、内部滚动、「收起 ▾」把手）。
  横屏 / 平板 / PC 保持原布局（右上面板），高度不够时面板内滚动。
- 方向 `window/handheld/orientation=6`（sensor，网页是响应式布局，横竖屏都支持）；只想横屏改成 `4`（sensor landscape）。

## 渲染 / 导出

- `rendering_method.mobile="mobile"`，桌面仍 Forward+。Mobile 渲染器下所有着色器编译通过，唯一警告是皮肤次表面散射（SSS）只在 Forward+ 有效，自动退化为普通漫反射。
- `textures/vram_compression/import_etc2_astc=true`（安卓 / iOS 纹理格式）；首次导出时编辑器会补导入 ETC2/ASTC。
- `export_presets.cfg` 已提交：Android（arm64-v8a、`com.zkr907999952.rouchang`、沉浸模式）、iOS（arm64、iOS 14+）、Windows。**不含任何签名 / 密钥**：
  - Android：编辑器设置里填 Java SDK（JDK 17）+ Android SDK（platform-tools、build-tools 34+）；安装 4.7.2 导出模板；
    release 签名用 `GODOT_ANDROID_KEYSTORE_RELEASE_PATH / _USER / _PASSWORD` 环境变量（或编辑器里本地填，别提交）。
    debug keystore 编辑器会自动生成。
  - iOS：需要 macOS + Xcode，填 `application/app_store_team_id`、签名身份 / 描述文件后导出 Xcode 工程再归档。

## 肚脐互动（移植自网页 `navel-morph.ts` + `soft-skeleton.ts` 姿势 + `figure.tsx` 拖拽）

- 她用右手食指插入自己的肚脐。插入量 t（0..1）：0.5 指尖接触；`navelInsertMorph`：u=(t−0.5)/0.5，深度 0.06+u·r，直径 0.42+u·r·0.5。
- 皮肤着色器 `navel_offset()`（= `applyNavelMorph`）：杏仁形开口 hx/hy、凹陷深度 D、边缘挤压；肚脐凹陷 dent 随深度加深。
- 手臂姿势：网页 park / insert 两组欧拉角按 t 球面插值，躯干 C_Spine_a..d 回到静止（网页同），食指指向手势由网页 `initHandAxes` 计算后镜像到右手；搅动时前臂 / 手腕 / 食指附加小旋转。
- 互动面板「肚脐」：深度 / 撑开比例滑条、自动抽插（起点、速度）、搅动（半径、速度），呼吸随插入加重。
- 拖拽（鼠标或触屏，同网页）：在肚脐附近按下，过肚脐、法线 = UP×视线 的竖直平面上拖动，沿身体前后方向的位移 / 0.09 = 插入量变化。
  正对身体时这个平面几乎与视线平行（网页同样），斜一点视角拖动最顺；也可直接用深度滑条。
- 分身：点到分身就作用到分身（复制本体肚脐参数）。

## 测试

`godot --headless --path . -s res://scripts/tests/touch_navel_check.gd`：捏合、双指平移、点按打击（只 1 次）、拖拽工具、
空白处环绕、双击拖环绕、手机抽屉开 / 关（触摸 → 模拟鼠标点 HUD 按钮）、切换模式、摇杆+视角同时、下蹲 / 长按匍匐、跳跃、缩放条、
肚脐指尖位置（t=0 在肚脐前 5cm、t=1 进入 5cm）、形变公式、抽插往复、触屏拖插入、分身肚脐。
带窗口 + `SHOT_DIR` 时保存手机竖屏截图。软件渲染很慢时「双击」340ms 窗口可能超时，那一项属测试环境问题。
