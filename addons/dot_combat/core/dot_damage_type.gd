@tool
class_name DotDamageType
extends Resource

## A kind of damage, and everything the rules need to know about it.
##
## Separate from the weapon because the same weapon fires several kinds — a rocket
## does splash to everyone and direct damage to whoever it hit, and the two obey
## different rules about friendly fire and self-damage. A game adds its own by making
## another one of these; nothing in dot-combat switches on a known list.
##
## [b]Falloff is expressed as two distances and a floor[/b] rather than as a [Curve],
## because the server has to compute it identically to the client that predicted it.
## A [Curve] is baked at a resolution and resampled with a float, which is exactly the
## sort of thing that agrees on two machines until it does not.

## Stable identifier. Travels on the wire and appears in logs and kill feeds.
@export var id: StringName = &"generic"

## Shown to players. Free to reword; never branch on it.
@export var display_name: String = "Generic"

@export_group("Falloff")

## Distance at or below which the full amount lands.
@export_range(0.0, 10000.0, 0.5) var falloff_start: float = 0.0

## Distance at or beyond which only [member falloff_floor] of the amount lands.
## Zero disables falloff entirely.
@export_range(0.0, 10000.0, 0.5) var falloff_end: float = 0.0

## Fraction of the amount that still lands past [member falloff_end].
@export_range(0.0, 1.0, 0.01) var falloff_floor: float = 0.25

@export_group("Mitigation")

## Fraction of the damage that armour absorbs before health is touched.
##
## 0 means armour is ignored — fall damage and drowning usually want this. 1 means
## armour takes everything until it runs out.
@export_range(0.0, 1.0, 0.05) var armour_share: float = 0.6

## Fraction of the absorbed damage that is actually deducted from armour.
##
## Below 1 armour lasts longer than the damage it soaks; above 1 it degrades faster.
@export_range(0.0, 4.0, 0.05) var armour_wear: float = 1.0

## Multiply damage this type does to the attacker themselves. 0 forbids it.
@export_range(0.0, 4.0, 0.05) var self_scale: float = 0.5

## Multiply damage this type does to a team-mate. Ignored when friendly fire is off.
@export_range(0.0, 4.0, 0.05) var friendly_scale: float = 1.0

@export_group("Hit groups")

## Whether per-hit-group multipliers apply. Splash and fall damage want this off:
## a rocket landing at someone's feet should not do head damage because the sphere
## happened to touch a head hitbox first.
@export var uses_hit_groups: bool = true

@export_group("Reaction")

## Impulse applied to the victim per point of damage, along the hit direction.
@export_range(0.0, 100.0, 0.1) var knockback_per_point: float = 0.0

## Whether a victim killed by this can be revived on the same life. Informational;
## dot-combat never reads it, but a game's rules do and it belongs with the type.
@export var lethal_is_final: bool = true


static func make(p_id: StringName, p_display_name: String = "") -> DotDamageType:
	var t := DotDamageType.new()
	t.id = p_id
	t.display_name = p_display_name if p_display_name != "" else String(p_id).capitalize()
	return t


## Fraction of the base amount that survives being fired from [param distance].
##
## Clamped rather than extrapolated at both ends, so a shot from behind the muzzle
## (which a lag-compensated rewind can produce, by a few centimetres) does not do
## more than full damage.
func falloff_scale(distance: float) -> float:
	if falloff_end <= 0.0 or falloff_end <= falloff_start:
		return 1.0

	if distance <= falloff_start:
		return 1.0

	if distance >= falloff_end:
		return falloff_floor

	var t := (distance - falloff_start) / (falloff_end - falloff_start)
	return lerpf(1.0, falloff_floor, t)


func describe() -> Dictionary:
	return {
		"id": String(id),
		"falloff": "%.0f..%.0f -> %.2f" % [falloff_start, falloff_end, falloff_floor],
		"armour_share": armour_share,
		"self_scale": self_scale,
		"friendly_scale": friendly_scale,
		"hit_groups": uses_hit_groups,
	}


func _to_string() -> String:
	return "DotDamageType(%s)" % id
