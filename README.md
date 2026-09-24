# 肉场模拟器 / GODOTgame

Godot **4.7.2** 项目（Forward Plus）。角色资源来自网页原型 [rouchangmoniqi3](https://github.com/zkr907999952-dev/rouchangmoniqi3)，体积小、骨骼与蒙皮已在网页端验证可用。

## 环境

- **引擎**: Godot **4.7.2.stable**
- **仓库**: https://github.com/zkr907999952-dev/GODOTgame
- **主场景**: `scenes/main.tscn`

## 角色来源（重要）

| 来源文件（网页项目） | 用途 |
|------|------|
| `public/models/tifa.glb`（约 16MB） | 角色网格 + 贴图（无骨架） |
| `src/lib/softbody/nude-rig-data.json` | 185 根软骨骼 + 每网格 4 影响权重 |

导入本仓库时已用 Blender 将上述网格与权重烘成：

- `assets/characters/tifa/Tifa_Web_Skinned.glb`（约 17MB，含 Skin + 185 bones）
- `assets/characters/tifa/soft_rig_bones.json`（骨骼名/父子关系清单）

**已删除的大体积资源**：原 `tifa_nude/`（FBX+4K TGA，约 650MB+）与 `tifa_clothed/`（约 125MB glb/旁路贴图）。骨架以网页端 soft-rig 为准，不再保留服装物理残留骨。

## 本地打开

1. 安装 [Godot 4.7.2](https://godotengine.org/download/)
2. `git pull origin main`
3. 打开 `project.godot`（首次导入约十几 MB 角色）
4. F5 运行

## 项目结构

```
project.godot
scenes/main.tscn
scenes/characters/tifa.tscn
scripts/tifa_character.gd
assets/characters/tifa/Tifa_Web_Skinned.glb
assets/characters/tifa/soft_rig_bones.json
icon.svg
```

`.godot/` 已被 `.gitignore` 忽略，请勿提交导入缓存。
