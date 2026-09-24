"""
Bake tifa.glb + nude-rig-data.json → Tifa_Web_Skinned.glb for Godot.
Mirrors web fitStanding(1.66) in Blender Z-up, then glTF Y-up export.
"""
import bpy
import json
import math
import os
from mathutils import Vector, Matrix

WEB = "/workspace/rouchangmoniqi3"
OUT = "/workspace/rouchang-godot/assets/characters/tifa/Tifa_Web_Skinned.glb"
TARGET_H = 1.66
RIG_PATH = f"{WEB}/src/lib/softbody/nude-rig-data.json"
SRC = f"{WEB}/public/models/tifa.glb"


def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def scene_aabb(objects):
    pts = []
    for o in objects:
        if o.type != "MESH":
            continue
        for c in o.bound_box:
            pts.append(o.matrix_world @ Vector(c))
    if not pts:
        return None, None, None
    mn = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    mx = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return mn, mx, mx - mn


def mesh_mat_key(obj):
    if obj.type != "MESH" or not obj.data.materials:
        return (obj.name or "").lower()
    mat = obj.data.materials[0]
    return ((mat.name if mat else obj.name) or "").lower()


def three_to_blender(v):
    return Vector((v[0], -v[2], v[1]))


def find_map(maps, key, count):
    direct = maps.get(f"{key}:{count}")
    if direct and direct["count"] == count:
        return f"{key}:{count}", direct
    for k, rec in maps.items():
        if rec["count"] == count:
            return k, rec
    return None, None


def main():
    clear_scene()
    bpy.ops.import_scene.gltf(filepath=SRC)
    for o in list(bpy.data.objects):
        if o.type == "MESH" and ("Ico" in o.name or o.name == "Cube"):
            bpy.data.objects.remove(o, do_unlink=True)

    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    print("imported", [(m.name, len(m.data.vertices)) for m in meshes])

    root = bpy.data.objects.new("FitRoot", None)
    bpy.context.scene.collection.objects.link(root)
    for m in meshes:
        mw = m.matrix_world.copy()
        m.parent = root
        m.matrix_world = mw

    bpy.context.view_layer.update()
    mn, mx, size = scene_aabb(meshes)
    center = (mn + mx) * 0.5
    print("pre-fit", list(size))

    # Mirror Three fitStanding with Blender axis map: Ty<->Bz, Tz<->-By
    if size.y > size.x * 1.2:
        face_plus_x = center.x < 0.2
        root.rotation_euler[2] += (-math.pi / 2 if face_plus_x else math.pi / 2)
        bpy.context.view_layer.update()
        mn, mx, size = scene_aabb(meshes)
        center = (mn + mx) * 0.5
        print("after yaw", list(size))

    if size.y > size.z * 1.25:
        root.rotation_euler[0] += -math.pi / 2
        bpy.context.view_layer.update()
        mn, mx, size = scene_aabb(meshes)
        center = (mn + mx) * 0.5
        print("after pitch", list(size))

    s = TARGET_H / max(size.z, 0.001)
    root.scale = Vector((s, s, s))
    bpy.context.view_layer.update()
    mn, mx, size = scene_aabb(meshes)
    center = (mn + mx) * 0.5
    root.location.x -= center.x
    root.location.y -= center.y
    root.location.z -= mn.z
    bpy.context.view_layer.update()
    mn, mx, size = scene_aabb(meshes)
    print("fitted", list(mn), list(mx), "h", size.z)

    # Unparent + bake world into mesh data (avoid double transform)
    for m in meshes:
        mw = m.matrix_world.copy()
        m.parent = None
        m.matrix_world = mw
    bpy.context.view_layer.update()

    for m in meshes:
        mw = m.matrix_world.copy()
        m.data.transform(mw)
        m.matrix_world = Matrix.Identity(4)
        m.location = (0, 0, 0)
        m.rotation_euler = (0, 0, 0)
        m.scale = (1, 1, 1)
    bpy.context.view_layer.update()

    if root.name in bpy.data.objects:
        bpy.data.objects.remove(root, do_unlink=True)

    mn, mx, size = scene_aabb(meshes)
    print("flattened", list(mn), list(mx), "h", size.z)

    # Expected: width~1m (x), depth~0.35 (y), height 1.66 (z)
    # If hair spans X more, OK.

    rig = json.load(open(RIG_PATH))
    arm_data = bpy.data.armatures.new("TifaSoftRigData")
    arm_obj = bpy.data.objects.new("TifaSoftRig", arm_data)
    bpy.context.scene.collection.objects.link(arm_obj)
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode="EDIT")

    edit_bones = {}
    for bdef in rig["bones"]:
        eb = arm_data.edit_bones.new(bdef["name"])
        head = three_to_blender((bdef["x"], bdef["y"], bdef["z"]))
        eb.head = head
        eb.tail = head + Vector((0, 0, 0.03))
        edit_bones[bdef["name"]] = eb

    for bdef in rig["bones"]:
        if bdef["parent"] and bdef["parent"] in edit_bones:
            edit_bones[bdef["name"]].parent = edit_bones[bdef["parent"]]

    children = {b["name"]: [] for b in rig["bones"]}
    for b in rig["bones"]:
        if b["parent"]:
            children[b["parent"]].append(b["name"])
    for bdef in rig["bones"]:
        eb = edit_bones[bdef["name"]]
        kids = children[bdef["name"]]
        if kids:
            child_head = edit_bones[kids[0]].head
            if (child_head - eb.head).length > 1e-4:
                eb.tail = child_head
            else:
                eb.tail = eb.head + Vector((0, 0, 0.02))
        else:
            if eb.parent:
                direction = eb.head - eb.parent.head
                if direction.length > 1e-6:
                    direction.normalize()
                else:
                    direction = Vector((0, 0, 1))
                eb.tail = eb.head + direction * 0.025
            else:
                eb.tail = eb.head + Vector((0, 0, 0.05))

    bpy.ops.object.mode_set(mode="OBJECT")
    print("bones", len(arm_data.bones))

    bone_names = [b["name"] for b in rig["bones"]]
    maps = rig["maps"]

    for mesh in meshes:
        key = mesh_mat_key(mesh)
        n = len(mesh.data.vertices)
        mk, rec = find_map(maps, key, n)
        if not rec:
            print("NO MAP", mesh.name, key, n)
            continue
        print("skin", mesh.name, "map", mk)

        for bname in bone_names:
            if bname not in mesh.vertex_groups:
                mesh.vertex_groups.new(name=bname)

        # Clear weights
        for vg in list(mesh.vertex_groups):
            try:
                vg.remove(range(n))
            except RuntimeError:
                pass

        idx = rec["index"]
        wts = rec["weight"]
        for vi in range(n):
            # gather & normalize
            infl = []
            for k in range(4):
                bi = idx[vi * 4 + k]
                w = float(wts[vi * 4 + k])
                if w > 0 and 0 <= bi < len(bone_names):
                    infl.append((bi, w))
            ssum = sum(w for _, w in infl)
            if ssum <= 1e-8:
                mesh.vertex_groups[bone_names[0]].add([vi], 1.0, "REPLACE")
                continue
            for bi, w in infl:
                mesh.vertex_groups[bone_names[bi]].add([vi], w / ssum, "REPLACE")

        mesh.parent = arm_obj
        mesh.parent_type = "OBJECT"
        # Keep mesh world transform (identity) under armature at origin
        mesh.matrix_parent_inverse = arm_obj.matrix_world.inverted()
        # Remove old armature mods
        for mod in list(mesh.modifiers):
            if mod.type == "ARMATURE":
                mesh.modifiers.remove(mod)
        mod = mesh.modifiers.new(name="Armature", type="ARMATURE")
        mod.object = arm_obj
        mod.use_vertex_groups = True
        mod.use_deform_preserve_volume = False

    bpy.context.view_layer.update()
    mn, mx, size = scene_aabb(meshes)
    print("pre-export AABB", list(mn), list(mx), "h", size.z)
    hip = arm_obj.data.bones["C_Hip_a"]
    foot = arm_obj.data.bones["L_Foot_a"]
    print("hip", list(arm_obj.matrix_world @ hip.head_local))
    print("foot", list(arm_obj.matrix_world @ foot.head_local))

    # depsgraph evaluate to get skinned AABB
    depsgraph = bpy.context.evaluated_depsgraph_get()
    pts = []
    for mesh in meshes:
        ev = mesh.evaluated_get(depsgraph)
        me = ev.to_mesh()
        for v in me.vertices:
            pts.append(ev.matrix_world @ v.co)
        ev.to_mesh_clear()
    if pts:
        mn = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
        mx = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
        print("SKINNED AABB", list(mn), list(mx), "h", (mx - mn).z)
        # feet near 0?
        print("feet_z", mn.z, "head_z", mx.z)

    bpy.ops.object.select_all(action="DESELECT")
    for o in bpy.data.objects:
        o.select_set(True)
    bpy.ops.export_scene.gltf(
        filepath=OUT,
        export_format="GLB",
        use_selection=True,
        export_skins=True,
        export_morph=False,
        export_animations=False,
        export_apply=False,
        export_yup=True,
    )
    print("OK", OUT, os.path.getsize(OUT))


if __name__ == "__main__":
    main()
