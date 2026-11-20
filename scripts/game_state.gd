extends Node

## Shared state between the menu and the city.
##
## The wallet, the owned cars and the last selected car are saved to
## `user://progress.cfg` so a purchase survives a restart.

const SAVE_PATH := "user://progress.cfg"
const MIN_NPC := 0
const MAX_NPC := 100
const DEFAULT_NPC := 40

var selected_car_id := "aveo"
var wallet := 0
var owned: Dictionary = {"aveo": true}
var npc_count := DEFAULT_NPC
## PBR reflections on NPC cars (off by default: cheaper on integrated GPUs).
var npc_reflections := false
## Audio toggles, also stored in the save file.
var music_enabled := true
var sfx_enabled := true
## Overridable so automated tests never touch the player's real save.
var save_path := SAVE_PATH


func _ready() -> void:
	var custom := OS.get_environment("DRIFT_SAVE_PATH")
	if not custom.is_empty():
		save_path = custom
	load_progress()


func owns(id: String) -> bool:
	return bool(owned.get(id, false))


func price_of(id: String) -> int:
	return CarCatalog.price_of_id(id)


func missing_for(id: String) -> int:
	if owns(id):
		return 0
	return maxi(price_of(id) - wallet, 0)


## Buys a car if the player can afford it. Returns true when the car is owned
## afterwards, so the caller can distinguish a successful purchase from a
## failed one.
func buy_car(id: String) -> bool:
	if owns(id):
		return true
	var cost := price_of(id)
	if wallet < cost:
		return false
	wallet -= cost
	owned[id] = true
	selected_car_id = id
	save_progress()
	return true


func add_money(amount: int) -> void:
	if amount <= 0:
		return
	wallet += amount
	save_progress()


func select_car(id: String) -> void:
	if not owns(id):
		return
	selected_car_id = id
	save_progress()


func set_npc_count(count: int) -> void:
	var value := clampi(count, MIN_NPC, MAX_NPC)
	if value == npc_count:
		return
	npc_count = value
	save_progress()


func set_npc_reflections(enabled: bool) -> void:
	if enabled == npc_reflections:
		return
	npc_reflections = enabled
	save_progress()


func set_music_enabled(enabled: bool) -> void:
	if enabled == music_enabled:
		return
	music_enabled = enabled
	Sound.apply_settings()
	save_progress()


func set_sfx_enabled(enabled: bool) -> void:
	if enabled == sfx_enabled:
		return
	sfx_enabled = enabled
	Sound.apply_settings()
	save_progress()


func load_progress() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(save_path) == OK:
		wallet = maxi(int(cfg.get_value("player", "wallet", 0)), 0)
		selected_car_id = String(cfg.get_value("player", "car", "aveo"))
		npc_count = clampi(int(cfg.get_value("player", "npc_count", DEFAULT_NPC)), MIN_NPC, MAX_NPC)
		npc_reflections = bool(cfg.get_value("player", "npc_reflections", false))
		music_enabled = bool(cfg.get_value("player", "music_enabled", true))
		sfx_enabled = bool(cfg.get_value("player", "sfx_enabled", true))
		var ids: Array = cfg.get_value("player", "owned", ["aveo"])
		owned.clear()
		for id in ids:
			owned[String(id)] = true
	# The Aveo is always in the garage, even on a fresh save.
	owned["aveo"] = true
	if not owns(selected_car_id):
		selected_car_id = "aveo"


func save_progress() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("player", "wallet", wallet)
	cfg.set_value("player", "car", selected_car_id)
	cfg.set_value("player", "npc_count", npc_count)
	cfg.set_value("player", "npc_reflections", npc_reflections)
	cfg.set_value("player", "music_enabled", music_enabled)
	cfg.set_value("player", "sfx_enabled", sfx_enabled)
	var ids: Array = []
	for id in owned.keys():
		if bool(owned[id]):
			ids.append(String(id))
	ids.sort()
	cfg.set_value("player", "owned", ids)
	cfg.save(save_path)
