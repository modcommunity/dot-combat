class_name DotShot
extends RefCounted

## One thing that was fired and now has to be resolved against the world.
##
## [b]It describes itself rather than pointing at a weapon.[/b] Until dot-weapon
## existed this held a `DotWeapon` and the manager read `weapon.damage`,
## `weapon.max_range` and `weapon.delivery` off it, which quietly made "what can be
## resolved" the same question as "what that one resource can describe": a bow, a
## thrown charge and a game's own weapon had no way to produce one without pretending
## to be a gun. Copying the six numbers the resolver actually needs onto the shot costs
## a few bytes and buys a combat layer that resolves anything.
##
## So dot-combat now knows nothing about weapons at all. dot-weapon fills one of these
## in; so can a trap, a turret, an environmental hazard or a script with no weapon
## anywhere near it.
##
## [b]Deciding a shot happened and deciding what it hit are still two different jobs in
## two different places.[/b] Whoever made the shot runs on the owning client and on the
## server; [DotCombatManager] resolves it only where the authority is.

## What produced it, for a kill feed, a statistic and a damage record.
##
## A [StringName] rather than a reference, because the resolver never needs the thing
## itself and a server validating a hit should not have to have the weapon loaded.
var weapon_id: StringName = &""

## The carrier. A game's own id space, matched against [member DotDamage.attacker].
var attacker: int = 0

## The tick the trigger was pulled on. On the server this is the tick the client
## claims, after clamping — see [method DotCombatManager.resolve_shot].
var tick: int = 0

## Index of this shot within the carrier's history, so two shots on the same tick
## scatter differently. A weapon firing faster than the tick rate is why this exists.
var index: int = 0

var origin: Vector3 = Vector3.ZERO

## Unit aim direction, before spread.
var direction: Vector3 = Vector3.FORWARD

## Cone half-angle applied to the pellets, in degrees.
var spread: float = 0.0

## Unit direction per pellet, already scattered. Filled by [method scatter].
var pellets: Array[Vector3] = []

## How many pellets [method scatter] should produce.
var pellet_count: int = 1

## Places the pellets on a ring rather than by hash.
##
## For a weapon whose pattern should be learnable rather than random, which is most
## competitive shotguns.
var fixed_pattern: bool = false

## Damage one pellet does before any rule is applied.
var damage: float = 0.0

var damage_type: DotDamageType = null

## Metres past which a pellet hits nothing.
var max_range: float = 200.0

## Traced later rather than now.
##
## A projectile, an arrow or a thrown charge is an entity with a lifetime that will hit
## something several ticks from now, and lag compensation has nothing to say about it:
## by the time it arrives everybody already agrees where everybody is. The manager
## records the endpoints so a caller can launch it along the right vector and applies
## no damage of its own.
var deferred: bool = false

## Radius of the splash where the shot lands. Zero means no splash.
var splash_radius: float = 0.0

var splash_damage: float = 0.0

## The splash's own type. Null falls back to [member damage_type].
var splash_type: DotDamageType = null

var splash_hurts_owner: bool = true

## Set on a shot produced by a replay rather than by a fresh command.
##
## A predicted client re-runs its inputs after every correction, and a replayed shot
## must not fire an effect, play a sound or bill a statistic a second time.
var replayed: bool = false

## Filled in by the manager once the shot is resolved.
var damages: Array[DotDamage] = []

## Where each pellet ended up, for tracers and decals. Parallel to [member pellets],
## and populated even for pellets that hit nothing — the endpoint is then the maximum
## range.
var impacts: Array[Vector3] = []


static func make(
	p_weapon_id: StringName,
	p_attacker: int,
	p_tick: int,
	p_index: int
) -> DotShot:
	var shot := DotShot.new()
	shot.weapon_id = p_weapon_id
	shot.attacker = p_attacker
	shot.tick = p_tick
	shot.index = p_index
	return shot


## Builds the pellet directions.
##
## Deterministic in every input, so a client and a server that agree on the shot agree
## on the pattern. See [DotSpread].
func scatter() -> void:
	pellets.clear()

	var count := maxi(1, pellet_count)

	for pellet in range(count):
		if fixed_pattern:
			pellets.append(DotSpread.fixed_cone(direction, spread, pellet, count))
		else:
			pellets.append(
				DotSpread.cone(direction, spread, attacker, tick, index, pellet)
			)


## Damage the splash does at [param distance] from its centre.
##
## Linear to zero at the edge, and zero outside. Linear rather than quadratic because
## an inverse-square splash is almost all edge, which plays as a weapon that has to be
## a direct hit — at which point the splash is decoration.
func splash_at(distance: float) -> float:
	if splash_radius <= 0.0 or splash_damage <= 0.0:
		return 0.0

	if distance >= splash_radius:
		return 0.0

	return splash_damage * (1.0 - distance / splash_radius)


## Total damage this shot actually did, after every rule.
func total_damage() -> float:
	var total := 0.0
	for d in damages:
		total += d.health_lost
	return total


func killed() -> Array[int]:
	var out: Array[int] = []
	for d in damages:
		if d.lethal:
			out.append(d.victim)
	return out


func hit_anyone() -> bool:
	for d in damages:
		if d.health_lost > 0.0:
			return true
	return false


func describe() -> Dictionary:
	return {
		"weapon": String(weapon_id),
		"attacker": attacker,
		"tick": tick,
		"index": index,
		"spread": spread,
		"pellets": pellets.size(),
		"hits": damages.size(),
		"damage": total_damage(),
		"deferred": deferred,
		"replayed": replayed,
	}


func _to_string() -> String:
	return "DotShot(%s t%d, %d pellets, %.0f dmg)" % [
		String(weapon_id), tick, pellets.size(), total_damage()
	]
