extends Node3D

## Trafic roulant — port compact du moteur de `mrdoob/slop-newyork`.
##
## Principes repris (voir js/traffic.js, road-network.js, vehicle-physics.js) :
##  - graphe de voies ORIENTÉES : chaque axe a sa voie de droite, les carrefours
##    sont reliés par des courbes de Bézier de voie à voie ;
##  - Intelligent Driver Model : accélération libre + freinage pour le véhicule
##    devant et limitation de vitesse dans les virages ;
##  - direction vers un point anticipé de la courbe (pas de rotation brutale) ;
##  - contacts rigides 2D avec impulsion linéaire ET angulaire : les voitures
##    se décolles en reculant et en tournant au lieu de se chevaucher.
##
## Le réseau vient des tuiles `Road_*` cuites : leurs centres forment une grille
## de 11,4 m, on ne relie que les carreaux directement voisins.

const ROADS := "res://low-poly-city/city_roads.res"
const CAR_DIR := "res://npc_cars"
const MAX_CARS := 100
const GRID := 11.4
## Décalage à droite de l'axe, comme dans le moteur source (conduite à droite).
const LANE := 2.3
const SAFE_RADIUS := 22.0
const RESPAWN_RADIUS := 330.0
const HALF_W := 0.95
const HALF_L := 2.1
const MASS := 1600.0
## Rayon de la zone de carrefour autour du centre d'un nœud : une voiture y
## entre seulement après avoir réservé le carrefour (voir try_reserve).
const ZONE := 3.5
## Deux trajectoires de carrefour se croisent si elles passent à moins de ça.
const CONFLICT_DIST := 3.5
## Taille des cellules de la grille de collision (m).
const CELL := 6.0
const CarScript = preload("res://scripts/npc_car.gd")

## Sens avant de chaque prefab : -1 = avant en -Z, +1 = avant en +Z.
## La sport, le pickup et la compacte (bleu ciel) ont été corrigés visuellement.
const FRONT := {
	"compact_car.tscn": 1.0,
	"coupe_car.tscn": -1.0,
	"hatchback_car.tscn": 1.0,
	"minivan_car.tscn": 1.0,
	"offroad_car.tscn": 1.0,
	"pickup_car.tscn": 1.0,
	"sedan_car.tscn": 1.0,
	"sport_car.tscn": 1.0,
	"suv_car.tscn": 1.0,
	"wagon_car.tscn": 1.0,
}

var _nodes: Array = []
var _adj: Array = []
## Arêtes orientées : {from, to, start, dir, right, len, moves}.
var _edges: Array = []
var _cars: Array = []
var _prefabs: Array = []
## Matériaux simplifiés, partagés entre toutes les voitures d'un même modèle.
var _flat_materials := {}
## Correspondance matériau simplifié -> matériau d'origine (pour le réactiver).
var _orig_by_flat := {}
## Voitures par arête (y compris celles dans la courbe de sortie de l'arête),
## reconstruit à chaque pas : la recherche du véhicule devant ne parcourt
## plus toute la flotte.
var _by_edge: Array = []
## Carrefour -> voitures qui l'ont réservé.
var _occ := {}
## Carrefour -> voitures qui attendent de pouvoir y entrer.
var _waiters := {}
## Après cette attente, une voiture d'une autre branche passe avant les
## nouvelles voitures de la file qui roule (pas de famine).
const FAIR_WAIT := 2.0
## (arête, mouvement, arête, mouvement) -> les trajectoires se croisent ?
var _conflicts := {}


func _ready() -> void:
	_load_roads()
	_load_prefabs()
	if _edges.is_empty() or _prefabs.is_empty():
		push_warning("Trafic NPC désactivé : routes ou modèles introuvables")
		return
	var links := 0
	for l in _adj:
		links += (l as Array).size()
	var count: int = Game.npc_count
	print("trafic NPC : %d carrefours, %d voies, %d modèles, %d voitures" % [
		_nodes.size(), _edges.size(), _prefabs.size(), count])
	for i in count:
		_spawn(i)


## Change le nombre de voitures en direct, sans recharger la ville.
func set_count(count: int) -> void:
	var target := clampi(count, 0, MAX_CARS)
	while _cars.size() > target:
		var car: Node = _cars.pop_back()
		release(car)
		car.queue_free()
	while _cars.size() < target:
		_spawn(_cars.size())
	print("trafic NPC : %d voitures" % _cars.size())


func _physics_process(delta: float) -> void:
	if _cars.is_empty():
		return
	_rebuild_buckets()
	_update_reservations()
	for car in _cars:
		car.call("step", delta)
	_collide_traffic()


func _rebuild_buckets() -> void:
	if _by_edge.size() != _edges.size():
		_by_edge.resize(_edges.size())
	for e in _edges.size():
		_by_edge[e] = []
	for car in _cars:
		var e: int = car.edge
		if e >= 0:
			(_by_edge[e] as Array).append(car)


## ---------------------------------------------------------------------------
## Véhicule devant
## ---------------------------------------------------------------------------

## Écart (pare-chocs à pare-chocs) et vitesse du premier véhicule devant, sur
## la voie actuelle, dans la courbe du carrefour puis sur la voie suivante.
func leader_ahead(car) -> Array:
	var e: int = car.edge
	var elen: float = float((_edges[e] as Dictionary)["len"])
	var p: float = float(car.s) if float(car.conn_s) < 0.0 else elen + float(car.conn_s)
	var best := 1.0e9
	var spd := 0.0
	for o in (_by_edge[e] as Array):
		if o == car:
			continue
		var po: float
		if float(o.conn_s) < 0.0:
			po = float(o.s)
		elif int(o.move) == int(car.move) or float(o.conn_s) < 3.0:
			po = elen + float(o.conn_s)
		else:
			continue
		if po <= p:
			continue
		var gap := po - p - 2.0 * HALF_L
		if gap < best:
			best = gap
			spd = float(o.speed)
	if int(car.move) >= 0:
		var mv := get_move(e, int(car.move))
		var curve: Dictionary = mv.get("curve", {})
		var clen: float = float(curve.get("len", 0.0))
		if clen < 0.5:
			clen = 0.0
		var oe: int = int(mv["to"])
		var base := elen + clen - p
		var olen: float = float((_edges[oe] as Dictionary)["len"])
		for o in (_by_edge[oe] as Array):
			if o == car:
				continue
			var po: float = float(o.s) if float(o.conn_s) < 0.0 else olen + float(o.conn_s)
			var gap := base + po - 2.0 * HALF_L
			if gap < best:
				best = gap
				spd = float(o.speed)
	return [maxf(best, 0.0), spd]


## ---------------------------------------------------------------------------
## Priorités aux carrefours
## ---------------------------------------------------------------------------

## Nœud au bout de l'arête de la voiture.
func node_ahead(car) -> int:
	return int((_edges[int(car.edge)] as Dictionary)["to"])


## Vrai carrefour (3 branches ou plus) : priorités gérées.
func is_gated(node: int) -> bool:
	return (_adj[node] as Array).size() >= 3


## Distance, depuis la position de la voiture, jusqu'à la ligne d'arrêt du
## carrefour qui suit la voie de sortie, si c'est un vrai carrefour (sinon INF).
## Les voies font 11,4 m : sans anticipation, une voiture sortie d'un
## carrefour à pleine vitesse ne peut plus s'arrêter avant le suivant.
func next_gate_distance(car, stop_line: float) -> float:
	if int(car.move) < 0 or float(car.conn_s) >= 0.0:
		return INF
	var e: int = car.edge
	var mv := get_move(e, int(car.move))
	var oe: int = int(mv["to"])
	if not is_gated(int((_edges[oe] as Dictionary)["to"])):
		return INF
	var clen: float = float((mv.get("curve", {}) as Dictionary).get("len", 0.0))
	if clen < 0.5:
		clen = 0.0
	return edge_length(e) - float(car.s) + clen + edge_length(oe) - stop_line - HALF_L


## Réserve le carrefour au bout de la voie si aucune voiture venant d'une
## autre branche ne l'occupe sur une trajectoire qui croise la nôtre.
## Les nœuds à 2 branches (route continue) n'ont pas de priorité.
## Une voiture peut tenir deux carrefours (celui qu'elle quitte et le suivant :
## les voies ne font que 11,4 m).
func try_reserve(car, force: bool = false) -> bool:
	var node := node_ahead(car)
	if int(car.res_node) == node:
		return true
	if (_adj[node] as Array).size() < 3:
		return true
	var entries: Array = _occ.get(node, [])
	var waiters: Dictionary = _waiters.get(node, {})
	if not force:
		for r in entries:
			if r["car"] == car or int(r["from"]) == int(car.edge):
				continue
			if _conflict(int(car.edge), int(car.move), int(r["from"]), int(r["move"])):
				waiters[car] = true
				_waiters[node] = waiters
				return false
		# Équité : une voiture qui attend depuis longtemps sur une autre branche,
		# sur une trajectoire qui croise la nôtre, passe d'abord.
		for w in waiters.keys():
			if w == car or not is_instance_valid(w) or int(w.edge) == int(car.edge):
				continue
			if node_ahead(w) != node or int(w.res_node) == node or int(w.move) < 0:
				waiters.erase(w)
				continue
			if float(w.wait_time) > FAIR_WAIT and _conflict(int(car.edge), int(car.move), int(w.edge), int(w.move)):
				waiters[car] = true
				_waiters[node] = waiters
				return false
	waiters.erase(car)
	entries.append({
		"car": car, "from": int(car.edge), "move": int(car.move),
		"to": int(get_move(int(car.edge), int(car.move)).get("to", -1)),
	})
	_occ[node] = entries
	car.res_node = node
	return true


## Libère tous les carrefours tenus par la voiture.
func release(car) -> void:
	for node in _occ.keys():
		var entries: Array = _occ[node]
		for i in range(entries.size() - 1, -1, -1):
			if entries[i]["car"] == car:
				entries.remove_at(i)
	for node in _waiters.keys():
		(_waiters[node] as Dictionary).erase(car)
	car.res_node = -1


## Libère les carrefours que les voitures ont quittés.
func _update_reservations() -> void:
	for node in _occ.keys():
		var entries: Array = _occ[node]
		for i in range(entries.size() - 1, -1, -1):
			var r: Dictionary = entries[i]
			var car = r["car"]
			if not is_instance_valid(car):
				entries.remove_at(i)
				continue
			var e: int = car.edge
			if e == int(r["from"]):
				continue
			if e == int(r["to"]) and float(car.conn_s) < 0.0 and float(car.s) < ZONE + HALF_L:
				continue
			entries.remove_at(i)
			if int(car.res_node) == int(node):
				car.res_node = -1


func _conflict(e1: int, m1: int, e2: int, m2: int) -> bool:
	var key := Vector4i(e1, m1, e2, m2)
	if _conflicts.has(key):
		return _conflicts[key]
	var a := _move_path(e1, m1)
	var b := _move_path(e2, m2)
	var hit := int(get_move(e1, m1).get("to", -1)) == int(get_move(e2, m2).get("to", -2))
	if not hit:
		for pa in a:
			for pb in b:
				if (pa as Vector2).distance_to(pb) < CONFLICT_DIST:
					hit = true
					break
			if hit:
				break
	_conflicts[key] = hit
	_conflicts[Vector4i(e2, m2, e1, m1)] = hit
	return hit


## Points de la trajectoire dans la zone de carrefour : fin de voie, courbe,
## début de la voie suivante.
func _move_path(e: int, m: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var elen := edge_length(e)
	for k in 4:
		pts.append(lane_point(e, maxf(0.0, elen - ZONE + ZONE * float(k) / 3.0))[0])
	var mv := get_move(e, m)
	if mv.is_empty():
		return pts
	var curve: Dictionary = mv.get("curve", {})
	if float(curve.get("len", 0.0)) > 0.5:
		for k in range(1, 8):
			pts.append(curve_point(curve, float(curve["len"]) * float(k) / 8.0)[0])
	var oe: int = int(mv["to"])
	for k in 4:
		pts.append(lane_point(oe, minf(edge_length(oe), ZONE * float(k) / 3.0))[0])
	return pts


## ---------------------------------------------------------------------------
## Réseau routier
## ---------------------------------------------------------------------------
func _load_roads() -> void:
	var res: Resource = load(ROADS)
	if res == null:
		return
	var pts: PackedVector3Array = res.points
	if pts.size() < 4:
		return

	var x0 := 1.0e9
	var z0 := 1.0e9
	for i in range(0, pts.size() - 1, 2):
		x0 = minf(x0, (pts[i].x + pts[i + 1].x) * 0.5)
		z0 = minf(z0, (pts[i].z + pts[i + 1].z) * 0.5)

	var index := {}
	for i in range(0, pts.size() - 1, 2):
		var cx := (pts[i].x + pts[i + 1].x) * 0.5
		var cz := (pts[i].z + pts[i + 1].z) * 0.5
		var gx: int = roundi((cx - x0) / GRID)
		var gz: int = roundi((cz - z0) / GRID)
		var key := Vector2i(gx, gz)
		if index.has(key):
			continue
		index[key] = _nodes.size()
		_nodes.append(Vector2(x0 + float(gx) * GRID, z0 + float(gz) * GRID))
		_adj.append([])

	var dirs := [Vector2i(1, 0), Vector2i(0, 1)]
	for key in index.keys():
		var a: int = index[key]
		for d in dirs:
			var other: Vector2i = (key as Vector2i) + (d as Vector2i)
			if index.has(other):
				var b: int = index[other]
				(_adj[a] as Array).append(b)
				(_adj[b] as Array).append(a)

	# Une arête orientée par sens de circulation.
	var by_pair := {}
	for a in _nodes.size():
		for b in (_adj[a] as Array):
			by_pair[Vector2i(a, b)] = _edges.size()
			_add_edge(a, b)
	# Puis les mouvements possibles à chaque carrefour, avec leur courbe.
	for e in range(_edges.size()):
		var edge: Dictionary = _edges[e]
		var moves: Array = edge["moves"]
		for f in _edges.size():
			var nxt: Dictionary = _edges[f]
			if int(nxt["from"]) != int(edge["to"]) or int(nxt["to"]) == int(edge["from"]):
				continue
			var straight: bool = (edge["dir"] as Vector2).dot(nxt["dir"] as Vector2) > 0.5
			moves.append({
				"to": f,
				"weight": 3.0 if straight else 1.0,
				"curve": _make_curve(edge, nxt),
			})
		# Demi-tour : rare sur un carrefour normal, mais indispensable en
		# impasse (sinon la voiture recule indéfiniment sur la même voie).
		var back: Variant = by_pair.get(Vector2i(int(edge["to"]), int(edge["from"])), -1)
		if int(back) >= 0:
			moves.append({
				"to": int(back),
				"weight": 0.03 if not moves.is_empty() else 1.0,
				"curve": _make_curve(edge, _edges[int(back)]),
			})


func _add_edge(from: int, to: int) -> void:
	var dir: Vector2 = ((_nodes[to] as Vector2) - (_nodes[from] as Vector2)).normalized()
	_edges.append({
		"from": from,
		"to": to,
		"start": _nodes[from],
		"dir": dir,
		"right": Vector2(-dir.y, dir.x),
		"len": (_nodes[from] as Vector2).distance_to(_nodes[to] as Vector2),
		"moves": [],
	})


## Bézier cubique de la fin de la voie e au début de la voie f, avec table
## d'abscisse curviligne et courbure maximale (cf. makeCurve dans le source).
func _make_curve(e: Dictionary, f: Dictionary) -> Dictionary:
	var p0: Vector2 = (e["start"] as Vector2) + (e["dir"] as Vector2) * float(e["len"]) + (e["right"] as Vector2) * LANE
	var p3: Vector2 = (f["start"] as Vector2) + (f["right"] as Vector2) * LANE
	var ed: Vector2 = e["dir"]
	var fd: Vector2 = f["dir"]
	var cross := ed.x * fd.y - ed.y * fd.x
	var k0 := 0.0
	var k3 := 0.0
	if absf(cross) < 0.5:
		var straight_len := p0.distance_to(p3) / 3.0
		k0 = straight_len
		k3 = straight_len
	else:
		var t := ((p3.x - p0.x) * fd.y - (p3.y - p0.y) * fd.x) / cross
		k0 = 0.552 * absf(t)
		k3 = 0.552 * (p3 - (p0 + ed * t)).length()
	var p1 := p0 + ed * k0
	var p2 := p3 - fd * k3

	var lut := [0.0]
	var curv := 0.0
	var prev := p0
	for k in range(1, 17):
		var p := _bezier(p0, p1, p2, p3, float(k) / 16.0)
		lut.append(float(lut[k - 1]) + prev.distance_to(p))
		prev = p
	var length: float = lut[16]
	# Une voie continue (mouvement tout droit) a une courbe de longueur nulle :
	# elle ne doit surtout pas être considérée comme un virage serré.
	if length > 0.5:
		var last_dir: Vector2 = (p1 - p0).normalized()
		for k in range(1, 17):
			var p := _bezier(p0, p1, p2, p3, float(k) / 16.0)
			var q: Vector2 = _bezier(p0, p1, p2, p3, float(k + 1) / 16.0) if k < 16 else (p3 - p2).normalized() + p3
			var d: Vector2 = (q - p).normalized()
			if d.length_squared() < 0.5:
				continue
			var turn: float = acos(clampf(last_dir.dot(d), -1.0, 1.0))
			curv = maxf(curv, turn / maxf(0.01, length / 16.0))
			last_dir = d
	return {"p0": p0, "p1": p1, "p2": p2, "p3": p3, "lut": lut, "len": length, "curv": curv}


func _bezier(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var u := 1.0 - t
	return p0 * (u * u * u) + p1 * (3.0 * u * u * t) + p2 * (3.0 * u * t * t) + p3 * (t * t * t)


func _bezier_dir(c: Dictionary, t: float) -> Vector2:
	var p0: Vector2 = c["p0"]
	var p1: Vector2 = c["p1"]
	var p2: Vector2 = c["p2"]
	var p3: Vector2 = c["p3"]
	var u := 1.0 - t
	var d: Vector2 = (p1 - p0) * (3.0 * u * u) + (p2 - p1) * (6.0 * u * t) + (p3 - p2) * (3.0 * t * t)
	return d.normalized() if d.length_squared() > 0.000001 else (p3 - p0).normalized()


func curve_point(c: Dictionary, s: float) -> Array:
	var lut: Array = c["lut"]
	var k := 1
	while k < 16 and float(lut[k]) < s:
		k += 1
	var s0: float = lut[k - 1]
	var s1: float = lut[k]
	var t := (float(k - 1) + clampf((s - s0) / maxf(s1 - s0, 0.0001), 0.0, 1.0)) / 16.0
	return [_bezier(c["p0"], c["p1"], c["p2"], c["p3"], t), _bezier_dir(c, t)]


## ---------------------------------------------------------------------------
## Interface utilisée par `npc_car.gd`
## ---------------------------------------------------------------------------
func edge_length(e: int) -> float:
	return float((_edges[e] as Dictionary)["len"])


func get_move(e: int, m: int) -> Dictionary:
	var moves: Array = (_edges[e] as Dictionary)["moves"]
	return moves[m] if m >= 0 and m < moves.size() else {}


func lane_point(e: int, s: float) -> Array:
	var edge: Dictionary = _edges[e]
	var pos: Vector2 = (edge["start"] as Vector2) + (edge["dir"] as Vector2) * s + (edge["right"] as Vector2) * LANE
	return [pos, edge["dir"]]


## Point et tangente à la distance c le long du chemin de la voiture : voie,
## courbe de carrefour, puis voie suivante. Sert au suivi et à l'anticipation.
func path_point(car, c: float) -> Array:
	var e: int = car.edge
	var edge: Dictionary = _edges[e]
	var c_s: float = car.conn_s
	var m: int = car.move
	if c_s >= 0.0:
		var curve: Dictionary = get_move(e, m).get("curve", {})
		if curve.is_empty():
			return lane_point(e, float(edge["len"]))
		# Virage nul : on est déjà sur la voie suivante.
		if float(curve["len"]) < 0.5:
			return lane_point(int(get_move(e, m)["to"]), maxf(0.0, c))
		if c < 0.0:
			return lane_point(e, float(edge["len"]) + c)
		if c > float(curve["len"]):
			return lane_point(car.out_edge, c - float(curve["len"]))
		return curve_point(curve, c)
	if c <= float(edge["len"]):
		return lane_point(e, maxf(0.0, c))
	if m < 0:
		return lane_point(e, float(edge["len"]))
	var curve2: Dictionary = get_move(e, m).get("curve", {})
	if curve2.is_empty():
		return lane_point(e, float(edge["len"]))
	var d := c - float(edge["len"])
	if d <= float(curve2["len"]):
		return curve_point(curve2, d)
	return lane_point(int(get_move(e, m)["to"]), d - float(curve2["len"]))


func choose_move(car) -> int:
	var moves: Array = (_edges[car.edge] as Dictionary)["moves"]
	if moves.is_empty():
		return -1
	var total := 0.0
	for m in moves:
		total += float((m as Dictionary)["weight"])
	var r := randf() * total
	for i in moves.size():
		r -= float((moves[i] as Dictionary)["weight"])
		if r < 0.0:
			return i
	return moves.size() - 1


func leader(car) -> Array:
	return leader_on(car, car.edge, car.s)


func leader_on(car, e: int, s: float) -> Array:
	var best := 1.0e9
	var other_speed := 0.0
	for o in _cars:
		if o == car or int(o.edge) != e or float(o.conn_s) >= 0.0:
			continue
		var gap: float = float(o.s) - HALF_L - s - HALF_L
		if gap >= 0.0 and gap < best:
			best = gap
			other_speed = float(o.speed)
	return [best, other_speed]


func advance(car, ds: float) -> void:
	if car.conn_s >= 0.0:
		var curve: Dictionary = get_move(car.edge, car.move).get("curve", {})
		if curve.is_empty():
			car.conn_s = 0.0
			return
		car.conn_s += ds
		if car.conn_s >= float(curve["len"]):
			var overshoot: float = car.conn_s - float(curve["len"])
			car.edge = int(get_move(car.edge, car.move)["to"])
			car.move = -1
			car.conn_s = -1.0
			car.s = maxf(0.0, overshoot)
		return
	car.s += ds
	var edge_len: float = float((_edges[car.edge] as Dictionary)["len"])
	if car.s >= edge_len:
		if car.move >= 0:
			car.conn_s = 0.0
		else:
			car.s = edge_len - HALF_L


func locate(car, delta: float) -> void:
	var c: float = car.conn_s if car.conn_s >= 0.0 else car.s
	var pp: Array = path_point(car, c)
	var pos: Vector2 = pp[0]
	var d: Vector2 = pp[1]
	var right := Vector2(-d.y, d.x)
	pos += right * float(car.dl) + (car.knock as Vector2) * delta
	car.global_position = Vector3(pos.x, 0.02, pos.y)
	car.call("_apply_rotation")


func shove(car, dx: float, dz: float) -> void:
	var c: float = car.conn_s if car.conn_s >= 0.0 else car.s
	var pp: Array = path_point(car, c)
	var d: Vector2 = pp[1]
	var along := dx * d.x + dz * d.y
	var side := -dx * d.y + dz * d.x
	if car.conn_s >= 0.0:
		var curve: Dictionary = get_move(car.edge, car.move).get("curve", {})
		car.conn_s = clampf(car.conn_s + along, -0.5, float(curve.get("len", 1.0)) - 0.01)
	else:
		car.s = clampf(car.s + along, 0.0, float((_edges[car.edge] as Dictionary)["len"]) - HALF_L)
	car.dl = clampf(float(car.dl) + side, -2.6, 2.6)
	locate(car, 0.0)


## ---------------------------------------------------------------------------
## Contacts rigides (port de vehicle-physics.js)
## ---------------------------------------------------------------------------
func _body(car) -> Dictionary:
	var hx := sin(float(car.yaw))
	var hz := cos(float(car.yaw))
	return {
		"x": car.global_position.x, "z": car.global_position.z,
		"sin": hx, "cos": hz,
		"halfW": HALF_W, "halfL": HALF_L, "mass": MASS,
		"vx": hx * float(car.speed) + (car.knock as Vector2).x,
		"vz": hz * float(car.speed) + (car.knock as Vector2).y,
		"angularVel": float(car.yaw_rate) + float(car.yaw_vel),
	}


func _player_body(p: Node3D) -> Dictionary:
	var fwd: Vector3 = -p.global_transform.basis.z
	var yaw := atan2(fwd.x, fwd.z)
	var v: Vector3 = p.velocity
	return {
		"x": p.global_position.x, "z": p.global_position.z,
		"sin": sin(yaw), "cos": cos(yaw),
		"halfW": 1.0, "halfL": 2.2, "mass": 1400.0,
		"vx": v.x, "vz": v.z, "angularVel": 0.0,
	}


func _collide_traffic() -> void:
	var cars: Array = []
	var bodies: Array = []
	for car in _cars:
		cars.append(car)
		bodies.append(_body(car))
	var player := get_parent().get_node_or_null("Car")
	if player is Node3D:
		cars.append(player)
		bodies.append(_player_body(player as Node3D))

	# Grille spatiale : on ne teste que les voitures des cellules voisines.
	var grid := {}
	for i in bodies.size():
		var key := Vector2i(floori(float(bodies[i]["x"]) / CELL), floori(float(bodies[i]["z"]) / CELL))
		if not grid.has(key):
			grid[key] = []
		(grid[key] as Array).append(i)
	var pairs: Array = []
	for i in bodies.size():
		var cx := floori(float(bodies[i]["x"]) / CELL)
		var cz := floori(float(bodies[i]["z"]) / CELL)
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				for j in grid.get(Vector2i(cx + dx, cz + dz), []):
					if j > i:
						pairs.append(Vector2i(i, j))
	for pair in pairs:
		var i: int = pair.x
		var j: int = pair.y
		if true:
			var a: Dictionary = bodies[i]
			var b: Dictionary = bodies[j]
			var reach: float = float(a["halfL"]) + float(b["halfL"]) + 1.0
			if absf(float(a["x"]) - float(b["x"])) > reach or absf(float(a["z"]) - float(b["z"])) > reach:
				continue
			var hit: Variant = _vehicle_contact(a, b)
			if hit == null:
				continue
			var closing := _resolve_impulse(a, b, hit)
			var depth: float = hit["depth"]
			var nx: float = hit["nx"]
			var nz: float = hit["nz"]
			var share: float = float(b["mass"]) / (float(a["mass"]) + float(b["mass"]))
			# Contact par l'avant : compté pour que la voiture se dégage en
			# reculant si le blocage dure (voir npc_car.front_contact).
			if i < _cars.size():
				_front_contact(cars[i], -nx, -nz)
			if j < _cars.size():
				_front_contact(cars[j], nx, nz)
			if i < _cars.size():
				_apply_body(cars[i], a, nx, nz)
				shove(cars[i], nx * depth * share, nz * depth * share)
			if j < _cars.size():
				_apply_body(cars[j], b, -nx, -nz)
				shove(cars[j], -nx * depth * (1.0 - share), -nz * depth * (1.0 - share))
			if closing <= 0.0:
				continue


## SAT sur les 4 axes des deux boîtes ; normale de b vers a.
func _vehicle_contact(a: Dictionary, b: Dictionary) -> Variant:
	var dx: float = float(a["x"]) - float(b["x"])
	var dz: float = float(a["z"]) - float(b["z"])
	var depth := 1.0e9
	var nx := 0.0
	var nz := 0.0
	for axis in 4:
		var body: Dictionary = a if axis < 2 else b
		var ax: float = float(body["cos"]) if axis % 2 == 0 else float(body["sin"])
		var az: float = -float(body["sin"]) if axis % 2 == 0 else float(body["cos"])
		var separation := dx * ax + dz * az
		var overlap: float = \
			float(a["halfW"]) * absf(ax * float(a["cos"]) - az * float(a["sin"])) + \
			float(a["halfL"]) * absf(ax * float(a["sin"]) + az * float(a["cos"])) + \
			float(b["halfW"]) * absf(ax * float(b["cos"]) - az * float(b["sin"])) + \
			float(b["halfL"]) * absf(ax * float(b["sin"]) + az * float(b["cos"])) - absf(separation)
		if overlap <= 0.0:
			return null
		if overlap < depth:
			depth = overlap
			var sign := 1.0 if separation >= 0.0 else -1.0
			nx = ax * sign
			nz = az * sign
	return {
		"x": (float(a["x"]) + float(b["x"])) * 0.5,
		"z": (float(a["z"]) + float(b["z"])) * 0.5,
		"nx": nx, "nz": nz, "depth": depth,
	}


func _resolve_impulse(a: Dictionary, b: Dictionary, hit: Dictionary) -> float:
	var nx: float = hit["nx"]
	var nz: float = hit["nz"]
	var ax: float = float(hit["x"]) - float(a["x"])
	var az: float = float(hit["z"]) - float(a["z"])
	var bx: float = float(hit["x"]) - float(b["x"])
	var bz: float = float(hit["z"]) - float(b["z"])
	var inv_a: float = 1.0 / maxf(float(a["mass"]), 0.001)
	var inv_b: float = 1.0 / maxf(float(b["mass"]), 0.001)
	var inertia_a := 3.0 * inv_a / (HALF_W * HALF_W + HALF_L * HALF_L)
	var inertia_b := 3.0 * inv_b / (HALF_W * HALF_W + HALF_L * HALF_L)
	var normal_a := az * nx - ax * nz
	var normal_b := bz * nx - bx * nz
	var vx: float = float(a["vx"]) + float(a["angularVel"]) * az - float(b["vx"]) - float(b["angularVel"]) * bz
	var vz: float = float(a["vz"]) - float(a["angularVel"]) * ax - float(b["vz"]) + float(b["angularVel"]) * bx
	var closing: float = -(vx * nx + vz * nz)
	if closing <= 0.0:
		return 0.0
	var restitution := 0.08 if closing > 1.0 else 0.0
	var impulse: float = (1.0 + restitution) * closing / (inv_a + inv_b + normal_a * normal_a * inertia_a + normal_b * normal_b * inertia_b)
	a["vx"] = float(a["vx"]) + nx * impulse * inv_a
	a["vz"] = float(a["vz"]) + nz * impulse * inv_a
	a["angularVel"] = float(a["angularVel"]) + normal_a * impulse * inertia_a
	b["vx"] = float(b["vx"]) - nx * impulse * inv_b
	b["vz"] = float(b["vz"]) - nz * impulse * inv_b
	b["angularVel"] = float(b["angularVel"]) - normal_b * impulse * inertia_b

	# Frottement tangentiel, borné par l'impact normal.
	var tx := nz
	var tz := -nx
	var tangent_a := az * tx - ax * tz
	var tangent_b := bz * tx - bx * tz
	vx = float(a["vx"]) + float(a["angularVel"]) * az - float(b["vx"]) - float(b["angularVel"]) * bz
	vz = float(a["vz"]) - float(a["angularVel"]) * ax - float(b["vz"]) + float(b["angularVel"]) * bx
	var tangent: float = -(vx * tx + vz * tz) / (inv_a + inv_b + tangent_a * tangent_a * inertia_a + tangent_b * tangent_b * inertia_b)
	var friction: float = clampf(tangent, -impulse * 0.35, impulse * 0.35)
	a["vx"] = float(a["vx"]) + tx * friction * inv_a
	a["vz"] = float(a["vz"]) + tz * friction * inv_a
	a["angularVel"] = float(a["angularVel"]) + tangent_a * friction * inertia_a
	b["vx"] = float(b["vx"]) - tx * friction * inv_b
	b["vz"] = float(b["vz"]) - tz * friction * inv_b
	b["angularVel"] = float(b["angularVel"]) - tangent_b * friction * inertia_b
	return closing


## (ox, oz) : direction de l'obstacle vu depuis la voiture.
func _front_contact(car, ox: float, oz: float) -> void:
	if sin(float(car.yaw)) * ox + cos(float(car.yaw)) * oz > 0.5:
		car.front_contact = float(car.front_contact) + 1.0 / float(Engine.physics_ticks_per_second)


func _apply_body(car, body: Dictionary, nx: float, nz: float) -> void:
	var hx := sin(float(car.yaw))
	var hz := cos(float(car.yaw))
	car.speed = maxf(-3.0, float(body["vx"]) * hx + float(body["vz"]) * hz)
	car.knock = Vector2(float(body["vx"]) - hx * float(car.speed), float(body["vz"]) - hz * float(car.speed))
	car.yaw_vel = float(body["angularVel"]) - float(car.yaw_rate)
	# Un choc désaxé fait aussi tourner la voiture, comme dans le source.
	var side := nx * (-hz) + nz * hx
	car.yaw_vel = clampf(float(car.yaw_vel) + side * 0.7, -2.2, 2.2)
	car.impact_time = maxf(float(car.impact_time), 0.55)
	car.stalled = 0.0


## ---------------------------------------------------------------------------
## Création / recyclage
## ---------------------------------------------------------------------------
func _load_prefabs() -> void:
	var dir := DirAccess.open(CAR_DIR)
	if dir == null:
		return
	var files := dir.get_files()
	files.sort()
	for f in files:
		if not f.ends_with(".tscn"):
			continue
		var scene: PackedScene = load(CAR_DIR + "/" + f)
		if scene != null:
			_prefabs.append({"name": f, "scene": scene})


## Remplace les matériaux PBR des NPC par des matériaux bon marché : on garde
## la couleur / la texture de carrosserie, mais on supprime metallic, roughness,
## normal map et reflets spéculaires (inutiles sur des voitures de fond).
## Le cache évite de créer un matériau par voiture : ~40 matériaux pour 100 NPC.
func _apply_material_mode(node: Node, reflections: bool) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mesh := mi.mesh
		if mesh != null:
			for s in mesh.get_surface_count():
				var src: Material = mi.get_surface_override_material(s)
				if src == null:
					src = mesh.surface_get_material(s)
				if src == null:
					continue
				if reflections:
					if _orig_by_flat.has(src.get_instance_id()):
						mi.set_surface_override_material(s, _orig_by_flat[src.get_instance_id()])
				else:
					mi.set_surface_override_material(s, _flat_material(src))
	for child in node.get_children():
		_apply_material_mode(child, reflections)


## Applique le réglage à toutes les voitures déjà présentes, sans recharger.
func set_reflections(enabled: bool) -> void:
	for car in _cars:
		var visual: Node = car.get_node_or_null("Visual")
		if visual != null:
			_apply_material_mode(visual, enabled)


func _flat_material(src: Material) -> Material:
	if not src is StandardMaterial3D:
		return src
	var key := src.get_instance_id()
	if _flat_materials.has(key):
		return _flat_materials[key]
	# Déjà une version simplifiée : on la garde telle quelle.
	if _orig_by_flat.has(key):
		return src
	var s := src as StandardMaterial3D
	var mat := StandardMaterial3D.new()
	mat.resource_name = s.resource_name + " (flat)"
	mat.albedo_color = s.albedo_color
	mat.albedo_texture = s.albedo_texture
	mat.uv1_scale = s.uv1_scale
	mat.uv1_offset = s.uv1_offset
	mat.transparency = s.transparency
	mat.cull_mode = s.cull_mode
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	# Plus de reflets : spéculaire et métallique désactivés, rugosité max.
	if "specular" in mat:
		mat.set("specular", 0.0)
	if "specular_mode" in mat:
		mat.set("specular_mode", BaseMaterial3D.SPECULAR_DISABLED)
	mat.metallic = 0.0
	mat.metallic_texture = null
	mat.roughness = 1.0
	mat.roughness_texture = null
	mat.normal_texture = null
	_flat_materials[key] = mat
	_orig_by_flat[mat.get_instance_id()] = src
	return mat


func _spawn(i: int) -> void:
	var pick := _random_start()
	if pick.is_empty():
		return
	var e: int = pick[0]
	var start_s: float = pick[1]

	var body := CharacterBody3D.new()
	body.name = "NPC%d" % i
	body.set_script(CarScript)
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := BoxShape3D.new()
	shape.size = Vector3(HALF_W * 2.0, 1.4, HALF_L * 2.0)
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)

	var entry: Dictionary = _prefabs[i % _prefabs.size()]
	var visual: Node3D = (entry["scene"] as PackedScene).instantiate()
	visual.name = "Visual"
	_apply_material_mode(visual, Game.npc_reflections)
	body.add_child(visual)

	add_child(body)
	body.call("setup", self, e, start_s, randf_range(9.0, 13.0), float(FRONT.get(entry["name"], -1.0)))
	_cars.append(body)


func _random_start() -> Array:
	var player := get_parent().get_node_or_null("Car")
	var pp := Vector2.ZERO
	if player is Node3D:
		pp = Vector2((player as Node3D).global_position.x, (player as Node3D).global_position.z)
	for _i in 200:
		var e: int = randi() % _edges.size()
		var edge: Dictionary = _edges[e]
		if (edge["moves"] as Array).is_empty():
			continue
		var s := randf_range(1.0, float(edge["len"]) - 3.0)
		if not _spawn_ok(e, s):
			continue
		var pos: Vector2 = lane_point(e, s)[0]
		if pos.distance_to(pp) < SAFE_RADIUS:
			continue
		if _lane_clear(e, s, 9.0):
			return [e, s]
	for e in _edges.size():
		if not (_edges[e] as Dictionary)["moves"].is_empty() and _spawn_ok(e, 2.0) and _lane_clear(e, 2.0, 5.0):
			return [e, 2.0]
	return []


## Pas d'apparition dans une zone de carrefour ni juste avant sa ligne d'arrêt :
## la voiture devrait y forcer le passage et se bloquer contre le trafic.
func _spawn_ok(e: int, s: float) -> bool:
	var edge: Dictionary = _edges[e]
	if is_gated(int(edge["from"])) and s < ZONE + HALF_L + 1.0:
		return false
	if is_gated(int(edge["to"])) and s > float(edge["len"]) - 6.0 - HALF_L - 2.0:
		return false
	return true


func _lane_clear(e: int, s: float, margin: float) -> bool:
	for car in _cars:
		if int(car.edge) == e and absf(float(car.s) - s) < margin:
			return false
	return true


## Appelé au besoin pour ramener une voiture éloignée près du joueur.
func recycle(car) -> void:
	var pick := _random_start()
	if pick.is_empty():
		return
	var e: int = pick[0]
	release(car)
	car.wait_time = 0.0
	car.edge = e
	car.move = -1
	car.conn_s = -1.0
	car.s = pick[1]
	car.speed = 8.0
	car.knock = Vector2.ZERO
	car.dl = 0.0
	car.yaw_vel = 0.0
	car.impact_time = 0.0
	locate(car, 0.0)
	car.prev_pos = Vector2(car.global_position.x, car.global_position.z)
