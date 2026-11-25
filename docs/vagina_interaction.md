# 阴道互动模式

这是后续核心功能的底子。模式、镜头和工具栏先搭好，插入物继续走已有的 `VulvaInserter` / `VulvaParams`（见 `docs/vulva_module.md`）。

## 文件

| 路径 | 作用 |
|---|---|
| `scripts/interact/vagina_mode.gd` | 模式进入/退出、镜头预设、当前工具。Player 用 `get_vagina_mode()`。 |
| `scripts/interact/vagina_tool.gd` | 工具资源：id、显示名、图标、设置面板种类、插入物脚本。 |
| `scripts/interact/vagina_tool_registry.gd` | 数据工具表。新工具 `register()` 即可，不必改 HUD 布局逻辑。 |

## 怎么进出

检查床上（包括观察模式）可进。电脑按 **Y**，或点「阴道互动」。与手术模式互斥：进一个会退出另一个。退出后回到进入前的观察/控制视角。

进入时镜头自动飞到外阴附近，环绕中心在下体（阴道口到宫颈的中段），而不是肚脐。

## 镜头预设

轴线取自当前蒙皮后的阴道中线（`OrganRig.vagina_canal()`：外口 → `os_center`）。

- **自由视角**：以下体为中心环绕，右键旋转、中键平移、滚轮拉近，手机划屏同样可用。
- **阴道口视角**：相机在外口外侧，前向与阴道轴线一致，看向入口里面。
- **小腹视角**：相机在小腹一侧，前向与轴线垂直，看子宫、阴道和卵巢的整体。默认打开透视，方便隔着腹壁观察。

以后若要加「侧位」「宫颈特写」，在 `VaginaMode.set_camera_preset()` 里加一个预设名即可。

## 工具栏（扩展点）

工具是资源，不是写死在手术脚本里的 `if`。注册表默认包括：

- `speculum` — 阴道扩张器（从手术栏移入，插入/开合/取出行为不变，仍由 `SpeculumTool` 执行）
- `ball_rod` — 长柄金属球（本阶段占位，下一阶段实现）
- `reserved_2` / `reserved_3` — 预留空位

加新工具：做一份 `VaginaTool`（或在 `setup_defaults()` 里 `register()`），实现 `VulvaInserter`，需要的话加 `settings_kind` 和 HUD 里对应的设置条。模式脚本不用为每个道具写特殊分支。

## 自检

`scripts/tests/v0417_check.gd`：进入/退出（含观察模式）、与手术互斥、镜头飞到外阴、两个预设相对轴线的夹角、工具注册表、扩张器在阴道栏而不在手术栏、扩张器仍可插入。
