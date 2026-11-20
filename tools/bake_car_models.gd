extends SceneTree

## Pré-cuit les voitures du joueur en versions légères.
##
## Les modèles sources sont très lourds (Skyline 772k triangles, Aveo 670k,
## Miata 414k, jusqu'à 163 surfaces) : une seule voiture coûtait autant que
## toute la ville. Pour chaque entrée de CarCatalog, on construit la voiture
## exactement comme en jeu (CarModel.build, roues découpées comprises), puis :
##   1. la carrosserie (nœud "Body") est aplatie en un seul mesh, une surface
##      par matériau ; chaque roue de même, séparément (elle doit tourner) ;
##   2. si la voiture dépasse TARGET_TRIS, Blender la décime
##      (tools/blender_decimate.py, Decimate « Collapse », qui respecte les
##      coutures UV) ; seule la géométrie revient, les matériaux restent ceux
##      de Godot. Sans Blender, repli sur meshoptimizer pour les surfaces sans
##      texture uniquement ;
##   3. LOD automatiques (surfaces sans texture) pour les vues lointaines.
## Le résultat est sauvé dans assets/cars/baked/<id>.scn ; CarModel.build le
## charge en priorité (spec "raw" = true pour forcer le modèle source).
##
## Usage : Godot --headless --path . --script res://tools/bake_car_models.gd
## Blender : variable BLENDER, sinon /Applications/Blender.app.

const OUT_DIR := "res://assets/cars/baked"
## Budget de triangles pour une voiture entière (carrosserie + roues).
var TARGET_TRIS := int(OS.get_environment("BAKE_TARGET")) if OS.get_environment("BAKE_TARGET") != "" else 60000
## Voitures gardées telles quelles. Skyline : ses coques peinture/intérieur
## quasi confondues se chevauchent dès que la géométrie est réécrite.
const SKIP := ["skyline"]
const DEFAULT_BLENDER := "/Applications/Blender.app/Contents/MacOS/Blender"

const DROPPED := [Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS, Mesh.ARRAY_CUSTOM0,
	Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3]


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	for entry in CarCatalog.CARS:
		if entry["id"] in SKIP:
			DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s.scn" % [OUT_DIR, entry["id"]]))
			print("%-11s ignorée (modèle d'origine)" % entry["id"])
			continue
		var spec: Dictionary = entry.duplicate(true)
		spec["raw"] = true
		var t0 := Time.get_ticks_msec()
		var root: Node3D = CarModel.build(spec)
		var before := _stats(root)

		var parts: Array[MeshInstance3D] = []
		var body := root.get_node_or_null("Body") as Node3D
		if body != null:
			parts.append_array(_flatten(body, "BodyMesh"))
		var rig := root.get_node_or_null("WheelRig")
		if rig != null:
			for steer in rig.get_children():
				var spin := steer.get_node_or_null("Spin") as Node3D
				if spin != null:
					parts.append_array(_flatten(spin, "%sMesh" % steer.name))

		var ratio := minf(1.0, float(TARGET_TRIS) / maxf(1.0, float(before.y)))
		var how := "-"
		if ratio < 0.999:
			how = "blender" if _decimate_blender(root, parts, ratio, String(entry["id"])) else "godot"
			if how == "godot":
				for p in parts:
					_decimate_godot(p, ratio)
		for p in parts:
			_finish(p)

		var after := _stats(root)
		# Les descripteurs de roues contiennent des références de nœuds :
		# CarModel les reconstruit au chargement.
		root.remove_meta("wheels")
		_own(root, root)
		var packed := PackedScene.new()
		packed.pack(root)
		var path := "%s/%s.scn" % [OUT_DIR, entry["id"]]
		var err := ResourceSaver.save(packed, path, ResourceSaver.FLAG_COMPRESS)
		print("%-11s surfaces %3d -> %3d   triangles %7d -> %6d   décimation %-7s %s (%d ms)" % [
			entry["id"], before.x, after.x, before.y, after.y, how, error_string(err),
			Time.get_ticks_msec() - t0])
		root.free()
	quit()


# ------------------------------------------------------------------ fusion

## Remplace les MeshInstance3D sous `parent` par des meshes fusionnés, une
## surface par matériau :
##   - surfaces sans texture : toutes regroupées dans un seul mesh, transforms
##     appliqués aux sommets ;
##   - surfaces texturées : fusionnées par mesh d'origine seulement, qui garde
##     son transform. Appliquer le transform sur le CPU change les arrondis, et
##     les coques quasi confondues de la Skyline (peinture + intérieur blanc)
##     se mettaient à se chevaucher (z-fighting).
func _flatten(parent: Node3D, mesh_name: String) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	var instances := parent.find_children("*", "MeshInstance3D", true, false)
	if instances.is_empty():
		return result
	var flat := {}
	var flat_order: Array = []
	var textured: Array = []
	for node in instances:
		var mi := node as MeshInstance3D
		var src := mi.mesh
		if src == null or not mi.visible:
			continue
		var xf := _relative_xf(mi, parent)
		var own := {}
		var own_order: Array = []
		for s in src.get_surface_count():
			if src.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var mat: Material = mi.material_override
			if mat == null:
				mat = mi.get_surface_override_material(s)
			if mat == null:
				mat = src.surface_get_material(s)
			var key := _material_key(mat)
			# surface_get_arrays décode la compression des meshes (échelle des
			# UV) ; SurfaceTool.append_from ne le fait pas.
			var arrays := src.surface_get_arrays(s)
			if _textured(mat):
				if not own.has(key):
					own[key] = {"mat": mat, "parts": []}
					own_order.append(key)
				own[key]["parts"].append([arrays, Transform3D.IDENTITY])
			else:
				if not flat.has(key):
					flat[key] = {"mat": mat, "parts": []}
					flat_order.append(key)
				flat[key]["parts"].append([arrays, xf])
		if not own_order.is_empty():
			textured.append({"xf": xf, "groups": own, "order": own_order})

	for node in instances:
		node.get_parent().remove_child(node)
		node.free()
	if not flat_order.is_empty():
		result.append(_make_instance(parent, mesh_name, flat, flat_order, Transform3D.IDENTITY))
	for i in textured.size():
		var t: Dictionary = textured[i]
		result.append(_make_instance(parent, "%s_T%d" % [mesh_name, i], t["groups"], t["order"], t["xf"]))
	return result


func _make_instance(parent: Node3D, mesh_name: String, groups: Dictionary, order: Array, xf: Transform3D) -> MeshInstance3D:
	var out := ArrayMesh.new()
	for key in order:
		var arrays := _concat(groups[key]["parts"])
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _compact(arrays))
		out.surface_set_material(out.get_surface_count() - 1, groups[key]["mat"])
	var merged := MeshInstance3D.new()
	merged.name = mesh_name
	merged.mesh = out
	merged.transform = xf
	merged.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(merged)
	return merged


## Concatène des surfaces [arrays, transform] en une seule, indexée.
## Un canal absent d'une partie mais présent ailleurs reçoit une valeur neutre.
func _concat(parts: Array) -> Array:
	var has := {}
	for ch in [Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_COLOR]:
		has[ch] = false
		for p in parts:
			if p[0][ch] != null:
				has[ch] = true
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var t := PackedFloat32Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	for p in parts:
		var a: Array = p[0]
		var xf: Transform3D = p[1]
		var nb := xf.basis.inverse().transposed()
		var base := v.size()
		var pv: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var count := pv.size()
		for i in count:
			v.append(xf * pv[i])
		if has[Mesh.ARRAY_NORMAL]:
			var pn = a[Mesh.ARRAY_NORMAL]
			for i in count:
				n.append((nb * pn[i]).normalized() if pn != null else Vector3.UP)
		if has[Mesh.ARRAY_TANGENT]:
			var pt = a[Mesh.ARRAY_TANGENT]
			for i in count:
				if pt != null:
					var tv := (xf.basis * Vector3(pt[i * 4], pt[i * 4 + 1], pt[i * 4 + 2])).normalized()
					t.append_array([tv.x, tv.y, tv.z, pt[i * 4 + 3]])
				else:
					t.append_array([1.0, 0.0, 0.0, 1.0])
		for pair in [[Mesh.ARRAY_TEX_UV, uv], [Mesh.ARRAY_TEX_UV2, uv2]]:
			if has[pair[0]]:
				var pu = a[pair[0]]
				var dst: PackedVector2Array = pair[1]
				for i in count:
					dst.append(pu[i] if pu != null else Vector2.ZERO)
				if pair[0] == Mesh.ARRAY_TEX_UV:
					uv = dst
				else:
					uv2 = dst
		if has[Mesh.ARRAY_COLOR]:
			var pc = a[Mesh.ARRAY_COLOR]
			for i in count:
				col.append(pc[i] if pc != null else Color.WHITE)
		var pi = a[Mesh.ARRAY_INDEX]
		var tri_idx := PackedInt32Array(pi) if pi != null else PackedInt32Array(range(count))
		# Transform miroir (déterminant < 0) : le rendu inversait le sens des
		# faces ; une fois appliqué aux sommets, il faut inverser l'enroulement.
		var mirror := xf.basis.determinant() < 0.0
		for k in range(0, tri_idx.size(), 3):
			idx.append(base + tri_idx[k])
			if mirror:
				idx.append(base + tri_idx[k + 2])
				idx.append(base + tri_idx[k + 1])
			else:
				idx.append(base + tri_idx[k + 1])
				idx.append(base + tri_idx[k + 2])
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = v
	out[Mesh.ARRAY_INDEX] = idx
	if has[Mesh.ARRAY_NORMAL]:
		out[Mesh.ARRAY_NORMAL] = n
	if has[Mesh.ARRAY_TANGENT]:
		out[Mesh.ARRAY_TANGENT] = t
	if has[Mesh.ARRAY_TEX_UV]:
		out[Mesh.ARRAY_TEX_UV] = uv
	if has[Mesh.ARRAY_TEX_UV2]:
		out[Mesh.ARRAY_TEX_UV2] = uv2
	if has[Mesh.ARRAY_COLOR]:
		out[Mesh.ARRAY_COLOR] = col
	return out


func _relative_xf(node: Node, ancestor: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n := node
	while n != null and n != ancestor:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


## Deux matériaux aux propriétés identiques donnent la même clé (les modèles
## OBJ créent une instance par surface, même pour une peinture commune).
func _material_key(mat: Material) -> String:
	if mat == null:
		return "none"
	var parts := PackedStringArray([mat.get_class()])
	for p in mat.get_property_list():
		if int(p["usage"]) & PROPERTY_USAGE_STORAGE and String(p["name"]) != "resource_name":
			parts.append(str(mat.get(p["name"])))
	return "|".join(parts)


# ------------------------------------------------------------- décimation

## Exporte les meshes fusionnés en glTF, les fait décimer par Blender et
## remplace leur géométrie (matériaux conservés, surface par surface).
func _decimate_blender(root: Node3D, parts: Array[MeshInstance3D], ratio: float, id: String) -> bool:
	var blender := OS.get_environment("BLENDER")
	if blender.is_empty():
		blender = DEFAULT_BLENDER
	if not FileAccess.file_exists(blender):
		push_warning("Blender introuvable (%s) : repli sur meshoptimizer" % blender)
		return false
	var tmp := OS.get_cache_dir().path_join("drift_city_bake")
	DirAccess.make_dir_recursive_absolute(tmp)
	var src_glb := tmp.path_join(id + "_in.glb")
	var dst_glb := tmp.path_join(id + "_out.glb")

	# Scène d'export : uniquement la géométrie, à plat, noms uniques.
	var export_root := Node3D.new()
	export_root.name = "Export"
	for p in parts:
		var copy := MeshInstance3D.new()
		copy.name = p.name
		var geo := ArrayMesh.new()
		for s in p.mesh.get_surface_count():
			geo.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, p.mesh.surface_get_arrays(s))
			# Matériau neutre mais distinct par surface : Blender garde un slot
			# (donc une primitive glTF) par surface, dans le même ordre.
			var m := StandardMaterial3D.new()
			m.resource_name = "S%d" % s
			geo.surface_set_material(s, m)
		copy.mesh = geo
		export_root.add_child(copy)
		copy.owner = export_root
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(export_root, state)
	if err == OK:
		err = doc.write_to_filesystem(state, src_glb)
	export_root.free()
	if err != OK:
		push_warning("export glTF impossible : " + error_string(err))
		return false

	var script := ProjectSettings.globalize_path("res://tools/blender_decimate.py")
	var output := []
	var code := OS.execute(blender, ["-b", "--factory-startup", "--python", script, "--",
		src_glb, dst_glb, str(ratio)], output, true)
	if code != 0 or not FileAccess.file_exists(dst_glb):
		push_warning("Blender a échoué (%d) : %s" % [code, "\n".join(output).right(800)])
		return false

	var doc2 := GLTFDocument.new()
	var state2 := GLTFState.new()
	if doc2.append_from_file(dst_glb, state2) != OK:
		return false
	var scene := doc2.generate_scene(state2)
	var by_name := {}
	for n in scene.find_children("*", "MeshInstance3D", true, false):
		by_name[String(n.name)] = n
	var ok := false
	for p in parts:
		var dec: MeshInstance3D = by_name.get(String(p.name))
		if dec == null or dec.mesh.get_surface_count() != p.mesh.get_surface_count():
			# Pièce perdue ou incomplète : elle garde sa géométrie d'origine.
			push_warning("%s : surfaces perdues par Blender, pièce conservée" % p.name)
			continue
		ok = true
		var out := ArrayMesh.new()
		for s in p.mesh.get_surface_count():
			var arrays := dec.mesh.surface_get_arrays(s)
			for t in DROPPED:
				arrays[t] = null
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			out.surface_set_material(s, p.mesh.surface_get_material(s))
		p.mesh = out
	scene.free()
	return ok


## Repli sans Blender : meshoptimizer, uniquement sur les surfaces sans
## texture (il soude les coutures UV).
func _decimate_godot(mi: MeshInstance3D, ratio: float) -> void:
	var src := mi.mesh
	var out := ArrayMesh.new()
	for s in src.get_surface_count():
		var arrays := src.surface_get_arrays(s)
		var mat := src.surface_get_material(s)
		var tris: int = (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		if not _textured(mat) and tris > 64:
			var im := ImporterMesh.new()
			im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays)
			im.generate_lods(25.0, 60.0, [])
			var target := int(tris * ratio)
			var best: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var best_err := absi(best.size() / 3 - target)
			for l in im.get_surface_lod_count(0):
				var idx := im.get_surface_lod_indices(0, l)
				if absi(idx.size() / 3 - target) < best_err:
					best = idx
					best_err = absi(idx.size() / 3 - target)
			arrays[Mesh.ARRAY_INDEX] = best
			arrays = _compact(arrays)
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(s, mat)
	mi.mesh = out


## Ajoute les LOD automatiques aux surfaces sans texture.
func _finish(mi: MeshInstance3D) -> void:
	var src := mi.mesh
	var out := ArrayMesh.new()
	for s in src.get_surface_count():
		var arrays := src.surface_get_arrays(s)
		var mat := src.surface_get_material(s)
		if arrays[Mesh.ARRAY_INDEX] == null:
			var st := SurfaceTool.new()
			st.create_from_arrays(arrays)
			st.index()
			arrays = st.commit_to_arrays()
		var lods := {}
		if not _textured(mat):
			var im := ImporterMesh.new()
			im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays)
			im.generate_lods(25.0, 60.0, [])
			for l in im.get_surface_lod_count(0):
				lods[im.get_surface_lod_size(0, l)] = im.get_surface_lod_indices(0, l)
		# Compression (positions 16 bits, comme les imports Godot) : moitié moins
		# de mémoire, et les couches quasi confondues des modèles (Skyline :
		# peinture + sous-couche) retombent sur les mêmes valeurs, sans z-fighting.
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], lods, Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES)
		out.surface_set_material(s, mat)
	mi.mesh = out


func _textured(mat: Material) -> bool:
	if mat is BaseMaterial3D:
		var m := mat as BaseMaterial3D
		return m.albedo_texture != null or m.normal_texture != null
	return mat is ShaderMaterial


## Ne garde que les sommets référencés par l'index.
func _compact(arrays: Array) -> Array:
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var remap := PackedInt32Array()
	remap.resize(v.size())
	remap.fill(-1)
	var keep := PackedInt32Array()
	for k in idx.size():
		var i := idx[k]
		if remap[i] < 0:
			remap[i] = keep.size()
			keep.append(i)
		idx[k] = remap[i]
	var out := arrays.duplicate()
	out[Mesh.ARRAY_INDEX] = idx
	out[Mesh.ARRAY_VERTEX] = _pick3(v, keep)
	if arrays[Mesh.ARRAY_NORMAL] != null:
		out[Mesh.ARRAY_NORMAL] = _pick3(arrays[Mesh.ARRAY_NORMAL], keep)
	if arrays[Mesh.ARRAY_TANGENT] != null:
		var t: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
		var nt := PackedFloat32Array()
		nt.resize(keep.size() * 4)
		for j in keep.size():
			for e in 4:
				nt[j * 4 + e] = t[keep[j] * 4 + e]
		out[Mesh.ARRAY_TANGENT] = nt
	for ch in [Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2]:
		if arrays[ch] != null:
			var u: PackedVector2Array = arrays[ch]
			var nu := PackedVector2Array()
			nu.resize(keep.size())
			for j in keep.size():
				nu[j] = u[keep[j]]
			out[ch] = nu
	if arrays[Mesh.ARRAY_COLOR] != null:
		var c: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var nc := PackedColorArray()
		nc.resize(keep.size())
		for j in keep.size():
			nc[j] = c[keep[j]]
		out[Mesh.ARRAY_COLOR] = nc
	return out


func _pick3(src: PackedVector3Array, keep: PackedInt32Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(keep.size())
	for j in keep.size():
		out[j] = src[keep[j]]
	return out


func _own(node: Node, owner: Node) -> void:
	for c in node.get_children():
		c.owner = owner
		_own(c, owner)


func _stats(root: Node) -> Vector2i:
	var surf := 0
	var tris := 0
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m: Mesh = (mi as MeshInstance3D).mesh
		if m == null:
			continue
		for s in m.get_surface_count():
			surf += 1
			var a := m.surface_get_arrays(s)
			var idx = a[Mesh.ARRAY_INDEX]
			tris += (idx.size() if idx != null else (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	return Vector2i(surf, tris)
