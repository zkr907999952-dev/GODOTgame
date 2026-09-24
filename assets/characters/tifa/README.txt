Tifa（网页 soft-rig 烘培）
========================
来源: github.com/zkr907999952-dev/rouchangmoniqi3
  - public/models/tifa.glb
  - src/lib/softbody/nude-rig-data.json (185 bones, 4 weights/vert)

烘培步骤（tools/bake_tifa_skinned.py）:
  1. 按网页 figure.tsx 的 fitStanding(1.66) 校正朝向/缩放，脚底贴 y=0
  2. 将 JSON 骨骼写入 Armature（Three Y-up → Blender Z-up → glTF Y-up）
  3. 按 nude-rig-data 顶点权重绑定 Skin
  4. 导出 Tifa_Web_Skinned.glb

输出: Tifa_Web_Skinned.glb
  - 7 meshes + 185 joints + Skin
  - 站立高度约 1.66m，脚底近原点
