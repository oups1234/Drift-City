"""Décime chaque mesh d'un glTF avec Blender (appelé par tools/bake_car_models.gd).

Usage :
  Blender -b --factory-startup --python tools/blender_decimate.py -- IN.glb OUT.glb RATIO

Le Decimate « Collapse » de Blender respecte les coutures UV, contrairement à
la simplification de Godot (qui soude les sommets par position et mélange les
UV des modèles texturés comme la Skyline).
"""
import sys

import bpy

argv = sys.argv[sys.argv.index("--") + 1:]
src, dst, ratio = argv[0], argv[1], float(argv[2])
MIN_TRIS = 300

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)

before = after = 0
for obj in bpy.context.scene.objects:
    if obj.type != "MESH":
        continue
    tris = sum(len(p.vertices) - 2 for p in obj.data.polygons)
    before += tris
    if tris < MIN_TRIS:
        # Petites pièces : la décimation y ferait disparaître des surfaces.
        after += tris
        continue
    mod = obj.modifiers.new("Decimate", "DECIMATE")
    mod.decimate_type = "COLLAPSE"
    mod.ratio = ratio
    mod.use_collapse_triangulate = True
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=mod.name)
    after += sum(len(p.vertices) - 2 for p in obj.data.polygons)

bpy.ops.export_scene.gltf(
    filepath=dst,
    export_format="GLB",
    export_materials="PLACEHOLDER",
    export_normals=True,
    export_texcoords=True,
    export_apply=False,
)
print("BLENDER_DECIMATE %d -> %d triangles" % (before, after))
