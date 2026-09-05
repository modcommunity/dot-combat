class_name DotShot
extends RefCounted

## One trigger pull that produced projectiles, before anything has been traced.
##
## The arsenal decides that a shot happened and what it is made of; the manager
## decides what it hit. Keeping those apart is what lets the same shot be resolved
## twice — predicted on the client with no damage applied, and authoritatively on the
## server with the world rewound to the tick this carries.

var weapon: DotWeapon = null

## The carrier. A game's own id space, matched against [member DotDamage.attacker].
var attacker: int = 0

## The tick the trigger was pulled on. On the server this is the tick the client
## claims, after clamping — see [DotCombatManager.resolve_shot].
var tick: int = 0

## Index of this shot within the carrier's history, so two shots on the same tick
## scatter differently. A weapon firing faster than the tick rate is why this exists.
var index: int = 0

var origin: Vector3 = Vector3.ZERO

## Unit aim direction, before spread.
var direction: Vector3 = Vector3.FORWARD

## Cone half-angle applied to the pellets, in degrees.
var spread: float = 0.0

## Unit direction per pellet, already scattered. Length is
## [member DotWeapon.pellets].
var pellets: Array[Vector3] = []

## Set on a shot produced by a replay rather than by a fresh command. A predicted
## client re-runs its inputs after every correction, and a replayed shot must not
## fire an effect, play a sound or bill a statistic a second time.
var replayed: bool = false

## Filled in by the manager once the shot is resolved.
var damages: Array[DotDamage] = []

## Where each pellet ended up, for tracers and decals. Parallel to
## [member pellets], and populated even for pellets that hit nothing — the endpoint is
## then the maximum range.
var impacts: Array[Vector3] = []


static func make(
	p_weapon: DotWeapon,
	p_attacker: int,
	p_tick: int,
	p_index: int
) -> DotShot:
	var shot := DotShot.new()
	shot.weapon = p_weapon
	shot.attacker = p_attacker
	shot.tick = p_tick
	shot.index = p_index
	return shot


## Builds the pellet directions from the weapon's pattern.
##
## Deterministic in every input, so a client and a server that agree on the shot agree
## on the pattern. See [DotSpread].
func scatter() -> void:
	pellets.clear()

	if weapon == null:
		pellets.append(direction)
		return

	var count := maxi(1, weapon.pellets)

	for pellet in range(count):
		if weapon.fixed_pattern:
			pellets.append(DotSpread.fixed_cone(direction, spread, pellet, count))
		else:
			pellets.append(
				DotSpread.cone(direction, spread, attacker, tick, index, pellet)
			)


## Total damage this shot actually did, after every rule.
func total_damage() -> float:
	var total := 0.0
	for damage in damages:
		total += damage.health_lost
	return total


func killed() -> Array[int]:
	var out: Array[int] = []
	for damage in damages:
		if damage.lethal:
			out.append(damage.victim)
	return out


func hit_anyone() -> bool:
	for damage in damages:
		if damage.health_lost > 0.0:
			return true
	return false


func describe() -> Dictionary:
	return {
		"weapon": String(weapon.id) if weapon != null else "<none>",
		"attacker": attacker,
		"tick": tick,
		"index": index,
		"spread": spread,
		"pellets": pellets.size(),
		"hits": damages.size(),
		"damage": total_damage(),
		"replayed": replayed,
	}


func _to_string() -> String:
	return "DotShot(%s t%d, %d pellets, %.0f dmg)" % [
		weapon.id if weapon != null else &"?",
		tick,
		pellets.size(),
		total_damage(),
	]
