@tool
class_name DotCombatBase
extends Node

## State and entity registry under [DotCombatManager]: exports, signals, hitbox and health registration, damage types.

const CHANNEL := "combat"
const SERVICE := &"dot_combat"

## Damage was resolved and applied. Fires once per victim per shot, after
## [DotHealth] has finished with it, so the outcome fields are populated.
signal damage_applied(damage: DotDamage)

## An entity's health reached zero. [param damage] carries the attacker and weapon,
## which is what a kill feed needs.
signal entity_killed(entity_id: int, damage: DotDamage)

## A shot finished resolving. Carries every damage it produced, and fires even for a
## shot that hit nothing — a miss is what a tracer and a decal are drawn from.
signal shot_resolved(shot: DotShot)

## A shot was refused before it was traced. [param reason] is for logs and admin
## tools; it is never shown to a player, because every reason is either a hostile
## client or a bug and neither is the player's business.
signal shot_refused(shot: DotShot, reason: String)

## A hit landed on a hitbox tagged with a [member DotHitbox.limb] and did at least that limb's threshold
## ([member limb_min_damage]). Nothing here knows what a limb does: a host severs, bruises or ignores it.
## [param entity] is the node that owns the hitbox, [param impulse] the shot's direction scaled by the damage.
signal limb_hit(entity: Node, limb: StringName, point: Vector3, amount: float, impulse: Vector3)

@export_group("Role")

## Whether this instance applies damage.
##
## A client still traces (hit markers, effects) but never touches a [DotHealth].
@export var is_authority: bool = true

## Registers under [code]dot_combat[/code], or under a scoped name when set. Two
## managers in one process — a server and a client — need different scopes.
@export var service_scope: StringName = &""

## Register in [DotRegistry] at all.
@export var register_service: bool = true

@export_group("Configuration")

@export var config: DotCombatConfig = null

@export var config_file: String = ""

## Load the layered configuration on ready. Off, [member config] is used as-is.
@export var load_layered_config: bool = false

@export_group("Rules")

@export var rules: DotDamageRules = null

@export_group("Wiring")

## Where world geometry is traced. Left null, an empty [DotTraceFlat] hits nothing (setup warns).
var trace: DotTrace = null

## Minimum resolved damage for a hit on a limb to count, by limb name; `default` covers the rest.
## Loaded from `limb_min_damage:` in `cfg/addons/dot-combat/*.yml` by [method setup]; assign to override.
var limb_min_damage: Dictionary = {}

## Optional `func(entity: Node) -> Object`. When it returns an object with `hit(point, amount, impulse)`
## (dot-npc's `DotNpcLimbs`), a qualifying limb hit calls it: duck-typed, so neither addon imports the other.
var limb_target_fn: Callable = Callable()

## Turns hits into numbers. Built from [member rules] at setup if left null.
var resolver: DotDamageResolver = null

## Damage types by id, so a weapon can name one rather than hold a reference.
var damage_types: Dictionary = {}

## Rewinds the world to a tick: [code]func(tick: float) -> int[/code]. Unset, shots resolve
## against the present; dot-net is not named here (bridge in docs/design.md).
var rewind_fn: Callable = Callable()

## Undoes the most recent rewind: [code]func() -> int[/code]. Must be set whenever
## [member rewind_fn] is, or every hitbox stays in the past and shots miss for everyone.
var restore_fn: Callable = Callable()

## Whether a shot passes through an entity whose hitboxes already hold its muzzle.
## Signature: [code]func(shot: DotShot, set_node: DotHitboxSet, entity_id: int) -> bool[/code].
## Asked only for sets containing the origin; unset, the rules decide. Replaces the muzzle rule only.
var pass_through_fn: Callable = Callable()

## Master switch for shots that carry a [DotPenetration] (`sv_penetration`).
var penetration_enabled: bool = true

## Multiplier on every round's penetration power (`sv_penetration_scale`).
var penetration_scale: float = 1.0

## Whether a round passes bodies, not only walls (`sv_penetration_players`).
var penetration_players: bool = true

## Whether shallow hits on hard materials bounce (`sv_ricochet`); needs a round whose [DotPenetration] lists ricochet materials.
var ricochet_enabled: bool = false

## Metres a round is taken to cross a one-sided sheet (no far face to find), per material. A material not listed stops the round.
var sheet_thickness: Dictionary = {&"glass": 0.01, &"wood": 0.05, &"plastic": 0.02, &"cloth": 0.01, &"foliage": 0.02, &"metal": 0.015, &"fence": 0.02}

## entity id -> [DotHitboxSet].
var _sets: Dictionary = {}

## Flat list, rebuilt when [member _sets] changes. The trace walks this every shot and
## rebuilding a typed array per shot from a dictionary is measurable at 64 Hz.
var _set_list: Array[DotHitboxSet] = []

## entity id -> [DotHealth].
var _healths: Dictionary = {}

## Shot rate, keyed by attacker; [DotRateLimiter] keys and evicts its own buckets.
var _shot_limiter: DotRateLimiter = null

## owner node instance id -> entity id, kept at registration so a pellet does not walk
## every registration.
var _owner_ids: Dictionary = {}

## Where the server believes each entity is, for origin validation. Optional.
var _origins: Dictionary = {}

var _registered_name: StringName = &""
var _shots_resolved: int = 0
var _shots_refused: int = 0
var _registrations_refused: int = 0
var _rewinds: int = 0

## Makes an entity shootable. Called by [method DotHitboxSet.register_with].
func register_hitboxes(set_node: DotHitboxSet, entity_id: int) -> void:
	if set_node == null or entity_id == 0:
		_refuse_registration("hitboxes", entity_id, set_node == null)
		return

	_sets[entity_id] = set_node

	var owner := set_node.entity_owner()

	if owner != null:
		_owner_ids[owner.get_instance_id()] = entity_id

	_rebuild_set_list()


## A refused registration leaves an entity that cannot be shot or hurt; log and count it.
func _refuse_registration(what: String, entity_id: int, null_node: bool) -> void:
	_registrations_refused += 1
	DotLog.warn(CHANNEL, "%s registration ignored: %s" % [
		what, "node is null" if null_node else "entity id 0 is reserved (register after the entity has a network id)"
	], {"entity": entity_id})


func unregister_hitboxes(set_node: DotHitboxSet) -> void:
	for key in _sets.keys():
		if _sets[key] == set_node:
			_sets.erase(key)
			break

	for owner_id in _owner_ids.keys():
		if not _sets.has(_owner_ids[owner_id]):
			_owner_ids.erase(owner_id)

	_rebuild_set_list()


## Makes an entity damageable. Without this a shot hits it and nothing happens.
func register_health(entity_id: int, health: DotHealth) -> void:
	if entity_id == 0 or health == null:
		_refuse_registration("health", entity_id, health == null)
		return

	_healths[entity_id] = health

	if health.tick_rate() != config.tick_rate:
		health.set_tick_rate(config.tick_rate)


## Forgets everything about an entity. Call on despawn, or the manager leaks every entity ever seen.
func forget(entity_id: int) -> void:
	for owner_id in _owner_ids.keys():
		if int(_owner_ids[owner_id]) == entity_id:
			_owner_ids.erase(owner_id)

	_sets.erase(entity_id)
	_healths.erase(entity_id)
	_origins.erase(entity_id)

	if _shot_limiter != null:
		_shot_limiter.reset(entity_id)

	_rebuild_set_list()


func _rebuild_set_list() -> void:
	_set_list.clear()

	for key in _sets.keys():
		var set_node: DotHitboxSet = _sets[key]
		if set_node != null and is_instance_valid(set_node):
			_set_list.append(set_node)


func health_of(entity_id: int) -> DotHealth:
	return _healths.get(entity_id)


## Every registered hitbox set, for a projectile that sweeps the same world. Not a copy:
## do not hold it across a registration.
func hitbox_sets() -> Array[DotHitboxSet]:
	return _set_list


func hitboxes_of(entity_id: int) -> DotHitboxSet:
	return _sets.get(entity_id)


func entity_ids() -> Array[int]:
	var out: Array[int] = []
	for key in _healths.keys():
		out.append(int(key))
	out.sort()
	return out


## Where the server believes an entity is, for origin validation. Without it a reported
## muzzle is used as given.
func set_authoritative_origin(entity_id: int, position: Vector3) -> void:
	_origins[entity_id] = position


func register_damage_type(type: DotDamageType) -> void:
	if type == null:
		return
	damage_types[type.id] = type


func damage_type(id: StringName) -> DotDamageType:
	var type: DotDamageType = damage_types.get(id)

	if type != null:
		return type

	return damage_types.get(config.default_damage_type)
