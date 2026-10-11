@tool
class_name DotCombatManager
extends Node

## Resolves shots into damage. The server-side half of dot-combat.
##
## Whoever made the shot decided that it happened; this decides what it hit and what that
## cost. The split is not cosmetic — the arsenal runs on both ends and this runs only
## where the game is authoritative, so a client can predict its own fire without ever
## being in a position to decide who dies.
##
## [b]No autoload.[/b] It registers itself in [DotRegistry] under
## [constant SERVICE] and a game resolves it with a [DotNodeRef] in registry mode, or
## holds a reference. A process running a server and a client at once — which is what
## every one of this family's self-tests does — needs two of these, and
## [member service_scope] is how they coexist.
##
## [codeblock]
## var manager := DotCombatManager.new()
## manager.trace = DotTraceFlat.with_floor(0.0)
## manager.rules = DotDamageRules.strict()
## add_child(manager)
##
## # Every entity that can be shot.
## hitbox_set.register_with(manager, player_id)
## manager.register_health(player_id, health)
##
## # Every shot the arsenal produced, on the server.
## manager.resolve_shot(shot, client_view_tick)
## [/codeblock]

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

@export_group("Role")

## Whether this instance applies damage.
##
## A client instance still traces — for hit markers and for effects — but never
## touches a [DotHealth]. Predicting damage is how a client shows a kill that did not
## happen, which is worse than showing nothing.
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

## Where world geometry is traced. Left null a [DotTraceFlat] with no geometry is
## used, which hits nothing and is almost never what a game wants — the warning at
## setup says so.
var trace: DotTrace = null

## Turns hits into numbers. Built from [member rules] at setup if left null.
var resolver: DotDamageResolver = null

## Damage types by id, so a weapon can name one rather than hold a reference.
var damage_types: Dictionary = {}

## Rewinds the world to a tick. Signature: [code]func(tick: float) -> int[/code].
##
## [b]dot-net is not a dependency and is not named here.[/b] A game with dot-net
## installed assigns [code]manager.rewind_fn = net.history.rewind.bind(...)[/code] and
## lag compensation starts working; a game without it leaves this unset and shots
## resolve against the present. See this project's docs/design.md for the bridge.
var rewind_fn: Callable = Callable()

## Undoes the most recent rewind. Signature: [code]func() -> int[/code].
##
## [b]Must be set whenever [member rewind_fn] is.[/b] A rewind that is never restored
## leaves every hitbox in the level at a position from the past, permanently, and the
## symptom is that shots start missing for everyone rather than that anything errors.
var restore_fn: Callable = Callable()

## Whether a shot passes through an entity whose hitboxes already hold its muzzle.
## Signature: [code]func(shot: DotShot, set_node: DotHitboxSet, entity_id: int) -> bool[/code].
##
## Asked only for sets that contain [member DotShot.origin]; a set the muzzle is outside
## of is always traced. Left unset, [member DotDamageRules.pass_through_team_mate_at_muzzle]
## decides with [method DotDamageResolver.are_team_mates]. A game assigns this when "who
## may stand inside whom" is not a team question (a passenger in a vehicle's hitboxes, a
## mode where only some team-mates overlap). It replaces the muzzle rule only:
## [member DotDamageRules.pass_through_team_mates] (the `mp_teammate_passthrough 2` setting)
## still lets every team-mate through.
var pass_through_fn: Callable = Callable()

## entity id -> [DotHitboxSet].
var _sets: Dictionary = {}

## Flat list, rebuilt when [member _sets] changes. The trace walks this every shot and
## rebuilding a typed array per shot from a dictionary is measurable at 64 Hz.
var _set_list: Array[DotHitboxSet] = []

## entity id -> [DotHealth].
var _healths: Dictionary = {}

## Shot rate, keyed by attacker. One limiter for everyone: [DotRateLimiter] keys its
## own buckets and evicts idle ones, so a per-entity limiter would be a second
## dictionary doing the same job worse.
var _shot_limiter: DotRateLimiter = null

## owner node instance id -> entity id.
##
## The trace returns the node it hit and damage is keyed by entity id, so every pellet
## needs that mapping. Walking the registration dictionary per pellet is O(players)
## per pellet per shot, which a twelve-pellet shotgun on a full server turns into real
## work — so it is maintained at registration time instead.
var _owner_ids: Dictionary = {}

## Where the server believes each entity is, for origin validation. Optional.
var _origins: Dictionary = {}

var _registered_name: StringName = &""
var _shots_resolved: int = 0
var _shots_refused: int = 0
var _rewinds: int = 0


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	var res := setup()

	if not res.ok:
		DotLog.result(CHANNEL, "combat setup", res)


func _exit_tree() -> void:
	if _registered_name != &"":
		DotRegistry.unregister_instance(_registered_name, self)
		_registered_name = &""


## Builds everything that was left null and registers the service.
##
## Safe to call twice; the second call rebuilds nothing that already exists.
func setup() -> DotResult:
	if config == null:
		config = DotCombatConfig.new()

	if load_layered_config:
		var loaded := config.load_layered(config_file)
		if not loaded.ok:
			return loaded.wrap("Could not load the combat configuration.")

	var valid := config.validate()

	if not valid.ok:
		return valid

	if rules == null:
		rules = DotDamageRules.new()

	if resolver == null:
		resolver = DotDamageResolver.with_rules(rules)
	else:
		resolver.rules = rules
		if resolver.hit_groups == null:
			resolver.hit_groups = DotHitGroup.defaults()

	if trace == null:
		DotLog.warn(
			CHANNEL,
			"no trace backend; every shot will pass through world geometry"
		)
		trace = DotTraceFlat.new()

	if not damage_types.has(config.default_damage_type):
		register_damage_type(DotDamageType.make(config.default_damage_type, "Bullet"))

	if register_service:
		_registered_name = (
			DotRegistry.scoped_name(SERVICE, service_scope)
			if service_scope != &""
			else SERVICE
		)
		DotRegistry.register(_registered_name, self)

	if is_authority and not rewind_fn.is_valid() and config.lag_compensation:
		# Not an error: a listen server with one local player does not need it, and a
		# game may deliberately not want it. But "lag compensation is on" reading as
		# "lag compensation is happening" is a wrong belief worth one line to prevent.
		DotLog.info(
			CHANNEL,
			"lag compensation is enabled but no rewind function is wired; "
			+ "shots resolve against the present"
		)

	return DotResult.success(null)


# --- Registration ----------------------------------------------------------

## Makes an entity shootable. Called by [method DotHitboxSet.register_with].
func register_hitboxes(set_node: DotHitboxSet, entity_id: int) -> void:
	if set_node == null or entity_id == 0:
		return

	_sets[entity_id] = set_node

	var owner := set_node.entity_owner()

	if owner != null:
		_owner_ids[owner.get_instance_id()] = entity_id

	_rebuild_set_list()


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
		return

	_healths[entity_id] = health

	if health.tick_rate() != config.tick_rate:
		health.set_tick_rate(config.tick_rate)


## Forgets everything about an entity. Call on despawn.
##
## Without it the manager holds a reference to every entity that has ever existed,
## which on a server churning through players is a leak proportional to everyone who
## has ever connected — the same fault [code]DotNetBehaviour.forget_peer[/code] exists
## to avoid.
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


## Every registered hitbox set, for something outside the manager that has to trace.
##
## A projectile in flight is the case this exists for: it has to sweep the same world
## the manager traces against, and rebuilding the list from the registry each tick
## would walk every entity for every rocket. Returned rather than copied, so a caller
## must not hold it across a registration.
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


## Tells the manager where the server believes an entity is, for origin validation.
##
## Optional. Without it a client's reported muzzle is used as given, which is safe
## only if something else has already validated it.
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


# --- Resolution ------------------------------------------------------------

## Traces a shot, applies its damage, and returns it with the outcome filled in.
##
## [param view_tick] is the tick the shooter was looking at, which is not the tick
## they fired on: a client sees the world as of roughly its own tick minus its latency
## minus its interpolation delay. Pass -1 to resolve against the present, which is
## right for a shot the server itself produced (a bot, a turret) and wrong for one a
## client reported.
##
## [b]Restoring the rewind happens on every path out of this method[/b], including the
## refusal paths. A rewind that leaks leaves the world in the past permanently.
func resolve_shot(shot: DotShot, view_tick: float = -1.0) -> DotShot:
	if shot == null:
		return shot

	var refusal := _validate_shot(shot)

	if refusal != "":
		_shots_refused += 1
		shot_refused.emit(shot, refusal)
		return shot

	_correct_origin(shot)

	var rewound := _begin_rewind(shot, view_tick)

	# Nothing between here and _end_rewind may return early.
	_trace_shot(shot)

	if shot.splash_radius > 0.0:
		_apply_splash(shot)

	_end_rewind(rewound)

	if is_authority:
		_apply_damages(shot)

	_shots_resolved += 1

	if config.trace_shots:
		for damage in shot.damages:
			DotLog.debug(CHANNEL, "damage", damage.describe())

	shot_resolved.emit(shot)
	return shot


func _validate_shot(shot: DotShot) -> String:
	if config.reject_future_ticks and shot.tick < 0:
		return "negative tick"

	if _shot_limiter == null:
		_shot_limiter = DotRateLimiter.new(
			config.shots_per_second, config.shots_per_second
		)

	if not _shot_limiter.allow(shot.attacker):
		return "shot rate exceeded"

	var health := health_of(shot.attacker)

	if health != null and not health.alive:
		return "shooter is dead"

	return ""


## Relocates a shot whose reported muzzle is too far from where the server believes
## the shooter is.
##
## Relocating rather than refusing: a legitimate client's origin is always a little
## wrong — it is a tick ahead of the server by construction — and refusing those
## shots would make the game unplayable for everyone in order to stop a cheat that
## clamping already stops.
func _correct_origin(shot: DotShot) -> void:
	if not _origins.has(shot.attacker):
		return

	var believed: Vector3 = _origins[shot.attacker]
	var error := believed.distance_to(shot.origin)

	if error <= config.max_origin_error:
		return

	DotLog.debug(
		CHANNEL,
		"shot origin relocated",
		{"entity": shot.attacker, "error": error}
	)
	shot.origin = believed


func _begin_rewind(shot: DotShot, view_tick: float) -> bool:
	if not config.lag_compensation or view_tick < 0.0:
		return false

	if not rewind_fn.is_valid() or not restore_fn.is_valid():
		return false

	var oldest := float(shot.tick) - config.max_rewind_sec() * float(config.tick_rate)
	var clamped := maxf(view_tick, oldest)

	rewind_fn.call(clamped)
	_rewinds += 1
	return true


func _end_rewind(rewound: bool) -> void:
	if rewound and restore_fn.is_valid():
		restore_fn.call()


func _trace_shot(shot: DotShot) -> void:
	var type := shot.damage_type if shot.damage_type != null else damage_type(&"")

	var shooter := hitboxes_of(shot.attacker)
	var excluded: Array = [shooter] if shooter != null else []
	# Inside the rewind, so "holds the muzzle" is judged where the bodies were when the
	# shooter fired, the same positions the rays are about to be tested against.
	excluded.append_array(pass_through_sets(shot))
	trace.exclude = excluded

	shot.impacts.clear()

	if shot.deferred:
		# A deferred shot is an entity with a lifetime; it is not resolved here. The
		# endpoint is recorded so a caller can launch it along the right vector, and
		# the shot produces no damage of its own.
		for direction in shot.pellets:
			shot.impacts.append(shot.origin + direction * shot.max_range)
		return

	for pellet in range(shot.pellets.size()):
		var direction: Vector3 = shot.pellets[pellet]
		var hit := trace.ray(shot.origin, direction, shot.max_range, _set_list)

		if not hit.ok():
			shot.impacts.append(shot.origin + direction * shot.max_range)
			continue

		shot.impacts.append(hit.point)

		if hit.blocked or hit.entity == null:
			continue

		var victim := _entity_id_of(hit.entity)

		if victim == 0:
			continue

		var damage := DotDamage.make(
			shot.attacker,
			victim,
			shot.damage * config.damage_scale,
			type
		)
		damage.hit_group = hit.group
		damage.point = hit.point
		damage.direction = direction
		damage.distance = hit.distance
		damage.weapon_id = shot.weapon_id
		damage.tick = shot.tick

		if hit.hitbox != null:
			damage.scale_by(hit.hitbox.damage_scale, "hitbox")

		shot.damages.append(resolver.resolve(damage))


## The hitbox sets [param shot] passes through: a team-mate's that already holds its muzzle
## and, under [member DotDamageRules.pass_through_team_mates], every team-mate's.
##
## [b]Why the manager and not the trace or the hitbox.[/b] [DotHitbox] counting a ray that
## starts inside it as a hit at zero is right on its own terms (a point-blank shot on an
## enemy), and [DotTrace] knows geometry but not teams. Only here are the attacker, the
## victim's id and the resolver's [code]team_of[/code] all in hand, so this is the one place
## the rule can be written once for every game instead of in each game's trace subclass.
##
## Public for anything else that traces a shot outside [method resolve_shot] (a client's
## hit marker, a bot's "is a friend in my line" check): pass the result as
## [member DotTrace.exclude] alongside the shooter, or skip these sets yourself.
func pass_through_sets(shot: DotShot) -> Array[DotHitboxSet]:
	var out: Array[DotHitboxSet] = []

	if shot == null:
		return out

	var use_rule := rules != null and rules.pass_through_team_mate_at_muzzle
	# The broad rule (every team-mate in the line) is asked of the resolver whatever
	# pass_through_fn says: that callable replaces the muzzle question only, and an operator
	# who set mp_teammate_passthrough 2 meant it for every body a game's callable lets stand.
	var everywhere := rules != null and rules.pass_through_team_mates and resolver != null

	if not pass_through_fn.is_valid() and not everywhere and (not use_rule or resolver == null):
		return out

	for set_node in _set_list:
		if set_node == null or not is_instance_valid(set_node):
			continue

		var entity_id := _entity_id_of(set_node.entity_owner())

		# The shooter's own set is excluded by the caller already; asking the policy about
		# it would only invite a callable that returns false to shoot yourself.
		if entity_id == shot.attacker:
			continue

		var passes := false

		if everywhere and resolver.are_team_mates(shot.attacker, entity_id):
			passes = true
		elif not set_node.contains_point(shot.origin):
			continue
		elif pass_through_fn.is_valid():
			passes = bool(pass_through_fn.call(shot, set_node, entity_id))
		elif use_rule and resolver != null:
			passes = resolver.are_team_mates(shot.attacker, entity_id)

		if passes:
			out.append(set_node)
			if config != null and config.trace_shots:
				DotLog.debug(CHANNEL, "shot passes through a team-mate or a body at the muzzle", {
					"attacker": shot.attacker, "entity": entity_id,
				})

	return out


# --- Server settings -------------------------------------------------------

## The cvar an operator sets to decide whether shots pass through team-mates. Values are
## [DotDamageRules]' PASS_THROUGH_* levels: 0 never (a team-mate is hit and blocks like
## anybody), 1 at the muzzle (the default), 2 always (team-mates never block a shot).
const CVAR_TEAMMATE_PASSTHROUGH := "mp_teammate_passthrough"


## The cvars [method bind_cvars] registers, as data, for a host that registers them its own way.
func cvar_specs() -> Array[Dictionary]:
	var level := rules.pass_through_level() if rules != null else DotDamageRules.PASS_THROUGH_AT_MUZZLE
	var out: Array[Dictionary] = [
		{
			"name": CVAR_TEAMMATE_PASSTHROUGH,
			"value": str(level),
			"description": "Shots and team-mates: 0 a team-mate is hit and blocks the shot, 1 a shot passes through a team-mate standing at the muzzle, 2 shots pass through every team-mate in the line",
			"min": float(DotDamageRules.PASS_THROUGH_NONE),
			"max": float(DotDamageRules.PASS_THROUGH_ALWAYS),
		},
	]
	return out


## Registers this manager's server cvars through [param add] and keeps [member rules] in
## step with them. Call it on the authoritative manager, after it has its [member rules].
##
## [param add] is a server module's `add_cvar` (so the module unregisters them when it
## unloads) or anything with its signature: `(name, default, description, flags) -> cvar`.
## Returns the cvars it made.
##
## [b]Duck-typed, because dot-server is not a dependency of this addon[/b]; the same shape
## as dot-npc-ai's `DotNpcAiSkill.bind_cvars`. A cvar needs a `changed(old, new)` signal and
## a `get_string()`; a range is used when it offers one.
##
## [b]Live:[/b] a change writes through to [member rules], which the resolver shares, so the
## next shot uses it. [b]The current value is read back after registering[/b], because a
## cvar set before this ran (argv, a config executed early, the deploy's content.yml) already
## holds the operator's value.
##
## The cvar is the server's: a client's own manager keeps its default, so with 0 or 2 a
## client's predicted tracer can end somewhere the server's shot did not. Damage is only
## ever the server's, so the cost is cosmetic.
func bind_cvars(add: Callable, flags: int = 0) -> Array:
	var made: Array = []

	for spec in cvar_specs():
		var cvar_name: String = spec["name"]
		var made_cvar: Variant = add.call(
			cvar_name, String(spec["value"]), String(spec["description"]), flags
		)

		if not (made_cvar is Object) or made_cvar == null:
			continue

		var cv := made_cvar as Object

		if spec.has("min") and cv.has_method(&"with_range"):
			cv.call(&"with_range", float(spec["min"]), float(spec["max"]))

		if cv.has_signal(&"changed"):
			cv.connect(&"changed", _on_cvar_changed.bind(cvar_name))

		if cv.has_method(&"get_string"):
			set_cvar(cvar_name, String(cv.call(&"get_string")))

		made.append(cv)

	return made


## Applies one of [method cvar_specs]' cvars by name. Returns false for a name that is not
## this manager's or a value that is not a number.
func set_cvar(cvar_name: String, value: String) -> bool:
	if cvar_name != CVAR_TEAMMATE_PASSTHROUGH:
		return false

	var text := value.strip_edges()

	if not text.is_valid_float():
		DotLog.warn(CHANNEL, "cvar is not a number; left as it was", {"cvar": cvar_name, "value": value})
		return false

	if rules == null:
		rules = DotDamageRules.new()

	rules.set_pass_through_level(roundi(text.to_float()))

	# One object in practice (setup() hands the resolver this one), but a game that
	# assigned the resolver its own after setup would otherwise keep the old rule there.
	if resolver != null and resolver.rules != null and resolver.rules != rules:
		resolver.rules.set_pass_through_level(rules.pass_through_level())

	DotLog.debug(CHANNEL, "team-mate pass-through set", {"level": rules.pass_through_level()})
	return true


func _on_cvar_changed(_old: String, new_value: String, cvar_name: String) -> void:
	var _applied := set_cvar(cvar_name, new_value)


func _apply_splash(shot: DotShot) -> void:
	var type := shot.splash_type

	if type == null:
		type = shot.damage_type if shot.damage_type != null else damage_type(&"")

	# Splash originates where the shot actually landed, not at the muzzle. With no
	# impacts — a projectile, which has not landed yet — there is nothing to splash.
	if shot.impacts.is_empty():
		return

	var centre: Vector3 = shot.impacts[0]
	var shooter := hitboxes_of(shot.attacker)

	trace.exclude = [] if shot.splash_hurts_owner else (
		[shooter] if shooter != null else []
	)

	var caught := trace.sphere_overlap(centre, shot.splash_radius, _set_list, true)

	for set_node in caught:
		var victim := _entity_id_of(set_node.entity_owner())

		if victim == 0:
			continue

		var closest := set_node.closest_point(centre)
		var distance := centre.distance_to(closest)
		var amount := shot.splash_at(distance) * config.damage_scale

		if amount <= 0.0:
			continue

		var damage := DotDamage.make(shot.attacker, victim, amount, type)
		damage.point = closest
		damage.direction = (closest - centre).normalized()
		# Distance is already spent on the splash falloff; feeding it to the damage
		# type's falloff as well would apply two curves to one number.
		damage.distance = 0.0
		damage.hit_group = DotHitGroup.GENERIC
		damage.weapon_id = shot.weapon_id
		damage.tick = shot.tick

		shot.damages.append(resolver.resolve(damage))

	trace.exclude = []


func _apply_damages(shot: DotShot) -> void:
	# Iterated by index and appended to inside the loop: a reflection is a new damage
	# event that must itself be applied, and it belongs to the same shot.
	var index := 0

	while index < shot.damages.size():
		var damage: DotDamage = shot.damages[index]
		index += 1

		if damage.refused:
			continue

		var health := health_of(damage.victim)

		if health == null:
			continue

		health.apply(damage)

		if damage.refused:
			continue

		damage_applied.emit(damage)

		if damage.lethal:
			entity_killed.emit(damage.victim, damage)

		var back := resolver.reflection(damage)

		if back != null:
			shot.damages.append(back)


## Applies a damage event that did not come from a weapon.
##
## Fall damage, drowning, a kill command, a scripted trap. Goes through the resolver
## and the same signals, so a kill feed and a scoreboard do not need a second path.
func apply_damage(damage: DotDamage) -> DotDamage:
	if damage == null:
		return null

	if damage.type == null:
		damage.type = damage_type(&"")

	resolver.resolve(damage)

	if not is_authority or damage.refused:
		return damage

	var health := health_of(damage.victim)

	if health == null:
		damage.refuse("no health registered for victim %d" % damage.victim)
		return damage

	health.apply(damage)

	if damage.refused:
		return damage

	damage_applied.emit(damage)

	if damage.lethal:
		entity_killed.emit(damage.victim, damage)

	return damage


## An explosion with no weapon behind it. A barrel, a mine, a falling ceiling.
func explode(
	centre: Vector3,
	radius: float,
	damage_amount: float,
	attacker: int = 0,
	type: DotDamageType = null,
	tick: int = 0
) -> Array[DotDamage]:
	var out: Array[DotDamage] = []

	if type == null:
		type = damage_type(&"")

	trace.exclude = []

	for set_node in trace.sphere_overlap(centre, radius, _set_list, true):
		var victim := _entity_id_of(set_node.entity_owner())

		if victim == 0:
			continue

		var closest := set_node.closest_point(centre)
		var distance := centre.distance_to(closest)
		var amount := damage_amount * (1.0 - clampf(distance / maxf(0.001, radius), 0.0, 1.0))

		if amount <= 0.0:
			continue

		var damage := DotDamage.make(attacker, victim, amount * config.damage_scale, type)
		damage.point = closest
		damage.direction = (closest - centre).normalized()
		damage.hit_group = DotHitGroup.GENERIC
		damage.tick = tick

		out.append(apply_damage(damage))

	return out


func _entity_id_of(node: Node) -> int:
	if node == null:
		return 0

	return int(_owner_ids.get(node.get_instance_id(), 0))


# --- Advancing -------------------------------------------------------------

## Advances regeneration on every registered [DotHealth].
##
## Not automatic: a predicted entity is ticked by the simulation loop, and doing it
## here as well would run it twice at two different rates.
func tick(current_tick: int, delta: float) -> void:
	for key in _healths.keys():
		var health: DotHealth = _healths[key]
		if health != null and is_instance_valid(health):
			health.tick(current_tick, delta)


# --- Diagnostics -----------------------------------------------------------

func describe() -> Dictionary:
	return {
		"authority": is_authority,
		"entities": _sets.size(),
		"healths": _healths.size(),
		"resolved": _shots_resolved,
		"refused": _shots_refused,
		"rewinds": _rewinds,
		"lagcomp": config.lag_compensation and rewind_fn.is_valid(),
		"trace": trace.describe() if trace != null else {},
		"rules": rules.describe() if rules != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("combat  %s  %d entities" % [
		"authority" if is_authority else "client", _sets.size()
	])
	out.append("shots   %d resolved, %d refused" % [_shots_resolved, _shots_refused])
	out.append("lagcomp %s (%d rewinds)" % [
		"on" if config.lag_compensation and rewind_fn.is_valid() else "off",
		_rewinds,
	])
	return out
