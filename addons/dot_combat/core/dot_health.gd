@tool
class_name DotHealth
extends Node

## Health, armour and being alive. The node every damageable thing has one of.
##
## [b]This is a plain [Node], not a [code]DotNetBehaviour[/code].[/b] Only dot-core is
## a hard dependency in this family, and a script that so much as [i]mentions[/i] a
## [code]class_name[/code] the project does not have fails to parse — taking every
## script that references it down with it. So the numbers live here and
## [DotCombatNetSync] describes how to replicate them, without either file naming
## dot-net. See this project's CLAUDE.md for the bridge.
##
## [b]Applying damage is deterministic and takes no wall-clock time.[/b] Regeneration
## and invulnerability are counted in ticks, not seconds, because a predicted client
## and an authoritative server must reach the same number from the same tick — and
## [method Time.get_ticks_msec] on two machines never does.

const CHANNEL := "combat.health"

## Damage was applied. Carries the [DotDamage] with its outcome fields filled in.
signal damaged(damage: DotDamage)

## Health went up. [param amount] is what actually landed after the cap.
signal healed(amount: float, source: int)

## Health reached zero. Fires exactly once per life.
signal died(damage: DotDamage)

## [method revive] was called on a dead entity.
signal revived()

## Armour changed, including to zero. Separate from [signal damaged] so a HUD can
## bind to it without filtering.
signal armour_changed(value: float)

@export_group("Health")

@export_range(0.0, 10000.0, 1.0) var max_health: float = 100.0

## Ceiling for overheal. Below [member max_health] it is treated as equal to it —
## a game that does not want overheal leaves this at zero.
@export_range(0.0, 10000.0, 1.0) var overheal_cap: float = 0.0

@export_group("Armour")

@export_range(0.0, 10000.0, 1.0) var max_armour: float = 100.0

@export_group("Regeneration")

## Health per second restored once regeneration starts. Zero disables it.
@export_range(0.0, 1000.0, 1.0) var regen_per_second: float = 0.0

## Seconds of not being damaged before regeneration starts.
@export_range(0.0, 60.0, 0.1) var regen_delay_sec: float = 5.0

## Regeneration stops here rather than at [member max_health]. Zero means
## [member max_health].
@export_range(0.0, 10000.0, 1.0) var regen_ceiling: float = 0.0

@export_group("Rules")

## Ticks of invulnerability granted by [method reset]. Spawn protection.
@export_range(0, 600, 1) var spawn_protection_ticks: int = 0

## Refuse all damage. For spectators, warmup, and the noclip case.
@export var invulnerable: bool = false

## Current health. Zero or below means dead.
var health: float = 100.0

var armour: float = 0.0

## False once health reaches zero, until [method reset] or [method revive].
var alive: bool = true

## Tick this entity last took damage on. Drives regeneration.
var last_damage_tick: int = -1000000

## Ticks up to and including which damage is refused.
var invulnerable_until_tick: int = -1

## Total damage taken this life. For a scoreboard and for tests.
var damage_taken: float = 0.0

## What killed this entity, kept until the next [method reset]. Null when alive or
## when death had no attributable cause.
var last_fatal: DotDamage = null

var _tick_rate: int = 60


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	reset()


## Sets the simulation rate the tick-based timers are counted against.
##
## Must match whatever drives [method tick]. Getting it wrong does not desynchronise
## anything — both ends would be wrong the same way — but it makes regeneration run at
## the wrong speed, which reads as a tuning problem rather than a wiring one.
func set_tick_rate(rate: int) -> void:
	_tick_rate = maxi(1, rate)


func tick_rate() -> int:
	return _tick_rate


## Back to full, alive, no armour, spawn protection running from [param tick].
func reset(tick: int = 0) -> void:
	health = max_health
	armour = 0.0
	alive = true
	damage_taken = 0.0
	last_fatal = null
	last_damage_tick = tick - _regen_delay_ticks() - 1
	invulnerable_until_tick = (
		tick + spawn_protection_ticks - 1 if spawn_protection_ticks > 0 else -1
	)
	armour_changed.emit(armour)


## Applies one damage event and fills its outcome fields in.
##
## Returns the event either way — a refusal is not a failure, it is an outcome the
## caller usually wants to see. Callers that only care whether anything landed check
## [member DotDamage.health_lost].
##
## [b]The event is mutated, not copied.[/b] The resolver has already written its
## scaling trace into it and a rules hook may have adjusted [member DotDamage.amount];
## copying here would silently discard both.
func apply(damage: DotDamage) -> DotDamage:
	if damage == null:
		push_error("DotHealth.apply() called with null.")
		return null

	if not alive:
		damage.refuse("victim is already dead")
		return damage

	if invulnerable:
		damage.refuse("victim is invulnerable")
		return damage

	if damage.tick <= invulnerable_until_tick:
		damage.refuse("spawn protection")
		return damage

	if damage.amount <= 0.0:
		# Allowed but inert. Still records the tick, so a stream of zero-damage hits
		# does not let someone regenerate through a firefight.
		last_damage_tick = damage.tick
		damaged.emit(damage)
		return damage

	var absorbed := 0.0
	var to_armour := 0.0
	var share := damage.type.armour_share if damage.type != null else 0.0

	if armour > 0.0 and share > 0.0:
		var wanted := damage.amount * share
		var wear := damage.type.armour_wear if damage.type != null else 1.0
		if wear <= 0.0:
			# Armour that never wears would absorb its share forever. Treat it as
			# absorbing nothing rather than as invulnerability, which is what a
			# zero here almost always means: a resource left at its default.
			to_armour = 0.0
			absorbed = 0.0
		else:
			to_armour = minf(armour, wanted * wear)
			absorbed = to_armour / wear
			armour -= to_armour

	var to_health := maxf(0.0, damage.amount - absorbed)

	damage.armour_absorbed = absorbed
	damage.health_lost = minf(to_health, health)

	health -= to_health
	damage_taken += damage.health_lost
	last_damage_tick = damage.tick

	if absorbed > 0.0:
		armour_changed.emit(armour)

	if health <= 0.0:
		health = 0.0
		alive = false
		damage.lethal = true
		last_fatal = damage
		damaged.emit(damage)
		died.emit(damage)
		return damage

	damaged.emit(damage)
	return damage


## Restores health up to [member max_health], or [member overheal_cap] when it is
## higher. Returns what actually landed.
func heal(amount: float, source: int = 0) -> float:
	if not alive or amount <= 0.0:
		return 0.0

	var ceiling := maxf(max_health, overheal_cap)
	var landed := minf(amount, ceiling - health)

	if landed <= 0.0:
		return 0.0

	health += landed
	healed.emit(landed, source)
	return landed


## Adds armour up to [member max_armour]. Returns what actually landed.
func add_armour(amount: float) -> float:
	if not alive or amount <= 0.0:
		return 0.0

	var landed := minf(amount, max_armour - armour)

	if landed <= 0.0:
		return 0.0

	armour += landed
	armour_changed.emit(armour)
	return landed


## Brings a dead entity back at [param fraction] of full health, in place.
##
## Distinct from [method reset], which is what a respawn does: this keeps the
## accumulated [member damage_taken] and does not grant spawn protection, because a
## revive happens where the player died and protecting them there protects whoever is
## standing over the body.
func revive(fraction: float = 1.0) -> void:
	if alive:
		return

	alive = true
	health = maxf(1.0, max_health * clampf(fraction, 0.0, 1.0))
	last_fatal = null
	revived.emit()


## Advances regeneration by one simulation tick.
##
## Safe to call on a dead or full entity; it does nothing. Not called automatically —
## a predicted entity is ticked by the simulation loop, and calling it from
## [method Node._process] as well would run it twice at different rates.
func tick(current_tick: int, delta: float) -> void:
	if not alive or regen_per_second <= 0.0:
		return

	if current_tick - last_damage_tick < _regen_delay_ticks():
		return

	var ceiling := regen_ceiling if regen_ceiling > 0.0 else max_health

	if health >= ceiling:
		return

	var before := health
	health = minf(ceiling, health + regen_per_second * delta)

	if health > before:
		healed.emit(health - before, 0)


func _regen_delay_ticks() -> int:
	return int(round(regen_delay_sec * float(_tick_rate)))


## Health as a fraction of maximum, clamped to 1 even when overhealed.
##
## For a bar that should fill rather than overflow. A HUD that wants to show overheal
## reads [member health] directly.
func fraction() -> float:
	if max_health <= 0.0:
		return 0.0
	return clampf(health / max_health, 0.0, 1.0)


## Total damage of this type this entity could take before dying.
##
## What a bot's threat assessment and a "does this shot kill" test want, and not the
## same as health plus armour: armour only absorbs its type's share, and it may run
## out partway through.
##
## Armour absorbs [code]share[/code] of incoming damage and is deducted at
## [code]wear[/code] per absorbed point, so [code]armour / wear[/code] damage points
## can be absorbed in total. Either that runs out first, or it does not:
##
## - It does not: every point costs [code]1 - share[/code] health, so death comes at
##   [code]health / (1 - share)[/code].
## - It does: the rest arrives undiminished, so death comes at
##   [code]health + armour / wear[/code].
func effective_health(type: DotDamageType) -> float:
	if type == null or type.armour_share <= 0.0 or armour <= 0.0:
		return health

	var wear := maxf(0.001, type.armour_wear)
	var absorbable := armour / wear
	var share := clampf(type.armour_share, 0.0, 1.0)

	if share >= 1.0:
		return health + absorbable

	var if_armour_holds := health / (1.0 - share)

	if if_armour_holds * share <= absorbable:
		return if_armour_holds

	return health + absorbable


func is_protected(current_tick: int) -> bool:
	return invulnerable or current_tick <= invulnerable_until_tick


func describe() -> Dictionary:
	return {
		"health": health,
		"max_health": max_health,
		"armour": armour,
		"alive": alive,
		"invulnerable": invulnerable,
		"protected_until": invulnerable_until_tick,
		"damage_taken": damage_taken,
		"last_damage_tick": last_damage_tick,
		"killed_by": last_fatal.attacker if last_fatal != null else 0,
	}


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"health   %.0f/%.0f%s" % [
			health, max_health, "" if alive else "  (dead)"
		],
		"armour   %.0f/%.0f" % [armour, max_armour],
		"taken    %.0f this life" % damage_taken,
	])
