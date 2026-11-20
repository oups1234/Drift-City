class_name CarModel
extends RefCounted

## Construit le visuel d'une voiture à partir d'une entrée de CarCatalog.
## Le modèle est recentré, posé au sol, orienté nez vers -Z et redimensionné
## à la longueur demandée. Renvoie un Node3D avec la métadonnée "size".


## Version pré-cuite par tools/bake_car_models.gd (décimée, surfaces fusionnées).
const BAKED_DIR := "res://assets/cars/baked"


static func build(spec: Dictionary) -> Node3D:
	if not bool(spec.get("raw", false)):
		var baked := _load_baked(spec)
		if baked != null:
			return baked
	var root := Node3D.new()
	root.name = "CarModel"

	var path: String = spec.get("model", "")
	var res = load(path) if ResourceLoader.exists(path) else null
	if res == null:
		root.add_child(_fallback(spec))
		root.set_meta("size", Vector3(1.85, 1.35, 4.1))
		return root

	var bounds := AABB(spec.get("bounds_min", Vector3.ZERO), spec.get("bounds_size", Vector3(1.8, 1.3, 4)))
	var inner: Node3D

	if res is Mesh:
		var mi := MeshInstance3D.new()
		mi.name = "Body"
		mi.mesh = res
		_apply_obj_materials(mi, res, spec)
		_disable_shadows(mi)
		inner = mi
	elif res is PackedScene:
		inner = res.instantiate()
		_apply_scene_materials(inner, spec)
		_disable_shadows(inner)
	else:
		root.add_child(_fallback(spec))
		root.set_meta("size", Vector3(1.85, 1.35, 4.1))
		return root

	if inner == null:
		root.add_child(_fallback(spec))
		root.set_meta("size", Vector3(1.85, 1.35, 4.1))
		return root

	var up_i := _axis_index(spec.get("up", "y"))
	var len_i := _axis_index(spec.get("length", "z"))
	if up_i == len_i:
		up_i = 1
		len_i = 0 if up_i != 0 else 2

	var size := bounds.size
	var length_src: float = maxf(size[len_i], 0.001)
	var target_length: float = spec.get("target_length", 4.2)
	var s := target_length / length_src

	var basis := _axis_basis(up_i, len_i)
	if int(spec.get("nose", -1)) > 0:
		basis = Basis(Vector3.UP, PI) * basis
	var xf := Transform3D(basis.scaled(Vector3(s, s, s)), Vector3.ZERO)

	var moved := _transform_aabb(bounds, xf)
	var offset := Vector3(-moved.get_center().x, -moved.position.y, -moved.get_center().z)
	xf.origin = offset

	var wrapper := Node3D.new()
	wrapper.name = "Body"
	wrapper.add_child(inner)
	wrapper.transform = xf
	root.add_child(wrapper)
	root.set_meta("size", moved.size)
	var wheels: Array = WheelRig.attach(root, wrapper, spec)
	root.set_meta("wheels", wheels)
	return root


static func _load_baked(spec: Dictionary) -> Node3D:
	var path := "%s/%s.scn" % [BAKED_DIR, String(spec.get("id", ""))]
	if not ResourceLoader.exists(path):
		return null
	var packed := load(path) as PackedScene
	if packed == null:
		return null
	var root := packed.instantiate() as Node3D
	# Les roues sont des nœuds de la scène : on reconstruit leurs descripteurs.
	var wheels: Array = []
	var rig := root.get_node_or_null("WheelRig")
	var data: Dictionary = spec.get("wheels", {})
	if rig != null:
		for steer in rig.get_children():
			var center: Vector3 = (steer as Node3D).position
			wheels.append({
				"pivot": steer,
				"spin": steer.get_node("Spin"),
				"front": center.z < 0.0,
				"radius": float(data.get("spin_radius", data.get("radius", 0.32))),
				"center": center,
			})
	root.set_meta("wheels", wheels)
	return root


static func _fallback(spec: Dictionary) -> Node3D:
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.85, 1.1, 4.1)
	body.mesh = box
	body.position = Vector3(0, 0.55, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = spec.get("color", Color(0.7, 0.06, 0.08))
	mat.metallic = 0.4
	mat.roughness = 0.3
	body.material_override = mat
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return body


static func _axis_index(name: String) -> int:
	match name:
		"x":
			return 0
		"z":
			return 2
		_:
			return 1


## Permutation d'axes gardant un repère direct et envoyant la longueur sur +Z.
static func _axis_basis(up: int, length: int) -> Basis:
	if up == 1 and length == 2:
		return Basis(Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))
	if up == 1 and length == 0:
		return Basis(Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3(-1, 0, 0))
	if up == 2 and length == 0:
		return Basis(Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0))
	if up == 2 and length == 1:
		return Basis(Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0))
	return Basis()


static func _transform_aabb(box: AABB, xf: Transform3D) -> AABB:
	var aabb := AABB(xf * box.get_endpoint(0), Vector3.ZERO)
	for i in range(1, 8):
		aabb = aabb.expand(xf * box.get_endpoint(i))
	return aabb


static func _disable_shadows(node: Node) -> void:
	if node is GeometryInstance3D:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_disable_shadows(child)


# --------------------------------------------------------------------------
# Matériaux
# --------------------------------------------------------------------------

static func _apply_scene_materials(root: Node, spec: Dictionary) -> void:
	match String(spec.get("paint", "")):
		"pbr":
			_apply_pbr_materials(root, spec)
		_:
			pass


static func _apply_obj_materials(mi: MeshInstance3D, mesh: Mesh, spec: Dictionary) -> void:
	var mats := {}
	if String(spec.get("paint", "")) == "mtl":
		mats = _mtl_materials(String(spec.get("model", "")), spec)
	for i in mesh.get_surface_count():
		var n: String = mesh.surface_get_name(i).strip_edges()
		var mat: Material = mats.get(n)
		if mat == null:
			mat = _material_for_name(n, spec)
		mi.set_surface_override_material(i, mat)


static func _mtl_materials(obj_path: String, spec: Dictionary) -> Dictionary:
	var out := {}
	var dir := obj_path.get_base_dir()
	var mtl_path := ""
	var f := FileAccess.open(obj_path, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("mtllib "):
			mtl_path = dir.path_join(line.substr(7).strip_edges())
			break
	if mtl_path.is_empty() or not FileAccess.file_exists(mtl_path):
		return out

	var current := ""
	var texture := {}
	var alpha := {}
	var mf := FileAccess.open(mtl_path, FileAccess.READ)
	if mf == null:
		return out
	while not mf.eof_reached():
		var line := mf.get_line().strip_edges()
		if line.begins_with("newmtl "):
			current = line.substr(7).strip_edges()
			texture[current] = ""
			alpha[current] = 1.0
		elif line.begins_with("map_Kd ") and not current.is_empty():
			texture[current] = line.substr(7).strip_edges()
		elif line.begins_with("d ") and not current.is_empty():
			alpha[current] = float(line.substr(2).strip_edges())

	for key in texture:
		var name_l: String = String(key).to_lower()
		if name_l.contains("shadow"):
			out[key] = _invisible_material()
			continue
		var mat: StandardMaterial3D
		if name_l.contains("glass") or name_l.contains("gass") or name_l.contains("window"):
			mat = _glass_material()
		else:
			mat = _material_for_name(key, spec)
			var tex_file: String = texture[key]
			if not tex_file.is_empty():
				var tex_path := dir.path_join(tex_file)
				if ResourceLoader.exists(tex_path):
					mat.albedo_texture = load(tex_path)
					# La texture contient déjà la peinture : on ne la teinte pas.
					mat.albedo_color = Color(1.0, 1.0, 1.0, mat.albedo_color.a)
			var a: float = alpha[key]
			if a < 0.999:
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				mat.albedo_color.a = a
		out[key] = mat
	return out


static func _apply_pbr_materials(root: Node, spec: Dictionary) -> void:
	var dir: String = spec.get("pbr_dir", "")
	if dir.is_empty():
		return
	for mi in _all_meshes(root):
		for i in mi.mesh.get_surface_count():
			var name: String = mi.mesh.surface_get_name(i)
			mi.set_surface_override_material(i, _pbr_material(name, dir, spec))


static func _pbr_material(name: String, dir: String, spec: Dictionary) -> StandardMaterial3D:
	var base := dir.path_join(name)
	var mat := StandardMaterial3D.new()
	mat.resource_name = name
	var albedo := base + "_albedo.jpg"
	if ResourceLoader.exists(albedo):
		mat.albedo_texture = load(albedo)
	var metallic := base + "_metallic.jpg"
	if ResourceLoader.exists(metallic):
		mat.metallic_texture = load(metallic)
		mat.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		mat.metallic = 1.0
	var roughness := base + "_roughness.jpg"
	if ResourceLoader.exists(roughness):
		mat.roughness_texture = load(roughness)
		mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		mat.roughness = 1.0
	var normal := base + "_normal.png"
	if ResourceLoader.exists(normal):
		mat.normal_enabled = true
		mat.normal_texture = load(normal)
		mat.normal_scale = 0.8
	var emissive := base + "_emissive.jpg"
	if ResourceLoader.exists(emissive):
		mat.emission_enabled = true
		mat.emission_texture = load(emissive)
		mat.emission_energy_multiplier = 0.6

	var n := name.to_lower()
	if n.contains("window") or n.contains("glass"):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.72
		mat.metallic = 0.55
		mat.roughness = 0.08
	elif n.contains("body") or n.contains("bumper") or n.contains("door") or n.contains("bonnet"):
		mat.metallic = 0.55
		mat.roughness = 0.25
	elif n.contains("tire") or n.contains("wheel"):
		mat.metallic = 0.0
		mat.roughness = 0.9
	return mat


static func _all_meshes(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	_gather_meshes(root, out)
	return out


static func _gather_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and node.mesh != null:
		out.append(node)
	for child in node.get_children():
		_gather_meshes(child, out)


static func _invisible_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0, 0, 0, 0)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat


static func _glass_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.5, 0.62, 0.72, 0.4)
	mat.metallic = 0.35
	mat.roughness = 0.08
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = Color(0.14, 0.18, 0.22)
	mat.emission_energy_multiplier = 0.3
	return mat


static func _material_for_name(raw_name: String, spec: Dictionary) -> StandardMaterial3D:
	var n := raw_name.to_lower()
	var mat := StandardMaterial3D.new()
	mat.resource_name = raw_name
	var body: Color = spec.get("color", Color(0.62, 0.03, 0.06))

	if n.contains("shadow"):
		return _invisible_material()
	if n.contains("glass") or n.contains("gass") or n == "refract" or n.contains("window"):
		return _glass_material()
	if n.contains("tire") or n.contains("gum") or n.contains("tyre"):
		mat.albedo_color = Color(0.025, 0.025, 0.028)
		mat.roughness = 0.95
		return mat
	if n.contains("chrome") or n.contains("silver") or n.contains("rim") or n.contains("alu"):
		mat.albedo_color = Color(0.78, 0.79, 0.81)
		mat.metallic = 0.95
		mat.roughness = 0.18
		return mat
	if n.contains("light") or n.contains("tail") or n.contains("brake"):
		mat.albedo_color = Color(0.85, 0.12, 0.08)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.18, 0.1)
		mat.emission_energy_multiplier = 0.9
		return mat
	if n.contains("plate") or n.contains("number"):
		mat.albedo_color = Color(0.9, 0.9, 0.86)
		mat.roughness = 0.5
		return mat
	if n.contains("gold"):
		mat.albedo_color = Color(0.82, 0.6, 0.22)
		mat.metallic = 0.85
		mat.roughness = 0.28
		return mat
	if n == "body" or n.begins_with("body") or n.begins_with("bonnet") or n.begins_with("paint"):
		mat.albedo_color = body
		mat.metallic = 0.55
		mat.roughness = 0.28
		return mat
	mat.albedo_color = Color(0.06, 0.06, 0.07)
	mat.roughness = 0.65
	return mat
