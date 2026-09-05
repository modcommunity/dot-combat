class_name DotDamage
extends RefCounted

## One damage event, from the moment a weapon decides it happened to the moment a
## [DotHealth] has finished with it.
##
## The same object travels the whole way and is mutated by each stage, so a hook that
## wants to see why a number came out the way it did can read
## [member base_amount], every applied scale, and [member amount] side by side.
## A rules hook that wants to change the outcome writes to [member amount] or sets
## [member refused]; nothing downstream re-derives it.

## Who caused it. A game's own id space — dot-combat never interprets these beyond
## comparing them, so a peer id, a session id or a user id all work as long as one
## kind is used throughout.
var attacker: int = 0

## What is being damaged.
var victim: int = 0

## Damage before any scaling. Kept so a hook can see what the weapon asked for.
var base_amount: float = 0.0

## Damage after scaling, and what [DotHealth] will actually apply.
var amount: float = 0.0

var type: DotDamageType = null

## Which region was hit. See [DotHitGroup].
var hit_group: StringName = DotHitGroup.GENERIC

## World-space point of impact, for effects and for splash origin.
var point: Vector3 = Vector3.ZERO

## Direction the damage travelled, unit length. Knockback is applied along it.
var direction: Vector3 = Vector3.ZERO

## Metres between the muzzle and the impact, for falloff.
var distance: float = 0.0

## Which weapon, for the kill feed. Empty for world damage.
var weapon_id: StringName = &""

## The simulation tick this belongs to. On a lag-compensated shot this is the tick the
## world was rewound to, not the tick it was resolved on.
var tick: int = 0

## Set by the resolver when a rule forbids the damage outright — friendly fire off,
## victim already dead, victim invulnerable. Distinct from an amount of zero, which
## means the damage was allowed and simply did nothing.
var refused: bool = false

## Why it was refused. For logs and for tests; never shown to a player.
var refusal: String = ""

## How much armour actually absorbed. Filled in by [DotHealth].
var armour_absorbed: float = 0.0

## How much health was actually lost. Filled in by [DotHealth], and the number a kill
## feed and a damage counter should use — [member amount] is what was asked for, this
## is what landed.
var health_lost: float = 0.0

## Whether this event took the victim from alive to dead.
var lethal: bool = false

## Free-form space for a game's own rules to carry state between hooks.
var context: Dictionary = {}


static func make(
	p_attacker: int,
	p_victim: int,
	p_amount: float,
	p_type: DotDamageType
) -> DotDamage:
	var d := DotDamage.new()
	d.attacker = p_attacker
	d.victim = p_victim
	d.base_amount = p_amount
	d.amount = p_amount
	d.type = p_type
	return d


func is_self_damage() -> bool:
	return attacker == victim and attacker != 0


func is_world_damage() -> bool:
	return attacker == 0


func is_headshot() -> bool:
	return hit_group == DotHitGroup.HEAD


## Multiplies [member amount] and leaves a trace of why.
##
## Every stage of the resolver goes through here rather than assigning, so
## [method describe] can explain a final number that looks wrong — which, in a
## damage pipeline with falloff, hit groups, armour and two team scales, it regularly
## does.
func scale_by(factor: float, reason: String) -> void:
	if is_equal_approx(factor, 1.0):
		return

	amount *= factor

	var trace: Array = context.get("scales", [])
	trace.append("%s x%.3f" % [reason, factor])
	context["scales"] = trace


func refuse(reason: String) -> void:
	refused = true
	refusal = reason
	amount = 0.0


func describe() -> Dictionary:
	return {
		"attacker": attacker,
		"victim": victim,
		"base": base_amount,
		"amount": amount,
		"type": String(type.id) if type != null else "<none>",
		"group": String(hit_group),
		"distance": distance,
		"weapon": String(weapon_id),
		"tick": tick,
		"refused": refused,
		"refusal": refusal,
		"armour": armour_absorbed,
		"health": health_lost,
		"lethal": lethal,
		"scales": context.get("scales", []),
	}


func _to_string() -> String:
	if refused:
		return "DotDamage(refused: %s)" % refusal
	return "DotDamage(%d -> %d, %.1f %s%s)" % [
		attacker,
		victim,
		amount,
		type.id if type != null else &"?",
		", lethal" if lethal else "",
	]
