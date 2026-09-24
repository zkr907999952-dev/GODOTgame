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
| Shift | 冲刺 |
| 空格 | 跳跃 |
| 鼠标 | 第三人称环视（自动捕获） |
| Esc | 释放 / 重新捕获鼠标 |
| M | 房间 ↔ 城市 切换 |

默认出生在**房间**；按 `M` 传送到城市出生点附近。

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

导入本仓库时已用 Blender 脚本 `tools/bake_tifa_skinned.py` 烘成：

- `assets/characters/tifa/Tifa_Web_Skinned.glb`（约 15MB，Skin + 185 bones）
- 对齐网页 `fitStanding(1.66)`：脚底贴地、身高约 1.66m、骨骼与网格同一坐标系

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
scripts/map_collision.gd
scripts/game_root.gd
scripts/validate_headless.gd
assets/characters/tifa/Tifa_Web_Skinned.glb
assets/maps/room.glb
assets/maps/city.glb
tools/bake_tifa_skinned.py
```

`.godot/` 已被 `.gitignore` 忽略，请勿提交导入缓存。

## 已知限制

- 城市首次进入会为大量网格生成 trimesh，加载稍慢；树叶无碰撞。
- 角色目前为站立绑定姿态，尚无走路动画（移动时仅转向）。
- 房间部分材质的法线贴图 UV 与基础色不一致时，Godot 会忽略法线 UV（引擎限制，有警告）。
- 城市 GLB 已从网页版 meshopt 解压；若从网页重新拷贝 `city.glb`，需再跑解压脚本后再导入。
