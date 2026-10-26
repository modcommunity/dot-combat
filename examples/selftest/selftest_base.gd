extends Node

## The harness every dot-combat self-test section runs on: counters, assertions, fixtures.

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

## A stand-in for dot-server's DotConVar, which this addon may not name: what
## [method DotCombatManager.bind_cvars] duck-types (a `changed` signal, `get_string`,
## `with_range`), holding a value an operator set before the manager bound it.
class FakeCvar extends RefCounted:
	signal changed(old_value: String, new_value: String)
	var cvar_name := ""
	var value := ""
	var flags := 0
	var low := -1.0
	var high := -1.0

	func get_string() -> String:
		return value

	func with_range(p_min: float, p_max: float) -> FakeCvar:
		low = p_min
		high = p_max
		return self

	func set_value(text: String) -> void:
		var old := value
		value = text
		changed.emit(old, text)


## Stands in for dot-server's DotClientLink: the two members follow_cvars asks for.
class FakeLink extends Node:
	signal replicated_cvar_changed(cvar_name: String, value: String)
	var replicated_cvars := {}

	func replicated_cvar(cvar_name: String, fallback: String = "") -> String:
		return String(replicated_cvars.get(cvar_name, fallback))

	func tell(cvar_name: String, value: String) -> void:
		replicated_cvars[cvar_name] = value
		replicated_cvar_changed.emit(cvar_name, value)


## Players built by [method _make_player], torn down between groups.
var _players: Array[Node3D] = []

func _section(title: String) -> void:
	_entered += 1
	_group(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return condition


func _close(a: float, b: float, what: String, epsilon: float = 0.01) -> bool:
	return _check(absf(a - b) <= epsilon, what, "%.4f vs %.4f" % [a, b])


func _group(title: String) -> void:
	print("")
	print("%s" % title)


# --- Fixtures --------------------------------------------------------------

func _bullet() -> DotDamageType:
	var type := DotDamageType.make(&"bullet", "Bullet")
	type.armour_share = 0.5
	type.armour_wear = 1.0
	type.falloff_start = 20.0
	type.falloff_end = 60.0
	type.falloff_floor = 0.5
	return type


## A rifle shot, ready to resolve.
##
## A [DotShot] rather than a weapon: dot-combat no longer knows what a weapon is, and
## a shot now carries the six numbers the resolver actually needs. dot-weapon's suite
## covers the half that decides a shot happened.
func _rifle_shot(attacker: int, tick: int, index: int) -> DotShot:
	var shot := DotShot.make(&"rifle", attacker, tick, index)
	shot.damage = 25.0
	shot.damage_type = _bullet()
	shot.max_range = 200.0
	shot.spread = 0.0
	shot.pellet_count = 1
	return shot


## A rocket shot: no direct damage, a five-metre splash that hurts its own shooter.
func _rocket_shot(type: DotDamageType, attacker: int, tick: int, index: int) -> DotShot:
	var shot := DotShot.make(&"rocket", attacker, tick, index)
	shot.damage = 0.0
	shot.damage_type = type
	shot.splash_type = type
	shot.splash_radius = 5.0
	shot.splash_damage = 100.0
	shot.splash_hurts_owner = true
	shot.max_range = 100.0
	return shot


## A player: a body node with a [DotHealth] and a [DotHitboxSet] of three hitboxes.
##
## Built by hand rather than from a scene so the whole fixture is visible here — a
## self-test whose fixture is a .tscn is a self-test nobody can read.
func _make_player(position: Vector3, max_health: float = 100.0) -> Node3D:
	var body := Node3D.new()
	body.position = position

	var health := DotHealth.new()
	health.max_health = max_health
	health.regen_per_second = 0.0
	body.add_child(health)

	var set_node := DotHitboxSet.new()
	set_node.bounds_offset = Vector3(0.0, 0.9, 0.0)
	set_node.bounds_radius = 1.4

	var head := DotHitbox.new()
	head.group = DotHitGroup.HEAD
	head.shape = DotHitbox.Shape.SPHERE
	head.radius = 0.14
	head.position = Vector3(0.0, 1.62, 0.0)
	head.precedence = 10
	set_node.add_child(head)

	var chest := DotHitbox.new()
	chest.group = DotHitGroup.CHEST
	chest.shape = DotHitbox.Shape.CAPSULE
	chest.radius = 0.28
	chest.height = 1.1
	chest.position = Vector3(0.0, 1.0, 0.0)
	set_node.add_child(chest)

	var legs := DotHitbox.new()
	legs.group = DotHitGroup.LEG
	legs.shape = DotHitbox.Shape.CAPSULE
	legs.radius = 0.22
	legs.height = 0.9
	legs.position = Vector3(0.0, 0.45, 0.0)
	set_node.add_child(legs)

	body.add_child(set_node)
	add_child(body)
	set_node.refresh()

	_players.append(body)
	return body


func _health_of(body: Node3D) -> DotHealth:
	for child in body.get_children():
		if child is DotHealth:
			return child
	return null


func _hitboxes_of(body: Node3D) -> DotHitboxSet:
	for child in body.get_children():
		if child is DotHitboxSet:
			return child
	return null


func _clear_players() -> void:
	for body in _players:
		if is_instance_valid(body):
			body.queue_free()
			remove_child(body)
	_players.clear()
