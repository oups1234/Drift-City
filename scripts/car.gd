extends CharacterBody3D

const GROUND_Y := 0.02
## Calque 4 (valeur 8) : faces de sol sondees par raycast, sans collision
## physique, pour pouvoir monter sur les trottoirs.
const GROUND_LAYER := 8
const STEP_HEIGHT := 0.62
const GROUND_PROBE := 3.0
const FALL_GRAVITY := 22.0
## Water is driveable: no invisible wall stops the player. After a short
## splash the car is returned to the last point on land with a small world
## limit message (no death card).
const WATER_Y := -0.12
const WATER_LIMIT_DELAY := 0.9
const WATER_SINK_SPEED := 0.35
const WATER_SINK_MAX := 0.42

const NITRO_TOP_SPEED := 10.0
const NITRO_ACCEL := 14.0
const NITRO_DRAIN := 0.36
const NITRO_RECHARGE := 0.11

const CAM_MOUSE_SENS := 0.0026
const CAM_PITCH_MIN := 0.05
const CAM_PITCH_MAX := 1.15
const CAM_ZOOM_MIN := 4.5
const CAM_ZOOM_MAX := 16.0
const CAM_ZOOM_FACTOR := 0.88
const CAM_DEFAULT_DIST := 8.6
const CAM_DEFAULT_PITCH := 0.34
## Ignore the mouse warp macOS emits when the pointer is captured, and any
## implausible single jump (a real flick stays well below this).
const CAM_MOUSE_GRACE := 0.35
const CAM_MOUSE_MAX_STEP := 140.0

const VISUAL_STEER_MAX := 0.62
const VISUAL_STEER_SPEED := 12.0

var spec: Dictionary = {}
var hud: CanvasLayer
var drifting := false
var drift_meters := 0.0
var nitro := 1.0
var nitro_active := false

var _stats: Dictionary = {}
var _visual: Node3D
var _camera: Camera3D
var _cam_pos := Vector3.ZERO
var _forward_speed := 0.0
var _lateral := 0.0
var _pre_move_speed := 0.0
var _drift_exit := 0.0
var _was_colliding := false
var _fall_speed := 0.0
var _water_time := 0.0
var _water_sink := 0.0
## Dernier point sur terre, utilisé pour revenir après être entré dans l'eau.
var _last_land_position := Vector3.ZERO
var _last_land_yaw := 0.0
var _spawn_position := Vector3.ZERO
var _spawn_yaw := 0.0
var _car_width := 1.9
var _car_length := 4.2
var _car_height := 1.48
var _smoke_t := 0.0
var _smoke_log := 0.0
var _cam_yaw := 0.0
var _cam_pitch := CAM_DEFAULT_PITCH
var _cam_dist := CAM_DEFAULT_DIST
var _mouse_grace := 0.0
var _wheels: Array = []
var _rear_wheels: Array = []
var _skid: SkidMarks


func _ready() -> void:
	var id := OS.get_environment("DRIFT_CAR")
	if id.is_empty():
		id = Game.selected_car_id
	spec = CarCatalog.by_index(CarCatalog.index_of_id(id))
	_stats = spec.get("stats", {})
	Game.selected_car_id = spec["id"]

	motion_mode = MOTION_MODE_FLOATING
	collision_layer = 2
	collision_mask = 1
	_spawn_position = global_position
	_spawn_yaw = rotation.y
	_last_land_position = global_position
	_last_land_yaw = rotation.y
	_build_visuals()
	_build_camera()
	_cam_pos = _camera_desired()
	set_process_input(true)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_mouse_grace = CAM_MOUSE_GRACE
	Sound.start_car_sounds()


func _exit_tree() -> void:
	Sound.stop_car_sounds()


func bind_hud(node: CanvasLayer) -> void:
	hud = node


func car_name() -> String:
	return String(spec.get("name", "Car"))


func reset_to_spawn() -> void:
	global_position = _spawn_position
	rotation = Vector3(0.0, _spawn_yaw, 0.0)
	velocity = Vector3.ZERO
	_fall_speed = 0.0
	_forward_speed = 0.0
	_lateral = 0.0
	_water_time = 0.0
	_water_sink = 0.0
	_last_land_position = global_position
	_last_land_yaw = rotation.y
	# Téléportation : pas d'interpolation entre l'ancienne et la nouvelle place.
	reset_physics_interpolation()
	if hud:
		hud.hide_limit()
	drifting = false
	drift_meters = 0.0
	_drift_exit = 0.0
	_was_colliding = false
	nitro = 1.0
	nitro_active = false
	_cam_yaw = 0.0
	_cam_pitch = CAM_DEFAULT_PITCH
	_cam_dist = CAM_DEFAULT_DIST
	if _skid:
		_skid.reset()
	if _visual:
		_visual.rotation = Vector3.ZERO
	for w in _wheels:
		var pivot: Node3D = w["pivot"]
		var spin: Node3D = w["spin"]
		pivot.rotation.y = 0.0
		spin.rotation.x = 0.0


func _physics_process(delta: float) -> void:
	_update_nitro(delta)
	_smoke_drive(delta)
	_step_up()
	_drive(delta)
	_resolve_ground(delta)
	_check_water(delta)
	var moved := Vector2(velocity.x, velocity.z).length() * delta
	var hit := get_slide_collision_count() > 0
	if hit and not _was_colliding:
		_crash()
	if hit:
		_was_colliding = true
	else:
		_was_colliding = false
		_update_drift(delta, moved)
	_update_skid()


## Hauteur du sol sous un point. Les faces de route/trottoir sont sur le
## calque 8 ; en leur absence on retombe sur le sol virtuel y = GROUND_Y.
func _ground_hit_at(p: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	if space == null:
		return {}
	var q := PhysicsRayQueryParameters3D.create(
		p + Vector3.UP * 1.5, p - Vector3.UP * GROUND_PROBE, GROUND_LAYER)
	q.exclude = [get_rid()]
	return space.intersect_ray(q)


func _ground_height_at(p: Vector3) -> float:
	var hit := _ground_hit_at(p)
	if hit.is_empty():
		return GROUND_Y
	return float(hit["position"].y)


## The harbour has no walls: the player can drive straight into the water.
## After a short splash the car is sent back to the last point on land.
func _is_over_water() -> bool:
	var hit := _ground_hit_at(global_position)
	return hit.is_empty() or float(hit["position"].y) < WATER_Y


func _check_water(delta: float) -> void:
	if not _is_over_water():
		# On land: remember where to come back if we drive into the harbour.
		_water_time = 0.0
		_water_sink = 0.0
		_last_land_position = global_position
		_last_land_yaw = rotation.y
		return
	_water_time += delta
	_water_sink = minf(_water_sink + WATER_SINK_SPEED * delta, WATER_SINK_MAX)
	global_position.y = GROUND_Y - _water_sink
	# The water slows the car down before the world limit pushes it back.
	var drag := clampf(1.0 - 0.5 * delta, 0.0, 1.0)
	velocity.x *= drag
	velocity.z *= drag
	if _water_time >= WATER_LIMIT_DELAY:
		_return_to_last_land()


func _return_to_last_land() -> void:
	global_position = _last_land_position
	global_position.y = _ground_height_at(global_position) + 0.02
	rotation.y = _last_land_yaw
	reset_physics_interpolation()
	velocity = Vector3.ZERO
	_fall_speed = 0.0
	_forward_speed = 0.0
	_lateral = 0.0
	_water_time = 0.0
	_water_sink = 0.0
	drifting = false
	drift_meters = 0.0
	_drift_exit = 0.0
	_was_colliding = false
	if _skid:
		_skid.reset()
	if hud:
		hud.show_limit()


## Monte sur un trottoir avant le déplacement horizontal : sans cela la boîte
## de collision heurterait la bordure comme un mur.
func _step_up() -> void:
	var fwd := -global_transform.basis.z
	var ahead := global_position + fwd * 1.7
	var h := maxf(_ground_height_at(global_position), _ground_height_at(ahead))
	if h > global_position.y and h - global_position.y <= STEP_HEIGHT:
		global_position.y = h
		_fall_speed = 0.0


## Après le déplacement : suit le sol, ou tombe si la surface est plus basse.
func _resolve_ground(delta: float) -> void:
	var h := _ground_height_at(global_position)
	if h >= global_position.y - 0.22:
		global_position.y = h
		_fall_speed = 0.0
		return
	_fall_speed += FALL_GRAVITY * delta
	global_position.y = maxf(h, global_position.y - _fall_speed * delta)
	if global_position.y <= h + 0.001:
		_fall_speed = 0.0


func _process(delta: float) -> void:
	_mouse_grace = maxf(_mouse_grace - delta, 0.0)
	_update_camera(delta)
	_update_body(delta)
	_animate_wheels(delta)
	_update_audio()
	_update_hud()


## Le moteur suit la vitesse et la charge ; le crissement suit le glissement
## latéral, avec un plancher quand le frein à main est tiré.
func _update_audio() -> void:
	var speed := Vector2(velocity.x, velocity.z).length()
	var throttle := absf(Input.get_axis("brake", "accelerate"))
	Sound.update_engine(speed, throttle, nitro_active)
	var speed_gate := clampf((speed - 3.0) / 10.0, 0.0, 1.0)
	var slip := clampf((absf(_lateral) - 1.6) / 5.0, 0.0, 1.0)
	var intensity := slip * speed_gate
	if drifting:
		intensity = maxf(intensity, 0.58)
	if Input.is_action_pressed("handbrake") and speed > 4.0:
		intensity = maxf(intensity, 0.7 * speed_gate)
	Sound.update_skid(intensity)


func _update_nitro(delta: float) -> void:
	var throttle := Input.get_axis("brake", "accelerate")
	var want := Input.is_action_pressed("nitro") and throttle > 0.0 and nitro > 0.02
	nitro_active = want
	if nitro_active:
		nitro = maxf(nitro - NITRO_DRAIN * delta, 0.0)
		if nitro <= 0.0:
			nitro_active = false
	else:
		nitro = minf(nitro + NITRO_RECHARGE * delta, 1.0)


func _drive(delta: float) -> void:
	var steer := Input.get_axis("steer_right", "steer_left")
	var throttle := Input.get_axis("brake", "accelerate")
	var handbrake := Input.is_action_pressed("handbrake")

	var top_speed: float = _stat("max_speed", 33.0) + (NITRO_TOP_SPEED if nitro_active else 0.0)
	var accel: float = _stat("accel", 18.0) + (NITRO_ACCEL if nitro_active else 0.0)
	var grip: float = _stat("handbrake_grip", 2.1) if handbrake else _stat("grip", 12.0)

	var vel := Vector2(velocity.x, velocity.z)
	var speed := vel.length()
	var forward := -global_transform.basis.z
	var fwd2 := Vector2(forward.x, forward.z).normalized()
	var fwd_speed := vel.dot(fwd2)
	var reverse := fwd_speed < -0.5
	var dir := -1.0 if reverse else 1.0

	# Rotation du châssis. Elle s'annule à l'arrêt pour éviter de tourner
	# sur place, et s'inverse en marche arrière.
	var speed_factor := clampf(speed / 8.0, 0.0, 1.0)
	var yaw_rate := deg_to_rad(_stat("steer_rate", 75.0))
	if handbrake and speed > 4.0:
		yaw_rate = deg_to_rad(_stat("handbrake_steer", 115.0))
	rotation.y += yaw_rate * steer * dir * speed_factor * delta

	forward = -global_transform.basis.z
	fwd2 = Vector2(forward.x, forward.z).normalized()

	# Le grip ramène la trajectoire vers le cap. Plus il est faible (frein à
	# main), plus la voiture glisse : l'angle de dérive se stabilise au lieu
	# de partir en tête-à-queue.
	if speed > 0.5:
		var target := fwd2 * dir
		var ang := vel.angle_to(target)
		vel = vel.rotated(ang * clampf(grip * delta, 0.0, 1.0))

	# Moteur, frein et frein moteur.
	var drive := 0.0
	if throttle > 0.0:
		drive = accel * throttle
	elif throttle < 0.0:
		drive = (30.0 if fwd_speed > 0.4 else 10.0) * throttle
	else:
		drive = -signf(fwd_speed) * 3.2
	if handbrake:
		drive += -signf(fwd_speed) * 4.0
	vel += fwd2 * drive * delta

	# Résistance de l'air et des roulements.
	vel *= 1.0 - clampf(0.12 * delta, 0.0, 1.0)
	var spd := vel.length()
	if spd > top_speed:
		vel = vel / spd * top_speed
	_pre_move_speed = vel.length()

	velocity = Vector3(vel.x, 0.0, vel.y)
	move_and_slide()
	velocity.y = 0.0

	forward = -global_transform.basis.z
	var right := global_transform.basis.x
	_forward_speed = velocity.dot(forward)
	_lateral = velocity.dot(right)


func _crash() -> void:
	var show := drifting and drift_meters >= 1.0
	Sound.play_crash(clampf(_pre_move_speed / 18.0, 0.12, 1.0))
	drifting = false
	drift_meters = 0.0
	_drift_exit = 0.0
	if Vector2(velocity.x, velocity.z).length() > 4.0:
		velocity *= 0.32
	if show and hud:
		hud.show_crash()


func _update_drift(delta: float, moved: float) -> void:
	var speed := Vector2(velocity.x, velocity.z).length()
	var slip := rad_to_deg(absf(atan2(_lateral, maxf(_forward_speed, 0.1))))
	var angle := 11.0 if drifting else 20.0
	var sliding: bool = speed > 8.0 and _forward_speed > 2.0 and absf(_lateral) > 2.2 and slip > angle
	if drifting:
		if sliding:
			_drift_exit = 0.0
			drift_meters += moved
		else:
			_drift_exit += delta
			if _drift_exit >= 0.3:
				_bank()
	elif sliding:
		drifting = true
		_drift_exit = 0.0
		drift_meters += moved


func _bank() -> void:
	var meters := drift_meters
	drifting = false
	drift_meters = 0.0
	_drift_exit = 0.0
	var amount := int(round(meters * float(_multiplier(meters))))
	if amount <= 0:
		return
	Game.add_money(amount)
	if hud:
		hud.show_bank(amount)


func _multiplier(meters: float) -> int:
	if meters >= 500.0:
		return 5
	if meters >= 200.0:
		return 4
	if meters >= 100.0:
		return 3
	if meters >= 50.0:
		return 2
	return 1


func _update_hud() -> void:
	if hud == null:
		return
	var kmh := Vector2(velocity.x, velocity.z).length() * 3.6
	var mult := _multiplier(drift_meters) if drifting else 1
	var cash := int(round(drift_meters * float(mult))) if drifting else 0
	hud.set_state(kmh, Game.wallet, drift_meters, mult, cash, drifting, Input.is_action_pressed("handbrake"), nitro, nitro_active, car_name())


func _update_body(delta: float) -> void:
	if _visual == null:
		return
	var roll := clampf(-_lateral / 30.0, -0.07, 0.07)
	var pitch := clampf(-_forward_speed / 240.0, -0.035, 0.035)
	var t := 1.0 - exp(-6.0 * delta)
	_visual.rotation.z = lerpf(_visual.rotation.z, roll, t)
	_visual.rotation.x = lerpf(_visual.rotation.x, pitch, t)


func _animate_wheels(delta: float) -> void:
	if _wheels.is_empty():
		return
	var steer := Input.get_axis("steer_right", "steer_left")
	var handbrake := Input.is_action_pressed("handbrake")
	var t := 1.0 - exp(-VISUAL_STEER_SPEED * delta)
	for w in _wheels:
		var pivot: Node3D = w["pivot"]
		var spin: Node3D = w["spin"]
		var radius: float = maxf(w["radius"], 0.05)
		var front: bool = w["front"]
		# Les roues arrière se bloquent au frein à main.
		var speed := _forward_speed if (front or not handbrake) else 0.0
		if absf(speed) > 0.04:
			spin.rotation.x = wrapf(spin.rotation.x - speed * delta / radius, -PI, PI)
		if front:
			pivot.rotation.y = lerp_angle(pivot.rotation.y, steer * VISUAL_STEER_MAX, t)


func _update_skid() -> void:
	if _skid == null:
		return
	var speed := Vector2(velocity.x, velocity.z).length()
	var handbrake := Input.is_action_pressed("handbrake")
	var emitting := (drifting or (handbrake and speed > 4.0)) and speed > 2.0
	if not emitting:
		_skid.reset()
		return
	var basis := global_transform.basis
	for i in _rear_wheels.size():
		var c: Vector3 = _rear_wheels[i]
		var p := global_position + basis * Vector3(c.x, 0.0, c.z)
		# Follow the real surface (road, pavement) instead of a fixed height:
		# marks no longer float above or cut through the ground.
		p.y = _ground_height_at(p) + 0.02
		_skid.add_point(i, p)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if _mouse_grace > 0.0 or event.relative.length() > CAM_MOUSE_MAX_STEP:
			return
		_cam_yaw = wrapf(_cam_yaw - event.relative.x * CAM_MOUSE_SENS, -PI, PI)
		_cam_pitch = clampf(_cam_pitch + event.relative.y * CAM_MOUSE_SENS, CAM_PITCH_MIN, CAM_PITCH_MAX)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cam_dist = clampf(_cam_dist * CAM_ZOOM_FACTOR, CAM_ZOOM_MIN, CAM_ZOOM_MAX)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cam_dist = clampf(_cam_dist / CAM_ZOOM_FACTOR, CAM_ZOOM_MIN, CAM_ZOOM_MAX)


## La voiture bouge au rythme de la physique (60 Hz) mais la caméra à chaque
## image (jusqu'à 120 Hz et plus) : on suit la position interpolée, sinon la
## voiture avance une image sur deux et la caméra tremble.
func _camera_pivot() -> Vector3:
	return get_global_transform_interpolated().origin + Vector3.UP * (_car_height * 0.5)


func _camera_desired() -> Vector3:
	var pivot := _camera_pivot()
	var heading := -get_global_transform_interpolated().basis.z
	var orbit := Basis(Vector3.UP, _cam_yaw) * heading
	var back := -orbit.normalized()
	var horiz := cos(_cam_pitch) * _cam_dist
	var vert := sin(_cam_pitch) * _cam_dist
	return pivot + back * horiz + Vector3.UP * vert


func _update_camera(delta: float) -> void:
	if _camera == null:
		return
	var pivot := _camera_pivot()
	var desired := _camera_desired()
	var space := get_world_3d().direct_space_state
	if space:
		var query := PhysicsRayQueryParameters3D.create(pivot, desired, 1)
		query.exclude = [get_rid()]
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			var dir := desired - pivot
			var dist := dir.length()
			if dist > 0.01:
				dir /= dist
				var pull := maxf(pivot.distance_to(hit.position) - 0.45, 1.4)
				desired = pivot + dir * minf(pull, dist)
	_cam_pos = _cam_pos.lerp(desired, 1.0 - exp(-9.0 * delta))
	_camera.global_position = _cam_pos
	if _cam_pos.distance_squared_to(pivot) > 0.04:
		_camera.look_at(pivot, Vector3.UP)
	var target_fov := 68.0 + (7.0 if nitro_active else 0.0)
	_camera.fov = lerpf(_camera.fov, target_fov, 1.0 - exp(-5.0 * delta))


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 68.0
	_camera.near = 0.15
	_camera.far = 2400.0
	_camera.current = true
	# Placée à la main dans _process à partir de la pose interpolée.
	_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_camera)


func _build_visuals() -> void:
	_visual = Node3D.new()
	_visual.name = "Visual"
	add_child(_visual)

	var model := CarModel.build(spec)
	_visual.add_child(model)
	var size: Vector3 = model.get_meta("size", Vector3(1.9, 1.4, 4.2))
	_car_width = size.x
	_car_height = size.y
	_car_length = size.z

	_wheels = model.get_meta("wheels", [])
	_rear_wheels.clear()
	for w in _wheels:
		if not bool(w["front"]):
			_rear_wheels.append(w["center"])
	if _rear_wheels.is_empty():
		_rear_wheels.append(Vector3(-_car_width * 0.40, 0.0, _car_length * 0.32))
		_rear_wheels.append(Vector3(_car_width * 0.40, 0.0, _car_length * 0.32))

	_skid = SkidMarks.new()
	_skid.name = "SkidMarks"
	add_child(_skid)
	_skid.setup()

	var shape := BoxShape3D.new()
	shape.size = Vector3(_car_width, _car_height, _car_length)
	var col := get_node_or_null("CollisionShape3D")
	if col:
		col.shape = shape
		col.position = Vector3(0, _car_height * 0.5, 0)

	_build_blob_shadow()


func _build_blob_shadow() -> void:
	var shadow := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(_car_width * 0.7, 0.02, _car_length * 0.8)
	shadow.mesh = box
	shadow.position = Vector3(0, 0.03, 0)
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0, 0, 0, 0.32)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow.material_override = mat
	add_child(shadow)


func _stat(key: String, fallback: float) -> float:
	return float(_stats.get(key, fallback))


func _smoke_drive(delta: float) -> void:
	if OS.get_environment("DRIFT_SMOKE") != "1":
		return
	var long := OS.get_environment("DRIFT_SMOKE_LONG") == "1"
	var drift_end := 16.0 if long else 5.0
	var quit_at := 18.0 if long else 7.5
	_smoke_t += delta
	# Phase 1 : accélération. Phase 2 : drift au frein à main.
	# Phase 3 : on relâche tout pour que le drift se transforme en argent.
	if _smoke_t < drift_end + 1.0:
		Input.action_press("accelerate")
	else:
		Input.action_release("accelerate")
	if _smoke_t > 2.4 and _smoke_t < drift_end:
		Input.action_press("handbrake")
		Input.action_press("steer_left")
	else:
		Input.action_release("handbrake")
		Input.action_release("steer_left")
	if _smoke_t > drift_end and _smoke_t < quit_at - 1.0:
		Input.action_press("brake")
	else:
		Input.action_release("brake")
	if _smoke_t - _smoke_log > (1.5 if long else 0.5):
		_smoke_log = _smoke_t
		var slip := rad_to_deg(absf(atan2(_lateral, maxf(_forward_speed, 0.1))))
		print("t=%.1f speed=%.1f lat=%.1f slip=%.0f drift=%.1f drifting=%s wallet=%d" % [_smoke_t, Vector2(velocity.x, velocity.z).length(), _lateral, slip, drift_meters, drifting, Game.wallet])
	if _smoke_t >= quit_at:
		print("SMOKE car=", car_name(), " pos=", global_position, " speed=", snapped(Vector2(velocity.x, velocity.z).length(), 0.1), " drift=", snapped(drift_meters, 0.1), " wallet=", Game.wallet, " drifting=", drifting)
		get_tree().quit()
