@tool
class_name DotCombatManager
extends Node

## Resolves shots into damage. The server-side half of dot-combat.
##
## The shooter runs on both ends and this only where the game is authoritative, so a client
## can predict its own fire without ever deciding who dies.
##
## No autoload: it registers in [DotRegistry] under [constant SERVICE]; a server and a client
## in one process need two, told apart by [member service_scope].
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
## # Every shot the game's shooter produced, on the server.
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

## A hit landed on a hitbox tagged with a [member DotHitbox.limb] and did at least that limb's threshold
## ([member limb_min_damage]). Nothing here knows what a limb does: a host severs, bruises or ignores it.
## [param entity] is the node that owns the hitbox, [param impulse] the shot's direction scaled by the damage.
signal limb_hit(entity: Node, limb: StringName, point: Vector3, amount: float, impulse: Vector3)

@export_group("Role")

## Whether this instance applies damage.
##
## A client instance still traces (hit markers, effects) but never touches a [DotHealth]:
## predicted damage shows kills that did not happen.
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
##
## Asked only for sets that contain [member DotShot.origin]. Unset,
## [member DotDamageRules.pass_through_team_mate_at_muzzle] decides; assign for non-team
## overlap (a passenger in a vehicle). Replaces the muzzle rule only:
## [member DotDamageRules.pass_through_team_mates] still lets every team-mate through.
var pass_through_fn: Callable = Callable()

## Master switch for shots that carry a [DotPenetration] (`sv_penetration`).
var penetration_enabled: bool = true

## Multiplier on every round's penetration power (`sv_penetration_scale`).
var penetration_scale: float = 1.0

## Whether a round passes bodies, not only walls (`sv_penetration_players`).
var penetration_players: bool = true

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

	var cfg_limbs := DotAddonConfig.load_dir("dot-combat")
	if cfg_limbs.ok and limb_min_damage.is_empty():
		var v: Variant = DotAddonConfig.get_value(cfg_limbs.value, "limb_min_damage", {})
		if v is Dictionary:
			limb_min_damage = v

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

	if cfg_limbs.ok and resolver.hit_groups != null:
		var zones: Variant = DotAddonConfig.get_value(cfg_limbs.value, "hit_groups", {})
		if zones is Dictionary:
			var _n := resolver.hit_groups.apply_dict(zones)

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
		# Not an error (a listen server may not need it), but "on" must not read as "happening".
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


# --- Resolution ------------------------------------------------------------

## Traces a shot, applies its damage, and returns it with the outcome filled in.
##
## [param view_tick] is the tick the shooter was looking at (their tick minus latency and
## interpolation delay). -1 resolves against the present: right for server-made shots, wrong
## for a client's. The rewind is restored on every path out, or the world stays in the past.
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


## Relocates a shot whose muzzle is too far from the believed shooter position. Relocated,
## not refused: a legitimate origin is a tick ahead by construction.
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
	# Inside the rewind, so "holds the muzzle" uses the positions the rays test against.
	excluded.append_array(pass_through_sets(shot))
	trace.exclude = excluded

	shot.impacts.clear()

	if shot.deferred:
		# Deferred: an entity with a lifetime, not resolved here; only the endpoint is recorded.
		for direction in shot.pellets:
			shot.impacts.append(shot.origin + direction * shot.max_range)
		return

	var pen: DotPenetration = null
	if penetration_enabled and shot.penetration != null and shot.penetration.enabled():
		pen = shot.penetration.duplicate_scaled(penetration_scale)
		if not pen.enabled():
			pen = null

	for pellet in range(shot.pellets.size()):
		_trace_pellet(shot, pellet, type, pen, excluded)

	trace.exclude = excluded


## One pellet: walls and (under [member penetration_players]) bodies it passes spend [param pen]'s power, damage falls with what is left.
func _trace_pellet(shot: DotShot, pellet: int, type: DotDamageType, pen: DotPenetration, excluded: Array) -> void:
	var direction: Vector3 = shot.pellets[pellet]
	var from := shot.origin
	var remaining := shot.max_range
	var power := pen.power if pen != null else 0.0
	var passes := 0
	var walls := 0
	var skip: Array = excluded.duplicate()
	var walked := 0.0

	while true:
		trace.exclude = skip
		var hit := trace.ray(from, direction, remaining, _set_list)

		if not hit.ok():
			shot.impacts.append(shot.origin + direction * shot.max_range)
			return

		var can_pass := pen != null and passes < pen.max_passes and power > 0.0

		if hit.blocked or hit.entity == null:
			var exit: DotHitbox.Hit = _wall_exit(hit, direction, pen) if can_pass else null
			if exit == null:
				shot.impacts.append(hit.point)
				return
			var thickness: float = hit.point.distance_to(exit.point)
			power -= pen.wall_cost(thickness, hit.material)
			if power <= 0.0:
				shot.impacts.append(hit.point)
				return
			shot.penetrations.append({
				"pellet": pellet, "material": hit.material, "thickness": thickness,
				"entry": hit.point, "exit": exit.point,
				"entry_normal": hit.normal, "exit_normal": exit.normal,
			})
			passes += 1
			walls += 1
			walked += hit.distance + thickness
			from = exit.point + direction * 0.01
			remaining = shot.max_range - walked
			if remaining <= 0.0:
				shot.impacts.append(from)
				return
			continue

		var victim := _entity_id_of(hit.entity)

		if victim == 0:
			shot.impacts.append(hit.point)
			return

		var strength := pen.strength(power) if pen != null and passes > 0 else 1.0
		var damage := DotDamage.make(
			shot.attacker,
			victim,
			shot.damage * config.damage_scale * strength,
			type
		)
		damage.hit_group = hit.group
		damage.limb = hit.limb
		DotHitzone.annotate(damage, hit, direction)
		damage.context["entity"] = hit.entity
		if passes > 0:
			damage.context["penetrated"] = passes
			damage.context["wallbang"] = walls > 0
		damage.point = hit.point
		damage.direction = direction
		damage.distance = hit.distance + walked
		damage.weapon_id = shot.weapon_id
		damage.tick = shot.tick

		if hit.hitbox != null:
			damage.scale_by(hit.hitbox.damage_scale, "hitbox")

		shot.damages.append(resolver.resolve(damage))

		if not (can_pass and penetration_players):
			shot.impacts.append(hit.point)
			return

		power -= pen.body_cost_of(hit.group)
		if power <= 0.0:
			shot.impacts.append(hit.point)
			return

		var body_set := _set_of(hit.entity)
		if body_set == null:
			shot.impacts.append(hit.point)
			return
		skip.append(body_set)
		passes += 1
		walked += hit.distance
		from = hit.point + direction * 0.01
		remaining = shot.max_range - walked
		if remaining <= 0.0:
			shot.impacts.append(from)
			return


## The far face of the wall [param hit] is on: a ray from [member DotPenetration.max_depth] beyond it, back, against the world only. Null when there is none (a one-sided sheet, or thicker than the depth).
func _wall_exit(hit: DotHitbox.Hit, direction: Vector3, pen: DotPenetration) -> DotHitbox.Hit:
	var far := hit.point + direction * pen.max_depth
	var saved := trace.exclude
	trace.exclude = _set_list.duplicate()
	var back := trace.ray(far, -direction, pen.max_depth, _set_list)
	trace.exclude = saved
	if not back.ok() or back.entity != null:
		return null
	return back


func _set_of(entity: Node) -> DotHitboxSet:
	for set_node in _set_list:
		if set_node != null and is_instance_valid(set_node) and set_node.entity_owner() == entity:
			return set_node
	return null


## The hitbox sets [param shot] passes through: a team-mate's that already holds its muzzle
## and, under [member DotDamageRules.pass_through_team_mates], every team-mate's.
##
## Lives here, not in the trace or hitbox: only the manager has the attacker, the victim's id and the resolver's team_of together.
## Public for anything tracing outside [method resolve_shot]: pass the result as [member DotTrace.exclude] alongside the shooter.
func pass_through_sets(shot: DotShot) -> Array[DotHitboxSet]:
	var out: Array[DotHitboxSet] = []

	if shot == null:
		return out

	var use_rule := rules != null and rules.pass_through_team_mate_at_muzzle
	# The broad rule goes to the resolver whatever pass_through_fn says: that callable replaces the muzzle question only.
	var everywhere := rules != null and rules.pass_through_team_mates and resolver != null

	if not pass_through_fn.is_valid() and not everywhere and (not use_rule or resolver == null):
		return out

	for set_node in _set_list:
		if set_node == null or not is_instance_valid(set_node):
			continue

		# Without the broad rule only a body holding the muzzle can pass: ask that first, it is cheap.
		if not everywhere and not set_node.contains_point(shot.origin):
			continue

		var entity_id := _entity_id_of(set_node.entity_owner())

		# The shooter's own set is excluded by the caller already; asking the policy about
		# it would only invite a callable that returns false to shoot yourself.
		if entity_id == shot.attacker:
			continue

		var passes := false

		if everywhere and resolver.are_team_mates(shot.attacker, entity_id):
			passes = true
		elif everywhere and not set_node.contains_point(shot.origin):
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

## 1 lets a shooter damage a team-mate, 0 refuses it. The default is whatever the game's [member rules] say when the cvar binds, so binding it changes no game's behaviour until an operator sets it.
const CVAR_FRIENDLY_FIRE := "mp_friendlyfire"

## 1 makes neck, hand and foot zones of their own with their own multipliers, 0 folds them into chest, arm and leg ([DotHitzone]).
const CVAR_HITZONES := "mp_hitzones"

const CVAR_PENETRATION := "sv_penetration"
const CVAR_PENETRATION_SCALE := "sv_penetration_scale"
const CVAR_PENETRATION_PLAYERS := "sv_penetration_players"


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
		{
			"name": CVAR_FRIENDLY_FIRE,
			"value": "1" if rules != null and rules.friendly_fire else "0",
			"description": "Friendly fire: 1 a shooter can damage a team-mate, 0 team-mates are immune to each other",
			"min": 0.0,
			"max": 1.0,
		},
		{
			"name": CVAR_HITZONES,
			"value": "1" if rules != null and rules.hitzones else "0",
			"description": "Hit zones: 1 neck, hands and feet have their own damage multipliers, 0 they count as chest, arm and leg",
			"min": 0.0,
			"max": 1.0,
		},
		{
			"name": CVAR_PENETRATION,
			"value": "1" if penetration_enabled else "0",
			"description": "Bullet penetration: 1 rounds with an ammo profile pass walls and bodies, 0 every wall stops them",
			"min": 0.0,
			"max": 1.0,
		},
		{
			"name": CVAR_PENETRATION_SCALE,
			"value": str(penetration_scale),
			"description": "Multiplier on every round's penetration power",
			"min": 0.0,
			"max": 10.0,
		},
		{
			"name": CVAR_PENETRATION_PLAYERS,
			"value": "1" if penetration_players else "0",
			"description": "1 a round passes through a player and can hurt the one behind, 0 a player stops it",
			"min": 0.0,
			"max": 1.0,
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
## [b]Pass dot-server's FLAG_REPLICATED in [param flags][/b], and have each client's manager
## [method follow_cvars] its link: the value then reaches every client, which predicts its
## tracers and impacts under the server's rule rather than its own default.
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
	if cvar_name in [CVAR_PENETRATION, CVAR_PENETRATION_SCALE, CVAR_PENETRATION_PLAYERS]:
		return _set_penetration_cvar(cvar_name, value)
	if cvar_name != CVAR_TEAMMATE_PASSTHROUGH and cvar_name != CVAR_FRIENDLY_FIRE and cvar_name != CVAR_HITZONES:
		return false

	var text := value.strip_edges().to_lower()
	if (cvar_name == CVAR_FRIENDLY_FIRE or cvar_name == CVAR_HITZONES) and text in ["true", "false"]:
		text = "1" if text == "true" else "0"

	if not text.is_valid_float():
		DotLog.warn(CHANNEL, "cvar is not a number; left as it was", {"cvar": cvar_name, "value": value})
		return false

	if rules == null:
		rules = DotDamageRules.new()

	if cvar_name == CVAR_HITZONES:
		rules.hitzones = text.to_float() != 0.0
		if resolver != null and resolver.rules != null and resolver.rules != rules:
			resolver.rules.hitzones = rules.hitzones
		return true

	if cvar_name == CVAR_FRIENDLY_FIRE:
		rules.friendly_fire = text.to_float() != 0.0
		if resolver != null and resolver.rules != null and resolver.rules != rules:
			resolver.rules.friendly_fire = rules.friendly_fire
		DotLog.debug(CHANNEL, "friendly fire set", {"on": rules.friendly_fire})
		return true

	rules.set_pass_through_level(roundi(text.to_float()))

	# One object in practice (setup() hands the resolver this one), but a game that
	# assigned the resolver its own after setup would otherwise keep the old rule there.
	if resolver != null and resolver.rules != null and resolver.rules != rules:
		resolver.rules.set_pass_through_level(rules.pass_through_level())

	DotLog.debug(CHANNEL, "team-mate pass-through set", {"level": rules.pass_through_level()})
	return true


func _set_penetration_cvar(cvar_name: String, value: String) -> bool:
	var text := value.strip_edges().to_lower()
	if text in ["true", "false"]:
		text = "1" if text == "true" else "0"
	if not text.is_valid_float():
		DotLog.warn(CHANNEL, "cvar is not a number; left as it was", {"cvar": cvar_name, "value": value})
		return false
	var number := text.to_float()
	if cvar_name == CVAR_PENETRATION:
		penetration_enabled = number != 0.0
	elif cvar_name == CVAR_PENETRATION_PLAYERS:
		penetration_players = number != 0.0
	else:
		penetration_scale = maxf(0.0, number)
	return true


func _on_cvar_changed(_old: String, new_value: String, cvar_name: String) -> void:
	var _applied := set_cvar(cvar_name, new_value)


## Keeps a client's [member rules] on the server's values of [method cvar_specs]' cvars, as
## [param source] reports them: dot-server's `DotClientLink`, or anything with a
## `replicated_cvar(name, fallback) -> String` and a `replicated_cvar_changed(name, value)`
## signal. Applies what the source already holds, then every change. True when it is
## following.
##
## [b]Why a client needs the server's level at all.[/b] Damage is only the server's, but a
## client traces its own shots for tracers, impacts and hit markers. Left at the default 1
## against a server on 0 or 2, the predicted tracer stopped in a team-mate the server's shot
## went through, or went through one the server's shot hit: every shot near a friend drew
## somewhere it did not land.
##
## [b]Duck-typed, like [method bind_cvars][/b]: this addon names nothing outside dot-core. A
## source without the method or the signal (an older shell's link) is refused and the
## manager keeps its default, which is what every client did before. Calling it again with
## the same source is harmless; a manager rebuilt with the world needs it called again.
func follow_cvars(source: Object) -> bool:
	if source == null or not is_instance_valid(source):
		return false
	if not source.has_method(&"replicated_cvar") or not source.has_signal(&"replicated_cvar_changed"):
		DotLog.debug(CHANNEL, "cvar source cannot replicate; keeping this manager's own rules", {
			"source": source.get_class(),
		})
		return false

	for spec in cvar_specs():
		var cvar_name: String = spec["name"]
		var held := String(source.call(&"replicated_cvar", cvar_name, ""))
		if held != "":
			var _applied := set_cvar(cvar_name, held)

	if not source.is_connected(&"replicated_cvar_changed", _on_replicated_cvar):
		source.connect(&"replicated_cvar_changed", _on_replicated_cvar)

	return true


func _on_replicated_cvar(cvar_name: String, value: String) -> void:
	for spec in cvar_specs():
		if String(spec["name"]) == cvar_name:
			var _applied := set_cvar(cvar_name, value)
			return


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
		_emit_limb_hit(damage)

		if damage.lethal:
			entity_killed.emit(damage.victim, damage)

		var back := resolver.reflection(damage)

		if back != null:
			shot.damages.append(back)


## The limb threshold for [param limb]: its own entry, else `default`, else 0.
func limb_threshold(limb: StringName) -> float:
	return float(limb_min_damage.get(String(limb), limb_min_damage.get(limb, limb_min_damage.get("default", 0.0))))


func _emit_limb_hit(damage: DotDamage) -> void:
	if damage.limb == &"" or damage.amount < limb_threshold(damage.limb):
		return

	var entity: Node = damage.context.get("entity", null)

	if entity == null or not is_instance_valid(entity):
		return

	var impulse := damage.direction * damage.amount
	limb_hit.emit(entity, damage.limb, damage.point, damage.amount, impulse)

	if limb_target_fn.is_valid():
		var target: Object = limb_target_fn.call(entity)
		# Prefer the tagged limb: re-resolving it from geometry can name another where hitboxes overlap.
		if target != null and target.has_method(&"hit_limb"):
			target.call(&"hit_limb", damage.limb, damage.point, damage.amount, impulse)
		elif target != null and target.has_method(&"hit"):
			target.call(&"hit", damage.point, damage.amount, impulse)


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


## The entity id registered for the node a hit reported (a hitbox's owner), 0 when none.
func entity_id_of(node: Node) -> int:
	return _entity_id_of(node)


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
		"registrations_refused": _registrations_refused,
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
